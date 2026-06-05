#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
REPORT_FILE="operator-release-surface-report.json"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <package-dir>
  bash scripts/operator-release.sh --operator-inputs <package-or-json> [--doctor|--run]
  bash scripts/operator-release.sh --ga-report \
    --operator-inputs <online-use-existing-package> \
    --operator-inputs <online-install-substrates-package> \
    --operator-inputs <airgap-use-existing-package> \
    --operator-inputs <airgap-install-substrates-package> \
    --product-readiness-report <json> \
    --post-deploy-product-smoke-report <json> \
    --output-dir <dir>

Operator facade:
  This is the only operator-facing release-kit entry. Legacy positional flows
  are maintainer/internal diagnostics only; see docs/RELEASE_GATES.md.
  kit_provided is a maintainer/internal compatibility alias only; removal target: release-kit v1.0.0 GA cut.
  Operator packages use install_substrates.

Operator-inputs intake:
  --init-operator-inputs creates a package skeleton for one deployment_path.
  --operator-inputs validates one deployment-path input package and writes
  .release-kit-internal/operator-inputs-plan.json.
  Add --doctor to list missing package inputs without executing the path.

Operator-inputs run:
  Add --run to execute the current minimal orchestration slice. This currently
  supports online/use_existing, online/install_substrates, airgap/use_existing,
  and airgap/install_substrates with mode apply.
  install_substrates runs substrate-install, then online-deployment-gate bound
  to the installer output substrate truth for online, or bundle-check plus
  airgap-deployment-gate bound to that truth for airgap, then the internal
  deployment-path finalizer. Install packages do not provide substrate_truth.
  airgap/use_existing runs airgap-consume-rehearsal, extracts the
  nested bundle-check and deployment-gate reports, then runs the internal
  deployment-path finalizer. Server-dry-run modes fail fast.

Success boundary:
  --run produces path-level evidence for the release captain/finalizer to
  consume. Formal release success or failure is represented only by the final
  ga-release-report.json issued by the release finalizer/captain after required
  path evidence and AgentSmith product-side reports are available.

Final GA report:
  --ga-report consumes four operator-inputs packages that have already been
  run with --operator-inputs <package> --run, locates the finalized path
  evidence from those packages, and writes the final ga-release-report.json.
  A passing aggregate writes formal_verdict=issued; a blocked aggregate writes
  status=fail, formal_verdict=not_issued, and blockers in that same report.
  Operators do not pass .release-kit-internal deployment-path report paths.
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

function parseTargetProfile(profile) {
  const value = stringValue(profile.value, 'bundle manifest target_profile.value');
  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('bundle manifest target_profile.value must be <target_cluster>/<substrate_source>/<distribution>');
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!SUPPORTED_TARGET_PROFILES.includes(normalized)) {
    fail('bundle manifest target_profile.value must be an existing Kubernetes airgap profile');
  }

  const fields = {
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
  for (const [field, expected] of Object.entries(fields)) {
    if (stringValue(profile[field], `bundle manifest target_profile.${field}`) !== expected) {
      fail('bundle manifest target_profile fields must match target_profile.value');
    }
  }
  return normalized;
}

const bundleRoot = resolveBundleRoot(bundleRootArg);
const bundleManifestPath = resolveBundleFile(
  bundleManifestArg || path.join(bundleRoot, BUNDLE_MANIFEST_FILE),
  bundleRoot
);
const manifest = objectValue(readJson(bundleManifestPath, 'bundle manifest'), 'bundle manifest');
const targetProfile = objectValue(manifest.target_profile, 'bundle manifest target_profile');
const manifestProfile = parseTargetProfile(targetProfile);

if (manifestProfile !== expectedProfile) {
  fail(
    `operator airgap consume profile mismatch: facade maps to ${expectedProfile}, ` +
      `but bundle manifest target_profile.value is ${manifestProfile}`
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
import { pathToFileURL } from 'node:url';

const rootDir = process.argv[2];
const argv = process.argv.slice(3);
const REPORT_FILE = 'ga-release-report.json';
const SUMMARY_FILE = 'ga-release-summary.md';
const EVIDENCE_INDEX_FILE = 'ga-evidence-index.json';
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
    --post-deploy-product-smoke-report <json> \\
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
    operatorInputs: []
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
        setSingleton(parsed, 'postDeployProductSmokeReport', nextValue(), arg);
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
  if (!parsed.postDeployProductSmokeReport) {
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

async function writeFailureOutputs(outputDir, error) {
  if (!outputDir) {
    return;
  }
  const resolvedOutputDir = path.resolve(outputDir);
  await clearStaleFinalOutputs(resolvedOutputDir);
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
  await writeJson(path.join(resolvedOutputDir, REPORT_FILE), report);
  await writeJson(path.join(resolvedOutputDir, EVIDENCE_INDEX_FILE), buildFailureEvidenceIndex(report));
  await fs.writeFile(
    path.join(resolvedOutputDir, SUMMARY_FILE),
    [
      '# AgentSmith GA Release Summary',
      '',
      `Status: ${report.status}`,
      `Formal verdict: ${report.formal_verdict}`,
      '',
      'Blockers:',
      `- ${message}`,
      ''
    ].join('\n'),
    'utf8'
  );
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

async function resolvePackage({ resolveOperatorInputs, packageInput }) {
  let resolved;
  try {
    resolved = await resolveOperatorInputs({ inputPath: packageInput });
  } catch (error) {
    fail(`cannot resolve operator-inputs package ${packageInput}: ${error.message}`);
  }

  const plan = resolved.plan;
  const deploymentPath = requireString(plan.deployment_path, 'operator-inputs deployment_path');
  if (!REQUIRED_DEPLOYMENT_PATHS.includes(deploymentPath)) {
    fail(`unsupported operator-inputs deployment_path for --ga-report: ${deploymentPath}`);
  }
  const pathOutputDir = requireString(
    plan._internal?.expected?.output_dirs?.deployment_path,
    `deployment-path output dir for ${deploymentPath}`
  );
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
    releaseContract: plan.input_refs?.release_contract,
    deployTemplatePackage: plan.input_refs?.deploy_template_package
  };
}

function requireFileRef(ref, key, deploymentPath) {
  if (!ref || ref.kind !== 'file') {
    fail(`${key} ref is missing from operator-inputs package for ${deploymentPath}`);
  }
  return {
    path: requireString(ref.absolute_path, `${key} path for ${deploymentPath}`),
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
    const { resolveOperatorInputs } = await import(
      pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-resolver.mjs')).href
    );
    const resolvedPackages = [];
    const byDeploymentPath = new Map();
    for (const packageInput of args.operatorInputs) {
      const resolved = await resolvePackage({ resolveOperatorInputs, packageInput });
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
      args.productReadinessReport,
      '--post-deploy-product-smoke-report',
      args.postDeployProductSmokeReport,
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
