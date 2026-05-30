#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REPORT_FILE = 'release-engineering-gate-intake-report.json';
const REPORT_SCHEMA = 'agentsmith.release-engineering-gate-intake/v1';
const REPORT_SCOPE = 'release_engineering_gate_candidate_intake_only';
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const RELEASE_CONTRACT_SUBJECT_NAME = 'agentsmith-release-contract';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const ONLINE_ADOPTION_SCHEMA = 'agentsmith.online-adoption/v1';
const ONLINE_ADOPTION_SCOPE = 'online_adoption_aggregation_only';
const AIRGAP_ADOPTION_SCHEMA = 'agentsmith.airgap-adoption/v1';
const AIRGAP_ADOPTION_SCOPE = 'airgap_adoption_only';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const REQUIRED_ARGS = ['releaseContract', 'onlineAdoptionReport', 'outputDir'];
const REQUIRED_QUADRANTS = [
  'online/use_existing',
  'online/install_substrates',
  'airgap/use_existing',
  'airgap/install_substrates'
];
const REQUIRED_ONLINE_PATHS = {
  use_existing: {
    operatorPath: 'online/use_existing',
    targetProfile: 'existing_kubernetes/external_declared/online'
  },
  install_substrates: {
    operatorPath: 'online/install_substrates',
    targetProfile: 'existing_kubernetes/kit_installed/online'
  }
};
const REQUIRED_AIRGAP_STRATEGIES = {
  use_existing: {
    quadrant: 'airgap/use_existing',
    targetProfile: 'existing_kubernetes/external_declared/airgap'
  },
  install_substrates: {
    quadrant: 'airgap/install_substrates',
    targetProfile: 'existing_kubernetes/kit_installed/airgap'
  }
};
const REQUIRED_AIRGAP_DEPLOYMENT_STEPS = [
  'airgap-image-load',
  'airgap-bundle-render-check',
  'apply',
  'rollout',
  'smoke'
];
const FORBIDDEN_INPUT_KEYS = new Set([
  'release_verdict',
  'operator_verdict',
  'deploy_readiness',
  'package_readiness'
]);
const KNOWN_FOCUSED_PRODUCER_SCHEMAS = new Map([
  ['agentsmith.online-deployment-gate/v1', 'online deployment gate producer'],
  ['agentsmith.operator-release-surface-report/v1', 'operator release surface producer'],
  ['agentsmith.airgap-deployment-gate/v1', 'airgap deployment gate producer'],
  ['agentsmith.airgap-consume-rehearsal/v1', 'airgap consume rehearsal producer'],
  ['agentsmith.airgap-bundle-create-report/v1', 'airgap bundle create producer'],
  ['agentsmith.airgap-bundle-check-report/v1', 'airgap bundle check producer']
]);
const KNOWN_FOCUSED_PRODUCER_SCOPES = new Map([
  ['online_deployment_gate_only', 'online deployment gate producer'],
  ['operator_release_surface_v0', 'operator release surface producer'],
  ['airgap_deployment_gate_only', 'airgap deployment gate producer'],
  ['airgap_consume_rehearsal_only', 'airgap consume rehearsal producer'],
  ['airgap_bundle_create_only', 'airgap bundle create producer'],
  ['airgap_bundle_manifest_check_only', 'airgap bundle check producer']
]);
const LOCAL_OR_SECRET_TEXT_RE =
  /(?:^|["'\s])(?:\/(?:home|tmp|var|private)(?:\/|$)|[A-Za-z]:[\\/]|file:\/\/)|secretRef:|kubeconfig|Bearer\s+[A-Za-z0-9._~+/=-]+|token\s*[:=]|password\s*[:=]/i;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const SAFE_ARTIFACT_URI_SCHEMES = new Set(['gh-artifact', 'https']);
const SAFE_INTAKE_REPORT_URI_SCHEMES = new Set(['gh-artifact', 'https', 'signed-operator-run']);
const INTAKE_REPORT_URI_KEYS = new Set(['artifact_uri', 'report_uri', 'summary_uri']);

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
  node scripts/verify-release-engineering-gate-intake.mjs \\
    --release-contract <json> \\
    --online-adoption-report <online-adoption-report.json> \\
    --airgap-adoption-report <airgap use_existing airgap-adoption-report.json> \\
    --airgap-adoption-report <airgap install_substrates airgap-adoption-report.json> \\
    --output-dir <dir>

This is the repo-local release engineering gate candidate intake boundary only.
It consumes existing focused adoption outputs, writes ${REPORT_FILE} with
readiness=false and formal_verdict=not_issued, and does not issue deploy,
offline/package, operator, or release readiness.`;
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
    airgapAdoptionReports: []
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
      case '--online-adoption-report':
        parsed.onlineAdoptionReport = nextValue();
        break;
      case '--airgap-adoption-report':
        parsed.airgapAdoptionReports.push(nextValue());
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
  if (parsed.airgapAdoptionReports.length === 0) {
    cliFail('missing required argument: --airgap-adoption-report');
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
      value: JSON.parse(buffer.toString('utf8')),
      digest: digestBuffer(buffer),
      file
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

function requireBooleanFalse(value, label) {
  if (value !== false) {
    fail(`${label} must be false`);
  }
}

function requireBooleanTrue(value, label) {
  if (value !== true) {
    fail(`${label} must be true`);
  }
}

function requireNonNegativeInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function assertStringEquals(value, expected, label) {
  const text = requireString(value, label);
  if (text !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return text;
}

function assertDigestEquals(actual, expected, label) {
  if (actual !== expected) {
    fail(`${label} must match release contract`);
  }
}

function assertNoFormalInputFields(value, label = 'input') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoFormalInputFields(item, `${label}[${index}]`));
    return;
  }

  for (const [key, nested] of Object.entries(value)) {
    if (key === 'readiness' && nested === true) {
      fail(`${label}.readiness must not be true`);
    }
    if (FORBIDDEN_INPUT_KEYS.has(key)) {
      fail(`${label} must not contain formal readiness or verdict field: ${key}`);
    }
    assertNoFormalInputFields(nested, `${label}.${key}`);
  }
}

function rejectFocusedProducerReport(report, label) {
  const schema = typeof report.schema === 'string'
    ? report.schema
    : typeof report.schema_version === 'string'
      ? report.schema_version
      : undefined;
  const scope = typeof report.scope === 'string' ? report.scope : undefined;
  const schemaKind = KNOWN_FOCUSED_PRODUCER_SCHEMAS.get(schema);
  if (schemaKind) {
    fail(`${label} is a ${schemaKind}; pass a focused adoption report instead`);
  }
  const scopeKind = KNOWN_FOCUSED_PRODUCER_SCOPES.get(scope);
  if (scopeKind) {
    fail(`${label} is a ${scopeKind}; pass a focused adoption report instead`);
  }
}

function assertExactStringSet(values, expected, label) {
  const actualValues = requireArray(values, label).map((value, index) =>
    requireString(value, `${label}[${index}]`)
  );
  const actual = new Set(actualValues);
  const expectedSet = new Set(expected);
  if (actualValues.length !== expected.length || actual.size !== expectedSet.size) {
    fail(`${label} must contain exactly ${expected.join(', ')}`);
  }
  for (const item of expectedSet) {
    if (!actual.has(item)) {
      fail(`${label} must include ${item}`);
    }
  }
}

function validateDigestLeaves(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be a digest object`);
  }
  for (const [key, nested] of Object.entries(value)) {
    const nestedLabel = `${label}.${key}`;
    if (nested && typeof nested === 'object' && !Array.isArray(nested)) {
      validateDigestLeaves(nested, nestedLabel);
    } else {
      requireDigest(nested, nestedLabel);
    }
  }
}

function assertNoUnsafeText(value, label) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  if (LOCAL_OR_SECRET_TEXT_RE.test(serialized)) {
    fail(`${label} must not include raw local paths, kubeconfig, or secret-looking payloads`);
  }
}

function percentDecodedCandidates(value) {
  const candidates = [];
  let current = value;
  for (let depth = 0; depth < 3; depth += 1) {
    let decoded;
    try {
      decoded = decodeURIComponent(current);
    } catch {
      break;
    }
    if (decoded === current) {
      break;
    }
    candidates.push(decoded);
    current = decoded;
  }
  return candidates;
}

function assertNoUnsafeDecodedText(value, label) {
  if (typeof value === 'string') {
    assertNoUnsafeText(value, label);
    for (const decoded of percentDecodedCandidates(value)) {
      assertNoUnsafeText(decoded, `${label} decoded`);
    }
    return;
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoUnsafeDecodedText(item, `${label}[${index}]`));
    return;
  }

  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      assertNoUnsafeDecodedText(nested, `${label}.${key}`);
    }
  }
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

function assertNoUnsafeUriDecodedParts(parsed, label) {
  if (parsed.username || parsed.password) {
    fail(`${label} must not include raw local paths, kubeconfig, or secret-looking payloads`);
  }

  const candidates = [
    parsed.hostname,
    parsed.pathname,
    parsed.search,
    parsed.hash,
    ...percentDecodedCandidates(parsed.pathname),
    ...percentDecodedCandidates(parsed.search),
    ...percentDecodedCandidates(parsed.hash)
  ];
  for (const segment of parsed.pathname.split('/').filter(Boolean)) {
    candidates.push(segment, ...percentDecodedCandidates(segment));
  }
  for (const [key, value] of parsed.searchParams.entries()) {
    candidates.push(key, value, ...percentDecodedCandidates(key), ...percentDecodedCandidates(value));
  }
  for (const candidate of candidates) {
    assertNoUnsafeText(candidate, `${label} decoded uri`);
  }
}

function isGithubActionsArtifactUri(parsed) {
  const segments = pathSegments(parsed);
  if (parsed.protocol !== 'https:') {
    return false;
  }
  if (parsed.hostname === 'api.github.com') {
    return (
      segments[0] === 'repos' &&
      Boolean(segments[1]) &&
      Boolean(segments[2]) &&
      segments[3] === 'actions' &&
      ((segments[4] === 'runs' && Boolean(segments[5]) && segments[6] === 'artifacts') ||
        (segments[4] === 'artifacts' && Boolean(segments[5])))
    );
  }
  if (parsed.hostname === 'github.com') {
    return (
      Boolean(segments[0]) &&
      Boolean(segments[1]) &&
      segments[2] === 'actions' &&
      segments[3] === 'runs' &&
      Boolean(segments[4])
    );
  }
  return false;
}

function isSafeGhArtifactUri(parsed) {
  const segments = pathSegments(parsed);
  return (
    parsed.protocol === 'gh-artifact:' &&
    Boolean(parsed.hostname) &&
    segments.length >= 3 &&
    !segments.includes('.') &&
    !segments.includes('..')
  );
}

function parseSafeIntakeReportUri(value, label, allowedSchemes, message) {
  const uri = requireString(value, label);
  if (
    uri !== uri.trim() ||
    /[\r\n]/.test(uri) ||
    !URI_SCHEME_RE.test(uri)
  ) {
    fail(message);
  }
  assertNoUnsafeDecodedText(uri, label);

  let parsed;
  try {
    parsed = new URL(uri);
  } catch {
    fail(message);
  }

  const scheme = parsed.protocol.slice(0, -1).toLowerCase();
  if (!allowedSchemes.has(scheme)) {
    fail(message);
  }
  assertNoUnsafeUriDecodedParts(parsed, label);

  return { uri, parsed };
}

function requireSafeIntakeReportUri(value, label) {
  return parseSafeIntakeReportUri(
    value,
    label,
    SAFE_INTAKE_REPORT_URI_SCHEMES,
    `${label} must be an allowed remote provenance or summary URI`
  ).uri;
}

function requireAllowedArtifactUri(value, label) {
  const { uri, parsed } = parseSafeIntakeReportUri(
    value,
    label,
    SAFE_ARTIFACT_URI_SCHEMES,
    `${label} must be an allowed remote artifact URI`
  );
  if (isSafeGhArtifactUri(parsed) || isGithubActionsArtifactUri(parsed)) {
    return uri;
  }
  fail(`${label} must be an allowed remote artifact URI`);
}

function assertSafeIntakeReportUriFields(value, label) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertSafeIntakeReportUriFields(item, `${label}[${index}]`));
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  for (const [key, nested] of Object.entries(value)) {
    const nestedLabel = `${label}.${key}`;
    if (INTAKE_REPORT_URI_KEYS.has(key)) {
      requireSafeIntakeReportUri(nested, nestedLabel);
      continue;
    }
    assertSafeIntakeReportUriFields(nested, nestedLabel);
  }
}

function releaseContractSubjectDigest(contract) {
  const provenance = requireObject(
    contract.artifact_provenance,
    'release_contract.artifact_provenance'
  );
  assertStringEquals(
    provenance.schema_version,
    ARTIFACT_PROVENANCE_SCHEMA,
    'release_contract.artifact_provenance.schema_version'
  );
  assertStringEquals(
    provenance.subject_name,
    RELEASE_CONTRACT_SUBJECT_NAME,
    'release_contract.artifact_provenance.subject_name'
  );
  const declaredSubject = requireDigest(
    provenance.subject_sha256,
    'release_contract.artifact_provenance.subject_sha256'
  );
  const { artifact_provenance: _artifactProvenance, ...subject } = contract;
  const computedSubject = canonicalDigest(subject);
  if (declaredSubject !== computedSubject) {
    fail('release_contract.artifact_provenance.subject_sha256 must match release contract canonical subject');
  }
  return declaredSubject;
}

function validateReleaseContractProvenance(provenance, releaseContractSubjectSha256) {
  const sanitized = {
    provenance_kind: requireString(
      provenance.provenance_kind,
      'release_contract.artifact_provenance.provenance_kind'
    ),
    producer_repo: requireString(
      provenance.producer_repo,
      'release_contract.artifact_provenance.producer_repo'
    ),
    normalized_remote: requireString(
      provenance.normalized_remote,
      'release_contract.artifact_provenance.normalized_remote'
    ),
    commit_sha: requireGitSha(
      provenance.commit_sha,
      'release_contract.artifact_provenance.commit_sha'
    ),
    artifact_uri: requireAllowedArtifactUri(
      provenance.artifact_uri,
      'release_contract.artifact_provenance.artifact_uri'
    ),
    subject_sha256: releaseContractSubjectSha256
  };
  assertNoUnsafeDecodedText(sanitized, 'release_contract.artifact_provenance');
  return sanitized;
}

function releaseIdentityFromContract(releaseContractInput) {
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  assertNoFormalInputFields(contract, 'release_contract');
  assertStringEquals(contract.schema_version, RELEASE_CONTRACT_SCHEMA, 'release_contract.schema_version');
  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const provenance = requireObject(
    contract.artifact_provenance,
    'release_contract.artifact_provenance'
  );
  const provenanceCommitSha = requireGitSha(
    provenance.commit_sha,
    'release_contract.artifact_provenance.commit_sha'
  );
  if (provenanceCommitSha !== gitSha) {
    fail('release_contract.artifact_provenance.commit_sha must match release_contract.git_sha');
  }
  const releaseContractSubjectSha256 = releaseContractSubjectDigest(contract);

  return {
    releaseId,
    gitSha,
    releaseContractDigest: releaseContractInput.digest,
    releaseContractSubjectSha256,
    provenance: validateReleaseContractProvenance(provenance, releaseContractSubjectSha256)
  };
}

function assertReleaseIdentity({ releaseId, gitSha }, releaseIdentity, label) {
  if (releaseId !== releaseIdentity.releaseId) {
    fail(`${label}.release_id must match release contract`);
  }
  if (gitSha !== releaseIdentity.gitSha) {
    fail(`${label}.git_sha must match release contract`);
  }
}

function validateOnlineProvenance(provenance, label) {
  const summary = requireObject(provenance, label);
  const artifactUri = requireSafeIntakeReportUri(summary.artifact_uri, `${label}.artifact_uri`);
  const sanitized = {
    provenance_kind: requireString(summary.provenance_kind, `${label}.provenance_kind`),
    producer_repo: requireString(summary.producer_repo, `${label}.producer_repo`),
    normalized_remote: requireString(summary.normalized_remote, `${label}.normalized_remote`),
    commit_sha: requireGitSha(summary.commit_sha, `${label}.commit_sha`),
    artifact_uri: artifactUri,
    subject_sha256: requireDigest(summary.subject_sha256, `${label}.subject_sha256`)
  };
  assertNoUnsafeDecodedText(sanitized, label);
  return sanitized;
}

function validateOnlinePath({ pathEntry, key, spec, releaseIdentity }) {
  const entry = requireObject(pathEntry, `online_adoption.online_paths.${key}`);
  assertStringEquals(
    entry.operator_path,
    spec.operatorPath,
    `online_adoption.online_paths.${key}.operator_path`
  );
  assertStringEquals(
    entry.target_profile,
    spec.targetProfile,
    `online_adoption.online_paths.${key}.target_profile`
  );
  assertStringEquals(entry.mode, 'apply', `online_adoption.online_paths.${key}.mode`);
  requireBooleanTrue(
    entry.confirmed_apply,
    `online_adoption.online_paths.${key}.confirmed_apply`
  );
  requireBooleanTrue(
    entry.rollout_checked,
    `online_adoption.online_paths.${key}.rollout_checked`
  );
  requireBooleanTrue(
    entry.smoke_checked,
    `online_adoption.online_paths.${key}.smoke_checked`
  );
  validateDigestLeaves(entry.digests, `online_adoption.online_paths.${key}.digests`);
  assertDigestEquals(
    requireDigest(
      entry.digests.release_contract,
      `online_adoption.online_paths.${key}.digests.release_contract`
    ),
    releaseIdentity.releaseContractDigest,
    `online_adoption.online_paths.${key}.digests.release_contract`
  );

  return {
    operator_path: spec.operatorPath,
    target_profile: spec.targetProfile,
    provenance: validateOnlineProvenance(
      entry.provenance,
      `online_adoption.online_paths.${key}.provenance`
    )
  };
}

function validateOnlineAdoption(onlineInput, releaseIdentity) {
  const report = requireObject(onlineInput.value, 'online_adoption_report');
  rejectFocusedProducerReport(report, 'online_adoption_report');
  assertSafeIntakeReportUriFields(report, 'online_adoption_report');
  assertNoFormalInputFields(report, 'online_adoption_report');
  assertStringEquals(report.schema, ONLINE_ADOPTION_SCHEMA, 'online_adoption_report.schema');
  assertStringEquals(report.scope, ONLINE_ADOPTION_SCOPE, 'online_adoption_report.scope');
  requireBooleanFalse(report.readiness, 'online_adoption_report.readiness');
  assertStringEquals(report.status, 'pass', 'online_adoption_report.status');
  assertReleaseIdentity(
    {
      releaseId: requireString(report.release_id, 'online_adoption_report.release_id'),
      gitSha: requireGitSha(report.git_sha, 'online_adoption_report.git_sha')
    },
    releaseIdentity,
    'online_adoption_report'
  );
  const releaseContract = requireObject(
    report.release_contract,
    'online_adoption_report.release_contract'
  );
  assertDigestEquals(
    requireDigest(
      releaseContract.input_sha256,
      'online_adoption_report.release_contract.input_sha256'
    ),
    releaseIdentity.releaseContractDigest,
    'online_adoption_report.release_contract.input_sha256'
  );
  assertDigestEquals(
    requireDigest(
      releaseContract.subject_sha256,
      'online_adoption_report.release_contract.subject_sha256'
    ),
    releaseIdentity.releaseContractSubjectSha256,
    'online_adoption_report.release_contract.subject_sha256'
  );

  const coverage = requireObject(report.coverage, 'online_adoption_report.coverage');
  assertExactStringSet(
    coverage.required_operator_paths,
    Object.values(REQUIRED_ONLINE_PATHS).map((pathSpec) => pathSpec.operatorPath),
    'online_adoption_report.coverage.required_operator_paths'
  );
  requireNonNegativeInteger(
    coverage.confirmed_apply_paths,
    'online_adoption_report.coverage.confirmed_apply_paths'
  );
  if (coverage.confirmed_apply_paths < Object.keys(REQUIRED_ONLINE_PATHS).length) {
    fail('online_adoption_report.coverage.confirmed_apply_paths must cover both online paths');
  }

  const onlinePaths = requireObject(report.online_paths, 'online_adoption_report.online_paths');
  assertExactStringSet(
    Object.keys(onlinePaths),
    Object.keys(REQUIRED_ONLINE_PATHS),
    'online_adoption_report.online_paths keys'
  );
  const summaries = {};
  for (const [key, spec] of Object.entries(REQUIRED_ONLINE_PATHS)) {
    summaries[key] = validateOnlinePath({
      pathEntry: onlinePaths[key],
      key,
      spec,
      releaseIdentity
    });
  }

  const provenanceFingerprints = Object.values(summaries).map((summary) =>
    [
      summary.provenance.provenance_kind,
      summary.provenance.producer_repo,
      summary.provenance.normalized_remote
    ].join('|')
  );
  if (new Set(provenanceFingerprints).size !== 1) {
    fail('online adoption provenance summaries must use one release-kit producer identity');
  }

  return {
    digest: onlineInput.digest,
    coveredQuadrants: Object.values(REQUIRED_ONLINE_PATHS).map((pathSpec) => pathSpec.operatorPath),
    paths: summaries
  };
}

function validateAirgapOperatorPaths(report, label) {
  const operatorPaths = requireArray(report.operator_paths, `${label}.operator_paths`);
  if (operatorPaths.length !== 2) {
    fail(`${label}.operator_paths must contain airgap-bundle and airgap paths`);
  }

  const bySurface = new Map();
  const strategies = new Set();
  for (const [index, value] of operatorPaths.entries()) {
    const entry = requireObject(value, `${label}.operator_paths[${index}]`);
    const surface = requireString(entry.surface, `${label}.operator_paths[${index}].surface`);
    if (bySurface.has(surface)) {
      fail(`${label}.operator_paths contains duplicate surface: ${surface}`);
    }
    bySurface.set(surface, entry);
    strategies.add(
      requireString(
        entry.substrate_strategy,
        `${label}.operator_paths[${index}].substrate_strategy`
      )
    );
  }
  for (const surface of ['airgap-bundle', 'airgap']) {
    if (!bySurface.has(surface)) {
      fail(`${label}.operator_paths must include ${surface}`);
    }
  }
  if (strategies.size !== 1) {
    fail(`${label}.operator_paths must use one substrate strategy`);
  }

  const strategy = [...strategies][0];
  const strategySpec = REQUIRED_AIRGAP_STRATEGIES[strategy];
  if (!strategySpec) {
    fail(`${label}.operator_paths uses unsupported airgap strategy: ${strategy}`);
  }

  for (const [surface, entry] of bySurface) {
    assertStringEquals(
      entry.machine_profile,
      strategySpec.targetProfile,
      `${label}.operator_paths.${surface}.machine_profile`
    );
  }

  const consumePath = bySurface.get('airgap');
  assertStringEquals(consumePath.mode, 'apply', `${label}.operator_paths.airgap.mode`);
  requireBooleanTrue(
    consumePath.operator_run_id_present,
    `${label}.operator_paths.airgap.operator_run_id_present`
  );
  assertExactStringSet(
    consumePath.deployment_steps,
    REQUIRED_AIRGAP_DEPLOYMENT_STEPS,
    `${label}.operator_paths.airgap.deployment_steps`
  );

  return {
    strategy,
    quadrant: strategySpec.quadrant,
    targetProfile: strategySpec.targetProfile
  };
}

function validateAirgapAdoption(airgapInput, releaseIdentity, index) {
  const label = `airgap_adoption_report[${index}]`;
  const report = requireObject(airgapInput.value, label);
  rejectFocusedProducerReport(report, label);
  assertSafeIntakeReportUriFields(report, label);
  assertNoFormalInputFields(report, label);
  assertStringEquals(report.schema, AIRGAP_ADOPTION_SCHEMA, `${label}.schema`);
  assertStringEquals(report.scope, AIRGAP_ADOPTION_SCOPE, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);

  const release = requireObject(report.release, `${label}.release`);
  assertReleaseIdentity(
    {
      releaseId: requireString(release.release_id, `${label}.release.release_id`),
      gitSha: requireGitSha(release.git_sha, `${label}.release.git_sha`)
    },
    releaseIdentity,
    label
  );
  assertDigestEquals(
    requireDigest(report.release_contract_digest, `${label}.release_contract_digest`),
    releaseIdentity.releaseContractDigest,
    `${label}.release_contract_digest`
  );
  requireDigest(report.bundle_manifest_digest, `${label}.bundle_manifest_digest`);
  validateDigestLeaves(report.surface_report_digests, `${label}.surface_report_digests`);
  validateDigestLeaves(report.producer_report_digests, `${label}.producer_report_digests`);

  const targetRegistrySummary = requireObject(
    report.target_registry_summary,
    `${label}.target_registry_summary`
  );
  requireString(targetRegistrySummary.host, `${label}.target_registry_summary.host`);
  assertNoUnsafeDecodedText(targetRegistrySummary, `${label}.target_registry_summary`);

  const pathSummary = validateAirgapOperatorPaths(report, label);

  return {
    strategy: pathSummary.strategy,
    quadrant: pathSummary.quadrant,
    targetProfile: pathSummary.targetProfile,
    digest: airgapInput.digest,
    bundleManifestDigest: requireDigest(
      report.bundle_manifest_digest,
      `${label}.bundle_manifest_digest`
    )
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.release-engineering-gate-intake.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function removeManagedReport(outputDir) {
  if (!outputDir) {
    return;
  }
  await fs.rm(path.join(path.resolve(outputDir), REPORT_FILE), { force: true });
}

function extractExplicitOutputDir(argv) {
  let outputDir;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (value && value.trim() !== '' && !value.startsWith('--')) {
      outputDir = value;
    }
  }
  return outputDir;
}

async function main(argv) {
  const explicitOutputDir = extractExplicitOutputDir(argv);
  let args;
  try {
    args = parseArgs(argv);
    if (args.help) {
      console.log(usage());
      return;
    }
  } catch (error) {
    if ((error.exitCode || 1) === 2) {
      await removeManagedReport(explicitOutputDir);
    }
    throw error;
  }

  await removeManagedReport(args.outputDir);
  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const releaseIdentity = releaseIdentityFromContract(releaseContractInput);
  const onlineInput = await readJson(args.onlineAdoptionReport, 'online adoption report');
  const onlineSummary = validateOnlineAdoption(onlineInput, releaseIdentity);

  const airgapSummaries = new Map();
  for (const [index, reportFile] of args.airgapAdoptionReports.entries()) {
    const airgapInput = await readJson(reportFile, `airgap adoption report ${index + 1}`);
    const summary = validateAirgapAdoption(airgapInput, releaseIdentity, index);
    if (airgapSummaries.has(summary.strategy)) {
      fail(`duplicate airgap/${summary.strategy} adoption report`);
    }
    airgapSummaries.set(summary.strategy, summary);
  }
  for (const strategy of Object.keys(REQUIRED_AIRGAP_STRATEGIES)) {
    if (!airgapSummaries.has(strategy)) {
      fail(`missing airgap/${strategy} adoption report`);
    }
  }
  if (airgapSummaries.size !== Object.keys(REQUIRED_AIRGAP_STRATEGIES).length) {
    fail('airgap adoption reports must cover only the required airgap strategies');
  }

  const coveredQuadrants = [
    ...onlineSummary.coveredQuadrants,
    ...Object.values(REQUIRED_AIRGAP_STRATEGIES).map((spec) => spec.quadrant)
  ];
  assertExactStringSet(coveredQuadrants, REQUIRED_QUADRANTS, 'covered_quadrants');

  const report = {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    formal_verdict: 'not_issued',
    release: {
      release_id: releaseIdentity.releaseId,
      git_sha: releaseIdentity.gitSha
    },
    release_contract: {
      input_sha256: releaseIdentity.releaseContractDigest,
      subject_sha256: releaseIdentity.releaseContractSubjectSha256,
      provenance: releaseIdentity.provenance
    },
    coverage: {
      candidate_intake_only: true,
      required_quadrants: REQUIRED_QUADRANTS,
      covered_quadrants: REQUIRED_QUADRANTS,
      online_adoption_reports: 1,
      airgap_adoption_reports: airgapSummaries.size
    },
    adoption_report_digests: {
      online: onlineSummary.digest,
      airgap: {
        use_existing: airgapSummaries.get('use_existing').digest,
        install_substrates: airgapSummaries.get('install_substrates').digest
      }
    },
    identity_bindings: {
      release_contract_digest: releaseIdentity.releaseContractDigest,
      online_release_contract_digest: releaseIdentity.releaseContractDigest,
      airgap_release_contract_digests: {
        use_existing: releaseIdentity.releaseContractDigest,
        install_substrates: releaseIdentity.releaseContractDigest
      },
      airgap_bundle_manifest_digests: {
        use_existing: airgapSummaries.get('use_existing').bundleManifestDigest,
        install_substrates: airgapSummaries.get('install_substrates').bundleManifestDigest
      }
    },
    blocking_gaps: [
      {
        gap: 'formal_operator_verdict',
        status: 'not_issued',
        blocking: true
      },
      {
        gap: 'offline_install_readiness',
        status: 'not_issued',
        blocking: true
      },
      {
        gap: 'package_readiness',
        status: 'not_issued',
        blocking: true
      },
      {
        gap: 'release_readiness',
        status: 'not_issued',
        blocking: true
      }
    ],
    generated_at: new Date().toISOString()
  };

  await writeReport(args.outputDir, report);
  console.log(`PASS: wrote ${REPORT_FILE}; release engineering gate intake is candidate-only and not release readiness`);
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
