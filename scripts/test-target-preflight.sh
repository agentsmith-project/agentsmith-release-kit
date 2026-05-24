#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
EXTERNAL_PROFILE="existing_kubernetes/external_declared/online"
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
  case 'localhost_endpoint':
    truth.services.postgresql.host = 'localhost';
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
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

run_target_preflight() {
  local target_profile="$1"
  local substrate_truth="$2"
  local output_dir="$3"

  bash "$ROOT_DIR/scripts/verify-release.sh" --target-preflight \
    --target-profile "$target_profile" \
    --substrate-truth "$substrate_truth" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local mutation="${2:-$label}"
  local target_profile="${3:-$EXTERNAL_PROFILE}"
  local truth_file="$TMP_DIR/truth-$label.json"
  local output_dir="$TMP_DIR/out-$label"

  write_truth "$truth_file" "$EXTERNAL_PROFILE" "$mutation"

  if run_target_preflight "$target_profile" "$truth_file" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target preflight case to fail: $label"
  fi

  pass "invalid target preflight rejected: $label"
}

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local truth_file="$TMP_DIR/truth-profile-$label.json"
  local output_dir="$TMP_DIR/out-profile-$label"

  write_truth "$truth_file" "$EXTERNAL_PROFILE" valid

  if run_target_preflight "$target_profile" "$truth_file" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  pass "legacy or synonym target profile rejected: $label"
}

assert_pass_report() {
  local report_file="$1"
  local expected_profile="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (report.scope !== 'target_preflight_intake_only') {
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
if ('release_verdict' in report || 'verdict' in report) {
  throw new Error('target preflight report must not claim a release verdict');
}
NODE
}

EXTERNAL_TRUTH="$TMP_DIR/external-valid.json"
EXTERNAL_OUT="$TMP_DIR/out-external-valid"
write_truth "$EXTERNAL_TRUTH" "$EXTERNAL_PROFILE" valid
run_target_preflight "$EXTERNAL_PROFILE" "$EXTERNAL_TRUTH" "$EXTERNAL_OUT" >/dev/null
assert_pass_report "$EXTERNAL_OUT/target-preflight-report.json" "$EXTERNAL_PROFILE"
pass "valid existing_kubernetes/external_declared/online truth accepted with focused non-readiness report"

KIT_TRUTH="$TMP_DIR/kit-valid.json"
KIT_OUT="$TMP_DIR/out-kit-valid"
write_truth "$KIT_TRUTH" "$KIT_PROFILE" valid
run_target_preflight "$KIT_PROFILE" "$KIT_TRUTH" "$KIT_OUT" >/dev/null
assert_pass_report "$KIT_OUT/target-preflight-report.json" "$KIT_PROFILE"
pass "valid kind_rehearsal/kit_installed/online truth accepted"

SSLMODE_ONLY_TRUTH="$TMP_DIR/sslmode-only-valid.json"
SSLMODE_ONLY_OUT="$TMP_DIR/out-sslmode-only-valid"
write_truth "$SSLMODE_ONLY_TRUTH" "$EXTERNAL_PROFILE" sslmode_only
run_target_preflight "$EXTERNAL_PROFILE" "$SSLMODE_ONLY_TRUTH" "$SSLMODE_ONLY_OUT" >/dev/null
assert_pass_report "$SSLMODE_ONLY_OUT/target-preflight-report.json" "$EXTERNAL_PROFILE"
pass "valid sslmode-only truth accepted"

REDACTED_FINGERPRINT_TRUTH="$TMP_DIR/redacted-fingerprint-valid.json"
REDACTED_FINGERPRINT_OUT="$TMP_DIR/out-redacted-fingerprint-valid"
write_truth "$REDACTED_FINGERPRINT_TRUTH" "$EXTERNAL_PROFILE" redacted_fingerprint
run_target_preflight "$EXTERNAL_PROFILE" "$REDACTED_FINGERPRINT_TRUTH" "$REDACTED_FINGERPRINT_OUT" >/dev/null
assert_pass_report "$REDACTED_FINGERPRINT_OUT/target-preflight-report.json" "$EXTERNAL_PROFILE"
pass "valid redacted fingerprint truth accepted"

expect_profile_fail legacy-local-kind 'local-kind/external_declared/online'
expect_profile_fail legacy-existing-cluster 'existing-cluster/external_declared/online'
expect_profile_fail legacy-real-k8s 'real-k8s/external_declared/online'
expect_profile_fail synonym-kind 'kind/external_declared/online'
expect_profile_fail synonym-substrate-cluster 'existing_kubernetes/cluster/online'
expect_profile_fail synonym-distribution-cluster 'existing_kubernetes/external_declared/cluster'

if bash "$ROOT_DIR/scripts/verify-release.sh" --target-preflight \
  --target-profile "$EXTERNAL_PROFILE" \
  --output-dir "$TMP_DIR/out-missing-truth" >"$TMP_DIR/missing-truth.out" 2>"$TMP_DIR/missing-truth.err"; then
  fail "expected missing substrate truth to fail"
fi
pass "missing substrate truth rejected"

expect_fail wrong-schema wrong_schema
expect_fail target-profile-mismatch target_mismatch
expect_fail missing-endpoint missing_endpoint
expect_fail missing-secret-ref missing_secret_ref
expect_fail missing-tls missing_tls
expect_fail missing-vector-extension missing_vector_extension
expect_fail missing-reachability missing_reachability
expect_fail localhost-endpoint localhost_endpoint
expect_fail raw-password raw_password
expect_fail raw-token raw_token
expect_fail raw-connection-string raw_connection_string
expect_fail raw-kubeconfig raw_kubeconfig
expect_fail source-path source_path

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "target preflight diagnostic is not release readiness"
