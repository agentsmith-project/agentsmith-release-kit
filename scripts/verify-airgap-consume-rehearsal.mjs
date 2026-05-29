#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { statSync } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERIFY_RELEASE = path.join(ROOT_DIR, 'scripts', 'verify-release.sh');
const AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const REPORT_FILE = 'airgap-consume-rehearsal-report.json';
const BUNDLE_MANIFEST_FILE = 'airgap-bundle-manifest.json';
const REQUIRED_ARGS = [
  'bundleRoot',
  'renderValues',
  'substrateTruth',
  'targetPrerequisites',
  'namespace',
  'outputDir'
];
const COMPONENT_KINDS = [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'image_map'
];
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const SUPPORTED_REHEARSAL_LABELS = new Set(['existing_kubernetes', 'kind_rehearsal']);
const MANAGED_OUTPUT_ENTRIES = [
  REPORT_FILE,
  'airgap-bundle-check',
  'airgap-deployment-gate'
];
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i;

class CliError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 2;
  }
}

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

class StepError extends Error {
  constructor(step, status) {
    super(`airgap consume rehearsal step failed: ${step}`);
    this.exitCode = status || 1;
  }
}

function usage() {
  return `Usage:
  node scripts/verify-airgap-consume-rehearsal.mjs \\
    --bundle-root <dir> \\
    [--bundle-manifest <bundle-local-json>] \\
    --render-values <bundle-local-json> \\
    --substrate-truth <bundle-local-json> \\
    --target-prerequisites <json> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--rehearsal-label existing_kubernetes|kind_rehearsal] \\
    [--mode server-dry-run|apply] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
    [--forbidden-source-root <dir>] \\
    [--archive-probe <executable>] \\
    [--image-loader <executable>] \\
    [--confirm-apply existing_kubernetes/external_declared/airgap] \\
    [--operator-run-id <id>] \\
    [--timeout <duration>] \\
    [--smoke-url <https-url>] \\
    [--expected-status <code>] \\
    [--timeout-ms <ms>] \\
    [--allow-http] \\
    [--allow-localhost]

Rehearsal label is operator-provided label-only metadata. It does not change
the existing_kubernetes/external_declared/airgap target profile or prove kind.`;
}

function cliFail(message) {
  throw new CliError(message);
}

function fail(message) {
  throw new ValidationError(message);
}

function toKebab(value) {
  return value.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {
    mode: 'server-dry-run',
    kubectl: 'kubectl',
    rehearsalLabel: 'existing_kubernetes',
    forbiddenSourceRoots: [],
    allowHttp: false,
    allowLocalhost: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    if (arg.startsWith('--mode=')) {
      parsed.mode = arg.slice('--mode='.length);
      continue;
    }
    if (arg.startsWith('--rehearsal-label=')) {
      parsed.rehearsalLabel = arg.slice('--rehearsal-label='.length);
      continue;
    }

    switch (arg) {
      case '--bundle-root':
        parsed.bundleRoot = nextValue();
        break;
      case '--bundle-manifest':
        parsed.bundleManifest = nextValue();
        break;
      case '--render-values':
        parsed.renderValues = nextValue();
        break;
      case '--substrate-truth':
        parsed.substrateTruth = nextValue();
        break;
      case '--target-prerequisites':
        parsed.targetPrerequisites = nextValue();
        break;
      case '--namespace':
        parsed.namespace = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--rehearsal-label':
        parsed.rehearsalLabel = nextValue();
        break;
      case '--mode':
        parsed.mode = nextValue();
        break;
      case '--kubeconfig':
        parsed.kubeconfig = nextValue();
        break;
      case '--context':
        parsed.context = nextValue();
        break;
      case '--kubectl':
        parsed.kubectl = nextValue();
        break;
      case '--forbidden-source-root':
        parsed.forbiddenSourceRoots.push(nextValue());
        break;
      case '--archive-probe':
        parsed.archiveProbe = nextValue();
        break;
      case '--image-loader':
        parsed.imageLoader = nextValue();
        break;
      case '--confirm-apply':
        parsed.confirmApply = nextValue();
        break;
      case '--operator-run-id':
        parsed.operatorRunId = nextValue();
        break;
      case '--timeout':
        parsed.timeout = nextValue();
        break;
      case '--smoke-url':
        parsed.smokeUrl = nextValue();
        break;
      case '--expected-status':
        parsed.expectedStatus = nextValue();
        break;
      case '--timeout-ms':
        parsed.timeoutMs = nextValue();
        break;
      case '--allow-http':
        parsed.allowHttp = true;
        break;
      case '--allow-localhost':
        parsed.allowLocalhost = true;
        break;
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        cliFail(`unknown argument: ${arg}`);
    }
  }

  if (parsed.help) {
    return parsed;
  }

  for (const key of REQUIRED_ARGS) {
    if (!parsed[key]) {
      cliFail(`missing required argument: --${toKebab(key)}`);
    }
  }
  return parsed;
}

function validateArgs(args) {
  if (!SUPPORTED_MODES.has(args.mode)) {
    cliFail('--mode must be server-dry-run or apply');
  }
  if (!SUPPORTED_REHEARSAL_LABELS.has(args.rehearsalLabel)) {
    cliFail('--rehearsal-label must be existing_kubernetes or kind_rehearsal');
  }
}

async function removeManagedOutputs(outputDir) {
  await Promise.all(
    MANAGED_OUTPUT_ENTRIES.map((entry) =>
      fs.rm(path.join(outputDir, entry), { recursive: true, force: true })
    )
  );
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function digestFile(file, label) {
  try {
    return digestBuffer(await fs.readFile(file));
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function readJson(file, label) {
  let raw;
  try {
    raw = await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      value: JSON.parse(raw),
      input_sha256: digestBuffer(Buffer.from(raw))
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireArray(value, label) {
  if (!Array.isArray(value)) {
    fail(`${label} must be an array`);
  }
  return value;
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function rejectUriOrWindowsPath(value, label) {
  if (value.trim() !== value) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (value.startsWith('//') || WINDOWS_DRIVE_RE.test(value) || value.includes('\\')) {
    fail(`${label} must be a local POSIX path`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be a local POSIX path, not a URI`);
  }
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

async function canonicalBundleRoot(input) {
  rejectUriOrWindowsPath(requireString(input, 'bundle_root'), 'bundle_root');
  const requested = path.resolve(input);
  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read bundle root: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('bundle root must not be a symlink');
  }
  if (!stat.isDirectory()) {
    fail('bundle root must be a directory');
  }
  try {
    return await fs.realpath(requested);
  } catch (error) {
    fail(`cannot resolve bundle root: ${error.message}`);
  }
}

function validateBundleRelativePath(value, label) {
  const relativePath = requireString(value, label);
  if (
    relativePath.trim() !== relativePath ||
    path.posix.isAbsolute(relativePath) ||
    path.isAbsolute(relativePath) ||
    WINDOWS_DRIVE_RE.test(relativePath) ||
    relativePath.includes('\\') ||
    URI_SCHEME_RE.test(relativePath)
  ) {
    fail(`${label} must be a relative bundle path`);
  }
  if (relativePath.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) {
    fail(`${label} must not contain empty, dot, or parent segments`);
  }
  return relativePath;
}

async function bundleLocalFile(input, label, bundleRoot) {
  rejectUriOrWindowsPath(requireString(input, label), label);
  const requested = path.resolve(input);
  if (!isInsidePath(bundleRoot, requested)) {
    fail(`${label} must be inside bundle root`);
  }
  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a file`);
  }
  try {
    const realPath = await fs.realpath(requested);
    if (!isInsidePath(bundleRoot, realPath)) {
      fail(`${label} must resolve inside bundle root`);
    }
    return realPath;
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

async function resolveBundleManifest(args, bundleRoot) {
  return bundleLocalFile(
    args.bundleManifest || path.join(bundleRoot, BUNDLE_MANIFEST_FILE),
    'bundle manifest',
    bundleRoot
  );
}

async function resolveManifestComponent(bundleRoot, component, label) {
  const relativePath = validateBundleRelativePath(component.path, `${label}.path`);
  return bundleLocalFile(path.join(bundleRoot, relativePath), `${label}.path`, bundleRoot);
}

async function discoverComponents(bundleRoot, manifest) {
  const components = requireArray(manifest.components, 'bundle_manifest.components');
  const byKind = new Map();
  for (const [index, value] of components.entries()) {
    const label = `bundle_manifest.components[${index}]`;
    const component = requireObject(value, label);
    const kind = requireString(component.kind, `${label}.kind`);
    if (byKind.has(kind)) {
      fail(`bundle_manifest.components contains duplicate kind: ${kind}`);
    }
    byKind.set(kind, component);
  }

  const paths = {};
  for (const kind of COMPONENT_KINDS) {
    const component = byKind.get(kind);
    if (!component) {
      fail(`bundle_manifest.components must include ${kind}`);
    }
    paths[kind] = await resolveManifestComponent(
      bundleRoot,
      component,
      `bundle_manifest.components.${kind}`
    );
  }
  return paths;
}

async function readReleaseIdentity(releaseContractPath) {
  const input = await readJson(releaseContractPath, 'release contract');
  const contract = requireObject(input.value, 'release_contract');
  return {
    release_id: requireString(contract.release_id, 'release_contract.release_id'),
    git_sha: requireString(contract.git_sha, 'release_contract.git_sha'),
    input_sha256: input.input_sha256
  };
}

function pushIfValue(argv, flag, value) {
  if (value !== undefined) {
    argv.push(flag, value);
  }
}

function appendForwardedArgs(argv, args) {
  pushIfValue(argv, '--kubeconfig', args.kubeconfig);
  pushIfValue(argv, '--context', args.context);
  pushIfValue(argv, '--kubectl', args.kubectl);
  pushIfValue(argv, '--archive-probe', args.archiveProbe);
  pushIfValue(argv, '--image-loader', args.imageLoader);
  pushIfValue(argv, '--confirm-apply', args.confirmApply);
  pushIfValue(argv, '--operator-run-id', args.operatorRunId);
  pushIfValue(argv, '--timeout', args.timeout);
  pushIfValue(argv, '--smoke-url', args.smokeUrl);
  pushIfValue(argv, '--expected-status', args.expectedStatus);
  pushIfValue(argv, '--timeout-ms', args.timeoutMs);
  for (const root of args.forbiddenSourceRoots) {
    argv.push('--forbidden-source-root', root);
  }
  if (args.allowHttp) {
    argv.push('--allow-http');
  }
  if (args.allowLocalhost) {
    argv.push('--allow-localhost');
  }
}

function runVerify(step, mode, argv) {
  const result = spawnSync('bash', [VERIFY_RELEASE, mode, ...argv], {
    cwd: ROOT_DIR,
    stdio: 'inherit',
    env: process.env
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new StepError(step, result.status);
  }
}

function outputSubdir(args, name) {
  return path.join(args.outputDir, name);
}

function relativeOutputPath(outputDir, file) {
  return path.relative(outputDir, file).split(path.sep).join('/');
}

function assertReportFile(file, step) {
  let stat;
  try {
    stat = statSync(file);
  } catch {
    throw new StepError(step, 1);
  }
  if (!stat.isFile()) {
    throw new StepError(step, 1);
  }
}

async function readProducerReport(file, step, expectedMode) {
  assertReportFile(file, step);
  const input = await readJson(file, `${step} report`);
  const report = requireObject(input.value, `${step}_report`);
  if (report.readiness !== false) {
    fail(`${step} report readiness must be false`);
  }
  if (report.status !== 'pass') {
    fail(`${step} report status must be pass`);
  }
  if (expectedMode !== undefined && report.mode !== expectedMode) {
    fail(`${step} report mode must match requested mode`);
  }
  return input.input_sha256;
}

function targetProfile() {
  return {
    value: AIRGAP_TARGET_PROFILE,
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'airgap'
  };
}

function rehearsalLabel(value) {
  return {
    value,
    provided_by: 'operator',
    semantics: 'label_only',
    target_profile_effect: 'none',
    evidence_line:
      value === 'kind_rehearsal'
        ? 'operator_labeled_kind_rehearsal'
        : 'operator_labeled_existing_kubernetes'
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-consume-rehearsal.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main(argv) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log(usage());
    return;
  }
  validateArgs(args);
  const bundleRoot = await canonicalBundleRoot(args.bundleRoot);
  args.renderValues = await bundleLocalFile(args.renderValues, 'render values', bundleRoot);
  args.substrateTruth = await bundleLocalFile(args.substrateTruth, 'substrate truth', bundleRoot);

  await removeManagedOutputs(args.outputDir);

  const bundleManifestPath = await resolveBundleManifest(args, bundleRoot);
  const bundleManifestInput = await readJson(bundleManifestPath, 'bundle manifest');
  const componentPaths = await discoverComponents(
    bundleRoot,
    requireObject(bundleManifestInput.value, 'bundle_manifest')
  );
  const releaseIdentity = await readReleaseIdentity(componentPaths.release_contract);

  const bundleCheckDir = outputSubdir(args, 'airgap-bundle-check');
  const bundleCheckReportPath = path.join(bundleCheckDir, 'airgap-bundle-check-report.json');
  runVerify('airgap-bundle-check', '--airgap-bundle-check', [
    '--release-contract',
    componentPaths.release_contract,
    '--deploy-template-package',
    componentPaths.deploy_template_package,
    '--archive',
    componentPaths.deploy_template_archive,
    '--image-map',
    componentPaths.image_map,
    '--target-profile',
    AIRGAP_TARGET_PROFILE,
    '--bundle-root',
    bundleRoot,
    '--bundle-manifest',
    bundleManifestPath,
    '--output-dir',
    bundleCheckDir
  ]);
  const bundleCheckReportDigest = await readProducerReport(
    bundleCheckReportPath,
    'airgap-bundle-check'
  );

  const deploymentGateDir = outputSubdir(args, 'airgap-deployment-gate');
  const deploymentGateReportPath = path.join(
    deploymentGateDir,
    'airgap-deployment-gate-report.json'
  );
  const deploymentGateArgv = [
    '--release-contract',
    componentPaths.release_contract,
    '--deploy-template-package',
    componentPaths.deploy_template_package,
    '--archive',
    componentPaths.deploy_template_archive,
    '--image-map',
    componentPaths.image_map,
    '--target-profile',
    AIRGAP_TARGET_PROFILE,
    '--bundle-root',
    bundleRoot,
    '--bundle-manifest',
    bundleManifestPath,
    '--render-values',
    args.renderValues,
    '--substrate-truth',
    args.substrateTruth,
    '--target-prerequisites',
    args.targetPrerequisites,
    '--namespace',
    args.namespace,
    '--output-dir',
    deploymentGateDir,
    '--mode',
    args.mode
  ];
  appendForwardedArgs(deploymentGateArgv, args);
  runVerify('airgap-deployment-gate', '--airgap-deployment-gate', deploymentGateArgv);
  const deploymentGateReportDigest = await readProducerReport(
    deploymentGateReportPath,
    'airgap-deployment-gate',
    args.mode
  );

  await writeReport(args.outputDir, {
    schema: 'agentsmith.airgap-consume-rehearsal/v1',
    scope: 'airgap_consume_rehearsal_only',
    readiness: false,
    status: 'pass',
    mode: args.mode,
    release_id: releaseIdentity.release_id,
    git_sha: releaseIdentity.git_sha,
    target_profile: targetProfile(),
    rehearsal_label: rehearsalLabel(args.rehearsalLabel),
    input_digests: {
      release_contract: releaseIdentity.input_sha256,
      deploy_template_package: await digestFile(
        componentPaths.deploy_template_package,
        'deploy template package'
      ),
      deploy_template_archive: await digestFile(
        componentPaths.deploy_template_archive,
        'deploy template archive'
      ),
      image_map: await digestFile(componentPaths.image_map, 'image map'),
      bundle_manifest: bundleManifestInput.input_sha256
    },
    producer_report_digests: {
      airgap_bundle_check_report: bundleCheckReportDigest,
      airgap_deployment_gate_report: deploymentGateReportDigest
    },
    steps: [
      {
        name: 'airgap-bundle-check',
        report_path: relativeOutputPath(args.outputDir, bundleCheckReportPath)
      },
      {
        name: 'airgap-deployment-gate',
        report_path: relativeOutputPath(args.outputDir, deploymentGateReportPath)
      }
    ]
  });

  console.log('PASS: airgap consume rehearsal completed focused diagnostics');
}

main(process.argv.slice(2)).catch((error) => {
  const exitCode = error.exitCode || 1;
  const prefix = exitCode === 2 ? 'error' : 'FAIL';
  console.error(`${prefix}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
