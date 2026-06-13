#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { redactSecretLikeOutput } from './lib/output-redaction.mjs';

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
const APPLY_SCOPE = 'kubernetes_apply_with_pre_apply_controls';
const MANIFEST_EXTENSIONS = new Set(['.json', '.yaml', '.yml']);
const SECRET_REF_CSI_FIELDS = new Set([
  'nodePublishSecretRef',
  'nodeStageSecretRef',
  'controllerPublishSecretRef',
  'controllerExpandSecretRef'
]);
const POD_TEMPLATE_KINDS = new Set([
  'Deployment',
  'StatefulSet',
  'DaemonSet',
  'ReplicaSet',
  'ReplicationController',
  'Job'
]);
const SUPPORTED_TARGET_PROFILES = new Set([
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
]);
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const AGENTSMITH_JOB_OWNERSHIP_LABELS = {
  'app.kubernetes.io/name': 'agentsmith',
  'app.kubernetes.io/part-of': 'agentsmith-deploy'
};
const AGENTSMITH_JOB_OWNERSHIP_ANNOTATIONS = {
  'rendered-by': 'agentsmith-unified-deploy'
};
const AFSCP_STATIC_PVC_NAME = 'afscp-default-volume';
const AFSCP_STATIC_PV_NAME_SUFFIX = 'afscp-default-volume';
const AFSCP_JUICEFS_CSI_DRIVER = 'csi.juicefs.com';
const AFSCP_JUICEFS_FSTYPE = 'juicefs';
const AFSCP_RECONCILE_DELETE_TIMEOUT = '120s';
const AFSCP_WORKLOAD_LIST_RESOURCE =
  'deployment,statefulset,daemonset,job,cronjob,replicaset,pod';
const AFSCP_CSI_CACHE_LIST_RESOURCE = 'pod,secret';
const AFSCP_JUICEFS_MOUNT_POD_SELECTOR = 'app.kubernetes.io/name=juicefs-mount';
const AFSCP_JUICEFS_GENERATED_SECRET_SELECTOR = 'juicefs/secret=true';
const AFSCP_JUICEFS_DEFAULT_MOUNT_NAMESPACE = 'kube-system';
const AFSCP_JUICEFS_CSI_NODE_DAEMONSET = 'juicefs-csi-node';
const AFSCP_JUICEFS_CSI_NODE_CONTAINER = 'juicefs-plugin';
const AFSCP_OBJECT_STORAGE_CA_DIR = '/etc/agentsmith/substrate-ca/object-storage';
const AFSCP_TLS_DISABLED_VALUES = new Set([
  'disable',
  'disabled',
  'none',
  'false',
  'off',
  'http',
  'plain',
  'plaintext',
  '0',
  'no'
]);
const AFSCP_OWNER_CONTROLLER_KINDS = new Set([
  'Deployment',
  'StatefulSet',
  'DaemonSet',
  'Job',
  'CronJob'
]);
const AFSCP_WORKLOAD_DELETE_RESOURCE_BY_KIND = new Map([
  ['Deployment', 'deployment'],
  ['StatefulSet', 'statefulset'],
  ['DaemonSet', 'daemonset'],
  ['Job', 'job'],
  ['CronJob', 'cronjob'],
  ['Pod', 'pod']
]);
const AFSCP_WORKLOAD_DELETE_ORDER = new Map([
  ['Deployment', 10],
  ['StatefulSet', 20],
  ['DaemonSet', 30],
  ['Job', 40],
  ['CronJob', 50],
  ['Pod', 60]
]);
const AFSCP_CSI_CACHE_SCOPE_KEYS = new Set([
  'juicefs-name',
  'juicefs-uniqueid',
  'uniqueid',
  'volume-id',
  'juicefs/name',
  'juicefs/uniqueid',
  'juicefs/volume-id',
  'juicefs/volume-name',
  'juicefs/pv',
  'juicefs/pv-name',
  'juicefs/pvc',
  'juicefs/pvc-name',
  'juicefs/secret-name',
  'juicefs.com/name',
  'juicefs.com/uniqueid',
  'juicefs.com/volume-id',
  'juicefs.com/volume-name',
  'juicefs.com/pv',
  'juicefs.com/pv-name',
  'juicefs.com/pvc',
  'juicefs.com/pvc-name',
  'juicefs.com/secret-name',
  'juicefs.io/name',
  'juicefs.io/uniqueid',
  'juicefs.io/volume-id',
  'juicefs.io/volume-name',
  'juicefs.io/pv',
  'juicefs.io/pv-name',
  'juicefs.io/pvc',
  'juicefs.io/pvc-name',
  'juicefs.io/secret-name'
]);
const AFSCP_CSI_CACHE_UPSTREAM_ID_KEYS = new Set([
  'juicefs-name',
  'juicefs-uniqueid',
  'uniqueid',
  'volume-id',
  'juicefs/name',
  'juicefs/uniqueid',
  'juicefs/volume-id',
  'juicefs/volume-name',
  'juicefs.com/name',
  'juicefs.com/uniqueid',
  'juicefs.com/volume-id',
  'juicefs.com/volume-name',
  'juicefs.io/name',
  'juicefs.io/uniqueid',
  'juicefs.io/volume-id',
  'juicefs.io/volume-name'
]);
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
    --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--mode server-dry-run|apply] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
    [--forbidden-source-root <dir>]

  Real apply requires:
    --mode apply \\
    --confirm-apply <matching-target-profile> \\
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
  if (!SUPPORTED_TARGET_PROFILES.has(normalized)) {
    fail(`--apply only accepts ${[...SUPPORTED_TARGET_PROFILES].join(', ')}`);
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
    if (args.confirmApply !== args.targetProfile.value) {
      cliFail(`--mode apply requires --confirm-apply ${args.targetProfile.value}`);
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
  const text = redactSecretLikeOutput(output).trim();
  if (!text) {
    return '';
  }
  return `: ${text.split(/\r?\n/).slice(-6).join(' | ')}`;
}

function commandExitStatus(result) {
  return result.status === null ? `signal ${result.signal}` : `exit code ${result.status}`;
}

function executeCommand(command, commandArgs, label) {
  const result = spawnSync(command, commandArgs, {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  });

  if (result.error) {
    fail(`${label} failed to start: ${result.error.message}`);
  }

  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout || '',
    stderr: result.stderr || ''
  };
}

function runCommand(command, commandArgs, label, options = {}) {
  const result = executeCommand(command, commandArgs, label);

  if (result.status !== 0) {
    const output = options.includeOutput
      ? summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`)
      : '';
    fail(`${label} failed with ${commandExitStatus(result)}${output}`);
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

function assertInsideRoot(rootDir, file, label) {
  const relative = path.relative(rootDir, file);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must stay inside rendered manifests root`);
  }
}

function isManifestFile(file) {
  return MANIFEST_EXTENSIONS.has(path.extname(file).toLowerCase());
}

async function renderedManifestsRoot(input) {
  let root;
  try {
    root = await fs.realpath(input);
  } catch (error) {
    fail(`cannot read rendered manifests root: ${error.message}`);
  }

  let stat;
  try {
    stat = await fs.stat(root);
  } catch (error) {
    fail(`cannot stat rendered manifests root: ${error.message}`);
  }
  if (!stat.isDirectory()) {
    fail('rendered manifests root must be a directory');
  }
  return root;
}

async function collectApplyManifestFiles(root, dir = root, files = []) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch (error) {
    fail(`cannot read rendered manifests directory: ${error.message}`);
  }
  entries.sort((left, right) => left.name.localeCompare(right.name));

  for (const entry of entries) {
    const file = path.join(dir, entry.name);
    let stat;
    try {
      stat = await fs.lstat(file);
    } catch (error) {
      fail(`cannot stat rendered manifest path: ${error.message}`);
    }

    if (stat.isSymbolicLink()) {
      fail(`rendered manifest path must not be a symlink: ${path.relative(root, file)}`);
    }

    if (stat.isDirectory()) {
      const realDir = await fs.realpath(file);
      assertInsideRoot(root, realDir, `rendered manifest directory ${path.relative(root, file)}`);
      await collectApplyManifestFiles(root, file, files);
      continue;
    }

    if (!stat.isFile() || !isManifestFile(file)) {
      continue;
    }

    const realFile = await fs.realpath(file);
    assertInsideRoot(root, realFile, `rendered manifest ${path.relative(root, file)}`);
    files.push(file);
  }

  return files;
}

async function applyManifestFiles(args) {
  const root = await renderedManifestsRoot(args.renderedManifests);
  const files = await collectApplyManifestFiles(root);
  if (files.length === 0) {
    fail('rendered manifests root must contain yaml, yml, or json manifests');
  }
  return files;
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

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function kubectlFailedWithNotFound(result) {
  if (result.status === 0) {
    return false;
  }
  return /\bnotfound\b|not found/i.test(`${result.stderr || ''}\n${result.stdout || ''}`);
}

function failKubectlResult(label, result) {
  const output = summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`);
  fail(`${label} failed with ${commandExitStatus(result)}${output}`);
}

function parseKubectlJson(stdout, label) {
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (error) {
    fail(`${label} returned invalid JSON: ${error.message}`);
  }
  if (!isPlainObject(parsed)) {
    fail(`${label} returned non-object JSON`);
  }
  return parsed;
}

function jsonValueEnd(text, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = start; index < text.length; index += 1) {
    const char = text[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === '\\') {
        escaped = true;
      } else if (char === '"') {
        inString = false;
      }
      continue;
    }

    if (char === '"') {
      inString = true;
      continue;
    }
    if (char === '{' || char === '[') {
      depth += 1;
      continue;
    }
    if (char === '}' || char === ']') {
      depth -= 1;
      if (depth === 0) {
        return index + 1;
      }
      if (depth < 0) {
        return undefined;
      }
    }
  }

  return undefined;
}

function parseKubectlJsonTexts(stdout, label) {
  const values = [];
  let index = 0;

  while (index < stdout.length) {
    while (index < stdout.length && /\s/.test(stdout[index])) {
      index += 1;
    }
    if (index >= stdout.length) {
      break;
    }

    const first = stdout[index];
    if (first !== '{' && first !== '[') {
      fail(`${label} returned invalid JSON: unexpected character at offset ${index}`);
    }

    const end = jsonValueEnd(stdout, index);
    if (end === undefined) {
      try {
        JSON.parse(stdout.slice(index));
      } catch (error) {
        fail(`${label} returned invalid JSON: ${error.message}`);
      }
      fail(`${label} returned invalid JSON: incomplete JSON value`);
    }

    const raw = stdout.slice(index, end);
    try {
      values.push(JSON.parse(raw));
    } catch (error) {
      fail(`${label} returned invalid JSON: ${error.message}`);
    }
    index = end;
  }

  if (values.length === 0) {
    fail(`${label} returned invalid JSON: empty output`);
  }
  return values;
}

function stripYamlComment(line) {
  let quote;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (quote) {
      if (char === quote && line[index - 1] !== '\\') {
        quote = undefined;
      }
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === '#' && (index === 0 || /\s/.test(line[index - 1]))) {
      return line.slice(0, index);
    }
  }
  return line;
}

function stripYamlQuotes(value) {
  const trimmed = String(value ?? '').trim();
  if (trimmed.length >= 2) {
    const first = trimmed[0];
    const last = trimmed[trimmed.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return trimmed.slice(1, -1);
    }
  }
  return trimmed;
}

function parseYamlScalar(value) {
  const trimmed = stripYamlQuotes(value);
  if (/^(?:true|false)$/i.test(trimmed)) {
    return trimmed.toLowerCase() === 'true';
  }
  if (/^(?:null|~)$/i.test(trimmed)) {
    return null;
  }
  return trimmed;
}

function yamlLines(raw) {
  return raw
    .split(/\r?\n/)
    .map((line) => {
      const withoutComment = stripYamlComment(line).replace(/\s+$/, '');
      return {
        indent: withoutComment.match(/^ */)[0].length,
        content: withoutComment.trim()
      };
    })
    .filter((line) => line.content !== '');
}

function splitYamlDocuments(raw) {
  return raw
    .split(/^---[ \t]*(?:#.*)?$/m)
    .map((document) => document.trim())
    .filter((document) => document !== '');
}

function yamlKeyValue(content) {
  const match = content.match(/^([^:]+):(.*)$/);
  if (!match) {
    return undefined;
  }
  const key = stripYamlQuotes(match[1]);
  if (!key) {
    return undefined;
  }
  const rawValue = match[2].trim();
  return {
    key,
    hasValue: rawValue !== '',
    value: rawValue !== '' ? parseYamlScalar(rawValue) : undefined
  };
}

function parseYamlBlock(lines, state, indent) {
  const current = lines[state.index];
  if (!current || current.indent < indent) {
    return undefined;
  }
  if (current.content.startsWith('- ')) {
    return parseYamlArray(lines, state, current.indent);
  }
  return parseYamlObject(lines, state, current.indent);
}

function parseYamlObject(lines, state, indent) {
  const value = {};

  while (state.index < lines.length) {
    const line = lines[state.index];
    if (line.indent < indent || line.content.startsWith('- ')) {
      break;
    }
    if (line.indent > indent) {
      state.index += 1;
      continue;
    }

    const entry = yamlKeyValue(line.content);
    if (!entry) {
      state.index += 1;
      continue;
    }

    state.index += 1;
    if (entry.hasValue) {
      value[entry.key] = entry.value;
      continue;
    }

    const next = lines[state.index];
    value[entry.key] = next && next.indent > indent
      ? parseYamlBlock(lines, state, next.indent)
      : {};
  }

  return value;
}

function parseYamlArray(lines, state, indent) {
  const value = [];

  while (state.index < lines.length) {
    const line = lines[state.index];
    if (line.indent !== indent || !line.content.startsWith('- ')) {
      break;
    }

    const itemText = line.content.slice(2).trim();
    state.index += 1;

    if (itemText === '') {
      const next = lines[state.index];
      value.push(next && next.indent > indent ? parseYamlBlock(lines, state, next.indent) : null);
      continue;
    }

    const entry = yamlKeyValue(itemText);
    if (!entry) {
      value.push(parseYamlScalar(itemText));
      continue;
    }

    const item = {};
    if (entry.hasValue) {
      item[entry.key] = entry.value;
    } else {
      const next = lines[state.index];
      item[entry.key] =
        next && next.indent > indent ? parseYamlBlock(lines, state, next.indent) : {};
    }

    const next = lines[state.index];
    if (next && next.indent > indent) {
      const nested = parseYamlObject(lines, state, next.indent);
      Object.assign(item, nested);
    }
    value.push(item);
  }

  return value;
}

function parseYamlDocument(raw) {
  const lines = yamlLines(raw);
  if (lines.length === 0) {
    return undefined;
  }
  return parseYamlBlock(lines, { index: 0 }, lines[0].indent);
}

function flattenManifestResources(value) {
  if (Array.isArray(value)) {
    return value.flatMap((item) => flattenManifestResources(item));
  }
  if (!isPlainObject(value)) {
    return [];
  }
  if (value.kind === 'List' && Array.isArray(value.items)) {
    return value.items.flatMap((item) => flattenManifestResources(item));
  }
  return [value];
}

function parseRenderedManifestResources(raw, relativePath) {
  const trimmed = raw.trim();
  if (trimmed === '') {
    return [];
  }

  if (path.extname(relativePath).toLowerCase() === '.json' || /^[\[{]/.test(trimmed)) {
    let parsed;
    try {
      parsed = JSON.parse(trimmed);
    } catch (error) {
      fail(`invalid JSON manifest ${relativePath}: ${error.message}`);
    }
    return flattenManifestResources(parsed);
  }

  return splitYamlDocuments(raw).flatMap((document) => {
    return flattenManifestResources(parseYamlDocument(document));
  });
}

function renderedManifestDecodeCacheKey(manifestFiles) {
  return manifestFiles.join('\0');
}

function decodeRenderedManifestResources(args, manifestFiles) {
  const commandArgs = [
    ...kubectlPrefixArgs(args),
    'create',
    '--dry-run=client',
    '--validate=false',
    '--namespace',
    args.namespace
  ];

  for (const manifestFile of manifestFiles) {
    commandArgs.push('-f', manifestFile);
  }
  commandArgs.push('-o', 'json');

  const result = runCommand(
    args.kubectl,
    commandArgs,
    'kubectl client dry-run decode rendered manifests',
    { includeOutput: true }
  );
  const parsedValues = parseKubectlJsonTexts(
    result.stdout,
    'kubectl client dry-run decode rendered manifests'
  );
  return parsedValues
    .flatMap((parsed) => flattenManifestResources(parsed))
    .filter((resource) => isPlainObject(resource));
}

async function collectRenderedManifestResources(args, manifestFiles) {
  const cacheKey = renderedManifestDecodeCacheKey(manifestFiles);
  if (
    args._renderedManifestResources &&
    args._renderedManifestResources.cacheKey === cacheKey
  ) {
    return args._renderedManifestResources.resources;
  }

  const resources = decodeRenderedManifestResources(args, manifestFiles);
  args._renderedManifestResources = {
    cacheKey,
    resources
  };
  return resources;
}

function stringValue(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined;
}

function optionalTrue(value) {
  return value === true || value === 'true';
}

function resourceLabel(resource) {
  const kind = stringValue(resource.kind) || 'Unknown';
  const metadata = isPlainObject(resource.metadata) ? resource.metadata : {};
  const name = stringValue(metadata.name) || 'unknown';
  return `${kind}/${name}`;
}

function podSpecForResource(resource) {
  if (!isPlainObject(resource)) {
    return undefined;
  }
  if (resource.kind === 'Pod') {
    return resource.spec;
  }
  if (POD_TEMPLATE_KINDS.has(resource.kind)) {
    return resource.spec?.template?.spec;
  }
  if (resource.kind === 'CronJob') {
    return resource.spec?.jobTemplate?.spec?.template?.spec;
  }
  return undefined;
}

function addSecretRequirement(requirements, { name, key, resource, source }) {
  const secretName = stringValue(name);
  const label = stringValue(resource);
  const refSource = stringValue(source);
  if (!secretName || !label || !refSource) {
    return;
  }

  if (key !== undefined) {
    const secretKey = stringValue(key);
    if (!secretKey) {
      return;
    }
    requirements.push({
      name: secretName,
      key: secretKey,
      resource: label,
      source: refSource
    });
    return;
  }

  requirements.push({
    name: secretName,
    resource: label,
    source: refSource
  });
}

function addSecretItemRequirements(requirements, { name, items, resource, source }) {
  if (!Array.isArray(items)) {
    return;
  }

  for (const item of items) {
    if (!isPlainObject(item) || optionalTrue(item.optional)) {
      continue;
    }
    addSecretRequirement(requirements, {
      name,
      key: item.key,
      resource,
      source
    });
  }
}

function collectContainerSecretRefs(container, resource, requirements) {
  if (!isPlainObject(container)) {
    return;
  }

  if (Array.isArray(container.env)) {
    for (const env of container.env) {
      const ref = env?.valueFrom?.secretKeyRef;
      if (!isPlainObject(ref) || optionalTrue(ref.optional)) {
        continue;
      }
      addSecretRequirement(requirements, {
        name: ref.name,
        key: ref.key,
        resource,
        source: 'env'
      });
    }
  }

  if (Array.isArray(container.envFrom)) {
    for (const envFrom of container.envFrom) {
      const ref = envFrom?.secretRef;
      if (!isPlainObject(ref) || optionalTrue(ref.optional)) {
        continue;
      }
      addSecretRequirement(requirements, {
        name: ref.name,
        resource,
        source: 'envFrom'
      });
    }
  }
}

function collectPodSpecSecretRefs(podSpec, resource, requirements) {
  if (!isPlainObject(podSpec)) {
    return;
  }

  for (const field of ['initContainers', 'containers', 'ephemeralContainers']) {
    const containers = podSpec[field];
    if (!Array.isArray(containers)) {
      continue;
    }
    for (const container of containers) {
      collectContainerSecretRefs(container, resource, requirements);
    }
  }

  if (Array.isArray(podSpec.imagePullSecrets)) {
    for (const ref of podSpec.imagePullSecrets) {
      addSecretRequirement(requirements, {
        name: ref?.name,
        resource,
        source: 'imagePullSecrets'
      });
    }
  }

  if (!Array.isArray(podSpec.volumes)) {
    return;
  }

  for (const volume of podSpec.volumes) {
    const secretVolume = volume?.secret;
    if (isPlainObject(secretVolume) && !optionalTrue(secretVolume.optional)) {
      addSecretRequirement(requirements, {
        name: secretVolume.secretName,
        resource,
        source: 'volume'
      });
      addSecretItemRequirements(requirements, {
        name: secretVolume.secretName,
        items: secretVolume.items,
        resource,
        source: 'volume item'
      });
    }

    const projectedSources = volume?.projected?.sources;
    if (Array.isArray(projectedSources)) {
      for (const source of projectedSources) {
        const projectedSecret = source?.secret;
        if (!isPlainObject(projectedSecret) || optionalTrue(projectedSecret.optional)) {
          continue;
        }
        addSecretRequirement(requirements, {
          name: projectedSecret.name,
          resource,
          source: 'projected volume'
        });
        addSecretItemRequirements(requirements, {
          name: projectedSecret.name,
          items: projectedSecret.items,
          resource,
          source: 'projected volume item'
        });
      }
    }
  }
}

function collectCsiSecretRefs(value, resource, requirements) {
  if (Array.isArray(value)) {
    for (const item of value) {
      collectCsiSecretRefs(item, resource, requirements);
    }
    return;
  }
  if (!isPlainObject(value)) {
    return;
  }

  for (const [key, nested] of Object.entries(value)) {
    if (SECRET_REF_CSI_FIELDS.has(key) && isPlainObject(nested)) {
      addSecretRequirement(requirements, {
        name: nested.name,
        resource,
        source: `CSI ${key}`
      });
    }
    collectCsiSecretRefs(nested, resource, requirements);
  }
}

function collectResourceSecretRefs(resource) {
  const requirements = [];
  const label = resourceLabel(resource);
  collectPodSpecSecretRefs(podSpecForResource(resource), label, requirements);
  collectCsiSecretRefs(resource, label, requirements);
  return requirements;
}

async function collectRenderedSecretRequirements(args, manifestFiles) {
  const requirements = [];

  for (const resource of await collectRenderedManifestResources(args, manifestFiles)) {
    requirements.push(...collectResourceSecretRefs(resource));
  }

  return requirements;
}

function deduplicateSecretRequirements(requirements, namespace) {
  const bySecret = new Map();

  for (const requirement of requirements) {
    const secretKey = `${namespace}/${requirement.name}`;
    if (!bySecret.has(secretKey)) {
      bySecret.set(secretKey, {
        namespace,
        name: requirement.name,
        firstRequirement: requirement,
        keys: new Map()
      });
    }

    const entry = bySecret.get(secretKey);
    if (requirement.key && !entry.keys.has(requirement.key)) {
      entry.keys.set(requirement.key, requirement);
    }
  }

  return [...bySecret.values()];
}

function formatSecretRequirement(requirement) {
  return `${requirement.resource} ${requirement.source}`;
}

function getRenderedRequiredSecret(args, secretRequirement) {
  const label = `kubectl get secret ${secretRequirement.name}`;
  const result = executeCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'get',
      'secret',
      secretRequirement.name,
      '--namespace',
      secretRequirement.namespace,
      '-o',
      'json'
    ],
    label
  );

  if (result.status === 0) {
    return parseKubectlJson(result.stdout, label);
  }
  if (kubectlFailedWithNotFound(result)) {
    return undefined;
  }
  failKubectlResult(label, result);
}

async function runRenderedSecretRefPreflight(args, manifestFiles) {
  if (args.mode !== 'apply') {
    return {
      status: 'skipped',
      reason: 'server_dry_run_no_live_secret_check'
    };
  }

  const requirements = deduplicateSecretRequirements(
    await collectRenderedSecretRequirements(args, manifestFiles),
    args.namespace
  );

  for (const secretRequirement of requirements) {
    const secret = getRenderedRequiredSecret(args, secretRequirement);
    if (!secret) {
      fail(
        `rendered required Secret ref missing: Secret/${secretRequirement.name} required by ${formatSecretRequirement(
          secretRequirement.firstRequirement
        )}`
      );
    }

    const data = isPlainObject(secret.data) ? secret.data : {};
    for (const [key, requirement] of secretRequirement.keys.entries()) {
      if (!Object.hasOwn(data, key)) {
        fail(
          `rendered required Secret key missing: Secret/${secretRequirement.name} key ${key} required by ${formatSecretRequirement(
            requirement
          )}`
      );
    }
  }

  return {
    status: 'pass',
    reason: 'required_rendered_secret_refs_readable',
    required_secret_count: requirements.length,
    required_secret_key_count: requirements.reduce((count, requirement) => {
      return count + requirement.keys.size;
    }, 0)
  };
}
}

function afscpStaticPvName(namespace) {
  return `${namespace}-${AFSCP_STATIC_PV_NAME_SUFFIX}`;
}

function metadataFor(resource) {
  return isPlainObject(resource?.metadata) ? resource.metadata : {};
}

function labelsFor(resource) {
  const labels = metadataFor(resource).labels;
  return isPlainObject(labels) ? labels : {};
}

function annotationsFor(resource) {
  const annotations = metadataFor(resource).annotations;
  return isPlainObject(annotations) ? annotations : {};
}

function hasDeletionTimestamp(resource) {
  const metadata = metadataFor(resource);
  return metadata.deletionTimestamp !== undefined && metadata.deletionTimestamp !== null;
}

function resourceName(resource) {
  return stringValue(metadataFor(resource).name);
}

function resourceNamespace(resource, fallbackNamespace) {
  return stringValue(metadataFor(resource).namespace) || fallbackNamespace;
}

function refLabel(ref) {
  if (!ref.namespace) {
    return `${ref.kind} ${ref.name}`;
  }
  return `${ref.kind} ${ref.namespace}/${ref.name}`;
}

function staticStorageClassName(value) {
  if (value === undefined || value === null) {
    return true;
  }
  if (typeof value !== 'string') {
    return false;
  }
  const normalized = value.trim();
  return (
    normalized === '' ||
    normalized === 'static' ||
    normalized.startsWith('static-') ||
    normalized.endsWith('-static')
  );
}

function storageClassNameFor(resource) {
  const spec = isPlainObject(resource?.spec) ? resource.spec : {};
  if (!Object.hasOwn(spec, 'storageClassName')) {
    return undefined;
  }
  return spec.storageClassName;
}

function normalizeNodePublishSecretRef(resource, fallbackNamespace) {
  const ref = resource?.spec?.csi?.nodePublishSecretRef;
  if (!isPlainObject(ref)) {
    return undefined;
  }
  const name = stringValue(ref.name);
  if (!name) {
    return undefined;
  }
  return {
    name,
    namespace: stringValue(ref.namespace) || fallbackNamespace
  };
}

function explicitNodePublishSecretRef(resource) {
  const ref = resource?.spec?.csi?.nodePublishSecretRef;
  if (!isPlainObject(ref)) {
    return undefined;
  }
  const name = stringValue(ref.name);
  const namespace = stringValue(ref.namespace);
  if (!name) {
    return undefined;
  }
  return {
    name,
    namespace
  };
}

function secretRefsEqual(left, right) {
  return (
    left !== undefined &&
    right !== undefined &&
    left.name === right.name &&
    left.namespace === right.namespace
  );
}

function hasRenderedAfscpStaticPvIdentity(resource, pvName) {
  return (
    resource?.apiVersion === 'v1' &&
    resource.kind === 'PersistentVolume' &&
    resourceName(resource) === pvName
  );
}

function hasRenderedAfscpStaticPvcIdentity(resource, namespace) {
  return (
    resource?.apiVersion === 'v1' &&
    resource.kind === 'PersistentVolumeClaim' &&
    resourceName(resource) === AFSCP_STATIC_PVC_NAME &&
    resourceNamespace(resource, namespace) === namespace
  );
}

function hasExplicitStaticStorageClassName(resource) {
  const spec = isPlainObject(resource?.spec) ? resource.spec : {};
  return Object.hasOwn(spec, 'storageClassName') && staticStorageClassName(spec.storageClassName);
}

function renderedAfscpStaticPvSafetyProblems(resource, pvName, namespace) {
  const problems = [];
  const spec = isPlainObject(resource?.spec) ? resource.spec : {};
  const csi = isPlainObject(spec.csi) ? spec.csi : {};
  const claimRef = isPlainObject(spec.claimRef) ? spec.claimRef : {};
  const secretRef = explicitNodePublishSecretRef(resource);

  if (!hasRenderedAfscpStaticPvIdentity(resource, pvName)) {
    problems.push('identity does not match target PV');
  }
  if (hasDeletionTimestamp(resource)) {
    problems.push('metadata.deletionTimestamp is set');
  }
  if (spec.persistentVolumeReclaimPolicy !== 'Retain') {
    problems.push('reclaimPolicy is not Retain');
  }
  if (claimRef.namespace !== namespace || claimRef.name !== AFSCP_STATIC_PVC_NAME) {
    problems.push('claimRef does not match target PVC');
  }
  if (csi.driver !== AFSCP_JUICEFS_CSI_DRIVER) {
    problems.push(`CSI driver is not ${AFSCP_JUICEFS_CSI_DRIVER}`);
  }
  if (csi.fsType !== AFSCP_JUICEFS_FSTYPE) {
    problems.push(`CSI fsType is not ${AFSCP_JUICEFS_FSTYPE}`);
  }
  if (csi.volumeHandle !== pvName) {
    problems.push('CSI volumeHandle does not match target PV');
  }
  if (!secretRef) {
    problems.push('CSI nodePublishSecretRef is missing');
  } else if (secretRef.namespace !== namespace) {
    problems.push('CSI nodePublishSecretRef is not namespace-local to target namespace');
  }
  if (!hasExplicitStaticStorageClassName(resource)) {
    problems.push('storageClassName is not explicitly static/empty');
  }

  return problems;
}

function renderedAfscpStaticPvcSafetyProblems(resource, pvName, namespace) {
  const problems = [];
  const spec = isPlainObject(resource?.spec) ? resource.spec : {};

  if (!hasRenderedAfscpStaticPvcIdentity(resource, namespace)) {
    problems.push('identity does not match target PVC');
  }
  if (hasDeletionTimestamp(resource)) {
    problems.push('metadata.deletionTimestamp is set');
  }
  if (spec.volumeName !== pvName) {
    problems.push('spec.volumeName does not match target PV');
  }
  if (!hasExplicitStaticStorageClassName(resource)) {
    problems.push('storageClassName is not explicitly static/empty');
  }

  return problems;
}

function renderedAfscpWorkloadAllowlist(resources, namespace, pvcName) {
  const allowlist = new Map();

  for (const resource of resources) {
    const kind = stringValue(resource?.kind);
    if (!kind || !workloadDeleteResource(kind)) {
      continue;
    }
    if (!workloadUsesPvc(resource, pvcName)) {
      continue;
    }

    const name = resourceName(resource);
    const resourceNs = resourceNamespace(resource, namespace);
    if (!name || !resourceNs) {
      fail('rendered AFSCP workload allowlist candidate is missing metadata.name or metadata.namespace');
    }
    allowlist.set(workloadRefKey(kind, resourceNs, name), {
      kind,
      namespace: resourceNs,
      name
    });
  }

  return allowlist;
}

async function renderedAfscpStaticJuicefsVolume(args, manifestFiles) {
  const pvName = afscpStaticPvName(args.namespace);
  const resources = await collectRenderedManifestResources(args, manifestFiles);
  const pvs = resources.filter((resource) => {
    return hasRenderedAfscpStaticPvIdentity(resource, pvName);
  });
  const pvcs = resources.filter((resource) => {
    return hasRenderedAfscpStaticPvcIdentity(resource, args.namespace);
  });

  if (pvs.length > 1 || pvcs.length > 1) {
    fail('rendered manifests contain duplicate AFSCP static JuiceFS PV/PVC resources');
  }
  if (pvs.length === 0 && pvcs.length === 0) {
    return undefined;
  }
  if (pvs.length !== 1 || pvcs.length !== 1) {
    fail('rendered manifests contain incomplete AFSCP static JuiceFS PV/PVC resources');
  }

  const pvProblems = renderedAfscpStaticPvSafetyProblems(pvs[0], pvName, args.namespace);
  if (pvProblems.length > 0) {
    fail(
      `rendered AFSCP static JuiceFS PV ${pvName} is not safe for live delete reconcile: ${pvProblems.join(
        '; '
      )}`
    );
  }

  const pvcProblems = renderedAfscpStaticPvcSafetyProblems(pvcs[0], pvName, args.namespace);
  if (pvcProblems.length > 0) {
    fail(
      `rendered AFSCP static JuiceFS PVC ${args.namespace}/${AFSCP_STATIC_PVC_NAME} is not safe for live delete reconcile: ${pvcProblems.join(
        '; '
      )}`
    );
  }

  return {
    pv: pvs[0],
    pvc: pvcs[0],
    pvName,
    pvcName: AFSCP_STATIC_PVC_NAME,
    namespace: args.namespace,
    renderedNodePublishSecretRef: normalizeNodePublishSecretRef(pvs[0], args.namespace),
    renderedWorkloadAllowlist: renderedAfscpWorkloadAllowlist(
      resources,
      args.namespace,
      AFSCP_STATIC_PVC_NAME
    )
  };
}

function getExistingKubernetesResource(args, ref) {
  const commandArgs = [
    ...kubectlPrefixArgs(args),
    'get',
    ref.resource,
    ref.name,
    '-o',
    'json'
  ];
  if (ref.namespace) {
    commandArgs.splice(commandArgs.length - 2, 0, '--namespace', ref.namespace);
  }

  const result = executeCommand(args.kubectl, commandArgs, `kubectl get ${ref.resource} ${ref.name}`);

  if (result.status === 0) {
    return parseKubectlJson(result.stdout, `kubectl get ${ref.resource} ${ref.name}`);
  }
  if (kubectlFailedWithNotFound(result)) {
    return undefined;
  }
  failKubectlResult(`kubectl get ${ref.resource} ${ref.name}`, result);
}

function listKubernetesResources(args, { resource, namespace, allNamespaces, labelSelector, label }) {
  const commandArgs = [
    ...kubectlPrefixArgs(args),
    'get',
    resource
  ];
  if (namespace) {
    commandArgs.push('--namespace', namespace);
  }
  if (allNamespaces) {
    commandArgs.push('--all-namespaces');
  }
  if (labelSelector) {
    commandArgs.push('-l', labelSelector);
  }
  commandArgs.push('-o', 'json');

  const result = executeCommand(args.kubectl, commandArgs, label);

  if (result.status !== 0) {
    failKubectlResult(label, result);
  }

  const parsed = parseKubectlJson(result.stdout, label);
  if (Array.isArray(parsed.items)) {
    return parsed.items.filter((item) => isPlainObject(item));
  }
  return [parsed];
}

function secretDataValue(secret, key) {
  const stringData = isPlainObject(secret.stringData) ? secret.stringData : {};
  if (typeof stringData[key] === 'string') {
    return stringData[key];
  }

  const data = isPlainObject(secret.data) ? secret.data : {};
  const raw = data[key];
  if (typeof raw !== 'string') {
    return undefined;
  }

  const compact = raw.replace(/\s/g, '');
  if (
    compact !== '' &&
    compact.length % 4 === 0 &&
    /^[A-Za-z0-9+/]*={0,2}$/.test(compact)
  ) {
    const decoded = Buffer.from(compact, 'base64');
    const encoded = decoded.toString('base64').replace(/=+$/, '');
    if (encoded === compact.replace(/=+$/, '')) {
      return decoded.toString('utf8');
    }
  }

  return raw;
}

function parseInlineMap(text) {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return undefined;
  }

  const body = trimmed.slice(1, -1).trim();
  if (body === '') {
    return {};
  }

  const value = {};
  for (const entry of body.split(',')) {
    const separatorIndex = entry.indexOf(':');
    if (separatorIndex <= 0) {
      return undefined;
    }
    const key = stripYamlQuotes(entry.slice(0, separatorIndex).trim());
    const itemValue = stripYamlQuotes(entry.slice(separatorIndex + 1).trim());
    if (!key) {
      return undefined;
    }
    value[key] = itemValue;
  }
  return value;
}

function parseSecretStructuredField(raw, label) {
  const text = stringValue(raw);
  if (!text) {
    fail(`AFSCP JuiceFS volume Secret ${label} is required`);
  }

  try {
    return JSON.parse(text);
  } catch {
    const inlineMap = parseInlineMap(text);
    if (inlineMap) {
      return inlineMap;
    }

    const parsedYaml = parseYamlDocument(text);
    if (parsedYaml !== undefined) {
      return parsedYaml;
    }
  }

  fail(`AFSCP JuiceFS volume Secret ${label} must be a JSON or YAML object`);
}

function normalizedPosixPath(value) {
  const text = stringValue(value);
  if (!text) {
    return undefined;
  }
  return path.posix.normalize(text);
}

function configMountEntries(configs) {
  const entries = [];
  const addEntry = (fallbackName, value) => {
    if (typeof value === 'string') {
      entries.push({
        secretName: stringValue(fallbackName),
        mountDir: normalizedPosixPath(value)
      });
      return;
    }
    if (!isPlainObject(value)) {
      return;
    }
    entries.push({
      secretName: stringValue(
        value.secretName ||
          value.secret_name ||
          value.secret ||
          value.name ||
          fallbackName
      ),
      mountDir: normalizedPosixPath(
        value.mountPath ||
          value.mount_path ||
          value.mountDir ||
          value.mount_dir ||
          value.directory ||
          value.dir ||
          value.path
      )
    });
  };

  if (Array.isArray(configs)) {
    for (const item of configs) {
      addEntry(undefined, item);
    }
    return entries;
  }

  if (isPlainObject(configs)) {
    for (const [key, value] of Object.entries(configs)) {
      addEntry(key, value);
    }
  }

  return entries.filter((entry) => entry.secretName && entry.mountDir);
}

function envMapEntries(envs) {
  if (!isPlainObject(envs)) {
    return {};
  }
  return Object.fromEntries(
    Object.entries(envs).filter(([, value]) => typeof value === 'string')
  );
}

function decodeQueryComponent(value) {
  try {
    return decodeURIComponent(value.replace(/\+/g, '%20'));
  } catch {
    return value;
  }
}

function sslrootcertFromMetaurl(metaurl) {
  const text = stringValue(metaurl);
  if (!text) {
    return undefined;
  }

  try {
    const parsed = new URL(text);
    const value = parsed.searchParams.get('sslrootcert');
    if (value) {
      return value;
    }
  } catch {
    // Fall back to a bounded query-string scan below.
  }

  const match = /(?:^|[?&;])sslrootcert=([^&;\s]+)/i.exec(text);
  return match ? decodeQueryComponent(match[1]) : undefined;
}

function tlsModeRequiresCa(value) {
  const text = stringValue(value);
  return Boolean(text && !AFSCP_TLS_DISABLED_VALUES.has(text.toLowerCase()));
}

function valueLooksTrue(value) {
  if (value === true) {
    return true;
  }
  if (typeof value !== 'string') {
    return false;
  }
  return value.trim().toLowerCase() === 'true';
}

function renderedObjectStorageTlsHintForValue(value) {
  if (Array.isArray(value)) {
    return value.some((item) => renderedObjectStorageTlsHintForValue(item));
  }
  if (!isPlainObject(value)) {
    return false;
  }

  for (const [key, nested] of Object.entries(value)) {
    if (
      ['SUBSTRATE_OBJECT_STORAGE_USE_SSL', 'SUBSTRATE_MINIO_USE_SSL'].includes(key) &&
      valueLooksTrue(nested)
    ) {
      return true;
    }
    if (
      ['SUBSTRATE_OBJECT_STORAGE_TLS_MODE', 'SUBSTRATE_MINIO_TLS_MODE'].includes(key) &&
      tlsModeRequiresCa(nested)
    ) {
      return true;
    }
    if (
      ['SUBSTRATE_OBJECT_STORAGE_CA_SECRET_NAME', 'SUBSTRATE_MINIO_CA_SECRET_NAME'].includes(key) &&
      stringValue(nested)
    ) {
      return true;
    }
    if (renderedObjectStorageTlsHintForValue(nested)) {
      return true;
    }
  }

  return false;
}

async function renderedObjectStorageTlsHint(args, manifestFiles) {
  const resources = await collectRenderedManifestResources(args, manifestFiles);
  return resources.some((resource) => renderedObjectStorageTlsHintForValue(resource));
}

function findConfigMountForDir(configs, dir) {
  const expected = normalizedPosixPath(dir);
  return configMountEntries(configs).find((entry) => {
    return entry.mountDir === expected;
  });
}

function secretHasCaCrt(secret) {
  const data = isPlainObject(secret.data) ? secret.data : {};
  const stringData = isPlainObject(secret.stringData) ? secret.stringData : {};
  return Object.hasOwn(data, 'ca.crt') || Object.hasOwn(stringData, 'ca.crt');
}

function requireMountNamespaceCaSecret(args, mountNamespace, secretName, label, problems) {
  const secret = getExistingKubernetesResource(args, {
    resource: 'secret',
    namespace: mountNamespace,
    name: secretName
  });

  if (!secret) {
    problems.push(`${label} Secret ${mountNamespace}/${secretName} is missing`);
    return;
  }
  if (!secretHasCaCrt(secret)) {
    problems.push(`${label} Secret ${mountNamespace}/${secretName} is missing ca.crt`);
  }
}

function requireConfigMappedCaSecret(args, {
  configs,
  dir,
  mountNamespace,
  label,
  problems
}) {
  const entry = findConfigMountForDir(configs, dir);
  if (!entry) {
    problems.push(`${label} requires configs mapping a CA Secret to ${dir}`);
    return undefined;
  }

  requireMountNamespaceCaSecret(args, mountNamespace, entry.secretName, label, problems);
  return entry.secretName;
}

function containerEnv(workload, containerName, envName) {
  const podSpec = podSpecForResource(workload);
  const containers = Array.isArray(podSpec?.containers) ? podSpec.containers : [];
  const container = containers.find((item) => {
    return isPlainObject(item) && item.name === containerName;
  });
  if (!container || !Array.isArray(container.env)) {
    return undefined;
  }
  return container.env.find((env) => {
    return isPlainObject(env) && env.name === envName;
  });
}

function mountNamespaceFromCsiWorkload(workload) {
  if (!workload) {
    return undefined;
  }

  const env = containerEnv(
    workload,
    AFSCP_JUICEFS_CSI_NODE_CONTAINER,
    'JUICEFS_MOUNT_NAMESPACE'
  );
  const value = stringValue(env?.value);
  if (value) {
    return value;
  }

  if (env?.valueFrom?.fieldRef?.fieldPath === 'metadata.namespace') {
    return resourceNamespace(workload, AFSCP_JUICEFS_DEFAULT_MOUNT_NAMESPACE);
  }

  return undefined;
}

function requireKubernetesNamespace(value, label) {
  const namespace = stringValue(value);
  if (!namespace || namespace.length > 63 || !NAMESPACE_RE.test(namespace)) {
    fail(`${label} must be a Kubernetes DNS label`);
  }
  return namespace;
}

function requireMountNamespace(value) {
  return requireKubernetesNamespace(
    stringValue(value) || AFSCP_JUICEFS_DEFAULT_MOUNT_NAMESPACE,
    'AFSCP JuiceFS CSI mount namespace'
  );
}

function getJuicefsCsiNodeDaemonSet(args, namespace = AFSCP_JUICEFS_DEFAULT_MOUNT_NAMESPACE) {
  return getExistingKubernetesResource(args, {
    resource: 'daemonset',
    namespace,
    name: AFSCP_JUICEFS_CSI_NODE_DAEMONSET
  });
}

function listJuicefsCsiNodeDaemonSets(args) {
  return listKubernetesResources(args, {
    resource: 'daemonset',
    allNamespaces: true,
    label: 'kubectl get JuiceFS CSI node DaemonSets'
  }).filter((resource) => resourceName(resource) === AFSCP_JUICEFS_CSI_NODE_DAEMONSET);
}

function discoverJuicefsCsiNodeWorkload(args) {
  const defaultNamespaceNode = getJuicefsCsiNodeDaemonSet(args);
  if (defaultNamespaceNode) {
    return defaultNamespaceNode;
  }

  const nodes = listJuicefsCsiNodeDaemonSets(args);
  if (nodes.length === 0) {
    fail(
      `AFSCP JuiceFS CSI node workload ${AFSCP_JUICEFS_CSI_NODE_DAEMONSET} was not found in the cluster`
    );
  }
  if (nodes.length > 1) {
    const locations = nodes
      .map((node) => resourceNamespace(node))
      .filter((namespace) => namespace)
      .sort()
      .join(', ');
    fail(
      `AFSCP JuiceFS CSI node workload ${AFSCP_JUICEFS_CSI_NODE_DAEMONSET} matched multiple namespaces: ${locations}`
    );
  }
  return nodes[0];
}

function resolveJuicefsCsiNamespaces(args) {
  const csiNode = discoverJuicefsCsiNodeWorkload(args);
  const nodeNamespace = requireKubernetesNamespace(
    resourceNamespace(csiNode, AFSCP_JUICEFS_DEFAULT_MOUNT_NAMESPACE),
    'AFSCP JuiceFS CSI node workload namespace'
  );
  const mountNamespace = requireMountNamespace(mountNamespaceFromCsiWorkload(csiNode));

  return {
    nodeNamespace,
    mountNamespace
  };
}

function requireCsiNodeReadableFile(args, nodeNamespace, filePath) {
  const label = `kubectl exec ds/${AFSCP_JUICEFS_CSI_NODE_DAEMONSET} test -r ${filePath}`;
  const result = executeCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'exec',
      `ds/${AFSCP_JUICEFS_CSI_NODE_DAEMONSET}`,
      '--namespace',
      nodeNamespace,
      '-c',
      AFSCP_JUICEFS_CSI_NODE_CONTAINER,
      '--',
      'test',
      '-r',
      filePath
    ],
    label
  );

  if (result.status !== 0) {
    const output = summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`);
    fail(
      `AFSCP JuiceFS CSI node plugin cannot read Postgres sslrootcert ${filePath}: ${commandExitStatus(
        result
      )}${output}`
    );
  }
}

function sslCertDirIncludes(value, requiredDir) {
  const text = stringValue(value);
  if (!text) {
    return false;
  }
  const expected = normalizedPosixPath(requiredDir);
  return text.split(':').some((entry) => normalizedPosixPath(entry) === expected);
}

function bucketRequiresObjectStorageTls(bucket) {
  return stringValue(bucket)?.toLowerCase().startsWith('https://') === true;
}

async function runAfscpJuicefsCsiTlsReadinessPreflight(args, manifestFiles) {
  const intent = await renderedAfscpStaticJuicefsVolume(args, manifestFiles);
  if (!intent) {
    return {
      afscp_juicefs_csi_tls_readiness: {
        status: 'skipped',
        reason: 'rendered_afscp_static_juicefs_pv_not_found'
      }
    };
  }

  const summaryBase = {
    pv: {
      name: intent.pvName
    },
    pvc: {
      namespace: intent.namespace,
      name: intent.pvcName
    },
    volume_secret_ref: {
      namespace: intent.renderedNodePublishSecretRef.namespace,
      name: intent.renderedNodePublishSecretRef.name
    }
  };

  if (args.mode !== 'apply') {
    return {
      afscp_juicefs_csi_tls_readiness: {
        status: 'skipped',
        reason: 'server_dry_run_no_live_readiness_check',
        ...summaryBase
      }
    };
  }

  const volumeSecret = getExistingKubernetesResource(args, {
    resource: 'secret',
    namespace: intent.renderedNodePublishSecretRef.namespace,
    name: intent.renderedNodePublishSecretRef.name
  });
  if (!volumeSecret) {
    return {
      afscp_juicefs_csi_tls_readiness: {
        status: 'skipped',
        reason: 'target_volume_secret_not_readable',
        ...summaryBase
      }
    };
  }

  const metaurl = secretDataValue(volumeSecret, 'metaurl');
  const bucket = secretDataValue(volumeSecret, 'bucket');
  const sslrootcert = sslrootcertFromMetaurl(metaurl);
  const objectStorageTls =
    bucketRequiresObjectStorageTls(bucket) ||
    (await renderedObjectStorageTlsHint(args, manifestFiles));

  if (!sslrootcert && !objectStorageTls) {
    return {
      afscp_juicefs_csi_tls_readiness: {
        status: 'pass',
        reason: 'no_tls_projection_required',
        ...summaryBase
      }
    };
  }

  const { nodeNamespace, mountNamespace } = resolveJuicefsCsiNamespaces(args);
  const configs = parseSecretStructuredField(secretDataValue(volumeSecret, 'configs'), 'configs');
  const problems = [];
  const checks = [];

  if (sslrootcert && path.posix.basename(sslrootcert) === 'ca.crt') {
    const postgresCaDir = path.posix.dirname(sslrootcert);
    requireConfigMappedCaSecret(args, {
      configs,
      dir: postgresCaDir,
      mountNamespace,
      label: 'Postgres sslrootcert',
      problems
    });
    checks.push('postgresql_sslrootcert_ca_secret');

    if (problems.length === 0) {
      requireCsiNodeReadableFile(args, nodeNamespace, sslrootcert);
      checks.push('postgresql_sslrootcert_node_plugin_readable');
    }
  }

  if (objectStorageTls) {
    requireConfigMappedCaSecret(args, {
      configs,
      dir: AFSCP_OBJECT_STORAGE_CA_DIR,
      mountNamespace,
      label: 'object-storage TLS',
      problems
    });
    const envs = envMapEntries(parseSecretStructuredField(secretDataValue(volumeSecret, 'envs'), 'envs'));
    if (!sslCertDirIncludes(envs.SSL_CERT_DIR, AFSCP_OBJECT_STORAGE_CA_DIR)) {
      problems.push(
        `object-storage TLS requires envs.SSL_CERT_DIR to include ${AFSCP_OBJECT_STORAGE_CA_DIR}`
      );
    }
    checks.push('object_storage_tls_ca_secret');
  }

  if (problems.length > 0) {
    fail(`AFSCP JuiceFS CSI TLS readiness preflight failed: ${problems.join('; ')}`);
  }

  return {
    afscp_juicefs_csi_tls_readiness: {
      status: 'pass',
      reason: 'tls_projection_ready',
      ...summaryBase,
      node_namespace: nodeNamespace,
      mount_namespace: mountNamespace,
      checks
    }
  };
}

function unifiedDeployOwnershipProblems(resource) {
  const labels = labelsFor(resource);
  const annotations = annotationsFor(resource);
  const problems = [];

  for (const [key, expected] of Object.entries(AGENTSMITH_JOB_OWNERSHIP_LABELS)) {
    if (labels[key] !== expected) {
      problems.push(`missing label ${key}=${expected}`);
    }
  }
  for (const [key, expected] of Object.entries(AGENTSMITH_JOB_OWNERSHIP_ANNOTATIONS)) {
    if (annotations[key] !== expected) {
      problems.push(`missing annotation ${key}=${expected}`);
    }
  }

  return problems;
}

function hasUnifiedDeployOwnership(resource) {
  return unifiedDeployOwnershipProblems(resource).length === 0;
}

function requireUnifiedDeployOwnership(resource, label) {
  const problems = unifiedDeployOwnershipProblems(resource);
  if (problems.length > 0) {
    fail(`${label} is not eligible for AFSCP pre-apply reconcile: ${problems.join('; ')}`);
  }
}

function requireLiveAfscpVolumeSafety(livePv, livePvc, intent) {
  const problems = [];
  const pvSpec = isPlainObject(livePv?.spec) ? livePv.spec : {};
  const pvcSpec = isPlainObject(livePvc?.spec) ? livePvc.spec : {};
  const csi = isPlainObject(pvSpec.csi) ? pvSpec.csi : {};
  const claimRef = isPlainObject(pvSpec.claimRef) ? pvSpec.claimRef : {};

  if (livePv.kind !== 'PersistentVolume' || resourceName(livePv) !== intent.pvName) {
    problems.push('live PV identity does not match target PV');
  }
  if (hasDeletionTimestamp(livePv)) {
    problems.push('live PV metadata.deletionTimestamp is set');
  }
  if (
    livePvc.kind !== 'PersistentVolumeClaim' ||
    resourceName(livePvc) !== intent.pvcName ||
    resourceNamespace(livePvc, intent.namespace) !== intent.namespace
  ) {
    problems.push('live PVC identity does not match target PVC');
  }
  if (hasDeletionTimestamp(livePvc)) {
    problems.push('live PVC metadata.deletionTimestamp is set');
  }
  if (csi.driver !== AFSCP_JUICEFS_CSI_DRIVER) {
    problems.push(`live PV CSI driver is not ${AFSCP_JUICEFS_CSI_DRIVER}`);
  }
  if (csi.fsType !== AFSCP_JUICEFS_FSTYPE) {
    problems.push(`live PV CSI fsType is not ${AFSCP_JUICEFS_FSTYPE}`);
  }
  if (csi.volumeHandle !== intent.pvName) {
    problems.push('live PV CSI volumeHandle does not match target PV');
  }
  if (!normalizeNodePublishSecretRef(livePv, intent.namespace)) {
    problems.push('live PV CSI nodePublishSecretRef is missing');
  }
  if (pvSpec.persistentVolumeReclaimPolicy !== 'Retain') {
    problems.push('live PV reclaimPolicy is not Retain');
  }
  if (pvcSpec.volumeName !== intent.pvName) {
    problems.push('live PVC spec.volumeName does not match target PV');
  }
  if (claimRef.namespace !== intent.namespace || claimRef.name !== intent.pvcName) {
    problems.push('live PV claimRef does not match target PVC');
  }
  if (!staticStorageClassName(storageClassNameFor(livePv))) {
    problems.push('live PV storageClassName is not static/empty');
  }
  if (!staticStorageClassName(storageClassNameFor(livePvc))) {
    problems.push('live PVC storageClassName is not static/empty');
  }

  problems.push(...unifiedDeployOwnershipProblems(livePv).map((problem) => `live PV ${problem}`));
  problems.push(...unifiedDeployOwnershipProblems(livePvc).map((problem) => `live PVC ${problem}`));

  if (problems.length > 0) {
    fail(
      `AFSCP static JuiceFS PV ${intent.pvName} cannot be reconciled safely: ${problems.join(
        '; '
      )}`
    );
  }
}

function persistentVolumeClaimNamesForResource(resource) {
  const podSpec = podSpecForResource(resource);
  if (!isPlainObject(podSpec) || !Array.isArray(podSpec.volumes)) {
    return [];
  }

  return podSpec.volumes
    .map((volume) => {
      return stringValue(volume?.persistentVolumeClaim?.claimName);
    })
    .filter((name) => name !== undefined);
}

function workloadUsesPvc(resource, pvcName) {
  return persistentVolumeClaimNamesForResource(resource).includes(pvcName);
}

function metadataSearchText(resource) {
  const metadata = metadataFor(resource);
  const labels = labelsFor(resource);
  const annotations = annotationsFor(resource);
  return [
    resourceName(resource),
    ...Object.keys(labels),
    ...Object.values(labels),
    ...Object.keys(annotations),
    ...Object.values(annotations)
  ]
    .filter((value) => typeof value === 'string')
    .join(' ')
    .toLowerCase();
}

function isKnownAfscpComponent(resource) {
  const text = metadataSearchText(resource);
  return text.includes('afscp') || text.includes('agentsmith-fs-control-plane');
}

function workloadDeleteResource(kind) {
  return AFSCP_WORKLOAD_DELETE_RESOURCE_BY_KIND.get(kind);
}

function workloadDeleteOrder(target) {
  return AFSCP_WORKLOAD_DELETE_ORDER.get(target.kind) || 100;
}

function workloadRefKey(kind, namespace, name) {
  return `${kind}/${namespace}/${name}`;
}

function workloadRefKeyForResource(resource, fallbackNamespace) {
  const kind = stringValue(resource?.kind);
  const name = resourceName(resource);
  const namespace = resourceNamespace(resource, fallbackNamespace);
  if (!kind || !name || !namespace) {
    return undefined;
  }
  return workloadRefKey(kind, namespace, name);
}

function workloadResourceIndexes(resources, fallbackNamespace) {
  const byKey = new Map();
  const byUid = new Map();

  for (const resource of resources) {
    const key = workloadRefKeyForResource(resource, fallbackNamespace);
    if (key) {
      byKey.set(key, resource);
    }

    const uid = stringValue(metadataFor(resource).uid);
    if (uid) {
      byUid.set(uid, resource);
    }
  }

  return { byKey, byUid };
}

function controllerOwnerReferencesFor(resource) {
  const ownerReferences = ownerReferencesFor(resource);
  const controllerReferences = ownerReferences.filter((ownerReference) => {
    return ownerReference.controller === true || ownerReference.controller === 'true';
  });
  return controllerReferences.length > 0 ? controllerReferences : ownerReferences;
}

function replicaSetNameMatchesDeployment(replicaSetName, deploymentName) {
  const prefix = `${deploymentName}-`;
  if (!replicaSetName.startsWith(prefix)) {
    return false;
  }

  const suffix = replicaSetName.slice(prefix.length);
  return /^[a-z0-9]{5,}$/.test(suffix);
}

function replicaSetNameResolvesToOwnedDeployment(replicaSetName, namespace, ownerContext) {
  return ownerContext.ownedControllerTargets.some((target) => {
    return (
      target.kind === 'Deployment' &&
      target.namespace === namespace &&
      replicaSetNameMatchesDeployment(replicaSetName, target.name)
    );
  });
}

function ownerReferenceResolvesToOwnedAfscpTarget(
  ownerReference,
  namespace,
  ownerContext,
  visited
) {
  const kind = stringValue(ownerReference.kind);
  const name = stringValue(ownerReference.name);
  const uid = stringValue(ownerReference.uid);
  if (!kind || (!name && !uid)) {
    return false;
  }

  const directKey = name ? workloadRefKey(kind, namespace, name) : undefined;
  if (directKey && ownerContext.ownedControllerKeys.has(directKey)) {
    return true;
  }

  const liveOwner = (uid && ownerContext.resourcesByUid.get(uid)) ||
    (directKey && ownerContext.resourcesByKey.get(directKey));
  if (liveOwner && resourceOwnerChainResolvesToOwnedAfscpTarget(liveOwner, ownerContext, visited)) {
    return true;
  }

  if (kind === 'ReplicaSet' && name && !liveOwner) {
    return replicaSetNameResolvesToOwnedDeployment(name, namespace, ownerContext);
  }

  return false;
}

function resourceOwnerChainResolvesToOwnedAfscpTarget(resource, ownerContext, visited) {
  const key = workloadRefKeyForResource(resource, ownerContext.namespace);
  if (key) {
    if (ownerContext.ownedControllerKeys.has(key)) {
      return true;
    }
    if (visited.has(key)) {
      return false;
    }
    visited.add(key);
  }

  const namespace = resourceNamespace(resource, ownerContext.namespace);
  if (!namespace) {
    return false;
  }

  return controllerOwnerReferencesFor(resource).some((ownerReference) => {
    return ownerReferenceResolvesToOwnedAfscpTarget(
      ownerReference,
      namespace,
      ownerContext,
      visited
    );
  });
}

function podOwnerChainResolvesToOwnedAfscpTarget(pod, ownerContext) {
  const namespace = resourceNamespace(pod, ownerContext.namespace);
  if (!namespace) {
    return false;
  }

  return controllerOwnerReferencesFor(pod).some((ownerReference) => {
    return ownerReferenceResolvesToOwnedAfscpTarget(
      ownerReference,
      namespace,
      ownerContext,
      new Set()
    );
  });
}

function afscpWorkloadRef(resource, intent) {
  const kind = stringValue(resource?.kind) || 'Unknown';
  const namespace = resourceNamespace(resource, intent.namespace) || 'unknown';
  const name = resourceName(resource) || 'unknown';
  return {
    kind,
    namespace,
    name
  };
}

function afscpWorkloadEligibilityProblems(resource, intent) {
  const problems = [];
  const kind = stringValue(resource?.kind);
  const name = resourceName(resource);
  const namespace = resourceNamespace(resource, intent.namespace);

  if (!kind) {
    problems.push('kind is missing');
  }
  if (!name) {
    problems.push('metadata.name is missing');
  }
  if (!namespace) {
    problems.push('metadata.namespace is missing');
  } else if (namespace !== intent.namespace) {
    problems.push(`namespace is not target namespace ${intent.namespace}`);
  }
  if (!kind || !workloadDeleteResource(kind)) {
    problems.push('kind is not in the AFSCP workload delete allowlist');
  }
  if (!workloadUsesPvc(resource, intent.pvcName)) {
    problems.push(`does not mount target PVC ${intent.namespace}/${intent.pvcName}`);
  }

  problems.push(
    ...unifiedDeployOwnershipProblems(resource).map((problem) => {
      return `live workload ${problem}`;
    })
  );

  if (kind && name && namespace) {
    const key = workloadRefKey(kind, namespace, name);
    if (!intent.renderedWorkloadAllowlist?.has(key)) {
      problems.push(
        'rendered workload allowlist does not include the same kind/name/namespace mounting the target PVC'
      );
    }
  }

  return problems;
}

function failIneligibleAfscpWorkloadUsingTargetPvc(resource, intent, problems) {
  const diagnostic = isKnownAfscpComponent(resource)
    ? '; metadata contains an AFSCP marker, but that marker is diagnostic only'
    : '';
  fail(
    `workload ${refLabel(afscpWorkloadRef(resource, intent))} mounts PVC ${intent.namespace}/${intent.pvcName} but is not eligible for AFSCP pre-apply reconcile: ${problems.join('; ')}${diagnostic}`
  );
}

function requireAfscpWorkloadDeleteEligibility(resource, intent) {
  const problems = afscpWorkloadEligibilityProblems(resource, intent);
  if (problems.length > 0) {
    failIneligibleAfscpWorkloadUsingTargetPvc(resource, intent, problems);
  }
}

function addAfscpWorkloadDeleteTarget(targets, seen, resource, intent) {
  const deleteResource = workloadDeleteResource(resource.kind);
  if (!deleteResource) {
    return undefined;
  }

  const name = resourceName(resource);
  const namespace = resourceNamespace(resource, intent.namespace);
  if (!name || !namespace) {
    fail('AFSCP workload candidate is missing metadata.name or metadata.namespace');
  }
  requireUnifiedDeployOwnership(resource, `${resource.kind} ${namespace}/${name}`);

  const key = workloadRefKey(resource.kind, namespace, name);
  if (seen.has(key)) {
    return undefined;
  }
  seen.add(key);

  const target = {
    kind: resource.kind,
    resource: deleteResource,
    namespace,
    name,
    cascade: 'foreground',
    reason: 'afscp_workload_mounts_target_pvc'
  };
  targets.push(target);
  return target;
}

function collectAfscpWorkloadDeleteTargets(args, intent) {
  const resources = listKubernetesResources(args, {
    resource: AFSCP_WORKLOAD_LIST_RESOURCE,
    namespace: intent.namespace,
    label: 'kubectl get AFSCP workloads'
  });
  const targets = [];
  const ownedControllerTargets = [];
  const seen = new Set();

  for (const resource of resources) {
    if (resource.kind === 'Pod' || resource.kind === 'ReplicaSet') {
      continue;
    }

    const usesTargetPvc = workloadUsesPvc(resource, intent.pvcName);
    if (!usesTargetPvc) {
      continue;
    }

    requireAfscpWorkloadDeleteEligibility(resource, intent);
    const target = addAfscpWorkloadDeleteTarget(targets, seen, resource, intent);
    if (target && AFSCP_OWNER_CONTROLLER_KINDS.has(target.kind)) {
      ownedControllerTargets.push(target);
    }
  }

  const indexes = workloadResourceIndexes(resources, intent.namespace);
  const ownerContext = {
    namespace: intent.namespace,
    resourcesByKey: indexes.byKey,
    resourcesByUid: indexes.byUid,
    ownedControllerTargets,
    ownedControllerKeys: new Set(
      ownedControllerTargets.map((target) => {
        return workloadRefKey(target.kind, target.namespace, target.name);
      })
    )
  };

  for (const resource of resources) {
    if (resource.kind !== 'Pod' && resource.kind !== 'ReplicaSet') {
      continue;
    }

    const usesTargetPvc = workloadUsesPvc(resource, intent.pvcName);
    if (!usesTargetPvc) {
      continue;
    }

    if (resourceOwnerChainResolvesToOwnedAfscpTarget(resource, ownerContext, new Set())) {
      continue;
    }

    requireAfscpWorkloadDeleteEligibility(resource, intent);
    addAfscpWorkloadDeleteTarget(targets, seen, resource, intent);
  }

  return targets.sort((left, right) => {
    const orderDelta = workloadDeleteOrder(left) - workloadDeleteOrder(right);
    if (orderDelta !== 0) {
      return orderDelta;
    }
    return refLabel(left).localeCompare(refLabel(right));
  });
}

function metadataKeyValueEntries(resource) {
  return [
    ...Object.entries(labelsFor(resource)),
    ...Object.entries(annotationsFor(resource))
  ].filter(([, value]) => typeof value === 'string');
}

function ownerReferencesFor(resource) {
  const ownerReferences = metadataFor(resource).ownerReferences;
  return Array.isArray(ownerReferences)
    ? ownerReferences.filter((ownerReference) => isPlainObject(ownerReference))
    : [];
}

function isJuicefsCacheResource(resource) {
  const text = [
    resource.kind,
    resourceName(resource),
    ...metadataKeyValueEntries(resource).flat()
  ]
    .filter((value) => typeof value === 'string')
    .join(' ')
    .toLowerCase();
  return text.includes('juicefs') || text.includes('csi.juicefs.com');
}

function addScopeValue(scopeValues, value) {
  const normalized = stringValue(value);
  if (normalized) {
    scopeValues.add(normalized);
  }
}

function addMetadataUpstreamIdValues(selectorValues, resource) {
  for (const [key, value] of metadataKeyValueEntries(resource)) {
    if (AFSCP_CSI_CACHE_UPSTREAM_ID_KEYS.has(key)) {
      addScopeValue(selectorValues, value);
    }
  }
}

function csiCacheScopeValues(intent, livePv, livePvc) {
  const scopeValues = new Set();
  addScopeValue(scopeValues, intent.pvName);
  addScopeValue(scopeValues, livePv?.spec?.csi?.volumeHandle);
  addScopeValue(scopeValues, metadataFor(livePv).uid);
  addMetadataUpstreamIdValues(scopeValues, livePv);
  addMetadataUpstreamIdValues(scopeValues, livePvc);
  return scopeValues;
}

function csiCacheSecretRefKeys(intent, liveNodePublishSecretRef) {
  const keys = new Set();
  for (const ref of [intent.renderedNodePublishSecretRef, liveNodePublishSecretRef]) {
    if (!ref?.name || !ref.namespace) {
      continue;
    }
    keys.add(`${ref.namespace}/${ref.name}`);
  }
  return keys;
}

function resourceMatchesSecretRef(resource, secretRefKeys) {
  if (resource.kind !== 'Secret') {
    return false;
  }
  const name = resourceName(resource);
  const namespace = resourceNamespace(resource);
  return Boolean(name && namespace && secretRefKeys.has(`${namespace}/${name}`));
}

function weakCsiCacheScopeKey(key) {
  return key === 'juicefs/pvc' ||
    key === 'juicefs.com/pvc' ||
    key === 'juicefs.io/pvc' ||
    key.endsWith('/pvc-name') ||
    key.endsWith('.io/pvc-name') ||
    key.endsWith('.com/pvc-name') ||
    key.endsWith('/secret-name') ||
    key.endsWith('.io/secret-name') ||
    key.endsWith('.com/secret-name');
}

function metadataScopeEntryMatches(key, value, scopeValues, options = {}) {
  if (!AFSCP_CSI_CACHE_SCOPE_KEYS.has(key) || !scopeValues.has(value)) {
    return false;
  }
  return options.allowWeakNames === true || !weakCsiCacheScopeKey(key);
}

function metadataMatchesScope(resource, scopeValues, options = {}) {
  return metadataKeyValueEntries(resource).some(([key, value]) => {
    return metadataScopeEntryMatches(key, value, scopeValues, options);
  });
}

function ownerReferenceMatchesAfscpVolume(ownerReference, intent, livePv) {
  const kind = stringValue(ownerReference.kind);
  const name = stringValue(ownerReference.name);
  const uid = stringValue(ownerReference.uid);
  const livePvUid = stringValue(metadataFor(livePv).uid);

  if (livePvUid && uid === livePvUid) {
    return true;
  }
  if ((kind === 'PersistentVolume' || kind === 'PV') && name === intent.pvName) {
    return true;
  }
  return false;
}

function ownerReferencesMatchAfscpVolume(resource, intent, livePv) {
  return ownerReferencesFor(resource).some((ownerReference) => {
    return ownerReferenceMatchesAfscpVolume(ownerReference, intent, livePv);
  });
}

function hasGeneratedJuicefsSecretLabel(resource) {
  return labelsFor(resource)['juicefs/secret'] === 'true';
}

function isScopedGeneratedJuicefsSecret(resource, intent, livePv, scopeValues, secretRefKeys) {
  if (resource.kind !== 'Secret' || !hasGeneratedJuicefsSecretLabel(resource)) {
    return false;
  }
  if (!isJuicefsCacheResource(resource)) {
    return false;
  }
  return (
    ownerReferencesMatchAfscpVolume(resource, intent, livePv) ||
    resourceMatchesSecretRef(resource, secretRefKeys) ||
    metadataMatchesScope(resource, scopeValues)
  );
}

function isScopedJuicefsCacheResource(resource, intent, livePv, scopeValues, secretRefKeys) {
  if (!['Pod', 'Secret'].includes(resource.kind)) {
    return false;
  }
  if (!isJuicefsCacheResource(resource)) {
    return false;
  }

  if (metadataMatchesScope(resource, scopeValues)) {
    return true;
  }
  if (resourceMatchesSecretRef(resource, secretRefKeys)) {
    return true;
  }
  return ownerReferencesMatchAfscpVolume(resource, intent, livePv);
}

function kubernetesLabelValueSafe(value) {
  return (
    typeof value === 'string' &&
    value.length <= 63 &&
    (value === '' || /^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$/.test(value))
  );
}

function afscpCsiCacheSelectorValues(intent, livePv, livePvc) {
  const values = new Set();
  addScopeValue(values, intent.pvName);
  addScopeValue(values, livePv?.spec?.csi?.volumeHandle);
  addScopeValue(values, metadataFor(livePv).uid);
  addMetadataUpstreamIdValues(values, livePv);
  addMetadataUpstreamIdValues(values, livePvc);
  return values;
}

function afscpCsiCacheSelectors(selectorValues) {
  const selectors = [];

  for (const value of selectorValues) {
    if (!kubernetesLabelValueSafe(value)) {
      continue;
    }
    selectors.push(`${AFSCP_JUICEFS_MOUNT_POD_SELECTOR},volume-id=${value}`);
    selectors.push(`volume-id=${value}`);
    selectors.push(`juicefs.com/volume-id=${value}`);
    selectors.push(`juicefs-name=${value}`);
    selectors.push(`juicefs-uniqueid=${value}`);
  }

  return [...new Set(selectors)];
}

function cacheDeleteResource(kind) {
  if (kind === 'Pod') {
    return 'pod';
  }
  if (kind === 'Secret') {
    return 'secret';
  }
  return undefined;
}

function addAfscpCsiCacheDeleteTarget(targets, seen, resource) {
  const deleteResource = cacheDeleteResource(resource.kind);
  const name = resourceName(resource);
  const namespace = resourceNamespace(resource);
  if (!deleteResource || !name || !namespace) {
    fail('scoped JuiceFS CSI cache candidate is missing kind, metadata.name, or metadata.namespace');
  }

  const key = `${resource.kind}/${namespace}/${name}`;
  if (seen.has(key)) {
    return;
  }
  seen.add(key);
  targets.push({
    kind: resource.kind,
    resource: deleteResource,
    namespace,
    name,
    reason: 'scoped_juicefs_csi_cache'
  });
}

function collectAfscpCsiCacheDeleteTargets(args, intent, livePv, livePvc, liveNodePublishSecretRef) {
  const scopeValues = csiCacheScopeValues(intent, livePv, livePvc);
  const secretRefKeys = csiCacheSecretRefKeys(intent, liveNodePublishSecretRef);
  const selectorValues = afscpCsiCacheSelectorValues(intent, livePv, livePvc);
  const targets = [];
  const seen = new Set();

  const generatedSecrets = listKubernetesResources(args, {
    resource: 'secret',
    allNamespaces: true,
    labelSelector: AFSCP_JUICEFS_GENERATED_SECRET_SELECTOR,
    label: `kubectl get JuiceFS generated Secrets ${AFSCP_JUICEFS_GENERATED_SECRET_SELECTOR}`
  });

  for (const secret of generatedSecrets) {
    if (!isScopedGeneratedJuicefsSecret(secret, intent, livePv, scopeValues, secretRefKeys)) {
      continue;
    }
    addMetadataUpstreamIdValues(scopeValues, secret);
    addMetadataUpstreamIdValues(selectorValues, secret);
    addAfscpCsiCacheDeleteTarget(targets, seen, secret);
  }

  for (const selector of afscpCsiCacheSelectors(selectorValues)) {
    const resources = listKubernetesResources(args, {
      resource: AFSCP_CSI_CACHE_LIST_RESOURCE,
      allNamespaces: true,
      labelSelector: selector,
      label: `kubectl get JuiceFS CSI cache ${selector}`
    });

    for (const resource of resources) {
      if (!isScopedJuicefsCacheResource(resource, intent, livePv, scopeValues, secretRefKeys)) {
        continue;
      }
      addAfscpCsiCacheDeleteTarget(targets, seen, resource);
    }
  }

  return targets.sort((left, right) => {
    const order = { Pod: 10, Secret: 20 };
    const orderDelta = (order[left.kind] || 100) - (order[right.kind] || 100);
    if (orderDelta !== 0) {
      return orderDelta;
    }
    return refLabel(left).localeCompare(refLabel(right));
  });
}

function deleteReconcileTarget(args, target) {
  const commandArgs = [
    ...kubectlPrefixArgs(args),
    'delete',
    target.resource,
    target.name
  ];
  if (target.namespace) {
    commandArgs.push('--namespace', target.namespace);
  }
  if (target.cascade === 'foreground') {
    commandArgs.push('--cascade=foreground');
  }
  commandArgs.push('--wait=true', `--timeout=${AFSCP_RECONCILE_DELETE_TIMEOUT}`);

  const label = `kubectl delete ${target.resource} ${target.name}`;
  const result = executeCommand(args.kubectl, commandArgs, label);
  if (result.status === 0) {
    return {
      kind: target.kind,
      name: target.name,
      namespace: target.namespace,
      action: 'delete',
      status: 'deleted',
      reason: target.reason
    };
  }
  if (kubectlFailedWithNotFound(result)) {
    return {
      kind: target.kind,
      name: target.name,
      namespace: target.namespace,
      action: 'delete',
      status: 'not_found',
      reason: target.reason
    };
  }
  failKubectlResult(label, result);
}

function deleteAfscpReconcileTargets(args, targets) {
  return targets.map((target) => {
    return Object.fromEntries(
      Object.entries(deleteReconcileTarget(args, target)).filter(([, value]) => {
        return value !== undefined && value !== null;
      })
    );
  });
}

async function runPreApplyAfscpStaticJuicefsPvReconcile(args, manifestFiles) {
  const intent = await renderedAfscpStaticJuicefsVolume(args, manifestFiles);
  if (!intent) {
    return {
      afscp_static_juicefs_pv: {
        status: 'skipped',
        reason: 'rendered_afscp_static_juicefs_pv_not_found'
      }
    };
  }

  const summaryBase = {
    pv: {
      name: intent.pvName
    },
    pvc: {
      namespace: intent.namespace,
      name: intent.pvcName
    }
  };

  if (args.mode !== 'apply') {
    return {
      afscp_static_juicefs_pv: {
        status: 'skipped',
        reason: 'server_dry_run_no_mutation',
        ...summaryBase
      }
    };
  }

  const livePv = getExistingKubernetesResource(args, {
    resource: 'pv',
    name: intent.pvName
  });
  const livePvc = getExistingKubernetesResource(args, {
    resource: 'pvc',
    namespace: intent.namespace,
    name: intent.pvcName
  });

  if (!livePv || !livePvc) {
    return {
      afscp_static_juicefs_pv: {
        status: 'noop',
        reason: 'live_pv_or_pvc_not_found',
        ...summaryBase
      }
    };
  }

  const liveNodePublishSecretRef = normalizeNodePublishSecretRef(livePv, intent.namespace);
  if (secretRefsEqual(liveNodePublishSecretRef, intent.renderedNodePublishSecretRef)) {
    return {
      afscp_static_juicefs_pv: {
        status: 'noop',
        reason: 'node_publish_secret_ref_already_matches',
        ...summaryBase
      }
    };
  }

  requireLiveAfscpVolumeSafety(livePv, livePvc, intent);

  const workloadTargets = collectAfscpWorkloadDeleteTargets(args, intent);
  const cacheTargets = collectAfscpCsiCacheDeleteTargets(
    args,
    intent,
    livePv,
    livePvc,
    liveNodePublishSecretRef
  );
  const storageTargets = [
    {
      kind: 'PersistentVolumeClaim',
      resource: 'pvc',
      namespace: intent.namespace,
      name: intent.pvcName,
      reason: 'afscp_static_pvc_recreate_for_immutable_pv_source'
    },
    {
      kind: 'PersistentVolume',
      resource: 'pv',
      name: intent.pvName,
      reason: 'afscp_static_pv_recreate_for_immutable_csi_source'
    }
  ];

  return {
    afscp_static_juicefs_pv: {
      status: 'reconciled',
      reason: 'node_publish_secret_ref_immutable_drift',
      ...summaryBase,
      operations: deleteAfscpReconcileTargets(args, [
        ...workloadTargets,
        ...cacheTargets,
        ...storageTargets
      ])
    }
  };
}

function renderedJobRefs(renderReport, namespace) {
  const manifests = Array.isArray(renderReport.manifests) ? renderReport.manifests : [];
  const refs = [];
  const seen = new Set();

  for (const manifest of manifests) {
    if (manifest.kind !== 'Job') {
      continue;
    }
    if (typeof manifest.name !== 'string' || manifest.name.trim() === '') {
      fail('render-check Job manifest is missing metadata.name');
    }

    const name = manifest.name.trim();
    const key = `${namespace}/${name}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    refs.push({
      kind: 'Job',
      name,
      namespace
    });
  }

  return refs;
}

function hasJobCondition(job, type, status) {
  const conditions = job.status?.conditions;
  if (!Array.isArray(conditions)) {
    return false;
  }
  return conditions.some((condition) => {
    return isPlainObject(condition) && condition.type === type && condition.status === status;
  });
}

function existingJobLabel(jobRef) {
  return `Job ${jobRef.namespace}/${jobRef.name}`;
}

function requireAdoptableCompletedJob(job, jobRef) {
  const metadata = isPlainObject(job.metadata) ? job.metadata : {};
  const labels = isPlainObject(metadata.labels) ? metadata.labels : {};
  const annotations = isPlainObject(metadata.annotations) ? metadata.annotations : {};
  const problems = [];

  if (job.kind !== 'Job') {
    problems.push('kind is not Job');
  }
  if (metadata.name !== jobRef.name) {
    problems.push('metadata.name does not match rendered Job');
  }

  for (const [key, expected] of Object.entries(AGENTSMITH_JOB_OWNERSHIP_LABELS)) {
    if (labels[key] !== expected) {
      problems.push(`missing label ${key}=${expected}`);
    }
  }
  for (const [key, expected] of Object.entries(AGENTSMITH_JOB_OWNERSHIP_ANNOTATIONS)) {
    if (annotations[key] !== expected) {
      problems.push(`missing annotation ${key}=${expected}`);
    }
  }

  if (metadata.deletionTimestamp !== undefined && metadata.deletionTimestamp !== null) {
    problems.push('has deletionTimestamp');
  }
  if (
    metadata.ownerReferences !== undefined &&
    (!Array.isArray(metadata.ownerReferences) || metadata.ownerReferences.length > 0)
  ) {
    problems.push('has ownerReferences');
  }
  if (hasJobCondition(job, 'Failed', 'True')) {
    problems.push('has Failed=True condition');
  }
  if (!hasJobCondition(job, 'Complete', 'True')) {
    problems.push('is not Complete=True');
  }

  if (problems.length > 0) {
    fail(
      `${existingJobLabel(jobRef)} is not eligible for pre-apply replacement: ${problems.join(
        '; '
      )}`
    );
  }
}

function getExistingJob(args, jobRef) {
  const label = `kubectl get job ${jobRef.name}`;
  const result = executeCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'get',
      'job',
      jobRef.name,
      '--namespace',
      jobRef.namespace,
      '-o',
      'json'
    ],
    label
  );

  if (result.status === 0) {
    return parseKubectlJson(result.stdout, label);
  }
  if (kubectlFailedWithNotFound(result)) {
    return undefined;
  }
  failKubectlResult(label, result);
}

function deleteExistingJob(args, jobRef) {
  const label = `kubectl delete job ${jobRef.name}`;
  const result = executeCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'delete',
      'job',
      jobRef.name,
      '--namespace',
      jobRef.namespace,
      '--wait=true'
    ],
    label
  );

  if (result.status === 0) {
    return true;
  }
  if (kubectlFailedWithNotFound(result)) {
    return false;
  }
  failKubectlResult(label, result);
}

function runPreApplyJobReplacements(args, renderReport) {
  if (args.mode !== 'apply') {
    return [];
  }

  const replacements = [];
  for (const jobRef of renderedJobRefs(renderReport, args.namespace)) {
    const existingJob = getExistingJob(args, jobRef);
    if (!existingJob) {
      continue;
    }

    requireAdoptableCompletedJob(existingJob, jobRef);
    if (deleteExistingJob(args, jobRef)) {
      replacements.push({
        ...jobRef,
        reason: 'completed_existing_job_replaced_before_apply'
      });
    }
  }

  return replacements;
}

function runKubectlApply(args, manifestFiles) {
  const applyArgs = [
    ...kubectlPrefixArgs(args),
    'apply',
    '--server-side',
    '--namespace',
    args.namespace
  ];

  for (const manifestFile of manifestFiles) {
    applyArgs.push('-f', manifestFile);
  }

  if (args.mode === 'server-dry-run') {
    applyArgs.push('--dry-run=server');
  }

  applyArgs.push('-o', 'name');
  return runCommand(args.kubectl, applyArgs, 'kubectl apply', { includeOutput: true });
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

function completedJobReplacementsControl(args, preApplyJobReplacements) {
  const replacements = preApplyJobReplacements || [];
  return {
    status: args.mode === 'apply' ? 'pass' : 'skipped',
    reason: args.mode === 'apply'
      ? 'completed_existing_jobs_checked_before_apply'
      : 'server_dry_run_no_mutation',
    replacement_count: replacements.length,
    replacements
  };
}

function buildPreApplyControls({
  args,
  secretPreflight,
  preApplyReconcile,
  preApplyJobReplacements
}) {
  return {
    secret_preflight: secretPreflight || {
      status: 'skipped',
      reason: 'not_run'
    },
    afscp_juicefs_csi_tls_readiness:
      preApplyReconcile?.afscp_juicefs_csi_tls_readiness || {
        status: 'skipped',
        reason: 'not_run'
      },
    afscp_static_juicefs_pv_reconcile:
      preApplyReconcile?.afscp_static_juicefs_pv || {
        status: 'skipped',
        reason: 'not_run'
      },
    completed_job_replacements: completedJobReplacementsControl(
      args,
      preApplyJobReplacements
    )
  };
}

function buildReport({
  args,
  renderReport,
  kubectlVersion,
  kubectlApplyOutput,
  preApplyJobReplacements,
  preApplyReconcile,
  preApplyControls
}) {
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
    pre_apply_controls: preApplyControls || {},
    pre_apply_job_replacements: preApplyJobReplacements || [],
    pre_apply_reconcile: preApplyReconcile || {},
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
  const manifestFiles = await applyManifestFiles(args);

  const secretPreflight = await runRenderedSecretRefPreflight(args, manifestFiles);
  const afscpCsiTlsReadiness = await runAfscpJuicefsCsiTlsReadinessPreflight(
    args,
    manifestFiles
  );
  const kubectlVersion = runKubectlVersion(args);
  const afscpStaticPvReconcile = await runPreApplyAfscpStaticJuicefsPvReconcile(
    args,
    manifestFiles
  );
  const preApplyReconcile = {
    ...afscpCsiTlsReadiness,
    ...afscpStaticPvReconcile
  };
  const preApplyJobReplacements = runPreApplyJobReplacements(args, renderCheckReport.value);
  const preApplyControls = buildPreApplyControls({
    args,
    secretPreflight,
    preApplyReconcile,
    preApplyJobReplacements
  });
  const kubectlApplyOutput = runKubectlApply(args, manifestFiles);

  await writeReport(
    args.outputDir,
    buildReport({
      args,
      renderReport: renderCheckReport.value,
      kubectlVersion,
      kubectlApplyOutput,
      preApplyJobReplacements,
      preApplyReconcile,
      preApplyControls
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
