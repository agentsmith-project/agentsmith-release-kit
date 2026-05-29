#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = [
  'surface',
  'substrateStrategy',
  'machineProfile',
  'producerMode',
  'releaseContract',
  'outputDir'
];
const REPORT_SCHEMA = 'agentsmith.operator-release-surface-report/v1';
const REPORT_SCOPE = 'operator_release_surface_v0';
const REPORT_FILE = 'operator-release-surface-report.json';
const ONLINE_PRODUCER_REPORT_FILE = 'online-deployment-gate-report.json';
const BUNDLE_CREATE_REPORT_FILE = 'bundle-create-report.json';
const AIRGAP_BUNDLE_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const AIRGAP_BUNDLE_MANIFEST_FILE = 'airgap-bundle-manifest.json';
const ONLINE_PRODUCER_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const ONLINE_PRODUCER_SCOPE = 'online_deployment_gate_only';
const BUNDLE_CREATE_SCHEMA = 'agentsmith.airgap-bundle-create-report/v1';
const BUNDLE_CREATE_SCOPE = 'airgap_bundle_create_only';
const AIRGAP_BUNDLE_CHECK_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const AIRGAP_BUNDLE_CHECK_SCOPE = 'airgap_bundle_manifest_check_only';
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
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
    --surface online|airgap-bundle \\
    --substrate-strategy use_existing|install_substrates \\
    --machine-profile <mapped-profile> \\
    --producer-mode online-deployment-gate|bundle-create \\
    --release-contract <json> \\
    --output-dir <dir> \\
    [--bundle-root <dir> --target-registry <registry-host[/namespace]>]`;
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
  if (args.producerMode === 'bundle-create' && (!args.bundleRoot || !args.targetRegistry)) {
    cliFail('bundle-create summaries require --bundle-root and --target-registry');
  }
  if (args.producerMode !== 'bundle-create' && (args.bundleRoot || args.targetRegistry)) {
    cliFail('online summaries do not accept --bundle-root or --target-registry');
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

  return {
    producer_report_digests: {
      online_deployment_gate_report: producerReportInput.digest
    },
    steps: await sanitizeProducerSteps(outputDir, producerReport.steps)
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
  const releaseIdentity = await releaseIdentityFromContract(args.releaseContract);
  const outputDir = path.resolve(args.outputDir);
  const producerSummary = args.producerMode === 'online-deployment-gate'
    ? await buildOnlineSummary(args, releaseIdentity)
    : await buildAirgapSummary(args, releaseIdentity);
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
