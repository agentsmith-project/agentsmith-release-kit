#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  DISTRIBUTION_VALUES,
  SUBSTRATE_SOURCE_VALUES,
  TARGET_CLUSTER_VALUES,
  assertNoUnsafeSubstratePayload,
  isSafeSecretReference,
  parseTargetProfile,
  validateSubstrateConnectionTruth
} from './lib/substrate-truth-validation.mjs';
import {
  CURRENT_RELEASE_KIT_VERSION,
  assertPlainSemverAtLeast,
  requirePlainSemver
} from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'releaseContract',
  'evidenceRoot',
  'targetProfile',
  'outputDir'
];
const PRODUCER_REPO = 'github.com/agentsmith-project/agentsmith-release-kit';
const EVIDENCE_SCHEMA = 'agentsmith.release-kit-evidence-envelope/v1';
const EVIDENCE_SUBJECT_SCHEMA = 'agentsmith.release-kit-evidence-subject/v1';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const EVIDENCE_SUBJECT_NAME = 'release-kit-evidence-subject';
const EVIDENCE_SUBJECT_URI = 'evidence-subject.json';
const RELEASE_KIT_OUTPUT_VALUES = new Set([
  'deploy-result.json#substrate',
  'image-map.json',
  'render-report.json+rollout-report.json'
]);
const RELEASE_KIT_OUTPUT_REQUIRED_FILES = new Map([
  ['deploy-result.json#substrate', ['deploy-result.json']],
  ['image-map.json', ['image-map.json']],
  ['render-report.json+rollout-report.json', ['render-report.json', 'rollout-report.json']]
]);
const FORBIDDEN_RELEASE_KIT_OUTPUT_VALUES = new Set([
  'AgentSmith product flow aggregate'
]);
const STATUS_VALUES = new Set(['passed', 'failed']);
const PROVENANCE_KINDS = new Set(['ci_artifact', 'signed_operator_run']);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCAL_SCHEME_RE = /^(?:file|local|source|git\+file):/i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|0\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[?(?:::|::1)\]?|host\.docker\.internal)(?::\d+)?(?:[/?#]|$)/i;
const HOST_DOCKER_INTERNAL_RE = /(^|[^A-Za-z0-9.-])host\.docker\.internal(?=$|[^A-Za-z0-9.-])/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const AGENTSMITH_SOURCE_PATH_RE = /\/home\/[^/]+\/works\/[^/]+\/agentsmith(?:\/|$)/i;
const SECRET_KEY_RE = /(^|[_-])(password|passwd|pwd|token|secret|client_secret|private_key|kubeconfig|access_key|api_key)([_-]|$)/i;
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:postgres|mongodb|redis):\/\/[^:\s]+:[^@\s]+@/i,
  /\b(?:password|token|secret|client_secret)\s*[:=]\s*["']?[^"'\s]{8,}/i,
  /\bexecution[_ -]?ticket\b/i,
  /\bmanaged_credentials\b/i,
  /\bkubeconfig\b/i
];
const SAFE_REDACTED_SECRET_RE = /^(redacted|\*+)$/i;
const FORBIDDEN_RELEASE_KIT_KEYS = new Set(['product_flows', 'product_flow_results']);

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
  node scripts/verify-evidence.mjs \\
    --release-contract <json> \\
    --evidence-root <dir> \\
    --target-profile <target_cluster>/<substrate_source>/<distribution> \\
    --output-dir <dir>`;
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

function parseArgs(argv) {
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        cliFail(`missing value for ${arg}`);
      }
      index += 1;
      return value;
    };

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--evidence-root':
        parsed.evidenceRoot = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
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

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function requireGitSha(value, label) {
  const gitSha = requireString(value, label).toLowerCase();
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function requireEnumString(value, label, allowedValues) {
  const text = requireString(value, label);
  if (!allowedValues.has(text)) {
    fail(`${label} must be one of: ${[...allowedValues].join(', ')}`);
  }
  return text;
}

function assertSchemaVersion(value, expected, label) {
  const schemaVersion = requireString(value, label);
  if (schemaVersion !== expected) {
    fail(`${label} must be ${expected}`);
  }
}

async function readText(file, label) {
  try {
    return await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function readBuffer(file, label) {
  try {
    return await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function readJson(file, label) {
  const raw = await readText(file, label);
  try {
    return {
      value: JSON.parse(raw),
      raw,
      inputDigest: digestBuffer(Buffer.from(raw))
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

function isLoopbackHost(hostname) {
  const normalized = hostname.toLowerCase().replace(/^\[(.*)\]$/, '$1');
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::' ||
    normalized === '::1' ||
    /^(?:127|0)(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

function requireRemoteUri(value, label) {
  const uri = requireString(value, label);

  if (
    uri !== uri.trim() ||
    /[\r\n]/.test(uri) ||
    LOCAL_SCHEME_RE.test(uri) ||
    LOCAL_URI_RE.test(uri) ||
    LOCALHOST_URI_RE.test(uri) ||
    ABSOLUTE_LOCAL_PATH_RE.test(uri) ||
    RELATIVE_URI_RE.test(uri) ||
    AGENTSMITH_SOURCE_PATH_RE.test(uri) ||
    !URI_SCHEME_RE.test(uri)
  ) {
    fail(`${label} must be a remote provenance URI`);
  }

  let parsed;
  try {
    parsed = new URL(uri);
  } catch {
    fail(`${label} must be a remote provenance URI`);
  }

  const scheme = parsed.protocol.slice(0, -1).toLowerCase();
  if (!['gh-artifact', 'https'].includes(scheme)) {
    fail(`${label} must be a remote provenance URI`);
  }
  if (isLoopbackHost(parsed.hostname)) {
    fail(`${label} must be a remote provenance URI`);
  }

  return uri;
}

function isSafeSecretValue(value) {
  if (typeof value !== 'string') {
    return false;
  }
  if (SAFE_REDACTED_SECRET_RE.test(value)) {
    return true;
  }
  return isSafeSecretReference(value);
}

function scanUnsafeString(value, label, issues) {
  if (
    LOCAL_URI_RE.test(value) ||
    LOCALHOST_URI_RE.test(value) ||
    HOST_DOCKER_INTERNAL_RE.test(value) ||
    ABSOLUTE_LOCAL_PATH_RE.test(value) ||
    RELATIVE_URI_RE.test(value) ||
    AGENTSMITH_SOURCE_PATH_RE.test(value)
  ) {
    issues.push(`${label} contains a local or source URI`);
  }

  if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
    issues.push(`${label} contains a secret-looking value`);
  }
}

function scanPayload(value, label, issues = []) {
  if (typeof value === 'string') {
    scanUnsafeString(value, label, issues);
    return issues;
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      scanPayload(item, `${label}[${index}]`, issues);
    });
    return issues;
  }

  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      const nestedLabel = `${label}.${key}`;
      if (FORBIDDEN_RELEASE_KIT_KEYS.has(key)) {
        issues.push(`${nestedLabel} is owned by AgentSmith product evidence`);
      }
      if (
        SECRET_KEY_RE.test(key) &&
        typeof nested === 'string' &&
        !isSafeSecretValue(nested)
      ) {
        issues.push(`${nestedLabel} contains a secret-looking payload`);
      }
      scanPayload(nested, nestedLabel, issues);
    }
  }

  return issues;
}

function assertNoUnsafePayload(...payloads) {
  const issues = [];
  for (const [value, label] of payloads) {
    scanPayload(value, label, issues);
  }
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function assertNoUnsafeText(raw, label) {
  const issues = [];
  scanUnsafeString(raw, label, issues);
  if (/"(?:product_flows|product_flow_results)"\s*:/.test(raw)) {
    issues.push(`${label} contains AgentSmith product flow evidence`);
  }
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function containsKey(value, keyName) {
  if (Array.isArray(value)) {
    return value.some((item) => containsKey(item, keyName));
  }
  if (value && typeof value === 'object') {
    return Object.entries(value).some(
      ([key, nested]) => key === keyName || containsKey(nested, keyName)
    );
  }
  return false;
}

function evidenceSubjectProjection(evidence) {
  const { artifact_provenance: _artifactProvenance, ...subject } = evidence;
  return subject;
}

function normalizeSubjectPath(subjectPath, label) {
  const value = requireString(subjectPath, label);
  if (value.includes('\\')) {
    fail(`${label} must not contain backslashes`);
  }
  if (value.startsWith('/') || /^[A-Za-z]:[\\/]/.test(value)) {
    fail(`${label} must be relative to evidence root`);
  }

  const parts = value.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not escape evidence root`);
  }

  return parts.join('/');
}

function assertInsideRoot(rootDir, file, label) {
  const relative = path.relative(rootDir, file);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must stay inside evidence root`);
  }
}

function isTextBuffer(buffer) {
  return !buffer.subarray(0, Math.min(buffer.length, 8192)).includes(0);
}

async function assertSubjectFile({
  evidenceRoot,
  evidence,
  entry,
  index
}) {
  const label = `evidence_subject.files[${index}]`;
  const object = requireObject(entry, label);
  const relativePath = normalizeSubjectPath(object.path, `${label}.path`);
  if (relativePath === 'evidence-subject.json') {
    fail(`${label}.path must not list evidence-subject.json`);
  }
  const expectedSha256 = requireDigest(object.sha256, `${label}.sha256`);
  const file = path.resolve(evidenceRoot, relativePath);
  assertInsideRoot(evidenceRoot, file, `${label}.path`);

  let stat;
  try {
    stat = await fs.lstat(file);
  } catch (error) {
    fail(`${label}.path cannot be read: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label}.path must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label}.path must be a regular file`);
  }
  if (stat.nlink > 1) {
    fail(`${label}.path must not be a hardlink`);
  }

  const buffer = await readBuffer(file, `${label}.path`);
  if (!isTextBuffer(buffer)) {
    fail(`${label}.path must be a text evidence file`);
  }
  const raw = buffer.toString('utf8');
  assertNoUnsafeText(raw, `subject file ${relativePath}`);

  const actualSha256 = relativePath === 'evidence.json'
    ? canonicalDigest(evidenceSubjectProjection(evidence))
    : digestBuffer(buffer);
  if (actualSha256 !== expectedSha256) {
    fail(`${label}.sha256 must match ${relativePath}`);
  }

  return relativePath;
}

async function assertSubjectFiles(evidenceRoot, evidence, evidenceSubject, releaseKitOutput) {
  const files = requireArray(evidenceSubject.files, 'evidence_subject.files');
  const seen = new Set();

  for (const [index, entry] of files.entries()) {
    const relativePath = await assertSubjectFile({
      evidenceRoot,
      evidence,
      entry,
      index
    });
    if (seen.has(relativePath)) {
      fail(`evidence_subject.files contains duplicate path: ${relativePath}`);
    }
    seen.add(relativePath);
  }

  if (!seen.has('evidence.json')) {
    fail('evidence_subject.files must include evidence.json');
  }

  const requiredFiles = RELEASE_KIT_OUTPUT_REQUIRED_FILES.get(releaseKitOutput) || [];
  const expectedFiles = new Set(['evidence.json', ...requiredFiles]);
  for (const requiredFile of requiredFiles) {
    if (!seen.has(requiredFile)) {
      fail(`evidence.release_kit_output ${releaseKitOutput} requires evidence_subject.files to include ${requiredFile}`);
    }
  }
  for (const relativePath of seen) {
    if (!expectedFiles.has(relativePath)) {
      fail(`evidence.release_kit_output ${releaseKitOutput} requires evidence_subject.files to contain only ${[...expectedFiles].join(', ')}`);
    }
  }
  if (seen.size !== expectedFiles.size) {
    fail(`evidence.release_kit_output ${releaseKitOutput} requires evidence_subject.files to be exactly ${[...expectedFiles].join(', ')}`);
  }

  return {
    files_count: files.length,
    files: [...seen]
  };
}

function assertTarget(evidence, targetProfile) {
  const evidenceTargetCluster = requireEnumString(
    evidence.target_cluster,
    'evidence.target_cluster',
    TARGET_CLUSTER_VALUES
  );
  const evidenceSubstrateSource = requireEnumString(
    evidence.substrate_source,
    'evidence.substrate_source',
    SUBSTRATE_SOURCE_VALUES
  );
  const evidenceDistribution = requireEnumString(
    evidence.distribution,
    'evidence.distribution',
    DISTRIBUTION_VALUES
  );

  if (
    evidenceTargetCluster !== targetProfile.target_cluster ||
    evidenceSubstrateSource !== targetProfile.substrate_source ||
    evidenceDistribution !== targetProfile.distribution
  ) {
    fail('evidence target_profile must match CLI target_profile');
  }

  const target = requireObject(evidence.target, 'evidence.target');
  const hasNamespaceBaseUrl = (
    typeof target.namespace === 'string' &&
    target.namespace.trim() !== '' &&
    typeof target.base_url === 'string' &&
    target.base_url.trim() !== ''
  );
  const hasClusterServer = (
    typeof target.cluster === 'string' &&
    target.cluster.trim() !== '' &&
    typeof target.server === 'string' &&
    target.server.trim() !== ''
  );
  if (!hasNamespaceBaseUrl && !hasClusterServer) {
    fail('evidence.target must include namespace/base_url or cluster/server');
  }
}

function assertReleaseKitOutput(evidence) {
  const releaseKitOutput = requireString(
    evidence.release_kit_output,
    'evidence.release_kit_output'
  );
  if (FORBIDDEN_RELEASE_KIT_OUTPUT_VALUES.has(releaseKitOutput)) {
    fail('evidence.release_kit_output must not be AgentSmith product flow aggregate');
  }
  if (!RELEASE_KIT_OUTPUT_VALUES.has(releaseKitOutput)) {
    fail(`evidence.release_kit_output must be one of: ${[...RELEASE_KIT_OUTPUT_VALUES].join(', ')}`);
  }
  return releaseKitOutput;
}

function assertExternalDeclaredSubstrateConnectionTruth(evidence, targetProfile) {
  if (evidence.substrate_source !== 'external_declared') {
    return;
  }

  const truth = requireObject(
    evidence.substrate_connection_truth,
    'evidence.substrate_connection_truth'
  );
  assertNoUnsafeSubstratePayload(
    truth,
    'evidence.substrate_connection_truth',
    JSON.stringify(truth)
  );
  validateSubstrateConnectionTruth(truth, targetProfile, {
    label: 'evidence.substrate_connection_truth',
    requiredSubstrateSource: 'external_declared'
  });
}

function assertStatus(evidence) {
  const status = requireEnumString(evidence.status, 'evidence.status', STATUS_VALUES);
  const failureClass = requireString(evidence.failure_class, 'evidence.failure_class');
  if (status === 'passed' && failureClass !== 'none') {
    fail('evidence.failure_class must be none when status is passed');
  }
  if (status === 'failed' && failureClass === 'none') {
    fail('evidence.failure_class must not be none when status is failed');
  }
}

function assertFixedString(value, expected, label) {
  const text = requireString(value, label);
  if (text !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return text;
}

function readAttestation(value, label) {
  if (value === 'none') {
    return 'none';
  }
  if (typeof value === 'undefined') {
    fail(`${label} must be "none" or an object`);
  }

  const attestation = requireObject(value, label);
  const allowedFields = new Set(['attestation_uri', 'attestation_sha256']);
  for (const field of Object.keys(attestation)) {
    if (!allowedFields.has(field)) {
      fail(`${label}.${field} is not allowed`);
    }
  }

  return {
    attestation_uri: requireRemoteUri(
      attestation.attestation_uri,
      `${label}.attestation_uri`
    ),
    attestation_sha256: requireDigest(
      attestation.attestation_sha256,
      `${label}.attestation_sha256`
    )
  };
}

function assertProvenance(evidence, evidenceSubjectDigest) {
  const provenance = requireObject(
    evidence.artifact_provenance,
    'evidence.artifact_provenance'
  );
  assertSchemaVersion(
    provenance.schema_version,
    ARTIFACT_PROVENANCE_SCHEMA,
    'evidence.artifact_provenance.schema_version'
  );
  const provenanceKind = requireEnumString(
    provenance.provenance_kind,
    'evidence.artifact_provenance.provenance_kind',
    PROVENANCE_KINDS
  );
  const producerRepo = requireString(
    provenance.producer_repo,
    'evidence.artifact_provenance.producer_repo'
  );
  const normalizedRemote = requireString(
    provenance.normalized_remote,
    'evidence.artifact_provenance.normalized_remote'
  );
  if (producerRepo !== normalizedRemote) {
    fail('evidence.artifact_provenance.producer_repo must match normalized_remote');
  }
  if (producerRepo !== PRODUCER_REPO) {
    fail(`evidence.artifact_provenance.producer_repo must be ${PRODUCER_REPO}`);
  }

  requireGitSha(
    provenance.commit_sha,
    'evidence.artifact_provenance.commit_sha'
  );
  assertFixedString(
    provenance.subject_name,
    EVIDENCE_SUBJECT_NAME,
    'evidence.artifact_provenance.subject_name'
  );
  assertFixedString(
    provenance.subject_uri,
    EVIDENCE_SUBJECT_URI,
    'evidence.artifact_provenance.subject_uri'
  );
  const subjectSha256 = requireDigest(
    provenance.subject_sha256,
    'evidence.artifact_provenance.subject_sha256'
  );
  if (subjectSha256 !== evidenceSubjectDigest) {
    fail('evidence.artifact_provenance.subject_sha256 must match evidence-subject canonical digest');
  }

  requireRemoteUri(
    provenance.artifact_uri,
    'evidence.artifact_provenance.artifact_uri'
  );
  requireString(provenance.generated_at, 'evidence.artifact_provenance.generated_at');
  requireString(
    provenance.generator_command,
    'evidence.artifact_provenance.generator_command'
  );
  requireString(
    provenance.generator_version,
    'evidence.artifact_provenance.generator_version'
  );
  readAttestation(provenance.attestation, 'evidence.artifact_provenance.attestation');

  if (provenanceKind === 'ci_artifact') {
    for (const field of ['workflow_name', 'run_id', 'run_attempt', 'job']) {
      requireString(provenance[field], `evidence.artifact_provenance.${field}`);
    }
  }

  if (provenanceKind === 'signed_operator_run') {
    for (const field of [
      'operator_run_id',
      'operator_identity',
      'signature_uri',
      'signature_sha256'
    ]) {
      if (field === 'signature_sha256') {
        requireDigest(provenance[field], `evidence.artifact_provenance.${field}`);
      } else if (field === 'signature_uri') {
        requireRemoteUri(provenance[field], `evidence.artifact_provenance.${field}`);
      } else {
        requireString(provenance[field], `evidence.artifact_provenance.${field}`);
      }
    }
  }

  return {
    provenance_kind: provenanceKind,
    subject_sha256: subjectSha256
  };
}

function assertReleaseIdentity(evidence, releaseContractInput) {
  const releaseContractDigest = requireDigest(
    evidence.release_contract_digest,
    'evidence.release_contract_digest'
  );
  if (releaseContractDigest !== releaseContractInput.inputDigest) {
    fail('evidence.release_contract_digest must match release contract input sha256');
  }

  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const contractReleaseId = requireString(contract.release_id, 'release_contract.release_id');
  const contractGitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const evidenceReleaseId = requireString(evidence.release_id, 'evidence.release_id');
  const evidenceGitSha = requireGitSha(evidence.git_sha, 'evidence.git_sha');

  if (evidenceReleaseId !== contractReleaseId) {
    fail('evidence.release_id must match release contract release_id');
  }
  if (evidenceGitSha !== contractGitSha) {
    fail('evidence.git_sha must match release contract git_sha');
  }
}

function assertEvidenceShape(evidence) {
  assertSchemaVersion(
    evidence.schema_version,
    EVIDENCE_SCHEMA,
    'evidence.schema_version'
  );
  requireObject(evidence.artifact_provenance, 'evidence.artifact_provenance');
}

function assertReleaseKitVersion(evidence, releaseContractInput) {
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const minReleaseKitVersion = requirePlainSemver(
    contract.min_release_kit_version,
    'release_contract.min_release_kit_version',
    fail
  );
  assertPlainSemverAtLeast(
    CURRENT_RELEASE_KIT_VERSION,
    minReleaseKitVersion.value,
    'current release-kit version',
    'release_contract.min_release_kit_version',
    fail
  );
  assertPlainSemverAtLeast(
    evidence.release_kit_version,
    minReleaseKitVersion.value,
    'evidence.release_kit_version',
    'release_contract.min_release_kit_version',
    fail
  );
}

function buildReport({
  evidence,
  releaseKitOutput,
  targetProfile,
  releaseContractInputDigest,
  provenance,
  subjectFiles
}) {
  return {
    scope: 'release_kit_evidence_intake_only',
    readiness: false,
    release_id: evidence.release_id,
    git_sha: evidence.git_sha,
    release_kit_output: releaseKitOutput,
    target_profile: targetProfile,
    artifacts: {
      release_contract: {
        input_sha256: releaseContractInputDigest
      },
      evidence: {
        schema_version: evidence.schema_version,
        provenance_kind: provenance.provenance_kind,
        subject_sha256: provenance.subject_sha256,
        files_count: subjectFiles.files_count
      }
    },
    status: 'pass'
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(
    path.join(outputDir, 'evidence-validation-report.json'),
    `${JSON.stringify(report, null, 2)}\n`
  );
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const targetProfile = parseTargetProfile(args.targetProfile);
  const evidenceRoot = path.resolve(args.evidenceRoot);
  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const evidenceInput = await readJson(
    path.join(evidenceRoot, 'evidence.json'),
    'evidence.json'
  );
  const evidenceSubjectInput = await readJson(
    path.join(evidenceRoot, 'evidence-subject.json'),
    'evidence-subject.json'
  );

  assertNoUnsafeText(evidenceInput.raw, 'evidence.json');
  assertNoUnsafeText(evidenceSubjectInput.raw, 'evidence-subject.json');

  const evidence = requireObject(evidenceInput.value, 'evidence');
  const evidenceSubject = requireObject(evidenceSubjectInput.value, 'evidence_subject');
  assertNoUnsafePayload([evidence, 'evidence'], [evidenceSubject, 'evidence_subject']);

  if (containsKey(evidenceSubject, 'artifact_provenance')) {
    fail('evidence-subject.json must not contain artifact_provenance');
  }

  assertEvidenceShape(evidence);
  assertReleaseKitVersion(evidence, releaseContractInput);
  const releaseKitOutput = assertReleaseKitOutput(evidence);
  assertSchemaVersion(
    evidenceSubject.schema_version,
    EVIDENCE_SUBJECT_SCHEMA,
    'evidence_subject.schema_version'
  );
  assertReleaseIdentity(evidence, releaseContractInput);
  assertTarget(evidence, targetProfile);
  assertExternalDeclaredSubstrateConnectionTruth(evidence, targetProfile);
  assertStatus(evidence);

  const subjectFiles = await assertSubjectFiles(
    evidenceRoot,
    evidence,
    evidenceSubject,
    releaseKitOutput
  );
  const evidenceSubjectDigest = canonicalDigest(evidenceSubject);
  const provenance = assertProvenance(evidence, evidenceSubjectDigest);

  await writeReport(
    args.outputDir,
    buildReport({
      evidence,
      releaseKitOutput,
      targetProfile,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      provenance,
      subjectFiles
    })
  );
  console.log('PASS: release-kit evidence accepted');
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
