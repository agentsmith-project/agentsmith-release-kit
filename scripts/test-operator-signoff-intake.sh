#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
UNSUPPORTED_PROFILE="existing_kubernetes/external_declared/airgap"
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

sha256_file() {
  "$NODE_BIN" --input-type=module - "$1" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [file] = process.argv.slice(2);
const body = fs.readFileSync(file);
console.log(`sha256:${crypto.createHash('sha256').update(body).digest('hex')}`);
NODE
}

write_inputs() {
  local label="$1"
  local mutation="${2:-valid}"
  local release_contract="$TMP_DIR/$label.release-contract.json"
  local gate_report="$TMP_DIR/$label.online-deployment-gate-report.json"
  local signoff_intake="$TMP_DIR/$label.operator-signoff-intake.json"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$release_contract" "$gate_report" "$signoff_intake" "$TARGET_PROFILE" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  validContract,
  releaseContractOutput,
  gateReportOutput,
  signoffOutput,
  targetProfile,
  mutation
] = process.argv.slice(2);

const contractRaw = fs.readFileSync(validContract);
const contract = JSON.parse(contractRaw.toString('utf8'));
const contractDigest = digestBuffer(contractRaw);
const [targetCluster, substrateSource, distribution] = targetProfile.split('/');
const operatorRunId = 'operator-run-1003';

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestFile(file) {
  return digestBuffer(fs.readFileSync(file));
}

function targetProfileObject(profile) {
  const [cluster, source, dist] = profile.split('/');
  return {
    value: profile,
    target_cluster: cluster,
    substrate_source: source,
    distribution: dist
  };
}

function fixtureDigest(char) {
  return `sha256:${char.repeat(64)}`;
}

const gateReport = {
  schema: 'agentsmith.online-deployment-gate/v1',
  scope: 'online_deployment_gate_only',
  readiness: false,
  status: 'pass',
  mode: 'apply',
  operator_run_id: operatorRunId,
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: contractDigest
  },
  target_profile: {
    value: targetProfile,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  },
  capability_map: {
    [targetProfile]: {
      declared: 'supported',
      intake: 'supported',
      preflight: 'supported',
      render: 'supported',
      apply: 'supported',
      rollout: 'supported',
      smoke: 'optional',
      evidence_envelope: 'optional'
    }
  },
  steps: [
    {
      name: 'inputs',
      status: 'pass',
      report_paths: ['inputs/target-profile-coverage-report.json']
    },
    {
      name: 'target-preflight',
      status: 'pass',
      report_paths: ['target-preflight/target-preflight-report.json']
    },
    {
      name: 'template-package',
      status: 'pass',
      report_paths: ['template-package/template-package-report.json']
    },
    {
      name: 'render',
      status: 'pass',
      report_paths: ['render/manifest-render-report.json']
    },
    {
      name: 'render-check',
      status: 'pass',
      report_paths: ['render-check/render-report.json']
    },
    {
      name: 'apply',
      status: 'pass',
      report_paths: ['apply/apply-report.json']
    },
    {
      name: 'rollout',
      status: 'pass',
      report_paths: ['rollout/rollout-report.json']
    }
  ],
  generated_at: '2026-05-23T12:00:00.000Z'
};

switch (mutation) {
  case 'valid':
  case 'subject_sha_mismatch':
  case 'signoff_operator_run_id_mismatch':
  case 'signoff_target_mismatch':
  case 'signoff_release_id_mismatch':
  case 'signoff_git_sha_mismatch':
  case 'signoff_release_contract_digest_mismatch':
  case 'signoff_out_of_scope_unsafe':
    break;
  case 'gate_missing_operator_run_id':
    delete gateReport.operator_run_id;
    break;
  case 'gate_dry_run':
    gateReport.mode = 'server-dry-run';
    break;
  case 'gate_missing_rollout':
    gateReport.steps = gateReport.steps.filter((step) => step.name !== 'rollout');
    break;
  case 'gate_target_registry_registry_presence':
    gateReport.steps.splice(
      3,
      0,
      {
        name: 'image-map',
        status: 'pass',
        report_paths: ['image-map/image-map.json']
      },
      {
        name: 'registry-presence',
        status: 'pass',
        report_paths: ['registry-presence/registry-presence-report.json']
      }
    );
    break;
  case 'gate_minimal_apply_rollout_steps':
    gateReport.steps = gateReport.steps.filter((step) =>
      ['apply', 'rollout'].includes(step.name)
    );
    break;
  case 'gate_unknown_step':
    gateReport.steps.push({
      name: 'product_flows',
      status: 'pass',
      report_paths: ['product-flows/product-flow-results.json']
    });
    break;
  case 'gate_unknown_top_level_field':
    gateReport.releaseReady = true;
    gateReport.registryPresence = true;
    break;
  case 'gate_standalone_registry_presence_report':
    Object.assign(gateReport, {
      schema: 'agentsmith.registry-presence/v1',
      scope: 'registry_presence_only',
      target_registry: 'registry.example.internal/releases',
      image_count: 6,
      mappings: []
    });
    delete gateReport.mode;
    delete gateReport.capability_map;
    delete gateReport.steps;
    break;
  case 'gate_missing_capability_map':
    delete gateReport.capability_map;
    break;
  case 'gate_bad_capability_map':
    gateReport.capability_map[targetProfile].smoke = 'supported';
    gateReport.capability_map[targetProfile].releaseReady = true;
    gateReport.capability_map[targetProfile].registryPresence = true;
    break;
  case 'gate_missing_generated_at':
    delete gateReport.generated_at;
    break;
  case 'unsupported_target_profile':
    gateReport.target_profile = targetProfileObject('existing_kubernetes/external_declared/airgap');
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(releaseContractOutput, `${JSON.stringify(contract, null, 2)}\n`);
fs.writeFileSync(gateReportOutput, `${JSON.stringify(gateReport, null, 2)}\n`);

const gateReportDigest = digestFile(gateReportOutput);
const signoff = {
  schema_version: 'agentsmith.operator-signoff-intake/v1',
  scope: 'operator_signoff_intake_only',
  decision: 'signed_off',
  operator_run_id: operatorRunId,
  operator_identity: 'release-operator@example.com',
  signed_off_at: '2026-05-23T12:00:00.000Z',
  target_profile: targetProfile,
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: contractDigest,
  subject: {
    kind: 'online_deployment_gate_report',
    sha256: gateReportDigest
  }
};

switch (mutation) {
  case 'valid':
  case 'gate_target_registry_registry_presence':
  case 'gate_missing_operator_run_id':
  case 'gate_dry_run':
  case 'gate_missing_rollout':
  case 'gate_minimal_apply_rollout_steps':
  case 'gate_unknown_step':
  case 'gate_unknown_top_level_field':
  case 'gate_standalone_registry_presence_report':
  case 'gate_missing_capability_map':
  case 'gate_bad_capability_map':
  case 'gate_missing_generated_at':
    break;
  case 'subject_sha_mismatch':
    signoff.subject.sha256 = fixtureDigest('b');
    break;
  case 'signoff_operator_run_id_mismatch':
    signoff.operator_run_id = 'operator-run-drift';
    break;
  case 'signoff_target_mismatch':
    signoff.target_profile = 'existing_kubernetes/external_declared/airgap';
    break;
  case 'signoff_release_id_mismatch':
    signoff.release_id = `${contract.release_id}-drift`;
    break;
  case 'signoff_git_sha_mismatch':
    signoff.git_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    break;
  case 'signoff_release_contract_digest_mismatch':
    signoff.release_contract_digest = fixtureDigest('c');
    break;
  case 'signoff_out_of_scope_unsafe':
    signoff.release_verdict = 'ready';
    signoff.registry_presence = true;
    signoff.product_flow_results = ['workspace_project'];
    signoff.signature_uri = 'file:///tmp/operator.sig';
    signoff.operator_token = 'redacted-token-value-for-negative-test';
    break;
  case 'unsupported_target_profile':
    signoff.target_profile = 'existing_kubernetes/external_declared/airgap';
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(signoffOutput, `${JSON.stringify(signoff, null, 2)}\n`);
NODE

  printf '%s\n' "$release_contract|$gate_report|$signoff_intake"
}

run_intake() {
  local release_contract="$1"
  local gate_report="$2"
  local signoff_intake="$3"
  local output_dir="$4"
  local target_profile="${5:-$TARGET_PROFILE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --operator-signoff-intake \
    --release-contract "$release_contract" \
    --online-deployment-gate-report "$gate_report" \
    --operator-signoff-intake "$signoff_intake" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir"
}

assert_no_intake_report() {
  local output_dir="$1"
  if [[ -e "$output_dir/operator-signoff-intake-report.json" ]]; then
    fail "failed operator-signoff-intake must not leave operator-signoff-intake-report.json"
  fi
}

expect_fail() {
  local label="$1"
  local mutation="$2"
  local cli_target_profile="${3:-$TARGET_PROFILE}"
  local output_dir="$TMP_DIR/out-$label"
  local tuple
  tuple="$(write_inputs "$label" "$mutation")"
  local release_contract="${tuple%%|*}"
  local rest="${tuple#*|}"
  local gate_report="${rest%%|*}"
  local signoff_intake="${rest#*|}"

  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/operator-signoff-intake-report.json"

  if run_intake "$release_contract" "$gate_report" "$signoff_intake" "$output_dir" "$cli_target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected operator-signoff-intake case to fail: $label"
  fi

  assert_no_intake_report "$output_dir"
  pass "operator-signoff-intake rejected invalid case: $label"
}

assert_pass_report() {
  local report_file="$1"
  local gate_report_file="$2"
  local expected_steps="${3:-}"

  "$NODE_BIN" --input-type=module - "$report_file" "$gate_report_file" "$TARGET_PROFILE" "$expected_steps" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile, gateReportFile, targetProfile, expectedStepsText] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedGateSha = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(gateReportFile)).digest('hex')}`;
const allowedTopLevelKeys = new Set([
  'schema',
  'scope',
  'readiness',
  'status',
  'decision',
  'release_id',
  'git_sha',
  'release_contract',
  'target_profile',
  'operator_run_id',
  'operator_identity',
  'signed_off_at',
  'subject',
  'online_deployment_gate',
  'generated_at'
]);

if (report.schema !== 'agentsmith.operator-signoff-intake-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'operator_signoff_intake_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('operator signoff intake report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== targetProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.operator_run_id !== 'operator-run-1003') {
  throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
}
if (report.subject?.kind !== 'online_deployment_gate_report') {
  throw new Error(`unexpected subject kind: ${report.subject?.kind}`);
}
if (report.subject?.sha256 !== expectedGateSha) {
  throw new Error('subject sha must bind raw online deployment gate report file');
}
if (report.online_deployment_gate?.mode !== 'apply') {
  throw new Error('intake report must summarize apply-mode gate report binding');
}
if (!report.online_deployment_gate?.steps?.includes('apply') || !report.online_deployment_gate?.steps?.includes('rollout')) {
  throw new Error('intake report must summarize apply and rollout step binding');
}
if (expectedStepsText) {
  const expectedSteps = expectedStepsText.split(',');
  if (JSON.stringify(report.online_deployment_gate?.steps) !== JSON.stringify(expectedSteps)) {
    throw new Error(`unexpected summarized gate steps: ${report.online_deployment_gate?.steps}`);
  }
}
for (const key of Object.keys(report)) {
  if (!allowedTopLevelKeys.has(key)) {
    throw new Error(`operator signoff intake report has unexpected top-level key: ${key}`);
  }
}
const forbiddenReportTextRe = new RegExp(
  [
    'release_verdict',
    '\\bverdict\\b',
    'deploy_readiness',
    'release_readiness',
    'package_readiness',
    'registry_presence',
    'image_push',
    'image_pull',
    'image_mirror',
    'image_load',
    'image_import',
    'full_online_adoption',
    'product_flows',
    'product_flow_results',
    'signature_uri',
    'signature_sha256',
    'kubeconfig',
    'password',
    'token',
    ['client', 'secret'].join('_'),
    'Bearer '
  ].join('|'),
  'i'
);
if (forbiddenReportTextRe.test(serialized)) {
  throw new Error('operator signoff intake report contains out-of-scope readiness, registry, product-flow, signature, or secret fields');
}
NODE
}

valid_tuple="$(write_inputs valid valid)"
valid_release_contract="${valid_tuple%%|*}"
valid_rest="${valid_tuple#*|}"
valid_gate_report="${valid_rest%%|*}"
valid_signoff_intake="${valid_rest#*|}"
valid_output="$TMP_DIR/out-valid"
if ! run_intake "$valid_release_contract" "$valid_gate_report" "$valid_signoff_intake" "$valid_output" >"$TMP_DIR/valid.out" 2>"$TMP_DIR/valid.err"; then
  cat "$TMP_DIR/valid.out" >&2
  cat "$TMP_DIR/valid.err" >&2
  fail "expected valid operator-signoff-intake to pass"
fi
[[ -f "$valid_output/operator-signoff-intake-report.json" ]] || fail "valid operator-signoff-intake did not write report"
assert_pass_report "$valid_output/operator-signoff-intake-report.json" "$valid_gate_report"
pass "valid operator-signoff-intake accepted focused binding without readiness claims"

target_registry_tuple="$(write_inputs target-registry gate_target_registry_registry_presence)"
target_registry_release_contract="${target_registry_tuple%%|*}"
target_registry_rest="${target_registry_tuple#*|}"
target_registry_gate_report="${target_registry_rest%%|*}"
target_registry_signoff_intake="${target_registry_rest#*|}"
target_registry_output="$TMP_DIR/out-target-registry"
if ! run_intake "$target_registry_release_contract" "$target_registry_gate_report" "$target_registry_signoff_intake" "$target_registry_output" >"$TMP_DIR/target-registry.out" 2>"$TMP_DIR/target-registry.err"; then
  cat "$TMP_DIR/target-registry.out" >&2
  cat "$TMP_DIR/target-registry.err" >&2
  fail "expected target-registry operator-signoff-intake to pass"
fi
[[ -f "$target_registry_output/operator-signoff-intake-report.json" ]] || fail "target-registry operator-signoff-intake did not write report"
assert_pass_report \
  "$target_registry_output/operator-signoff-intake-report.json" \
  "$target_registry_gate_report" \
  "inputs,target-preflight,template-package,image-map,registry-presence,render,render-check,apply,rollout"
pass "target-registry operator-signoff-intake accepts image-map registry-presence canonical binding"

expect_fail subject-sha-mismatch subject_sha_mismatch
expect_fail signoff-operator-run-id-mismatch signoff_operator_run_id_mismatch
expect_fail gate-missing-operator-run-id gate_missing_operator_run_id
expect_fail gate-dry-run gate_dry_run
expect_fail gate-missing-rollout gate_missing_rollout
expect_fail gate-minimal-apply-rollout-steps gate_minimal_apply_rollout_steps
expect_fail gate-unknown-step gate_unknown_step
expect_fail gate-unknown-top-level-field gate_unknown_top_level_field
expect_fail gate-standalone-registry-presence-report gate_standalone_registry_presence_report
expect_fail gate-missing-capability-map gate_missing_capability_map
expect_fail gate-bad-capability-map gate_bad_capability_map
expect_fail gate-missing-generated-at gate_missing_generated_at
expect_fail signoff-target-mismatch signoff_target_mismatch
expect_fail signoff-release-id-mismatch signoff_release_id_mismatch
expect_fail signoff-git-sha-mismatch signoff_git_sha_mismatch
expect_fail signoff-release-contract-digest-mismatch signoff_release_contract_digest_mismatch
expect_fail signoff-out-of-scope-unsafe signoff_out_of_scope_unsafe
expect_fail unsupported-target-profile unsupported_target_profile "$UNSUPPORTED_PROFILE"

stale_tuple="$(write_inputs stale valid)"
stale_release_contract="${stale_tuple%%|*}"
stale_rest="${stale_tuple#*|}"
stale_gate_report="${stale_rest%%|*}"
stale_signoff_intake="${stale_rest#*|}"
stale_output="$TMP_DIR/out-stale-clear"
mkdir -p "$stale_output"
printf '%s\n' '{"stale":true}' >"$stale_output/operator-signoff-intake-report.json"
if run_intake "$stale_release_contract" "$stale_gate_report" "$stale_signoff_intake" "$stale_output" "$UNSUPPORTED_PROFILE" >"$TMP_DIR/stale-clear.out" 2>"$TMP_DIR/stale-clear.err"; then
  fail "expected unsupported target profile stale-clear case to fail"
fi
assert_no_intake_report "$stale_output"
pass "failed operator-signoff-intake clears stale report"

pass "operator-signoff-intake focused tests completed"
