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
  requirePlainSemver,
  validateContractTargetProfileEntry
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
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const IMAGE_MAP_SCOPE = 'image_map_only';
const ONLINE_DEPLOYMENT_GATE_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const ONLINE_DEPLOYMENT_GATE_SCOPE = 'online_deployment_gate_only';
const AIRGAP_BUNDLE_CHECK_REPORT_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const AIRGAP_BUNDLE_CHECK_REPORT_SCOPE = 'airgap_bundle_manifest_check_only';
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const EVIDENCE_SUBJECT_NAME = 'release-kit-evidence-subject';
const EVIDENCE_SUBJECT_URI = 'evidence-subject.json';
const IMAGE_MAP_TARGET_PROFILES = new Set([
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap'
]);
const ONLINE_DEPLOYMENT_GATE_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const AIRGAP_BUNDLE_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const AIRGAP_BUNDLE_EVIDENCE_OUTPUT =
  'airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json';
const OLD_AIRGAP_BUNDLE_EVIDENCE_OUTPUT =
  'airgap-bundle-check-report.json+airgap-bundle-manifest.json';
const RELEASE_KIT_OUTPUT_VALUES = new Set([
  'image-map.json',
  'online-deployment-gate-report.json',
  AIRGAP_BUNDLE_EVIDENCE_OUTPUT
]);
const RELEASE_KIT_OUTPUT_REQUIRED_FILES = new Map([
  ['image-map.json', ['image-map.json']],
  ['online-deployment-gate-report.json', ['online-deployment-gate-report.json']],
  [
    AIRGAP_BUNDLE_EVIDENCE_OUTPUT,
    ['airgap-bundle-check-report.json', 'airgap-bundle-manifest.json', 'image-map.json']
  ]
]);
const RELEASE_KIT_OUTPUT_TARGET_PROFILE_VALUES = new Map([
  [
    'image-map.json',
    IMAGE_MAP_TARGET_PROFILES
  ],
  [
    'online-deployment-gate-report.json',
    new Set([ONLINE_DEPLOYMENT_GATE_TARGET_PROFILE])
  ],
  [
    AIRGAP_BUNDLE_EVIDENCE_OUTPUT,
    new Set([AIRGAP_BUNDLE_TARGET_PROFILE])
  ]
]);
const FUTURE_RESERVED_RELEASE_KIT_OUTPUT_VALUES = new Set([
  'deploy-result.json#substrate'
]);
const INVALID_RELEASE_KIT_OUTPUT_VALUES = new Map([
  [
    OLD_AIRGAP_BUNDLE_EVIDENCE_OUTPUT,
    `${OLD_AIRGAP_BUNDLE_EVIDENCE_OUTPUT} is no longer accepted; use ${AIRGAP_BUNDLE_EVIDENCE_OUTPUT}`
  ],
  [
    'airgap-bundle-render-check-report.json',
    'airgap-bundle-render-check-report.json is render-check-only and is not accepted as release evidence'
  ],
  [
    'airgap-image-archive-check-report.json',
    'airgap-image-archive-check-report.json is image-archive-content-check-only and is not accepted as release evidence'
  ],
  [
    'airgap-image-load-report.json',
    'airgap-image-load-report.json is image-load-only and is not accepted as release evidence'
  ],
  [
    'airgap-deployment-gate-report.json',
    'airgap-deployment-gate-report.json is an airgap focused diagnostic and is not accepted as release evidence'
  ],
  [
    'registry-presence-report.json',
    'registry-presence-report.json is registry-presence-only and is not accepted as release evidence'
  ],
  [
    'substrate-pack-check-report.json',
    'substrate-pack-check-report.json is substrate-pack-check-only and is not accepted as release evidence'
  ]
]);
const FORBIDDEN_RELEASE_KIT_OUTPUT_VALUES = new Set([
  'AgentSmith product flow aggregate'
]);
const STATUS_VALUES = new Set(['passed', 'failed']);
const PROVENANCE_KINDS = new Set(['ci_artifact', 'signed_operator_run']);
const RELEASE_KIT_GH_ARTIFACT_HOST = 'agentsmith-release-kit';
const GITHUB_ACTIONS_API_HOST = 'api.github.com';
const GITHUB_ACTIONS_API_OWNER = 'agentsmith-project';
const GITHUB_ACTIONS_API_REPO = 'agentsmith-release-kit';
const SIGNED_OPERATOR_RUN_ARTIFACT_SCHEME = 'signed-operator-run';
const COMMON_PROVENANCE_FIELDS = [
  'schema_version',
  'provenance_kind',
  'producer_repo',
  'normalized_remote',
  'commit_sha',
  'artifact_uri',
  'generated_at',
  'generator_command',
  'generator_version',
  'attestation',
  'subject_name',
  'subject_uri',
  'subject_sha256'
];
const CI_PROVENANCE_FIELDS = new Set([
  ...COMMON_PROVENANCE_FIELDS,
  'workflow_name',
  'run_id',
  'run_attempt',
  'job'
]);
const SIGNED_OPERATOR_RUN_PROVENANCE_FIELDS = new Set([
  ...COMMON_PROVENANCE_FIELDS,
  'operator_run_id',
  'operator_identity',
  'signature_uri',
  'signature_sha256'
]);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const OPERATOR_REF_URI_SCHEME_RE = /\b[a-z][a-z0-9+.-]*:\/\/[^\s]*/i;
const DNS_HOST_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i;
const TARGET_NAMESPACE_COMPONENT_RE = /^[a-z0-9]+(?:(?:[._-]|__)[a-z0-9]+)*$/;
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
const DOWNLOAD_SEMANTICS_RE = /\b(?:public\s+download|public\s+url|https?\s+url|curl|wget|docker\s+pull|oras\s+pull|skopeo\s+copy)\b/i;
const SAFE_REDACTED_SECRET_RE = /^(redacted|\*+)$/i;
const FORBIDDEN_RELEASE_KIT_KEYS = new Set(['product_flows', 'product_flow_results']);
const ONLINE_DEPLOYMENT_GATE_REQUIRED_APPLY_STEPS = [
  'inputs',
  'target-preflight',
  'template-package',
  'render',
  'render-check',
  'apply',
  'rollout'
];
const ONLINE_DEPLOYMENT_GATE_ALLOWED_STEPS = new Set([
  ...ONLINE_DEPLOYMENT_GATE_REQUIRED_APPLY_STEPS,
  'image-map',
  'registry-presence',
  'smoke'
]);
const ONLINE_DEPLOYMENT_GATE_ALLOWED_STEP_SEQUENCES = [
  [
    'inputs',
    'target-preflight',
    'template-package',
    'render',
    'render-check',
    'apply',
    'rollout'
  ],
  [
    'inputs',
    'target-preflight',
    'template-package',
    'render',
    'render-check',
    'apply',
    'rollout',
    'smoke'
  ],
  [
    'inputs',
    'target-preflight',
    'template-package',
    'image-map',
    'registry-presence',
    'render',
    'render-check',
    'apply',
    'rollout'
  ],
  [
    'inputs',
    'target-preflight',
    'template-package',
    'image-map',
    'registry-presence',
    'render',
    'render-check',
    'apply',
    'rollout',
    'smoke'
  ]
];
const AIRGAP_BUNDLE_COMPONENT_KINDS = new Set([
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'image_map'
]);
const AIRGAP_BUNDLE_BINDING_KEYS = new Set([
  'release_contract_sha256',
  'deploy_template_package_sha256',
  'deploy_template_archive_sha256',
  'deploy_template_manifest_sha256',
  'image_map_sha256'
]);
const AIRGAP_BUNDLE_COMPONENT_KEYS = new Set(['kind', 'path', 'sha256']);
const AIRGAP_IMAGE_ARTIFACT_DECLARATION_KEYS = new Set([
  'id',
  'source_image',
  'source_digest',
  'target_image',
  'target_digest',
  'artifact_format',
  'path',
  'sha256'
]);
const AIRGAP_PAYLOAD_ARTIFACT_KEYS = new Set(['id', 'kind', 'path', 'sha256']);
const AIRGAP_PAYLOAD_ARTIFACT_KINDS = new Set([
  'runbook',
  'script',
  'profile_values_schema',
  'profile_values_example',
  'checksums'
]);
const AIRGAP_REQUIRED_PAYLOAD_ARTIFACT_KINDS = new Set([
  'runbook',
  'script',
  'profile_values_schema',
  'checksums'
]);
const AIRGAP_OPERATOR_PREREQUISITES_KEYS = new Set([
  'substrate_connection_truth_ref',
  'target_registry_proof_ref',
  'tools'
]);
const AIRGAP_BUNDLED_TOOL_KEYS = new Set(['name', 'version', 'source', 'path', 'sha256']);
const AIRGAP_OPERATOR_PREREQUISITE_TOOL_KEYS = new Set([
  'name',
  'version',
  'source',
  'location',
  'proof'
]);
const AIRGAP_SUBSTRATE_KEYS = new Set(['mode', 'bundled']);
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;

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

function assertStringEquals(value, expected, label) {
  const text = requireString(value, label);
  if (text !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return text;
}

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') {
    fail(`${label} must be a boolean`);
  }
  return value;
}

function requireBooleanFalse(value, label) {
  if (value !== false) {
    fail(`${label} must be false`);
  }
}

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function assertIntegerEquals(value, expected, label) {
  const actual = requireInteger(value, label);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function assertAllowedKeys(object, allowedKeys, label) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function assertSafeRelativePath(value, label) {
  const relativePath = requireString(value, label);
  if (
    relativePath !== relativePath.trim() ||
    relativePath.startsWith('/') ||
    /^[A-Za-z]:[\\/]/.test(relativePath) ||
    relativePath.includes('\\') ||
    relativePath.includes('//') ||
    relativePath.split('/').some((part) => part === '' || part === '.' || part === '..') ||
    URI_SCHEME_RE.test(relativePath) ||
    !SAFE_RELATIVE_PATH_RE.test(relativePath)
  ) {
    fail(`${label} must be a safe relative path`);
  }
  return relativePath;
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

function parseRemoteUri(value, label, allowedSchemes = ['gh-artifact', 'https']) {
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
  if (!allowedSchemes.includes(scheme)) {
    fail(`${label} must be a remote provenance URI`);
  }
  if (isLoopbackHost(parsed.hostname)) {
    fail(`${label} must be a remote provenance URI`);
  }

  return { uri, parsed, scheme };
}

function requireRemoteUri(value, label) {
  return parseRemoteUri(value, label).uri;
}

function pathSegments(parsed) {
  return parsed.pathname
    .split('/')
    .filter(Boolean)
    .map((segment) => {
      try {
        return decodeURIComponent(segment);
      } catch {
        return segment;
      }
    });
}

function hasPathSegment(parsed, expected) {
  return pathSegments(parsed).includes(expected);
}

function isReleaseKitGhArtifactUri(parsed, runId) {
  if (parsed.protocol.slice(0, -1).toLowerCase() !== 'gh-artifact') {
    return false;
  }
  if (parsed.hostname !== RELEASE_KIT_GH_ARTIFACT_HOST) {
    return false;
  }
  return Boolean(runId) && hasPathSegment(parsed, runId);
}

function isGitHubActionsArtifactApiUri(parsed, runId) {
  if (parsed.protocol !== 'https:' || parsed.hostname !== GITHUB_ACTIONS_API_HOST) {
    return false;
  }

  const segments = pathSegments(parsed);
  if (
    segments[0] !== 'repos' ||
    segments[1] !== GITHUB_ACTIONS_API_OWNER ||
    segments[2] !== GITHUB_ACTIONS_API_REPO ||
    segments[3] !== 'actions'
  ) {
    return false;
  }

  if (segments[4] === 'runs' && segments[6] === 'artifacts') {
    return Boolean(runId) && segments[5] === runId;
  }

  return false;
}

function isSignedOperatorRunArtifactUri(parsed, operatorRunId) {
  if (parsed.protocol.slice(0, -1).toLowerCase() !== SIGNED_OPERATOR_RUN_ARTIFACT_SCHEME) {
    return false;
  }
  if (parsed.hostname !== RELEASE_KIT_GH_ARTIFACT_HOST) {
    return false;
  }
  return Boolean(operatorRunId) && hasPathSegment(parsed, operatorRunId);
}

function requireBoundArtifactUri(
  value,
  label,
  { provenanceKind, runId, operatorRunId } = {}
) {
  const allowedSchemes =
    provenanceKind === 'signed_operator_run'
      ? [SIGNED_OPERATOR_RUN_ARTIFACT_SCHEME]
      : ['gh-artifact', 'https'];
  const { uri, parsed } = parseRemoteUri(value, label, allowedSchemes);

  if (
    provenanceKind === 'ci_artifact' &&
    (isReleaseKitGhArtifactUri(parsed, runId) ||
      isGitHubActionsArtifactApiUri(parsed, runId))
  ) {
    return uri;
  }

  if (
    provenanceKind === 'signed_operator_run' &&
    isSignedOperatorRunArtifactUri(parsed, operatorRunId)
  ) {
    return uri;
  }

  fail(`${label} must be bound to ${PRODUCER_REPO}`);
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
  if (FUTURE_RESERVED_RELEASE_KIT_OUTPUT_VALUES.has(releaseKitOutput)) {
    fail(`evidence.release_kit_output ${releaseKitOutput} is future reserved and is not accepted during pre-GA`);
  }
  if (INVALID_RELEASE_KIT_OUTPUT_VALUES.has(releaseKitOutput)) {
    fail(`evidence.release_kit_output ${INVALID_RELEASE_KIT_OUTPUT_VALUES.get(releaseKitOutput)}`);
  }
  if (FORBIDDEN_RELEASE_KIT_OUTPUT_VALUES.has(releaseKitOutput)) {
    fail('evidence.release_kit_output must not be AgentSmith product flow aggregate');
  }
  if (!RELEASE_KIT_OUTPUT_VALUES.has(releaseKitOutput)) {
    fail(`evidence.release_kit_output must be one of: ${[...RELEASE_KIT_OUTPUT_VALUES].join(', ')}`);
  }
  return releaseKitOutput;
}

function assertReleaseKitOutputTarget(releaseKitOutput, targetProfile) {
  const acceptedProfiles = RELEASE_KIT_OUTPUT_TARGET_PROFILE_VALUES.get(releaseKitOutput);
  if (!acceptedProfiles || acceptedProfiles.has(targetProfile.value)) {
    return;
  }
  fail(
    `evidence.release_kit_output ${releaseKitOutput} only accepts target_profile: ${[
      ...acceptedProfiles
    ].join(', ')}`
  );
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

function assertAllowedObjectFields(value, allowedFields, label) {
  for (const field of Object.keys(value)) {
    if (!allowedFields.has(field)) {
      fail(`${label}.${field} is not allowed`);
    }
  }
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
  assertAllowedObjectFields(
    provenance,
    provenanceKind === 'ci_artifact'
      ? CI_PROVENANCE_FIELDS
      : SIGNED_OPERATOR_RUN_PROVENANCE_FIELDS,
    'evidence.artifact_provenance'
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
    const runId = requireString(provenance.run_id, 'evidence.artifact_provenance.run_id');
    requireBoundArtifactUri(provenance.artifact_uri, 'evidence.artifact_provenance.artifact_uri', {
      provenanceKind,
      runId
    });
    requireString(provenance.workflow_name, 'evidence.artifact_provenance.workflow_name');
    requireString(provenance.run_attempt, 'evidence.artifact_provenance.run_attempt');
    requireString(provenance.job, 'evidence.artifact_provenance.job');
  }

  let operatorRunId;
  if (provenanceKind === 'signed_operator_run') {
    operatorRunId = requireString(
      provenance.operator_run_id,
      'evidence.artifact_provenance.operator_run_id'
    );
    requireBoundArtifactUri(provenance.artifact_uri, 'evidence.artifact_provenance.artifact_uri', {
      provenanceKind,
      operatorRunId
    });
    requireString(provenance.operator_identity, 'evidence.artifact_provenance.operator_identity');
    requireRemoteUri(provenance.signature_uri, 'evidence.artifact_provenance.signature_uri');
    requireDigest(provenance.signature_sha256, 'evidence.artifact_provenance.signature_sha256');
  }

  return {
    provenance_kind: provenanceKind,
    subject_sha256: subjectSha256,
    ...(operatorRunId ? { operator_run_id: operatorRunId } : {})
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

  assertReleaseContractTargetProfiles(contract);
}

function assertReleaseContractTargetProfiles(contract) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const seen = new Map();
  for (const [index, value] of profiles.entries()) {
    const label = `release_contract.target_profiles[${index}]`;
    const profile = validateContractTargetProfileEntry(value, fail, label);
    if (seen.has(profile.value)) {
      fail(`${label} duplicates target profile tuple declared at ${seen.get(profile.value)}`);
    }
    seen.set(profile.value, label);
  }
}

function assertReleaseContractIncludesTargetProfile(contract, targetProfile) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const found = profiles.some((value, index) => {
    const label = `release_contract.target_profiles[${index}]`;
    const profile = requireObject(value, label);
    const targetCluster = requireString(profile.target_cluster, `${label}.target_cluster`);
    const substrateSource = requireString(profile.substrate_source, `${label}.substrate_source`);
    const distribution = requireString(profile.distribution, `${label}.distribution`);
    return `${targetCluster}/${substrateSource}/${distribution}` === targetProfile.value;
  });
  if (!found) {
    fail('release_contract.target_profiles must include evidence target_profile');
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

function parseImageDigestRef(image, label) {
  const value = requireString(image, label);
  if (/\s/.test(value)) {
    fail(`${label} must not contain whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be an image reference, not a URI`);
  }
  if (/[?#]/.test(value)) {
    fail(`${label} must not contain query or hash text`);
  }

  const marker = '@sha256:';
  const index = value.lastIndexOf(marker);
  if (index < 0) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const imageWithoutDigest = value.slice(0, index);
  if (imageWithoutDigest === '') {
    fail(`${label} must include an image repository`);
  }
  if (imageWithoutDigest.includes('@')) {
    fail(`${label} must contain only one digest separator`);
  }
  const digest = `sha256:${value.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return { digest, imageWithoutDigest };
}

function imageDigestSuffix(image, label) {
  return parseImageDigestRef(image, label).digest;
}

function parseRegistryHostPort(hostPort, label) {
  if (hostPort.startsWith('[') || hostPort.includes(']')) {
    fail(`${label} must use a DNS host or IPv4 address, not an IPv6 literal`);
  }

  const colonParts = hostPort.split(':');
  if (colonParts.length > 2) {
    fail(`${label} must use a DNS host or IPv4 address with optional port`);
  }

  const [host, port] = colonParts;
  if (!host) {
    fail(`${label} host is required`);
  }
  if (port !== undefined) {
    if (!/^[0-9]+$/.test(port)) {
      fail(`${label} port must be numeric`);
    }
    const portNumber = Number(port);
    if (portNumber < 1 || portNumber > 65535) {
      fail(`${label} port must be between 1 and 65535`);
    }
  }

  return host;
}

function isIpv4Address(host) {
  const parts = host.split('.');
  return (
    parts.length === 4 &&
    parts.every((part) => /^[0-9]+$/.test(part) && Number(part) >= 0 && Number(part) <= 255)
  );
}

function isLocalRegistryHost(host) {
  const normalized = host.toLowerCase();
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::1' ||
    normalized === '0.0.0.0' ||
    /^127\./.test(normalized)
  );
}

function validateTargetRegistry(input, label = 'image_map.target_registry') {
  const value = requireString(input, label);
  if (value.trim() !== value || /\s/.test(value)) {
    fail(`${label} must not contain whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must not include a URI scheme`);
  }
  if (value.includes('@')) {
    fail(`${label} must not include userinfo`);
  }
  if (/[?#]/.test(value)) {
    fail(`${label} must not include query or hash text`);
  }
  if (value.includes('\\') || value.startsWith('/') || value.endsWith('/') || value.includes('//')) {
    fail(`${label} must be <registry-host[/namespace]>`);
  }

  const parts = value.split('/');
  const host = parseRegistryHostPort(parts[0], label);
  const hostName = host.toLowerCase();
  if (isLocalRegistryHost(hostName)) {
    fail(`${label} must not point at localhost, loopback, or host.docker.internal`);
  }
  if (!isIpv4Address(hostName) && !DNS_HOST_RE.test(hostName)) {
    fail(`${label} host must be a DNS name or IPv4 address`);
  }

  for (const [index, component] of parts.slice(1).entries()) {
    if (!TARGET_NAMESPACE_COMPONENT_RE.test(component)) {
      fail(`${label} namespace component ${index + 1} is invalid`);
    }
  }

  return value;
}

function stripTag(imageWithoutDigest) {
  const lastSlash = imageWithoutDigest.lastIndexOf('/');
  const lastColon = imageWithoutDigest.lastIndexOf(':');
  if (lastColon > lastSlash) {
    return imageWithoutDigest.slice(0, lastColon);
  }
  return imageWithoutDigest;
}

function firstPathComponentLooksLikeRegistry(component) {
  return (
    component.includes('.') ||
    component.includes(':') ||
    component === 'localhost' ||
    component === 'host.docker.internal'
  );
}

function sourceRepositoryPath(imageWithoutDigest, label) {
  const withoutTag = stripTag(imageWithoutDigest);
  const parts = withoutTag.split('/');
  if (parts.some((part) => part === '')) {
    fail(`${label} must not contain empty repository path components`);
  }
  if (parts.length > 1 && firstPathComponentLooksLikeRegistry(parts[0])) {
    return parts.slice(1).join('/');
  }
  return withoutTag;
}

function targetImageFor(inventoryItem, targetRegistry) {
  const repositoryPath = sourceRepositoryPath(
    inventoryItem.image_without_digest,
    `image ${inventoryItem.id}`
  );
  return `${targetRegistry}/${repositoryPath}@${inventoryItem.digest}`;
}

function buildDeployImageInventoryById(releaseContractInput) {
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const inventory = requireArray(
    contract.deploy_image_inventory,
    'release_contract.deploy_image_inventory'
  );
  if (inventory.length === 0) {
    fail('release_contract.deploy_image_inventory must not be empty');
  }

  const byId = new Map();
  for (const [index, value] of inventory.entries()) {
    const label = `release_contract.deploy_image_inventory[${index}]`;
    const item = requireObject(value, label);
    const id = requireString(item.id, `${label}.id`);
    if (byId.has(id)) {
      fail(`release_contract.deploy_image_inventory contains duplicate image id: ${id}`);
    }
    const source = requireString(item.source, `${label}.source`);
    const image = requireString(item.image, `${label}.image`);
    const digest = requireDigest(item.digest, `${label}.digest`);
    const {
      digest: imageDigest,
      imageWithoutDigest
    } = parseImageDigestRef(image, `${label}.image`);
    if (imageDigest !== digest) {
      fail(`${label}.digest must match image digest suffix`);
    }
    byId.set(id, {
      id,
      source,
      image,
      digest,
      image_without_digest: imageWithoutDigest
    });
  }
  return byId;
}

function assertTargetProfileObjectMatches(value, expected, label) {
  const object = requireObject(value, label);
  const declaredValue = requireString(object.value, `${label}.value`);
  const targetCluster = requireEnumString(
    object.target_cluster,
    `${label}.target_cluster`,
    TARGET_CLUSTER_VALUES
  );
  const substrateSource = requireEnumString(
    object.substrate_source,
    `${label}.substrate_source`,
    SUBSTRATE_SOURCE_VALUES
  );
  const distribution = requireEnumString(
    object.distribution,
    `${label}.distribution`,
    DISTRIBUTION_VALUES
  );
  const computedValue = `${targetCluster}/${substrateSource}/${distribution}`;
  if (declaredValue !== computedValue) {
    fail(`${label}.value must match target profile axes`);
  }
  if (computedValue !== expected.value) {
    fail(`${label} must match CLI target_profile`);
  }
}

function assertReleaseContractDigestBinding(value, label, evidence, releaseContractInput) {
  const digest = requireDigest(value, label);
  if (digest !== evidence.release_contract_digest) {
    fail(`${label} must match evidence.release_contract_digest`);
  }
  if (digest !== releaseContractInput.inputDigest) {
    fail(`${label} must match release contract input sha256`);
  }
}

function assertFocusedReportHeader(report, { schema, scope, label }) {
  assertStringEquals(report.schema, schema, `${label}.schema`);
  assertStringEquals(report.scope, scope, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);
}

function assertOutputIdentity({
  report,
  evidence,
  releaseContractInput,
  targetProfile,
  label,
  releaseContractDigestPath = 'release_contract.input_sha256'
}) {
  assertStringEquals(report.release_id, evidence.release_id, `${label}.release_id`);
  assertStringEquals(report.git_sha, evidence.git_sha, `${label}.git_sha`);
  assertTargetProfileObjectMatches(report.target_profile, targetProfile, `${label}.target_profile`);

  const pathParts = releaseContractDigestPath.split('.');
  let holder = report;
  for (const part of pathParts.slice(0, -1)) {
    holder = requireObject(holder[part], `${label}.${part}`);
  }
  const field = pathParts[pathParts.length - 1];
  assertReleaseContractDigestBinding(
    holder[field],
    `${label}.${releaseContractDigestPath}`,
    evidence,
    releaseContractInput
  );
}

async function readEvidenceOutputJson(evidenceRoot, relativePath) {
  return readJson(path.join(evidenceRoot, relativePath), relativePath);
}

function assertImageMapOutput({
  imageMap,
  evidence,
  releaseContractInput,
  targetProfile
}) {
  const label = 'image_map';
  assertFocusedReportHeader(imageMap, {
    schema: IMAGE_MAP_SCHEMA,
    scope: IMAGE_MAP_SCOPE,
    label
  });
  assertOutputIdentity({
    report: imageMap,
    evidence,
    releaseContractInput,
    targetProfile,
    label
  });

  const inventoryById = buildDeployImageInventoryById(releaseContractInput);
  const releaseContract = requireObject(
    imageMap.release_contract,
    'image_map.release_contract'
  );
  const inventoryCount = requireInteger(
    releaseContract.deploy_image_inventory_count,
    'image_map.release_contract.deploy_image_inventory_count'
  );
  if (inventoryCount !== inventoryById.size) {
    fail('image_map.release_contract.deploy_image_inventory_count must match release_contract.deploy_image_inventory length');
  }

  const mirrorRequired = requireBoolean(
    imageMap.mirror_required,
    'image_map.mirror_required'
  );
  const targetRegistry =
    typeof imageMap.target_registry === 'undefined'
      ? undefined
      : validateTargetRegistry(imageMap.target_registry, 'image_map.target_registry');
  if (mirrorRequired && !targetRegistry) {
    fail('image_map.target_registry is required when mirror_required is true');
  }
  if (!mirrorRequired && targetRegistry) {
    fail('image_map.target_registry is only allowed when mirror_required is true');
  }
  if (targetProfile.distribution === 'airgap') {
    if (!mirrorRequired) {
      fail('image_map.mirror_required must be true for airgap target_profile');
    }
    if (!targetRegistry) {
      fail('image_map.target_registry is required for airgap target_profile');
    }
  }

  const mappings = requireArray(imageMap.mappings, 'image_map.mappings');
  if (mappings.length !== inventoryById.size) {
    fail('image_map.mappings must match release_contract.deploy_image_inventory length');
  }
  const imageCount = requireInteger(imageMap.image_count, 'image_map.image_count');
  if (imageCount !== mappings.length) {
    fail('image_map.image_count must match image_map.mappings length');
  }

  const mappingsById = new Map();
  for (const [index, value] of mappings.entries()) {
    const mappingLabel = `image_map.mappings[${index}]`;
    const mapping = requireObject(value, mappingLabel);
    const id = requireString(mapping.id, `${mappingLabel}.id`);
    if (mappingsById.has(id)) {
      fail(`image_map.mappings contains duplicate id: ${id}`);
    }
    const inventoryItem = inventoryById.get(id);
    if (!inventoryItem) {
      fail(`${mappingLabel}.id must exist in release_contract.deploy_image_inventory`);
    }

    assertStringEquals(mapping.source, inventoryItem.source, `${mappingLabel}.source`);
    assertStringEquals(
      mapping.source_image,
      inventoryItem.image,
      `${mappingLabel}.source_image`
    );
    const sourceDigest = requireDigest(mapping.source_digest, `${mappingLabel}.source_digest`);
    if (sourceDigest !== inventoryItem.digest) {
      fail(`${mappingLabel}.source_digest must match release_contract.deploy_image_inventory`);
    }
    imageDigestSuffix(mapping.source_image, `${mappingLabel}.source_image`);

    const targetImage = requireString(mapping.target_image, `${mappingLabel}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${mappingLabel}.target_digest`);
    if (targetDigest !== sourceDigest) {
      fail(`${mappingLabel}.target_digest must match source_digest`);
    }
    const targetImageDigest = imageDigestSuffix(targetImage, `${mappingLabel}.target_image`);
    if (targetImageDigest !== targetDigest) {
      fail(`${mappingLabel}.target_image must be digest-pinned with target_digest`);
    }
    if (!mirrorRequired && targetImage !== mapping.source_image) {
      fail(`${mappingLabel}.target_image must match source_image when image_map.mirror_required is false`);
    }
    if (mirrorRequired) {
      const expectedTargetImage = targetImageFor(inventoryItem, targetRegistry);
      if (targetImage !== expectedTargetImage) {
        fail(`${mappingLabel}.target_image must match deterministic image_map.target_registry mirror ref`);
      }
    }
    const action = assertStringEquals(
      mapping.action,
      mirrorRequired ? 'mirror_required' : 'use_source',
      `${mappingLabel}.action`
    );
    mappingsById.set(id, {
      id,
      source_image: mapping.source_image,
      source_digest: sourceDigest,
      target_image: targetImage,
      target_digest: targetDigest,
      action
    });
  }

  for (const id of inventoryById.keys()) {
    if (!mappingsById.has(id)) {
      fail(`image_map.mappings is missing release_contract.deploy_image_inventory id: ${id}`);
    }
  }

  return {
    mirrorRequired,
    targetRegistry,
    imageCount: mappings.length,
    mappingsById
  };
}

function assertOnlineDeploymentGateOutput({
  report,
  evidence,
  releaseContractInput,
  targetProfile,
  provenance
}) {
  if (targetProfile.value !== ONLINE_DEPLOYMENT_GATE_TARGET_PROFILE) {
    fail(`online_deployment_gate target_profile must be ${ONLINE_DEPLOYMENT_GATE_TARGET_PROFILE}`);
  }
  assertFocusedReportHeader(report, {
    schema: ONLINE_DEPLOYMENT_GATE_SCHEMA,
    scope: ONLINE_DEPLOYMENT_GATE_SCOPE,
    label: 'online_deployment_gate'
  });
  assertOutputIdentity({
    report,
    evidence,
    releaseContractInput,
    targetProfile,
    label: 'online_deployment_gate'
  });

  assertStringEquals(report.mode, 'apply', 'online_deployment_gate.mode');
  const reportOperatorRunId = requireString(
    report.operator_run_id,
    'online_deployment_gate.operator_run_id'
  );
  if (provenance.provenance_kind === 'signed_operator_run') {
    if (reportOperatorRunId !== provenance.operator_run_id) {
      fail('online_deployment_gate.operator_run_id must match signed_operator_run provenance operator_run_id');
    }
  }

  const capabilityMap = requireObject(
    report.capability_map,
    'online_deployment_gate.capability_map'
  );
  const capabilityProfiles = Object.keys(capabilityMap);
  if (
    capabilityProfiles.length !== 1 ||
    capabilityProfiles[0] !== ONLINE_DEPLOYMENT_GATE_TARGET_PROFILE
  ) {
    fail('online_deployment_gate.capability_map must bind only the evidence target_profile');
  }

  const steps = requireArray(report.steps, 'online_deployment_gate.steps');
  if (steps.length === 0) {
    fail('online_deployment_gate.steps must not be empty');
  }

  const seenSteps = new Set();
  const stepOrder = [];
  for (const [index, value] of steps.entries()) {
    const label = `online_deployment_gate.steps[${index}]`;
    const step = requireObject(value, label);
    const name = requireString(step.name, `${label}.name`);
    if (!ONLINE_DEPLOYMENT_GATE_ALLOWED_STEPS.has(name)) {
      fail(`${label}.name is not an online deployment gate producer step`);
    }
    if (seenSteps.has(name)) {
      fail(`online_deployment_gate.steps contains duplicate step: ${name}`);
    }
    seenSteps.add(name);
    stepOrder.push(name);
    assertStringEquals(step.status, 'pass', `${label}.status`);
    const reportPaths = requireArray(step.report_paths, `${label}.report_paths`);
    if (reportPaths.length === 0) {
      fail(`${label}.report_paths must not be empty`);
    }
    for (const [pathIndex, reportPath] of reportPaths.entries()) {
      assertSafeRelativePath(reportPath, `${label}.report_paths[${pathIndex}]`);
    }
  }

  for (const name of ONLINE_DEPLOYMENT_GATE_REQUIRED_APPLY_STEPS) {
    if (!seenSteps.has(name)) {
      fail(`online_deployment_gate.steps is missing confirmed apply step: ${name}`);
    }
  }

  const isCanonicalSequence = ONLINE_DEPLOYMENT_GATE_ALLOWED_STEP_SEQUENCES.some(
    (sequence) =>
      sequence.length === stepOrder.length &&
      sequence.every((expectedStep, index) => stepOrder[index] === expectedStep)
  );
  if (!isCanonicalSequence) {
    fail('online_deployment_gate.steps must match a canonical confirmed apply sequence');
  }

  requireString(report.generated_at, 'online_deployment_gate.generated_at');
}

function assertDigestEquals(value, expected, label) {
  const digest = requireDigest(value, label);
  if (digest !== expected) {
    fail(`${label} must match expected sha256`);
  }
  return digest;
}

function assertAirgapReportArtifacts({
  reportArtifacts,
  manifestInputDigest,
  imageMapInputDigest,
  evidence,
  releaseContractInput
}) {
  const releaseContractArtifact = requireObject(
    reportArtifacts.release_contract,
    'airgap_bundle_check_report.artifacts.release_contract'
  );
  assertReleaseContractDigestBinding(
    releaseContractArtifact.input_sha256,
    'airgap_bundle_check_report.artifacts.release_contract.input_sha256',
    evidence,
    releaseContractInput
  );

  const deployTemplatePackageArtifact = requireObject(
    reportArtifacts.deploy_template_package,
    'airgap_bundle_check_report.artifacts.deploy_template_package'
  );
  const deployTemplatePackageInputSha = requireDigest(
    deployTemplatePackageArtifact.input_sha256,
    'airgap_bundle_check_report.artifacts.deploy_template_package.input_sha256'
  );
  const deployTemplatePackageSha = requireDigest(
    deployTemplatePackageArtifact.package_sha256,
    'airgap_bundle_check_report.artifacts.deploy_template_package.package_sha256'
  );
  const deployTemplateManifestSha = requireDigest(
    deployTemplatePackageArtifact.manifest_sha256,
    'airgap_bundle_check_report.artifacts.deploy_template_package.manifest_sha256'
  );
  const deployTemplateArtifactSha = requireDigest(
    deployTemplatePackageArtifact.artifact_sha256,
    'airgap_bundle_check_report.artifacts.deploy_template_package.artifact_sha256'
  );

  const deployTemplateArchiveArtifact = requireObject(
    reportArtifacts.deploy_template_archive,
    'airgap_bundle_check_report.artifacts.deploy_template_archive'
  );
  const deployTemplateArchiveInputSha = requireDigest(
    deployTemplateArchiveArtifact.input_sha256,
    'airgap_bundle_check_report.artifacts.deploy_template_archive.input_sha256'
  );
  if (
    deployTemplatePackageSha !== deployTemplateArchiveInputSha ||
    deployTemplateArtifactSha !== deployTemplateArchiveInputSha
  ) {
    fail('airgap_bundle_check_report deploy template archive digests must match package/artifact sha256');
  }

  const imageMapArtifact = requireObject(
    reportArtifacts.image_map,
    'airgap_bundle_check_report.artifacts.image_map'
  );
  const imageMapInputSha = requireDigest(
    imageMapArtifact.input_sha256,
    'airgap_bundle_check_report.artifacts.image_map.input_sha256'
  );
  if (imageMapInputSha !== imageMapInputDigest) {
    fail('airgap_bundle_check_report.artifacts.image_map.input_sha256 must match image-map.json sha256');
  }
  const imageMapCount = requireInteger(
    imageMapArtifact.image_count,
    'airgap_bundle_check_report.artifacts.image_map.image_count'
  );
  if (imageMapCount === 0) {
    fail('airgap_bundle_check_report.artifacts.image_map.image_count must not be empty');
  }

  const bundleManifestArtifact = requireObject(
    reportArtifacts.bundle_manifest,
    'airgap_bundle_check_report.artifacts.bundle_manifest'
  );
  assertDigestEquals(
    bundleManifestArtifact.input_sha256,
    manifestInputDigest,
    'airgap_bundle_check_report.artifacts.bundle_manifest.input_sha256'
  );
  const manifestImageDeclarationCount = requireInteger(
    bundleManifestArtifact.image_artifact_declaration_count,
    'airgap_bundle_check_report.artifacts.bundle_manifest.image_artifact_declaration_count'
  );

  return {
    deployTemplatePackageInputSha,
    deployTemplateArchiveInputSha,
    deployTemplateManifestSha,
    imageMapInputSha,
    imageMapCount,
    manifestImageDeclarationCount
  };
}

function assertAirgapBindings({ bindings, expected }) {
  const object = requireObject(bindings, 'airgap_bundle_manifest.bindings');
  assertAllowedKeys(object, AIRGAP_BUNDLE_BINDING_KEYS, 'airgap_bundle_manifest.bindings');
  for (const [key, expectedDigest] of Object.entries(expected)) {
    assertDigestEquals(
      object[key],
      expectedDigest,
      `airgap_bundle_manifest.bindings.${key}`
    );
  }
}

function assertAirgapComponents({ components, expected }) {
  const items = requireArray(components, 'airgap_bundle_manifest.components');
  if (items.length !== AIRGAP_BUNDLE_COMPONENT_KINDS.size) {
    fail('airgap_bundle_manifest.components must contain release_contract, deploy_template_package, deploy_template_archive, and image_map');
  }

  const seen = new Set();
  for (const [index, value] of items.entries()) {
    const label = `airgap_bundle_manifest.components[${index}]`;
    const component = requireObject(value, label);
    assertAllowedKeys(component, AIRGAP_BUNDLE_COMPONENT_KEYS, label);
    const kind = requireString(component.kind, `${label}.kind`);
    if (!AIRGAP_BUNDLE_COMPONENT_KINDS.has(kind)) {
      fail(`${label}.kind is invalid`);
    }
    if (seen.has(kind)) {
      fail(`airgap_bundle_manifest.components contains duplicate kind: ${kind}`);
    }
    seen.add(kind);
    assertSafeRelativePath(component.path, `${label}.path`);
    assertDigestEquals(component.sha256, expected[kind], `${label}.sha256`);
  }

  for (const kind of AIRGAP_BUNDLE_COMPONENT_KINDS) {
    if (!seen.has(kind)) {
      fail(`airgap_bundle_manifest.components is missing ${kind}`);
    }
  }

  return items.length;
}

function assertAirgapImageArtifactDeclarations({
  declarations,
  imageMapSummary,
  expectedCount
}) {
  const items = requireArray(
    declarations,
    'airgap_bundle_manifest.image_artifact_declarations'
  );
  if (items.length !== expectedCount || items.length !== imageMapSummary.mappingsById.size) {
    fail('airgap_bundle_manifest.image_artifact_declarations must match image-map report count and image_map.mappings');
  }

  const seen = new Set();
  for (const [index, value] of items.entries()) {
    const label = `airgap_bundle_manifest.image_artifact_declarations[${index}]`;
    const declaration = requireObject(value, label);
    assertAllowedKeys(declaration, AIRGAP_IMAGE_ARTIFACT_DECLARATION_KEYS, label);
    const id = requireString(declaration.id, `${label}.id`);
    if (seen.has(id)) {
      fail(`airgap_bundle_manifest.image_artifact_declarations contains duplicate id: ${id}`);
    }
    seen.add(id);

    const mapping = imageMapSummary.mappingsById.get(id);
    if (!mapping) {
      fail(`${label}.id must exist in image_map.mappings`);
    }
    if (mapping.action !== 'mirror_required') {
      fail(`${label} image-map mapping action must be mirror_required`);
    }

    assertStringEquals(declaration.source_image, mapping.source_image, `${label}.source_image`);
    const sourceDigest = requireDigest(declaration.source_digest, `${label}.source_digest`);
    if (sourceDigest !== mapping.source_digest) {
      fail(`${label}.source_digest must match image_map mapping`);
    }
    imageDigestSuffix(declaration.source_image, `${label}.source_image`);

    const targetImage = requireString(declaration.target_image, `${label}.target_image`);
    if (targetImage !== mapping.target_image) {
      fail(`${label}.target_image must match image_map mapping`);
    }
    const targetDigest = requireDigest(declaration.target_digest, `${label}.target_digest`);
    if (targetDigest !== mapping.target_digest) {
      fail(`${label}.target_digest must match image_map mapping`);
    }
    const targetImageDigest = imageDigestSuffix(targetImage, `${label}.target_image`);
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
    assertStringEquals(declaration.artifact_format, 'oci_layout_tar', `${label}.artifact_format`);
    assertSafeRelativePath(declaration.path, `${label}.path`);
    requireDigest(declaration.sha256, `${label}.sha256`);
  }

  for (const id of imageMapSummary.mappingsById.keys()) {
    if (!seen.has(id)) {
      fail(`airgap_bundle_manifest.image_artifact_declarations is missing image_map.mappings id: ${id}`);
    }
  }

  return items.length;
}

function assertAirgapPayloadArtifacts({ payloadArtifacts, expectedCount }) {
  const items = requireArray(
    payloadArtifacts,
    'airgap_bundle_manifest.payload_artifacts'
  );
  if (items.length !== expectedCount) {
    fail('airgap_bundle_manifest.payload_artifacts must match airgap bundle check report payload count');
  }

  const seenIds = new Set();
  const seenRequiredKinds = new Set();
  for (const [index, value] of items.entries()) {
    const label = `airgap_bundle_manifest.payload_artifacts[${index}]`;
    const artifact = requireObject(value, label);
    assertAllowedKeys(artifact, AIRGAP_PAYLOAD_ARTIFACT_KEYS, label);
    const id = requireString(artifact.id, `${label}.id`);
    if (seenIds.has(id)) {
      fail(`airgap_bundle_manifest.payload_artifacts contains duplicate id: ${id}`);
    }
    seenIds.add(id);
    const kind = requireString(artifact.kind, `${label}.kind`);
    if (!AIRGAP_PAYLOAD_ARTIFACT_KINDS.has(kind)) {
      fail(`${label}.kind is invalid`);
    }
    if (AIRGAP_REQUIRED_PAYLOAD_ARTIFACT_KINDS.has(kind)) {
      seenRequiredKinds.add(kind);
    }
    assertSafeRelativePath(artifact.path, `${label}.path`);
    requireDigest(artifact.sha256, `${label}.sha256`);
  }

  for (const kind of AIRGAP_REQUIRED_PAYLOAD_ARTIFACT_KINDS) {
    if (!seenRequiredKinds.has(kind)) {
      fail(`airgap_bundle_manifest.payload_artifacts is missing required payload type: ${kind}`);
    }
  }

  return items.length;
}

function assertAirgapOperatorRef(value, label) {
  const ref = requireString(value, label);
  if (ref.trim() !== ref) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (OPERATOR_REF_URI_SCHEME_RE.test(ref)) {
    fail(`${label} must be an operator-held reference, not a URI`);
  }
  if (DOWNLOAD_SEMANTICS_RE.test(ref)) {
    fail(`${label} must not describe public download semantics`);
  }
  if (SECRET_VALUE_RE.some((pattern) => pattern.test(ref))) {
    fail(`${label} must not contain secret-looking content`);
  }
  return ref;
}

function assertAirgapOperatorPrerequisites({
  prerequisites,
  expectedToolCount,
  expectedBundledToolCount,
  expectedOperatorPrerequisiteToolCount
}) {
  const object = requireObject(
    prerequisites,
    'airgap_bundle_manifest.operator_prerequisites'
  );
  assertAllowedKeys(
    object,
    AIRGAP_OPERATOR_PREREQUISITES_KEYS,
    'airgap_bundle_manifest.operator_prerequisites'
  );
  assertAirgapOperatorRef(
    object.substrate_connection_truth_ref,
    'airgap_bundle_manifest.operator_prerequisites.substrate_connection_truth_ref'
  );
  assertAirgapOperatorRef(
    object.target_registry_proof_ref,
    'airgap_bundle_manifest.operator_prerequisites.target_registry_proof_ref'
  );

  const tools = requireArray(
    object.tools,
    'airgap_bundle_manifest.operator_prerequisites.tools'
  );
  if (expectedToolCount <= 0) {
    fail('airgap_bundle_check_report.tool_count must be greater than 0');
  }
  if (tools.length === 0) {
    fail('airgap_bundle_manifest.operator_prerequisites.tools must not be empty');
  }
  if (tools.length !== expectedToolCount) {
    fail('airgap_bundle_manifest.operator_prerequisites.tools must match airgap bundle check report tool count');
  }

  let bundledToolCount = 0;
  let operatorPrerequisiteToolCount = 0;
  for (const [index, value] of tools.entries()) {
    const label = `airgap_bundle_manifest.operator_prerequisites.tools[${index}]`;
    const tool = requireObject(value, label);
    const source = requireString(tool.source, `${label}.source`);
    if (source === 'bundled') {
      assertAllowedKeys(tool, AIRGAP_BUNDLED_TOOL_KEYS, label);
      requireString(tool.name, `${label}.name`);
      requireString(tool.version, `${label}.version`);
      assertSafeRelativePath(tool.path, `${label}.path`);
      requireDigest(tool.sha256, `${label}.sha256`);
      bundledToolCount += 1;
    } else if (source === 'operator_prerequisite') {
      assertAllowedKeys(tool, AIRGAP_OPERATOR_PREREQUISITE_TOOL_KEYS, label);
      requireString(tool.name, `${label}.name`);
      requireString(tool.version, `${label}.version`);
      assertAirgapOperatorRef(tool.location, `${label}.location`);
      assertAirgapOperatorRef(tool.proof, `${label}.proof`);
      operatorPrerequisiteToolCount += 1;
    } else {
      fail(`${label}.source is invalid`);
    }
  }

  if (bundledToolCount !== expectedBundledToolCount) {
    fail('airgap_bundle_manifest.operator_prerequisites.tools bundled count must match report');
  }
  if (operatorPrerequisiteToolCount !== expectedOperatorPrerequisiteToolCount) {
    fail('airgap_bundle_manifest.operator_prerequisites.tools operator prerequisite count must match report');
  }

  return {
    toolCount: tools.length,
    bundledToolCount,
    operatorPrerequisiteToolCount
  };
}

function assertAirgapSubstrate(value) {
  const substrate = requireObject(value, 'airgap_bundle_manifest.substrate');
  assertAllowedKeys(substrate, AIRGAP_SUBSTRATE_KEYS, 'airgap_bundle_manifest.substrate');
  assertStringEquals(substrate.mode, 'external_declared', 'airgap_bundle_manifest.substrate.mode');
  requireBooleanFalse(substrate.bundled, 'airgap_bundle_manifest.substrate.bundled');
}

function assertAirgapBundleOutput({
  report,
  manifest,
  manifestInputDigest,
  imageMap,
  imageMapInputDigest,
  evidence,
  releaseContractInput,
  targetProfile
}) {
  if (targetProfile.value !== AIRGAP_BUNDLE_TARGET_PROFILE) {
    fail(`airgap_bundle target_profile must be ${AIRGAP_BUNDLE_TARGET_PROFILE}`);
  }

  assertFocusedReportHeader(report, {
    schema: AIRGAP_BUNDLE_CHECK_REPORT_SCHEMA,
    scope: AIRGAP_BUNDLE_CHECK_REPORT_SCOPE,
    label: 'airgap_bundle_check_report'
  });
  assertOutputIdentity({
    report,
    evidence,
    releaseContractInput,
    targetProfile,
    label: 'airgap_bundle_check_report',
    releaseContractDigestPath: 'artifacts.release_contract.input_sha256'
  });
  const imageMapSummary = assertImageMapOutput({
    imageMap,
    evidence,
    releaseContractInput,
    targetProfile
  });

  const reportArtifacts = requireObject(
    report.artifacts,
    'airgap_bundle_check_report.artifacts'
  );
  const reportArtifactSummary = assertAirgapReportArtifacts({
    reportArtifacts,
    manifestInputDigest,
    imageMapInputDigest,
    evidence,
    releaseContractInput
  });
  if (reportArtifactSummary.imageMapCount !== imageMapSummary.imageCount) {
    fail('airgap_bundle_check_report.artifacts.image_map.image_count must match image_map.image_count');
  }

  assertSchemaVersion(
    manifest.schema_version,
    AIRGAP_BUNDLE_MANIFEST_SCHEMA,
    'airgap_bundle_manifest.schema_version'
  );
  assertStringEquals(
    manifest.release_id,
    evidence.release_id,
    'airgap_bundle_manifest.release_id'
  );
  assertStringEquals(manifest.git_sha, evidence.git_sha, 'airgap_bundle_manifest.git_sha');
  assertTargetProfileObjectMatches(
    manifest.target_profile,
    targetProfile,
    'airgap_bundle_manifest.target_profile'
  );
  const bindings = requireObject(manifest.bindings, 'airgap_bundle_manifest.bindings');
  assertAirgapBindings({
    bindings,
    expected: {
      release_contract_sha256: releaseContractInput.inputDigest,
      deploy_template_package_sha256: reportArtifactSummary.deployTemplatePackageInputSha,
      deploy_template_archive_sha256: reportArtifactSummary.deployTemplateArchiveInputSha,
      deploy_template_manifest_sha256: reportArtifactSummary.deployTemplateManifestSha,
      image_map_sha256: reportArtifactSummary.imageMapInputSha
    }
  });

  const componentsCount = assertAirgapComponents({
    components: manifest.components,
    expected: {
      release_contract: releaseContractInput.inputDigest,
      deploy_template_package: reportArtifactSummary.deployTemplatePackageInputSha,
      deploy_template_archive: reportArtifactSummary.deployTemplateArchiveInputSha,
      image_map: reportArtifactSummary.imageMapInputSha
    }
  });
  const imageArtifactDeclarationCount = assertAirgapImageArtifactDeclarations({
    declarations: manifest.image_artifact_declarations,
    imageMapSummary,
    expectedCount: reportArtifactSummary.imageMapCount
  });
  const payloadArtifactCount = assertAirgapPayloadArtifacts({
    payloadArtifacts: manifest.payload_artifacts,
    expectedCount: requireInteger(
      report.payload_artifact_count,
      'airgap_bundle_check_report.payload_artifact_count'
    )
  });
  const operatorPrerequisiteSummary = assertAirgapOperatorPrerequisites({
    prerequisites: manifest.operator_prerequisites,
    expectedToolCount: requireInteger(
      report.tool_count,
      'airgap_bundle_check_report.tool_count'
    ),
    expectedBundledToolCount: requireInteger(
      report.bundled_tool_count,
      'airgap_bundle_check_report.bundled_tool_count'
    ),
    expectedOperatorPrerequisiteToolCount: requireInteger(
      report.operator_prerequisite_tool_count,
      'airgap_bundle_check_report.operator_prerequisite_tool_count'
    )
  });
  assertAirgapSubstrate(manifest.substrate);

  assertIntegerEquals(
    report.components_count,
    componentsCount,
    'airgap_bundle_check_report.components_count'
  );
  assertIntegerEquals(
    report.image_artifact_declaration_count,
    imageArtifactDeclarationCount,
    'airgap_bundle_check_report.image_artifact_declaration_count'
  );
  assertIntegerEquals(
    reportArtifactSummary.manifestImageDeclarationCount,
    imageArtifactDeclarationCount,
    'airgap_bundle_check_report.artifacts.bundle_manifest.image_artifact_declaration_count'
  );
  assertIntegerEquals(
    payloadArtifactCount,
    report.payload_artifact_count,
    'airgap_bundle_manifest.payload_artifacts count'
  );
  assertIntegerEquals(
    operatorPrerequisiteSummary.toolCount,
    report.tool_count,
    'airgap_bundle_manifest.operator_prerequisites.tools count'
  );
}

async function assertReleaseKitOutputSemantics({
  evidenceRoot,
  evidence,
  releaseContractInput,
  targetProfile,
  releaseKitOutput,
  provenance
}) {
  switch (releaseKitOutput) {
    case 'image-map.json': {
      const imageMapInput = await readEvidenceOutputJson(evidenceRoot, 'image-map.json');
      assertImageMapOutput({
        imageMap: requireObject(imageMapInput.value, 'image_map'),
        evidence,
        releaseContractInput,
        targetProfile
      });
      return;
    }
    case 'online-deployment-gate-report.json': {
      const reportInput = await readEvidenceOutputJson(
        evidenceRoot,
        'online-deployment-gate-report.json'
      );
      assertOnlineDeploymentGateOutput({
        report: requireObject(reportInput.value, 'online_deployment_gate'),
        evidence,
        releaseContractInput,
        targetProfile,
        provenance
      });
      return;
    }
    case AIRGAP_BUNDLE_EVIDENCE_OUTPUT: {
      const reportInput = await readEvidenceOutputJson(
        evidenceRoot,
        'airgap-bundle-check-report.json'
      );
      const manifestInput = await readEvidenceOutputJson(
        evidenceRoot,
        'airgap-bundle-manifest.json'
      );
      const imageMapInput = await readEvidenceOutputJson(evidenceRoot, 'image-map.json');
      assertAirgapBundleOutput({
        report: requireObject(reportInput.value, 'airgap_bundle_check_report'),
        manifest: requireObject(manifestInput.value, 'airgap_bundle_manifest'),
        manifestInputDigest: manifestInput.inputDigest,
        imageMap: requireObject(imageMapInput.value, 'image_map'),
        imageMapInputDigest: imageMapInput.inputDigest,
        evidence,
        releaseContractInput,
        targetProfile
      });
      return;
    }
    default:
      fail(`evidence.release_kit_output ${releaseKitOutput} is not accepted`);
  }
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
        files_count: subjectFiles.files_count,
        files: subjectFiles.files
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
  assertReleaseContractIncludesTargetProfile(releaseContractInput.value, targetProfile);
  assertReleaseKitOutputTarget(releaseKitOutput, targetProfile);
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
  await assertReleaseKitOutputSemantics({
    evidenceRoot,
    evidence,
    releaseContractInput,
    targetProfile,
    releaseKitOutput,
    provenance
  });

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
