#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
UNSUPPORTED_PROFILE="existing_kubernetes/kit_installed/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
TARGET_REGISTRY="registry.example.internal/releases"

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
  local output_dir="$1"

  bash "$ROOT_DIR/scripts/verify-release.sh" --image-map \
    --release-contract "$VALID_CONTRACT" \
    --target-profile "$TARGET_PROFILE" \
    --target-registry "$TARGET_REGISTRY" \
    --output-dir "$output_dir"
}

run_registry_presence() {
  local release_contract="$1"
  local image_map="$2"
  local output_dir="$3"
  local target_profile="$4"
  local registry_probe="$5"

  bash "$ROOT_DIR/scripts/verify-release.sh" --registry-presence \
    --release-contract "$release_contract" \
    --image-map "$image_map" \
    --target-profile "$target_profile" \
    --registry-probe "$registry_probe" \
    --output-dir "$output_dir"
}

assert_no_report() {
  local report_file="$1"
  [[ ! -e "$report_file" ]] || fail "unexpected registry presence report exists: $report_file"
}

write_probe() {
  local output="$1"
  local mode="${2:-pass}"

  cat >"$output" <<SH
#!/usr/bin/env bash
set -euo pipefail

mode="$mode"
target_image="\${1:?target image required}"
expected_digest="\${2:?expected digest required}"

case "\$mode" in
  pass)
    [[ "\$target_image" == *@sha256:* ]] || exit 23
    printf '%s\n' "\$expected_digest"
    ;;
  mismatch)
    printf '%s\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  nonzero)
    printf '%s\n' 'TOKEN_SHOULD_NOT_LEAK_FROM_STDOUT'
    printf '%s\n' 'SECRET_STDERR_SHOULD_NOT_LEAK kubeconfig' >&2
    exit 42
    ;;
  sleep)
    sleep 10
    printf '%s\n' "\$expected_digest"
    ;;
  *)
    exit 64
    ;;
esac
SH
  chmod +x "$output"
}

mutate_image_map() {
  local input="$1"
  local output="$2"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$input" "$output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [input, output, mutation] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(input, 'utf8'));
const digest = (char) => `sha256:${char.repeat(64)}`;

switch (mutation) {
  case 'valid':
    break;
  case 'mirror_required_false':
    imageMap.mirror_required = false;
    break;
  case 'target_digest_mismatch':
    imageMap.mappings[0].target_digest = digest('a');
    break;
  case 'target_ref_outside_registry':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      'registry.example.internal',
      'registry-drift.example.internal'
    );
    break;
  case 'same_registry_repo_path_drift':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      `${imageMap.target_registry}/`,
      `${imageMap.target_registry}/manual-drift/`
    );
    break;
  case 'target_image_missing_digest':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /@sha256:[0-9a-f]{64}$/,
      ''
    );
    break;
  case 'release_contract_digest_mismatch':
    imageMap.release_contract.input_sha256 = digest('e');
    break;
  default:
    throw new Error(`unknown image-map mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(imageMap, null, 2)}\n`);
NODE
}

write_contract_and_bound_image_map() {
  local contract_output="$1"
  local image_map_input="$2"
  local image_map_output="$3"
  local mutation="$4"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$image_map_input" \
    "$contract_output" \
    "$image_map_output" \
    "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [validContract, imageMapInput, contractOutput, imageMapOutput, mutation] =
  process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(validContract, 'utf8'));
const imageMap = JSON.parse(fs.readFileSync(imageMapInput, 'utf8'));

switch (mutation) {
  case 'legacy_three_image_required_image_ids':
    contract.required_image_ids = [
      'agentsmith_app',
      'llmup',
      'ingress_nginx_controller'
    ];
    break;
  case 'required_current_id_absent_from_inventory':
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.id !== 'asbcp'
    );
    break;
  default:
    throw new Error(`unknown contract mutation: ${mutation}`);
}

const contractRaw = `${JSON.stringify(contract, null, 2)}\n`;
const contractDigest = `sha256:${crypto.createHash('sha256').update(contractRaw).digest('hex')}`;
imageMap.release_contract.input_sha256 = contractDigest;
imageMap.release_contract.deploy_image_inventory_count =
  contract.deploy_image_inventory.length;

fs.writeFileSync(contractOutput, contractRaw);
fs.writeFileSync(imageMapOutput, `${JSON.stringify(imageMap, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" "$TARGET_PROFILE" "$TARGET_REGISTRY" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile, expectedRegistry] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.registry-presence/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'registry_presence_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('registry presence report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.target_registry !== expectedRegistry) {
  throw new Error(`unexpected target registry: ${report.target_registry}`);
}
if (
  report.image_count !== 6 ||
  report.image_map?.image_count !== 6 ||
  !Array.isArray(report.mappings) ||
  report.mappings.length !== 6
) {
  throw new Error('registry presence report must contain six image mappings');
}
if (report.present_digest_summary?.matched_count !== 6) {
  throw new Error('registry presence report must summarize six matched digests');
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('release contract input sha is missing');
}
if (!report.image_map?.input_sha256?.startsWith('sha256:')) {
  throw new Error('image-map input sha is missing');
}
if (
  /stdout|stderr|registry_probe|probe_path|TOKEN_SHOULD_NOT_LEAK|SECRET_STDERR|kubeconfig|authorization|bearer/i.test(
    serialized
  )
) {
  throw new Error('registry presence report leaked probe or secret-looking payloads');
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('registry presence report must not claim verdict or readiness');
}
for (const mapping of report.mappings) {
  if (!mapping.id || !mapping.target_digest || !mapping.probe_digest) {
    throw new Error('mapping must include id, target_digest, and probe_digest');
  }
  if (mapping.target_digest !== mapping.probe_digest) {
    throw new Error(`probe digest mismatch in report for ${mapping.id}`);
  }
  if ('target_image' in mapping) {
    throw new Error('mapping must not include target_image in the focused report');
  }
}
NODE
}

expect_fail() {
  local label="$1"
  local release_contract="$2"
  local image_map="$3"
  local target_profile="$4"
  local registry_probe="$5"
  local expected_stderr="${6:-}"
  local output_dir="$TMP_DIR/out-$label"

  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true,"token":"TOKEN_SHOULD_BE_REMOVED"}' \
    >"$output_dir/registry-presence-report.json"

  if run_registry_presence "$release_contract" "$image_map" "$output_dir" "$target_profile" "$registry_probe" \
    >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected registry-presence case to fail: $label"
  fi

  if [[ -n "$expected_stderr" ]] && ! grep -Fq -- "$expected_stderr" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected registry-presence stderr to contain '$expected_stderr': $label"
  fi

  assert_no_report "$output_dir/registry-presence-report.json"
  pass "invalid registry presence rejected: $label"
}

image_map_output="$TMP_DIR/image-map-valid"
run_image_map "$image_map_output" >/dev/null
valid_image_map="$image_map_output/image-map.json"

pass_probe="$TMP_DIR/probe-pass.sh"
write_probe "$pass_probe" pass

valid_output="$TMP_DIR/out-valid"
run_registry_presence "$VALID_CONTRACT" "$valid_image_map" "$valid_output" "$TARGET_PROFILE" "$pass_probe" \
  >/dev/null
assert_report "$valid_output/registry-presence-report.json"
pass "registry presence accepts six target digest refs with readiness=false"

mirror_false_image_map="$TMP_DIR/image-map-mirror-false.json"
mutate_image_map "$valid_image_map" "$mirror_false_image_map" mirror_required_false
expect_fail \
  image-map-not-mirror-required \
  "$VALID_CONTRACT" \
  "$mirror_false_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe" \
  "image_map.mirror_required must be true"

target_digest_mismatch_image_map="$TMP_DIR/image-map-target-digest-mismatch.json"
mutate_image_map "$valid_image_map" "$target_digest_mismatch_image_map" target_digest_mismatch
expect_fail \
  target-digest-mismatch \
  "$VALID_CONTRACT" \
  "$target_digest_mismatch_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe"

outside_registry_image_map="$TMP_DIR/image-map-outside-registry.json"
mutate_image_map "$valid_image_map" "$outside_registry_image_map" target_ref_outside_registry
expect_fail \
  target-ref-outside-registry \
  "$VALID_CONTRACT" \
  "$outside_registry_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe"

same_registry_path_drift_image_map="$TMP_DIR/image-map-same-registry-path-drift.json"
mutate_image_map "$valid_image_map" "$same_registry_path_drift_image_map" same_registry_repo_path_drift
expect_fail \
  same-registry-repo-path-drift \
  "$VALID_CONTRACT" \
  "$same_registry_path_drift_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe" \
  "target_image must match deterministic image_map.target_registry mirror ref"

missing_digest_image_map="$TMP_DIR/image-map-missing-digest.json"
mutate_image_map "$valid_image_map" "$missing_digest_image_map" target_image_missing_digest
expect_fail \
  target-image-missing-digest \
  "$VALID_CONTRACT" \
  "$missing_digest_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe"

release_digest_mismatch_image_map="$TMP_DIR/image-map-release-digest-mismatch.json"
mutate_image_map "$valid_image_map" "$release_digest_mismatch_image_map" release_contract_digest_mismatch
expect_fail \
  release-contract-raw-sha-mismatch \
  "$VALID_CONTRACT" \
  "$release_digest_mismatch_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe"

mismatch_probe="$TMP_DIR/probe-mismatch.sh"
write_probe "$mismatch_probe" mismatch
expect_fail \
  probe-stdout-digest-mismatch \
  "$VALID_CONTRACT" \
  "$valid_image_map" \
  "$TARGET_PROFILE" \
  "$mismatch_probe" \
  "registry probe digest mismatch"

nonzero_probe="$TMP_DIR/probe-nonzero.sh"
write_probe "$nonzero_probe" nonzero
expect_fail \
  probe-nonzero \
  "$VALID_CONTRACT" \
  "$valid_image_map" \
  "$TARGET_PROFILE" \
  "$nonzero_probe" \
  "registry probe returned non-zero status"

sleep_probe="$TMP_DIR/probe-sleep.sh"
write_probe "$sleep_probe" sleep
expect_fail \
  probe-timeout \
  "$VALID_CONTRACT" \
  "$valid_image_map" \
  "$TARGET_PROFILE" \
  "$sleep_probe" \
  "registry probe timed out"

leak_output="$TMP_DIR/out-leak-scan"
mkdir -p "$leak_output"
printf '%s\n' '{"stale":true,"secret":"stale-kubeconfig"}' \
  >"$leak_output/registry-presence-report.json"
if run_registry_presence "$VALID_CONTRACT" "$valid_image_map" "$leak_output" "$TARGET_PROFILE" "$nonzero_probe" \
  >"$TMP_DIR/leak.out" 2>"$TMP_DIR/leak.err"; then
  fail "expected nonzero leak probe to fail"
fi
if grep -Eiq 'TOKEN_SHOULD_NOT_LEAK|SECRET_STDERR|stale-kubeconfig|kubeconfig' \
  "$TMP_DIR/leak.out" "$TMP_DIR/leak.err"; then
  cat "$TMP_DIR/leak.out" >&2
  cat "$TMP_DIR/leak.err" >&2
  fail "probe stdout/stderr or stale report content leaked"
fi
assert_no_report "$leak_output/registry-presence-report.json"
pass "probe stdout/stderr and stale report payloads are not leaked"

expect_fail \
  unsupported-target-profile \
  "$VALID_CONTRACT" \
  "$valid_image_map" \
  "$UNSUPPORTED_PROFILE" \
  "$pass_probe" \
  "--registry-presence only accepts $TARGET_PROFILE"

legacy_contract="$TMP_DIR/contract-legacy-required.json"
legacy_image_map="$TMP_DIR/image-map-legacy-required.json"
write_contract_and_bound_image_map \
  "$legacy_contract" \
  "$valid_image_map" \
  "$legacy_image_map" \
  legacy_three_image_required_image_ids
expect_fail \
  legacy-three-image-required-image-ids \
  "$legacy_contract" \
  "$legacy_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe" \
  "release_contract.required_image_ids must match current app image ids"

missing_inventory_contract="$TMP_DIR/contract-missing-inventory.json"
missing_inventory_image_map="$TMP_DIR/image-map-missing-inventory.json"
write_contract_and_bound_image_map \
  "$missing_inventory_contract" \
  "$valid_image_map" \
  "$missing_inventory_image_map" \
  required_current_id_absent_from_inventory
expect_fail \
  required-current-id-absent-from-inventory \
  "$missing_inventory_contract" \
  "$missing_inventory_image_map" \
  "$TARGET_PROFILE" \
  "$pass_probe" \
  "release_contract.required_image_ids contains id missing from release_contract.deploy_image_inventory"

pass "registry-presence focused diagnostic tests completed"
