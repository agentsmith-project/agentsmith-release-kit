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
REPORT_FILE="bundle-create-report.json"
CHECK_REPORT_FILE="airgap-bundle-check-report.json"
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
trap 'rm -rf "$TMP_DIR"' EXIT

VALID_CONTRACT="$TMP_DIR/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.valid.json"
VALID_ARCHIVE="$TMP_DIR/agentsmith-deploy-template-package.tgz"
PAYLOAD_DIR="$TMP_DIR/payload"
IMAGE_DIR="$TMP_DIR/image-archives"
OPERATOR_PREREQUISITES="$TMP_DIR/operator-prerequisites.json"
KIT_SUBSTRATE_PACK="$TMP_DIR/substrate-pack-manifest.kit-airgap.json"
KIT_SUBSTRATE_INSTALL_INPUTS="$TMP_DIR/substrate-install-inputs.kit-airgap.json"
VALID_PROVENANCE="$TMP_DIR/evidence-provenance.valid.json"

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

create_plain_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package"

  mkdir -p "$package_dir/templates"
  cat >"$package_dir/templates/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  replicas: 1
YAML
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": [
    {
      "path": "templates/deployment.yaml",
      "kind": "kubernetes"
    }
  ]
}
JSON

  tar -czf "$archive" -C "$package_dir" manifest.json templates/deployment.yaml
  sha256_file "$package_dir/manifest.json"
}

write_materials() {
  local manifest_sha="$1"
  local archive_sha="$2"

  "$NODE_BIN" --input-type=module - \
    "$FIXTURE_CONTRACT" \
    "$FIXTURE_DEPLOY_TEMPLATE_PACKAGE" \
    "$manifest_sha" \
    "$archive_sha" \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" <<'NODE'
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
  cat >"$PAYLOAD_DIR/profile-values.example.yaml" <<'YAML'
namespace: agentsmith
YAML
}

create_image_archives() {
  mkdir -p "$IMAGE_DIR"
  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    printf 'local oci layout tar placeholder for %s\n' "$id" >"$IMAGE_DIR/$id.oci-layout.tar"
  done
}

kit_image_args=()
kit_image_args_without_redis=()

create_substrate_image_archives() {
  local image_dir="$1"
  local substrate_pack_manifest="$2"
  local archive_args=()
  local archive_args_without_redis=()

  mkdir -p "$image_dir"
  while IFS= read -r id; do
    printf 'local oci layout tar placeholder for %s\n' "$id" >"$image_dir/$id.oci-layout.tar"
    archive_args+=(--image-archive "$id=$image_dir/$id.oci-layout.tar")
    if [[ "$id" != "substrate_redis" ]]; then
      archive_args_without_redis+=(--image-archive "$id=$image_dir/$id.oci-layout.tar")
    fi
  done < <("$NODE_BIN" --input-type=module - "$substrate_pack_manifest" <<'NODE'
import fs from 'node:fs';

const [substratePackManifest] = process.argv.slice(2);
const pack = JSON.parse(fs.readFileSync(substratePackManifest, 'utf8'));
for (const key of Object.keys(pack.images).sort()) {
  console.log(`substrate_${key}`);
}
NODE
)

  kit_image_args=("${archive_args[@]}")
  kit_image_args_without_redis=("${archive_args_without_redis[@]}")
}

write_operator_prerequisites() {
  local output="$1"
  local mutation="${2:-valid}"
  local tool_file="$TMP_DIR/kubectl-local"

  printf '%s\n' 'bundled kubectl placeholder' >"$tool_file"
  "$NODE_BIN" --input-type=module - "$output" "$mutation" "$tool_file" <<'NODE'
import fs from 'node:fs';

const [output, mutation, toolFile] = process.argv.slice(2);

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

switch (mutation) {
  case 'valid':
    break;
  case 'missing':
    delete prerequisites.substrate_connection_truth_ref;
    break;
  case 'tools_empty':
    prerequisites.tools = [];
    break;
  case 'embedded_url':
    prerequisites.target_registry_proof_ref = 'operator proof at https://example.invalid/proof';
    break;
  case 'download':
    prerequisites.tools[1].proof = 'operator proof says docker pull registry.invalid/skopeo:1.16';
    break;
  case 'secret_proof':
    prerequisites.tools[1].proof = 'Bearer abcdefghijklmnop';
    break;
  default:
    throw new Error(`unknown operator prerequisites mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

write_kit_substrate_pack_manifest() {
  local output="$1"
  local profile="$2"
  local mutation="${3:-valid}"
  local postgresql_digest
  local mongodb_digest
  local redis_digest
  local object_storage_digest
  local oidc_digest

  postgresql_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_postgresql)"
  mongodb_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_mongodb)"
  redis_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_redis)"
  object_storage_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_object_storage)"
  oidc_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_oidc)"

  "$NODE_BIN" --input-type=module - \
    "$output" \
    "$profile" \
    "$mutation" \
    "$postgresql_digest" \
    "$mongodb_digest" \
    "$redis_digest" \
    "$object_storage_digest" \
    "$oidc_digest" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  output,
  profile,
  mutation,
  postgresqlDigest,
  mongodbDigest,
  redisDigest,
  objectStorageDigest,
  oidcDigest
] = process.argv.slice(2);
const digest = (char) => `sha256:${char.repeat(64)}`;
const digestImage = (name, tag, digestValue) =>
  `ghcr.io/agentsmith-project/substrates/${name}:${tag}@${digestValue}`;
const packRoot = path.dirname(output);

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function writePackText(relativePath, content) {
  const file = path.join(packRoot, relativePath);
  const bytes = Buffer.from(content);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return digestBuffer(bytes);
}

function writePackJson(relativePath, value) {
  return writePackText(relativePath, `${JSON.stringify(value, null, 2)}\n`);
}

const payloadDigest = writePackJson('payload/install-substrates.json', {
  schema_version: 'agentsmith.substrate-install-plan.fixture/v1',
  installation_id: 'kit-install-10001',
  resources: ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc']
});
writePackText('templates/postgresql.yaml', 'kind: StatefulSet\nmetadata:\n  name: postgresql\n');
writePackText('templates/mongodb.yaml', 'kind: StatefulSet\nmetadata:\n  name: mongodb\n');
writePackText('templates/redis.yaml', 'kind: Deployment\nmetadata:\n  name: redis\n');
writePackText('templates/object-storage.yaml', 'kind: Deployment\nmetadata:\n  name: object-storage\n');
writePackText('templates/oidc.yaml', 'kind: Deployment\nmetadata:\n  name: oidc\n');
const resourceListDigest = writePackJson('templates/substrate-resources.json', [
  {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: {
      name: 'agentsmith-substrate-install-fixture',
      namespace: 'agentsmith',
      labels: {
        'app.kubernetes.io/managed-by': 'agentsmith-release-kit'
      },
      annotations: {
        'agentsmith.io/managed-by': 'agentsmith-release-kit',
        'agentsmith.io/installation-id': 'kit-install-10001'
      }
    },
    data: {
      target_profile: profile
    }
  }
]);
const probeDigest = writePackText(
  'tools/substrate-routability-probe.txt',
  'postgresql tls\nmongodb tls\nredis ping\nobject-storage head-bucket\noidc discovery\n'
);

const manifest = {
  schema_version: 'agentsmith.substrate-pack-manifest/v1',
  release_kit_version: '0.1.0',
  installed_by: 'agentsmith-release-kit',
  target_profile: profile,
  images: {
    postgresql: digestImage('postgresql', '16.3', postgresqlDigest),
    mongodb: digestImage('mongodb', '7.0', mongodbDigest),
    redis: digestImage('redis', '7.2', redisDigest),
    object_storage: digestImage('object-storage', '2026.05', objectStorageDigest),
    oidc: digestImage('keycloak', '25.0', oidcDigest)
  },
  payload: {
    install_plan: {
      path: 'payload/install-substrates.json',
      sha256: payloadDigest
    }
  },
  templates: {
    postgresql: 'templates/postgresql.yaml',
    mongodb: 'templates/mongodb.yaml',
    redis: 'templates/redis.yaml',
    object_storage: 'templates/object-storage.yaml',
    oidc: 'templates/oidc.yaml',
    resource_list: {
      path: 'templates/substrate-resources.json',
      sha256: resourceListDigest
    }
  },
  tools: {
    routability_probe: {
      path: 'tools/substrate-routability-probe.txt',
      sha256: probeDigest
    }
  },
  checksums: {
    manifest: digest('8')
  }
};

switch (mutation) {
  case 'valid':
    break;
  case 'secret_payload':
    manifest.payload.access_token = 'Bearer notrealcredential12345';
    break;
  case 'non_digest_image':
    manifest.images.redis = 'ghcr.io/agentsmith-project/substrates/redis:7.2';
    break;
  case 'localhost_image':
    manifest.images.postgresql = 'localhost:5000/substrates/postgresql:16.3@' + digest('1');
    break;
  case 'missing_required_section':
    delete manifest.tools;
    break;
  case 'missing_material_file':
    fs.rmSync(path.join(packRoot, 'payload/install-substrates.json'));
    break;
  case 'material_sha_mismatch':
    manifest.payload.install_plan.sha256 = digest('6');
    break;
  default:
    throw new Error(`unknown substrate pack mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

write_kit_substrate_install_inputs() {
  local output="$1"
  local profile="$2"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$output" "$profile" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [output, profileValue, mutation] = process.argv.slice(2);
const [targetCluster, substrateSource, distribution] = profileValue.split('/');
const resourceListPath = mutation === 'missing_resource_list'
  ? 'templates/missing-substrate-resources.json'
  : 'templates/substrate-resources.json';
const installProfileValue = mutation === 'target_profile_mismatch'
  ? 'existing_kubernetes/kit_installed/online'
  : profileValue;
const [installTargetCluster, installSubstrateSource, installDistribution] =
  installProfileValue.split('/');
const installationId = 'kit-install-10001';
const truthInstallationId = mutation === 'installation_id_mismatch'
  ? 'kit-install-10002'
  : installationId;
const reachability = {
  status: 'declared_reachable',
  proof: 'operator fixture declared reachable'
};
const substrateTruth = {
  schema_version: 'agentsmith.substrate-connection.truth/v1',
  redacted_fingerprint: `sha256:${'a'.repeat(64)}`,
  target_cluster: installTargetCluster,
  substrate_source: installSubstrateSource,
  distribution: installDistribution,
  declared_at: '2026-06-10T12:00:00.000Z',
  declared_by: 'release-operator@example.com',
  installed_by: 'agentsmith-release-kit',
  release_kit_version: '0.1.0',
  installation_id: truthInstallationId,
  services: {
    postgresql: {
      host: 'postgresql.agentsmith.svc',
      port: 5432,
      database: 'agentsmith',
      credential_secret_ref: 'secretRef:agentsmith/postgresql-app',
      admin_secret_ref: 'secretRef:agentsmith/postgresql-admin',
      sslmode: 'verify-full',
      reachability,
      extensions: {
        pgvector: {
          status: 'installed',
          version: '0.7.4'
        }
      }
    },
    mongodb: {
      host: 'mongodb.agentsmith.svc',
      port: 27017,
      credential_secret_ref: 'secretRef:agentsmith/mongodb-app',
      tls: { mode: 'verify-full' },
      reachability
    },
    redis: {
      host: 'redis.agentsmith.svc',
      port: 6379,
      credential_secret_ref: 'secretRef:agentsmith/redis-app',
      tls: { mode: 'verify-full' },
      reachability
    },
    object_storage: {
      url: 'https://objects.agentsmith.example.com',
      bucket: 'agentsmith-release-artifacts',
      region: 'us-west-2',
      credential_secret_ref: 'secretRef:agentsmith/object-storage-app',
      tls: { mode: 'https' },
      reachability
    },
    oidc: {
      issuer_url: 'https://oidc.agentsmith.example.com/realms/agentsmith',
      client_id: 'agentsmith-web',
      client_secret_ref: 'secretRef:agentsmith/oidc-client',
      tls: { mode: 'https' },
      reachability
    }
  }
};
const installInputs = {
  schema_version: 'agentsmith.substrate-install-inputs/v1',
  target_profile: installProfileValue,
  installation_id: installationId,
  substrate_truth: substrateTruth,
  resource_list_path: resourceListPath
};

fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, `${JSON.stringify(installInputs, null, 2)}\n`);
NODE
}

write_evidence_provenance() {
  local output="$1"

  "$NODE_BIN" --input-type=module - "$output" <<'NODE'
import fs from 'node:fs';

const [output] = process.argv.slice(2);
const provenance = {
  schema_version: 'agentsmith.artifact-provenance/v1',
  provenance_kind: 'ci_artifact',
  producer_repo: 'github.com/agentsmith-project/agentsmith-release-kit',
  normalized_remote: 'github.com/agentsmith-project/agentsmith-release-kit',
  commit_sha: 'fedcba9876543210fedcba9876543210fedcba98',
  artifact_uri: 'gh-artifact://agentsmith-release-kit/evidence/20001/airgap-bundle-evidence.tgz',
  generated_at: '2026-05-23T12:00:00.000Z',
  generator_command: 'bash scripts/verify-release.sh --bundle-create --evidence-root',
  generator_version: '0.1.0',
  attestation: 'none',
  workflow_name: 'release-kit-focused-evidence',
  run_id: '20001',
  run_attempt: '1',
  job: 'bundle-create'
};

fs.writeFileSync(output, `${JSON.stringify(provenance, null, 2)}\n`);
NODE
}

common_payload_args=()
default_image_args=()

refresh_args() {
  common_payload_args=(
    --runbook "$PAYLOAD_DIR/runbook.md"
    --script "$PAYLOAD_DIR/install.sh"
    --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json"
    --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml"
    --operator-prerequisites "$OPERATOR_PREREQUISITES"
  )
  default_image_args=(
  )
  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    default_image_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
  done
}

run_bundle_create_full() {
  local target_profile="$1"
  local target_registry="$2"
  local bundle_root="$3"
  local output_dir="$4"
  shift 4

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    --archive "$VALID_ARCHIVE" \
    --target-profile "$target_profile" \
    --target-registry "$target_registry" \
    --bundle-root "$bundle_root" \
    --output-dir "$output_dir" \
    "$@"
}

run_bundle_create() {
  local bundle_root="$1"
  local output_dir="$2"

  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$bundle_root" "$output_dir" \
    "${default_image_args[@]}" \
    "${common_payload_args[@]}"
}

run_airgap_bundle_check() {
  local bundle_root="$1"
  local output_dir="$2"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-bundle-check \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    --archive "$VALID_ARCHIVE" \
    --image-map "$bundle_root/components/image-map.json" \
    --target-profile "$AIRGAP_PROFILE" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_root/airgap-bundle-manifest.json" \
    --output-dir "$output_dir"
}

assert_no_create_report() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "unexpected bundle create report exists: $output_dir/$REPORT_FILE"
}

assert_no_self_check_report() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$CHECK_REPORT_FILE" ]] || fail "unexpected self-check report exists: $output_dir/$CHECK_REPORT_FILE"
}

write_stale_reports() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
  printf '%s\n' '{"stale":true}' >"$output_dir/$CHECK_REPORT_FILE"
}

write_stale_evidence_outputs() {
  local evidence_root="$1"
  local label="${2:-stale}"
  mkdir -p "$evidence_root"
  for evidence_file in \
    evidence.json \
    evidence-subject.json \
    airgap-bundle-check-report.json \
    airgap-bundle-manifest.json \
    image-map.json; do
    printf '{"stale":"%s:%s"}\n' "$label" "$evidence_file" >"$evidence_root/$evidence_file"
  done
}

assert_stale_evidence_outputs() {
  local evidence_root="$1"
  local label="$2"
  for evidence_file in \
    evidence.json \
    evidence-subject.json \
    airgap-bundle-check-report.json \
    airgap-bundle-manifest.json \
    image-map.json; do
    grep -q "\"stale\":\"$label:$evidence_file\"" "$evidence_root/$evidence_file" || \
      fail "early evidence validation failure modified stale evidence file: $evidence_root/$evidence_file"
  done
}

assert_bundle_and_report() {
  local bundle_root="$1"
  local output_dir="$2"

  "$NODE_BIN" --input-type=module - "$bundle_root" "$output_dir/$REPORT_FILE" "$output_dir/$CHECK_REPORT_FILE" "$VALID_CONTRACT" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, reportFile, checkReportFile, validContract] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const checkReport = JSON.parse(fs.readFileSync(checkReportFile, 'utf8'));
const manifest = JSON.parse(
  fs.readFileSync(path.join(bundleRoot, 'airgap-bundle-manifest.json'), 'utf8')
);
const serializedReport = JSON.stringify(report);
const expectedImageIds = JSON.parse(
  fs.readFileSync(validContract, 'utf8')
).deploy_image_inventory.map((item) => item.id);

function assertFile(relativePath) {
  const file = path.join(bundleRoot, relativePath);
  if (!fs.statSync(file).isFile()) {
    throw new Error(`expected bundle file: ${relativePath}`);
  }
}

function assertNoLeakKeys(value, label = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoLeakKeys(item, `${label}[${index}]`));
    return;
  }
  for (const [key, item] of Object.entries(value)) {
    if (
      key === 'path' ||
      key === 'location' ||
      key === 'proof' ||
      key.endsWith('_ref') ||
      key === 'bundle_root' ||
      key === 'bundleRoot'
    ) {
      throw new Error(`bundle create report must not include leak-prone key: ${label}.${key}`);
    }
    assertNoLeakKeys(item, `${label}.${key}`);
  }
}

for (const relativePath of [
  'components/release-contract.json',
  'components/deploy-template-package.json',
  'components/agentsmith-deploy-template-package.tgz',
  'components/image-map.json',
  ...expectedImageIds.map((id) => `images/${id}.oci-layout.tar`),
  'payload/runbook.md',
  'payload/install.sh',
  'payload/profile-values.schema.json',
  'payload/profile-values.example.yaml',
  'payload/checksums.txt',
  'tools/kubectl'
]) {
  assertFile(relativePath);
}

if (report.schema !== 'agentsmith.airgap-bundle-create-report/v1') {
  throw new Error(`unexpected create report schema: ${report.schema}`);
}
if (report.scope !== 'airgap_bundle_create_only') {
  throw new Error(`unexpected create report scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('bundle create report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected create report status: ${report.status}`);
}
if (report.target_profile?.value !== 'existing_kubernetes/external_declared/airgap') {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (checkReport.schema !== 'agentsmith.airgap-bundle-check-report/v1') {
  throw new Error(`unexpected self-check schema: ${checkReport.schema}`);
}
if (checkReport.readiness !== false) {
  throw new Error('self-check report must keep readiness=false');
}
if (manifest.schema_version !== 'agentsmith.airgap-bundle-manifest/v1') {
  throw new Error(`unexpected bundle manifest schema: ${manifest.schema_version}`);
}
if (
  Object.prototype.hasOwnProperty.call(manifest, 'target_profile') ||
  Object.prototype.hasOwnProperty.call(manifest, 'substrate')
) {
  throw new Error('bundle manifest must derive target/substrate identity from the selected path');
}
if (manifest.image_artifact_declarations?.length !== expectedImageIds.length) {
  throw new Error('bundle manifest must declare all fixture image archives');
}
const imageIds = manifest.image_artifact_declarations.map((item) => item.id);
if (JSON.stringify(imageIds) !== JSON.stringify(expectedImageIds)) {
  throw new Error(`bundle manifest must declare release contract image ids: ${imageIds.join(',')}`);
}
if (manifest.operator_prerequisites?.tools?.length !== 2) {
  throw new Error('bundle manifest must include bundled and operator prerequisite tools');
}
if (report.components_count !== 4) {
  throw new Error(`unexpected component count: ${report.components_count}`);
}
if (report.image_artifact_count !== expectedImageIds.length) {
  throw new Error(`unexpected image artifact count: ${report.image_artifact_count}`);
}
if (report.payload_artifact_count !== 5) {
  throw new Error(`unexpected payload artifact count: ${report.payload_artifact_count}`);
}
if (report.tool_count !== 2 || report.bundled_tool_count !== 1) {
  throw new Error('unexpected tool counts in create report');
}
assertNoLeakKeys(report);
for (const digest of [
  report.artifacts?.release_contract?.input_sha256,
  report.artifacts?.deploy_template_package?.input_sha256,
  report.artifacts?.deploy_template_package?.package_sha256,
  report.artifacts?.deploy_template_package?.manifest_sha256,
  report.artifacts?.deploy_template_archive?.input_sha256,
  report.artifacts?.image_map?.input_sha256,
  report.artifacts?.bundle_manifest?.input_sha256,
  report.artifacts?.airgap_bundle_check_report?.input_sha256,
  report.artifacts?.bundle_checksums?.input_sha256
]) {
  if (typeof digest !== 'string' || !digest.startsWith('sha256:')) {
    throw new Error('create report digest summary is missing');
  }
}
if (
  /\b(?:release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|registry_presence|image_load|docker|skopeo|oras|kubectl|pull|push|mirror|save|load)\b/.test(
    serializedReport
  )
) {
  throw new Error('bundle create report must not claim readiness or tool execution proofs');
}
if (/payload\/|tools\/|operator held|operator workstation|signed operator prerequisite|\/tmp\//.test(serializedReport)) {
  throw new Error('bundle create report must not leak paths or operator refs');
}
NODE
}

assert_airgap_bundle_evidence() {
  local evidence_root="$1"
  local expected_profile="${2:-$AIRGAP_PROFILE}"
  local substrate_pack_manifest="${3:-}"

  "$NODE_BIN" --input-type=module - \
    "$evidence_root" \
    "$VALID_CONTRACT" \
    "$expected_profile" \
    "$substrate_pack_manifest" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [evidenceRoot, validContract, expectedProfile, substratePackManifest] =
  process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(validContract, 'utf8'));
const [expectedTargetCluster, expectedSubstrateSource, expectedDistribution] =
  expectedProfile.split('/');
const expectedFiles = [
  'evidence.json',
  'evidence-subject.json',
  'airgap-bundle-check-report.json',
  'airgap-bundle-manifest.json',
  'image-map.json'
];
if (expectedSubstrateSource === 'kit_installed') {
  expectedFiles.push('substrate-pack-manifest.json');
}

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

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function canonicalDigest(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(evidenceRoot, relativePath), 'utf8'));
}

for (const relativePath of expectedFiles) {
  if (!fs.statSync(path.join(evidenceRoot, relativePath)).isFile()) {
    throw new Error(`missing evidence file: ${relativePath}`);
  }
}

const serializedEvidenceRoot = expectedFiles
  .map((relativePath) => fs.readFileSync(path.join(evidenceRoot, relativePath), 'utf8'))
  .join('\n');
if (/"(?:signature_uri|operator_identity|formal_verdict)"\s*:/.test(serializedEvidenceRoot)) {
  throw new Error('unsigned bundle evidence must not contain signature, operator identity, or formal verdict fields');
}
if (/"readiness"\s*:\s*true/.test(serializedEvidenceRoot)) {
  throw new Error('bundle evidence outputs must not contain readiness=true');
}

const evidence = readJson('evidence.json');
const subject = readJson('evidence-subject.json');
const checkReport = readJson('airgap-bundle-check-report.json');
const manifest = readJson('airgap-bundle-manifest.json');
const imageMap = readJson('image-map.json');
const evidenceProjection = { ...evidence };
delete evidenceProjection.artifact_provenance;
const subjectPaths = subject.files.map((file) => file.path).sort();
const expectedSubjectPaths = expectedFiles.filter((file) => file !== 'evidence-subject.json').sort();

if (evidence.schema_version !== 'agentsmith.release-kit-evidence-envelope/v1') {
  throw new Error(`unexpected evidence schema: ${evidence.schema_version}`);
}
if (evidence.release_kit_output !== 'airgap_bundle_check') {
  throw new Error(`unexpected evidence output: ${evidence.release_kit_output}`);
}
if (
  evidence.target_cluster !== expectedTargetCluster ||
  evidence.substrate_source !== expectedSubstrateSource ||
  evidence.distribution !== expectedDistribution
) {
  throw new Error(`evidence target profile must be ${expectedProfile}`);
}
if (Object.prototype.hasOwnProperty.call(evidence, 'substrate_connection_truth')) {
  throw new Error('bundle-create evidence must not include inline substrate connection truth');
}
if (evidence.release_id !== contract.release_id || evidence.git_sha !== contract.git_sha) {
  throw new Error('evidence release identity must match release contract');
}
if (evidence.artifact_provenance?.provenance_kind !== 'ci_artifact') {
  throw new Error('bundle-create evidence must be unsigned ci_artifact provenance');
}
if (JSON.stringify(subjectPaths) !== JSON.stringify(expectedSubjectPaths)) {
  throw new Error(`unexpected evidence subject files: ${subjectPaths.join(',')}`);
}
const evidenceSubjectEntry = subject.files.find((file) => file.path === 'evidence.json');
if (evidenceSubjectEntry.sha256 !== canonicalDigest(evidenceProjection)) {
  throw new Error('evidence subject must bind canonical evidence projection');
}
if (evidence.artifact_provenance.subject_sha256 !== canonicalDigest(subject)) {
  throw new Error('artifact provenance must bind evidence-subject canonical digest');
}
for (const relativePath of expectedSubjectPaths.filter((file) => file !== 'evidence.json')) {
  const entry = subject.files.find((file) => file.path === relativePath);
  const actual = digestBuffer(fs.readFileSync(path.join(evidenceRoot, relativePath)));
  if (entry.sha256 !== actual) {
    throw new Error(`subject digest mismatch for ${relativePath}`);
  }
}
if (checkReport.readiness !== false || imageMap.readiness !== false) {
  throw new Error('focused bundle evidence reports must keep readiness=false');
}
if (checkReport.target_profile?.value !== expectedProfile) {
  throw new Error(`bundle check evidence target profile must be ${expectedProfile}`);
}
if (
  Object.prototype.hasOwnProperty.call(manifest, 'target_profile') ||
  Object.prototype.hasOwnProperty.call(manifest, 'substrate')
) {
  throw new Error('bundle manifest must derive target/substrate identity from the selected path');
}
const packComponent = manifest.components.find((component) => (
  component.kind === 'substrate_pack_manifest'
));
if (expectedSubstrateSource === 'kit_installed') {
  if (!substratePackManifest) {
    throw new Error('kit evidence assertion requires substrate pack manifest input');
  }
  const packDigest = digestBuffer(fs.readFileSync(substratePackManifest));
  if (!packComponent || packComponent.path !== 'components/substrate-pack-manifest.json') {
    throw new Error('kit bundle evidence must include substrate pack manifest component');
  }
  if (packComponent.sha256 !== packDigest) {
    throw new Error('kit bundle evidence substrate pack component digest mismatch');
  }
  if (manifest.bindings?.substrate_pack_manifest_sha256 !== packDigest) {
    throw new Error('kit bundle evidence substrate pack binding digest mismatch');
  }
} else if (packComponent || manifest.bindings?.substrate_pack_manifest_sha256) {
  throw new Error('external bundle evidence must not include substrate pack binding');
}
NODE
}

assert_kit_bundle_and_report() {
  local bundle_root="$1"
  local output_dir="$2"
  local substrate_pack_manifest="$3"
  local substrate_install_inputs="$4"

  "$NODE_BIN" --input-type=module - \
    "$bundle_root" \
    "$output_dir/$REPORT_FILE" \
    "$output_dir/$CHECK_REPORT_FILE" \
    "$substrate_pack_manifest" \
    "$substrate_install_inputs" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, reportFile, checkReportFile, substratePackManifest, substrateInstallInputs] =
  process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const checkReport = JSON.parse(fs.readFileSync(checkReportFile, 'utf8'));
const manifest = JSON.parse(
  fs.readFileSync(path.join(bundleRoot, 'airgap-bundle-manifest.json'), 'utf8')
);
const packDigest =
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(substratePackManifest)).digest('hex')}`;
const bundledPackDigest =
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(bundleRoot, 'components/substrate-pack-manifest.json'))).digest('hex')}`;
const installInputsDigest =
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(substrateInstallInputs)).digest('hex')}`;
const bundledInstallInputsPath = path.join(
  bundleRoot,
  'components/substrate-install-inputs.json'
);
const bundledInstallInputsDigest =
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(bundledInstallInputsPath)).digest('hex')}`;
const packComponent = manifest.components.find((component) => (
  component.kind === 'substrate_pack_manifest'
));
const installInputsComponent = manifest.components.find((component) => (
  component.kind === 'substrate_install_inputs'
));
const substratePack = JSON.parse(fs.readFileSync(substratePackManifest, 'utf8'));
const installInputs = JSON.parse(fs.readFileSync(substrateInstallInputs, 'utf8'));
const expectedSubstrateDeclarations = Object.keys(substratePack.images)
  .sort()
  .map((key) => {
    const image = substratePack.images[key];
    const digest = image.slice(image.lastIndexOf('@') + 1);
    return {
      id: `substrate_${key}`,
      image,
      digest
    };
  });
const materialPaths = new Set();

function collectMaterialPaths(value) {
  if (typeof value === 'string') {
    if (!value.startsWith('sha256:')) {
      materialPaths.add(value);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach(collectMaterialPaths);
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  if (
    typeof value.path === 'string' &&
    typeof value.sha256 === 'string'
  ) {
    materialPaths.add(value.path);
    for (const [key, nested] of Object.entries(value)) {
      if (key !== 'path' && key !== 'sha256') {
        collectMaterialPaths(nested);
      }
    }
    return;
  }
  Object.values(value).forEach(collectMaterialPaths);
}

for (const section of ['payload', 'templates', 'tools', 'checksums']) {
  collectMaterialPaths(substratePack[section]);
}

function fileDigest(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

if (report.target_profile?.value !== 'existing_kubernetes/kit_installed/airgap') {
  throw new Error(`unexpected kit create target profile: ${report.target_profile?.value}`);
}
if (checkReport.target_profile?.value !== 'existing_kubernetes/kit_installed/airgap') {
  throw new Error(`unexpected kit bundle-check target profile: ${checkReport.target_profile?.value}`);
}
if (
  Object.prototype.hasOwnProperty.call(manifest, 'target_profile') ||
  Object.prototype.hasOwnProperty.call(manifest, 'substrate')
) {
  throw new Error('kit airgap manifest must derive target/substrate identity from the selected path');
}
if (!packComponent) {
  throw new Error('kit airgap manifest must include substrate_pack_manifest component');
}
if (packComponent.path !== 'components/substrate-pack-manifest.json') {
  throw new Error(`unexpected substrate pack component path: ${packComponent.path}`);
}
if (packComponent.sha256 !== packDigest || bundledPackDigest !== packDigest) {
  throw new Error('substrate pack component sha must bind to input and bundled file');
}
if (manifest.bindings?.substrate_pack_manifest_sha256 !== packDigest) {
  throw new Error('substrate pack binding digest must match input manifest digest');
}
if (!installInputsComponent) {
  throw new Error('kit airgap manifest must include substrate_install_inputs component');
}
if (installInputsComponent.path !== 'components/substrate-install-inputs.json') {
  throw new Error(`unexpected substrate install inputs component path: ${installInputsComponent.path}`);
}
if (
  installInputsComponent.sha256 !== installInputsDigest ||
  bundledInstallInputsDigest !== installInputsDigest
) {
  throw new Error('substrate install inputs component sha must bind to input and bundled file');
}
if (manifest.bindings?.substrate_install_inputs_sha256 !== installInputsDigest) {
  throw new Error('substrate install inputs binding digest must match input digest');
}
if (installInputs.resource_list_path) {
  const sourceResourceList = path.join(path.dirname(substratePackManifest), installInputs.resource_list_path);
  const bundledResourceList = path.join(bundleRoot, 'components', installInputs.resource_list_path);
  if (!fs.statSync(bundledResourceList).isFile()) {
    throw new Error(`missing bundled substrate install resource list: ${installInputs.resource_list_path}`);
  }
  if (fileDigest(sourceResourceList) !== fileDigest(bundledResourceList)) {
    throw new Error(`bundled substrate install resource list digest mismatch: ${installInputs.resource_list_path}`);
  }
}
if (report.components_count !== 6 || checkReport.components_count !== 6) {
  throw new Error('kit airgap reports must count substrate pack and install inputs components');
}
for (const expected of expectedSubstrateDeclarations) {
  const declaration = manifest.image_artifact_declarations.find((item) => item.id === expected.id);
  if (!declaration) {
    throw new Error(`kit airgap manifest must declare substrate image: ${expected.id}`);
  }
  if (
    declaration.source_image !== expected.image ||
    declaration.target_image !== expected.image ||
    declaration.source_digest !== expected.digest ||
    declaration.target_digest !== expected.digest
  ) {
    throw new Error(`kit substrate declaration must bind pack image ref and digest: ${expected.id}`);
  }
  if (declaration.path !== `images/${expected.id}.oci-layout.tar`) {
    throw new Error(`unexpected substrate archive path: ${declaration.path}`);
  }
  if (!fs.statSync(path.join(bundleRoot, declaration.path)).isFile()) {
    throw new Error(`missing bundled substrate archive: ${declaration.path}`);
  }
}
if (report.image_artifact_count !== manifest.image_artifact_declarations.length) {
  throw new Error('kit create report must count release and substrate image artifacts');
}
if (
  checkReport.image_artifact_declaration_count !== manifest.image_artifact_declarations.length ||
  checkReport.artifacts?.bundle_manifest?.image_artifact_declaration_count !==
    manifest.image_artifact_declarations.length
) {
  throw new Error('kit bundle check report must count release and substrate image declarations');
}
for (const relativePath of [...materialPaths].sort()) {
  const source = path.join(path.dirname(substratePackManifest), relativePath);
  const bundled = path.join(bundleRoot, 'components', relativePath);
  if (!fs.statSync(bundled).isFile()) {
    throw new Error(`missing bundled substrate pack material: ${relativePath}`);
  }
  if (fileDigest(source) !== fileDigest(bundled)) {
    throw new Error(`bundled substrate pack material digest mismatch: ${relativePath}`);
  }
}
NODE
}

expect_create_fail() {
  local label="$1"
  local bundle_root="$2"
  local output_dir="$3"
  shift 3

  write_stale_reports "$output_dir"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected bundle create failure: $label"
  fi

  assert_no_create_report "$output_dir"
  assert_no_self_check_report "$output_dir"
  pass "bundle create rejected invalid case: $label"
}

expect_create_fail_with_evidence() {
  local label="$1"
  local bundle_root="$2"
  local output_dir="$3"
  local evidence_root="$4"
  shift 4

  write_stale_reports "$output_dir"
  write_stale_evidence_outputs "$evidence_root" "$label"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected bundle create evidence failure: $label"
  fi

  assert_no_create_report "$output_dir"
  assert_no_self_check_report "$output_dir"
  assert_stale_evidence_outputs "$evidence_root" "$label"
  pass "bundle create rejected invalid evidence case: $label"
}

manifest_sha="$(create_plain_archive "$VALID_ARCHIVE")"
archive_sha="$(sha256_file "$VALID_ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha"
create_payloads
create_image_archives
write_operator_prerequisites "$OPERATOR_PREREQUISITES"
write_kit_substrate_pack_manifest "$KIT_SUBSTRATE_PACK" "$KIT_AIRGAP_PROFILE"
write_kit_substrate_install_inputs "$KIT_SUBSTRATE_INSTALL_INPUTS" "$KIT_AIRGAP_PROFILE"
create_substrate_image_archives "$IMAGE_DIR" "$KIT_SUBSTRATE_PACK"
write_evidence_provenance "$VALID_PROVENANCE"
refresh_args

valid_bundle_root="$TMP_DIR/bundle-valid"
valid_output_dir="$TMP_DIR/out-valid"
run_bundle_create "$valid_bundle_root" "$valid_output_dir" >"$TMP_DIR/valid-create.out"
assert_bundle_and_report "$valid_bundle_root" "$valid_output_dir"
if ! tail -n 1 "$TMP_DIR/valid-create.out" | grep -q 'bundle create mode is not release readiness; readiness=false'; then
  cat "$TMP_DIR/valid-create.out" >&2
  fail "bundle create stdout must end with non-readiness wording"
fi
pass "valid bundle create assembled bundle and wrote focused non-readiness report"

evidence_bundle_root="$TMP_DIR/bundle-evidence"
evidence_output_dir="$TMP_DIR/out-evidence"
evidence_root="$TMP_DIR/evidence-root"
run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$evidence_bundle_root" "$evidence_output_dir" \
  "${default_image_args[@]}" \
  "${common_payload_args[@]}" \
  --evidence-root "$evidence_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/evidence-create.out"
assert_bundle_and_report "$evidence_bundle_root" "$evidence_output_dir"
assert_airgap_bundle_evidence "$evidence_root"
if ! grep -q 'PASS: release-kit evidence accepted' "$TMP_DIR/evidence-create.out"; then
  cat "$TMP_DIR/evidence-create.out" >&2
  fail "bundle-create evidence path must call --evidence self-check"
fi
pass "valid external-declared airgap bundle create wrote unsigned focused evidence root"

valid_kit_bundle_root="$TMP_DIR/bundle-valid-kit"
valid_kit_output_dir="$TMP_DIR/out-valid-kit"
run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$valid_kit_bundle_root" "$valid_kit_output_dir" \
  "${default_image_args[@]}" \
  "${kit_image_args[@]}" \
  "${common_payload_args[@]}" \
  --substrate-pack-manifest "$KIT_SUBSTRATE_PACK" \
  --substrate-install-inputs "$KIT_SUBSTRATE_INSTALL_INPUTS" >"$TMP_DIR/valid-create-kit.out"
assert_kit_bundle_and_report \
  "$valid_kit_bundle_root" \
  "$valid_kit_output_dir" \
  "$KIT_SUBSTRATE_PACK" \
  "$KIT_SUBSTRATE_INSTALL_INPUTS"
pass "valid kit-installed airgap bundle create binds substrate pack manifest"

materialized_kit_pack_dir="$TMP_DIR/materialized-kit-airgap-substrate-pack"
"$NODE_BIN" "$ROOT_DIR/scripts/materialize-substrate-pack.mjs" \
  --deployment-path airgap/install_substrates \
  --target-registry "$AIRGAP_REGISTRY" \
  --output-dir "$materialized_kit_pack_dir" \
  --namespace agentsmith \
  --installation-id kit-install-minimal-airgap-1001 \
  --storage-class gp3 \
  --declared-at 2026-06-10T12:00:00.000Z >/dev/null
create_substrate_image_archives "$IMAGE_DIR" "$materialized_kit_pack_dir/substrate-pack-manifest.json"
materialized_kit_bundle_root="$TMP_DIR/bundle-materialized-kit"
materialized_kit_output_dir="$TMP_DIR/out-materialized-kit"
run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$materialized_kit_bundle_root" "$materialized_kit_output_dir" \
  "${default_image_args[@]}" \
  "${kit_image_args[@]}" \
  "${common_payload_args[@]}" \
  --substrate-pack-manifest "$materialized_kit_pack_dir/substrate-pack-manifest.json" \
  --substrate-install-inputs "$materialized_kit_pack_dir/substrate-install-inputs.json" >"$TMP_DIR/materialized-create-kit.out"
assert_kit_bundle_and_report \
  "$materialized_kit_bundle_root" \
  "$materialized_kit_output_dir" \
  "$materialized_kit_pack_dir/substrate-pack-manifest.json" \
  "$materialized_kit_pack_dir/substrate-install-inputs.json"
pass "kit-installed airgap bundle create consumes first-party materialized substrate pack"

expect_create_fail_with_evidence missing-evidence-provenance "$TMP_DIR/bundle-missing-evidence-provenance" "$TMP_DIR/out-missing-evidence-provenance" "$TMP_DIR/evidence-missing-provenance" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-missing-evidence-provenance" "$TMP_DIR/out-missing-evidence-provenance" \
    "${default_image_args[@]}" \
    "${common_payload_args[@]}" \
    --evidence-root "$TMP_DIR/evidence-missing-provenance"

kit_evidence_bundle_root="$TMP_DIR/bundle-kit-evidence"
kit_evidence_output_dir="$TMP_DIR/out-kit-evidence"
kit_evidence_root="$TMP_DIR/evidence-kit"
run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$kit_evidence_bundle_root" "$kit_evidence_output_dir" \
  "${default_image_args[@]}" \
  "${kit_image_args[@]}" \
  "${common_payload_args[@]}" \
  --substrate-pack-manifest "$KIT_SUBSTRATE_PACK" \
  --substrate-install-inputs "$KIT_SUBSTRATE_INSTALL_INPUTS" \
  --evidence-root "$kit_evidence_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/kit-evidence-create.out"
assert_kit_bundle_and_report \
  "$kit_evidence_bundle_root" \
  "$kit_evidence_output_dir" \
  "$KIT_SUBSTRATE_PACK" \
  "$KIT_SUBSTRATE_INSTALL_INPUTS"
assert_airgap_bundle_evidence "$kit_evidence_root" "$KIT_AIRGAP_PROFILE" "$KIT_SUBSTRATE_PACK"
if ! grep -q 'PASS: release-kit evidence accepted' "$TMP_DIR/kit-evidence-create.out"; then
  cat "$TMP_DIR/kit-evidence-create.out" >&2
  fail "kit bundle-create evidence path must call --evidence self-check"
fi
pass "valid kit-installed airgap bundle create wrote unsigned focused evidence root"

evidence_dir_root="$TMP_DIR/evidence-managed-dir"
mkdir -p "$evidence_dir_root/evidence.json"
write_stale_reports "$TMP_DIR/out-evidence-managed-dir"
if run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-evidence-managed-dir" "$TMP_DIR/out-evidence-managed-dir" \
  "${default_image_args[@]}" \
  "${common_payload_args[@]}" \
  --evidence-root "$evidence_dir_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/evidence-managed-dir.out" 2>"$TMP_DIR/evidence-managed-dir.err"; then
  cat "$TMP_DIR/evidence-managed-dir.out" >&2
  cat "$TMP_DIR/evidence-managed-dir.err" >&2
  fail "expected bundle create to reject managed evidence directory"
fi
assert_no_create_report "$TMP_DIR/out-evidence-managed-dir"
assert_no_self_check_report "$TMP_DIR/out-evidence-managed-dir"
[[ ! -e "$TMP_DIR/bundle-evidence-managed-dir/airgap-bundle-manifest.json" ]] || \
  fail "managed evidence directory failure must happen before bundle assembly"
[[ -d "$evidence_dir_root/evidence.json" ]] || fail "managed evidence directory must not be recursively removed"
if ! grep -q 'managed evidence entry evidence.json must be a file or symlink' "$TMP_DIR/evidence-managed-dir.err"; then
  cat "$TMP_DIR/evidence-managed-dir.out" >&2
  cat "$TMP_DIR/evidence-managed-dir.err" >&2
  fail "managed evidence directory failure must be explicit"
fi
pass "bundle create rejects managed evidence directories without recursive cleanup"

evidence_extra_root="$TMP_DIR/evidence-extra-entry"
mkdir -p "$evidence_extra_root"
printf '%s\n' 'operator handoff note' >"$evidence_extra_root/operator-notes.txt"
write_stale_reports "$TMP_DIR/out-evidence-extra-entry"
if run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-evidence-extra-entry" "$TMP_DIR/out-evidence-extra-entry" \
  "${default_image_args[@]}" \
  "${common_payload_args[@]}" \
  --evidence-root "$evidence_extra_root" \
  --evidence-provenance "$VALID_PROVENANCE" >"$TMP_DIR/evidence-extra-entry.out" 2>"$TMP_DIR/evidence-extra-entry.err"; then
  cat "$TMP_DIR/evidence-extra-entry.out" >&2
  cat "$TMP_DIR/evidence-extra-entry.err" >&2
  fail "expected bundle create to reject non-managed evidence entry"
fi
assert_no_create_report "$TMP_DIR/out-evidence-extra-entry"
assert_no_self_check_report "$TMP_DIR/out-evidence-extra-entry"
[[ ! -e "$TMP_DIR/bundle-evidence-extra-entry/airgap-bundle-manifest.json" ]] || \
  fail "non-managed evidence entry failure must happen before bundle assembly"
grep -q 'operator handoff note' "$evidence_extra_root/operator-notes.txt" || \
  fail "non-managed evidence entry must not be deleted or modified"
if ! grep -q 'evidence root contains non-managed entry operator-notes.txt' "$TMP_DIR/evidence-extra-entry.err"; then
  cat "$TMP_DIR/evidence-extra-entry.out" >&2
  cat "$TMP_DIR/evidence-extra-entry.err" >&2
  fail "non-managed evidence entry failure must be explicit"
fi
pass "bundle create rejects non-managed evidence entries without cleanup"

rerun_output_dir="$TMP_DIR/out-rerun-check"
run_airgap_bundle_check "$valid_bundle_root" "$rerun_output_dir" >"$TMP_DIR/rerun-check.out"
[[ -f "$rerun_output_dir/$CHECK_REPORT_FILE" ]] || fail "rerun airgap bundle check report missing"
pass "airgap bundle check reruns independently on generated bundle"

expect_create_fail missing-image-archive "$TMP_DIR/bundle-missing-image" "$TMP_DIR/out-missing-image" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-missing-image" "$TMP_DIR/out-missing-image" \
    --image-archive "agentsmith_app=$IMAGE_DIR/agentsmith_app.oci-layout.tar" \
    --image-archive "llmup=$IMAGE_DIR/llmup.oci-layout.tar" \
    --image-archive "afscp=$IMAGE_DIR/afscp.oci-layout.tar" \
    --image-archive "asbcp=$IMAGE_DIR/asbcp.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail duplicate-image-id "$TMP_DIR/bundle-duplicate-image" "$TMP_DIR/out-duplicate-image" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-duplicate-image" "$TMP_DIR/out-duplicate-image" \
    "${default_image_args[@]}" \
    --image-archive "agentsmith_app=$IMAGE_DIR/llmup.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail unknown-image-id "$TMP_DIR/bundle-unknown-image" "$TMP_DIR/out-unknown-image" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-unknown-image" "$TMP_DIR/out-unknown-image" \
    "${default_image_args[@]}" \
    --image-archive "unknown_component=$IMAGE_DIR/agentsmith_app.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail external-declared-rejects-substrate-image-archive "$TMP_DIR/bundle-external-substrate-image" "$TMP_DIR/out-external-substrate-image" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-external-substrate-image" "$TMP_DIR/out-external-substrate-image" \
    "${default_image_args[@]}" \
    --image-archive "substrate_redis=$IMAGE_DIR/substrate_redis.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail missing-substrate-image-archive "$TMP_DIR/bundle-missing-substrate-image" "$TMP_DIR/out-missing-substrate-image" \
  run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-missing-substrate-image" "$TMP_DIR/out-missing-substrate-image" \
    "${default_image_args[@]}" \
    "${kit_image_args_without_redis[@]}" \
    "${common_payload_args[@]}" \
    --substrate-pack-manifest "$KIT_SUBSTRATE_PACK" \
    --substrate-install-inputs "$KIT_SUBSTRATE_INSTALL_INPUTS"
if ! grep -Fq -- '--image-archive is missing substrate image archive id: substrate_redis' "$TMP_DIR/missing-substrate-image-archive.err"; then
  cat "$TMP_DIR/missing-substrate-image-archive.err" >&2
  fail "missing substrate image archive failure must name substrate_redis"
fi

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE" \
  "alias-offline:$ALIAS_OFFLINE_PROFILE"; do
  label="${profile_case%%:*}"
  profile="${profile_case#*:}"
  expect_create_fail "unsupported-profile-$label" "$TMP_DIR/bundle-profile-$label" "$TMP_DIR/out-profile-$label" \
    run_bundle_create_full "$profile" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-profile-$label" "$TMP_DIR/out-profile-$label" \
      "${default_image_args[@]}" \
      "${common_payload_args[@]}"
done

expect_create_fail missing-substrate-pack-manifest "$TMP_DIR/bundle-missing-substrate-pack" "$TMP_DIR/out-missing-substrate-pack" \
  run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-missing-substrate-pack" "$TMP_DIR/out-missing-substrate-pack" \
    "${default_image_args[@]}" \
    "${kit_image_args[@]}" \
    "${common_payload_args[@]}" \
    --substrate-install-inputs "$KIT_SUBSTRATE_INSTALL_INPUTS"

expect_create_fail missing-substrate-install-inputs "$TMP_DIR/bundle-missing-substrate-install-inputs" "$TMP_DIR/out-missing-substrate-install-inputs" \
  run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-missing-substrate-install-inputs" "$TMP_DIR/out-missing-substrate-install-inputs" \
    "${default_image_args[@]}" \
    "${kit_image_args[@]}" \
    "${common_payload_args[@]}" \
    --substrate-pack-manifest "$KIT_SUBSTRATE_PACK"

expect_create_fail external-declared-rejects-substrate-pack-manifest "$TMP_DIR/bundle-external-substrate-pack" "$TMP_DIR/out-external-substrate-pack" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-external-substrate-pack" "$TMP_DIR/out-external-substrate-pack" \
    "${default_image_args[@]}" \
    "${common_payload_args[@]}" \
    --substrate-pack-manifest "$KIT_SUBSTRATE_PACK"

expect_create_fail external-declared-rejects-substrate-install-inputs "$TMP_DIR/bundle-external-substrate-install-inputs" "$TMP_DIR/out-external-substrate-install-inputs" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-external-substrate-install-inputs" "$TMP_DIR/out-external-substrate-install-inputs" \
    "${default_image_args[@]}" \
    "${common_payload_args[@]}" \
    --substrate-install-inputs "$KIT_SUBSTRATE_INSTALL_INPUTS"

for substrate_pack_case in secret_payload non_digest_image localhost_image missing_required_section missing_material_file material_sha_mismatch; do
  bad_substrate_pack="$TMP_DIR/substrate-pack-$substrate_pack_case.json"
  write_kit_substrate_pack_manifest "$bad_substrate_pack" "$KIT_AIRGAP_PROFILE" "$substrate_pack_case"
  expect_create_fail "kit-substrate-pack-$substrate_pack_case" "$TMP_DIR/bundle-kit-substrate-pack-$substrate_pack_case" "$TMP_DIR/out-kit-substrate-pack-$substrate_pack_case" \
    run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-kit-substrate-pack-$substrate_pack_case" "$TMP_DIR/out-kit-substrate-pack-$substrate_pack_case" \
      "${default_image_args[@]}" \
      "${kit_image_args[@]}" \
      "${common_payload_args[@]}" \
      --substrate-pack-manifest "$bad_substrate_pack" \
      --substrate-install-inputs "$KIT_SUBSTRATE_INSTALL_INPUTS"
done

for substrate_install_inputs_case in target_profile_mismatch installation_id_mismatch missing_resource_list; do
  bad_substrate_install_inputs="$TMP_DIR/substrate-install-inputs-$substrate_install_inputs_case.json"
  write_kit_substrate_install_inputs "$bad_substrate_install_inputs" "$KIT_AIRGAP_PROFILE" "$substrate_install_inputs_case"
  expect_create_fail "kit-substrate-install-inputs-$substrate_install_inputs_case" "$TMP_DIR/bundle-kit-substrate-install-inputs-$substrate_install_inputs_case" "$TMP_DIR/out-kit-substrate-install-inputs-$substrate_install_inputs_case" \
    run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-kit-substrate-install-inputs-$substrate_install_inputs_case" "$TMP_DIR/out-kit-substrate-install-inputs-$substrate_install_inputs_case" \
      "${default_image_args[@]}" \
      "${kit_image_args[@]}" \
      "${common_payload_args[@]}" \
      --substrate-pack-manifest "$KIT_SUBSTRATE_PACK" \
      --substrate-install-inputs "$bad_substrate_install_inputs"
done

expect_create_fail invalid-target-registry "$TMP_DIR/bundle-bad-registry" "$TMP_DIR/out-bad-registry" \
  run_bundle_create_full "$AIRGAP_PROFILE" "https://registry.example.internal/releases" "$TMP_DIR/bundle-bad-registry" "$TMP_DIR/out-bad-registry" \
    "${default_image_args[@]}" \
    "${common_payload_args[@]}"

nonempty_root="$TMP_DIR/bundle-nonempty"
mkdir -p "$nonempty_root"
printf '%s\n' 'do not overwrite' >"$nonempty_root/existing.txt"
expect_create_fail non-empty-bundle-root "$nonempty_root" "$TMP_DIR/out-nonempty" \
  run_bundle_create "$nonempty_root" "$TMP_DIR/out-nonempty"

ln -s "$IMAGE_DIR/agentsmith_app.oci-layout.tar" "$TMP_DIR/agentsmith_app.symlink.tar"
expect_create_fail image-archive-symlink "$TMP_DIR/bundle-image-symlink" "$TMP_DIR/out-image-symlink" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-image-symlink" "$TMP_DIR/out-image-symlink" \
    --image-archive "agentsmith_app=$TMP_DIR/agentsmith_app.symlink.tar" \
    --image-archive "llmup=$IMAGE_DIR/llmup.oci-layout.tar" \
    --image-archive "afscp=$IMAGE_DIR/afscp.oci-layout.tar" \
    --image-archive "asbcp=$IMAGE_DIR/asbcp.oci-layout.tar" \
    --image-archive "ingress_nginx_controller=$IMAGE_DIR/ingress_nginx_controller.oci-layout.tar" \
    --image-archive "ingress_nginx_certgen=$IMAGE_DIR/ingress_nginx_certgen.oci-layout.tar" \
    --image-archive "managed_runner=$IMAGE_DIR/managed_runner.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail image-archive-directory "$TMP_DIR/bundle-image-directory" "$TMP_DIR/out-image-directory" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-image-directory" "$TMP_DIR/out-image-directory" \
    --image-archive "agentsmith_app=$IMAGE_DIR" \
    --image-archive "llmup=$IMAGE_DIR/llmup.oci-layout.tar" \
    --image-archive "afscp=$IMAGE_DIR/afscp.oci-layout.tar" \
    --image-archive "asbcp=$IMAGE_DIR/asbcp.oci-layout.tar" \
    --image-archive "ingress_nginx_controller=$IMAGE_DIR/ingress_nginx_controller.oci-layout.tar" \
    --image-archive "ingress_nginx_certgen=$IMAGE_DIR/ingress_nginx_certgen.oci-layout.tar" \
    --image-archive "managed_runner=$IMAGE_DIR/managed_runner.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail image-archive-uri "$TMP_DIR/bundle-image-uri" "$TMP_DIR/out-image-uri" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-image-uri" "$TMP_DIR/out-image-uri" \
    --image-archive "agentsmith_app=https://example.invalid/agentsmith_app.oci-layout.tar" \
    --image-archive "llmup=$IMAGE_DIR/llmup.oci-layout.tar" \
    --image-archive "afscp=$IMAGE_DIR/afscp.oci-layout.tar" \
    --image-archive "asbcp=$IMAGE_DIR/asbcp.oci-layout.tar" \
    --image-archive "ingress_nginx_controller=$IMAGE_DIR/ingress_nginx_controller.oci-layout.tar" \
    --image-archive "ingress_nginx_certgen=$IMAGE_DIR/ingress_nginx_certgen.oci-layout.tar" \
    --image-archive "managed_runner=$IMAGE_DIR/managed_runner.oci-layout.tar" \
    "${common_payload_args[@]}"

expect_create_fail missing-runbook "$TMP_DIR/bundle-missing-runbook" "$TMP_DIR/out-missing-runbook" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-missing-runbook" "$TMP_DIR/out-missing-runbook" \
    "${default_image_args[@]}" \
    --runbook "$TMP_DIR/missing-runbook.md" \
    --script "$PAYLOAD_DIR/install.sh" \
    --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json" \
    --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml" \
    --operator-prerequisites "$OPERATOR_PREREQUISITES"

secret_runbook="$TMP_DIR/secret-runbook.md"
printf '%s\n' 'token=abcdefghijklmnop' >"$secret_runbook"
expect_create_fail secret-looking-payload "$TMP_DIR/bundle-secret-payload" "$TMP_DIR/out-secret-payload" \
  run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-secret-payload" "$TMP_DIR/out-secret-payload" \
    "${default_image_args[@]}" \
    --runbook "$secret_runbook" \
    --script "$PAYLOAD_DIR/install.sh" \
    --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json" \
    --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml" \
    --operator-prerequisites "$OPERATOR_PREREQUISITES"

for operator_case in missing tools_empty embedded_url download secret_proof; do
  operator_file="$TMP_DIR/operator-$operator_case.json"
  write_operator_prerequisites "$operator_file" "$operator_case"
  expect_create_fail "operator-prerequisites-$operator_case" "$TMP_DIR/bundle-operator-$operator_case" "$TMP_DIR/out-operator-$operator_case" \
    run_bundle_create_full "$AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$TMP_DIR/bundle-operator-$operator_case" "$TMP_DIR/out-operator-$operator_case" \
      "${default_image_args[@]}" \
      --runbook "$PAYLOAD_DIR/runbook.md" \
      --script "$PAYLOAD_DIR/install.sh" \
      --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json" \
      --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml" \
      --operator-prerequisites "$operator_file"
done

shim_dir="$TMP_DIR/shims"
mkdir -p "$shim_dir"
for binary in curl wget docker skopeo oras kubectl; do
  cat >"$shim_dir/$binary" <<'SH'
#!/usr/bin/env sh
echo "forbidden tool was called: $(basename "$0")" >&2
exit 99
SH
  chmod +x "$shim_dir/$binary"
done
PATH="$shim_dir:$PATH" run_bundle_create "$TMP_DIR/bundle-no-tools" "$TMP_DIR/out-no-tools" >"$TMP_DIR/no-tools.out"
assert_bundle_and_report "$TMP_DIR/bundle-no-tools" "$TMP_DIR/out-no-tools"
pass "bundle create does not call network or tool binaries"

pass "bundle-create focused diagnostic tests completed"
