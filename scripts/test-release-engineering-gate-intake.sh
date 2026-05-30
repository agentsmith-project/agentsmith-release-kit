#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
REPORT_FILE="release-engineering-gate-intake-report.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_candidate_inputs() {
  local output_dir="$1"
  local release_contract="${2:-$VALID_CONTRACT}"

  "$NODE_BIN" --input-type=module - "$release_contract" "$output_dir" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [contractFile, outputDir] = process.argv.slice(2);
const contractRaw = fs.readFileSync(contractFile);
const contract = JSON.parse(contractRaw.toString('utf8'));
const contractDigest = digestBuffer(contractRaw);
const { artifact_provenance: _artifactProvenance, ...contractSubject } = contract;
const contractSubjectDigest = canonicalDigest(contractSubject);

fs.mkdirSync(outputDir, { recursive: true });

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
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
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

function digest(char) {
  return `sha256:${char.repeat(64)}`;
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function onlinePath({ operatorPath, targetProfile, runId, digestChars }) {
  return {
    operator_path: operatorPath,
    target_profile: targetProfile,
    mode: 'apply',
    confirmed_apply: true,
    rollout_checked: true,
    smoke_checked: true,
    digests: {
      online_deployment_gate_report: digest(digestChars[0]),
      evidence: digest(digestChars[1]),
      evidence_subject: digest(digestChars[2]),
      release_contract: contractDigest
    },
    provenance: {
      provenance_kind: 'signed_operator_run',
      producer_repo: 'github.com/agentsmith-project/agentsmith-release-kit',
      normalized_remote: 'github.com/agentsmith-project/agentsmith-release-kit',
      commit_sha: 'fedcba9876543210fedcba9876543210fedcba98',
      artifact_uri: `signed-operator-run://agentsmith-release-kit/evidence/${runId}/online-deployment-gate-evidence.tgz`,
      subject_sha256: digest(digestChars[3])
    },
    coverage: {
      steps: ['inputs', 'target-preflight', 'template-package', 'render', 'render-check', 'apply', 'rollout', 'smoke'],
      step_count: 8,
      required_steps: ['inputs', 'target-preflight', 'template-package', 'render', 'render-check', 'apply', 'rollout', 'smoke']
    }
  };
}

writeJson(path.join(outputDir, 'online-adoption-report.json'), {
  schema: 'agentsmith.online-adoption/v1',
  scope: 'online_adoption_aggregation_only',
  readiness: false,
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: contractDigest,
    subject_sha256: contractSubjectDigest
  },
  coverage: {
    required_operator_paths: ['online/use_existing', 'online/install_substrates'],
    target_profiles: [
      'existing_kubernetes/external_declared/online',
      'existing_kubernetes/kit_installed/online'
    ],
    confirmed_apply_paths: 2,
    rollout_checked_paths: 2,
    smoke_checked_paths: 2
  },
  online_paths: {
    use_existing: onlinePath({
      operatorPath: 'online/use_existing',
      targetProfile: 'existing_kubernetes/external_declared/online',
      runId: 'operator-online-use-existing',
      digestChars: ['1', '2', '3', '4']
    }),
    install_substrates: onlinePath({
      operatorPath: 'online/install_substrates',
      targetProfile: 'existing_kubernetes/kit_installed/online',
      runId: 'operator-online-install-substrates',
      digestChars: ['5', '6', '7', '8']
    })
  },
  generated_at: '2026-05-23T12:00:00.000Z'
});

function airgapAdoption({ strategy, profile, digestChars }) {
  return {
    schema: 'agentsmith.airgap-adoption/v1',
    scope: 'airgap_adoption_only',
    readiness: false,
    status: 'pass',
    release: {
      release_id: contract.release_id,
      git_sha: contract.git_sha
    },
    release_contract_digest: contractDigest,
    bundle_manifest_digest: digest(digestChars[0]),
    surface_report_digests: {
      airgap_bundle_surface_report: digest(digestChars[1]),
      airgap_consume_surface_report: digest(digestChars[2])
    },
    producer_report_digests: {
      bundle: {
        bundle_create_report: digest(digestChars[3]),
        airgap_bundle_check_report: digest(digestChars[4])
      },
      consume: {
        airgap_consume_rehearsal_report: digest(digestChars[5]),
        airgap_bundle_check_report: digest(digestChars[4]),
        airgap_deployment_gate_report: digest(digestChars[6])
      }
    },
    operator_paths: [
      {
        surface: 'airgap-bundle',
        substrate_strategy: strategy,
        machine_profile: profile,
        steps: ['bundle-create', 'airgap-bundle-check']
      },
      {
        surface: 'airgap',
        substrate_strategy: strategy,
        machine_profile: profile,
        mode: 'apply',
        operator_run_id_present: true,
        steps: ['airgap-bundle-check', 'airgap-deployment-gate'],
        deployment_steps: ['airgap-image-load', 'airgap-bundle-render-check', 'apply', 'rollout', 'smoke']
      }
    ],
    target_registry_summary: {
      host: 'registry.example.internal'
    }
  };
}

writeJson(
  path.join(outputDir, 'airgap-use-existing', 'airgap-adoption-report.json'),
  airgapAdoption({
    strategy: 'use_existing',
    profile: 'existing_kubernetes/external_declared/airgap',
    digestChars: ['9', 'a', 'b', 'c', 'd', 'e', 'f']
  })
);
writeJson(
  path.join(outputDir, 'airgap-install-substrates', 'airgap-adoption-report.json'),
  airgapAdoption({
    strategy: 'install_substrates',
    profile: 'existing_kubernetes/kit_installed/airgap',
    digestChars: ['a', 'b', 'c', 'd', 'e', 'f', '1']
  })
);

writeJson(path.join(outputDir, 'producers', 'online-deployment-gate-report.json'), {
  schema: 'agentsmith.online-deployment-gate/v1',
  scope: 'online_deployment_gate_only',
  readiness: false,
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: contractDigest
  },
  target_profile: {
    value: 'existing_kubernetes/external_declared/online',
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'online'
  }
});

writeJson(path.join(outputDir, 'producers', 'operator-release-surface-report.json'), {
  schema: 'agentsmith.operator-release-surface-report/v1',
  scope: 'operator_release_surface_v0',
  readiness: false,
  status: 'pass',
  surface: 'airgap',
  substrate_strategy: 'use_existing',
  machine_profile: 'existing_kubernetes/external_declared/airgap',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: contractDigest,
  producer_report_digests: {
    airgap_deployment_gate_report: digest('2')
  }
});

writeJson(path.join(outputDir, 'producers', 'airgap-deployment-gate-report.json'), {
  schema: 'agentsmith.airgap-deployment-gate/v1',
  scope: 'airgap_deployment_gate_only',
  readiness: false,
  status: 'pass',
  mode: 'apply',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: contractDigest
  },
  target_profile: {
    value: 'existing_kubernetes/external_declared/airgap',
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'airgap'
  }
});
NODE
}

copy_and_mutate_json() {
  local source="$1"
  local target="$2"
  local mutation="$3"

  "$NODE_BIN" --input-type=module - "$source" "$target" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [source, target, mutation] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(source, 'utf8'));

switch (mutation) {
  case 'readiness_true':
    data.readiness = true;
    break;
  case 'release_verdict':
    data.release_verdict = 'passed';
    break;
  case 'operator_verdict':
    data.operator_verdict = 'approved';
    break;
  case 'deploy_readiness':
    data.deploy_readiness = { status: 'ready' };
    break;
  case 'package_readiness':
    data.package_readiness = { status: 'ready' };
    break;
  case 'release_id_drift':
    if (data.release_id) {
      data.release_id = '2026.05.23-p0-drifted';
    }
    if (data.release?.release_id) {
      data.release.release_id = '2026.05.23-p0-drifted';
    }
    break;
  case 'git_sha_drift':
    if (data.git_sha) {
      data.git_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    }
    if (data.release?.git_sha) {
      data.release.git_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    }
    break;
  case 'release_contract_digest_drift':
    if (data.release_contract?.input_sha256) {
      data.release_contract.input_sha256 = `sha256:${'b'.repeat(64)}`;
    }
    if (data.release_contract_digest) {
      data.release_contract_digest = `sha256:${'b'.repeat(64)}`;
    }
    break;
  case 'unsafe_release_contract_artifact_uri':
    data.artifact_provenance.artifact_uri = '/home/percy/.kube/config';
    break;
  case 'encoded_home_release_contract_artifact_uri':
    data.artifact_provenance.artifact_uri =
      'gh-artifact://agentsmith/release-contract/10001/%2Fhome%2Fpercy%2F.kube%2Fconfig';
    break;
  case 'double_encoded_home_release_contract_artifact_uri':
    data.artifact_provenance.artifact_uri =
      'gh-artifact://agentsmith/release-contract/10001/%252Fhome%252Fpercy%252F.kube%252Fconfig';
    break;
  case 'encoded_token_release_contract_artifact_uri':
    data.artifact_provenance.artifact_uri =
      'gh-artifact://agentsmith/release-contract/10001/token%3Dabc123';
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, `${JSON.stringify(data, null, 2)}\n`);
NODE
}

run_intake() {
  local output_dir="$1"
  local online_report="$2"
  local airgap_first="$3"
  local airgap_second="$4"
  local release_contract="${5:-$VALID_CONTRACT}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --release-engineering-gate-intake \
    --release-contract "$release_contract" \
    --online-adoption-report "$online_report" \
    --airgap-adoption-report "$airgap_first" \
    --airgap-adoption-report "$airgap_second" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  shift

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected release engineering gate intake failure: $label"
  fi

  pass "release engineering gate intake rejected invalid case: $label"
}

assert_intake_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const digestRe = /^sha256:[0-9a-f]{64}$/;
const requiredQuadrants = [
  'online/use_existing',
  'online/install_substrates',
  'airgap/use_existing',
  'airgap/install_substrates'
];
const requiredGaps = new Set([
  'formal_operator_verdict',
  'offline_install_readiness',
  'package_readiness',
  'release_readiness'
]);

if (report.schema !== 'agentsmith.release-engineering-gate-intake/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'release_engineering_gate_candidate_intake_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false || report.status !== 'pass') {
  throw new Error('intake report must pass with readiness=false');
}
if (report.formal_verdict !== 'not_issued') {
  throw new Error('intake report must not issue a formal verdict');
}
if (report.release?.release_id !== '2026.05.23-p0') {
  throw new Error('release identity missing from intake report');
}
if (!/^[0-9a-f]{40}$/.test(report.release?.git_sha || '')) {
  throw new Error('release git sha missing from intake report');
}
for (const digest of [
  report.release_contract?.input_sha256,
  report.release_contract?.subject_sha256,
  report.adoption_report_digests?.online,
  report.adoption_report_digests?.airgap?.use_existing,
  report.adoption_report_digests?.airgap?.install_substrates
]) {
  if (!digestRe.test(digest || '')) {
    throw new Error(`invalid digest in intake report: ${digest}`);
  }
}
if (JSON.stringify(report.coverage?.required_quadrants) !== JSON.stringify(requiredQuadrants)) {
  throw new Error('intake report must list required four quadrants');
}
if (JSON.stringify(report.coverage?.covered_quadrants) !== JSON.stringify(requiredQuadrants)) {
  throw new Error('intake report must list covered four quadrants');
}
if (report.coverage?.candidate_intake_only !== true) {
  throw new Error('intake report must identify candidate-intake-only scope');
}
const gaps = new Set((report.blocking_gaps || []).map((gap) => gap.gap));
for (const gap of requiredGaps) {
  if (!gaps.has(gap)) {
    throw new Error(`missing blocking gap: ${gap}`);
  }
}
for (const gap of report.blocking_gaps || []) {
  if (gap.status !== 'not_issued' || gap.blocking !== true) {
    throw new Error(`blocking gap must be not issued and blocking: ${gap.gap}`);
  }
}
if (JSON.stringify(report).includes('"readiness":true')) {
  throw new Error('intake report must not contain readiness=true');
}
if ('release_verdict' in report || 'operator_verdict' in report || 'deploy_readiness' in report || 'package_readiness' in report) {
  throw new Error('intake report must not issue formal readiness fields');
}
NODE
}

assert_no_stale_report() {
  local report_file="$1"

  if [[ -e "$report_file" ]]; then
    fail "failed intake left stale report: $report_file"
  fi

  pass "failed release engineering gate intake removed stale report"
}

INPUT_DIR="$TMP_DIR/inputs"
write_candidate_inputs "$INPUT_DIR"

ONLINE_REPORT="$INPUT_DIR/online-adoption-report.json"
AIRGAP_USE_EXISTING_REPORT="$INPUT_DIR/airgap-use-existing/airgap-adoption-report.json"
AIRGAP_INSTALL_SUBSTRATES_REPORT="$INPUT_DIR/airgap-install-substrates/airgap-adoption-report.json"
ONLINE_PRODUCER_REPORT="$INPUT_DIR/producers/online-deployment-gate-report.json"
OPERATOR_SURFACE_REPORT="$INPUT_DIR/producers/operator-release-surface-report.json"
AIRGAP_PRODUCER_REPORT="$INPUT_DIR/producers/airgap-deployment-gate-report.json"

PASS_OUTPUT="$TMP_DIR/out-pass"
run_intake \
  "$PASS_OUTPUT" \
  "$ONLINE_REPORT" \
  "$AIRGAP_USE_EXISTING_REPORT" \
  "$AIRGAP_INSTALL_SUBSTRATES_REPORT" >"$TMP_DIR/pass.out"
[[ -f "$PASS_OUTPUT/$REPORT_FILE" ]] || fail "release engineering gate intake report missing"
assert_intake_report "$PASS_OUTPUT/$REPORT_FILE"
grep -q 'not release readiness' "$TMP_DIR/pass.out" ||
  fail "release engineering gate intake command must state readiness boundary"
pass "release engineering gate intake accepts valid four-quadrant candidate inputs"

BAD_ONLINE="$TMP_DIR/bad/online-readiness-true.json"
copy_and_mutate_json "$ONLINE_REPORT" "$BAD_ONLINE" readiness_true
expect_fail readiness-true \
  run_intake \
    "$TMP_DIR/out-readiness-true" \
    "$BAD_ONLINE" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

BAD_ONLINE_RELEASE_VERDICT="$TMP_DIR/bad/online-release-verdict.json"
copy_and_mutate_json "$ONLINE_REPORT" "$BAD_ONLINE_RELEASE_VERDICT" release_verdict
expect_fail release-verdict \
  run_intake \
    "$TMP_DIR/out-release-verdict" \
    "$BAD_ONLINE_RELEASE_VERDICT" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

BAD_AIRGAP_OPERATOR_VERDICT="$TMP_DIR/bad/airgap-operator-verdict.json"
copy_and_mutate_json "$AIRGAP_USE_EXISTING_REPORT" "$BAD_AIRGAP_OPERATOR_VERDICT" operator_verdict
expect_fail operator-verdict \
  run_intake \
    "$TMP_DIR/out-operator-verdict" \
    "$ONLINE_REPORT" \
    "$BAD_AIRGAP_OPERATOR_VERDICT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

BAD_AIRGAP_DEPLOY_READINESS="$TMP_DIR/bad/airgap-deploy-readiness.json"
copy_and_mutate_json "$AIRGAP_INSTALL_SUBSTRATES_REPORT" "$BAD_AIRGAP_DEPLOY_READINESS" deploy_readiness
expect_fail deploy-readiness \
  run_intake \
    "$TMP_DIR/out-deploy-readiness" \
    "$ONLINE_REPORT" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$BAD_AIRGAP_DEPLOY_READINESS"

BAD_CONTRACT_PACKAGE_READINESS="$TMP_DIR/bad/release-contract-package-readiness.json"
copy_and_mutate_json "$VALID_CONTRACT" "$BAD_CONTRACT_PACKAGE_READINESS" package_readiness
expect_fail package-readiness \
  run_intake \
    "$TMP_DIR/out-package-readiness" \
    "$ONLINE_REPORT" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT" \
    "$BAD_CONTRACT_PACKAGE_READINESS"

BAD_CONTRACT_UNSAFE_ARTIFACT_URI="$TMP_DIR/bad/release-contract-unsafe-artifact-uri.json"
copy_and_mutate_json "$VALID_CONTRACT" "$BAD_CONTRACT_UNSAFE_ARTIFACT_URI" unsafe_release_contract_artifact_uri
UNSAFE_ARTIFACT_URI_INPUT_DIR="$TMP_DIR/unsafe-artifact-uri-inputs"
write_candidate_inputs "$UNSAFE_ARTIFACT_URI_INPUT_DIR" "$BAD_CONTRACT_UNSAFE_ARTIFACT_URI"
UNSAFE_ARTIFACT_URI_OUTPUT="$TMP_DIR/out-unsafe-artifact-uri"
expect_fail unsafe-release-contract-artifact-uri \
  run_intake \
    "$UNSAFE_ARTIFACT_URI_OUTPUT" \
    "$UNSAFE_ARTIFACT_URI_INPUT_DIR/online-adoption-report.json" \
    "$UNSAFE_ARTIFACT_URI_INPUT_DIR/airgap-use-existing/airgap-adoption-report.json" \
    "$UNSAFE_ARTIFACT_URI_INPUT_DIR/airgap-install-substrates/airgap-adoption-report.json" \
    "$BAD_CONTRACT_UNSAFE_ARTIFACT_URI"
assert_no_stale_report "$UNSAFE_ARTIFACT_URI_OUTPUT/$REPORT_FILE"

BAD_CONTRACT_ENCODED_HOME_ARTIFACT_URI="$TMP_DIR/bad/release-contract-encoded-home-artifact-uri.json"
copy_and_mutate_json "$VALID_CONTRACT" "$BAD_CONTRACT_ENCODED_HOME_ARTIFACT_URI" encoded_home_release_contract_artifact_uri
ENCODED_HOME_ARTIFACT_URI_INPUT_DIR="$TMP_DIR/encoded-home-artifact-uri-inputs"
write_candidate_inputs "$ENCODED_HOME_ARTIFACT_URI_INPUT_DIR" "$BAD_CONTRACT_ENCODED_HOME_ARTIFACT_URI"
ENCODED_HOME_ARTIFACT_URI_OUTPUT="$TMP_DIR/out-encoded-home-artifact-uri"
expect_fail encoded-home-release-contract-artifact-uri \
  run_intake \
    "$ENCODED_HOME_ARTIFACT_URI_OUTPUT" \
    "$ENCODED_HOME_ARTIFACT_URI_INPUT_DIR/online-adoption-report.json" \
    "$ENCODED_HOME_ARTIFACT_URI_INPUT_DIR/airgap-use-existing/airgap-adoption-report.json" \
    "$ENCODED_HOME_ARTIFACT_URI_INPUT_DIR/airgap-install-substrates/airgap-adoption-report.json" \
    "$BAD_CONTRACT_ENCODED_HOME_ARTIFACT_URI"
assert_no_stale_report "$ENCODED_HOME_ARTIFACT_URI_OUTPUT/$REPORT_FILE"

BAD_CONTRACT_DOUBLE_ENCODED_HOME_ARTIFACT_URI="$TMP_DIR/bad/release-contract-double-encoded-home-artifact-uri.json"
copy_and_mutate_json "$VALID_CONTRACT" "$BAD_CONTRACT_DOUBLE_ENCODED_HOME_ARTIFACT_URI" double_encoded_home_release_contract_artifact_uri
DOUBLE_ENCODED_HOME_ARTIFACT_URI_INPUT_DIR="$TMP_DIR/double-encoded-home-artifact-uri-inputs"
write_candidate_inputs "$DOUBLE_ENCODED_HOME_ARTIFACT_URI_INPUT_DIR" "$BAD_CONTRACT_DOUBLE_ENCODED_HOME_ARTIFACT_URI"
DOUBLE_ENCODED_HOME_ARTIFACT_URI_OUTPUT="$TMP_DIR/out-double-encoded-home-artifact-uri"
expect_fail double-encoded-home-release-contract-artifact-uri \
  run_intake \
    "$DOUBLE_ENCODED_HOME_ARTIFACT_URI_OUTPUT" \
    "$DOUBLE_ENCODED_HOME_ARTIFACT_URI_INPUT_DIR/online-adoption-report.json" \
    "$DOUBLE_ENCODED_HOME_ARTIFACT_URI_INPUT_DIR/airgap-use-existing/airgap-adoption-report.json" \
    "$DOUBLE_ENCODED_HOME_ARTIFACT_URI_INPUT_DIR/airgap-install-substrates/airgap-adoption-report.json" \
    "$BAD_CONTRACT_DOUBLE_ENCODED_HOME_ARTIFACT_URI"
assert_no_stale_report "$DOUBLE_ENCODED_HOME_ARTIFACT_URI_OUTPUT/$REPORT_FILE"

BAD_CONTRACT_ENCODED_TOKEN_ARTIFACT_URI="$TMP_DIR/bad/release-contract-encoded-token-artifact-uri.json"
copy_and_mutate_json "$VALID_CONTRACT" "$BAD_CONTRACT_ENCODED_TOKEN_ARTIFACT_URI" encoded_token_release_contract_artifact_uri
ENCODED_TOKEN_ARTIFACT_URI_INPUT_DIR="$TMP_DIR/encoded-token-artifact-uri-inputs"
write_candidate_inputs "$ENCODED_TOKEN_ARTIFACT_URI_INPUT_DIR" "$BAD_CONTRACT_ENCODED_TOKEN_ARTIFACT_URI"
ENCODED_TOKEN_ARTIFACT_URI_OUTPUT="$TMP_DIR/out-encoded-token-artifact-uri"
expect_fail encoded-token-release-contract-artifact-uri \
  run_intake \
    "$ENCODED_TOKEN_ARTIFACT_URI_OUTPUT" \
    "$ENCODED_TOKEN_ARTIFACT_URI_INPUT_DIR/online-adoption-report.json" \
    "$ENCODED_TOKEN_ARTIFACT_URI_INPUT_DIR/airgap-use-existing/airgap-adoption-report.json" \
    "$ENCODED_TOKEN_ARTIFACT_URI_INPUT_DIR/airgap-install-substrates/airgap-adoption-report.json" \
    "$BAD_CONTRACT_ENCODED_TOKEN_ARTIFACT_URI"
assert_no_stale_report "$ENCODED_TOKEN_ARTIFACT_URI_OUTPUT/$REPORT_FILE"

expect_fail focused-online-producer-as-adoption \
  run_intake \
    "$TMP_DIR/out-focused-online" \
    "$ONLINE_PRODUCER_REPORT" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

expect_fail focused-operator-surface-as-airgap-adoption \
  run_intake \
    "$TMP_DIR/out-focused-surface" \
    "$ONLINE_REPORT" \
    "$OPERATOR_SURFACE_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

expect_fail focused-airgap-producer-as-adoption \
  run_intake \
    "$TMP_DIR/out-focused-airgap" \
    "$ONLINE_REPORT" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_PRODUCER_REPORT"

expect_fail missing-airgap-install-substrates \
  bash "$ROOT_DIR/scripts/verify-release.sh" --release-engineering-gate-intake \
    --release-contract "$VALID_CONTRACT" \
    --online-adoption-report "$ONLINE_REPORT" \
    --airgap-adoption-report "$AIRGAP_USE_EXISTING_REPORT" \
    --output-dir "$TMP_DIR/out-missing-airgap-install"

expect_fail duplicate-airgap-use-existing \
  run_intake \
    "$TMP_DIR/out-duplicate-airgap-use-existing" \
    "$ONLINE_REPORT" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_USE_EXISTING_REPORT"

BAD_ONLINE_RELEASE_ID="$TMP_DIR/bad/online-release-id-drift.json"
copy_and_mutate_json "$ONLINE_REPORT" "$BAD_ONLINE_RELEASE_ID" release_id_drift
expect_fail release-id-drift \
  run_intake \
    "$TMP_DIR/out-release-id-drift" \
    "$BAD_ONLINE_RELEASE_ID" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

BAD_AIRGAP_GIT_SHA="$TMP_DIR/bad/airgap-git-sha-drift.json"
copy_and_mutate_json "$AIRGAP_USE_EXISTING_REPORT" "$BAD_AIRGAP_GIT_SHA" git_sha_drift
expect_fail git-sha-drift \
  run_intake \
    "$TMP_DIR/out-git-sha-drift" \
    "$ONLINE_REPORT" \
    "$BAD_AIRGAP_GIT_SHA" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

BAD_ONLINE_CONTRACT_DIGEST="$TMP_DIR/bad/online-release-contract-digest-drift.json"
copy_and_mutate_json "$ONLINE_REPORT" "$BAD_ONLINE_CONTRACT_DIGEST" release_contract_digest_drift
expect_fail release-contract-digest-drift \
  run_intake \
    "$TMP_DIR/out-release-contract-digest-drift" \
    "$BAD_ONLINE_CONTRACT_DIGEST" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"

STALE_OUTPUT="$TMP_DIR/out-stale-clear"
run_intake \
  "$STALE_OUTPUT" \
  "$ONLINE_REPORT" \
  "$AIRGAP_USE_EXISTING_REPORT" \
  "$AIRGAP_INSTALL_SUBSTRATES_REPORT" >"$TMP_DIR/stale-pass.out"
[[ -f "$STALE_OUTPUT/$REPORT_FILE" ]] || fail "stale setup report missing"
expect_fail stale-report-clear \
  run_intake \
    "$STALE_OUTPUT" \
    "$BAD_ONLINE" \
    "$AIRGAP_USE_EXISTING_REPORT" \
    "$AIRGAP_INSTALL_SUBSTRATES_REPORT"
assert_no_stale_report "$STALE_OUTPUT/$REPORT_FILE"

STALE_CLI_OUTPUT="$TMP_DIR/out-stale-cli-clear"
run_intake \
  "$STALE_CLI_OUTPUT" \
  "$ONLINE_REPORT" \
  "$AIRGAP_USE_EXISTING_REPORT" \
  "$AIRGAP_INSTALL_SUBSTRATES_REPORT" >"$TMP_DIR/stale-cli-pass.out"
[[ -f "$STALE_CLI_OUTPUT/$REPORT_FILE" ]] || fail "stale CLI setup report missing"
expect_fail stale-cli-report-clear \
  bash "$ROOT_DIR/scripts/verify-release.sh" --release-engineering-gate-intake \
    --release-contract "$VALID_CONTRACT" \
    --online-adoption-report "$ONLINE_REPORT" \
    --output-dir "$STALE_CLI_OUTPUT"
assert_no_stale_report "$STALE_CLI_OUTPUT/$REPORT_FILE"

expect_fail default-verify-release-fail-closed \
  bash "$ROOT_DIR/scripts/verify-release.sh"
grep -q 'full release gate is not implemented' "$TMP_DIR/default-verify-release-fail-closed.out" ||
  grep -q 'full release gate is not implemented' "$TMP_DIR/default-verify-release-fail-closed.err" ||
  fail "default verify-release.sh must remain fail-closed"

pass "release engineering gate intake focused tests completed"
