#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
ONLINE_PROFILE="existing_kubernetes/external_declared/online"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

run_image_map() {
  local release_contract="$1"
  local output_dir="$2"
  local target_profile="$3"
  shift 3

  bash "$ROOT_DIR/scripts/verify-release.sh" --image-map \
    --release-contract "$release_contract" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir" \
    "$@"
}

assert_no_report() {
  local report_file="$1"
  [[ ! -e "$report_file" ]] || fail "unexpected image-map report exists: $report_file"
}

write_contract() {
  local output="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [validContract, output, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(validContract, 'utf8'));
const digest = (char) => `sha256:${char.repeat(64)}`;
const legacyThreeImageIds = ['agentsmith_app', 'llmup', 'ingress_nginx_controller'];

switch (mutation) {
  case 'valid':
    break;
  case 'tag_only_image':
    contract.deploy_image_inventory[0].image = contract.deploy_image_inventory[0].image.replace(
      /@sha256:[0-9a-f]{64}$/,
      ''
    );
    break;
  case 'digest_mismatch':
    contract.deploy_image_inventory[0].digest = digest('9');
    break;
  case 'duplicate_id':
    contract.deploy_image_inventory[1].id = contract.deploy_image_inventory[0].id;
    break;
  case 'duplicate_image':
    contract.deploy_image_inventory[1].image = contract.deploy_image_inventory[0].image;
    contract.deploy_image_inventory[1].digest = contract.deploy_image_inventory[0].digest;
    break;
  case 'duplicate_digest':
    contract.deploy_image_inventory[1].digest = contract.deploy_image_inventory[0].digest;
    contract.deploy_image_inventory[1].image = contract.deploy_image_inventory[1].image.replace(
      /@sha256:[0-9a-f]{64}$/,
      `@${contract.deploy_image_inventory[0].digest}`
    );
    break;
  case 'empty_inventory':
    contract.deploy_image_inventory = [];
    break;
  case 'legacy_three_image_required_image_ids':
    contract.required_image_ids = legacyThreeImageIds;
    break;
  case 'required_current_id_absent_from_inventory':
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.id !== 'asbcp'
    );
    break;
  case 'noncanonical_contract_target_profile':
    contract.target_profiles[1].target_cluster = 'existing-cluster';
    break;
  case 'noncanonical_contract_target_tuple':
    contract.target_profiles[0].substrate_source = 'cluster';
    break;
  case 'required_target_profile':
    contract.target_profiles[0].required = true;
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"
  local expected_profile="$2"
  local expected_mirror_required="$3"
  local expected_registry="${4:-}"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_profile" "$expected_mirror_required" "$expected_registry" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile, expectedMirrorRequiredText, expectedRegistry] =
  process.argv.slice(2);
const expectedMirrorRequired = expectedMirrorRequiredText === 'true';
const expectedImageCount = 6;
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.image-map/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'image_map_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('image-map report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('release contract input sha is missing');
}
if (report.mirror_required !== expectedMirrorRequired) {
  throw new Error(`unexpected mirror_required: ${report.mirror_required}`);
}
if (expectedRegistry) {
  if (report.target_registry !== expectedRegistry) {
    throw new Error(`unexpected target registry: ${report.target_registry}`);
  }
} else if ('target_registry' in report) {
  throw new Error('target_registry must be omitted when source images are used directly');
}
if (
  report.image_count !== expectedImageCount ||
  !Array.isArray(report.mappings) ||
  report.mappings.length !== expectedImageCount
) {
  throw new Error(`image-map report must contain ${expectedImageCount} app-current image mappings`);
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('image-map report must not claim verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('image-map report must not include AgentSmith product flow fields');
}
if (/password|token|secret|client_secret|kubeconfig|authorization|bearer/i.test(serialized)) {
  throw new Error('image-map report must not include raw secret-ish payloads');
}

for (const mapping of report.mappings) {
  if (!mapping.source || !mapping.source_image || !mapping.source_digest) {
    throw new Error('mapping must include source identity and digest');
  }
  if (!mapping.source_image.endsWith(`@${mapping.source_digest}`)) {
    throw new Error(`source digest mismatch for ${mapping.id}`);
  }
  if (mapping.target_digest !== mapping.source_digest) {
    throw new Error(`target digest mismatch for ${mapping.id}`);
  }
  if (expectedMirrorRequired) {
    if (mapping.action !== 'mirror_required') {
      throw new Error(`unexpected action for ${mapping.id}: ${mapping.action}`);
    }
    if (!mapping.target_image.startsWith(`${expectedRegistry}/`)) {
      throw new Error(`target image did not use target registry for ${mapping.id}`);
    }
  } else {
    if (mapping.action !== 'use_source') {
      throw new Error(`unexpected action for ${mapping.id}: ${mapping.action}`);
    }
    if (mapping.target_image !== mapping.source_image) {
      throw new Error(`target image must equal source image for ${mapping.id}`);
    }
  }
}

NODE
}

expect_contract_fail() {
  local label="$1"
  local mutation="$2"
  local expected_stderr="${3:-}"
  local contract_file="$TMP_DIR/contract-$label.json"
  local output_dir="$TMP_DIR/out-$label"

  write_contract "$contract_file" "$mutation"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/image-map.json"

  if run_image_map "$contract_file" "$output_dir" "$ONLINE_PROFILE" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid image-map contract case to fail: $label"
  fi

  if [[ -n "$expected_stderr" ]] && ! grep -Fq "$expected_stderr" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected image-map stderr to contain '$expected_stderr': $label"
  fi

  assert_no_report "$output_dir/image-map.json"
  pass "invalid image-map contract rejected: $label"
}

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local output_dir="$TMP_DIR/out-profile-$label"

  if run_image_map "$VALID_CONTRACT" "$output_dir" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  assert_no_report "$output_dir/image-map.json"
  pass "image-map target profile rejected: $label"
}

expect_registry_fail() {
  local label="$1"
  local target_registry="$2"
  local output_dir="$TMP_DIR/out-registry-$label"

  if run_image_map "$VALID_CONTRACT" "$output_dir" "$ONLINE_PROFILE" \
    --target-registry "$target_registry" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target registry to fail: $label"
  fi

  assert_no_report "$output_dir/image-map.json"
  pass "invalid target registry rejected: $label"
}

online_source_output="$TMP_DIR/out-online-source"
run_image_map "$VALID_CONTRACT" "$online_source_output" "$ONLINE_PROFILE" >/dev/null
assert_report "$online_source_output/image-map.json" "$ONLINE_PROFILE" false
pass "online image-map without target registry uses source digest-pinned refs"

online_mirror_registry="registry.example.internal/releases"
online_mirror_output="$TMP_DIR/out-online-mirror"
run_image_map "$VALID_CONTRACT" "$online_mirror_output" "$ONLINE_PROFILE" \
  --target-registry "$online_mirror_registry" >/dev/null
assert_report "$online_mirror_output/image-map.json" "$ONLINE_PROFILE" true "$online_mirror_registry"
pass "online image-map with target registry writes mirror-required refs"

airgap_registry="registry.example.internal:5000/releases"
airgap_output="$TMP_DIR/out-airgap"
run_image_map "$VALID_CONTRACT" "$airgap_output" "$AIRGAP_PROFILE" \
  --target-registry "$airgap_registry" >/dev/null
assert_report "$airgap_output/image-map.json" "$AIRGAP_PROFILE" true "$airgap_registry"
pass "airgap image-map with target registry accepted"

kit_online_output="$TMP_DIR/out-kit-online-source"
run_image_map "$VALID_CONTRACT" "$kit_online_output" "$KIT_ONLINE_PROFILE" >/dev/null
assert_report "$kit_online_output/image-map.json" "$KIT_ONLINE_PROFILE" false
pass "kit-installed online image-map writes source digest-pinned refs"

kit_airgap_registry="registry.example.internal:5000/kit/releases"
kit_airgap_output="$TMP_DIR/out-kit-airgap"
run_image_map "$VALID_CONTRACT" "$kit_airgap_output" "$KIT_AIRGAP_PROFILE" \
  --target-registry "$kit_airgap_registry" >/dev/null
assert_report "$kit_airgap_output/image-map.json" "$KIT_AIRGAP_PROFILE" true "$kit_airgap_registry"
pass "kit-installed airgap image-map with target registry accepted"

airgap_missing_output="$TMP_DIR/out-airgap-missing-registry"
mkdir -p "$airgap_missing_output"
printf '%s\n' '{"stale":true}' >"$airgap_missing_output/image-map.json"
if run_image_map "$VALID_CONTRACT" "$airgap_missing_output" "$AIRGAP_PROFILE" >"$TMP_DIR/airgap-missing.out" 2>"$TMP_DIR/airgap-missing.err"; then
  cat "$TMP_DIR/airgap-missing.out" >&2
  cat "$TMP_DIR/airgap-missing.err" >&2
  fail "expected airgap without target registry to fail"
fi
assert_no_report "$airgap_missing_output/image-map.json"
pass "airgap without target registry removes stale report and fails"

expect_profile_fail kind-rehearsal "kind_rehearsal/kit_installed/online"
expect_profile_fail noncanonical-local-kind "local-kind/external_declared/online"
expect_profile_fail noncanonical-existing-cluster "existing-cluster/external_declared/online"
expect_profile_fail synonym-kind "kind/external_declared/online"
expect_profile_fail synonym-substrate-cluster "existing_kubernetes/cluster/online"
expect_profile_fail synonym-distribution-cluster "existing_kubernetes/external_declared/cluster"

expect_registry_fail scheme "https://registry.example.internal/releases"
expect_registry_fail userinfo "user@registry.example.internal/releases"
expect_registry_fail localhost "localhost:5000/releases"
expect_registry_fail loopback "127.0.0.1:5000/releases"
expect_registry_fail ipv6-loopback "[::1]:5000/releases"
expect_registry_fail host-docker-internal "host.docker.internal/releases"
expect_registry_fail whitespace "registry.example.internal /releases"
expect_registry_fail query "registry.example.internal/releases?pull=true"
expect_registry_fail uppercase-namespace "registry.example.internal/Releases"
expect_registry_fail trailing-separator-namespace "registry.example.internal/releases-"

expect_contract_fail noncanonical-target-profile noncanonical_contract_target_profile
expect_contract_fail noncanonical-target-tuple noncanonical_contract_target_tuple
expect_contract_fail required-target-profile required_target_profile
expect_contract_fail tag-only-image tag_only_image
expect_contract_fail digest-mismatch digest_mismatch
expect_contract_fail duplicate-id duplicate_id
expect_contract_fail duplicate-image duplicate_image
expect_contract_fail duplicate-digest duplicate_digest
expect_contract_fail empty-inventory empty_inventory
expect_contract_fail \
  legacy-three-image-required-image-ids \
  legacy_three_image_required_image_ids \
  "release_contract.required_image_ids must match current app image ids"
expect_contract_fail \
  required-current-id-absent-from-inventory \
  required_current_id_absent_from_inventory \
  "release_contract.required_image_ids contains id missing from release_contract.deploy_image_inventory"

pass "image-map focused diagnostic tests completed"
