#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { validateSubstratePackManifest } from './lib/substrate-pack-manifest-validation.mjs';
import { CURRENT_RELEASE_KIT_VERSION } from './lib/release-kit-version-policy.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'targetProfile',
  'targetRegistry',
  'runbook',
  'script',
  'profileValuesSchema',
  'operatorPrerequisites',
  'bundleRoot',
  'outputDir'
];
const AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const KIT_AIRGAP_TARGET_PROFILE = 'existing_kubernetes/kit_installed/airgap';
const AIRGAP_BUNDLE_TARGET_PROFILE_VALUES = [
  AIRGAP_TARGET_PROFILE,
  KIT_AIRGAP_TARGET_PROFILE
];
const AIRGAP_BUNDLE_TARGET_PROFILE_SET = new Set(AIRGAP_BUNDLE_TARGET_PROFILE_VALUES);
const REPORT_SCHEMA = 'agentsmith.airgap-bundle-create-report/v1';
const REPORT_SCOPE = 'airgap_bundle_create_only';
const REPORT_FILE = 'bundle-create-report.json';
const SELF_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const BUNDLE_MANIFEST_FILE = 'airgap-bundle-manifest.json';
const EVIDENCE_SCHEMA = 'agentsmith.release-kit-evidence-envelope/v1';
const EVIDENCE_SUBJECT_SCHEMA = 'agentsmith.release-kit-evidence-subject/v1';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const PRODUCER_REPO = 'github.com/agentsmith-project/agentsmith-release-kit';
const EVIDENCE_SUBJECT_NAME = 'release-kit-evidence-subject';
const EVIDENCE_SUBJECT_URI = 'evidence-subject.json';
const EVIDENCE_RELEASE_KIT_OUTPUT = 'airgap_bundle_check';
const EVIDENCE_OUTPUT_FILES = [
  'airgap-bundle-check-report.json',
  'airgap-bundle-manifest.json',
  'image-map.json',
  'substrate-pack-manifest.json'
];
const MANAGED_EVIDENCE_ENTRIES = [
  'evidence.json',
  'evidence-subject.json',
  ...EVIDENCE_OUTPUT_FILES
];
const MANAGED_EVIDENCE_ENTRY_SET = new Set(MANAGED_EVIDENCE_ENTRIES);
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
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const OPERATOR_REF_URI_SCHEME_RE = /\b[a-z][a-z0-9+.-]*:\/\/[^\s]*/i;
const SAFE_SEGMENT_RE = /^[A-Za-z0-9_.-]+$/;
const BUNDLED_TOOL_KEYS = new Set(['name', 'version', 'source', 'path', 'sha256']);
const OPERATOR_PREREQUISITE_TOOL_KEYS = new Set([
  'name',
  'version',
  'source',
  'location',
  'proof'
]);
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
  node scripts/verify-bundle-create.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap \\
    --target-registry <registry-host[/namespace]> \\
    --image-archive <image_id=local-file> [repeat] \\
    --runbook <file> \\
    --script <file> \\
    --profile-values-schema <file> \\
    [--profile-values-example <file>] \\
    [--substrate-pack-manifest <json> for existing_kubernetes/kit_installed/airgap] \\
    --operator-prerequisites <json> \\
    --bundle-root <dir> \\
    --output-dir <dir> \\
    [--evidence-root <dir> --evidence-provenance <json> for existing_kubernetes/<external_declared|kit_installed>/airgap]`;
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
    imageArchives: []
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
      case '--archive':
        parsed.archive = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--target-registry':
        parsed.targetRegistry = nextValue();
        break;
      case '--image-archive':
        parsed.imageArchives.push(nextValue());
        break;
      case '--runbook':
        parsed.runbook = nextValue();
        break;
      case '--script':
        parsed.script = nextValue();
        break;
      case '--profile-values-schema':
        parsed.profileValuesSchema = nextValue();
        break;
      case '--profile-values-example':
        parsed.profileValuesExample = nextValue();
        break;
      case '--substrate-pack-manifest':
        parsed.substratePackManifest = nextValue();
        break;
      case '--operator-prerequisites':
        parsed.operatorPrerequisites = nextValue();
        break;
      case '--bundle-root':
        parsed.bundleRoot = nextValue();
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
  if (parsed.imageArchives.length === 0) {
    cliFail('missing required argument: --image-archive');
  }
  if (parsed.evidenceProvenance && !parsed.evidenceRoot) {
    cliFail('--evidence-provenance requires --evidence-root <dir>');
  }
  if (parsed.evidenceRoot && !parsed.evidenceProvenance) {
    cliFail('--evidence-root requires --evidence-provenance <json>');
  }

  return parsed;
}

function findOutputDirArg(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (value && value.trim() !== '' && !value.startsWith('--')) {
      return value;
    }
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

async function digestFile(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return digestBuffer(buffer);
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
      raw,
      inputDigest: digestBuffer(Buffer.from(raw))
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function removeManagedReports(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, SELF_CHECK_REPORT_FILE), { force: true });
}

async function removeManagedEvidenceOutputs(evidenceRoot) {
  for (const entry of MANAGED_EVIDENCE_ENTRIES) {
    const file = path.join(evidenceRoot, entry);
    let stat;
    try {
      stat = await fs.lstat(file);
    } catch (error) {
      if (error.code === 'ENOENT') {
        continue;
      }
      fail(`cannot inspect managed evidence entry ${entry}: ${error.message}`);
    }
    if (!stat.isFile() && !stat.isSymbolicLink()) {
      fail(`managed evidence entry ${entry} must be a file or symlink; remove it manually`);
    }
    try {
      await fs.unlink(file);
    } catch (error) {
      fail(`cannot remove managed evidence entry ${entry}: ${error.message}`);
    }
  }
}

async function assertEvidenceRootPreflight(args) {
  if (!args.evidenceRoot) {
    return;
  }

  const evidenceRoot = path.resolve(args.evidenceRoot);
  let rootStat;
  try {
    rootStat = await fs.lstat(evidenceRoot);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      fail(`cannot inspect evidence root: ${error.message}`);
    }
  }

  if (rootStat) {
    if (rootStat.isSymbolicLink()) {
      fail('evidence root must not be a symlink');
    }
    if (!rootStat.isDirectory()) {
      fail('evidence root must be absent or a directory');
    }
    let rootEntries;
    try {
      rootEntries = await fs.readdir(evidenceRoot);
    } catch (error) {
      fail(`cannot read evidence root: ${error.message}`);
    }
    for (const entry of rootEntries.sort()) {
      if (!MANAGED_EVIDENCE_ENTRY_SET.has(entry)) {
        fail(`evidence root contains non-managed entry ${entry}; remove it manually`);
      }
    }
  }

  for (const entry of MANAGED_EVIDENCE_ENTRIES) {
    const file = path.join(evidenceRoot, entry);
    let stat;
    try {
      stat = await fs.lstat(file);
    } catch (error) {
      if (error.code === 'ENOENT') {
        continue;
      }
      fail(`cannot inspect managed evidence entry ${entry}: ${error.message}`);
    }
    if (!stat.isFile() && !stat.isSymbolicLink()) {
      fail(`managed evidence entry ${entry} must be a file or symlink; remove it manually`);
    }
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

function assertStringEquals(value, expected, label) {
  const actual = requireString(value, label);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function assertAllowedKeys(object, allowedKeys, label) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function parseTargetProfile(value) {
  const text = requireString(value, 'target_profile');
  if (!AIRGAP_BUNDLE_TARGET_PROFILE_SET.has(text)) {
    fail(`--bundle-create only accepts ${AIRGAP_BUNDLE_TARGET_PROFILE_VALUES.join(' or ')}`);
  }
  const [targetCluster, substrateSource, distribution] = text.split('/');
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateEvidenceArgs(args, targetProfile) {
  if (args.evidenceRoot && !AIRGAP_BUNDLE_TARGET_PROFILE_SET.has(targetProfile.value)) {
    cliFail(
      `--evidence-root is only accepted for ${AIRGAP_BUNDLE_TARGET_PROFILE_VALUES.join(' or ')}`
    );
  }
}

function assertSafeSegment(value, label) {
  const segment = requireString(value, label);
  if (
    segment !== segment.trim() ||
    segment === '.' ||
    segment === '..' ||
    !SAFE_SEGMENT_RE.test(segment) ||
    segment.includes('/') ||
    segment.includes('\\') ||
    URI_SCHEME_RE.test(segment)
  ) {
    fail(`${label} must be a safe file name segment`);
  }
  return segment;
}

function rejectUriOrWindowsPath(value, label) {
  if (value.trim() !== value) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be a local file path, not a URI`);
  }
  if (WINDOWS_DRIVE_RE.test(value)) {
    fail(`${label} must be a local POSIX path`);
  }
}

async function canonicalLocalFile(input, label) {
  const value = requireString(input, label);
  rejectUriOrWindowsPath(value, label);
  const resolved = path.resolve(value);

  let stat;
  try {
    stat = await fs.lstat(resolved);
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
    return await fs.realpath(resolved);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

async function assertBundleRootAvailable(input) {
  const value = requireString(input, 'bundle_root');
  rejectUriOrWindowsPath(value, 'bundle_root');
  const resolved = path.resolve(value);

  let stat;
  try {
    stat = await fs.lstat(resolved);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return resolved;
    }
    fail(`cannot read bundle root: ${error.message}`);
  }

  if (stat.isSymbolicLink()) {
    fail('bundle root must not be a symlink');
  }
  if (!stat.isDirectory()) {
    fail('bundle root must be absent or an empty directory');
  }
  const entries = await fs.readdir(resolved);
  if (entries.length > 0) {
    fail('bundle root must be absent or empty');
  }
  return resolved;
}

function isSecretLookingText(value) {
  return SECRET_VALUE_RE.some((pattern) => pattern.test(value));
}

async function assertSafePayloadFile(file, label) {
  const buffer = await fs.readFile(file);
  if (buffer.includes(0)) {
    fail(`${label} must be text`);
  }
  const text = buffer.toString('utf8');
  if (isSecretLookingText(text)) {
    fail(`${label} must not contain secret-looking content`);
  }
}

function assertOperatorRef(value, label) {
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
  if (isSecretLookingText(ref)) {
    fail(`${label} must not contain secret-looking content`);
  }
  return ref;
}

function validateEvidenceProvenanceInput(value) {
  const provenance = requireObject(value, 'evidence_provenance');
  assertStringEquals(
    provenance.schema_version,
    ARTIFACT_PROVENANCE_SCHEMA,
    'evidence_provenance.schema_version'
  );
  const provenanceKind = assertStringEquals(
    provenance.provenance_kind,
    'ci_artifact',
    'evidence_provenance.provenance_kind'
  );
  assertAllowedKeys(provenance, CI_PROVENANCE_INPUT_FIELDS, 'evidence_provenance');

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

  const runId = requireString(provenance.run_id, 'evidence_provenance.run_id');
  if (typeof provenance.attestation === 'undefined') {
    fail('evidence_provenance.attestation is required');
  }
  return {
    schema_version: ARTIFACT_PROVENANCE_SCHEMA,
    provenance_kind: provenanceKind,
    producer_repo: producerRepo,
    normalized_remote: normalizedRemote,
    commit_sha: requireString(provenance.commit_sha, 'evidence_provenance.commit_sha'),
    artifact_uri: requireString(provenance.artifact_uri, 'evidence_provenance.artifact_uri'),
    generated_at: requireString(provenance.generated_at, 'evidence_provenance.generated_at'),
    generator_command: requireString(
      provenance.generator_command,
      'evidence_provenance.generator_command'
    ),
    generator_version: requireString(
      provenance.generator_version,
      'evidence_provenance.generator_version'
    ),
    attestation: provenance.attestation,
    workflow_name: requireString(provenance.workflow_name, 'evidence_provenance.workflow_name'),
    run_id: runId,
    run_attempt: requireString(provenance.run_attempt, 'evidence_provenance.run_attempt'),
    job: requireString(provenance.job, 'evidence_provenance.job')
  };
}

async function loadEvidenceProvenance(args) {
  if (!args.evidenceRoot) {
    return undefined;
  }
  const input = await readJson(args.evidenceProvenance, 'evidence provenance');
  return validateEvidenceProvenanceInput(input.value);
}

async function normalizeOperatorPrerequisites(inputFile) {
  const input = await readJson(inputFile, 'operator prerequisites');
  const object = requireObject(input.value, 'operator_prerequisites');

  const substrateConnectionTruthRef = assertOperatorRef(
    object.substrate_connection_truth_ref,
    'operator_prerequisites.substrate_connection_truth_ref'
  );
  const targetRegistryProofRef = assertOperatorRef(
    object.target_registry_proof_ref,
    'operator_prerequisites.target_registry_proof_ref'
  );
  const tools = requireArray(object.tools, 'operator_prerequisites.tools');
  if (tools.length === 0) {
    fail('operator_prerequisites.tools must not be empty');
  }

  const outputPaths = new Set();
  const normalizedTools = [];
  for (const [index, value] of tools.entries()) {
    const label = `operator_prerequisites.tools[${index}]`;
    const tool = requireObject(value, label);
    const source = requireString(tool.source, `${label}.source`);

    if (source === 'bundled') {
      assertAllowedKeys(tool, BUNDLED_TOOL_KEYS, label);
      const name = assertSafeSegment(tool.name, `${label}.name`);
      const version = requireString(tool.version, `${label}.version`);
      const sourcePath = await canonicalLocalFile(tool.path, `${label}.path`);
      const sourceSha256 = await digestFile(sourcePath, `${label}.path`);
      if (Object.prototype.hasOwnProperty.call(tool, 'sha256')) {
        const expectedSha256 = requireDigest(tool.sha256, `${label}.sha256`);
        if (expectedSha256 !== sourceSha256) {
          fail(`${label}.sha256 must match bundled tool file sha256`);
        }
      }
      const bundlePath = `tools/${name}`;
      if (outputPaths.has(bundlePath)) {
        fail(`operator_prerequisites.tools contains duplicate bundled output path: ${bundlePath}`);
      }
      outputPaths.add(bundlePath);
      normalizedTools.push({
        name,
        version,
        source,
        sourcePath,
        bundlePath,
        sha256: sourceSha256
      });
    } else if (source === 'operator_prerequisite') {
      assertAllowedKeys(tool, OPERATOR_PREREQUISITE_TOOL_KEYS, label);
      normalizedTools.push({
        name: requireString(tool.name, `${label}.name`),
        version: requireString(tool.version, `${label}.version`),
        source,
        location: assertOperatorRef(tool.location, `${label}.location`),
        proof: assertOperatorRef(tool.proof, `${label}.proof`)
      });
    } else {
      fail(`${label}.source is invalid`);
    }
  }

  return {
    substrate_connection_truth_ref: substrateConnectionTruthRef,
    target_registry_proof_ref: targetRegistryProofRef,
    tools: normalizedTools
  };
}

async function normalizePayloadInputs(args) {
  const entries = [
    ['runbook', 'runbook', args.runbook, 'payload/runbook.md'],
    ['script', 'script', args.script, 'payload/install.sh'],
    [
      'profile_values_schema',
      'profile_values_schema',
      args.profileValuesSchema,
      'payload/profile-values.schema.json'
    ]
  ];
  if (args.profileValuesExample) {
    entries.push([
      'profile_values_example',
      'profile_values_example',
      args.profileValuesExample,
      'payload/profile-values.example.yaml'
    ]);
  }

  const normalized = [];
  for (const [id, kind, input, bundlePath] of entries) {
    const sourcePath = await canonicalLocalFile(input, `${kind} payload`);
    await assertSafePayloadFile(sourcePath, `${kind} payload`);
    if (kind === 'profile_values_schema') {
      await readJson(sourcePath, 'profile values schema');
    }
    normalized.push({
      id,
      kind,
      sourcePath,
      bundlePath
    });
  }
  return normalized;
}

async function normalizeSubstratePackManifest(args, targetProfile) {
  const requiresSubstratePack = targetProfile.value === KIT_AIRGAP_TARGET_PROFILE;
  if (!requiresSubstratePack) {
    if (args.substratePackManifest) {
      fail(`--substrate-pack-manifest is only accepted for ${KIT_AIRGAP_TARGET_PROFILE}`);
    }
    return undefined;
  }
  if (!args.substratePackManifest) {
    cliFail('missing required argument: --substrate-pack-manifest');
  }

  const sourcePath = await canonicalLocalFile(
    args.substratePackManifest,
    'substrate pack manifest'
  );
  const input = await readJson(sourcePath, 'substrate pack manifest');
  validateSubstratePackManifest(input.value, targetProfile, { fail });

  return {
    sourcePath,
    bundlePath: 'components/substrate-pack-manifest.json',
    inputDigest: input.inputDigest
  };
}

async function normalizeImageArchives(values) {
  const seen = new Set();
  const normalized = [];
  for (const [index, value] of values.entries()) {
    const label = `image_archive[${index}]`;
    const separator = value.indexOf('=');
    if (separator < 1 || separator === value.length - 1) {
      fail(`--image-archive must be <image_id=local-file>: ${value}`);
    }
    const id = assertSafeSegment(value.slice(0, separator), `${label}.id`);
    if (seen.has(id)) {
      fail(`--image-archive contains duplicate image id: ${id}`);
    }
    seen.add(id);
    const sourcePath = await canonicalLocalFile(value.slice(separator + 1), `${label}.path`);
    normalized.push({
      id,
      sourcePath,
      bundlePath: `images/${id}.oci-layout.tar`
    });
  }
  return normalized;
}

function assertImageArchiveCoverage(imageArchives, imageMap) {
  const mappings = requireArray(imageMap.mappings, 'image_map.mappings');
  const mappingIds = new Set();
  for (const [index, mappingValue] of mappings.entries()) {
    const mapping = requireObject(mappingValue, `image_map.mappings[${index}]`);
    mappingIds.add(assertSafeSegment(mapping.id, `image_map.mappings[${index}].id`));
  }

  const archiveIds = new Set(imageArchives.map((archive) => archive.id));
  for (const archive of imageArchives) {
    if (!mappingIds.has(archive.id)) {
      fail(`--image-archive id is not declared by image-map mappings: ${archive.id}`);
    }
  }
  for (const id of mappingIds) {
    if (!archiveIds.has(id)) {
      fail(`--image-archive is missing image-map mapping id: ${id}`);
    }
  }
  if (archiveIds.size !== mappingIds.size) {
    fail('--image-archive entries must match image-map mappings one-to-one');
  }
}

function runNodeScript(scriptName, args, label) {
  const result = spawnSync(process.execPath, [path.join(SCRIPT_DIR, scriptName), ...args], {
    cwd: ROOT_DIR,
    stdio: 'inherit'
  });
  if (result.error) {
    fail(`${label} failed to start: ${result.error.message}`);
  }
  if (result.status !== 0) {
    fail(`${label} failed`);
  }
}

async function copyInputFile(sourcePath, bundleRoot, relativePath) {
  const destination = path.join(bundleRoot, ...relativePath.split('/'));
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.copyFile(sourcePath, destination);
  return {
    path: relativePath,
    sha256: await digestFile(destination, relativePath)
  };
}

async function writeJsonFile(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`);
}

async function writeTextFile(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, value);
}

function imageDeclarationFor(mapping, copiedArtifact) {
  return {
    id: mapping.id,
    source_image: mapping.source_image,
    source_digest: mapping.source_digest,
    target_image: mapping.target_image,
    target_digest: mapping.target_digest,
    artifact_format: 'oci_layout_tar',
    path: copiedArtifact.path,
    sha256: copiedArtifact.sha256
  };
}

function operatorPrerequisitesForManifest(normalized) {
  return {
    substrate_connection_truth_ref: normalized.substrate_connection_truth_ref,
    target_registry_proof_ref: normalized.target_registry_proof_ref,
    tools: normalized.tools.map((tool) => {
      if (tool.source === 'bundled') {
        return {
          name: tool.name,
          version: tool.version,
          source: tool.source,
          path: tool.bundlePath,
          sha256: tool.sha256
        };
      }
      return {
        name: tool.name,
        version: tool.version,
        source: tool.source,
        location: tool.location,
        proof: tool.proof
      };
    })
  };
}

async function assembleBundle({
  args,
  bundleRoot,
  targetProfile,
  imageMapPath,
  imageArchives,
  payloadInputs,
  operatorPrerequisites,
  substratePackManifest
}) {
  await fs.mkdir(bundleRoot, { recursive: true });

  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const deployTemplatePackageInput = await readJson(
    args.deployTemplatePackage,
    'deploy template package'
  );
  const imageMapInput = await readJson(imageMapPath, 'image map');
  const deployTemplateArchiveInputDigest = await digestFile(
    args.archive,
    'deploy template archive'
  );
  const releaseContract = requireObject(releaseContractInput.value, 'release_contract');
  const deployTemplatePackage = requireObject(
    deployTemplatePackageInput.value,
    'deploy_template_package'
  );
  const imageMap = requireObject(imageMapInput.value, 'image_map');
  const mappings = requireArray(imageMap.mappings, 'image_map.mappings');

  const componentPaths = {
    release_contract: 'components/release-contract.json',
    deploy_template_package: 'components/deploy-template-package.json',
    deploy_template_archive: 'components/agentsmith-deploy-template-package.tgz',
    image_map: 'components/image-map.json'
  };
  const components = [
    {
      kind: 'release_contract',
      ...(await copyInputFile(args.releaseContract, bundleRoot, componentPaths.release_contract))
    },
    {
      kind: 'deploy_template_package',
      ...(await copyInputFile(
        args.deployTemplatePackage,
        bundleRoot,
        componentPaths.deploy_template_package
      ))
    },
    {
      kind: 'deploy_template_archive',
      ...(await copyInputFile(args.archive, bundleRoot, componentPaths.deploy_template_archive))
    },
    {
      kind: 'image_map',
      ...(await copyInputFile(imageMapPath, bundleRoot, componentPaths.image_map))
    }
  ];
  if (substratePackManifest) {
    components.push({
      kind: 'substrate_pack_manifest',
      ...(await copyInputFile(
        substratePackManifest.sourcePath,
        bundleRoot,
        substratePackManifest.bundlePath
      ))
    });
  }

  const imageArchiveById = new Map(imageArchives.map((archive) => [archive.id, archive]));
  const imageArtifactDeclarations = [];
  for (const mappingValue of mappings) {
    const mapping = requireObject(mappingValue, 'image_map.mappings[]');
    const archive = imageArchiveById.get(mapping.id);
    const copied = await copyInputFile(archive.sourcePath, bundleRoot, archive.bundlePath);
    imageArtifactDeclarations.push(imageDeclarationFor(mapping, copied));
  }

  const payloadArtifacts = [];
  const checksumInputs = [...components, ...imageArtifactDeclarations];
  for (const payload of payloadInputs) {
    const copied = await copyInputFile(payload.sourcePath, bundleRoot, payload.bundlePath);
    const artifact = {
      id: payload.id,
      kind: payload.kind,
      path: copied.path,
      sha256: copied.sha256
    };
    payloadArtifacts.push(artifact);
    checksumInputs.push(artifact);
  }

  for (const tool of operatorPrerequisites.tools) {
    if (tool.source !== 'bundled') {
      continue;
    }
    const copied = await copyInputFile(tool.sourcePath, bundleRoot, tool.bundlePath);
    tool.sha256 = copied.sha256;
    checksumInputs.push({
      id: `tool_${tool.name}`,
      kind: 'tool',
      path: copied.path,
      sha256: copied.sha256
    });
  }

  const checksumsText = checksumInputs
    .map((item) => `${item.sha256}  ${item.path}`)
    .sort()
    .join('\n') + '\n';
  const checksumsPath = 'payload/checksums.txt';
  await writeTextFile(path.join(bundleRoot, checksumsPath), checksumsText);
  const checksumsSha256 = await digestFile(
    path.join(bundleRoot, checksumsPath),
    checksumsPath
  );
  payloadArtifacts.push({
    id: 'bundle_checksums',
    kind: 'checksums',
    path: checksumsPath,
    sha256: checksumsSha256
  });

  const releaseId = requireString(releaseContract.release_id, 'release_contract.release_id');
  const gitSha = requireString(releaseContract.git_sha, 'release_contract.git_sha');
  const deployTemplateManifestSha256 = requireDigest(
    deployTemplatePackage.manifest_sha256,
    'deploy_template_package.manifest_sha256'
  );

  const componentDigestByKind = Object.fromEntries(
    components.map((component) => [component.kind, component.sha256])
  );
  const bindings = {
    release_contract_sha256: componentDigestByKind.release_contract,
    deploy_template_package_sha256: componentDigestByKind.deploy_template_package,
    deploy_template_archive_sha256: deployTemplateArchiveInputDigest,
    deploy_template_manifest_sha256: deployTemplateManifestSha256,
    image_map_sha256: componentDigestByKind.image_map
  };
  if (substratePackManifest) {
    bindings.substrate_pack_manifest_sha256 =
      componentDigestByKind.substrate_pack_manifest;
  }
  const manifest = {
    schema_version: 'agentsmith.airgap-bundle-manifest/v1',
    release_id: releaseId,
    git_sha: gitSha,
    bindings,
    components,
    image_artifact_declarations: imageArtifactDeclarations,
    payload_artifacts: payloadArtifacts,
    operator_prerequisites: operatorPrerequisitesForManifest(operatorPrerequisites)
  };

  const manifestPath = path.join(bundleRoot, BUNDLE_MANIFEST_FILE);
  await writeJsonFile(manifestPath, manifest);

  return {
    releaseId,
    gitSha,
    releaseContractInputDigest: releaseContractInput.inputDigest,
    deployTemplatePackageInputDigest: deployTemplatePackageInput.inputDigest,
    deployTemplatePackage,
    deployTemplateArchiveInputDigest,
    imageMapInputDigest: imageMapInput.inputDigest,
    imageMapImageCount: mappings.length,
    bundleChecksumsInputDigest: checksumsSha256,
    substratePackManifestInputDigest: substratePackManifest?.inputDigest,
    manifestPath
  };
}

function buildReport({
  targetProfile,
  assembly,
  bundleManifestInputDigest,
  checkReportInputDigest,
  checkReport
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: assembly.releaseId,
    git_sha: assembly.gitSha,
    target_profile: targetProfile,
    artifacts: {
      release_contract: {
        input_sha256: assembly.releaseContractInputDigest
      },
      deploy_template_package: {
        input_sha256: assembly.deployTemplatePackageInputDigest,
        package_sha256: assembly.deployTemplatePackage.package_sha256,
        manifest_sha256: assembly.deployTemplatePackage.manifest_sha256,
        artifact_sha256: assembly.deployTemplatePackage.artifact_provenance?.artifact_sha256
      },
      deploy_template_archive: {
        input_sha256: assembly.deployTemplateArchiveInputDigest
      },
      image_map: {
        input_sha256: assembly.imageMapInputDigest,
        image_count: assembly.imageMapImageCount
      },
      bundle_manifest: {
        input_sha256: bundleManifestInputDigest
      },
      bundle_checksums: {
        input_sha256: assembly.bundleChecksumsInputDigest
      },
      airgap_bundle_check_report: {
        input_sha256: checkReportInputDigest
      },
      ...(assembly.substratePackManifestInputDigest
        ? {
            substrate_pack_manifest: {
              input_sha256: assembly.substratePackManifestInputDigest
            }
          }
        : {})
    },
    components_count: checkReport.components_count,
    image_artifact_count: checkReport.image_artifact_declaration_count,
    payload_artifact_count: checkReport.payload_artifact_count,
    tool_count: checkReport.tool_count,
    bundled_tool_count: checkReport.bundled_tool_count,
    operator_prerequisite_tool_count: checkReport.operator_prerequisite_tool_count,
    substrate: {
      mode: targetProfile.substrate_source,
      bundled: targetProfile.substrate_source === 'kit_installed'
    }
  };
}

function evidenceProjection(evidence) {
  const { artifact_provenance: _artifactProvenance, ...subject } = evidence;
  return subject;
}

function buildEvidenceBase({ targetProfile, assembly }) {
  return {
    schema_version: EVIDENCE_SCHEMA,
    release_kit_output: EVIDENCE_RELEASE_KIT_OUTPUT,
    release_contract_digest: assembly.releaseContractInputDigest,
    release_id: assembly.releaseId,
    git_sha: assembly.gitSha,
    release_kit_version: CURRENT_RELEASE_KIT_VERSION,
    target_cluster: targetProfile.target_cluster,
    substrate_source: targetProfile.substrate_source,
    distribution: targetProfile.distribution,
    target: {
      cluster: targetProfile.target_cluster,
      server: targetProfile.value
    },
    status: 'passed',
    failure_class: 'none'
  };
}

function buildEvidenceSubject({ evidence, outputDigests }) {
  return {
    schema_version: EVIDENCE_SUBJECT_SCHEMA,
    files: [
      {
        path: 'evidence.json',
        sha256: canonicalDigest(evidenceProjection(evidence))
      },
      ...outputDigests.map(([relativePath, sha256]) => ({
        path: relativePath,
        sha256
      }))
    ]
  };
}

function buildEvidenceArtifactProvenance(provenance, subjectSha256) {
  return {
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
    subject_sha256: subjectSha256,
    workflow_name: provenance.workflow_name,
    run_id: provenance.run_id,
    run_attempt: provenance.run_attempt,
    job: provenance.job
  };
}

async function copyEvidenceOutputFile(source, stagingRoot, relativePath) {
  const destination = path.join(stagingRoot, relativePath);
  await fs.copyFile(source, destination);
  return [relativePath, await digestFile(destination, relativePath)];
}

async function moveManagedEvidenceFiles(stagingRoot, evidenceRoot) {
  await fs.mkdir(evidenceRoot, { recursive: true });
  for (const entry of MANAGED_EVIDENCE_ENTRIES) {
    const source = path.join(stagingRoot, entry);
    try {
      await fs.rename(source, path.join(evidenceRoot, entry));
    } catch (error) {
      if (error.code === 'ENOENT') {
        continue;
      }
      throw error;
    }
  }
}

async function writeAndValidateEvidenceRoot({
  args,
  bundleRoot,
  targetProfile,
  assembly,
  provenance
}) {
  if (!args.evidenceRoot) {
    return;
  }

  const evidenceRoot = path.resolve(args.evidenceRoot);
  const stagingRoot = path.join(evidenceRoot, `.bundle-create-evidence.${process.pid}.tmp`);

  await fs.rm(stagingRoot, { recursive: true, force: true });
  await fs.mkdir(stagingRoot, { recursive: true });

  try {
    const outputDigests = [];
    outputDigests.push(
      await copyEvidenceOutputFile(
        path.join(args.outputDir, SELF_CHECK_REPORT_FILE),
        stagingRoot,
        'airgap-bundle-check-report.json'
      )
    );
    outputDigests.push(
      await copyEvidenceOutputFile(
        assembly.manifestPath,
        stagingRoot,
        'airgap-bundle-manifest.json'
      )
    );
    outputDigests.push(
      await copyEvidenceOutputFile(
        path.join(bundleRoot, 'components/image-map.json'),
        stagingRoot,
        'image-map.json'
      )
    );
    if (targetProfile.value === KIT_AIRGAP_TARGET_PROFILE) {
      outputDigests.push(
        await copyEvidenceOutputFile(
          path.join(bundleRoot, 'components/substrate-pack-manifest.json'),
          stagingRoot,
          'substrate-pack-manifest.json'
        )
      );
    }

    const evidence = buildEvidenceBase({ targetProfile, assembly });
    const subject = buildEvidenceSubject({ evidence, outputDigests });
    evidence.artifact_provenance = buildEvidenceArtifactProvenance(
      provenance,
      canonicalDigest(subject)
    );

    await writeJsonFile(path.join(stagingRoot, 'evidence.json'), evidence);
    await writeJsonFile(path.join(stagingRoot, 'evidence-subject.json'), subject);

    runNodeScript(
      'verify-evidence.mjs',
      [
        '--release-contract',
        args.releaseContract,
        '--evidence-root',
        stagingRoot,
        '--target-profile',
        targetProfile.value,
        '--output-dir',
        path.join(stagingRoot, '.evidence-validation')
      ],
      'evidence self-check'
    );

    await removeManagedEvidenceOutputs(evidenceRoot);
    await moveManagedEvidenceFiles(stagingRoot, evidenceRoot);
  } finally {
    await fs.rm(stagingRoot, { recursive: true, force: true });
  }
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.bundle-create.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  const argv = process.argv.slice(2);
  const startupOutputDir = findOutputDirArg(argv);
  if (startupOutputDir) {
    await removeManagedReports(startupOutputDir);
  }

  const args = parseArgs(argv);
  if (args.help) {
    console.log(usage());
    return;
  }

  if (!startupOutputDir) {
    await removeManagedReports(args.outputDir);
  }
  let workDir;

  try {
    const targetProfile = parseTargetProfile(args.targetProfile);
    validateEvidenceArgs(args, targetProfile);
    const evidenceProvenance = await loadEvidenceProvenance(args);
    await assertEvidenceRootPreflight(args);
    const bundleRoot = await assertBundleRootAvailable(args.bundleRoot);
    const imageArchives = await normalizeImageArchives(args.imageArchives);
    const payloadInputs = await normalizePayloadInputs(args);
    const operatorPrerequisites = await normalizeOperatorPrerequisites(args.operatorPrerequisites);
    const substratePackManifest = await normalizeSubstratePackManifest(args, targetProfile);

    await fs.mkdir(args.outputDir, { recursive: true });
    workDir = await fs.mkdtemp(path.join(path.resolve(args.outputDir), '.bundle-create-work-'));
    const inputsDir = path.join(workDir, 'inputs');
    const templatePackageDir = path.join(workDir, 'template-package');
    const imageMapDir = path.join(workDir, 'image-map');

    runNodeScript(
      'verify-inputs.mjs',
      [
        '--release-contract',
        args.releaseContract,
        '--deploy-template-package',
        args.deployTemplatePackage,
        '--target-profile',
        args.targetProfile,
        '--output-dir',
        inputsDir
      ],
      'inputs precheck'
    );
    runNodeScript(
      'verify-template-package.mjs',
      [
        '--release-contract',
        args.releaseContract,
        '--deploy-template-package',
        args.deployTemplatePackage,
        '--archive',
        args.archive,
        '--output-dir',
        templatePackageDir
      ],
      'template package precheck'
    );
    runNodeScript(
      'verify-image-map.mjs',
      [
        '--release-contract',
        args.releaseContract,
        '--target-profile',
        args.targetProfile,
        '--target-registry',
        args.targetRegistry,
        '--output-dir',
        imageMapDir
      ],
      'image-map precheck'
    );

    const imageMapPath = path.join(imageMapDir, 'image-map.json');
    const imageMapInput = await readJson(imageMapPath, 'image map');
    assertImageArchiveCoverage(imageArchives, requireObject(imageMapInput.value, 'image_map'));

    const assembly = await assembleBundle({
      args,
      bundleRoot,
      targetProfile,
      imageMapPath,
      imageArchives,
      payloadInputs,
      operatorPrerequisites,
      substratePackManifest
    });

    runNodeScript(
      'verify-airgap-bundle-check.mjs',
      [
        '--release-contract',
        args.releaseContract,
        '--deploy-template-package',
        args.deployTemplatePackage,
        '--archive',
        args.archive,
        '--image-map',
        path.join(bundleRoot, 'components/image-map.json'),
        '--target-profile',
        args.targetProfile,
        '--bundle-root',
        bundleRoot,
        '--bundle-manifest',
        assembly.manifestPath,
        '--output-dir',
        args.outputDir
      ],
      'airgap bundle self-check'
    );

    const checkReportPath = path.join(args.outputDir, 'airgap-bundle-check-report.json');
    const checkReportInput = await readJson(checkReportPath, 'airgap bundle check report');
    const bundleManifestInputDigest = await digestFile(
      assembly.manifestPath,
      'airgap bundle manifest'
    );
    await writeAndValidateEvidenceRoot({
      args,
      bundleRoot,
      targetProfile,
      assembly,
      provenance: evidenceProvenance
    });

    const report = buildReport({
      targetProfile,
      assembly,
      bundleManifestInputDigest,
      checkReportInputDigest: checkReportInput.inputDigest,
      checkReport: requireObject(checkReportInput.value, 'airgap_bundle_check_report')
    });
    await writeReport(args.outputDir, report);

    console.log('PASS: airgap bundle assembled and self-check accepted readiness=false');
  } catch (error) {
    await removeManagedReports(args.outputDir);
    throw error;
  } finally {
    if (workDir) {
      await fs.rm(workDir, { recursive: true, force: true });
    }
  }
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
