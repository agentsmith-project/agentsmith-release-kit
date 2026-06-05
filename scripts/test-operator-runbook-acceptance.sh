#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
VERIFIER="$ROOT_DIR/scripts/verify-operator-runbook-acceptance.mjs"
REPORT_FILE="operator-runbook-acceptance-report.json"
MACHINE_PROFILE="existing_kubernetes/kit_installed/airgap"
OPERATOR_CHOICE="airgap-bundle/kit_provided"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

assert_operator_success_contract_docs() {
  local help_output="$TMP_DIR/operator-release-help.out"
  local runbooks_readme="$ROOT_DIR/docs/runbooks/README.md"
  local root_readme="$ROOT_DIR/README.md"
  local first_screen="$TMP_DIR/runbook-first-screen.md"
  local root_first_screen="$TMP_DIR/root-readme-first-screen.md"
  local root_full="$TMP_DIR/root-readme-full.md"
  local forbidden

  bash "$ROOT_DIR/scripts/operator-release.sh" --help >"$help_output"
  grep -q -- '--init-operator-inputs <deployment_path> --output-dir <package-dir>' "$help_output" ||
    fail "operator-release help must foreground operator-inputs init"
  grep -q -- '--operator-inputs <package-or-json> --doctor' "$help_output" ||
    fail "operator-release help must foreground the operator-inputs doctor command"
  grep -q -- '--operator-inputs <package-or-json> --run' "$help_output" ||
    fail "operator-release help must foreground the operator-inputs run command"
  grep -q -- 'Formal release success or failure' "$help_output" ||
    fail "operator-release help must name the formal success boundary"
  grep -q -- 'ga-release-report.json issued by the release finalizer/captain' "$help_output" ||
    fail "operator-release help must point formal success to ga-release-report.json"
  if grep -q -- 'verify-release.sh' "$help_output"; then
    fail "operator-release help must not expose finalizer command details"
  fi
  if grep -Eiq 'kit_provided|[.]release-kit-internal|operator-inputs-plan|docs/RELEASE_GATES[.]md|operator-release-surface-report|adoption report|candidate intake|release-engineering|operator-signoff|external_declared|kit_installed|existing_kubernetes|kind_rehearsal' "$help_output"; then
    fail "operator-release help must not expose legacy aliases, internal paths, machine profiles, or maintainer diagnostics"
  fi
  if grep -q -- 'No ga-release-report' "$help_output"; then
    fail "operator-release help must explain the phase boundary without bare ga-release-report negation"
  fi
  if grep -Eiq 'internal execution plan|internal plan|without --run' "$help_output" ||
    grep -Fq -- '--operator-inputs <package-or-json> [--doctor|--run]' "$help_output"; then
    fail "operator-release help must not expose plain validation or internal plan concepts"
  fi

  awk '
    /^## Operator Package Matrix$/ { exit }
    { print }
  ' "$runbooks_readme" >"$first_screen"
  for forbidden in \
    'operator-release-surface-report' \
    'adoption' \
    'candidate' \
    'kit_provided' \
    'deployment-path-report.json' \
    'internal plan' \
    'internal execution plan' \
    'without `--run`' \
    'bash scripts/operator-release[.]sh --operator-inputs <dir-or-json>$'; do
    if grep -Eiq "$forbidden" "$first_screen"; then
      fail "operator runbook first screen must not present $forbidden as a success path"
    fi
  done
  if grep -q -- 'verify-release.sh' "$first_screen"; then
    fail "operator runbook first screen must not expose finalizer command details"
  fi
  for required in \
    '### 1. Which path do I choose?' \
    '### 2. What do I prepare?' \
    '### 3. What do I run?' \
    '### 4. What is the final report?' \
    'Formal release success or failure is represented only by the final'; do
    grep -q -- "$required" "$first_screen" ||
      fail "operator runbook first screen missing: $required"
  done

  awk '
    /^### Maintainer\/Internal Diagnostics$/ { exit }
    { print }
  ' "$root_readme" >"$root_first_screen"
  cp "$root_readme" "$root_full"
  for forbidden in \
    'kit_provided' \
    '[.]release-kit-internal' \
    'operator-inputs-plan' \
    'operator-release-surface-report' \
    'adoption report|adoption aggregation' \
    'candidate intake' \
    'release-engineering' \
    'operator-signoff|operator signoff' \
    'external_declared' \
    'kit_installed' \
    'existing_kubernetes' \
    'kind_rehearsal' \
    'internal plan' \
    'internal execution plan' \
    'without `--run`' \
    'bash scripts/operator-release[.]sh --operator-inputs <dir-or-json>$'; do
    if grep -Eiq "$forbidden" "$root_first_screen"; then
      fail "root README operator first screen must not expose legacy aliases, internal paths, machine profiles, or maintainer diagnostics: $forbidden"
    fi
  done
  for forbidden in \
    'operator-release-surface-report' \
    'airgap-adoption-report' \
    'release-engineering-gate-intake' \
    'operator-signoff-intake' \
    'verify-release[.]sh[[:space:]]+--' \
    'test-[^[:space:]]+[.]sh' \
    '[.]release-kit-internal' \
    'kit_provided' \
    'external_declared' \
    'kit_installed' \
    'kind_rehearsal'; do
    if grep -Eiq "$forbidden" "$root_full"; then
      fail "root README must not duplicate the maintainer producer catalog: $forbidden"
    fi
  done

  grep -q -- 'The GA operator substrate choices are `use_existing` and' "$root_readme" ||
    fail "root README must name the GA operator substrate choices"
  grep -q -- 'The operator-facing path is a single package-driven facade' "$root_readme" ||
    fail "root README must name the operator-facing package-driven facade"
  if grep -Fqi -- 'operator-facing path is a single package-driven flow' "$root_readme"; then
    fail "root README must not regress to the old package-driven flow wording"
  fi
  grep -q -- 'Formal release success' "$root_readme" ||
    fail "root README must name the formal GA success boundary"
  grep -q -- 'or failure is represented only by the' "$root_readme" ||
    fail "root README must point formal success to the finalizer GA report"
  grep -q -- 'final `ga-release-report.json` issued by' "$root_readme" ||
    fail "root README must point formal success to the finalizer GA report"
  grep -q -- 'release finalizer/captain' "$root_readme" ||
    fail "root README must point formal success to the finalizer GA report"
  grep -q -- 'formal_verdict=not_issued' "$root_readme" ||
    fail "root README must describe blocked GA aggregates as not_issued"
  grep -q -- 'formal_verdict=not_issued' "$first_screen" ||
    fail "operator runbook first screen must describe blocked GA aggregates as not_issued"
  grep -q -- 'The focused producer catalog is no longer duplicated' "$root_readme" ||
    fail "root README must route maintainer diagnostics out of the operator first screen"
  grep -q -- 'docs/maintainer-diagnostics.md' "$root_readme" ||
    fail "root README must point maintainers to maintainer diagnostics"
  pass "operator success contract docs keep internal diagnostics out of the first screen"
}

run_acceptance() {
  local case_dir="$1"
  local output_dir="$2"
  local machine_profile="${3:-$MACHINE_PROFILE}"

  "$NODE_BIN" "$VERIFIER" \
    --operator-choice "$OPERATOR_CHOICE" \
    --machine-profile "$machine_profile" \
    --surface-report "$case_dir/operator-release-surface-report.json" \
    --evidence-root "$case_dir/evidence" \
    --runbook "$case_dir/bundle/payload/runbook.md" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local mutation="$2"
  local machine_profile="${3:-$MACHINE_PROFILE}"
  local case_dir="$TMP_DIR/case-$label"
  local output_dir="$TMP_DIR/out-$label"

  write_case "$case_dir" "$mutation"

  if run_acceptance "$case_dir" "$output_dir" "$machine_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected operator runbook acceptance failure: $label"
  fi
  [[ ! -e "$output_dir/$REPORT_FILE" ]] ||
    fail "invalid runbook acceptance wrote report: $label"
  pass "operator runbook acceptance rejected invalid case: $label"
}

assert_acceptance_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const allowedKeys = new Set([
  'schema',
  'scope',
  'status',
  'operator_choice',
  'machine_profile',
  'surface_report_digest',
  'evidence_root_digest',
  'runbook'
]);
const forbiddenKeys = new Set([
  'readiness',
  'verdict',
  'formal_verdict',
  'release_verdict',
  'operator_identity',
  'signature',
  'signature_uri',
  'signature_sha256'
]);

function scan(value, label = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => scan(item, `${label}[${index}]`));
    return;
  }
  for (const [key, nested] of Object.entries(value)) {
    if (forbiddenKeys.has(key)) {
      throw new Error(`acceptance report must not include ${label}.${key}`);
    }
    scan(nested, `${label}.${key}`);
  }
}

if (report.schema !== 'agentsmith.operator-runbook-acceptance/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'operator_runbook_acceptance_v0') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.operator_choice !== 'airgap-bundle/kit_provided') {
  throw new Error(`unexpected operator choice: ${report.operator_choice}`);
}
if (report.machine_profile !== 'existing_kubernetes/kit_installed/airgap') {
  throw new Error(`unexpected machine profile: ${report.machine_profile}`);
}
for (const key of Object.keys(report)) {
  if (!allowedKeys.has(key)) {
    throw new Error(`unexpected acceptance report key: ${key}`);
  }
}
for (const digest of [
  report.surface_report_digest,
  report.evidence_root_digest,
  report.runbook?.sha256
]) {
  if (!/^sha256:[0-9a-f]{64}$/.test(digest || '')) {
    throw new Error('acceptance report digest missing');
  }
}
if (report.runbook?.path !== 'payload/runbook.md') {
  throw new Error(`unexpected runbook path: ${report.runbook?.path}`);
}
scan(report);
NODE
}

write_case() {
  local case_dir="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$case_dir" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [caseDir, mutation] = process.argv.slice(2);
const evidenceRoot = path.join(caseDir, 'evidence');
const bundleRoot = path.join(caseDir, 'bundle');
const runbookPath = path.join(bundleRoot, 'payload/runbook.md');
const releaseId = 'release-2026.05.30';
const gitSha = '0123456789abcdef0123456789abcdef01234567';
const releaseContractDigest = digestText('release-contract');
const profile = 'existing_kubernetes/kit_installed/airgap';
const airgapOutput = 'airgap_bundle_check';

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestText(value) {
  return digestBuffer(Buffer.from(value));
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

function digestJson(value) {
  return digestText(`${JSON.stringify(value, null, 2)}\n`);
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function targetProfile(value = profile) {
  const [targetCluster, substrateSource, distribution] = value.split('/');
  return {
    value,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

fs.mkdirSync(path.dirname(runbookPath), { recursive: true });
fs.writeFileSync(runbookPath, '# AgentSmith airgap runbook\n\nUse scoped kit evidence only.\n');
const runbookDigest = digestBuffer(fs.readFileSync(runbookPath));

const imageMap = {
  schema: 'agentsmith.image-map/v1',
  scope: 'image_map_only',
  readiness: false,
  status: 'pass',
  release_id: releaseId,
  git_sha: gitSha,
  target_profile: targetProfile(),
  mirror_required: true,
  image_count: 1,
  mappings: [
    {
      id: 'agentsmith_app',
      source_image: 'ghcr.io/agentsmith-project/agentsmith/app@sha256:' + 'a'.repeat(64),
      source_digest: 'sha256:' + 'a'.repeat(64),
      target_image: 'registry.release.example/agentsmith/app@sha256:' + 'a'.repeat(64),
      target_digest: 'sha256:' + 'a'.repeat(64),
      action: 'mirror_required'
    }
  ]
};
const imageMapDigest = digestJson(imageMap);
const substratePack = {
  schema_version: 'agentsmith.substrate-pack-manifest/v1',
  release_kit_version: '0.1.0',
  installed_by: 'agentsmith-release-kit',
  target_profile: profile,
  images: {
    postgresql: 'ghcr.io/agentsmith-project/substrates/postgresql:16.3@sha256:' + '1'.repeat(64),
    mongodb: 'ghcr.io/agentsmith-project/substrates/mongodb:7.0@sha256:' + '2'.repeat(64),
    redis: 'ghcr.io/agentsmith-project/substrates/redis:7.2@sha256:' + '3'.repeat(64),
    object_storage:
      'ghcr.io/agentsmith-project/substrates/object-storage:2026.05@sha256:' + '4'.repeat(64),
    oidc: 'ghcr.io/agentsmith-project/substrates/keycloak:25.0@sha256:' + '5'.repeat(64)
  },
  payload: {
    install_plan: {
      path: 'payload/kit-provided.json',
      sha256: 'sha256:' + '6'.repeat(64)
    }
  },
  templates: {
    postgresql: 'templates/postgresql.yaml',
    mongodb: 'templates/mongodb.yaml',
    redis: 'templates/redis.yaml',
    object_storage: 'templates/object-storage.yaml',
    oidc: 'templates/oidc.yaml'
  },
  tools: {
    routability_probe: {
      path: 'tools/substrate-routability-probe.txt',
      sha256: 'sha256:' + '7'.repeat(64)
    }
  },
  checksums: {
    manifest: 'sha256:' + '8'.repeat(64)
  }
};
const substratePackDigest = digestJson(substratePack);
const bundleManifest = {
  schema_version: 'agentsmith.airgap-bundle-manifest/v1',
  release_id: releaseId,
  git_sha: gitSha,
  target_profile: targetProfile(),
  bindings: {
    release_contract_sha256: releaseContractDigest,
    deploy_template_package_sha256: digestText('deploy-template-package'),
    deploy_template_archive_sha256: digestText('archive'),
    deploy_template_manifest_sha256: digestText('manifest'),
    image_map_sha256: imageMapDigest,
    substrate_pack_manifest_sha256: substratePackDigest
  },
  components: [
    {
      kind: 'release_contract',
      path: 'components/release-contract.json',
      sha256: releaseContractDigest
    },
    {
      kind: 'deploy_template_package',
      path: 'components/deploy-template-package.json',
      sha256: digestText('deploy-template-package')
    },
    {
      kind: 'deploy_template_archive',
      path: 'components/agentsmith-deploy-template-package.tgz',
      sha256: digestText('archive')
    },
    {
      kind: 'image_map',
      path: 'components/image-map.json',
      sha256: imageMapDigest
    },
    {
      kind: 'substrate_pack_manifest',
      path: 'components/substrate-pack-manifest.json',
      sha256: substratePackDigest
    }
  ],
  image_artifact_declarations: [],
  payload_artifacts: [
    {
      id: 'operator_runbook',
      kind: 'runbook',
      path: 'payload/runbook.md',
      sha256: runbookDigest
    }
  ],
  operator_prerequisites: {
    substrate_connection_truth_ref: 'operator-substrate-truth-ref',
    target_registry_proof_ref: 'operator-registry-proof-ref',
    tools: []
  },
  substrate: {
    mode: 'kit_installed',
    bundled: true
  }
};
const bundleManifestDigest = digestJson(bundleManifest);
const bundleCheck = {
  schema: 'agentsmith.airgap-bundle-check-report/v1',
  scope: 'airgap_bundle_manifest_check_only',
  readiness: false,
  status: 'pass',
  release_id: releaseId,
  git_sha: gitSha,
  target_profile: targetProfile(),
  artifacts: {
    release_contract: {
      input_sha256: releaseContractDigest
    },
    bundle_manifest: {
      input_sha256: bundleManifestDigest,
      image_artifact_declaration_count: 0
    },
    image_map: {
      input_sha256: imageMapDigest,
      image_count: 1
    }
  },
  components_count: 5,
  image_artifact_declaration_count: 0,
  payload_artifact_count: 1,
  tool_count: 0,
  bundled_tool_count: 0,
  operator_prerequisite_tool_count: 0
};
const bundleCheckDigest = digestJson(bundleCheck);
const evidence = {
  schema_version: 'agentsmith.release-kit-evidence-envelope/v1',
  release_kit_output: airgapOutput,
  release_contract_digest: releaseContractDigest,
  release_id: releaseId,
  git_sha: gitSha,
  release_kit_version: '0.1.0',
  target_cluster: 'existing_kubernetes',
  substrate_source: 'kit_installed',
  distribution: 'airgap',
  target: {
    cluster: 'existing_kubernetes',
    server: profile
  },
  status: 'passed',
  failure_class: 'none',
  artifact_provenance: {
    schema_version: 'agentsmith.artifact-provenance/v1',
    provenance_kind: 'ci_artifact',
    producer_repo: 'github.com/agentsmith-project/agentsmith-release-kit',
    normalized_remote: 'github.com/agentsmith-project/agentsmith-release-kit',
    commit_sha: 'fedcba9876543210fedcba9876543210fedcba98',
    artifact_uri: 'gh-artifact://agentsmith-release-kit/evidence/20003/runbook-acceptance.tgz',
    generated_at: '2026-05-23T12:00:00.000Z',
    generator_command: 'bash scripts/verify-release.sh --bundle-create --evidence-root',
    generator_version: '0.1.0',
    attestation: 'none',
    subject_name: 'release-kit-evidence-subject',
    subject_uri: 'evidence-subject.json',
    subject_sha256: 'sha256:' + '0'.repeat(64),
    workflow_name: 'release-kit-focused-evidence',
    run_id: '20003',
    run_attempt: '1',
    job: 'bundle-create'
  }
};
const evidenceSubject = {
  schema_version: 'agentsmith.release-kit-evidence-subject/v1',
  files: [
    {
      path: 'evidence.json',
      sha256: digestText('evidence-projection')
    },
    {
      path: 'airgap-bundle-check-report.json',
      sha256: bundleCheckDigest
    },
    {
      path: 'airgap-bundle-manifest.json',
      sha256: bundleManifestDigest
    },
    {
      path: 'image-map.json',
      sha256: imageMapDigest
    },
    ...(mutation === 'missing_substrate_pack_subject'
      ? []
      : [
          {
            path: 'substrate-pack-manifest.json',
            sha256: substratePackDigest
          }
        ])
  ]
};
evidence.artifact_provenance.subject_sha256 = canonicalDigest(evidenceSubject);

const surface = {
  schema: 'agentsmith.operator-release-surface-report/v1',
  scope: 'operator_release_surface_v0',
  readiness: false,
  status: 'pass',
  surface: 'airgap-bundle',
  substrate_strategy: 'kit_provided',
  machine_profile: profile,
  release_id: releaseId,
  git_sha: gitSha,
  release_contract_digest: releaseContractDigest,
  producer_report_digests: {
    bundle_create_report: digestText('bundle-create-report'),
    airgap_bundle_check_report: bundleCheckDigest
  },
  steps: [
    {
      name: 'bundle-create',
      report_paths: ['bundle-create-report.json']
    },
    {
      name: 'airgap-bundle-check',
      report_paths: ['airgap-bundle-check-report.json']
    }
  ],
  airgap_handoff: {
    bundle_manifest_digest: bundleManifestDigest,
    airgap_bundle_check_report_digest: bundleCheckDigest,
    image_count: 1,
    payload_artifact_count: 1,
    tool_count: 0,
    target_registry_summary: {
      host: 'registry.release.example'
    }
  },
  airgap_evidence_handoff: {
    evidence_digest: 'pending',
    evidence_subject_digest: digestJson(evidenceSubject),
    airgap_bundle_check_report_digest: bundleCheckDigest,
    airgap_bundle_manifest_digest: bundleManifestDigest,
    image_map_digest: imageMapDigest,
    substrate_pack_manifest_digest: substratePackDigest
  }
};

switch (mutation) {
  case 'valid':
    break;
  case 'profile_mismatch':
    surface.machine_profile = 'existing_kubernetes/external_declared/airgap';
    break;
  case 'signed_provenance':
    evidence.artifact_provenance.provenance_kind = 'signed_operator_run';
    evidence.artifact_provenance.operator_identity = 'release-operator@example.com';
    evidence.artifact_provenance.signature_uri =
      'https://signatures.example.com/agentsmith-release-kit/operator.sig';
    evidence.artifact_provenance.signature_sha256 = 'sha256:' + 'b'.repeat(64);
    break;
  case 'formal_readiness_fields':
    evidence.readiness = false;
    evidence.formal_verdict = 'accepted';
    break;
  case 'operator_identity':
    evidence.artifact_provenance.operator_identity = 'release-operator@example.com';
    break;
  case 'missing_substrate_pack_file':
    break;
  case 'missing_substrate_pack_subject':
    break;
  case 'missing_substrate_pack_handoff':
    delete surface.airgap_evidence_handoff.substrate_pack_manifest_digest;
    break;
  case 'producer_bundle_check_digest_mismatch':
    surface.producer_report_digests.airgap_bundle_check_report =
      digestText('wrong-producer-bundle-check-report');
    break;
  case 'airgap_handoff_bundle_check_digest_mismatch':
    surface.airgap_handoff.airgap_bundle_check_report_digest =
      digestText('wrong-handoff-bundle-check-report');
    break;
  case 'airgap_handoff_manifest_digest_mismatch':
    surface.airgap_handoff.bundle_manifest_digest = digestText('wrong-handoff-bundle-manifest');
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.mkdirSync(evidenceRoot, { recursive: true });
writeJson(path.join(evidenceRoot, 'airgap-bundle-check-report.json'), bundleCheck);
writeJson(path.join(evidenceRoot, 'airgap-bundle-manifest.json'), bundleManifest);
writeJson(path.join(evidenceRoot, 'image-map.json'), imageMap);
writeJson(path.join(evidenceRoot, 'evidence-subject.json'), evidenceSubject);
writeJson(path.join(evidenceRoot, 'evidence.json'), evidence);
if (mutation !== 'missing_substrate_pack_file') {
  writeJson(path.join(evidenceRoot, 'substrate-pack-manifest.json'), substratePack);
}
surface.airgap_evidence_handoff.evidence_digest =
  digestBuffer(fs.readFileSync(path.join(evidenceRoot, 'evidence.json')));
writeJson(path.join(caseDir, 'operator-release-surface-report.json'), surface);
NODE
}

assert_operator_success_contract_docs

valid_case="$TMP_DIR/case-valid"
valid_out="$TMP_DIR/out-valid"
write_case "$valid_case"
run_acceptance "$valid_case" "$valid_out" >/dev/null
[[ -f "$valid_out/$REPORT_FILE" ]] || fail "operator runbook acceptance report missing"
assert_acceptance_report "$valid_out/$REPORT_FILE"
pass "operator runbook acceptance binds choice, machine profile, surface, evidence, and safe runbook digest"

expect_fail machine-profile-mismatch profile_mismatch
expect_fail kind-profile valid "kind_rehearsal/kit_installed/airgap"
expect_fail local-kind-profile valid "local-kind/kit_installed/airgap"
expect_fail signed-provenance signed_provenance
expect_fail formal-readiness-fields formal_readiness_fields
expect_fail operator-identity operator_identity
expect_fail missing-substrate-pack-file missing_substrate_pack_file
expect_fail missing-substrate-pack-subject missing_substrate_pack_subject
expect_fail missing-substrate-pack-handoff missing_substrate_pack_handoff
expect_fail producer-bundle-check-digest-mismatch producer_bundle_check_digest_mismatch
expect_fail airgap-handoff-bundle-check-digest-mismatch airgap_handoff_bundle_check_digest_mismatch
expect_fail airgap-handoff-manifest-digest-mismatch airgap_handoff_manifest_digest_mismatch

pass "operator runbook acceptance focused tests completed"
