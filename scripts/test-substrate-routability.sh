#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
EXTERNAL_ONLINE_PROFILE="existing_kubernetes/external_declared/online"
KIND_ONLINE_PROFILE="kind_rehearsal/kit_installed/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
PACK_REPORT_FILE="substrate-pack-check-report.json"
REPORT_FILE="substrate-routability-report.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_manifest() {
  local output="$1"
  local profile="$2"

  "$NODE_BIN" --input-type=module - "$output" "$profile" <<'NODE'
import fs from 'node:fs';

const [output, profile] = process.argv.slice(2);
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
    routability_probe: {
      path: 'tools/substrate-routability-probe.txt',
      sha256: digest('7')
    }
  },
  checksums: {
    manifest: digest('8')
  }
};

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

function service(name, host, port) {
  return {
    host,
    port,
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
      ...service('postgresql', 'postgresql.release.example.internal', 5432),
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
      ...service('mongodb', 'mongodb.release.example.internal', 27017)
    },
    redis: {
      ...service('redis', 'redis.release.example.internal', 6379)
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
  case 'raw_kubeconfig':
    truth.target_access = {
      ['kube' + 'config']: 'apiVersion: v1\nclusters:\n- name: release'
    };
    break;
  default:
    throw new Error(`unknown truth mutation: ${mutation}`);
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

const prerequisites = {
  schema_version: 'agentsmith.target-prerequisites.truth/v1',
  target_profile: profile,
  namespace: 'agentsmith',
  rbac: {
    policy: 'pre_provisioned',
    proof: 'operator kubectl auth can-i create pods in namespace agentsmith 2026-05-23T12:00:00Z'
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
  substrate_secret_refs: [
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
  ]
};

switch (mutation) {
  case 'valid':
    break;
  case 'raw_kubeconfig':
    prerequisites.target_access = {
      ['kube' + 'config']: 'apiVersion: v1\nclusters:\n- name: release'
    };
    break;
  default:
    throw new Error(`unknown prerequisites mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
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

write_bound_inputs() {
  local label="$1"
  local profile="${2:-$KIT_ONLINE_PROFILE}"
  local truth_mutation="${3:-valid}"
  local prerequisites_mutation="${4:-valid}"

  local manifest="$TMP_DIR/manifest-$label.json"
  local truth="$TMP_DIR/truth-$label.json"
  local prerequisites="$TMP_DIR/prerequisites-$label.json"
  local pack_output="$TMP_DIR/pack-$label"

  write_manifest "$manifest" "$profile"
  write_truth "$truth" "$profile" "$truth_mutation"
  write_prerequisites "$prerequisites" "$profile" "$prerequisites_mutation"
  run_pack_check "$profile" "$manifest" "$truth" "$pack_output" >/dev/null

  printf '%s\n' "$truth"
  printf '%s\n' "$prerequisites"
  printf '%s\n' "$pack_output/$PACK_REPORT_FILE"
}

write_fake_kubectl() {
  local output="$1"
  local mode="${2:-pass}"

  "$NODE_BIN" --input-type=module - "$output" "$mode" <<'NODE'
import fs from 'node:fs';

const [output, mode] = process.argv.slice(2);
const script = `#!/usr/bin/env bash
set -euo pipefail
mode="${mode}"
printf '%s\\n' "$*" >> "\${KUBECTL_LOG:?KUBECTL_LOG required}"
if [[ "$*" == *"version --output=json"* ]]; then
  case "$mode" in
    pass)
      printf '%s\\n' '{"clientVersion":{"gitVersion":"v1.30.0"},"serverVersion":{"gitVersion":"v1.30.1"}}'
      ;;
    malicious_version)
      printf '%s\\n' '{"clientVersion":{"gitVersion":"Bearer abcdefghijkl","major":"token=TOKEN_SHOULD_NOT_LEAK12345","minor":"31","platform":"linux/amd64 kubeconfig"},"serverVersion":{"gitVersion":"v1.30.1","platform":"Bearer mnopqrstuvwx"}}'
      ;;
    *)
      echo "unexpected fake kubectl mode: $mode" >&2
      exit 65
      ;;
  esac
  exit 0
fi
echo "unexpected fake kubectl args: $*" >&2
exit 64
`;
fs.writeFileSync(output, script);
fs.chmodSync(output, 0o755);
NODE
}

write_fake_probe() {
  local output="$1"
  local mode="${2:-pass}"

  "$NODE_BIN" --input-type=module - "$output" "$mode" <<'NODE'
import fs from 'node:fs';

const [output, mode] = process.argv.slice(2);
const script = `#!/usr/bin/env bash
set -euo pipefail
mode="${mode}"
log="\${PROBE_LOG:?PROBE_LOG required}"
printf '%s\\n' "$*" >> "$log"
expected=""
service=""
endpoint=""
namespace=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --expected-fingerprint)
      expected="\${2:?expected fingerprint required}"
      shift 2
      ;;
    --service)
      service="\${2:?service required}"
      shift 2
      ;;
    --endpoint)
      endpoint="\${2:?endpoint required}"
      shift 2
      ;;
    --namespace)
      namespace="\${2:?namespace required}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ "$namespace" == "agentsmith" ]] || exit 21
[[ -n "$service" ]] || exit 22
[[ -n "$endpoint" ]] || exit 23
[[ -n "$expected" ]] || exit 24
case "$mode" in
  pass)
    printf '%s\\n' "$expected"
    ;;
  mismatch)
    printf '%s\\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  nonzero)
    printf '%s\\n' 'TOKEN_SHOULD_NOT_LEAK kubeconfig'
    printf '%s\\n' 'TOKEN_SHOULD_NOT_LEAK kubeconfig' >&2
    exit 42
    ;;
  *)
    exit 64
    ;;
esac
`;
fs.writeFileSync(output, script);
fs.chmodSync(output, 0o755);
NODE
}

KUBECTL_LOG="$TMP_DIR/kubectl.log"
PROBE_LOG="$TMP_DIR/probe.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"
FAKE_PROBE="$TMP_DIR/routability-probe"
export KUBECTL_LOG PROBE_LOG
write_fake_kubectl "$FAKE_KUBECTL"
write_fake_probe "$FAKE_PROBE" pass

reset_logs() {
  : >"$KUBECTL_LOG"
  : >"$PROBE_LOG"
}

assert_no_report() {
  local report_file="$1"
  [[ ! -e "$report_file" ]] || fail "unexpected substrate routability report exists: $report_file"
}

assert_no_leak_marker() {
  local label="$1"
  shift

  local file
  for file in "$@"; do
    if [[ -e "$file" ]] && grep -Eiq 'Bearer|TOKEN_SHOULD_NOT_LEAK|kubeconfig' "$file"; then
      fail "$label leaked raw kubectl/probe marker into $file"
    fi
  done
}

write_stale_report() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
}

run_substrate_routability() {
  local target_profile="$1"
  local substrate_truth="$2"
  local target_prerequisites="$3"
  local pack_report="$4"
  local output_dir="$5"
  shift 5 || true

  bash "$ROOT_DIR/scripts/verify-release.sh" --substrate-routability \
    --target-profile "$target_profile" \
    --substrate-pack-check-report "$pack_report" \
    --substrate-truth "$substrate_truth" \
    --target-prerequisites "$target_prerequisites" \
    --namespace agentsmith \
    --kubectl "$FAKE_KUBECTL" \
    --context release-admin \
    --kubeconfig "$TMP_DIR/kubeconfig.ref" \
    --routability-probe "$FAKE_PROBE" \
    --output-dir "$output_dir" \
    "$@"
}

mutate_report() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  "$NODE_BIN" --input-type=module - "$input" "$output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [input, output, mutation] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(input, 'utf8'));

switch (mutation) {
  case 'target_profile_mismatch':
    report.target_profile = {
      value: 'existing_kubernetes/kit_installed/airgap',
      target_cluster: 'existing_kubernetes',
      substrate_source: 'kit_installed',
      distribution: 'airgap'
    };
    break;
  case 'truth_digest_mismatch':
    report.inputs.substrate_truth.input_sha256 =
      'sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    break;
  case 'raw_kubeconfig':
    report.diagnostics = {
      ['kube' + 'config']: 'apiVersion: v1\nclusters:\n- name: release'
    };
    break;
  default:
    throw new Error(`unknown report mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" "$KIT_ONLINE_PROFILE" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.substrate-routability-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'substrate_routability_probe_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('substrate routability report must keep readiness=false');
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
if (!report.inputs?.substrate_pack_check_report?.input_sha256?.startsWith('sha256:')) {
  throw new Error('substrate pack check report input sha is missing');
}
if (!report.inputs?.substrate_truth?.input_sha256?.startsWith('sha256:')) {
  throw new Error('substrate truth input sha is missing');
}
if (!report.inputs?.target_prerequisites?.input_sha256?.startsWith('sha256:')) {
  throw new Error('target prerequisites input sha is missing');
}
if (report.inputs.substrate_pack_check_report.substrate_truth_input_sha256 !== report.inputs.substrate_truth.input_sha256) {
  throw new Error('pack report substrate truth digest must bind to substrate truth input digest');
}
const kubectlVersion = report.kubectl_version;
if (!kubectlVersion || typeof kubectlVersion !== 'object' || Array.isArray(kubectlVersion)) {
  throw new Error('kubectl version summary is missing');
}
if (!kubectlVersion.output_sha256?.startsWith('sha256:') || kubectlVersion.parsed !== true) {
  throw new Error('kubectl version summary must keep only output_sha256 and parsed=true');
}
if ('client' in kubectlVersion || 'server' in kubectlVersion || 'output' in kubectlVersion || 'parse_status' in kubectlVersion) {
  throw new Error('kubectl version summary must not store raw parsed version fields or raw stdout');
}
if (report.probe?.mode !== 'operator_pod_network_probe') {
  throw new Error(`unexpected probe mode: ${report.probe?.mode}`);
}
if (report.probe?.services_count !== 5 || !Array.isArray(report.results) || report.results.length !== 5) {
  throw new Error('probe results must include five substrate services');
}
for (const item of report.results) {
  if (!item.service || item.status !== 'pass' || !item.endpoint_fingerprint?.startsWith('sha256:')) {
    throw new Error('probe result must include service, pass status, and endpoint fingerprint');
  }
  if ('endpoint' in item || 'host' in item || 'url' in item || 'stdout' in item || 'stderr' in item) {
    throw new Error('probe result must not store raw endpoint or probe output');
  }
}
if (/release_verdict|deploy_readiness|product_flow|kubeconfig|Bearer|TOKEN_SHOULD_NOT_LEAK|SECRET/i.test(serialized)) {
  throw new Error('substrate routability report leaked verdict, deploy readiness, product flow, kubeconfig, or raw secret content');
}
NODE
}

expect_fail() {
  local label="$1"
  local target_profile="${2:-$KIT_ONLINE_PROFILE}"
  local pack_mutation="${3:-valid}"
  local truth_mutation="${4:-valid}"
  local prerequisites_mutation="${5:-valid}"
  local extra_mode="${6:-none}"
  local output_dir="$TMP_DIR/out-$label"

  mapfile -t inputs < <(write_bound_inputs "$label" "$KIT_ONLINE_PROFILE" valid valid)
  local truth="${inputs[0]}"
  local prerequisites="${inputs[1]}"
  local pack_report="${inputs[2]}"
  if [[ "$truth_mutation" != "valid" ]]; then
    write_truth "$truth" "$KIT_ONLINE_PROFILE" "$truth_mutation"
  fi
  if [[ "$prerequisites_mutation" != "valid" ]]; then
    write_prerequisites "$prerequisites" "$KIT_ONLINE_PROFILE" "$prerequisites_mutation"
  fi
  if [[ "$pack_mutation" != "valid" ]]; then
    local mutated_pack="$TMP_DIR/pack-report-$label.json"
    mutate_report "$pack_report" "$mutated_pack" "$pack_mutation"
    pack_report="$mutated_pack"
  fi

  write_stale_report "$output_dir"
  reset_logs

  local extra_args=()
  if [[ "$extra_mode" == "kubeconfig_payload_arg" ]]; then
    extra_args+=(--kubeconfig $'apiVersion: v1\nclusters:\n- name: release')
  elif [[ "$extra_mode" == "missing_pack_report" ]]; then
    pack_report="$TMP_DIR/missing-$label.json"
  fi

  if run_substrate_routability \
    "$target_profile" \
    "$truth" \
    "$prerequisites" \
    "$pack_report" \
    "$output_dir" \
    "${extra_args[@]}" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid substrate routability case to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid substrate routability rejected: $label"
}

mapfile -t valid_inputs < <(write_bound_inputs valid "$KIT_ONLINE_PROFILE" valid valid)
VALID_TRUTH="${valid_inputs[0]}"
VALID_PREREQUISITES="${valid_inputs[1]}"
VALID_PACK_REPORT="${valid_inputs[2]}"
VALID_OUT="$TMP_DIR/out-valid"
reset_logs
if ! run_substrate_routability \
  "$KIT_ONLINE_PROFILE" \
  "$VALID_TRUTH" \
  "$VALID_PREREQUISITES" \
  "$VALID_PACK_REPORT" \
  "$VALID_OUT" >"$TMP_DIR/valid.out" 2>"$TMP_DIR/valid.err"; then
  cat "$TMP_DIR/valid.out" >&2
  cat "$TMP_DIR/valid.err" >&2
  fail "expected valid substrate routability case to pass"
fi
assert_report "$VALID_OUT/$REPORT_FILE"
grep -q 'version --output=json' "$KUBECTL_LOG" || fail "fake kubectl did not receive version call"
for service in postgresql mongodb redis object_storage oidc; do
  grep -q -- "--service $service" "$PROBE_LOG" || fail "fake probe did not receive $service"
done
pass "valid existing_kubernetes/kit_installed/online substrate routability accepted"

expect_fail unsupported-external-declared "$EXTERNAL_ONLINE_PROFILE"
expect_fail unsupported-kind-rehearsal "$KIND_ONLINE_PROFILE"
expect_fail unsupported-airgap "$KIT_AIRGAP_PROFILE"
expect_fail missing-pack-report "$KIT_ONLINE_PROFILE" valid valid valid missing_pack_report
expect_fail pack-report-target-profile-mismatch "$KIT_ONLINE_PROFILE" target_profile_mismatch
expect_fail pack-report-truth-digest-mismatch "$KIT_ONLINE_PROFILE" truth_digest_mismatch

expect_truth_profile_mismatch() {
  local label="truth-profile-mismatch"
  local output_dir="$TMP_DIR/out-$label"

  mapfile -t inputs < <(write_bound_inputs "$label" "$KIT_ONLINE_PROFILE" valid valid)
  local truth="${inputs[0]}"
  local prerequisites="${inputs[1]}"
  local pack_report="${inputs[2]}"
  write_truth "$truth" "$KIT_AIRGAP_PROFILE" valid
  write_stale_report "$output_dir"
  reset_logs

  if run_substrate_routability \
    "$KIT_ONLINE_PROFILE" \
    "$truth" \
    "$prerequisites" \
    "$pack_report" \
    "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid substrate routability case to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid substrate routability rejected: $label"
}

expect_truth_profile_mismatch
expect_fail truth-raw-kubeconfig "$KIT_ONLINE_PROFILE" valid raw_kubeconfig
expect_fail prerequisites-raw-kubeconfig "$KIT_ONLINE_PROFILE" valid valid raw_kubeconfig
expect_fail pack-report-raw-kubeconfig "$KIT_ONLINE_PROFILE" raw_kubeconfig
expect_fail kubeconfig-payload-arg "$KIT_ONLINE_PROFILE" valid valid valid kubeconfig_payload_arg

write_fake_kubectl "$FAKE_KUBECTL" malicious_version
MALICIOUS_KUBECTL_OUT="$TMP_DIR/out-kubectl-version-secret"
reset_logs
if ! run_substrate_routability \
  "$KIT_ONLINE_PROFILE" \
  "$VALID_TRUTH" \
  "$VALID_PREREQUISITES" \
  "$VALID_PACK_REPORT" \
  "$MALICIOUS_KUBECTL_OUT" >"$TMP_DIR/kubectl-version-secret.out" 2>"$TMP_DIR/kubectl-version-secret.err"; then
  cat "$TMP_DIR/kubectl-version-secret.out" >&2
  cat "$TMP_DIR/kubectl-version-secret.err" >&2
  fail "expected malicious kubectl version payload to pass with digest-only report"
fi
assert_report "$MALICIOUS_KUBECTL_OUT/$REPORT_FILE"
assert_no_leak_marker \
  "malicious kubectl version" \
  "$TMP_DIR/kubectl-version-secret.out" \
  "$TMP_DIR/kubectl-version-secret.err" \
  "$MALICIOUS_KUBECTL_OUT/$REPORT_FILE"
write_fake_kubectl "$FAKE_KUBECTL" pass
pass "malicious kubectl version output reduced to digest-only summary"

expect_probe_nonzero_leak_rejected() {
  local label="probe-nonzero-leak"
  local output_dir="$TMP_DIR/out-$label"

  mapfile -t inputs < <(write_bound_inputs "$label" "$KIT_ONLINE_PROFILE" valid valid)
  local truth="${inputs[0]}"
  local prerequisites="${inputs[1]}"
  local pack_report="${inputs[2]}"

  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":"TOKEN_SHOULD_NOT_LEAK kubeconfig"}' >"$output_dir/$REPORT_FILE"
  reset_logs

  if run_substrate_routability \
    "$KIT_ONLINE_PROFILE" \
    "$truth" \
    "$prerequisites" \
    "$pack_report" \
    "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected probe nonzero leak case to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  assert_no_leak_marker \
    "$label" \
    "$TMP_DIR/$label.out" \
    "$TMP_DIR/$label.err" \
    "$output_dir/$REPORT_FILE"
  pass "probe nonzero stdout/stderr marker did not leak into output or stale report"
}

write_fake_probe "$FAKE_PROBE" mismatch
expect_fail probe-digest-mismatch
write_fake_probe "$FAKE_PROBE" nonzero
expect_probe_nonzero_leak_rejected
write_fake_probe "$FAKE_PROBE" pass

expect_evidence_reject() {
  local evidence_root="$TMP_DIR/evidence-substrate-routability"
  local output_dir="$TMP_DIR/out-evidence-substrate-routability"

  mkdir -p "$evidence_root"
  "$NODE_BIN" --input-type=module - "$evidence_root" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [evidenceRoot] = process.argv.slice(2);
const evidence = {
  schema_version: 'agentsmith.release-kit-evidence-envelope/v1',
  release_kit_version: '0.1.0',
  release_kit_output: 'substrate-routability-report.json',
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
    --output-dir "$output_dir" >"$TMP_DIR/evidence-substrate-routability.out" 2>"$TMP_DIR/evidence-substrate-routability.err"; then
    cat "$TMP_DIR/evidence-substrate-routability.out" >&2
    cat "$TMP_DIR/evidence-substrate-routability.err" >&2
    fail "expected substrate routability report to be rejected by evidence intake"
  fi
  if ! grep -Fq 'substrate-routability-report.json' "$TMP_DIR/evidence-substrate-routability.err"; then
    cat "$TMP_DIR/evidence-substrate-routability.out" >&2
    cat "$TMP_DIR/evidence-substrate-routability.err" >&2
    fail "evidence rejection must name substrate-routability-report.json"
  fi
  pass "substrate routability report rejected by evidence intake"
}

expect_evidence_reject

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "substrate routability diagnostic is not release readiness"
