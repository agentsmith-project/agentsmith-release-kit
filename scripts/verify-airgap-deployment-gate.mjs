#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { statSync } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERIFY_RELEASE = path.join(ROOT_DIR, 'scripts', 'verify-release.sh');
const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'imageMap',
  'targetProfile',
  'bundleRoot',
  'bundleManifest',
  'renderValues',
  'substrateTruth',
  'targetPrerequisites',
  'namespace',
  'outputDir'
];
const EXTERNAL_AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const KIT_AIRGAP_TARGET_PROFILE = 'existing_kubernetes/kit_installed/airgap';
const SUPPORTED_TARGET_PROFILES = [
  EXTERNAL_AIRGAP_TARGET_PROFILE,
  KIT_AIRGAP_TARGET_PROFILE
];
const SUPPORTED_TARGET_PROFILE_SET = new Set(SUPPORTED_TARGET_PROFILES);
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const REPORT_SCHEMA = 'agentsmith.airgap-deployment-gate/v1';
const REPORT_SCOPE = 'airgap_deployment_gate_only';
const REPORT_FILE = 'airgap-deployment-gate-report.json';
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const TIMEOUT_RE = /^(?:0|[1-9][0-9]*(?:ms|s|m|h))$/;
const FORBIDDEN_ROUTE_TEXT_RE = /(?:required_product_flows|product_flows|product_flow_results|deploy_readiness|release_verdict|\bverdict\b|\bkubeconfig\b)/i;
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:password|passwd|pwd|token|secret|client_secret|private_key|access_key|api_key)\s*[:=]\s*[^/\s]{8,}/i
];
const MANAGED_OUTPUT_ENTRIES = [
  REPORT_FILE,
  'target-preflight',
  'substrate-pack-check',
  'airgap-image-load',
  'airgap-bundle-render-check',
  'apply',
  'rollout',
  'smoke'
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
  constructor(step, status, message) {
    super(message || `airgap focused chain step failed: ${step}`);
    this.exitCode = status || 1;
  }
}

function usage() {
  return `Usage:
  node scripts/verify-airgap-deployment-gate.mjs \\
    --release-contract <bundle-local-json> \\
    --deploy-template-package <bundle-local-json> \\
    --archive <bundle-local-tgz> \\
    --image-map <bundle-local-json> \\
    --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap \\
    --bundle-root <dir> \\
    --bundle-manifest <bundle-local-json> \\
    --render-values <bundle-local-json> \\
    --substrate-truth <bundle-local-json> \\
    --target-prerequisites <json> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--mode server-dry-run|apply] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
    [--archive-probe <executable>] \\
    [--image-loader <executable>] \\
    [--confirm-apply <matching-target-profile>] \\
    [--operator-run-id <id>] \\
    [--timeout <duration>] \\
    [--smoke-url <https-url>] \\
    [--expected-status <code>] \\
    [--timeout-ms <ms>] \\
    [--allow-http] \\
    [--allow-localhost] \\
    [--forbidden-source-root <dir>]`;
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

function extractOutputDirFromRawArgs(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.trim() === '' || value.startsWith('--')) {
      return undefined;
    }
    return value;
  }
  return undefined;
}

async function removeManagedOutputsFromRawArgs(argv) {
  const outputDir = extractOutputDirFromRawArgs(argv);
  if (outputDir) {
    await removeManagedOutputs(path.resolve(outputDir));
  }
}

function parseArgs(argv) {
  const parsed = {
    mode: 'server-dry-run',
    kubectl: 'kubectl',
    kubectlProvided: false,
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
    if (arg.startsWith('--confirm-apply=')) {
      parsed.confirmApply = arg.slice('--confirm-apply='.length);
      continue;
    }
    if (arg.startsWith('--timeout=')) {
      parsed.timeout = arg.slice('--timeout='.length);
      continue;
    }
    if (arg.startsWith('--expected-status=')) {
      parsed.expectedStatus = arg.slice('--expected-status='.length);
      continue;
    }
    if (arg.startsWith('--timeout-ms=')) {
      parsed.timeoutMs = arg.slice('--timeout-ms='.length);
      continue;
    }

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--deploy-template-package':
        parsed.deployTemplatePackage = nextValue();
        break;
      case '--archive':
        parsed.archive = nextValue();
        break;
      case '--image-map':
        parsed.imageMap = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
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
        parsed.kubectlProvided = true;
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
      case '--forbidden-source-root':
        parsed.forbiddenSourceRoots.push(nextValue());
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

function parseTargetProfile(value) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail('target_profile is required');
  }
  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!SUPPORTED_TARGET_PROFILE_SET.has(normalized)) {
    fail(`--airgap-deployment-gate only accepts ${SUPPORTED_TARGET_PROFILES.join(' or ')}`);
  }
  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateOperatorRunId(operatorRunId) {
  if (typeof operatorRunId !== 'string' || !OPERATOR_RUN_ID_RE.test(operatorRunId)) {
    fail('operator_run_id must be a non-empty run identifier without whitespace');
  }
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
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

function parseInteger(value, label, min, max) {
  const text = requireString(value, label);
  if (!/^(?:0|[1-9][0-9]*)$/.test(text)) {
    fail(`${label} must be an integer`);
  }
  const parsed = Number(text);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    fail(`${label} must be between ${min} and ${max}`);
  }
  return parsed;
}

function validateTimeout(timeout) {
  if (typeof timeout !== 'string' || !TIMEOUT_RE.test(timeout)) {
    fail('timeout must be 0 or a Kubernetes duration like 120s, 2m, or 1h');
  }
}

function isIpv4MappedLoopback(hostname) {
  if (!hostname.startsWith('::ffff:')) {
    return false;
  }

  const mapped = hostname.slice('::ffff:'.length);
  if (/^127(?:\.\d{1,3}){3}$/.test(mapped)) {
    return true;
  }

  const [firstHextet] = mapped.split(':');
  if (!/^[0-9a-f]{1,4}$/.test(firstHextet)) {
    return false;
  }

  return (Number.parseInt(firstHextet, 16) & 0xff00) === 0x7f00;
}

function isLocalhost(hostname) {
  const normalized = hostname
    .toLowerCase()
    .replace(/^\[(.*)\]$/, '$1')
    .replace(/\.+$/, '');
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::' ||
    normalized === '::1' ||
    isIpv4MappedLoopback(normalized) ||
    /^127(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

function decodedPath(pathname) {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return pathname;
  }
}

function assertSafeSmokeRoutePath(pathname) {
  const values = [pathname, decodedPath(pathname)];
  for (const value of values) {
    if (FORBIDDEN_ROUTE_TEXT_RE.test(value)) {
      fail('smoke_url path contains report-forbidden text');
    }
    if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
      fail('smoke_url path contains a secret-looking payload');
    }
  }
}

function validateSmokeUrl(value, args) {
  const input = requireString(value, 'smoke_url');
  if (input !== input.trim() || /[\s\r\n]/.test(input)) {
    fail('smoke_url must not contain whitespace');
  }

  let parsed;
  try {
    parsed = new URL(input);
  } catch {
    fail('smoke_url must be an absolute URL');
  }

  if (parsed.username || parsed.password) {
    fail('smoke_url must not include userinfo');
  }
  if (parsed.search || parsed.hash || input.includes('?') || input.includes('#')) {
    fail('smoke_url must not include query or hash');
  }
  if (parsed.protocol !== 'https:' && !(args.allowHttp && parsed.protocol === 'http:')) {
    fail('smoke_url must use https unless --allow-http is explicit');
  }
  if (!args.allowLocalhost && isLocalhost(parsed.hostname)) {
    fail('smoke_url must not target localhost unless --allow-localhost is explicit');
  }
  assertSafeSmokeRoutePath(parsed.pathname || '/');
}

function validateSmokeHandoffArgs(args) {
  if (!args.smokeUrl) {
    return;
  }

  validateSmokeUrl(args.smokeUrl, args);
  if (args.expectedStatus !== undefined) {
    parseInteger(args.expectedStatus, 'expected_status', 100, 599);
  }
  if (args.timeoutMs !== undefined) {
    parseInteger(args.timeoutMs, 'timeout_ms', 1, 300000);
  }
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);

  if (!SUPPORTED_MODES.has(args.mode)) {
    cliFail('--mode must be server-dry-run or apply');
  }

  if (args.timeout !== undefined) {
    validateTimeout(args.timeout);
  }

  const hasSmokeOption =
    args.smokeUrl ||
    args.expectedStatus !== undefined ||
    args.timeoutMs !== undefined ||
    args.allowHttp ||
    args.allowLocalhost;
  if (args.mode === 'server-dry-run' && hasSmokeOption) {
    cliFail('smoke options require --mode apply');
  }
  if (!args.smokeUrl && hasSmokeOption) {
    cliFail('smoke options require --smoke-url');
  }
  validateSmokeHandoffArgs(args);

  if (args.mode === 'apply') {
    if (!args.archiveProbe) {
      cliFail('--mode apply requires --archive-probe <executable>');
    }
    if (!args.imageLoader) {
      cliFail('--mode apply requires --image-loader <executable>');
    }
    if (args.confirmApply !== args.targetProfile.value) {
      cliFail(`--mode apply requires --confirm-apply ${args.targetProfile.value}`);
    }
    if (!args.operatorRunId) {
      cliFail('--mode apply requires --operator-run-id <id>');
    }
    validateOperatorRunId(args.operatorRunId);
    return args;
  }

  if (args.archiveProbe) {
    cliFail('--archive-probe is only accepted with --mode apply');
  }
  if (args.imageLoader) {
    cliFail('--image-loader is only accepted with --mode apply');
  }
  if (args.confirmApply) {
    cliFail('--confirm-apply is only accepted with --mode apply');
  }
  if (args.operatorRunId) {
    cliFail('--operator-run-id is only accepted with --mode apply');
  }
  if (args.timeout) {
    cliFail('--timeout is only accepted with --mode apply');
  }

  return args;
}

async function removeManagedOutputs(outputDir) {
  await Promise.all(
    MANAGED_OUTPUT_ENTRIES.map((entry) =>
      fs.rm(path.join(outputDir, entry), { recursive: true, force: true })
    )
  );
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function rejectUriOrWindowsPath(value, label) {
  const text = requireString(value, label);
  if (text.trim() !== text) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (text.startsWith('//') || WINDOWS_DRIVE_RE.test(text) || text.includes('\\')) {
    fail(`${label} must be a local POSIX path`);
  }
  if (URI_SCHEME_RE.test(text)) {
    fail(`${label} must be a local POSIX path, not a URI`);
  }
  return text;
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

async function canonicalBundleRoot(input) {
  rejectUriOrWindowsPath(input, 'bundle_root');
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

async function bundleLocalFile(input, label, bundleRoot) {
  rejectUriOrWindowsPath(input, label);
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

async function discoverSubstratePackManifest(args) {
  if (args.targetProfile.value !== KIT_AIRGAP_TARGET_PROFILE) {
    return undefined;
  }

  const bundleRoot = await canonicalBundleRoot(args.bundleRoot);
  const bundleManifestPath = await bundleLocalFile(
    args.bundleManifest,
    'bundle manifest',
    bundleRoot
  );
  const bundleManifestInput = await readJsonFile(bundleManifestPath, 'bundle manifest');
  const manifest = requireObject(bundleManifestInput.value, 'bundle_manifest');
  const manifestTargetProfile = requireObject(
    manifest.target_profile,
    'bundle_manifest.target_profile'
  );
  if (requireString(manifestTargetProfile.value, 'bundle_manifest.target_profile.value') !== args.targetProfile.value) {
    fail('bundle_manifest.target_profile.value must match --target-profile');
  }
  const components = requireArray(manifest.components, 'bundle_manifest.components');
  const substratePackComponents = components
    .map((value, index) => ({ value: requireObject(value, `bundle_manifest.components[${index}]`), index }))
    .filter(({ value }) => value.kind === 'substrate_pack_manifest');

  if (substratePackComponents.length !== 1) {
    fail('kit airgap bundle manifest must include exactly one substrate_pack_manifest component');
  }

  const { value, index } = substratePackComponents[0];
  const relativePath = validateBundleRelativePath(
    value.path,
    `bundle_manifest.components[${index}].path`
  );
  return bundleLocalFile(
    path.join(bundleRoot, relativePath),
    `bundle_manifest.components[${index}].path`,
    bundleRoot
  );
}

async function canonicalForbiddenSourceRoots(inputRoots) {
  const roots = [];

  for (const input of inputRoots) {
    const requested = path.resolve(input);
    let stat;
    try {
      stat = await fs.stat(requested);
    } catch {
      cliFail(`forbidden source root must exist: ${input}`);
    }

    if (!stat.isDirectory()) {
      cliFail(`forbidden source root must be a directory: ${input}`);
    }

    try {
      roots.push(await fs.realpath(requested));
    } catch (error) {
      cliFail(`cannot resolve forbidden source root: ${error.message}`);
    }
  }

  return roots;
}

function assertNotForbiddenSourcePath(candidate, label, forbiddenSourceRoots) {
  const resolved = path.resolve(candidate);
  for (const root of forbiddenSourceRoots) {
    if (isInsidePath(root, resolved)) {
      fail(`${label} must not point to a configured forbidden product source tree`);
    }
  }
}

async function assertPathOutsideForbiddenRoots(input, label, forbiddenSourceRoots) {
  const requested = path.resolve(input);
  assertNotForbiddenSourcePath(requested, `${label} path`, forbiddenSourceRoots);

  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch {
    return;
  }

  if (stat.isSymbolicLink()) {
    let target;
    try {
      target = await fs.readlink(requested);
    } catch (error) {
      fail(`cannot read ${label} symlink: ${error.message}`);
    }
    const targetPath = path.resolve(path.dirname(requested), target);
    assertNotForbiddenSourcePath(targetPath, `${label} symlink target`, forbiddenSourceRoots);
  }

  try {
    const realPath = await fs.realpath(requested);
    assertNotForbiddenSourcePath(realPath, `${label} real path`, forbiddenSourceRoots);
  } catch {
    // Missing paths are validated by the focused step that owns that input.
  }
}

function inputPathEntries(args) {
  const entries = [
    ['release_contract', args.releaseContract],
    ['deploy_template_package', args.deployTemplatePackage],
    ['archive', args.archive],
    ['image_map', args.imageMap],
    ['bundle_root', args.bundleRoot],
    ['bundle_manifest', args.bundleManifest],
    ['render_values', args.renderValues],
    ['substrate_truth', args.substrateTruth],
    ['target_prerequisites', args.targetPrerequisites]
  ];

  if (args.mode === 'apply') {
    entries.push(['archive_probe', args.archiveProbe]);
    entries.push(['image_loader', args.imageLoader]);
  }
  if (args.kubeconfig) {
    entries.push(['kubeconfig', args.kubeconfig]);
  }
  if (args.kubectlProvided && (path.isAbsolute(args.kubectl) || args.kubectl.includes('/'))) {
    entries.push(['kubectl', args.kubectl]);
  }

  return entries.filter(([, value]) => value !== undefined);
}

async function assertInputPathsOutsideForbiddenRoots(args) {
  if (args.forbiddenSourceRoots.length === 0) {
    return;
  }

  const forbiddenSourceRoots = await canonicalForbiddenSourceRoots(args.forbiddenSourceRoots);
  for (const [label, value] of inputPathEntries(args)) {
    await assertPathOutsideForbiddenRoots(value, label, forbiddenSourceRoots);
  }
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function readJsonFile(file, label) {
  let raw;
  try {
    raw = await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      value: JSON.parse(raw),
      raw,
      input_sha256: digestBuffer(Buffer.from(raw))
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function readReleaseContract(file) {
  const input = await readJsonFile(file, 'release contract');
  const contract = input.value;
  if (!contract || typeof contract !== 'object' || Array.isArray(contract)) {
    fail('release contract must be an object');
  }
  return {
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    input_sha256: input.input_sha256
  };
}

function outputSubdir(args, name) {
  return path.join(args.outputDir, name);
}

function relativeOutputPath(outputDir, file) {
  return path.relative(outputDir, file).split(path.sep).join('/');
}

function renderedManifestsDir(args) {
  return path.join(
    outputSubdir(args, 'airgap-bundle-render-check'),
    'render',
    'rendered-manifests'
  );
}

function rolloutReportPath(args) {
  return path.join(outputSubdir(args, 'rollout'), 'rollout-report.json');
}

function pushIfValue(argv, flag, value) {
  if (value !== undefined) {
    argv.push(flag, value);
  }
}

function appendForbiddenRoots(argv, args) {
  for (const root of args.forbiddenSourceRoots) {
    argv.push('--forbidden-source-root', root);
  }
}

function kubeArgs(args) {
  const argv = [];
  pushIfValue(argv, '--kubeconfig', args.kubeconfig);
  pushIfValue(argv, '--context', args.context);
  pushIfValue(argv, '--kubectl', args.kubectl);
  return argv;
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

function runStep({ args, steps, name, mode, argv, reportPaths }) {
  runVerify(name, mode, argv);
  for (const reportPath of reportPaths) {
    let stat;
    try {
      stat = statSync(reportPath);
    } catch {
      throw new StepError(name, 1, `airgap focused chain step report missing: ${name}`);
    }
    if (!stat.isFile()) {
      throw new StepError(name, 1, `airgap focused chain step report is not a file: ${name}`);
    }
  }
  steps.push({
    name,
    status: 'pass',
    report_paths: reportPaths.map((reportPath) => relativeOutputPath(args.outputDir, reportPath))
  });
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-deployment-gate.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

function buildReport({ releaseIdentity, args, steps }) {
  const report = {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    mode: args.mode,
    release_id: releaseIdentity.release_id,
    git_sha: releaseIdentity.git_sha,
    release_contract: {
      input_sha256: releaseIdentity.input_sha256
    },
    target_profile: args.targetProfile,
    steps,
    generated_at: new Date().toISOString()
  };
  if (args.mode === 'apply') {
    report.operator_run_id = args.operatorRunId;
  }
  return report;
}

async function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    await removeManagedOutputsFromRawArgs(argv);
    throw error;
  }
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeManagedOutputs(args.outputDir);
  validateArgs(args);
  await assertInputPathsOutsideForbiddenRoots(args);

  const steps = [];
  const targetProfile = args.targetProfile.value;
  const substratePackManifest = await discoverSubstratePackManifest(args);

  runStep({
    args,
    steps,
    name: 'target-preflight',
    mode: '--target-preflight',
    argv: [
      '--target-profile',
      targetProfile,
      '--substrate-truth',
      args.substrateTruth,
      '--target-prerequisites',
      args.targetPrerequisites,
      '--expected-namespace',
      args.namespace,
      '--output-dir',
      outputSubdir(args, 'target-preflight')
    ],
    reportPaths: [
      path.join(outputSubdir(args, 'target-preflight'), 'target-preflight-report.json')
    ]
  });

  if (substratePackManifest) {
    runStep({
      args,
      steps,
      name: 'substrate-pack-check',
      mode: '--substrate-pack-check',
      argv: [
        '--target-profile',
        targetProfile,
        '--substrate-pack-manifest',
        substratePackManifest,
        '--substrate-truth',
        args.substrateTruth,
        '--output-dir',
        outputSubdir(args, 'substrate-pack-check')
      ],
      reportPaths: [
        path.join(outputSubdir(args, 'substrate-pack-check'), 'substrate-pack-check-report.json')
      ]
    });
  }

  if (args.mode === 'apply') {
    runStep({
      args,
      steps,
      name: 'airgap-image-load',
      mode: '--airgap-image-load',
      argv: [
        '--release-contract',
        args.releaseContract,
        '--deploy-template-package',
        args.deployTemplatePackage,
        '--archive',
        args.archive,
        '--image-map',
        args.imageMap,
        '--target-profile',
        targetProfile,
        '--bundle-root',
        args.bundleRoot,
        '--bundle-manifest',
        args.bundleManifest,
        '--archive-probe',
        args.archiveProbe,
        '--image-loader',
        args.imageLoader,
        '--output-dir',
        outputSubdir(args, 'airgap-image-load')
      ],
      reportPaths: [
        path.join(outputSubdir(args, 'airgap-image-load'), 'airgap-image-load-report.json')
      ]
    });
  }

  runStep({
    args,
    steps,
    name: 'airgap-bundle-render-check',
    mode: '--airgap-bundle-render-check',
    argv: [
      '--release-contract',
      args.releaseContract,
      '--deploy-template-package',
      args.deployTemplatePackage,
      '--archive',
      args.archive,
      '--image-map',
      args.imageMap,
      '--target-profile',
      targetProfile,
      '--bundle-root',
      args.bundleRoot,
      '--bundle-manifest',
      args.bundleManifest,
      '--render-values',
      args.renderValues,
      '--substrate-truth',
      args.substrateTruth,
      '--output-dir',
      outputSubdir(args, 'airgap-bundle-render-check')
    ],
    reportPaths: [
      path.join(
        outputSubdir(args, 'airgap-bundle-render-check'),
        'airgap-bundle-render-check-report.json'
      )
    ]
  });

  const applyArgv = [
    '--release-contract',
    args.releaseContract,
    '--rendered-manifests',
    renderedManifestsDir(args),
    '--target-profile',
    targetProfile,
    '--namespace',
    args.namespace,
    '--output-dir',
    outputSubdir(args, 'apply'),
    '--mode',
    args.mode,
    ...kubeArgs(args)
  ];
  if (args.mode === 'apply') {
    applyArgv.push(
      '--confirm-apply',
      targetProfile,
      '--operator-run-id',
      args.operatorRunId
    );
  }
  appendForbiddenRoots(applyArgv, args);
  runStep({
    args,
    steps,
    name: 'apply',
    mode: '--apply',
    argv: applyArgv,
    reportPaths: [path.join(outputSubdir(args, 'apply'), 'apply-report.json')]
  });

  if (args.mode === 'apply') {
    const rolloutArgv = [
      '--release-contract',
      args.releaseContract,
      '--rendered-manifests',
      renderedManifestsDir(args),
      '--target-profile',
      targetProfile,
      '--namespace',
      args.namespace,
      '--output-dir',
      outputSubdir(args, 'rollout'),
      ...kubeArgs(args)
    ];
    pushIfValue(rolloutArgv, '--timeout', args.timeout);
    appendForbiddenRoots(rolloutArgv, args);
    runStep({
      args,
      steps,
      name: 'rollout',
      mode: '--rollout',
      argv: rolloutArgv,
      reportPaths: [rolloutReportPath(args)]
    });

    if (args.smokeUrl) {
      const smokeArgv = [
        '--release-contract',
        args.releaseContract,
        '--rollout-report',
        rolloutReportPath(args),
        '--target-profile',
        targetProfile,
        '--url',
        args.smokeUrl,
        '--output-dir',
        outputSubdir(args, 'smoke')
      ];
      pushIfValue(smokeArgv, '--expected-status', args.expectedStatus);
      pushIfValue(smokeArgv, '--timeout-ms', args.timeoutMs);
      if (args.allowHttp) {
        smokeArgv.push('--allow-http');
      }
      if (args.allowLocalhost) {
        smokeArgv.push('--allow-localhost');
      }
      runStep({
        args,
        steps,
        name: 'smoke',
        mode: '--smoke',
        argv: smokeArgv,
        reportPaths: [path.join(outputSubdir(args, 'smoke'), 'smoke-report.json')]
      });
    }
  }

  const releaseContract = await readReleaseContract(args.releaseContract);
  await writeReport(
    args.outputDir,
    buildReport({
      releaseIdentity: releaseContract,
      args,
      steps
    })
  );

  console.log('PASS: airgap focused chain completed focused diagnostics');
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
