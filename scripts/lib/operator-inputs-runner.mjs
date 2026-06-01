import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PLAN_SCHEMA = 'agentsmith.operator-inputs-plan/v1';
const PLAN_SCOPE = 'operator_inputs_intake_only';
const INTERNAL_EXPECTED_SCHEMA = 'agentsmith.operator-inputs-plan-internal/v1';
const SUPPORTED_MODE = 'apply';
const ONLINE_USE_EXISTING_PATH = 'online/use_existing';
const ONLINE_INSTALL_SUBSTRATES_PATH = 'online/install_substrates';
const AIRGAP_USE_EXISTING_PATH = 'airgap/use_existing';
const AIRGAP_INSTALL_SUBSTRATES_PATH = 'airgap/install_substrates';
const SUPPORTED_DEPLOYMENT_PATHS = new Set([
  ONLINE_USE_EXISTING_PATH,
  ONLINE_INSTALL_SUBSTRATES_PATH,
  AIRGAP_USE_EXISTING_PATH
]);
const CLEANUP_DEPLOYMENT_PATHS = new Set([
  ...SUPPORTED_DEPLOYMENT_PATHS,
  AIRGAP_INSTALL_SUBSTRATES_PATH
]);
const TARGET_PROFILE_BY_DEPLOYMENT_PATH = new Map([
  [ONLINE_USE_EXISTING_PATH, 'existing_kubernetes/external_declared/online'],
  [ONLINE_INSTALL_SUBSTRATES_PATH, 'existing_kubernetes/kit_installed/online'],
  [AIRGAP_USE_EXISTING_PATH, 'existing_kubernetes/external_declared/airgap']
]);
const PLAN_DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const INTERNAL_DIR = '.release-kit-internal';
const OPERATOR_RELEASE_SCRIPT = path.join(REPO_ROOT, 'scripts/operator-release.sh');
const VERIFY_RELEASE_SCRIPT = path.join(REPO_ROOT, 'scripts/verify-release.sh');
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const DEPLOYMENT_PATH_REPORT_FILE = 'deployment-path-report.json';
const DEPLOYMENT_PATH_FINALIZER_MANIFEST = 'deployment-path-finalizer-manifest.json';
const DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR = 'source-evidence';
const WINDOWS_DRIVE_RE = /^[A-Za-z]:[\\/]/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i;

const COMMON_INPUT_REFS = [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'substrate_truth',
  'target_prerequisites'
];
const INSTALL_INPUT_REFS = [
  'substrate_pack_manifest',
  'substrate_install_inputs',
  'kubectl',
  'routability_probe'
];
const AIRGAP_PACKAGE_INPUT_REFS = [
  'airgap_bundle',
  'airgap_bundle_manifest'
];
const AIRGAP_APPLY_INPUT_REFS = [
  'archive_probe',
  'image_loader'
];
const AIRGAP_USE_EXISTING_INPUT_REFS = [
  ...AIRGAP_PACKAGE_INPUT_REFS,
  ...AIRGAP_APPLY_INPUT_REFS
];
const DIRECTORY_INPUT_REFS = new Set(['airgap_bundle']);
const COMMAND_INPUT_REFS = new Set([
  'kubectl',
  'routability_probe',
  'archive_probe',
  'image_loader'
]);
const MANIFEST_FILE_REF_FIELDS = new Set([
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'substrate_truth',
  'target_prerequisites',
  'airgap_bundle_manifest',
  'substrate_pack_manifest',
  'substrate_install_inputs'
]);
const MANIFEST_DIRECTORY_REF_FIELDS = new Set(['airgap_bundle']);
const MANIFEST_COMMAND_REF_FIELDS = new Set([
  'kubectl',
  'registry_probe',
  'routability_probe',
  'archive_probe',
  'image_loader'
]);
const AIRGAP_BUNDLE_COMPONENT_REF_KEYS = [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive'
];
const SUPPORTED_INPUT_REFS = new Set([
  ...COMMON_INPUT_REFS,
  ...INSTALL_INPUT_REFS,
  ...AIRGAP_USE_EXISTING_INPUT_REFS,
  'kubectl'
]);
const ONLINE_GATE_REQUIRED_VALUE_FLAGS = new Set([
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
const ONLINE_GATE_OPTIONAL_VALUE_FLAGS = new Set([
  '--context',
  '--kubectl',
  '--timeout',
  '--smoke-url',
  '--expected-status',
  '--timeout-ms',
  '--substrate-pack-manifest',
  '--routability-probe'
]);
const ONLINE_GATE_BOOLEAN_FLAGS = new Set(['--allow-http', '--allow-localhost']);
const SUBSTRATE_INSTALL_REQUIRED_VALUE_FLAGS = new Set([
  '--release-contract',
  '--deploy-template-package',
  '--target-profile',
  '--substrate-pack-manifest',
  '--substrate-install-inputs',
  '--target-prerequisites',
  '--namespace',
  '--output-dir',
  '--mode',
  '--context',
  '--kubectl',
  '--confirm-substrate-install',
  '--confirm-install-parameters',
  '--operator-run-id'
]);
const SUBSTRATE_INSTALL_OPTIONAL_VALUE_FLAGS = new Set();
const SUBSTRATE_INSTALL_BOOLEAN_FLAGS = new Set();
const AIRGAP_CONSUME_REQUIRED_VALUE_FLAGS = new Set([
  '--bundle-root',
  '--bundle-manifest',
  '--render-values',
  '--substrate-truth',
  '--target-prerequisites',
  '--namespace',
  '--output-dir',
  '--mode',
  '--context',
  '--kubectl',
  '--archive-probe',
  '--image-loader',
  '--smoke-url',
  '--confirm-apply',
  '--operator-run-id'
]);
const AIRGAP_CONSUME_OPTIONAL_VALUE_FLAGS = new Set([
  '--timeout',
  '--expected-status',
  '--timeout-ms'
]);
const AIRGAP_CONSUME_BOOLEAN_FLAGS = new Set(['--allow-http', '--allow-localhost']);

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

async function digestDirectory(rootDir) {
  const entries = [];

  async function walk(absoluteDir, relativeDir = '') {
    const dirents = await fs.readdir(absoluteDir, { withFileTypes: true });
    for (const dirent of dirents.sort((a, b) => a.name.localeCompare(b.name))) {
      const relativePath = relativeDir ? `${relativeDir}/${dirent.name}` : dirent.name;
      const absolutePath = path.join(absoluteDir, dirent.name);
      if (dirent.isSymbolicLink()) {
        fail(`directory input contains a symlink: ${relativePath}`);
      }
      if (dirent.isDirectory()) {
        entries.push({ path: relativePath, type: 'directory' });
        await walk(absolutePath, relativePath);
        continue;
      }
      if (!dirent.isFile()) {
        fail(`directory input contains a non-file entry: ${relativePath}`);
      }
      entries.push({
        path: relativePath,
        type: 'file',
        sha256: await fileDigest(absolutePath, relativePath)
      });
    }
  }

  await walk(rootDir);
  return {
    entry_count: entries.length,
    tree_sha256: digestJson(entries)
  };
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

function isReservedOperatorOutputPath(relativePath) {
  const normalized = path.posix.normalize(relativePath.replace(/\\/g, '/'));
  return normalized === INTERNAL_DIR || normalized.startsWith(`${INTERNAL_DIR}/`);
}

function assertNotReservedOperatorOutputPath(relativePath, label) {
  if (isReservedOperatorOutputPath(relativePath)) {
    fail(`${label} must not point into reserved operator-inputs output tree: ${INTERNAL_DIR}`);
  }
}

function packageRelativePath(operatorInputsRoot, absolutePath) {
  const relative = path.relative(operatorInputsRoot, absolutePath).split(path.sep).join('/');
  if (relative === '' || relative.startsWith('../') || relative === '..' || path.isAbsolute(relative)) {
    fail(`resolved path escaped operator-inputs package: ${absolutePath}`);
  }
  return relative;
}

function assertAbsolutePackagePathNotReserved(operatorInputsRoot, absolutePath, label) {
  assertNotReservedOperatorOutputPath(packageRelativePath(operatorInputsRoot, absolutePath), label);
}

function assertPackageRelativeInput(value, label) {
  const raw = requireString(value, label);
  if (raw.includes('\0')) {
    fail(`${label} contains an invalid path byte`);
  }
  if (raw.startsWith('/') || WINDOWS_DRIVE_RE.test(raw) || URI_SCHEME_RE.test(raw)) {
    fail(`${label} must be a package-relative path`);
  }
  const normalized = path.posix.normalize(raw.replace(/\\/g, '/'));
  if (
    normalized === '.' ||
    normalized.startsWith('../') ||
    normalized === '..' ||
    normalized.split('/').includes('..')
  ) {
    fail(`${label} escapes the operator-inputs package`);
  }
  assertNotReservedOperatorOutputPath(normalized, label);
  return normalized;
}

async function resolvePackagePath({ operatorInputsRoot, value, label, kind }) {
  const relativePath = assertPackageRelativeInput(value, label);
  const requested = path.resolve(operatorInputsRoot, relativePath);
  let lstat;
  try {
    lstat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (lstat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (kind === 'file' && !lstat.isFile()) {
    fail(`${label} must point to a file`);
  }
  if (kind === 'directory' && !lstat.isDirectory()) {
    fail(`${label} must point to a directory`);
  }

  const realPath = await realpathForExisting(requested, label);
  if (!isInsidePath(operatorInputsRoot, realPath)) {
    fail(`${label} resolves outside the operator-inputs package`);
  }
  const canonicalRelativePath = packageRelativePath(operatorInputsRoot, realPath);
  assertNotReservedOperatorOutputPath(canonicalRelativePath, label);

  return {
    absolutePath: realPath,
    path: canonicalRelativePath
  };
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

function deploymentPathOutputSlug(deploymentPath) {
  return deploymentPath.replace(/[/_]+/g, '-');
}

function expectedOutputDirs(internalRoot, deploymentPath) {
  const outputBase = path.join(internalRoot, deploymentPathOutputSlug(deploymentPath));
  const airgapConsumeRehearsal = path.join(outputBase, 'airgap-consume-rehearsal');
  return {
    substrateInstall: path.join(outputBase, 'substrate-install'),
    onlineDeploymentGate: path.join(outputBase, 'online-deployment-gate'),
    airgapConsumeRehearsal,
    airgapBundleCheck: path.join(airgapConsumeRehearsal, 'airgap-bundle-check'),
    airgapDeploymentGate: path.join(airgapConsumeRehearsal, 'airgap-deployment-gate'),
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

async function validatePlanPrecleanEnvelope(plan, canonicalPlanPath) {
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
  if (!isInsidePath(internalRoot, canonicalPlanPath)) {
    fail('operator-inputs plan path must be inside operator-inputs internal output root');
  }

  return {
    internalRoot,
    operatorInputsRoot
  };
}

function isInstallSubstratesPath(deploymentPath) {
  return deploymentPath === ONLINE_INSTALL_SUBSTRATES_PATH;
}

function isAirgapUseExistingPath(deploymentPath) {
  return deploymentPath === AIRGAP_USE_EXISTING_PATH;
}

function isAirgapInstallSubstratesPath(deploymentPath) {
  return deploymentPath === AIRGAP_INSTALL_SUBSTRATES_PATH;
}

function inputRefsForDeploymentPath(deploymentPath, mode) {
  const required = [...COMMON_INPUT_REFS];
  const optional = [];
  if (isInstallSubstratesPath(deploymentPath)) {
    required.push(...INSTALL_INPUT_REFS);
  } else if (isAirgapUseExistingPath(deploymentPath)) {
    required.push(...AIRGAP_PACKAGE_INPUT_REFS, 'kubectl');
    if (mode === SUPPORTED_MODE) {
      required.push(...AIRGAP_APPLY_INPUT_REFS);
    }
  } else if (isAirgapInstallSubstratesPath(deploymentPath)) {
    required.push('substrate_pack_manifest', 'substrate_install_inputs', 'kubectl');
    required.push(...AIRGAP_PACKAGE_INPUT_REFS);
    if (mode === SUPPORTED_MODE) {
      required.push(...AIRGAP_APPLY_INPUT_REFS);
    }
  } else {
    optional.push('kubectl');
  }
  return {
    required,
    allowed: new Set([...required, ...optional])
  };
}

async function validateRefPackageBinding({ ref, key, operatorInputsRoot }) {
  if (!isInsidePath(operatorInputsRoot, ref.absolute_path)) {
    fail(`plan.input_refs.${key}.absolute_path must resolve inside operator-inputs package`);
  }
  const declaredRelativePath = assertPackageRelativeInput(
    ref.path,
    `plan.input_refs.${key}.path`
  );
  const resolved = await resolvePackagePath({
    operatorInputsRoot,
    value: declaredRelativePath,
    label: `plan.input_refs.${key}.path`,
    kind: ref.kind
  });
  if (resolved.absolutePath !== ref.absolute_path) {
    fail(`plan.input_refs.${key}.path must resolve to plan.input_refs.${key}.absolute_path`);
  }
  if (resolved.path !== packageRelativePath(operatorInputsRoot, ref.absolute_path)) {
    fail(`plan.input_refs.${key}.path must be canonical package-relative path`);
  }
}

async function validateFileRef(refs, key, operatorInputsRoot) {
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
  if (!isInsidePath(operatorInputsRoot, canonicalPath)) {
    fail(`plan.input_refs.${key}.absolute_path must resolve inside operator-inputs package`);
  }
  assertAbsolutePackagePathNotReserved(
    operatorInputsRoot,
    canonicalPath,
    `plan.input_refs.${key}.absolute_path`
  );
  const actual = await fileDigest(canonicalPath, `plan.input_refs.${key}`);
  if (requireDigest(ref.sha256, `plan.input_refs.${key}.sha256`) !== actual) {
    fail(`input ref digest changed after plan generation: ${key}`);
  }
  if (COMMAND_INPUT_REFS.has(key)) {
    try {
      await fs.access(canonicalPath, fsConstants.X_OK);
    } catch {
      fail(`plan.input_refs.${key}.absolute_path must be executable`);
    }
  }
  ref.absolute_path = canonicalPath;
  await validateRefPackageBinding({ ref, key, operatorInputsRoot });
  return ref;
}

async function validateDirectoryRef(refs, key, operatorInputsRoot) {
  const ref = requireObject(refs[key], `plan.input_refs.${key}`);
  if (ref.kind !== 'directory') {
    fail(`plan.input_refs.${key} ref type must be directory`);
  }
  const absolutePath = await requireDirectory(
    ref.absolute_path,
    `plan.input_refs.${key}.absolute_path`
  );
  const canonicalPath = await realpathForExisting(
    absolutePath,
    `plan.input_refs.${key}.absolute_path`
  );
  if (absolutePath !== canonicalPath) {
    fail(`plan.input_refs.${key}.absolute_path must be canonical`);
  }
  if (!isInsidePath(operatorInputsRoot, canonicalPath)) {
    fail(`plan.input_refs.${key}.absolute_path must resolve inside operator-inputs package`);
  }
  assertAbsolutePackagePathNotReserved(
    operatorInputsRoot,
    canonicalPath,
    `plan.input_refs.${key}.absolute_path`
  );
  const actual = await digestDirectory(canonicalPath);
  if (!Number.isInteger(ref.entry_count) || ref.entry_count !== actual.entry_count) {
    fail(`input ref directory entry count changed after plan generation: ${key}`);
  }
  if (
    requireDigest(ref.tree_sha256, `plan.input_refs.${key}.tree_sha256`) !==
    actual.tree_sha256
  ) {
    fail(`input ref directory digest changed after plan generation: ${key}`);
  }
  ref.absolute_path = canonicalPath;
  await validateRefPackageBinding({ ref, key, operatorInputsRoot });
  return ref;
}

function validateInputRefPathSafety(ref, key, operatorInputsRoot) {
  if (!ref || typeof ref !== 'object' || Array.isArray(ref)) {
    return undefined;
  }

  const safeRef = {};
  if (ref.kind === 'file' || ref.kind === 'directory') {
    safeRef.kind = ref.kind;
  }

  if (Object.hasOwn(ref, 'absolute_path')) {
    const absolutePath = requireAbsolutePath(
      ref.absolute_path,
      `plan.input_refs.${key}.absolute_path`
    );
    const normalizedAbsolutePath = path.resolve(absolutePath);
    if (absolutePath !== normalizedAbsolutePath) {
      fail(`plan.input_refs.${key}.absolute_path must be canonical`);
    }
    if (!isInsidePath(operatorInputsRoot, normalizedAbsolutePath)) {
      fail(`plan.input_refs.${key}.absolute_path must resolve inside operator-inputs package`);
    }
    assertAbsolutePackagePathNotReserved(
      operatorInputsRoot,
      normalizedAbsolutePath,
      `plan.input_refs.${key}.absolute_path`
    );
    safeRef.absolute_path = normalizedAbsolutePath;
  }

  if (Object.hasOwn(ref, 'path')) {
    const relativePath = assertPackageRelativeInput(ref.path, `plan.input_refs.${key}.path`);
    safeRef.path = relativePath;
    if (
      safeRef.absolute_path &&
      path.resolve(operatorInputsRoot, relativePath) !== safeRef.absolute_path
    ) {
      fail(`plan.input_refs.${key}.path must resolve to plan.input_refs.${key}.absolute_path`);
    }
  }

  if (!safeRef.absolute_path) {
    return undefined;
  }
  return safeRef;
}

function validatePlanInputRefPathSafety(plan, operatorInputsRoot) {
  if (!plan.input_refs || typeof plan.input_refs !== 'object' || Array.isArray(plan.input_refs)) {
    return {};
  }

  const safeRefs = {};
  for (const key of Object.keys(plan.input_refs)) {
    const safeRef = validateInputRefPathSafety(plan.input_refs[key], key, operatorInputsRoot);
    if (safeRef) {
      safeRefs[key] = safeRef;
    }
  }
  return safeRefs;
}

async function validateManifestRefBindings({
  refs,
  operatorManifest,
  operatorInputsRoot,
  expectedRefs
}) {
  for (const key of expectedRefs.required) {
    if (!Object.hasOwn(operatorManifest, key)) {
      fail(`operator-inputs manifest.${key} is required for plan input ref validation`);
    }
  }

  for (const key of Object.keys(refs)) {
    if (!Object.hasOwn(operatorManifest, key)) {
      fail(`plan.input_refs.${key} has no matching operator-inputs manifest field`);
    }
    if (COMMAND_INPUT_REFS.has(key)) {
      const commandValue = requireString(operatorManifest[key], `operator-inputs manifest.${key}`);
      if (!commandValue.includes('/') && !commandValue.includes('\\')) {
        fail(`operator-inputs manifest.${key} must be a package-relative executable path`);
      }
    }
    const resolved = await resolvePackagePath({
      operatorInputsRoot,
      value: operatorManifest[key],
      label: `operator-inputs manifest.${key}`,
      kind: DIRECTORY_INPUT_REFS.has(key) ? 'directory' : 'file'
    });
    if (resolved.absolutePath !== refs[key].absolute_path) {
      fail(`plan.input_refs.${key} must match operator-inputs manifest.${key}`);
    }
    if (resolved.path !== refs[key].path) {
      fail(`plan.input_refs.${key}.path must match operator-inputs manifest.${key}`);
    }
  }
}

function assertAirgapBundleRelativePath(value, label) {
  const relativePath = requireString(value, label);
  if (
    relativePath.trim() !== relativePath ||
    path.posix.isAbsolute(relativePath) ||
    path.isAbsolute(relativePath) ||
    WINDOWS_DRIVE_RE.test(relativePath) ||
    relativePath.includes('\\') ||
    URI_SCHEME_RE.test(relativePath)
  ) {
    fail(`${label} must be a relative bundle path`);
  }
  if (relativePath.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) {
    fail(`${label} must not contain empty, dot, or parent segments`);
  }
  return relativePath;
}

async function resolveAirgapBundleComponent({ bundleRoot, component, label }) {
  const relativePath = assertAirgapBundleRelativePath(component.path, `${label}.path`);
  const requested = path.resolve(bundleRoot, relativePath);
  if (!isInsidePath(bundleRoot, requested)) {
    fail(`${label}.path must resolve inside airgap_bundle`);
  }

  let lstat;
  try {
    lstat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${label}.path: ${error.message}`);
  }
  if (lstat.isSymbolicLink()) {
    fail(`${label}.path must not be a symlink`);
  }
  if (!lstat.isFile()) {
    fail(`${label}.path must point to a file`);
  }

  const realPath = await realpathForExisting(requested, `${label}.path`);
  if (!isInsidePath(bundleRoot, realPath)) {
    fail(`${label}.path must resolve inside airgap_bundle`);
  }
  return {
    absolute_path: realPath,
    sha256: await fileDigest(realPath, `${label}.path`)
  };
}

async function validateAirgapBundleComponentBindings({ refs, deploymentPath }) {
  if (!deploymentPath.startsWith('airgap/')) {
    return {};
  }

  const bundleRoot = refs.airgap_bundle.absolute_path;
  const bundleManifestPath = refs.airgap_bundle_manifest.absolute_path;
  if (!isInsidePath(bundleRoot, bundleManifestPath)) {
    fail('airgap_bundle_manifest must resolve inside airgap_bundle');
  }
  const bundleManifest = requireObject(
    await readJson(bundleManifestPath, 'airgap_bundle_manifest'),
    'airgap_bundle_manifest'
  );
  if (bundleManifest.schema_version !== AIRGAP_BUNDLE_MANIFEST_SCHEMA) {
    fail(`airgap_bundle_manifest.schema_version must be ${AIRGAP_BUNDLE_MANIFEST_SCHEMA}`);
  }
  if (!Array.isArray(bundleManifest.components)) {
    fail('airgap_bundle_manifest.components must be an array');
  }

  const components = new Map();
  for (const [index, value] of bundleManifest.components.entries()) {
    const label = `airgap_bundle_manifest.components[${index}]`;
    const component = requireObject(value, label);
    const kind = requireString(component.kind, `${label}.kind`);
    if (components.has(kind)) {
      fail(`airgap_bundle_manifest.components contains duplicate kind: ${kind}`);
    }
    const declaredSha256 = requireDigest(component.sha256, `${label}.sha256`);
    const componentRef = await resolveAirgapBundleComponent({
      bundleRoot,
      component,
      label
    });
    if (componentRef.sha256 !== declaredSha256) {
      fail(`${label}.sha256 must match component file sha256`);
    }
    components.set(kind, componentRef);
  }

  for (const key of AIRGAP_BUNDLE_COMPONENT_REF_KEYS) {
    const componentRef = components.get(key);
    if (!componentRef) {
      fail(`airgap_bundle_manifest.components must include ${key}`);
    }
    if (refs[key].absolute_path !== componentRef.absolute_path) {
      fail(`${key} must match airgap_bundle_manifest.components.${key}.path for airgap deployment_path`);
    }
    if (refs[key].sha256 !== componentRef.sha256) {
      fail(`${key} digest must match airgap_bundle_manifest.components.${key}.sha256`);
    }
  }

  return Object.fromEntries(components.entries());
}

function validateManifestDeploymentPath(operatorManifest) {
  const deploymentPath = requireString(
    operatorManifest.deployment_path,
    'operator-inputs manifest.deployment_path'
  );
  if (!CLEANUP_DEPLOYMENT_PATHS.has(deploymentPath)) {
    fail('operator-inputs manifest.deployment_path must be a known operator-inputs cleanup path');
  }
  return deploymentPath;
}

async function validatePackageManifest(plan, operatorInputsRoot, { checkDigest = true } = {}) {
  const packageInfo = requireObject(plan.package, 'plan.package');
  const manifestPath = await requireFile(packageInfo.manifest_path, 'plan.package.manifest_path');
  const canonicalManifestPath = await realpathForExisting(
    manifestPath,
    'plan.package.manifest_path'
  );
  if (manifestPath !== canonicalManifestPath) {
    fail('plan.package.manifest_path must be canonical');
  }
  if (!isInsidePath(operatorInputsRoot, canonicalManifestPath)) {
    fail('plan.package.manifest_path must resolve inside operator-inputs package');
  }
  assertAbsolutePackagePathNotReserved(
    operatorInputsRoot,
    canonicalManifestPath,
    'plan.package.manifest_path'
  );
  const manifestFromRelative = await resolvePackagePath({
    operatorInputsRoot,
    value: packageInfo.manifest_relative_path,
    label: 'plan.package.manifest_relative_path',
    kind: 'file'
  });
  if (manifestFromRelative.absolutePath !== canonicalManifestPath) {
    fail('plan.package.manifest_relative_path must resolve to plan.package.manifest_path');
  }
  if (checkDigest) {
    const declaredManifestDigest = requireDigest(
      packageInfo.manifest_sha256,
      'plan.package.manifest_sha256'
    );
    const actualManifestDigest = await fileDigest(canonicalManifestPath, 'operator-inputs manifest');
    if (declaredManifestDigest !== actualManifestDigest) {
      fail('operator-inputs manifest digest changed after plan generation');
    }
  }
  const operatorManifest = requireObject(
    await readJson(canonicalManifestPath, 'operator-inputs manifest'),
    'operator-inputs manifest'
  );
  const manifestDeploymentPath = validateManifestDeploymentPath(operatorManifest);
  return {
    operatorManifest,
    manifestDeploymentPath
  };
}

async function validatePackageManifestPathSafety(plan, operatorInputsRoot) {
  const packageInfo = requireObject(plan.package, 'plan.package');
  const manifestPath = requireAbsolutePath(
    packageInfo.manifest_path,
    'plan.package.manifest_path'
  );
  const normalizedManifestPath = path.resolve(manifestPath);
  if (manifestPath !== normalizedManifestPath) {
    fail('plan.package.manifest_path must be canonical');
  }
  if (!isInsidePath(operatorInputsRoot, normalizedManifestPath)) {
    fail('plan.package.manifest_path must resolve inside operator-inputs package');
  }
  assertAbsolutePackagePathNotReserved(
    operatorInputsRoot,
    normalizedManifestPath,
    'plan.package.manifest_path'
  );

  let stat;
  try {
    stat = await fs.lstat(normalizedManifestPath);
  } catch (error) {
    fail(`cannot read plan.package.manifest_path: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('plan.package.manifest_path must not be a symlink');
  }
  if (!stat.isFile()) {
    fail('plan.package.manifest_path must point to a file');
  }

  const canonicalManifestPath = await realpathForExisting(
    normalizedManifestPath,
    'plan.package.manifest_path'
  );
  if (normalizedManifestPath !== canonicalManifestPath) {
    fail('plan.package.manifest_path must be canonical');
  }
  if (!isInsidePath(operatorInputsRoot, canonicalManifestPath)) {
    fail('plan.package.manifest_path must resolve inside operator-inputs package');
  }

  const manifestFromRelative = await resolvePackagePath({
    operatorInputsRoot,
    value: packageInfo.manifest_relative_path,
    label: 'plan.package.manifest_relative_path',
    kind: 'file'
  });
  if (manifestFromRelative.absolutePath !== canonicalManifestPath) {
    fail('plan.package.manifest_relative_path must resolve to plan.package.manifest_path');
  }

  const operatorManifest = requireObject(
    await readJson(canonicalManifestPath, 'operator-inputs manifest'),
    'operator-inputs manifest'
  );
  const manifestDeploymentPath = validateManifestDeploymentPath(operatorManifest);
  return {
    operatorManifest,
    manifestDeploymentPath
  };
}

function validateManifestRefSafety({
  operatorManifest,
  operatorInputsRoot
}) {
  const refs = {};
  for (const key of [
    ...MANIFEST_FILE_REF_FIELDS,
    ...MANIFEST_DIRECTORY_REF_FIELDS,
    ...MANIFEST_COMMAND_REF_FIELDS
  ]) {
    if (!Object.hasOwn(operatorManifest, key)) {
      continue;
    }
    const relativePath = assertPackageRelativeInput(
      operatorManifest[key],
      `operator-inputs manifest.${key}`
    );
    refs[key] = {
      kind: MANIFEST_DIRECTORY_REF_FIELDS.has(key) ? 'directory' : 'file',
      path: relativePath,
      absolute_path: path.resolve(operatorInputsRoot, relativePath)
    };
  }
  return refs;
}

async function validatePackageRefSafety(plan, operatorInputsRoot) {
  const { operatorManifest, manifestDeploymentPath } = await validatePackageManifestPathSafety(
    plan,
    operatorInputsRoot
  );
  const manifestRefs = validateManifestRefSafety({
    operatorManifest,
    operatorInputsRoot
  });
  const planRefs = validatePlanInputRefPathSafety(plan, operatorInputsRoot);

  return {
    refs: manifestRefs,
    planRefs,
    operatorManifest,
    manifestDeploymentPath
  };
}

async function validatePackageRefs(plan, operatorInputsRoot) {
  const { operatorManifest, manifestDeploymentPath } = await validatePackageManifest(
    plan,
    operatorInputsRoot
  );
  const manifestMode =
    typeof operatorManifest.mode === 'string' ? operatorManifest.mode : 'server-dry-run';

  const refs = requireObject(plan.input_refs, 'plan.input_refs');
  const expectedRefs = inputRefsForDeploymentPath(manifestDeploymentPath, manifestMode);
  for (const key of Object.keys(refs)) {
    if (!SUPPORTED_INPUT_REFS.has(key)) {
      fail(`operator-inputs --run does not support input ref: ${key}`);
    }
    if (!expectedRefs.allowed.has(key)) {
      fail(`operator-inputs --run does not support input ref for ${manifestDeploymentPath}: ${key}`);
    }
  }
  for (const key of expectedRefs.required) {
    if (!refs[key]) {
      fail(`missing required input ref for ${manifestDeploymentPath}: ${key}`);
    }
  }
  for (const key of Object.keys(refs)) {
    if (DIRECTORY_INPUT_REFS.has(key)) {
      await validateDirectoryRef(refs, key, operatorInputsRoot);
    } else {
      await validateFileRef(refs, key, operatorInputsRoot);
    }
  }
  await validateManifestRefBindings({
    refs,
    operatorManifest,
    operatorInputsRoot,
    expectedRefs
  });
  const airgapBundleComponents = await validateAirgapBundleComponentBindings({
    refs,
    deploymentPath: manifestDeploymentPath
  });
  return {
    refs,
    operatorManifest,
    airgapBundleComponents,
    manifestDeploymentPath
  };
}

function producerFlagSpec({ requiredValueFlags, optionalValueFlags, booleanFlags }) {
  const valueFlags = new Set([...requiredValueFlags, ...optionalValueFlags]);
  return {
    requiredValueFlags,
    optionalValueFlags,
    booleanFlags,
    valueFlags,
    allowedFlags: new Set([...valueFlags, ...booleanFlags])
  };
}

function parseProducerFlags(argv, label, spec) {
  const values = new Map();
  const booleans = new Set();

  for (let index = 3; index < argv.length; index += 1) {
    const flag = argv[index];
    if (typeof flag !== 'string' || !flag.startsWith('--')) {
      fail(`${label} producer argv contains unexpected positional argument: ${flag}`);
    }
    if (!spec.allowedFlags.has(flag)) {
      fail(`${label} producer argv contains unsupported flag: ${flag}`);
    }

    if (spec.valueFlags.has(flag)) {
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

  for (const flag of spec.requiredValueFlags) {
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
  if (!SUPPORTED_DEPLOYMENT_PATHS.has(expected.deployment_path)) {
    fail('plan._internal.expected.deployment_path must be a supported operator-inputs run path');
  }
  const expectedTargetProfile = TARGET_PROFILE_BY_DEPLOYMENT_PATH.get(expected.deployment_path);
  if (expected.target_profile !== expectedTargetProfile) {
    fail(`plan._internal.expected.target_profile must be ${expectedTargetProfile}`);
  }
  if (expected.mode !== SUPPORTED_MODE) {
    fail(`plan._internal.expected.mode must be ${SUPPORTED_MODE}`);
  }

  const outputDirs = requireObject(expected.output_dirs, 'plan._internal.expected.output_dirs');
  const canonicalOutputDirs = expectedOutputDirs(internalRoot, expected.deployment_path);
  const installExpected = isInstallSubstratesPath(expected.deployment_path);
  const airgapExpected = isAirgapUseExistingPath(expected.deployment_path);
  if (installExpected) {
    if (outputDirs.substrate_install !== canonicalOutputDirs.substrateInstall) {
      fail('plan._internal.expected.output_dirs.substrate_install must be the internal expected dir');
    }
  } else if (outputDirs.substrate_install !== null && outputDirs.substrate_install !== undefined) {
    fail('plan._internal.expected.output_dirs.substrate_install must be null for use_existing');
  }
  if (!airgapExpected && outputDirs.online_deployment_gate !== canonicalOutputDirs.onlineDeploymentGate) {
    fail('plan._internal.expected.output_dirs.online_deployment_gate must be the internal expected dir');
  }
  if (airgapExpected && outputDirs.online_deployment_gate !== null && outputDirs.online_deployment_gate !== undefined) {
    fail('plan._internal.expected.output_dirs.online_deployment_gate must be null for airgap');
  }
  if (airgapExpected) {
    if (outputDirs.airgap_consume_rehearsal !== canonicalOutputDirs.airgapConsumeRehearsal) {
      fail('plan._internal.expected.output_dirs.airgap_consume_rehearsal must be the internal expected dir');
    }
    if (outputDirs.airgap_bundle_check !== canonicalOutputDirs.airgapBundleCheck) {
      fail('plan._internal.expected.output_dirs.airgap_bundle_check must be the internal expected dir');
    }
    if (outputDirs.airgap_deployment_gate !== canonicalOutputDirs.airgapDeploymentGate) {
      fail('plan._internal.expected.output_dirs.airgap_deployment_gate must be the internal expected dir');
    }
  } else {
    for (const key of ['airgap_consume_rehearsal', 'airgap_bundle_check', 'airgap_deployment_gate']) {
      if (outputDirs[key] !== null && outputDirs[key] !== undefined) {
        fail(`plan._internal.expected.output_dirs.${key} must be null for online paths`);
      }
    }
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
  const generatedRefs = requireObject(
    expected.generated_refs,
    'plan._internal.expected.generated_refs'
  );
  const expectedGeneratedSubstrateTruth = installExpected
    ? path.join(canonicalOutputDirs.substrateInstall, 'substrate-truth.json')
    : null;
  if (generatedRefs.substrate_truth !== expectedGeneratedSubstrateTruth) {
    fail('plan._internal.expected.generated_refs.substrate_truth must point to installer output truth for install paths');
  }

  let expectedInstall;
  if (installExpected) {
    expectedInstall = requireObject(expected.install, 'plan._internal.expected.install');
    expectedInstall = {
      operatorRunId: requireString(
        expectedInstall.operator_run_id,
        'plan._internal.expected.install.operator_run_id'
      ),
      installParametersSha256: requireDigest(
        expectedInstall.install_parameters_sha256,
        'plan._internal.expected.install.install_parameters_sha256'
      )
    };
  } else if (expected.install !== null && expected.install !== undefined) {
    fail('plan._internal.expected.install must be null for use_existing');
  }
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
  if (installExpected) {
    const installConfirmation = requireObject(
      operatorManifest.install_confirmation,
      'operator-inputs manifest.install_confirmation'
    );
    if (
      requireString(
        installConfirmation.operator_run_id,
        'operator-inputs manifest.install_confirmation.operator_run_id'
      ) !== expectedInstall.operatorRunId
    ) {
      fail('plan._internal.expected.install.operator_run_id must match operator-inputs manifest');
    }
    if (
      requireDigest(
        installConfirmation.install_parameters_sha256,
        'operator-inputs manifest.install_confirmation.install_parameters_sha256'
      ) !== expectedInstall.installParametersSha256
    ) {
      fail('plan._internal.expected.install.install_parameters_sha256 must match operator-inputs manifest');
    }
  } else if (Object.hasOwn(operatorManifest, 'install_confirmation')) {
    fail('operator-inputs manifest.install_confirmation is accepted only for install_substrates run paths');
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
    install: expectedInstall,
    generatedRefs: {
      substrateTruth: expectedGeneratedSubstrateTruth
    },
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
  if (plan.deployment_path === AIRGAP_INSTALL_SUBSTRATES_PATH) {
    fail('operator-inputs --run does not implement airgap/install_substrates path-level orchestration yet');
  }
  if (!SUPPORTED_DEPLOYMENT_PATHS.has(plan.deployment_path) || plan.mode !== SUPPORTED_MODE) {
    fail(
      `operator-inputs --run currently supports only ${ONLINE_USE_EXISTING_PATH}, ${ONLINE_INSTALL_SUBSTRATES_PATH}, or ${AIRGAP_USE_EXISTING_PATH} with mode ${SUPPORTED_MODE}`
    );
  }
}

async function cleanupDeploymentPathOutputsForDeploymentPath({ deploymentPath, internalRoot }) {
  const outputDirs = expectedOutputDirs(internalRoot, deploymentPath);
  await ensureDirectoryInsideInternalRoot({
    internalRoot,
    targetDir: path.join(internalRoot, deploymentPathOutputSlug(deploymentPath)),
    label: 'operator-inputs deployment output base'
  });
  const deploymentPathDir = await ensureDirectoryInsideInternalRoot({
    internalRoot,
    targetDir: outputDirs.deploymentPath,
    label: 'deployment-path output dir'
  });
  await cleanupDeploymentPathOutputs(deploymentPathDir);
}

function assertRefsOutsideCleanupRange({ refs, cleanupDir, labelPrefix = 'operator-inputs manifest' }) {
  for (const [key, ref] of Object.entries(refs)) {
    const absolutePath = ref?.absolute_path;
    if (!absolutePath) {
      continue;
    }
    if (isInsidePath(cleanupDir, absolutePath)) {
      fail(`${labelPrefix}.${key} must not overlap deployment-path cleanup output`);
    }
    if (ref.kind === 'directory' && isInsidePath(absolutePath, cleanupDir)) {
      fail(`${labelPrefix}.${key} must not contain deployment-path cleanup output`);
    }
  }
}

function deploymentPathBindingError(plan, manifestDeploymentPath) {
  const internal = requireObject(plan._internal, 'plan._internal');
  const expected = requireObject(internal.expected, 'plan._internal.expected');
  const expectedDeploymentPath = requireString(
    expected.deployment_path,
    'plan._internal.expected.deployment_path'
  );
  if (plan.deployment_path !== manifestDeploymentPath) {
    return 'plan.deployment_path must match operator-inputs manifest.deployment_path';
  }
  if (expectedDeploymentPath !== manifestDeploymentPath) {
    return 'plan._internal.expected.deployment_path must match operator-inputs manifest';
  }
  return undefined;
}

function validateSubstrateInstallStep(step, refs, expected) {
  if (step.name !== 'substrate-install') {
    fail(`operator-inputs --run install path first producer must be substrate-install, got: ${step.name}`);
  }
  const argv = step.argv;
  if (!Array.isArray(argv) || argv.length < 4) {
    fail('substrate-install producer argv is invalid');
  }
  if (argv[0] !== 'bash' || argv[1] !== VERIFY_RELEASE_SCRIPT || argv[2] !== '--substrate-install') {
    fail('substrate-install producer argv must call verify-release.sh --substrate-install');
  }

  const parsed = parseProducerFlags(
    argv,
    step.name,
    producerFlagSpec({
      requiredValueFlags: SUBSTRATE_INSTALL_REQUIRED_VALUE_FLAGS,
      optionalValueFlags: SUBSTRATE_INSTALL_OPTIONAL_VALUE_FLAGS,
      booleanFlags: SUBSTRATE_INSTALL_BOOLEAN_FLAGS
    })
  );
  assertBoundValue(parsed, '--release-contract', refs.release_contract.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--deploy-template-package',
    refs.deploy_template_package.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--target-profile', expected.targetProfile, step.name);
  assertBoundValue(
    parsed,
    '--substrate-pack-manifest',
    refs.substrate_pack_manifest.absolute_path,
    step.name
  );
  assertBoundValue(
    parsed,
    '--substrate-install-inputs',
    refs.substrate_install_inputs.absolute_path,
    step.name
  );
  assertBoundValue(
    parsed,
    '--target-prerequisites',
    refs.target_prerequisites.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--namespace', expected.namespace, step.name);
  assertBoundValue(parsed, '--output-dir', expected.outputDirs.substrateInstall, step.name);
  assertBoundValue(parsed, '--mode', expected.mode, step.name);
  assertBoundValue(parsed, '--context', expected.context, step.name);
  assertBoundValue(parsed, '--kubectl', refs.kubectl.absolute_path, step.name);
  assertBoundValue(parsed, '--confirm-substrate-install', expected.targetProfile, step.name);
  assertBoundValue(
    parsed,
    '--confirm-install-parameters',
    expected.install.installParametersSha256,
    step.name
  );
  assertBoundValue(parsed, '--operator-run-id', expected.install.operatorRunId, step.name);

  const outputDir = requireAbsolutePath(parsed.value('--output-dir'), 'substrate-install output dir');

  return {
    step,
    outputDir,
    reportPath: path.join(outputDir, 'substrate-install-report.json'),
    truthPath: expected.generatedRefs.substrateTruth
  };
}

function validateOnlineDeploymentGateStep(step, refs, expected) {
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

  const parsed = parseProducerFlags(
    argv,
    step.name,
    producerFlagSpec({
      requiredValueFlags: ONLINE_GATE_REQUIRED_VALUE_FLAGS,
      optionalValueFlags: ONLINE_GATE_OPTIONAL_VALUE_FLAGS,
      booleanFlags: ONLINE_GATE_BOOLEAN_FLAGS
    })
  );
  assertBoundValue(parsed, '--release-contract', refs.release_contract.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--deploy-template-package',
    refs.deploy_template_package.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--archive', refs.deploy_template_archive.absolute_path, step.name);
  assertBoundValue(parsed, '--render-values', refs.render_values.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--substrate-truth',
    expected.generatedRefs.substrateTruth ?? refs.substrate_truth.absolute_path,
    step.name
  );
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
  if (isInstallSubstratesPath(expected.deploymentPath)) {
    assertBoundValue(
      parsed,
      '--substrate-pack-manifest',
      refs.substrate_pack_manifest.absolute_path,
      step.name
    );
    assertBoundValue(
      parsed,
      '--routability-probe',
      refs.routability_probe.absolute_path,
      step.name
    );
  } else {
    assertOptionalBoundValue(parsed, '--substrate-pack-manifest', undefined, step.name);
    assertOptionalBoundValue(parsed, '--routability-probe', undefined, step.name);
  }

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

function validateAirgapConsumeStep(step, refs, expected) {
  if (step.name !== 'airgap-consume-rehearsal') {
    fail(`operator-inputs --run airgap use_existing producer must be airgap-consume-rehearsal, got: ${step.name}`);
  }
  const argv = step.argv;
  if (!Array.isArray(argv) || argv.length < 4) {
    fail('airgap-consume-rehearsal producer argv is invalid');
  }
  if (argv[0] !== 'bash' || argv[1] !== VERIFY_RELEASE_SCRIPT || argv[2] !== '--airgap-consume-rehearsal') {
    fail('airgap-consume-rehearsal producer argv must call verify-release.sh --airgap-consume-rehearsal');
  }

  const parsed = parseProducerFlags(
    argv,
    step.name,
    producerFlagSpec({
      requiredValueFlags: AIRGAP_CONSUME_REQUIRED_VALUE_FLAGS,
      optionalValueFlags: AIRGAP_CONSUME_OPTIONAL_VALUE_FLAGS,
      booleanFlags: AIRGAP_CONSUME_BOOLEAN_FLAGS
    })
  );
  assertBoundValue(parsed, '--bundle-root', refs.airgap_bundle.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--bundle-manifest',
    refs.airgap_bundle_manifest.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--render-values', refs.render_values.absolute_path, step.name);
  assertBoundValue(parsed, '--substrate-truth', refs.substrate_truth.absolute_path, step.name);
  assertBoundValue(
    parsed,
    '--target-prerequisites',
    refs.target_prerequisites.absolute_path,
    step.name
  );
  assertBoundValue(parsed, '--namespace', expected.namespace, step.name);
  assertBoundValue(parsed, '--output-dir', expected.outputDirs.airgapConsumeRehearsal, step.name);
  assertBoundValue(parsed, '--mode', expected.mode, step.name);
  assertBoundValue(parsed, '--archive-probe', refs.archive_probe.absolute_path, step.name);
  assertBoundValue(parsed, '--image-loader', refs.image_loader.absolute_path, step.name);
  assertBoundValue(parsed, '--smoke-url', expected.smoke.smokeUrl, step.name);
  assertBoundValue(parsed, '--confirm-apply', expected.targetProfile, step.name);
  assertBoundValue(parsed, '--operator-run-id', expected.operatorRunId, step.name);
  assertBoundValue(parsed, '--context', expected.context, step.name);
  assertBoundValue(parsed, '--kubectl', refs.kubectl.absolute_path, step.name);
  assertOptionalBoundValue(parsed, '--timeout', expected.smoke.timeout, step.name);
  assertOptionalBoundValue(parsed, '--expected-status', expected.smoke.expectedStatus, step.name);
  assertOptionalBoundValue(parsed, '--timeout-ms', expected.smoke.timeoutMs, step.name);
  assertOptionalBoundBoolean(parsed, '--allow-http', expected.smoke.allowHttp, step.name);
  assertOptionalBoundBoolean(parsed, '--allow-localhost', expected.smoke.allowLocalhost, step.name);

  const outputDir = requireAbsolutePath(
    parsed.value('--output-dir'),
    'airgap-consume-rehearsal output dir'
  );

  return {
    step,
    outputDir,
    reportPath: path.join(outputDir, 'airgap-consume-rehearsal-report.json')
  };
}

function validateProducerSteps(plan, refs, expected) {
  if (!Array.isArray(plan.producer_argv)) {
    fail('plan.producer_argv must be an array');
  }

  if (isAirgapUseExistingPath(expected.deploymentPath)) {
    if (plan.producer_argv.length !== 1) {
      fail('operator-inputs --run airgap use_existing path requires exactly one producer step');
    }
    const airgapConsumeStep = requireObject(plan.producer_argv[0], 'plan.producer_argv[0]');
    return {
      substrateInstall: undefined,
      onlineDeploymentGate: undefined,
      airgapConsume: validateAirgapConsumeStep(airgapConsumeStep, refs, expected)
    };
  }

  if (isInstallSubstratesPath(expected.deploymentPath)) {
    if (plan.producer_argv.length !== 2) {
      fail('operator-inputs --run install path requires exactly two producer steps');
    }
    const substrateInstallStep = requireObject(plan.producer_argv[0], 'plan.producer_argv[0]');
    const onlineGateStep = requireObject(plan.producer_argv[1], 'plan.producer_argv[1]');
    if (substrateInstallStep.name !== 'substrate-install' || onlineGateStep.name !== 'online-deployment-gate') {
      fail('operator-inputs --run install path producer order must be substrate-install then online-deployment-gate');
    }
    return {
      substrateInstall: validateSubstrateInstallStep(substrateInstallStep, refs, expected),
      onlineDeploymentGate: validateOnlineDeploymentGateStep(onlineGateStep, refs, expected),
      airgapConsume: undefined
    };
  }

  if (plan.producer_argv.length !== 1) {
    fail('operator-inputs --run use_existing path requires exactly one producer step');
  }
  return {
    substrateInstall: undefined,
    onlineDeploymentGate: validateOnlineDeploymentGateStep(
      requireObject(plan.producer_argv[0], 'plan.producer_argv[0]'),
      refs,
      expected
    ),
    airgapConsume: undefined
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

async function validateSubstrateInstallOutputs(producer, expected) {
  const report = await requireGeneratedReport(producer.reportPath, 'substrate-install report');
  const outputSubstrateTruthDigest = requireDigest(
    report.output_substrate_truth_digest,
    'substrate-install report.output_substrate_truth_digest'
  );
  const generatedTruthDigest = await fileDigest(
    producer.truthPath,
    'substrate-install generated substrate truth'
  );
  if (outputSubstrateTruthDigest !== generatedTruthDigest) {
    fail('substrate-install generated substrate truth digest must match substrate-install report.output_substrate_truth_digest');
  }
  if (
    Object.hasOwn(report, 'substrate_truth_digest') &&
    requireDigest(report.substrate_truth_digest, 'substrate-install report.substrate_truth_digest') !==
      generatedTruthDigest
  ) {
    fail('substrate-install report.substrate_truth_digest must match generated substrate truth digest');
  }
  if (report.mode !== expected.mode) {
    fail('substrate-install report.mode must match operator-inputs mode');
  }
  if (
    requireString(report.operator_run_id, 'substrate-install report.operator_run_id') !==
    expected.install.operatorRunId
  ) {
    fail('substrate-install report.operator_run_id must match install confirmation operator_run_id');
  }
  return report;
}

function requireSafeRelativeReportPath(value, label) {
  const relativePath = requireString(value, label);
  if (relativePath.includes('\\') || path.isAbsolute(relativePath)) {
    fail(`${label} must be a portable relative path`);
  }
  const segments = relativePath.split('/');
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
    fail(`${label} must not contain empty, current, or parent path segments`);
  }
  return relativePath;
}

async function resolveReportPathInsideOutput({ outputDir, relativePath, label }) {
  const absolutePath = path.join(outputDir, relativePath);
  if (!isInsidePath(outputDir, absolutePath)) {
    fail(`${label} must resolve inside airgap consume output dir`);
  }
  await requireFile(absolutePath, label);
  const canonicalPath = await realpathForExisting(absolutePath, label);
  if (!isInsidePath(outputDir, canonicalPath)) {
    fail(`${label} resolves outside airgap consume output dir`);
  }
  return canonicalPath;
}

async function extractAirgapConsumeStepReportPath({
  consumeReport,
  outputDir,
  stepName,
  expectedRelativePath
}) {
  const steps = Array.isArray(consumeReport.steps)
    ? consumeReport.steps
    : fail('airgap-consume-rehearsal report.steps must be an array');
  const matchingSteps = steps.filter((step) => {
    const object = requireObject(step, 'airgap-consume-rehearsal report step');
    return object.name === stepName;
  });
  if (matchingSteps.length !== 1) {
    fail(`airgap-consume-rehearsal report must contain exactly one ${stepName} step`);
  }
  const relativePath = requireSafeRelativeReportPath(
    matchingSteps[0].report_path,
    `airgap-consume-rehearsal report ${stepName}.report_path`
  );
  if (relativePath !== expectedRelativePath) {
    fail(`airgap-consume-rehearsal report ${stepName}.report_path must be ${expectedRelativePath}`);
  }
  return resolveReportPathInsideOutput({
    outputDir,
    relativePath,
    label: `${stepName} nested report`
  });
}

async function validateAirgapConsumeOutputs(producer, expected) {
  const report = await requireGeneratedReport(
    producer.reportPath,
    'airgap-consume-rehearsal report'
  );
  if (report.mode !== expected.mode) {
    fail('airgap-consume-rehearsal report.mode must match operator-inputs mode');
  }
  const targetProfile = requireObject(
    report.target_profile,
    'airgap-consume-rehearsal report.target_profile'
  );
  if (
    requireString(
      targetProfile.value,
      'airgap-consume-rehearsal report.target_profile.value'
    ) !== expected.targetProfile
  ) {
    fail('airgap-consume-rehearsal report.target_profile.value must match operator-inputs target profile');
  }

  const bundleCheckReportPath = await extractAirgapConsumeStepReportPath({
    consumeReport: report,
    outputDir: producer.outputDir,
    stepName: 'airgap-bundle-check',
    expectedRelativePath: 'airgap-bundle-check/airgap-bundle-check-report.json'
  });
  const deploymentGateReportPath = await extractAirgapConsumeStepReportPath({
    consumeReport: report,
    outputDir: producer.outputDir,
    stepName: 'airgap-deployment-gate',
    expectedRelativePath: 'airgap-deployment-gate/airgap-deployment-gate-report.json'
  });

  await requireGeneratedReport(bundleCheckReportPath, 'airgap-bundle-check report');
  const deploymentGateReport = await requireGeneratedReport(
    deploymentGateReportPath,
    'airgap-deployment-gate report'
  );
  if (deploymentGateReport.mode !== expected.mode) {
    fail('airgap-deployment-gate report.mode must match operator-inputs mode');
  }

  return {
    report,
    bundleCheckReportPath,
    deploymentGateReportPath
  };
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
  const precleanEnvelope = await validatePlanPrecleanEnvelope(plan, canonicalPlanPath);
  const {
    refs: safetyRefs,
    planRefs: safetyPlanRefs,
    manifestDeploymentPath
  } = await validatePackageRefSafety(plan, precleanEnvelope.operatorInputsRoot);
  const precleanBindingError = deploymentPathBindingError(plan, manifestDeploymentPath);
  if (precleanBindingError) {
    fail(precleanBindingError);
  }
  const manifestCleanupDir = expectedOutputDirs(
    precleanEnvelope.internalRoot,
    manifestDeploymentPath
  ).deploymentPath;
  assertRefsOutsideCleanupRange({ refs: safetyRefs, cleanupDir: manifestCleanupDir });
  assertRefsOutsideCleanupRange({
    refs: safetyPlanRefs,
    cleanupDir: manifestCleanupDir,
    labelPrefix: 'plan.input_refs'
  });
  await cleanupDeploymentPathOutputsForDeploymentPath({
    deploymentPath: manifestDeploymentPath,
    internalRoot: precleanEnvelope.internalRoot
  });

  const envelope = await validatePlanEnvelope(plan);
  if (!isInsidePath(envelope.internalRoot, canonicalPlanPath)) {
    fail('operator-inputs plan path must be inside operator-inputs internal output root');
  }
  await validateFacadeArgv(plan);
  const bindingError = deploymentPathBindingError(plan, manifestDeploymentPath);
  if (bindingError) {
    fail(bindingError);
  }
  validateUnsupportedScope(plan);
  const { refs, operatorManifest, airgapBundleComponents } = await validatePackageRefs(
    plan,
    envelope.operatorInputsRoot
  );
  const expected = validateInternalExpected(plan, envelope.internalRoot, operatorManifest);
  await ensureDirectoryInsideInternalRoot({
    internalRoot: envelope.internalRoot,
    targetDir: path.join(envelope.internalRoot, deploymentPathOutputSlug(expected.deploymentPath)),
    label: 'operator-inputs deployment output base'
  });
  if (isInstallSubstratesPath(expected.deploymentPath)) {
    expected.outputDirs.substrateInstall = await ensureDirectoryInsideInternalRoot({
      internalRoot: envelope.internalRoot,
      targetDir: expected.outputDirs.substrateInstall,
      label: 'substrate-install output dir'
    });
    expected.generatedRefs.substrateTruth = path.join(
      expected.outputDirs.substrateInstall,
      'substrate-truth.json'
    );
  }
  if (isAirgapUseExistingPath(expected.deploymentPath)) {
    expected.outputDirs.airgapConsumeRehearsal = await ensureDirectoryInsideInternalRoot({
      internalRoot: envelope.internalRoot,
      targetDir: expected.outputDirs.airgapConsumeRehearsal,
      label: 'airgap-consume-rehearsal output dir'
    });
    expected.outputDirs.airgapBundleCheck = path.join(
      expected.outputDirs.airgapConsumeRehearsal,
      'airgap-bundle-check'
    );
    expected.outputDirs.airgapDeploymentGate = path.join(
      expected.outputDirs.airgapConsumeRehearsal,
      'airgap-deployment-gate'
    );
  } else {
    expected.outputDirs.onlineDeploymentGate = await ensureDirectoryInsideInternalRoot({
      internalRoot: envelope.internalRoot,
      targetDir: expected.outputDirs.onlineDeploymentGate,
      label: 'online-deployment-gate output dir'
    });
  }
  expected.outputDirs.deploymentPath = await ensureDirectoryInsideInternalRoot({
    internalRoot: envelope.internalRoot,
    targetDir: expected.outputDirs.deploymentPath,
    label: 'deployment-path output dir'
  });
  await cleanupDeploymentPathOutputs(expected.outputDirs.deploymentPath);
  const producers = validateProducerSteps(plan, refs, expected);

  let substrateInstallReportPath;
  if (producers.substrateInstall) {
    runCommand(producers.substrateInstall.step.argv, 'operator-inputs producer substrate-install');
    await validateSubstrateInstallOutputs(producers.substrateInstall, expected);
    substrateInstallReportPath = producers.substrateInstall.reportPath;
  }

  let producerReportPath;
  let onlineDeploymentGateReportPath;
  let airgapConsumeReportPath;
  let airgapDeploymentGateReportPath;
  let airgapBundleCheckReportPath;
  if (producers.airgapConsume) {
    runCommand(
      producers.airgapConsume.step.argv,
      'operator-inputs producer airgap-consume-rehearsal'
    );
    const airgapReports = await validateAirgapConsumeOutputs(producers.airgapConsume, expected);
    producerReportPath = producers.airgapConsume.reportPath;
    airgapConsumeReportPath = producers.airgapConsume.reportPath;
    airgapDeploymentGateReportPath = airgapReports.deploymentGateReportPath;
    airgapBundleCheckReportPath = airgapReports.bundleCheckReportPath;
  } else {
    runCommand(
      producers.onlineDeploymentGate.step.argv,
      'operator-inputs producer online-deployment-gate'
    );
    await requireGeneratedReport(
      producers.onlineDeploymentGate.reportPath,
      'online-deployment-gate report'
    );
    producerReportPath = producers.onlineDeploymentGate.reportPath;
    onlineDeploymentGateReportPath = producers.onlineDeploymentGate.reportPath;
  }

  const finalizerRefs = producers.airgapConsume ? airgapBundleComponents : refs;
  const finalizerArgv = [
    'bash',
    VERIFY_RELEASE_SCRIPT,
    '--deployment-path',
    '--operator-path',
    expected.deploymentPath,
    '--release-contract',
    finalizerRefs.release_contract.absolute_path,
    '--deploy-template-package',
    finalizerRefs.deploy_template_package.absolute_path
  ];
  if (producers.airgapConsume) {
    finalizerArgv.push(
      '--airgap-deployment-gate-report',
      airgapDeploymentGateReportPath,
      '--airgap-bundle-check-report',
      airgapBundleCheckReportPath,
      '--airgap-bundle-manifest',
      refs.airgap_bundle_manifest.absolute_path
    );
  } else {
    finalizerArgv.push(
      '--online-deployment-gate-report',
      producers.onlineDeploymentGate.reportPath
    );
  }
  if (producers.substrateInstall) {
    finalizerArgv.push(
      '--substrate-install-report',
      producers.substrateInstall.reportPath,
      '--confirm-install-substrates',
      expected.install.operatorRunId
    );
  }
  finalizerArgv.push('--output-dir', expected.outputDirs.deploymentPath);
  try {
    runCommand(finalizerArgv, 'operator-inputs deployment-path finalizer');
  } catch (error) {
    await cleanupDeploymentPathOutputs(expected.outputDirs.deploymentPath);
    throw error;
  }

  const deploymentPathReport = path.join(expected.outputDirs.deploymentPath, DEPLOYMENT_PATH_REPORT_FILE);
  const finalizerManifest = path.join(
    expected.outputDirs.deploymentPath,
    DEPLOYMENT_PATH_FINALIZER_MANIFEST
  );
  await requireGeneratedReport(deploymentPathReport, 'deployment-path report');
  await requireFile(finalizerManifest, 'deployment-path finalizer manifest');

  return {
    planPath: canonicalPlanPath,
    producerReportPath,
    onlineDeploymentGateReportPath,
    airgapConsumeReportPath,
    airgapDeploymentGateReportPath,
    airgapBundleCheckReportPath,
    substrateInstallReportPath,
    deploymentPathReport,
    finalizerManifest,
    sourceEvidenceDir: path.join(
      expected.outputDirs.deploymentPath,
      DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR
    )
  };
}

export { OperatorInputsRunnerError };
