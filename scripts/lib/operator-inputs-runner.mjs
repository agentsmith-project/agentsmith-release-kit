import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PLAN_SCHEMA = 'agentsmith.operator-inputs-plan/v1';
const PLAN_SCOPE = 'operator_inputs_intake_only';
const INTERNAL_EXPECTED_SCHEMA = 'agentsmith.operator-inputs-plan-internal/v1';
const SUPPORTED_DEPLOYMENT_PATH = 'online/use_existing';
const SUPPORTED_MODE = 'apply';
const SUPPORTED_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const PLAN_DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const INTERNAL_DIR = '.release-kit-internal';
const OPERATOR_RELEASE_SCRIPT = path.join(REPO_ROOT, 'scripts/operator-release.sh');
const VERIFY_RELEASE_SCRIPT = path.join(REPO_ROOT, 'scripts/verify-release.sh');
const DEPLOYMENT_PATH_REPORT_FILE = 'deployment-path-report.json';
const DEPLOYMENT_PATH_FINALIZER_MANIFEST = 'deployment-path-finalizer-manifest.json';
const DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR = 'source-evidence';

const REQUIRED_INPUT_REFS = [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'substrate_truth',
  'target_prerequisites'
];
const OPTIONAL_INPUT_REFS = ['kubectl'];
const SUPPORTED_INPUT_REFS = new Set([...REQUIRED_INPUT_REFS, ...OPTIONAL_INPUT_REFS]);
const PRODUCER_REQUIRED_VALUE_FLAGS = new Set([
  '--release-contract',
  '--deploy-template-package',
  '--archive',
  '--target-profile',
  '--render-values',
  '--substrate-truth',
  '--target-prerequisites',
  '--namespace',
  '--output-dir',
  '--mode',
  '--confirm-apply',
  '--operator-run-id'
]);
const PRODUCER_OPTIONAL_VALUE_FLAGS = new Set([
  '--context',
  '--kubectl',
  '--timeout',
  '--smoke-url',
  '--expected-status',
  '--timeout-ms'
]);
const PRODUCER_BOOLEAN_FLAGS = new Set(['--allow-http', '--allow-localhost']);
const PRODUCER_VALUE_FLAGS = new Set([
  ...PRODUCER_REQUIRED_VALUE_FLAGS,
  ...PRODUCER_OPTIONAL_VALUE_FLAGS
]);
const PRODUCER_ALLOWED_FLAGS = new Set([...PRODUCER_VALUE_FLAGS, ...PRODUCER_BOOLEAN_FLAGS]);

class OperatorInputsRunnerError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

function fail(message, exitCode = 1) {
  throw new OperatorInputsRunnerError(message, exitCode);
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

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestJson(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

async function readJson(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  try {
    return JSON.parse(buffer.toString('utf8'));
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function fileDigest(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return digestBuffer(buffer);
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`);
  }
  return value;
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!PLAN_DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function optionalExpectedString(value, label) {
  if (value === null || value === undefined) {
    return undefined;
  }
  return requireString(value, label);
}

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') {
    fail(`${label} must be a boolean`);
  }
  return value;
}

function requireAbsolutePath(value, label) {
  const absolutePath = requireString(value, label);
  if (!path.isAbsolute(absolutePath)) {
    fail(`${label} must be an absolute path`);
  }
  return absolutePath;
}

async function requireFile(file, label) {
  const absolutePath = requireAbsolutePath(file, label);
  let stat;
  try {
    stat = await fs.stat(absolutePath);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a file`);
  }
  return absolutePath;
}

async function requireDirectory(file, label) {
  const absolutePath = requireAbsolutePath(file, label);
  let stat;
  try {
    stat = await fs.stat(absolutePath);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (!stat.isDirectory()) {
    fail(`${label} must point to a directory`);
  }
  return absolutePath;
}

async function realpathForExisting(file, label) {
  try {
    return await fs.realpath(file);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

async function lstatIfExists(absolutePath, label) {
  try {
    return await fs.lstat(absolutePath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return undefined;
    }
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function ensureInternalRuntimeRoot(operatorInputsRoot) {
  const internalPath = path.join(operatorInputsRoot, INTERNAL_DIR);
  let stat = await lstatIfExists(internalPath, 'operator-inputs internal output root');
  if (!stat) {
    try {
      await fs.mkdir(internalPath);
    } catch (error) {
      if (error.code !== 'EEXIST') {
        fail(`cannot create operator-inputs internal output root: ${error.message}`);
      }
    }
    stat = await lstatIfExists(internalPath, 'operator-inputs internal output root');
  }
  if (!stat) {
    fail('cannot create operator-inputs internal output root');
  }
  if (stat.isSymbolicLink()) {
    fail('operator-inputs internal output root must not be a symlink');
  }
  if (!stat.isDirectory()) {
    fail('operator-inputs internal output root must be a directory');
  }

  const realPath = await realpathForExisting(internalPath, 'operator-inputs internal output root');
  if (!isInsidePath(operatorInputsRoot, realPath)) {
    fail('operator-inputs internal output root resolves outside the operator-inputs package');
  }
  return realPath;
}

async function ensureDirectoryInsideInternalRoot({ internalRoot, targetDir, label }) {
  const absoluteDir = path.resolve(targetDir);
  if (!isInsidePath(internalRoot, absoluteDir)) {
    fail(`${label} must be inside operator-inputs internal output root`);
  }

  const relativePath = path.relative(internalRoot, absoluteDir);
  const segments = relativePath === '' ? [] : relativePath.split(path.sep);
  let current = internalRoot;

  for (const segment of segments) {
    current = path.join(current, segment);
    let stat = await lstatIfExists(current, label);
    if (!stat) {
      try {
        await fs.mkdir(current);
      } catch (error) {
        if (error.code !== 'EEXIST') {
          fail(`cannot create ${label}: ${error.message}`);
        }
      }
      stat = await lstatIfExists(current, label);
    }
    if (!stat) {
      fail(`cannot create ${label}`);
    }
    if (stat.isSymbolicLink()) {
      fail(`${label} must not contain a symlink`);
    }
    if (!stat.isDirectory()) {
      fail(`${label} must be a directory`);
    }

    const realPath = await realpathForExisting(current, label);
    if (!isInsidePath(internalRoot, realPath)) {
      fail(`${label} resolves outside operator-inputs internal output root`);
    }
  }

  const realTarget = await realpathForExisting(absoluteDir, label);
  if (!isInsidePath(internalRoot, realTarget)) {
    fail(`${label} resolves outside operator-inputs internal output root`);
  }
  return realTarget;
}

async function cleanupDeploymentPathOutputs(outputDir) {
  await fs.rm(path.join(outputDir, DEPLOYMENT_PATH_REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, DEPLOYMENT_PATH_FINALIZER_MANIFEST), { force: true });
  await fs.rm(path.join(outputDir, DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR), {
    recursive: true,
    force: true
  });
}

function expectedOutputDirs(internalRoot) {
  const outputBase = path.join(internalRoot, 'online-use-existing');
  return {
    onlineDeploymentGate: path.join(outputBase, 'online-deployment-gate'),
    deploymentPath: path.join(outputBase, 'deployment-path')
  };
}

function computePlanSha256(plan) {
  return digestJson({ ...plan, plan_sha256: null });
}

function assertPlanDigest(plan) {
  const declared = requireDigest(plan.plan_sha256, 'plan.plan_sha256');
  const actual = computePlanSha256(plan);
  if (declared !== actual) {
    fail('operator-inputs plan digest mismatch; regenerate the plan from operator-inputs');
  }
}

async function validatePlanEnvelope(plan) {
  if (plan.schema_version !== PLAN_SCHEMA) {
    fail(`operator-inputs plan schema_version must be ${PLAN_SCHEMA}`);
  }
  if (plan.scope !== PLAN_SCOPE) {
    fail(`operator-inputs plan scope must be ${PLAN_SCOPE}`);
  }
  if (plan.status !== 'pass') {
    fail('operator-inputs plan status must be pass');
  }
  if (Object.hasOwn(plan, 'readiness') || Object.hasOwn(plan, 'formal_verdict')) {
    fail('operator-inputs plan must not contain readiness or formal_verdict');
  }
  if (plan.argv_path_mode !== 'absolute') {
    fail('operator-inputs plan must use absolute argv paths');
  }

  const declaredRepoRoot = requireAbsolutePath(plan.repo_root, 'plan.repo_root');
  const repoRoot = await realpathForExisting(declaredRepoRoot, 'plan.repo_root');
  if (declaredRepoRoot !== repoRoot) {
    fail('operator-inputs plan repo_root must be canonical');
  }
  const expectedRepoRoot = await realpathForExisting(REPO_ROOT, 'release-kit repo root');
  if (repoRoot !== expectedRepoRoot) {
    fail('operator-inputs plan repo_root does not match this release-kit checkout');
  }

  const declaredOperatorInputsRoot = requireAbsolutePath(
    plan.operator_inputs_root,
    'plan.operator_inputs_root'
  );
  const operatorInputsRoot = await realpathForExisting(
    declaredOperatorInputsRoot,
    'plan.operator_inputs_root'
  );
  if (declaredOperatorInputsRoot !== operatorInputsRoot) {
    fail('operator-inputs plan operator_inputs_root must be canonical');
  }
  await requireDirectory(operatorInputsRoot, 'plan.operator_inputs_root');
  const internalRoot = await ensureInternalRuntimeRoot(operatorInputsRoot);
  assertPlanDigest(plan);

  return {
    internalRoot,
    operatorInputsRoot
  };
}

async function validatePackageRefs(plan) {
  const packageInfo = requireObject(plan.package, 'plan.package');
  const manifestPath = await requireFile(packageInfo.manifest_path, 'plan.package.manifest_path');
  const canonicalManifestPath = await realpathForExisting(
    manifestPath,
    'plan.package.manifest_path'
  );
  if (manifestPath !== canonicalManifestPath) {
    fail('plan.package.manifest_path must be canonical');
  }
  requireString(packageInfo.manifest_relative_path, 'plan.package.manifest_relative_path');
  const declaredManifestDigest = requireDigest(
    packageInfo.manifest_sha256,
    'plan.package.manifest_sha256'
  );
  const actualManifestDigest = await fileDigest(canonicalManifestPath, 'operator-inputs manifest');
  if (declaredManifestDigest !== actualManifestDigest) {
    fail('operator-inputs manifest digest changed after plan generation');
  }
  const operatorManifest = requireObject(
    await readJson(canonicalManifestPath, 'operator-inputs manifest'),
    'operator-inputs manifest'
  );

  const refs = requireObject(plan.input_refs, 'plan.input_refs');
  for (const key of Object.keys(refs)) {
    if (!SUPPORTED_INPUT_REFS.has(key)) {
      fail(`operator-inputs --run does not support input ref: ${key}`);
    }
  }
  for (const key of REQUIRED_INPUT_REFS) {
    const ref = requireObject(refs[key], `plan.input_refs.${key}`);
    if (ref.kind !== 'file') {
      fail(`plan.input_refs.${key} ref type must be file`);
    }
    const absolutePath = await requireFile(ref.absolute_path, `plan.input_refs.${key}.absolute_path`);
    const canonicalPath = await realpathForExisting(
      absolutePath,
      `plan.input_refs.${key}.absolute_path`
    );
    if (absolutePath !== canonicalPath) {
      fail(`plan.input_refs.${key}.absolute_path must be canonical`);
    }
    const actual = await fileDigest(canonicalPath, `plan.input_refs.${key}`);
    if (requireDigest(ref.sha256, `plan.input_refs.${key}.sha256`) !== actual) {
      fail(`input ref digest changed after plan generation: ${key}`);
    }
    ref.absolute_path = canonicalPath;
  }
  if (refs.kubectl) {
    const ref = requireObject(refs.kubectl, 'plan.input_refs.kubectl');
    if (ref.kind !== 'file') {
      fail('plan.input_refs.kubectl ref type must be file');
    }
    const absolutePath = await requireFile(ref.absolute_path, 'plan.input_refs.kubectl.absolute_path');
    const canonicalPath = await realpathForExisting(
      absolutePath,
      'plan.input_refs.kubectl.absolute_path'
    );
    if (absolutePath !== canonicalPath) {
      fail('plan.input_refs.kubectl.absolute_path must be canonical');
    }
    const actual = await fileDigest(canonicalPath, 'plan.input_refs.kubectl');
    if (requireDigest(ref.sha256, 'plan.input_refs.kubectl.sha256') !== actual) {
      fail('input ref digest changed after plan generation: kubectl');
    }
    ref.absolute_path = canonicalPath;
  }
  return {
    refs,
    operatorManifest
  };
}

function parseProducerFlags(argv, label) {
  const values = new Map();
  const booleans = new Set();

  for (let index = 3; index < argv.length; index += 1) {
    const flag = argv[index];
    if (typeof flag !== 'string' || !flag.startsWith('--')) {
      fail(`${label} producer argv contains unexpected positional argument: ${flag}`);
    }
    if (!PRODUCER_ALLOWED_FLAGS.has(flag)) {
      fail(`${label} producer argv contains unsupported flag: ${flag}`);
    }

    if (PRODUCER_VALUE_FLAGS.has(flag)) {
      if (values.has(flag)) {
        fail(`${label} producer argv contains duplicate flag: ${flag}`);
      }
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        fail(`${label} producer argv missing value after ${flag}`);
      }
      values.set(flag, value);
      index += 1;
      continue;
    }

    if (booleans.has(flag)) {
      fail(`${label} producer argv contains duplicate flag: ${flag}`);
    }
    booleans.add(flag);
  }

  for (const flag of PRODUCER_REQUIRED_VALUE_FLAGS) {
    if (!values.has(flag)) {
      fail(`${label} producer argv must include ${flag}`);
    }
  }

  return {
    value(flag) {
      return values.get(flag);
    },
    has(flag) {
      return values.has(flag) || booleans.has(flag);
    },
    boolean(flag) {
      return booleans.has(flag);
    }
  };
}

function assertBoundValue(parsed, flag, expected, label) {
  const actual = parsed.value(flag);
  if (actual !== expected) {
    fail(`${label} ${flag} must match plan expected value`);
  }
  return actual;
}

function assertOptionalBoundValue(parsed, flag, expected, label) {
  if (expected === undefined) {
    if (parsed.has(flag)) {
      fail(`${label} ${flag} is not modeled by the operator-inputs plan`);
    }
    return undefined;
  }
  return assertBoundValue(parsed, flag, expected, label);
}

function assertOptionalBoundBoolean(parsed, flag, expected, label) {
  const actual = parsed.boolean(flag);
  if (actual !== expected) {
    fail(`${label} ${flag} must match plan expected value`);
  }
}

function optionalManifestString(manifest, key, label) {
  if (!Object.hasOwn(manifest, key)) {
    return undefined;
  }
  return requireString(manifest[key], label);
}

function optionalManifestScalarString(manifest, key) {
  if (!Object.hasOwn(manifest, key)) {
    return undefined;
  }
  return String(manifest[key]);
}

function validateInternalExpected(plan, internalRoot, operatorManifest) {
  const internal = requireObject(plan._internal, 'plan._internal');
  const expected = requireObject(internal.expected, 'plan._internal.expected');
  if (expected.schema_version !== INTERNAL_EXPECTED_SCHEMA) {
    fail(`plan._internal.expected.schema_version must be ${INTERNAL_EXPECTED_SCHEMA}`);
  }
  if (expected.deployment_path !== SUPPORTED_DEPLOYMENT_PATH) {
    fail(`plan._internal.expected.deployment_path must be ${SUPPORTED_DEPLOYMENT_PATH}`);
  }
  if (expected.target_profile !== SUPPORTED_TARGET_PROFILE) {
    fail(`plan._internal.expected.target_profile must be ${SUPPORTED_TARGET_PROFILE}`);
  }
  if (expected.mode !== SUPPORTED_MODE) {
    fail(`plan._internal.expected.mode must be ${SUPPORTED_MODE}`);
  }

  const outputDirs = requireObject(expected.output_dirs, 'plan._internal.expected.output_dirs');
  const canonicalOutputDirs = expectedOutputDirs(internalRoot);
  if (outputDirs.online_deployment_gate !== canonicalOutputDirs.onlineDeploymentGate) {
    fail('plan._internal.expected.output_dirs.online_deployment_gate must be the internal expected dir');
  }
  if (outputDirs.deployment_path !== canonicalOutputDirs.deploymentPath) {
    fail('plan._internal.expected.output_dirs.deployment_path must be the internal expected dir');
  }

  const smoke = requireObject(expected.smoke, 'plan._internal.expected.smoke');
  const namespace = requireString(expected.namespace, 'plan._internal.expected.namespace');
  const context = optionalExpectedString(expected.context, 'plan._internal.expected.context');
  const operatorRunId = requireString(
    expected.operator_run_id,
    'plan._internal.expected.operator_run_id'
  );
  const expectedSmoke = {
    timeout: optionalExpectedString(smoke.timeout, 'plan._internal.expected.smoke.timeout'),
    smokeUrl: optionalExpectedString(smoke.smoke_url, 'plan._internal.expected.smoke.smoke_url'),
    expectedStatus: optionalExpectedString(
      smoke.expected_status,
      'plan._internal.expected.smoke.expected_status'
    ),
    timeoutMs: optionalExpectedString(
      smoke.timeout_ms,
      'plan._internal.expected.smoke.timeout_ms'
    ),
    allowHttp: requireBoolean(smoke.allow_http, 'plan._internal.expected.smoke.allow_http'),
    allowLocalhost: requireBoolean(
      smoke.allow_localhost,
      'plan._internal.expected.smoke.allow_localhost'
    )
  };

  if (operatorManifest.deployment_path !== expected.deployment_path) {
    fail('plan._internal.expected.deployment_path must match operator-inputs manifest');
  }
  if ((operatorManifest.mode || 'server-dry-run') !== expected.mode) {
    fail('plan._internal.expected.mode must match operator-inputs manifest');
  }
  if (operatorManifest.namespace !== namespace) {
    fail('plan._internal.expected.namespace must match operator-inputs manifest');
  }
  const manifestContext = optionalManifestString(
    operatorManifest,
    'context',
    'operator-inputs manifest.context'
  );
  if (manifestContext !== context) {
    fail('plan._internal.expected.context must match operator-inputs manifest');
  }
  const deployConfirmation = requireObject(
    operatorManifest.deploy_confirmation,
    'operator-inputs manifest.deploy_confirmation'
  );
  if (
    requireString(
      deployConfirmation.operator_run_id,
      'operator-inputs manifest.deploy_confirmation.operator_run_id'
    ) !== operatorRunId
  ) {
    fail('plan._internal.expected.operator_run_id must match operator-inputs manifest');
  }
  if (
    optionalManifestString(operatorManifest, 'timeout', 'operator-inputs manifest.timeout') !==
    expectedSmoke.timeout
  ) {
    fail('plan._internal.expected.smoke.timeout must match operator-inputs manifest');
  }
  if (
    optionalManifestString(operatorManifest, 'smoke_url', 'operator-inputs manifest.smoke_url') !==
    expectedSmoke.smokeUrl
  ) {
    fail('plan._internal.expected.smoke.smoke_url must match operator-inputs manifest');
  }
  if (optionalManifestScalarString(operatorManifest, 'expected_status') !== expectedSmoke.expectedStatus) {
    fail('plan._internal.expected.smoke.expected_status must match operator-inputs manifest');
  }
  if (optionalManifestScalarString(operatorManifest, 'timeout_ms') !== expectedSmoke.timeoutMs) {
    fail('plan._internal.expected.smoke.timeout_ms must match operator-inputs manifest');
  }
  if ((operatorManifest.allow_http === true) !== expectedSmoke.allowHttp) {
    fail('plan._internal.expected.smoke.allow_http must match operator-inputs manifest');
  }
  if ((operatorManifest.allow_localhost === true) !== expectedSmoke.allowLocalhost) {
    fail('plan._internal.expected.smoke.allow_localhost must match operator-inputs manifest');
  }

  return {
    deploymentPath: expected.deployment_path,
    targetProfile: expected.target_profile,
    mode: expected.mode,
    namespace,
    context,
    operatorRunId,
    outputDirs: canonicalOutputDirs,
    smoke: expectedSmoke
  };
}

async function validateFacadeArgv(plan) {
  const argv = plan.facade_argv;
  if (!Array.isArray(argv) || argv.length !== 4) {
    fail('plan.facade_argv must replay the operator-inputs intake command');
  }
  if (argv[0] !== 'bash' || argv[1] !== OPERATOR_RELEASE_SCRIPT || argv[2] !== '--operator-inputs') {
    fail('plan.facade_argv must replay through scripts/operator-release.sh --operator-inputs');
  }
  const replayInput = requireAbsolutePath(argv[3], 'plan.facade_argv operator input');
  let stat;
  try {
    stat = await fs.lstat(replayInput);
  } catch (error) {
    fail(`cannot read plan.facade_argv operator input: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('plan.facade_argv operator input must not be a symlink');
  }
  if (!stat.isFile() && !stat.isDirectory()) {
    fail('plan.facade_argv operator input must be a file or directory');
  }
}

function validateUnsupportedScope(plan) {
  if (plan.deployment_path !== SUPPORTED_DEPLOYMENT_PATH || plan.mode !== SUPPORTED_MODE) {
    fail(
      `operator-inputs --run currently supports only ${SUPPORTED_DEPLOYMENT_PATH} with mode ${SUPPORTED_MODE}`
    );
  }
}

async function validateProducerStep(plan, refs, expected) {
  if (!Array.isArray(plan.producer_argv) || plan.producer_argv.length !== 1) {
    fail('operator-inputs --run currently supports exactly one producer step');
  }
  const step = requireObject(plan.producer_argv[0], 'plan.producer_argv[0]');
  if (step.name !== 'online-deployment-gate') {
    fail(`operator-inputs --run does not support producer step: ${step.name}`);
  }
  const argv = step.argv;
  if (!Array.isArray(argv) || argv.length < 4) {
    fail('online-deployment-gate producer argv is invalid');
  }
  if (argv[0] !== 'bash' || argv[1] !== VERIFY_RELEASE_SCRIPT || argv[2] !== '--online-deployment-gate') {
    fail('online-deployment-gate producer argv must call verify-release.sh --online-deployment-gate');
  }

  const parsed = parseProducerFlags(argv, step.name);
  assertBoundValue(parsed, '--release-contract', refs.release_contract.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--deploy-template-package',
    refs.deploy_template_package.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--archive', refs.deploy_template_archive.absolute_path, step.name);
  assertBoundValue(parsed, '--render-values', refs.render_values.absolute_path, step.name);
  assertBoundValue(parsed, '--substrate-truth', refs.substrate_truth.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--target-prerequisites',
    refs.target_prerequisites.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--target-profile', expected.targetProfile, step.name);
  assertBoundValue(parsed, '--namespace', expected.namespace, step.name);
  assertBoundValue(parsed, '--output-dir', expected.outputDirs.onlineDeploymentGate, step.name);
  assertBoundValue(parsed, '--mode', expected.mode, step.name);
  assertBoundValue(parsed, '--confirm-apply', expected.targetProfile, step.name);
  assertBoundValue(parsed, '--operator-run-id', expected.operatorRunId, step.name);
  assertOptionalBoundValue(parsed, '--context', expected.context, step.name);
  assertOptionalBoundValue(parsed, '--kubectl', refs.kubectl?.absolute_path, step.name);
  assertOptionalBoundValue(parsed, '--timeout', expected.smoke.timeout, step.name);
  assertOptionalBoundValue(parsed, '--smoke-url', expected.smoke.smokeUrl, step.name);
  assertOptionalBoundValue(parsed, '--expected-status', expected.smoke.expectedStatus, step.name);
  assertOptionalBoundValue(parsed, '--timeout-ms', expected.smoke.timeoutMs, step.name);
  assertOptionalBoundBoolean(parsed, '--allow-http', expected.smoke.allowHttp, step.name);
  assertOptionalBoundBoolean(parsed, '--allow-localhost', expected.smoke.allowLocalhost, step.name);

  const outputDir = requireAbsolutePath(
    parsed.value('--output-dir'),
    'online-deployment-gate output dir'
  );

  return {
    step,
    outputDir,
    reportPath: path.join(outputDir, 'online-deployment-gate-report.json')
  };
}

function runCommand(argv, label) {
  const result = spawnSync(argv[0], argv.slice(1), {
    cwd: REPO_ROOT,
    stdio: 'inherit',
    env: process.env
  });
  if (result.error) {
    fail(`${label} failed to start: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const status = result.status === null ? `signal ${result.signal}` : `exit code ${result.status}`;
    fail(`${label} failed with ${status}`, result.status || 1);
  }
}

async function requireGeneratedReport(file, label) {
  await requireFile(file, label);
  const report = await readJson(file, label);
  const object = requireObject(report, label);
  if (object.status !== 'pass') {
    fail(`${label}.status must be pass`);
  }
  return object;
}

export async function runOperatorInputsPlan({ planPath } = {}) {
  if (!planPath) {
    fail('--plan is required', 2);
  }
  const resolvedPlanPath = path.resolve(planPath);
  await requireFile(resolvedPlanPath, 'operator-inputs plan');
  const canonicalPlanPath = await realpathForExisting(resolvedPlanPath, 'operator-inputs plan');
  if (resolvedPlanPath !== canonicalPlanPath) {
    fail('operator-inputs plan path must be canonical');
  }

  const plan = requireObject(
    await readJson(canonicalPlanPath, 'operator-inputs plan'),
    'operator-inputs plan'
  );
  const envelope = await validatePlanEnvelope(plan);
  if (!isInsidePath(envelope.internalRoot, canonicalPlanPath)) {
    fail('operator-inputs plan path must be inside operator-inputs internal output root');
  }
  validateUnsupportedScope(plan);
  await validateFacadeArgv(plan);
  const { refs, operatorManifest } = await validatePackageRefs(plan);
  const expected = validateInternalExpected(plan, envelope.internalRoot, operatorManifest);
  await ensureDirectoryInsideInternalRoot({
    internalRoot: envelope.internalRoot,
    targetDir: path.dirname(expected.outputDirs.onlineDeploymentGate),
    label: 'operator-inputs deployment output base'
  });
  expected.outputDirs.onlineDeploymentGate = await ensureDirectoryInsideInternalRoot({
    internalRoot: envelope.internalRoot,
    targetDir: expected.outputDirs.onlineDeploymentGate,
    label: 'online-deployment-gate output dir'
  });
  expected.outputDirs.deploymentPath = await ensureDirectoryInsideInternalRoot({
    internalRoot: envelope.internalRoot,
    targetDir: expected.outputDirs.deploymentPath,
    label: 'deployment-path output dir'
  });
  await cleanupDeploymentPathOutputs(expected.outputDirs.deploymentPath);
  const producer = await validateProducerStep(plan, refs, expected);

  runCommand(producer.step.argv, 'operator-inputs producer online-deployment-gate');
  await requireGeneratedReport(producer.reportPath, 'online-deployment-gate report');

  const finalizerArgv = [
    'bash',
    VERIFY_RELEASE_SCRIPT,
    '--deployment-path',
    '--operator-path',
    SUPPORTED_DEPLOYMENT_PATH,
    '--release-contract',
    refs.release_contract.absolute_path,
    '--deploy-template-package',
    refs.deploy_template_package.absolute_path,
    '--online-deployment-gate-report',
    producer.reportPath,
    '--output-dir',
    expected.outputDirs.deploymentPath
  ];
  runCommand(finalizerArgv, 'operator-inputs deployment-path finalizer');

  const deploymentPathReport = path.join(expected.outputDirs.deploymentPath, DEPLOYMENT_PATH_REPORT_FILE);
  const finalizerManifest = path.join(
    expected.outputDirs.deploymentPath,
    DEPLOYMENT_PATH_FINALIZER_MANIFEST
  );
  await requireGeneratedReport(deploymentPathReport, 'deployment-path report');
  await requireFile(finalizerManifest, 'deployment-path finalizer manifest');

  return {
    planPath: canonicalPlanPath,
    producerReportPath: producer.reportPath,
    deploymentPathReport,
    finalizerManifest,
    sourceEvidenceDir: path.join(
      expected.outputDirs.deploymentPath,
      DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR
    )
  };
}

export { OperatorInputsRunnerError };
