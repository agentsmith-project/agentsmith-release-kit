#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"

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

sha256_file() {
  "$NODE_BIN" --input-type=module - "$1" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [file] = process.argv.slice(2);
const body = fs.readFileSync(file);
console.log(`sha256:${crypto.createHash('sha256').update(body).digest('hex')}`);
NODE
}

write_truth() {
  local output="$1"

  "$NODE_BIN" --input-type=module - "$output" "$TARGET_PROFILE" <<'NODE'
import fs from 'node:fs';

const [output, profile] = process.argv.slice(2);
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
      proof: `operator ${name} check 2026-05-23T12:00:00Z`
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

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_render_values() {
  local output="$1"

  cat >"$output" <<'JSON'
{
  "namespace": "agentsmith",
  "replicas": 2
}
JSON
}

create_archive() {
  local label="$1"
  local archive="$2"
  local mutation="${3:-valid}"
  local package_dir="$TMP_DIR/package-$label"

  mkdir -p "$package_dir/templates"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": [
    {
      "path": "templates/workloads.yaml",
      "kind": "kubernetes"
    }
  ]
}
JSON

  case "$mutation" in
    valid)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
spec:
  replicas: ${{ values.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: agentsmith-web
      app.kubernetes.io/part: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: agentsmith-web
        app.kubernetes.io/part: web
    spec:
      initContainers:
        - name: schema
          image: ${{ images.agentsmith_app.image }}
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
YAML
      ;;
    unknown_variable)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: MISSING
              value: ${{ values.not_declared }}
YAML
      ;;
    *)
      fail "unknown archive mutation: $mutation"
      ;;
  esac

  tar -czf "$archive" -C "$package_dir" manifest.json templates/workloads.yaml
  sha256_file "$package_dir/manifest.json"
}

write_materials() {
  local manifest_sha="$1"
  local archive_sha="$2"
  local contract_output="$3"
  local deploy_template_package_output="$4"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    "$manifest_sha" \
    "$archive_sha" \
    "$contract_output" \
    "$deploy_template_package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  contractInput,
  packageInput,
  manifestSha,
  archiveSha,
  contractOutput,
  packageOutput
] = process.argv.slice(2);

const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));

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

function subjectDigest(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(subject))).digest('hex')}`;
}

function artifactProjectionDigest(value) {
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } = value.artifact_provenance;
  const projection = { ...value, artifact_provenance: artifactProvenance };
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(projection))).digest('hex')}`;
}

deployTemplatePackage.package_sha256 = archiveSha;
deployTemplatePackage.manifest_sha256 = manifestSha;
deployTemplatePackage.artifact_provenance.artifact_sha256 = archiveSha;
deployTemplatePackage.artifact_provenance.subject_sha256 = subjectDigest(deployTemplatePackage);

contract.deploy_template_digest = manifestSha;
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

prepare_archive_case() {
  local label="$1"
  local mutation="$2"
  local archive_output="$3"
  local contract_output="$4"
  local package_output="$5"

  local manifest_sha
  manifest_sha="$(create_archive "$label" "$archive_output" "$mutation")"
  local archive_sha
  archive_sha="$(sha256_file "$archive_output")"
  write_materials "$manifest_sha" "$archive_sha" "$contract_output" "$package_output"
}

write_fake_kubectl() {
  local fake_kubectl="$1"

  "$NODE_BIN" --input-type=module - "$fake_kubectl" <<'NODE'
import fs from 'node:fs';

const [fakeKubectl] = process.argv.slice(2);
fs.writeFileSync(
  fakeKubectl,
  `#!/usr/bin/env bash
set -euo pipefail
: "\${FAKE_KUBECTL_LOG:?}"
printf '%s\\n' "$*" >> "$FAKE_KUBECTL_LOG"

command_name=""
for arg in "$@"; do
  if [[ "$arg" == "version" || "$arg" == "apply" || "$arg" == "rollout" || "$arg" == "get" ]]; then
    command_name="$arg"
    break
  fi
done

if [[ "$command_name" == "version" ]]; then
  printf '%s\\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
  exit 0
fi

if [[ "$command_name" == "apply" ]]; then
  printf '%s\\n' "deployment.apps/agentsmith-web"
  exit 0
fi

if [[ "$command_name" == "rollout" ]]; then
  printf '%s\\n' "deployment.apps/agentsmith-web rolled out"
  exit 0
fi

if [[ "$command_name" == "get" ]]; then
  get_target=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "get" ]]; then
      get_target="$arg"
    fi
    previous="$arg"
  done

  if [[ "$get_target" == "Deployment/agentsmith-web" ]]; then
    cat <<'JSON'
{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"agentsmith-web","app.kubernetes.io/part":"web"}}}}
JSON
    exit 0
  fi

  if [[ "$get_target" == "pods" ]]; then
    cat <<'JSON'
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":"docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"}],"containerStatuses":[{"name":"web","image":"ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111","imageID":"docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}}]}
JSON
    exit 0
  fi
fi

echo "unexpected fake kubectl args: $*" >&2
exit 2
`
);
fs.chmodSync(fakeKubectl, 0o755);
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
  response.statusCode = url.pathname === '/ok' ? 200 : 404;
  response.end(url.pathname === '/ok' ? 'route ok token=plain-secret-value' : 'not found');
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
      fail "online gate smoke server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "online gate smoke server did not become ready"
}

hit_count() {
  if [[ -f "$SERVER_LOG" ]]; then
    wc -l <"$SERVER_LOG" | tr -d '[:space:]'
    return
  fi
  echo 0
}

KUBECTL_LOG="$TMP_DIR/kubectl.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"
write_fake_kubectl "$FAKE_KUBECTL"

reset_kubectl_log() {
  : >"$KUBECTL_LOG"
}

assert_kubectl_not_called() {
  if [[ -s "$KUBECTL_LOG" ]]; then
    cat "$KUBECTL_LOG" >&2
    fail "kubectl should not have been called"
  fi
}

assert_no_gate_report() {
  local output_dir="$1"
  if [[ -e "$output_dir/online-deployment-gate-report.json" ]]; then
    fail "failed gate must not leave online-deployment-gate-report.json"
  fi
}

run_gate() {
  local release_contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local render_values="$4"
  local substrate_truth="$5"
  local output_dir="$6"
  local target_profile="${7:-$TARGET_PROFILE}"
  shift 7 || true

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" bash "$ROOT_DIR/scripts/verify-release.sh" --online-deployment-gate \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --target-profile "$target_profile" \
    --render-values "$render_values" \
    --substrate-truth "$substrate_truth" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    "$@"
}

assert_gate_report() {
  local report_file="$1"
  local expected_mode="$2"
  local expected_steps="$3"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_mode" "$expected_steps" "$TARGET_PROFILE" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [reportFile, expectedMode, expectedStepsText, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedSteps = expectedStepsText.split(',');
const outputRoot = path.dirname(reportFile);

if (report.schema !== 'agentsmith.online-deployment-gate/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'online_deployment_gate_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('online deployment gate report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.mode !== expectedMode) {
  throw new Error(`unexpected mode: ${report.mode}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (!report.release_id || !report.git_sha) {
  throw new Error('aggregate report must include release identity');
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('aggregate report must include release contract digest');
}
if (!Array.isArray(report.steps) || report.steps.length !== expectedSteps.length) {
  throw new Error(`unexpected step count: ${report.steps?.length}`);
}
for (const [index, step] of report.steps.entries()) {
  if (step.name !== expectedSteps[index]) {
    throw new Error(`unexpected step at ${index}: ${step.name}`);
  }
  if (step.status !== 'pass') {
    throw new Error(`unexpected step status for ${step.name}: ${step.status}`);
  }
  if (!Array.isArray(step.report_paths) || step.report_paths.length < 1) {
    throw new Error(`step ${step.name} must list report paths`);
  }
  if (step.report_paths.some((reportPath) => reportPath.startsWith('/') || reportPath.includes('..'))) {
    throw new Error(`step ${step.name} has unsafe report path`);
  }
  for (const reportPath of step.report_paths) {
    const absolutePath = path.join(outputRoot, reportPath);
    if (!fs.statSync(absolutePath).isFile()) {
      throw new Error(`step ${step.name} report path is not a file: ${reportPath}`);
    }
  }
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('aggregate report must not claim verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('aggregate report must not include AgentSmith product flow fields');
}
if (/password|token=|plain-secret-value|client_secret|authorization|bearer|kubeconfig/i.test(serialized)) {
  throw new Error('aggregate report leaked secret-ish payloads or kubeconfig fields');
}
NODE
}

KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
VALID_TRUTH="$TMP_DIR/substrate-truth.valid.json"
VALID_VALUES="$TMP_DIR/render-values.valid.json"
VALID_ARCHIVE="$TMP_DIR/valid.tgz"
VALID_CONTRACT_MATERIAL="$TMP_DIR/release-contract.valid-material.json"
VALID_PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.valid-material.json"
INVALID_ARCHIVE="$TMP_DIR/invalid-render.tgz"
INVALID_CONTRACT_MATERIAL="$TMP_DIR/release-contract.invalid-render.json"
INVALID_PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.invalid-render.json"

write_truth "$VALID_TRUTH"
write_render_values "$VALID_VALUES"
prepare_archive_case valid valid "$VALID_ARCHIVE" "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL"
prepare_archive_case invalid-render unknown_variable "$INVALID_ARCHIVE" "$INVALID_CONTRACT_MATERIAL" "$INVALID_PACKAGE_MATERIAL"
start_server
BASE_URL="http://127.0.0.1:$SERVER_PORT"

dry_output="$TMP_DIR/out-dry"
mkdir -p "$dry_output/rollout" "$dry_output/smoke"
printf '%s\n' '{"stale":true}' >"$dry_output/rollout/rollout-report.json"
printf '%s\n' '{"stale":true}' >"$dry_output/smoke/smoke-report.json"
reset_kubectl_log
run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$dry_output" "$TARGET_PROFILE" >/dev/null
[[ -f "$dry_output/render/manifest-render-report.json" ]] || fail "dry-run gate did not write render report"
[[ -f "$dry_output/render-check/render-report.json" ]] || fail "dry-run gate did not write render-check report"
[[ -f "$dry_output/apply/apply-report.json" ]] || fail "dry-run gate did not write apply report"
[[ ! -e "$dry_output/rollout/rollout-report.json" ]] || fail "dry-run gate left stale rollout report"
[[ ! -e "$dry_output/smoke/smoke-report.json" ]] || fail "dry-run gate left stale smoke report"
grep -q 'version' "$KUBECTL_LOG" || fail "dry-run gate did not call kubectl version"
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "dry-run gate did not call server dry-run apply"
if grep -Eq 'rollout|get pods' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "server dry-run gate must not call rollout or pod checks"
fi
assert_gate_report "$dry_output/online-deployment-gate-report.json" server-dry-run "inputs,target-preflight,template-package,render,render-check,apply"
pass "online deployment gate server dry-run writes non-readiness aggregate without rollout or smoke"

smoke_dry_output="$TMP_DIR/out-dry-smoke"
mkdir -p "$smoke_dry_output"
printf '%s\n' '{"stale":true}' >"$smoke_dry_output/online-deployment-gate-report.json"
reset_kubectl_log
before_smoke_dry="$(hit_count)"
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$smoke_dry_output" "$TARGET_PROFILE" \
  --smoke-url "$BASE_URL/ok" --allow-http --allow-localhost >"$TMP_DIR/dry-smoke.out" 2>"$TMP_DIR/dry-smoke.err"; then
  fail "expected server dry-run with smoke URL to fail"
fi
after_smoke_dry="$(hit_count)"
assert_kubectl_not_called
[[ "$before_smoke_dry" == "$after_smoke_dry" ]] || fail "server dry-run smoke rejection reached network"
assert_no_gate_report "$smoke_dry_output"
pass "server dry-run rejects smoke URL before kubectl or network"

dry_apply_only_output="$TMP_DIR/out-dry-apply-only"
mkdir -p "$dry_apply_only_output"
printf '%s\n' '{"stale":true}' >"$dry_apply_only_output/online-deployment-gate-report.json"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$dry_apply_only_output" "$TARGET_PROFILE" \
  --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1000 --timeout 120s >"$TMP_DIR/dry-apply-only.out" 2>"$TMP_DIR/dry-apply-only.err"; then
  fail "expected server dry-run with apply-only options to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$dry_apply_only_output"
pass "server dry-run rejects apply-only options before kubectl"

reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$TMP_DIR/out-apply-missing-confirm" "$TARGET_PROFILE" \
  --mode apply --operator-run-id operator-run-1001 >"$TMP_DIR/apply-missing-confirm.out" 2>"$TMP_DIR/apply-missing-confirm.err"; then
  fail "expected apply mode without confirm to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$TMP_DIR/out-apply-missing-confirm"
pass "apply mode without confirm rejected before kubectl"

reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$TMP_DIR/out-apply-missing-run-id" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" >"$TMP_DIR/apply-missing-run-id.out" 2>"$TMP_DIR/apply-missing-run-id.err"; then
  fail "expected apply mode without operator run id to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$TMP_DIR/out-apply-missing-run-id"
pass "apply mode without operator run id rejected before kubectl"

apply_output="$TMP_DIR/out-apply-smoke"
reset_kubectl_log
before_apply_smoke="$(hit_count)"
run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$apply_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1002 \
  --timeout 120s \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost >/dev/null
after_apply_smoke="$(hit_count)"
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "apply gate must not dry-run confirmed apply"
fi
grep -q 'rollout status Deployment/agentsmith-web' "$KUBECTL_LOG" || fail "apply gate did not call rollout"
grep -q 'get pods' "$KUBECTL_LOG" || fail "apply gate did not check live pods"
[[ "$after_apply_smoke" -eq $((before_apply_smoke + 1)) ]] || fail "apply gate smoke should issue one request"
[[ -f "$apply_output/rollout/rollout-report.json" ]] || fail "apply gate did not write rollout report"
[[ -f "$apply_output/smoke/smoke-report.json" ]] || fail "apply gate did not write smoke report"
assert_gate_report "$apply_output/online-deployment-gate-report.json" apply "inputs,target-preflight,template-package,render,render-check,apply,rollout,smoke"
pass "apply mode runs rollout and optional smoke with non-readiness aggregate"

reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$TMP_DIR/out-unsupported-kit-online" "$KIT_ONLINE_PROFILE" >"$TMP_DIR/unsupported-kit-online.out" 2>"$TMP_DIR/unsupported-kit-online.err"; then
  fail "expected kit-installed online target profile to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$TMP_DIR/out-unsupported-kit-online"
pass "kit-installed online profile stays intake-only and is rejected before kubectl"

reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$TMP_DIR/out-unsupported" "kind_rehearsal/kit_installed/online" >"$TMP_DIR/unsupported.out" 2>"$TMP_DIR/unsupported.err"; then
  fail "expected unsupported target profile to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$TMP_DIR/out-unsupported"
pass "unsupported target profile rejected before kubectl"

bad_render_output="$TMP_DIR/out-bad-render"
mkdir -p "$bad_render_output"
printf '%s\n' '{"stale":true}' >"$bad_render_output/online-deployment-gate-report.json"
reset_kubectl_log
if run_gate "$INVALID_CONTRACT_MATERIAL" "$INVALID_PACKAGE_MATERIAL" "$INVALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$bad_render_output" "$TARGET_PROFILE" >"$TMP_DIR/bad-render.out" 2>"$TMP_DIR/bad-render.err"; then
  cat "$TMP_DIR/bad-render.out" >&2
  cat "$TMP_DIR/bad-render.err" >&2
  fail "expected render failure to stop online deployment gate"
fi
assert_kubectl_not_called
assert_no_gate_report "$bad_render_output"
pass "render failure stops before apply and removes stale aggregate"

pass "online deployment gate focused tests completed"
