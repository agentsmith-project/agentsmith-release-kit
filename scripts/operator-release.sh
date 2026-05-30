#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
REPORT_FILE="operator-release-surface-report.json"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/operator-release.sh online use_existing <producer args without --target-profile>
  bash scripts/operator-release.sh online install_substrates <producer args without --target-profile>
  bash scripts/operator-release.sh airgap use_existing <producer args without --target-profile>
  bash scripts/operator-release.sh airgap install_substrates <producer args without --target-profile>
  bash scripts/operator-release.sh airgap-bundle use_existing <producer args without --target-profile>
  bash scripts/operator-release.sh airgap-bundle install_substrates <producer args without --target-profile>

Operator surface:
  online/use_existing maps internally to existing_kubernetes/external_declared/online.
  online/install_substrates maps internally to existing_kubernetes/kit_installed/online.
  airgap/use_existing maps internally to existing_kubernetes/external_declared/airgap.
  airgap/install_substrates maps internally to existing_kubernetes/kit_installed/airgap.
  airgap-bundle/use_existing maps internally to existing_kubernetes/external_declared/airgap.
  airgap-bundle/install_substrates maps internally to existing_kubernetes/kit_installed/airgap.

This facade forwards to existing producer diagnostics only:
  online/* -> scripts/verify-release.sh --online-deployment-gate
  airgap/* -> scripts/verify-release.sh --airgap-consume-rehearsal
  airgap-bundle/* -> scripts/verify-release.sh --bundle-create
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

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
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
  online/install_substrates)
    producer_mode="--online-deployment-gate"
    producer_name="online-deployment-gate"
    machine_profile="existing_kubernetes/kit_installed/online"
    ;;
  airgap/use_existing)
    producer_mode="--airgap-consume-rehearsal"
    producer_name="airgap-consume-rehearsal"
    machine_profile="existing_kubernetes/external_declared/airgap"
    ;;
  airgap/install_substrates)
    producer_mode="--airgap-consume-rehearsal"
    producer_name="airgap-consume-rehearsal"
    machine_profile="existing_kubernetes/kit_installed/airgap"
    ;;
  airgap-bundle/use_existing)
    producer_mode="--bundle-create"
    producer_name="bundle-create"
    machine_profile="existing_kubernetes/external_declared/airgap"
    ;;
  airgap-bundle/install_substrates)
    producer_mode="--bundle-create"
    producer_name="bundle-create"
    machine_profile="existing_kubernetes/kit_installed/airgap"
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

if [[ "$surface/$substrate_strategy" == "airgap-bundle/install_substrates" ]]; then
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

if [[ "$producer_name" == "online-deployment-gate" && -n "$evidence_root" ]]; then
  summary_args+=(
    --evidence-root "$evidence_root"
  )
fi

"$NODE_BIN" "$ROOT_DIR/scripts/verify-operator-release-surface.mjs" "${summary_args[@]}"
