#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_FORBIDDEN_SOURCE_ROOTS = [path.resolve(ROOT_DIR, '..', 'agentsmith')];
const REQUIRED_ARGS = [
  'releaseContract',
  'renderedManifests',
  'targetProfile',
  'namespace',
  'outputDir'
];
const REPORT_SCHEMA = 'agentsmith.kubernetes-apply-report/v1';
const APPLY_SCOPE = 'kubernetes_apply_only';
const SUPPORTED_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;

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

function usage() {
  return `Usage:
  node scripts/verify-apply.mjs \\
    --release-contract <json> \\
    --rendered-manifests <dir> \\
    --target-profile existing_kubernetes/external_declared/online \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--mode server-dry-run|apply] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
    [--forbidden-source-root <dir>]

  Real apply requires:
    --mode apply \\
    --confirm-apply existing_kubernetes/external_declared/online \\
    --operator-run-id <id>`;
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

function nextValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {
    mode: 'server-dry-run',
    kubectl: 'kubectl'
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const readValue = () => {
      const value = nextValue(argv, index, arg);
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

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = readValue();
        break;
      case '--rendered-manifests':
        parsed.renderedManifests = readValue();
        break;
      case '--target-profile':
        parsed.targetProfile = readValue();
        break;
      case '--namespace':
        parsed.namespace = readValue();
        break;
      case '--output-dir':
        parsed.outputDir = readValue();
        break;
      case '--mode':
        parsed.mode = readValue();
        break;
      case '--confirm-apply':
        parsed.confirmApply = readValue();
        break;
      case '--operator-run-id':
        parsed.operatorRunId = readValue();
        break;
      case '--kubeconfig':
        parsed.kubeconfig = readValue();
        break;
      case '--context':
        parsed.context = readValue();
        break;
      case '--kubectl':
        parsed.kubectl = readValue();
        break;
      case '--forbidden-source-root':
        if (!parsed.forbiddenSourceRoots) {
          parsed.forbiddenSourceRoots = [];
        }
        parsed.forbiddenSourceRoots.push(readValue());
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

  validateArgs(parsed);
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
  if (normalized !== SUPPORTED_TARGET_PROFILE) {
    fail(`--apply only accepts ${SUPPORTED_TARGET_PROFILE}`);
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateNamespace(namespace) {
  if (
    typeof namespace !== 'string' ||
    namespace.length > 63 ||
    !NAMESPACE_RE.test(namespace)
  ) {
    fail('namespace must be a Kubernetes DNS label');
  }
}

function validateOperatorRunId(operatorRunId) {
  if (typeof operatorRunId !== 'string' || !OPERATOR_RUN_ID_RE.test(operatorRunId)) {
    fail('operator_run_id must be a non-empty run identifier without whitespace');
  }
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);
  validateNamespace(args.namespace);

  if (!SUPPORTED_MODES.has(args.mode)) {
    cliFail('--mode must be server-dry-run or apply');
  }

  if (args.mode === 'apply') {
    if (args.confirmApply !== SUPPORTED_TARGET_PROFILE) {
      cliFail(`--mode apply requires --confirm-apply ${SUPPORTED_TARGET_PROFILE}`);
    }
    if (!args.operatorRunId) {
      cliFail('--mode apply requires --operator-run-id <id>');
    }
    validateOperatorRunId(args.operatorRunId);
    return;
  }

  if (args.confirmApply) {
    cliFail('--confirm-apply is only accepted with --mode apply');
  }
  if (args.operatorRunId) {
    cliFail('--operator-run-id is only accepted with --mode apply');
  }
}

function digestText(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function summarizeOutput(output) {
  const text = output.trim();
  if (!text) {
    return '';
  }
  return `: ${text.split(/\r?\n/).slice(-6).join(' | ')}`;
}

function runCommand(command, commandArgs, label, options = {}) {
  const result = spawnSync(command, commandArgs, {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  });

  if (result.error) {
    fail(`${label} failed to start: ${result.error.message}`);
  }

  if (result.status !== 0) {
    const exitStatus = result.status === null ? `signal ${result.signal}` : `exit code ${result.status}`;
    const output = options.includeOutput
      ? summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`)
      : '';
    fail(`${label} failed with ${exitStatus}${output}`);
  }

  return {
    stdout: result.stdout || '',
    stderr: result.stderr || ''
  };
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
      raw
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function removeStaleReport(outputDir) {
  await fs.rm(path.join(outputDir, 'apply-report.json'), { force: true });
}

async function existingDefaultForbiddenSourceRoots() {
  const roots = [];

  for (const root of DEFAULT_FORBIDDEN_SOURCE_ROOTS) {
    let stat;
    try {
      stat = await fs.stat(root);
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') {
        continue;
      }
      cliFail(`cannot inspect default forbidden source root: ${error.message}`);
    }

    if (stat.isDirectory()) {
      roots.push(root);
    }
  }

  return roots;
}

async function renderCheckForbiddenRootArgs(args) {
  const roots = [
    ...(await existingDefaultForbiddenSourceRoots()),
    ...(args.forbiddenSourceRoots || [])
  ];
  return roots.flatMap((root) => ['--forbidden-source-root', root]);
}

async function runRenderCheckGuard(args) {
  const tempOutputDir = await fs.mkdtemp(
    path.join(os.tmpdir(), 'agentsmith-apply-render-check-')
  );
  const forbiddenRootArgs = await renderCheckForbiddenRootArgs(args);

  try {
    runCommand(
      process.execPath,
      [
        path.join(ROOT_DIR, 'scripts/verify-render-check.mjs'),
        '--release-contract',
        args.releaseContract,
        '--rendered-manifests',
        args.renderedManifests,
        '--target-profile',
        args.targetProfile.value,
        '--output-dir',
        tempOutputDir,
        ...forbiddenRootArgs
      ],
      'render-check guard',
      { includeOutput: true }
    );

    return await readJson(path.join(tempOutputDir, 'render-report.json'), 'render-check report');
  } finally {
    await fs.rm(tempOutputDir, { recursive: true, force: true });
  }
}

function kubectlPrefixArgs(args) {
  const prefix = [];
  if (args.kubeconfig) {
    prefix.push('--kubeconfig', args.kubeconfig);
  }
  if (args.context) {
    prefix.push('--context', args.context);
  }
  return prefix;
}

function versionFields(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }

  const fields = {};
  for (const key of ['gitVersion', 'major', 'minor', 'platform']) {
    if (typeof value[key] === 'string' && value[key].trim() !== '') {
      fields[key] = value[key];
    }
  }
  return Object.keys(fields).length > 0 ? fields : undefined;
}

function normalizeKubectlVersion(stdout) {
  const trimmed = stdout.trim();
  if (trimmed === '') {
    return {
      output: 'empty',
      output_sha256: digestText(trimmed)
    };
  }

  try {
    const parsed = JSON.parse(trimmed);
    const normalized = {
      output_sha256: digestText(trimmed)
    };
    const client = versionFields(parsed.clientVersion);
    const server = versionFields(parsed.serverVersion);
    if (client) {
      normalized.client = client;
    }
    if (server) {
      normalized.server = server;
    }
    return normalized;
  } catch {
    return {
      parse_status: 'unparsed',
      output_sha256: digestText(trimmed)
    };
  }
}

function runKubectlVersion(args) {
  const result = runCommand(
    args.kubectl,
    [...kubectlPrefixArgs(args), 'version', '--output=json'],
    'kubectl version'
  );
  return normalizeKubectlVersion(result.stdout);
}

function runKubectlApply(args) {
  const applyArgs = [
    ...kubectlPrefixArgs(args),
    'apply',
    '--server-side',
    '--namespace',
    args.namespace,
    '-f',
    args.renderedManifests
  ];

  if (args.mode === 'server-dry-run') {
    applyArgs.push('--dry-run=server');
  }

  applyArgs.push('-o', 'name');
  return runCommand(args.kubectl, applyArgs, 'kubectl apply');
}

function manifestResourceRefs(renderReport, namespace) {
  const manifests = Array.isArray(renderReport.manifests) ? renderReport.manifests : [];
  return manifests.map((manifest) => {
    const ref = {
      kind: manifest.kind,
      name: manifest.name,
      namespace,
      path: manifest.path,
      document_index: manifest.document_index
    };

    return Object.fromEntries(
      Object.entries(ref).filter(([, value]) => value !== undefined && value !== null)
    );
  });
}

function kubectlResourceRefs(stdout) {
  return stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== '');
}

function requireRenderCheckPass(renderReport) {
  if (renderReport.readiness !== false) {
    fail('render-check guard report must keep readiness=false');
  }
  if (renderReport.status !== 'pass') {
    fail('render-check guard report must pass before apply');
  }
  if (renderReport.scope !== 'render_check_image_inventory_only') {
    fail('render-check guard report has unexpected scope');
  }
}

function buildReport({ args, renderReport, kubectlVersion, kubectlApplyOutput }) {
  const report = {
    schema_version: REPORT_SCHEMA,
    scope: APPLY_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: renderReport.release_id,
    git_sha: renderReport.git_sha,
    release_contract: {
      input_sha256: renderReport.release_contract?.input_sha256,
      deploy_image_inventory_count: renderReport.release_contract?.deploy_image_inventory_count
    },
    target_profile: args.targetProfile,
    namespace: args.namespace,
    mode: args.mode,
    resource_refs: manifestResourceRefs(renderReport, args.namespace),
    kubectl_resource_refs: kubectlResourceRefs(kubectlApplyOutput.stdout),
    kubectl_version: kubectlVersion,
    render_check: {
      schema: renderReport.schema,
      scope: renderReport.scope,
      status: renderReport.status,
      images_count: Array.isArray(renderReport.images) ? renderReport.images.length : 0,
      workload_count: Array.isArray(renderReport.manifests) ? renderReport.manifests.length : 0
    },
    generated_at: new Date().toISOString()
  };

  if (args.mode === 'apply') {
    report.operator_run_id = args.operatorRunId;
  }

  return report;
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'apply-report.json');
  const tempFile = path.join(outputDir, `.apply-report.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(args.outputDir);

  const renderCheckReport = await runRenderCheckGuard(args);
  requireRenderCheckPass(renderCheckReport.value);

  const kubectlVersion = runKubectlVersion(args);
  const kubectlApplyOutput = runKubectlApply(args);

  await writeReport(
    args.outputDir,
    buildReport({
      args,
      renderReport: renderCheckReport.value,
      kubectlVersion,
      kubectlApplyOutput
    })
  );

  if (args.mode === 'server-dry-run') {
    console.log('PASS: Kubernetes server-side dry-run accepted rendered manifests');
    return;
  }
  console.log('PASS: Kubernetes apply accepted rendered manifests');
}

main().catch((error) => {
  const exitCode = error.exitCode || 1;
  const prefix = exitCode === 2 ? 'error' : 'FAIL';
  console.error(`${prefix}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
