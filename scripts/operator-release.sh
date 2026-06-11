#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
REPORT_FILE="operator-release-surface-report.json"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <package-dir>
  bash scripts/operator-release.sh --operator-inputs <package-or-json> --doctor
  bash scripts/operator-release.sh --operator-inputs <package-or-json> --run
  bash scripts/operator-release.sh --ga-report \
    --operator-inputs <online-use-existing-package> \
    --operator-inputs <online-install-substrates-package> \
    --operator-inputs <airgap-use-existing-package> \
    --operator-inputs <airgap-install-substrates-package> \
    --product-readiness-report <json> \
    --post-deploy-product-smoke-report <online-json> \
    --post-deploy-product-smoke-report <airgap-json> \
    --output-dir <dir>

Operator facade:
  Use this facade for the GA operator path: prepare operator-inputs, run the
  selected package, and finish with --ga-report.

Operator package checks:
  --init-operator-inputs creates a package skeleton for one deployment_path.
  Add --doctor to list missing package refs/fields plus static package blockers
  without executing the path. A passing doctor only means static package checks
  passed; it is not runnable readiness or the final GA result.
  Add --run when the package is ready to execute the selected path.

Operator-inputs run:
  The current minimal orchestration slice supports online/use_existing,
  online/install_substrates, airgap/use_existing, and
  airgap/install_substrates.
  install_substrates runs the namespace-scoped installer first and deploys with
  the installer output substrate truth. Airgap paths use bundle-local release
  materials and package-local tools.

Success boundary:
  --run records package output consumed by --ga-report.
  Final release pass/fail is represented only by ga-release-report.json
  written by --ga-report.
  Required package outputs and AgentSmith product-side reports must already be
  available.

Final GA report:
  --ga-report consumes four operator-inputs packages that have already been
  run with --operator-inputs <package> --run, requires online and airgap
  post-deploy product smoke reports, and writes the final
  ga-release-report.json with pass/fail and blockers.
  Operators do not pass internal report paths.
USAGE
}

fail() {
  echo "error: $*" >&2
  usage >&2
  exit 2
}

find_arg_value() {
  local flag="$1"
  shift

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      "$flag")
        if [[ "$#" -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
          return 1
        fi
        printf '%s\n' "$2"
        return 0
        ;;
      "$flag"=*)
        printf '%s\n' "${1#*=}"
        return 0
        ;;
    esac
    shift
  done

  return 1
}

OPERATOR_SINGLETON_FLAGS=(
  --operator-inputs
  --bundle-root
  --bundle-manifest
  --output-dir
  --confirm-apply
  --release-contract
  --deploy-template-package
  --archive
  --target-registry
  --registry-probe
  --mode
  --rehearsal-label
  --operator-run-id
  --render-values
  --substrate-truth
  --target-prerequisites
  --namespace
  --kubeconfig
  --context
  --kubectl
  --archive-probe
  --image-loader
  --timeout
  --smoke-url
  --expected-status
  --allow-http
  --allow-localhost
  --timeout-ms
  --evidence-root
  --evidence-provenance
  --substrate-pack-manifest
  --substrate-install-inputs
  --routability-probe
  --runbook
  --script
  --profile-values-schema
  --profile-values-example
  --operator-prerequisites
)

OPERATOR_RAW_INTERNAL_FLAGS=(
  --substrate-install-inputs
  --confirm-substrate-install
  --confirm-install-parameters
  --substrate-install-report
  --confirm-install-substrates
  --operator-path
)

assert_no_equals_singleton_args() {
  local flag
  local arg

  for arg in "$@"; do
    for flag in "${OPERATOR_SINGLETON_FLAGS[@]}"; do
      case "$arg" in
        "$flag"=*)
          fail "operator facade does not accept equals form for singleton/control argument: $flag"
          ;;
      esac
    done
  done
}

assert_no_duplicate_singleton_args() {
  local flag
  local arg
  local count

  for flag in "${OPERATOR_SINGLETON_FLAGS[@]}"; do
    count=0
    for arg in "$@"; do
      case "$arg" in
        "$flag"|"$flag"=*)
          count=$((count + 1))
          ;;
      esac
    done
    if [[ "$count" -gt 1 ]]; then
      fail "duplicate singleton/control argument for operator facade: $flag"
    fi
  done
}

remove_operator_summary_if_requested() {
  local output_dir="${1:-}"
  if [[ -n "$output_dir" ]]; then
    rm -f "$output_dir/$REPORT_FILE"
  fi
}

is_machine_profile_vocabulary() {
  local value="$1"

  [[ "$value" =~ ^(existing_kubernetes|kind_rehearsal)/(external_declared|kit_installed)/(online|airgap)$ ]] ||
    [[ "$value" =~ ^(kind|local-kind|existing-cluster)/ ]]
}

reject_producer_vocabulary() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --target-profile|--target-profile=*)
        fail "operator surface does not accept producer argument: --target-profile"
        ;;
      external_declared|kit_installed|kind|local-kind|existing-cluster)
        fail "operator surface does not accept producer vocabulary parameter: $arg"
        ;;
      --confirm-apply=*)
        if is_machine_profile_vocabulary "${arg#*=}"; then
          fail "operator surface does not accept machine profile vocabulary parameter: ${arg#*=}"
        fi
        ;;
    esac

    if is_machine_profile_vocabulary "$arg"; then
      fail "operator surface does not accept machine profile vocabulary parameter: $arg"
    fi
  done
}

reject_raw_internal_flags() {
  local arg
  local flag

  for arg in "$@"; do
    for flag in "${OPERATOR_RAW_INTERNAL_FLAGS[@]}"; do
      if [[ "$surface/$substrate_strategy" == "airgap-bundle/kit_provided" && "$flag" == "--substrate-install-inputs" ]]; then
        continue
      fi
      case "$arg" in
        "$flag"|"$flag"=*)
          fail "operator facade does not accept internal installer/finalizer argument: $flag"
          ;;
      esac
    done
    case "$arg" in
      --operator-inputs|--operator-inputs=*)
        fail "--operator-inputs must be the first and only operator facade argument"
        ;;
      --run)
        fail "--run is accepted only after --operator-inputs <package-or-json>"
        ;;
    esac
  done
}

translate_operator_confirm_apply() {
  local operator_confirm="$1"
  local mapped_confirm="$2"
  shift 2
  translated_args=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --confirm-apply)
        if [[ "$#" -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
          fail "missing value for --confirm-apply"
        fi
        if [[ "$2" != "$operator_confirm" ]]; then
          fail "--confirm-apply must use operator confirmation: $operator_confirm"
        fi
        translated_args+=(--confirm-apply "$mapped_confirm")
        shift 2
        ;;
      --confirm-apply=*)
        local value="${1#*=}"
        if [[ -z "$value" ]]; then
          fail "missing value for --confirm-apply"
        fi
        if [[ "$value" != "$operator_confirm" ]]; then
          fail "--confirm-apply must use operator confirmation: $operator_confirm"
        fi
        translated_args+=(--confirm-apply "$mapped_confirm")
        shift
        ;;
      *)
        translated_args+=("$1")
        shift
        ;;
    esac
  done
}

require_arg_value() {
  local flag="$1"
  shift
  local value

  if ! value="$(find_arg_value "$flag" "$@")"; then
    fail "missing required producer argument for operator facade: $flag"
  fi
  printf '%s\n' "$value"
}

assert_airgap_consume_manifest_matches_machine_profile() {
  local bundle_root="$1"
  local bundle_manifest="$2"
  local expected_profile="$3"

  "$NODE_BIN" --input-type=module - "$bundle_root" "$bundle_manifest" "$expected_profile" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [bundleRootArg, bundleManifestArg, expectedProfile] = process.argv.slice(2);
const BUNDLE_MANIFEST_FILE = 'airgap-bundle-manifest.json';
const SUPPORTED_TARGET_PROFILES = [
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/airgap'
];

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function stringValue(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function objectValue(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function arrayValue(value, label) {
  if (!Array.isArray(value)) {
    fail(`${label} must be an array`);
  }
  return value;
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function lstatChecked(file, label) {
  try {
    return fs.lstatSync(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

function realpathChecked(file, label) {
  try {
    return fs.realpathSync(file);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

function resolveBundleRoot(input) {
  const requested = path.resolve(stringValue(input, 'bundle root'));
  const stat = lstatChecked(requested, 'bundle root');
  if (stat.isSymbolicLink()) {
    fail('bundle root must not be a symlink');
  }
  if (!stat.isDirectory()) {
    fail('bundle root must be a directory');
  }
  return realpathChecked(requested, 'bundle root');
}

function resolveBundleFile(input, bundleRoot) {
  const requested = path.resolve(stringValue(input, 'bundle manifest'));
  if (!isInsidePath(bundleRoot, requested)) {
    fail('bundle manifest must be inside bundle root');
  }
  const stat = lstatChecked(requested, 'bundle manifest');
  if (stat.isSymbolicLink()) {
    fail('bundle manifest must not be a symlink');
  }
  if (!stat.isFile()) {
    fail('bundle manifest must point to a file');
  }
  const realPath = realpathChecked(requested, 'bundle manifest');
  if (!isInsidePath(bundleRoot, realPath)) {
    fail('bundle manifest must resolve inside bundle root');
  }
  return realPath;
}

function resolveBundleComponentFile(manifest, bundleRoot, kind) {
  const components = arrayValue(manifest.components, 'bundle manifest components');
  const matches = components
    .map((value, index) => ({
      value: objectValue(value, `bundle manifest components[${index}]`),
      index
    }))
    .filter(({ value }) => value.kind === kind);
  if (matches.length !== 1) {
    fail(`bundle manifest components must include exactly one ${kind}`);
  }

  const { value, index } = matches[0];
  const relativePath = stringValue(value.path, `bundle manifest components[${index}].path`);
  const requested = path.resolve(bundleRoot, relativePath);
  if (!isInsidePath(bundleRoot, requested)) {
    fail(`bundle manifest components[${index}].path must stay inside bundle root`);
  }
  const stat = lstatChecked(requested, `bundle manifest components[${index}].path`);
  if (stat.isSymbolicLink()) {
    fail(`bundle manifest components[${index}].path must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`bundle manifest components[${index}].path must point to a file`);
  }
  const realPath = realpathChecked(requested, `bundle manifest components[${index}].path`);
  if (!isInsidePath(bundleRoot, realPath)) {
    fail(`bundle manifest components[${index}].path must resolve inside bundle root`);
  }
  return realPath;
}

function readJson(file, label) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

function parseTargetProfile(profile, label) {
  const value = stringValue(profile.value, `${label}.value`);
  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail(`${label}.value must be <target_cluster>/<substrate_source>/<distribution>`);
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!SUPPORTED_TARGET_PROFILES.includes(normalized)) {
    fail(`${label}.value must be an existing Kubernetes airgap profile`);
  }

  const fields = {
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
  for (const [field, expected] of Object.entries(fields)) {
    if (stringValue(profile[field], `${label}.${field}`) !== expected) {
      fail(`${label} fields must match ${label}.value`);
    }
  }
  return normalized;
}

function discoverTargetProfile(manifest, bundleRoot) {
  if (Object.hasOwn(manifest, 'target_profile')) {
    return parseTargetProfile(
      objectValue(manifest.target_profile, 'bundle manifest target_profile'),
      'bundle manifest target_profile'
    );
  }
  const imageMapPath = resolveBundleComponentFile(manifest, bundleRoot, 'image_map');
  const imageMap = objectValue(readJson(imageMapPath, 'image map'), 'image map');
  return parseTargetProfile(
    objectValue(imageMap.target_profile, 'image map target_profile'),
    'image map target_profile'
  );
}

const bundleRoot = resolveBundleRoot(bundleRootArg);
const bundleManifestPath = resolveBundleFile(
  bundleManifestArg || path.join(bundleRoot, BUNDLE_MANIFEST_FILE),
  bundleRoot
);
const manifest = objectValue(readJson(bundleManifestPath, 'bundle manifest'), 'bundle manifest');
const manifestProfile = discoverTargetProfile(manifest, bundleRoot);

if (manifestProfile !== expectedProfile) {
  fail(
    `operator airgap consume profile mismatch: facade maps to ${expectedProfile}, ` +
      `but bundle identity resolves to ${manifestProfile}`
  );
}
NODE
}

run_ga_report_facade() {
  "$NODE_BIN" --input-type=module - "$ROOT_DIR" "$@" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const rootDir = process.argv[2];
const argv = process.argv.slice(3);
const REPORT_FILE = 'ga-release-report.json';
const SUMMARY_FILE = 'ga-release-summary.md';
const EVIDENCE_INDEX_FILE = 'ga-evidence-index.json';
const OPERATOR_INPUTS_MANIFEST_FILE = 'operator-inputs.json';
const OPERATOR_INPUTS_INTERNAL_DIR = '.release-kit-internal';
const OPERATOR_INPUTS_PLAN_FILE = 'operator-inputs-plan.json';
const PATH_REPORT_FILE = 'deployment-path-report.json';
const FINALIZER_MANIFEST_FILE = 'deployment-path-finalizer-manifest.json';
const SOURCE_EVIDENCE_DIR = 'source-evidence';
const REQUIRED_DEPLOYMENT_PATHS = [
  'online/use_existing',
  'online/install_substrates',
  'airgap/use_existing',
  'airgap/install_substrates'
];
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;

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
  bash scripts/operator-release.sh --ga-report \\
    --operator-inputs <online-use-existing-package> \\
    --operator-inputs <online-install-substrates-package> \\
    --operator-inputs <airgap-use-existing-package> \\
    --operator-inputs <airgap-install-substrates-package> \\
    --product-readiness-report <json> \\
    --post-deploy-product-smoke-report <online-json> \\
    --post-deploy-product-smoke-report <airgap-json> \\
    --output-dir <dir>`;
}

function cliFail(message) {
  throw new CliError(message);
}

function fail(message) {
  throw new ValidationError(message);
}

function readArgValue(argvIndex, arg) {
  const value = argv[argvIndex + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function setSingleton(parsed, key, value, flag) {
  if (parsed[key]) {
    cliFail(`duplicate argument for --ga-report: ${flag}`);
  }
  parsed[key] = value;
}

function parseArgs() {
  const parsed = {
    operatorInputs: [],
    postDeployProductSmokeReports: []
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(index, arg);
      index += 1;
      return value;
    };

    switch (arg) {
      case '--operator-inputs':
        parsed.operatorInputs.push(nextValue());
        break;
      case '--product-readiness-report':
        setSingleton(parsed, 'productReadinessReport', nextValue(), arg);
        break;
      case '--post-deploy-product-smoke-report':
        parsed.postDeployProductSmokeReports.push(nextValue());
        break;
      case '--output-dir':
        setSingleton(parsed, 'outputDir', nextValue(), arg);
        break;
      case '--deployment-path-report':
        cliFail('--ga-report does not accept --deployment-path-report; provide the corresponding --operator-inputs package and rerun that package with --run if path evidence is missing');
        break;
      case '--release-contract':
      case '--deploy-template-package':
        cliFail(`${arg} is resolved from operator-inputs packages for --ga-report`);
        break;
      case '--run':
        cliFail('--run is accepted only with a single --operator-inputs package, not --ga-report');
        break;
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        if (arg.startsWith('--operator-inputs=')) {
          cliFail('--ga-report accepts repeated --operator-inputs as separate arguments only');
        }
        if (
          arg.startsWith('--product-readiness-report=') ||
          arg.startsWith('--post-deploy-product-smoke-report=') ||
          arg.startsWith('--output-dir=') ||
          arg.startsWith('--deployment-path-report=') ||
          arg.startsWith('--release-contract=') ||
          arg.startsWith('--deploy-template-package=')
        ) {
          cliFail(`--ga-report does not accept equals form: ${arg.split('=')[0]}`);
        }
        cliFail(`unknown --ga-report argument: ${arg}`);
    }
  }

  if (parsed.help) {
    return parsed;
  }
  if (parsed.operatorInputs.length !== REQUIRED_DEPLOYMENT_PATHS.length) {
    cliFail(
      `--ga-report requires exactly ${REQUIRED_DEPLOYMENT_PATHS.length} --operator-inputs packages: ` +
        REQUIRED_DEPLOYMENT_PATHS.join(', ')
    );
  }
  if (!parsed.productReadinessReport) {
    cliFail('missing required --product-readiness-report');
  }
  if (parsed.postDeployProductSmokeReports.length === 0) {
    cliFail('missing required --post-deploy-product-smoke-report');
  }
  if (!parsed.outputDir) {
    cliFail('missing required --output-dir');
  }
  return parsed;
}

function findOutputDirArg() {
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

async function removeStaleOutputFile(file) {
  try {
    await fs.rm(file, { force: true });
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') {
      return;
    }
    fail(`cannot remove stale GA output ${path.basename(file)}: ${error.message}`);
  }
}

async function clearStaleFinalOutputs(outputDir) {
  const resolvedOutputDir = path.resolve(outputDir);
  await removeStaleOutputFile(path.join(resolvedOutputDir, REPORT_FILE));
  await removeStaleOutputFile(path.join(resolvedOutputDir, SUMMARY_FILE));
  await removeStaleOutputFile(path.join(resolvedOutputDir, EVIDENCE_INDEX_FILE));
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function bestEffortRemoveOutputFile(file) {
  try {
    await fs.rm(file, { force: true });
  } catch {
    // Preserve the original output failure. Cleanup is best effort.
  }
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
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

function safePackageRelativePath(value, label) {
  const relativePath = requireString(value, label).replace(/\\/g, '/');
  const normalized = path.posix.normalize(relativePath);
  if (
    path.posix.isAbsolute(relativePath) ||
    normalized !== relativePath ||
    normalized === '.' ||
    normalized === '..' ||
    normalized.startsWith('../') ||
    normalized.split('/').includes('..')
  ) {
    fail(`${label} must be a package-relative path`);
  }
  return relativePath;
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

async function readJson(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  try {
    return {
      value: JSON.parse(buffer.toString('utf8')),
      digest: `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function readFileDigest(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function digestDirectory(root) {
  const entries = [];

  async function walk(absoluteDir, relativeDir = '') {
    let dirents;
    try {
      dirents = await fs.readdir(absoluteDir, { withFileTypes: true });
    } catch (error) {
      fail(`cannot read operator-inputs directory ref: ${error.message}`);
    }
    for (const dirent of dirents.sort((left, right) => left.name.localeCompare(right.name))) {
      const relativePath = relativeDir ? `${relativeDir}/${dirent.name}` : dirent.name;
      const absolutePath = path.join(absoluteDir, dirent.name);
      if (dirent.isSymbolicLink()) {
        fail(`operator-inputs directory ref contains a symlink: ${relativePath}`);
      }
      if (dirent.isDirectory()) {
        entries.push({ path: relativePath, type: 'directory' });
        await walk(absolutePath, relativePath);
        continue;
      }
      if (!dirent.isFile()) {
        fail(`operator-inputs directory ref contains a non-file entry: ${relativePath}`);
      }
      entries.push({
        path: relativePath,
        type: 'file',
        sha256: await readFileDigest(absolutePath, `operator-inputs directory ref ${relativePath}`)
      });
    }
  }

  await walk(root);
  return {
    entry_count: entries.length,
    tree_sha256: canonicalDigest(entries)
  };
}

async function requireNoSymlinkFile(file, label) {
  let stat;
  try {
    stat = await fs.lstat(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must be a regular file`);
  }
}

async function resolveOperatorInputsPackage(inputPath) {
  const requested = path.resolve(requireString(inputPath, '--operator-inputs'));
  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read operator-inputs package ${inputPath}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`operator-inputs package must not be a symlink: ${inputPath}`);
  }

  let packageRoot;
  let manifestPath;
  if (stat.isDirectory()) {
    packageRoot = await fs.realpath(requested);
    manifestPath = path.join(packageRoot, OPERATOR_INPUTS_MANIFEST_FILE);
    await requireNoSymlinkFile(manifestPath, 'operator-inputs manifest');
    manifestPath = await fs.realpath(manifestPath);
  } else if (stat.isFile()) {
    packageRoot = await fs.realpath(path.dirname(requested));
    manifestPath = await fs.realpath(requested);
  } else {
    fail(`operator-inputs package must be a directory or JSON manifest file: ${inputPath}`);
  }

  const internalDir = path.join(packageRoot, OPERATOR_INPUTS_INTERNAL_DIR);
  let internalStat;
  try {
    internalStat = await fs.lstat(internalDir);
  } catch (error) {
    fail(`operator-inputs package has no run plan; ${rerunMessage(inputPath)}: ${error.message}`);
  }
  if (internalStat.isSymbolicLink() || !internalStat.isDirectory()) {
    fail(`operator-inputs internal run output is invalid; ${rerunMessage(inputPath)}`);
  }

  const planPath = path.join(internalDir, OPERATOR_INPUTS_PLAN_FILE);
  await requireNoSymlinkFile(planPath, 'operator-inputs run plan');
  return {
    packageRoot,
    manifestPath,
    planPath
  };
}

async function validatePlanRef({ key, ref, packageRoot, packageInput, deploymentPath }) {
  const refObject = requireObject(ref, `operator-inputs plan input_refs.${key}`);
  const kind = requireString(refObject.kind, `operator-inputs plan input_refs.${key}.kind`);
  const relativePath = safePackageRelativePath(
    refObject.path,
    `operator-inputs plan input_refs.${key}.path`
  );
  const currentPath = path.join(packageRoot, relativePath);

  let stat;
  try {
    stat = await fs.lstat(currentPath);
  } catch (error) {
    fail(`operator-inputs ${key} ref is missing for ${deploymentPath}; ${rerunMessage(packageInput)}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`operator-inputs ${key} ref must not be a symlink for ${deploymentPath}; ${rerunMessage(packageInput)}`);
  }
  if (kind === 'file') {
    if (!stat.isFile()) {
      fail(`operator-inputs ${key} ref must be a file for ${deploymentPath}; ${rerunMessage(packageInput)}`);
    }
    const expectedDigest = requireDigest(
      refObject.sha256,
      `operator-inputs plan input_refs.${key}.sha256`
    );
    const actualDigest = await readFileDigest(currentPath, `operator-inputs ${key} ref`);
    if (actualDigest !== expectedDigest) {
      fail(`operator-inputs ${key} ref changed after package run for ${deploymentPath}; ${rerunMessage(packageInput)}`);
    }
    return {
      kind,
      path: currentPath,
      relativePath,
      sha256: expectedDigest
    };
  }
  if (kind === 'directory') {
    if (!stat.isDirectory()) {
      fail(`operator-inputs ${key} ref must be a directory for ${deploymentPath}; ${rerunMessage(packageInput)}`);
    }
    const expectedTreeDigest = requireDigest(
      refObject.tree_sha256,
      `operator-inputs plan input_refs.${key}.tree_sha256`
    );
    const actualTree = await digestDirectory(currentPath);
    if (actualTree.tree_sha256 !== expectedTreeDigest) {
      fail(`operator-inputs ${key} ref changed after package run for ${deploymentPath}; ${rerunMessage(packageInput)}`);
    }
    return {
      kind,
      path: currentPath,
      relativePath,
      tree_sha256: expectedTreeDigest
    };
  }
  fail(`operator-inputs ${key} ref kind is unsupported for ${deploymentPath}; ${rerunMessage(packageInput)}`);
}

function legacyPackageRelativePath({ legacyRoot, absolutePath, label }) {
  const root = path.resolve(requireString(legacyRoot, `${label} package root`));
  const target = path.resolve(requireString(absolutePath, label));
  const relative = path.relative(root, target).split(path.sep).join('/');
  if (
    relative === '' ||
    relative.startsWith('../') ||
    relative === '..' ||
    path.posix.isAbsolute(relative)
  ) {
    fail(`${label} must resolve inside the operator-inputs package`);
  }
  return safePackageRelativePath(relative, `${label} package-relative path`);
}

function resolveCurrentPackagePathFromPlan({ packageRoot, legacyRoot, plannedPath, label }) {
  const value = requireString(plannedPath, label);
  const relative = path.isAbsolute(value)
    ? legacyPackageRelativePath({ legacyRoot, absolutePath: value, label })
    : safePackageRelativePath(value, label);
  return path.join(packageRoot, relative);
}

async function readBoundPackagePlan(packageInput) {
  const { packageRoot, manifestPath, planPath } = await resolveOperatorInputsPackage(packageInput);
  const planInput = await readJson(planPath, 'operator-inputs run plan');
  const plan = requireObject(planInput.value, 'operator-inputs run plan');
  if (requireString(plan.schema_version, 'operator-inputs plan schema_version') !== 'agentsmith.operator-inputs-plan/v1') {
    fail(`operator-inputs run plan schema is unsupported; ${rerunMessage(packageInput)}`);
  }
  if (requireString(plan.status, 'operator-inputs plan status') !== 'pass') {
    fail(`operator-inputs run plan did not pass; ${rerunMessage(packageInput)}`);
  }
  const planDigest = requireDigest(plan.plan_sha256, 'operator-inputs plan plan_sha256');
  if (canonicalDigest({ ...plan, plan_sha256: null }) !== planDigest) {
    fail(`operator-inputs run plan digest changed; ${rerunMessage(packageInput)}`);
  }

  const deploymentPath = requireString(plan.deployment_path, 'operator-inputs deployment_path');
  const legacyRoot = requireString(plan.operator_inputs_root, 'operator-inputs plan operator_inputs_root');

  const packageInfo = requireObject(plan.package, 'operator-inputs plan package');
  const manifestRelativePath = safePackageRelativePath(
    packageInfo.manifest_relative_path,
    'operator-inputs plan package.manifest_relative_path'
  );
  if (packageInfo.manifest_path !== undefined) {
    const plannedManifestPath = requireString(
      packageInfo.manifest_path,
      'operator-inputs plan package.manifest_path'
    );
    const plannedManifestRelativePath = path.isAbsolute(plannedManifestPath)
      ? legacyPackageRelativePath({
          legacyRoot,
          absolutePath: plannedManifestPath,
          label: 'operator-inputs plan package.manifest_path'
        })
      : safePackageRelativePath(plannedManifestPath, 'operator-inputs plan package.manifest_path');
    if (plannedManifestRelativePath !== manifestRelativePath) {
      fail(`operator-inputs manifest path changed after package run for ${deploymentPath}; ${rerunMessage(packageInput)}`);
    }
  }
  const currentManifestPath = path.join(packageRoot, manifestRelativePath);
  if (path.resolve(manifestPath) !== path.resolve(currentManifestPath)) {
    fail(`operator-inputs manifest path changed after package run for ${deploymentPath}; ${rerunMessage(packageInput)}`);
  }
  const manifestInput = await readJson(manifestPath, 'operator-inputs manifest');
  if (
    manifestInput.digest !==
    requireDigest(packageInfo.manifest_sha256, 'operator-inputs plan package.manifest_sha256')
  ) {
    fail(`operator-inputs manifest changed after package run for ${deploymentPath}; ${rerunMessage(packageInput)}`);
  }

  const inputRefs = requireObject(plan.input_refs, 'operator-inputs plan input_refs');
  const boundInputRefs = {};
  for (const [key, ref] of Object.entries(inputRefs)) {
    boundInputRefs[key] = await validatePlanRef({ key, ref, packageRoot, packageInput, deploymentPath });
  }

  return {
    plan,
    planPath,
    packageRoot,
    legacyRoot,
    boundInputRefs
  };
}

function buildFailureEvidenceIndex(report) {
  return {
    schema: 'agentsmith.ga-evidence-index/v1',
    generated_at: report.generated_at,
    role: 'derived_from_ga_release_report',
    source_report: {
      path: REPORT_FILE,
      schema: report.schema,
      digest: canonicalDigest(report),
      status: report.status,
      formal_verdict: report.formal_verdict
    },
    artifact_index: null,
    deployment_paths: [],
    product_readiness: null,
    post_deploy_product_smoke: null,
    blockers: Array.isArray(report.blockers) ? report.blockers : []
  };
}

function failureSummary(report, message) {
  return [
    '# AgentSmith GA Release Summary',
    '',
    `Status: ${report.status}`,
    `Formal verdict: ${report.formal_verdict}`,
    '',
    'Blockers:',
    `- ${message}`,
    ''
  ].join('\n');
}

async function writeFailureOutputs(outputDir, error) {
  if (!outputDir) {
    return;
  }
  const resolvedOutputDir = path.resolve(outputDir);
  await clearStaleFinalOutputs(resolvedOutputDir);
  const stamp = `${process.pid}-${Date.now()}`;
  const reportFile = path.join(resolvedOutputDir, REPORT_FILE);
  const summaryFile = path.join(resolvedOutputDir, SUMMARY_FILE);
  const evidenceIndexFile = path.join(resolvedOutputDir, EVIDENCE_INDEX_FILE);
  const reportTemp = path.join(resolvedOutputDir, `.${REPORT_FILE}.${stamp}.tmp`);
  const summaryTemp = path.join(resolvedOutputDir, `.${SUMMARY_FILE}.${stamp}.tmp`);
  const evidenceIndexTemp = path.join(resolvedOutputDir, `.${EVIDENCE_INDEX_FILE}.${stamp}.tmp`);
  const message = error instanceof Error ? error.message : String(error);
  const report = {
    schema: 'agentsmith.ga-release-report/v1',
    status: 'fail',
    formal_verdict: 'not_issued',
    generated_at: new Date().toISOString(),
    summary: {
      conclusion: 'AgentSmith GA release aggregate blocked.'
    },
    blockers: [
      {
        message,
        exit_code: error?.exitCode ?? 1
      }
    ]
  };
  try {
    await writeJson(reportTemp, report);
    await writeJson(evidenceIndexTemp, buildFailureEvidenceIndex(report));
    await fs.writeFile(summaryTemp, failureSummary(report, message), 'utf8');
    await fs.rename(summaryTemp, summaryFile);
    await fs.rename(evidenceIndexTemp, evidenceIndexFile);
    await fs.rename(reportTemp, reportFile);
  } catch (outputError) {
    await Promise.all([
      bestEffortRemoveOutputFile(reportFile),
      bestEffortRemoveOutputFile(summaryFile),
      bestEffortRemoveOutputFile(evidenceIndexFile),
      bestEffortRemoveOutputFile(reportTemp),
      bestEffortRemoveOutputFile(summaryTemp),
      bestEffortRemoveOutputFile(evidenceIndexTemp)
    ]);
    throw outputError;
  }
  console.error(`FAIL: wrote ${REPORT_FILE} with formal_verdict=not_issued`);
}

async function finalReportExists(outputDir) {
  try {
    await fs.access(path.join(path.resolve(outputDir), REPORT_FILE));
    return true;
  } catch {
    return false;
  }
}

function verifierExitError(result) {
  const exitCode = result.status ?? 1;
  const combinedOutput = `${result.stderr || ''}\n${result.stdout || ''}`;
  const detail = combinedOutput
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line !== '' && !line.startsWith('PASS:'));
  const error = new Error(`GA verifier exited with code ${exitCode}${detail ? `: ${detail}` : ''}`);
  error.exitCode = exitCode;
  return error;
}

function rerunMessage(packageInput) {
  return `rerun the corresponding package: bash scripts/operator-release.sh --operator-inputs ${packageInput} --run`;
}

async function requirePathEvidenceEntry(file, kind, { deploymentPath, packageInput }) {
  let stat;
  try {
    stat = await fs.lstat(file);
  } catch (error) {
    if (error.code === 'ENOENT') {
      fail(`finalized path evidence is missing for ${deploymentPath}; ${rerunMessage(packageInput)}`);
    }
    fail(`cannot read finalized path evidence for ${deploymentPath}: ${error.message}; ${rerunMessage(packageInput)}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`finalized path evidence must not be a symlink for ${deploymentPath}; ${rerunMessage(packageInput)}`);
  }
  if (kind === 'file' && !stat.isFile()) {
    fail(`finalized path evidence file is invalid for ${deploymentPath}; ${rerunMessage(packageInput)}`);
  }
  if (kind === 'directory' && !stat.isDirectory()) {
    fail(`finalized path source evidence is invalid for ${deploymentPath}; ${rerunMessage(packageInput)}`);
  }
}

async function resolvePackage({ packageInput }) {
  const resolved = await readBoundPackagePlan(packageInput);
  const plan = resolved.plan;
  const deploymentPath = requireString(plan.deployment_path, 'operator-inputs deployment_path');
  if (!REQUIRED_DEPLOYMENT_PATHS.includes(deploymentPath)) {
    fail(`unsupported operator-inputs deployment_path for --ga-report: ${deploymentPath}`);
  }
  const pathOutputDir = resolveCurrentPackagePathFromPlan({
    packageRoot: resolved.packageRoot,
    legacyRoot: resolved.legacyRoot,
    plannedPath: plan._internal?.expected?.output_dirs?.deployment_path,
    label: `deployment-path output dir for ${deploymentPath}`
  });
  const pathReport = path.join(pathOutputDir, PATH_REPORT_FILE);
  await requirePathEvidenceEntry(pathReport, 'file', { deploymentPath, packageInput });
  await requirePathEvidenceEntry(
    path.join(pathOutputDir, FINALIZER_MANIFEST_FILE),
    'file',
    { deploymentPath, packageInput }
  );
  await requirePathEvidenceEntry(
    path.join(pathOutputDir, SOURCE_EVIDENCE_DIR),
    'directory',
    { deploymentPath, packageInput }
  );

  return {
    deploymentPath,
    pathReport,
    planPath: resolved.planPath,
    packageInput,
    releaseContract: resolved.boundInputRefs.release_contract,
    deployTemplatePackage: resolved.boundInputRefs.deploy_template_package
  };
}

function requireFileRef(ref, key, deploymentPath) {
  if (!ref || ref.kind !== 'file') {
    fail(`${key} ref is missing from operator-inputs package for ${deploymentPath}`);
  }
  return {
    path: requireString(ref.path, `${key} path for ${deploymentPath}`),
    sha256: requireDigest(ref.sha256, `${key} digest for ${deploymentPath}`)
  };
}

function pickSharedRef(resolvedPackages, key) {
  const first = requireFileRef(
    resolvedPackages[0][key],
    key,
    resolvedPackages[0].deploymentPath
  );
  for (const entry of resolvedPackages.slice(1)) {
    const current = requireFileRef(entry[key], key, entry.deploymentPath);
    if (current.sha256 !== first.sha256) {
      fail(`${key} digest differs across operator-inputs packages; rerun the mismatched package before --ga-report`);
    }
  }
  return first.path;
}

async function main() {
  let args;
  try {
    args = parseArgs();
  } catch (error) {
    const outputDir = findOutputDirArg();
    if (outputDir) {
      await writeFailureOutputs(outputDir, error);
    }
    throw error;
  }
  if (args.help) {
    console.log(usage());
    return;
  }

  await clearStaleFinalOutputs(args.outputDir);
  let verifyArgs;
  try {
    const resolvedPackages = [];
    const byDeploymentPath = new Map();
    for (const packageInput of args.operatorInputs) {
      const resolved = await resolvePackage({ packageInput });
      if (byDeploymentPath.has(resolved.deploymentPath)) {
        fail(
          `duplicate deployment_path ${resolved.deploymentPath}; provide one package for each of: ` +
            REQUIRED_DEPLOYMENT_PATHS.join(', ')
        );
      }
      byDeploymentPath.set(resolved.deploymentPath, resolved);
      resolvedPackages.push(resolved);
    }

    for (const deploymentPath of REQUIRED_DEPLOYMENT_PATHS) {
      if (!byDeploymentPath.has(deploymentPath)) {
        fail(`missing operator-inputs package for deployment_path ${deploymentPath}`);
      }
    }

    verifyArgs = [
      path.join(rootDir, 'scripts/verify-release.sh'),
      '--ga-release',
      '--release-contract',
      pickSharedRef(resolvedPackages, 'releaseContract'),
      '--deploy-template-package',
      pickSharedRef(resolvedPackages, 'deployTemplatePackage')
    ];
    for (const deploymentPath of REQUIRED_DEPLOYMENT_PATHS) {
      verifyArgs.push(
        '--deployment-path-report',
        byDeploymentPath.get(deploymentPath).pathReport
      );
    }
    for (const deploymentPath of REQUIRED_DEPLOYMENT_PATHS) {
      verifyArgs.push(
        '--operator-inputs-plan',
        byDeploymentPath.get(deploymentPath).planPath
      );
    }
    verifyArgs.push(
      '--product-readiness-report',
      args.productReadinessReport
    );
    for (const report of args.postDeployProductSmokeReports) {
      verifyArgs.push('--post-deploy-product-smoke-report', report);
    }
    verifyArgs.push(
      '--output-dir',
      args.outputDir
    );
  } catch (error) {
    await writeFailureOutputs(args.outputDir, error);
    throw error;
  }

  const result = spawnSync('bash', verifyArgs, {
    cwd: rootDir,
    encoding: 'utf8',
    env: process.env
  });
  if (result.error) {
    await writeFailureOutputs(args.outputDir, new Error(`cannot run GA verifier: ${result.error.message}`));
    fail(`cannot run GA verifier: ${result.error.message}`);
  }
  if (result.status !== 0) {
    if (result.stdout) {
      process.stdout.write(result.stdout);
    }
    if (result.stderr) {
      process.stderr.write(result.stderr);
    }
    if (!(await finalReportExists(args.outputDir))) {
      await writeFailureOutputs(args.outputDir, verifierExitError(result));
    }
    process.exit(result.status ?? 1);
  }

  console.log(`operator ga-release report: ${path.resolve(args.outputDir, REPORT_FILE)}`);
}

main().catch((error) => {
  const exitCode = error.exitCode ?? 1;
  console.error(`${exitCode === 2 ? 'error' : 'FAIL'}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
NODE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--ga-report" ]]; then
  shift
  run_ga_report_facade "$@"
  exit 0
fi

if [[ "${1:-}" == "--init-operator-inputs" ]]; then
  if [[ "$#" -ne 4 ]]; then
    fail "--init-operator-inputs accepts <deployment_path> --output-dir <package-dir>"
  fi
  if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    fail "missing deployment_path for --init-operator-inputs"
  fi
  if [[ "${3:-}" != "--output-dir" ]]; then
    fail "--init-operator-inputs requires --output-dir <package-dir>"
  fi
  if [[ -z "${4:-}" || "${4:-}" == --* ]]; then
    fail "missing package dir for --output-dir"
  fi
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --init "$2" --output-dir "$4"
  exit 0
fi

if [[ "${1:-}" == --init-operator-inputs=* ]]; then
  fail "operator facade accepts --init-operator-inputs as a separate argument only"
fi

if [[ "${1:-}" == "--operator-inputs" ]]; then
  if [[ "$#" -ne 2 && "$#" -ne 3 ]]; then
    fail "--operator-inputs accepts one directory or JSON manifest plus optional --doctor or --run"
  fi
  if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    fail "missing directory or JSON manifest for --operator-inputs"
  fi
  if [[ "$#" -eq 3 ]]; then
    if [[ "${3:-}" != "--run" && "${3:-}" != "--doctor" ]]; then
      fail "--operator-inputs accepts only optional --doctor or --run after the package or JSON manifest"
    fi
    if [[ "${3:-}" == "--doctor" ]]; then
      "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$2" --doctor
      exit 0
    fi
    "$NODE_BIN" "$ROOT_DIR/scripts/run-operator-inputs.mjs" --operator-inputs "$2"
    exit 0
  fi
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$2"
  exit 0
fi

if [[ "${1:-}" == --operator-inputs=* ]]; then
  fail "operator facade accepts --operator-inputs as a separate argument only"
fi

if [[ "${1:-}" == "--run" ]]; then
  fail "--run is accepted only after --operator-inputs <package-or-json>"
fi

if [[ "$#" -eq 0 ]]; then
  fail "missing operator command; use --operator-inputs <package-or-json> --doctor|--run or --ga-report"
fi

if [[ "${1:-}" != --* && "${AGENTSMITH_ALLOW_LEGACY_OPERATOR_RELEASE_DIAGNOSTIC:-}" != "1" ]]; then
  fail "legacy positional diagnostics are maintainer-only; use package-driven operator inputs instead: bash scripts/operator-release.sh --operator-inputs <package-or-json> --run"
fi

if [[ "$#" -lt 2 ]]; then
  fail "missing operator surface and substrate strategy"
fi

surface="$1"
substrate_strategy="$2"
shift 2

producer_mode=""
producer_name=""
machine_profile=""

case "$surface/$substrate_strategy" in
  online/use_existing)
    producer_mode="--online-deployment-gate"
    producer_name="online-deployment-gate"
    machine_profile="existing_kubernetes/external_declared/online"
    ;;
  online/kit_provided)
    producer_mode="--online-deployment-gate"
    producer_name="online-deployment-gate"
    machine_profile="existing_kubernetes/kit_installed/online"
    ;;
  airgap/use_existing)
    producer_mode="--airgap-consume-rehearsal"
    producer_name="airgap-consume-rehearsal"
    machine_profile="existing_kubernetes/external_declared/airgap"
    ;;
  airgap/kit_provided)
    producer_mode="--airgap-consume-rehearsal"
    producer_name="airgap-consume-rehearsal"
    machine_profile="existing_kubernetes/kit_installed/airgap"
    ;;
  airgap-bundle/use_existing)
    producer_mode="--bundle-create"
    producer_name="bundle-create"
    machine_profile="existing_kubernetes/external_declared/airgap"
    ;;
  airgap-bundle/kit_provided)
    producer_mode="--bundle-create"
    producer_name="bundle-create"
    machine_profile="existing_kubernetes/kit_installed/airgap"
    ;;
  online/install_substrates|airgap/install_substrates|airgap-bundle/install_substrates)
    fail "legacy positional diagnostics do not accept install_substrates; use package-driven operator inputs instead: bash scripts/operator-release.sh --operator-inputs <package-or-json> --run"
    ;;
  online/*)
    fail "unknown online substrate strategy: $substrate_strategy"
    ;;
  airgap/*)
    fail "unknown airgap substrate strategy: $substrate_strategy"
    ;;
  airgap-bundle/*)
    fail "unknown airgap-bundle substrate strategy: $substrate_strategy"
    ;;
  *)
    fail "unknown operator surface: $surface"
    ;;
esac

assert_no_equals_singleton_args "$@"
assert_no_duplicate_singleton_args "$@"
reject_raw_internal_flags "$@"
reject_producer_vocabulary "$@"
operator_confirm="$surface/$substrate_strategy"
translated_args=()
translate_operator_confirm_apply "$operator_confirm" "$machine_profile" "$@"

release_contract=""
output_dir="$(require_arg_value --output-dir "$@")"
bundle_root=""
bundle_manifest=""
target_registry=""
evidence_root=""

if [[ "$producer_name" != "airgap-consume-rehearsal" ]]; then
  release_contract="$(require_arg_value --release-contract "$@")"
fi

if evidence_root="$(find_arg_value --evidence-root "$@")"; then
  :
else
  evidence_root=""
fi

if [[ "$surface/$substrate_strategy" == "airgap-bundle/kit_provided" ]]; then
  require_arg_value --substrate-pack-manifest "$@" >/dev/null
  require_arg_value --substrate-install-inputs "$@" >/dev/null
fi

if [[ "$producer_name" == "bundle-create" ]]; then
  bundle_root="$(require_arg_value --bundle-root "$@")"
  target_registry="$(require_arg_value --target-registry "$@")"
elif [[ "$producer_name" == "airgap-consume-rehearsal" ]]; then
  bundle_root="$(require_arg_value --bundle-root "$@")"
  if bundle_manifest="$(find_arg_value --bundle-manifest "$@")"; then
    :
  else
    bundle_manifest=""
  fi
fi

if [[ "$producer_name" == "airgap-consume-rehearsal" ]]; then
  assert_airgap_consume_manifest_matches_machine_profile \
    "$bundle_root" \
    "$bundle_manifest" \
    "$machine_profile"
fi

remove_operator_summary_if_requested "$output_dir"

producer_args=(
  "$producer_mode"
)

if [[ "$producer_name" != "airgap-consume-rehearsal" ]]; then
  producer_args+=(
    --target-profile "$machine_profile"
  )
fi

producer_args+=(
  "${translated_args[@]}"
)

bash "$ROOT_DIR/scripts/verify-release.sh" "${producer_args[@]}"

summary_args=(
  --surface "$surface"
  --substrate-strategy "$substrate_strategy"
  --machine-profile "$machine_profile"
  --producer-mode "$producer_name"
  --output-dir "$output_dir"
)

if [[ -n "$release_contract" ]]; then
  summary_args+=(
    --release-contract "$release_contract"
  )
fi

if [[ "$producer_name" == "bundle-create" ]]; then
  summary_args+=(
    --bundle-root "$bundle_root"
    --target-registry "$target_registry"
  )
elif [[ "$producer_name" == "airgap-consume-rehearsal" ]]; then
  summary_args+=(
    --bundle-root "$bundle_root"
  )
  if [[ -n "$bundle_manifest" ]]; then
    summary_args+=(
      --bundle-manifest "$bundle_manifest"
    )
  fi
fi

if [[ "$producer_name" =~ ^(online-deployment-gate|bundle-create)$ && -n "$evidence_root" ]]; then
  summary_args+=(
    --evidence-root "$evidence_root"
  )
fi

"$NODE_BIN" "$ROOT_DIR/scripts/verify-operator-release-surface.mjs" "${summary_args[@]}"
