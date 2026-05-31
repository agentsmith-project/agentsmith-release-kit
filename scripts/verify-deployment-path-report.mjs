#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REPORT_FILE = 'deployment-path-report.json';
const MANIFEST_FILE = 'deployment-path-finalizer-manifest.json';
const SOURCE_EVIDENCE_DIR = 'source-evidence';
const REPORT_SCHEMA = 'agentsmith.deployment-path-report/v1';
const MANIFEST_SCHEMA = 'agentsmith.deployment-path-finalizer-manifest/v1';
const SOURCE_EVIDENCE_SCHEMA = 'agentsmith.deployment-path-source-evidence/v1';
const FINALIZER_SCHEMA = 'agentsmith.deployment-path-report-finalizer/v1';
const FINALIZER_MANIFEST_TOOL = 'verify-deployment-path-report';
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const ONLINE_GATE_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const AIRGAP_GATE_SCHEMA = 'agentsmith.airgap-deployment-gate/v1';
const AIRGAP_BUNDLE_CHECK_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const IMAGE_MAP_SCOPE = 'image_map_only';
const SUBSTRATE_INSTALL_SCHEMA = 'agentsmith.substrate-install-report/v1';
const SUBSTRATE_INSTALL_SCOPE = 'substrate_install_only';
const SUBSTRATE_INSTALL_PRODUCER = 'agentsmith-release-kit-substrate-installer';
const TARGET_PREFLIGHT_SCHEMA = 'agentsmith.target-preflight-report/v1';
const SUBSTRATE_CONNECTION_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
const TARGET_PREREQUISITES_SCHEMA = 'agentsmith.target-prerequisites.truth/v1';
const RENDER_CHECK_SCHEMA = 'agentsmith.render-check-report/v1';
const APPLY_SCHEMA = 'agentsmith.kubernetes-apply-report/v1';
const ROLLOUT_SCHEMA = 'agentsmith.kubernetes-rollout-report/v1';
const ROUTE_SMOKE_SCHEMA = 'agentsmith.route-smoke-report/v1';
const AIRGAP_IMAGE_LOAD_SCHEMA = 'agentsmith.airgap-image-load-report/v1';
const AIRGAP_BUNDLE_RENDER_CHECK_SCHEMA = 'agentsmith.airgap-bundle-render-check-report/v1';
const AIRGAP_BUNDLE_CHECK_SCOPE = 'airgap_bundle_manifest_check_only';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const SERVICE_NAME_RE = /^[a-z][a-z0-9_-]{0,63}$/;
const TARGET_PREFLIGHT_SUBSTRATE_SERVICES = [
  'postgresql',
  'mongodb',
  'redis',
  'object_storage',
  'oidc'
];

const SOURCE_STEP_REPORTS = new Map([
  ['target-preflight', {
    schema: TARGET_PREFLIGHT_SCHEMA,
    scope: 'target_preflight_prerequisite_only'
  }],
  ['render-check', {
    schema: RENDER_CHECK_SCHEMA,
    scope: 'render_check_image_inventory_only'
  }],
  ['apply', {
    schema: APPLY_SCHEMA,
    scope: 'kubernetes_apply_only',
    mode: 'apply'
  }],
  ['rollout', {
    schema: ROLLOUT_SCHEMA,
    scope: 'kubernetes_rollout_imageid_only'
  }],
  ['smoke', {
    schema: ROUTE_SMOKE_SCHEMA,
    scope: 'route_smoke_only'
  }],
  ['airgap-image-load', {
    schema: AIRGAP_IMAGE_LOAD_SCHEMA,
    scope: 'airgap_image_load_only'
  }],
  ['airgap-bundle-render-check', {
    schema: AIRGAP_BUNDLE_RENDER_CHECK_SCHEMA,
    scope: 'airgap_bundle_render_check_only'
  }]
]);

const PATHS = new Map([
  [
    'online/use_existing',
    {
      source: 'online',
      targetProfile: 'existing_kubernetes/external_declared/online',
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['render-check', 'render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ],
  [
    'online/install_substrates',
    {
      source: 'online',
      targetProfile: 'existing_kubernetes/kit_installed/online',
      installSubstrates: true,
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['render-check', 'render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ],
  [
    'airgap/use_existing',
    {
      source: 'airgap',
      targetProfile: 'existing_kubernetes/external_declared/airgap',
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['image-load', 'airgap-image-load'],
        ['offline-render-check', 'airgap-bundle-render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ],
  [
    'airgap/install_substrates',
    {
      source: 'airgap',
      targetProfile: 'existing_kubernetes/kit_installed/airgap',
      installSubstrates: true,
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['image-load', 'airgap-image-load'],
        ['offline-render-check', 'airgap-bundle-render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ]
]);

const REQUIRED_ARGS = [
  'operatorPath',
  'releaseContract',
  'deployTemplatePackage',
  'outputDir'
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

function usage() {
  return `Usage:
  node scripts/verify-deployment-path-report.mjs \\
    --operator-path <online/use_existing|online/install_substrates> \\
    --release-contract <agentsmith-release-contract.json> \\
    --deploy-template-package <agentsmith-deploy-template-package.json> \\
    --online-deployment-gate-report <online-deployment-gate-report.json> \\
    --output-dir <dir>

  node scripts/verify-deployment-path-report.mjs \\
    --operator-path <airgap/use_existing|airgap/install_substrates> \\
    --release-contract <bundle-local-release-contract.json> \\
    --deploy-template-package <bundle-local-deploy-template-package.json> \\
    --airgap-deployment-gate-report <airgap-deployment-gate-report.json> \\
    --airgap-bundle-check-report <airgap-bundle-check-report.json> \\
    --airgap-bundle-manifest <airgap-bundle-manifest.json> \\
    --output-dir <dir>

Install-substrate paths additionally require:
    --substrate-install-report <substrate-install-report.json> \\
    --confirm-install-substrates <operator-run-id>

This is an internal finalizer. It writes ${REPORT_FILE}, ${MANIFEST_FILE}, and
${SOURCE_EVIDENCE_DIR}/ JSON copies for --ga-release and does not issue a
formal verdict or rerun deployment producers.`;
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
      case '--operator-path':
        parsed.operatorPath = nextValue();
        break;
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--deploy-template-package':
        parsed.deployTemplatePackage = nextValue();
        break;
      case '--online-deployment-gate-report':
        parsed.onlineDeploymentGateReport = nextValue();
        break;
      case '--airgap-deployment-gate-report':
        parsed.airgapDeploymentGateReport = nextValue();
        break;
      case '--airgap-bundle-check-report':
        parsed.airgapBundleCheckReport = nextValue();
        break;
      case '--airgap-bundle-manifest':
        parsed.airgapBundleManifest = nextValue();
        break;
      case '--substrate-install-report':
        parsed.substrateInstallReport = nextValue();
        break;
      case '--confirm-install-substrates':
        parsed.confirmInstallSubstrates = nextValue();
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
  if (!PATHS.has(parsed.operatorPath)) {
    cliFail(`unsupported operator path: ${parsed.operatorPath}`);
  }

  const requirement = PATHS.get(parsed.operatorPath);
  if (requirement.source === 'online') {
    if (!parsed.onlineDeploymentGateReport) {
      cliFail('--online-deployment-gate-report is required for online deployment path reports');
    }
    if (parsed.airgapDeploymentGateReport || parsed.airgapBundleCheckReport || parsed.airgapBundleManifest) {
      cliFail('airgap reports are not accepted for online deployment path reports');
    }
  }
  if (requirement.source === 'airgap') {
    for (const key of ['airgapDeploymentGateReport', 'airgapBundleCheckReport', 'airgapBundleManifest']) {
      if (!parsed[key]) {
        cliFail(`missing required argument: --${toKebab(key)}`);
      }
    }
    if (parsed.onlineDeploymentGateReport) {
      cliFail('--online-deployment-gate-report is not accepted for airgap deployment path reports');
    }
  }
  if (requirement.installSubstrates) {
    if (!parsed.substrateInstallReport || !parsed.confirmInstallSubstrates) {
      cliFail('install_substrates paths require --substrate-install-report and --confirm-install-substrates');
    }
    requireOperatorRunId(parsed.confirmInstallSubstrates, '--confirm-install-substrates');
  } else if (parsed.substrateInstallReport || parsed.confirmInstallSubstrates) {
    cliFail('substrate install inputs are accepted only for install_substrates paths');
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

function requireNonEmptyArray(value, label) {
  const array = requireArray(value, label);
  if (array.length === 0) {
    fail(`${label} must not be empty`);
  }
  return array;
}

function requireNonEmptyStringArray(value, label) {
  const array = requireNonEmptyArray(value, label);
  for (const [index, item] of array.entries()) {
    requireString(item, `${label}[${index}]`);
  }
  return array;
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function requireGitSha(value, label) {
  const gitSha = requireString(value, label);
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function requireOperatorRunId(value, label) {
  const runId = requireString(value, label);
  if (!OPERATOR_RUN_ID_RE.test(runId)) {
    fail(`${label} must be a safe operator run id`);
  }
  return runId;
}

function requireStatusPass(report, label) {
  if (report.status !== 'pass') {
    fail(`${label}.status must be pass`);
  }
}

function requireCheckPass(value, label) {
  if (value !== 'pass') {
    fail(`${label} must be pass`);
  }
}

function requireSchema(report, schema, label) {
  if (report.schema !== schema && report.schema_version !== schema) {
    fail(`${label}.schema must be ${schema}`);
  }
}

function reportSchema(report) {
  return report.schema ?? report.schema_version;
}

function requireReadinessFalse(report, label) {
  if (report.readiness !== false) {
    fail(`${label}.readiness must be false`);
  }
}

function requireNoFormalVerdict(report, label) {
  if (Object.prototype.hasOwnProperty.call(report, 'formal_verdict')) {
    fail(`${label} must not issue formal_verdict`);
  }
}

function parseTargetProfile(value, label) {
  const text = requireString(value, label);
  const tuple = text.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail(`${label} must be <target_cluster>/<substrate_source>/<distribution>`);
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function requireTargetProfile(value, expected, label) {
  const profile = requireObject(value, label);
  const parsed = parseTargetProfile(profile.value, `${label}.value`);
  if (parsed.value !== expected) {
    fail(`${label}.value must be ${expected}`);
  }
  for (const key of ['target_cluster', 'substrate_source', 'distribution']) {
    if (profile[key] !== parsed[key]) {
      fail(`${label}.${key} must match ${label}.value`);
    }
  }
  return parsed;
}

function requireTargetProfileString(value, expected, label) {
  const parsed = parseTargetProfile(requireString(value, label), label);
  if (parsed.value !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return parsed;
}

function sameArraySet(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) {
    return false;
  }
  const leftSet = new Set(left);
  const rightSet = new Set(right);
  if (leftSet.size !== left.length || rightSet.size !== right.length || leftSet.size !== rightSet.size) {
    return false;
  }
  return [...leftSet].every((item) => rightSet.has(item));
}

function validateReleaseInputs(contractInput, deployTemplateInput) {
  const contract = requireObject(contractInput.value, 'release contract');
  const deployTemplate = requireObject(deployTemplateInput.value, 'deploy template package');
  requireSchema(contract, RELEASE_CONTRACT_SCHEMA, 'release contract');
  requireSchema(deployTemplate, DEPLOY_TEMPLATE_SCHEMA, 'deploy template package');

  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const contractTemplate = requireObject(
    contract.deploy_template_package,
    'release_contract.deploy_template_package'
  );
  if (
    requireDigest(deployTemplate.package_sha256, 'deploy_template_package.package_sha256') !==
    requireDigest(contractTemplate.package_sha256, 'release_contract.deploy_template_package.package_sha256')
  ) {
    fail('deploy template package package_sha256 must match release contract');
  }
  if (
    requireDigest(deployTemplate.manifest_sha256, 'deploy_template_package.manifest_sha256') !==
    requireDigest(contractTemplate.manifest_sha256, 'release_contract.deploy_template_package.manifest_sha256')
  ) {
    fail('deploy template package manifest_sha256 must match release contract');
  }
  if (
    !sameArraySet(
      requireArray(deployTemplate.required_image_ids, 'deploy_template_package.required_image_ids'),
      requireArray(contractTemplate.required_image_ids, 'release_contract.deploy_template_package.required_image_ids')
    )
  ) {
    fail('deploy template package required_image_ids must match release contract');
  }

  return {
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: contractInput.digest,
    deploy_template_package_digest: deployTemplateInput.digest
  };
}

function requireCommonReleaseFields(report, release, label) {
  if (requireString(report.release_id, `${label}.release_id`) !== release.release_id) {
    fail(`${label}.release_id must match release contract`);
  }
  if (requireGitSha(report.git_sha, `${label}.git_sha`) !== release.git_sha) {
    fail(`${label}.git_sha must match release contract`);
  }
}

function requireReleaseContractDigest(report, release, label) {
  const container = requireObject(report.release_contract, `${label}.release_contract`);
  if (
    requireDigest(container.input_sha256, `${label}.release_contract.input_sha256`) !==
    release.release_contract_digest
  ) {
    fail(`${label}.release_contract.input_sha256 must match release contract input`);
  }
}

function requireReportReleaseContractDigest(report, release, label) {
  const digest = report.release_contract_digest ?? report.release_contract?.input_sha256;
  if (requireDigest(digest, `${label}.release_contract_digest`) !== release.release_contract_digest) {
    fail(`${label} release contract digest must match release contract input`);
  }
}

function requireReportDeployTemplateDigest(report, release, label) {
  const digest = report.deploy_template_package_digest ?? report.deploy_template_package?.input_sha256;
  if (requireDigest(digest, `${label}.deploy_template_package_digest`) !== release.deploy_template_package_digest) {
    fail(`${label} deploy template package digest must match input`);
  }
}

function requireReportSubstrateTruthDigest(report, label) {
  const digest = report.substrate_truth_digest ?? report.substrate_truth?.input_sha256;
  return requireDigest(digest, `${label}.substrate_truth_digest`);
}

function requireScope(report, expectedScope, label) {
  if (requireString(report.scope, `${label}.scope`) !== expectedScope) {
    fail(`${label}.scope must be ${expectedScope}`);
  }
}

function validateDigestArray(value, label) {
  const digests = requireNonEmptyArray(value, label);
  for (const [index, digest] of digests.entries()) {
    requireDigest(digest, `${label}[${index}]`);
  }
}

function validateExpectedImageDigestEntry(value, label) {
  const entry = requireObject(value, label);
  requireDigest(entry.digest, `${label}.digest`);
  requireNonEmptyStringArray(entry.inventory_ids, `${label}.inventory_ids`);
  requirePositiveInteger(entry.images_count, `${label}.images_count`);
}

function validateExpectedImageDigestEntries(value, label) {
  const entries = requireNonEmptyArray(value, label);
  for (const [index, entry] of entries.entries()) {
    validateExpectedImageDigestEntry(entry, `${label}[${index}]`);
  }
}

function validateRenderImageEntry(value, label) {
  const image = requireObject(value, label);
  requireString(image.image, `${label}.image`);
  requireDigest(image.digest, `${label}.digest`);
  requireString(image.inventory_id, `${label}.inventory_id`);
}

function validateRenderImageEntries(value, label) {
  const images = requireNonEmptyArray(value, label);
  for (const [index, image] of images.entries()) {
    validateRenderImageEntry(image, `${label}[${index}]`);
  }
}

function validateRenderManifestEntry(value, label) {
  const manifest = requireObject(value, label);
  requireString(manifest.path, `${label}.path`);
  requirePositiveInteger(manifest.document_index, `${label}.document_index`);
  requireString(manifest.kind, `${label}.kind`);
  requireDigest(manifest.sha256, `${label}.sha256`);
  validateRenderImageEntries(manifest.images, `${label}.images`);
}

function validateResourceRef(value, label, options = {}) {
  const ref = requireObject(value, label);
  requireString(ref.kind, `${label}.kind`);
  requireString(ref.name, `${label}.name`);
  requireString(ref.namespace, `${label}.namespace`);
  if (options.requireSelector) {
    requireString(ref.selector, `${label}.selector`);
  }
  if (Object.prototype.hasOwnProperty.call(ref, 'path')) {
    requireString(ref.path, `${label}.path`);
  }
  if (Object.prototype.hasOwnProperty.call(ref, 'document_index')) {
    requirePositiveInteger(ref.document_index, `${label}.document_index`);
  }
}

function validateResourceRefs(value, label, options = {}) {
  const refs = requireNonEmptyArray(value, label);
  for (const [index, ref] of refs.entries()) {
    validateResourceRef(ref, `${label}[${index}]`, options);
  }
}

function validateLiveDigestSummary(value, label) {
  const summary = requireObject(value, label);
  requirePositiveInteger(summary.observed_digest_count, `${label}.observed_digest_count`);
  validateDigestArray(summary.observed_digests, `${label}.observed_digests`);
  validateDigestArray(summary.matched_expected_digests, `${label}.matched_expected_digests`);
}

function stepMap(steps, label) {
  const byName = new Map();
  for (const [index, rawStep] of requireArray(steps, `${label}.steps`).entries()) {
    const step = requireObject(rawStep, `${label}.steps[${index}]`);
    const name = requireString(step.name, `${label}.steps[${index}].name`);
    if (byName.has(name)) {
      fail(`${label}.steps contains duplicate step: ${name}`);
    }
    requireStatusPass(step, `${label}.steps[${index}]`);
    byName.set(name, step);
  }
  return byName;
}

function safeRelativeReportPath(value, label) {
  const relative = requireString(value, label);
  if (relative.includes('\\') || path.isAbsolute(relative)) {
    fail(`${label} must be a portable relative path`);
  }
  const parts = relative.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not contain empty, current, or parent segments`);
  }
  return relative;
}

function reportPathForStep(step, label) {
  const paths = requireArray(step.report_paths, `${label}.report_paths`);
  if (paths.length !== 1) {
    fail(`${label}.report_paths must contain exactly one report`);
  }
  return safeRelativeReportPath(paths[0], `${label}.report_paths[0]`);
}

function validateSourceStepReport({
  report,
  sourceStep,
  release,
  expectedTargetProfile,
  airgapContext
}) {
  const expected = SOURCE_STEP_REPORTS.get(sourceStep);
  if (!expected) {
    fail(`unsupported source step report type: ${sourceStep}`);
  }
  const label = `${sourceStep} step report`;
  requireSchema(report, expected.schema, label);
  requireScope(report, expected.scope, label);
  requireReadinessFalse(report, label);
  requireStatusPass(report, label);
  requireNoFormalVerdict(report, label);
  requireCommonReleaseFields(report, release, label);
  requireTargetProfile(report.target_profile, expectedTargetProfile, `${label}.target_profile`);
  if (expected.mode && report.mode !== expected.mode) {
    fail(`${label}.mode must be ${expected.mode}`);
  }

  if (sourceStep === 'target-preflight') {
    requireReleaseContractDigest(report, release, label);
    validateTargetPreflightStepReport(report, expectedTargetProfile);
  }

  if (sourceStep === 'render-check') {
    requireReleaseContractDigest(report, release, label);
    validateRenderCheckStepReport(report);
  }
  if (sourceStep === 'apply') {
    requireReleaseContractDigest(report, release, label);
    validateApplyStepReport(report);
  }
  if (sourceStep === 'rollout') {
    requireReleaseContractDigest(report, release, label);
    validateRolloutStepReport(report);
  }
  if (sourceStep === 'smoke') {
    requireReleaseContractDigest(report, release, label);
    validateSmokeStepReport(report);
  }

  if (sourceStep === 'airgap-image-load') {
    validateAirgapImageLoadStepReport(report, release, airgapContext);
  }
  if (sourceStep === 'airgap-bundle-render-check') {
    validateAirgapBundleRenderCheckStepReport(report, release, airgapContext);
  }
}

function validateTargetPreflightStepReport(report, expectedTargetProfile) {
  const substrateTruth = requireObject(report.substrate_truth, 'target-preflight step report.substrate_truth');
  requireSchema(substrateTruth, SUBSTRATE_CONNECTION_SCHEMA, 'target-preflight step report.substrate_truth');
  requireDigest(
    substrateTruth.input_sha256,
    'target-preflight step report.substrate_truth.input_sha256'
  );
  requireTargetProfile(
    substrateTruth.target_profile,
    expectedTargetProfile,
    'target-preflight step report.substrate_truth.target_profile'
  );
  const servicesCount = requirePositiveInteger(
    substrateTruth.services_count,
    'target-preflight step report.substrate_truth.services_count'
  );
  const services = requireNonEmptyStringArray(
    substrateTruth.services,
    'target-preflight step report.substrate_truth.services'
  );
  if (services.length !== servicesCount) {
    fail('target-preflight step report.substrate_truth.services_count must match services length');
  }
  for (const [index, service] of services.entries()) {
    if (!SERVICE_NAME_RE.test(service)) {
      fail(`target-preflight step report.substrate_truth.services[${index}] must be a service name`);
    }
  }
  if (!sameArraySet(services, TARGET_PREFLIGHT_SUBSTRATE_SERVICES)) {
    fail('target-preflight step report.substrate_truth.services must match target-preflight producer service summary');
  }

  const prerequisites = requireObject(
    report.target_prerequisites,
    'target-preflight step report.target_prerequisites'
  );
  requireSchema(
    prerequisites,
    TARGET_PREREQUISITES_SCHEMA,
    'target-preflight step report.target_prerequisites'
  );
  requireDigest(
    prerequisites.input_sha256,
    'target-preflight step report.target_prerequisites.input_sha256'
  );
  requireTargetProfileString(
    prerequisites.target_profile,
    expectedTargetProfile,
    'target-preflight step report.target_prerequisites.target_profile'
  );
  requireString(prerequisites.namespace, 'target-preflight step report.target_prerequisites.namespace');
  requireString(
    prerequisites.ingress_host,
    'target-preflight step report.target_prerequisites.ingress_host'
  );
  requirePositiveInteger(
    prerequisites.substrate_secret_refs_count,
    'target-preflight step report.target_prerequisites.substrate_secret_refs_count'
  );

  const checks = requireObject(report.checks, 'target-preflight step report.checks');
  for (const key of [
    'schema',
    'target_axes',
    'service_contracts',
    'target_prerequisites',
    'secret_references',
    'tls_or_sslmode',
    'reachability'
  ]) {
    requireCheckPass(checks[key], `target-preflight step report.checks.${key}`);
  }
}

function validateRenderCheckStepReport(report) {
  const renderedManifests = requireObject(
    report.rendered_manifests,
    'render-check step report.rendered_manifests'
  );
  requireInteger(renderedManifests.files_count, 'render-check step report.rendered_manifests.files_count');
  requireInteger(
    renderedManifests.workload_count,
    'render-check step report.rendered_manifests.workload_count'
  );
  validateRenderImageEntries(report.images, 'render-check step report.images');
  const manifests = requireNonEmptyArray(report.manifests, 'render-check step report.manifests');
  for (const [index, manifest] of manifests.entries()) {
    validateRenderManifestEntry(manifest, `render-check step report.manifests[${index}]`);
  }
}

function validateApplyStepReport(report) {
  requireOperatorRunId(report.operator_run_id, 'apply step report.operator_run_id');
  validateResourceRefs(report.resource_refs, 'apply step report.resource_refs');
  requireNonEmptyStringArray(report.kubectl_resource_refs, 'apply step report.kubectl_resource_refs');
  validateRenderCheckSummary(report.render_check, 'apply step report.render_check');
}

function validateRolloutStepReport(report) {
  validateResourceRefs(
    report.rollout_resource_refs,
    'rollout step report.rollout_resource_refs',
    { requireSelector: true }
  );
  validateExpectedImageDigestEntries(
    report.expected_image_digests,
    'rollout step report.expected_image_digests'
  );
  validateLiveDigestSummary(
    report.observed_live_image_digest_summary,
    'rollout step report.observed_live_image_digest_summary'
  );
  const workloads = requireNonEmptyArray(report.workload_summaries, 'rollout step report.workload_summaries');
  for (const [index, workload] of workloads.entries()) {
    validateRolloutWorkloadSummary(workload, `rollout step report.workload_summaries[${index}]`);
  }
}

function validateRolloutWorkloadSummary(value, label) {
  const workload = requireObject(value, label);
  validateResourceRef(workload.resource_ref, `${label}.resource_ref`, {
    requireSelector: true
  });
  validateExpectedImageDigestEntries(workload.expected_image_digests, `${label}.expected_image_digests`);
  validateLiveDigestSummary(
    workload.observed_live_image_digest_summary,
    `${label}.observed_live_image_digest_summary`
  );
}

function validateRenderCheckSummary(value, label) {
  const summary = requireObject(value, label);
  requireSchema(summary, RENDER_CHECK_SCHEMA, label);
  requireScope(summary, 'render_check_image_inventory_only', label);
  requireStatusPass(summary, label);
  requirePositiveInteger(summary.images_count, `${label}.images_count`);
  requirePositiveInteger(summary.workload_count, `${label}.workload_count`);
}

function validateSmokeStepReport(report) {
  const route = requireObject(report.route, 'smoke step report.route');
  requireString(route.scheme, 'smoke step report.route.scheme');
  requireString(route.origin, 'smoke step report.route.origin');
  requireString(route.host, 'smoke step report.route.host');
  requireString(route.path, 'smoke step report.route.path');
  const expectedStatus = requireInteger(report.expected_status, 'smoke step report.expected_status');
  if (expectedStatus < 100 || expectedStatus > 599) {
    fail('smoke step report.expected_status must be an HTTP status code');
  }
  const statusCode = requireInteger(report.status_code, 'smoke step report.status_code');
  if (statusCode < 100 || statusCode > 599) {
    fail('smoke step report.status_code must be an HTTP status code');
  }
  requireInteger(report.duration_ms, 'smoke step report.duration_ms');
  const rolloutReport = requireObject(report.rollout_report, 'smoke step report.rollout_report');
  requireDigest(rolloutReport.input_sha256, 'smoke step report.rollout_report.input_sha256');
  requireSchema(rolloutReport, ROLLOUT_SCHEMA, 'smoke step report.rollout_report');
  requireScope(rolloutReport, 'kubernetes_rollout_imageid_only', 'smoke step report.rollout_report');
  requireStatusPass(rolloutReport, 'smoke step report.rollout_report');
}

function requireSourceInput(sourceInputsByStep, stepName) {
  const input = sourceInputsByStep.get(stepName);
  if (!input) {
    fail(`missing source input materiality for finalized step: ${stepName}`);
  }
  return input;
}

function validateInstallSubstrateTruthBinding(installSummary, sourceInputsByStep) {
  if (!installSummary) {
    return;
  }
  const targetPreflightInput = requireSourceInput(sourceInputsByStep, 'target-preflight');
  const targetPreflightReport = requireObject(
    targetPreflightInput.value,
    'target-preflight step report'
  );
  const substrateTruth = requireObject(
    targetPreflightReport.substrate_truth,
    'target-preflight step report.substrate_truth'
  );
  const targetPreflightSubstrateTruthDigest = requireDigest(
    substrateTruth.input_sha256,
    'target-preflight step report.substrate_truth.input_sha256'
  );
  if (installSummary.output_substrate_truth_digest !== targetPreflightSubstrateTruthDigest) {
    fail(
      'substrate_install_report.output_substrate_truth_digest must match target-preflight step report.substrate_truth.input_sha256'
    );
  }
}

function validateRouteSmokeRolloutBinding(sourceInputsByStep) {
  const rolloutInput = requireSourceInput(sourceInputsByStep, 'rollout');
  const smokeInput = requireSourceInput(sourceInputsByStep, 'route-smoke');
  const smokeReport = requireObject(smokeInput.value, 'smoke step report');
  const rolloutReport = requireObject(
    smokeReport.rollout_report,
    'smoke step report.rollout_report'
  );
  if (
    requireDigest(
      rolloutReport.input_sha256,
      'smoke step report.rollout_report.input_sha256'
    ) !== rolloutInput.digest
  ) {
    fail('smoke step report.rollout_report.input_sha256 must match rollout step report digest');
  }
}

function requireDigestSummary(report, label) {
  return requireObject(report.digest_summary, `${label}.digest_summary`);
}

function requireDigestSummaryMatch(summary, key, expectedDigest, label) {
  if (requireDigest(summary[key], `${label}.digest_summary.${key}`) !== expectedDigest) {
    fail(`${label}.digest_summary.${key} must match bound input`);
  }
}

function validateAirgapImageLoadStepReport(report, release, airgapContext) {
  if (!airgapContext) {
    fail('airgap image load validation requires airgap context');
  }
  const label = 'airgap-image-load step report';
  const summary = requireDigestSummary(report, label);
  requireDigestSummaryMatch(summary, 'release_contract_input_sha256', release.release_contract_digest, label);
  requireDigestSummaryMatch(
    summary,
    'deploy_template_package_input_sha256',
    release.deploy_template_package_digest,
    label
  );
  requireDigestSummaryMatch(summary, 'bundle_manifest_input_sha256', airgapContext.bundleManifestDigest, label);
  requireDigestSummaryMatch(
    summary,
    'airgap_bundle_check_report_input_sha256',
    airgapContext.bundleCheckDigest,
    label
  );
  requireDigestSummaryMatch(summary, 'image_map_input_sha256', airgapContext.imageMapInputSha256, label);
}

function validateAirgapBundleRenderCheckStepReport(report, release, airgapContext) {
  if (!airgapContext) {
    fail('airgap bundle render-check validation requires airgap context');
  }
  const label = 'airgap-bundle-render-check step report';
  const summary = requireDigestSummary(report, label);
  requireDigestSummaryMatch(summary, 'release_contract_input_sha256', release.release_contract_digest, label);
  requireDigestSummaryMatch(
    summary,
    'deploy_template_package_input_sha256',
    release.deploy_template_package_digest,
    label
  );
  requireDigestSummaryMatch(summary, 'bundle_manifest_input_sha256', airgapContext.bundleManifestDigest, label);
  requireDigestSummaryMatch(
    summary,
    'airgap_bundle_check_report_input_sha256',
    airgapContext.bundleCheckDigest,
    label
  );
  requireDigestSummaryMatch(summary, 'image_map_input_sha256', airgapContext.imageMapInputSha256, label);
  const loadImageMapDigest = airgapContext.imageLoadReport?.digest_summary?.image_map_input_sha256;
  if (loadImageMapDigest !== undefined) {
    const renderImageMapDigest = requireDigest(
      summary.image_map_input_sha256,
      `${label}.digest_summary.image_map_input_sha256`
    );
    if (
      renderImageMapDigest !==
      requireDigest(loadImageMapDigest, 'airgap-image-load step report.digest_summary.image_map_input_sha256')
    ) {
      fail('airgap image-load and bundle render-check image_map digests must match');
    }
  }
}

async function readStepReport({
  gateInput,
  gateReport,
  sourceStep,
  release,
  expectedTargetProfile,
  airgapContext
}) {
  const steps = stepMap(gateReport.steps, 'deployment gate report');
  const step = steps.get(sourceStep);
  if (!step) {
    fail(`deployment gate report missing required step: ${sourceStep}`);
  }
  const relative = reportPathForStep(step, `deployment gate report step ${sourceStep}`);
  const file = path.join(path.dirname(gateInput.file), relative);
  const stepInput = await readJson(file, `${sourceStep} step report`);
  const stepReport = requireObject(stepInput.value, `${sourceStep} step report`);
  validateSourceStepReport({
    report: stepReport,
    sourceStep,
    release,
    expectedTargetProfile,
    airgapContext
  });
  return {
    digest: stepInput.digest,
    input: stepInput,
    report: stepReport,
    source_step: sourceStep,
    source_schema: reportSchema(stepReport),
    source_scope: stepReport.scope
  };
}

function validateDeploymentGateReport({ report, source, release, expectedTargetProfile }) {
  const label = `${source} deployment gate report`;
  const expectedSchema = source === 'online' ? ONLINE_GATE_SCHEMA : AIRGAP_GATE_SCHEMA;
  const expectedScope = source === 'online' ? 'online_deployment_gate_only' : 'airgap_deployment_gate_only';
  requireSchema(report, expectedSchema, label);
  requireScope(report, expectedScope, label);
  requireReadinessFalse(report, label);
  requireNoFormalVerdict(report, label);
  requireStatusPass(report, label);
  requireCommonReleaseFields(report, release, label);
  requireReleaseContractDigest(report, release, label);
  if (report.mode !== 'apply') {
    fail(`${label}.mode must be apply for GA deployment path evidence`);
  }
  requireOperatorRunId(report.operator_run_id, `${label}.operator_run_id`);
  requireTargetProfile(report.target_profile, expectedTargetProfile, `${label}.target_profile`);
}

async function buildSourceSteps({ gateInput, gateReport, requirement, release, airgapContext }) {
  const steps = [];
  const sourceEvidenceSteps = [];
  const sourceInputsByStep = new Map();
  for (const [reportStep, sourceStep] of requirement.sourceSteps) {
    const sourceReport = await readStepReport({
      gateInput,
      gateReport,
      sourceStep,
      release,
      expectedTargetProfile: requirement.targetProfile,
      airgapContext
    });
    if (sourceStep === 'airgap-image-load' && airgapContext) {
      airgapContext.imageLoadReport = sourceReport.report;
    }
    steps.push({
      name: reportStep,
      status: 'pass',
      report_digest: sourceReport.digest
    });
    sourceEvidenceSteps.push({
      name: reportStep,
      source_step: sourceReport.source_step,
      source_schema: sourceReport.source_schema,
      source_scope: sourceReport.source_scope,
      report_digest: sourceReport.digest
    });
    sourceInputsByStep.set(reportStep, sourceReport.input);
  }
  return { steps, sourceEvidenceSteps, sourceInputsByStep };
}

function validateSubstrateInstallReport(report, release, expectedTargetProfile, operatorRunId) {
  requireSchema(report, SUBSTRATE_INSTALL_SCHEMA, 'substrate install report');
  requireScope(report, SUBSTRATE_INSTALL_SCOPE, 'substrate install report');
  requireReadinessFalse(report, 'substrate install report');
  requireNoFormalVerdict(report, 'substrate install report');
  requireStatusPass(report, 'substrate install report');
  requireCommonReleaseFields(report, release, 'substrate install report');
  const producer = requireString(report.producer ?? report.producer_id, 'substrate_install_report.producer');
  if (producer !== SUBSTRATE_INSTALL_PRODUCER) {
    fail(`substrate_install_report.producer must be ${SUBSTRATE_INSTALL_PRODUCER}`);
  }
  requireTargetProfile(report.target_profile, expectedTargetProfile, 'substrate_install_report.target_profile');
  if (requireOperatorRunId(report.operator_run_id, 'substrate_install_report.operator_run_id') !== operatorRunId) {
    fail('substrate install report operator_run_id must match --confirm-install-substrates');
  }
  requireReportReleaseContractDigest(report, release, 'substrate install report');
  requireReportDeployTemplateDigest(report, release, 'substrate install report');
  requireReportSubstrateTruthDigest(report, 'substrate install report');
  const installedServices = requireArray(report.installed_services, 'substrate_install_report.installed_services');
  if (installedServices.length === 0) {
    fail('substrate_install_report.installed_services must not be empty');
  }
  const seenServices = new Set();
  for (const [index, value] of installedServices.entries()) {
    const service = requireString(value, `substrate_install_report.installed_services[${index}]`);
    if (!SERVICE_NAME_RE.test(service)) {
      fail(`substrate_install_report.installed_services[${index}] must be a service name`);
    }
    if (seenServices.has(service)) {
      fail(`substrate_install_report.installed_services contains duplicate service: ${service}`);
    }
    seenServices.add(service);
  }
  requireDigest(
    report.output_substrate_truth_digest,
    'substrate_install_report.output_substrate_truth_digest'
  );
  return {
    schema: reportSchema(report),
    scope: report.scope,
    output_substrate_truth_digest: report.output_substrate_truth_digest,
    service_count: installedServices.length
  };
}

function validateAirgapBundleCheckReport(report, release, expectedTargetProfile, bundleManifestDigest) {
  requireSchema(report, AIRGAP_BUNDLE_CHECK_SCHEMA, 'airgap bundle check report');
  requireScope(report, AIRGAP_BUNDLE_CHECK_SCOPE, 'airgap bundle check report');
  requireReadinessFalse(report, 'airgap bundle check report');
  requireNoFormalVerdict(report, 'airgap bundle check report');
  requireStatusPass(report, 'airgap bundle check report');
  requireCommonReleaseFields(report, release, 'airgap bundle check report');
  requireTargetProfile(report.target_profile, expectedTargetProfile, 'airgap_bundle_check_report.target_profile');
  const artifacts = requireObject(report.artifacts, 'airgap_bundle_check_report.artifacts');
  const releaseContract = requireObject(
    artifacts.release_contract,
    'airgap_bundle_check_report.artifacts.release_contract'
  );
  if (
    requireDigest(
      releaseContract.input_sha256,
      'airgap_bundle_check_report.artifacts.release_contract.input_sha256'
    ) !== release.release_contract_digest
  ) {
    fail('airgap bundle check release contract digest must match release contract input');
  }
  const deployTemplatePackage = requireObject(
    artifacts.deploy_template_package,
    'airgap_bundle_check_report.artifacts.deploy_template_package'
  );
  if (
    requireDigest(
      deployTemplatePackage.input_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_package.input_sha256'
    ) !== release.deploy_template_package_digest
  ) {
    fail('airgap bundle check deploy template package digest must match input');
  }
  const imageMap = requireObject(
    artifacts.image_map,
    'airgap_bundle_check_report.artifacts.image_map'
  );
  const imageMapInputSha256 = requireDigest(
    imageMap.input_sha256,
    'airgap_bundle_check_report.artifacts.image_map.input_sha256'
  );
  const bundleManifest = requireObject(
    artifacts.bundle_manifest,
    'airgap_bundle_check_report.artifacts.bundle_manifest'
  );
  if (
    requireDigest(
      bundleManifest.input_sha256,
      'airgap_bundle_check_report.artifacts.bundle_manifest.input_sha256'
    ) !== bundleManifestDigest
  ) {
    fail('airgap bundle check bundle manifest digest must match input');
  }
  return { imageMapInputSha256 };
}

function validateAirgapBundleManifest(report, release, expectedTargetProfile) {
  requireSchema(report, AIRGAP_BUNDLE_MANIFEST_SCHEMA, 'airgap bundle manifest');
  requireCommonReleaseFields(report, release, 'airgap bundle manifest');
  requireTargetProfile(report.target_profile, expectedTargetProfile, 'airgap_bundle_manifest.target_profile');
}

function imageMapComponentFromBundleManifest(report) {
  const components = requireArray(report.components, 'airgap_bundle_manifest.components');
  let imageMapComponent;
  for (const [index, rawComponent] of components.entries()) {
    const component = requireObject(rawComponent, `airgap_bundle_manifest.components[${index}]`);
    const kind = requireString(component.kind, `airgap_bundle_manifest.components[${index}].kind`);
    if (kind !== 'image_map') {
      continue;
    }
    if (imageMapComponent) {
      fail('airgap_bundle_manifest.components must contain only one image_map component');
    }
    imageMapComponent = component;
  }
  if (!imageMapComponent) {
    fail('airgap_bundle_manifest.components must include image_map');
  }
  return imageMapComponent;
}

async function readAirgapImageMap({ bundleManifestInput, bundleManifestReport, expectedDigest, release, expectedTargetProfile }) {
  const component = imageMapComponentFromBundleManifest(bundleManifestReport);
  const relativePath = safeRelativeReportPath(
    component.path,
    'airgap_bundle_manifest.components.image_map.path'
  );
  const componentDigest = requireDigest(
    component.sha256,
    'airgap_bundle_manifest.components.image_map.sha256'
  );
  if (componentDigest !== expectedDigest) {
    fail('airgap bundle manifest image_map sha256 must match airgap bundle check report');
  }

  const imageMapInput = await readJson(
    path.join(path.dirname(bundleManifestInput.file), relativePath),
    'airgap image map'
  );
  if (imageMapInput.digest !== expectedDigest) {
    fail('airgap image map file sha256 must match airgap bundle check report');
  }

  const imageMap = requireObject(imageMapInput.value, 'airgap image map');
  requireSchema(imageMap, IMAGE_MAP_SCHEMA, 'airgap image map');
  requireScope(imageMap, IMAGE_MAP_SCOPE, 'airgap image map');
  requireReadinessFalse(imageMap, 'airgap image map');
  requireStatusPass(imageMap, 'airgap image map');
  requireCommonReleaseFields(imageMap, release, 'airgap image map');
  requireTargetProfile(imageMap.target_profile, expectedTargetProfile, 'airgap_image_map.target_profile');

  return imageMapInput;
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const tempFile = path.join(path.dirname(file), `.deployment-path-report.${process.pid}.tmp`);
  const buffer = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
  await fs.writeFile(tempFile, buffer);
  await fs.rename(tempFile, file);
  return digestBuffer(buffer);
}

async function resetSourceEvidenceDir(outputDir) {
  await fs.rm(path.join(outputDir, SOURCE_EVIDENCE_DIR), { recursive: true, force: true });
  await fs.mkdir(path.join(outputDir, SOURCE_EVIDENCE_DIR), { recursive: true });
}

function sourceEvidenceFilePath(name) {
  return `${SOURCE_EVIDENCE_DIR}/${name}`;
}

async function copySourceEvidenceFile({ outputDir, input, kind, step, fileName, schema, scope }) {
  const relativePath = sourceEvidenceFilePath(fileName);
  const outputFile = path.join(outputDir, relativePath);
  await fs.mkdir(path.dirname(outputFile), { recursive: true });
  await fs.writeFile(outputFile, input.buffer);
  const entry = {
    kind,
    path: relativePath,
    sha256: input.digest,
    schema,
    scope
  };
  if (step) {
    entry.step = step;
  }
  return entry;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const requirement = PATHS.get(args.operatorPath);
  const releaseContract = await readJson(args.releaseContract, 'release contract');
  const deployTemplatePackage = await readJson(args.deployTemplatePackage, 'deploy template package');
  const release = validateReleaseInputs(releaseContract, deployTemplatePackage);

  const gateInput = await readJson(
    requirement.source === 'online' ? args.onlineDeploymentGateReport : args.airgapDeploymentGateReport,
    `${requirement.source} deployment gate report`
  );
  const gateReport = requireObject(gateInput.value, `${requirement.source} deployment gate report`);
  validateDeploymentGateReport({
    report: gateReport,
    source: requirement.source,
    release,
    expectedTargetProfile: requirement.targetProfile
  });

  const steps = [];
  const sourceEvidenceSteps = [];
  const sourceInputsByStep = new Map();
  let bundleManifestDigest;
  let bundleCheckStep;
  let bundleCheckEvidenceStep;
  let bundleCheckInput;
  let bundleManifestInput;
  let imageMapInput;
  let airgapSourceEvidence;
  let airgapContext;
  if (requirement.source === 'airgap') {
    const bundleManifest = await readJson(args.airgapBundleManifest, 'airgap bundle manifest');
    bundleManifestInput = bundleManifest;
    bundleManifestDigest = bundleManifest.digest;
    validateAirgapBundleManifest(bundleManifest.value, release, requirement.targetProfile);
    const bundleCheck = await readJson(args.airgapBundleCheckReport, 'airgap bundle check report');
    bundleCheckInput = bundleCheck;
    const bundleCheckSummary = validateAirgapBundleCheckReport(
      bundleCheck.value,
      release,
      requirement.targetProfile,
      bundleManifestDigest
    );
    imageMapInput = await readAirgapImageMap({
      bundleManifestInput,
      bundleManifestReport: bundleManifest.value,
      expectedDigest: bundleCheckSummary.imageMapInputSha256,
      release,
      expectedTargetProfile: requirement.targetProfile
    });
    airgapContext = {
      bundleManifestDigest,
      bundleCheckDigest: bundleCheck.digest,
      imageMapInputSha256: bundleCheckSummary.imageMapInputSha256
    };
    bundleCheckStep = {
      name: 'bundle-check',
      status: 'pass',
      report_digest: bundleCheck.digest
    };
    bundleCheckEvidenceStep = {
      name: 'bundle-check',
      source_step: 'airgap-bundle-check',
      source_schema: AIRGAP_BUNDLE_CHECK_SCHEMA,
      source_scope: AIRGAP_BUNDLE_CHECK_SCOPE,
      report_digest: bundleCheck.digest
    };
    sourceInputsByStep.set('bundle-check', bundleCheckInput);
    airgapSourceEvidence = {
      bundle_manifest_digest: bundleManifestDigest,
      bundle_check_report_digest: bundleCheck.digest,
      image_map_input_sha256: bundleCheckSummary.imageMapInputSha256
    };
  }

  let installStep;
  let installEvidenceStep;
  let installInput;
  let installSummary;
  let substrateInstallEvidence;
  if (requirement.installSubstrates) {
    installInput = await readJson(args.substrateInstallReport, 'substrate install report');
    installSummary = validateSubstrateInstallReport(
      installInput.value,
      release,
      requirement.targetProfile,
      args.confirmInstallSubstrates
    );
    installStep = {
      name: 'substrate-install',
      status: 'pass',
      report_digest: installInput.digest
    };
    installEvidenceStep = {
      name: 'substrate-install',
      source_step: 'substrate-install',
      source_schema: installSummary.schema,
      source_scope: installSummary.scope,
      report_digest: installInput.digest
    };
    sourceInputsByStep.set('substrate-install', installInput);
    substrateInstallEvidence = {
      report_digest: installInput.digest,
      schema: installSummary.schema,
      scope: installSummary.scope,
      output_substrate_truth_digest: installSummary.output_substrate_truth_digest,
      service_count: installSummary.service_count
    };
  }

  const sourceStepResult = await buildSourceSteps({
    gateInput,
    gateReport,
    requirement,
    release,
    airgapContext
  });
  const sourceSteps = sourceStepResult.steps;
  const sourceStepEvidence = sourceStepResult.sourceEvidenceSteps;
  for (const [stepName, input] of sourceStepResult.sourceInputsByStep) {
    sourceInputsByStep.set(stepName, input);
  }
  validateInstallSubstrateTruthBinding(installSummary, sourceInputsByStep);
  validateRouteSmokeRolloutBinding(sourceInputsByStep);
  if (installStep && requirement.source === 'airgap') {
    steps.push(sourceSteps[0], bundleCheckStep, sourceSteps[1], installStep, ...sourceSteps.slice(2));
    sourceEvidenceSteps.push(
      sourceStepEvidence[0],
      bundleCheckEvidenceStep,
      sourceStepEvidence[1],
      installEvidenceStep,
      ...sourceStepEvidence.slice(2)
    );
  } else if (requirement.source === 'airgap') {
    steps.push(sourceSteps[0], bundleCheckStep, ...sourceSteps.slice(1));
    sourceEvidenceSteps.push(sourceStepEvidence[0], bundleCheckEvidenceStep, ...sourceStepEvidence.slice(1));
  } else {
    if (installStep) {
      steps.push(installStep);
      sourceEvidenceSteps.push(installEvidenceStep);
    }
    steps.push(...sourceSteps);
    sourceEvidenceSteps.push(...sourceStepEvidence);
  }

  const report = {
    schema: REPORT_SCHEMA,
    scope: 'deployment_path_ga_evidence',
    readiness: false,
    status: 'pass',
    release_id: release.release_id,
    git_sha: release.git_sha,
    release_contract_digest: release.release_contract_digest,
    deploy_template_package_digest: release.deploy_template_package_digest,
    operator_path: args.operatorPath,
    target_profile: parseTargetProfile(requirement.targetProfile, 'target_profile'),
    steps,
    source_evidence: {
      schema: SOURCE_EVIDENCE_SCHEMA,
      operator_path: args.operatorPath,
      target_profile: parseTargetProfile(requirement.targetProfile, 'source_evidence.target_profile'),
      finalizer: {
        schema: FINALIZER_SCHEMA,
        tool: 'verify-deployment-path-report.mjs',
        mode: 'deployment_path_source_evidence_finalization'
      },
      source_deployment_gate_report: {
        schema: reportSchema(gateReport),
        scope: gateReport.scope,
        digest: gateInput.digest
      },
      finalized_steps: sourceEvidenceSteps
    }
  };

  if (airgapSourceEvidence) {
    report.source_evidence.airgap = airgapSourceEvidence;
  }

  if (substrateInstallEvidence) {
    report.source_evidence.substrate_install = substrateInstallEvidence;
  }

  if (requirement.installSubstrates) {
    const substrateInstallDigest = steps.find((step) => step.name === 'substrate-install').report_digest;
    report.install_substrates_confirmation = {
      confirmed: true,
      operator_run_id: args.confirmInstallSubstrates,
      substrate_install_report_digest: substrateInstallDigest
    };
  }

  if (requirement.source === 'airgap') {
    const imageLoadDigest = steps.find((step) => step.name === 'image-load').report_digest;
    const offlineRenderDigest = steps.find((step) => step.name === 'offline-render-check').report_digest;
    report.airgap_offline = {
      public_internet_downloads: false,
      bundle_manifest_digest: bundleManifestDigest,
      image_load_report_digest: imageLoadDigest,
      offline_render_report_digest: offlineRenderDigest
    };
  }

  const outputDir = path.resolve(args.outputDir);
  await resetSourceEvidenceDir(outputDir);
  const sourceEvidenceFiles = [
    await copySourceEvidenceFile({
      outputDir,
      input: gateInput,
      kind: 'source_deployment_gate',
      fileName: 'deployment-gate-report.json',
      schema: reportSchema(gateReport),
      scope: gateReport.scope
    })
  ];

  for (const step of sourceEvidenceSteps) {
    const input = sourceInputsByStep.get(step.name);
    if (!input) {
      fail(`missing source input materiality for finalized step: ${step.name}`);
    }
    sourceEvidenceFiles.push(
      await copySourceEvidenceFile({
        outputDir,
        input,
        kind: 'finalized_step_report',
        step: step.name,
        fileName: `${step.name}-report.json`,
        schema: step.source_schema,
        scope: step.source_scope
      })
    );
  }

  if (requirement.source === 'airgap') {
    sourceEvidenceFiles.push(
      await copySourceEvidenceFile({
        outputDir,
        input: bundleManifestInput,
        kind: 'airgap_bundle_manifest',
        fileName: 'airgap-bundle-manifest.json',
        schema: AIRGAP_BUNDLE_MANIFEST_SCHEMA,
        scope: null
      })
    );
    sourceEvidenceFiles.push(
      await copySourceEvidenceFile({
        outputDir,
        input: imageMapInput,
        kind: 'airgap_image_map',
        fileName: 'image-map.json',
        schema: IMAGE_MAP_SCHEMA,
        scope: IMAGE_MAP_SCOPE
      })
    );
  }

  const pathReportSha256 = await writeJson(path.join(outputDir, REPORT_FILE), report);
  await writeJson(path.join(outputDir, MANIFEST_FILE), {
    schema: MANIFEST_SCHEMA,
    tool: FINALIZER_MANIFEST_TOOL,
    operator_path: args.operatorPath,
    deployment_profile: requirement.targetProfile,
    release_contract_digest: release.release_contract_digest,
    template_digest: release.deploy_template_package_digest,
    path_report_sha256: pathReportSha256,
    source_evidence_files: sourceEvidenceFiles,
    created_at: new Date().toISOString()
  });
  console.log(`PASS: wrote ${REPORT_FILE} and ${MANIFEST_FILE}`);
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
