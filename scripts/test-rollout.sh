#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
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
let appImage = inventory.get('agentsmith_app');

if (!appImage) {
  throw new Error('missing fixture image inventory');
}

if (mutation === 'unknown_image') {
  appImage = `ghcr.io/agentsmith-project/not-in-contract:${contract.release_id}@sha256:${'9'.repeat(64)}`;
}

fs.mkdirSync(renderedManifests, { recursive: true });

if (mutation === 'job') {
  const job = {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: {
      name: 'agentsmith-api-migration'
    },
    spec: {
      template: {
        spec: {
          containers: [
            {
              name: 'api',
              image: appImage
            }
          ]
        }
      }
    }
  };
  fs.writeFileSync(path.join(renderedManifests, 'job.json'), `${JSON.stringify(job, null, 2)}\n`);
  process.exit(0);
}

fs.writeFileSync(
  path.join(renderedManifests, 'deployment.yaml'),
  `apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      initContainers:
        - name: schema
          image: ${appImage}
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
  if [[ "$arg" == "rollout" || "$arg" == "get" ]]; then
    command_name="$arg"
    break
  fi
done

if [[ "$command_name" == "rollout" ]]; then
  if [[ "\${FAKE_KUBECTL_ROLLOUT_MODE:-pass}" == "fail" ]]; then
    echo "rollout failed token=plain-secret-value" >&2
    exit 1
  fi
  echo "deployment rolled out token=plain-secret-value"
  exit 0
fi

if [[ "$command_name" == "get" ]]; then
  get_target=""
  selector=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "get" ]]; then
      get_target="$arg"
    fi
    if [[ "$previous" == "--selector" ]]; then
      selector="$arg"
    fi
    previous="$arg"
  done

  if [[ "$get_target" == "Deployment/agentsmith-web" ]]; then
    cat <<'JSON'
{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/part":"web","app.kubernetes.io/name":"agentsmith-web"}}}}
JSON
    exit 0
  fi

  if [[ "$get_target" == "pods" ]]; then
    expected_selector="app.kubernetes.io/name=agentsmith-web,app.kubernetes.io/part=web"
    if [[ "\${FAKE_KUBECTL_PODS_MODE:-full}" == "stale_unrelated_digest" ]]; then
      if [[ "$selector" == "$expected_selector" ]]; then
        cat <<'JSON'
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"containerStatuses":[{"name":"web","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:9999999999999999999999999999999999999999999999999999999999999999","imageID":"docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:9999999999999999999999999999999999999999999999999999999999999999"}]}}]}
JSON
        exit 0
      fi
      cat <<'JSON'
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"containerStatuses":[{"name":"web","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:9999999999999999999999999999999999999999999999999999999999999999","imageID":"docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:9999999999999999999999999999999999999999999999999999999999999999"}]}},{"metadata":{"name":"unrelated-stale-pod"},"status":{"containerStatuses":[{"name":"schema","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":"docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}}]}
JSON
      exit 0
    fi

    if [[ "\${FAKE_KUBECTL_PODS_MODE:-full}" == "missing_digest" ]]; then
    cat <<'JSON'
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"containerStatuses":[{"name":"web","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0","imageID":""}]}}]}
JSON
      exit 0
    fi

    if [[ "\${FAKE_KUBECTL_PODS_MODE:-full}" == "rewritten_ref_same_digest" ]]; then
    cat <<'JSON'
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"runtime.registry.example/rewritten/agentsmith-app:runtime@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":"docker-pullable://runtime.registry.example/rewritten/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"}],"containerStatuses":[{"name":"web","image":"runtime.registry.example/rewritten/agentsmith-app:runtime@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":""}]}}]}
JSON
      exit 0
    fi
    cat <<'JSON'
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":"docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"}],"containerStatuses":[{"name":"web","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":""}]}}]}
JSON
    exit 0
  fi
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

assert_no_report() {
  local report_file="$1"
  if [[ -e "$report_file" ]]; then
    fail "failed rollout must not leave rollout-report.json"
  fi
}

run_rollout() {
  local rendered_manifests="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"
  if (($# >= 3)); then
    shift 3
  else
    shift 2
  fi

  run_rollout_raw "$VALID_CONTRACT" "$rendered_manifests" "$output_dir" "$target_profile" "$@"
}

run_rollout_raw() {
  local release_contract="$1"
  local rendered_manifests="$2"
  local output_dir="$3"
  local target_profile="$4"
  shift 4

  local command=(
    bash "$ROOT_DIR/scripts/verify-release.sh" --rollout
    --release-contract "$release_contract"
    --rendered-manifests "$rendered_manifests"
    --target-profile "$target_profile"
    --namespace agentsmith
    --output-dir "$output_dir"
    --kubectl "$FAKE_KUBECTL"
  )
  command+=("$@")

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  FAKE_KUBECTL_ROLLOUT_MODE="${FAKE_KUBECTL_ROLLOUT_MODE:-pass}" \
  FAKE_KUBECTL_PODS_MODE="${FAKE_KUBECTL_PODS_MODE:-full}" \
    "${command[@]}"
}

run_rollout_from_release_kit() {
  local release_kit_root="$1"
  local release_contract="$2"
  local rendered_manifests="$3"
  local output_dir="$4"
  local target_profile="$5"
  shift 5

  local command=(
    bash "$release_kit_root/scripts/verify-release.sh" --rollout
    --release-contract "$release_contract"
    --rendered-manifests "$rendered_manifests"
    --target-profile "$target_profile"
    --namespace agentsmith
    --output-dir "$output_dir"
    --kubectl "$FAKE_KUBECTL"
  )
  command+=("$@")

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  FAKE_KUBECTL_ROLLOUT_MODE="${FAKE_KUBECTL_ROLLOUT_MODE:-pass}" \
  FAKE_KUBECTL_PODS_MODE="${FAKE_KUBECTL_PODS_MODE:-full}" \
    "${command[@]}"
}

assert_rollout_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" "$TARGET_PROFILE" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.kubernetes-rollout-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'kubernetes_rollout_imageid_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('rollout report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.namespace !== 'agentsmith') {
  throw new Error(`unexpected namespace: ${report.namespace}`);
}
if (report.timeout !== '120s') {
  throw new Error(`unexpected timeout: ${report.timeout}`);
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('release contract digest is missing');
}
if (!Array.isArray(report.rollout_resource_refs) || report.rollout_resource_refs.length !== 1) {
  throw new Error('rollout report must include one rollout resource ref');
}
if (report.rollout_resource_refs[0].kind !== 'Deployment' || report.rollout_resource_refs[0].name !== 'agentsmith-web') {
  throw new Error('rollout resource ref is not the fixture deployment');
}
if (report.rollout_resource_refs[0].selector !== 'app.kubernetes.io/name=agentsmith-web,app.kubernetes.io/part=web') {
  throw new Error(`unexpected rollout selector: ${report.rollout_resource_refs[0].selector}`);
}
if (!Array.isArray(report.expected_image_digests) || report.expected_image_digests.length !== 1) {
  throw new Error('rollout report must include the fixture image digest');
}
const expected = new Set(report.expected_image_digests.map((entry) => entry.digest));
const fixtureDigest = `sha256:${'1'.repeat(64)}`;
if (!expected.has(fixtureDigest)) {
  throw new Error(`missing expected digest: ${fixtureDigest}`);
}
if ('observed_live_image_ids_summary' in report) {
  throw new Error('rollout report must use observed_live_image_digest_summary');
}
const observed = report.observed_live_image_digest_summary;
if (observed?.pods_count !== 1 || observed?.status_entries_count !== 2) {
  throw new Error('live digest summary must include pod and status-entry counts');
}
if (observed.image_id_count !== 1 || observed.image_field_fallback_count !== 1 || observed.missing_digest_count !== 0) {
  throw new Error('live digest summary must include source breakdown');
}
if (!Array.isArray(observed.matched_expected_digests) || observed.matched_expected_digests.length !== 1) {
  throw new Error('live digest summary must match the expected digest');
}
if (!Array.isArray(report.workload_summaries) || report.workload_summaries.length !== 1) {
  throw new Error('rollout report must include one workload summary');
}
if (report.workload_summaries[0].resource_ref?.selector !== report.rollout_resource_refs[0].selector) {
  throw new Error('workload summary must keep the selector-scoped resource ref');
}
if (report.render_check?.scope !== 'render_check_image_inventory_only' || report.render_check?.status !== 'pass') {
  throw new Error('rollout report must include render-check pass summary');
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('rollout report must not claim a verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('rollout report must not include AgentSmith product flow fields');
}
if (/plain-secret-value|token=|deployment rolled out|rollout failed/.test(serialized)) {
  throw new Error('rollout report leaked raw kubectl stdout or stderr');
}
if (/kubeconfig/i.test(serialized)) {
  throw new Error('rollout report must not include kubeconfig data or field names');
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
run_rollout "$valid_manifests" "$valid_output" "$TARGET_PROFILE" >/dev/null
grep -q 'rollout status Deployment/agentsmith-web --namespace agentsmith --timeout 120s' "$KUBECTL_LOG" || fail "fake kubectl did not receive rollout status call"
grep -q 'get Deployment/agentsmith-web --namespace agentsmith -o json' "$KUBECTL_LOG" || fail "fake kubectl did not receive workload get call"
grep -q 'get pods --namespace agentsmith --selector app.kubernetes.io/name=agentsmith-web,app.kubernetes.io/part=web -o json' "$KUBECTL_LOG" || fail "fake kubectl did not receive selector-scoped get pods call"
assert_rollout_report "$valid_output/rollout-report.json"
pass "rollout happy path calls kubectl and writes non-readiness report"

rewritten_ref_output="$TMP_DIR/out-rewritten-ref"
reset_kubectl_log
FAKE_KUBECTL_PODS_MODE=rewritten_ref_same_digest run_rollout "$valid_manifests" "$rewritten_ref_output" "$TARGET_PROFILE" >/dev/null
grep -q 'get pods --namespace agentsmith --selector app.kubernetes.io/name=agentsmith-web,app.kubernetes.io/part=web -o json' "$KUBECTL_LOG" || fail "fake kubectl did not receive selector-scoped get pods for rewritten-ref case"
assert_rollout_report "$rewritten_ref_output/rollout-report.json"
pass "source-registry rollout keeps digest-only semantics for rewritten live refs"

bad_manifests="$TMP_DIR/manifests-render-check-fail"
bad_output="$TMP_DIR/out-render-check-fail"
write_manifests "$bad_manifests" unknown_image
reset_kubectl_log
if run_rollout "$bad_manifests" "$bad_output" "$TARGET_PROFILE" >"$TMP_DIR/render-check-fail.out" 2>"$TMP_DIR/render-check-fail.err"; then
  cat "$TMP_DIR/render-check-fail.out" >&2
  cat "$TMP_DIR/render-check-fail.err" >&2
  fail "expected rollout to fail when render-check fails"
fi
assert_kubectl_not_called
assert_no_report "$bad_output/rollout-report.json"
pass "render-check failure stops before kubectl rollout"

rollout_fail_output="$TMP_DIR/out-rollout-fail"
reset_kubectl_log
if FAKE_KUBECTL_ROLLOUT_MODE=fail run_rollout "$valid_manifests" "$rollout_fail_output" "$TARGET_PROFILE" >"$TMP_DIR/rollout-fail.out" 2>"$TMP_DIR/rollout-fail.err"; then
  cat "$TMP_DIR/rollout-fail.out" >&2
  cat "$TMP_DIR/rollout-fail.err" >&2
  fail "expected rollout status failure to fail"
fi
grep -q 'rollout status Deployment/agentsmith-web' "$KUBECTL_LOG" || fail "fake kubectl did not receive rollout status before failure"
assert_no_report "$rollout_fail_output/rollout-report.json"
pass "rollout status failure leaves no pass report"

missing_digest_output="$TMP_DIR/out-missing-digest"
reset_kubectl_log
if FAKE_KUBECTL_PODS_MODE=missing_digest run_rollout "$valid_manifests" "$missing_digest_output" "$TARGET_PROFILE" >"$TMP_DIR/missing-digest.out" 2>"$TMP_DIR/missing-digest.err"; then
  cat "$TMP_DIR/missing-digest.out" >&2
  cat "$TMP_DIR/missing-digest.err" >&2
  fail "expected missing live digest to fail"
fi
grep -q 'get pods --namespace agentsmith --selector app.kubernetes.io/name=agentsmith-web,app.kubernetes.io/part=web -o json' "$KUBECTL_LOG" || fail "fake kubectl did not receive selector-scoped get pods before digest failure"
assert_no_report "$missing_digest_output/rollout-report.json"
pass "missing live image digest leaves no pass report"

stale_mask_output="$TMP_DIR/out-stale-mask"
reset_kubectl_log
if FAKE_KUBECTL_PODS_MODE=stale_unrelated_digest run_rollout "$valid_manifests" "$stale_mask_output" "$TARGET_PROFILE" >"$TMP_DIR/stale-mask.out" 2>"$TMP_DIR/stale-mask.err"; then
  cat "$TMP_DIR/stale-mask.out" >&2
  cat "$TMP_DIR/stale-mask.err" >&2
  fail "expected unrelated pod digest not to satisfy target workload"
fi
grep -q 'get pods --namespace agentsmith --selector app.kubernetes.io/name=agentsmith-web,app.kubernetes.io/part=web -o json' "$KUBECTL_LOG" || fail "fake kubectl did not receive selector-scoped get pods for stale-mask case"
assert_no_report "$stale_mask_output/rollout-report.json"
pass "unrelated pod digest cannot satisfy selector-scoped workload digest"

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  reset_kubectl_log
  if run_rollout "$valid_manifests" "$TMP_DIR/out-profile-$label" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid rollout target profile to fail: $label"
  fi
  assert_kubectl_not_called
  pass "invalid rollout target profile rejected: $label"
}

expect_profile_fail kind-rehearsal "kind_rehearsal/kit_installed/online"
expect_profile_fail airgap "existing_kubernetes/external_declared/airgap"
expect_profile_fail noncanonical-local-kind "local-kind/external_declared/online"
expect_profile_fail synonym-cluster "existing_kubernetes/cluster/online"

job_manifests="$TMP_DIR/manifests-job"
job_output="$TMP_DIR/out-job"
write_manifests "$job_manifests" job
reset_kubectl_log
if run_rollout "$job_manifests" "$job_output" "$TARGET_PROFILE" >"$TMP_DIR/job.out" 2>"$TMP_DIR/job.err"; then
  cat "$TMP_DIR/job.out" >&2
  cat "$TMP_DIR/job.err" >&2
  fail "expected unsupported workload kind to fail"
fi
assert_kubectl_not_called
assert_no_report "$job_output/rollout-report.json"
pass "unsupported workload kind rejected before kubectl rollout"

default_boundary_parent="$TMP_DIR/default-boundary"
default_release_kit="$default_boundary_parent/release-kit"
default_agentsmith="$default_boundary_parent/agentsmith"
mkdir -p "$default_release_kit/scripts" "$default_agentsmith"
cp "$ROOT_DIR/scripts/verify-release.sh" "$default_release_kit/scripts/verify-release.sh"
cp "$ROOT_DIR/scripts/verify-rollout.mjs" "$default_release_kit/scripts/verify-rollout.mjs"
cp "$ROOT_DIR/scripts/verify-render-check.mjs" "$default_release_kit/scripts/verify-render-check.mjs"
chmod +x "$default_release_kit/scripts/verify-release.sh" "$default_release_kit/scripts/verify-rollout.mjs" "$default_release_kit/scripts/verify-render-check.mjs"

default_forbidden_contract="$default_agentsmith/release-contract.json"
cp "$VALID_CONTRACT" "$default_forbidden_contract"
reset_kubectl_log
if run_rollout_from_release_kit "$default_release_kit" "$default_forbidden_contract" "$valid_manifests" "$TMP_DIR/out-default-contract" "$TARGET_PROFILE" >"$TMP_DIR/default-contract.out" 2>"$TMP_DIR/default-contract.err"; then
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
if run_rollout_from_release_kit "$default_release_kit" "$VALID_CONTRACT" "$default_forbidden_manifests" "$TMP_DIR/out-default-manifests" "$TARGET_PROFILE" >"$TMP_DIR/default-manifests.out" 2>"$TMP_DIR/default-manifests.err"; then
  cat "$TMP_DIR/default-manifests.out" >&2
  cat "$TMP_DIR/default-manifests.err" >&2
  fail "expected default sibling forbidden source root to reject rendered manifests"
fi
assert_boundary_failure "$TMP_DIR/default-manifests.out" "$TMP_DIR/default-manifests.err" default-sibling-rendered-manifests
assert_kubectl_not_called
pass "default sibling forbidden source root rejects rendered manifests before kubectl"

pass "Kubernetes rollout/live digest focused diagnostic tests completed"
