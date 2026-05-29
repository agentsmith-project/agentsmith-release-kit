#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
ONLINE_PROFILE="existing_kubernetes/external_declared/online"
KIND_PROFILE="kind_rehearsal/kit_installed/online"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
ALIAS_OFFLINE_PROFILE="existing_kubernetes/external_declared/offline"
AIRGAP_REGISTRY="registry.example.internal/releases"
REPORT_FILE="airgap-deployment-gate-report.json"
mapfile -t RELEASE_IMAGE_IDS < <(
  "$NODE_BIN" --input-type=module - "$FIXTURE_CONTRACT" <<'NODE'
import fs from 'node:fs';

const [fixtureContract] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(fixtureContract, 'utf8'));
for (const item of contract.deploy_image_inventory) {
  console.log(item.id);
}
NODE
)

TMP_DIR="$(mktemp -d)"
SERVER_PID=""
trap 'if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP_DIR"' EXIT

PAYLOAD_DIR="$TMP_DIR/payload"
IMAGE_DIR="$TMP_DIR/image-archives"
OPERATOR_PREREQUISITES="$TMP_DIR/operator-prerequisites.json"
GOOD_PROBE="$TMP_DIR/tools/archive-digest-probe"
GOOD_LOADER="$TMP_DIR/tools/image-loader"
LOAD_LOG="$TMP_DIR/image-load.log"
KUBECTL_LOG="$TMP_DIR/kubectl.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"

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

  "$NODE_BIN" --input-type=module - "$output" "$AIRGAP_PROFILE" <<'NODE'
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

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_prerequisites() {
  local output="$1"

  "$NODE_BIN" --input-type=module - "$output" "$AIRGAP_PROFILE" <<'NODE'
import fs from 'node:fs';

const [output, profile] = process.argv.slice(2);
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

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

write_render_values() {
  local output="$1"

  "$NODE_BIN" --input-type=module - "$output" <<'NODE'
import fs from 'node:fs';

const [output] = process.argv.slice(2);
const values = {
  namespace: 'agentsmith',
  replicas: 2
};

fs.writeFileSync(output, `${JSON.stringify(values, null, 2)}\n`);
NODE
}

create_render_archive() {
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
  template:
    spec:
      initContainers:
        - name: schema
          image: ${{ images.agentsmith_app.image }}
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
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
    "$FIXTURE_CONTRACT" \
    "$FIXTURE_DEPLOY_TEMPLATE_PACKAGE" \
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

create_payloads() {
  mkdir -p "$PAYLOAD_DIR"
  cat >"$PAYLOAD_DIR/runbook.md" <<'EOF_RUNBOOK'
# AgentSmith airgap runbook

Use the approved operator-held substrate and registry records.
EOF_RUNBOOK
  cat >"$PAYLOAD_DIR/install.sh" <<'EOF_SCRIPT'
#!/usr/bin/env sh
set -eu
printf '%s\n' "operator-reviewed local install placeholder"
EOF_SCRIPT
  chmod +x "$PAYLOAD_DIR/install.sh"
  cat >"$PAYLOAD_DIR/profile-values.schema.json" <<'JSON'
{
  "type": "object",
  "additionalProperties": false
}
JSON
  printf '%s\n' 'namespace: agentsmith' >"$PAYLOAD_DIR/profile-values.example.yaml"
}

create_image_archives() {
  mkdir -p "$IMAGE_DIR"
  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$IMAGE_DIR" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, imageDir] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
for (const image of contract.deploy_image_inventory) {
  fs.writeFileSync(
    path.join(imageDir, `${image.id}.oci-layout.tar`),
    [
      'local oci layout tar fixture',
      `id=${image.id}`,
      `target_digest=${image.digest}`,
      ''
    ].join('\n')
  );
}
NODE
}

write_operator_prerequisites() {
  local output="$1"
  local tool_file="$TMP_DIR/kubectl-local"

  printf '%s\n' 'bundled kubectl placeholder' >"$tool_file"
  "$NODE_BIN" --input-type=module - "$output" "$tool_file" <<'NODE'
import fs from 'node:fs';

const [output, toolFile] = process.argv.slice(2);
const prerequisites = {
  substrate_connection_truth_ref: 'operator held substrate truth record AS-123',
  target_registry_proof_ref: 'operator held target registry proof AS-123',
  tools: [
    {
      name: 'kubectl',
      version: '1.30.0',
      source: 'bundled',
      path: toolFile
    },
    {
      name: 'skopeo',
      version: '1.16.0',
      source: 'operator_prerequisite',
      location: 'operator workstation inventory skopeo',
      proof: 'signed operator prerequisite proof skopeo'
    }
  ]
};

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

write_tools() {
  mkdir -p "$(dirname "$GOOD_PROBE")"
  cat >"$GOOD_PROBE" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const archivePath = process.argv[2] || process.env.AGENTSMITH_IMAGE_ARCHIVE_PATH;
if (!archivePath) {
  process.exit(2);
}
const body = fs.readFileSync(archivePath, 'utf8');
const matches = [...body.matchAll(/^target_digest=(sha256:[0-9a-f]{64})$/gm)];
if (matches.length !== 1) {
  process.exit(3);
}
console.log(matches[0][1]);
NODE
  chmod +x "$GOOD_PROBE"

  cat >"$GOOD_LOADER" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const [archivePath, targetImage, targetDigest] = process.argv.slice(2);
if (!archivePath || !targetImage || !targetDigest) {
  process.exit(2);
}
const body = fs.readFileSync(archivePath, 'utf8');
const matches = [...body.matchAll(/^target_digest=(sha256:[0-9a-f]{64})$/gm)];
if (matches.length !== 1 || matches[0][1] !== targetDigest) {
  process.exit(3);
}
if (!targetImage.endsWith(`@${targetDigest}`)) {
  process.exit(4);
}
if (process.env.AGENTSMITH_LOAD_LOG) {
  fs.appendFileSync(process.env.AGENTSMITH_LOAD_LOG, `${targetDigest}\n`);
}
console.log(targetDigest);
NODE
  chmod +x "$GOOD_LOADER"

  cat >"$FAKE_KUBECTL" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_KUBECTL_LOG:?}"
printf '%s\n' "$*" >> "$FAKE_KUBECTL_LOG"

command_name=""
for arg in "$@"; do
  if [[ "$arg" == "version" || "$arg" == "apply" || "$arg" == "rollout" || "$arg" == "get" ]]; then
    command_name="$arg"
    break
  fi
done

case "$command_name" in
  version)
    printf '%s\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
    ;;
  apply)
    printf '%s\n' "deployment.apps/agentsmith-web"
    ;;
  rollout)
    printf '%s\n' "deployment rolled out token=plain-secret-value"
    ;;
  get)
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
{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/part":"web","app.kubernetes.io/name":"agentsmith-web"}}}}
JSON
      exit 0
    fi

    if [[ "$get_target" == "pods" ]]; then
      : "${FAKE_KUBECTL_TARGET_IMAGE:?}"
      cat <<JSON
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"$FAKE_KUBECTL_TARGET_IMAGE","imageID":"docker-pullable://$FAKE_KUBECTL_TARGET_IMAGE"}],"containerStatuses":[{"name":"web","image":"$FAKE_KUBECTL_TARGET_IMAGE","imageID":"docker-pullable://$FAKE_KUBECTL_TARGET_IMAGE"}]}}]}
JSON
      exit 0
    fi

    echo "unexpected fake kubectl get target: $get_target" >&2
    exit 2
    ;;
  *)
    echo "unexpected fake kubectl args: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$FAKE_KUBECTL"
}

run_bundle_create() {
  local release_contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local bundle_root="$4"
  local output_dir="$5"
  local image_archive_args=()

  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    image_archive_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
  done

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --target-profile "$AIRGAP_PROFILE" \
    --target-registry "$AIRGAP_REGISTRY" \
    --bundle-root "$bundle_root" \
    --output-dir "$output_dir" \
    "${image_archive_args[@]}" \
    --runbook "$PAYLOAD_DIR/runbook.md" \
    --script "$PAYLOAD_DIR/install.sh" \
    --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json" \
    --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml" \
    --operator-prerequisites "$OPERATOR_PREREQUISITES"
}

write_bundle_operator_inputs() {
  local bundle_root="$1"

  mkdir -p "$bundle_root/operator-inputs"
  write_render_values "$bundle_root/operator-inputs/render-values.json"
  write_truth "$bundle_root/operator-inputs/substrate-truth.json"
  write_prerequisites "$bundle_root/operator-inputs/target-prerequisites.json"
}

target_image_for_id() {
  local image_map="$1"
  local image_id="$2"

  "$NODE_BIN" --input-type=module - "$image_map" "$image_id" <<'NODE'
import fs from 'node:fs';

const [imageMapInput, imageId] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(imageMapInput, 'utf8'));
const mapping = imageMap.mappings.find((item) => item.id === imageId);
if (!mapping) {
  throw new Error(`missing image-map mapping: ${imageId}`);
}
console.log(mapping.target_image);
NODE
}

run_airgap_gate() {
  local bundle_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$AIRGAP_PROFILE}"
  if (($# >= 3)); then
    shift 3
  else
    shift 2
  fi

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-deployment-gate \
    --release-contract "$bundle_root/components/release-contract.json" \
    --deploy-template-package "$bundle_root/components/deploy-template-package.json" \
    --archive "$bundle_root/components/agentsmith-deploy-template-package.tgz" \
    --image-map "$bundle_root/components/image-map.json" \
    --target-profile "$target_profile" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_root/airgap-bundle-manifest.json" \
    --render-values "$bundle_root/operator-inputs/render-values.json" \
    --substrate-truth "$bundle_root/operator-inputs/substrate-truth.json" \
    --target-prerequisites "$bundle_root/operator-inputs/target-prerequisites.json" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    "$@"
}

reset_logs() {
  : >"$KUBECTL_LOG"
  : >"$LOAD_LOG"
  : >"$SERVER_LOG"
}

assert_no_report() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "unexpected airgap deployment gate report exists: $output_dir/$REPORT_FILE"
}

load_count() {
  grep -c '^sha256:' "$LOAD_LOG" 2>/dev/null || true
}

hit_count() {
  if [[ -f "$SERVER_LOG" ]]; then
    wc -l <"$SERVER_LOG" | tr -d '[:space:]'
    return
  fi
  echo 0
}

assert_no_apply_side_effects() {
  local label="$1"
  local expected_hits="${2:-}"

  [[ ! -s "$KUBECTL_LOG" ]] || fail "$label must fail before kubectl"
  [[ "$(load_count)" -eq 0 ]] || fail "$label must fail before image loader"
  if [[ -n "$expected_hits" ]]; then
    [[ "$(hit_count)" -eq "$expected_hits" ]] || fail "$label must fail before smoke"
  fi
}

assert_report() {
  local report_file="$1"
  local expected_mode="$2"
  local expected_steps_csv="$3"
  local expected_operator_run_id="${4:-}"

  "$NODE_BIN" --input-type=module - \
    "$report_file" \
    "$expected_mode" \
    "$expected_steps_csv" \
    "$expected_operator_run_id" \
    "$AIRGAP_PROFILE" <<'NODE'
import fs from 'node:fs';

const [
  reportFile,
  expectedMode,
  expectedStepsCsv,
  expectedOperatorRunId,
  expectedProfile
] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedSteps = expectedStepsCsv.split(',').filter(Boolean);
const stepNames = Array.isArray(report.steps)
  ? report.steps.map((step) => step.name)
  : [];

if (report.schema !== 'agentsmith.airgap-deployment-gate/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'airgap_deployment_gate_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('airgap deployment gate report must keep readiness=false');
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
if (stepNames.join(',') !== expectedSteps.join(',')) {
  throw new Error(`unexpected steps: ${stepNames.join(',')}`);
}
for (const step of report.steps) {
  if (step.status !== 'pass') {
    throw new Error(`unexpected step status for ${step.name}: ${step.status}`);
  }
  if (!Array.isArray(step.report_paths) || step.report_paths.length === 0) {
    throw new Error(`step missing report paths: ${step.name}`);
  }
  for (const reportPath of step.report_paths) {
    if (reportPath.startsWith('/') || reportPath.includes('..')) {
      throw new Error(`step report path must be output-relative: ${reportPath}`);
    }
  }
}
if (expectedMode === 'apply') {
  if (report.operator_run_id !== expectedOperatorRunId) {
    throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
  }
} else if ('operator_run_id' in report) {
  throw new Error('server dry-run report must not include operator_run_id');
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('airgap deployment gate report must not claim a verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results|registry_presence|registry_mirror|image_push|image_pull|login|signature|identity/.test(serialized)) {
  throw new Error('airgap deployment gate report included out-of-scope governance or registry fields');
}
if (/\/tmp\/|operator held|operator workstation|signed operator prerequisite|plain-secret-value|token=/.test(serialized)) {
  throw new Error('airgap deployment gate report leaked paths, operator refs, or command output');
}
NODE
}

expect_gate_fail() {
  local label="$1"
  local output_dir="$2"
  shift 2

  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap deployment gate failure: $label"
  fi

  assert_no_report "$output_dir"
  pass "airgap deployment gate rejected invalid case: $label"
}

start_server() {
  local ready_file="$TMP_DIR/server-ready"
  SERVER_LOG="$TMP_DIR/server-hits.log"
  local stdout_file="$TMP_DIR/server.out"
  local stderr_file="$TMP_DIR/server.err"

  "$NODE_BIN" --input-type=module - "$ready_file" "$SERVER_LOG" >"$stdout_file" 2>"$stderr_file" <<'NODE' &
import fs from 'node:fs';
import http from 'node:http';

const [readyFile, logFile] = process.argv.slice(2);

const server = http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || '127.0.0.1'}`);
  fs.appendFileSync(logFile, `${request.method} ${url.pathname}\n`);
  if (url.pathname === '/ok') {
    response.statusCode = 200;
    response.end('route ok token=plain-secret-value');
    return;
  }
  response.statusCode = 404;
  response.end('not found token=plain-secret-value');
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
      return
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$stdout_file" >&2 || true
      cat "$stderr_file" >&2 || true
      fail "airgap deployment gate smoke server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "airgap deployment gate smoke server did not become ready"
}

VALID_ARCHIVE="$TMP_DIR/valid.tgz"
VALID_MANIFEST_SHA="$(create_render_archive "$VALID_ARCHIVE")"
VALID_ARCHIVE_SHA="$(sha256_file "$VALID_ARCHIVE")"
VALID_CONTRACT="$TMP_DIR/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.valid.json"
write_materials "$VALID_MANIFEST_SHA" "$VALID_ARCHIVE_SHA" "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE"

create_payloads
create_image_archives
write_operator_prerequisites "$OPERATOR_PREREQUISITES"
write_tools

VALID_BUNDLE_ROOT="$TMP_DIR/bundle-valid"
VALID_CREATE_OUTPUT="$TMP_DIR/out-create-valid"
run_bundle_create \
  "$VALID_CONTRACT" \
  "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$VALID_BUNDLE_ROOT" \
  "$VALID_CREATE_OUTPUT" >"$TMP_DIR/create-valid.out"
write_bundle_operator_inputs "$VALID_BUNDLE_ROOT"

TARGET_APP_IMAGE="$(target_image_for_id "$VALID_BUNDLE_ROOT/components/image-map.json" agentsmith_app)"
export AGENTSMITH_LOAD_LOG="$LOAD_LOG"
export FAKE_KUBECTL_LOG="$KUBECTL_LOG"
export FAKE_KUBECTL_TARGET_IMAGE="$TARGET_APP_IMAGE"
SERVER_LOG="$TMP_DIR/server-hits.log"
start_server
BASE_URL="http://127.0.0.1:$SERVER_PORT"

dry_run_output="$TMP_DIR/out-dry-run"
reset_logs
run_airgap_gate "$VALID_BUNDLE_ROOT" "$dry_run_output" "$AIRGAP_PROFILE" \
  --mode server-dry-run >"$TMP_DIR/dry-run.out"
grep -q 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "server dry-run must call kubectl apply --dry-run=server"
if grep -q 'rollout status' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "server dry-run must not call rollout"
fi
[[ "$(load_count)" -eq 0 ]] || fail "server dry-run must not run image loader"
[[ "$(hit_count)" -eq 0 ]] || fail "server dry-run must not run smoke"
[[ ! -e "$dry_run_output/airgap-image-load" ]] || fail "server dry-run must not leave image-load output"
[[ ! -e "$dry_run_output/rollout" ]] || fail "server dry-run must not leave rollout output"
[[ ! -e "$dry_run_output/smoke" ]] || fail "server dry-run must not leave smoke output"
assert_report \
  "$dry_run_output/$REPORT_FILE" \
  server-dry-run \
  target-preflight,airgap-bundle-render-check,apply
if ! tail -n 1 "$TMP_DIR/dry-run.out" | grep -q 'airgap deployment focused chain mode is not release readiness; readiness=false'; then
  cat "$TMP_DIR/dry-run.out" >&2
  fail "airgap deployment gate stdout must end with non-readiness wording"
fi
pass "airgap deployment server dry-run ran preflight, bundle render-check, and apply dry-run only"

apply_output="$TMP_DIR/out-apply-smoke"
reset_logs
before_smoke="$(hit_count)"
run_airgap_gate "$VALID_BUNDLE_ROOT" "$apply_output" "$AIRGAP_PROFILE" \
  --mode apply \
  --archive-probe "$GOOD_PROBE" \
  --image-loader "$GOOD_LOADER" \
  --confirm-apply "$AIRGAP_PROFILE" \
  --operator-run-id airgap-run-1001 \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost >"$TMP_DIR/apply-smoke.out"
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed airgap apply must not pass --dry-run=server"
fi
grep -q 'rollout status Deployment/agentsmith-web' "$KUBECTL_LOG" || fail "apply mode must call rollout"
[[ "$(load_count)" -eq "${#RELEASE_IMAGE_IDS[@]}" ]] || fail "apply mode must load each image exactly once"
after_smoke="$(hit_count)"
[[ "$after_smoke" -eq $((before_smoke + 1)) ]] || fail "apply mode with smoke-url must issue exactly one smoke GET"
assert_report \
  "$apply_output/$REPORT_FILE" \
  apply \
  target-preflight,airgap-image-load,airgap-bundle-render-check,apply,rollout,smoke \
  airgap-run-1001
pass "airgap deployment apply mode ran image-load, render-check, apply, rollout, and optional smoke"

reset_logs
expect_gate_fail "apply-bad-timeout" "$TMP_DIR/out-bad-timeout" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-bad-timeout" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-bad-timeout \
    --timeout forever
assert_no_apply_side_effects "bad rollout timeout"

reset_logs
before_smoke="$(hit_count)"
expect_gate_fail "apply-bad-smoke-url" "$TMP_DIR/out-bad-smoke-url" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-bad-smoke-url" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-bad-smoke-url \
    --smoke-url "$BASE_URL/ok"
assert_no_apply_side_effects "bad smoke url" "$before_smoke"

reset_logs
before_smoke="$(hit_count)"
expect_gate_fail "apply-bad-timeout-ms" "$TMP_DIR/out-bad-timeout-ms" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-bad-timeout-ms" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-bad-timeout-ms \
    --smoke-url "$BASE_URL/ok" \
    --allow-http \
    --allow-localhost \
    --timeout-ms 0
assert_no_apply_side_effects "bad smoke timeout-ms" "$before_smoke"

reset_logs
expect_gate_fail "apply-smoke-option-without-url" "$TMP_DIR/out-smoke-option-without-url" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-smoke-option-without-url" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-smoke-option-without-url \
    --expected-status 200
assert_no_apply_side_effects "smoke option without smoke-url"

reset_logs
before_smoke="$(hit_count)"
expect_gate_fail "apply-bad-expected-status" "$TMP_DIR/out-bad-expected-status" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-bad-expected-status" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-bad-expected-status \
    --smoke-url "$BASE_URL/ok" \
    --allow-http \
    --allow-localhost \
    --expected-status 99
assert_no_apply_side_effects "bad smoke expected status" "$before_smoke"

FORBIDDEN_ROOT="$TMP_DIR/forbidden-source-root"
mkdir -p "$FORBIDDEN_ROOT"
cp "$VALID_BUNDLE_ROOT/components/release-contract.json" "$FORBIDDEN_ROOT/release-contract.json"
reset_logs
expect_gate_fail "forbidden-release-contract-input" "$TMP_DIR/out-forbidden-source-root" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-forbidden-source-root" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-forbidden-source-root \
    --forbidden-source-root "$FORBIDDEN_ROOT" \
    --release-contract "$FORBIDDEN_ROOT/release-contract.json"
assert_no_apply_side_effects "forbidden source root"
[[ ! -e "$TMP_DIR/out-forbidden-source-root/target-preflight" ]] || fail "forbidden source root must fail before any focused step"

reset_logs
expect_gate_fail "apply-missing-archive-probe" "$TMP_DIR/out-missing-probe" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-missing-probe" "$AIRGAP_PROFILE" \
    --mode apply \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-1002
[[ ! -s "$KUBECTL_LOG" ]] || fail "missing archive probe must fail before kubectl"

reset_logs
expect_gate_fail "apply-missing-image-loader" "$TMP_DIR/out-missing-loader" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-missing-loader" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --confirm-apply "$AIRGAP_PROFILE" \
    --operator-run-id airgap-run-1003
[[ ! -s "$KUBECTL_LOG" ]] || fail "missing image loader must fail before kubectl"

reset_logs
expect_gate_fail "apply-confirm-mismatch" "$TMP_DIR/out-confirm-mismatch" \
  run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-confirm-mismatch" "$AIRGAP_PROFILE" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply "$ONLINE_PROFILE" \
    --operator-run-id airgap-run-1004
[[ ! -s "$KUBECTL_LOG" ]] || fail "confirm mismatch must fail before kubectl"

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE" \
  "kit-airgap:$KIT_AIRGAP_PROFILE" \
  "alias-offline:$ALIAS_OFFLINE_PROFILE"; do
  label="${profile_case%%:*}"
  profile="${profile_case#*:}"
  reset_logs
  expect_gate_fail "unsupported-profile-$label" "$TMP_DIR/out-profile-$label" \
    run_airgap_gate "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-profile-$label" "$profile" \
      --mode server-dry-run
  [[ ! -s "$KUBECTL_LOG" ]] || fail "unsupported profile must fail before kubectl: $label"
done

pass "airgap deployment focused diagnostic tests completed"
