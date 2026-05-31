#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import * as sourceValidation from './lib/deployment-path-source-validation.mjs';
import { scanReportForForbiddenContent } from './lib/report-forbidden-scan.mjs';

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
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const PATHS = sourceValidation.DEPLOYMENT_PATHS;
const AIRGAP_BUNDLE_CHECK_SCHEMA = sourceValidation.AIRGAP_BUNDLE_CHECK_SCHEMA;
const AIRGAP_BUNDLE_CHECK_SCOPE = sourceValidation.AIRGAP_BUNDLE_CHECK_SCOPE;
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = sourceValidation.AIRGAP_BUNDLE_MANIFEST_SCHEMA;
const IMAGE_MAP_SCHEMA = sourceValidation.IMAGE_MAP_SCHEMA;
const IMAGE_MAP_SCOPE = sourceValidation.IMAGE_MAP_SCOPE;

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

function validateDeployImageInventory(value) {
  const entries = requireNonEmptyArray(value, 'release_contract.deploy_image_inventory');
  const seenIds = new Set();
  return entries.map((entry, index) => {
    const image = requireObject(entry, `release_contract.deploy_image_inventory[${index}]`);
    const id = requireString(image.id, `release_contract.deploy_image_inventory[${index}].id`);
    if (seenIds.has(id)) {
      fail(`release_contract.deploy_image_inventory contains duplicate image id: ${id}`);
    }
    seenIds.add(id);
    return {
      id,
      source: typeof image.source === 'string' && image.source.trim() !== '' ? image.source : undefined,
      image: requireString(image.image, `release_contract.deploy_image_inventory[${index}].image`),
      digest: requireDigest(image.digest, `release_contract.deploy_image_inventory[${index}].digest`)
    };
  });
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
  const deployTemplateRequiredImageIds = requireNonEmptyStringArray(
    deployTemplate.required_image_ids,
    'deploy_template_package.required_image_ids'
  );
  const contractRequiredImageIds = requireNonEmptyStringArray(
    contractTemplate.required_image_ids,
    'release_contract.deploy_template_package.required_image_ids'
  );
  const deployImageInventory = validateDeployImageInventory(contract.deploy_image_inventory);
  const contractInventoryImageIds = deployImageInventory.map((entry) => entry.id);
  if (!sameArraySet(contractRequiredImageIds, contractInventoryImageIds)) {
    fail('release_contract.deploy_template_package.required_image_ids must exactly match release_contract.deploy_image_inventory ids');
  }
  if (!sameArraySet(deployTemplateRequiredImageIds, contractRequiredImageIds)) {
    fail('deploy template package required_image_ids must match release contract');
  }

  return {
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: contractInput.digest,
    deploy_template_package_digest: deployTemplateInput.digest,
    deploy_image_inventory: deployImageInventory
  };
}

async function readStepReport({
  gateInput,
  gateReport,
  sourceStep,
  release,
  expectedTargetProfile,
  airgapContext
}) {
  const steps = sourceValidation.stepMap(gateReport.steps, 'deployment gate report');
  const step = steps.get(sourceStep);
  if (!step) {
    fail(`deployment gate report missing required step: ${sourceStep}`);
  }
  const relative = sourceValidation.reportPathForStep(step, `deployment gate report step ${sourceStep}`);
  const file = path.join(path.dirname(gateInput.file), relative);
  const stepInput = await readJson(file, `${sourceStep} step report`);
  const stepReport = requireObject(stepInput.value, `${sourceStep} step report`);
  sourceValidation.validateSourceStepReport({
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
    source_schema: sourceValidation.reportSchema(stepReport),
    source_scope: stepReport.scope
  };
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

async function readAirgapImageMap({ bundleManifestInput, bundleManifestReport, expectedDigest, release, expectedTargetProfile }) {
  const relativePath = sourceValidation.airgapImageMapPathFromBundleManifest(bundleManifestReport);

  const imageMapInput = await readJson(
    path.join(path.dirname(bundleManifestInput.file), relativePath),
    'airgap image map'
  );
  sourceValidation.validateAirgapImageMapEvidence({
    bundleManifestReport,
    imageMapReport: imageMapInput.value,
    imageMapDigest: imageMapInput.digest,
    expectedDigest,
    release,
    expectedTargetProfile
  });

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

async function cleanupKnownOutputs(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, MANIFEST_FILE), { force: true });
  await fs.rm(path.join(outputDir, SOURCE_EVIDENCE_DIR), { recursive: true, force: true });
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

function scanSourceEvidenceFile({ input, kind, step, fileName }) {
  scanReportForForbiddenContent({
    value: input.value,
    buffer: input.buffer,
    label: `source evidence material ${kind}${step ? ` ${step}` : ''} (${sourceEvidenceFilePath(fileName)})`
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }
  const outputDir = path.resolve(args.outputDir);
  await cleanupKnownOutputs(outputDir);

  const requirement = PATHS.get(args.operatorPath);
  const releaseContract = await readJson(args.releaseContract, 'release contract');
  const deployTemplatePackage = await readJson(args.deployTemplatePackage, 'deploy template package');
  const release = validateReleaseInputs(releaseContract, deployTemplatePackage);

  const gateInput = await readJson(
    requirement.source === 'online' ? args.onlineDeploymentGateReport : args.airgapDeploymentGateReport,
    `${requirement.source} deployment gate report`
  );
  const gateReport = requireObject(gateInput.value, `${requirement.source} deployment gate report`);
  sourceValidation.validateDeploymentGateReport({
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
    sourceValidation.validateAirgapBundleManifest(bundleManifest.value, release, requirement.targetProfile);
    const bundleCheck = await readJson(args.airgapBundleCheckReport, 'airgap bundle check report');
    bundleCheckInput = bundleCheck;
    const bundleCheckSummary = sourceValidation.validateAirgapBundleCheckReport(
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
    installSummary = sourceValidation.validateSubstrateInstallReport(
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
  sourceValidation.validateInstallSubstrateTruthBinding(installSummary, sourceInputsByStep);
  sourceValidation.validateRouteSmokeRolloutBinding(sourceInputsByStep);
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

  const sourceEvidenceItems = [
    {
      outputDir,
      input: gateInput,
      kind: 'source_deployment_gate',
      fileName: 'deployment-gate-report.json',
      schema: reportSchema(gateReport),
      scope: gateReport.scope
    }
  ];

  for (const step of sourceEvidenceSteps) {
    const input = sourceInputsByStep.get(step.name);
    if (!input) {
      fail(`missing source input materiality for finalized step: ${step.name}`);
    }
    sourceEvidenceItems.push({
      outputDir,
      input,
      kind: 'finalized_step_report',
      step: step.name,
      fileName: `${step.name}-report.json`,
      schema: step.source_schema,
      scope: step.source_scope
    });
  }

  if (requirement.source === 'airgap') {
    sourceEvidenceItems.push({
      outputDir,
      input: bundleManifestInput,
      kind: 'airgap_bundle_manifest',
      fileName: 'airgap-bundle-manifest.json',
      schema: AIRGAP_BUNDLE_MANIFEST_SCHEMA,
      scope: null
    });
    sourceEvidenceItems.push({
      outputDir,
      input: imageMapInput,
      kind: 'airgap_image_map',
      fileName: 'image-map.json',
      schema: IMAGE_MAP_SCHEMA,
      scope: IMAGE_MAP_SCOPE
    });
  }

  for (const item of sourceEvidenceItems) {
    scanSourceEvidenceFile(item);
  }

  await resetSourceEvidenceDir(outputDir);
  const sourceEvidenceFiles = [];
  for (const item of sourceEvidenceItems) {
    sourceEvidenceFiles.push(await copySourceEvidenceFile(item));
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
