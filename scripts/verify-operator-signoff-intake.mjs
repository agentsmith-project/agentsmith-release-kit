#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = [
  'releaseContract',
  'onlineDeploymentGateReport',
  'operatorSignoffIntake',
  'targetProfile',
  'outputDir'
];
const SUPPORTED_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const INPUT_SCHEMA = 'agentsmith.operator-signoff-intake/v1';
const REPORT_SCHEMA = 'agentsmith.operator-signoff-intake-report/v1';
const SCOPE = 'operator_signoff_intake_only';
const ONLINE_DEPLOYMENT_GATE_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const ONLINE_DEPLOYMENT_GATE_SCOPE = 'online_deployment_gate_only';
const ONLINE_DEPLOYMENT_GATE_SUBJECT_KIND = 'online_deployment_gate_report';
const ONLINE_DEPLOYMENT_GATE_ALLOWED_FIELDS = new Set([
  'schema',
  'scope',
  'readiness',
  'status',
  'mode',
  'operator_run_id',
  'release_id',
  'git_sha',
  'release_contract',
  'target_profile',
  'capability_map',
  'steps',
  'generated_at'
]);
const ONLINE_DEPLOYMENT_GATE_ALLOWED_STEPS = new Set([
  'inputs',
  'target-preflight',
  'template-package',
  'image-map',
  'render',
  'render-check',
  'apply',
  'rollout',
  'smoke'
]);
const ONLINE_DEPLOYMENT_GATE_STEP_ALLOWED_FIELDS = new Set(['name', 'status', 'report_paths']);
const ONLINE_DEPLOYMENT_GATE_CAPABILITY_FIELDS = new Set([
  'declared',
  'intake',
  'preflight',
  'render',
  'apply',
  'rollout',
  'smoke',
  'evidence_envelope'
]);
const ONLINE_DEPLOYMENT_GATE_CAPABILITY_EXPECTED = {
  declared: 'supported',
  intake: 'supported',
  preflight: 'supported',
  render: 'supported',
  apply: 'supported',
  rollout: 'supported',
  smoke: 'optional',
  evidence_envelope: 'optional'
};
const ONLINE_DEPLOYMENT_GATE_ALLOWED_STEP_SEQUENCES = [
  ['inputs', 'target-preflight', 'template-package', 'render', 'render-check', 'apply', 'rollout'],
  [
    'inputs',
    'target-preflight',
    'template-package',
    'render',
    'render-check',
    'apply',
    'rollout',
    'smoke'
  ],
  [
    'inputs',
    'target-preflight',
    'template-package',
    'image-map',
    'render',
    'render-check',
    'apply',
    'rollout'
  ],
  [
    'inputs',
    'target-preflight',
    'template-package',
    'image-map',
    'render',
    'render-check',
    'apply',
    'rollout',
    'smoke'
  ]
];
const SIGNOFF_DECISION = 'signed_off';
const SIGNOFF_ALLOWED_FIELDS = new Set([
  'schema_version',
  'scope',
  'decision',
  'operator_run_id',
  'operator_identity',
  'signed_off_at',
  'target_profile',
  'release_id',
  'git_sha',
  'release_contract_digest',
  'subject'
]);
const SUBJECT_ALLOWED_FIELDS = new Set(['kind', 'sha256']);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCAL_SCHEME_RE = /^(?:file|local|source|git\+file):/i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|0\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[?(?:::|::1)\]?|host\.docker\.internal)(?::\d+)?(?:[/?#]|$)/i;
const HOST_DOCKER_INTERNAL_RE = /(^|[^A-Za-z0-9.-])host\.docker\.internal(?=$|[^A-Za-z0-9.-])/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const AGENTSMITH_SOURCE_PATH_RE = /\/home\/[^/]+\/works\/[^/]+\/agentsmith(?:\/|$)/i;
const SECRET_KEY_TERMS = [
  'password',
  'passwd',
  'pwd',
  'token',
  'secret',
  ['client', 'secret'].join('_'),
  'private_key',
  'kubeconfig',
  'access_key',
  ['api', 'key'].join('_')
];
const SECRET_KEY_RE = new RegExp(`(^|[_-])(${SECRET_KEY_TERMS.join('|')})([_-]|$)`, 'i');
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  new RegExp(`${['github', 'pat'].join('_')}_[A-Za-z0-9_]{20,}`),
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:postgres|mongodb|redis):\/\/[^:\s]+:[^@\s]+@/i,
  new RegExp(
    String.raw`\b(?:password|token|secret|${['client', 'secret'].join('_')})\s*[:=]\s*["']?[^"'\s]{8,}`,
    'i'
  ),
  /\bexecution[_ -]?ticket\b/i,
  /\bmanaged_credentials\b/i,
  /\bkubeconfig\b/i
];
const FORBIDDEN_OUT_OF_SCOPE_KEYS = new Set([
  'release_verdict',
  'verdict',
  'deploy_readiness',
  'release_readiness',
  'package_readiness',
  'registry_presence',
  'image_push',
  'image_pull',
  'image_mirror',
  'image_load',
  'image_import',
  'full_online_adoption',
  'product_flows',
  'product_flow_results',
  'signature_uri',
  'signature_sha256',
  'kubeconfig'
]);
const OUTPUT_REPORT = 'operator-signoff-intake-report.json';

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
  node scripts/verify-operator-signoff-intake.mjs \\
    --release-contract <json> \\
    --online-deployment-gate-report <json> \\
    --operator-signoff-intake <json> \\
    --target-profile existing_kubernetes/external_declared/online \\
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
      case '--online-deployment-gate-report':
        parsed.onlineDeploymentGateReport = nextValue();
        break;
      case '--operator-signoff-intake':
        parsed.operatorSignoffIntake = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
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

function extractOutputDirFromRawArgs(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.trim() === '' || value.startsWith('--')) {
      return undefined;
    }
    return value;
  }
  return undefined;
}

async function removeStaleReport(outputDir) {
  await fs.rm(path.join(outputDir, OUTPUT_REPORT), { force: true });
}

async function removeStaleReportFromRawArgs(argv) {
  const outputDir = extractOutputDirFromRawArgs(argv);
  if (!outputDir) {
    return;
  }
  await removeStaleReport(path.resolve(outputDir));
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function readJson(file, label) {
  let raw;
  try {
    raw = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      value: JSON.parse(raw.toString('utf8')),
      raw,
      input_sha256: digestBuffer(raw)
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
  const gitSha = requireString(value, label);
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

function requireBooleanFalse(value, label) {
  if (value !== false) {
    fail(`${label} must be false`);
  }
}

function assertAllowedFields(value, allowedFields, label) {
  for (const field of Object.keys(value)) {
    if (!allowedFields.has(field)) {
      fail(`${label}.${field} is not allowed`);
    }
  }
}

function scanUnsafeString(value, label, issues) {
  if (
    LOCAL_SCHEME_RE.test(value) ||
    LOCAL_URI_RE.test(value) ||
    LOCALHOST_URI_RE.test(value) ||
    HOST_DOCKER_INTERNAL_RE.test(value) ||
    ABSOLUTE_LOCAL_PATH_RE.test(value) ||
    RELATIVE_URI_RE.test(value) ||
    AGENTSMITH_SOURCE_PATH_RE.test(value)
  ) {
    issues.push(`${label} contains a local or source URI`);
  }

  if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
    issues.push(`${label} contains a secret-looking value`);
  }
}

function scanPayload(value, label, issues = []) {
  if (typeof value === 'string') {
    scanUnsafeString(value, label, issues);
    return issues;
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      scanPayload(item, `${label}[${index}]`, issues);
    });
    return issues;
  }

  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      const nestedLabel = `${label}.${key}`;
      if (FORBIDDEN_OUT_OF_SCOPE_KEYS.has(key)) {
        issues.push(`${nestedLabel} is out of scope for operator signoff intake`);
      }
      if (SECRET_KEY_RE.test(key)) {
        issues.push(`${nestedLabel} contains a secret-looking payload`);
      }
      scanPayload(nested, nestedLabel, issues);
    }
  }

  return issues;
}

function assertNoUnsafePayload(...payloads) {
  const issues = [];
  for (const [value, label] of payloads) {
    scanPayload(value, label, issues);
  }
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function parseTargetProfile(value) {
  const text = requireString(value, 'target_profile');
  const tuple = text.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }
  if (text !== SUPPORTED_TARGET_PROFILE) {
    fail(`operator-signoff-intake only accepts ${SUPPORTED_TARGET_PROFILE}`);
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateReleaseContract(input) {
  const contract = requireObject(input.value, 'release_contract');
  return {
    release_id: requireString(contract.release_id, 'release_contract.release_id'),
    git_sha: requireGitSha(contract.git_sha, 'release_contract.git_sha'),
    input_sha256: input.input_sha256
  };
}

function validateOperatorRunId(value, label) {
  const operatorRunId = requireString(value, label);
  if (!OPERATOR_RUN_ID_RE.test(operatorRunId)) {
    fail(`${label} must be a non-empty run identifier without whitespace`);
  }
  return operatorRunId;
}

function validateSignedOffAt(value) {
  const signedOffAt = requireString(value, 'operator_signoff_intake.signed_off_at');
  if (Number.isNaN(Date.parse(signedOffAt))) {
    fail('operator_signoff_intake.signed_off_at must be an ISO timestamp');
  }
  return signedOffAt;
}

function validateSignoffInput(input, { targetProfile, releaseIdentity, gateReportDigest }) {
  const signoff = requireObject(input.value, 'operator_signoff_intake');
  assertNoUnsafePayload([signoff, 'operator_signoff_intake']);
  assertAllowedFields(signoff, SIGNOFF_ALLOWED_FIELDS, 'operator_signoff_intake');

  assertStringEquals(
    signoff.schema_version,
    INPUT_SCHEMA,
    'operator_signoff_intake.schema_version'
  );
  assertStringEquals(signoff.scope, SCOPE, 'operator_signoff_intake.scope');
  assertStringEquals(signoff.decision, SIGNOFF_DECISION, 'operator_signoff_intake.decision');

  const operatorRunId = validateOperatorRunId(
    signoff.operator_run_id,
    'operator_signoff_intake.operator_run_id'
  );
  const operatorIdentity = requireString(
    signoff.operator_identity,
    'operator_signoff_intake.operator_identity'
  );
  const signedOffAt = validateSignedOffAt(signoff.signed_off_at);

  const signoffTargetProfile = requireString(
    signoff.target_profile,
    'operator_signoff_intake.target_profile'
  );
  if (signoffTargetProfile !== targetProfile.value) {
    fail('operator_signoff_intake.target_profile must match CLI target_profile');
  }

  const releaseId = requireString(signoff.release_id, 'operator_signoff_intake.release_id');
  const gitSha = requireGitSha(signoff.git_sha, 'operator_signoff_intake.git_sha');
  const releaseContractDigest = requireDigest(
    signoff.release_contract_digest,
    'operator_signoff_intake.release_contract_digest'
  );
  if (releaseId !== releaseIdentity.release_id) {
    fail('operator_signoff_intake.release_id must match release contract release_id');
  }
  if (gitSha !== releaseIdentity.git_sha) {
    fail('operator_signoff_intake.git_sha must match release contract git_sha');
  }
  if (releaseContractDigest !== releaseIdentity.input_sha256) {
    fail('operator_signoff_intake.release_contract_digest must match release contract raw sha256');
  }

  const subject = requireObject(signoff.subject, 'operator_signoff_intake.subject');
  assertAllowedFields(subject, SUBJECT_ALLOWED_FIELDS, 'operator_signoff_intake.subject');
  const subjectKind = assertStringEquals(
    subject.kind,
    ONLINE_DEPLOYMENT_GATE_SUBJECT_KIND,
    'operator_signoff_intake.subject.kind'
  );
  const subjectSha256 = requireDigest(
    subject.sha256,
    'operator_signoff_intake.subject.sha256'
  );
  if (subjectSha256 !== gateReportDigest) {
    fail('operator_signoff_intake.subject.sha256 must match online deployment gate report raw sha256');
  }

  return {
    decision: SIGNOFF_DECISION,
    operator_run_id: operatorRunId,
    operator_identity: operatorIdentity,
    signed_off_at: signedOffAt,
    target_profile: signoffTargetProfile,
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: releaseContractDigest,
    subject: {
      kind: subjectKind,
      sha256: subjectSha256
    }
  };
}

function validateTargetProfileObject(value, expected) {
  const targetProfile = requireObject(value, 'online_deployment_gate.target_profile');
  const declaredValue = requireString(
    targetProfile.value,
    'online_deployment_gate.target_profile.value'
  );
  const targetCluster = requireString(
    targetProfile.target_cluster,
    'online_deployment_gate.target_profile.target_cluster'
  );
  const substrateSource = requireString(
    targetProfile.substrate_source,
    'online_deployment_gate.target_profile.substrate_source'
  );
  const distribution = requireString(
    targetProfile.distribution,
    'online_deployment_gate.target_profile.distribution'
  );
  const computedValue = `${targetCluster}/${substrateSource}/${distribution}`;
  if (declaredValue !== computedValue) {
    fail('online_deployment_gate.target_profile.value must match target profile axes');
  }
  if (computedValue !== expected.value) {
    fail('online_deployment_gate.target_profile must match CLI target_profile');
  }
}

function validateCapabilityMap(value, targetProfile) {
  const capabilityMap = requireObject(value, 'online_deployment_gate.capability_map');
  const profileKeys = Object.keys(capabilityMap);
  if (profileKeys.length !== 1 || profileKeys[0] !== targetProfile.value) {
    fail('online_deployment_gate.capability_map must bind only the CLI target_profile');
  }

  const capability = requireObject(
    capabilityMap[targetProfile.value],
    `online_deployment_gate.capability_map.${targetProfile.value}`
  );
  assertAllowedFields(
    capability,
    ONLINE_DEPLOYMENT_GATE_CAPABILITY_FIELDS,
    `online_deployment_gate.capability_map.${targetProfile.value}`
  );

  for (const [field, expected] of Object.entries(ONLINE_DEPLOYMENT_GATE_CAPABILITY_EXPECTED)) {
    assertStringEquals(
      capability[field],
      expected,
      `online_deployment_gate.capability_map.${targetProfile.value}.${field}`
    );
  }
}

function validateGateSteps(value) {
  const steps = requireArray(value, 'online_deployment_gate.steps');
  if (steps.length === 0) {
    fail('online_deployment_gate.steps must not be empty');
  }

  const seenSteps = new Set();
  const stepNames = [];
  for (const [index, entry] of steps.entries()) {
    const label = `online_deployment_gate.steps[${index}]`;
    const step = requireObject(entry, label);
    assertAllowedFields(step, ONLINE_DEPLOYMENT_GATE_STEP_ALLOWED_FIELDS, label);
    const name = requireString(step.name, `${label}.name`);
    if (!ONLINE_DEPLOYMENT_GATE_ALLOWED_STEPS.has(name)) {
      fail(`${label}.name is not an online deployment gate producer step`);
    }
    if (seenSteps.has(name)) {
      fail(`online_deployment_gate.steps contains duplicate step: ${name}`);
    }
    seenSteps.add(name);
    stepNames.push(name);
    assertStringEquals(step.status, 'pass', `${label}.status`);

    const reportPaths = requireArray(step.report_paths, `${label}.report_paths`);
    if (reportPaths.length === 0) {
      fail(`${label}.report_paths must not be empty`);
    }
    for (const [pathIndex, reportPath] of reportPaths.entries()) {
      requireString(reportPath, `${label}.report_paths[${pathIndex}]`);
    }
  }

  for (const requiredStep of ['apply', 'rollout']) {
    if (!seenSteps.has(requiredStep)) {
      fail(`online_deployment_gate.steps must include ${requiredStep}`);
    }
  }

  const isCanonicalSequence = ONLINE_DEPLOYMENT_GATE_ALLOWED_STEP_SEQUENCES.some(
    (sequence) =>
      sequence.length === stepNames.length &&
      sequence.every((expectedStep, index) => stepNames[index] === expectedStep)
  );
  if (!isCanonicalSequence) {
    fail('online_deployment_gate.steps must match a canonical confirmed apply sequence');
  }

  return stepNames;
}

function validateOnlineGateReport(input, { targetProfile, releaseIdentity, signoff }) {
  const report = requireObject(input.value, 'online_deployment_gate');
  assertNoUnsafePayload([report, 'online_deployment_gate']);
  assertAllowedFields(report, ONLINE_DEPLOYMENT_GATE_ALLOWED_FIELDS, 'online_deployment_gate');

  assertStringEquals(report.schema, ONLINE_DEPLOYMENT_GATE_SCHEMA, 'online_deployment_gate.schema');
  assertStringEquals(report.scope, ONLINE_DEPLOYMENT_GATE_SCOPE, 'online_deployment_gate.scope');
  requireBooleanFalse(report.readiness, 'online_deployment_gate.readiness');
  assertStringEquals(report.status, 'pass', 'online_deployment_gate.status');
  assertStringEquals(report.mode, 'apply', 'online_deployment_gate.mode');

  const releaseId = requireString(report.release_id, 'online_deployment_gate.release_id');
  const gitSha = requireGitSha(report.git_sha, 'online_deployment_gate.git_sha');
  if (releaseId !== releaseIdentity.release_id) {
    fail('online_deployment_gate.release_id must match release contract release_id');
  }
  if (gitSha !== releaseIdentity.git_sha) {
    fail('online_deployment_gate.git_sha must match release contract git_sha');
  }

  const releaseContract = requireObject(
    report.release_contract,
    'online_deployment_gate.release_contract'
  );
  const gateReleaseContractDigest = requireDigest(
    releaseContract.input_sha256,
    'online_deployment_gate.release_contract.input_sha256'
  );
  if (gateReleaseContractDigest !== releaseIdentity.input_sha256) {
    fail('online_deployment_gate.release_contract.input_sha256 must match release contract raw sha256');
  }

  validateTargetProfileObject(report.target_profile, targetProfile);
  const operatorRunId = validateOperatorRunId(
    report.operator_run_id,
    'online_deployment_gate.operator_run_id'
  );
  if (operatorRunId !== signoff.operator_run_id) {
    fail('online_deployment_gate.operator_run_id must match operator signoff intake operator_run_id');
  }
  const steps = validateGateSteps(report.steps);
  validateCapabilityMap(report.capability_map, targetProfile);
  const generatedAt = requireString(report.generated_at, 'online_deployment_gate.generated_at');
  if (Number.isNaN(Date.parse(generatedAt))) {
    fail('online_deployment_gate.generated_at must be an ISO timestamp');
  }

  return {
    schema: ONLINE_DEPLOYMENT_GATE_SCHEMA,
    scope: ONLINE_DEPLOYMENT_GATE_SCOPE,
    status: 'pass',
    mode: 'apply',
    operator_run_id: operatorRunId,
    steps
  };
}

function buildReport({ releaseIdentity, targetProfile, signoff, gateSummary }) {
  return {
    schema: REPORT_SCHEMA,
    scope: SCOPE,
    readiness: false,
    status: 'pass',
    decision: signoff.decision,
    release_id: releaseIdentity.release_id,
    git_sha: releaseIdentity.git_sha,
    release_contract: {
      input_sha256: releaseIdentity.input_sha256
    },
    target_profile: targetProfile,
    operator_run_id: signoff.operator_run_id,
    operator_identity: signoff.operator_identity,
    signed_off_at: signoff.signed_off_at,
    subject: signoff.subject,
    online_deployment_gate: {
      schema: gateSummary.schema,
      scope: gateSummary.scope,
      status: gateSummary.status,
      mode: gateSummary.mode,
      operator_run_id: gateSummary.operator_run_id,
      steps: gateSummary.steps
    },
    generated_at: new Date().toISOString()
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, OUTPUT_REPORT);
  const tempFile = path.join(outputDir, `.operator-signoff-intake.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    await removeStaleReportFromRawArgs(argv);
    throw error;
  }
  if (args.help) {
    console.log(usage());
    return;
  }

  const outputDir = path.resolve(args.outputDir);
  await removeStaleReport(outputDir);

  const targetProfile = parseTargetProfile(args.targetProfile);
  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const releaseIdentity = validateReleaseContract(releaseContractInput);
  const gateReportInput = await readJson(
    args.onlineDeploymentGateReport,
    'online deployment gate report'
  );
  const signoffInput = await readJson(args.operatorSignoffIntake, 'operator signoff intake');
  const signoff = validateSignoffInput(signoffInput, {
    targetProfile,
    releaseIdentity,
    gateReportDigest: gateReportInput.input_sha256
  });
  const gateSummary = validateOnlineGateReport(gateReportInput, {
    targetProfile,
    releaseIdentity,
    signoff
  });
  const report = buildReport({
    releaseIdentity,
    targetProfile,
    signoff,
    gateSummary
  });
  assertNoUnsafePayload([report, 'operator_signoff_intake_report']);

  await writeReport(outputDir, report);
  console.log('PASS: operator signoff intake accepted focused binding');
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
