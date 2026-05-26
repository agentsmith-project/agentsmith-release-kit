#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
EXTERNAL_PROFILE="existing_kubernetes/external_declared/online"
EXTERNAL_AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
EXISTING_KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
EXISTING_KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
KIT_PROFILE="kind_rehearsal/kit_installed/online"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
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

function useSslmodeOnly() {
  for (const service of Object.values(truth.services)) {
    delete service.tls;
    service.sslmode = 'verify-full';
  }
}

function useRedactedFingerprints() {
  const fingerprint = `redacted:sha256:${'b'.repeat(64)}`;
  truth.services.postgresql.credential_secret_ref = fingerprint;
  truth.services.postgresql.admin_secret_ref = fingerprint;
  truth.services.postgresql.tls.ca_secret_ref = fingerprint;
  truth.services.mongodb.credential_secret_ref = fingerprint;
  truth.services.mongodb.tls.ca_secret_ref = fingerprint;
  truth.services.redis.credential_secret_ref = fingerprint;
  truth.services.redis.tls.ca_secret_ref = fingerprint;
  truth.services.object_storage.credential_secret_ref = fingerprint;
  truth.services.object_storage.tls.ca_secret_ref = fingerprint;
  truth.services.oidc.client_secret_ref = fingerprint;
  truth.services.oidc.tls.ca_secret_ref = fingerprint;
}

if (substrateSource === 'kit_installed') {
  truth.installed_by = 'agentsmith-release-kit';
  truth.release_kit_version = '0.1.0';
  truth.installation_id = 'kit-install-10001';
}

switch (mutation) {
  case 'valid':
    break;
  case 'wrong_schema':
    truth.schema_version = 'docker-substrate.truth/v1';
    break;
  case 'target_mismatch':
    truth.target_cluster = 'kind_rehearsal';
    break;
  case 'missing_endpoint':
    delete truth.services.mongodb.host;
    break;
  case 'missing_secret_ref':
    delete truth.services.redis.credential_secret_ref;
    break;
  case 'missing_tls':
    delete truth.services.object_storage.tls;
    break;
  case 'missing_vector_extension':
    delete truth.services.postgresql.extensions;
    break;
  case 'missing_reachability':
    delete truth.services.oidc.reachability;
    break;
  case 'reachability_status_reachable':
    truth.services.postgresql.reachability.status = 'reachable';
    break;
  case 'reachability_status_passed':
    truth.services.mongodb.reachability.status = 'passed';
    break;
  case 'vector_status_enabled':
    truth.services.postgresql.extensions.pgvector.status = 'enabled';
    break;
  case 'vector_status_available':
    truth.services.postgresql.extensions.pgvector.status = 'available';
    break;
  case 'vector_extension_alias':
    truth.services.postgresql.extensions.vector = truth.services.postgresql.extensions.pgvector;
    delete truth.services.postgresql.extensions.pgvector;
    break;
  case 'postgresql_endpoint_alias':
    truth.services.postgresql.endpoint = truth.services.postgresql.host;
    delete truth.services.postgresql.host;
    break;
  case 'mongodb_url_alias':
    truth.services.mongodb.url = 'https://mongodb.release.example.internal';
    delete truth.services.mongodb.host;
    break;
  case 'redis_endpoint_alias':
    truth.services.redis.endpoint = truth.services.redis.host;
    delete truth.services.redis.host;
    break;
  case 'object_storage_host_alias':
    truth.services.object_storage.host = 'objects.release.example.internal';
    delete truth.services.object_storage.url;
    break;
  case 'object_storage_missing_region':
    delete truth.services.object_storage.region;
    break;
  case 'object_storage_userinfo_url':
    truth.services.object_storage.url = 'https://operator@objects.release.example.internal';
    break;
  case 'oidc_issuer_alias':
    truth.services.oidc.issuer = truth.services.oidc.issuer_url;
    delete truth.services.oidc.issuer_url;
    break;
  case 'localhost_endpoint':
    truth.services.postgresql.host = 'localhost';
    break;
  case 'localhost_with_port_endpoint':
    truth.services.postgresql.host = 'localhost:5432';
    break;
  case 'loopback_ip_with_port_endpoint':
    truth.services.postgresql.host = '127.0.0.1:5432';
    break;
  case 'unspecified_ip_with_port_endpoint':
    truth.services.redis.host = '0.0.0.0:6379';
    break;
  case 'top_level_namespace':
    truth.namespace = 'agentsmith';
    break;
  case 'top_level_ingress':
    truth.ingress = {
      host: 'agentsmith.release.example.com',
      tls_secret_ref: 'secretRef:release/agentsmith-ingress-tls'
    };
    break;
  case 'sslmode_only':
    useSslmodeOnly();
    break;
  case 'redacted_fingerprint':
    useRedactedFingerprints();
    break;
  case 'raw_password':
    truth.services.postgresql['pass' + 'word'] = 'plain-' + 'cre' + 'dential-value';
    break;
  case 'raw_token':
    truth.services.oidc['access_' + 'token'] = 'Bearer ' + 'notrealcredential12345';
    break;
  case 'raw_connection_string':
    truth.services.postgresql.url =
      'postgres' + '://user:' + 'password' + '@postgresql.release.example.internal:5432/appdb';
    break;
  case 'raw_kubeconfig':
    truth.target_access = {
      ['kube' + 'config']: 'apiVersion: v1\nclusters:\n- name: release'
    };
    break;
  case 'source_path':
    truth.operator_note =
      '/home/percy/works/mbos-v1/' + 'agent' + 'smith/' + 'sr' + 'c/ap' + 'p/page.tsx';
    break;
  case 'bare_host_docker_internal':
    truth.operator_note = 'declared by host.docker.internal';
    break;
  case 'v_prefixed_release_kit_version':
    truth.release_kit_version = 'v0.1.0';
    break;
  case 'short_release_kit_version':
    truth.release_kit_version = '0.1';
    break;
  case 'leading_zero_release_kit_version':
    truth.release_kit_version = '0.01.0';
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_prerequisites() {
  local output="$1"
  local profile="$2"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$output" "$profile" "$mutation" <<'NODE'
import fs from 'node:fs';

const [output, profile, mutation] = process.argv.slice(2);

const substrateSecretRefs = [
  'secretRef:release/postgresql-credential',
  'secretRef:release/postgresql-admin',
  'secretRef:release/postgresql-ca',
  'secretRef:release/mongodb-credential',
  'secretRef:release/mongodb-ca',
  'secretRef:release/redis-credential',
  'secretRef:release/redis-ca',
  'secretRef:release/object-storage-credential',
  'secretRef:release/object-storage-ca',
  'secretRef:release/oidc-client',
  'secretRef:release/oidc-ca'
];

const prerequisites = {
  schema_version: 'agentsmith.target-prerequisites.truth/v1',
  target_profile: profile,
  namespace: 'agentsmith',
  rbac: {
    policy: 'pre_provisioned',
    proof: 'operator kubectl auth can-i apply deployments in namespace agentsmith 2026-05-23T12:00:00Z'
  },
  ingress: {
    host: 'agentsmith.release.example.com',
    tls_secret_ref: 'secretRef:release/agentsmith-ingress-tls'
  },
  registry: {
    pull_secret_ref: 'secretRef:release/registry-pull'
  },
  storage: {
    storage_class: 'gp3',
    persistent_volume_policy: 'dynamic'
  },
  substrate_secret_refs: substrateSecretRefs
};

function useSslmodeOnlyRefs() {
  prerequisites.substrate_secret_refs = prerequisites.substrate_secret_refs.filter(
    (ref) => !ref.endsWith('-ca')
  );
}

function useRedactedFingerprints() {
  const fingerprint = `redacted:sha256:${'b'.repeat(64)}`;
  prerequisites.ingress.tls_secret_ref = fingerprint;
  prerequisites.registry.pull_secret_ref = fingerprint;
  prerequisites.substrate_secret_refs = [fingerprint];
}

switch (mutation) {
  case 'valid':
    break;
  case 'sslmode_only':
    useSslmodeOnlyRefs();
    break;
  case 'redacted_fingerprint':
    useRedactedFingerprints();
    break;
  case 'wrong_schema':
    prerequisites.schema_version = 'agentsmith.kubernetes-prerequisites/v1';
    break;
  case 'target_profile_mismatch':
    prerequisites.target_profile = 'kind_rehearsal/kit_installed/online';
    break;
  case 'missing_namespace':
    delete prerequisites.namespace;
    break;
  case 'namespace_mismatch':
    prerequisites.namespace = 'agentsmith-other';
    break;
  case 'missing_rbac':
    delete prerequisites.rbac;
    break;
  case 'missing_rbac_policy_and_proof':
    delete prerequisites.rbac.policy;
    delete prerequisites.rbac.proof;
    break;
  case 'missing_ingress_host':
    delete prerequisites.ingress.host;
    break;
  case 'missing_ingress_tls_secret_ref':
    delete prerequisites.ingress.tls_secret_ref;
    break;
  case 'missing_registry_pull_secret_ref':
    delete prerequisites.registry.pull_secret_ref;
    break;
  case 'missing_storage_class':
    delete prerequisites.storage.storage_class;
    break;
  case 'missing_persistent_volume_policy':
    delete prerequisites.storage.persistent_volume_policy;
    break;
  case 'missing_substrate_secret_ref':
    prerequisites.substrate_secret_refs = prerequisites.substrate_secret_refs.filter(
      (ref) => ref !== 'secretRef:release/redis-credential'
    );
    break;
  case 'extra_substrate_secret_ref':
    prerequisites.substrate_secret_refs.push('secretRef:release/not-declared-by-substrate');
    break;
  case 'plaintext_registry_pull_secret':
    prerequisites.registry.pull_secret_ref = 'plain-registry-secret-value';
    break;
  case 'empty_registry_pull_secret':
    prerequisites.registry.pull_secret_ref = '';
    break;
  case 'ingress_localhost':
    prerequisites.ingress.host = 'localhost';
    break;
  case 'ingress_host_docker_internal':
    prerequisites.ingress.host = 'host.docker.internal';
    break;
  case 'ingress_userinfo':
    prerequisites.ingress.host = 'operator@agentsmith.release.example.com';
    break;
  case 'ingress_url_with_userinfo':
    prerequisites.ingress.host = 'https://operator@agentsmith.release.example.com';
    break;
  case 'raw_kubeconfig':
    prerequisites.target_access = {
      ['kube' + 'config']: 'apiVersion: v1\nclusters:\n- name: release'
    };
    break;
  case 'provider_matrix':
    prerequisites.provider_matrix = {
      eks: 'not_in_pre_ga_scope'
    };
    break;
  case 'rollback_plan':
    prerequisites.rollback_plan = {
      strategy: 'future_release_scope'
    };
    break;
  case 'live_k8s_checks':
    prerequisites.live_k8s_checks = {
      enabled: true
    };
    break;
  default:
    throw new Error(`unknown prerequisites mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

run_target_preflight() {
  local target_profile="$1"
  local substrate_truth="$2"
  local target_prerequisites="$3"
  local output_dir="$4"
  shift 4 || true

  bash "$ROOT_DIR/scripts/verify-release.sh" --target-preflight \
    --target-profile "$target_profile" \
    --substrate-truth "$substrate_truth" \
    --target-prerequisites "$target_prerequisites" \
    --output-dir "$output_dir" \
    "$@"
}

expect_fail() {
  local label="$1"
  local mutation="${2:-$label}"
  local target_profile="${3:-$EXTERNAL_PROFILE}"
  local truth_file="$TMP_DIR/truth-$label.json"
  local prerequisites_file="$TMP_DIR/prerequisites-$label.json"
  local output_dir="$TMP_DIR/out-$label"

  write_truth "$truth_file" "$EXTERNAL_PROFILE" "$mutation"
  write_prerequisites "$prerequisites_file" "$EXTERNAL_PROFILE" valid

  if run_target_preflight "$target_profile" "$truth_file" "$prerequisites_file" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target preflight case to fail: $label"
  fi

  pass "invalid target preflight rejected: $label"
}

expect_kit_fail() {
  local label="$1"
  local mutation="${2:-$label}"
  local truth_file="$TMP_DIR/truth-kit-$label.json"
  local prerequisites_file="$TMP_DIR/prerequisites-kit-$label.json"
  local output_dir="$TMP_DIR/out-kit-$label"

  write_truth "$truth_file" "$KIT_PROFILE" "$mutation"
  write_prerequisites "$prerequisites_file" "$KIT_PROFILE" valid

  if run_target_preflight "$KIT_PROFILE" "$truth_file" "$prerequisites_file" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid kit target preflight case to fail: $label"
  fi

  pass "invalid kit target preflight rejected: $label"
}

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local truth_file="$TMP_DIR/truth-profile-$label.json"
  local prerequisites_file="$TMP_DIR/prerequisites-profile-$label.json"
  local output_dir="$TMP_DIR/out-profile-$label"

  write_truth "$truth_file" "$EXTERNAL_PROFILE" valid
  write_prerequisites "$prerequisites_file" "$EXTERNAL_PROFILE" valid

  if run_target_preflight "$target_profile" "$truth_file" "$prerequisites_file" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  pass "canonical profiles only; non-canonical pre-GA name or synonym axis rejected: $label"
}

expect_prerequisites_fail() {
  local label="$1"
  local mutation="${2:-$label}"
  local target_profile="${3:-$EXTERNAL_PROFILE}"
  local truth_mutation="${4:-valid}"
  local truth_file="$TMP_DIR/truth-prerequisites-$label.json"
  local prerequisites_file="$TMP_DIR/prerequisites-invalid-$label.json"
  local output_dir="$TMP_DIR/out-prerequisites-$label"

  write_truth "$truth_file" "$EXTERNAL_PROFILE" "$truth_mutation"
  write_prerequisites "$prerequisites_file" "$EXTERNAL_PROFILE" "$mutation"

  local extra_args=()
  if [[ "$mutation" == "namespace_mismatch" ]]; then
    extra_args+=(--expected-namespace agentsmith)
  fi

  if run_target_preflight "$target_profile" "$truth_file" "$prerequisites_file" "$output_dir" "${extra_args[@]}" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target prerequisites case to fail: $label"
  fi

  pass "invalid target prerequisites rejected: $label"
}

assert_pass_report() {
  local report_file="$1"
  local expected_profile="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (report.scope !== 'target_preflight_prerequisite_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('target preflight report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.target_prerequisites?.schema_version !== 'agentsmith.target-prerequisites.truth/v1') {
  throw new Error('target preflight report must summarize target prerequisites truth');
}
if (report.target_prerequisites?.namespace !== 'agentsmith') {
  throw new Error(`unexpected prerequisites namespace: ${report.target_prerequisites?.namespace}`);
}
if ('release_verdict' in report || 'verdict' in report) {
  throw new Error('target preflight report must not claim a release verdict');
}
NODE
}

EXTERNAL_TRUTH="$TMP_DIR/external-valid.json"
EXTERNAL_PREREQUISITES="$TMP_DIR/external-prerequisites-valid.json"
EXTERNAL_OUT="$TMP_DIR/out-external-valid"
write_truth "$EXTERNAL_TRUTH" "$EXTERNAL_PROFILE" valid
write_prerequisites "$EXTERNAL_PREREQUISITES" "$EXTERNAL_PROFILE" valid
run_target_preflight "$EXTERNAL_PROFILE" "$EXTERNAL_TRUTH" "$EXTERNAL_PREREQUISITES" "$EXTERNAL_OUT" >/dev/null
assert_pass_report "$EXTERNAL_OUT/target-preflight-report.json" "$EXTERNAL_PROFILE"
pass "valid existing_kubernetes/external_declared/online truth accepted with focused non-readiness report"

EXTERNAL_AIRGAP_TRUTH="$TMP_DIR/external-airgap-valid.json"
EXTERNAL_AIRGAP_PREREQUISITES="$TMP_DIR/external-airgap-prerequisites-valid.json"
EXTERNAL_AIRGAP_OUT="$TMP_DIR/out-external-airgap-valid"
write_truth "$EXTERNAL_AIRGAP_TRUTH" "$EXTERNAL_AIRGAP_PROFILE" valid
write_prerequisites "$EXTERNAL_AIRGAP_PREREQUISITES" "$EXTERNAL_AIRGAP_PROFILE" valid
run_target_preflight "$EXTERNAL_AIRGAP_PROFILE" "$EXTERNAL_AIRGAP_TRUTH" "$EXTERNAL_AIRGAP_PREREQUISITES" "$EXTERNAL_AIRGAP_OUT" >/dev/null
assert_pass_report "$EXTERNAL_AIRGAP_OUT/target-preflight-report.json" "$EXTERNAL_AIRGAP_PROFILE"
pass "valid existing_kubernetes/external_declared/airgap truth accepted"

EXISTING_KIT_ONLINE_TRUTH="$TMP_DIR/existing-kit-online-valid.json"
EXISTING_KIT_ONLINE_PREREQUISITES="$TMP_DIR/existing-kit-online-prerequisites-valid.json"
EXISTING_KIT_ONLINE_OUT="$TMP_DIR/out-existing-kit-online-valid"
write_truth "$EXISTING_KIT_ONLINE_TRUTH" "$EXISTING_KIT_ONLINE_PROFILE" valid
write_prerequisites "$EXISTING_KIT_ONLINE_PREREQUISITES" "$EXISTING_KIT_ONLINE_PROFILE" valid
run_target_preflight "$EXISTING_KIT_ONLINE_PROFILE" "$EXISTING_KIT_ONLINE_TRUTH" "$EXISTING_KIT_ONLINE_PREREQUISITES" "$EXISTING_KIT_ONLINE_OUT" >/dev/null
assert_pass_report \
  "$EXISTING_KIT_ONLINE_OUT/target-preflight-report.json" \
  "$EXISTING_KIT_ONLINE_PROFILE"
pass "valid existing_kubernetes/kit_installed/online truth accepted"

EXISTING_KIT_AIRGAP_TRUTH="$TMP_DIR/existing-kit-airgap-valid.json"
EXISTING_KIT_AIRGAP_PREREQUISITES="$TMP_DIR/existing-kit-airgap-prerequisites-valid.json"
EXISTING_KIT_AIRGAP_OUT="$TMP_DIR/out-existing-kit-airgap-valid"
write_truth "$EXISTING_KIT_AIRGAP_TRUTH" "$EXISTING_KIT_AIRGAP_PROFILE" valid
write_prerequisites "$EXISTING_KIT_AIRGAP_PREREQUISITES" "$EXISTING_KIT_AIRGAP_PROFILE" valid
run_target_preflight "$EXISTING_KIT_AIRGAP_PROFILE" "$EXISTING_KIT_AIRGAP_TRUTH" "$EXISTING_KIT_AIRGAP_PREREQUISITES" "$EXISTING_KIT_AIRGAP_OUT" >/dev/null
assert_pass_report \
  "$EXISTING_KIT_AIRGAP_OUT/target-preflight-report.json" \
  "$EXISTING_KIT_AIRGAP_PROFILE"
pass "valid existing_kubernetes/kit_installed/airgap truth accepted"

KIT_TRUTH="$TMP_DIR/kit-valid.json"
KIT_PREREQUISITES="$TMP_DIR/kit-prerequisites-valid.json"
KIT_OUT="$TMP_DIR/out-kit-valid"
write_truth "$KIT_TRUTH" "$KIT_PROFILE" valid
write_prerequisites "$KIT_PREREQUISITES" "$KIT_PROFILE" valid
run_target_preflight "$KIT_PROFILE" "$KIT_TRUTH" "$KIT_PREREQUISITES" "$KIT_OUT" >/dev/null
assert_pass_report "$KIT_OUT/target-preflight-report.json" "$KIT_PROFILE"
pass "valid kind_rehearsal/kit_installed/online truth accepted"

SSLMODE_ONLY_TRUTH="$TMP_DIR/sslmode-only-valid.json"
SSLMODE_ONLY_PREREQUISITES="$TMP_DIR/sslmode-only-prerequisites-valid.json"
SSLMODE_ONLY_OUT="$TMP_DIR/out-sslmode-only-valid"
write_truth "$SSLMODE_ONLY_TRUTH" "$EXTERNAL_PROFILE" sslmode_only
write_prerequisites "$SSLMODE_ONLY_PREREQUISITES" "$EXTERNAL_PROFILE" sslmode_only
run_target_preflight "$EXTERNAL_PROFILE" "$SSLMODE_ONLY_TRUTH" "$SSLMODE_ONLY_PREREQUISITES" "$SSLMODE_ONLY_OUT" >/dev/null
assert_pass_report "$SSLMODE_ONLY_OUT/target-preflight-report.json" "$EXTERNAL_PROFILE"
pass "valid sslmode-only truth accepted"

REDACTED_FINGERPRINT_TRUTH="$TMP_DIR/redacted-fingerprint-valid.json"
REDACTED_FINGERPRINT_PREREQUISITES="$TMP_DIR/redacted-fingerprint-prerequisites-valid.json"
REDACTED_FINGERPRINT_OUT="$TMP_DIR/out-redacted-fingerprint-valid"
write_truth "$REDACTED_FINGERPRINT_TRUTH" "$EXTERNAL_PROFILE" redacted_fingerprint
write_prerequisites "$REDACTED_FINGERPRINT_PREREQUISITES" "$EXTERNAL_PROFILE" redacted_fingerprint
run_target_preflight "$EXTERNAL_PROFILE" "$REDACTED_FINGERPRINT_TRUTH" "$REDACTED_FINGERPRINT_PREREQUISITES" "$REDACTED_FINGERPRINT_OUT" >/dev/null
assert_pass_report "$REDACTED_FINGERPRINT_OUT/target-preflight-report.json" "$EXTERNAL_PROFILE"
pass "valid redacted fingerprint truth accepted"

expect_profile_fail noncanonical-local-kind 'local-kind/external_declared/online'
expect_profile_fail noncanonical-existing-cluster 'existing-cluster/external_declared/online'
expect_profile_fail noncanonical-real-k8s 'real-k8s/external_declared/online'
expect_profile_fail synonym-kind 'kind/external_declared/online'
expect_profile_fail synonym-substrate-cluster 'existing_kubernetes/cluster/online'
expect_profile_fail synonym-distribution-cluster 'existing_kubernetes/external_declared/cluster'

MISSING_ARG_PREREQUISITES="$TMP_DIR/missing-arg-prerequisites-valid.json"
write_prerequisites "$MISSING_ARG_PREREQUISITES" "$EXTERNAL_PROFILE" valid

if bash "$ROOT_DIR/scripts/verify-release.sh" --target-preflight \
  --target-profile "$EXTERNAL_PROFILE" \
  --target-prerequisites "$MISSING_ARG_PREREQUISITES" \
  --output-dir "$TMP_DIR/out-missing-truth" >"$TMP_DIR/missing-truth.out" 2>"$TMP_DIR/missing-truth.err"; then
  fail "expected missing substrate truth to fail"
fi
pass "missing substrate truth rejected"

MISSING_ARG_TRUTH="$TMP_DIR/missing-arg-truth-valid.json"
write_truth "$MISSING_ARG_TRUTH" "$EXTERNAL_PROFILE" valid
if bash "$ROOT_DIR/scripts/verify-release.sh" --target-preflight \
  --target-profile "$EXTERNAL_PROFILE" \
  --substrate-truth "$MISSING_ARG_TRUTH" \
  --output-dir "$TMP_DIR/out-missing-prerequisites" >"$TMP_DIR/missing-prerequisites.out" 2>"$TMP_DIR/missing-prerequisites.err"; then
  fail "expected missing target prerequisites to fail"
fi
pass "missing target prerequisites rejected"

expect_fail wrong-schema wrong_schema
expect_fail target-profile-mismatch target_mismatch
expect_fail missing-endpoint missing_endpoint
expect_fail missing-secret-ref missing_secret_ref
expect_fail missing-tls missing_tls
expect_fail missing-vector-extension missing_vector_extension
expect_fail missing-reachability missing_reachability
expect_fail reachability-status-reachable reachability_status_reachable
expect_fail reachability-status-passed reachability_status_passed
expect_fail vector-status-enabled vector_status_enabled
expect_fail vector-status-available vector_status_available
expect_fail vector-extension-alias vector_extension_alias
expect_fail postgresql-endpoint-alias postgresql_endpoint_alias
expect_fail mongodb-url-alias mongodb_url_alias
expect_fail redis-endpoint-alias redis_endpoint_alias
expect_fail object-storage-host-alias object_storage_host_alias
expect_fail object-storage-missing-region object_storage_missing_region
expect_fail object-storage-userinfo-url object_storage_userinfo_url
expect_fail oidc-issuer-alias oidc_issuer_alias
expect_fail localhost-with-port-endpoint localhost_with_port_endpoint
expect_fail loopback-ip-with-port-endpoint loopback_ip_with_port_endpoint
expect_fail unspecified-ip-with-port-endpoint unspecified_ip_with_port_endpoint
expect_fail top-level-namespace top_level_namespace
expect_fail top-level-ingress top_level_ingress
expect_prerequisites_fail prerequisites-wrong-schema wrong_schema
expect_prerequisites_fail prerequisites-target-profile-mismatch target_profile_mismatch
expect_prerequisites_fail prerequisites-missing-namespace missing_namespace
expect_prerequisites_fail prerequisites-namespace-mismatch namespace_mismatch
expect_prerequisites_fail prerequisites-missing-rbac missing_rbac
expect_prerequisites_fail prerequisites-missing-rbac-policy-and-proof missing_rbac_policy_and_proof
expect_prerequisites_fail prerequisites-missing-ingress-host missing_ingress_host
expect_prerequisites_fail prerequisites-missing-ingress-tls-secret-ref missing_ingress_tls_secret_ref
expect_prerequisites_fail prerequisites-missing-registry-pull-secret-ref missing_registry_pull_secret_ref
expect_prerequisites_fail prerequisites-missing-storage-class missing_storage_class
expect_prerequisites_fail prerequisites-missing-persistent-volume-policy missing_persistent_volume_policy
expect_prerequisites_fail prerequisites-missing-substrate-secret-ref missing_substrate_secret_ref
expect_prerequisites_fail prerequisites-extra-substrate-secret-ref extra_substrate_secret_ref
expect_prerequisites_fail prerequisites-plaintext-registry-pull-secret plaintext_registry_pull_secret
expect_prerequisites_fail prerequisites-empty-registry-pull-secret empty_registry_pull_secret
expect_prerequisites_fail prerequisites-ingress-localhost ingress_localhost
expect_prerequisites_fail prerequisites-ingress-host-docker-internal ingress_host_docker_internal
expect_prerequisites_fail prerequisites-ingress-userinfo ingress_userinfo
expect_prerequisites_fail prerequisites-ingress-url-with-userinfo ingress_url_with_userinfo
expect_prerequisites_fail prerequisites-raw-kubeconfig raw_kubeconfig
expect_prerequisites_fail prerequisites-provider-matrix provider_matrix
expect_prerequisites_fail prerequisites-rollback-plan rollback_plan
expect_prerequisites_fail prerequisites-live-k8s-checks live_k8s_checks
expect_fail localhost-endpoint localhost_endpoint
expect_fail raw-password raw_password
expect_fail raw-token raw_token
expect_fail raw-connection-string raw_connection_string
expect_fail raw-kubeconfig raw_kubeconfig
expect_fail source-path source_path
expect_fail bare-host-docker-internal bare_host_docker_internal
expect_kit_fail v-prefixed-release-kit-version v_prefixed_release_kit_version
expect_kit_fail short-release-kit-version short_release_kit_version
expect_kit_fail leading-zero-release-kit-version leading_zero_release_kit_version

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "target preflight diagnostic is not release readiness"
