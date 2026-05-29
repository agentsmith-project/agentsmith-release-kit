#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
EXTERNAL_ONLINE_PROFILE="existing_kubernetes/external_declared/online"
KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_online_evidence() {
  local report_dir="$1"
  local evidence_root="$2"
  local profile="$3"
  local operator_run_id="$4"
  local mutation="${5:-valid}"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$report_dir" \
    "$evidence_root" \
    "$profile" \
    "$operator_run_id" \
    "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  contractFile,
  reportDir,
  evidenceRoot,
  profile,
  operatorRunId,
  mutation
] = process.argv.slice(2);

const [targetCluster, substrateSource, distribution] = profile.split('/');
const contractRaw = fs.readFileSync(contractFile);
const contract = JSON.parse(contractRaw.toString('utf8'));
const contractDigest = digestBuffer(contractRaw);
const releaseKitVersion = '0.1.0';

fs.mkdirSync(reportDir, { recursive: true });
fs.mkdirSync(evidenceRoot, { recursive: true });

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

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function targetProfileObject(value) {
  const [cluster, source, dist] = value.split('/');
  return {
    value,
    target_cluster: cluster,
    substrate_source: source,
    distribution: dist
  };
}

function service(name, host) {
  return {
    host,
    credential_secret_ref: `secretRef:release/${name}-credential`,
    tls: {
      mode: 'verify-full',
      ca_secret_ref: `secretRef:release/${name}-ca`
    },
    reachability: {
      status: 'declared_reachable',
      proof: `operator ${name} check 2026-05-23T12:00:00Z`
    }
  };
}

function substrateTruth() {
  const truth = {
    schema_version: 'agentsmith.substrate-connection.truth/v1',
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution,
    declared_at: '2026-05-23T12:00:00.000Z',
    declared_by: 'release-operator@example.com',
    services: {
      postgresql: {
        ...service('postgresql', 'postgresql.release.example.internal'),
        port: 5432,
        database: 'appdb',
        admin_secret_ref: 'secretRef:release/postgresql-admin',
        sslmode: 'verify-full',
        extensions: {
          pgvector: {
            status: 'installed',
            version: '0.7.4'
          }
        }
      },
      mongodb: {
        ...service('mongodb', 'mongodb.release.example.internal'),
        port: 27017
      },
      redis: {
        ...service('redis', 'redis.release.example.internal'),
        port: 6379
      },
      object_storage: {
        url: 'https://objects.release.example.internal',
        bucket: 'release-artifacts',
        region: 'us-west-2',
        credential_secret_ref: 'secretRef:release/object-storage-credential',
        tls: {
          mode: 'https',
          ca_secret_ref: 'secretRef:release/object-storage-ca'
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator bucket check 2026-05-23T12:00:00Z'
        }
      },
      oidc: {
        issuer_url: 'https://keycloak.release.example.com/realms/app',
        client_id: 'app-web',
        client_secret_ref: 'secretRef:release/oidc-client',
        tls: {
          mode: 'https',
          ca_secret_ref: 'secretRef:release/oidc-ca'
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator oidc check 2026-05-23T12:00:00Z'
        }
      }
    }
  };
  if (substrateSource === 'kit_installed') {
    truth.installed_by = 'agentsmith-release-kit';
    truth.release_kit_version = releaseKitVersion;
    truth.installation_id = 'kit-install-10001';
  }
  return truth;
}

function reportPathForStep(step) {
  const fileByStep = {
    inputs: 'target-profile-coverage-report.json',
    'target-preflight': 'target-preflight-report.json',
    'substrate-pack-check': 'substrate-pack-check-report.json',
    'template-package': 'template-package-report.json',
    'substrate-routability': 'substrate-routability-report.json',
    render: 'manifest-render-report.json',
    'render-check': 'render-report.json',
    apply: 'apply-report.json',
    rollout: 'rollout-report.json',
    smoke: 'smoke-report.json'
  };
  return `${step}/${fileByStep[step]}`;
}

const stepNames = substrateSource === 'kit_installed'
  ? [
      'inputs',
      'target-preflight',
      'substrate-pack-check',
      'template-package',
      'substrate-routability',
      'render',
      'render-check',
      'apply',
      'rollout',
      'smoke'
    ]
  : [
      'inputs',
      'target-preflight',
      'template-package',
      'render',
      'render-check',
      'apply',
      'rollout',
      'smoke'
    ];

const profileObject = targetProfileObject(profile);
const report = {
  schema: 'agentsmith.online-deployment-gate/v1',
  scope: 'online_deployment_gate_only',
  readiness: false,
  status: 'pass',
  mode: 'apply',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: contractDigest
  },
  target_profile: profileObject,
  capability_map: {
    [profile]: {
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
  steps: stepNames.map((name) => ({
    name,
    status: 'pass',
    report_paths: [reportPathForStep(name)]
  })),
  generated_at: '2026-05-23T12:00:00.000Z',
  operator_run_id: operatorRunId
};

if (mutation === 'non_apply') {
  report.mode = 'server-dry-run';
  delete report.operator_run_id;
}
if (mutation === 'release_digest_mismatch') {
  report.release_contract.input_sha256 = `sha256:${'e'.repeat(64)}`;
}

const reportFile = path.join(reportDir, 'online-deployment-gate-report.json');
const evidenceReportFile = path.join(evidenceRoot, 'online-deployment-gate-report.json');
writeJson(reportFile, report);
writeJson(evidenceReportFile, report);
const reportDigest = digestBuffer(fs.readFileSync(reportFile));

const evidence = {
  schema_version: 'agentsmith.release-kit-evidence-envelope/v1',
  release_kit_output: 'online-deployment-gate-report.json',
  release_contract_digest:
    mutation === 'release_digest_mismatch' ? `sha256:${'e'.repeat(64)}` : contractDigest,
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_kit_version: releaseKitVersion,
  target_cluster: targetCluster,
  substrate_source: substrateSource,
  distribution,
  target: {
    namespace: 'agentsmith',
    cluster: targetCluster,
    server: profile
  },
  status: 'passed',
  failure_class: 'none',
  substrate_connection_truth: substrateTruth()
};

const subject = {
  schema_version: 'agentsmith.release-kit-evidence-subject/v1',
  files: [
    {
      path: 'evidence.json',
      sha256: canonicalDigest(evidence)
    },
    {
      path: 'online-deployment-gate-report.json',
      sha256: reportDigest
    }
  ]
};
const subjectDigest = canonicalDigest(subject);
evidence.artifact_provenance = {
  schema_version: 'agentsmith.artifact-provenance/v1',
  provenance_kind: 'signed_operator_run',
  producer_repo: 'github.com/agentsmith-project/agentsmith-release-kit',
  normalized_remote: 'github.com/agentsmith-project/agentsmith-release-kit',
  commit_sha: 'fedcba9876543210fedcba9876543210fedcba98',
  artifact_uri:
    `signed-operator-run://agentsmith-release-kit/evidence/${operatorRunId}/online-deployment-gate-evidence.tgz`,
  generated_at: '2026-05-23T12:00:00.000Z',
  generator_command: 'bash scripts/verify-release.sh --online-deployment-gate --evidence-root',
  generator_version: releaseKitVersion,
  attestation: 'none',
  subject_name: 'release-kit-evidence-subject',
  subject_uri: 'evidence-subject.json',
  subject_sha256: subjectDigest,
  operator_run_id: operatorRunId,
  operator_identity: 'release-operator@example.com',
  signature_uri: `https://signatures.example.com/agentsmith-release-kit/${operatorRunId}.sig`,
  signature_sha256: `sha256:${'a'.repeat(64)}`
};

writeJson(path.join(evidenceRoot, 'evidence-subject.json'), subject);
writeJson(path.join(evidenceRoot, 'evidence.json'), evidence);

if (mutation === 'invalid_evidence') {
  fs.writeFileSync(path.join(evidenceRoot, 'evidence.json'), '{"broken": true}\n');
}
NODE
}

run_adoption() {
  local output_dir="$1"
  local use_existing_report="$2"
  local use_existing_evidence="$3"
  local install_report="$4"
  local install_evidence="$5"

  bash "$ROOT_DIR/scripts/verify-release.sh" --online-adoption \
    --release-contract "$VALID_CONTRACT" \
    --use-existing-report "$use_existing_report" \
    --use-existing-evidence-root "$use_existing_evidence" \
    --install-substrates-report "$install_report" \
    --install-substrates-evidence-root "$install_evidence" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  shift

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected online adoption failure: $label"
  fi

  pass "online adoption rejected invalid case: $label"
}

assert_adoption_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const allowedTopLevelKeys = new Set([
  'schema',
  'scope',
  'readiness',
  'status',
  'release_id',
  'git_sha',
  'release_contract',
  'coverage',
  'online_paths',
  'generated_at'
]);
const allowedPathKeys = new Set([
  'operator_path',
  'target_profile',
  'mode',
  'confirmed_apply',
  'rollout_checked',
  'smoke_checked',
  'digests',
  'provenance',
  'coverage'
]);
const forbiddenKeys = new Set([
  'verdict',
  'release_verdict',
  'operator_verdict',
  'deploy_readiness',
  'package_readiness',
  'release_readiness',
  'ready',
  'kubeconfig',
  'secret',
  'secrets',
  'product_flows',
  'product_flow_results',
  'report_path',
  'report_paths',
  'evidence_root'
]);

function assertNoForbiddenKeys(value, label = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoForbiddenKeys(item, `${label}[${index}]`));
    return;
  }
  for (const [key, nested] of Object.entries(value)) {
    if (forbiddenKeys.has(key)) {
      throw new Error(`online adoption report leaked forbidden key: ${label}.${key}`);
    }
    assertNoForbiddenKeys(nested, `${label}.${key}`);
  }
}

if (report.schema !== 'agentsmith.online-adoption/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'online_adoption_aggregation_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('online adoption report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
for (const key of Object.keys(report)) {
  if (!allowedTopLevelKeys.has(key)) {
    throw new Error(`unexpected top-level key: ${key}`);
  }
}
if (!report.release_id || !/^[0-9a-f]{40}$/.test(report.git_sha || '')) {
  throw new Error('online adoption report must include release identity');
}
if (!/^sha256:[0-9a-f]{64}$/.test(report.release_contract?.input_sha256 || '')) {
  throw new Error('online adoption report must include release contract input digest');
}
if (!/^sha256:[0-9a-f]{64}$/.test(report.release_contract?.subject_sha256 || '')) {
  throw new Error('online adoption report must include release contract subject digest');
}
if (report.coverage?.required_operator_paths?.join(',') !== 'online/use_existing,online/install_substrates') {
  throw new Error('online adoption report must summarize required operator paths');
}
if (report.coverage.confirmed_apply_paths !== 2) {
  throw new Error('online adoption report must count two confirmed apply paths');
}
for (const key of ['use_existing', 'install_substrates']) {
  const entry = report.online_paths?.[key];
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
    throw new Error(`missing online path summary: ${key}`);
  }
  for (const entryKey of Object.keys(entry)) {
    if (!allowedPathKeys.has(entryKey)) {
      throw new Error(`unexpected online path key: ${key}.${entryKey}`);
    }
  }
  if (entry.mode !== 'apply' || entry.confirmed_apply !== true) {
    throw new Error(`${key} must be confirmed apply`);
  }
  if (entry.rollout_checked !== true || entry.smoke_checked !== true) {
    throw new Error(`${key} must summarize rollout and smoke coverage`);
  }
  for (const digest of Object.values(entry.digests || {})) {
    if (!/^sha256:[0-9a-f]{64}$/.test(digest)) {
      throw new Error(`${key} digest summary contains an invalid digest`);
    }
  }
  if (entry.provenance?.provenance_kind !== 'signed_operator_run') {
    throw new Error(`${key} provenance summary has unexpected type`);
  }
  if (!/^signed-operator-run:\/\/agentsmith-release-kit\/evidence\//.test(entry.provenance?.artifact_uri || '')) {
    throw new Error(`${key} provenance artifact uri must be a sanitized remote reference`);
  }
  if (!Array.isArray(entry.coverage?.steps) || !entry.coverage.steps.includes('smoke')) {
    throw new Error(`${key} coverage must list passing smoke step`);
  }
}
assertNoForbiddenKeys(report);
if (
  /\b(?:verdict|release_verdict|operator_verdict|product_flows|product_flow_results)\b/i.test(serialized) ||
  /(?:^|["'\s])(?:\/home\/|\/tmp\/|\/var\/|\/private\/|[A-Za-z]:[\\/]|file:\/\/)/i.test(serialized) ||
  /\b(?:kubeconfig|secretRef:|Bearer\s+[A-Za-z0-9._~+/=-]+|token\s*[:=]|password\s*[:=])\b/i.test(serialized)
) {
  throw new Error('online adoption report leaked verdict wording, raw local paths, or secret-looking payloads');
}
NODE
}

USE_EXISTING_REPORT_DIR="$TMP_DIR/use-existing-report"
USE_EXISTING_EVIDENCE="$TMP_DIR/use-existing-evidence"
INSTALL_REPORT_DIR="$TMP_DIR/install-substrates-report"
INSTALL_EVIDENCE="$TMP_DIR/install-substrates-evidence"
write_online_evidence "$USE_EXISTING_REPORT_DIR" "$USE_EXISTING_EVIDENCE" "$EXTERNAL_ONLINE_PROFILE" operator-run-use-existing
write_online_evidence "$INSTALL_REPORT_DIR" "$INSTALL_EVIDENCE" "$KIT_ONLINE_PROFILE" operator-run-install-substrates

PASS_OUTPUT="$TMP_DIR/out-pass"
run_adoption \
  "$PASS_OUTPUT" \
  "$USE_EXISTING_REPORT_DIR/online-deployment-gate-report.json" \
  "$USE_EXISTING_EVIDENCE" \
  "$INSTALL_REPORT_DIR/online-deployment-gate-report.json" \
  "$INSTALL_EVIDENCE" >"$TMP_DIR/pass.out"
[[ -f "$PASS_OUTPUT/online-adoption-report.json" ]] || fail "online adoption report missing"
assert_adoption_report "$PASS_OUTPUT/online-adoption-report.json"
grep -q 'not release readiness' "$TMP_DIR/pass.out" || fail "online adoption command must state readiness boundary"
pass "online adoption aggregates two confirmed online evidence roots with readiness=false"

expect_fail missing-use-existing \
  bash "$ROOT_DIR/scripts/verify-release.sh" --online-adoption \
    --release-contract "$VALID_CONTRACT" \
    --use-existing-evidence-root "$USE_EXISTING_EVIDENCE" \
    --install-substrates-report "$INSTALL_REPORT_DIR/online-deployment-gate-report.json" \
    --install-substrates-evidence-root "$INSTALL_EVIDENCE" \
    --output-dir "$TMP_DIR/out-missing-use-existing"

expect_fail missing-install-substrates \
  bash "$ROOT_DIR/scripts/verify-release.sh" --online-adoption \
    --release-contract "$VALID_CONTRACT" \
    --use-existing-report "$USE_EXISTING_REPORT_DIR/online-deployment-gate-report.json" \
    --use-existing-evidence-root "$USE_EXISTING_EVIDENCE" \
    --install-substrates-evidence-root "$INSTALL_EVIDENCE" \
    --output-dir "$TMP_DIR/out-missing-install-substrates"

MISMATCH_REPORT_DIR="$TMP_DIR/mismatch-report"
MISMATCH_EVIDENCE="$TMP_DIR/mismatch-evidence"
write_online_evidence "$MISMATCH_REPORT_DIR" "$MISMATCH_EVIDENCE" "$KIT_ONLINE_PROFILE" operator-run-mismatch release_digest_mismatch
expect_fail release-contract-digest-mismatch \
  run_adoption \
    "$TMP_DIR/out-digest-mismatch" \
    "$USE_EXISTING_REPORT_DIR/online-deployment-gate-report.json" \
    "$USE_EXISTING_EVIDENCE" \
    "$MISMATCH_REPORT_DIR/online-deployment-gate-report.json" \
    "$MISMATCH_EVIDENCE"

NON_APPLY_REPORT_DIR="$TMP_DIR/non-apply-report"
NON_APPLY_EVIDENCE="$TMP_DIR/non-apply-evidence"
write_online_evidence "$NON_APPLY_REPORT_DIR" "$NON_APPLY_EVIDENCE" "$EXTERNAL_ONLINE_PROFILE" operator-run-non-apply non_apply
expect_fail non-apply-mode \
  run_adoption \
    "$TMP_DIR/out-non-apply" \
    "$NON_APPLY_REPORT_DIR/online-deployment-gate-report.json" \
    "$NON_APPLY_EVIDENCE" \
    "$INSTALL_REPORT_DIR/online-deployment-gate-report.json" \
    "$INSTALL_EVIDENCE"

expect_fail missing-evidence-root \
  run_adoption \
    "$TMP_DIR/out-missing-evidence-root" \
    "$USE_EXISTING_REPORT_DIR/online-deployment-gate-report.json" \
    "$TMP_DIR/does-not-exist" \
    "$INSTALL_REPORT_DIR/online-deployment-gate-report.json" \
    "$INSTALL_EVIDENCE"

INVALID_EVIDENCE_REPORT_DIR="$TMP_DIR/invalid-evidence-report"
INVALID_EVIDENCE="$TMP_DIR/invalid-evidence"
write_online_evidence "$INVALID_EVIDENCE_REPORT_DIR" "$INVALID_EVIDENCE" "$KIT_ONLINE_PROFILE" operator-run-invalid-evidence invalid_evidence
expect_fail invalid-evidence \
  run_adoption \
    "$TMP_DIR/out-invalid-evidence" \
    "$USE_EXISTING_REPORT_DIR/online-deployment-gate-report.json" \
    "$USE_EXISTING_EVIDENCE" \
    "$INVALID_EVIDENCE_REPORT_DIR/online-deployment-gate-report.json" \
    "$INVALID_EVIDENCE"

pass "online adoption focused tests completed"
