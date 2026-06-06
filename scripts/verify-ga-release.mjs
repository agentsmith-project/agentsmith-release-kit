#!/usr/bin/env node
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import * as sourceValidation from './lib/deployment-path-source-validation.mjs';
import {
  assertReportUriHasNoForbiddenContent,
  scanReportForForbiddenContent
} from './lib/report-forbidden-scan.mjs';

const execFileAsync = promisify(execFile);
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const REPORT_FILE = 'ga-release-report.json';
const SUMMARY_FILE = 'ga-release-summary.md';
const EVIDENCE_INDEX_FILE = 'ga-evidence-index.json';
const FINALIZER_MANIFEST_FILE = 'deployment-path-finalizer-manifest.json';
const SOURCE_EVIDENCE_DIR = 'source-evidence';
const REPORT_SCHEMA = 'agentsmith.ga-release-report/v1';
const EVIDENCE_INDEX_SCHEMA = 'agentsmith.ga-evidence-index/v1';
const PATH_REPORT_SCHEMA = 'agentsmith.deployment-path-report/v1';
const PATH_REPORT_SCOPE = 'deployment_path_ga_evidence';
const FINALIZER_MANIFEST_SCHEMA = 'agentsmith.deployment-path-finalizer-manifest/v1';
const SOURCE_EVIDENCE_SCHEMA = 'agentsmith.deployment-path-source-evidence/v1';
const FINALIZER_SCHEMA = 'agentsmith.deployment-path-report-finalizer/v1';
const FINALIZER_TOOL = 'verify-deployment-path-report.mjs';
const FINALIZER_MANIFEST_TOOL = 'verify-deployment-path-report';
const FINALIZER_MODE = 'deployment_path_source_evidence_finalization';
const AIRGAP_OFFLINE_PROOF_SCOPE = 'release_kit_package_local_bundle_local_digest_bound_inputs_only';
const PRODUCT_READY_SCHEMA = 'agentsmith.product-readiness-report/v1';
const PRODUCT_RUNTIME_READINESS_SCHEMA = 'agentsmith.runtime-readiness-details/v1';
const PRODUCT_RUNTIME_READINESS_THEME = 'runtime_pending_readiness';
const PRODUCT_RUNTIME_READINESS_BACKOFF = 'increasing_after_consecutive_non_terminal';
const PRODUCT_RUNTIME_READINESS_INTERVAL_MS = [60_000, 90_000, 120_000, 180_000, 300_000];
const PRODUCT_RUNTIME_READINESS_EVIDENCE_FOCUS = [
  'Files restore continuation focused backend-real gate',
  'AGENT_SANDBOX_UNAVAILABLE API/pod-manager/ASBCP summaries',
  'runtime flake versus stability blocker classification'
];
const PRODUCT_RUNTIME_READINESS_CONVERGENCE = {
  files: {
    pending: 'file_library_list_pending',
    releasing: 'workspace binding release convergence',
    offline: 'no active writer',
    not_found: 'no active writer'
  },
  agent_task_sandbox: {
    pending: 'bounded ASBCP status checks',
    releasing: 'release-incomplete',
    offline: 'ASBCP create-or-ensure',
    not_found: 'ASBCP create-or-ensure'
  },
  afscp_workspace_binding: {
    pending: 'workspace binding owner',
    releasing: 'terminal released/revoked/expired/deleted',
    offline: 'no active writer',
    not_found: 'no active writer'
  },
  read_export: {
    pending: 'typed pending',
    releasing: 'runtime release fence',
    offline: 'no active writer',
    not_found: 'fresh read export'
  }
};
const PRODUCT_RUNTIME_READINESS_DETAILS_PATH =
  'gate-release/child-internal-evidence/files_restore_continuation_spec/runtime-readiness-details.json';
const PRODUCT_SMOKE_SCHEMA = 'agentsmith.post-deploy-product-smoke-report/v1';
const PRODUCT_SMOKE_PRODUCER = 'agentsmith-post-deploy-product-smoke';
const PRODUCT_SMOKE_OWNER = 'agentsmith';
const REQUIRED_PRODUCT_SMOKE_DISTRIBUTIONS = ['online', 'airgap'];
const OPERATOR_INPUTS_MANIFEST_SCHEMA = 'agentsmith.operator-inputs/v1';
const OPERATOR_INPUTS_MANIFEST_VERSION = 1;
const OPERATOR_INPUTS_PLAN_SCHEMA = 'agentsmith.operator-inputs-plan/v1';
const OPERATOR_INPUTS_PLAN_SCOPE = 'operator_inputs_intake_only';
const OPERATOR_INPUTS_PLAN_INTERNAL_SCHEMA = 'agentsmith.operator-inputs-plan-internal/v1';
const PRODUCT_FLOWS_AGGREGATE_SCHEMA = 'agentsmith.unified-deploy.product-flows.aggregate/v1';
const PRODUCT_FLOWS_AGGREGATE_PRODUCER = 'unified-deploy-product-flows';
const PRODUCT_FLOWS_AGGREGATE_COMMAND = 'npm run lane:unified-deploy:product-flows';
const PRODUCT_SMOKE_LEGACY_FIELDS = [
  'covered_flows',
  'artifact_provenance',
  'release_id',
  'git_sha',
  'release_contract_digest'
];
const PRODUCT_SMOKE_RELEASE_CONTRACT_KEYS = new Set([
  'path',
  'input_sha256',
  'release_id',
  'git_sha'
]);
const PRODUCT_SMOKE_SOURCE_KEYS = new Set([
  'product_flows_path',
  'product_flows_sha256',
  'aggregate_schema_version',
  'aggregate_producer',
  'aggregate_generated_at',
  'aggregate_command'
]);
const PRODUCT_SMOKE_DEPLOYMENT_TARGET_KEYS = new Set([
  'profile',
  'public_base_url',
  'api_base_url',
  'runner_public_api_base_url',
  'site_env',
  'substrate_truth'
]);
const PRODUCT_SMOKE_FILE_BINDING_KEYS = new Set([
  'path',
  'sha256'
]);
const PRODUCT_SMOKE_PROVIDER_NEUTRAL_PROOF_KEYS = new Set([
  'endpoint_type',
  'provider_family',
  'upstream_protocol',
  'credential_type',
  'success_path'
]);
const PRODUCT_SMOKE_RESULT_KEYS = new Set([
  'id',
  'status',
  'label',
  'source_flow',
  'source_evidence_path',
  'source_evidence_sha256'
]);
const PRODUCT_SMOKE_PROVIDER_NEUTRAL_RESULT_KEYS = new Set([
  ...PRODUCT_SMOKE_RESULT_KEYS,
  'proof'
]);
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const ARTIFACT_PROVENANCE_KIND = 'ci_artifact';
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = sourceValidation.AIRGAP_BUNDLE_MANIFEST_SCHEMA;
const IMAGE_MAP_SCHEMA = sourceValidation.IMAGE_MAP_SCHEMA;
const IMAGE_MAP_SCOPE = sourceValidation.IMAGE_MAP_SCOPE;
const SUBSTRATE_INSTALL_SCHEMA = sourceValidation.SUBSTRATE_INSTALL_SCHEMA;
const SUBSTRATE_INSTALL_SCOPE = sourceValidation.SUBSTRATE_INSTALL_SCOPE;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const ARTIFACT_URI_RE = /^[a-z][a-z0-9+.-]*:\/\/[^\s]+$/i;
const KUBERNETES_NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const AGENTSMITH_REPO = 'github.com/agentsmith-project/agentsmith';
const RELEASE_KIT_REPO = 'github.com/agentsmith-project/agentsmith-release-kit';
const RUNNER_REPO = 'github.com/agentsmith-project/agentsmith-runner';
const LLMUP_REPO = 'github.com/agentsmith-project/llm-universal-proxy';
const AFSCP_REPO = 'github.com/agentsmith-project/agentsmith-fs-control-plane';
const ASBCP_REPO = 'github.com/agentsmith-project/agentsmith-sandbox-control-plane';
const RUNNER_RELEASE_MANIFEST_URI_RE =
  /^gh-artifact:\/\/agentsmith-project\/agentsmith-runner\/runner-release-manifest\/([0-9]+)\/runner-release-manifest\.json$/;
const RUNNER_GA_HANDOFF_URI_RE =
  /^gh-artifact:\/\/agentsmith-project\/agentsmith-runner\/runner-ga-handoff\/([0-9]+)\/runner-ga-handoff-report\.json$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:[\\/]/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i;

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'productReadinessReport',
  'outputDir'
];

const DEPLOYMENT_PATHS = sourceValidation.DEPLOYMENT_PATHS;

const SOURCE_STEP_REPORTS = sourceValidation.FINALIZED_STEP_SOURCE_REPORTS;
const DEPLOYMENT_GATE_BY_SOURCE = sourceValidation.DEPLOYMENT_GATE_BY_SOURCE;
const GA_RELEASE_CONTRACT_TARGET_PROFILE_PREREQUISITE_KEYS = new Set([
  'namespace',
  'rbac',
  'ingress',
  'tls',
  'storage_class',
  'registry',
  'pull_secret_ref'
]);
const GA_RELEASE_CONTRACT_TARGET_PROFILE_PREREQUISITES = new Map([
  ['existing_kubernetes/external_declared/online', {
    namespace: 'agentsmith',
    rbac: 'namespace_admin',
    ingress: 'operator_provided',
    tls: 'required',
    storage_class: 'operator_provided',
    registry: 'ghcr_or_operator_mirror',
    pull_secret_ref: 'operator_secret_ref'
  }],
  ['existing_kubernetes/kit_installed/online', {
    namespace: 'agentsmith',
    rbac: 'namespace_admin',
    ingress: 'kit_installed',
    tls: 'required',
    storage_class: 'kit_installed',
    registry: 'ghcr_or_operator_mirror',
    pull_secret_ref: 'operator_secret_ref'
  }],
  ['existing_kubernetes/external_declared/airgap', {
    namespace: 'agentsmith',
    rbac: 'namespace_admin',
    ingress: 'operator_provided',
    tls: 'required',
    storage_class: 'operator_provided',
    registry: 'operator_mirror',
    pull_secret_ref: 'operator_secret_ref'
  }],
  ['existing_kubernetes/kit_installed/airgap', {
    namespace: 'agentsmith',
    rbac: 'namespace_admin',
    ingress: 'kit_installed',
    tls: 'required',
    storage_class: 'kit_installed',
    registry: 'operator_mirror',
    pull_secret_ref: 'operator_secret_ref'
  }]
]);
const GA_RELEASE_CONTRACT_TARGET_PROFILE_TUPLES = [
  ...new Set([...DEPLOYMENT_PATHS.values()].map((requirement) => requirement.targetProfile))
];

const canonicalProductSmokeSpec = (sourceFlow) => ({
  source_flow: sourceFlow,
  source_evidence_path: `unified-deploy/product-flows/${sourceFlow}.json`
});
const CANONICAL_PRODUCT_SMOKE_SPECS = {
  login_profile: canonicalProductSmokeSpec('login_profile'),
  workspace_project: canonicalProductSmokeSpec('workspace_project'),
  provider_neutral_endpoint: canonicalProductSmokeSpec('chat_via_llmup'),
  agent_task_managed_runner: canonicalProductSmokeSpec('agent_task_managed_runner'),
  files: canonicalProductSmokeSpec('files'),
  audit: canonicalProductSmokeSpec('audit'),
  usage: canonicalProductSmokeSpec('usage')
};
const REQUIRED_PRODUCT_SMOKE_IDS = Object.keys(CANONICAL_PRODUCT_SMOKE_SPECS);
const PRODUCT_SMOKE_ACCEPTANCE_COVERAGE = {
  auth_profile: ['login_profile'],
  workspace_project: ['workspace_project'],
  files: ['files'],
  managed_runner_agent_task: ['agent_task_managed_runner'],
  provider_neutral_endpoint: ['provider_neutral_endpoint'],
  audit_usage_readback: ['audit', 'usage']
};

const REQUIRED_IMAGE_IDS = ['agentsmith_app', 'managed_runner', 'llmup', 'afscp', 'asbcp'];
const CANONICAL_REPO_SPECS = [
  {
    repo: AGENTSMITH_REPO,
    image_ids: ['agentsmith_app']
  },
  {
    repo: RELEASE_KIT_REPO,
    finalizer: true
  },
  {
    repo: RUNNER_REPO,
    image_ids: ['managed_runner']
  },
  {
    repo: LLMUP_REPO,
    image_ids: ['llmup']
  },
  {
    repo: AFSCP_REPO,
    image_ids: ['afscp']
  },
  {
    repo: ASBCP_REPO,
    image_ids: ['asbcp']
  }
];
const FINALIZER_MANIFEST_KEYS = new Set([
  'schema',
  'tool',
  'operator_path',
  'deployment_profile',
  'release_contract_digest',
  'template_digest',
  'path_report_sha256',
  'source_evidence_files',
  'created_at'
]);
const FINALIZER_MANIFEST_SOURCE_EVIDENCE_KEYS = new Set([
  'kind',
  'path',
  'sha256',
  'schema',
  'scope',
  'step'
]);
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
  node scripts/verify-ga-release.mjs \\
    --release-contract <agentsmith-release-contract.json> \\
    --deploy-template-package <agentsmith-deploy-template-package.json> \\
    --deployment-path-report <online/use_existing/deployment-path-report.json> \\
    --deployment-path-report <online/install_substrates/deployment-path-report.json> \\
    --deployment-path-report <airgap/use_existing/deployment-path-report.json> \\
    --deployment-path-report <airgap/install_substrates/deployment-path-report.json> \\
    [--operator-inputs-plan <operator-inputs-plan.json> ...] \\
    --product-readiness-report <agentsmith/product-readiness-report.json> \\
    --post-deploy-product-smoke-report <agentsmith/online-post-deploy-product-smoke-report.json> \\
    --post-deploy-product-smoke-report <agentsmith/airgap-post-deploy-product-smoke-report.json> \\
    --output-dir <dir>

This is the release-kit final GA aggregate. It consumes finalized path reports
and product-side reports only; it does not rerun producers.`;
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
    deploymentPathReports: [],
    operatorInputsPlans: [],
    postDeployProductSmokeReports: []
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--deploy-template-package':
        parsed.deployTemplatePackage = nextValue();
        break;
      case '--deployment-path-report':
        parsed.deploymentPathReports.push(nextValue());
        break;
      case '--operator-inputs-plan':
        parsed.operatorInputsPlans.push(nextValue());
        break;
      case '--product-readiness-report':
        parsed.productReadinessReport = nextValue();
        break;
      case '--post-deploy-product-smoke-report':
        parsed.postDeployProductSmokeReports.push(nextValue());
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
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
  if (parsed.deploymentPathReports.length !== DEPLOYMENT_PATHS.size) {
    cliFail(`expected exactly ${DEPLOYMENT_PATHS.size} --deployment-path-report inputs`);
  }
  if (parsed.postDeployProductSmokeReports.length === 0) {
    cliFail('missing required --post-deploy-product-smoke-report');
  }
  if (
    parsed.operatorInputsPlans.length > 0 &&
    parsed.operatorInputsPlans.length !== DEPLOYMENT_PATHS.size
  ) {
    cliFail(`expected exactly ${DEPLOYMENT_PATHS.size} --operator-inputs-plan inputs when provided`);
  }
  return parsed;
}

function findOutputDirArg(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.trim() === '' || value.startsWith('--')) {
      return undefined;
    }
    return path.resolve(value);
  }
  return undefined;
}

function findArgValue(argv, flag) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== flag) {
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

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function stableJson(value) {
  if (Array.isArray(value)) {
    return value.map(stableJson);
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableJson(value[key])])
    );
  }
  return value;
}

function canonicalDigest(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

function installParametersDigest({
  installInputDigest,
  resourceListDigest,
  applyResourceListDigest,
  effectiveNamespace
}) {
  return digestBuffer(Buffer.from([
    'agentsmith.substrate-install-parameters/v1',
    `substrate_install_inputs=${installInputDigest}`,
    `resource_list=${resourceListDigest}`,
    `apply_resource_list=${applyResourceListDigest}`,
    `effective_namespace=${effectiveNamespace}`
  ].join('\n')));
}

async function readBuffer(file, label) {
  try {
    return await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function readJson(file, label) {
  const buffer = await readBuffer(file, label);
  try {
    return {
      file,
      buffer,
      value: JSON.parse(buffer.toString('utf8')),
      digest: digestBuffer(buffer)
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

function rejectUnknownKeys(value, allowedKeys, label) {
  for (const key of Object.keys(value)) {
    if (!allowedKeys.has(key)) {
      fail(`${label} contains unknown field: ${key}`);
    }
  }
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

function requireKubernetesNamespace(value, label) {
  const namespace = requireString(value, label);
  if (namespace.length > 63 || !KUBERNETES_NAMESPACE_RE.test(namespace)) {
    fail(`${label} must be a Kubernetes namespace name`);
  }
  return namespace;
}

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function requirePositiveInteger(value, label) {
  const integer = requireInteger(value, label);
  if (integer <= 0) {
    fail(`${label} must be greater than zero`);
  }
  return integer;
}

function optionalString(value, label) {
  if (value === undefined) {
    return undefined;
  }
  return requireString(value, label);
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function requireIsoTimestamp(value, label) {
  const timestamp = requireString(value, label);
  const parsed = new Date(timestamp);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString() !== timestamp) {
    fail(`${label} must be an ISO timestamp`);
  }
  return timestamp;
}

function requireStringSet(value, label) {
  const items = requireArray(value, label);
  if (items.length === 0) {
    fail(`${label} must not be empty`);
  }
  const set = new Set();
  for (const [index, item] of items.entries()) {
    const text = requireString(item, `${label}[${index}]`);
    if (set.has(text)) {
      fail(`${label} must not contain duplicate values`);
    }
    set.add(text);
  }
  return set;
}

function requireSafePackageRelativePath(value, label) {
  const relative = requireString(value, label).replace(/\\/g, '/');
  if (
    path.posix.isAbsolute(relative) ||
    WINDOWS_DRIVE_RE.test(relative) ||
    URI_SCHEME_RE.test(relative)
  ) {
    fail(`${label} must be a package-relative path`);
  }
  const normalized = path.posix.normalize(relative);
  if (
    normalized !== relative ||
    normalized === '.' ||
    normalized === '..' ||
    normalized.startsWith('../') ||
    normalized === '.release-kit-internal' ||
    normalized.startsWith('.release-kit-internal/')
  ) {
    fail(`${label} must be a safe package-relative path`);
  }
  return normalized;
}

function sameSet(left, right) {
  return left.size === right.size && [...left].every((item) => right.has(item));
}

function requireGitSha(value, label) {
  const gitSha = requireString(value, label);
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function requireStatusPass(report, label) {
  if (report.status !== 'pass') {
    fail(`${label} status must be pass`);
  }
}

function requireStatusPassed(report, label) {
  if (report.status !== 'passed') {
    fail(`${label} status must be passed`);
  }
}

function requireSchema(report, schema, label) {
  if (report.schema !== schema && report.schema_version !== schema) {
    fail(`${label} schema must be ${schema}`);
  }
}

function reportSchema(report) {
  return report.schema ?? report.schema_version;
}

function requireNoFormalVerdict(report, label) {
  if (Object.prototype.hasOwnProperty.call(report, 'formal_verdict')) {
    fail(`${label} must not issue formal_verdict`);
  }
}

function normalizeRepoIdentity(value, label) {
  let remote = requireString(value, label).trim();
  if (remote.startsWith('git@github.com:')) {
    remote = `github.com/${remote.slice('git@github.com:'.length)}`;
  } else if (remote.startsWith('ssh://git@github.com/')) {
    remote = `github.com/${remote.slice('ssh://git@github.com/'.length)}`;
  } else {
    remote = remote.replace(/^https?:\/\//, '');
  }
  return remote.replace(/\.git$/, '').replace(/\/+$/, '').toLowerCase();
}

function requireArtifactUri(value, label) {
  const uri = requireString(value, label);
  if (!ARTIFACT_URI_RE.test(uri) || uri.toLowerCase().startsWith('file://')) {
    fail(`${label} must be an artifact URI`);
  }
  assertReportUriHasNoForbiddenContent(uri, label);
  return uri;
}

function requireExternalUri(value, label) {
  const uri = requireString(value, label);
  if (!ARTIFACT_URI_RE.test(uri) || uri.toLowerCase().startsWith('file://')) {
    fail(`${label} must be a URI`);
  }
  assertReportUriHasNoForbiddenContent(uri, label);
  return uri;
}

function requireGithubActionsRunUrl(value, label, { expectedRepo, runId, runAttempt }) {
  const uri = requireExternalUri(value, label);
  let parsed;
  try {
    parsed = new URL(uri);
  } catch {
    fail(`${label} must be a GitHub Actions run attempt URL`);
  }
  if (
    parsed.protocol !== 'https:' ||
    parsed.hostname !== 'github.com' ||
    parsed.search ||
    parsed.hash
  ) {
    fail(`${label} must be a GitHub Actions run attempt URL`);
  }
  const parts = parsed.pathname.split('/').filter(Boolean);
  if (
    parts.length !== 7 ||
    parts[2] !== 'actions' ||
    parts[3] !== 'runs' ||
    parts[5] !== 'attempts'
  ) {
    fail(`${label} must be a GitHub Actions run attempt URL`);
  }
  const repo = normalizeRepoIdentity(`github.com/${parts[0]}/${parts[1]}`, `${label}.repo`);
  if (repo !== expectedRepo) {
    fail(`${label} must be for canonical repo ${expectedRepo}`);
  }
  if (parts[4] !== runId) {
    fail(`${label} run id must match ${label.replace(/\.run_url$/, '.run_id')}`);
  }
  if (parts[6] !== runAttempt) {
    fail(`${label} run attempt must match ${label.replace(/\.run_url$/, '.run_attempt')}`);
  }
  return uri;
}

function requireProvenance(provenance, label) {
  const value = requireObject(provenance, label);
  const normalizedRemote = requireString(value.normalized_remote ?? value.producer_repo, `${label}.normalized_remote`);
  const commitSha = requireGitSha(value.commit_sha, `${label}.commit_sha`);
  const runId = requireString(value.run_id, `${label}.run_id`);
  const runAttempt = requireString(value.run_attempt, `${label}.run_attempt`);
  const runUrl = value.run_url === undefined
    ? undefined
    : requireExternalUri(value.run_url, `${label}.run_url`);
  const subjectSha = optionalString(value.subject_sha256, `${label}.subject_sha256`);
  const artifactSha = optionalString(value.artifact_sha256, `${label}.artifact_sha256`);
  const artifactUri = value.artifact_uri === undefined
    ? undefined
    : requireArtifactUri(value.artifact_uri, `${label}.artifact_uri`);
  if (subjectSha !== undefined) {
    requireDigest(subjectSha, `${label}.subject_sha256`);
  }
  if (artifactSha !== undefined) {
    requireDigest(artifactSha, `${label}.artifact_sha256`);
  }
  return {
    producer_repo: requireString(value.producer_repo ?? normalizedRemote, `${label}.producer_repo`),
    normalized_remote: normalizedRemote,
    commit_sha: commitSha,
    run_id: runId,
    run_attempt: runAttempt,
    run_url: runUrl,
    subject_name: optionalString(value.subject_name, `${label}.subject_name`),
    subject_sha256: subjectSha,
    artifact_sha256: artifactSha,
    artifact_uri: artifactUri
  };
}

function parseImageTag(image, label) {
  const withoutDigest = image.split('@sha256:')[0];
  const lastSlash = withoutDigest.lastIndexOf('/');
  const lastColon = withoutDigest.lastIndexOf(':');
  if (lastColon <= lastSlash) {
    fail(`${label}.image must include an immutable tag before its digest`);
  }
  return withoutDigest.slice(lastColon + 1);
}

function validateCanonicalRepoIdentity({ producerRepo, normalizedRemote, expectedRepo, label }) {
  const producer = normalizeRepoIdentity(producerRepo, `${label}.producer_repo`);
  const normalized = normalizeRepoIdentity(normalizedRemote, `${label}.normalized_remote`);
  if (producer !== normalized) {
    fail(`${label}.producer_repo must match ${label}.normalized_remote`);
  }
  if (normalized !== expectedRepo) {
    fail(`${label}.normalized_remote must be canonical repo ${expectedRepo}`);
  }
}

function validateImageSourceProvenance(image, expectedRepo) {
  const label = `release_contract.deploy_image_inventory.${image.id}.source_provenance`;
  const provenance = requireProvenance(image.source_provenance, label);
  validateCanonicalRepoIdentity({
    producerRepo: provenance.producer_repo,
    normalizedRemote: provenance.normalized_remote,
    expectedRepo,
    label
  });
  const imageTag = parseImageTag(image.image, `release_contract.deploy_image_inventory.${image.id}`);
  const provenanceTag = requireString(image.source_provenance.tag, `${label}.tag`);
  if (provenanceTag !== imageTag) {
    fail(`${label}.tag must match release_contract.deploy_image_inventory.${image.id}.image tag`);
  }
  if (provenance.artifact_sha256 !== image.digest) {
    fail(`${label}.artifact_sha256 must match release_contract.deploy_image_inventory.${image.id}.digest`);
  }
  const runUrl = requireGithubActionsRunUrl(image.source_provenance.run_url, `${label}.run_url`, {
    expectedRepo,
    runId: provenance.run_id,
    runAttempt: provenance.run_attempt
  });
  const artifactUri = requireArtifactUri(image.source_provenance.artifact_uri, `${label}.artifact_uri`);
  const runnerReleaseManifest = image.id === 'managed_runner'
    ? validateRunnerReleaseManifestProvenance({ image, provenance, label })
    : undefined;
  const runnerGaHandoff = image.id === 'managed_runner'
    ? validateRunnerGaHandoffProvenance({ image, provenance, label })
    : undefined;
  return {
    repo: expectedRepo,
    commit_sha: provenance.commit_sha,
    run_id: provenance.run_id,
    run_attempt: provenance.run_attempt,
    run_url: runUrl,
    image_ids: [image.id],
    image_tags: [imageTag],
    image_digests: [image.digest],
    freshness_key: [
      expectedRepo,
      provenance.commit_sha,
      imageTag,
      provenance.run_id,
      provenance.run_attempt,
      runUrl,
      artifactUri,
      image.digest,
      ...(runnerReleaseManifest ? [
        runnerReleaseManifest.artifact_uri,
        runnerReleaseManifest.subject_sha256,
        runnerReleaseManifest.artifact_sha256
      ] : []),
      ...(runnerGaHandoff ? [
        runnerGaHandoff.artifact_uri,
        runnerGaHandoff.manifest_input_sha256,
        runnerGaHandoff.report_sha256
      ] : [])
    ].join(':'),
    ...(runnerReleaseManifest ? { runner_release_manifest: runnerReleaseManifest } : {}),
    ...(runnerGaHandoff ? { runner_ga_handoff: runnerGaHandoff } : {}),
    provenance: {
      ...provenance,
      tag: provenanceTag,
      run_url: runUrl,
      artifact_uri: artifactUri,
      ...(runnerReleaseManifest ? { runner_release_manifest: runnerReleaseManifest } : {}),
      ...(runnerGaHandoff ? { runner_ga_handoff: runnerGaHandoff } : {})
    }
  };
}

function validateRunnerReleaseManifestProvenance({ image, provenance, label }) {
  if (provenance.normalized_remote !== RUNNER_REPO) {
    fail(`${label}.runner_release_manifest_uri is only valid for canonical repo ${RUNNER_REPO}`);
  }
  const manifestUri = requireArtifactUri(
    image.source_provenance.runner_release_manifest_uri,
    `${label}.runner_release_manifest_uri`
  );
  const match = manifestUri.match(RUNNER_RELEASE_MANIFEST_URI_RE);
  if (!match) {
    fail(`${label}.runner_release_manifest_uri must be the canonical runner release manifest artifact URI`);
  }
  if (match[1] !== provenance.run_id) {
    fail(`${label}.runner_release_manifest_uri run id must match ${label}.run_id`);
  }
  const subjectSha = requireDigest(
    image.source_provenance.runner_release_manifest_subject_sha256,
    `${label}.runner_release_manifest_subject_sha256`
  );
  const artifactSha = requireDigest(
    image.source_provenance.runner_release_manifest_artifact_sha256,
    `${label}.runner_release_manifest_artifact_sha256`
  );
  if (artifactSha !== subjectSha) {
    fail(`${label}.runner_release_manifest_artifact_sha256 must match ${label}.runner_release_manifest_subject_sha256`);
  }
  return {
    artifact_uri: manifestUri,
    subject_sha256: subjectSha,
    artifact_sha256: artifactSha,
    producer_repo: RUNNER_REPO,
    run_id: provenance.run_id,
    run_attempt: provenance.run_attempt
  };
}

function validateRunnerGaHandoffProvenance({ image, provenance, label }) {
  if (provenance.normalized_remote !== RUNNER_REPO) {
    fail(`${label}.runner_ga_handoff_uri is only valid for canonical repo ${RUNNER_REPO}`);
  }
  const handoffUri = requireArtifactUri(
    image.source_provenance.runner_ga_handoff_uri,
    `${label}.runner_ga_handoff_uri`
  );
  const match = handoffUri.match(RUNNER_GA_HANDOFF_URI_RE);
  if (!match) {
    fail(`${label}.runner_ga_handoff_uri must be the canonical runner GA handoff artifact URI`);
  }
  if (match[1] !== provenance.run_id) {
    fail(`${label}.runner_ga_handoff_uri run id must match ${label}.run_id`);
  }
  const manifestInputSha = requireDigest(
    image.source_provenance.runner_ga_handoff_manifest_input_sha256,
    `${label}.runner_ga_handoff_manifest_input_sha256`
  );
  const reportSha = requireDigest(
    image.source_provenance.runner_ga_handoff_report_sha256,
    `${label}.runner_ga_handoff_report_sha256`
  );
  return {
    artifact_uri: handoffUri,
    manifest_input_sha256: manifestInputSha,
    report_sha256: reportSha,
    producer_repo: RUNNER_REPO,
    run_id: provenance.run_id,
    run_attempt: provenance.run_attempt
  };
}

function requireProductArtifactProvenance(provenance, label, release, reportLabel) {
  const value = requireObject(provenance, label);
  const schema = requireString(value.schema_version ?? value.schema, `${label}.schema_version`);
  if (schema !== ARTIFACT_PROVENANCE_SCHEMA) {
    fail(`${label}.schema_version must be ${ARTIFACT_PROVENANCE_SCHEMA}`);
  }
  const kind = requireString(value.provenance_kind ?? value.kind, `${label}.provenance_kind`);
  if (kind !== ARTIFACT_PROVENANCE_KIND) {
    fail(`${label}.provenance_kind must be ${ARTIFACT_PROVENANCE_KIND}`);
  }

  const producerRepo = requireString(value.producer_repo, `${label}.producer_repo`);
  const normalizedRemote = requireString(value.normalized_remote, `${label}.normalized_remote`);
  if (
    normalizeRepoIdentity(producerRepo, `${label}.producer_repo`) !==
    normalizeRepoIdentity(normalizedRemote, `${label}.normalized_remote`)
  ) {
    fail(`${label}.producer_repo must match ${label}.normalized_remote`);
  }

  const provenanceSummary = requireProvenance(value, label);
  if (
    normalizeRepoIdentity(provenanceSummary.normalized_remote, `${label}.normalized_remote`) !== AGENTSMITH_REPO ||
    provenanceSummary.commit_sha !== release.git_sha
  ) {
    fail(`${reportLabel} provenance must match AgentSmith repo and git sha`);
  }
  const runUrl = requireGithubActionsRunUrl(value.run_url, `${label}.run_url`, {
    expectedRepo: AGENTSMITH_REPO,
    runId: provenanceSummary.run_id,
    runAttempt: provenanceSummary.run_attempt
  });

  const artifactUri = value.artifact_uri === undefined
    ? undefined
    : requireArtifactUri(value.artifact_uri, `${label}.artifact_uri`);
  if (
    provenanceSummary.subject_sha256 === undefined &&
    provenanceSummary.artifact_sha256 === undefined &&
    artifactUri === undefined
  ) {
    fail(`${label} must include subject_sha256, artifact_sha256, or artifact_uri`);
  }
  const generatedAt = requireIsoTimestamp(value.generated_at, `${label}.generated_at`);

  return {
    ...provenanceSummary,
    schema_version: schema,
    provenance_kind: kind,
    run_url: runUrl,
    artifact_uri: artifactUri,
    generated_at: generatedAt
  };
}

function requireTargetProfile(profile, expected, label) {
  const value = requireObject(profile, label);
  const tuple = requireString(value.value, `${label}.value`);
  if (tuple !== expected) {
    fail(`${label}.value must be ${expected}`);
  }
  const [targetCluster, substrateSource, distribution] = tuple.split('/');
  if (
    value.target_cluster !== targetCluster ||
    value.substrate_source !== substrateSource ||
    value.distribution !== distribution
  ) {
    fail(`${label} fields must match ${expected}`);
  }
  return value;
}

function releaseContractTargetProfileTuple(profile, label) {
  const targetCluster = requireString(profile.target_cluster, `${label}.target_cluster`);
  const substrateSource = requireString(profile.substrate_source, `${label}.substrate_source`);
  const distribution = requireString(profile.distribution, `${label}.distribution`);
  return `${targetCluster}/${substrateSource}/${distribution}`;
}

function validateReleaseContractTargetProfiles(contract) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const byTuple = new Map();
  for (const [index, rawProfile] of profiles.entries()) {
    const label = `release_contract.target_profiles[${index}]`;
    const profile = requireObject(rawProfile, label);
    const tuple = releaseContractTargetProfileTuple(profile, label);
    if (byTuple.has(tuple)) {
      fail(`release_contract.target_profiles contains duplicate target profile: ${tuple}`);
    }
    byTuple.set(tuple, profile);
    if (tuple.startsWith('kind_rehearsal/')) {
      fail(`release_contract.target_profiles must not include non-GA target profile ${tuple}`);
    }
    const expectedPrerequisites = GA_RELEASE_CONTRACT_TARGET_PROFILE_PREREQUISITES.get(tuple);
    if (!expectedPrerequisites) {
      fail(
        `release_contract.target_profiles contains non-GA target profile ${tuple}; expected exact GA set: ${GA_RELEASE_CONTRACT_TARGET_PROFILE_TUPLES.join(', ')}`
      );
    }
    if (typeof profile.required !== 'boolean') {
      fail(`${label}.required must be a boolean`);
    }
    if (profile.required !== true) {
      fail(`${label}.required must be true for final GA aggregate`);
    }
    const prerequisites = requireObject(profile.prerequisites, `${label}.prerequisites`);
    rejectUnknownKeys(
      prerequisites,
      GA_RELEASE_CONTRACT_TARGET_PROFILE_PREREQUISITE_KEYS,
      `${label}.prerequisites`
    );
    for (const [key, value] of Object.entries(prerequisites)) {
      if (value === 'kit_provided' || value === 'operator_or_kit_provided') {
        fail(
          `${label}.prerequisites.${key} must use GA install_substrates/kit_installed wording, not ${value}`
        );
      }
    }
    for (const [key, expectedValue] of Object.entries(expectedPrerequisites)) {
      if (requireString(prerequisites[key], `${label}.prerequisites.${key}`) !== expectedValue) {
        fail(`${label}.prerequisites.${key} must be ${expectedValue}`);
      }
    }
  }

  if (profiles.length !== GA_RELEASE_CONTRACT_TARGET_PROFILE_TUPLES.length) {
    fail(
      `release_contract.target_profiles must exactly cover GA target profiles: ${GA_RELEASE_CONTRACT_TARGET_PROFILE_TUPLES.join(', ')}`
    );
  }
  for (const tuple of GA_RELEASE_CONTRACT_TARGET_PROFILE_TUPLES) {
    if (!byTuple.has(tuple)) {
      fail(`release_contract.target_profiles missing GA target profile: ${tuple}`);
    }
  }
}

function reportStepsByName(report, label) {
  const steps = requireArray(report.steps, `${label}.steps`);
  const byName = new Map();
  for (const step of steps) {
    const value = requireObject(step, `${label}.steps[]`);
    const name = requireString(value.name, `${label}.steps[].name`);
    if (byName.has(name)) {
      fail(`${label} has duplicate step: ${name}`);
    }
    requireStatusPass(value, `${label} step ${name}`);
    requireDigest(value.report_digest, `${label} step ${name} report_digest`);
    byName.set(name, value);
  }
  return byName;
}

function validateImageRef(entry, label) {
  const value = requireObject(entry, label);
  const id = requireString(value.id, `${label}.id`);
  const image = requireString(value.image, `${label}.image`);
  const digest = requireDigest(value.digest, `${label}.digest`);
  if (!image.includes(`@${digest}`)) {
    fail(`${label}.image must include its digest`);
  }
  return {
    id,
    image,
    digest,
    source: typeof value.source === 'string' && value.source.trim() !== '' ? value.source : undefined,
    source_provenance: value.source_provenance
  };
}

function validateReleaseContract(contract, contractDigest) {
  requireSchema(contract, RELEASE_CONTRACT_SCHEMA, 'release contract');
  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const provenance = requireProvenance(contract.artifact_provenance, 'release_contract.artifact_provenance');
  if (provenance.normalized_remote !== AGENTSMITH_REPO || provenance.commit_sha !== gitSha) {
    fail('release contract provenance must match AgentSmith repo and git sha');
  }
  requireGithubActionsRunUrl(contract.artifact_provenance.run_url, 'release_contract.artifact_provenance.run_url', {
    expectedRepo: AGENTSMITH_REPO,
    runId: provenance.run_id,
    runAttempt: provenance.run_attempt
  });
  validateReleaseContractTargetProfiles(contract);

  const inventory = requireArray(contract.deploy_image_inventory, 'release_contract.deploy_image_inventory')
    .map((entry, index) => validateImageRef(entry, `release_contract.deploy_image_inventory[${index}]`));
  const byId = new Map(inventory.map((entry) => [entry.id, entry]));
  for (const id of REQUIRED_IMAGE_IDS) {
    if (!byId.has(id)) {
      fail(`release contract deploy_image_inventory missing required image id: ${id}`);
    }
  }
  if (byId.size !== inventory.length) {
    fail('release contract deploy_image_inventory must not contain duplicate image ids');
  }
  validateImageRef(contract.managed_runner_image, 'release_contract.managed_runner_image');

  return {
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: contractDigest,
    provenance,
    images: {
      app: byId.get('agentsmith_app'),
      runner: byId.get('managed_runner'),
      dependencies: ['llmup', 'afscp', 'asbcp'].map((id) => byId.get(id)),
      inventory
    },
    deploy_image_inventory: inventory
  };
}

async function gitOutput(args, label) {
  try {
    const { stdout } = await execFileAsync('git', args, {
      cwd: REPO_ROOT,
      timeout: 5000,
      maxBuffer: 1024 * 1024
    });
    return stdout.trim();
  } catch (error) {
    fail(`release-kit finalizer provenance requires ${label}: ${error.message}`);
  }
}

async function releaseKitFinalizerProvenance() {
  const envRepo = process.env.GITHUB_REPOSITORY
    ? `github.com/${process.env.GITHUB_REPOSITORY}`
    : undefined;
  const repo = envRepo ?? await gitOutput(['remote', 'get-url', 'origin'], 'GITHUB_REPOSITORY or git origin remote');
  const normalizedRepo = normalizeRepoIdentity(repo, 'release_kit_finalizer_provenance.normalized_remote');
  if (normalizedRepo !== RELEASE_KIT_REPO) {
    fail(`release_kit_finalizer_provenance.normalized_remote must be canonical repo ${RELEASE_KIT_REPO}`);
  }

  const commitSha = process.env.GITHUB_SHA
    ? requireGitSha(process.env.GITHUB_SHA, 'release_kit_finalizer_provenance.commit_sha')
    : requireGitSha(
      await gitOutput(['rev-parse', 'HEAD'], 'GITHUB_SHA or git HEAD'),
      'release_kit_finalizer_provenance.commit_sha'
    );
  const runId = process.env.GITHUB_RUN_ID && process.env.GITHUB_RUN_ID.trim() !== ''
    ? process.env.GITHUB_RUN_ID
    : 'local-git';
  const runAttempt = process.env.GITHUB_RUN_ATTEMPT && process.env.GITHUB_RUN_ATTEMPT.trim() !== ''
    ? process.env.GITHUB_RUN_ATTEMPT
    : '0';
  const runUrl = process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
    ? requireGithubActionsRunUrl(
      `${process.env.GITHUB_SERVER_URL.replace(/\/+$/, '')}/${process.env.GITHUB_REPOSITORY}/actions/runs/${runId}/attempts/${runAttempt}`,
      'release_kit_finalizer_provenance.run_url',
      {
        expectedRepo: RELEASE_KIT_REPO,
        runId,
        runAttempt
      }
    )
    : undefined;

  return {
    repo: RELEASE_KIT_REPO,
    commit_sha: commitSha,
    run_id: runId,
    run_attempt: runAttempt,
    ...(runUrl ? { run_url: runUrl } : {}),
    freshness_key: [
      RELEASE_KIT_REPO,
      commitSha,
      runId,
      runAttempt,
      runUrl ?? 'local-git'
    ].join(':'),
    provenance: {
      producer_repo: RELEASE_KIT_REPO,
      normalized_remote: RELEASE_KIT_REPO,
      commit_sha: commitSha,
      run_id: runId,
      run_attempt: runAttempt,
      ...(runUrl ? { run_url: runUrl } : {}),
      source: process.env.GITHUB_SHA ? 'github_actions_env' : 'git_worktree'
    }
  };
}

async function buildCanonicalRepos(release) {
  const imageById = new Map(release.deploy_image_inventory.map((image) => [image.id, image]));
  const repos = [];

  for (const spec of CANONICAL_REPO_SPECS) {
    if (spec.finalizer) {
      repos.push(await releaseKitFinalizerProvenance());
      continue;
    }

    const imageSummaries = [];
    for (const imageId of spec.image_ids) {
      const image = imageById.get(imageId);
      if (!image) {
        fail(`release contract deploy_image_inventory missing required image id: ${imageId}`);
      }
      imageSummaries.push(validateImageSourceProvenance(image, spec.repo));
    }

    const [first] = imageSummaries;
    for (const summary of imageSummaries.slice(1)) {
      if (
        summary.commit_sha !== first.commit_sha ||
        summary.run_id !== first.run_id ||
        summary.run_attempt !== first.run_attempt ||
        summary.run_url !== first.run_url
      ) {
        fail(`canonical repo ${spec.repo} source provenance must use one commit/run across images`);
      }
    }

    repos.push({
      repo: spec.repo,
      commit_sha: first.commit_sha,
      run_id: first.run_id,
      run_attempt: first.run_attempt,
      run_url: first.run_url,
      image_ids: imageSummaries.flatMap((summary) => summary.image_ids).sort(),
      image_tags: imageSummaries.flatMap((summary) => summary.image_tags).sort(),
      image_digests: imageSummaries.flatMap((summary) => summary.image_digests).sort(),
      freshness_key: [
        spec.repo,
        first.commit_sha,
        first.run_id,
        first.run_attempt,
        first.run_url,
        ...imageSummaries.map((summary) => summary.provenance.artifact_uri).sort(),
        ...imageSummaries.flatMap((summary) => summary.image_tags).sort(),
        ...imageSummaries.flatMap((summary) => summary.image_digests).sort(),
        ...imageSummaries.flatMap((summary) => summary.runner_release_manifest
          ? [
            summary.runner_release_manifest.artifact_uri,
            summary.runner_release_manifest.subject_sha256,
            summary.runner_release_manifest.artifact_sha256
          ]
          : []).sort(),
        ...imageSummaries.flatMap((summary) => summary.runner_ga_handoff
          ? [
            summary.runner_ga_handoff.artifact_uri,
            summary.runner_ga_handoff.manifest_input_sha256,
            summary.runner_ga_handoff.report_sha256
          ]
          : []).sort()
      ].join(':'),
      ...(first.runner_release_manifest ? { runner_release_manifest: first.runner_release_manifest } : {}),
      ...(first.runner_ga_handoff ? { runner_ga_handoff: first.runner_ga_handoff } : {}),
      provenance: Object.fromEntries(
        imageSummaries.map((summary) => [summary.image_ids[0], summary.provenance])
      )
    });
  }

  const expectedRepos = new Set(CANONICAL_REPO_SPECS.map((spec) => spec.repo));
  const actualRepos = new Set(repos.map((entry) => entry.repo));
  if (!sameSet(actualRepos, expectedRepos)) {
    fail('ga release canonical_repos must exactly cover the six canonical repos');
  }
  if (actualRepos.size !== repos.length) {
    fail('ga release canonical_repos must not contain duplicate repos');
  }

  return repos.sort((a, b) => a.repo.localeCompare(b.repo));
}

function validateDeployTemplatePackage(descriptor, contract, descriptorDigest) {
  requireSchema(descriptor, DEPLOY_TEMPLATE_SCHEMA, 'deploy template package');
  requireDigest(descriptor.package_sha256, 'deploy_template_package.package_sha256');
  requireDigest(descriptor.manifest_sha256, 'deploy_template_package.manifest_sha256');
  const provenance = requireProvenance(descriptor.artifact_provenance, 'deploy_template_package.artifact_provenance');
  requireGithubActionsRunUrl(
    descriptor.artifact_provenance.run_url,
    'deploy_template_package.artifact_provenance.run_url',
    {
      expectedRepo: AGENTSMITH_REPO,
      runId: provenance.run_id,
      runAttempt: provenance.run_attempt
    }
  );
  const contractDescriptor = requireObject(contract.deploy_template_package, 'release_contract.deploy_template_package');
  if (descriptor.package_sha256 !== contractDescriptor.package_sha256) {
    fail('deploy template package package_sha256 must match release contract');
  }
  if (descriptor.manifest_sha256 !== contractDescriptor.manifest_sha256) {
    fail('deploy template package manifest_sha256 must match release contract');
  }
  const descriptorRequiredIds = requireStringSet(
    descriptor.required_image_ids,
    'deploy_template_package.required_image_ids'
  );
  const contractRequiredIds = requireStringSet(
    contractDescriptor.required_image_ids,
    'release_contract.deploy_template_package.required_image_ids'
  );
  const inventoryIds = new Set(
    requireArray(contract.deploy_image_inventory, 'release_contract.deploy_image_inventory')
      .map((entry, index) => requireString(
        requireObject(entry, `release_contract.deploy_image_inventory[${index}]`).id,
        `release_contract.deploy_image_inventory[${index}].id`
      ))
  );
  if (!sameSet(contractRequiredIds, inventoryIds)) {
    fail('release_contract.deploy_template_package.required_image_ids must exactly match release_contract.deploy_image_inventory ids');
  }
  if (!sameSet(descriptorRequiredIds, contractRequiredIds) || !sameSet(descriptorRequiredIds, inventoryIds)) {
    fail('deploy template package required_image_ids must exactly match release contract deploy_image_inventory ids');
  }
  return {
    deploy_template_package_digest: descriptorDigest,
    package_sha256: descriptor.package_sha256,
    manifest_sha256: descriptor.manifest_sha256,
    provenance
  };
}

function commonReportChecks(report, label, release) {
  requireStatusPass(report, label);
  if (requireString(report.release_id, `${label}.release_id`) !== release.release_id) {
    fail(`${label}.release_id must match release contract`);
  }
  if (requireGitSha(report.git_sha, `${label}.git_sha`) !== release.git_sha) {
    fail(`${label}.git_sha must match release contract`);
  }
  if (requireDigest(report.release_contract_digest, `${label}.release_contract_digest`) !== release.release_contract_digest) {
    fail(`${label}.release_contract_digest must match release contract digest`);
  }
}

function requireExactStringSet(value, expectedValues, label) {
  const actual = requireStringSet(value, label);
  const expected = new Set(expectedValues);
  if (!sameSet(actual, expected)) {
    fail(`${label} must exactly match ${expectedValues.join(', ')}`);
  }
  return [...expectedValues];
}

function validateProductRuntimeObservationPolicy(runtimeReadiness) {
  const label = 'product_readiness_report.runtime_readiness.observation_policy';
  const policy = requireObject(runtimeReadiness.observation_policy, label);
  if (requireString(policy.step_id, `${label}.step_id`) !== 'gate-release') {
    fail(`${label}.step_id must be gate-release`);
  }
  if (requireString(policy.gate_id, `${label}.gate_id`) !== 'gate-release') {
    fail(`${label}.gate_id must be gate-release`);
  }
  if (requireString(policy.theme, `${label}.theme`) !== PRODUCT_RUNTIME_READINESS_THEME) {
    fail(`${label}.theme must be ${PRODUCT_RUNTIME_READINESS_THEME}`);
  }
  if (requireString(policy.backoff, `${label}.backoff`) !== PRODUCT_RUNTIME_READINESS_BACKOFF) {
    fail(`${label}.backoff must be ${PRODUCT_RUNTIME_READINESS_BACKOFF}`);
  }
  const intervalMs = requireArray(policy.interval_ms, `${label}.interval_ms`)
    .map((entry, index) => requireInteger(entry, `${label}.interval_ms[${index}]`));
  if (JSON.stringify(intervalMs) !== JSON.stringify(PRODUCT_RUNTIME_READINESS_INTERVAL_MS)) {
    fail(`${label}.interval_ms must be ${PRODUCT_RUNTIME_READINESS_INTERVAL_MS.join(', ')}`);
  }
  const evidenceFocus = requireExactStringSet(
    policy.evidence_focus,
    PRODUCT_RUNTIME_READINESS_EVIDENCE_FOCUS,
    `${label}.evidence_focus`
  );
  const convergence = requireObject(policy.state_convergence, `${label}.state_convergence`);
  const expectedSurfaces = Object.keys(PRODUCT_RUNTIME_READINESS_CONVERGENCE);
  if (!sameSet(new Set(Object.keys(convergence)), new Set(expectedSurfaces))) {
    fail(`${label}.state_convergence must cover ${expectedSurfaces.join(', ')}`);
  }
  const stateConvergence = {};
  for (const surface of expectedSurfaces) {
    const surfaceLabel = `${label}.state_convergence.${surface}`;
    const states = requireObject(convergence[surface], surfaceLabel);
    const expectedStates = Object.keys(PRODUCT_RUNTIME_READINESS_CONVERGENCE[surface]);
    if (!sameSet(new Set(Object.keys(states)), new Set(expectedStates))) {
      fail(`${surfaceLabel} must cover ${expectedStates.join(', ')}`);
    }
    stateConvergence[surface] = {};
    for (const state of expectedStates) {
      const text = requireString(states[state], `${surfaceLabel}.${state}`);
      const requiredSnippet = PRODUCT_RUNTIME_READINESS_CONVERGENCE[surface][state];
      if (!text.includes(requiredSnippet)) {
        fail(`${surfaceLabel}.${state} must describe ${requiredSnippet}`);
      }
      stateConvergence[surface][state] = text;
    }
  }

  return {
    step_id: 'gate-release',
    gate_id: 'gate-release',
    theme: PRODUCT_RUNTIME_READINESS_THEME,
    backoff: PRODUCT_RUNTIME_READINESS_BACKOFF,
    interval_ms: [...PRODUCT_RUNTIME_READINESS_INTERVAL_MS],
    evidence_focus: evidenceFocus,
    state_convergence: stateConvergence
  };
}

function validateProductRuntimeReadiness(report) {
  const runtimeReadiness = requireObject(
    report.runtime_readiness,
    'product_readiness_report.runtime_readiness'
  );
  const observationPolicy = validateProductRuntimeObservationPolicy(runtimeReadiness);
  const filesRestore = requireObject(
    runtimeReadiness.files_restore_continuation,
    'product_readiness_report.runtime_readiness.files_restore_continuation'
  );
  const runtimePath = requirePortableRelativePath(
    filesRestore.path,
    'product_readiness_report.runtime_readiness.files_restore_continuation.path'
  );
  if (runtimePath !== PRODUCT_RUNTIME_READINESS_DETAILS_PATH) {
    fail('product_readiness_report.runtime_readiness.files_restore_continuation.path must point to the Files restore continuation runtime readiness details');
  }
  const runtimeDigest = requireDigest(
    filesRestore.sha256,
    'product_readiness_report.runtime_readiness.files_restore_continuation.sha256'
  );
  if (
    requireString(
      filesRestore.schema_version,
      'product_readiness_report.runtime_readiness.files_restore_continuation.schema_version'
    ) !== PRODUCT_RUNTIME_READINESS_SCHEMA
  ) {
    fail(`product_readiness_report.runtime_readiness.files_restore_continuation.schema_version must be ${PRODUCT_RUNTIME_READINESS_SCHEMA}`);
  }
  if (
    requireString(
      filesRestore.theme,
      'product_readiness_report.runtime_readiness.files_restore_continuation.theme'
    ) !== PRODUCT_RUNTIME_READINESS_THEME
  ) {
    fail(`product_readiness_report.runtime_readiness.files_restore_continuation.theme must be ${PRODUCT_RUNTIME_READINESS_THEME}`);
  }
  const classification = requireString(
    filesRestore.classification,
    'product_readiness_report.runtime_readiness.files_restore_continuation.classification'
  );
  if (classification === 'stability_blocker') {
    fail('product_readiness_report.runtime_readiness.files_restore_continuation.classification stability_blocker blocks final GA verdict; resolve consecutive focused gate runtime readiness failures before rerunning --ga-release');
  }
  if (!['clean_pass', 'runtime_flake'].includes(classification)) {
    fail('product_readiness_report.runtime_readiness.files_restore_continuation.classification must be clean_pass or runtime_flake for a passed product readiness report');
  }
  const outcome = requireString(
    filesRestore.outcome,
    'product_readiness_report.runtime_readiness.files_restore_continuation.outcome'
  );
  const signalsCount = requireInteger(
    filesRestore.signals_count,
    'product_readiness_report.runtime_readiness.files_restore_continuation.signals_count'
  );
  const callSummariesCount = requireInteger(
    filesRestore.call_summaries_count,
    'product_readiness_report.runtime_readiness.files_restore_continuation.call_summaries_count'
  );
  if (classification === 'clean_pass' && (signalsCount !== 0 || callSummariesCount !== 0)) {
    fail('product_readiness_report.runtime_readiness.files_restore_continuation.classification clean_pass must not include runtime readiness signals or call summaries');
  }
  if (classification === 'runtime_flake' && (signalsCount < 3 || callSummariesCount < 3)) {
    fail('product_readiness_report.runtime_readiness.files_restore_continuation.classification runtime_flake must cover API, pod-manager, and ASBCP call summaries');
  }

  const referencedFiles = requireArray(
    report.referenced_files,
    'product_readiness_report.referenced_files'
  );
  const runtimeReference = referencedFiles
    .map((entry, index) => requireObject(entry, `product_readiness_report.referenced_files[${index}]`))
    .find((entry) => entry.id === 'runtime_readiness_details');
  if (!runtimeReference) {
    fail('product_readiness_report.referenced_files must include runtime_readiness_details');
  }
  if (
    requirePortableRelativePath(
      runtimeReference.path,
      'product_readiness_report.referenced_files.runtime_readiness_details.path'
    ) !== runtimePath
  ) {
    fail('product_readiness_report.referenced_files.runtime_readiness_details.path must match runtime readiness path');
  }
  if (
    requireDigest(
      runtimeReference.sha256,
      'product_readiness_report.referenced_files.runtime_readiness_details.sha256'
    ) !== runtimeDigest
  ) {
    fail('product_readiness_report.referenced_files.runtime_readiness_details.sha256 must match runtime readiness digest');
  }

  return {
    observation_policy: observationPolicy,
    files_restore_continuation: {
      path: runtimePath,
      sha256: runtimeDigest,
      schema_version: PRODUCT_RUNTIME_READINESS_SCHEMA,
      theme: PRODUCT_RUNTIME_READINESS_THEME,
      classification,
      outcome,
      signals_count: signalsCount,
      call_summaries_count: callSummariesCount
    }
  };
}

function validateProductReadiness(report, reportDigest, release) {
  requireSchema(report, PRODUCT_READY_SCHEMA, 'product readiness report');
  commonReportChecks(report, 'product readiness report', release);
  const provenance = requireProductArtifactProvenance(
    report.artifact_provenance,
    'product_readiness_report.artifact_provenance',
    release,
    'product readiness'
  );
  const runtimeReadiness = validateProductRuntimeReadiness(report);
  return { report_digest: reportDigest, provenance, runtime_readiness: runtimeReadiness };
}

function productSmokeEntries(smokeResults) {
  const value = requireObject(smokeResults, 'post_deploy_product_smoke.smoke_results');
  return Object.entries(value).map(([id, entry]) => ({
    id: requireString(id, 'post_deploy_product_smoke.smoke_results key'),
    value: requireObject(entry, `post_deploy_product_smoke.smoke_results.${id}`),
    label: `post_deploy_product_smoke.smoke_results.${id}`
  }));
}

function requireProductSmokeSchemaVersion(report) {
  if (Object.prototype.hasOwnProperty.call(report, 'schema')) {
    fail('post_deploy_product_smoke.schema must not be present; use schema_version');
  }
  const schemaVersion = requireString(
    report.schema_version,
    'post_deploy_product_smoke.schema_version'
  );
  if (schemaVersion !== PRODUCT_SMOKE_SCHEMA) {
    fail(`post_deploy_product_smoke.schema_version must be ${PRODUCT_SMOKE_SCHEMA}`);
  }
  return schemaVersion;
}

function rejectProductSmokeLegacyFields(report) {
  for (const field of PRODUCT_SMOKE_LEGACY_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(report, field)) {
      fail(`post_deploy_product_smoke.${field} must not be present`);
    }
  }
}

function requirePortableRelativePath(value, label) {
  const relative = requireString(value, label);
  if (
    relative.includes('\\') ||
    path.posix.isAbsolute(relative) ||
    path.win32.isAbsolute(relative)
  ) {
    fail(`${label} must be a portable relative path`);
  }
  if (relative.includes('//')) {
    fail(`${label} must not contain empty, current, or parent segments`);
  }
  const parts = relative.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not contain empty, current, or parent segments`);
  }
  return relative;
}

function validateProductSmokeReleaseContract(value, release) {
  const binding = requireObject(value, 'post_deploy_product_smoke.release_contract');
  rejectUnknownKeys(
    binding,
    PRODUCT_SMOKE_RELEASE_CONTRACT_KEYS,
    'post_deploy_product_smoke.release_contract'
  );

  const inputSha256 = requireDigest(
    binding.input_sha256,
    'post_deploy_product_smoke.release_contract.input_sha256'
  );
  if (inputSha256 !== release.release_contract_digest) {
    fail('post_deploy_product_smoke.release_contract.input_sha256 must match release contract digest');
  }

  const releaseId = requireString(
    binding.release_id,
    'post_deploy_product_smoke.release_contract.release_id'
  );
  if (releaseId !== release.release_id) {
    fail('post_deploy_product_smoke.release_contract.release_id must match release contract');
  }

  const gitSha = requireGitSha(
    binding.git_sha,
    'post_deploy_product_smoke.release_contract.git_sha'
  );
  if (gitSha !== release.git_sha) {
    fail('post_deploy_product_smoke.release_contract.git_sha must match release contract');
  }

  return {
    path: requirePortableRelativePath(
      binding.path,
      'post_deploy_product_smoke.release_contract.path'
    ),
    input_sha256: inputSha256,
    release_id: releaseId,
    git_sha: gitSha
  };
}

function validateProductSmokeSource(value) {
  const source = requireObject(value, 'post_deploy_product_smoke.source');
  rejectUnknownKeys(source, PRODUCT_SMOKE_SOURCE_KEYS, 'post_deploy_product_smoke.source');
  const productFlowsPath = requirePortableRelativePath(
    source.product_flows_path,
    'post_deploy_product_smoke.source.product_flows_path'
  );
  const productFlowsSha256 = requireDigest(
    source.product_flows_sha256,
    'post_deploy_product_smoke.source.product_flows_sha256'
  );
  const aggregateSchemaVersion = requireString(
    source.aggregate_schema_version,
    'post_deploy_product_smoke.source.aggregate_schema_version'
  );
  requireEquals(
    aggregateSchemaVersion,
    PRODUCT_FLOWS_AGGREGATE_SCHEMA,
    'post_deploy_product_smoke.source.aggregate_schema_version'
  );
  const aggregateProducer = requireString(
    source.aggregate_producer,
    'post_deploy_product_smoke.source.aggregate_producer'
  );
  requireEquals(
    aggregateProducer,
    PRODUCT_FLOWS_AGGREGATE_PRODUCER,
    'post_deploy_product_smoke.source.aggregate_producer'
  );
  const aggregateGeneratedAt = source.aggregate_generated_at === undefined
    ? undefined
    : requireIsoTimestamp(
      source.aggregate_generated_at,
      'post_deploy_product_smoke.source.aggregate_generated_at'
    );
  const aggregateCommand = requireString(
    source.aggregate_command,
    'post_deploy_product_smoke.source.aggregate_command'
  );
  requireEquals(
    aggregateCommand,
    PRODUCT_FLOWS_AGGREGATE_COMMAND,
    'post_deploy_product_smoke.source.aggregate_command'
  );
  return {
    product_flows_path: productFlowsPath,
    product_flows_sha256: productFlowsSha256,
    aggregate_schema_version: aggregateSchemaVersion,
    aggregate_producer: aggregateProducer,
    ...(aggregateGeneratedAt ? { aggregate_generated_at: aggregateGeneratedAt } : {}),
    aggregate_command: aggregateCommand
  };
}

function validateProductSmokeFileBinding(value, label) {
  const binding = requireObject(value, label);
  rejectUnknownKeys(binding, PRODUCT_SMOKE_FILE_BINDING_KEYS, label);
  return {
    path: requirePortableRelativePath(binding.path, `${label}.path`),
    sha256: requireDigest(binding.sha256, `${label}.sha256`)
  };
}

function validateProductSmokeDeploymentTarget(value) {
  const target = requireObject(value, 'post_deploy_product_smoke.deployment_target');
  rejectUnknownKeys(
    target,
    PRODUCT_SMOKE_DEPLOYMENT_TARGET_KEYS,
    'post_deploy_product_smoke.deployment_target'
  );
  const runnerPublicApiBaseUrl = optionalString(
    target.runner_public_api_base_url,
    'post_deploy_product_smoke.deployment_target.runner_public_api_base_url'
  );
  return {
    profile: requireString(
      target.profile,
      'post_deploy_product_smoke.deployment_target.profile'
    ),
    public_base_url: requireString(
      target.public_base_url,
      'post_deploy_product_smoke.deployment_target.public_base_url'
    ),
    api_base_url: requireString(
      target.api_base_url,
      'post_deploy_product_smoke.deployment_target.api_base_url'
    ),
    ...(runnerPublicApiBaseUrl ? { runner_public_api_base_url: runnerPublicApiBaseUrl } : {}),
    site_env: validateProductSmokeFileBinding(
      target.site_env,
      'post_deploy_product_smoke.deployment_target.site_env'
    ),
    substrate_truth: validateProductSmokeFileBinding(
      target.substrate_truth,
      'post_deploy_product_smoke.deployment_target.substrate_truth'
    )
  };
}

function validateProductSmokeProviderNeutralProof(value, label) {
  const proof = requireObject(value.proof, `${label}.proof`);
  rejectUnknownKeys(proof, PRODUCT_SMOKE_PROVIDER_NEUTRAL_PROOF_KEYS, `${label}.proof`);
  requireEquals(
    requireString(proof.endpoint_type, `${label}.proof.endpoint_type`),
    'custom',
    `${label}.proof.endpoint_type`
  );
  requireEquals(
    requireString(proof.provider_family, `${label}.proof.provider_family`),
    'custom',
    `${label}.proof.provider_family`
  );
  requireEquals(
    requireString(proof.upstream_protocol, `${label}.proof.upstream_protocol`),
    'openai_chat_completions',
    `${label}.proof.upstream_protocol`
  );
  requireEquals(
    requireString(proof.credential_type, `${label}.proof.credential_type`),
    'api_key',
    `${label}.proof.credential_type`
  );
  requireEquals(
    requireString(proof.success_path, `${label}.proof.success_path`),
    'provider_neutral_endpoint',
    `${label}.proof.success_path`
  );
  return {
    endpoint_type: proof.endpoint_type,
    provider_family: proof.provider_family,
    upstream_protocol: proof.upstream_protocol,
    credential_type: proof.credential_type,
    success_path: proof.success_path
  };
}

function validateProductSmoke(report, reportDigest, release) {
  const schemaVersion = requireProductSmokeSchemaVersion(report);
  rejectProductSmokeLegacyFields(report);
  const releaseContract = validateProductSmokeReleaseContract(report.release_contract, release);
  const source = validateProductSmokeSource(report.source);
  const deploymentTarget = validateProductSmokeDeploymentTarget(report.deployment_target);
  requireEquals(
    requireString(report.producer, 'post_deploy_product_smoke.producer'),
    PRODUCT_SMOKE_PRODUCER,
    'post_deploy_product_smoke.producer'
  );
  requireEquals(
    requireString(report.owner, 'post_deploy_product_smoke.owner'),
    PRODUCT_SMOKE_OWNER,
    'post_deploy_product_smoke.owner'
  );
  requireEquals(
    requireString(report.repo, 'post_deploy_product_smoke.repo'),
    AGENTSMITH_REPO,
    'post_deploy_product_smoke.repo'
  );
  requireStatusPassed(report, 'post-deploy product smoke report');
  const failures = requireArray(report.failures, 'post_deploy_product_smoke.failures');
  if (failures.length !== 0) {
    fail('post_deploy_product_smoke.failures must be empty');
  }

  const expectedIds = new Set(REQUIRED_PRODUCT_SMOKE_IDS);
  const seenIds = new Set();
  const sourceEvidencePaths = {};
  const sourceEvidenceDigests = {};
  let providerNeutralEndpointProof = null;
  for (const entry of productSmokeEntries(report.smoke_results)) {
    const spec = CANONICAL_PRODUCT_SMOKE_SPECS[entry.id];
    rejectUnknownKeys(
      entry.value,
      entry.id === 'provider_neutral_endpoint'
        ? PRODUCT_SMOKE_PROVIDER_NEUTRAL_RESULT_KEYS
        : PRODUCT_SMOKE_RESULT_KEYS,
      entry.label
    );
    if (seenIds.has(entry.id)) {
      fail(`post-deploy product smoke duplicate canonical smoke id: ${entry.id}`);
    }
    seenIds.add(entry.id);
    if (!spec || !expectedIds.has(entry.id)) {
      fail(`post-deploy product smoke contains unknown canonical smoke id: ${entry.id}`);
    }
    requireEquals(
      requireString(entry.value.id, `${entry.label}.id`),
      entry.id,
      `${entry.label}.id`
    );
    requireEquals(
      requireString(entry.value.source_flow, `${entry.label}.source_flow`),
      spec.source_flow,
      `${entry.label}.source_flow`
    );
    if (entry.value.status !== 'passed') {
      fail(`${entry.label}.status must be passed`);
    }
    const sourceEvidencePath = requireString(
      entry.value.source_evidence_path,
      `${entry.label}.source_evidence_path`
    );
    requireEquals(
      sourceEvidencePath,
      spec.source_evidence_path,
      `${entry.label}.source_evidence_path`
    );
    const sourceEvidenceDigest = requireDigest(
      entry.value.source_evidence_sha256,
      `${entry.label}.source_evidence_sha256`
    );
    if (entry.id === 'provider_neutral_endpoint') {
      providerNeutralEndpointProof = validateProductSmokeProviderNeutralProof(entry.value, entry.label);
    }
    sourceEvidencePaths[entry.id] = sourceEvidencePath;
    sourceEvidenceDigests[entry.id] = sourceEvidenceDigest;
  }
  for (const id of REQUIRED_PRODUCT_SMOKE_IDS) {
    if (!seenIds.has(id)) {
      fail(`post-deploy product smoke missing canonical smoke id: ${id}`);
    }
  }
  if (!providerNeutralEndpointProof) {
    fail('post_deploy_product_smoke.smoke_results.provider_neutral_endpoint.proof must be present');
  }

  return {
    report_digest: reportDigest,
    schema: schemaVersion,
    producer: report.producer,
    owner: report.owner,
    repo: report.repo,
    release_contract: releaseContract,
    source,
    deployment_target: deploymentTarget,
    canonical_smoke_ids: [...REQUIRED_PRODUCT_SMOKE_IDS],
    source_evidence_paths: Object.fromEntries(
      Object.entries(sourceEvidencePaths).sort(([left], [right]) => left.localeCompare(right))
    ),
    source_evidence_sha256: Object.fromEntries(
      Object.entries(sourceEvidenceDigests).sort(([left], [right]) => left.localeCompare(right))
    ),
    provider_neutral_endpoint_proof: providerNeutralEndpointProof
  };
}

function validateProductSmokeDeploymentPathBinding(productSmokeSummary, deploymentPaths) {
  const smokeProfile = productSmokeSummary.deployment_target.profile;
  const matchingPath = deploymentPaths.find((entry) => entry.target_profile === smokeProfile);
  if (!matchingPath) {
    fail('post_deploy_product_smoke.deployment_target.profile must match one finalized deployment path target_profile');
  }
  const pathSubstrateTruthDigest = requireDigest(
    matchingPath.substrate_truth_digest,
    'deployment path substrate_truth_digest'
  );
  if (
    productSmokeSummary.deployment_target.substrate_truth.sha256 !==
    pathSubstrateTruthDigest
  ) {
    fail('post_deploy_product_smoke.deployment_target.substrate_truth.sha256 must match finalized deployment path substrate truth digest');
  }
  return {
    operator_path: matchingPath.operator_path,
    target_profile: matchingPath.target_profile,
    distribution: matchingPath.operator_path.split('/')[0],
    deployment_path_report_digest: matchingPath.report_digest,
    deployment_path_substrate_truth_digest: pathSubstrateTruthDigest
  };
}

function validateProductSmokeCoverage(productSmokeSummaries, deploymentPaths) {
  const reports = productSmokeSummaries.map((summary) => ({
    ...summary,
    deployment_path_binding: validateProductSmokeDeploymentPathBinding(summary, deploymentPaths)
  }));
  const seenReportDigests = new Set();
  const seenOperatorPaths = new Set();
  const seenSiteEnvDigests = new Set();
  const seenProductFlowsDigests = new Set();
  const byDistribution = new Map();
  for (const report of reports) {
    if (seenReportDigests.has(report.report_digest)) {
      fail(`duplicate post_deploy_product_smoke report digest: ${report.report_digest}`);
    }
    seenReportDigests.add(report.report_digest);
    const operatorPath = report.deployment_path_binding.operator_path;
    if (seenOperatorPaths.has(operatorPath)) {
      fail(`duplicate post_deploy_product_smoke deployment path: ${operatorPath}`);
    }
    seenOperatorPaths.add(operatorPath);
    const siteEnvDigest = report.deployment_target.site_env.sha256;
    if (seenSiteEnvDigests.has(siteEnvDigest)) {
      fail(`duplicate post_deploy_product_smoke site env digest: ${siteEnvDigest}`);
    }
    seenSiteEnvDigests.add(siteEnvDigest);
    const productFlowsDigest = report.source.product_flows_sha256;
    if (seenProductFlowsDigests.has(productFlowsDigest)) {
      fail(`duplicate post_deploy_product_smoke product flows digest: ${productFlowsDigest}`);
    }
    seenProductFlowsDigests.add(productFlowsDigest);
    const distribution = report.deployment_path_binding.distribution;
    if (!byDistribution.has(distribution)) {
      byDistribution.set(distribution, []);
    }
    byDistribution.get(distribution).push({
      report_digest: report.report_digest,
      operator_path: report.deployment_path_binding.operator_path,
      target_profile: report.deployment_path_binding.target_profile,
      deployment_path_report_digest: report.deployment_path_binding.deployment_path_report_digest
    });
  }
  for (const distribution of REQUIRED_PRODUCT_SMOKE_DISTRIBUTIONS) {
    if (!byDistribution.has(distribution)) {
      fail(`post_deploy_product_smoke coverage must include at least one ${distribution} deployment target`);
    }
  }

  const coveredDistributions = [...byDistribution.keys()].sort();
  return {
    required_distributions: [...REQUIRED_PRODUCT_SMOKE_DISTRIBUTIONS],
    covered_distributions: coveredDistributions,
    canonical_smoke_ids: [...REQUIRED_PRODUCT_SMOKE_IDS],
    acceptance_coverage: PRODUCT_SMOKE_ACCEPTANCE_COVERAGE,
    covered_operator_paths: reports
      .map((report) => report.deployment_path_binding.operator_path)
      .sort(),
    covered_target_profiles: reports
      .map((report) => report.deployment_path_binding.target_profile)
      .sort(),
    reports_by_distribution: Object.fromEntries(
      [...byDistribution.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([distribution, entries]) => [
          distribution,
          entries.sort((left, right) => left.operator_path.localeCompare(right.operator_path))
        ])
    ),
    reports
  };
}

function requireEquals(actual, expected, label) {
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
}

function validateSourceEvidenceLedger(report, requirement, requiredSteps, steps, operatorPath) {
  const ledger = requireObject(report.source_evidence, 'deployment_path_report.source_evidence');
  requireSchema(ledger, SOURCE_EVIDENCE_SCHEMA, 'deployment_path_report.source_evidence');
  requireEquals(
    requireString(ledger.operator_path, 'deployment_path_report.source_evidence.operator_path'),
    operatorPath,
    'deployment_path_report.source_evidence.operator_path'
  );
  requireTargetProfile(
    ledger.target_profile,
    requirement.targetProfile,
    'deployment_path_report.source_evidence.target_profile'
  );

  const finalizer = requireObject(
    ledger.finalizer,
    'deployment_path_report.source_evidence.finalizer'
  );
  requireEquals(
    requireString(finalizer.schema, 'deployment_path_report.source_evidence.finalizer.schema'),
    FINALIZER_SCHEMA,
    'deployment_path_report.source_evidence.finalizer.schema'
  );
  requireEquals(
    requireString(finalizer.tool, 'deployment_path_report.source_evidence.finalizer.tool'),
    FINALIZER_TOOL,
    'deployment_path_report.source_evidence.finalizer.tool'
  );
  requireEquals(
    requireString(finalizer.mode, 'deployment_path_report.source_evidence.finalizer.mode'),
    FINALIZER_MODE,
    'deployment_path_report.source_evidence.finalizer.mode'
  );

  const expectedGate = DEPLOYMENT_GATE_BY_SOURCE.get(requirement.source);
  const gate = requireObject(
    ledger.source_deployment_gate_report,
    'deployment_path_report.source_evidence.source_deployment_gate_report'
  );
  requireEquals(
    requireString(gate.schema, 'deployment_path_report.source_evidence.source_deployment_gate_report.schema'),
    expectedGate.schema,
    'deployment_path_report.source_evidence.source_deployment_gate_report.schema'
  );
  requireEquals(
    requireString(gate.scope, 'deployment_path_report.source_evidence.source_deployment_gate_report.scope'),
    expectedGate.scope,
    'deployment_path_report.source_evidence.source_deployment_gate_report.scope'
  );
  requireDigest(gate.digest, 'deployment_path_report.source_evidence.source_deployment_gate_report.digest');

  const ledgerSteps = requireArray(
    ledger.finalized_steps,
    'deployment_path_report.source_evidence.finalized_steps'
  );
  if (ledgerSteps.length !== steps.size) {
    fail('deployment_path_report.source_evidence.finalized_steps must match steps[] length');
  }
  const ledgerStepsByName = new Map();
  for (const [index, rawStep] of ledgerSteps.entries()) {
    const step = requireObject(
      rawStep,
      `deployment_path_report.source_evidence.finalized_steps[${index}]`
    );
    const name = requireString(
      step.name,
      `deployment_path_report.source_evidence.finalized_steps[${index}].name`
    );
    if (ledgerStepsByName.has(name)) {
      fail(`deployment_path_report.source_evidence.finalized_steps contains duplicate step: ${name}`);
    }
    ledgerStepsByName.set(name, step);
  }

  for (const stepName of requiredSteps) {
    const reportStep = steps.get(stepName);
    const ledgerStep = ledgerStepsByName.get(stepName);
    if (!ledgerStep) {
      fail(`deployment_path_report.source_evidence missing finalized step: ${stepName}`);
    }
    const expected = SOURCE_STEP_REPORTS.get(stepName);
    requireEquals(
      requireString(ledgerStep.source_step, `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_step`),
      expected.source_step,
      `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_step`
    );
    requireEquals(
      requireString(ledgerStep.source_schema, `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_schema`),
      expected.source_schema,
      `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_schema`
    );
    requireEquals(
      requireString(ledgerStep.source_scope, `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_scope`),
      expected.source_scope,
      `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_scope`
    );
    if (
      requireDigest(
        ledgerStep.report_digest,
        `deployment_path_report.source_evidence.finalized_steps.${stepName}.report_digest`
      ) !== reportStep.report_digest
    ) {
      fail(`deployment_path_report.source_evidence.finalized_steps ${stepName} report_digest must match steps[]`);
    }
  }

  if (requirement.source === 'airgap') {
    const offline = requireObject(report.airgap_offline, 'deployment_path_report.airgap_offline');
    const airgap = requireObject(ledger.airgap, 'deployment_path_report.source_evidence.airgap');
    if (
      requireDigest(
        airgap.bundle_manifest_digest,
        'deployment_path_report.source_evidence.airgap.bundle_manifest_digest'
      ) !== offline.bundle_manifest_digest
    ) {
      fail('deployment_path_report.source_evidence.airgap.bundle_manifest_digest must match airgap_offline');
    }
    if (
      requireDigest(
        airgap.bundle_check_report_digest,
        'deployment_path_report.source_evidence.airgap.bundle_check_report_digest'
      ) !== steps.get('bundle-check').report_digest
    ) {
      fail('deployment_path_report.source_evidence.airgap.bundle_check_report_digest must match bundle-check step');
    }
    requireDigest(
      airgap.image_map_input_sha256,
      'deployment_path_report.source_evidence.airgap.image_map_input_sha256'
    );
  } else if (Object.prototype.hasOwnProperty.call(ledger, 'airgap')) {
    fail('deployment_path_report.source_evidence.airgap is only accepted for airgap paths');
  }

  if (requirement.installSubstrates) {
    const install = requireObject(
      ledger.substrate_install,
      'deployment_path_report.source_evidence.substrate_install'
    );
    if (
      requireDigest(
        install.report_digest,
        'deployment_path_report.source_evidence.substrate_install.report_digest'
      ) !== steps.get('substrate-install').report_digest
    ) {
      fail('deployment_path_report.source_evidence.substrate_install.report_digest must match substrate-install step');
    }
    requireEquals(
      requireString(install.schema, 'deployment_path_report.source_evidence.substrate_install.schema'),
      SUBSTRATE_INSTALL_SCHEMA,
      'deployment_path_report.source_evidence.substrate_install.schema'
    );
    requireEquals(
      requireString(install.scope, 'deployment_path_report.source_evidence.substrate_install.scope'),
      SUBSTRATE_INSTALL_SCOPE,
      'deployment_path_report.source_evidence.substrate_install.scope'
    );
    requireDigest(
      install.output_substrate_truth_digest,
      'deployment_path_report.source_evidence.substrate_install.output_substrate_truth_digest'
    );
    const installInputDigest = requireDigest(
      install.substrate_install_inputs_sha256,
      'deployment_path_report.source_evidence.substrate_install.substrate_install_inputs_sha256'
    );
    const resourceListDigest = requireDigest(
      install.resource_list_sha256,
      'deployment_path_report.source_evidence.substrate_install.resource_list_sha256'
    );
    const applyResourceListDigest = requireDigest(
      install.apply_resource_list_sha256,
      'deployment_path_report.source_evidence.substrate_install.apply_resource_list_sha256'
    );
    const effectiveNamespace = requireKubernetesNamespace(
      install.effective_namespace,
      'deployment_path_report.source_evidence.substrate_install.effective_namespace'
    );
    const installParametersSha256 = requireDigest(
      install.install_parameters_sha256,
      'deployment_path_report.source_evidence.substrate_install.install_parameters_sha256'
    );
    requireDigest(
      install.target_prerequisites_sha256,
      'deployment_path_report.source_evidence.substrate_install.target_prerequisites_sha256'
    );
    if (
      installParametersSha256 !==
      installParametersDigest({
        installInputDigest,
        resourceListDigest,
        applyResourceListDigest,
        effectiveNamespace
      })
    ) {
      fail('deployment_path_report.source_evidence.substrate_install.install_parameters_sha256 must bind install input, resource list, apply artifact, and effective namespace');
    }
    const serviceCount = requireInteger(
      install.service_count,
      'deployment_path_report.source_evidence.substrate_install.service_count'
    );
    if (serviceCount === 0) {
      fail('deployment_path_report.source_evidence.substrate_install.service_count must be greater than zero');
    }
    const resourceCount = requirePositiveInteger(
      install.resource_count,
      'deployment_path_report.source_evidence.substrate_install.resource_count'
    );
    const proofCounts = [
      ['kubectl_resource_count', 'kubectl_resource_count'],
      ['namespace_scope_allowed_resource_count', 'namespace_scope_allowed_resource_count'],
      ['collision_checked_resource_count', 'collision_checked_resource_count'],
      ['kubectl_apply_applied_resource_count', 'kubectl_apply_applied_resource_count']
    ];
    for (const [field, labelSuffix] of proofCounts) {
      if (
        requirePositiveInteger(
          install[field],
          `deployment_path_report.source_evidence.substrate_install.${labelSuffix}`
        ) !== resourceCount
      ) {
        fail(`deployment_path_report.source_evidence.substrate_install.${labelSuffix} must match resource_count`);
      }
    }
  } else if (Object.prototype.hasOwnProperty.call(ledger, 'substrate_install')) {
    fail('deployment_path_report.source_evidence.substrate_install is only accepted for install_substrates paths');
  }

  return ledger;
}

function validateMaterializedSubstrateInstallLedger({ ledger, materializedSummary, requirement }) {
  if (!requirement.installSubstrates) {
    return;
  }
  const install = requireObject(
    ledger.substrate_install,
    'deployment_path_report.source_evidence.substrate_install'
  );
  const installSummary = requireObject(
    materializedSummary?.substrateInstallSummary,
    'materialized substrate install report summary'
  );
  const inputDigests = requireObject(
    installSummary.input_digests,
    'materialized substrate install report input_digests'
  );
  const proof = requireObject(
    installSummary.proof,
    'materialized substrate install report proof'
  );
  const inputBindings = requireObject(
    installSummary.input_bindings,
    'materialized substrate install report input_bindings'
  );
  if (
    requireDigest(
      install.output_substrate_truth_digest,
      'deployment_path_report.source_evidence.substrate_install.output_substrate_truth_digest'
    ) !== installSummary.output_substrate_truth_digest
  ) {
    fail('deployment_path_report.source_evidence.substrate_install.output_substrate_truth_digest must match materialized substrate install report');
  }
  if (
    requireInteger(
      install.service_count,
      'deployment_path_report.source_evidence.substrate_install.service_count'
    ) !== installSummary.service_count
  ) {
    fail('deployment_path_report.source_evidence.substrate_install.service_count must match materialized substrate install report');
  }
  const comparisons = [
    ['substrate_install_inputs_sha256', 'input_sha256'],
    ['resource_list_sha256', 'resource_list_sha256'],
    ['apply_resource_list_sha256', 'apply_resource_list_sha256'],
    ['install_parameters_sha256', 'install_parameters_sha256']
  ];
  for (const [ledgerField, reportField] of comparisons) {
    if (
      requireDigest(
        install[ledgerField],
        `deployment_path_report.source_evidence.substrate_install.${ledgerField}`
      ) !== inputDigests[reportField]
    ) {
      fail(`deployment_path_report.source_evidence.substrate_install.${ledgerField} must match materialized substrate install report`);
    }
  }
  if (
    requireDigest(
      install.target_prerequisites_sha256,
      'deployment_path_report.source_evidence.substrate_install.target_prerequisites_sha256'
    ) !== inputBindings.target_prerequisites_sha256
  ) {
    fail('deployment_path_report.source_evidence.substrate_install.target_prerequisites_sha256 must match materialized substrate install report');
  }
  if (
    requireKubernetesNamespace(
      install.effective_namespace,
      'deployment_path_report.source_evidence.substrate_install.effective_namespace'
    ) !== inputDigests.effective_namespace
  ) {
    fail('deployment_path_report.source_evidence.substrate_install.effective_namespace must match materialized substrate install report');
  }
  const proofComparisons = [
    ['resource_count', 'resource_count'],
    ['kubectl_resource_count', 'kubectl_resource_count'],
    ['namespace_scope_allowed_resource_count', 'namespace_scope_allowed_resource_count'],
    ['collision_checked_resource_count', 'collision_checked_resource_count'],
    ['kubectl_apply_applied_resource_count', 'kubectl_apply_applied_resource_count']
  ];
  for (const [ledgerField, reportField] of proofComparisons) {
    if (
      requirePositiveInteger(
        install[ledgerField],
        `deployment_path_report.source_evidence.substrate_install.${ledgerField}`
      ) !== proof[reportField]
    ) {
      fail(`deployment_path_report.source_evidence.substrate_install.${ledgerField} must match materialized substrate install report`);
    }
  }
}

function safeSourceEvidencePath(value, label) {
  const relative = requireString(value, label);
  if (relative.includes('\\') || path.isAbsolute(relative)) {
    fail(`${label} must be a portable relative path`);
  }
  const parts = relative.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not contain empty, current, or parent segments`);
  }
  if (parts[0] !== SOURCE_EVIDENCE_DIR) {
    fail(`${label} must be under ${SOURCE_EVIDENCE_DIR}/`);
  }
  return relative;
}

function sourceEvidenceManifestPathSet(entries) {
  const paths = new Set();
  for (const [index, entry] of entries.entries()) {
    const relative = safeSourceEvidencePath(
      entry.path,
      `finalizer_manifest.source_evidence_files[${index}].path`
    );
    if (paths.has(relative)) {
      fail(`finalizer_manifest.source_evidence_files contains duplicate path: ${relative}`);
    }
    paths.add(relative);
  }
  return paths;
}

async function listSourceEvidenceFiles(sourceDir, currentDir = sourceDir) {
  let entries;
  try {
    entries = await fs.readdir(currentDir, { withFileTypes: true });
  } catch (error) {
    fail(`cannot read source evidence directory: ${error.message}`);
  }

  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(currentDir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await listSourceEvidenceFiles(sourceDir, fullPath));
      continue;
    }
    if (entry.isFile()) {
      files.push(
        `${SOURCE_EVIDENCE_DIR}/${path.relative(sourceDir, fullPath).split(path.sep).join('/')}`
      );
    }
  }
  return files;
}

async function validateSourceEvidenceDirectoryClosure(reportDir, manifestPaths) {
  const actualFiles = await listSourceEvidenceFiles(
    path.join(reportDir, SOURCE_EVIDENCE_DIR)
  );
  const actualFileSet = new Set(actualFiles);
  for (const relative of actualFiles) {
    if (!manifestPaths.has(relative)) {
      fail(`source evidence directory contains unlisted file: ${relative}`);
    }
  }
  for (const relative of manifestPaths) {
    if (!actualFileSet.has(relative)) {
      fail(`source evidence directory is missing manifest-listed file: ${relative}`);
    }
  }
}

function sourceEvidenceKey(kind, step) {
  return `${kind}:${step ?? ''}`;
}

function expectedSourceEvidenceFiles({ ledger, requirement }) {
  const gate = requireObject(
    ledger.source_deployment_gate_report,
    'deployment_path_report.source_evidence.source_deployment_gate_report'
  );
  const expected = [
    {
      kind: 'source_deployment_gate',
      sha256: gate.digest,
      schema: gate.schema,
      scope: gate.scope
    }
  ];

  for (const step of ledger.finalized_steps) {
    expected.push({
      kind: 'finalized_step_report',
      step: step.name,
      sha256: step.report_digest,
      schema: step.source_schema,
      scope: step.source_scope
    });
  }

  if (requirement.source === 'airgap') {
    const airgap = requireObject(ledger.airgap, 'deployment_path_report.source_evidence.airgap');
    expected.push({
      kind: 'airgap_bundle_manifest',
      sha256: airgap.bundle_manifest_digest,
      schema: AIRGAP_BUNDLE_MANIFEST_SCHEMA,
      scope: null
    });
    expected.push({
      kind: 'airgap_image_map',
      sha256: airgap.image_map_input_sha256,
      schema: IMAGE_MAP_SCHEMA,
      scope: IMAGE_MAP_SCOPE
    });
  }

  return expected;
}

async function validateSourceEvidenceMaterialFile({ reportDir, entry, expected }) {
  if (requireString(entry.kind, 'finalizer_manifest.source_evidence_files[].kind') !== expected.kind) {
    fail('finalizer_manifest.source_evidence_files entry type must match path report source evidence');
  }
  if (expected.step !== undefined) {
    if (
      requireString(entry.step, `finalizer_manifest.source_evidence_files.${expected.kind}.step`) !==
      expected.step
    ) {
      fail('finalizer_manifest.source_evidence_files finalized step must match path report source evidence');
    }
  } else if (Object.prototype.hasOwnProperty.call(entry, 'step')) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} must not include step`);
  }

  const relative = safeSourceEvidencePath(
    entry.path,
    `finalizer_manifest.source_evidence_files.${expected.kind}.path`
  );
  if (
    requireDigest(entry.sha256, `finalizer_manifest.source_evidence_files.${expected.kind}.sha256`) !==
    expected.sha256
  ) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} sha256 must match path report source evidence`);
  }
  if (
    requireString(entry.schema, `finalizer_manifest.source_evidence_files.${expected.kind}.schema`) !==
    expected.schema
  ) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} schema must match path report source evidence`);
  }
  if (entry.scope !== expected.scope) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} scope must match path report source evidence`);
  }

  const materialInput = await readJson(
    path.join(reportDir, relative),
    `source evidence file ${relative}`
  );
  if (materialInput.digest !== expected.sha256) {
    fail(`source evidence file ${relative} sha256 must match finalizer manifest`);
  }
  const materialReport = requireObject(materialInput.value, `source evidence file ${relative}`);
  scanReportForForbiddenContent({
    value: materialReport,
    buffer: materialInput.buffer,
    label: `source evidence file ${relative}`
  });
  if (reportSchema(materialReport) !== expected.schema) {
    fail(`source evidence file ${relative} schema must match finalizer manifest`);
  }
  if (expected.scope !== null && materialReport.scope !== expected.scope) {
    fail(`source evidence file ${relative} scope must match finalizer manifest`);
  }
  return materialInput;
}

async function validateFinalizerManifest({
  pathInput,
  report,
  ledger,
  operatorPath,
  requirement,
  release,
  deployTemplate
}) {
  const reportDir = path.dirname(pathInput.file);
  const manifestInput = await readJson(
    path.join(reportDir, FINALIZER_MANIFEST_FILE),
    'deployment path finalizer manifest'
  );
  scanReportForForbiddenContent({
    value: manifestInput.value,
    buffer: manifestInput.buffer,
    label: 'deployment path finalizer manifest'
  });
  const manifest = requireObject(manifestInput.value, 'deployment path finalizer manifest');
  rejectUnknownKeys(manifest, FINALIZER_MANIFEST_KEYS, 'finalizer_manifest');
  requireSchema(manifest, FINALIZER_MANIFEST_SCHEMA, 'deployment path finalizer manifest');
  if (
    requireString(manifest.tool, 'finalizer_manifest.tool') !== FINALIZER_MANIFEST_TOOL
  ) {
    fail(`finalizer_manifest.tool must be ${FINALIZER_MANIFEST_TOOL}`);
  }
  if (requireString(manifest.operator_path, 'finalizer_manifest.operator_path') !== operatorPath) {
    fail('finalizer_manifest.operator_path must match deployment path report');
  }
  if (
    requireString(manifest.deployment_profile, 'finalizer_manifest.deployment_profile') !==
    report.target_profile.value
  ) {
    fail('finalizer_manifest.deployment_profile must match deployment path report');
  }
  if (
    requireDigest(manifest.release_contract_digest, 'finalizer_manifest.release_contract_digest') !==
    release.release_contract_digest
  ) {
    fail('finalizer_manifest.release_contract_digest must match release contract digest');
  }
  if (
    requireDigest(manifest.template_digest, 'finalizer_manifest.template_digest') !==
    deployTemplate.deploy_template_package_digest
  ) {
    fail('finalizer_manifest.template_digest must match deploy template package digest');
  }
  if (
    requireDigest(manifest.path_report_sha256, 'finalizer_manifest.path_report_sha256') !==
    pathInput.digest
  ) {
    fail('finalizer_manifest.path_report_sha256 must match deployment path report bytes');
  }
  requireIsoTimestamp(manifest.created_at, 'finalizer_manifest.created_at');

  const actualEntries = requireArray(
    manifest.source_evidence_files,
    'finalizer_manifest.source_evidence_files'
  );
  for (const [index, rawEntry] of actualEntries.entries()) {
    const entry = requireObject(rawEntry, `finalizer_manifest.source_evidence_files[${index}]`);
    rejectUnknownKeys(
      entry,
      FINALIZER_MANIFEST_SOURCE_EVIDENCE_KEYS,
      `finalizer_manifest.source_evidence_files[${index}]`
    );
  }
  const manifestPaths = sourceEvidenceManifestPathSet(actualEntries);
  await validateSourceEvidenceDirectoryClosure(reportDir, manifestPaths);
  const expectedEntries = expectedSourceEvidenceFiles({ ledger, requirement });
  if (actualEntries.length !== expectedEntries.length) {
    fail('finalizer_manifest.source_evidence_files must exactly cover path report source evidence');
  }

  const actualByKey = new Map();
  for (const [index, rawEntry] of actualEntries.entries()) {
    const entry = requireObject(rawEntry, `finalizer_manifest.source_evidence_files[${index}]`);
    const kind = requireString(entry.kind, `finalizer_manifest.source_evidence_files[${index}].kind`);
    const step = kind === 'finalized_step_report'
      ? requireString(entry.step, `finalizer_manifest.source_evidence_files[${index}].step`)
      : undefined;
    const key = sourceEvidenceKey(kind, step);
    if (actualByKey.has(key)) {
      fail(`finalizer_manifest.source_evidence_files contains duplicate entry: ${key}`);
    }
    actualByKey.set(key, entry);
  }

  const materializedSourceEvidence = {
    sourceInputsByStep: new Map(),
    evidenceIndex: {
      finalizer_manifest: {
        path: FINALIZER_MANIFEST_FILE,
        digest: manifestInput.digest,
        created_at: manifest.created_at,
        path_report_sha256: manifest.path_report_sha256
      },
      source_evidence_files: actualEntries.map((entry) => ({
        kind: entry.kind,
        ...(entry.step === undefined ? {} : { step: entry.step }),
        path: entry.path,
        sha256: entry.sha256,
        schema: entry.schema,
        scope: entry.scope
      }))
    }
  };

  for (const expected of expectedEntries) {
    const key = sourceEvidenceKey(expected.kind, expected.step);
    const entry = actualByKey.get(key);
    if (!entry) {
      fail(`finalizer_manifest.source_evidence_files missing entry: ${key}`);
    }
    const materialInput = await validateSourceEvidenceMaterialFile({ reportDir, entry, expected });
    if (expected.kind === 'source_deployment_gate') {
      materializedSourceEvidence.sourceDeploymentGateInput = materialInput;
    } else if (expected.kind === 'finalized_step_report') {
      materializedSourceEvidence.sourceInputsByStep.set(expected.step, materialInput);
    } else if (expected.kind === 'airgap_bundle_manifest') {
      materializedSourceEvidence.airgapBundleManifestInput = materialInput;
    } else if (expected.kind === 'airgap_image_map') {
      materializedSourceEvidence.airgapImageMapInput = materialInput;
    }
  }

  return materializedSourceEvidence;
}

function validateAirgapOfflineSummary({ report, steps, operatorPath }) {
  const offline = requireObject(report.airgap_offline, 'deployment_path_report.airgap_offline');
  const proofScope = requireString(
    offline.proof_scope,
    'deployment_path_report.airgap_offline.proof_scope'
  );
  if (proofScope !== AIRGAP_OFFLINE_PROOF_SCOPE) {
    fail(
      `deployment_path_report.airgap_offline.proof_scope must be ${AIRGAP_OFFLINE_PROOF_SCOPE}`
    );
  }
  if (offline.public_internet_downloads_observed_by_release_kit !== false) {
    fail(`deployment path ${operatorPath} reports public internet downloads observed by release-kit`);
  }
  if (
    Object.prototype.hasOwnProperty.call(offline, 'public_internet_downloads') &&
    offline.public_internet_downloads !== false
  ) {
    fail('deployment_path_report.airgap_offline.public_internet_downloads legacy field must be false');
  }
  if (offline.release_kit_inputs_package_local_digest_bound !== true) {
    fail(
      'deployment_path_report.airgap_offline.release_kit_inputs_package_local_digest_bound must be true'
    );
  }
  if (offline.release_kit_inputs_and_tools_package_local_or_bundle_local_digest_bound !== true) {
    fail(
      'deployment_path_report.airgap_offline.release_kit_inputs_and_tools_package_local_or_bundle_local_digest_bound must be true'
    );
  }

  const proofLimitations = requireArray(
    offline.proof_limitations,
    'deployment_path_report.airgap_offline.proof_limitations'
  );
  const limitationSet = new Set(
    proofLimitations.map((limitation, index) =>
      requireString(limitation, `deployment_path_report.airgap_offline.proof_limitations[${index}]`)
    )
  );
  for (const requiredLimitation of [
    'does_not_prove_physical_network_isolation',
    'does_not_prove_absence_of_public_internet_access_outside_release_kit'
  ]) {
    if (!limitationSet.has(requiredLimitation)) {
      fail(
        `deployment_path_report.airgap_offline.proof_limitations must include ${requiredLimitation}`
      );
    }
  }

  const bundleManifestDigest = requireDigest(
    offline.bundle_manifest_digest,
    'deployment_path_report.airgap_offline.bundle_manifest_digest'
  );
  const imageLoadReportDigest = requireDigest(
    offline.image_load_report_digest,
    'deployment_path_report.airgap_offline.image_load_report_digest'
  );
  if (imageLoadReportDigest !== steps.get('image-load').report_digest) {
    fail('deployment_path_report.airgap_offline.image_load_report_digest must match image-load step');
  }
  const offlineRenderReportDigest = requireDigest(
    offline.offline_render_report_digest,
    'deployment_path_report.airgap_offline.offline_render_report_digest'
  );
  if (offlineRenderReportDigest !== steps.get('offline-render-check').report_digest) {
    fail('deployment_path_report.airgap_offline.offline_render_report_digest must match offline-render-check step');
  }

  return {
    proof_scope: proofScope,
    public_internet_downloads_observed_by_release_kit: false,
    release_kit_inputs_package_local_digest_bound: true,
    release_kit_inputs_and_tools_package_local_or_bundle_local_digest_bound: true,
    bundle_manifest_digest: bundleManifestDigest,
    image_load_report_digest: imageLoadReportDigest,
    offline_render_report_digest: offlineRenderReportDigest
  };
}

function deploymentPathSubstrateTruthDigest(sourceInputsByStep) {
  const targetPreflightInput = sourceInputsByStep.get('target-preflight');
  if (!targetPreflightInput) {
    fail('deployment path source evidence must include materialized target-preflight report');
  }
  const targetPreflightReport = requireObject(
    targetPreflightInput.value,
    'target-preflight step report'
  );
  const substrateTruth = requireObject(
    targetPreflightReport.substrate_truth,
    'target-preflight step report.substrate_truth'
  );
  return requireDigest(
    substrateTruth.input_sha256,
    'target-preflight step report.substrate_truth.input_sha256'
  );
}

async function validateDeploymentPathReport(pathInput, release, deployTemplate) {
  const report = pathInput.value;
  const reportDigest = pathInput.digest;
  requireSchema(report, PATH_REPORT_SCHEMA, 'deployment path report');
  if (requireString(report.scope, 'deployment_path_report.scope') !== PATH_REPORT_SCOPE) {
    fail(`deployment_path_report.scope must be ${PATH_REPORT_SCOPE}`);
  }
  if (report.readiness !== false) {
    fail('deployment path report readiness must be false');
  }
  requireNoFormalVerdict(report, 'deployment path report');
  commonReportChecks(report, 'deployment path report', release);
  if (
    requireDigest(report.deploy_template_package_digest, 'deployment_path_report.deploy_template_package_digest') !==
    deployTemplate.deploy_template_package_digest
  ) {
    fail('deployment path report deploy_template_package_digest must match descriptor digest');
  }

  const operatorPath = requireString(report.operator_path, 'deployment_path_report.operator_path');
  const requirement = DEPLOYMENT_PATHS.get(operatorPath);
  if (!requirement) {
    fail(`unexpected deployment operator path: ${operatorPath}`);
  }
  requireTargetProfile(report.target_profile, requirement.targetProfile, 'deployment_path_report.target_profile');

  const steps = reportStepsByName(report, `deployment path ${operatorPath}`);
  const requiredSteps = sourceValidation.deploymentPathReportStepNames(requirement);
  for (const step of requiredSteps) {
    if (!steps.has(step)) {
      fail(`deployment path ${operatorPath} missing required step: ${step}`);
    }
  }
  if (steps.size !== requiredSteps.length) {
    fail(`deployment path ${operatorPath} steps must exactly match required steps`);
  }

  if (requirement.installSubstrates) {
    const confirmation = requireObject(report.install_substrates_confirmation, 'deployment_path_report.install_substrates_confirmation');
    if (confirmation.confirmed !== true) {
      fail(`deployment path ${operatorPath} requires explicit install_substrates confirmation`);
    }
    requireString(confirmation.operator_run_id, 'deployment_path_report.install_substrates_confirmation.operator_run_id');
    if (
      requireDigest(
        confirmation.substrate_install_report_digest,
        'deployment_path_report.install_substrates_confirmation.substrate_install_report_digest'
      ) !== steps.get('substrate-install').report_digest
    ) {
      fail('deployment_path_report.install_substrates_confirmation.substrate_install_report_digest must match substrate-install step');
    }
  }

  const airgapOffline = requirement.source === 'airgap'
    ? validateAirgapOfflineSummary({ report, steps, operatorPath })
    : null;

  const ledger = validateSourceEvidenceLedger(report, requirement, requiredSteps, steps, operatorPath);
  const materializedSourceEvidence = await validateFinalizerManifest({
    pathInput,
    report,
    ledger,
    operatorPath,
    requirement,
    release,
    deployTemplate
  });
  const materializedSummary = sourceValidation.validateMaterializedDeploymentPathSourceEvidence({
    operatorPath,
    release: {
      ...release,
      deploy_template_package_digest: deployTemplate.deploy_template_package_digest
    },
    ...materializedSourceEvidence,
    installOperatorRunId: report.install_substrates_confirmation?.operator_run_id
  });
  validateMaterializedSubstrateInstallLedger({
    ledger,
    materializedSummary,
    requirement
  });
  const substrateTruthDigest = deploymentPathSubstrateTruthDigest(
    materializedSourceEvidence.sourceInputsByStep
  );

  return {
    operator_path: operatorPath,
    target_profile: report.target_profile.value,
    report_digest: reportDigest,
    substrate_truth_digest: substrateTruthDigest,
    report_file: path.resolve(pathInput.file),
    steps: [...steps.keys()],
    source_evidence_index: materializedSourceEvidence.evidenceIndex,
    ...(airgapOffline ? { airgap_offline: airgapOffline } : {})
  };
}

async function validateOperatorInputsMaterialRef({
  plan,
  packageRoot,
  key,
  expectedDigest,
  expectedDigestLabel,
  operatorPath
}) {
  return validateOperatorInputsFileRef({
    plan,
    packageRoot,
    key,
    expectedDigest,
    expectedDigestLabel,
    operatorPath
  });
}

async function validateOperatorInputsFileRef({
  plan,
  packageRoot,
  key,
  expectedDigest,
  expectedDigestLabel,
  operatorPath,
  executable = false
}) {
  const inputRefs = requireObject(plan.input_refs, 'operator_inputs_plan.input_refs');
  if (!Object.prototype.hasOwnProperty.call(inputRefs, key)) {
    fail(`operator_inputs_plan.input_refs.${key} is required for ${operatorPath}`);
  }
  const ref = requireObject(inputRefs[key], `operator_inputs_plan.input_refs.${key}`);
  if (requireString(ref.kind, `operator_inputs_plan.input_refs.${key}.kind`) !== 'file') {
    fail(`operator_inputs_plan.input_refs.${key}.kind must be file`);
  }
  const relativePath = requireSafePackageRelativePath(
    ref.path,
    `operator_inputs_plan.input_refs.${key}.path`
  );
  const absolutePath = requireString(
    ref.absolute_path,
    `operator_inputs_plan.input_refs.${key}.absolute_path`
  );
  if (path.resolve(packageRoot, relativePath) !== path.resolve(absolutePath)) {
    fail(`operator_inputs_plan.input_refs.${key}.path must bind absolute_path for ${operatorPath}`);
  }

  let stat;
  try {
    stat = await fs.lstat(absolutePath);
  } catch (error) {
    fail(`cannot read operator-inputs ${key} for ${operatorPath}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`operator_inputs_plan.input_refs.${key}.absolute_path must not be a symlink for ${operatorPath}`);
  }
  if (!stat.isFile()) {
    fail(`operator_inputs_plan.input_refs.${key}.absolute_path must point to a file for ${operatorPath}`);
  }
  if (executable && (stat.mode & 0o111) === 0) {
    fail(`operator_inputs_plan.input_refs.${key}.absolute_path must be executable for ${operatorPath}`);
  }

  const declaredDigest = requireDigest(
    ref.sha256,
    `operator_inputs_plan.input_refs.${key}.sha256`
  );
  const material = await readBuffer(
    absolutePath,
    `operator-inputs ${key} for ${operatorPath}`
  );
  const actualDigest = digestBuffer(material);
  if (declaredDigest !== actualDigest) {
    fail(`operator_inputs_plan.input_refs.${key}.sha256 must match file digest for ${operatorPath}`);
  }
  if (expectedDigest !== undefined && declaredDigest !== expectedDigest) {
    fail(`operator_inputs_plan.input_refs.${key}.sha256 must match ${expectedDigestLabel} for ${operatorPath}`);
  }

  return {
    path: relativePath,
    digest: declaredDigest
  };
}

function validateOperatorInputsManifestRef(manifest, key, expectedRelativePath, operatorPath) {
  const actual = requireString(
    manifest[key],
    `operator_inputs_manifest.${key}`
  );
  if (actual !== expectedRelativePath) {
    fail(`operator_inputs_manifest.${key} must match operator_inputs_plan.input_refs.${key}.path for ${operatorPath}`);
  }
}

async function validateOperatorInputsPlan(planInput, deploymentPathByOperatorPath, release, deployTemplate) {
  const plan = planInput.value;
  requireSchema(plan, OPERATOR_INPUTS_PLAN_SCHEMA, 'operator-inputs plan');
  if (requireString(plan.scope, 'operator_inputs_plan.scope') !== OPERATOR_INPUTS_PLAN_SCOPE) {
    fail(`operator_inputs_plan.scope must be ${OPERATOR_INPUTS_PLAN_SCOPE}`);
  }
  requireStatusPass(plan, 'operator-inputs plan');
  requireNoFormalVerdict(plan, 'operator-inputs plan');

  const operatorPath = requireString(plan.deployment_path, 'operator_inputs_plan.deployment_path');
  if (!DEPLOYMENT_PATHS.has(operatorPath)) {
    fail(`unexpected operator-inputs deployment path: ${operatorPath}`);
  }
  const deploymentPath = deploymentPathByOperatorPath.get(operatorPath);
  if (!deploymentPath) {
    fail(`operator-inputs plan has no matching deployment path report: ${operatorPath}`);
  }

  const internal = requireObject(plan._internal, 'operator_inputs_plan._internal');
  const expected = requireObject(
    internal.expected,
    'operator_inputs_plan._internal.expected'
  );
  requireSchema(
    expected,
    OPERATOR_INPUTS_PLAN_INTERNAL_SCHEMA,
    'operator_inputs_plan._internal.expected'
  );
  if (
    requireString(
      expected.deployment_path,
      'operator_inputs_plan._internal.expected.deployment_path'
    ) !== operatorPath
  ) {
    fail(`operator_inputs_plan._internal.expected.deployment_path must match deployment_path for ${operatorPath}`);
  }
  const expectedOutputDirs = requireObject(
    expected.output_dirs,
    'operator_inputs_plan._internal.expected.output_dirs'
  );
  const expectedDeploymentPathOutputDir = requireString(
    expectedOutputDirs.deployment_path,
    'operator_inputs_plan._internal.expected.output_dirs.deployment_path'
  );
  if (
    path.resolve(expectedDeploymentPathOutputDir) !==
    path.dirname(path.resolve(deploymentPath.report_file))
  ) {
    fail(`operator_inputs_plan._internal.expected.output_dirs.deployment_path must match deployment path report directory for ${operatorPath}`);
  }

  const packageInfo = requireObject(plan.package, 'operator_inputs_plan.package');
  const packageRoot = requireString(plan.operator_inputs_root, 'operator_inputs_plan.operator_inputs_root');
  const manifestPath = requireString(packageInfo.manifest_path, 'operator_inputs_plan.package.manifest_path');
  const manifestRelativePath = requireSafePackageRelativePath(
    packageInfo.manifest_relative_path,
    'operator_inputs_plan.package.manifest_relative_path'
  );
  if (path.resolve(packageRoot, manifestRelativePath) !== path.resolve(manifestPath)) {
    fail(`operator_inputs_plan.package.manifest_relative_path must bind manifest_path for ${operatorPath}`);
  }
  const manifestDigest = requireDigest(
    packageInfo.manifest_sha256,
    'operator_inputs_plan.package.manifest_sha256'
  );
  const planDigest = requireDigest(plan.plan_sha256, 'operator_inputs_plan.plan_sha256');
  const computedPlanDigest = canonicalDigest({ ...plan, plan_sha256: null });
  if (planDigest !== computedPlanDigest) {
    fail(`operator_inputs_plan.plan_sha256 must match canonical plan digest for ${operatorPath}`);
  }

  const manifestInput = await readJson(manifestPath, `operator-inputs manifest for ${operatorPath}`);
  if (manifestInput.digest !== manifestDigest) {
    fail(`operator-inputs manifest digest changed after plan generation for ${operatorPath}`);
  }
  requireSchema(manifestInput.value, OPERATOR_INPUTS_MANIFEST_SCHEMA, 'operator-inputs manifest');
  if (
    requireString(
      manifestInput.value.deployment_path,
      'operator_inputs_manifest.deployment_path'
    ) !== operatorPath
  ) {
    fail(`operator-inputs manifest deployment_path must match plan for ${operatorPath}`);
  }
  if (manifestInput.value.operator_inputs_version !== OPERATOR_INPUTS_MANIFEST_VERSION) {
    fail(`operator_inputs_manifest.operator_inputs_version must be ${OPERATOR_INPUTS_MANIFEST_VERSION}`);
  }
  const releaseContractRef = await validateOperatorInputsMaterialRef({
    plan,
    packageRoot,
    key: 'release_contract',
    expectedDigest: release.release_contract_digest,
    expectedDigestLabel: 'release contract digest',
    operatorPath
  });
  const deployTemplatePackageRef = await validateOperatorInputsMaterialRef({
    plan,
    packageRoot,
    key: 'deploy_template_package',
    expectedDigest: deployTemplate.deploy_template_package_digest,
    expectedDigestLabel: 'deploy template package descriptor digest',
    operatorPath
  });
  let airgapRuntimeTools;
  if (DEPLOYMENT_PATHS.get(operatorPath).source === 'airgap') {
    const archiveProbeRef = await validateOperatorInputsFileRef({
      plan,
      packageRoot,
      key: 'archive_probe',
      operatorPath,
      executable: true
    });
    const imageLoaderRef = await validateOperatorInputsFileRef({
      plan,
      packageRoot,
      key: 'image_loader',
      operatorPath,
      executable: true
    });
    validateOperatorInputsManifestRef(
      manifestInput.value,
      'archive_probe',
      archiveProbeRef.path,
      operatorPath
    );
    validateOperatorInputsManifestRef(
      manifestInput.value,
      'image_loader',
      imageLoaderRef.path,
      operatorPath
    );
    airgapRuntimeTools = {
      archive_probe: archiveProbeRef,
      image_loader: imageLoaderRef
    };
  }

  return {
    operator_path: operatorPath,
    package_manifest: {
      path: manifestRelativePath,
      digest: manifestDigest,
      schema: OPERATOR_INPUTS_MANIFEST_SCHEMA,
      operator_inputs_version: OPERATOR_INPUTS_MANIFEST_VERSION
    },
    package_plan: {
      digest: planDigest,
      schema: OPERATOR_INPUTS_PLAN_SCHEMA,
      scope: OPERATOR_INPUTS_PLAN_SCOPE
    },
    release_materials: {
      release_contract: releaseContractRef,
      deploy_template_package: deployTemplatePackageRef
    },
    ...(airgapRuntimeTools ? { airgap_runtime_tools: airgapRuntimeTools } : {}),
    deployment_path_report: {
      digest: deploymentPath.report_digest
    }
  };
}

async function validateOperatorInputsPlans(planInputs, deploymentPaths, release, deployTemplate) {
  if (planInputs.length === 0) {
    return [];
  }

  const deploymentPathByOperatorPath = new Map(
    deploymentPaths.map((entry) => [entry.operator_path, entry])
  );
  const packages = [];
  const seenPaths = new Set();
  for (const planInput of planInputs) {
    const entry = await validateOperatorInputsPlan(
      planInput,
      deploymentPathByOperatorPath,
      release,
      deployTemplate
    );
    if (seenPaths.has(entry.operator_path)) {
      fail(`duplicate operator-inputs plan: ${entry.operator_path}`);
    }
    seenPaths.add(entry.operator_path);
    packages.push(entry);
  }
  for (const operatorPath of DEPLOYMENT_PATHS.keys()) {
    if (!seenPaths.has(operatorPath)) {
      fail(`missing operator-inputs plan: ${operatorPath}`);
    }
  }
  return packages.sort((a, b) => a.operator_path.localeCompare(b.operator_path));
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function removeStaleOutputFile(file) {
  try {
    await fs.rm(file, { force: true });
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') {
      return;
    }
    fail(`cannot remove stale GA output ${path.basename(file)}: ${error.message}`);
  }
}

async function clearStaleFinalOutputs(outputDir) {
  await removeStaleOutputFile(path.join(outputDir, REPORT_FILE));
  await removeStaleOutputFile(path.join(outputDir, SUMMARY_FILE));
  await removeStaleOutputFile(path.join(outputDir, EVIDENCE_INDEX_FILE));
}

async function bestEffortRemoveOutputFile(file) {
  try {
    await fs.rm(file, { force: true });
  } catch {
    // Preserve the original output failure. Cleanup is best effort.
  }
}

async function writeSummary(file, report) {
  if (report.status === 'fail') {
    const lines = [
      '# AgentSmith GA Release Summary',
      '',
      `Status: ${report.status}`,
      `Formal verdict: ${report.formal_verdict}`,
      ...(report.release?.release_id ? [`Release: ${report.release.release_id}`] : []),
      ...(report.release?.git_sha ? [`Git SHA: ${report.release.git_sha}`] : []),
      ...(report.release?.release_contract_digest ? [`Release contract: ${report.release.release_contract_digest}`] : []),
      '',
      'Blockers:',
      ...report.blockers.map((entry) => `- ${entry.message}`),
      ''
    ];
    await fs.writeFile(file, `${lines.join('\n')}\n`, 'utf8');
    return;
  }

  const productSmokeReports = Array.isArray(report.post_deploy_product_smoke_reports)
    ? report.post_deploy_product_smoke_reports
    : report.post_deploy_product_smoke
      ? [report.post_deploy_product_smoke]
      : [];
  const coverage = report.post_deploy_product_smoke_coverage;
  const productSmokeReportDetails = productSmokeReports
    .map((entry) => ({
      operatorPath: entry.deployment_path_binding?.operator_path ?? 'unbound',
      targetProfile: entry.deployment_path_binding?.target_profile ?? entry.deployment_target?.profile ?? 'unknown-target',
      digest: entry.report_digest ?? 'missing-digest'
    }))
    .sort((left, right) => left.operatorPath.localeCompare(right.operatorPath))
    .map((entry) => `  - ${entry.operatorPath}: ${entry.digest} (target: ${entry.targetProfile})`);
  const runtimeReadiness = report.product_readiness.runtime_readiness;
  const filesRestoreRuntime = runtimeReadiness.files_restore_continuation;
  const lines = [
    '# AgentSmith GA Release Summary',
    '',
    `Status: ${report.status}`,
    `Formal verdict: ${report.formal_verdict}`,
    `Release: ${report.release.release_id}`,
    `Git SHA: ${report.release.git_sha}`,
    `Release contract: ${report.release.release_contract_digest}`,
    '',
    'Deployment paths:',
    ...report.deployment_paths.map((entry) => `- ${entry.operator_path}: ${entry.report_digest}`),
    '',
    `Product readiness: ${report.product_readiness.report_digest}`,
    `Product runtime readiness: ${filesRestoreRuntime.classification} (${filesRestoreRuntime.outcome})`,
    `Product runtime readiness evidence: ${filesRestoreRuntime.path}`,
    `Product runtime readiness intervals: ${runtimeReadiness.observation_policy.interval_ms.join(', ')}`,
    `Post-deploy product smoke: ${report.post_deploy_product_smoke.report_digest}`,
    `Post-deploy product smoke reports: ${productSmokeReports.length}`,
    ...(coverage?.covered_distributions
      ? [`Post-deploy product smoke distributions: ${coverage.covered_distributions.join(', ')}`]
      : []),
    ...(productSmokeReportDetails.length > 0
      ? ['Post-deploy product smoke report details:', ...productSmokeReportDetails]
      : []),
    `Post-deploy product smoke schema: ${report.post_deploy_product_smoke.schema}`,
    `Post-deploy product smoke producer: ${report.post_deploy_product_smoke.producer}`,
    `Post-deploy product smoke release contract: ${report.post_deploy_product_smoke.release_contract.input_sha256}`,
    `Post-deploy product smoke ids: ${report.post_deploy_product_smoke.canonical_smoke_ids.join(', ')}`,
    ''
  ];
  await fs.writeFile(file, `${lines.join('\n')}\n`, 'utf8');
}

async function readReleaseSummaryForFailure(releaseContractPath) {
  if (!releaseContractPath) {
    return undefined;
  }
  try {
    const input = await readJson(releaseContractPath, 'release contract');
    const value = input.value && typeof input.value === 'object' ? input.value : {};
    return {
      ...(typeof value.release_id === 'string' && value.release_id.trim() !== '' ? { release_id: value.release_id } : {}),
      ...(typeof value.git_sha === 'string' && value.git_sha.trim() !== '' ? { git_sha: value.git_sha } : {}),
      release_contract_digest: input.digest
    };
  } catch {
    return undefined;
  }
}

async function writeFailureOutputs(outputDir, error, argsOrRawArgs) {
  const releaseContractPath = Array.isArray(argsOrRawArgs)
    ? findArgValue(argsOrRawArgs, '--release-contract')
    : argsOrRawArgs?.releaseContract;
  const release = await readReleaseSummaryForFailure(releaseContractPath);
  const message = error instanceof Error ? error.message : String(error);
  const report = {
    schema: REPORT_SCHEMA,
    status: 'fail',
    formal_verdict: 'not_issued',
    generated_at: new Date().toISOString(),
    ...(release ? { release } : {}),
    summary: {
      conclusion: 'AgentSmith GA release aggregate blocked.'
    },
    blockers: [
      {
        message,
        exit_code: error?.exitCode ?? 1
      }
    ]
  };

  await writeFinalOutputs(outputDir, report);
  console.error(`FAIL: wrote ${REPORT_FILE} (${canonicalDigest(report)}) with formal_verdict=not_issued`);
}

function buildEvidenceIndex(report) {
  const artifactIndex = report.artifact_index ?? null;
  const canonicalRepos = Array.isArray(artifactIndex?.canonical_repos)
    ? artifactIndex.canonical_repos
    : Array.isArray(report.canonical_repos)
      ? report.canonical_repos
      : [];
  const productRuntimeReadiness = report.product_readiness?.runtime_readiness ?? null;
  const productSmoke = report.post_deploy_product_smoke ?? null;
  const productSmokeReports = Array.isArray(report.post_deploy_product_smoke_reports)
    ? report.post_deploy_product_smoke_reports
    : productSmoke
      ? [productSmoke]
      : [];
  const productSmokeCoverage = report.post_deploy_product_smoke_coverage
    ?? (productSmoke
      ? {
        canonical_smoke_ids: productSmoke.canonical_smoke_ids ?? [],
        source_evidence_paths: productSmoke.source_evidence_paths ?? {},
        source_evidence_sha256: productSmoke.source_evidence_sha256 ?? {},
        provider_neutral_endpoint_proof: productSmoke.provider_neutral_endpoint_proof ?? null,
        source: productSmoke.source ?? null,
        deployment_target: productSmoke.deployment_target ?? null,
        deployment_path_binding: productSmoke.deployment_path_binding ?? null
      }
      : null);
  const indexedDeploymentPaths = Array.isArray(artifactIndex?.deployment_paths)
    ? artifactIndex.deployment_paths.map((entry) => ({
        operator_path: entry.operator_path,
        digest: entry.digest,
        finalizer_manifest: entry.finalizer_manifest,
        source_evidence_files: entry.source_evidence_files
      }))
    : [];
  const reportDeploymentPaths = Array.isArray(report.deployment_paths)
    ? report.deployment_paths.map((entry) => ({
        operator_path: entry.operator_path,
        digest: entry.report_digest
      }))
    : [];

  return {
    schema: EVIDENCE_INDEX_SCHEMA,
    generated_at: report.generated_at,
    role: 'derived_from_ga_release_report',
    source_report: {
      path: REPORT_FILE,
      schema: report.schema,
      digest: canonicalDigest(report),
      status: report.status,
      formal_verdict: report.formal_verdict
    },
    ...(report.release ? { release: report.release } : {}),
    artifact_index: artifactIndex,
    ...(canonicalRepos.length > 0 ? { canonical_repos: canonicalRepos } : {}),
    deployment_paths: indexedDeploymentPaths.length > 0 ? indexedDeploymentPaths : reportDeploymentPaths,
    product_readiness: artifactIndex?.product_readiness ?? report.product_readiness?.report_digest ?? null,
    ...(productRuntimeReadiness ? { product_runtime_readiness: productRuntimeReadiness } : {}),
    post_deploy_product_smoke:
      artifactIndex?.post_deploy_product_smoke ?? report.post_deploy_product_smoke?.report_digest ?? null,
    ...(productSmokeReports.length > 0 ? {
      post_deploy_product_smoke_reports: artifactIndex?.post_deploy_product_smoke_reports
        ?? productSmokeReports.map((entry) => ({
          report_digest: entry.report_digest,
          source: entry.source,
          deployment_target: entry.deployment_target,
          deployment_path_binding: entry.deployment_path_binding
        }))
    } : {}),
    ...(productSmokeCoverage ? { post_deploy_product_smoke_coverage: productSmokeCoverage } : {}),
    blockers: Array.isArray(report.blockers) ? report.blockers : []
  };
}

async function writeFinalOutputs(outputDir, report) {
  const stamp = `${process.pid}-${Date.now()}`;
  const reportFile = path.join(outputDir, REPORT_FILE);
  const summaryFile = path.join(outputDir, SUMMARY_FILE);
  const evidenceIndexFile = path.join(outputDir, EVIDENCE_INDEX_FILE);
  const reportTemp = path.join(outputDir, `.${REPORT_FILE}.${stamp}.tmp`);
  const summaryTemp = path.join(outputDir, `.${SUMMARY_FILE}.${stamp}.tmp`);
  const evidenceIndexTemp = path.join(outputDir, `.${EVIDENCE_INDEX_FILE}.${stamp}.tmp`);

  try {
    await writeJson(reportTemp, report);
    await writeSummary(summaryTemp, report);
    await writeJson(evidenceIndexTemp, buildEvidenceIndex(report));
    await fs.rename(summaryTemp, summaryFile);
    await fs.rename(evidenceIndexTemp, evidenceIndexFile);
    await fs.rename(reportTemp, reportFile);
  } catch (error) {
    await Promise.all([
      bestEffortRemoveOutputFile(reportFile),
      bestEffortRemoveOutputFile(summaryFile),
      bestEffortRemoveOutputFile(evidenceIndexFile),
      bestEffortRemoveOutputFile(reportTemp),
      bestEffortRemoveOutputFile(summaryTemp),
      bestEffortRemoveOutputFile(evidenceIndexTemp)
    ]);
    throw error;
  }
}

async function buildPassReport(args) {
  const contract = await readJson(args.releaseContract, 'release contract');
  const deployTemplate = await readJson(args.deployTemplatePackage, 'deploy template package');
  const productReady = await readJson(args.productReadinessReport, 'product readiness report');
  const productSmokeInputs = [];
  for (const file of args.postDeployProductSmokeReports) {
    productSmokeInputs.push(await readJson(file, 'post-deploy product smoke report'));
  }
  const pathReports = [];
  for (const file of args.deploymentPathReports) {
    pathReports.push(await readJson(file, 'deployment path report'));
  }
  const operatorInputsPlans = [];
  for (const file of args.operatorInputsPlans) {
    operatorInputsPlans.push(await readJson(file, 'operator-inputs plan'));
  }

  for (const input of [productReady, ...productSmokeInputs, ...pathReports]) {
    scanReportForForbiddenContent({
      value: input.value,
      buffer: input.buffer,
      label: 'input report'
    });
  }

  const release = validateReleaseContract(contract.value, contract.digest);
  const canonicalRepos = await buildCanonicalRepos(release);
  const runnerReleaseManifest = requireObject(
    canonicalRepos.find((entry) => entry.repo === RUNNER_REPO)?.runner_release_manifest,
    'canonical_repos.agentsmith-runner.runner_release_manifest'
  );
  const runnerGaHandoff = requireObject(
    canonicalRepos.find((entry) => entry.repo === RUNNER_REPO)?.runner_ga_handoff,
    'canonical_repos.agentsmith-runner.runner_ga_handoff'
  );
  const deployTemplateSummary = validateDeployTemplatePackage(deployTemplate.value, contract.value, deployTemplate.digest);
  const productReadinessSummary = validateProductReadiness(productReady.value, productReady.digest, release);
  const productSmokeSummaries = productSmokeInputs.map((input) =>
    validateProductSmoke(input.value, input.digest, release)
  );

  const deploymentPaths = [];
  for (const entry of pathReports) {
    deploymentPaths.push(await validateDeploymentPathReport(entry, release, deployTemplateSummary));
  }
  const seenPaths = new Set();
  for (const entry of deploymentPaths) {
    if (seenPaths.has(entry.operator_path)) {
      fail(`duplicate deployment path report: ${entry.operator_path}`);
    }
    seenPaths.add(entry.operator_path);
  }
  for (const pathName of DEPLOYMENT_PATHS.keys()) {
    if (!seenPaths.has(pathName)) {
      fail(`missing deployment path report: ${pathName}`);
    }
  }
  const productSmokeCoverage = validateProductSmokeCoverage(productSmokeSummaries, deploymentPaths);
  const primaryProductSmoke =
    productSmokeCoverage.reports.find((entry) => entry.deployment_path_binding.distribution === 'online')
      ?? productSmokeCoverage.reports[0];
  const operatorInputsPackages = await validateOperatorInputsPlans(
    operatorInputsPlans,
    deploymentPaths,
    release,
    deployTemplateSummary
  );
  const deploymentPathReportEntries = deploymentPaths
    .map(({ report_file: _reportFile, ...entry }) => entry)
    .sort((a, b) => a.operator_path.localeCompare(b.operator_path));

  return {
    schema: REPORT_SCHEMA,
    status: 'pass',
    formal_verdict: 'issued',
    generated_at: new Date().toISOString(),
    release: {
      release_id: release.release_id,
      git_sha: release.git_sha,
      release_contract_digest: release.release_contract_digest,
      deploy_template_package_digest: deployTemplateSummary.deploy_template_package_digest,
      artifact_freshness_key: [
        release.release_id,
        release.git_sha,
        release.provenance.producer_repo,
        release.provenance.run_id,
        release.provenance.run_attempt,
        release.release_contract_digest
      ].join(':')
    },
    images: {
      ...release.images,
      runner_release_manifest: runnerReleaseManifest,
      runner_ga_handoff: runnerGaHandoff
    },
    deployment_paths: deploymentPathReportEntries,
    product_readiness: productReadinessSummary,
    post_deploy_product_smoke: primaryProductSmoke,
    post_deploy_product_smoke_reports: productSmokeCoverage.reports,
    post_deploy_product_smoke_coverage: {
      required_distributions: productSmokeCoverage.required_distributions,
      covered_distributions: productSmokeCoverage.covered_distributions,
      canonical_smoke_ids: productSmokeCoverage.canonical_smoke_ids,
      acceptance_coverage: productSmokeCoverage.acceptance_coverage,
      covered_operator_paths: productSmokeCoverage.covered_operator_paths,
      covered_target_profiles: productSmokeCoverage.covered_target_profiles,
      reports_by_distribution: productSmokeCoverage.reports_by_distribution
    },
    canonical_repos: canonicalRepos,
    artifact_index: {
      release_contract: {
        digest: release.release_contract_digest,
        provenance: release.provenance
      },
      canonical_repos: canonicalRepos,
      deploy_template_package: deployTemplateSummary,
      deployment_paths: deploymentPathReportEntries.map((entry) => ({
        operator_path: entry.operator_path,
        digest: entry.report_digest,
        finalizer_manifest: entry.source_evidence_index.finalizer_manifest,
        source_evidence_files: entry.source_evidence_index.source_evidence_files
      })),
      ...(operatorInputsPackages.length > 0 ? {
        operator_inputs_packages: operatorInputsPackages
      } : {}),
      product_readiness: productReadinessSummary.report_digest,
      post_deploy_product_smoke: primaryProductSmoke.report_digest,
      post_deploy_product_smoke_reports: productSmokeCoverage.reports.map((entry) => ({
        report_digest: entry.report_digest,
        source: entry.source,
        deployment_target: entry.deployment_target,
        deployment_path_binding: entry.deployment_path_binding
      }))
    },
    summary: {
      conclusion: 'AgentSmith GA release aggregate passed.',
      operator_paths: deploymentPathReportEntries.map((entry) => entry.operator_path).sort(),
      post_deploy_product_smoke: {
        report_digest: primaryProductSmoke.report_digest,
        reports_count: productSmokeCoverage.reports.length,
        covered_distributions: productSmokeCoverage.covered_distributions,
        acceptance_coverage: productSmokeCoverage.acceptance_coverage,
        schema: primaryProductSmoke.schema,
        producer: primaryProductSmoke.producer,
        release_contract: primaryProductSmoke.release_contract,
        canonical_smoke_ids: primaryProductSmoke.canonical_smoke_ids
      }
    },
    blockers: []
  };
}

async function main() {
  const rawArgs = process.argv.slice(2);
  let args;
  try {
    args = parseArgs(rawArgs);
  } catch (error) {
    const outputDir = findOutputDirArg(rawArgs);
    if (outputDir) {
      await clearStaleFinalOutputs(outputDir);
      await writeFailureOutputs(outputDir, error, rawArgs);
    }
    throw error;
  }
  if (args.help) {
    console.log(usage());
    return;
  }

  const outputDir = path.resolve(args.outputDir);
  await clearStaleFinalOutputs(outputDir);

  let report;
  try {
    report = await buildPassReport(args);
  } catch (error) {
    await writeFailureOutputs(outputDir, error, args);
    throw error;
  }

  await writeFinalOutputs(outputDir, report);
  console.log(`PASS: wrote ${REPORT_FILE} (${canonicalDigest(report)})`);
}

main().catch((error) => {
  const exitCode = error.exitCode ?? 1;
  console.error(`${exitCode === 2 ? 'error' : 'FAIL'}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
