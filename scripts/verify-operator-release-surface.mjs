#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = [
  'surface',
  'substrateStrategy',
  'machineProfile',
  'producerMode',
  'outputDir'
];
const REPORT_SCHEMA = 'agentsmith.operator-release-surface-report/v1';
const REPORT_SCOPE = 'operator_release_surface_v0';
const REPORT_FILE = 'operator-release-surface-report.json';
const ONLINE_PRODUCER_REPORT_FILE = 'online-deployment-gate-report.json';
const EVIDENCE_FILE = 'evidence.json';
const EVIDENCE_SUBJECT_FILE = 'evidence-subject.json';
const BUNDLE_CREATE_REPORT_FILE = 'bundle-create-report.json';
const AIRGAP_BUNDLE_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const AIRGAP_BUNDLE_MANIFEST_FILE = 'airgap-bundle-manifest.json';
const AIRGAP_CONSUME_REPORT_FILE = 'airgap-consume-rehearsal-report.json';
const AIRGAP_DEPLOYMENT_GATE_REPORT_FILE = 'airgap-deployment-gate-report.json';
const ONLINE_PRODUCER_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const ONLINE_PRODUCER_SCOPE = 'online_deployment_gate_only';
const EVIDENCE_SCHEMA = 'agentsmith.release-kit-evidence-envelope/v1';
const EVIDENCE_SUBJECT_SCHEMA = 'agentsmith.release-kit-evidence-subject/v1';
const BUNDLE_CREATE_SCHEMA = 'agentsmith.airgap-bundle-create-report/v1';
const BUNDLE_CREATE_SCOPE = 'airgap_bundle_create_only';
const AIRGAP_BUNDLE_CHECK_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const AIRGAP_BUNDLE_CHECK_SCOPE = 'airgap_bundle_manifest_check_only';
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const AIRGAP_CONSUME_SCHEMA = 'agentsmith.airgap-consume-rehearsal/v1';
const AIRGAP_CONSUME_SCOPE = 'airgap_consume_rehearsal_only';
const AIRGAP_DEPLOYMENT_GATE_SCHEMA = 'agentsmith.airgap-deployment-gate/v1';
const AIRGAP_DEPLOYMENT_GATE_SCOPE = 'airgap_deployment_gate_only';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const ONLINE_HANDOFF_PROVENANCE_KINDS = new Set(['ci_artifact', 'signed_operator_run']);
const MAPPINGS = new Map([
  [
    'online/use_existing',
    {
      producerMode: 'online-deployment-gate',
      machineProfile: 'existing_kubernetes/external_declared/online'
    }
  ],
  [
    'online/install_substrates',
    {
      producerMode: 'online-deployment-gate',
      machineProfile: 'existing_kubernetes/kit_installed/online'
    }
  ],
  [
    'airgap-bundle/use_existing',
    {
      producerMode: 'bundle-create',
      machineProfile: 'existing_kubernetes/external_declared/airgap'
    }
  ],
  [
    'airgap/use_existing',
    {
      producerMode: 'airgap-consume-rehearsal',
      machineProfile: 'existing_kubernetes/external_declared/airgap'
    }
  ]
]);
const FORBIDDEN_OUTPUT_KEYS = new Set([
  'verdict',
  'release_verdict',
  'deploy_readiness',
  'package_readiness',
  'offline_install_readiness',
  'ready'
]);
const FORBIDDEN_OUTPUT_TEXT_RE =
  /\b(?:verdict|release_verdict|deploy_readiness|package_readiness|offline_install_readiness|ready)\b/i;
const LOCAL_OR_SECRET_TEXT_RE =
  /(?:^|["'\s])(?:\/home\/|\/tmp\/|\/var\/|\/private\/|[A-Za-z]:[\\/]|file:\/\/)|secretRef:|operator held|operator workstation|signed operator prerequisite|kubeconfig|kubectl|probe|Bearer\s+[A-Za-z0-9._~+/=-]+|token\s*[:=]/i;

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
  node scripts/verify-operator-release-surface.mjs \\
    --surface online|airgap|airgap-bundle \\
    --substrate-strategy use_existing|install_substrates \\
    --machine-profile <mapped-profile> \\
    --producer-mode online-deployment-gate|airgap-consume-rehearsal|bundle-create \\
    --output-dir <dir> \\
    [--release-contract <json>] \\
    [--evidence-root <dir>] \\
    [--bundle-root <dir>] \\
    [--target-registry <registry-host[/namespace]>]`;
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
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    switch (arg) {
      case '--surface':
        parsed.surface = nextValue();
        break;
      case '--substrate-strategy':
        parsed.substrateStrategy = nextValue();
        break;
      case '--machine-profile':
        parsed.machineProfile = nextValue();
        break;
      case '--producer-mode':
        parsed.producerMode = nextValue();
        break;
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--evidence-root':
        parsed.evidenceRoot = nextValue();
        break;
      case '--bundle-root':
        parsed.bundleRoot = nextValue();
        break;
      case '--target-registry':
        parsed.targetRegistry = nextValue();
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
  const { buffer, digest } = await readFileDigest(file, label);
  try {
    return {
      value: JSON.parse(buffer.toString('utf8')),
      digest
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

function requireEnumString(value, label, allowed) {
  const text = requireString(value, label);
  if (!allowed.has(text)) {
    fail(`${label} is not supported`);
  }
  return text;
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

function assertStringEquals(value, expected, label) {
  const text = requireString(value, label);
  if (text !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return text;
}

function requireNonNegativeInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function assertMapping(args) {
  const key = `${args.surface}/${args.substrateStrategy}`;
  const mapping = MAPPINGS.get(key);
  if (!mapping) {
    fail(`unsupported operator mapping: ${key}`);
  }
  if (args.machineProfile !== mapping.machineProfile) {
    fail('machine profile must match operator surface mapping');
  }
  if (args.producerMode !== mapping.producerMode) {
    fail('producer mode must match operator surface mapping');
  }
  if (args.producerMode !== 'airgap-consume-rehearsal' && !args.releaseContract) {
    cliFail(`${args.producerMode} summaries require --release-contract`);
  }
  if (args.producerMode === 'bundle-create' && (!args.bundleRoot || !args.targetRegistry)) {
    cliFail('bundle-create summaries require --bundle-root and --target-registry');
  }
  if (args.producerMode === 'airgap-consume-rehearsal' && !args.bundleRoot) {
    cliFail('airgap consume summaries require --bundle-root');
  }
  if (args.producerMode === 'airgap-consume-rehearsal' && args.targetRegistry) {
    cliFail('airgap consume summaries do not accept --target-registry');
  }
  if (args.producerMode === 'online-deployment-gate' && (args.bundleRoot || args.targetRegistry)) {
    cliFail('online summaries do not accept --bundle-root or --target-registry');
  }
  if (args.producerMode !== 'bundle-create' && args.targetRegistry) {
    cliFail('--target-registry is only accepted for bundle-create summaries');
  }
  if (args.evidenceRoot && args.producerMode !== 'online-deployment-gate') {
    cliFail('--evidence-root is only accepted for online summaries');
  }
}

function targetProfileValue(report, label) {
  return requireString(
    requireObject(report.target_profile, `${label}.target_profile`).value,
    `${label}.target_profile.value`
  );
}

function assertProducerBase({
  report,
  label,
  schema,
  scope,
  args,
  releaseIdentity
}) {
  assertStringEquals(report.schema, schema, `${label}.schema`);
  assertStringEquals(report.scope, scope, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);
  assertStringEquals(report.release_id, releaseIdentity.releaseId, `${label}.release_id`);
  const gitSha = requireGitSha(report.git_sha, `${label}.git_sha`);
  if (gitSha !== releaseIdentity.gitSha) {
    fail(`${label}.git_sha must match release contract`);
  }
  if (targetProfileValue(report, label) !== args.machineProfile) {
    fail(`${label}.target_profile.value must match machine profile`);
  }
}

function assertReleaseContractDigest(report, label, releaseIdentity) {
  const digest = requireDigest(
    requireObject(report.release_contract, `${label}.release_contract`).input_sha256,
    `${label}.release_contract.input_sha256`
  );
  if (digest !== releaseIdentity.releaseContractDigest) {
    fail(`${label}.release_contract.input_sha256 must match release contract input`);
  }
}

function assertArtifactReleaseContractDigest(report, label, releaseIdentity) {
  const artifacts = requireObject(report.artifacts, `${label}.artifacts`);
  const releaseContract = requireObject(
    artifacts.release_contract,
    `${label}.artifacts.release_contract`
  );
  const digest = requireDigest(
    releaseContract.input_sha256,
    `${label}.artifacts.release_contract.input_sha256`
  );
  if (digest !== releaseIdentity.releaseContractDigest) {
    fail(`${label}.artifacts.release_contract.input_sha256 must match release contract input`);
  }
}

function assertSafeOutputPath(value, label) {
  const relativePath = requireString(value, label);
  if (
    relativePath.startsWith('/') ||
    /^[A-Za-z]:[\\/]/.test(relativePath) ||
    relativePath.includes('\\') ||
    relativePath.includes('//') ||
    relativePath.split('/').some((part) => part === '' || part === '.' || part === '..') ||
    !SAFE_RELATIVE_PATH_RE.test(relativePath)
  ) {
    fail(`${label} must be an output-relative safe path`);
  }
  return relativePath;
}

async function assertOutputFile(outputDir, relativePath, label) {
  const absolutePath = path.join(outputDir, relativePath);
  const relative = path.relative(outputDir, absolutePath);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must stay inside output directory`);
  }
  let stat;
  try {
    stat = await fs.stat(absolutePath);
  } catch (error) {
    fail(`${label} does not exist: ${error.message}`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a file`);
  }
}

async function sanitizeProducerSteps(outputDir, producerSteps) {
  const steps = [];
  for (const [index, stepValue] of requireArray(producerSteps, 'online_report.steps').entries()) {
    const step = requireObject(stepValue, `online_report.steps[${index}]`);
    const name = requireString(step.name, `online_report.steps[${index}].name`);
    assertStringEquals(step.status, 'pass', `online_report.steps[${index}].status`);
    const reportPaths = [];
    for (const [pathIndex, reportPath] of requireArray(
      step.report_paths,
      `online_report.steps[${index}].report_paths`
    ).entries()) {
      const safePath = assertSafeOutputPath(
        reportPath,
        `online_report.steps[${index}].report_paths[${pathIndex}]`
      );
      await assertOutputFile(
        outputDir,
        safePath,
        `online_report.steps[${index}].report_paths[${pathIndex}]`
      );
      reportPaths.push(safePath);
    }
    steps.push({
      name,
      report_paths: reportPaths
    });
  }
  return steps;
}

async function fixedOutputStep(outputDir, name, reportPath) {
  const safePath = assertSafeOutputPath(reportPath, `${name}.report_path`);
  await assertOutputFile(outputDir, safePath, `${name}.report_path`);
  return {
    name,
    report_paths: [safePath]
  };
}

async function sanitizeConsumeSteps(outputDir, producerSteps) {
  const steps = [];
  for (const [index, stepValue] of requireArray(
    producerSteps,
    'airgap_consume_rehearsal_report.steps'
  ).entries()) {
    const step = requireObject(stepValue, `airgap_consume_rehearsal_report.steps[${index}]`);
    const name = requireString(step.name, `airgap_consume_rehearsal_report.steps[${index}].name`);
    const safePath = assertSafeOutputPath(
      step.report_path,
      `airgap_consume_rehearsal_report.steps[${index}].report_path`
    );
    await assertOutputFile(
      outputDir,
      safePath,
      `airgap_consume_rehearsal_report.steps[${index}].report_path`
    );
    steps.push({
      name,
      report_paths: [safePath]
    });
  }
  return steps;
}

function findSubjectFileDigest(subject, filePath) {
  for (const [index, item] of requireArray(subject.files, 'evidence_subject.files').entries()) {
    const entry = requireObject(item, `evidence_subject.files[${index}]`);
    const pathValue = requireString(entry.path, `evidence_subject.files[${index}].path`);
    if (pathValue === filePath) {
      return requireDigest(entry.sha256, `evidence_subject.files[${index}].sha256`);
    }
  }
  fail(`evidence_subject.files must include ${filePath}`);
}

async function buildOnlineHandoff(args, releaseIdentity) {
  if (!args.evidenceRoot) {
    return undefined;
  }

  const evidenceRoot = path.resolve(args.evidenceRoot);
  const evidenceInput = await readJson(path.join(evidenceRoot, EVIDENCE_FILE), 'online evidence');
  const subjectInput = await readJson(
    path.join(evidenceRoot, EVIDENCE_SUBJECT_FILE),
    'online evidence subject'
  );
  const evidenceReportInput = await readJson(
    path.join(evidenceRoot, ONLINE_PRODUCER_REPORT_FILE),
    'online evidence gate report'
  );
  const evidence = requireObject(evidenceInput.value, 'online_evidence');
  const subject = requireObject(subjectInput.value, 'online_evidence_subject');
  const evidenceReport = requireObject(
    evidenceReportInput.value,
    'online_evidence_gate_report'
  );

  assertStringEquals(
    evidence.schema_version,
    EVIDENCE_SCHEMA,
    'online_evidence.schema_version'
  );
  assertStringEquals(
    evidence.release_kit_output,
    ONLINE_PRODUCER_REPORT_FILE,
    'online_evidence.release_kit_output'
  );
  assertStringEquals(evidence.release_id, releaseIdentity.releaseId, 'online_evidence.release_id');
  const evidenceGitSha = requireGitSha(evidence.git_sha, 'online_evidence.git_sha');
  if (evidenceGitSha !== releaseIdentity.gitSha) {
    fail('online_evidence.git_sha must match release contract');
  }
  const evidenceReleaseContractDigest = requireDigest(
    evidence.release_contract_digest,
    'online_evidence.release_contract_digest'
  );
  if (evidenceReleaseContractDigest !== releaseIdentity.releaseContractDigest) {
    fail('online_evidence.release_contract_digest must match release contract input');
  }

  assertStringEquals(
    subject.schema_version,
    EVIDENCE_SUBJECT_SCHEMA,
    'online_evidence_subject.schema_version'
  );
  findSubjectFileDigest(subject, EVIDENCE_FILE);
  const subjectGateReportDigest = findSubjectFileDigest(subject, ONLINE_PRODUCER_REPORT_FILE);
  if (subjectGateReportDigest !== evidenceReportInput.digest) {
    fail('online_evidence_subject gate report digest must match evidence root gate report');
  }

  assertProducerBase({
    report: evidenceReport,
    label: 'online_evidence_gate_report',
    schema: ONLINE_PRODUCER_SCHEMA,
    scope: ONLINE_PRODUCER_SCOPE,
    args,
    releaseIdentity
  });
  assertReleaseContractDigest(evidenceReport, 'online_evidence_gate_report', releaseIdentity);

  const provenance = requireObject(
    evidence.artifact_provenance,
    'online_evidence.artifact_provenance'
  );
  const subjectSha256 = requireDigest(
    provenance.subject_sha256,
    'online_evidence.artifact_provenance.subject_sha256'
  );
  if (subjectSha256 !== canonicalDigest(subject)) {
    fail('online_evidence.artifact_provenance.subject_sha256 must match evidence subject');
  }

  return {
    evidence_digest: evidenceInput.digest,
    evidence_subject_digest: subjectInput.digest,
    online_deployment_gate_report_digest: evidenceReportInput.digest,
    artifact_uri: requireString(
      provenance.artifact_uri,
      'online_evidence.artifact_provenance.artifact_uri'
    ),
    provenance_kind: requireEnumString(
      provenance.provenance_kind,
      'online_evidence.artifact_provenance.provenance_kind',
      ONLINE_HANDOFF_PROVENANCE_KINDS
    ),
    subject_sha256: subjectSha256
  };
}

function parseTargetRegistry(value) {
  const text = requireString(value, 'target_registry');
  const parts = text.split('/');
  const host = parts.shift();
  const summary = {
    host
  };
  if (parts.length > 0) {
    summary.namespace = parts.join('/');
  }
  return summary;
}

function parseTargetRegistryFromImage(value, label) {
  const imageRef = requireString(value, label);
  const withoutDigest = imageRef.split('@')[0];
  const withoutTag = withoutDigest.replace(/:[^/:]*$/, '');
  const parts = withoutTag.split('/').filter(Boolean);
  if (parts.length < 2) {
    fail(`${label} must include a registry host`);
  }
  return {
    host: parts[0]
  };
}

function targetRegistrySummaryFromManifest(manifest) {
  const declarations = requireArray(
    manifest.image_artifact_declarations,
    'airgap_bundle_manifest.image_artifact_declarations'
  );
  if (declarations.length === 0) {
    fail('airgap_bundle_manifest.image_artifact_declarations must not be empty');
  }
  const summaries = declarations.map((item, index) => {
    const declaration = requireObject(
      item,
      `airgap_bundle_manifest.image_artifact_declarations[${index}]`
    );
    return parseTargetRegistryFromImage(
      declaration.target_image,
      `airgap_bundle_manifest.image_artifact_declarations[${index}].target_image`
    );
  });
  const host = summaries[0].host;
  if (summaries.some((summary) => summary.host !== host)) {
    fail('airgap bundle target images must share one target registry host');
  }
  return {
    host
  };
}

function assertNoForbiddenKeys(value, label = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoForbiddenKeys(item, `${label}[${index}]`));
    return;
  }
  for (const [key, nested] of Object.entries(value)) {
    if (FORBIDDEN_OUTPUT_KEYS.has(key)) {
      fail(`operator summary must not include forbidden key: ${label}.${key}`);
    }
    assertNoForbiddenKeys(nested, `${label}.${key}`);
  }
}

function assertSafeSummary(summary) {
  assertNoForbiddenKeys(summary);
  const serialized = JSON.stringify(summary);
  if (FORBIDDEN_OUTPUT_TEXT_RE.test(serialized)) {
    fail('operator summary must not include forbidden readiness or verdict wording');
  }
  if (LOCAL_OR_SECRET_TEXT_RE.test(serialized)) {
    fail('operator summary must not include raw local paths, tool/probe details, or operator refs');
  }
}

async function releaseIdentityFromContract(file) {
  const releaseContractInput = await readJson(file, 'release contract');
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  return {
    releaseId: requireString(contract.release_id, 'release_contract.release_id'),
    gitSha: requireGitSha(contract.git_sha, 'release_contract.git_sha'),
    releaseContractDigest: releaseContractInput.digest
  };
}

async function buildOnlineSummary(args, releaseIdentity) {
  const outputDir = path.resolve(args.outputDir);
  const producerReportPath = path.join(outputDir, ONLINE_PRODUCER_REPORT_FILE);
  const producerReportInput = await readJson(producerReportPath, 'online deployment gate report');
  const producerReport = requireObject(
    producerReportInput.value,
    'online_deployment_gate_report'
  );

  assertProducerBase({
    report: producerReport,
    label: 'online_deployment_gate_report',
    schema: ONLINE_PRODUCER_SCHEMA,
    scope: ONLINE_PRODUCER_SCOPE,
    args,
    releaseIdentity
  });
  assertReleaseContractDigest(
    producerReport,
    'online_deployment_gate_report',
    releaseIdentity
  );
  const onlineHandoff = await buildOnlineHandoff(args, releaseIdentity);

  return {
    producer_report_digests: {
      online_deployment_gate_report: producerReportInput.digest
    },
    steps: await sanitizeProducerSteps(outputDir, producerReport.steps),
    ...(onlineHandoff ? { online_handoff: onlineHandoff } : {})
  };
}

async function buildAirgapSummary(args, releaseIdentity) {
  const outputDir = path.resolve(args.outputDir);
  const bundleRoot = path.resolve(args.bundleRoot);
  const bundleCreateReportPath = path.join(outputDir, BUNDLE_CREATE_REPORT_FILE);
  const checkReportPath = path.join(outputDir, AIRGAP_BUNDLE_CHECK_REPORT_FILE);
  const manifestPath = path.join(bundleRoot, AIRGAP_BUNDLE_MANIFEST_FILE);
  const bundleCreateInput = await readJson(bundleCreateReportPath, 'bundle create report');
  const checkReportInput = await readJson(checkReportPath, 'airgap bundle check report');
  const manifestInput = await readJson(manifestPath, 'airgap bundle manifest');
  const bundleCreateReport = requireObject(bundleCreateInput.value, 'bundle_create_report');
  const checkReport = requireObject(checkReportInput.value, 'airgap_bundle_check_report');
  const manifest = requireObject(manifestInput.value, 'airgap_bundle_manifest');

  assertProducerBase({
    report: bundleCreateReport,
    label: 'bundle_create_report',
    schema: BUNDLE_CREATE_SCHEMA,
    scope: BUNDLE_CREATE_SCOPE,
    args,
    releaseIdentity
  });
  assertProducerBase({
    report: checkReport,
    label: 'airgap_bundle_check_report',
    schema: AIRGAP_BUNDLE_CHECK_SCHEMA,
    scope: AIRGAP_BUNDLE_CHECK_SCOPE,
    args,
    releaseIdentity
  });
  assertStringEquals(
    manifest.schema_version,
    AIRGAP_BUNDLE_MANIFEST_SCHEMA,
    'airgap_bundle_manifest.schema_version'
  );
  assertStringEquals(
    manifest.release_id,
    releaseIdentity.releaseId,
    'airgap_bundle_manifest.release_id'
  );
  const manifestGitSha = requireGitSha(manifest.git_sha, 'airgap_bundle_manifest.git_sha');
  if (manifestGitSha !== releaseIdentity.gitSha) {
    fail('airgap_bundle_manifest.git_sha must match release contract');
  }
  if (targetProfileValue(manifest, 'airgap_bundle_manifest') !== args.machineProfile) {
    fail('airgap_bundle_manifest.target_profile.value must match machine profile');
  }
  assertArtifactReleaseContractDigest(bundleCreateReport, 'bundle_create_report', releaseIdentity);
  assertArtifactReleaseContractDigest(checkReport, 'airgap_bundle_check_report', releaseIdentity);

  return {
    producer_report_digests: {
      bundle_create_report: bundleCreateInput.digest,
      airgap_bundle_check_report: checkReportInput.digest
    },
    steps: [
      await fixedOutputStep(outputDir, 'bundle-create', BUNDLE_CREATE_REPORT_FILE),
      await fixedOutputStep(outputDir, 'airgap-bundle-check', AIRGAP_BUNDLE_CHECK_REPORT_FILE)
    ],
    airgap_handoff: {
      bundle_manifest_digest: manifestInput.digest,
      airgap_bundle_check_report_digest: checkReportInput.digest,
      image_count: requireNonNegativeInteger(
        checkReport.image_artifact_declaration_count,
        'airgap_bundle_check_report.image_artifact_declaration_count'
      ),
      payload_artifact_count: requireNonNegativeInteger(
        checkReport.payload_artifact_count,
        'airgap_bundle_check_report.payload_artifact_count'
      ),
      tool_count: requireNonNegativeInteger(
        checkReport.tool_count,
        'airgap_bundle_check_report.tool_count'
      ),
      target_registry_summary: parseTargetRegistry(args.targetRegistry)
    }
  };
}

function releaseIdentityFromConsumeReport(consumeReport) {
  const inputDigests = requireObject(
    consumeReport.input_digests,
    'airgap_consume_rehearsal_report.input_digests'
  );
  return {
    releaseId: requireString(consumeReport.release_id, 'airgap_consume_rehearsal_report.release_id'),
    gitSha: requireGitSha(consumeReport.git_sha, 'airgap_consume_rehearsal_report.git_sha'),
    releaseContractDigest: requireDigest(
      inputDigests.release_contract,
      'airgap_consume_rehearsal_report.input_digests.release_contract'
    )
  };
}

function assertAirgapManifestIdentity(manifest, releaseIdentity, args) {
  assertStringEquals(
    manifest.schema_version,
    AIRGAP_BUNDLE_MANIFEST_SCHEMA,
    'airgap_bundle_manifest.schema_version'
  );
  assertStringEquals(
    manifest.release_id,
    releaseIdentity.releaseId,
    'airgap_bundle_manifest.release_id'
  );
  const manifestGitSha = requireGitSha(manifest.git_sha, 'airgap_bundle_manifest.git_sha');
  if (manifestGitSha !== releaseIdentity.gitSha) {
    fail('airgap_bundle_manifest.git_sha must match consume report');
  }
  if (targetProfileValue(manifest, 'airgap_bundle_manifest') !== args.machineProfile) {
    fail('airgap_bundle_manifest.target_profile.value must match machine profile');
  }
}

function assertConsumeDigestBindings({
  consumeReport,
  consumeInput,
  bundleCheckInput,
  deploymentGateInput,
  manifestInput
}) {
  const inputDigests = requireObject(
    consumeReport.input_digests,
    'airgap_consume_rehearsal_report.input_digests'
  );
  const producerDigests = requireObject(
    consumeReport.producer_report_digests,
    'airgap_consume_rehearsal_report.producer_report_digests'
  );
  const bundleManifestDigest = requireDigest(
    inputDigests.bundle_manifest,
    'airgap_consume_rehearsal_report.input_digests.bundle_manifest'
  );
  if (bundleManifestDigest !== manifestInput.digest) {
    fail('airgap consume bundle manifest digest must match bundle manifest');
  }
  const bundleCheckDigest = requireDigest(
    producerDigests.airgap_bundle_check_report,
    'airgap_consume_rehearsal_report.producer_report_digests.airgap_bundle_check_report'
  );
  if (bundleCheckDigest !== bundleCheckInput.digest) {
    fail('airgap consume bundle-check digest must match nested report');
  }
  const deploymentGateDigest = requireDigest(
    producerDigests.airgap_deployment_gate_report,
    'airgap_consume_rehearsal_report.producer_report_digests.airgap_deployment_gate_report'
  );
  if (deploymentGateDigest !== deploymentGateInput.digest) {
    fail('airgap consume deployment-gate digest must match nested report');
  }
  return {
    airgap_consume_rehearsal_report: consumeInput.digest,
    airgap_bundle_check_report: bundleCheckInput.digest,
    airgap_deployment_gate_report: deploymentGateInput.digest
  };
}

async function buildAirgapConsumeSummary(args) {
  const outputDir = path.resolve(args.outputDir);
  const bundleRoot = path.resolve(args.bundleRoot);
  const consumeReportPath = path.join(outputDir, AIRGAP_CONSUME_REPORT_FILE);
  const bundleCheckReportPath = path.join(
    outputDir,
    'airgap-bundle-check',
    AIRGAP_BUNDLE_CHECK_REPORT_FILE
  );
  const deploymentGateReportPath = path.join(
    outputDir,
    'airgap-deployment-gate',
    AIRGAP_DEPLOYMENT_GATE_REPORT_FILE
  );
  const manifestPath = path.join(bundleRoot, AIRGAP_BUNDLE_MANIFEST_FILE);
  const consumeInput = await readJson(consumeReportPath, 'airgap consume rehearsal report');
  const bundleCheckInput = await readJson(bundleCheckReportPath, 'airgap bundle check report');
  const deploymentGateInput = await readJson(
    deploymentGateReportPath,
    'airgap deployment gate report'
  );
  const manifestInput = await readJson(manifestPath, 'airgap bundle manifest');
  const consumeReport = requireObject(
    consumeInput.value,
    'airgap_consume_rehearsal_report'
  );
  const bundleCheckReport = requireObject(
    bundleCheckInput.value,
    'airgap_bundle_check_report'
  );
  const deploymentGateReport = requireObject(
    deploymentGateInput.value,
    'airgap_deployment_gate_report'
  );
  const manifest = requireObject(manifestInput.value, 'airgap_bundle_manifest');
  const releaseIdentity = releaseIdentityFromConsumeReport(consumeReport);

  assertProducerBase({
    report: consumeReport,
    label: 'airgap_consume_rehearsal_report',
    schema: AIRGAP_CONSUME_SCHEMA,
    scope: AIRGAP_CONSUME_SCOPE,
    args,
    releaseIdentity
  });
  assertProducerBase({
    report: bundleCheckReport,
    label: 'airgap_bundle_check_report',
    schema: AIRGAP_BUNDLE_CHECK_SCHEMA,
    scope: AIRGAP_BUNDLE_CHECK_SCOPE,
    args,
    releaseIdentity
  });
  assertProducerBase({
    report: deploymentGateReport,
    label: 'airgap_deployment_gate_report',
    schema: AIRGAP_DEPLOYMENT_GATE_SCHEMA,
    scope: AIRGAP_DEPLOYMENT_GATE_SCOPE,
    args,
    releaseIdentity
  });
  assertArtifactReleaseContractDigest(
    bundleCheckReport,
    'airgap_bundle_check_report',
    releaseIdentity
  );
  assertReleaseContractDigest(
    deploymentGateReport,
    'airgap_deployment_gate_report',
    releaseIdentity
  );
  assertAirgapManifestIdentity(manifest, releaseIdentity, args);
  const producerReportDigests = assertConsumeDigestBindings({
    consumeReport,
    consumeInput,
    bundleCheckInput,
    deploymentGateInput,
    manifestInput
  });

  return {
    releaseIdentity,
    producerSummary: {
      producer_report_digests: producerReportDigests,
      steps: await sanitizeConsumeSteps(outputDir, consumeReport.steps),
      airgap_handoff: {
        bundle_manifest_digest: manifestInput.digest,
        airgap_bundle_check_report_digest: bundleCheckInput.digest,
        airgap_deployment_gate_report_digest: deploymentGateInput.digest,
        image_count: requireNonNegativeInteger(
          bundleCheckReport.image_artifact_declaration_count,
          'airgap_bundle_check_report.image_artifact_declaration_count'
        ),
        payload_artifact_count: requireNonNegativeInteger(
          bundleCheckReport.payload_artifact_count,
          'airgap_bundle_check_report.payload_artifact_count'
        ),
        tool_count: requireNonNegativeInteger(
          bundleCheckReport.tool_count,
          'airgap_bundle_check_report.tool_count'
        ),
        target_registry_summary: targetRegistrySummaryFromManifest(manifest)
      }
    }
  };
}

async function writeSummary(outputDir, summary) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.operator-release-surface.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(summary, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main(argv) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log(usage());
    return;
  }

  assertMapping(args);
  let releaseIdentity;
  let producerSummary;
  if (args.producerMode === 'airgap-consume-rehearsal') {
    const airgapConsume = await buildAirgapConsumeSummary(args);
    releaseIdentity = airgapConsume.releaseIdentity;
    producerSummary = airgapConsume.producerSummary;
  } else {
    releaseIdentity = await releaseIdentityFromContract(args.releaseContract);
    producerSummary = args.producerMode === 'online-deployment-gate'
      ? await buildOnlineSummary(args, releaseIdentity)
      : await buildAirgapSummary(args, releaseIdentity);
  }
  const outputDir = path.resolve(args.outputDir);
  const summary = {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    surface: args.surface,
    substrate_strategy: args.substrateStrategy,
    machine_profile: args.machineProfile,
    release_id: releaseIdentity.releaseId,
    git_sha: releaseIdentity.gitSha,
    release_contract_digest: releaseIdentity.releaseContractDigest,
    producer_report_digests: producerSummary.producer_report_digests,
    steps: producerSummary.steps,
    ...(producerSummary.online_handoff
      ? { online_handoff: producerSummary.online_handoff }
      : {}),
    ...(producerSummary.airgap_handoff
      ? { airgap_handoff: producerSummary.airgap_handoff }
      : {})
  };

  assertSafeSummary(summary);
  await writeSummary(outputDir, summary);
  console.log(`PASS: wrote ${REPORT_FILE}`);
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
