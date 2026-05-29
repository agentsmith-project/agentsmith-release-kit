#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
AIRGAP_TARGET_PROFILE="existing_kubernetes/external_declared/airgap"
KIT_ONLINE_TARGET_PROFILE="existing_kubernetes/kit_installed/online"
KIT_AIRGAP_TARGET_PROFILE="existing_kubernetes/kit_installed/airgap"
ALIAS_OFFLINE_TARGET_PROFILE="existing_kubernetes/external_declared/offline"
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

write_manifests() {
  local rendered_manifests="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$rendered_manifests" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, renderedManifests, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const inventory = new Map(contract.deploy_image_inventory.map((item) => [item.id, item.image]));
const unknownDigest = `sha256:${'e'.repeat(64)}`;
let appImage = inventory.get('agentsmith_app');

if (!appImage) {
  throw new Error('missing fixture app image');
}

if (mutation === 'unknown_image') {
  appImage = `ghcr.io/agentsmith-project/not-in-contract:${contract.release_id}@${unknownDigest}`;
}

fs.mkdirSync(renderedManifests, { recursive: true });
fs.writeFileSync(
  path.join(renderedManifests, 'deployment.yaml'),
  `apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${appImage}
`
);
NODE
}

write_fake_kubectl() {
  local fake_kubectl="$1"

  "$NODE_BIN" --input-type=module - "$fake_kubectl" <<'NODE'
import fs from 'node:fs';

const [fakeKubectl] = process.argv.slice(2);
fs.writeFileSync(
  fakeKubectl,
  `#!/usr/bin/env bash
set -euo pipefail
: "\${FAKE_KUBECTL_LOG:?}"
printf '%s\\n' "$*" >> "$FAKE_KUBECTL_LOG"

command_name=""
for arg in "$@"; do
  if [[ "$arg" == "version" || "$arg" == "apply" ]]; then
    command_name="$arg"
    break
  fi
done

if [[ "$command_name" == "version" ]]; then
  if [[ "\${FAKE_KUBECTL_VERSION_MODE:-json}" == "nonjson" ]]; then
    printf '%s\\n' "kubectl client output token=plain-secret-value client=v1.30.0"
    exit 0
  fi
  printf '%s\\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
  exit 0
fi

if [[ "$command_name" == "apply" ]]; then
  printf '%s\\n' "deployment.apps/agentsmith-web"
  exit 0
fi

echo "unexpected fake kubectl args: $*" >&2
exit 2
`
);
fs.chmodSync(fakeKubectl, 0o755);
NODE
}

KUBECTL_LOG="$TMP_DIR/kubectl.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"
write_fake_kubectl "$FAKE_KUBECTL"

reset_kubectl_log() {
  : >"$KUBECTL_LOG"
}

assert_kubectl_not_called() {
  if [[ -s "$KUBECTL_LOG" ]]; then
    cat "$KUBECTL_LOG" >&2
    fail "kubectl should not have been called"
  fi
}

run_apply() {
  local rendered_manifests="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"
  if (($# >= 3)); then
    shift 3
  else
    shift 2
  fi

  run_apply_raw "$VALID_CONTRACT" "$rendered_manifests" "$output_dir" "$target_profile" "$@"
}

run_apply_raw() {
  local release_contract="$1"
  local rendered_manifests="$2"
  local output_dir="$3"
  local target_profile="$4"
  shift 4

  local command=(
    bash "$ROOT_DIR/scripts/verify-release.sh" --apply
    --release-contract "$release_contract"
    --rendered-manifests "$rendered_manifests"
    --target-profile "$target_profile"
    --namespace agentsmith
    --output-dir "$output_dir"
    --kubectl "$FAKE_KUBECTL"
  )
  command+=("$@")

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" FAKE_KUBECTL_VERSION_MODE="${FAKE_KUBECTL_VERSION_MODE:-json}" "${command[@]}"
}

run_apply_from_release_kit() {
  local release_kit_root="$1"
  local release_contract="$2"
  local rendered_manifests="$3"
  local output_dir="$4"
  local target_profile="$5"
  shift 5

  local command=(
    bash "$release_kit_root/scripts/verify-release.sh" --apply
    --release-contract "$release_contract"
    --rendered-manifests "$rendered_manifests"
    --target-profile "$target_profile"
    --namespace agentsmith
    --output-dir "$output_dir"
    --kubectl "$FAKE_KUBECTL"
  )
  command+=("$@")

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" FAKE_KUBECTL_VERSION_MODE="${FAKE_KUBECTL_VERSION_MODE:-json}" "${command[@]}"
}

assert_apply_report() {
  local report_file="$1"
  local expected_mode="$2"
  local expected_operator_run_id="${3:-}"
  local expected_profile="${4:-$TARGET_PROFILE}"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_mode" "$expected_operator_run_id" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedMode, expectedOperatorRunId, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema_version !== 'agentsmith.kubernetes-apply-report/v1') {
  throw new Error(`unexpected schema_version: ${report.schema_version}`);
}
if (report.scope !== 'kubernetes_apply_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('apply report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.mode !== expectedMode) {
  throw new Error(`unexpected mode: ${report.mode}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.namespace !== 'agentsmith') {
  throw new Error(`unexpected namespace: ${report.namespace}`);
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('release contract digest is missing');
}
if (!Array.isArray(report.resource_refs) || report.resource_refs.length !== 1) {
  throw new Error('apply report must include manifest resource refs');
}
if (!Array.isArray(report.kubectl_resource_refs) || report.kubectl_resource_refs[0] !== 'deployment.apps/agentsmith-web') {
  throw new Error('apply report must include kubectl resource refs');
}
if (!report.kubectl_version?.client?.gitVersion || !report.kubectl_version?.server?.gitVersion) {
  throw new Error('apply report must include kubectl client and server versions');
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('apply report must not claim a verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('apply report must not include AgentSmith product flow fields');
}
if (expectedMode === 'apply') {
  if (report.operator_run_id !== expectedOperatorRunId) {
    throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
  }
} else if ('operator_run_id' in report) {
  throw new Error('dry-run report must not include operator_run_id');
}
NODE
}

assert_unparsed_version_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.kubectl_version?.parse_status !== 'unparsed') {
  throw new Error('unparsed kubectl version output must be marked parse_status=unparsed');
}
if (!report.kubectl_version?.output_sha256?.startsWith('sha256:')) {
  throw new Error('unparsed kubectl version output must keep a sha256 digest');
}
if ('output' in report.kubectl_version) {
  throw new Error('unparsed kubectl version output must not store raw stdout');
}
if ('client' in report.kubectl_version || 'server' in report.kubectl_version) {
  throw new Error('unparsed kubectl version output must not claim parsed client/server fields');
}
if (/plain-secret-value|token=|kubectl client output/.test(serialized)) {
  throw new Error('apply report leaked raw kubectl version stdout');
}
NODE
}

assert_boundary_failure() {
  local stdout_file="$1"
  local stderr_file="$2"
  local label="$3"

  if ! grep -Eiq 'forbidden|source|boundary|product source tree' "$stdout_file" "$stderr_file"; then
    cat "$stdout_file" >&2
    cat "$stderr_file" >&2
    fail "expected source-boundary failure message for: $label"
  fi
}

valid_manifests="$TMP_DIR/manifests-valid"
valid_output="$TMP_DIR/out-valid"
write_manifests "$valid_manifests" valid
reset_kubectl_log
run_apply "$valid_manifests" "$valid_output" "$TARGET_PROFILE" >/dev/null
grep -q 'version' "$KUBECTL_LOG" || fail "fake kubectl did not receive version call"
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "fake kubectl did not receive server dry-run apply call"
assert_apply_report "$valid_output/apply-report.json" server-dry-run
pass "server dry-run happy path calls kubectl dry-run and writes non-readiness report"

airgap_dry_run_output="$TMP_DIR/out-airgap-dry-run"
reset_kubectl_log
run_apply "$valid_manifests" "$airgap_dry_run_output" "$AIRGAP_TARGET_PROFILE" >/dev/null
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "airgap apply dry-run did not pass --dry-run=server"
assert_apply_report "$airgap_dry_run_output/apply-report.json" server-dry-run "" "$AIRGAP_TARGET_PROFILE"
pass "airgap server dry-run accepted without enabling kind or aliases"

kit_online_dry_run_output="$TMP_DIR/out-kit-online-dry-run"
reset_kubectl_log
run_apply "$valid_manifests" "$kit_online_dry_run_output" "$KIT_ONLINE_TARGET_PROFILE" >/dev/null
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "kit online apply dry-run did not pass --dry-run=server"
assert_apply_report "$kit_online_dry_run_output/apply-report.json" server-dry-run "" "$KIT_ONLINE_TARGET_PROFILE"
pass "kit-installed online server dry-run accepted without changing Kubernetes apply behavior"

unparsed_version_output="$TMP_DIR/out-unparsed-version"
reset_kubectl_log
FAKE_KUBECTL_VERSION_MODE=nonjson run_apply "$valid_manifests" "$unparsed_version_output" "$TARGET_PROFILE" >/dev/null
assert_unparsed_version_report "$unparsed_version_output/apply-report.json"
pass "non-JSON kubectl version output records only hash and unparsed marker"

apply_output="$TMP_DIR/out-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$apply_output" "$TARGET_PROFILE" \
  --mode=apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed apply must not pass --dry-run=server"
fi
assert_apply_report "$apply_output/apply-report.json" apply operator-run-1001
pass "confirmed apply requires operator run id and records it"

airgap_apply_output="$TMP_DIR/out-airgap-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$airgap_apply_output" "$AIRGAP_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$AIRGAP_TARGET_PROFILE" \
  --operator-run-id operator-run-airgap-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed airgap apply must not pass --dry-run=server"
fi
assert_apply_report "$airgap_apply_output/apply-report.json" apply operator-run-airgap-1001 "$AIRGAP_TARGET_PROFILE"
pass "confirmed airgap apply requires matching confirm target profile"

kit_online_apply_output="$TMP_DIR/out-kit-online-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$kit_online_apply_output" "$KIT_ONLINE_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$KIT_ONLINE_TARGET_PROFILE" \
  --operator-run-id operator-run-kit-online-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed kit online apply must not pass --dry-run=server"
fi
assert_apply_report "$kit_online_apply_output/apply-report.json" apply operator-run-kit-online-1001 "$KIT_ONLINE_TARGET_PROFILE"
pass "confirmed kit-installed online apply requires matching confirm target profile"

reset_kubectl_log
if run_apply "$valid_manifests" "$TMP_DIR/out-airgap-confirm-mismatch" "$AIRGAP_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-airgap-1002 >"$TMP_DIR/airgap-confirm-mismatch.out" 2>"$TMP_DIR/airgap-confirm-mismatch.err"; then
  fail "expected airgap apply with online confirm to fail"
fi
assert_kubectl_not_called
pass "airgap apply confirm must match the target profile exactly"

reset_kubectl_log
if run_apply "$valid_manifests" "$TMP_DIR/out-missing-confirm" "$TARGET_PROFILE" \
  --mode apply \
  --operator-run-id operator-run-1002 >"$TMP_DIR/missing-confirm.out" 2>"$TMP_DIR/missing-confirm.err"; then
  fail "expected apply without confirm to fail"
fi
assert_kubectl_not_called
pass "apply mode without confirm rejected"

reset_kubectl_log
if run_apply "$valid_manifests" "$TMP_DIR/out-missing-run-id" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" >"$TMP_DIR/missing-run-id.out" 2>"$TMP_DIR/missing-run-id.err"; then
  fail "expected apply without operator run id to fail"
fi
assert_kubectl_not_called
pass "apply mode without operator run id rejected"

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  reset_kubectl_log
  if run_apply "$valid_manifests" "$TMP_DIR/out-profile-$label" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid apply target profile to fail: $label"
  fi
  assert_kubectl_not_called
  pass "invalid apply target profile rejected: $label"
}

expect_profile_fail kind-rehearsal "kind_rehearsal/kit_installed/online"
expect_profile_fail kit-airgap "$KIT_AIRGAP_TARGET_PROFILE"
expect_profile_fail alias-offline "$ALIAS_OFFLINE_TARGET_PROFILE"
expect_profile_fail noncanonical-local-kind "local-kind/external_declared/online"
expect_profile_fail synonym-cluster "existing_kubernetes/cluster/online"

bad_manifests="$TMP_DIR/manifests-render-check-fail"
bad_output="$TMP_DIR/out-render-check-fail"
write_manifests "$bad_manifests" unknown_image
reset_kubectl_log
if run_apply "$bad_manifests" "$bad_output" "$TARGET_PROFILE" >"$TMP_DIR/render-check-fail.out" 2>"$TMP_DIR/render-check-fail.err"; then
  cat "$TMP_DIR/render-check-fail.out" >&2
  cat "$TMP_DIR/render-check-fail.err" >&2
  fail "expected apply to fail when render-check fails"
fi
assert_kubectl_not_called
if [[ -e "$bad_output/apply-report.json" ]]; then
  fail "failed apply must not leave apply-report.json"
fi
pass "render-check failure stops before kubectl apply"

explicit_forbidden_root="$TMP_DIR/explicit-forbidden-source"
explicit_forbidden_manifests="$explicit_forbidden_root/rendered-manifests"
write_manifests "$explicit_forbidden_manifests" valid
reset_kubectl_log
if run_apply_raw "$VALID_CONTRACT" "$explicit_forbidden_manifests" "$TMP_DIR/out-explicit-forbidden" "$TARGET_PROFILE" \
  --forbidden-source-root "$explicit_forbidden_root" >"$TMP_DIR/explicit-forbidden.out" 2>"$TMP_DIR/explicit-forbidden.err"; then
  cat "$TMP_DIR/explicit-forbidden.out" >&2
  cat "$TMP_DIR/explicit-forbidden.err" >&2
  fail "expected explicit forbidden source root to reject rendered manifests"
fi
assert_boundary_failure "$TMP_DIR/explicit-forbidden.out" "$TMP_DIR/explicit-forbidden.err" explicit-forbidden-rendered-manifests
assert_kubectl_not_called
pass "explicit forbidden source root rejects rendered manifests before kubectl"

default_boundary_parent="$TMP_DIR/default-boundary"
default_release_kit="$default_boundary_parent/release-kit"
default_agentsmith="$default_boundary_parent/agentsmith"
mkdir -p "$default_release_kit/scripts" "$default_agentsmith"
cp "$ROOT_DIR/scripts/verify-release.sh" "$default_release_kit/scripts/verify-release.sh"
cp "$ROOT_DIR/scripts/verify-apply.mjs" "$default_release_kit/scripts/verify-apply.mjs"
cp "$ROOT_DIR/scripts/verify-render-check.mjs" "$default_release_kit/scripts/verify-render-check.mjs"
chmod +x "$default_release_kit/scripts/verify-release.sh" "$default_release_kit/scripts/verify-apply.mjs" "$default_release_kit/scripts/verify-render-check.mjs"

default_forbidden_contract="$default_agentsmith/release-contract.json"
cp "$VALID_CONTRACT" "$default_forbidden_contract"
reset_kubectl_log
if run_apply_from_release_kit "$default_release_kit" "$default_forbidden_contract" "$valid_manifests" "$TMP_DIR/out-default-contract" "$TARGET_PROFILE" >"$TMP_DIR/default-contract.out" 2>"$TMP_DIR/default-contract.err"; then
  cat "$TMP_DIR/default-contract.out" >&2
  cat "$TMP_DIR/default-contract.err" >&2
  fail "expected default sibling forbidden source root to reject release contract"
fi
assert_boundary_failure "$TMP_DIR/default-contract.out" "$TMP_DIR/default-contract.err" default-sibling-release-contract
assert_kubectl_not_called
pass "default sibling forbidden source root rejects release contract before kubectl"

default_forbidden_manifests="$default_agentsmith/rendered-manifests"
write_manifests "$default_forbidden_manifests" valid
reset_kubectl_log
if run_apply_from_release_kit "$default_release_kit" "$VALID_CONTRACT" "$default_forbidden_manifests" "$TMP_DIR/out-default-manifests" "$TARGET_PROFILE" >"$TMP_DIR/default-manifests.out" 2>"$TMP_DIR/default-manifests.err"; then
  cat "$TMP_DIR/default-manifests.out" >&2
  cat "$TMP_DIR/default-manifests.err" >&2
  fail "expected default sibling forbidden source root to reject rendered manifests"
fi
assert_boundary_failure "$TMP_DIR/default-manifests.out" "$TMP_DIR/default-manifests.err" default-sibling-rendered-manifests
assert_kubectl_not_called
pass "default sibling forbidden source root rejects rendered manifests before kubectl"

pass "Kubernetes apply-only focused diagnostic tests completed"
