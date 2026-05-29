#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { statSync } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { CURRENT_RELEASE_KIT_VERSION } from './lib/release-kit-version-policy.mjs';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERIFY_RELEASE = path.join(ROOT_DIR, 'scripts', 'verify-release.sh');
const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'targetProfile',
  'renderValues',
  'substrateTruth',
  'targetPrerequisites',
  'namespace',
  'outputDir'
];
const EXTERNAL_ONLINE_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const KIT_ONLINE_TARGET_PROFILE = 'existing_kubernetes/kit_installed/online';
const SUPPORTED_TARGET_PROFILE_VALUES = [
  EXTERNAL_ONLINE_TARGET_PROFILE,
  KIT_ONLINE_TARGET_PROFILE
];
const SUPPORTED_TARGET_PROFILE_SET = new Set(SUPPORTED_TARGET_PROFILE_VALUES);
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const REPORT_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const REPORT_SCOPE = 'online_deployment_gate_only';
const EVIDENCE_SCHEMA = 'agentsmith.release-kit-evidence-envelope/v1';
const EVIDENCE_SUBJECT_SCHEMA = 'agentsmith.release-kit-evidence-subject/v1';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const PRODUCER_REPO = 'github.com/agentsmith-project/agentsmith-release-kit';
const EVIDENCE_SUBJECT_NAME = 'release-kit-evidence-subject';
const EVIDENCE_SUBJECT_URI = 'evidence-subject.json';
const EVIDENCE_RELEASE_KIT_OUTPUT = 'online-deployment-gate-report.json';
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const PROVENANCE_KINDS = new Set(['ci_artifact', 'signed_operator_run']);
const RELEASE_KIT_GH_ARTIFACT_HOST = 'agentsmith-release-kit';
const GITHUB_ACTIONS_API_HOST = 'api.github.com';
const GITHUB_ACTIONS_API_OWNER = 'agentsmith-project';
const GITHUB_ACTIONS_API_REPO = 'agentsmith-release-kit';
const SIGNED_OPERATOR_RUN_ARTIFACT_SCHEME = 'signed-operator-run';
const COMMON_PROVENANCE_INPUT_FIELDS = [
  'schema_version',
  'provenance_kind',
  'producer_repo',
  'normalized_remote',
  'commit_sha',
  'artifact_uri',
  'generated_at',
  'generator_command',
  'generator_version',
  'attestation'
];
const CI_PROVENANCE_INPUT_FIELDS = new Set([
  ...COMMON_PROVENANCE_INPUT_FIELDS,
  'workflow_name',
  'run_id',
  'run_attempt',
  'job'
]);
const SIGNED_OPERATOR_RUN_PROVENANCE_INPUT_FIELDS = new Set([
  ...COMMON_PROVENANCE_INPUT_FIELDS,
  'operator_run_id',
  'operator_identity',
  'signature_uri',
  'signature_sha256'
]);
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
const MANAGED_OUTPUT_ENTRIES = [
  'online-deployment-gate-report.json',
  'inputs',
  'target-preflight',
  'substrate-pack-check',
  'template-package',
  'substrate-routability',
  'image-map',
  'registry-presence',
  'render',
  'render-check',
  'apply',
  'rollout',
  'smoke',
  'evidence-validation'
];
const MANAGED_EVIDENCE_ENTRIES = [
  'evidence.json',
  'evidence-subject.json',
  'online-deployment-gate-report.json'
];

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
    super(message || `online focused chain step failed: ${step}`);
    this.exitCode = status || 1;
  }
}

function usage() {
  return `Usage:
  node scripts/verify-online-deployment-gate.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --target-profile existing_kubernetes/external_declared/online|existing_kubernetes/kit_installed/online \\
    --render-values <json> \\
    --substrate-truth <json> \\
    --target-prerequisites <json> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--mode server-dry-run|apply] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
    [--confirm-apply <matching-target-profile>] \\
    [--operator-run-id <id>] \\
    [--timeout <duration>] \\
    [--smoke-url <https-url>] \\
    [--expected-status <code>] \\
    [--timeout-ms <ms>] \\
    [--allow-http] \\
    [--allow-localhost] \\
    [--target-registry <registry-host[/namespace]>] \\
    [--registry-probe <executable>] \\
    [--substrate-pack-manifest <json> --routability-probe <executable>] \\
    [--evidence-root <dir> --evidence-provenance <json>] \\
    [--forbidden-source-root <dir>]

Kit-installed online requires --substrate-pack-manifest and --routability-probe.
External-declared online rejects kit-only substrate args.`;
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

function extractEvidenceRootFromRawArgs(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--evidence-root') {
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
  if (!outputDir) {
    return;
  }
  await removeManagedOutputs(path.resolve(outputDir));
}

async function removeManagedEvidenceOutputsFromRawArgs(argv) {
  const evidenceRoot = extractEvidenceRootFromRawArgs(argv);
  if (!evidenceRoot) {
    return;
  }
  await removeManagedEvidenceOutputs(path.resolve(evidenceRoot));
}

function parseArgs(argv) {
  const parsed = {
    mode: 'server-dry-run',
    kubectl: 'kubectl',
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
      case '--target-profile':
        parsed.targetProfile = nextValue();
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
      case '--substrate-pack-manifest':
        parsed.substratePackManifest = nextValue();
        break;
      case '--namespace':
        parsed.namespace = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--evidence-root':
        parsed.evidenceRoot = nextValue();
        break;
      case '--evidence-provenance':
        parsed.evidenceProvenance = nextValue();
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
      case '--target-registry':
        parsed.targetRegistry = nextValue();
        break;
      case '--registry-probe':
        parsed.registryProbe = nextValue();
        break;
      case '--routability-probe':
        parsed.routabilityProbe = nextValue();
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
    fail(`--online-deployment-gate only accepts ${SUPPORTED_TARGET_PROFILE_VALUES.join(' or ')}`);
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

function isKitOnline(args) {
  return args.targetProfile.value === KIT_ONLINE_TARGET_PROFILE;
}

function isExternalOnline(args) {
  return args.targetProfile.value === EXTERNAL_ONLINE_TARGET_PROFILE;
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);

  if (!SUPPORTED_MODES.has(args.mode)) {
    cliFail('--mode must be server-dry-run or apply');
  }

  if (isExternalOnline(args) && (args.substratePackManifest || args.routabilityProbe)) {
    cliFail(
      '--substrate-pack-manifest and --routability-probe are only accepted with existing_kubernetes/kit_installed/online'
    );
  }

  if (isKitOnline(args)) {
    if (args.targetRegistry) {
      cliFail('--target-registry is not supported for existing_kubernetes/kit_installed/online');
    }
    if (args.registryProbe) {
      cliFail('--registry-probe is not supported for existing_kubernetes/kit_installed/online');
    }
    if (!args.substratePackManifest) {
      cliFail('--target-profile existing_kubernetes/kit_installed/online requires --substrate-pack-manifest <json>');
    }
    if (!args.routabilityProbe) {
      cliFail('--target-profile existing_kubernetes/kit_installed/online requires --routability-probe <executable>');
    }
  }

  const hasSmokeOption =
    args.smokeUrl ||
    args.expectedStatus !== undefined ||
    args.timeoutMs !== undefined ||
    args.allowHttp ||
    args.allowLocalhost;
  if (args.mode === 'server-dry-run' && args.smokeUrl) {
    fail('--smoke-url requires --mode apply');
  }
  if (!args.smokeUrl && hasSmokeOption) {
    fail('smoke options require --smoke-url');
  }

  if (args.mode === 'apply') {
    if (args.confirmApply !== args.targetProfile.value) {
      cliFail(`--mode apply requires --confirm-apply ${args.targetProfile.value}`);
    }
    if (!args.operatorRunId) {
      cliFail('--mode apply requires --operator-run-id <id>');
    }
    validateOperatorRunId(args.operatorRunId);
  } else {
    if (args.confirmApply) {
      cliFail('--confirm-apply is only accepted with --mode apply');
    }
    if (args.operatorRunId) {
      cliFail('--operator-run-id is only accepted with --mode apply');
    }
    if (args.timeout) {
      cliFail('--timeout is only accepted with --mode apply');
    }
  }

  if (args.evidenceRoot && args.mode !== 'apply') {
    cliFail('--evidence-root requires --mode apply');
  }
  if (args.evidenceProvenance && !args.evidenceRoot) {
    cliFail('--evidence-provenance requires --evidence-root <dir>');
  }
  if (args.evidenceRoot && !args.evidenceProvenance) {
    cliFail('--evidence-root requires --evidence-provenance <json>');
  }

  if (args.registryProbe && !args.targetRegistry) {
    cliFail('--registry-probe requires --target-registry');
  }
  if (args.registryProbe && args.mode !== 'apply') {
    cliFail('--registry-probe is only accepted with --mode apply');
  }
  if (args.mode === 'apply' && args.targetRegistry && !args.registryProbe) {
    cliFail('--mode apply with --target-registry requires --registry-probe <executable>');
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

async function removeManagedEvidenceOutputs(evidenceRoot) {
  await Promise.all(
    MANAGED_EVIDENCE_ENTRIES.map((entry) =>
      fs.rm(path.join(evidenceRoot, entry), { recursive: true, force: true })
    )
  );
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
    value: contract,
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    input_sha256: input.input_sha256
  };
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
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
      if (SECRET_KEY_RE.test(key) && typeof nested === 'string') {
        issues.push(`${nestedLabel} contains a secret-looking payload`);
      }
      scanPayload(nested, nestedLabel, issues);
    }
  }

  return issues;
}

function assertNoUnsafePayload(value, label) {
  const issues = scanPayload(value, label);
  if (issues.length > 0) {
    fail(issues[0]);
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
    attestation_uri: requireRemoteUri(attestation.attestation_uri, `${label}.attestation_uri`),
    attestation_sha256: requireDigest(attestation.attestation_sha256, `${label}.attestation_sha256`)
  };
}

function validateEvidenceProvenanceInput(value, args) {
  const provenance = requireObject(value, 'evidence_provenance');
  assertNoUnsafePayload(provenance, 'evidence_provenance');

  assertFixedString(
    provenance.schema_version,
    ARTIFACT_PROVENANCE_SCHEMA,
    'evidence_provenance.schema_version'
  );
  const provenanceKind = requireEnumString(
    provenance.provenance_kind,
    'evidence_provenance.provenance_kind',
    PROVENANCE_KINDS
  );
  assertAllowedObjectFields(
    provenance,
    provenanceKind === 'ci_artifact'
      ? CI_PROVENANCE_INPUT_FIELDS
      : SIGNED_OPERATOR_RUN_PROVENANCE_INPUT_FIELDS,
    'evidence_provenance'
  );
  const producerRepo = requireString(
    provenance.producer_repo,
    'evidence_provenance.producer_repo'
  );
  const normalizedRemote = requireString(
    provenance.normalized_remote,
    'evidence_provenance.normalized_remote'
  );
  if (producerRepo !== normalizedRemote) {
    fail('evidence_provenance.producer_repo must match normalized_remote');
  }
  if (producerRepo !== PRODUCER_REPO) {
    fail(`evidence_provenance.producer_repo must be ${PRODUCER_REPO}`);
  }

  const common = {
    schema_version: ARTIFACT_PROVENANCE_SCHEMA,
    provenance_kind: provenanceKind,
    producer_repo: producerRepo,
    normalized_remote: normalizedRemote,
    commit_sha: requireGitSha(provenance.commit_sha, 'evidence_provenance.commit_sha'),
    generated_at: requireString(provenance.generated_at, 'evidence_provenance.generated_at'),
    generator_command: requireString(
      provenance.generator_command,
      'evidence_provenance.generator_command'
    ),
    generator_version: requireString(
      provenance.generator_version,
      'evidence_provenance.generator_version'
    ),
    attestation: readAttestation(provenance.attestation, 'evidence_provenance.attestation')
  };

  if (provenanceKind === 'ci_artifact') {
    const runId = requireString(provenance.run_id, 'evidence_provenance.run_id');
    return {
      ...common,
      artifact_uri: requireBoundArtifactUri(provenance.artifact_uri, 'evidence_provenance.artifact_uri', {
        provenanceKind,
        runId
      }),
      workflow_name: requireString(
        provenance.workflow_name,
        'evidence_provenance.workflow_name'
      ),
      run_id: runId,
      run_attempt: requireString(provenance.run_attempt, 'evidence_provenance.run_attempt'),
      job: requireString(provenance.job, 'evidence_provenance.job')
    };
  }

  const operatorRunId = requireString(
    provenance.operator_run_id,
    'evidence_provenance.operator_run_id'
  );
  if (operatorRunId !== args.operatorRunId) {
    fail('evidence_provenance.operator_run_id must match --operator-run-id');
  }
  return {
    ...common,
    artifact_uri: requireBoundArtifactUri(provenance.artifact_uri, 'evidence_provenance.artifact_uri', {
      provenanceKind,
      operatorRunId
    }),
    operator_run_id: operatorRunId,
    operator_identity: requireString(
      provenance.operator_identity,
      'evidence_provenance.operator_identity'
    ),
    signature_uri: requireRemoteUri(provenance.signature_uri, 'evidence_provenance.signature_uri'),
    signature_sha256: requireDigest(
      provenance.signature_sha256,
      'evidence_provenance.signature_sha256'
    )
  };
}

async function loadEvidenceProvenance(args) {
  if (!args.evidenceRoot) {
    return undefined;
  }
  const input = await readJsonFile(args.evidenceProvenance, 'evidence provenance');
  return validateEvidenceProvenanceInput(input.value, args);
}

function outputSubdir(args, name) {
  return path.join(args.outputDir, name);
}

function renderedManifestsDir(args) {
  return path.join(outputSubdir(args, 'render'), 'rendered-manifests');
}

function rolloutReportPath(args) {
  return path.join(outputSubdir(args, 'rollout'), 'rollout-report.json');
}

function relativeOutputPath(outputDir, file) {
  return path.relative(outputDir, file).split(path.sep).join('/');
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
      throw new StepError(name, 1, `online focused chain step report missing: ${name}`);
    }
    if (!stat.isFile()) {
      throw new StepError(name, 1, `online focused chain step report is not a file: ${name}`);
    }
  }
  steps.push({
    name,
    status: 'pass',
    report_paths: reportPaths.map((reportPath) => relativeOutputPath(args.outputDir, reportPath))
  });
}

function kubeArgs(args) {
  const argv = [];
  pushIfValue(argv, '--kubeconfig', args.kubeconfig);
  pushIfValue(argv, '--context', args.context);
  pushIfValue(argv, '--kubectl', args.kubectl);
  return argv;
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'online-deployment-gate-report.json');
  const tempFile = path.join(outputDir, `.online-deployment-gate.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function writeJsonFile(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`);
}

function buildCapabilityMap(targetProfile) {
  return {
    [targetProfile.value]: {
      declared: 'supported',
      intake: 'supported',
      preflight: 'supported',
      render: 'supported',
      apply: 'supported',
      rollout: 'supported',
      smoke: 'optional',
      evidence_envelope: 'optional'
    }
  };
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
    capability_map: buildCapabilityMap(args.targetProfile),
    steps,
    generated_at: new Date().toISOString()
  };
  if (args.mode === 'apply') {
    report.operator_run_id = args.operatorRunId;
  }
  return report;
}

function evidenceProjection(evidence) {
  const { artifact_provenance: _artifactProvenance, ...subject } = evidence;
  return subject;
}

function buildEvidenceBase({ releaseContract, args, substrateTruth }) {
  const targetProfile = args.targetProfile;
  return {
    schema_version: EVIDENCE_SCHEMA,
    release_kit_output: EVIDENCE_RELEASE_KIT_OUTPUT,
    release_contract_digest: releaseContract.input_sha256,
    release_id: releaseContract.release_id,
    git_sha: releaseContract.git_sha,
    release_kit_version: CURRENT_RELEASE_KIT_VERSION,
    target_cluster: targetProfile.target_cluster,
    substrate_source: targetProfile.substrate_source,
    distribution: targetProfile.distribution,
    target: {
      namespace: args.namespace,
      cluster: targetProfile.target_cluster,
      server: targetProfile.value
    },
    status: 'passed',
    failure_class: 'none',
    substrate_connection_truth: substrateTruth
  };
}

function buildEvidenceSubject({ evidence, gateReportSha256 }) {
  return {
    schema_version: EVIDENCE_SUBJECT_SCHEMA,
    files: [
      {
        path: 'evidence.json',
        sha256: canonicalDigest(evidenceProjection(evidence))
      },
      {
        path: EVIDENCE_RELEASE_KIT_OUTPUT,
        sha256: gateReportSha256
      }
    ]
  };
}

function buildEvidenceArtifactProvenance(provenance, subjectSha256) {
  const common = {
    schema_version: provenance.schema_version,
    provenance_kind: provenance.provenance_kind,
    producer_repo: provenance.producer_repo,
    normalized_remote: provenance.normalized_remote,
    commit_sha: provenance.commit_sha,
    artifact_uri: provenance.artifact_uri,
    generated_at: provenance.generated_at,
    generator_command: provenance.generator_command,
    generator_version: provenance.generator_version,
    attestation: provenance.attestation,
    subject_name: EVIDENCE_SUBJECT_NAME,
    subject_uri: EVIDENCE_SUBJECT_URI,
    subject_sha256: subjectSha256
  };

  if (provenance.provenance_kind === 'ci_artifact') {
    return {
      ...common,
      workflow_name: provenance.workflow_name,
      run_id: provenance.run_id,
      run_attempt: provenance.run_attempt,
      job: provenance.job
    };
  }

  return {
    ...common,
    operator_run_id: provenance.operator_run_id,
    operator_identity: provenance.operator_identity,
    signature_uri: provenance.signature_uri,
    signature_sha256: provenance.signature_sha256
  };
}

async function moveManagedEvidenceFiles(stagingRoot, evidenceRoot) {
  await fs.mkdir(evidenceRoot, { recursive: true });
  for (const entry of MANAGED_EVIDENCE_ENTRIES) {
    await fs.rename(path.join(stagingRoot, entry), path.join(evidenceRoot, entry));
  }
}

async function writeAndValidateEvidenceRoot({
  args,
  report,
  releaseContract,
  substrateTruth,
  provenance
}) {
  const evidenceRoot = path.resolve(args.evidenceRoot);
  const stagingRoot = path.join(evidenceRoot, `.online-deployment-gate-evidence.${process.pid}.tmp`);

  await fs.rm(stagingRoot, { recursive: true, force: true });
  await fs.mkdir(stagingRoot, { recursive: true });

  try {
    const stagingReportFile = path.join(stagingRoot, EVIDENCE_RELEASE_KIT_OUTPUT);
    await writeJsonFile(stagingReportFile, report);
    const gateReportSha256 = digestBuffer(await fs.readFile(stagingReportFile));

    const evidence = buildEvidenceBase({
      releaseContract,
      args,
      substrateTruth
    });
    const subject = buildEvidenceSubject({
      evidence,
      gateReportSha256
    });
    evidence.artifact_provenance = buildEvidenceArtifactProvenance(
      provenance,
      canonicalDigest(subject)
    );

    await writeJsonFile(path.join(stagingRoot, 'evidence.json'), evidence);
    await writeJsonFile(path.join(stagingRoot, 'evidence-subject.json'), subject);

    runVerify('evidence', '--evidence', [
      '--release-contract',
      args.releaseContract,
      '--evidence-root',
      stagingRoot,
      '--target-profile',
      args.targetProfile.value,
      '--output-dir',
      outputSubdir(args, 'evidence-validation')
    ]);

    await removeManagedEvidenceOutputs(evidenceRoot);
    await moveManagedEvidenceFiles(stagingRoot, evidenceRoot);
  } finally {
    await fs.rm(stagingRoot, { recursive: true, force: true });
  }
}

async function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    await Promise.all([
      removeManagedOutputsFromRawArgs(argv),
      removeManagedEvidenceOutputsFromRawArgs(argv)
    ]);
    throw error;
  }
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeManagedOutputs(args.outputDir);
  if (args.evidenceRoot) {
    await removeManagedEvidenceOutputs(path.resolve(args.evidenceRoot));
  }
  validateArgs(args);
  const evidenceProvenance = await loadEvidenceProvenance(args);

  const steps = [];
  const targetProfile = args.targetProfile.value;

  runStep({
    args,
    steps,
    name: 'inputs',
    mode: '--inputs',
    argv: [
      '--release-contract',
      args.releaseContract,
      '--deploy-template-package',
      args.deployTemplatePackage,
      '--target-profile',
      targetProfile,
      '--output-dir',
      outputSubdir(args, 'inputs')
    ],
    reportPaths: [path.join(outputSubdir(args, 'inputs'), 'target-profile-coverage-report.json')]
  });

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

  const substratePackCheckReportPath = path.join(
    outputSubdir(args, 'substrate-pack-check'),
    'substrate-pack-check-report.json'
  );
  if (isKitOnline(args)) {
    runStep({
      args,
      steps,
      name: 'substrate-pack-check',
      mode: '--substrate-pack-check',
      argv: [
        '--target-profile',
        targetProfile,
        '--substrate-pack-manifest',
        args.substratePackManifest,
        '--substrate-truth',
        args.substrateTruth,
        '--output-dir',
        outputSubdir(args, 'substrate-pack-check')
      ],
      reportPaths: [substratePackCheckReportPath]
    });
  }

  runStep({
    args,
    steps,
    name: 'template-package',
    mode: '--template-package',
    argv: [
      '--release-contract',
      args.releaseContract,
      '--deploy-template-package',
      args.deployTemplatePackage,
      '--archive',
      args.archive,
      '--output-dir',
      outputSubdir(args, 'template-package')
    ],
    reportPaths: [
      path.join(outputSubdir(args, 'template-package'), 'template-package-report.json')
    ]
  });

  if (isKitOnline(args)) {
    runStep({
      args,
      steps,
      name: 'substrate-routability',
      mode: '--substrate-routability',
      argv: [
        '--target-profile',
        targetProfile,
        '--substrate-pack-check-report',
        substratePackCheckReportPath,
        '--substrate-truth',
        args.substrateTruth,
        '--target-prerequisites',
        args.targetPrerequisites,
        '--namespace',
        args.namespace,
        ...kubeArgs(args),
        '--routability-probe',
        args.routabilityProbe,
        '--output-dir',
        outputSubdir(args, 'substrate-routability')
      ],
      reportPaths: [
        path.join(outputSubdir(args, 'substrate-routability'), 'substrate-routability-report.json')
      ]
    });
  }

  const imageMapPath = path.join(outputSubdir(args, 'image-map'), 'image-map.json');
  if (args.targetRegistry) {
    runStep({
      args,
      steps,
      name: 'image-map',
      mode: '--image-map',
      argv: [
        '--release-contract',
        args.releaseContract,
        '--target-profile',
        targetProfile,
        '--output-dir',
        outputSubdir(args, 'image-map'),
        '--target-registry',
        args.targetRegistry
      ],
      reportPaths: [imageMapPath]
    });

    if (args.mode === 'apply') {
      runStep({
        args,
        steps,
        name: 'registry-presence',
        mode: '--registry-presence',
        argv: [
          '--release-contract',
          args.releaseContract,
          '--image-map',
          imageMapPath,
          '--target-profile',
          targetProfile,
          '--registry-probe',
          args.registryProbe,
          '--output-dir',
          outputSubdir(args, 'registry-presence')
        ],
        reportPaths: [
          path.join(outputSubdir(args, 'registry-presence'), 'registry-presence-report.json')
        ]
      });
    }
  }

  const renderArgv = [
    '--release-contract',
    args.releaseContract,
    '--deploy-template-package',
    args.deployTemplatePackage,
    '--archive',
    args.archive,
    '--target-profile',
    targetProfile,
    '--render-values',
    args.renderValues,
    '--substrate-truth',
    args.substrateTruth,
    '--output-dir',
    outputSubdir(args, 'render')
  ];
  if (args.targetRegistry) {
    renderArgv.push('--image-map', imageMapPath);
  }
  appendForbiddenRoots(renderArgv, args);
  runStep({
    args,
    steps,
    name: 'render',
    mode: '--render',
    argv: renderArgv,
    reportPaths: [path.join(outputSubdir(args, 'render'), 'manifest-render-report.json')]
  });

  const renderCheckArgv = [
    '--release-contract',
    args.releaseContract,
    '--rendered-manifests',
    renderedManifestsDir(args),
    '--target-profile',
    targetProfile,
    '--output-dir',
    outputSubdir(args, 'render-check')
  ];
  appendForbiddenRoots(renderCheckArgv, args);
  runStep({
    args,
    steps,
    name: 'render-check',
    mode: '--render-check',
    argv: renderCheckArgv,
    reportPaths: [path.join(outputSubdir(args, 'render-check'), 'render-report.json')]
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
      args.targetProfile.value,
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
  const report = buildReport({
    releaseIdentity: releaseContract,
    args,
    steps
  });

  if (args.evidenceRoot) {
    const substrateTruth = (await readJsonFile(args.substrateTruth, 'substrate truth')).value;
    await writeAndValidateEvidenceRoot({
      args,
      report,
      releaseContract,
      substrateTruth,
      provenance: evidenceProvenance
    });
  }

  await writeReport(args.outputDir, report);

  console.log('PASS: online focused chain completed focused diagnostics');
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
