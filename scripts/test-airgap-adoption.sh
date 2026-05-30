#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
AIRGAP_REGISTRY="registry.example.internal/releases"
SURFACE_REPORT_FILE="operator-release-surface-report.json"
ADOPTION_REPORT_FILE="airgap-adoption-report.json"

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
BUNDLED_TOOL="$TMP_DIR/kubectl-local"
GOOD_PROBE="$TMP_DIR/tools/archive-digest-probe"
GOOD_LOADER="$TMP_DIR/tools/image-loader"
LOAD_LOG="$TMP_DIR/image-load.log"
KUBECTL_LOG="$TMP_DIR/kubectl.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"
SERVER_PORT=""
SERVER_LOG=""

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

function digest(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function subjectDigest(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return digest(JSON.stringify(stableJson(subject)));
}

function artifactProjectionDigest(value) {
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } =
    value.artifact_provenance;
  const projection = { ...value, artifact_provenance: artifactProvenance };
  return digest(JSON.stringify(stableJson(projection)));
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
  local profile="${2:-$AIRGAP_PROFILE}"

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
  truth.installation_id = 'kit-install-airgap-adoption-10001';
}

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_prerequisites() {
  local output="$1"
  local profile="${2:-$AIRGAP_PROFILE}"

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

create_payloads() {
  mkdir -p "$PAYLOAD_DIR" "$(dirname "$BUNDLED_TOOL")"
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
  printf '%s\n' 'bundled kubectl placeholder' >"$BUNDLED_TOOL"
}

create_image_archives() {
  mkdir -p "$IMAGE_DIR"
  "$NODE_BIN" --input-type=module - "$FIXTURE_CONTRACT" "$IMAGE_DIR" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [fixtureContract, imageDir] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(fixtureContract, 'utf8'));
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
  "$NODE_BIN" --input-type=module - "$OPERATOR_PREREQUISITES" "$BUNDLED_TOOL" <<'NODE'
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

write_airgap_apply_tools() {
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
}

write_fake_kubectl() {
  "$NODE_BIN" --input-type=module - "$FAKE_KUBECTL" <<'NODE'
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
    cat <<JSON
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"$live_image","imageID":"$live_image_id"}],"containerStatuses":[{"name":"web","image":"$live_image","imageID":"$live_image_id"}]}}]}
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

write_bundle_operator_inputs() {
  local bundle_root="$1"
  local profile="${2:-$AIRGAP_PROFILE}"

  mkdir -p "$bundle_root/operator-inputs"
  write_render_values "$bundle_root/operator-inputs/render-values.json"
  write_truth "$bundle_root/operator-inputs/substrate-truth.json" "$profile"
  write_prerequisites "$bundle_root/operator-inputs/target-prerequisites.json" "$profile"
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

start_server() {
  local ready_file="$TMP_DIR/server-ready"
  local stdout_file="$TMP_DIR/server.out"
  local stderr_file="$TMP_DIR/server.err"
  SERVER_LOG="$TMP_DIR/server-hits.log"

  "$NODE_BIN" --input-type=module - "$ready_file" "$SERVER_LOG" >"$stdout_file" 2>"$stderr_file" <<'NODE' &
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
      return
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$stdout_file" >&2 || true
      cat "$stderr_file" >&2 || true
      fail "smoke server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "smoke server did not become ready"
}

run_bundle_surface() {
  local bundle_root="$1"
  local output_dir="$2"
  shift 2

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
    --bundle-root "$bundle_root" \
    --output-dir "$output_dir" \
    "$@"
}

run_kit_bundle_surface() {
  local bundle_root="$1"
  local output_dir="$2"
  shift 2

  bash "$ROOT_DIR/scripts/operator-release.sh" airgap-bundle install_substrates \
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
    --substrate-pack-manifest "$KIT_AIRGAP_SUBSTRATE_PACK" \
    --bundle-root "$bundle_root" \
    --output-dir "$output_dir" \
    "$@"
}

run_consume_surface() {
  local bundle_root="$1"
  local output_dir="$2"
  local operator_run_id="$3"
  local smoke_url="$4"
  shift 4
  local target_app_image
  local smoke_args=()

  target_app_image="$(target_image_for_id "$bundle_root/components/image-map.json" agentsmith_app)"
  if [[ -n "$smoke_url" ]]; then
    smoke_args+=(--smoke-url "$smoke_url" --allow-http --allow-localhost)
  fi

  AGENTSMITH_LOAD_LOG="$LOAD_LOG" \
  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  FAKE_KUBECTL_LIVE_IMAGE="$target_app_image" \
  FAKE_KUBECTL_LIVE_IMAGE_ID="docker-pullable://$target_app_image" \
  bash "$ROOT_DIR/scripts/operator-release.sh" airgap use_existing \
    --bundle-root "$bundle_root" \
    --render-values "$bundle_root/operator-inputs/render-values.json" \
    --substrate-truth "$bundle_root/operator-inputs/substrate-truth.json" \
    --target-prerequisites "$bundle_root/operator-inputs/target-prerequisites.json" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply airgap/use_existing \
    --operator-run-id "$operator_run_id" \
    --timeout 120s \
    "${smoke_args[@]}" \
    "$@"
}

run_kit_consume_surface() {
  local bundle_root="$1"
  local output_dir="$2"
  local operator_run_id="$3"
  local smoke_url="$4"
  shift 4
  local target_app_image
  local smoke_args=()

  target_app_image="$(target_image_for_id "$bundle_root/components/image-map.json" agentsmith_app)"
  if [[ -n "$smoke_url" ]]; then
    smoke_args+=(--smoke-url "$smoke_url" --allow-http --allow-localhost)
  fi

  AGENTSMITH_LOAD_LOG="$LOAD_LOG" \
  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  FAKE_KUBECTL_LIVE_IMAGE="$target_app_image" \
  FAKE_KUBECTL_LIVE_IMAGE_ID="docker-pullable://$target_app_image" \
  bash "$ROOT_DIR/scripts/operator-release.sh" airgap install_substrates \
    --bundle-root "$bundle_root" \
    --render-values "$bundle_root/operator-inputs/render-values.json" \
    --substrate-truth "$bundle_root/operator-inputs/substrate-truth.json" \
    --target-prerequisites "$bundle_root/operator-inputs/target-prerequisites.json" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    --mode apply \
    --archive-probe "$GOOD_PROBE" \
    --image-loader "$GOOD_LOADER" \
    --confirm-apply airgap/install_substrates \
    --operator-run-id "$operator_run_id" \
    --timeout 120s \
    "${smoke_args[@]}" \
    "$@"
}

run_consume_surface_dry_run() {
  local bundle_root="$1"
  local output_dir="$2"

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
  bash "$ROOT_DIR/scripts/operator-release.sh" airgap use_existing \
    --bundle-root "$bundle_root" \
    --render-values "$bundle_root/operator-inputs/render-values.json" \
    --substrate-truth "$bundle_root/operator-inputs/substrate-truth.json" \
    --target-prerequisites "$bundle_root/operator-inputs/target-prerequisites.json" \
    --namespace agentsmith \
    --output-dir "$output_dir" \
    --kubectl "$FAKE_KUBECTL" \
    --mode server-dry-run
}

run_adoption() {
  local bundle_surface_report="$1"
  local consume_surface_report="$2"
  local bundle_manifest="$3"
  local output_dir="$4"
  local release_contract="${5:-$VALID_CONTRACT}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-adoption \
    --release-contract "$release_contract" \
    --bundle-surface-report "$bundle_surface_report" \
    --consume-surface-report "$consume_surface_report" \
    --bundle-manifest "$bundle_manifest" \
    --output-dir "$output_dir"
}

assert_adoption_report() {
  local report_file="$1"
  local expected_profile="${2:-$AIRGAP_PROFILE}"
  local expected_strategy="${3:-use_existing}"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_profile" "$expected_strategy" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedProfile, expectedStrategy] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const digestRe = /^sha256:[0-9a-f]{64}$/;
const allowedTopLevelKeys = new Set([
  'schema',
  'scope',
  'readiness',
  'status',
  'release',
  'release_contract_digest',
  'bundle_manifest_digest',
  'surface_report_digests',
  'producer_report_digests',
  'operator_paths',
  'target_registry_summary'
]);
const forbiddenKeys = new Set([
  'verdict',
  'release_verdict',
  'release_readiness',
  'package_readiness',
  'operator_verdict',
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
      throw new Error(`airgap adoption report included forbidden key: ${label}.${key}`);
    }
    assertNoForbiddenKeys(nested, `${label}.${key}`);
  }
}

if (report.schema !== 'agentsmith.airgap-adoption/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'airgap_adoption_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false || report.status !== 'pass') {
  throw new Error('adoption report must pass with readiness=false');
}
for (const key of Object.keys(report)) {
  if (!allowedTopLevelKeys.has(key)) {
    throw new Error(`unexpected adoption report key: ${key}`);
  }
}
assertNoForbiddenKeys(report);
if (!report.release || !report.release.release_id || !/^[0-9a-f]{40}$/.test(report.release.git_sha || '')) {
  throw new Error('adoption report must include release identity');
}
if (!digestRe.test(report.release_contract_digest || '')) {
  throw new Error('adoption report must include release contract digest');
}
if (!digestRe.test(report.bundle_manifest_digest || '')) {
  throw new Error('adoption report must include bundle manifest digest');
}
for (const digest of Object.values(report.surface_report_digests || {})) {
  if (!digestRe.test(digest)) {
    throw new Error('surface report digest is invalid');
  }
}
for (const group of Object.values(report.producer_report_digests || {})) {
  for (const digest of Object.values(group || {})) {
    if (!digestRe.test(digest)) {
      throw new Error('producer report digest is invalid');
    }
  }
}
const bundlePath = report.operator_paths?.find((item) => item.surface === 'airgap-bundle');
const consumePath = report.operator_paths?.find((item) => item.surface === 'airgap');
if (
  !bundlePath ||
  bundlePath.substrate_strategy !== expectedStrategy ||
  bundlePath.machine_profile !== expectedProfile
) {
  throw new Error('bundle operator path summary missing');
}
if (
  !consumePath ||
  consumePath.substrate_strategy !== expectedStrategy ||
  consumePath.machine_profile !== expectedProfile
) {
  throw new Error('consume operator path summary missing');
}
if (consumePath.mode !== 'apply' || consumePath.operator_run_id_present !== true) {
  throw new Error('consume path must prove confirmed apply with operator_run_id');
}
for (const requiredStep of ['airgap-image-load', 'airgap-bundle-render-check', 'apply', 'rollout', 'smoke']) {
  if (!consumePath.deployment_steps?.includes(requiredStep)) {
    throw new Error(`consume path missing deployment step: ${requiredStep}`);
  }
}
if (report.target_registry_summary?.host !== 'registry.example.internal') {
  throw new Error('target registry summary must use sanitized registry host');
}
if (/\/tmp\/|\/home\/|secretRef:|kubeconfig|Bearer|token\s*[:=]|password\s*[:=]|operator_identity|signature_uri/i.test(serialized)) {
  throw new Error('adoption report leaked paths, kubeconfig, signatures, identity, or secret-ish payloads');
}
NODE
}

expect_adoption_fail() {
  local label="$1"
  shift

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap adoption failure: $label"
  fi

  pass "airgap adoption rejected invalid case: $label"
}

ADOPTION_REGRESSION_FAILURES=()

record_adoption_regression_failure() {
  ADOPTION_REGRESSION_FAILURES+=("$*")
}

expect_adoption_fail_or_record() {
  local label="$1"
  shift

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    record_adoption_regression_failure "expected airgap adoption failure: $label"
    return
  fi

  pass "airgap adoption rejected invalid case: $label"
}

flush_adoption_regression_failures() {
  if [[ "${#ADOPTION_REGRESSION_FAILURES[@]}" -eq 0 ]]; then
    return
  fi

  printf 'FAIL: %s\n' "${ADOPTION_REGRESSION_FAILURES[@]}" >&2
  fail "airgap adoption regression guards failed"
}

mutate_bundle_check_manifest_digest() {
  local report_file="$1"
  local mismatched_digest="$2"
  local explicit_manifest_digest="$3"

  "$NODE_BIN" --input-type=module - \
    "$report_file" \
    "$mismatched_digest" \
    "$explicit_manifest_digest" <<'NODE'
import fs from 'node:fs';

const [reportFile, mismatchedDigest, explicitManifestDigest] = process.argv.slice(2);
if (mismatchedDigest === explicitManifestDigest) {
  throw new Error('mismatched digest fixture must differ from explicit manifest digest');
}
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (!report.artifacts?.bundle_manifest) {
  throw new Error('bundle-check report missing artifacts.bundle_manifest');
}
report.artifacts.bundle_manifest.input_sha256 = mismatchedDigest;
fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

update_surface_bundle_check_digest() {
  local surface_report="$1"
  local bundle_check_digest="$2"

  "$NODE_BIN" --input-type=module - \
    "$surface_report" \
    "$bundle_check_digest" <<'NODE'
import fs from 'node:fs';

const [surfaceReport, bundleCheckDigest] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(surfaceReport, 'utf8'));
if (!report.producer_report_digests || !report.airgap_handoff) {
  throw new Error('surface report missing producer digests or handoff');
}
report.producer_report_digests.airgap_bundle_check_report = bundleCheckDigest;
report.airgap_handoff.airgap_bundle_check_report_digest = bundleCheckDigest;
fs.writeFileSync(surfaceReport, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

update_bundle_surface_bundle_create_digest() {
  local surface_report="$1"
  local bundle_create_digest="$2"

  "$NODE_BIN" --input-type=module - \
    "$surface_report" \
    "$bundle_create_digest" <<'NODE'
import fs from 'node:fs';

const [surfaceReport, bundleCreateDigest] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(surfaceReport, 'utf8'));
if (!report.producer_report_digests) {
  throw new Error('bundle surface missing producer digests');
}
report.producer_report_digests.bundle_create_report = bundleCreateDigest;
fs.writeFileSync(surfaceReport, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

update_consume_report_bundle_check_digest() {
  local consume_report="$1"
  local bundle_check_digest="$2"

  "$NODE_BIN" --input-type=module - \
    "$consume_report" \
    "$bundle_check_digest" <<'NODE'
import fs from 'node:fs';

const [consumeReport, bundleCheckDigest] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(consumeReport, 'utf8'));
if (!report.producer_report_digests) {
  throw new Error('consume report missing producer_report_digests');
}
report.producer_report_digests.airgap_bundle_check_report = bundleCheckDigest;
fs.writeFileSync(consumeReport, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

update_consume_surface_digests() {
  local surface_report="$1"
  local bundle_check_digest="$2"
  local consume_report_digest="$3"

  "$NODE_BIN" --input-type=module - \
    "$surface_report" \
    "$bundle_check_digest" \
    "$consume_report_digest" <<'NODE'
import fs from 'node:fs';

const [surfaceReport, bundleCheckDigest, consumeReportDigest] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(surfaceReport, 'utf8'));
if (!report.producer_report_digests || !report.airgap_handoff) {
  throw new Error('consume surface missing producer digests or handoff');
}
report.producer_report_digests.airgap_bundle_check_report = bundleCheckDigest;
report.producer_report_digests.airgap_consume_rehearsal_report = consumeReportDigest;
report.airgap_handoff.airgap_bundle_check_report_digest = bundleCheckDigest;
fs.writeFileSync(surfaceReport, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

remove_bundle_create_substrate_pack_artifact() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (!report.artifacts?.substrate_pack_manifest) {
  throw new Error('bundle create report missing substrate_pack_manifest fixture');
}
delete report.artifacts.substrate_pack_manifest;
fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

remove_consume_substrate_pack_digest() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (!report.input_digests?.substrate_pack_manifest) {
  throw new Error('consume report missing substrate_pack_manifest fixture');
}
delete report.input_digests.substrate_pack_manifest;
fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

assert_no_stale_pass_adoption_report_or_record() {
  local report_file="$1"

  if [[ ! -e "$report_file" ]]; then
    pass "failed airgap adoption removed stale adoption report"
    return
  fi

  if ! "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
let report;
try {
  report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
} catch {
  process.exit(0);
}
if (
  report.schema === 'agentsmith.airgap-adoption/v1' &&
  report.scope === 'airgap_adoption_only' &&
  report.status === 'pass'
) {
  console.error('stale passing airgap adoption report remains');
  process.exit(1);
}
NODE
  then
    record_adoption_regression_failure "failed airgap adoption left stale pass report"
    return
  fi

  pass "failed airgap adoption did not leave stale pass report"
}

VALID_ARCHIVE="$TMP_DIR/agentsmith-deploy-template-package.tgz"
VALID_CONTRACT="$TMP_DIR/release-contract.valid-material.json"
VALID_PACKAGE="$TMP_DIR/deploy-template-package.valid-material.json"
VALID_VALUES="$TMP_DIR/render-values.valid.json"
VALID_TRUTH="$TMP_DIR/substrate-truth.airgap.json"
VALID_PREREQUISITES="$TMP_DIR/target-prerequisites.airgap.json"
KIT_AIRGAP_SUBSTRATE_PACK="$TMP_DIR/substrate-pack-manifest.kit-airgap.json"

manifest_sha="$(create_archive "$VALID_ARCHIVE")"
archive_sha="$(sha256_file "$VALID_ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha" "$VALID_CONTRACT" "$VALID_PACKAGE"
write_render_values "$VALID_VALUES"
write_truth "$VALID_TRUTH"
write_prerequisites "$VALID_PREREQUISITES"
create_payloads
create_image_archives
write_operator_prerequisites
write_kit_substrate_pack_manifest "$KIT_AIRGAP_SUBSTRATE_PACK" "$KIT_AIRGAP_PROFILE"
write_airgap_apply_tools
write_fake_kubectl
start_server

image_args=()
for id in "${RELEASE_IMAGE_IDS[@]}"; do
  image_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
done

bundle_output="$TMP_DIR/out-airgap-bundle"
bundle_root="$TMP_DIR/bundle-airgap-use-existing"
run_bundle_surface "$bundle_root" "$bundle_output" >"$TMP_DIR/airgap-bundle.out"
[[ -f "$bundle_output/$SURFACE_REPORT_FILE" ]] || fail "bundle operator surface report missing"
[[ -f "$bundle_root/airgap-bundle-manifest.json" ]] || fail "bundle manifest missing"

write_bundle_operator_inputs "$bundle_root"
consume_output="$TMP_DIR/out-airgap-consume"
: >"$LOAD_LOG"
: >"$KUBECTL_LOG"
run_consume_surface "$bundle_root" "$consume_output" operator-airgap-adoption-1001 "http://127.0.0.1:$SERVER_PORT/ok" >"$TMP_DIR/airgap-consume.out"
[[ -f "$consume_output/$SURFACE_REPORT_FILE" ]] || fail "consume operator surface report missing"

adoption_output="$TMP_DIR/out-airgap-adoption"
run_adoption \
  "$bundle_output/$SURFACE_REPORT_FILE" \
  "$consume_output/$SURFACE_REPORT_FILE" \
  "$bundle_root/airgap-bundle-manifest.json" \
  "$adoption_output" >"$TMP_DIR/airgap-adoption.out"
assert_adoption_report "$adoption_output/$ADOPTION_REPORT_FILE"
pass "airgap adoption aggregates bundle and consume operator surfaces"

kit_bundle_output="$TMP_DIR/out-airgap-bundle-install-substrates"
kit_bundle_root="$TMP_DIR/bundle-airgap-install-substrates"
run_kit_bundle_surface "$kit_bundle_root" "$kit_bundle_output" >"$TMP_DIR/kit-airgap-bundle.out"
[[ -f "$kit_bundle_output/$SURFACE_REPORT_FILE" ]] || fail "kit bundle operator surface report missing"
[[ -f "$kit_bundle_root/airgap-bundle-manifest.json" ]] || fail "kit bundle manifest missing"

write_bundle_operator_inputs "$kit_bundle_root" "$KIT_AIRGAP_PROFILE"
kit_consume_output="$TMP_DIR/out-airgap-consume-install-substrates"
: >"$LOAD_LOG"
: >"$KUBECTL_LOG"
run_kit_consume_surface "$kit_bundle_root" "$kit_consume_output" operator-airgap-adoption-kit-1002 "http://127.0.0.1:$SERVER_PORT/ok" >"$TMP_DIR/kit-airgap-consume.out"
[[ -f "$kit_consume_output/$SURFACE_REPORT_FILE" ]] || fail "kit consume operator surface report missing"

kit_adoption_output="$TMP_DIR/out-airgap-adoption-kit"
run_adoption \
  "$kit_bundle_output/$SURFACE_REPORT_FILE" \
  "$kit_consume_output/$SURFACE_REPORT_FILE" \
  "$kit_bundle_root/airgap-bundle-manifest.json" \
  "$kit_adoption_output" >"$TMP_DIR/kit-airgap-adoption.out"
assert_adoption_report "$kit_adoption_output/$ADOPTION_REPORT_FILE" "$KIT_AIRGAP_PROFILE" install_substrates
pass "kit airgap adoption aggregates bundle packaging and consume/deploy chain"

expect_adoption_fail kit-profile-mismatch \
  run_adoption \
    "$kit_bundle_output/$SURFACE_REPORT_FILE" \
    "$consume_output/$SURFACE_REPORT_FILE" \
    "$kit_bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-kit-profile-mismatch"

kit_missing_bundle_pack_output="$TMP_DIR/out-airgap-bundle-kit-missing-pack"
cp -R "$kit_bundle_output" "$kit_missing_bundle_pack_output"
remove_bundle_create_substrate_pack_artifact \
  "$kit_missing_bundle_pack_output/bundle-create-report.json"
kit_missing_bundle_create_digest="$(sha256_file "$kit_missing_bundle_pack_output/bundle-create-report.json")"
update_bundle_surface_bundle_create_digest \
  "$kit_missing_bundle_pack_output/$SURFACE_REPORT_FILE" \
  "$kit_missing_bundle_create_digest"
expect_adoption_fail kit-bundle-create-missing-substrate-pack \
  run_adoption \
    "$kit_missing_bundle_pack_output/$SURFACE_REPORT_FILE" \
    "$kit_consume_output/$SURFACE_REPORT_FILE" \
    "$kit_bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-kit-bundle-create-missing-pack"

kit_missing_consume_pack_output="$TMP_DIR/out-airgap-consume-kit-missing-pack"
cp -R "$kit_consume_output" "$kit_missing_consume_pack_output"
remove_consume_substrate_pack_digest \
  "$kit_missing_consume_pack_output/airgap-consume-rehearsal-report.json"
kit_consume_bundle_check_digest="$(sha256_file "$kit_missing_consume_pack_output/airgap-bundle-check/airgap-bundle-check-report.json")"
kit_missing_consume_report_digest="$(sha256_file "$kit_missing_consume_pack_output/airgap-consume-rehearsal-report.json")"
update_consume_surface_digests \
  "$kit_missing_consume_pack_output/$SURFACE_REPORT_FILE" \
  "$kit_consume_bundle_check_digest" \
  "$kit_missing_consume_report_digest"
expect_adoption_fail kit-consume-missing-substrate-pack \
  run_adoption \
    "$kit_bundle_output/$SURFACE_REPORT_FILE" \
    "$kit_missing_consume_pack_output/$SURFACE_REPORT_FILE" \
    "$kit_bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-kit-consume-missing-pack"

explicit_manifest_digest="$(sha256_file "$bundle_root/airgap-bundle-manifest.json")"
mismatched_manifest_digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

nested_mismatch_bundle_output="$TMP_DIR/out-airgap-bundle-nested-mismatch"
cp -R "$bundle_output" "$nested_mismatch_bundle_output"
mutate_bundle_check_manifest_digest \
  "$nested_mismatch_bundle_output/airgap-bundle-check-report.json" \
  "$mismatched_manifest_digest" \
  "$explicit_manifest_digest"
nested_bundle_check_digest="$(sha256_file "$nested_mismatch_bundle_output/airgap-bundle-check-report.json")"
update_surface_bundle_check_digest \
  "$nested_mismatch_bundle_output/$SURFACE_REPORT_FILE" \
  "$nested_bundle_check_digest"
expect_adoption_fail nested-bundle-check-manifest-digest-mismatch-bundle-surface \
  run_adoption \
    "$nested_mismatch_bundle_output/$SURFACE_REPORT_FILE" \
    "$consume_output/$SURFACE_REPORT_FILE" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-nested-bundle-surface-mismatch"

nested_mismatch_consume_output="$TMP_DIR/out-airgap-consume-nested-mismatch"
cp -R "$consume_output" "$nested_mismatch_consume_output"
mutate_bundle_check_manifest_digest \
  "$nested_mismatch_consume_output/airgap-bundle-check/airgap-bundle-check-report.json" \
  "$mismatched_manifest_digest" \
  "$explicit_manifest_digest"
nested_consume_check_digest="$(sha256_file "$nested_mismatch_consume_output/airgap-bundle-check/airgap-bundle-check-report.json")"
update_consume_report_bundle_check_digest \
  "$nested_mismatch_consume_output/airgap-consume-rehearsal-report.json" \
  "$nested_consume_check_digest"
nested_consume_report_digest="$(sha256_file "$nested_mismatch_consume_output/airgap-consume-rehearsal-report.json")"
update_consume_surface_digests \
  "$nested_mismatch_consume_output/$SURFACE_REPORT_FILE" \
  "$nested_consume_check_digest" \
  "$nested_consume_report_digest"
expect_adoption_fail nested-bundle-check-manifest-digest-mismatch-consume-surface \
  run_adoption \
    "$bundle_output/$SURFACE_REPORT_FILE" \
    "$nested_mismatch_consume_output/$SURFACE_REPORT_FILE" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-nested-consume-surface-mismatch"

dry_run_consume_output="$TMP_DIR/out-airgap-consume-dry-run"
: >"$KUBECTL_LOG"
run_consume_surface_dry_run "$bundle_root" "$dry_run_consume_output" >"$TMP_DIR/airgap-consume-dry-run.out"
expect_adoption_fail server-dry-run \
  run_adoption \
    "$bundle_output/$SURFACE_REPORT_FILE" \
    "$dry_run_consume_output/$SURFACE_REPORT_FILE" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-dry-run"

missing_smoke_consume_output="$TMP_DIR/out-airgap-consume-missing-smoke"
: >"$LOAD_LOG"
: >"$KUBECTL_LOG"
run_consume_surface "$bundle_root" "$missing_smoke_consume_output" operator-airgap-adoption-no-smoke "" >"$TMP_DIR/airgap-consume-missing-smoke.out"
expect_adoption_fail missing-smoke \
  run_adoption \
    "$bundle_output/$SURFACE_REPORT_FILE" \
    "$missing_smoke_consume_output/$SURFACE_REPORT_FILE" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-missing-smoke"

drifted_manifest="$TMP_DIR/airgap-bundle-manifest.drifted.json"
cp "$bundle_root/airgap-bundle-manifest.json" "$drifted_manifest"
"$NODE_BIN" --input-type=module - "$drifted_manifest" <<'NODE'
import fs from 'node:fs';

const [manifestFile] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
manifest.release_id = '2026.05.23-p0-drifted';
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
expect_adoption_fail bundle-manifest-digest-drift \
  run_adoption \
    "$bundle_output/$SURFACE_REPORT_FILE" \
    "$consume_output/$SURFACE_REPORT_FILE" \
    "$drifted_manifest" \
    "$TMP_DIR/out-adoption-manifest-drift"

stale_adoption_output="$TMP_DIR/out-adoption-stale-clear"
run_adoption \
  "$bundle_output/$SURFACE_REPORT_FILE" \
  "$consume_output/$SURFACE_REPORT_FILE" \
  "$bundle_root/airgap-bundle-manifest.json" \
  "$stale_adoption_output" >"$TMP_DIR/airgap-adoption-stale-pass.out"
assert_adoption_report "$stale_adoption_output/$ADOPTION_REPORT_FILE"
expect_adoption_fail_or_record stale-output-clear \
  run_adoption \
    "$bundle_output/$SURFACE_REPORT_FILE" \
    "$consume_output/$SURFACE_REPORT_FILE" \
    "$drifted_manifest" \
    "$stale_adoption_output"
assert_no_stale_pass_adoption_report_or_record \
  "$stale_adoption_output/$ADOPTION_REPORT_FILE"
flush_adoption_regression_failures

drifted_contract="$TMP_DIR/release-contract.digest-drift.json"
cp "$VALID_CONTRACT" "$drifted_contract"
printf '\n' >>"$drifted_contract"
expect_adoption_fail release-digest-mismatch \
  run_adoption \
    "$bundle_output/$SURFACE_REPORT_FILE" \
    "$consume_output/$SURFACE_REPORT_FILE" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$TMP_DIR/out-adoption-release-drift" \
    "$drifted_contract"

pass "airgap adoption focused tests completed"
