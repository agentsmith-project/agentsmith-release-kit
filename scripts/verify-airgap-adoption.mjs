#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REPORT_FILE = 'airgap-adoption-report.json';
const REQUIRED_ARGS = [
  'releaseContract',
  'bundleSurfaceReport',
  'consumeSurfaceReport',
  'bundleManifest',
  'outputDir'
];
const REPORT_SCHEMA = 'agentsmith.airgap-adoption/v1';
const REPORT_SCOPE = 'airgap_adoption_only';
const SURFACE_SCHEMA = 'agentsmith.operator-release-surface-report/v1';
const SURFACE_SCOPE = 'operator_release_surface_v0';
const BUNDLE_CREATE_SCHEMA = 'agentsmith.airgap-bundle-create-report/v1';
const BUNDLE_CREATE_SCOPE = 'airgap_bundle_create_only';
const AIRGAP_BUNDLE_CHECK_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const AIRGAP_BUNDLE_CHECK_SCOPE = 'airgap_bundle_manifest_check_only';
const BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const AIRGAP_PROFILE = 'existing_kubernetes/external_declared/airgap';
const AIRGAP_CONSUME_SCHEMA = 'agentsmith.airgap-consume-rehearsal/v1';
const AIRGAP_CONSUME_SCOPE = 'airgap_consume_rehearsal_only';
const AIRGAP_DEPLOYMENT_GATE_SCHEMA = 'agentsmith.airgap-deployment-gate/v1';
const AIRGAP_DEPLOYMENT_GATE_SCOPE = 'airgap_deployment_gate_only';
const BUNDLE_CREATE_REPORT_FILE = 'bundle-create-report.json';
const AIRGAP_BUNDLE_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const AIRGAP_CONSUME_REPORT_FILE = 'airgap-consume-rehearsal-report.json';
const AIRGAP_DEPLOYMENT_GATE_REPORT_FILE = 'airgap-deployment-gate-report.json';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const REQUIRED_DEPLOYMENT_STEPS = [
  'airgap-image-load',
  'airgap-bundle-render-check',
  'apply',
  'rollout',
  'smoke'
];
const FORBIDDEN_OUTPUT_KEYS = new Set([
  'verdict',
  'release_verdict',
  'release_readiness',
  'package_readiness',
  'operator_verdict',
  'deploy_readiness',
  'offline_install_readiness',
  'ready',
  'kubeconfig',
  'secret',
  'secrets',
  'operator_identity',
  'signature_uri',
  'signature_sha256',
  'raw_path',
  'raw_paths',
  'report_path',
  'report_paths'
]);
const FORBIDDEN_OUTPUT_TEXT_RE =
  /\b(?:verdict|release_verdict|release_readiness|package_readiness|operator_verdict|deploy_readiness|offline_install_readiness)\b/i;
const LOCAL_OR_SECRET_TEXT_RE =
  /(?:^|["'\s])(?:\/home\/|\/tmp\/|\/var\/|\/private\/|[A-Za-z]:[\\/]|file:\/\/)|secretRef:|kubeconfig|Bearer\s+[A-Za-z0-9._~+/=-]+|token\s*[:=]|password\s*[:=]|operator_identity|signature_uri/i;

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
  node scripts/verify-airgap-adoption.mjs \\
    --release-contract <json> \\
    --bundle-surface-report <airgap-bundle/operator-release-surface-report.json> \\
    --consume-surface-report <airgap/operator-release-surface-report.json> \\
    --bundle-manifest <airgap-bundle-manifest.json> \\
    --output-dir <dir>

This is repo-local airgap/use_existing adoption aggregation only. It validates
already generated operator-facing airgap-bundle/use_existing and
airgap/use_existing confirmed-apply summaries and writes ${REPORT_FILE}; it is
not deploy, package, operator signoff, full release gate, or release readiness.`;
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
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--bundle-surface-report':
        parsed.bundleSurfaceReport = nextValue();
        break;
      case '--consume-surface-report':
        parsed.consumeSurfaceReport = nextValue();
        break;
      case '--bundle-manifest':
        parsed.bundleManifest = nextValue();
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

function assertProfile(report, label) {
  const profile = requireObject(report.target_profile, `${label}.target_profile`);
  const targetCluster = requireString(
    profile.target_cluster,
    `${label}.target_profile.target_cluster`
  );
  const substrateSource = requireString(
    profile.substrate_source,
    `${label}.target_profile.substrate_source`
  );
  const distribution = requireString(
    profile.distribution,
    `${label}.target_profile.distribution`
  );
  const computed = `${targetCluster}/${substrateSource}/${distribution}`;
  assertStringEquals(profile.value, computed, `${label}.target_profile.value`);
  if (computed !== AIRGAP_PROFILE) {
    fail(`${label}.target_profile must be ${AIRGAP_PROFILE}`);
  }
}

function releaseIdentityFromContract(releaseContractInput) {
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  return {
    releaseId: requireString(contract.release_id, 'release_contract.release_id'),
    gitSha: requireGitSha(contract.git_sha, 'release_contract.git_sha'),
    releaseContractDigest: releaseContractInput.digest
  };
}

function assertReleaseIdentity(report, label, releaseIdentity) {
  assertStringEquals(report.release_id, releaseIdentity.releaseId, `${label}.release_id`);
  const gitSha = requireGitSha(report.git_sha, `${label}.git_sha`);
  if (gitSha !== releaseIdentity.gitSha) {
    fail(`${label}.git_sha must match release contract`);
  }
}

function assertSurfaceBase(report, label, releaseIdentity) {
  assertStringEquals(report.schema, SURFACE_SCHEMA, `${label}.schema`);
  assertStringEquals(report.scope, SURFACE_SCOPE, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);
  assertReleaseIdentity(report, label, releaseIdentity);
  assertProfile(
    {
      target_profile: {
        value: report.machine_profile,
        target_cluster: report.machine_profile?.split('/')?.[0],
        substrate_source: report.machine_profile?.split('/')?.[1],
        distribution: report.machine_profile?.split('/')?.[2]
      }
    },
    label
  );
  const releaseContractDigest = requireDigest(
    report.release_contract_digest,
    `${label}.release_contract_digest`
  );
  if (releaseContractDigest !== releaseIdentity.releaseContractDigest) {
    fail(`${label}.release_contract_digest must match release contract input`);
  }
}

function assertProducerBase(report, label, { schema, scope, releaseIdentity }) {
  assertStringEquals(report.schema, schema, `${label}.schema`);
  assertStringEquals(report.scope, scope, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);
  assertReleaseIdentity(report, label, releaseIdentity);
  assertProfile(report, label);
}

function assertReleaseContractDigestObject(report, label, releaseIdentity) {
  const releaseContract = requireObject(
    report.release_contract,
    `${label}.release_contract`
  );
  const digest = requireDigest(
    releaseContract.input_sha256,
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

function assertSafeRelativePath(value, label) {
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

function assertInside(rootDir, file, label) {
  const relative = path.relative(rootDir, file);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must stay inside the surface output directory`);
  }
}

async function readOutputRelativeJson(outputDir, relativePath, label) {
  const safePath = assertSafeRelativePath(relativePath, `${label}.path`);
  const absolutePath = path.join(outputDir, safePath);
  assertInside(outputDir, absolutePath, label);
  return readJson(absolutePath, label);
}

function stepNames(report, label) {
  return requireArray(report.steps, `${label}.steps`).map((stepValue, index) => {
    const step = requireObject(stepValue, `${label}.steps[${index}]`);
    return requireString(step.name, `${label}.steps[${index}].name`);
  });
}

function requireStep(report, stepName, label) {
  for (const [index, stepValue] of requireArray(report.steps, `${label}.steps`).entries()) {
    const step = requireObject(stepValue, `${label}.steps[${index}]`);
    const name = requireString(step.name, `${label}.steps[${index}].name`);
    if (name !== stepName) {
      continue;
    }
    const reportPaths = requireArray(
      step.report_paths,
      `${label}.steps[${index}].report_paths`
    );
    if (reportPaths.length !== 1) {
      fail(`${label}.steps.${stepName}.report_paths must contain one report`);
    }
    return requireString(
      reportPaths[0],
      `${label}.steps[${index}].report_paths[0]`
    );
  }
  fail(`${label}.steps must include ${stepName}`);
}

function requireConsumeStep(report, stepName, label) {
  for (const [index, stepValue] of requireArray(report.steps, `${label}.steps`).entries()) {
    const step = requireObject(stepValue, `${label}.steps[${index}]`);
    const name = requireString(step.name, `${label}.steps[${index}].name`);
    if (name === stepName) {
      return requireString(step.report_path, `${label}.steps[${index}].report_path`);
    }
  }
  fail(`${label}.steps must include ${stepName}`);
}

function requireDigestKey(object, key, label) {
  return requireDigest(
    requireObject(object, label)[key],
    `${label}.${key}`
  );
}

function assertDigestEquals(actual, expected, label) {
  if (actual !== expected) {
    fail(`${label} digest mismatch`);
  }
}

function targetRegistryFromImage(imageRef, label) {
  const image = requireString(imageRef, label);
  const withoutDigest = image.split('@')[0];
  const withoutTag = withoutDigest.replace(/:[^/:]*$/, '');
  const parts = withoutTag.split('/').filter(Boolean);
  if (parts.length < 2) {
    fail(`${label} must include a registry host`);
  }
  return {
    host: parts[0],
    repositoryParts: parts.slice(1)
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
    return targetRegistryFromImage(
      declaration.target_image,
      `airgap_bundle_manifest.image_artifact_declarations[${index}].target_image`
    );
  });
  const host = summaries[0].host;
  if (summaries.some((summary) => summary.host !== host)) {
    fail('airgap bundle target images must share one target registry host');
  }
  return {
    host,
    repositoryParts: summaries.map((summary) => summary.repositoryParts)
  };
}

function normalizeRegistrySummary(value, label) {
  const summary = requireObject(value, label);
  const host = requireString(summary.host, `${label}.host`);
  const normalized = { host };
  if (summary.namespace !== undefined) {
    normalized.namespace = requireString(summary.namespace, `${label}.namespace`);
  }
  return normalized;
}

function assertRegistryBindable({
  bundleSummary,
  consumeSummary,
  manifestSummary
}) {
  if (bundleSummary.host !== manifestSummary.host) {
    fail('bundle target registry host must match bundle manifest target images');
  }
  if (consumeSummary.host !== manifestSummary.host) {
    fail('consume target registry host must match bundle manifest target images');
  }
  if (bundleSummary.namespace) {
    const namespaceParts = bundleSummary.namespace.split('/');
    const hasNamespace = manifestSummary.repositoryParts.every((parts) =>
      namespaceParts.every((part, index) => parts[index] === part)
    );
    if (!hasNamespace) {
      fail('bundle target registry namespace must bind to bundle manifest target images');
    }
  }
  if (consumeSummary.namespace && bundleSummary.namespace !== consumeSummary.namespace) {
    fail('bundle and consume target registry namespaces must match');
  }
}

function assertBundleManifest(manifest, releaseIdentity, manifestDigest) {
  assertStringEquals(
    manifest.schema_version,
    BUNDLE_MANIFEST_SCHEMA,
    'airgap_bundle_manifest.schema_version'
  );
  assertStringEquals(
    manifest.release_id,
    releaseIdentity.releaseId,
    'airgap_bundle_manifest.release_id'
  );
  const gitSha = requireGitSha(manifest.git_sha, 'airgap_bundle_manifest.git_sha');
  if (gitSha !== releaseIdentity.gitSha) {
    fail('airgap_bundle_manifest.git_sha must match release contract');
  }
  assertProfile(manifest, 'airgap_bundle_manifest');
  const bindings = requireObject(manifest.bindings, 'airgap_bundle_manifest.bindings');
  const releaseContractDigest = requireDigest(
    bindings.release_contract_sha256,
    'airgap_bundle_manifest.bindings.release_contract_sha256'
  );
  if (releaseContractDigest !== releaseIdentity.releaseContractDigest) {
    fail('airgap_bundle_manifest release contract binding must match release contract input');
  }
  requireDigest(manifestDigest, 'airgap_bundle_manifest input digest');
}

function assertSurfaceHandoff(surface, label, manifestDigest) {
  const handoff = requireObject(surface.airgap_handoff, `${label}.airgap_handoff`);
  const handoffManifestDigest = requireDigest(
    handoff.bundle_manifest_digest,
    `${label}.airgap_handoff.bundle_manifest_digest`
  );
  if (handoffManifestDigest !== manifestDigest) {
    fail(`${label}.airgap_handoff.bundle_manifest_digest must match bundle manifest input`);
  }
  return handoff;
}

async function validateBundleSurface({
  surfaceInput,
  releaseIdentity,
  manifestDigest
}) {
  const surface = requireObject(surfaceInput.value, 'bundle_surface_report');
  assertSurfaceBase(surface, 'bundle_surface_report', releaseIdentity);
  assertStringEquals(surface.surface, 'airgap-bundle', 'bundle_surface_report.surface');
  assertStringEquals(
    surface.substrate_strategy,
    'use_existing',
    'bundle_surface_report.substrate_strategy'
  );
  const handoff = assertSurfaceHandoff(surface, 'bundle_surface_report', manifestDigest);
  const producerDigests = requireObject(
    surface.producer_report_digests,
    'bundle_surface_report.producer_report_digests'
  );
  const outputDir = path.dirname(path.resolve(surfaceInput.file));
  const bundleCreatePath = requireStep(surface, 'bundle-create', 'bundle_surface_report');
  const bundleCheckPath = requireStep(surface, 'airgap-bundle-check', 'bundle_surface_report');
  const bundleCreateInput = await readOutputRelativeJson(
    outputDir,
    bundleCreatePath,
    'bundle_create_report'
  );
  const bundleCheckInput = await readOutputRelativeJson(
    outputDir,
    bundleCheckPath,
    'bundle_airgap_bundle_check_report'
  );
  assertSafeRelativePath(BUNDLE_CREATE_REPORT_FILE, 'bundle create fixed report');
  assertSafeRelativePath(AIRGAP_BUNDLE_CHECK_REPORT_FILE, 'bundle check fixed report');
  assertDigestEquals(
    requireDigestKey(producerDigests, 'bundle_create_report', 'bundle_surface_report.producer_report_digests'),
    bundleCreateInput.digest,
    'bundle_create_report'
  );
  assertDigestEquals(
    requireDigestKey(producerDigests, 'airgap_bundle_check_report', 'bundle_surface_report.producer_report_digests'),
    bundleCheckInput.digest,
    'bundle_airgap_bundle_check_report'
  );
  assertDigestEquals(
    requireDigest(
      handoff.airgap_bundle_check_report_digest,
      'bundle_surface_report.airgap_handoff.airgap_bundle_check_report_digest'
    ),
    bundleCheckInput.digest,
    'bundle surface airgap bundle check handoff'
  );

  const bundleCreateReport = requireObject(bundleCreateInput.value, 'bundle_create_report');
  const bundleCheckReport = requireObject(
    bundleCheckInput.value,
    'bundle_airgap_bundle_check_report'
  );
  assertProducerBase(bundleCreateReport, 'bundle_create_report', {
    schema: BUNDLE_CREATE_SCHEMA,
    scope: BUNDLE_CREATE_SCOPE,
    releaseIdentity
  });
  assertProducerBase(bundleCheckReport, 'bundle_airgap_bundle_check_report', {
    schema: AIRGAP_BUNDLE_CHECK_SCHEMA,
    scope: AIRGAP_BUNDLE_CHECK_SCOPE,
    releaseIdentity
  });
  assertArtifactReleaseContractDigest(
    bundleCreateReport,
    'bundle_create_report',
    releaseIdentity
  );
  assertArtifactReleaseContractDigest(
    bundleCheckReport,
    'bundle_airgap_bundle_check_report',
    releaseIdentity
  );

  return {
    surface,
    handoff,
    producerReportDigests: {
      bundle_create_report: bundleCreateInput.digest,
      airgap_bundle_check_report: bundleCheckInput.digest
    },
    steps: stepNames(surface, 'bundle_surface_report')
  };
}

async function validateConsumeSurface({
  surfaceInput,
  releaseIdentity,
  manifestDigest
}) {
  const surface = requireObject(surfaceInput.value, 'consume_surface_report');
  assertSurfaceBase(surface, 'consume_surface_report', releaseIdentity);
  assertStringEquals(surface.surface, 'airgap', 'consume_surface_report.surface');
  assertStringEquals(
    surface.substrate_strategy,
    'use_existing',
    'consume_surface_report.substrate_strategy'
  );
  const handoff = assertSurfaceHandoff(surface, 'consume_surface_report', manifestDigest);
  const producerDigests = requireObject(
    surface.producer_report_digests,
    'consume_surface_report.producer_report_digests'
  );
  const outputDir = path.dirname(path.resolve(surfaceInput.file));
  const consumeInput = await readJson(
    path.join(outputDir, AIRGAP_CONSUME_REPORT_FILE),
    'airgap consume rehearsal report'
  );
  const bundleCheckPath = requireStep(surface, 'airgap-bundle-check', 'consume_surface_report');
  const deploymentGatePath = requireStep(
    surface,
    'airgap-deployment-gate',
    'consume_surface_report'
  );
  const bundleCheckInput = await readOutputRelativeJson(
    outputDir,
    bundleCheckPath,
    'consume_airgap_bundle_check_report'
  );
  const deploymentGateInput = await readOutputRelativeJson(
    outputDir,
    deploymentGatePath,
    'airgap_deployment_gate_report'
  );

  assertDigestEquals(
    requireDigestKey(
      producerDigests,
      'airgap_consume_rehearsal_report',
      'consume_surface_report.producer_report_digests'
    ),
    consumeInput.digest,
    'airgap_consume_rehearsal_report'
  );
  assertDigestEquals(
    requireDigestKey(
      producerDigests,
      'airgap_bundle_check_report',
      'consume_surface_report.producer_report_digests'
    ),
    bundleCheckInput.digest,
    'consume_airgap_bundle_check_report'
  );
  assertDigestEquals(
    requireDigestKey(
      producerDigests,
      'airgap_deployment_gate_report',
      'consume_surface_report.producer_report_digests'
    ),
    deploymentGateInput.digest,
    'airgap_deployment_gate_report'
  );

  const consumeReport = requireObject(consumeInput.value, 'airgap_consume_rehearsal_report');
  const bundleCheckReport = requireObject(
    bundleCheckInput.value,
    'consume_airgap_bundle_check_report'
  );
  assertProducerBase(consumeReport, 'airgap_consume_rehearsal_report', {
    schema: AIRGAP_CONSUME_SCHEMA,
    scope: AIRGAP_CONSUME_SCOPE,
    releaseIdentity
  });
  assertProducerBase(bundleCheckReport, 'consume_airgap_bundle_check_report', {
    schema: AIRGAP_BUNDLE_CHECK_SCHEMA,
    scope: AIRGAP_BUNDLE_CHECK_SCOPE,
    releaseIdentity
  });
  assertArtifactReleaseContractDigest(
    bundleCheckReport,
    'consume_airgap_bundle_check_report',
    releaseIdentity
  );
  assertStringEquals(consumeReport.mode, 'apply', 'airgap_consume_rehearsal_report.mode');
  const inputDigests = requireObject(
    consumeReport.input_digests,
    'airgap_consume_rehearsal_report.input_digests'
  );
  assertDigestEquals(
    requireDigest(inputDigests.release_contract, 'airgap_consume_rehearsal_report.input_digests.release_contract'),
    releaseIdentity.releaseContractDigest,
    'airgap consume release contract input'
  );
  assertDigestEquals(
    requireDigest(inputDigests.bundle_manifest, 'airgap_consume_rehearsal_report.input_digests.bundle_manifest'),
    manifestDigest,
    'airgap consume bundle manifest input'
  );
  const consumeProducerDigests = requireObject(
    consumeReport.producer_report_digests,
    'airgap_consume_rehearsal_report.producer_report_digests'
  );
  assertDigestEquals(
    requireDigest(consumeProducerDigests.airgap_bundle_check_report, 'airgap_consume_rehearsal_report.producer_report_digests.airgap_bundle_check_report'),
    bundleCheckInput.digest,
    'consume report bundle check producer'
  );
  assertDigestEquals(
    requireDigest(consumeProducerDigests.airgap_deployment_gate_report, 'airgap_consume_rehearsal_report.producer_report_digests.airgap_deployment_gate_report'),
    deploymentGateInput.digest,
    'consume report deployment gate producer'
  );
  assertDigestEquals(
    requireDigest(
      handoff.airgap_bundle_check_report_digest,
      'consume_surface_report.airgap_handoff.airgap_bundle_check_report_digest'
    ),
    bundleCheckInput.digest,
    'consume surface airgap bundle check handoff'
  );
  assertDigestEquals(
    requireDigest(
      handoff.airgap_deployment_gate_report_digest,
      'consume_surface_report.airgap_handoff.airgap_deployment_gate_report_digest'
    ),
    deploymentGateInput.digest,
    'consume surface deployment gate handoff'
  );

  const deploymentGateReport = requireObject(
    deploymentGateInput.value,
    'airgap_deployment_gate_report'
  );
  assertProducerBase(deploymentGateReport, 'airgap_deployment_gate_report', {
    schema: AIRGAP_DEPLOYMENT_GATE_SCHEMA,
    scope: AIRGAP_DEPLOYMENT_GATE_SCOPE,
    releaseIdentity
  });
  assertStringEquals(deploymentGateReport.mode, 'apply', 'airgap_deployment_gate_report.mode');
  assertReleaseContractDigestObject(
    deploymentGateReport,
    'airgap_deployment_gate_report',
    releaseIdentity
  );
  requireString(
    deploymentGateReport.operator_run_id,
    'airgap_deployment_gate_report.operator_run_id'
  );
  const deploymentSteps = stepNames(
    deploymentGateReport,
    'airgap_deployment_gate_report'
  );
  for (const requiredStep of REQUIRED_DEPLOYMENT_STEPS) {
    if (!deploymentSteps.includes(requiredStep)) {
      fail(`airgap_deployment_gate_report.steps must include ${requiredStep}`);
    }
  }

  const consumeBundleCheckPath = requireConsumeStep(
    consumeReport,
    'airgap-bundle-check',
    'airgap_consume_rehearsal_report'
  );
  const consumeDeploymentPath = requireConsumeStep(
    consumeReport,
    'airgap-deployment-gate',
    'airgap_consume_rehearsal_report'
  );
  assertSafeRelativePath(consumeBundleCheckPath, 'airgap_consume_rehearsal_report bundle check path');
  assertSafeRelativePath(consumeDeploymentPath, 'airgap_consume_rehearsal_report deployment path');

  return {
    surface,
    handoff,
    producerReportDigests: {
      airgap_consume_rehearsal_report: consumeInput.digest,
      airgap_bundle_check_report: bundleCheckInput.digest,
      airgap_deployment_gate_report: deploymentGateInput.digest
    },
    steps: stepNames(surface, 'consume_surface_report'),
    deploymentSteps,
    mode: deploymentGateReport.mode,
    operatorRunIdPresent: true
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
      fail(`airgap adoption report must not include forbidden key: ${label}.${key}`);
    }
    assertNoForbiddenKeys(nested, `${label}.${key}`);
  }
}

function assertSafeReport(report) {
  assertNoForbiddenKeys(report);
  const serialized = JSON.stringify(report);
  if (FORBIDDEN_OUTPUT_TEXT_RE.test(serialized)) {
    fail('airgap adoption report must not include forbidden readiness or verdict wording');
  }
  if (LOCAL_OR_SECRET_TEXT_RE.test(serialized)) {
    fail('airgap adoption report must not include raw paths, kubeconfig, identities, signatures, or secrets');
  }
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-adoption.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main(argv) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log(usage());
    return;
  }

  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const releaseIdentity = releaseIdentityFromContract(releaseContractInput);
  const bundleManifestInput = await readJson(args.bundleManifest, 'airgap bundle manifest');
  const bundleManifest = requireObject(bundleManifestInput.value, 'airgap_bundle_manifest');
  assertBundleManifest(bundleManifest, releaseIdentity, bundleManifestInput.digest);

  const bundleSurfaceInput = {
    ...(await readJson(args.bundleSurfaceReport, 'airgap bundle operator surface report')),
    file: args.bundleSurfaceReport
  };
  const consumeSurfaceInput = {
    ...(await readJson(args.consumeSurfaceReport, 'airgap consume operator surface report')),
    file: args.consumeSurfaceReport
  };

  const bundleSummary = await validateBundleSurface({
    surfaceInput: bundleSurfaceInput,
    releaseIdentity,
    manifestDigest: bundleManifestInput.digest
  });
  const consumeSummary = await validateConsumeSurface({
    surfaceInput: consumeSurfaceInput,
    releaseIdentity,
    manifestDigest: bundleManifestInput.digest
  });

  assertDigestEquals(
    bundleSummary.producerReportDigests.airgap_bundle_check_report,
    consumeSummary.producerReportDigests.airgap_bundle_check_report,
    'bundle and consume airgap bundle check report'
  );

  const bundleRegistrySummary = normalizeRegistrySummary(
    bundleSummary.handoff.target_registry_summary,
    'bundle_surface_report.airgap_handoff.target_registry_summary'
  );
  const consumeRegistrySummary = normalizeRegistrySummary(
    consumeSummary.handoff.target_registry_summary,
    'consume_surface_report.airgap_handoff.target_registry_summary'
  );
  const manifestRegistrySummary = targetRegistrySummaryFromManifest(bundleManifest);
  assertRegistryBindable({
    bundleSummary: bundleRegistrySummary,
    consumeSummary: consumeRegistrySummary,
    manifestSummary: manifestRegistrySummary
  });

  const report = {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release: {
      release_id: releaseIdentity.releaseId,
      git_sha: releaseIdentity.gitSha
    },
    release_contract_digest: releaseIdentity.releaseContractDigest,
    bundle_manifest_digest: bundleManifestInput.digest,
    surface_report_digests: {
      airgap_bundle_surface_report: bundleSurfaceInput.digest,
      airgap_consume_surface_report: consumeSurfaceInput.digest
    },
    producer_report_digests: {
      bundle: bundleSummary.producerReportDigests,
      consume: consumeSummary.producerReportDigests
    },
    operator_paths: [
      {
        surface: 'airgap-bundle',
        substrate_strategy: 'use_existing',
        machine_profile: AIRGAP_PROFILE,
        steps: bundleSummary.steps
      },
      {
        surface: 'airgap',
        substrate_strategy: 'use_existing',
        machine_profile: AIRGAP_PROFILE,
        mode: consumeSummary.mode,
        operator_run_id_present: consumeSummary.operatorRunIdPresent,
        steps: consumeSummary.steps,
        deployment_steps: consumeSummary.deploymentSteps
      }
    ],
    target_registry_summary: bundleRegistrySummary
  };

  assertSafeReport(report);
  await writeReport(args.outputDir, report);
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
