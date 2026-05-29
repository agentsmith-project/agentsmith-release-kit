#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERIFY_RELEASE = path.join(ROOT_DIR, 'scripts', 'verify-release.sh');
const REPORT_FILE = 'online-adoption-report.json';
const ONLINE_REPORT_FILE = 'online-deployment-gate-report.json';
const EVIDENCE_FILE = 'evidence.json';
const EVIDENCE_SUBJECT_FILE = 'evidence-subject.json';
const REPORT_SCHEMA = 'agentsmith.online-adoption/v1';
const REPORT_SCOPE = 'online_adoption_aggregation_only';
const ONLINE_GATE_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const ONLINE_GATE_SCOPE = 'online_deployment_gate_only';
const EVIDENCE_SCHEMA = 'agentsmith.release-kit-evidence-envelope/v1';
const EVIDENCE_SUBJECT_SCHEMA = 'agentsmith.release-kit-evidence-subject/v1';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const RELEASE_CONTRACT_SUBJECT_NAME = 'agentsmith-release-contract';
const USE_EXISTING_PROFILE = 'existing_kubernetes/external_declared/online';
const INSTALL_SUBSTRATES_PROFILE = 'existing_kubernetes/kit_installed/online';
const REQUIRED_ARGS = [
  'releaseContract',
  'useExistingReport',
  'useExistingEvidenceRoot',
  'installSubstratesReport',
  'installSubstratesEvidenceRoot',
  'outputDir'
];
const REQUIRED_PATHS = [
  {
    key: 'use_existing',
    operatorPath: 'online/use_existing',
    reportArg: 'useExistingReport',
    evidenceRootArg: 'useExistingEvidenceRoot',
    targetProfile: USE_EXISTING_PROFILE,
    requiredSteps: [
      'inputs',
      'target-preflight',
      'template-package',
      'render',
      'render-check',
      'apply',
      'rollout',
      'smoke'
    ]
  },
  {
    key: 'install_substrates',
    operatorPath: 'online/install_substrates',
    reportArg: 'installSubstratesReport',
    evidenceRootArg: 'installSubstratesEvidenceRoot',
    targetProfile: INSTALL_SUBSTRATES_PROFILE,
    requiredSteps: [
      'inputs',
      'target-preflight',
      'substrate-pack-check',
      'template-package',
      'substrate-routability',
      'render',
      'render-check',
      'apply',
      'rollout',
      'smoke'
    ]
  }
];
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const FORBIDDEN_OUTPUT_KEYS = new Set([
  'verdict',
  'release_verdict',
  'operator_verdict',
  'deploy_readiness',
  'package_readiness',
  'release_readiness',
  'ready',
  'kubeconfig',
  'secret',
  'secrets',
  'product_flows',
  'product_flow_results',
  'report_path',
  'report_paths',
  'evidence_root'
]);
const FORBIDDEN_OUTPUT_TEXT_RE =
  /\b(?:verdict|release_verdict|operator_verdict|product_flows|product_flow_results)\b/i;
const LOCAL_OR_SECRET_TEXT_RE =
  /(?:^|["'\s])(?:\/home\/|\/tmp\/|\/var\/|\/private\/|[A-Za-z]:[\\/]|file:\/\/)|secretRef:|kubeconfig|Bearer\s+[A-Za-z0-9._~+/=-]+|token\s*[:=]|password\s*[:=]/i;

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
  node scripts/verify-online-adoption.mjs \\
    --release-contract <json> \\
    --use-existing-report <online-deployment-gate-report.json> \\
    --use-existing-evidence-root <dir> \\
    --install-substrates-report <online-deployment-gate-report.json> \\
    --install-substrates-evidence-root <dir> \\
    --output-dir <dir>

This is repo-local online adoption aggregation only. It validates two existing
operator-facing online focused evidence roots and writes ${REPORT_FILE}; it is
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
      case '--use-existing-report':
        parsed.useExistingReport = nextValue();
        break;
      case '--use-existing-evidence-root':
        parsed.useExistingEvidenceRoot = nextValue();
        break;
      case '--install-substrates-report':
        parsed.installSubstratesReport = nextValue();
        break;
      case '--install-substrates-evidence-root':
        parsed.installSubstratesEvidenceRoot = nextValue();
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

function assertProfileObject(value, expectedProfile, label) {
  const profile = requireObject(value, label);
  const targetCluster = requireString(profile.target_cluster, `${label}.target_cluster`);
  const substrateSource = requireString(profile.substrate_source, `${label}.substrate_source`);
  const distribution = requireString(profile.distribution, `${label}.distribution`);
  const computed = `${targetCluster}/${substrateSource}/${distribution}`;
  assertStringEquals(profile.value, computed, `${label}.value`);
  if (computed !== expectedProfile) {
    fail(`${label} must be ${expectedProfile}`);
  }
  return profile;
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

function releaseContractSubjectDigest(contract) {
  const provenance = requireObject(
    contract.artifact_provenance,
    'release_contract.artifact_provenance'
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

async function releaseIdentityFromContract(file) {
  const input = await readJson(file, 'release contract');
  const contract = requireObject(input.value, 'release_contract');
  return {
    releaseId: requireString(contract.release_id, 'release_contract.release_id'),
    gitSha: requireGitSha(contract.git_sha, 'release_contract.git_sha'),
    releaseContractDigest: input.digest,
    releaseContractSubjectSha256: releaseContractSubjectDigest(contract)
  };
}

function evidenceProjection(evidence) {
  const { artifact_provenance: _artifactProvenance, ...subject } = evidence;
  return subject;
}

function subjectFileDigest(subject, filePath) {
  for (const [index, entryValue] of requireArray(subject.files, 'evidence_subject.files').entries()) {
    const entry = requireObject(entryValue, `evidence_subject.files[${index}]`);
    const entryPath = requireString(entry.path, `evidence_subject.files[${index}].path`);
    if (entryPath === filePath) {
      return requireDigest(entry.sha256, `evidence_subject.files[${index}].sha256`);
    }
  }
  fail(`evidence_subject.files must include ${filePath}`);
}

function assertReportHeader({ report, pathSpec, releaseIdentity, label }) {
  assertStringEquals(report.schema, ONLINE_GATE_SCHEMA, `${label}.schema`);
  assertStringEquals(report.scope, ONLINE_GATE_SCOPE, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);
  assertStringEquals(report.mode, 'apply', `${label}.mode`);
  requireString(report.operator_run_id, `${label}.operator_run_id`);
  assertStringEquals(report.release_id, releaseIdentity.releaseId, `${label}.release_id`);
  const reportGitSha = requireGitSha(report.git_sha, `${label}.git_sha`);
  if (reportGitSha !== releaseIdentity.gitSha) {
    fail(`${label}.git_sha must match release contract`);
  }
  const reportReleaseContract = requireObject(
    report.release_contract,
    `${label}.release_contract`
  );
  const reportReleaseDigest = requireDigest(
    reportReleaseContract.input_sha256,
    `${label}.release_contract.input_sha256`
  );
  if (reportReleaseDigest !== releaseIdentity.releaseContractDigest) {
    fail(`${label}.release_contract.input_sha256 must match release contract input`);
  }
  assertProfileObject(report.target_profile, pathSpec.targetProfile, `${label}.target_profile`);
}

function summarizeSteps(report, requiredSteps, label) {
  const steps = [];
  const seen = new Set();
  for (const [index, stepValue] of requireArray(report.steps, `${label}.steps`).entries()) {
    const step = requireObject(stepValue, `${label}.steps[${index}]`);
    const name = requireString(step.name, `${label}.steps[${index}].name`);
    if (seen.has(name)) {
      fail(`${label}.steps contains duplicate step: ${name}`);
    }
    seen.add(name);
    assertStringEquals(step.status, 'pass', `${label}.steps[${index}].status`);
    const reportPaths = requireArray(step.report_paths, `${label}.steps[${index}].report_paths`);
    if (reportPaths.length === 0) {
      fail(`${label}.steps[${index}].report_paths must not be empty`);
    }
    reportPaths.forEach((reportPath, pathIndex) => {
      assertSafeRelativePath(reportPath, `${label}.steps[${index}].report_paths[${pathIndex}]`);
    });
    steps.push(name);
  }

  for (const requiredStep of requiredSteps) {
    if (!seen.has(requiredStep)) {
      fail(`${label}.steps is missing confirmed online adoption step: ${requiredStep}`);
    }
  }

  return steps;
}

function runEvidenceValidation({ args, pathSpec }) {
  const outputDir = path.join(
    path.resolve(args.outputDir),
    'evidence-validation',
    pathSpec.key
  );
  const result = spawnSync(
    'bash',
    [
      VERIFY_RELEASE,
      '--evidence',
      '--release-contract',
      args.releaseContract,
      '--evidence-root',
      args[pathSpec.evidenceRootArg],
      '--target-profile',
      pathSpec.targetProfile,
      '--output-dir',
      outputDir
    ],
    {
      cwd: ROOT_DIR,
      stdio: 'inherit',
      env: process.env
    }
  );

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    fail(`${pathSpec.operatorPath} evidence root must pass focused evidence validation`);
  }
}

function validateEvidence({
  evidence,
  subject,
  evidenceReport,
  reportDigest,
  evidenceReportDigest,
  pathSpec,
  releaseIdentity
}) {
  assertStringEquals(evidence.schema_version, EVIDENCE_SCHEMA, 'evidence.schema_version');
  assertStringEquals(
    evidence.release_kit_output,
    ONLINE_REPORT_FILE,
    'evidence.release_kit_output'
  );
  assertStringEquals(evidence.release_id, releaseIdentity.releaseId, 'evidence.release_id');
  const evidenceGitSha = requireGitSha(evidence.git_sha, 'evidence.git_sha');
  if (evidenceGitSha !== releaseIdentity.gitSha) {
    fail('evidence.git_sha must match release contract');
  }
  const evidenceReleaseDigest = requireDigest(
    evidence.release_contract_digest,
    'evidence.release_contract_digest'
  );
  if (evidenceReleaseDigest !== releaseIdentity.releaseContractDigest) {
    fail('evidence.release_contract_digest must match release contract input');
  }
  const evidenceProfile =
    `${requireString(evidence.target_cluster, 'evidence.target_cluster')}/` +
    `${requireString(evidence.substrate_source, 'evidence.substrate_source')}/` +
    `${requireString(evidence.distribution, 'evidence.distribution')}`;
  if (evidenceProfile !== pathSpec.targetProfile) {
    fail('evidence target profile must match operator online path');
  }
  assertStringEquals(evidence.status, 'passed', 'evidence.status');
  assertStringEquals(evidence.failure_class, 'none', 'evidence.failure_class');

  assertStringEquals(
    subject.schema_version,
    EVIDENCE_SUBJECT_SCHEMA,
    'evidence_subject.schema_version'
  );
  const subjectEvidenceDigest = subjectFileDigest(subject, EVIDENCE_FILE);
  if (subjectEvidenceDigest !== canonicalDigest(evidenceProjection(evidence))) {
    fail('evidence_subject evidence.json digest must match evidence projection');
  }
  const subjectReportDigest = subjectFileDigest(subject, ONLINE_REPORT_FILE);
  if (subjectReportDigest !== evidenceReportDigest) {
    fail('evidence_subject online deployment gate digest must match evidence root report');
  }
  if (evidenceReportDigest !== reportDigest) {
    fail(`${pathSpec.operatorPath} report digest must match evidence root gate report`);
  }

  const provenance = requireObject(evidence.artifact_provenance, 'evidence.artifact_provenance');
  assertStringEquals(
    provenance.schema_version,
    ARTIFACT_PROVENANCE_SCHEMA,
    'evidence.artifact_provenance.schema_version'
  );
  const subjectSha256 = requireDigest(
    provenance.subject_sha256,
    'evidence.artifact_provenance.subject_sha256'
  );
  if (subjectSha256 !== canonicalDigest(subject)) {
    fail('evidence.artifact_provenance.subject_sha256 must match evidence subject');
  }

  assertReportHeader({
    report: evidenceReport,
    pathSpec,
    releaseIdentity,
    label: 'evidence_online_deployment_gate_report'
  });

  return {
    provenance_kind: requireString(
      provenance.provenance_kind,
      'evidence.artifact_provenance.provenance_kind'
    ),
    producer_repo: requireString(
      provenance.producer_repo,
      'evidence.artifact_provenance.producer_repo'
    ),
    normalized_remote: requireString(
      provenance.normalized_remote,
      'evidence.artifact_provenance.normalized_remote'
    ),
    commit_sha: requireGitSha(
      provenance.commit_sha,
      'evidence.artifact_provenance.commit_sha'
    ),
    artifact_uri: requireString(
      provenance.artifact_uri,
      'evidence.artifact_provenance.artifact_uri'
    ),
    subject_sha256: subjectSha256
  };
}

async function summarizeOnlinePath({ args, pathSpec, releaseIdentity }) {
  const reportPath = path.resolve(args[pathSpec.reportArg]);
  const evidenceRoot = path.resolve(args[pathSpec.evidenceRootArg]);
  const reportInput = await readJson(reportPath, `${pathSpec.operatorPath} online gate report`);
  const report = requireObject(reportInput.value, `${pathSpec.key}_online_deployment_gate_report`);

  assertReportHeader({
    report,
    pathSpec,
    releaseIdentity,
    label: `${pathSpec.key}_online_deployment_gate_report`
  });
  const steps = summarizeSteps(
    report,
    pathSpec.requiredSteps,
    `${pathSpec.key}_online_deployment_gate_report`
  );

  runEvidenceValidation({ args, pathSpec });

  const evidenceInput = await readJson(
    path.join(evidenceRoot, EVIDENCE_FILE),
    `${pathSpec.operatorPath} evidence`
  );
  const subjectInput = await readJson(
    path.join(evidenceRoot, EVIDENCE_SUBJECT_FILE),
    `${pathSpec.operatorPath} evidence subject`
  );
  const evidenceReportInput = await readJson(
    path.join(evidenceRoot, ONLINE_REPORT_FILE),
    `${pathSpec.operatorPath} evidence gate report`
  );
  const evidence = requireObject(evidenceInput.value, `${pathSpec.key}_evidence`);
  const subject = requireObject(subjectInput.value, `${pathSpec.key}_evidence_subject`);
  const evidenceReport = requireObject(
    evidenceReportInput.value,
    `${pathSpec.key}_evidence_gate_report`
  );
  const provenance = validateEvidence({
    evidence,
    subject,
    evidenceReport,
    reportDigest: reportInput.digest,
    evidenceReportDigest: evidenceReportInput.digest,
    pathSpec,
    releaseIdentity
  });

  return {
    operator_path: pathSpec.operatorPath,
    target_profile: pathSpec.targetProfile,
    mode: 'apply',
    confirmed_apply: true,
    rollout_checked: true,
    smoke_checked: true,
    digests: {
      online_deployment_gate_report: reportInput.digest,
      evidence: evidenceInput.digest,
      evidence_subject: subjectInput.digest,
      release_contract: releaseIdentity.releaseContractDigest
    },
    provenance,
    coverage: {
      steps,
      step_count: steps.length,
      required_steps: pathSpec.requiredSteps
    }
  };
}

function assertNoForbiddenKeys(value, label = 'online_adoption_report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoForbiddenKeys(item, `${label}[${index}]`));
    return;
  }
  for (const [key, nested] of Object.entries(value)) {
    if (FORBIDDEN_OUTPUT_KEYS.has(key)) {
      fail(`online adoption report must not include forbidden key: ${label}.${key}`);
    }
    assertNoForbiddenKeys(nested, `${label}.${key}`);
  }
}

function assertSafeReport(report) {
  assertNoForbiddenKeys(report);
  const serialized = JSON.stringify(report);
  if (FORBIDDEN_OUTPUT_TEXT_RE.test(serialized) || LOCAL_OR_SECRET_TEXT_RE.test(serialized)) {
    fail('online adoption report must not include verdict wording, raw local paths, or secret-looking payloads');
  }
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.online-adoption.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function removeManagedReport(outputDir) {
  if (!outputDir) {
    return;
  }
  await fs.rm(path.join(path.resolve(outputDir), REPORT_FILE), { force: true });
}

async function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    throw error;
  }
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeManagedReport(args.outputDir);
  const releaseIdentity = await releaseIdentityFromContract(args.releaseContract);
  const summaries = {};
  for (const pathSpec of REQUIRED_PATHS) {
    summaries[pathSpec.key] = await summarizeOnlinePath({
      args,
      pathSpec,
      releaseIdentity
    });
  }

  const report = {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: releaseIdentity.releaseId,
    git_sha: releaseIdentity.gitSha,
    release_contract: {
      input_sha256: releaseIdentity.releaseContractDigest,
      subject_sha256: releaseIdentity.releaseContractSubjectSha256
    },
    coverage: {
      required_operator_paths: REQUIRED_PATHS.map((pathSpec) => pathSpec.operatorPath),
      target_profiles: REQUIRED_PATHS.map((pathSpec) => pathSpec.targetProfile),
      confirmed_apply_paths: REQUIRED_PATHS.length,
      rollout_checked_paths: REQUIRED_PATHS.length,
      smoke_checked_paths: REQUIRED_PATHS.length
    },
    online_paths: summaries,
    generated_at: new Date().toISOString()
  };

  assertSafeReport(report);
  await writeReport(args.outputDir, report);
  console.log(`PASS: wrote ${REPORT_FILE}; online adoption aggregation is not release readiness`);
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
