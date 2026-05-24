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

run_evidence() {
  local evidence_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --evidence \
    --release-contract "$VALID_CONTRACT" \
    --evidence-root "$evidence_root" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local kind="${2:-ci_artifact}"
  local mutation="${3:-$label}"
  local evidence_root="$TMP_DIR/evidence-$label"
  local output_dir="$TMP_DIR/out-$label"

  write_evidence "$evidence_root" "$kind" "$mutation"

  if run_evidence "$evidence_root" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid evidence case to fail: $label"
  fi

  pass "invalid evidence rejected: $label"
}

expect_target_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local evidence_root="$TMP_DIR/evidence-target-$label"
  local output_dir="$TMP_DIR/out-target-$label"

  write_evidence "$evidence_root" ci_artifact valid

  if run_evidence "$evidence_root" "$output_dir" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  pass "legacy or synonym target profile rejected: $label"
}

assert_pass_report() {
  local report_file="$1"
  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (report.scope !== 'release_kit_evidence_intake_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('evidence validation report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if ('release_verdict' in report || 'verdict' in report) {
  throw new Error('evidence validation report must not claim a release verdict');
}
NODE
}

write_evidence() {
  local evidence_root="$1"
  local kind="${2:-ci_artifact}"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$evidence_root" "$kind" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, evidenceRoot, kind, mutation] = process.argv.slice(2);
const producerRepo = 'github.com/agentsmith-project/agentsmith-release-kit';
const releaseKitCommitSha = 'fedcba9876543210fedcba9876543210fedcba98';
const contractRaw = fs.readFileSync(contractInput);
const contract = JSON.parse(contractRaw.toString('utf8'));

fs.mkdirSync(evidenceRoot, { recursive: true });

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestFile(file) {
  return digestBuffer(fs.readFileSync(file));
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

function withoutArtifactProvenance(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return subject;
}

function writeJson(relativePath, value) {
  const file = path.join(evidenceRoot, relativePath);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  return file;
}

const evidence = {
  schema_version: 'agentsmith.release-kit-evidence-envelope/v1',
  release_contract_digest: digestBuffer(contractRaw),
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_kit_version: '0.1.0',
  target_cluster: 'existing_kubernetes',
  substrate_source: 'external_declared',
  distribution: 'online',
  target: {
    namespace: 'release-ns',
    base_url: 'https://app.example.com'
  },
  status: 'passed',
  failure_class: 'none'
};

const deployResult = {
  status: 'passed',
  namespace: 'service-ns'
};

let provenanceArtifactUri =
  'gh-artifact://agentsmith-release-kit/evidence/10001/evidence-envelope.tgz';

switch (mutation) {
  case 'valid':
    break;
  case 'missing_release_contract_digest':
    delete evidence.release_contract_digest;
    break;
  case 'reserved_agentsmith_adapter_schema':
    evidence.schema_version = 'agentsmith.release-kit-evidence/v1';
    break;
  case 'release_identity_mismatch':
    evidence.release_id = `${contract.release_id}-drift`;
    break;
  case 'target_profile_mismatch':
    evidence.target_cluster = 'kind_rehearsal';
    break;
  case 'status_failure_class_passed_wrong':
    evidence.failure_class = 'rollout_failed';
    break;
  case 'status_failure_class_failed_wrong':
    evidence.status = 'failed';
    evidence.failure_class = 'none';
    break;
  case 'product_flows_present':
    evidence.product_flows = ['workspace_project'];
    break;
  case 'wrong_producer_repo':
    break;
  case 'local_provenance_uri':
    provenanceArtifactUri = 'file://' + path.join(evidenceRoot, 'evidence-envelope.tgz');
    break;
  case 'valid_secret_ref':
    evidence.target.pull_secret_ref = 'secretRef:release/registry-pull';
    break;
  case 'subject_file_secret_payload':
    deployResult.database =
      'postgres' + '://user:' + 'password' + '@db.example.internal:5432/appdb';
    break;
  case 'subject_file_source_payload':
    deployResult.source_path =
      '/home/percy/works/mbos-v1/' + 'agent' + 'smith/' + 'sr' + 'c/' + 'ap' + 'p/page.tsx';
    break;
  case 'evidence_json_secret_payload':
    evidence['client_' + 'secret'] = 'not-real-credential-value';
    break;
  case 'signed_missing_signature':
    break;
  case 'missing_provenance_schema_version':
  case 'missing_commit_sha':
  case 'bad_provenance_commit_sha':
  case 'missing_subject_uri':
  case 'bad_subject_name':
  case 'missing_generated_at':
  case 'missing_generator_command':
  case 'missing_generator_version':
  case 'bad_attestation_object':
  case 'raw_evidence_file_sha':
    break;
  case 'subject_sha_mismatch':
  case 'subject_contains_artifact_provenance':
  case 'subject_missing_file':
  case 'subject_sha_mismatch_file':
  case 'subject_parent_path':
  case 'subject_absolute_path':
  case 'subject_symlink':
  case 'subject_hardlink':
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

const deployResultFile = writeJson('deploy-result.json', deployResult);
const subjectEntries = [
  {
    path: 'deploy-result.json',
    sha256: digestFile(deployResultFile)
  }
];

if (mutation === 'subject_missing_file') {
  subjectEntries.push({
    path: 'missing-result.json',
    sha256: `sha256:${'b'.repeat(64)}`
  });
}
if (mutation === 'subject_sha_mismatch_file') {
  subjectEntries[0].sha256 = `sha256:${'c'.repeat(64)}`;
}
if (mutation === 'subject_parent_path') {
  subjectEntries.push({
    path: '../escape.json',
    sha256: digestFile(deployResultFile)
  });
}
if (mutation === 'subject_absolute_path') {
  subjectEntries.push({
    path: '/tmp/evidence-result.json',
    sha256: digestFile(deployResultFile)
  });
}
if (mutation === 'subject_symlink') {
  fs.symlinkSync('deploy-result.json', path.join(evidenceRoot, 'deploy-result-link.json'));
  subjectEntries.push({
    path: 'deploy-result-link.json',
    sha256: digestFile(deployResultFile)
  });
}
if (mutation === 'subject_hardlink') {
  const targetFile = writeJson('hardlink-target.json', { status: 'passed' });
  const hardlinkFile = path.join(evidenceRoot, 'hardlink-result.json');
  fs.linkSync(targetFile, hardlinkFile);
  subjectEntries.push({
    path: 'hardlink-result.json',
    sha256: digestFile(hardlinkFile)
  });
}

const evidenceSubjectProjectionSha = canonicalDigest(withoutArtifactProvenance(evidence));
const subject = {
  schema_version: 'agentsmith.release-kit-evidence-subject/v1',
  files: [
    {
      path: 'evidence.json',
      sha256: evidenceSubjectProjectionSha
    },
    ...subjectEntries
  ]
};

if (mutation === 'subject_contains_artifact_provenance') {
  subject.artifact_provenance = {
    producer_repo: producerRepo
  };
}

let subjectSha = canonicalDigest(subject);
if (mutation === 'subject_sha_mismatch') {
  subjectSha = `sha256:${'d'.repeat(64)}`;
}

const provenance = {
  schema_version: 'agentsmith.artifact-provenance/v1',
  provenance_kind: kind,
  producer_repo: producerRepo,
  normalized_remote: producerRepo,
  commit_sha: releaseKitCommitSha,
  subject_name: 'agentsmith-release-kit-evidence',
  subject_uri: 'evidence-subject.json',
  subject_sha256: subjectSha,
  artifact_uri: provenanceArtifactUri,
  generated_at: '2026-05-23T12:00:00.000Z',
  generator_command: 'bash scripts/verify-release.sh --evidence',
  generator_version: '0.1.0',
  attestation: 'none'
};

if (kind === 'ci_artifact') {
  Object.assign(provenance, {
    workflow_name: 'release-kit-evidence',
    run_id: '10001',
    run_attempt: '1',
    job: 'evidence'
  });
} else if (kind === 'signed_operator_run') {
  Object.assign(provenance, {
    operator_run_id: 'operator-run-10001',
    operator_identity: 'release-operator@example.com',
    signature_uri: 'https://signatures.example.com/agentsmith-release-kit/operator-run-10001.sig',
    signature_sha256: `sha256:${'a'.repeat(64)}`
  });
} else {
  throw new Error(`unknown provenance kind: ${kind}`);
}

if (mutation === 'wrong_producer_repo') {
  provenance.producer_repo = 'github.com/example/not-release-kit';
  provenance.normalized_remote = 'github.com/example/not-release-kit';
}
if (mutation === 'signed_missing_signature') {
  delete provenance.signature_uri;
}
if (mutation === 'missing_provenance_schema_version') {
  delete provenance.schema_version;
}
if (mutation === 'missing_commit_sha') {
  delete provenance.commit_sha;
}
if (mutation === 'bad_provenance_commit_sha') {
  provenance.commit_sha = 'not-a-git-sha';
}
if (mutation === 'missing_subject_uri') {
  delete provenance.subject_uri;
}
if (mutation === 'bad_subject_name') {
  provenance.subject_name = 'agentsmith-release-kit-render-report';
}
if (mutation === 'missing_generated_at') {
  delete provenance.generated_at;
}
if (mutation === 'missing_generator_command') {
  delete provenance.generator_command;
}
if (mutation === 'missing_generator_version') {
  delete provenance.generator_version;
}
if (mutation === 'bad_attestation_object') {
  provenance.attestation = {
    attestation_uri: 'https://attestations.example.com/agentsmith-release-kit/evidence.intoto.jsonl',
    attestation_sha256: 'not-a-sha256-digest'
  };
}

evidence.artifact_provenance = provenance;
const evidenceFile = writeJson('evidence.json', evidence);
if (mutation === 'raw_evidence_file_sha') {
  subject.files[0].sha256 = digestFile(evidenceFile);
  provenance.subject_sha256 = canonicalDigest(subject);
  writeJson('evidence.json', evidence);
}
writeJson('evidence-subject.json', subject);
NODE
}

VALID_CI_ROOT="$TMP_DIR/evidence-valid-ci"
VALID_CI_OUT="$TMP_DIR/out-valid-ci"
write_evidence "$VALID_CI_ROOT" ci_artifact valid
run_evidence "$VALID_CI_ROOT" "$VALID_CI_OUT" >/dev/null
assert_pass_report "$VALID_CI_OUT/evidence-validation-report.json"
pass "valid ci_artifact evidence accepted with focused non-readiness report"

VALID_SIGNED_ROOT="$TMP_DIR/evidence-valid-signed"
VALID_SIGNED_OUT="$TMP_DIR/out-valid-signed"
write_evidence "$VALID_SIGNED_ROOT" signed_operator_run valid
run_evidence "$VALID_SIGNED_ROOT" "$VALID_SIGNED_OUT" >/dev/null
assert_pass_report "$VALID_SIGNED_OUT/evidence-validation-report.json"
pass "valid signed_operator_run evidence accepted"

VALID_SECRET_REF_ROOT="$TMP_DIR/evidence-valid-secret-ref"
VALID_SECRET_REF_OUT="$TMP_DIR/out-valid-secret-ref"
write_evidence "$VALID_SECRET_REF_ROOT" ci_artifact valid_secret_ref
run_evidence "$VALID_SECRET_REF_ROOT" "$VALID_SECRET_REF_OUT" >/dev/null
assert_pass_report "$VALID_SECRET_REF_OUT/evidence-validation-report.json"
pass "valid persisted secretRef evidence accepted"

expect_fail missing-release-contract-digest ci_artifact missing_release_contract_digest
expect_fail reserved-agentsmith-adapter-schema ci_artifact reserved_agentsmith_adapter_schema
expect_fail release-identity-mismatch ci_artifact release_identity_mismatch
expect_fail target-profile-mismatch ci_artifact target_profile_mismatch

expect_target_profile_fail legacy-local-kind 'local-kind/external_declared/online'
expect_target_profile_fail legacy-existing-cluster 'existing-cluster/external_declared/online'
expect_target_profile_fail legacy-real-k8s 'real-k8s/external_declared/online'
expect_target_profile_fail synonym-kind 'kind/external_declared/online'
expect_target_profile_fail synonym-cluster 'existing_kubernetes/cluster/online'

expect_fail status-failure-class-passed-wrong ci_artifact status_failure_class_passed_wrong
expect_fail status-failure-class-failed-wrong ci_artifact status_failure_class_failed_wrong
expect_fail product-flows-present ci_artifact product_flows_present
expect_fail wrong-producer-repo ci_artifact wrong_producer_repo
expect_fail local-provenance-uri ci_artifact local_provenance_uri
expect_fail missing-provenance-schema-version ci_artifact missing_provenance_schema_version
expect_fail missing-commit-sha ci_artifact missing_commit_sha
expect_fail bad-provenance-commit-sha ci_artifact bad_provenance_commit_sha
expect_fail missing-subject-uri ci_artifact missing_subject_uri
expect_fail bad-subject-name ci_artifact bad_subject_name
expect_fail missing-generated-at ci_artifact missing_generated_at
expect_fail missing-generator-command ci_artifact missing_generator_command
expect_fail missing-generator-version ci_artifact missing_generator_version
expect_fail bad-attestation-object ci_artifact bad_attestation_object
expect_fail signed-missing-signature signed_operator_run signed_missing_signature
expect_fail subject-sha-mismatch ci_artifact subject_sha_mismatch
expect_fail subject-contains-artifact-provenance ci_artifact subject_contains_artifact_provenance
expect_fail raw-evidence-file-sha ci_artifact raw_evidence_file_sha
expect_fail subject-missing-file ci_artifact subject_missing_file
expect_fail subject-sha-mismatch-file ci_artifact subject_sha_mismatch_file
expect_fail subject-parent-path ci_artifact subject_parent_path
expect_fail subject-absolute-path ci_artifact subject_absolute_path
expect_fail subject-symlink ci_artifact subject_symlink
expect_fail subject-hardlink ci_artifact subject_hardlink
expect_fail subject-file-secret-payload ci_artifact subject_file_secret_payload
expect_fail subject-file-source-payload ci_artifact subject_file_source_payload
expect_fail evidence-json-secret-payload ci_artifact evidence_json_secret_payload

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "evidence diagnostic is not release readiness"
