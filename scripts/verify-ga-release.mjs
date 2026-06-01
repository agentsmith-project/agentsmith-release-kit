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
const FINALIZER_MANIFEST_FILE = 'deployment-path-finalizer-manifest.json';
const SOURCE_EVIDENCE_DIR = 'source-evidence';
const REPORT_SCHEMA = 'agentsmith.ga-release-report/v1';
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
const PRODUCT_SMOKE_SCHEMA = 'agentsmith.post-deploy-product-smoke-report/v1';
const PRODUCT_SMOKE_PRODUCER = 'agentsmith-post-deploy-product-smoke';
const PRODUCT_SMOKE_OWNER = 'agentsmith';
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

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'productReadinessReport',
  'postDeployProductSmokeReport',
  'outputDir'
];

const DEPLOYMENT_PATHS = sourceValidation.DEPLOYMENT_PATHS;

const SOURCE_STEP_REPORTS = sourceValidation.FINALIZED_STEP_SOURCE_REPORTS;
const DEPLOYMENT_GATE_BY_SOURCE = sourceValidation.DEPLOYMENT_GATE_BY_SOURCE;

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
    --product-readiness-report <agentsmith/product-readiness-report.json> \\
    --post-deploy-product-smoke-report <agentsmith/post-deploy-product-smoke-report.json> \\
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
  const parsed = { deploymentPathReports: [] };

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
      case '--product-readiness-report':
        parsed.productReadinessReport = nextValue();
        break;
      case '--post-deploy-product-smoke-report':
        parsed.postDeployProductSmokeReport = nextValue();
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
  return parsed;
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

function requireProvenance(provenance, label) {
  const value = requireObject(provenance, label);
  const normalizedRemote = requireString(value.normalized_remote ?? value.producer_repo, `${label}.normalized_remote`);
  const commitSha = requireGitSha(value.commit_sha, `${label}.commit_sha`);
  const runId = requireString(value.run_id, `${label}.run_id`);
  const runAttempt = requireString(value.run_attempt, `${label}.run_attempt`);
  const subjectSha = optionalString(value.subject_sha256, `${label}.subject_sha256`);
  const artifactSha = optionalString(value.artifact_sha256, `${label}.artifact_sha256`);
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
    subject_name: optionalString(value.subject_name, `${label}.subject_name`),
    subject_sha256: subjectSha,
    artifact_sha256: artifactSha
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
  return {
    repo: expectedRepo,
    commit_sha: provenance.commit_sha,
    run_id: provenance.run_id,
    run_attempt: provenance.run_attempt,
    image_ids: [image.id],
    image_tags: [imageTag],
    image_digests: [image.digest],
    freshness_key: [
      expectedRepo,
      provenance.commit_sha,
      imageTag,
      provenance.run_id,
      provenance.run_attempt,
      image.digest
    ].join(':'),
    provenance: {
      ...provenance,
      tag: provenanceTag
    }
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

  return {
    repo: RELEASE_KIT_REPO,
    commit_sha: commitSha,
    run_id: runId,
    run_attempt: runAttempt,
    freshness_key: [
      RELEASE_KIT_REPO,
      commitSha,
      runId,
      runAttempt
    ].join(':'),
    provenance: {
      producer_repo: RELEASE_KIT_REPO,
      normalized_remote: RELEASE_KIT_REPO,
      commit_sha: commitSha,
      run_id: runId,
      run_attempt: runAttempt,
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
        summary.run_attempt !== first.run_attempt
      ) {
        fail(`canonical repo ${spec.repo} source provenance must use one commit/run across images`);
      }
    }

    repos.push({
      repo: spec.repo,
      commit_sha: first.commit_sha,
      run_id: first.run_id,
      run_attempt: first.run_attempt,
      image_ids: imageSummaries.flatMap((summary) => summary.image_ids).sort(),
      image_tags: imageSummaries.flatMap((summary) => summary.image_tags).sort(),
      image_digests: imageSummaries.flatMap((summary) => summary.image_digests).sort(),
      freshness_key: [
        spec.repo,
        first.commit_sha,
        first.run_id,
        first.run_attempt,
        ...imageSummaries.flatMap((summary) => summary.image_tags).sort(),
        ...imageSummaries.flatMap((summary) => summary.image_digests).sort()
      ].join(':'),
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

function validateProductReadiness(report, reportDigest, release) {
  requireSchema(report, PRODUCT_READY_SCHEMA, 'product readiness report');
  commonReportChecks(report, 'product readiness report', release);
  const provenance = requireProductArtifactProvenance(
    report.artifact_provenance,
    'product_readiness_report.artifact_provenance',
    release,
    'product readiness'
  );
  return { report_digest: reportDigest, provenance };
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

function validateProductSmoke(report, reportDigest, release) {
  const schemaVersion = requireProductSmokeSchemaVersion(report);
  rejectProductSmokeLegacyFields(report);
  const releaseContract = validateProductSmokeReleaseContract(report.release_contract, release);
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
  for (const entry of productSmokeEntries(report.smoke_results)) {
    const spec = CANONICAL_PRODUCT_SMOKE_SPECS[entry.id];
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
    sourceEvidencePaths[entry.id] = sourceEvidencePath;
  }
  for (const id of REQUIRED_PRODUCT_SMOKE_IDS) {
    if (!seenIds.has(id)) {
      fail(`post-deploy product smoke missing canonical smoke id: ${id}`);
    }
  }

  return {
    report_digest: reportDigest,
    schema: schemaVersion,
    producer: report.producer,
    owner: report.owner,
    repo: report.repo,
    release_contract: releaseContract,
    canonical_smoke_ids: [...REQUIRED_PRODUCT_SMOKE_IDS],
    source_evidence_paths: Object.fromEntries(
      Object.entries(sourceEvidencePaths).sort(([left], [right]) => left.localeCompare(right))
    )
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
    sourceInputsByStep: new Map()
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

  return {
    operator_path: operatorPath,
    target_profile: report.target_profile.value,
    report_digest: reportDigest,
    steps: [...steps.keys()],
    ...(airgapOffline ? { airgap_offline: airgapOffline } : {})
  };
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function writeSummary(file, report) {
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
    `Post-deploy product smoke: ${report.post_deploy_product_smoke.report_digest}`,
    `Post-deploy product smoke schema: ${report.post_deploy_product_smoke.schema}`,
    `Post-deploy product smoke producer: ${report.post_deploy_product_smoke.producer}`,
    `Post-deploy product smoke release contract: ${report.post_deploy_product_smoke.release_contract.input_sha256}`,
    `Post-deploy product smoke ids: ${report.post_deploy_product_smoke.canonical_smoke_ids.join(', ')}`,
    ''
  ];
  await fs.writeFile(file, `${lines.join('\n')}\n`, 'utf8');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const contract = await readJson(args.releaseContract, 'release contract');
  const deployTemplate = await readJson(args.deployTemplatePackage, 'deploy template package');
  const productReady = await readJson(args.productReadinessReport, 'product readiness report');
  const productSmoke = await readJson(args.postDeployProductSmokeReport, 'post-deploy product smoke report');
  const pathReports = [];
  for (const file of args.deploymentPathReports) {
    pathReports.push(await readJson(file, 'deployment path report'));
  }

  for (const input of [productReady, productSmoke, ...pathReports]) {
    scanReportForForbiddenContent({
      value: input.value,
      buffer: input.buffer,
      label: 'input report'
    });
  }

  const release = validateReleaseContract(contract.value, contract.digest);
  const canonicalRepos = await buildCanonicalRepos(release);
  const deployTemplateSummary = validateDeployTemplatePackage(deployTemplate.value, contract.value, deployTemplate.digest);
  const productReadinessSummary = validateProductReadiness(productReady.value, productReady.digest, release);
  const productSmokeSummary = validateProductSmoke(productSmoke.value, productSmoke.digest, release);

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

  const report = {
    schema: REPORT_SCHEMA,
    status: 'pass',
    formal_verdict: 'issued',
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
    images: release.images,
    deployment_paths: deploymentPaths.sort((a, b) => a.operator_path.localeCompare(b.operator_path)),
    product_readiness: productReadinessSummary,
    post_deploy_product_smoke: productSmokeSummary,
    canonical_repos: canonicalRepos,
    artifact_index: {
      release_contract: {
        digest: release.release_contract_digest,
        provenance: release.provenance
      },
      deploy_template_package: deployTemplateSummary,
      deployment_paths: deploymentPaths.map((entry) => ({
        operator_path: entry.operator_path,
        digest: entry.report_digest
      })),
      product_readiness: productReadinessSummary.report_digest,
      post_deploy_product_smoke: productSmokeSummary.report_digest
    },
    summary: {
      conclusion: 'AgentSmith GA release aggregate passed.',
      operator_paths: deploymentPaths.map((entry) => entry.operator_path).sort(),
      post_deploy_product_smoke: {
        report_digest: productSmokeSummary.report_digest,
        schema: productSmokeSummary.schema,
        producer: productSmokeSummary.producer,
        release_contract: productSmokeSummary.release_contract,
        canonical_smoke_ids: productSmokeSummary.canonical_smoke_ids
      }
    },
    blockers: []
  };

  const outputDir = path.resolve(args.outputDir);
  await writeJson(path.join(outputDir, REPORT_FILE), report);
  await writeSummary(path.join(outputDir, SUMMARY_FILE), report);
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
