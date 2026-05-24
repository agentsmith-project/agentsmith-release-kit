#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"

TMP_DIR="$(mktemp -d)"
SERVER_PID=""
trap 'if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_rollout_report() {
  local output="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$output" "$TARGET_PROFILE" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [contractInput, output, profileValue, mutation] = process.argv.slice(2);
const contractRaw = fs.readFileSync(contractInput);
const contract = JSON.parse(contractRaw.toString('utf8'));
const [targetCluster, substrateSource, distribution] = profileValue.split('/');

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

const report = {
  schema: 'agentsmith.kubernetes-rollout-report/v1',
  scope: 'kubernetes_rollout_imageid_only',
  readiness: false,
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: digestBuffer(contractRaw),
    deploy_image_inventory_count: contract.deploy_image_inventory.length
  },
  target_profile: {
    value: profileValue,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  },
  namespace: 'agentsmith',
  timeout: '120s',
  rollout_resource_refs: [
    {
      kind: 'Deployment',
      name: 'agentsmith-web',
      namespace: 'agentsmith'
    }
  ],
  expected_image_digests: [
    {
      digest: `sha256:${'1'.repeat(64)}`,
      inventory_ids: ['web'],
      images_count: 1
    }
  ],
  observed_live_image_digest_summary: {
    pods_count: 1,
    status_entries_count: 1,
    image_id_count: 1,
    image_field_fallback_count: 0,
    missing_digest_count: 0,
    observed_digest_count: 1,
    observed_digests: [`sha256:${'1'.repeat(64)}`],
    matched_expected_digests: [`sha256:${'1'.repeat(64)}`]
  },
  generated_at: '2026-05-23T12:00:00.000Z'
};

switch (mutation) {
  case 'valid':
    break;
  case 'bad_status':
    report.status = 'fail';
    break;
  case 'bad_readiness':
    report.readiness = true;
    break;
  case 'bad_scope':
    report.scope = 'full_rollout';
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

start_server() {
  local ready_file="$TMP_DIR/server-ready"
  local log_file="$TMP_DIR/server-hits.log"
  local stdout_file="$TMP_DIR/server.out"
  local stderr_file="$TMP_DIR/server.err"

  "$NODE_BIN" --input-type=module - "$ready_file" "$log_file" >"$stdout_file" 2>"$stderr_file" <<'NODE' &
import fs from 'node:fs';
import http from 'node:http';

const [readyFile, logFile] = process.argv.slice(2);

const server = http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || '127.0.0.1'}`);
  fs.appendFileSync(logFile, `${request.method} ${url.pathname}\n`);

  if (url.pathname === '/ok') {
    response.statusCode = 200;
    response.setHeader('x-debug-token', 'plain-secret-value');
    response.end('route ok token=plain-secret-value');
    return;
  }

  if (url.pathname === '/created') {
    response.statusCode = 201;
    response.end('created');
    return;
  }

  response.statusCode = 404;
  response.end('not found token=plain-secret-value');
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(readyFile, String(server.address().port));
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
NODE
  SERVER_PID=$!

  for _ in {1..50}; do
    if [[ -s "$ready_file" ]]; then
      SERVER_PORT="$(<"$ready_file")"
      SERVER_LOG="$log_file"
      return
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$stdout_file" >&2 || true
      cat "$stderr_file" >&2 || true
      fail "route smoke test server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "route smoke test server did not become ready"
}

hit_count() {
  if [[ -f "$SERVER_LOG" ]]; then
    wc -l <"$SERVER_LOG" | tr -d '[:space:]'
    return
  fi
  echo 0
}

assert_no_report() {
  local report_file="$1"
  if [[ -e "$report_file" ]]; then
    fail "failed smoke must not leave smoke-report.json"
  fi
}

run_smoke() {
  local url="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"
  if (($# >= 3)); then
    shift 3
  else
    shift 2
  fi

  run_smoke_raw "$VALID_CONTRACT" "$VALID_ROLLOUT" "$url" "$output_dir" "$target_profile" "$@"
}

run_smoke_raw() {
  local release_contract="$1"
  local rollout_report="$2"
  local url="$3"
  local output_dir="$4"
  local target_profile="$5"
  shift 5

  bash "$ROOT_DIR/scripts/verify-release.sh" --smoke \
    --release-contract "$release_contract" \
    --rollout-report "$rollout_report" \
    --target-profile "$target_profile" \
    --url "$url" \
    --output-dir "$output_dir" \
    "$@"
}

expect_no_network_fail() {
  local label="$1"
  local url="$2"
  local output_dir="$3"
  local target_profile="$4"
  shift 4

  local before after
  before="$(hit_count)"
  if run_smoke "$url" "$output_dir" "$target_profile" "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected smoke validation to fail before network: $label"
  fi
  if grep -q 'route smoke GET' "$TMP_DIR/$label.out" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "smoke validation reached fetch for: $label"
  fi
  after="$(hit_count)"
  if [[ "$before" != "$after" ]]; then
    cat "$SERVER_LOG" >&2
    fail "smoke validation reached network for: $label"
  fi
  assert_no_report "$output_dir/smoke-report.json"
  pass "invalid smoke input rejected before network: $label"
}

assert_smoke_report() {
  local report_file="$1"
  local expected_origin="$2"
  local expected_host="$3"

  "$NODE_BIN" --input-type=module - "$report_file" "$TARGET_PROFILE" "$expected_origin" "$expected_host" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile, expectedOrigin, expectedHost] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.route-smoke-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'route_smoke_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('smoke report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('release contract digest is missing');
}
if (report.route?.scheme !== 'http') {
  throw new Error(`unexpected route scheme: ${report.route?.scheme}`);
}
if (report.route?.origin !== expectedOrigin) {
  throw new Error(`unexpected route origin: ${report.route?.origin}`);
}
if (report.route?.host !== expectedHost) {
  throw new Error(`unexpected route host: ${report.route?.host}`);
}
if (report.route?.path !== '/ok') {
  throw new Error(`unexpected route path: ${report.route?.path}`);
}
if ('url' in report.route || 'query' in report.route || 'hash' in report.route || 'userinfo' in report.route) {
  throw new Error('smoke report must keep only normalized route summary');
}
if (report.expected_status !== 200 || report.status_code !== 200) {
  throw new Error('smoke report must record expected and observed status');
}
if (!Number.isInteger(report.duration_ms) || report.duration_ms < 0) {
  throw new Error('smoke report must record duration_ms');
}
if (!report.rollout_report?.input_sha256?.startsWith('sha256:')) {
  throw new Error('smoke report must include rollout report input digest');
}
if (report.rollout_report?.scope !== 'kubernetes_rollout_imageid_only' || report.rollout_report?.status !== 'pass') {
  throw new Error('smoke report must include rollout pass summary');
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('smoke report must not claim verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('smoke report must not include AgentSmith product flow fields');
}
if (/plain-secret-value|token=|x-debug-token|not found/.test(serialized)) {
  throw new Error('smoke report leaked response body or raw headers');
}
if (/kubeconfig/i.test(serialized)) {
  throw new Error('smoke report must not include kubeconfig data or field names');
}
NODE
}

VALID_ROLLOUT="$TMP_DIR/rollout-report.valid.json"
BAD_ROLLOUT="$TMP_DIR/rollout-report.bad.json"
write_rollout_report "$VALID_ROLLOUT" valid
write_rollout_report "$BAD_ROLLOUT" bad_status
start_server

BASE_URL="http://127.0.0.1:$SERVER_PORT"

valid_output="$TMP_DIR/out-valid"
before_valid="$(hit_count)"
run_smoke "$BASE_URL/ok" "$valid_output" "$TARGET_PROFILE" --allow-http --allow-localhost >/dev/null
after_valid="$(hit_count)"
if [[ "$after_valid" -ne $((before_valid + 1)) ]]; then
  cat "$SERVER_LOG" >&2
  fail "happy path should issue exactly one GET"
fi
assert_smoke_report "$valid_output/smoke-report.json" "$BASE_URL" "127.0.0.1:$SERVER_PORT"
pass "route smoke happy path writes normalized non-readiness report"

mismatch_output="$TMP_DIR/out-status-mismatch"
mkdir -p "$mismatch_output"
printf '%s\n' '{"stale":true}' >"$mismatch_output/smoke-report.json"
if run_smoke "$BASE_URL/missing" "$mismatch_output" "$TARGET_PROFILE" --allow-http --allow-localhost >"$TMP_DIR/status-mismatch.out" 2>"$TMP_DIR/status-mismatch.err"; then
  cat "$TMP_DIR/status-mismatch.out" >&2
  cat "$TMP_DIR/status-mismatch.err" >&2
  fail "expected status mismatch to fail"
fi
assert_no_report "$mismatch_output/smoke-report.json"
pass "status mismatch removes stale report and leaves no pass report"

expect_no_network_fail query "$BASE_URL/ok?token=plain-secret-value" "$TMP_DIR/out-query" "$TARGET_PROFILE" --allow-http --allow-localhost
expect_no_network_fail userinfo "http://user:plain-secret-value@127.0.0.1:$SERVER_PORT/ok" "$TMP_DIR/out-userinfo" "$TARGET_PROFILE" --allow-http --allow-localhost
expect_no_network_fail secret-path "$BASE_URL/token=plain-secret-value" "$TMP_DIR/out-secret-path" "$TARGET_PROFILE" --allow-http --allow-localhost
expect_no_network_fail http-default "$BASE_URL/ok" "$TMP_DIR/out-http-default" "$TARGET_PROFILE"
expect_no_network_fail localhost-default "$BASE_URL/ok" "$TMP_DIR/out-localhost-default" "$TARGET_PROFILE" --allow-http
expect_no_network_fail dotted-localhost "https://localhost./ok" "$TMP_DIR/out-dotted-localhost" "$TARGET_PROFILE"
expect_no_network_fail mapped-loopback-decimal "http://[::ffff:127.0.0.1]:$SERVER_PORT/ok" "$TMP_DIR/out-mapped-loopback-decimal" "$TARGET_PROFILE" --allow-http
expect_no_network_fail mapped-loopback-hex "http://[::ffff:7f00:1]:$SERVER_PORT/ok" "$TMP_DIR/out-mapped-loopback-hex" "$TARGET_PROFILE" --allow-http
expect_no_network_fail unsupported-target "$BASE_URL/ok" "$TMP_DIR/out-unsupported-target" "kind_rehearsal/kit_installed/online" --allow-http --allow-localhost

before_bad_rollout="$(hit_count)"
if run_smoke_raw "$VALID_CONTRACT" "$BAD_ROLLOUT" "$BASE_URL/ok" "$TMP_DIR/out-bad-rollout" "$TARGET_PROFILE" --allow-http --allow-localhost >"$TMP_DIR/bad-rollout.out" 2>"$TMP_DIR/bad-rollout.err"; then
  cat "$TMP_DIR/bad-rollout.out" >&2
  cat "$TMP_DIR/bad-rollout.err" >&2
  fail "expected bad rollout report to fail"
fi
after_bad_rollout="$(hit_count)"
if [[ "$before_bad_rollout" != "$after_bad_rollout" ]]; then
  cat "$SERVER_LOG" >&2
  fail "bad rollout report reached network"
fi
assert_no_report "$TMP_DIR/out-bad-rollout/smoke-report.json"
pass "bad rollout report rejected before network"

pass "route/service smoke focused diagnostic tests completed"
