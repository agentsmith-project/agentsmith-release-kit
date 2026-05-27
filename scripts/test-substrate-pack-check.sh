#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
EXTERNAL_ONLINE_PROFILE="existing_kubernetes/external_declared/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
REPORT_FILE="substrate-pack-check-report.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

run_pack_check() {
  local target_profile="$1"
  local manifest="$2"
  local truth="$3"
  local output_dir="$4"

  bash "$ROOT_DIR/scripts/verify-release.sh" --substrate-pack-check \
    --target-profile "$target_profile" \
    --substrate-pack-manifest "$manifest" \
    --substrate-truth "$truth" \
    --output-dir "$output_dir"
}

assert_no_report() {
  local report_file="$1"
  [[ ! -e "$report_file" ]] || fail "unexpected substrate pack check report exists: $report_file"
}

write_stale_report() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
}

write_manifest() {
  local output="$1"
  local profile="$2"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$output" "$profile" "$mutation" <<'NODE'
import fs from 'node:fs';

const [output, profile, mutation] = process.argv.slice(2);
const digest = (char) => `sha256:${char.repeat(64)}`;
const image = (name, tag, char) =>
  `ghcr.io/agentsmith-project/substrates/${name}:${tag}@${digest(char)}`;

const manifest = {
  schema_version: 'agentsmith.substrate-pack-manifest/v1',
  release_kit_version: '0.1.0',
  installed_by: 'agentsmith-release-kit',
  target_profile: profile,
  images: {
    postgresql: image('postgresql', '16.3', '1'),
    mongodb: image('mongodb', '7.0', '2'),
    redis: image('redis', '7.2', '3'),
    object_storage: image('object-storage', '2026.05', '4'),
    oidc: image('keycloak', '25.0', '5')
  },
  payload: {
    install_plan: {
      path: 'payload/install-substrates.json',
      sha256: digest('6')
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
    checks: {
      path: 'tools/substrate-checks.txt',
      sha256: digest('7')
    }
  },
  checksums: {
    manifest: digest('8')
  }
};

switch (mutation) {
  case 'valid':
    break;
  case 'wrong_schema':
    manifest.schema_version = 'agentsmith.substrate-pack/v0';
    break;
  case 'v_prefixed_release_kit_version':
    manifest.release_kit_version = 'v0.1.0';
    break;
  case 'wrong_installed_by':
    manifest.installed_by = 'operator-workstation';
    break;
  case 'target_profile_mismatch':
    manifest.target_profile = 'existing_kubernetes/kit_installed/airgap';
    break;
  case 'missing_required_image':
    delete manifest.images.mongodb;
    break;
  case 'non_digest_image':
    manifest.images.redis = 'ghcr.io/agentsmith-project/substrates/redis:7.2';
    break;
  case 'latest_image':
    manifest.images.redis =
      'ghcr.io/agentsmith-project/substrates/redis:' + 'late' + 'st@' + digest('3');
    break;
  case 'localhost_image':
    manifest.images.postgresql = 'localhost:5000/substrates/postgresql:16.3@' + digest('1');
    break;
  case 'ipv6_loopback_image':
    manifest.images.postgresql = '[::1]:5000/substrates/postgresql:16.3@' + digest('1');
    break;
  case 'unsafe_path':
    manifest.payload.install_plan.path = '../payload/install-substrates.json';
    break;
  case 'source_uri':
    manifest.templates.postgresql =
      'source://' + 'workspace/substrate/templates/postgresql.yaml';
    break;
  case 'source_uri_key':
    manifest.payload['source://' + 'workspace/foo'] = 'payload/source-workspace-foo.json';
    break;
  case 'secret_payload':
    manifest.payload['access_' + 'token'] = 'Bearer ' + 'notrealcredential12345';
    break;
  case 'public_download':
    manifest.tools.kubectl = 'curl https://downloads.example.invalid/kubectl';
    break;
  case 'public_download_key':
    manifest.tools.public_download = 'tools/kubectl';
    break;
  case 'empty_tools':
    manifest.tools = {};
    break;
  default:
    throw new Error(`unknown manifest mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

write_truth() {
  local output="$1"
  local profile="$2"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$output" "$profile" "$mutation" <<'NODE'
import fs from 'node:fs';

const [output, profile, mutation] = process.argv.slice(2);
const [targetCluster, substrateSource, distribution] = profile.split('/');

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
      proof: `operator ${name} tcp/tls check 2026-05-23T12:00:00Z`
    }
  };
}

const truth = {
  schema_version: 'agentsmith.substrate-connection.truth/v1',
  target_cluster: targetCluster,
  substrate_source: substrateSource,
  distribution,
  declared_at: '2026-05-23T12:00:00.000Z',
  declared_by: 'release-operator@example.com',
  installed_by: 'agentsmith-release-kit',
  release_kit_version: '0.1.0',
  installation_id: 'kit-install-10001',
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
        proof: 'operator bucket head-object check 2026-05-23T12:00:00Z'
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
        proof: 'operator oidc discovery check 2026-05-23T12:00:00Z'
      }
    }
  }
};

switch (mutation) {
  case 'valid':
    break;
  case 'missing_required_service':
    delete truth.services.mongodb;
    break;
  case 'wrong_installed_by':
    truth.installed_by = 'operator-workstation';
    break;
  case 'raw_kubeconfig':
    truth.target_access = {
      ['kube' + 'config']: 'apiVersion: v1\nclusters:\n- name: release'
    };
    break;
  case 'source_path':
    truth.operator_note =
      '/home/percy/works/mbos-v1/' + 'agent' + 'smith/' + 'src/' + 'app/page.tsx';
    break;
  default:
    throw new Error(`unknown truth mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"
  local expected_profile="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.substrate-pack-check-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'substrate_pack_check_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('substrate pack check report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (!report.inputs?.substrate_pack_manifest?.input_sha256?.startsWith('sha256:')) {
  throw new Error('substrate pack manifest input sha is missing');
}
if (!report.inputs?.substrate_truth?.input_sha256?.startsWith('sha256:')) {
  throw new Error('substrate truth input sha is missing');
}
if (report.summary?.required_images_count !== 5) {
  throw new Error('required substrate image count must be summarized');
}
if (report.summary?.substrate_services_count !== 5) {
  throw new Error('required substrate service count must be summarized');
}
for (const section of ['payload', 'templates', 'tools', 'checksums']) {
  if (!report.summary?.material_sections?.[section]?.entries_count) {
    throw new Error(`missing material section summary: ${section}`);
  }
}
if (/release_verdict|deploy_readiness|product_flow|kubeconfig|Bearer/i.test(serialized)) {
  throw new Error('substrate pack report must not contain verdict, deploy readiness, product flow, kubeconfig, or raw secret content');
}
NODE
}

expect_fail() {
  local label="$1"
  local manifest_mutation="${2:-$label}"
  local truth_mutation="${3:-valid}"
  local target_profile="${4:-$KIT_ONLINE_PROFILE}"
  local manifest_profile="${5:-$target_profile}"
  local truth_profile="${6:-$target_profile}"
  local manifest_file="$TMP_DIR/manifest-$label.json"
  local truth_file="$TMP_DIR/truth-$label.json"
  local output_dir="$TMP_DIR/out-$label"

  write_manifest "$manifest_file" "$manifest_profile" "$manifest_mutation"
  write_truth "$truth_file" "$truth_profile" "$truth_mutation"
  write_stale_report "$output_dir"

  if run_pack_check "$target_profile" "$manifest_file" "$truth_file" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid substrate pack check case to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid substrate pack check rejected: $label"
}

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  expect_fail "$label" valid valid "$target_profile" "$KIT_ONLINE_PROFILE" "$KIT_ONLINE_PROFILE"
}

expect_evidence_reject() {
  local evidence_root="$TMP_DIR/evidence-substrate-pack"
  local output_dir="$TMP_DIR/out-evidence-substrate-pack"

  mkdir -p "$evidence_root"
  "$NODE_BIN" --input-type=module - "$evidence_root" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [evidenceRoot] = process.argv.slice(2);
const evidence = {
  schema_version: 'agentsmith.release-kit-evidence-envelope/v1',
  release_kit_version: '0.1.0',
  release_kit_output: 'substrate-pack-check-report.json',
  artifact_provenance: {}
};
const subject = {
  schema_version: 'agentsmith.release-kit-evidence-subject/v1',
  files: []
};
fs.writeFileSync(path.join(evidenceRoot, 'evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`);
fs.writeFileSync(
  path.join(evidenceRoot, 'evidence-subject.json'),
  `${JSON.stringify(subject, null, 2)}\n`
);
NODE

  if bash "$ROOT_DIR/scripts/verify-release.sh" --evidence \
    --release-contract "$VALID_CONTRACT" \
    --evidence-root "$evidence_root" \
    --target-profile "$EXTERNAL_ONLINE_PROFILE" \
    --output-dir "$output_dir" >"$TMP_DIR/evidence-substrate-pack.out" 2>"$TMP_DIR/evidence-substrate-pack.err"; then
    cat "$TMP_DIR/evidence-substrate-pack.out" >&2
    cat "$TMP_DIR/evidence-substrate-pack.err" >&2
    fail "expected substrate pack check report to be rejected by evidence intake"
  fi
  if ! grep -Fq 'substrate-pack-check-report.json' "$TMP_DIR/evidence-substrate-pack.err"; then
    cat "$TMP_DIR/evidence-substrate-pack.out" >&2
    cat "$TMP_DIR/evidence-substrate-pack.err" >&2
    fail "evidence rejection must name substrate-pack-check-report.json"
  fi
  pass "substrate pack check report rejected by evidence intake"
}

ONLINE_MANIFEST="$TMP_DIR/manifest-online-valid.json"
ONLINE_TRUTH="$TMP_DIR/truth-online-valid.json"
ONLINE_OUT="$TMP_DIR/out-online-valid"
write_manifest "$ONLINE_MANIFEST" "$KIT_ONLINE_PROFILE" valid
write_truth "$ONLINE_TRUTH" "$KIT_ONLINE_PROFILE" valid
run_pack_check "$KIT_ONLINE_PROFILE" "$ONLINE_MANIFEST" "$ONLINE_TRUTH" "$ONLINE_OUT" >/dev/null
assert_report "$ONLINE_OUT/$REPORT_FILE" "$KIT_ONLINE_PROFILE"
pass "valid existing_kubernetes/kit_installed/online substrate pack accepted"

AIRGAP_MANIFEST="$TMP_DIR/manifest-airgap-valid.json"
AIRGAP_TRUTH="$TMP_DIR/truth-airgap-valid.json"
AIRGAP_OUT="$TMP_DIR/out-airgap-valid"
write_manifest "$AIRGAP_MANIFEST" "$KIT_AIRGAP_PROFILE" valid
write_truth "$AIRGAP_TRUTH" "$KIT_AIRGAP_PROFILE" valid
run_pack_check "$KIT_AIRGAP_PROFILE" "$AIRGAP_MANIFEST" "$AIRGAP_TRUTH" "$AIRGAP_OUT" >/dev/null
assert_report "$AIRGAP_OUT/$REPORT_FILE" "$KIT_AIRGAP_PROFILE"
pass "valid existing_kubernetes/kit_installed/airgap substrate pack accepted"

expect_profile_fail unsupported-external-declared "$EXTERNAL_ONLINE_PROFILE"
expect_profile_fail unsupported-kind-rehearsal 'kind_rehearsal/kit_installed/online'
expect_profile_fail noncanonical-local-kind 'local-kind/kit_installed/online'
expect_profile_fail noncanonical-existing-cluster 'existing-cluster/kit_installed/online'
expect_profile_fail noncanonical-real-k8s 'real-k8s/kit_installed/online'
expect_profile_fail synonym-kind 'kind/kit_installed/online'
expect_profile_fail synonym-existing-cluster 'existing_kubernetes/existing-cluster/online'
expect_profile_fail synonym-real-k8s 'real-k8s/kit_installed/online'
expect_profile_fail synonym-cluster 'existing_kubernetes/cluster/online'
expect_profile_fail synonym-offline 'existing_kubernetes/kit_installed/offline'

expect_fail wrong-schema wrong_schema
expect_fail v-prefixed-release-kit-version v_prefixed_release_kit_version
expect_fail wrong-installed-by wrong_installed_by
expect_fail manifest-target-profile-mismatch target_profile_mismatch
expect_fail missing-required-image missing_required_image
expect_fail missing-required-service valid missing_required_service
expect_fail non-digest-image non_digest_image
expect_fail latest-image latest_image
expect_fail localhost-image localhost_image
expect_fail ipv6-loopback-image ipv6_loopback_image
expect_fail unsafe-path unsafe_path
expect_fail source-uri source_uri
expect_fail source-uri-key source_uri_key
expect_fail secret-payload secret_payload
expect_fail public-download public_download
expect_fail public-download-key public_download_key
expect_fail empty-tools empty_tools
expect_fail truth-profile-mismatch valid valid "$KIT_ONLINE_PROFILE" "$KIT_ONLINE_PROFILE" "$KIT_AIRGAP_PROFILE"
expect_fail truth-wrong-installed-by valid wrong_installed_by
expect_fail truth-raw-kubeconfig valid raw_kubeconfig
expect_fail truth-source-path valid source_path

expect_evidence_reject

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "substrate pack check diagnostic is not release readiness"
