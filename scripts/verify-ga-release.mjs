#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import * as sourceValidation from './lib/deployment-path-source-validation.mjs';
import { scanReportForForbiddenContent } from './lib/report-forbidden-scan.mjs';

const REPORT_FILE = 'ga-release-report.json';
const SUMMARY_FILE = 'ga-release-summary.md';
const FINALIZER_MANIFEST_FILE = 'deployment-path-finalizer-manifest.json';
const SOURCE_EVIDENCE_DIR = 'source-evidence';
const REPORT_SCHEMA = 'agentsmith.ga-release-report/v1';
const PATH_REPORT_SCHEMA = 'agentsmith.deployment-path-report/v1';
const PATH_REPORT_SCOPE = 'deployment_path_ga_evidence';
const FINALIZER_MANIFEST_SCHEMA = 'agentsmith.deployment-path-finalizer-manifest/v1';
const SOURCE_EVIDENCE_SCHEMA = 'agentsmith.deployment-path-source-evidence/v1';
const FINALIZER_SCHEMA = 'agentsmith.deployment-path-report-finalizer/v1';
const FINALIZER_TOOL = 'verify-deployment-path-report.mjs';
const FINALIZER_MANIFEST_TOOL = 'verify-deployment-path-report';
const FINALIZER_MODE = 'deployment_path_source_evidence_finalization';
const PRODUCT_READY_SCHEMA = 'agentsmith.product-readiness-report/v1';
const PRODUCT_SMOKE_SCHEMA = 'agentsmith.post-deploy-product-smoke/v1';
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = sourceValidation.AIRGAP_BUNDLE_MANIFEST_SCHEMA;
const IMAGE_MAP_SCHEMA = sourceValidation.IMAGE_MAP_SCHEMA;
const IMAGE_MAP_SCOPE = sourceValidation.IMAGE_MAP_SCOPE;
const SUBSTRATE_INSTALL_SCHEMA = sourceValidation.SUBSTRATE_INSTALL_SCHEMA;
const SUBSTRATE_INSTALL_SCOPE = sourceValidation.SUBSTRATE_INSTALL_SCOPE;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const AGENTSMITH_REPO = 'github.com/agentsmith-project/agentsmith';

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'productReadinessReport',
  'postDeployProductSmokeReport',
  'outputDir'
];

const DEPLOYMENT_PATHS = sourceValidation.DEPLOYMENT_PATHS;

const SOURCE_STEP_REPORTS = sourceValidation.FINALIZED_STEP_SOURCE_REPORTS;
const DEPLOYMENT_GATE_BY_SOURCE = sourceValidation.DEPLOYMENT_GATE_BY_SOURCE;

const REQUIRED_PRODUCT_SMOKE_FLOWS = [
  'auth_profile',
  'workspace_project',
  'files',
  'managed_runner_agent_task',
  'provider_neutral_endpoint',
  'audit_usage_readback'
];

const REQUIRED_IMAGE_IDS = ['agentsmith_app', 'managed_runner', 'llmup', 'afscp', 'asbcp'];
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
  node scripts/verify-ga-release.mjs \\
    --release-contract <agentsmith-release-contract.json> \\
    --deploy-template-package <agentsmith-deploy-template-package.json> \\
    --deployment-path-report <online/use_existing/deployment-path-report.json> \\
    --deployment-path-report <online/install_substrates/deployment-path-report.json> \\
    --deployment-path-report <airgap/use_existing/deployment-path-report.json> \\
    --deployment-path-report <airgap/install_substrates/deployment-path-report.json> \\
    --product-readiness-report <agentsmith/product-readiness-report.json> \\
    --post-deploy-product-smoke-report <agentsmith/post-deploy-product-smoke-report.json> \\
    --output-dir <dir>

This is the release-kit final GA aggregate. It consumes finalized path reports
and product-side reports only; it does not rerun producers.`;
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
  const parsed = { deploymentPathReports: [] };

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
      case '--deployment-path-report':
        parsed.deploymentPathReports.push(nextValue());
        break;
      case '--product-readiness-report':
        parsed.productReadinessReport = nextValue();
        break;
      case '--post-deploy-product-smoke-report':
        parsed.postDeployProductSmokeReport = nextValue();
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
  if (parsed.deploymentPathReports.length !== DEPLOYMENT_PATHS.size) {
    cliFail(`expected exactly ${DEPLOYMENT_PATHS.size} --deployment-path-report inputs`);
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

function optionalString(value, label) {
  if (value === undefined) {
    return undefined;
  }
  return requireString(value, label);
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

function requireStatusPass(report, label) {
  if (report.status !== 'pass') {
    fail(`${label} status must be pass`);
  }
}

function requireSchema(report, schema, label) {
  if (report.schema !== schema && report.schema_version !== schema) {
    fail(`${label} schema must be ${schema}`);
  }
}

function reportSchema(report) {
  return report.schema ?? report.schema_version;
}

function requireNoFormalVerdict(report, label) {
  if (Object.prototype.hasOwnProperty.call(report, 'formal_verdict')) {
    fail(`${label} must not issue formal_verdict`);
  }
}

function requireProvenance(provenance, label) {
  const value = requireObject(provenance, label);
  const normalizedRemote = requireString(value.normalized_remote ?? value.producer_repo, `${label}.normalized_remote`);
  const commitSha = requireGitSha(value.commit_sha, `${label}.commit_sha`);
  const runId = requireString(value.run_id, `${label}.run_id`);
  const runAttempt = requireString(value.run_attempt, `${label}.run_attempt`);
  const subjectSha = optionalString(value.subject_sha256, `${label}.subject_sha256`);
  const artifactSha = optionalString(value.artifact_sha256, `${label}.artifact_sha256`);
  if (subjectSha !== undefined) {
    requireDigest(subjectSha, `${label}.subject_sha256`);
  }
  if (artifactSha !== undefined) {
    requireDigest(artifactSha, `${label}.artifact_sha256`);
  }
  return {
    producer_repo: requireString(value.producer_repo ?? normalizedRemote, `${label}.producer_repo`),
    normalized_remote: normalizedRemote,
    commit_sha: commitSha,
    run_id: runId,
    run_attempt: runAttempt,
    subject_name: optionalString(value.subject_name, `${label}.subject_name`),
    subject_sha256: subjectSha,
    artifact_sha256: artifactSha
  };
}

function requireTargetProfile(profile, expected, label) {
  const value = requireObject(profile, label);
  const tuple = requireString(value.value, `${label}.value`);
  if (tuple !== expected) {
    fail(`${label}.value must be ${expected}`);
  }
  const [targetCluster, substrateSource, distribution] = tuple.split('/');
  if (
    value.target_cluster !== targetCluster ||
    value.substrate_source !== substrateSource ||
    value.distribution !== distribution
  ) {
    fail(`${label} fields must match ${expected}`);
  }
  return value;
}

function reportStepsByName(report, label) {
  const steps = requireArray(report.steps, `${label}.steps`);
  const byName = new Map();
  for (const step of steps) {
    const value = requireObject(step, `${label}.steps[]`);
    const name = requireString(value.name, `${label}.steps[].name`);
    if (byName.has(name)) {
      fail(`${label} has duplicate step: ${name}`);
    }
    requireStatusPass(value, `${label} step ${name}`);
    requireDigest(value.report_digest, `${label} step ${name} report_digest`);
    byName.set(name, value);
  }
  return byName;
}

function validateImageRef(entry, label) {
  const value = requireObject(entry, label);
  const id = requireString(value.id, `${label}.id`);
  const image = requireString(value.image, `${label}.image`);
  const digest = requireDigest(value.digest, `${label}.digest`);
  if (!image.includes(`@${digest}`)) {
    fail(`${label}.image must include its digest`);
  }
  return { id, image, digest };
}

function validateReleaseContract(contract, contractDigest) {
  requireSchema(contract, RELEASE_CONTRACT_SCHEMA, 'release contract');
  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const provenance = requireProvenance(contract.artifact_provenance, 'release_contract.artifact_provenance');
  if (provenance.normalized_remote !== AGENTSMITH_REPO || provenance.commit_sha !== gitSha) {
    fail('release contract provenance must match AgentSmith repo and git sha');
  }

  const inventory = requireArray(contract.deploy_image_inventory, 'release_contract.deploy_image_inventory')
    .map((entry, index) => validateImageRef(entry, `release_contract.deploy_image_inventory[${index}]`));
  const byId = new Map(inventory.map((entry) => [entry.id, entry]));
  for (const id of REQUIRED_IMAGE_IDS) {
    if (!byId.has(id)) {
      fail(`release contract deploy_image_inventory missing required image id: ${id}`);
    }
  }
  if (byId.size !== inventory.length) {
    fail('release contract deploy_image_inventory must not contain duplicate image ids');
  }
  validateImageRef(contract.managed_runner_image, 'release_contract.managed_runner_image');

  return {
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: contractDigest,
    provenance,
    images: {
      app: byId.get('agentsmith_app'),
      runner: byId.get('managed_runner'),
      dependencies: ['llmup', 'afscp', 'asbcp'].map((id) => byId.get(id)),
      inventory
    }
  };
}

function validateDeployTemplatePackage(descriptor, contract, descriptorDigest) {
  requireSchema(descriptor, DEPLOY_TEMPLATE_SCHEMA, 'deploy template package');
  requireDigest(descriptor.package_sha256, 'deploy_template_package.package_sha256');
  requireDigest(descriptor.manifest_sha256, 'deploy_template_package.manifest_sha256');
  const provenance = requireProvenance(descriptor.artifact_provenance, 'deploy_template_package.artifact_provenance');
  const contractDescriptor = requireObject(contract.deploy_template_package, 'release_contract.deploy_template_package');
  if (descriptor.package_sha256 !== contractDescriptor.package_sha256) {
    fail('deploy template package package_sha256 must match release contract');
  }
  if (descriptor.manifest_sha256 !== contractDescriptor.manifest_sha256) {
    fail('deploy template package manifest_sha256 must match release contract');
  }
  const requiredIds = new Set(requireArray(descriptor.required_image_ids, 'deploy_template_package.required_image_ids'));
  const inventoryIds = new Set(requireArray(contract.deploy_image_inventory, 'release_contract.deploy_image_inventory').map((entry) => entry.id));
  if (requiredIds.size !== inventoryIds.size || [...requiredIds].some((id) => !inventoryIds.has(id))) {
    fail('deploy template package required_image_ids must exactly match release contract deploy_image_inventory ids');
  }
  return {
    deploy_template_package_digest: descriptorDigest,
    package_sha256: descriptor.package_sha256,
    manifest_sha256: descriptor.manifest_sha256,
    provenance
  };
}

function commonReportChecks(report, label, release) {
  requireStatusPass(report, label);
  if (requireString(report.release_id, `${label}.release_id`) !== release.release_id) {
    fail(`${label}.release_id must match release contract`);
  }
  if (requireGitSha(report.git_sha, `${label}.git_sha`) !== release.git_sha) {
    fail(`${label}.git_sha must match release contract`);
  }
  if (requireDigest(report.release_contract_digest, `${label}.release_contract_digest`) !== release.release_contract_digest) {
    fail(`${label}.release_contract_digest must match release contract digest`);
  }
}

function validateProductReadiness(report, reportDigest, release) {
  requireSchema(report, PRODUCT_READY_SCHEMA, 'product readiness report');
  commonReportChecks(report, 'product readiness report', release);
  const provenance = requireProvenance(report.artifact_provenance, 'product_readiness_report.artifact_provenance');
  if (provenance.normalized_remote !== AGENTSMITH_REPO || provenance.commit_sha !== release.git_sha) {
    fail('product readiness provenance must match AgentSmith repo and git sha');
  }
  return { report_digest: reportDigest, provenance };
}

function validateProductSmoke(report, reportDigest, release) {
  requireSchema(report, PRODUCT_SMOKE_SCHEMA, 'post-deploy product smoke report');
  commonReportChecks(report, 'post-deploy product smoke report', release);
  const flows = new Set(requireArray(report.covered_flows, 'post_deploy_product_smoke.covered_flows'));
  for (const flow of REQUIRED_PRODUCT_SMOKE_FLOWS) {
    if (!flows.has(flow)) {
      fail(`post-deploy product smoke missing required flow: ${flow}`);
    }
  }
  return { report_digest: reportDigest, covered_flows: [...flows].sort() };
}

function requireEquals(actual, expected, label) {
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
}

function validateSourceEvidenceLedger(report, requirement, requiredSteps, steps, operatorPath) {
  const ledger = requireObject(report.source_evidence, 'deployment_path_report.source_evidence');
  requireSchema(ledger, SOURCE_EVIDENCE_SCHEMA, 'deployment_path_report.source_evidence');
  requireEquals(
    requireString(ledger.operator_path, 'deployment_path_report.source_evidence.operator_path'),
    operatorPath,
    'deployment_path_report.source_evidence.operator_path'
  );
  requireTargetProfile(
    ledger.target_profile,
    requirement.targetProfile,
    'deployment_path_report.source_evidence.target_profile'
  );

  const finalizer = requireObject(
    ledger.finalizer,
    'deployment_path_report.source_evidence.finalizer'
  );
  requireEquals(
    requireString(finalizer.schema, 'deployment_path_report.source_evidence.finalizer.schema'),
    FINALIZER_SCHEMA,
    'deployment_path_report.source_evidence.finalizer.schema'
  );
  requireEquals(
    requireString(finalizer.tool, 'deployment_path_report.source_evidence.finalizer.tool'),
    FINALIZER_TOOL,
    'deployment_path_report.source_evidence.finalizer.tool'
  );
  requireEquals(
    requireString(finalizer.mode, 'deployment_path_report.source_evidence.finalizer.mode'),
    FINALIZER_MODE,
    'deployment_path_report.source_evidence.finalizer.mode'
  );

  const expectedGate = DEPLOYMENT_GATE_BY_SOURCE.get(requirement.source);
  const gate = requireObject(
    ledger.source_deployment_gate_report,
    'deployment_path_report.source_evidence.source_deployment_gate_report'
  );
  requireEquals(
    requireString(gate.schema, 'deployment_path_report.source_evidence.source_deployment_gate_report.schema'),
    expectedGate.schema,
    'deployment_path_report.source_evidence.source_deployment_gate_report.schema'
  );
  requireEquals(
    requireString(gate.scope, 'deployment_path_report.source_evidence.source_deployment_gate_report.scope'),
    expectedGate.scope,
    'deployment_path_report.source_evidence.source_deployment_gate_report.scope'
  );
  requireDigest(gate.digest, 'deployment_path_report.source_evidence.source_deployment_gate_report.digest');

  const ledgerSteps = requireArray(
    ledger.finalized_steps,
    'deployment_path_report.source_evidence.finalized_steps'
  );
  if (ledgerSteps.length !== steps.size) {
    fail('deployment_path_report.source_evidence.finalized_steps must match steps[] length');
  }
  const ledgerStepsByName = new Map();
  for (const [index, rawStep] of ledgerSteps.entries()) {
    const step = requireObject(
      rawStep,
      `deployment_path_report.source_evidence.finalized_steps[${index}]`
    );
    const name = requireString(
      step.name,
      `deployment_path_report.source_evidence.finalized_steps[${index}].name`
    );
    if (ledgerStepsByName.has(name)) {
      fail(`deployment_path_report.source_evidence.finalized_steps contains duplicate step: ${name}`);
    }
    ledgerStepsByName.set(name, step);
  }

  for (const stepName of requiredSteps) {
    const reportStep = steps.get(stepName);
    const ledgerStep = ledgerStepsByName.get(stepName);
    if (!ledgerStep) {
      fail(`deployment_path_report.source_evidence missing finalized step: ${stepName}`);
    }
    const expected = SOURCE_STEP_REPORTS.get(stepName);
    requireEquals(
      requireString(ledgerStep.source_step, `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_step`),
      expected.source_step,
      `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_step`
    );
    requireEquals(
      requireString(ledgerStep.source_schema, `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_schema`),
      expected.source_schema,
      `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_schema`
    );
    requireEquals(
      requireString(ledgerStep.source_scope, `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_scope`),
      expected.source_scope,
      `deployment_path_report.source_evidence.finalized_steps.${stepName}.source_scope`
    );
    if (
      requireDigest(
        ledgerStep.report_digest,
        `deployment_path_report.source_evidence.finalized_steps.${stepName}.report_digest`
      ) !== reportStep.report_digest
    ) {
      fail(`deployment_path_report.source_evidence.finalized_steps ${stepName} report_digest must match steps[]`);
    }
  }

  if (requirement.source === 'airgap') {
    const offline = requireObject(report.airgap_offline, 'deployment_path_report.airgap_offline');
    const airgap = requireObject(ledger.airgap, 'deployment_path_report.source_evidence.airgap');
    if (
      requireDigest(
        airgap.bundle_manifest_digest,
        'deployment_path_report.source_evidence.airgap.bundle_manifest_digest'
      ) !== offline.bundle_manifest_digest
    ) {
      fail('deployment_path_report.source_evidence.airgap.bundle_manifest_digest must match airgap_offline');
    }
    if (
      requireDigest(
        airgap.bundle_check_report_digest,
        'deployment_path_report.source_evidence.airgap.bundle_check_report_digest'
      ) !== steps.get('bundle-check').report_digest
    ) {
      fail('deployment_path_report.source_evidence.airgap.bundle_check_report_digest must match bundle-check step');
    }
    requireDigest(
      airgap.image_map_input_sha256,
      'deployment_path_report.source_evidence.airgap.image_map_input_sha256'
    );
  } else if (Object.prototype.hasOwnProperty.call(ledger, 'airgap')) {
    fail('deployment_path_report.source_evidence.airgap is only accepted for airgap paths');
  }

  if (requirement.installSubstrates) {
    const install = requireObject(
      ledger.substrate_install,
      'deployment_path_report.source_evidence.substrate_install'
    );
    if (
      requireDigest(
        install.report_digest,
        'deployment_path_report.source_evidence.substrate_install.report_digest'
      ) !== steps.get('substrate-install').report_digest
    ) {
      fail('deployment_path_report.source_evidence.substrate_install.report_digest must match substrate-install step');
    }
    requireEquals(
      requireString(install.schema, 'deployment_path_report.source_evidence.substrate_install.schema'),
      SUBSTRATE_INSTALL_SCHEMA,
      'deployment_path_report.source_evidence.substrate_install.schema'
    );
    requireEquals(
      requireString(install.scope, 'deployment_path_report.source_evidence.substrate_install.scope'),
      SUBSTRATE_INSTALL_SCOPE,
      'deployment_path_report.source_evidence.substrate_install.scope'
    );
    requireDigest(
      install.output_substrate_truth_digest,
      'deployment_path_report.source_evidence.substrate_install.output_substrate_truth_digest'
    );
    const serviceCount = requireInteger(
      install.service_count,
      'deployment_path_report.source_evidence.substrate_install.service_count'
    );
    if (serviceCount === 0) {
      fail('deployment_path_report.source_evidence.substrate_install.service_count must be greater than zero');
    }
  } else if (Object.prototype.hasOwnProperty.call(ledger, 'substrate_install')) {
    fail('deployment_path_report.source_evidence.substrate_install is only accepted for install_substrates paths');
  }

  return ledger;
}

function safeSourceEvidencePath(value, label) {
  const relative = requireString(value, label);
  if (relative.includes('\\') || path.isAbsolute(relative)) {
    fail(`${label} must be a portable relative path`);
  }
  const parts = relative.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not contain empty, current, or parent segments`);
  }
  if (parts[0] !== SOURCE_EVIDENCE_DIR) {
    fail(`${label} must be under ${SOURCE_EVIDENCE_DIR}/`);
  }
  return relative;
}

function sourceEvidenceManifestPathSet(entries) {
  const paths = new Set();
  for (const [index, entry] of entries.entries()) {
    const relative = safeSourceEvidencePath(
      entry.path,
      `finalizer_manifest.source_evidence_files[${index}].path`
    );
    if (paths.has(relative)) {
      fail(`finalizer_manifest.source_evidence_files contains duplicate path: ${relative}`);
    }
    paths.add(relative);
  }
  return paths;
}

async function listSourceEvidenceJsonFiles(sourceDir, currentDir = sourceDir) {
  let entries;
  try {
    entries = await fs.readdir(currentDir, { withFileTypes: true });
  } catch (error) {
    fail(`cannot read source evidence directory: ${error.message}`);
  }

  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(currentDir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await listSourceEvidenceJsonFiles(sourceDir, fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith('.json')) {
      files.push(
        `${SOURCE_EVIDENCE_DIR}/${path.relative(sourceDir, fullPath).split(path.sep).join('/')}`
      );
    }
  }
  return files;
}

async function validateSourceEvidenceDirectoryClosure(reportDir, manifestPaths) {
  const actualJsonFiles = await listSourceEvidenceJsonFiles(
    path.join(reportDir, SOURCE_EVIDENCE_DIR)
  );
  const actualJsonSet = new Set(actualJsonFiles);
  for (const relative of actualJsonFiles) {
    if (!manifestPaths.has(relative)) {
      fail(`source evidence directory contains unlisted JSON file: ${relative}`);
    }
  }
  for (const relative of manifestPaths) {
    if (relative.endsWith('.json') && !actualJsonSet.has(relative)) {
      fail(`source evidence directory is missing manifest-listed JSON file: ${relative}`);
    }
  }
}

function sourceEvidenceKey(kind, step) {
  return `${kind}:${step ?? ''}`;
}

function expectedSourceEvidenceFiles({ ledger, requirement }) {
  const gate = requireObject(
    ledger.source_deployment_gate_report,
    'deployment_path_report.source_evidence.source_deployment_gate_report'
  );
  const expected = [
    {
      kind: 'source_deployment_gate',
      sha256: gate.digest,
      schema: gate.schema,
      scope: gate.scope
    }
  ];

  for (const step of ledger.finalized_steps) {
    expected.push({
      kind: 'finalized_step_report',
      step: step.name,
      sha256: step.report_digest,
      schema: step.source_schema,
      scope: step.source_scope
    });
  }

  if (requirement.source === 'airgap') {
    const airgap = requireObject(ledger.airgap, 'deployment_path_report.source_evidence.airgap');
    expected.push({
      kind: 'airgap_bundle_manifest',
      sha256: airgap.bundle_manifest_digest,
      schema: AIRGAP_BUNDLE_MANIFEST_SCHEMA,
      scope: null
    });
    expected.push({
      kind: 'airgap_image_map',
      sha256: airgap.image_map_input_sha256,
      schema: IMAGE_MAP_SCHEMA,
      scope: IMAGE_MAP_SCOPE
    });
  }

  return expected;
}

async function validateSourceEvidenceMaterialFile({ reportDir, entry, expected }) {
  if (requireString(entry.kind, 'finalizer_manifest.source_evidence_files[].kind') !== expected.kind) {
    fail('finalizer_manifest.source_evidence_files entry type must match path report source evidence');
  }
  if (expected.step !== undefined) {
    if (
      requireString(entry.step, `finalizer_manifest.source_evidence_files.${expected.kind}.step`) !==
      expected.step
    ) {
      fail('finalizer_manifest.source_evidence_files finalized step must match path report source evidence');
    }
  } else if (Object.prototype.hasOwnProperty.call(entry, 'step')) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} must not include step`);
  }

  const relative = safeSourceEvidencePath(
    entry.path,
    `finalizer_manifest.source_evidence_files.${expected.kind}.path`
  );
  if (
    requireDigest(entry.sha256, `finalizer_manifest.source_evidence_files.${expected.kind}.sha256`) !==
    expected.sha256
  ) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} sha256 must match path report source evidence`);
  }
  if (
    requireString(entry.schema, `finalizer_manifest.source_evidence_files.${expected.kind}.schema`) !==
    expected.schema
  ) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} schema must match path report source evidence`);
  }
  if (entry.scope !== expected.scope) {
    fail(`finalizer_manifest.source_evidence_files ${expected.kind} scope must match path report source evidence`);
  }

  const materialInput = await readJson(
    path.join(reportDir, relative),
    `source evidence file ${relative}`
  );
  if (materialInput.digest !== expected.sha256) {
    fail(`source evidence file ${relative} sha256 must match finalizer manifest`);
  }
  const materialReport = requireObject(materialInput.value, `source evidence file ${relative}`);
  scanReportForForbiddenContent({
    value: materialReport,
    buffer: materialInput.buffer,
    label: `source evidence file ${relative}`
  });
  if (reportSchema(materialReport) !== expected.schema) {
    fail(`source evidence file ${relative} schema must match finalizer manifest`);
  }
  if (expected.scope !== null && materialReport.scope !== expected.scope) {
    fail(`source evidence file ${relative} scope must match finalizer manifest`);
  }
  return materialInput;
}

async function validateFinalizerManifest({
  pathInput,
  report,
  ledger,
  operatorPath,
  requirement,
  release,
  deployTemplate
}) {
  const reportDir = path.dirname(pathInput.file);
  const manifestInput = await readJson(
    path.join(reportDir, FINALIZER_MANIFEST_FILE),
    'deployment path finalizer manifest'
  );
  const manifest = requireObject(manifestInput.value, 'deployment path finalizer manifest');
  requireSchema(manifest, FINALIZER_MANIFEST_SCHEMA, 'deployment path finalizer manifest');
  if (
    requireString(manifest.tool, 'finalizer_manifest.tool') !== FINALIZER_MANIFEST_TOOL
  ) {
    fail(`finalizer_manifest.tool must be ${FINALIZER_MANIFEST_TOOL}`);
  }
  if (requireString(manifest.operator_path, 'finalizer_manifest.operator_path') !== operatorPath) {
    fail('finalizer_manifest.operator_path must match deployment path report');
  }
  if (
    requireString(manifest.deployment_profile, 'finalizer_manifest.deployment_profile') !==
    report.target_profile.value
  ) {
    fail('finalizer_manifest.deployment_profile must match deployment path report');
  }
  if (
    requireDigest(manifest.release_contract_digest, 'finalizer_manifest.release_contract_digest') !==
    release.release_contract_digest
  ) {
    fail('finalizer_manifest.release_contract_digest must match release contract digest');
  }
  if (
    requireDigest(manifest.template_digest, 'finalizer_manifest.template_digest') !==
    deployTemplate.deploy_template_package_digest
  ) {
    fail('finalizer_manifest.template_digest must match deploy template package digest');
  }
  if (
    requireDigest(manifest.path_report_sha256, 'finalizer_manifest.path_report_sha256') !==
    pathInput.digest
  ) {
    fail('finalizer_manifest.path_report_sha256 must match deployment path report bytes');
  }
  requireString(manifest.created_at, 'finalizer_manifest.created_at');

  const actualEntries = requireArray(
    manifest.source_evidence_files,
    'finalizer_manifest.source_evidence_files'
  );
  const manifestPaths = sourceEvidenceManifestPathSet(actualEntries);
  await validateSourceEvidenceDirectoryClosure(reportDir, manifestPaths);
  const expectedEntries = expectedSourceEvidenceFiles({ ledger, requirement });
  if (actualEntries.length !== expectedEntries.length) {
    fail('finalizer_manifest.source_evidence_files must exactly cover path report source evidence');
  }

  const actualByKey = new Map();
  for (const [index, rawEntry] of actualEntries.entries()) {
    const entry = requireObject(rawEntry, `finalizer_manifest.source_evidence_files[${index}]`);
    const kind = requireString(entry.kind, `finalizer_manifest.source_evidence_files[${index}].kind`);
    const step = kind === 'finalized_step_report'
      ? requireString(entry.step, `finalizer_manifest.source_evidence_files[${index}].step`)
      : undefined;
    const key = sourceEvidenceKey(kind, step);
    if (actualByKey.has(key)) {
      fail(`finalizer_manifest.source_evidence_files contains duplicate entry: ${key}`);
    }
    actualByKey.set(key, entry);
  }

  const materializedSourceEvidence = {
    sourceInputsByStep: new Map()
  };

  for (const expected of expectedEntries) {
    const key = sourceEvidenceKey(expected.kind, expected.step);
    const entry = actualByKey.get(key);
    if (!entry) {
      fail(`finalizer_manifest.source_evidence_files missing entry: ${key}`);
    }
    const materialInput = await validateSourceEvidenceMaterialFile({ reportDir, entry, expected });
    if (expected.kind === 'source_deployment_gate') {
      materializedSourceEvidence.sourceDeploymentGateInput = materialInput;
    } else if (expected.kind === 'finalized_step_report') {
      materializedSourceEvidence.sourceInputsByStep.set(expected.step, materialInput);
    } else if (expected.kind === 'airgap_bundle_manifest') {
      materializedSourceEvidence.airgapBundleManifestInput = materialInput;
    } else if (expected.kind === 'airgap_image_map') {
      materializedSourceEvidence.airgapImageMapInput = materialInput;
    }
  }

  return materializedSourceEvidence;
}

async function validateDeploymentPathReport(pathInput, release, deployTemplate) {
  const report = pathInput.value;
  const reportDigest = pathInput.digest;
  requireSchema(report, PATH_REPORT_SCHEMA, 'deployment path report');
  if (requireString(report.scope, 'deployment_path_report.scope') !== PATH_REPORT_SCOPE) {
    fail(`deployment_path_report.scope must be ${PATH_REPORT_SCOPE}`);
  }
  if (report.readiness !== false) {
    fail('deployment path report readiness must be false');
  }
  requireNoFormalVerdict(report, 'deployment path report');
  commonReportChecks(report, 'deployment path report', release);
  if (
    requireDigest(report.deploy_template_package_digest, 'deployment_path_report.deploy_template_package_digest') !==
    deployTemplate.deploy_template_package_digest
  ) {
    fail('deployment path report deploy_template_package_digest must match descriptor digest');
  }

  const operatorPath = requireString(report.operator_path, 'deployment_path_report.operator_path');
  const requirement = DEPLOYMENT_PATHS.get(operatorPath);
  if (!requirement) {
    fail(`unexpected deployment operator path: ${operatorPath}`);
  }
  requireTargetProfile(report.target_profile, requirement.targetProfile, 'deployment_path_report.target_profile');

  const steps = reportStepsByName(report, `deployment path ${operatorPath}`);
  const requiredSteps = sourceValidation.deploymentPathReportStepNames(requirement);
  for (const step of requiredSteps) {
    if (!steps.has(step)) {
      fail(`deployment path ${operatorPath} missing required step: ${step}`);
    }
  }
  if (steps.size !== requiredSteps.length) {
    fail(`deployment path ${operatorPath} steps must exactly match required steps`);
  }

  if (requirement.installSubstrates) {
    const confirmation = requireObject(report.install_substrates_confirmation, 'deployment_path_report.install_substrates_confirmation');
    if (confirmation.confirmed !== true) {
      fail(`deployment path ${operatorPath} requires explicit install_substrates confirmation`);
    }
    requireString(confirmation.operator_run_id, 'deployment_path_report.install_substrates_confirmation.operator_run_id');
    if (
      requireDigest(
        confirmation.substrate_install_report_digest,
        'deployment_path_report.install_substrates_confirmation.substrate_install_report_digest'
      ) !== steps.get('substrate-install').report_digest
    ) {
      fail('deployment_path_report.install_substrates_confirmation.substrate_install_report_digest must match substrate-install step');
    }
  }

  if (requirement.source === 'airgap') {
    const offline = requireObject(report.airgap_offline, 'deployment_path_report.airgap_offline');
    if (offline.public_internet_downloads !== false) {
      fail(`deployment path ${operatorPath} must prove no public internet downloads`);
    }
    requireDigest(offline.bundle_manifest_digest, 'deployment_path_report.airgap_offline.bundle_manifest_digest');
    if (
      requireDigest(
        offline.image_load_report_digest,
        'deployment_path_report.airgap_offline.image_load_report_digest'
      ) !== steps.get('image-load').report_digest
    ) {
      fail('deployment_path_report.airgap_offline.image_load_report_digest must match image-load step');
    }
    if (
      requireDigest(
        offline.offline_render_report_digest,
        'deployment_path_report.airgap_offline.offline_render_report_digest'
      ) !== steps.get('offline-render-check').report_digest
    ) {
      fail('deployment_path_report.airgap_offline.offline_render_report_digest must match offline-render-check step');
    }
  }

  const ledger = validateSourceEvidenceLedger(report, requirement, requiredSteps, steps, operatorPath);
  const materializedSourceEvidence = await validateFinalizerManifest({
    pathInput,
    report,
    ledger,
    operatorPath,
    requirement,
    release,
    deployTemplate
  });
  sourceValidation.validateMaterializedDeploymentPathSourceEvidence({
    operatorPath,
    release: {
      ...release,
      deploy_template_package_digest: deployTemplate.deploy_template_package_digest
    },
    ...materializedSourceEvidence,
    installOperatorRunId: report.install_substrates_confirmation?.operator_run_id
  });

  return {
    operator_path: operatorPath,
    target_profile: report.target_profile.value,
    report_digest: reportDigest,
    steps: [...steps.keys()]
  };
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function writeSummary(file, report) {
  const lines = [
    '# AgentSmith GA Release Summary',
    '',
    `Status: ${report.status}`,
    `Formal verdict: ${report.formal_verdict}`,
    `Release: ${report.release.release_id}`,
    `Git SHA: ${report.release.git_sha}`,
    `Release contract: ${report.release.release_contract_digest}`,
    '',
    'Deployment paths:',
    ...report.deployment_paths.map((entry) => `- ${entry.operator_path}: ${entry.report_digest}`),
    '',
    `Product readiness: ${report.product_readiness.report_digest}`,
    `Post-deploy product smoke: ${report.post_deploy_product_smoke.report_digest}`,
    ''
  ];
  await fs.writeFile(file, `${lines.join('\n')}\n`, 'utf8');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const contract = await readJson(args.releaseContract, 'release contract');
  const deployTemplate = await readJson(args.deployTemplatePackage, 'deploy template package');
  const productReady = await readJson(args.productReadinessReport, 'product readiness report');
  const productSmoke = await readJson(args.postDeployProductSmokeReport, 'post-deploy product smoke report');
  const pathReports = [];
  for (const file of args.deploymentPathReports) {
    pathReports.push(await readJson(file, 'deployment path report'));
  }

  for (const input of [productReady, productSmoke, ...pathReports]) {
    scanReportForForbiddenContent({
      value: input.value,
      buffer: input.buffer,
      label: 'input report'
    });
  }

  const release = validateReleaseContract(contract.value, contract.digest);
  const deployTemplateSummary = validateDeployTemplatePackage(deployTemplate.value, contract.value, deployTemplate.digest);
  const productReadinessSummary = validateProductReadiness(productReady.value, productReady.digest, release);
  const productSmokeSummary = validateProductSmoke(productSmoke.value, productSmoke.digest, release);

  const deploymentPaths = [];
  for (const entry of pathReports) {
    deploymentPaths.push(await validateDeploymentPathReport(entry, release, deployTemplateSummary));
  }
  const seenPaths = new Set();
  for (const entry of deploymentPaths) {
    if (seenPaths.has(entry.operator_path)) {
      fail(`duplicate deployment path report: ${entry.operator_path}`);
    }
    seenPaths.add(entry.operator_path);
  }
  for (const pathName of DEPLOYMENT_PATHS.keys()) {
    if (!seenPaths.has(pathName)) {
      fail(`missing deployment path report: ${pathName}`);
    }
  }

  const report = {
    schema: REPORT_SCHEMA,
    status: 'pass',
    formal_verdict: 'issued',
    release: {
      release_id: release.release_id,
      git_sha: release.git_sha,
      release_contract_digest: release.release_contract_digest,
      deploy_template_package_digest: deployTemplateSummary.deploy_template_package_digest,
      artifact_freshness_key: [
        release.release_id,
        release.git_sha,
        release.provenance.producer_repo,
        release.provenance.run_id,
        release.provenance.run_attempt,
        release.release_contract_digest
      ].join(':')
    },
    images: release.images,
    deployment_paths: deploymentPaths.sort((a, b) => a.operator_path.localeCompare(b.operator_path)),
    product_readiness: productReadinessSummary,
    post_deploy_product_smoke: productSmokeSummary,
    canonical_repos: [
      {
        repo: AGENTSMITH_REPO,
        commit_sha: release.git_sha,
        run_id: release.provenance.run_id,
        run_attempt: release.provenance.run_attempt
      }
    ],
    artifact_index: {
      release_contract: {
        digest: release.release_contract_digest,
        provenance: release.provenance
      },
      deploy_template_package: deployTemplateSummary,
      deployment_paths: deploymentPaths.map((entry) => ({
        operator_path: entry.operator_path,
        digest: entry.report_digest
      })),
      product_readiness: productReadinessSummary.report_digest,
      post_deploy_product_smoke: productSmokeSummary.report_digest
    },
    summary: {
      conclusion: 'AgentSmith GA release aggregate passed.',
      operator_paths: deploymentPaths.map((entry) => entry.operator_path).sort(),
      product_smoke_flows: productSmokeSummary.covered_flows
    },
    blockers: []
  };

  const outputDir = path.resolve(args.outputDir);
  await writeJson(path.join(outputDir, REPORT_FILE), report);
  await writeSummary(path.join(outputDir, SUMMARY_FILE), report);
  console.log(`PASS: wrote ${REPORT_FILE} (${canonicalDigest(report)})`);
}

main().catch((error) => {
  const exitCode = error.exitCode ?? 1;
  console.error(`${exitCode === 2 ? 'error' : 'FAIL'}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
