#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = [
  'operatorChoice',
  'machineProfile',
  'surfaceReport',
  'evidenceRoot',
  'runbook',
  'outputDir'
];
const REPORT_FILE = 'operator-runbook-acceptance-report.json';
const REPORT_SCHEMA = 'agentsmith.operator-runbook-acceptance/v1';
const REPORT_SCOPE = 'operator_runbook_acceptance_v0';
const SURFACE_SCHEMA = 'agentsmith.operator-release-surface-report/v1';
const SURFACE_SCOPE = 'operator_release_surface_v0';
const EVIDENCE_SCHEMA = 'agentsmith.release-kit-evidence-envelope/v1';
const EVIDENCE_SUBJECT_SCHEMA = 'agentsmith.release-kit-evidence-subject/v1';
const AIRGAP_BUNDLE_EVIDENCE_OUTPUT = 'airgap_bundle_check';
const BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const SUBSTRATE_PACK_MANIFEST_FILE = 'substrate-pack-manifest.json';
const SUBSTRATE_PACK_COMPONENT_PATH = 'components/substrate-pack-manifest.json';
const KIT_AIRGAP_PROFILE = 'existing_kubernetes/kit_installed/airgap';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const URI_SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:[\\/]/;
const CHOICE_TO_PROFILE = new Map([
  ['airgap-bundle/use_existing', 'existing_kubernetes/external_declared/airgap'],
  ['airgap-bundle/kit_provided', 'existing_kubernetes/kit_installed/airgap']
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
  node scripts/verify-operator-runbook-acceptance.mjs \\
    --operator-choice airgap-bundle/use_existing|airgap-bundle/kit_provided \\
    --machine-profile existing_kubernetes/<external_declared|kit_installed>/airgap \\
    --surface-report <operator-release-surface-report.json> \\
    --evidence-root <dir> \\
    --runbook <file> \\
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
      if (!value || value.trim() === '' || value.startsWith('--')) {
        cliFail(`missing value for ${arg}`);
      }
      index += 1;
      return value;
    };

    switch (arg) {
      case '--operator-choice':
        parsed.operatorChoice = nextValue();
        break;
      case '--machine-profile':
        parsed.machineProfile = nextValue();
        break;
      case '--surface-report':
        parsed.surfaceReport = nextValue();
        break;
      case '--evidence-root':
        parsed.evidenceRoot = nextValue();
        break;
      case '--runbook':
        parsed.runbook = nextValue();
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

function assertStringEquals(value, expected, label) {
  const text = requireString(value, label);
  if (text !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return text;
}

function rejectUriOrWindowsPath(value, label) {
  if (value.trim() !== value || value.startsWith('//') || WINDOWS_DRIVE_RE.test(value)) {
    fail(`${label} must be a local POSIX path`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be a local POSIX path, not a URI`);
  }
}

async function readFileDigest(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return {
    buffer,
    digest: digestBuffer(buffer)
  };
}

async function readJson(file, label) {
  const input = await readFileDigest(file, label);
  try {
    return {
      value: JSON.parse(input.buffer.toString('utf8')),
      digest: input.digest
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
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
    fail(`cannot inspect ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must be a file`);
  }
  return resolved;
}

async function canonicalLocalDirectory(input, label) {
  const value = requireString(input, label);
  rejectUriOrWindowsPath(value, label);
  const resolved = path.resolve(value);
  let stat;
  try {
    stat = await fs.lstat(resolved);
  } catch (error) {
    fail(`cannot inspect ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isDirectory()) {
    fail(`${label} must be a directory`);
  }
  return resolved;
}

function assertNoAcceptanceForbiddenFields(value, label, { allowRootReadiness = false } = {}) {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) =>
      assertNoAcceptanceForbiddenFields(item, `${label}[${index}]`)
    );
    return;
  }
  const forbiddenKeys = new Set([
    'operator_identity',
    'signature',
    'signature_uri',
    'signature_sha256',
    'formal_verdict',
    'release_verdict',
    'verdict',
    'ready',
    'deploy_readiness',
    'package_readiness',
    'offline_install_readiness'
  ]);
  for (const [key, nested] of Object.entries(value)) {
    if (
      forbiddenKeys.has(key) ||
      (key === 'readiness' && !(allowRootReadiness && label === 'surface_report'))
    ) {
      fail(`${label}.${key} is not allowed in runbook acceptance input`);
    }
    assertNoAcceptanceForbiddenFields(nested, `${label}.${key}`);
  }
}

function assertMachineProfile(operatorChoice, machineProfile) {
  if (
    machineProfile.startsWith('kind/') ||
    machineProfile.startsWith('kind_rehearsal/') ||
    machineProfile.startsWith('local-kind/')
  ) {
    fail('operator runbook acceptance rejects kind/local-kind machine profiles');
  }
  const expectedProfile = CHOICE_TO_PROFILE.get(operatorChoice);
  if (!expectedProfile) {
    fail(`operator choice is not supported for runbook acceptance: ${operatorChoice}`);
  }
  if (machineProfile !== expectedProfile) {
    fail('machine profile must match operator choice');
  }
  return expectedProfile;
}

function profileParts(profile) {
  const parts = profile.split('/');
  if (parts.length !== 3 || parts.some((part) => part.trim() === '')) {
    fail('machine profile must be <target_cluster>/<substrate_source>/<distribution>');
  }
  return {
    target_cluster: parts[0],
    substrate_source: parts[1],
    distribution: parts[2]
  };
}

function targetProfileValue(value, label) {
  return requireString(
    requireObject(value.target_profile, `${label}.target_profile`).value,
    `${label}.target_profile.value`
  );
}

function isKitAirgapProfile(machineProfile) {
  return machineProfile === KIT_AIRGAP_PROFILE;
}

function assertDigestOnlyHandoff(
  handoff,
  label,
  expected = {},
  { requireSubstratePack = false } = {}
) {
  const object = requireObject(handoff, label);
  const keys = Object.keys(object).sort();
  const expectedKeys = [
    'airgap_bundle_check_report_digest',
    'airgap_bundle_manifest_digest',
    'evidence_digest',
    'evidence_subject_digest',
    'image_map_digest'
  ];
  if (requireSubstratePack) {
    expectedKeys.push('substrate_pack_manifest_digest');
  }
  expectedKeys.sort();
  if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) {
    fail(`${label} must contain digest-only handoff keys`);
  }
  for (const [key, value] of Object.entries(object)) {
    const digest = requireDigest(value, `${label}.${key}`);
    if (expected[key] && digest !== expected[key]) {
      fail(`${label}.${key} must match evidence root digest`);
    }
  }
}

function assertSurfaceAirgapDigestBindings(surfaceReport, evidenceDigests) {
  const producerDigests = requireObject(
    surfaceReport.producer_report_digests,
    'surface_report.producer_report_digests'
  );
  const producerCheckDigest = requireDigest(
    producerDigests.airgap_bundle_check_report,
    'surface_report.producer_report_digests.airgap_bundle_check_report'
  );
  if (producerCheckDigest !== evidenceDigests.airgapBundleCheckReport) {
    fail('surface_report producer bundle-check digest must match evidence root');
  }

  const handoff = requireObject(surfaceReport.airgap_handoff, 'surface_report.airgap_handoff');
  const handoffCheckDigest = requireDigest(
    handoff.airgap_bundle_check_report_digest,
    'surface_report.airgap_handoff.airgap_bundle_check_report_digest'
  );
  if (handoffCheckDigest !== evidenceDigests.airgapBundleCheckReport) {
    fail('surface_report airgap handoff bundle-check digest must match evidence root');
  }
  const handoffManifestDigest = requireDigest(
    handoff.bundle_manifest_digest,
    'surface_report.airgap_handoff.bundle_manifest_digest'
  );
  if (handoffManifestDigest !== evidenceDigests.airgapBundleManifest) {
    fail('surface_report airgap handoff bundle manifest digest must match evidence root');
  }
}

function findSubjectDigest(subject, relativePath) {
  for (const [index, entryValue] of requireArray(subject.files, 'evidence_subject.files').entries()) {
    const entry = requireObject(entryValue, `evidence_subject.files[${index}]`);
    if (requireString(entry.path, `evidence_subject.files[${index}].path`) === relativePath) {
      return requireDigest(entry.sha256, `evidence_subject.files[${index}].sha256`);
    }
  }
  fail(`evidence_subject.files must include ${relativePath}`);
}

function assertSubstratePackManifestBinding(manifest, expectedDigest, label) {
  const bindings = requireObject(manifest.bindings, `${label}.bindings`);
  const bindingDigest = requireDigest(
    bindings.substrate_pack_manifest_sha256,
    `${label}.bindings.substrate_pack_manifest_sha256`
  );
  if (bindingDigest !== expectedDigest) {
    fail(`${label}.bindings.substrate_pack_manifest_sha256 must match evidence root`);
  }

  const components = requireArray(manifest.components, `${label}.components`);
  let matchedComponent;
  for (const [index, componentValue] of components.entries()) {
    const component = requireObject(componentValue, `${label}.components[${index}]`);
    const kind = requireString(component.kind, `${label}.components[${index}].kind`);
    if (kind !== 'substrate_pack_manifest') {
      continue;
    }
    if (matchedComponent) {
      fail(`${label}.components contains duplicate substrate_pack_manifest`);
    }
    matchedComponent = {
      value: component,
      label: `${label}.components[${index}]`
    };
  }

  if (!matchedComponent) {
    fail(`${label}.components must include substrate_pack_manifest`);
  }

  assertStringEquals(
    matchedComponent.value.path,
    SUBSTRATE_PACK_COMPONENT_PATH,
    `${matchedComponent.label}.path`
  );
  const componentDigest = requireDigest(
    matchedComponent.value.sha256,
    `${matchedComponent.label}.sha256`
  );
  if (componentDigest !== expectedDigest) {
    fail(`${matchedComponent.label}.sha256 must match evidence root`);
  }
}

function assertSafeRelativePath(value, label) {
  const relativePath = requireString(value, label);
  if (
    relativePath.startsWith('/') ||
    WINDOWS_DRIVE_RE.test(relativePath) ||
    URI_SCHEME_RE.test(relativePath) ||
    relativePath.includes('\\') ||
    relativePath.includes('//') ||
    relativePath.split('/').some((part) => part === '' || part === '.' || part === '..') ||
    !SAFE_RELATIVE_PATH_RE.test(relativePath)
  ) {
    fail(`${label} must be a safe relative path`);
  }
  return relativePath;
}

async function validateSurface({ surfaceReportPath, operatorChoice, machineProfile }) {
  const input = await readJson(surfaceReportPath, 'surface report');
  const report = requireObject(input.value, 'surface_report');
  assertNoAcceptanceForbiddenFields(report, 'surface_report', { allowRootReadiness: true });
  assertStringEquals(report.schema, SURFACE_SCHEMA, 'surface_report.schema');
  assertStringEquals(report.scope, SURFACE_SCOPE, 'surface_report.scope');
  if (report.readiness !== false) {
    fail('surface_report.readiness must be false');
  }
  assertStringEquals(report.status, 'pass', 'surface_report.status');
  const [surface, substrateStrategy] = operatorChoice.split('/');
  assertStringEquals(report.surface, surface, 'surface_report.surface');
  assertStringEquals(
    report.substrate_strategy,
    substrateStrategy,
    'surface_report.substrate_strategy'
  );
  assertStringEquals(report.machine_profile, machineProfile, 'surface_report.machine_profile');
  requireString(report.release_id, 'surface_report.release_id');
  requireGitSha(report.git_sha, 'surface_report.git_sha');
  requireDigest(report.release_contract_digest, 'surface_report.release_contract_digest');
  assertDigestOnlyHandoff(
    report.airgap_evidence_handoff,
    'surface_report.airgap_evidence_handoff',
    {},
    { requireSubstratePack: isKitAirgapProfile(machineProfile) }
  );
  return {
    input,
    report
  };
}

async function validateEvidenceRoot({ evidenceRoot, machineProfile, surfaceReport }) {
  const evidenceInput = await readJson(path.join(evidenceRoot, 'evidence.json'), 'evidence.json');
  const subjectInput = await readJson(
    path.join(evidenceRoot, 'evidence-subject.json'),
    'evidence-subject.json'
  );
  const checkInput = await readJson(
    path.join(evidenceRoot, 'airgap-bundle-check-report.json'),
    'airgap-bundle-check-report.json'
  );
  const manifestInput = await readJson(
    path.join(evidenceRoot, 'airgap-bundle-manifest.json'),
    'airgap-bundle-manifest.json'
  );
  const substratePackInput = isKitAirgapProfile(machineProfile)
    ? await readJson(
        path.join(evidenceRoot, SUBSTRATE_PACK_MANIFEST_FILE),
        SUBSTRATE_PACK_MANIFEST_FILE
      )
    : undefined;
  const imageMapInput = await readJson(path.join(evidenceRoot, 'image-map.json'), 'image-map.json');
  const evidence = requireObject(evidenceInput.value, 'evidence');
  const subject = requireObject(subjectInput.value, 'evidence_subject');
  const manifest = requireObject(manifestInput.value, 'airgap_bundle_manifest');

  assertNoAcceptanceForbiddenFields(evidence, 'evidence');
  assertStringEquals(evidence.schema_version, EVIDENCE_SCHEMA, 'evidence.schema_version');
  assertStringEquals(
    evidence.release_kit_output,
    AIRGAP_BUNDLE_EVIDENCE_OUTPUT,
    'evidence.release_kit_output'
  );
  assertStringEquals(evidence.release_id, surfaceReport.release_id, 'evidence.release_id');
  const evidenceGitSha = requireGitSha(evidence.git_sha, 'evidence.git_sha');
  if (evidenceGitSha !== surfaceReport.git_sha) {
    fail('evidence.git_sha must match surface report');
  }
  const evidenceContractDigest = requireDigest(
    evidence.release_contract_digest,
    'evidence.release_contract_digest'
  );
  if (evidenceContractDigest !== surfaceReport.release_contract_digest) {
    fail('evidence.release_contract_digest must match surface report');
  }

  const parts = profileParts(machineProfile);
  for (const [key, expected] of Object.entries(parts)) {
    assertStringEquals(evidence[key], expected, `evidence.${key}`);
  }

  const provenance = requireObject(evidence.artifact_provenance, 'evidence.artifact_provenance');
  assertNoAcceptanceForbiddenFields(provenance, 'evidence.artifact_provenance');
  assertStringEquals(
    provenance.provenance_kind,
    'ci_artifact',
    'evidence.artifact_provenance.provenance_kind'
  );
  const subjectSha256 = requireDigest(
    provenance.subject_sha256,
    'evidence.artifact_provenance.subject_sha256'
  );
  if (subjectSha256 !== canonicalDigest(subject)) {
    fail('evidence.artifact_provenance.subject_sha256 must match evidence subject');
  }

  assertStringEquals(
    subject.schema_version,
    EVIDENCE_SUBJECT_SCHEMA,
    'evidence_subject.schema_version'
  );
  if (findSubjectDigest(subject, 'airgap-bundle-check-report.json') !== checkInput.digest) {
    fail('evidence subject bundle check digest must match evidence root');
  }
  if (findSubjectDigest(subject, 'airgap-bundle-manifest.json') !== manifestInput.digest) {
    fail('evidence subject bundle manifest digest must match evidence root');
  }
  if (findSubjectDigest(subject, 'image-map.json') !== imageMapInput.digest) {
    fail('evidence subject image map digest must match evidence root');
  }
  if (
    substratePackInput &&
    findSubjectDigest(subject, SUBSTRATE_PACK_MANIFEST_FILE) !== substratePackInput.digest
  ) {
    fail('evidence subject substrate pack digest must match evidence root');
  }
  assertSurfaceAirgapDigestBindings(surfaceReport, {
    airgapBundleCheckReport: checkInput.digest,
    airgapBundleManifest: manifestInput.digest
  });
  assertDigestOnlyHandoff(
    surfaceReport.airgap_evidence_handoff,
    'surface_report.airgap_evidence_handoff',
    {
      evidence_digest: evidenceInput.digest,
      evidence_subject_digest: subjectInput.digest,
      airgap_bundle_check_report_digest: checkInput.digest,
      airgap_bundle_manifest_digest: manifestInput.digest,
      image_map_digest: imageMapInput.digest,
      ...(substratePackInput
        ? { substrate_pack_manifest_digest: substratePackInput.digest }
        : {})
    },
    { requireSubstratePack: Boolean(substratePackInput) }
  );

  assertStringEquals(
    manifest.schema_version,
    BUNDLE_MANIFEST_SCHEMA,
    'airgap_bundle_manifest.schema_version'
  );
  if (targetProfileValue(manifest, 'airgap_bundle_manifest') !== machineProfile) {
    fail('airgap bundle manifest profile must match machine profile');
  }
  if (substratePackInput) {
    assertSubstratePackManifestBinding(
      manifest,
      substratePackInput.digest,
      'airgap_bundle_manifest'
    );
  }

  return {
    evidenceInput,
    subjectInput,
    checkInput,
    manifestInput,
    imageMapInput,
    substratePackInput,
    manifest
  };
}

function findRunbookArtifact(manifest) {
  const payloadArtifacts = requireArray(
    manifest.payload_artifacts,
    'airgap_bundle_manifest.payload_artifacts'
  );
  const runbooks = payloadArtifacts
    .map((entry, index) => ({
      value: requireObject(entry, `airgap_bundle_manifest.payload_artifacts[${index}]`),
      index
    }))
    .filter(({ value }) => value.kind === 'runbook');
  if (runbooks.length !== 1) {
    fail('airgap bundle manifest must contain exactly one runbook payload artifact');
  }
  const { value, index } = runbooks[0];
  return {
    path: assertSafeRelativePath(
      value.path,
      `airgap_bundle_manifest.payload_artifacts[${index}].path`
    ),
    sha256: requireDigest(
      value.sha256,
      `airgap_bundle_manifest.payload_artifacts[${index}].sha256`
    )
  };
}

async function validateRunbook(runbookPath, manifest) {
  const artifact = findRunbookArtifact(manifest);
  const runbookInput = await readFileDigest(runbookPath, 'runbook');
  if (runbookInput.digest !== artifact.sha256) {
    fail('runbook digest must match bundle manifest runbook payload artifact');
  }
  return {
    path: artifact.path,
    sha256: runbookInput.digest
  };
}

function evidenceRootDigest(evidenceSummary) {
  const input = {
    evidence: evidenceSummary.evidenceInput.digest,
    evidence_subject: evidenceSummary.subjectInput.digest,
    airgap_bundle_check_report: evidenceSummary.checkInput.digest,
    airgap_bundle_manifest: evidenceSummary.manifestInput.digest,
    image_map: evidenceSummary.imageMapInput.digest
  };
  if (evidenceSummary.substratePackInput) {
    input.substrate_pack_manifest = evidenceSummary.substratePackInput.digest;
  }
  return canonicalDigest(input);
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportPath = path.join(outputDir, REPORT_FILE);
  const tempPath = path.join(outputDir, `.operator-runbook-acceptance.${process.pid}.tmp`);
  await fs.writeFile(tempPath, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempPath, reportPath);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const expectedProfile = assertMachineProfile(args.operatorChoice, args.machineProfile);
  const surfaceReportPath = await canonicalLocalFile(args.surfaceReport, 'surface report');
  const evidenceRoot = await canonicalLocalDirectory(args.evidenceRoot, 'evidence root');
  const runbookPath = await canonicalLocalFile(args.runbook, 'runbook');
  const surface = await validateSurface({
    surfaceReportPath,
    operatorChoice: args.operatorChoice,
    machineProfile: expectedProfile
  });
  const evidenceSummary = await validateEvidenceRoot({
    evidenceRoot,
    machineProfile: expectedProfile,
    surfaceReport: surface.report
  });
  const runbook = await validateRunbook(runbookPath, evidenceSummary.manifest);
  await writeReport(path.resolve(args.outputDir), {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    status: 'pass',
    operator_choice: args.operatorChoice,
    machine_profile: expectedProfile,
    surface_report_digest: surface.input.digest,
    evidence_root_digest: evidenceRootDigest(evidenceSummary),
    runbook
  });
  console.log(`PASS: wrote ${REPORT_FILE}`);
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
