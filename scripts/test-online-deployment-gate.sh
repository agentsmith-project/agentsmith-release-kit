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

write_prerequisites() {
  local output="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$output" "$TARGET_PROFILE" "$mutation" <<'NODE'
import fs from 'node:fs';

const [output, profile, mutation] = process.argv.slice(2);

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

switch (mutation) {
  case 'valid':
    break;
  case 'missing_namespace':
    delete prerequisites.namespace;
    break;
  default:
    throw new Error(`unknown prerequisites mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
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

write_evidence_provenance() {
  local output="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [output, mutation] = process.argv.slice(2);

const provenance = {
  schema_version: 'agentsmith.artifact-provenance/v1',
  provenance_kind: 'ci_artifact',
  producer_repo: 'github.com/agentsmith-project/agentsmith-release-kit',
  normalized_remote: 'github.com/agentsmith-project/agentsmith-release-kit',
  commit_sha: 'fedcba9876543210fedcba9876543210fedcba98',
  artifact_uri: 'gh-artifact://agentsmith-release-kit/evidence/10001/online-deployment-gate-evidence.tgz',
  generated_at: '2026-05-23T12:00:00.000Z',
  generator_command: 'bash scripts/verify-release.sh --online-deployment-gate --evidence-root',
  generator_version: '0.1.0',
  attestation: 'none',
  workflow_name: 'online-deployment-gate-evidence',
  run_id: '10001',
  run_attempt: '1',
  job: 'online-deployment-gate'
};

function useSignedOperatorRun(artifactUri) {
  provenance.provenance_kind = 'signed_operator_run';
  provenance.artifact_uri = artifactUri;
  provenance.operator_run_id = 'operator-run-10001';
  provenance.operator_identity = 'release-operator@example.com';
  provenance.signature_uri =
    'https://signatures.example.com/agentsmith-release-kit/operator-run-10001.sig';
  provenance.signature_sha256 = `sha256:${'a'.repeat(64)}`;
  delete provenance.workflow_name;
  delete provenance.run_id;
  delete provenance.run_attempt;
  delete provenance.job;
}

switch (mutation) {
  case 'valid':
    break;
  case 'local_uri':
    provenance.artifact_uri = 'file:///tmp/online-deployment-gate-evidence.tgz';
    break;
  case 'secret_payload':
    provenance.operator_token = 'ghp_123456789012345678901234567890123456';
    break;
  case 'out_of_scope_fields':
    provenance.readiness = true;
    provenance.verdict = 'release-ready';
    provenance.scope = 'release_readiness';
    provenance['product-flow'] = 'workspace_project';
    provenance.operator_signoff = { status: 'approved' };
    break;
  case 'wrong_artifact_host':
    provenance.artifact_uri =
      'https://example.com/agentsmith-release-kit/actions/runs/10001/artifacts/evidence.zip';
    break;
  case 'wrong_artifact_repo':
    provenance.artifact_uri =
      'https://api.github.com/repos/example/not-release-kit/actions/runs/10001/artifacts/evidence.zip';
    break;
  case 'repo_level_artifact_uri':
    provenance.artifact_uri =
      'https://api.github.com/repos/agentsmith-project/agentsmith-release-kit/actions/artifacts';
    break;
  case 'run_id_mismatch':
    provenance.artifact_uri =
      'gh-artifact://agentsmith-release-kit/evidence/99999/online-deployment-gate-evidence.tgz';
    break;
  case 'signed_unbound_operator_run_uri':
    useSignedOperatorRun(
      'gh-artifact://agentsmith-release-kit/evidence/10001/online-deployment-gate-evidence.tgz'
    );
    break;
  default:
    throw new Error(`unknown provenance mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(provenance, null, 2)}\n`);
NODE
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
    live_image="\${FAKE_KUBECTL_LIVE_IMAGE:-ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111}"
    live_image_id="\${FAKE_KUBECTL_LIVE_IMAGE_ID:-docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111}"
    live_init_image="\${FAKE_KUBECTL_LIVE_INIT_IMAGE:-$live_image}"
    live_init_image_id="\${FAKE_KUBECTL_LIVE_INIT_IMAGE_ID:-$live_image_id}"
    live_container_image="\${FAKE_KUBECTL_LIVE_CONTAINER_IMAGE:-$live_image}"
    live_container_image_id="\${FAKE_KUBECTL_LIVE_CONTAINER_IMAGE_ID:-$live_image_id}"
    cat <<JSON
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"$live_init_image","imageID":"$live_init_image_id"}],"containerStatuses":[{"name":"web","image":"$live_container_image","imageID":"$live_container_image_id"}]}}]}
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

write_stale_evidence_files() {
  local evidence_root="$1"

  mkdir -p "$evidence_root"
  printf '%s\n' '{"stale":true}' >"$evidence_root/evidence.json"
  printf '%s\n' '{"stale":true}' >"$evidence_root/evidence-subject.json"
  printf '%s\n' '{"stale":true}' >"$evidence_root/online-deployment-gate-report.json"
}

assert_no_evidence_files() {
  local evidence_root="$1"

  for evidence_file in evidence.json evidence-subject.json online-deployment-gate-report.json; do
    if [[ -e "$evidence_root/$evidence_file" ]]; then
      fail "failed gate must not leave stale evidence file: $evidence_file"
    fi
  done
}

run_evidence() {
  local release_contract="$1"
  local evidence_root="$2"
  local output_dir="$3"
  local target_profile="${4:-$TARGET_PROFILE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --evidence \
    --release-contract "$release_contract" \
    --evidence-root "$evidence_root" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir"
}

run_gate() {
  local release_contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local render_values="$4"
  local substrate_truth="$5"
  local output_dir="$6"
  local target_profile="${7:-$TARGET_PROFILE}"
  local target_prerequisites="${TARGET_PREREQUISITES_OVERRIDE:-$VALID_PREREQUISITES}"
  shift 7 || true

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  FAKE_KUBECTL_LIVE_IMAGE="${FAKE_KUBECTL_LIVE_IMAGE:-}" \
  FAKE_KUBECTL_LIVE_IMAGE_ID="${FAKE_KUBECTL_LIVE_IMAGE_ID:-}" \
  FAKE_KUBECTL_LIVE_INIT_IMAGE="${FAKE_KUBECTL_LIVE_INIT_IMAGE:-}" \
  FAKE_KUBECTL_LIVE_INIT_IMAGE_ID="${FAKE_KUBECTL_LIVE_INIT_IMAGE_ID:-}" \
  FAKE_KUBECTL_LIVE_CONTAINER_IMAGE="${FAKE_KUBECTL_LIVE_CONTAINER_IMAGE:-}" \
  FAKE_KUBECTL_LIVE_CONTAINER_IMAGE_ID="${FAKE_KUBECTL_LIVE_CONTAINER_IMAGE_ID:-}" \
  bash "$ROOT_DIR/scripts/verify-release.sh" --online-deployment-gate \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --target-profile "$target_profile" \
    --render-values "$render_values" \
    --substrate-truth "$substrate_truth" \
    --target-prerequisites "$target_prerequisites" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    "$@"
}

run_gate_without_prerequisites() {
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
const capabilityMap = report.capability_map;
if (!capabilityMap || typeof capabilityMap !== 'object' || Array.isArray(capabilityMap)) {
  throw new Error('aggregate report must include a capability map');
}
const capabilityProfiles = Object.keys(capabilityMap);
if (capabilityProfiles.length !== 1 || capabilityProfiles[0] !== expectedProfile) {
  throw new Error(`capability map must only declare the current target profile: ${capabilityProfiles.join(',')}`);
}
const capability = capabilityMap[expectedProfile];
const expectedCapability = {
  declared: 'supported',
  intake: 'supported',
  preflight: 'supported',
  render: 'supported',
  apply: 'supported',
  rollout: 'supported',
  smoke: 'optional',
  evidence_envelope: 'optional'
};
const expectedCapabilityKeys = Object.keys(expectedCapability).sort();
const actualCapabilityKeys = Object.keys(capability || {}).sort();
if (JSON.stringify(actualCapabilityKeys) !== JSON.stringify(expectedCapabilityKeys)) {
  throw new Error(`unexpected capability keys: ${actualCapabilityKeys.join(',')}`);
}
for (const [key, value] of Object.entries(expectedCapability)) {
  if (capability[key] !== value) {
    throw new Error(`unexpected capability value for ${key}: ${capability[key]}`);
  }
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
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report || 'readiness_verdict' in report) {
  throw new Error('aggregate report must not claim verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('aggregate report must not include AgentSmith product flow fields');
}
if (/cloud.?provision|registry.?login|registry.?push|registry.?mirror|airgap.?create|airgap.?load|rollback|release_readiness|deploy_readiness|release_verdict|\bverdict\b/i.test(serialized)) {
  throw new Error('aggregate report must not include out-of-scope deploy or release capabilities');
}
if (/password|token=|plain-secret-value|client_secret|authorization|bearer|kubeconfig/i.test(serialized)) {
  throw new Error('aggregate report leaked secret-ish payloads or kubeconfig fields');
}
NODE
}

assert_gate_rendered_target_registry() {
  local output_dir="$1"
  local expected_registry="$2"

  "$NODE_BIN" --input-type=module - "$output_dir" "$expected_registry" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [outputDir, expectedRegistry] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(path.join(outputDir, 'image-map/image-map.json'), 'utf8'));
const rendered = fs.readFileSync(
  path.join(outputDir, 'render/rendered-manifests/templates/workloads.yaml'),
  'utf8'
);
const appMapping = imageMap.mappings.find((mapping) => mapping.id === 'agentsmith_app');

if (!appMapping) {
  throw new Error('image-map step did not include agentsmith_app');
}
if (imageMap.target_registry !== expectedRegistry) {
  throw new Error(`unexpected target registry: ${imageMap.target_registry}`);
}
if (!appMapping.target_image.startsWith(`${expectedRegistry}/`)) {
  throw new Error(`target image did not use expected registry: ${appMapping.target_image}`);
}
if (!rendered.includes(appMapping.target_image)) {
  throw new Error('rendered manifest did not adopt image-map target image');
}
if (rendered.includes(appMapping.source_image)) {
  throw new Error('rendered manifest kept source image despite target-registry image-map');
}
NODE
}

image_map_target_image() {
  local image_map="$1"
  local image_id="$2"

  "$NODE_BIN" --input-type=module - "$image_map" "$image_id" <<'NODE'
import fs from 'node:fs';

const [imageMapFile, imageId] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(imageMapFile, 'utf8'));
const mapping = imageMap.mappings.find((item) => item.id === imageId);

if (!mapping?.target_image) {
  throw new Error(`image-map is missing target image for ${imageId}`);
}

console.log(mapping.target_image);
NODE
}

assert_generated_evidence() {
  local evidence_root="$1"

  "$NODE_BIN" --input-type=module - "$evidence_root" "$TARGET_PROFILE" "$BASE_URL" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [evidenceRoot, targetProfile, localSmokeUrl] = process.argv.slice(2);
const evidence = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'evidence.json'), 'utf8'));
const subject = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'evidence-subject.json'), 'utf8'));
const gateReport = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'online-deployment-gate-report.json'), 'utf8'));
const serialized = [
  JSON.stringify(evidence),
  JSON.stringify(subject),
  JSON.stringify(gateReport)
].join('\n');

if (evidence.schema_version !== 'agentsmith.release-kit-evidence-envelope/v1') {
  throw new Error(`unexpected evidence schema: ${evidence.schema_version}`);
}
if (evidence.release_kit_output !== 'online-deployment-gate-report.json') {
  throw new Error(`unexpected release_kit_output: ${evidence.release_kit_output}`);
}
if (evidence.status !== 'passed' || evidence.failure_class !== 'none') {
  throw new Error('online gate evidence must be a passed focused diagnostic');
}
if (evidence.target_cluster !== 'existing_kubernetes' || evidence.substrate_source !== 'external_declared' || evidence.distribution !== 'online') {
  throw new Error('online gate evidence target axes drifted');
}
if (evidence.target?.namespace !== 'agentsmith') {
  throw new Error('online gate evidence target must include namespace');
}
if (!evidence.release_contract_digest?.startsWith('sha256:')) {
  throw new Error('online gate evidence must bind release contract digest');
}
if (evidence.artifact_provenance?.subject_name !== 'release-kit-evidence-subject') {
  throw new Error('online gate evidence provenance subject_name must be fixed');
}
if (evidence.artifact_provenance?.subject_uri !== 'evidence-subject.json') {
  throw new Error('online gate evidence provenance subject_uri must be fixed');
}
if (!evidence.artifact_provenance?.subject_sha256?.startsWith('sha256:')) {
  throw new Error('online gate evidence provenance subject_sha256 must be computed');
}
const provenanceKind = evidence.artifact_provenance?.provenance_kind;
const allowedProvenanceKeys = new Set([
  'schema_version',
  'provenance_kind',
  'producer_repo',
  'normalized_remote',
  'commit_sha',
  'artifact_uri',
  'generated_at',
  'generator_command',
  'generator_version',
  'attestation',
  'subject_name',
  'subject_uri',
  'subject_sha256',
  ...(provenanceKind === 'ci_artifact'
    ? ['workflow_name', 'run_id', 'run_attempt', 'job']
    : ['operator_run_id', 'operator_identity', 'signature_uri', 'signature_sha256'])
]);
for (const key of Object.keys(evidence.artifact_provenance || {})) {
  if (!allowedProvenanceKeys.has(key)) {
    throw new Error(`online gate evidence carried non-allowlisted provenance field: ${key}`);
  }
}
const files = subject.files?.map((file) => file.path).sort();
if (JSON.stringify(files) !== JSON.stringify(['evidence.json', 'online-deployment-gate-report.json'])) {
  throw new Error(`unexpected evidence subject files: ${files}`);
}
if (gateReport.target_profile?.value !== targetProfile) {
  throw new Error('evidence root gate report target profile drifted');
}
if (serialized.includes(localSmokeUrl)) {
  throw new Error('evidence root must not persist local focused smoke URL');
}
if (/required_product_flows|product_flows|product_flow_results|cloud.?provision|release_verdict|\bverdict\b|deploy_readiness|readiness":true/i.test(serialized)) {
  throw new Error('evidence root contains out-of-scope readiness or product-flow fields');
}
NODE
}

KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
VALID_TRUTH="$TMP_DIR/substrate-truth.valid.json"
VALID_PREREQUISITES="$TMP_DIR/target-prerequisites.valid.json"
INVALID_PREFLIGHT_PREREQUISITES="$TMP_DIR/target-prerequisites.invalid-preflight.json"
VALID_VALUES="$TMP_DIR/render-values.valid.json"
VALID_ARCHIVE="$TMP_DIR/valid.tgz"
VALID_CONTRACT_MATERIAL="$TMP_DIR/release-contract.valid-material.json"
VALID_PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.valid-material.json"
INVALID_ARCHIVE="$TMP_DIR/invalid-render.tgz"
INVALID_CONTRACT_MATERIAL="$TMP_DIR/release-contract.invalid-render.json"
INVALID_PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.invalid-render.json"
VALID_PROVENANCE="$TMP_DIR/evidence-provenance.valid.json"
LOCAL_URI_PROVENANCE="$TMP_DIR/evidence-provenance.local-uri.json"
SECRET_PROVENANCE="$TMP_DIR/evidence-provenance.secret.json"
OUT_OF_SCOPE_PROVENANCE="$TMP_DIR/evidence-provenance.out-of-scope.json"
WRONG_HOST_PROVENANCE="$TMP_DIR/evidence-provenance.wrong-host.json"
WRONG_REPO_PROVENANCE="$TMP_DIR/evidence-provenance.wrong-repo.json"
REPO_LEVEL_ARTIFACT_PROVENANCE="$TMP_DIR/evidence-provenance.repo-level-artifact.json"
RUN_ID_MISMATCH_PROVENANCE="$TMP_DIR/evidence-provenance.run-id-mismatch.json"
SIGNED_UNBOUND_OPERATOR_PROVENANCE="$TMP_DIR/evidence-provenance.signed-unbound-operator.json"

write_truth "$VALID_TRUTH"
write_prerequisites "$VALID_PREREQUISITES" valid
write_prerequisites "$INVALID_PREFLIGHT_PREREQUISITES" missing_namespace
write_render_values "$VALID_VALUES"
prepare_archive_case valid valid "$VALID_ARCHIVE" "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL"
prepare_archive_case invalid-render unknown_variable "$INVALID_ARCHIVE" "$INVALID_CONTRACT_MATERIAL" "$INVALID_PACKAGE_MATERIAL"
write_evidence_provenance "$VALID_PROVENANCE" valid
write_evidence_provenance "$LOCAL_URI_PROVENANCE" local_uri
write_evidence_provenance "$SECRET_PROVENANCE" secret_payload
write_evidence_provenance "$OUT_OF_SCOPE_PROVENANCE" out_of_scope_fields
write_evidence_provenance "$WRONG_HOST_PROVENANCE" wrong_artifact_host
write_evidence_provenance "$WRONG_REPO_PROVENANCE" wrong_artifact_repo
write_evidence_provenance "$REPO_LEVEL_ARTIFACT_PROVENANCE" repo_level_artifact_uri
write_evidence_provenance "$RUN_ID_MISMATCH_PROVENANCE" run_id_mismatch
write_evidence_provenance "$SIGNED_UNBOUND_OPERATOR_PROVENANCE" signed_unbound_operator_run_uri
start_server
BASE_URL="http://127.0.0.1:$SERVER_PORT"

parse_unknown_root="$TMP_DIR/evidence-parse-unknown"
write_stale_evidence_files "$parse_unknown_root"
if bash "$ROOT_DIR/scripts/verify-release.sh" --online-deployment-gate \
  --evidence-root "$parse_unknown_root" \
  --unknown-argument >"$TMP_DIR/parse-unknown.out" 2>"$TMP_DIR/parse-unknown.err"; then
  fail "expected unknown argument with evidence root to fail"
fi
assert_no_evidence_files "$parse_unknown_root"
pass "parse-time unknown argument clears stale evidence files"

parse_missing_root="$TMP_DIR/evidence-parse-missing"
write_stale_evidence_files "$parse_missing_root"
if bash "$ROOT_DIR/scripts/verify-release.sh" --online-deployment-gate \
  --evidence-root "$parse_missing_root" >"$TMP_DIR/parse-missing.out" 2>"$TMP_DIR/parse-missing.err"; then
  fail "expected missing required args with evidence root to fail"
fi
assert_no_evidence_files "$parse_missing_root"
pass "parse-time missing required args clear stale evidence files"

missing_preflight_input_output="$TMP_DIR/out-missing-target-prerequisites"
mkdir -p "$missing_preflight_input_output"
printf '%s\n' '{"stale":true}' >"$missing_preflight_input_output/online-deployment-gate-report.json"
reset_kubectl_log
before_missing_preflight_input="$(hit_count)"
if run_gate_without_prerequisites "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$missing_preflight_input_output" "$TARGET_PROFILE" >"$TMP_DIR/missing-target-prerequisites.out" 2>"$TMP_DIR/missing-target-prerequisites.err"; then
  fail "expected online deployment gate without target prerequisites to fail"
fi
after_missing_preflight_input="$(hit_count)"
assert_kubectl_not_called
[[ "$before_missing_preflight_input" == "$after_missing_preflight_input" ]] || fail "missing target prerequisites reached route/network smoke"
assert_no_gate_report "$missing_preflight_input_output"
pass "online deployment gate requires target prerequisites before kubectl or network"

invalid_preflight_output="$TMP_DIR/out-invalid-target-preflight"
mkdir -p "$invalid_preflight_output/render" "$invalid_preflight_output/apply"
printf '%s\n' '{"stale":true}' >"$invalid_preflight_output/online-deployment-gate-report.json"
printf '%s\n' '{"stale":true}' >"$invalid_preflight_output/render/manifest-render-report.json"
printf '%s\n' '{"stale":true}' >"$invalid_preflight_output/apply/apply-report.json"
reset_kubectl_log
before_invalid_preflight="$(hit_count)"
if TARGET_PREREQUISITES_OVERRIDE="$INVALID_PREFLIGHT_PREREQUISITES" run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$invalid_preflight_output" "$TARGET_PROFILE" >"$TMP_DIR/invalid-preflight.out" 2>"$TMP_DIR/invalid-preflight.err"; then
  fail "expected invalid target-preflight truth to stop online deployment gate"
fi
after_invalid_preflight="$(hit_count)"
assert_kubectl_not_called
[[ "$before_invalid_preflight" == "$after_invalid_preflight" ]] || fail "invalid target-preflight reached route/network smoke"
assert_no_gate_report "$invalid_preflight_output"
[[ ! -e "$invalid_preflight_output/render/manifest-render-report.json" ]] || fail "invalid target-preflight must not leave stale render report"
[[ ! -e "$invalid_preflight_output/apply/apply-report.json" ]] || fail "invalid target-preflight must not leave stale apply report"
pass "invalid target preflight stops online gate before render, kubectl, or network and clears stale reports"

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

target_registry="registry.release.example/agentsmith"
target_registry_output="$TMP_DIR/out-dry-target-registry"
reset_kubectl_log
before_target_registry="$(hit_count)"
run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$target_registry_output" "$TARGET_PROFILE" \
  --target-registry "$target_registry" >/dev/null
after_target_registry="$(hit_count)"
[[ "$before_target_registry" == "$after_target_registry" ]] || fail "target-registry dry-run should not issue route/network smoke requests"
[[ -f "$target_registry_output/image-map/image-map.json" ]] || fail "target-registry gate did not write image-map report"
grep -q 'version' "$KUBECTL_LOG" || fail "target-registry dry-run did not call kubectl version"
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "target-registry dry-run did not call server dry-run apply"
if grep -Eiq 'docker|skopeo|oras|crane|registry login|registry push|registry mirror|pull|push|mirror' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "target-registry dry-run must not run registry network operations"
fi
assert_gate_report "$target_registry_output/online-deployment-gate-report.json" server-dry-run "inputs,target-preflight,template-package,image-map,render,render-check,apply"
assert_gate_rendered_target_registry "$target_registry_output" "$target_registry"
pass "online deployment gate target-registry dry-run writes image-map step and renders target refs without registry ops"

target_registry_app_image="$(image_map_target_image "$target_registry_output/image-map/image-map.json" agentsmith_app)"

invalid_target_registry_output="$TMP_DIR/out-invalid-target-registry"
reset_kubectl_log
before_invalid_target_registry="$(hit_count)"
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$invalid_target_registry_output" "$TARGET_PROFILE" \
  --target-registry "https://registry.release.example/agentsmith" >"$TMP_DIR/invalid-target-registry.out" 2>"$TMP_DIR/invalid-target-registry.err"; then
  fail "expected invalid target registry to fail"
fi
after_invalid_target_registry="$(hit_count)"
assert_kubectl_not_called
[[ "$before_invalid_target_registry" == "$after_invalid_target_registry" ]] || fail "invalid target registry rejection reached network"
assert_no_gate_report "$invalid_target_registry_output"
pass "invalid target registry rejected before kubectl or network"

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

dry_evidence_root="$TMP_DIR/evidence-dry"
dry_evidence_output="$TMP_DIR/out-dry-evidence"
mkdir -p "$dry_evidence_output"
printf '%s\n' '{"stale":true}' >"$dry_evidence_output/online-deployment-gate-report.json"
write_stale_evidence_files "$dry_evidence_root"
reset_kubectl_log
before_dry_evidence="$(hit_count)"
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$dry_evidence_output" "$TARGET_PROFILE" \
  --evidence-root "$dry_evidence_root" --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/dry-evidence.out" 2>"$TMP_DIR/dry-evidence.err"; then
  fail "expected server dry-run evidence request to fail"
fi
after_dry_evidence="$(hit_count)"
assert_kubectl_not_called
[[ "$before_dry_evidence" == "$after_dry_evidence" ]] || fail "server dry-run evidence rejection reached network"
assert_no_gate_report "$dry_evidence_output"
assert_no_evidence_files "$dry_evidence_root"
pass "server dry-run rejects evidence output before kubectl or network and clears stale evidence"

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

apply_evidence_output="$TMP_DIR/out-apply-evidence"
apply_evidence_root="$TMP_DIR/evidence-apply"
apply_evidence_validation="$TMP_DIR/out-apply-evidence-validation"
reset_kubectl_log
before_apply_evidence="$(hit_count)"
run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$apply_evidence_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1003 \
  --timeout 120s \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost \
  --evidence-root "$apply_evidence_root" \
  --evidence-provenance "$VALID_PROVENANCE" >/dev/null
after_apply_evidence="$(hit_count)"
[[ "$after_apply_evidence" -eq $((before_apply_evidence + 1)) ]] || fail "apply evidence gate smoke should issue one request"
[[ -f "$apply_evidence_root/evidence.json" ]] || fail "apply evidence gate did not write evidence.json"
[[ -f "$apply_evidence_root/evidence-subject.json" ]] || fail "apply evidence gate did not write evidence-subject.json"
[[ -f "$apply_evidence_root/online-deployment-gate-report.json" ]] || fail "apply evidence gate did not write evidence root gate report"
assert_gate_report "$apply_evidence_output/online-deployment-gate-report.json" apply "inputs,target-preflight,template-package,render,render-check,apply,rollout,smoke"
assert_generated_evidence "$apply_evidence_root"
run_evidence "$VALID_CONTRACT_MATERIAL" "$apply_evidence_root" "$apply_evidence_validation" >/dev/null
[[ -f "$apply_evidence_output/evidence-validation/evidence-validation-report.json" ]] || fail "apply evidence gate did not internally validate evidence root"
pass "confirmed apply rollout smoke can generate validator-accepted online gate evidence root"

target_registry_apply_evidence_output="$TMP_DIR/out-apply-target-registry-evidence"
target_registry_apply_evidence_root="$TMP_DIR/evidence-apply-target-registry"
target_registry_apply_evidence_validation="$TMP_DIR/out-apply-target-registry-evidence-validation"
reset_kubectl_log
before_target_registry_apply_evidence="$(hit_count)"
FAKE_KUBECTL_LIVE_IMAGE="$target_registry_app_image" \
FAKE_KUBECTL_LIVE_IMAGE_ID="docker-pullable://$target_registry_app_image" \
run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$target_registry_apply_evidence_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1013 \
  --timeout 120s \
  --target-registry "$target_registry" \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost \
  --evidence-root "$target_registry_apply_evidence_root" \
  --evidence-provenance "$VALID_PROVENANCE" >/dev/null
after_target_registry_apply_evidence="$(hit_count)"
[[ "$after_target_registry_apply_evidence" -eq $((before_target_registry_apply_evidence + 1)) ]] || fail "target-registry apply evidence gate smoke should issue one request"
assert_gate_report "$target_registry_apply_evidence_output/online-deployment-gate-report.json" apply "inputs,target-preflight,template-package,image-map,render,render-check,apply,rollout,smoke"
assert_gate_rendered_target_registry "$target_registry_apply_evidence_output" "$target_registry"
assert_generated_evidence "$target_registry_apply_evidence_root"
run_evidence "$VALID_CONTRACT_MATERIAL" "$target_registry_apply_evidence_root" "$target_registry_apply_evidence_validation" >/dev/null
[[ -f "$target_registry_apply_evidence_output/evidence-validation/evidence-validation-report.json" ]] || fail "target-registry apply evidence gate did not internally validate evidence root"
pass "target-registry confirmed apply rollout smoke can generate validator-accepted online gate evidence root"

target_registry_digest_only_live_root="$TMP_DIR/evidence-target-registry-digest-only-live"
target_registry_digest_only_live_output="$TMP_DIR/out-target-registry-digest-only-live"
target_registry_tag_only_image="${target_registry_app_image%@sha256:*}:runtime"
target_registry_live_digest="${target_registry_app_image##*@}"
write_stale_evidence_files "$target_registry_digest_only_live_root"
reset_kubectl_log
before_target_registry_digest_only_live="$(hit_count)"
if FAKE_KUBECTL_LIVE_IMAGE="$target_registry_tag_only_image" \
  FAKE_KUBECTL_LIVE_IMAGE_ID="$target_registry_live_digest" \
  run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$target_registry_digest_only_live_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1014 \
  --timeout 120s \
  --target-registry "$target_registry" \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost \
  --evidence-root "$target_registry_digest_only_live_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/target-registry-digest-only-live.out" 2>"$TMP_DIR/target-registry-digest-only-live.err"; then
  fail "expected target-registry apply evidence to reject digest-only live status without target digest-pinned refs"
fi
after_target_registry_digest_only_live="$(hit_count)"
grep -q 'get pods' "$KUBECTL_LOG" || fail "target-registry digest-only live case did not reach live pod check"
[[ "$before_target_registry_digest_only_live" == "$after_target_registry_digest_only_live" ]] || fail "target-registry digest-only live rejection should stop before route/network smoke"
assert_no_gate_report "$target_registry_digest_only_live_output"
assert_no_evidence_files "$target_registry_digest_only_live_root"
[[ ! -e "$target_registry_digest_only_live_output/rollout/rollout-report.json" ]] || fail "target-registry digest-only live rejection must not write rollout report"
[[ ! -e "$target_registry_digest_only_live_output/smoke/smoke-report.json" ]] || fail "target-registry digest-only live rejection must not write smoke report"
pass "target-registry apply evidence rejects digest-only live status without target digest-pinned refs before smoke or evidence closure"

target_registry_mixed_live_root="$TMP_DIR/evidence-target-registry-mixed-live"
target_registry_mixed_live_output="$TMP_DIR/out-target-registry-mixed-live"
write_stale_evidence_files "$target_registry_mixed_live_root"
reset_kubectl_log
before_target_registry_mixed_live="$(hit_count)"
if FAKE_KUBECTL_LIVE_INIT_IMAGE="$target_registry_app_image" \
  FAKE_KUBECTL_LIVE_INIT_IMAGE_ID="docker-pullable://$target_registry_app_image" \
  FAKE_KUBECTL_LIVE_CONTAINER_IMAGE="ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111" \
  FAKE_KUBECTL_LIVE_CONTAINER_IMAGE_ID="docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111" \
  run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$target_registry_mixed_live_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1015 \
  --timeout 120s \
  --target-registry "$target_registry" \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost \
  --evidence-root "$target_registry_mixed_live_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/target-registry-mixed-live.out" 2>"$TMP_DIR/target-registry-mixed-live.err"; then
  fail "expected target-registry apply evidence to reject mixed source and target live image refs"
fi
after_target_registry_mixed_live="$(hit_count)"
grep -q 'get pods' "$KUBECTL_LOG" || fail "target-registry mixed live case did not reach live pod check"
[[ "$before_target_registry_mixed_live" == "$after_target_registry_mixed_live" ]] || fail "target-registry mixed live rejection should stop before route/network smoke"
assert_no_gate_report "$target_registry_mixed_live_output"
assert_no_evidence_files "$target_registry_mixed_live_root"
pass "target-registry apply evidence rejects mixed source and target live image refs before smoke or evidence closure"

missing_provenance_root="$TMP_DIR/evidence-missing-provenance"
missing_provenance_output="$TMP_DIR/out-missing-provenance"
write_stale_evidence_files "$missing_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$missing_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1004 --evidence-root "$missing_provenance_root" >"$TMP_DIR/missing-provenance.out" 2>"$TMP_DIR/missing-provenance.err"; then
  fail "expected evidence root without provenance input to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$missing_provenance_output"
assert_no_evidence_files "$missing_provenance_root"
pass "evidence output requires explicit provenance before kubectl"

local_provenance_root="$TMP_DIR/evidence-local-provenance"
local_provenance_output="$TMP_DIR/out-local-provenance"
write_stale_evidence_files "$local_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$local_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1005 --evidence-root "$local_provenance_root" --evidence-provenance "$LOCAL_URI_PROVENANCE" >"$TMP_DIR/local-provenance.out" 2>"$TMP_DIR/local-provenance.err"; then
  fail "expected local/file provenance URI to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$local_provenance_output"
assert_no_evidence_files "$local_provenance_root"
pass "local/file provenance URI rejected before kubectl"

secret_provenance_root="$TMP_DIR/evidence-secret-provenance"
secret_provenance_output="$TMP_DIR/out-secret-provenance"
write_stale_evidence_files "$secret_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$secret_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1006 --evidence-root "$secret_provenance_root" --evidence-provenance "$SECRET_PROVENANCE" >"$TMP_DIR/secret-provenance.out" 2>"$TMP_DIR/secret-provenance.err"; then
  fail "expected secret-looking provenance to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$secret_provenance_output"
assert_no_evidence_files "$secret_provenance_root"
pass "secret-looking provenance rejected before kubectl"

out_of_scope_provenance_root="$TMP_DIR/evidence-out-of-scope-provenance"
out_of_scope_provenance_output="$TMP_DIR/out-out-of-scope-provenance"
write_stale_evidence_files "$out_of_scope_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$out_of_scope_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1007 --evidence-root "$out_of_scope_provenance_root" --evidence-provenance "$OUT_OF_SCOPE_PROVENANCE" >"$TMP_DIR/out-of-scope-provenance.out" 2>"$TMP_DIR/out-of-scope-provenance.err"; then
  fail "expected out-of-scope provenance fields to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$out_of_scope_provenance_output"
assert_no_evidence_files "$out_of_scope_provenance_root"
pass "out-of-scope provenance fields rejected before kubectl"

wrong_host_provenance_root="$TMP_DIR/evidence-wrong-host-provenance"
wrong_host_provenance_output="$TMP_DIR/out-wrong-host-provenance"
write_stale_evidence_files "$wrong_host_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$wrong_host_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1008 --evidence-root "$wrong_host_provenance_root" --evidence-provenance "$WRONG_HOST_PROVENANCE" >"$TMP_DIR/wrong-host-provenance.out" 2>"$TMP_DIR/wrong-host-provenance.err"; then
  fail "expected wrong artifact_uri host to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$wrong_host_provenance_output"
assert_no_evidence_files "$wrong_host_provenance_root"
pass "wrong artifact_uri host rejected before kubectl"

wrong_repo_provenance_root="$TMP_DIR/evidence-wrong-repo-provenance"
wrong_repo_provenance_output="$TMP_DIR/out-wrong-repo-provenance"
write_stale_evidence_files "$wrong_repo_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$wrong_repo_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1009 --evidence-root "$wrong_repo_provenance_root" --evidence-provenance "$WRONG_REPO_PROVENANCE" >"$TMP_DIR/wrong-repo-provenance.out" 2>"$TMP_DIR/wrong-repo-provenance.err"; then
  fail "expected wrong artifact_uri repo to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$wrong_repo_provenance_output"
assert_no_evidence_files "$wrong_repo_provenance_root"
pass "wrong artifact_uri repo rejected before kubectl"

repo_level_artifact_provenance_root="$TMP_DIR/evidence-repo-level-artifact-provenance"
repo_level_artifact_provenance_output="$TMP_DIR/out-repo-level-artifact-provenance"
write_stale_evidence_files "$repo_level_artifact_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$repo_level_artifact_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1010 --evidence-root "$repo_level_artifact_provenance_root" --evidence-provenance "$REPO_LEVEL_ARTIFACT_PROVENANCE" >"$TMP_DIR/repo-level-artifact-provenance.out" 2>"$TMP_DIR/repo-level-artifact-provenance.err"; then
  fail "expected repo-level artifact_uri to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$repo_level_artifact_provenance_output"
assert_no_evidence_files "$repo_level_artifact_provenance_root"
pass "repo-level artifact_uri rejected before kubectl"

run_id_mismatch_provenance_root="$TMP_DIR/evidence-run-id-mismatch-provenance"
run_id_mismatch_provenance_output="$TMP_DIR/out-run-id-mismatch-provenance"
write_stale_evidence_files "$run_id_mismatch_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$run_id_mismatch_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1011 --evidence-root "$run_id_mismatch_provenance_root" --evidence-provenance "$RUN_ID_MISMATCH_PROVENANCE" >"$TMP_DIR/run-id-mismatch-provenance.out" 2>"$TMP_DIR/run-id-mismatch-provenance.err"; then
  fail "expected artifact_uri run_id mismatch to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$run_id_mismatch_provenance_output"
assert_no_evidence_files "$run_id_mismatch_provenance_root"
pass "artifact_uri run_id mismatch rejected before kubectl"

signed_unbound_operator_provenance_root="$TMP_DIR/evidence-signed-unbound-operator-provenance"
signed_unbound_operator_provenance_output="$TMP_DIR/out-signed-unbound-operator-provenance"
write_stale_evidence_files "$signed_unbound_operator_provenance_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$signed_unbound_operator_provenance_output" "$TARGET_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1012 --evidence-root "$signed_unbound_operator_provenance_root" --evidence-provenance "$SIGNED_UNBOUND_OPERATOR_PROVENANCE" >"$TMP_DIR/signed-unbound-operator-provenance.out" 2>"$TMP_DIR/signed-unbound-operator-provenance.err"; then
  fail "expected signed_operator_run artifact_uri without operator_run_id binding to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$signed_unbound_operator_provenance_output"
assert_no_evidence_files "$signed_unbound_operator_provenance_root"
pass "signed_operator_run artifact_uri without operator_run_id binding rejected before kubectl"

reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$TMP_DIR/out-unsupported-kit-online" "$KIT_ONLINE_PROFILE" >"$TMP_DIR/unsupported-kit-online.out" 2>"$TMP_DIR/unsupported-kit-online.err"; then
  fail "expected kit-installed online target profile to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$TMP_DIR/out-unsupported-kit-online"
pass "kit-installed online profile stays intake-only and is rejected before kubectl"

unsupported_evidence_root="$TMP_DIR/evidence-unsupported-kit-online"
unsupported_evidence_output="$TMP_DIR/out-unsupported-kit-online-evidence"
write_stale_evidence_files "$unsupported_evidence_root"
reset_kubectl_log
if run_gate "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH" "$unsupported_evidence_output" "$KIT_ONLINE_PROFILE" \
  --mode apply --confirm-apply "$TARGET_PROFILE" --operator-run-id operator-run-1011 --evidence-root "$unsupported_evidence_root" --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/unsupported-kit-online-evidence.out" 2>"$TMP_DIR/unsupported-kit-online-evidence.err"; then
  fail "expected kit-installed online evidence closure to fail"
fi
assert_kubectl_not_called
assert_no_gate_report "$unsupported_evidence_output"
assert_no_evidence_files "$unsupported_evidence_root"
pass "unsupported profile cannot pass online gate evidence closure"

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
