#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
EXTERNAL_ONLINE_PROFILE="existing_kubernetes/external_declared/online"
KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
REPORT_FILE="operator-release-surface-report.json"
AIRGAP_REGISTRY="registry.release.example/agentsmith"

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

write_render_values() {
  local output="$1"

  cat >"$output" <<'JSON'
{
  "namespace": "agentsmith",
  "replicas": 2
}
JSON
}

write_truth() {
  local output="$1"
  local profile="$2"

  "$NODE_BIN" --input-type=module - "$output" "$profile" <<'NODE'
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

if (substrateSource === 'kit_installed') {
  truth.installed_by = 'agentsmith-release-kit';
  truth.release_kit_version = '0.1.0';
  truth.installation_id = 'kit-install-10001';
}

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_prerequisites() {
  local output="$1"
  local profile="$2"

  "$NODE_BIN" --input-type=module - "$output" "$profile" <<'NODE'
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

write_evidence_provenance() {
  local output="$1"
  local operator_run_id="$2"

  "$NODE_BIN" --input-type=module - "$output" "$operator_run_id" <<'NODE'
import fs from 'node:fs';

const [output, operatorRunId] = process.argv.slice(2);

const provenance = {
  schema_version: 'agentsmith.artifact-provenance/v1',
  provenance_kind: 'signed_operator_run',
  producer_repo: 'github.com/agentsmith-project/agentsmith-release-kit',
  normalized_remote: 'github.com/agentsmith-project/agentsmith-release-kit',
  commit_sha: 'fedcba9876543210fedcba9876543210fedcba98',
  artifact_uri:
    `signed-operator-run://agentsmith-release-kit/evidence/${operatorRunId}/online-deployment-gate-evidence.tgz`,
  generated_at: '2026-05-23T12:00:00.000Z',
  generator_command: 'bash scripts/verify-release.sh --online-deployment-gate --evidence-root',
  generator_version: '0.1.0',
  attestation: 'none',
  operator_run_id: operatorRunId,
  operator_identity: 'release-operator@example.com',
  signature_uri: `https://signatures.example.com/agentsmith-release-kit/${operatorRunId}.sig`,
  signature_sha256: `sha256:${'a'.repeat(64)}`
};

fs.writeFileSync(output, `${JSON.stringify(provenance, null, 2)}\n`);
NODE
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

write_kit_substrate_pack_manifest() {
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

write_routability_probe() {
  local routability_probe="$1"

  "$NODE_BIN" --input-type=module - "$routability_probe" <<'NODE'
import fs from 'node:fs';

const [routabilityProbe] = process.argv.slice(2);
fs.writeFileSync(
  routabilityProbe,
  `#!/usr/bin/env bash
set -euo pipefail
: "\${ROUTABILITY_PROBE_LOG:?}"
printf '%s\\n' "$*" >> "$ROUTABILITY_PROBE_LOG"

expected=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --expected-fingerprint)
      expected="\${2:?expected fingerprint required}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$expected" ]] || exit 24
printf '%s\\n' "$expected"
`
);
fs.chmodSync(routabilityProbe, 0o755);
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
  response.end(url.pathname === '/ok' ? 'route ok' : 'not found');
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
      fail "operator surface smoke server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "operator surface smoke server did not become ready"
}

hit_count() {
  if [[ -f "$SERVER_LOG" ]]; then
    wc -l <"$SERVER_LOG" | tr -d '[:space:]'
    return
  fi
  echo 0
}

create_payloads() {
  local payload_dir="$1"
  local tool_file="$2"

  mkdir -p "$payload_dir"
  cat >"$payload_dir/runbook.md" <<'EOF_RUNBOOK'
# AgentSmith airgap runbook

Use the approved operator-held substrate and registry records.
EOF_RUNBOOK
  cat >"$payload_dir/install.sh" <<'EOF_SCRIPT'
#!/usr/bin/env sh
set -eu
printf '%s\n' "operator-reviewed local install placeholder"
EOF_SCRIPT
  chmod +x "$payload_dir/install.sh"
  cat >"$payload_dir/profile-values.schema.json" <<'JSON'
{
  "type": "object",
  "additionalProperties": false
}
JSON
  cat >"$payload_dir/profile-values.example.yaml" <<'YAML'
namespace: agentsmith
YAML
  printf '%s\n' 'bundled kubectl placeholder' >"$tool_file"
}

create_image_archives() {
  local image_dir="$1"

  mkdir -p "$image_dir"
  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    printf 'local oci layout tar placeholder for %s\n' "$id" >"$image_dir/$id.oci-layout.tar"
  done
}

write_operator_prerequisites() {
  local output="$1"
  local tool_file="$2"

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

assert_operator_report() {
  local output_dir="$1"
  local surface="$2"
  local strategy="$3"
  local machine_profile="$4"
  local expected_steps="$5"
  local expected_digest_keys="$6"
  local expect_airgap="${7:-false}"
  local expect_online_handoff="${8:-false}"

  "$NODE_BIN" --input-type=module - \
    "$output_dir/$REPORT_FILE" \
    "$output_dir" \
    "$surface" \
    "$strategy" \
    "$machine_profile" \
    "$expected_steps" \
    "$expected_digest_keys" \
    "$expect_airgap" \
    "$expect_online_handoff" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [
  reportFile,
  outputDir,
  surface,
  strategy,
  machineProfile,
  expectedStepsText,
  expectedDigestKeysText,
  expectAirgapText,
  expectOnlineHandoffText
] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedSteps = expectedStepsText.split(',');
const expectedDigestKeys = expectedDigestKeysText.split(',');
const expectAirgap = expectAirgapText === 'true';
const expectOnlineHandoff = expectOnlineHandoffText === 'true';
const allowedTopLevelKeys = new Set([
  'schema',
  'scope',
  'readiness',
  'status',
  'surface',
  'substrate_strategy',
  'machine_profile',
  'release_id',
  'git_sha',
  'release_contract_digest',
  'producer_report_digests',
  'steps',
  ...(expectAirgap ? ['airgap_handoff'] : []),
  ...(expectOnlineHandoff ? ['online_handoff'] : [])
]);
const forbiddenKeys = new Set([
  'verdict',
  'release_verdict',
  'deploy_readiness',
  'package_readiness',
  'offline_install_readiness',
  'ready'
]);

function assertNoForbiddenKeys(value, label = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoForbiddenKeys(item, `${label}[${index}]`));
    return;
  }
  for (const [key, nested] of Object.entries(value)) {
    if (forbiddenKeys.has(key)) {
      throw new Error(`operator summary must not include forbidden key: ${label}.${key}`);
    }
    assertNoForbiddenKeys(nested, `${label}.${key}`);
  }
}

if (report.schema !== 'agentsmith.operator-release-surface-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'operator_release_surface_v0') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('operator summary must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.surface !== surface) {
  throw new Error(`unexpected surface: ${report.surface}`);
}
if (report.substrate_strategy !== strategy) {
  throw new Error(`unexpected substrate strategy: ${report.substrate_strategy}`);
}
if (report.machine_profile !== machineProfile) {
  throw new Error(`unexpected machine profile: ${report.machine_profile}`);
}
if (!report.release_id || !/^[0-9a-f]{40}$/.test(report.git_sha || '')) {
  throw new Error('operator summary must include release identity');
}
if (!/^sha256:[0-9a-f]{64}$/.test(report.release_contract_digest || '')) {
  throw new Error('operator summary must include release contract digest');
}
for (const key of Object.keys(report)) {
  if (!allowedTopLevelKeys.has(key)) {
    throw new Error(`operator summary top-level field is not minimal: ${key}`);
  }
}
assertNoForbiddenKeys(report);
const actualDigestKeys = Object.keys(report.producer_report_digests || {}).sort();
if (JSON.stringify(actualDigestKeys) !== JSON.stringify([...expectedDigestKeys].sort())) {
  throw new Error(`unexpected producer digest keys: ${actualDigestKeys.join(',')}`);
}
for (const digest of Object.values(report.producer_report_digests || {})) {
  if (!/^sha256:[0-9a-f]{64}$/.test(digest)) {
    throw new Error('producer report digest is missing or invalid');
  }
}
if (!Array.isArray(report.steps) || report.steps.length !== expectedSteps.length) {
  throw new Error(`unexpected step count: ${report.steps?.length}`);
}
for (const [index, step] of report.steps.entries()) {
  if (step.name !== expectedSteps[index]) {
    throw new Error(`unexpected step at ${index}: ${step.name}`);
  }
  const keys = Object.keys(step).sort();
  if (JSON.stringify(keys) !== JSON.stringify(['name', 'report_paths'])) {
    throw new Error(`step must contain only name and report_paths: ${keys.join(',')}`);
  }
  if (!Array.isArray(step.report_paths) || step.report_paths.length < 1) {
    throw new Error(`step ${step.name} must list report paths`);
  }
  for (const reportPath of step.report_paths) {
    if (
      reportPath.startsWith('/') ||
      /^[A-Za-z]:[\\/]/.test(reportPath) ||
      reportPath.includes('\\') ||
      reportPath.split('/').some((part) => part === '' || part === '.' || part === '..')
    ) {
      throw new Error(`step ${step.name} has unsafe report path: ${reportPath}`);
    }
    const absolutePath = path.join(outputDir, reportPath);
    if (!fs.statSync(absolutePath).isFile()) {
      throw new Error(`step ${step.name} report path is not a file: ${reportPath}`);
    }
  }
}
if (expectAirgap) {
  const handoff = report.airgap_handoff;
  if (!handoff || typeof handoff !== 'object' || Array.isArray(handoff)) {
    throw new Error('airgap summary must include handoff digest/count summary');
  }
  for (const key of ['bundle_manifest_digest', 'airgap_bundle_check_report_digest']) {
    if (!/^sha256:[0-9a-f]{64}$/.test(handoff[key] || '')) {
      throw new Error(`airgap handoff missing digest: ${key}`);
    }
  }
  for (const key of ['image_count', 'payload_artifact_count', 'tool_count']) {
    if (!Number.isInteger(handoff[key]) || handoff[key] < 0) {
      throw new Error(`airgap handoff missing count: ${key}`);
    }
  }
  if (handoff.target_registry_summary?.host !== 'registry.release.example') {
    throw new Error('airgap handoff must include sanitized target registry host');
  }
}
if (expectOnlineHandoff) {
  const handoff = report.online_handoff;
  if (!handoff || typeof handoff !== 'object' || Array.isArray(handoff)) {
    throw new Error('online summary must include evidence handoff digest summary');
  }
  const expectedHandoffKeys = [
    'artifact_uri',
    'evidence_digest',
    'evidence_subject_digest',
    'online_deployment_gate_report_digest',
    'provenance_kind',
    'subject_sha256'
  ];
  const actualHandoffKeys = Object.keys(handoff).sort();
  if (JSON.stringify(actualHandoffKeys) !== JSON.stringify(expectedHandoffKeys.sort())) {
    throw new Error(`unexpected online handoff keys: ${actualHandoffKeys.join(',')}`);
  }
  for (const key of [
    'evidence_digest',
    'evidence_subject_digest',
    'online_deployment_gate_report_digest',
    'subject_sha256'
  ]) {
    if (!/^sha256:[0-9a-f]{64}$/.test(handoff[key] || '')) {
      throw new Error(`online handoff missing digest: ${key}`);
    }
  }
  if (handoff.provenance_kind !== 'signed_operator_run') {
    throw new Error(`unexpected online handoff provenance kind: ${handoff.provenance_kind}`);
  }
  if (!/^signed-operator-run:\/\/agentsmith-release-kit\/evidence\/operator-run-1003\//.test(handoff.artifact_uri || '')) {
    throw new Error('online handoff must include sanitized artifact uri');
  }
}
if (/\/tmp\/|\/home\/|secretRef:|operator held|operator workstation|signed operator prerequisite|kubeconfig|kubectl|probe|TOKEN|Bearer/i.test(serialized)) {
  throw new Error('operator summary leaked local paths, operator refs, tools, probes, or secret-ish payloads');
}
NODE
}

assert_producer_profile() {
  local report_file="$1"
  local expected_profile="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`producer report target profile drifted: ${report.target_profile?.value}`);
}
NODE
}

expect_operator_fail() {
  local label="$1"
  shift

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected operator surface failure: $label"
  fi

  pass "operator surface rejected invalid case: $label"
}

expect_operator_fail_preserves_summary() {
  local label="$1"
  local output_dir="$2"
  shift 2
  local sentinel='{"sentinel":"operator fail-fast should preserve existing summary"}'
  local producer_report

  mkdir -p "$output_dir"
  printf '%s' "$sentinel" >"$output_dir/$REPORT_FILE"

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected operator surface failure: $label"
  fi

  [[ -f "$output_dir/$REPORT_FILE" ]] || fail "invalid case removed existing operator summary: $label"
  [[ "$(<"$output_dir/$REPORT_FILE")" == "$sentinel" ]] ||
    fail "invalid case modified existing operator summary: $label"

  producer_report="$(find "$output_dir" -type f -name '*-report.json' ! -name "$REPORT_FILE" -print -quit)"
  [[ -z "$producer_report" ]] || fail "invalid case created producer report: $label: $producer_report"

  pass "operator surface rejected invalid case without side effects: $label"
}

VALID_ARCHIVE="$TMP_DIR/agentsmith-deploy-template-package.tgz"
VALID_CONTRACT="$TMP_DIR/release-contract.valid-material.json"
VALID_PACKAGE="$TMP_DIR/deploy-template-package.valid-material.json"
VALID_VALUES="$TMP_DIR/render-values.valid.json"
EXTERNAL_TRUTH="$TMP_DIR/substrate-truth.external-online.json"
KIT_TRUTH="$TMP_DIR/substrate-truth.kit-online.json"
EXTERNAL_PREREQUISITES="$TMP_DIR/target-prerequisites.external-online.json"
KIT_PREREQUISITES="$TMP_DIR/target-prerequisites.kit-online.json"
KIT_SUBSTRATE_PACK="$TMP_DIR/substrate-pack-manifest.kit-online.json"
FAKE_KUBECTL="$TMP_DIR/kubectl"
KUBECTL_LOG="$TMP_DIR/kubectl.log"
ROUTABILITY_PROBE="$TMP_DIR/routability-probe.sh"
ROUTABILITY_PROBE_LOG="$TMP_DIR/routability-probe.log"
PAYLOAD_DIR="$TMP_DIR/payload"
IMAGE_DIR="$TMP_DIR/image-archives"
BUNDLED_TOOL="$TMP_DIR/kubectl-local"
OPERATOR_PREREQUISITES="$TMP_DIR/operator-prerequisites.json"
VALID_PROVENANCE="$TMP_DIR/evidence-provenance.signed-operator-run.json"

manifest_sha="$(create_archive "$VALID_ARCHIVE")"
archive_sha="$(sha256_file "$VALID_ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha" "$VALID_CONTRACT" "$VALID_PACKAGE"
write_render_values "$VALID_VALUES"
write_truth "$EXTERNAL_TRUTH" "$EXTERNAL_ONLINE_PROFILE"
write_truth "$KIT_TRUTH" "$KIT_ONLINE_PROFILE"
write_prerequisites "$EXTERNAL_PREREQUISITES" "$EXTERNAL_ONLINE_PROFILE"
write_prerequisites "$KIT_PREREQUISITES" "$KIT_ONLINE_PROFILE"
write_kit_substrate_pack_manifest "$KIT_SUBSTRATE_PACK" "$KIT_ONLINE_PROFILE"
write_fake_kubectl "$FAKE_KUBECTL"
write_routability_probe "$ROUTABILITY_PROBE"
create_payloads "$PAYLOAD_DIR" "$BUNDLED_TOOL"
create_image_archives "$IMAGE_DIR"
write_operator_prerequisites "$OPERATOR_PREREQUISITES" "$BUNDLED_TOOL"
write_evidence_provenance "$VALID_PROVENANCE" operator-run-1003
: >"$KUBECTL_LOG"
: >"$ROUTABILITY_PROBE_LOG"
start_server
BASE_URL="http://127.0.0.1:$SERVER_PORT"

image_args=()
for id in "${RELEASE_IMAGE_IDS[@]}"; do
  image_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
done

external_online_output="$TMP_DIR/out-online-use-existing"
FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing \
  --release-contract "$VALID_CONTRACT" \
  --deploy-template-package "$VALID_PACKAGE" \
  --archive "$VALID_ARCHIVE" \
  --render-values "$VALID_VALUES" \
  --substrate-truth "$EXTERNAL_TRUTH" \
  --target-prerequisites "$EXTERNAL_PREREQUISITES" \
  --namespace agentsmith \
  --output-dir "$external_online_output" \
  --kubectl "$FAKE_KUBECTL" >"$TMP_DIR/online-use-existing.out"

[[ -f "$external_online_output/$REPORT_FILE" ]] || fail "operator online/use_existing summary missing"
assert_producer_profile "$external_online_output/online-deployment-gate-report.json" "$EXTERNAL_ONLINE_PROFILE"
assert_operator_report \
  "$external_online_output" \
  online \
  use_existing \
  "$EXTERNAL_ONLINE_PROFILE" \
  "inputs,target-preflight,template-package,render,render-check,apply" \
  "online_deployment_gate_report"
pass "operator online/use_existing maps to external-declared online producer gate"

external_online_apply_output="$TMP_DIR/out-online-use-existing-apply"
external_online_evidence_root="$TMP_DIR/evidence-online-use-existing-apply"
: >"$KUBECTL_LOG"
before_online_apply="$(hit_count)"
FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing \
  --release-contract "$VALID_CONTRACT" \
  --deploy-template-package "$VALID_PACKAGE" \
  --archive "$VALID_ARCHIVE" \
  --render-values "$VALID_VALUES" \
  --substrate-truth "$EXTERNAL_TRUTH" \
  --target-prerequisites "$EXTERNAL_PREREQUISITES" \
  --namespace agentsmith \
  --output-dir "$external_online_apply_output" \
  --kubectl "$FAKE_KUBECTL" \
  --mode apply \
  --confirm-apply online/use_existing \
  --operator-run-id operator-run-1003 \
  --timeout 120s \
  --smoke-url "$BASE_URL/ok" \
  --allow-http \
  --allow-localhost \
  --evidence-root "$external_online_evidence_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/online-use-existing-apply.out"
after_online_apply="$(hit_count)"

[[ "$after_online_apply" -eq $((before_online_apply + 1)) ]] || fail "operator online apply smoke should issue one request"
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "operator online apply must not dry-run confirmed apply"
fi
grep -q 'rollout status Deployment/agentsmith-web' "$KUBECTL_LOG" || fail "operator online apply did not call rollout"
grep -q 'get pods' "$KUBECTL_LOG" || fail "operator online apply did not check live pods"
[[ -f "$external_online_evidence_root/evidence.json" ]] || fail "operator online apply evidence missing evidence.json"
[[ -f "$external_online_evidence_root/evidence-subject.json" ]] || fail "operator online apply evidence missing evidence-subject.json"
[[ -f "$external_online_evidence_root/online-deployment-gate-report.json" ]] || fail "operator online apply evidence missing gate report"
assert_producer_profile "$external_online_apply_output/online-deployment-gate-report.json" "$EXTERNAL_ONLINE_PROFILE"
assert_operator_report \
  "$external_online_apply_output" \
  online \
  use_existing \
  "$EXTERNAL_ONLINE_PROFILE" \
  "inputs,target-preflight,template-package,render,render-check,apply,rollout,smoke" \
  "online_deployment_gate_report" \
  false \
  true
pass "operator online/use_existing confirmed apply accepts operator confirmation and writes handoff summary"

kit_online_output="$TMP_DIR/out-online-install-substrates"
: >"$KUBECTL_LOG"
: >"$ROUTABILITY_PROBE_LOG"
FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
ROUTABILITY_PROBE_LOG="$ROUTABILITY_PROBE_LOG" \
bash "$ROOT_DIR/scripts/operator-release.sh" online install_substrates \
  --release-contract "$VALID_CONTRACT" \
  --deploy-template-package "$VALID_PACKAGE" \
  --archive "$VALID_ARCHIVE" \
  --render-values "$VALID_VALUES" \
  --substrate-truth "$KIT_TRUTH" \
  --target-prerequisites "$KIT_PREREQUISITES" \
  --substrate-pack-manifest "$KIT_SUBSTRATE_PACK" \
  --routability-probe "$ROUTABILITY_PROBE" \
  --namespace agentsmith \
  --output-dir "$kit_online_output" \
  --kubectl "$FAKE_KUBECTL" >"$TMP_DIR/online-install-substrates.out"

[[ -s "$ROUTABILITY_PROBE_LOG" ]] || fail "kit online path did not call fake routability probe"
assert_producer_profile "$kit_online_output/online-deployment-gate-report.json" "$KIT_ONLINE_PROFILE"
assert_operator_report \
  "$kit_online_output" \
  online \
  install_substrates \
  "$KIT_ONLINE_PROFILE" \
  "inputs,target-preflight,substrate-pack-check,template-package,substrate-routability,render,render-check,apply" \
  "online_deployment_gate_report"
pass "operator online/install_substrates maps to kit-installed online producer gate"

airgap_output="$TMP_DIR/out-airgap-use-existing"
airgap_bundle_root="$TMP_DIR/bundle-airgap-use-existing"
bash "$ROOT_DIR/scripts/operator-release.sh" airgap-bundle use_existing \
  --release-contract "$VALID_CONTRACT" \
  --deploy-template-package "$VALID_PACKAGE" \
  --archive "$VALID_ARCHIVE" \
  --target-registry "$AIRGAP_REGISTRY" \
  "${image_args[@]}" \
  --runbook "$PAYLOAD_DIR/runbook.md" \
  --script "$PAYLOAD_DIR/install.sh" \
  --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json" \
  --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml" \
  --operator-prerequisites "$OPERATOR_PREREQUISITES" \
  --bundle-root "$airgap_bundle_root" \
  --output-dir "$airgap_output" >"$TMP_DIR/airgap-use-existing.out"

[[ -f "$airgap_output/$REPORT_FILE" ]] || fail "operator airgap-bundle/use_existing summary missing"
assert_producer_profile "$airgap_output/bundle-create-report.json" "$AIRGAP_PROFILE"
assert_operator_report \
  "$airgap_output" \
  airgap-bundle \
  use_existing \
  "$AIRGAP_PROFILE" \
  "bundle-create,airgap-bundle-check" \
  "airgap_bundle_check_report,bundle_create_report" \
  true
pass "operator airgap-bundle/use_existing maps to bundle-create and writes handoff summary"

unsupported_output="$TMP_DIR/out-airgap-install-substrates"
expect_operator_fail_preserves_summary airgap-install-substrates "$unsupported_output" \
  bash "$ROOT_DIR/scripts/operator-release.sh" airgap-bundle install_substrates \
    --output-dir "$unsupported_output"
[[ ! -e "$unsupported_output/bundle-create-report.json" ]] || fail "unsupported airgap install path called bundle-create"

target_profile_output="$TMP_DIR/out-target-profile"
expect_operator_fail_preserves_summary rejected-target-profile "$target_profile_output" \
  bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing \
    --target-profile "$EXTERNAL_ONLINE_PROFILE" \
    --output-dir "$target_profile_output"

raw_confirm_output="$TMP_DIR/out-raw-confirm-apply"
expect_operator_fail_preserves_summary raw-confirm-apply "$raw_confirm_output" \
  env FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_PACKAGE" \
    --archive "$VALID_ARCHIVE" \
    --render-values "$VALID_VALUES" \
    --substrate-truth "$EXTERNAL_TRUTH" \
    --target-prerequisites "$EXTERNAL_PREREQUISITES" \
    --namespace agentsmith \
    --output-dir "$raw_confirm_output" \
    --kubectl "$FAKE_KUBECTL" \
    --mode apply \
    --confirm-apply "$EXTERNAL_ONLINE_PROFILE" \
    --operator-run-id operator-run-raw

raw_confirm_equals_output="$TMP_DIR/out-raw-confirm-apply-equals"
expect_operator_fail_preserves_summary raw-confirm-apply-equals "$raw_confirm_equals_output" \
  env FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_PACKAGE" \
    --archive "$VALID_ARCHIVE" \
    --render-values "$VALID_VALUES" \
    --substrate-truth "$EXTERNAL_TRUTH" \
    --target-prerequisites "$EXTERNAL_PREREQUISITES" \
    --namespace agentsmith \
    --output-dir "$raw_confirm_equals_output" \
    --kubectl "$FAKE_KUBECTL" \
    --mode apply \
    --confirm-apply="$EXTERNAL_ONLINE_PROFILE" \
    --operator-run-id operator-run-raw-equals

missing_release_contract_output="$TMP_DIR/out-missing-release-contract"
expect_operator_fail_preserves_summary missing-release-contract "$missing_release_contract_output" \
  bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing \
    --output-dir "$missing_release_contract_output"

for vocabulary in \
  "--target-profile" \
  "external_declared" \
  "kit_installed" \
  "kind" \
  "local-kind" \
  "existing-cluster" \
  "existing_kubernetes/external_declared/online"; do
  expect_operator_fail "producer-vocabulary-${vocabulary//[^A-Za-z0-9]/-}" \
    bash "$ROOT_DIR/scripts/operator-release.sh" online use_existing "$vocabulary" \
      --output-dir "$TMP_DIR/out-producer-vocabulary"
done

unknown_surface_output="$TMP_DIR/out-unknown-surface"
expect_operator_fail_preserves_summary unknown-surface "$unknown_surface_output" \
  bash "$ROOT_DIR/scripts/operator-release.sh" deploy use_existing \
    --output-dir "$unknown_surface_output"
expect_operator_fail unknown-strategy \
  bash "$ROOT_DIR/scripts/operator-release.sh" online external_declared \
    --output-dir "$TMP_DIR/out-unknown-strategy"

pass "operator release surface v0 focused tests completed"
