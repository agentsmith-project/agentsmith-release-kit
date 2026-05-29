#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
EXAMPLE_DIR="$ROOT_DIR/examples/online-existing-kubernetes"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"

TMP_DIR="$(mktemp -d)"
SERVER_PID=""
SERVER_PORT=""
SERVER_LOG=""
trap 'if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing example file: $file"
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

create_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package"

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
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } =
    value.artifact_provenance;
  const projection = { ...value, artifact_provenance: artifactProvenance };
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(projection))).digest('hex')}`;
}

deployTemplatePackage.package_sha256 = archiveSha;
deployTemplatePackage.manifest_sha256 = manifestSha;
deployTemplatePackage.artifact_provenance.artifact_sha256 = archiveSha;
deployTemplatePackage.artifact_provenance.subject_sha256 =
  subjectDigest(deployTemplatePackage);

contract.deploy_template_digest = manifestSha;
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

write_fake_kubectl() {
  local fake_kubectl="$1"

  cat >"$fake_kubectl" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_KUBECTL_LOG:?}"
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"

command_name=""
for arg in "$@"; do
  if [[ "$arg" == "version" || "$arg" == "apply" || "$arg" == "rollout" || "$arg" == "get" ]]; then
    command_name="$arg"
    break
  fi
done

if [[ "$command_name" == "version" ]]; then
  printf '%s\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
  exit 0
fi

if [[ "$command_name" == "apply" ]]; then
  printf '%s\n' "deployment.apps/agentsmith-web"
  exit 0
fi

if [[ "$command_name" == "rollout" ]]; then
  printf '%s\n' "deployment.apps/agentsmith-web rolled out"
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
    live_image="ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    live_image_id="docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    cat <<JSON
{"items":[{"metadata":{"name":"agentsmith-web-example"},"status":{"initContainerStatuses":[{"name":"schema","image":"$live_image","imageID":"$live_image_id"}],"containerStatuses":[{"name":"web","image":"$live_image","imageID":"$live_image_id"}]}}]}
JSON
    exit 0
  fi
fi

echo "unexpected fake kubectl args: $*" >&2
exit 2
BASH
  chmod +x "$fake_kubectl"
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
      fail "operator example smoke server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "operator example smoke server did not become ready"
}

hit_count() {
  if [[ -f "$SERVER_LOG" ]]; then
    wc -l <"$SERVER_LOG" | tr -d '[:space:]'
    return
  fi
  echo 0
}

assert_gate_report() {
  local report_file="$1"
  local expected_mode="$2"
  local expected_steps="$3"
  local expected_operator_run_id="${4:-}"

  "$NODE_BIN" --input-type=module - \
    "$report_file" \
    "$expected_mode" \
    "$expected_steps" \
    "$TARGET_PROFILE" \
    "$expected_operator_run_id" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [reportFile, expectedMode, expectedStepsText, expectedProfile, expectedOperatorRunId] =
  process.argv.slice(2);
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
  throw new Error('operator example gate report must keep readiness=false');
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
if (expectedMode === 'apply') {
  if (report.operator_run_id !== expectedOperatorRunId) {
    throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
  }
} else if ('operator_run_id' in report) {
  throw new Error('server dry-run report must not include operator_run_id');
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
  for (const reportPath of step.report_paths) {
    if (reportPath.startsWith('/') || reportPath.includes('..')) {
      throw new Error(`step ${step.name} has unsafe report path`);
    }
    if (!fs.statSync(path.join(outputRoot, reportPath)).isFile()) {
      throw new Error(`step ${step.name} report path is not a file: ${reportPath}`);
    }
  }
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report || 'readiness_verdict' in report) {
  throw new Error('operator example gate report must not claim deploy or release readiness');
}
if (/required_product_flows|product_flows|product_flow_results|cloud.?provision|registry.?login|registry.?push|registry.?mirror|rollback|release_readiness|deploy_readiness|release_verdict|\bverdict\b/i.test(serialized)) {
  throw new Error('operator example gate report contains out-of-scope release/deploy/product-flow fields');
}
if (/password|token=|plain-secret-value|client_secret|authorization|bearer|kubeconfig/i.test(serialized)) {
  throw new Error('operator example gate report leaked secret-ish payloads or kubeconfig fields');
}
NODE
}

assert_evidence_root() {
  local evidence_root="$1"

  "$NODE_BIN" --input-type=module - "$evidence_root" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [evidenceRoot] = process.argv.slice(2);
for (const file of ['evidence.json', 'evidence-subject.json', 'online-deployment-gate-report.json']) {
  const candidate = path.join(evidenceRoot, file);
  if (!fs.statSync(candidate).isFile()) {
    throw new Error(`missing evidence root file: ${file}`);
  }
}
const evidence = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'evidence.json'), 'utf8'));
const gateReport = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'online-deployment-gate-report.json'), 'utf8'));
const serialized = `${JSON.stringify(evidence)}\n${JSON.stringify(gateReport)}`;

if (evidence.release_kit_output !== 'online-deployment-gate-report.json') {
  throw new Error(`unexpected release_kit_output: ${evidence.release_kit_output}`);
}
if (evidence.status !== 'passed' || evidence.failure_class !== 'none') {
  throw new Error('operator example evidence must be a passed focused diagnostic');
}
if (evidence.artifact_provenance?.provenance_kind !== 'ci_artifact') {
  throw new Error('operator example provenance must stay ci_artifact and must not imply operator signature');
}
if (gateReport.readiness !== false || evidence.readiness === true) {
  throw new Error('operator example evidence must not claim readiness');
}
if (/operator_identity|signature_uri|signature_sha256|release_readiness|deploy_readiness|release_verdict|\bverdict\b|required_product_flows|product_flows|product_flow_results/i.test(serialized)) {
  throw new Error('operator example evidence contains out-of-scope signoff or readiness fields');
}
NODE
}

run_gate() {
  local release_contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local output_dir="$4"
  shift 4 || true

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  bash "$ROOT_DIR/scripts/verify-release.sh" --online-deployment-gate \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --target-profile "$TARGET_PROFILE" \
    --render-values "$EXAMPLE_DIR/render-values.example.json" \
    --substrate-truth "$EXAMPLE_DIR/substrate-truth.example.json" \
    --target-prerequisites "$EXAMPLE_DIR/target-prerequisites.example.json" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    "$@"
}

require_file "$EXAMPLE_DIR/render-values.example.json"
require_file "$EXAMPLE_DIR/substrate-truth.example.json"
require_file "$EXAMPLE_DIR/target-prerequisites.example.json"
require_file "$EXAMPLE_DIR/evidence-provenance.example.json"

ARCHIVE="$TMP_DIR/operator-example.tgz"
CONTRACT_MATERIAL="$TMP_DIR/release-contract.material.json"
PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.material.json"
manifest_sha="$(create_archive "$ARCHIVE")"
archive_sha="$(sha256_file "$ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha" "$CONTRACT_MATERIAL" "$PACKAGE_MATERIAL"

KUBECTL_LOG="$TMP_DIR/kubectl.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"
write_fake_kubectl "$FAKE_KUBECTL"
start_server
BASE_URL="http://127.0.0.1:$SERVER_PORT"

dry_output="$TMP_DIR/out-server-dry-run"
: >"$KUBECTL_LOG"
run_gate "$CONTRACT_MATERIAL" "$PACKAGE_MATERIAL" "$ARCHIVE" "$dry_output" >/dev/null
grep -q 'version' "$KUBECTL_LOG" || fail "server dry-run did not call kubectl version"
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "server dry-run did not call kubectl apply --dry-run=server"
if grep -Eq 'rollout|get pods' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "server dry-run must not run rollout or pod checks"
fi
assert_gate_report "$dry_output/online-deployment-gate-report.json" \
  server-dry-run \
  "inputs,target-preflight,template-package,render,render-check,apply"
pass "online existing Kubernetes operator example drives server-dry-run focused gate"

apply_output="$TMP_DIR/out-apply"
evidence_root="$TMP_DIR/evidence-root"
: >"$KUBECTL_LOG"
before_smoke="$(hit_count)"
run_gate "$CONTRACT_MATERIAL" "$PACKAGE_MATERIAL" "$ARCHIVE" "$apply_output" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-example-1001 \
  --timeout 120s \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost \
  --evidence-root "$evidence_root" \
  --evidence-provenance "$EXAMPLE_DIR/evidence-provenance.example.json" >/dev/null
after_smoke="$(hit_count)"
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed apply must not use server dry-run"
fi
grep -q 'rollout status Deployment/agentsmith-web' "$KUBECTL_LOG" || fail "confirmed apply did not call rollout"
grep -q 'get pods' "$KUBECTL_LOG" || fail "confirmed apply did not check live pods"
[[ "$after_smoke" -eq $((before_smoke + 1)) ]] || fail "confirmed apply smoke should issue one route request"
assert_gate_report "$apply_output/online-deployment-gate-report.json" \
  apply \
  "inputs,target-preflight,template-package,render,render-check,apply,rollout,smoke" \
  operator-example-1001
assert_evidence_root "$evidence_root"
[[ -f "$apply_output/evidence-validation/evidence-validation-report.json" ]] || fail "confirmed apply did not validate evidence root"
pass "online existing Kubernetes operator example drives confirmed apply, rollout, smoke, and focused evidence"

pass "online operator example focused tests completed"
