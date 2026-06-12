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
REPORT_FILE="airgap-image-archive-check-report.json"
LARGE_FIXTURE_SIZE=$((2 * 1024 * 1024 * 1024 + 1))
LARGE_READ_GUARD="$ROOT_DIR/scripts/lib/test-large-file-read-guard.cjs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VALID_CONTRACT="$TMP_DIR/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.valid.json"
VALID_ARCHIVE="$TMP_DIR/agentsmith-deploy-template-package.tgz"
PAYLOAD_DIR="$TMP_DIR/payload"
IMAGE_DIR="$TMP_DIR/image-archives"
OPERATOR_PREREQUISITES="$TMP_DIR/operator-prerequisites.json"
KIT_SUBSTRATE_PACK_MANIFEST="$TMP_DIR/substrate-pack-manifest.kit-airgap.json"
KIT_SUBSTRATE_INSTALL_INPUTS="$TMP_DIR/substrate-install-inputs.kit-airgap.json"
GOOD_PROBE="$TMP_DIR/probes/archive-digest-probe"
TARGET_ANNOTATION_PROBE="$TMP_DIR/probes/target-annotation-probe"
DOUBLE_OUTPUT_PROBE="$TMP_DIR/probes/double-output-probe"
TIMEOUT_PROBE="$TMP_DIR/probes/timeout-probe"
LARGE_TARGET_DIGEST_PROBE="$TMP_DIR/probes/large-target-digest-probe"

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

assert_larger_than_2g() {
  "$NODE_BIN" --input-type=module - "$1" <<'NODE'
import fs from 'node:fs';

const [file] = process.argv.slice(2);
const stat = fs.statSync(file);
if (stat.size <= 2 * 1024 * 1024 * 1024) {
  throw new Error(`expected >2GiB sparse fixture: ${file}`);
}
NODE
}

create_plain_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package"

  mkdir -p "$package_dir/templates"
  printf '%s\n' \
    'apiVersion: apps/v1' \
    'kind: Deployment' \
    'metadata:' \
    '  name: agentsmith-web' \
    'spec:' \
    '  replicas: 1' >"$package_dir/templates/deployment.yaml"
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
  local contract_output="${3:-$VALID_CONTRACT}"
  local package_output="${4:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"
  local fixture_variant="${5:-valid}"

  "$NODE_BIN" --input-type=module - \
    "$FIXTURE_CONTRACT" \
    "$FIXTURE_DEPLOY_TEMPLATE_PACKAGE" \
    "$manifest_sha" \
    "$archive_sha" \
    "$contract_output" \
    "$package_output" \
    "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    "$fixture_variant" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const [
  contractInput,
  packageInput,
  manifestSha,
  archiveSha,
  contractOutput,
  packageOutput,
  fixtureHelper,
  fixtureVariant
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

function fixtureTargetDigest(imageId) {
  const result = spawnSync(
    process.execPath,
    [
      fixtureHelper,
      '--print-target-digest',
      '--image-id',
      imageId,
      '--variant',
      fixtureVariant
    ],
    { encoding: 'utf8' }
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(result.stderr || `fixture digest failed for ${imageId}`);
  }
  const value = result.stdout.trim();
  if (!/^sha256:[0-9a-f]{64}$/.test(value)) {
    throw new Error(`fixture digest returned invalid digest for ${imageId}: ${value}`);
  }
  return value;
}

function replaceImageDigest(image, nextDigest) {
  if (!/@sha256:[0-9a-f]{64}$/.test(image)) {
    throw new Error(`image must be digest-pinned: ${image}`);
  }
  return image.replace(/@sha256:[0-9a-f]{64}$/, `@${nextDigest}`);
}

function retargetImageItem(item, imageId) {
  const nextDigest = fixtureTargetDigest(imageId);
  item.digest = nextDigest;
  item.image = replaceImageDigest(item.image, nextDigest);
  if (item.source_provenance?.artifact_sha256) {
    item.source_provenance.artifact_sha256 = nextDigest;
  }
}

function subjectDigest(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return digest(JSON.stringify(stableJson(subject)));
}

function artifactProjectionDigest(value) {
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } = value.artifact_provenance;
  const projection = { ...value, artifact_provenance: artifactProvenance };
  return digest(JSON.stringify(stableJson(projection)));
}

for (const item of contract.deploy_image_inventory) {
  retargetImageItem(item, item.id);
}
for (const item of contract.product_images) {
  retargetImageItem(item, item.id);
}
for (const item of contract.adopted_provider_images) {
  retargetImageItem(item, item.id);
}
for (const item of contract.release_kit_prerequisite_images) {
  retargetImageItem(item, item.id);
}
retargetImageItem(contract.managed_runner_image, 'managed_runner');

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
  local image_dir="${1:-$IMAGE_DIR}"
  local contract="${2:-$VALID_CONTRACT}"
  local fixture_variant="${3:-valid}"

  mkdir -p "$image_dir"
  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --from-contract "$contract" \
    --output-dir "$image_dir" \
    --variant "$fixture_variant"
}

create_substrate_image_archives() {
  local image_dir="$1"
  local substrate_pack_manifest="$2"

  mkdir -p "$image_dir"
  "$NODE_BIN" --input-type=module - \
    "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    "$image_dir" \
    "$substrate_pack_manifest" <<'NODE'
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [fixtureScript, imageDir, substratePackManifest] = process.argv.slice(2);
const pack = JSON.parse(fs.readFileSync(substratePackManifest, 'utf8'));
for (const key of Object.keys(pack.images).sort()) {
  const id = `substrate_${key}`;
  const image = pack.images[key];
  const digest = image.slice(image.lastIndexOf('@') + 1);
  const result = spawnSync(process.execPath, [
    fixtureScript,
    '--archive',
    path.join(imageDir, `${id}.oci-layout.tar`),
    '--image-id',
    id,
    '--target-digest',
    digest
  ], {
    stdio: 'inherit'
  });
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
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

write_kit_substrate_pack_manifest() {
  local output="$1"
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
    "$KIT_AIRGAP_PROFILE" \
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
  postgresqlDigest,
  mongodbDigest,
  redisDigest,
  objectStorageDigest,
  oidcDigest
] = process.argv.slice(2);
const digest = (char) => `sha256:${char.repeat(64)}`;
const image = (name, tag, digestValue) =>
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
const toolsDigest = writePackText(
  'tools/substrate-checks.txt',
  'postgresql tls\nmongodb tls\nredis ping\nobject-storage head-bucket\noidc discovery\n'
);
const manifest = {
  schema_version: 'agentsmith.substrate-pack-manifest/v1',
  release_kit_version: '0.1.0',
  installed_by: 'agentsmith-release-kit',
  target_profile: profile,
  images: {
    postgresql: image('postgresql', '16.3', postgresqlDigest),
    mongodb: image('mongodb', '7.0', mongodbDigest),
    redis: image('redis', '7.2', redisDigest),
    object_storage: image('object-storage', '2026.05', objectStorageDigest),
    oidc: image('keycloak', '25.0', oidcDigest)
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
    oidc: 'templates/oidc.yaml'
  },
  tools: {
    checks: {
      path: 'tools/substrate-checks.txt',
      sha256: toolsDigest
    }
  },
  checksums: {
    manifest: digest('8')
  }
};

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

write_kit_substrate_install_inputs() {
  local output="$1"
  local profile="$2"

  "$NODE_BIN" --input-type=module - "$output" "$profile" <<'NODE'
import fs from 'node:fs';

const [output, profileValue] = process.argv.slice(2);
const [targetCluster, substrateSource, distribution] = profileValue.split('/');
const installationId = 'kit-install-10001';
const reachability = {
  status: 'declared_reachable',
  proof: 'operator fixture declared reachable'
};
const substrateTruth = {
  schema_version: 'agentsmith.substrate-connection.truth/v1',
  redacted_fingerprint: `sha256:${'a'.repeat(64)}`,
  target_cluster: targetCluster,
  substrate_source: substrateSource,
  distribution,
  declared_at: '2026-06-10T12:00:00.000Z',
  declared_by: 'release-operator@example.com',
  installed_by: 'agentsmith-release-kit',
  release_kit_version: '0.1.0',
  installation_id: installationId,
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
const resources = [
  {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: {
      name: 'agentsmith-substrate-config',
      namespace: 'agentsmith',
      labels: {
        'app.kubernetes.io/managed-by': 'agentsmith-release-kit'
      },
      annotations: {
        'agentsmith.io/managed-by': 'agentsmith-release-kit',
        'agentsmith.io/installation-id': installationId
      }
    },
    data: {
      profile: profileValue
    }
  }
];
const installInputs = {
  schema_version: 'agentsmith.substrate-install-inputs/v1',
  target_profile: profileValue,
  installation_id: installationId,
  substrate_truth: substrateTruth,
  resources
};

fs.writeFileSync(output, `${JSON.stringify(installInputs, null, 2)}\n`);
NODE
}

write_probes() {
  mkdir -p "$(dirname "$GOOD_PROBE")"
  cat >"$GOOD_PROBE" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const TAR_BLOCK_SIZE = 512;
const archivePath = process.argv[2] || process.env.AGENTSMITH_IMAGE_ARCHIVE_PATH;
if (!archivePath) {
  process.exit(2);
}

function readTarString(block, start, length) {
  const slice = block.subarray(start, start + length);
  const end = slice.indexOf(0);
  return slice.subarray(0, end === -1 ? slice.length : end).toString('utf8').trim();
}

function parseTarOctal(block, start, length) {
  const raw = readTarString(block, start, length).trim();
  return raw === '' ? 0 : Number.parseInt(raw, 8);
}

function readTarFile(buffer, wantedPath) {
  for (let offset = 0; offset + TAR_BLOCK_SIZE <= buffer.length; ) {
    const block = buffer.subarray(offset, offset + TAR_BLOCK_SIZE);
    if (block.every((byte) => byte === 0)) {
      break;
    }
    const name = readTarString(block, 0, 100);
    const prefix = readTarString(block, 345, 155);
    const entryPath = prefix ? `${prefix}/${name}` : name;
    const size = parseTarOctal(block, 124, 12);
    const contentStart = offset + TAR_BLOCK_SIZE;
    const contentEnd = contentStart + size;
    if (entryPath === wantedPath) {
      return buffer.subarray(contentStart, contentEnd);
    }
    offset = contentStart + Math.ceil(size / TAR_BLOCK_SIZE) * TAR_BLOCK_SIZE;
  }
  return undefined;
}

const body = fs.readFileSync(archivePath);
const indexContent = readTarFile(body, 'index.json');
if (!indexContent) {
  process.exit(3);
}
const index = JSON.parse(indexContent.toString('utf8'));
if (!Array.isArray(index.manifests) || index.manifests.length !== 1) {
  process.exit(4);
}
const digest = index.manifests[0]?.digest;
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) {
  process.exit(5);
}
console.log(digest);
NODE
  chmod +x "$GOOD_PROBE"

  cat >"$TARGET_ANNOTATION_PROBE" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const archivePath = process.argv[2] || process.env.AGENTSMITH_IMAGE_ARCHIVE_PATH;
if (!archivePath) {
  process.exit(2);
}
const body = fs.readFileSync(archivePath, 'utf8');
const matches = [
  ...body.matchAll(/"io\.agentsmith\.fixture\.target_digest"\s*:\s*"(sha256:[0-9a-f]{64})"/g)
];
if (matches.length !== 1) {
  process.exit(3);
}
console.log(matches[0][1]);
NODE
  chmod +x "$TARGET_ANNOTATION_PROBE"

  cat >"$DOUBLE_OUTPUT_PROBE" <<'NODE'
#!/usr/bin/env node
console.log(`sha256:${'1'.repeat(64)}`);
console.log(`sha256:${'2'.repeat(64)}`);
NODE
  chmod +x "$DOUBLE_OUTPUT_PROBE"

  cat >"$TIMEOUT_PROBE" <<'NODE'
#!/usr/bin/env node
setTimeout(() => {}, 10000);
NODE
  chmod +x "$TIMEOUT_PROBE"

  cat >"$LARGE_TARGET_DIGEST_PROBE" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const TAR_BLOCK_SIZE = 512;
const archivePath = process.argv[2] || process.env.AGENTSMITH_IMAGE_ARCHIVE_PATH;
const imageId = process.env.AGENTSMITH_IMAGE_ID || '';
const largeImageId = process.env.RELEASE_KIT_TEST_LARGE_IMAGE_ID || '';
const largeDigest = process.env.RELEASE_KIT_TEST_LARGE_TARGET_DIGEST || '';
if (!archivePath) {
  process.exit(2);
}

if (imageId === largeImageId) {
  if (!/^sha256:[0-9a-f]{64}$/.test(largeDigest)) {
    process.exit(3);
  }
  console.log(largeDigest);
  process.exit(0);
}

function readTarString(block, start, length) {
  const slice = block.subarray(start, start + length);
  const end = slice.indexOf(0);
  return slice.subarray(0, end === -1 ? slice.length : end).toString('utf8').trim();
}

function parseTarOctal(block, start, length) {
  const raw = readTarString(block, start, length).trim();
  return raw === '' ? 0 : Number.parseInt(raw, 8);
}

function readTarFile(buffer, wantedPath) {
  for (let offset = 0; offset + TAR_BLOCK_SIZE <= buffer.length; ) {
    const block = buffer.subarray(offset, offset + TAR_BLOCK_SIZE);
    if (block.every((byte) => byte === 0)) {
      break;
    }
    const name = readTarString(block, 0, 100);
    const prefix = readTarString(block, 345, 155);
    const entryPath = prefix ? `${prefix}/${name}` : name;
    const size = parseTarOctal(block, 124, 12);
    const contentStart = offset + TAR_BLOCK_SIZE;
    const contentEnd = contentStart + size;
    if (entryPath === wantedPath) {
      return buffer.subarray(contentStart, contentEnd);
    }
    offset = contentStart + Math.ceil(size / TAR_BLOCK_SIZE) * TAR_BLOCK_SIZE;
  }
  return undefined;
}

const body = fs.readFileSync(archivePath);
const indexContent = readTarFile(body, 'index.json');
if (!indexContent) {
  process.exit(4);
}
const index = JSON.parse(indexContent.toString('utf8'));
if (!Array.isArray(index.manifests) || index.manifests.length !== 1) {
  process.exit(5);
}
const digest = index.manifests[0]?.digest;
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) {
  process.exit(6);
}
console.log(digest);
NODE
  chmod +x "$LARGE_TARGET_DIGEST_PROBE"
}

run_bundle_create() {
  local bundle_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$AIRGAP_PROFILE}"
  local substrate_pack_manifest="${4:-}"
  local substrate_install_inputs="${5:-}"
  local release_contract="${6:-$VALID_CONTRACT}"
  local deploy_template_package="${7:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"
  local image_dir="${8:-$IMAGE_DIR}"
  local image_archive_args=()
  local substrate_pack_args=()

  while IFS= read -r id; do
    image_archive_args+=(--image-archive "$id=$image_dir/$id.oci-layout.tar")
  done < <("$NODE_BIN" --input-type=module - "$release_contract" <<'NODE'
import fs from 'node:fs';

const [contractInput] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
for (const image of contract.deploy_image_inventory) {
  console.log(image.id);
}
NODE
)
  if [[ -n "$substrate_pack_manifest" ]]; then
    substrate_pack_args+=(--substrate-pack-manifest "$substrate_pack_manifest")
    while IFS= read -r id; do
      image_archive_args+=(--image-archive "$id=$image_dir/$id.oci-layout.tar")
    done < <("$NODE_BIN" --input-type=module - "$substrate_pack_manifest" <<'NODE'
import fs from 'node:fs';

const [substratePackManifest] = process.argv.slice(2);
const pack = JSON.parse(fs.readFileSync(substratePackManifest, 'utf8'));
for (const key of Object.keys(pack.images).sort()) {
  console.log(`substrate_${key}`);
}
NODE
)
  fi
  if [[ -n "$substrate_install_inputs" ]]; then
    substrate_pack_args+=(--substrate-install-inputs "$substrate_install_inputs")
  fi

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$VALID_ARCHIVE" \
    --target-profile "$target_profile" \
    --target-registry "$AIRGAP_REGISTRY" \
    --bundle-root "$bundle_root" \
    --output-dir "$output_dir" \
    "${image_archive_args[@]}" \
    "${substrate_pack_args[@]}" \
    --runbook "$PAYLOAD_DIR/runbook.md" \
    --script "$PAYLOAD_DIR/install.sh" \
    --profile-values-schema "$PAYLOAD_DIR/profile-values.schema.json" \
    --profile-values-example "$PAYLOAD_DIR/profile-values.example.yaml" \
    --operator-prerequisites "$OPERATOR_PREREQUISITES"

  if [[ -n "$substrate_pack_manifest" ]]; then
    assert_bundled_substrate_pack_materials "$bundle_root"
  fi
}

assert_bundled_substrate_pack_materials() {
  local bundle_root="$1"

  for material in \
    payload/install-substrates.json \
    templates/postgresql.yaml \
    templates/mongodb.yaml \
    templates/redis.yaml \
    templates/object-storage.yaml \
    templates/oidc.yaml \
    tools/substrate-checks.txt; do
    [[ -f "$bundle_root/components/$material" ]] ||
      fail "bundle-create did not copy substrate pack material: $material"
  done
}

run_image_archive_check_full() {
  local image_map="$1"
  local target_profile="$2"
  local bundle_root="$3"
  local bundle_manifest="$4"
  local archive_probe="$5"
  local output_dir="$6"
  local release_contract="${7:-$VALID_CONTRACT}"
  local deploy_template_package="${8:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-image-archive-check \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$VALID_ARCHIVE" \
    --image-map "$image_map" \
    --target-profile "$target_profile" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_manifest" \
    --archive-probe "$archive_probe" \
    --output-dir "$output_dir"
}

run_image_archive_check() {
  local bundle_root="$1"
  local output_dir="$2"
  local archive_probe="${3:-$GOOD_PROBE}"
  local target_profile="${4:-$AIRGAP_PROFILE}"

  run_image_archive_check_full \
    "$bundle_root/components/image-map.json" \
    "$target_profile" \
    "$bundle_root" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$archive_probe" \
    "$output_dir"
}

write_stale_report() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
}

assert_no_report() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "unexpected airgap image archive check report exists: $output_dir/$REPORT_FILE"
}

copy_valid_bundle() {
  local destination="$1"

  rm -rf "$destination"
  cp -R "$VALID_BUNDLE_ROOT" "$destination"
}

mutate_image_archive_digest() {
  local bundle_root="$1"
  local image_id="$2"
  local digest="$3"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --target-digest "$digest"
}

mutate_image_archive_manifest_digest_mismatch() {
  local bundle_root="$1"
  local image_id="$2"
  local archive_info=()

  mapfile -t archive_info < <("$NODE_BIN" --input-type=module - "$bundle_root" "$image_id" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, imageId] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(path.join(bundleRoot, 'airgap-bundle-manifest.json'), 'utf8'));
const declaration = manifest.image_artifact_declarations.find((item) => item.id === imageId);
if (!declaration) {
  throw new Error(`missing image declaration: ${imageId}`);
}
console.log(path.join(bundleRoot, ...declaration.path.split('/')));
console.log(declaration.target_digest);
NODE
)
  local archive_path="${archive_info[0]}"
  local target_digest="${archive_info[1]}"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --archive "$archive_path" \
    --image-id "${image_id}_archive_manifest_mismatch" \
    --target-digest "$target_digest"

  "$NODE_BIN" --input-type=module - "$bundle_root" "$image_id" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, imageId] = process.argv.slice(2);
const manifestPath = path.join(bundleRoot, 'airgap-bundle-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const declaration = manifest.image_artifact_declarations.find((item) => item.id === imageId);
if (!declaration) {
  throw new Error(`missing image declaration: ${imageId}`);
}
const archivePath = path.join(bundleRoot, ...declaration.path.split('/'));
declaration.sha256 = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(archivePath)).digest('hex')}`;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

mutate_image_archive_missing_layer() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --variant missing-layer
}

mutate_image_archive_manifest_only() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --variant manifest-only
}

mutate_image_archive_nested_missing_layer() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --variant nested-missing-layer
}

mutate_image_archive_nested_missing_config() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --variant nested-missing-config
}

mutate_image_archive_nested_empty_index() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --variant nested-empty-index
}

mutate_image_archive_unknown_media_type() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --bundle-root "$bundle_root" \
    --image-id "$image_id" \
    --variant unknown-media-type
}

mutate_image_archive_placeholder() {
  local bundle_root="$1"
  local image_id="$2"

  "$NODE_BIN" --input-type=module - "$bundle_root" "$image_id" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, imageId] = process.argv.slice(2);
const manifestPath = path.join(bundleRoot, 'airgap-bundle-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const declaration = manifest.image_artifact_declarations.find((item) => item.id === imageId);
if (!declaration) {
  throw new Error(`missing image declaration: ${imageId}`);
}
const archivePath = path.join(bundleRoot, ...declaration.path.split('/'));
fs.writeFileSync(archivePath, `placeholder archive for ${imageId}\n`);
declaration.sha256 = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(archivePath)).digest('hex')}`;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"
  local expected_profile="${2:-$AIRGAP_PROFILE}"

  "$NODE_BIN" --input-type=module - "$report_file" "$VALID_CONTRACT" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, validContract, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedReleaseImageCount = JSON.parse(
  fs.readFileSync(validContract, 'utf8')
).deploy_image_inventory.length;
const expectedSubstrateIds = expectedProfile.includes('/kit_installed/')
  ? [
      'substrate_mongodb',
      'substrate_object_storage',
      'substrate_oidc',
      'substrate_postgresql',
      'substrate_redis'
    ]
  : [];
const expectedImageCount = expectedReleaseImageCount + expectedSubstrateIds.length;
const digestRe = /^sha256:[0-9a-f]{64}$/;

function assertNoLeakKeys(value, path = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoLeakKeys(item, `${path}[${index}]`));
    return;
  }
  for (const [key, item] of Object.entries(value)) {
    if (
      key === 'path' ||
      key === 'probe' ||
      key === 'probe_path' ||
      key === 'raw_probe_output' ||
      key === 'bundle_root' ||
      key === 'bundleRoot' ||
      key === 'target_registry'
    ) {
      throw new Error(`airgap image archive report must not include leak-prone key: ${path}.${key}`);
    }
    assertNoLeakKeys(item, `${path}.${key}`);
  }
}

if (report.schema !== 'agentsmith.airgap-image-archive-check-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'airgap_image_archive_content_check_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('airgap image archive report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.archive_count !== expectedImageCount) {
  throw new Error(`unexpected archive count: ${report.archive_count}`);
}
if (!Array.isArray(report.image_ids) || report.image_ids.length !== expectedImageCount) {
  throw new Error('report must list each image id once');
}
if (new Set(report.image_ids).size !== expectedImageCount) {
  throw new Error('report image ids must be unique');
}
for (const id of expectedSubstrateIds) {
  if (!report.image_ids.includes(id)) {
    throw new Error(`report must include substrate image id: ${id}`);
  }
}
if (!Array.isArray(report.images) || report.images.length !== expectedImageCount) {
  throw new Error('report must summarize each image archive');
}
for (const [label, digest] of Object.entries(report.digest_summary || {})) {
  if (!digestRe.test(digest)) {
    throw new Error(`digest summary missing sha256 for ${label}`);
  }
}
for (const image of report.images) {
  if (!report.image_ids.includes(image.id)) {
    throw new Error(`unexpected image id in summary: ${image.id}`);
  }
  for (const field of [
    'source_digest',
    'target_digest',
    'archive_manifest_digest',
    'archive_sha256',
    'probe_digest'
  ]) {
    if (!digestRe.test(image[field])) {
      throw new Error(`image ${image.id} missing ${field}`);
    }
  }
  if (image.archive_manifest_digest !== image.target_digest) {
    throw new Error(`archive manifest digest must match target digest for ${image.id}`);
  }
  if (image.probe_digest !== image.target_digest) {
    throw new Error(`probe digest must match target digest for ${image.id}`);
  }
}
if (report.archive_digest_summary?.archive_count !== expectedImageCount) {
  throw new Error('archive digest summary must count archives');
}
if (report.archive_digest_summary?.probe_digest_count !== expectedImageCount) {
  throw new Error('archive digest summary must count probe digests');
}
if (report.archive_digest_summary?.archive_manifest_digest_count !== expectedImageCount) {
  throw new Error('archive digest summary must count archive manifest digests');
}
assertNoLeakKeys(report);
if (/\/tmp\/|operator held|operator workstation|signed operator prerequisite/.test(serialized)) {
  throw new Error('airgap image archive report must not leak paths or operator refs');
}
if (
  /\b(?:release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|registry_presence|image_load|image_import|image_push|push_success|import_success|load_success|docker|skopeo|oras|kubectl|pull|push|mirror)\b/.test(
    serialized
  )
) {
  throw new Error('airgap image archive report must not claim readiness or registry/load execution');
}
NODE
}

expect_check_fail() {
  local label="$1"
  local output_dir="$2"
  shift 2

  write_stale_report "$output_dir"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap image archive check failure: $label"
  fi

  assert_no_report "$output_dir"
  pass "airgap image archive check rejected invalid case: $label"
}

manifest_sha="$(create_plain_archive "$VALID_ARCHIVE")"
archive_sha="$(sha256_file "$VALID_ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha"
create_payloads
create_image_archives
write_operator_prerequisites "$OPERATOR_PREREQUISITES"
write_kit_substrate_pack_manifest "$KIT_SUBSTRATE_PACK_MANIFEST"
write_kit_substrate_install_inputs "$KIT_SUBSTRATE_INSTALL_INPUTS" "$KIT_AIRGAP_PROFILE"
create_substrate_image_archives "$IMAGE_DIR" "$KIT_SUBSTRATE_PACK_MANIFEST"
write_probes

VALID_BUNDLE_ROOT="$TMP_DIR/bundle-valid"
VALID_CREATE_OUTPUT="$TMP_DIR/out-create-valid"
run_bundle_create "$VALID_BUNDLE_ROOT" "$VALID_CREATE_OUTPUT" >"$TMP_DIR/create-valid.out"

KIT_BUNDLE_ROOT="$TMP_DIR/bundle-kit-valid"
KIT_CREATE_OUTPUT="$TMP_DIR/out-create-kit-valid"
run_bundle_create \
  "$KIT_BUNDLE_ROOT" \
  "$KIT_CREATE_OUTPUT" \
  "$KIT_AIRGAP_PROFILE" \
  "$KIT_SUBSTRATE_PACK_MANIFEST" \
  "$KIT_SUBSTRATE_INSTALL_INPUTS" >"$TMP_DIR/create-kit-valid.out"

TOP_INDEX_CONTRACT="$TMP_DIR/release-contract.top-index.json"
TOP_INDEX_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.top-index.json"
TOP_INDEX_IMAGE_DIR="$TMP_DIR/image-archives-top-index"
TOP_INDEX_BUNDLE_ROOT="$TMP_DIR/bundle-top-index-valid"
write_materials \
  "$manifest_sha" \
  "$archive_sha" \
  "$TOP_INDEX_CONTRACT" \
  "$TOP_INDEX_DEPLOY_TEMPLATE_PACKAGE" \
  top-level-index
create_image_archives "$TOP_INDEX_IMAGE_DIR" "$TOP_INDEX_CONTRACT" top-level-index
run_bundle_create \
  "$TOP_INDEX_BUNDLE_ROOT" \
  "$TMP_DIR/out-create-top-index-valid" \
  "$AIRGAP_PROFILE" \
  "" \
  "" \
  "$TOP_INDEX_CONTRACT" \
  "$TOP_INDEX_DEPLOY_TEMPLATE_PACKAGE" \
  "$TOP_INDEX_IMAGE_DIR" >"$TMP_DIR/create-top-index-valid.out"

NESTED_INDEX_CONTRACT="$TMP_DIR/release-contract.nested-index.json"
NESTED_INDEX_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.nested-index.json"
NESTED_INDEX_IMAGE_DIR="$TMP_DIR/image-archives-nested-index"
NESTED_INDEX_BUNDLE_ROOT="$TMP_DIR/bundle-nested-index-valid"
write_materials \
  "$manifest_sha" \
  "$archive_sha" \
  "$NESTED_INDEX_CONTRACT" \
  "$NESTED_INDEX_DEPLOY_TEMPLATE_PACKAGE" \
  nested-index
create_image_archives "$NESTED_INDEX_IMAGE_DIR" "$NESTED_INDEX_CONTRACT" nested-index
run_bundle_create \
  "$NESTED_INDEX_BUNDLE_ROOT" \
  "$TMP_DIR/out-create-nested-index-valid" \
  "$AIRGAP_PROFILE" \
  "" \
  "" \
  "$NESTED_INDEX_CONTRACT" \
  "$NESTED_INDEX_DEPLOY_TEMPLATE_PACKAGE" \
  "$NESTED_INDEX_IMAGE_DIR" >"$TMP_DIR/create-nested-index-valid.out"

shim_dir="$TMP_DIR/shims"
mkdir -p "$shim_dir"
for binary in docker skopeo oras kubectl curl wget; do
  cat >"$shim_dir/$binary" <<'SH'
#!/usr/bin/env sh
echo "forbidden tool was called: $(basename "$0")" >&2
exit 99
SH
  chmod +x "$shim_dir/$binary"
done

valid_output_dir="$TMP_DIR/out-image-archive-valid"
PATH="$shim_dir:$PATH" run_image_archive_check "$VALID_BUNDLE_ROOT" "$valid_output_dir" >"$TMP_DIR/image-archive-valid.out"
assert_report "$valid_output_dir/$REPORT_FILE"
if ! tail -n 1 "$TMP_DIR/image-archive-valid.out" | grep -q 'airgap image archive check mode is not release readiness; readiness=false'; then
  cat "$TMP_DIR/image-archive-valid.out" >&2
  fail "airgap image archive check stdout must end with non-readiness wording"
fi
pass "valid airgap image archives matched target digests without calling registry tools"

large_bundle_root="$TMP_DIR/bundle-large-image-archive"
copy_valid_bundle "$large_bundle_root"
large_image_id="agentsmith_app"
large_stream_source="$TMP_DIR/large-image-archive-stream-source.tar"
large_archive_info=()
mapfile -t large_archive_info < <("$NODE_BIN" --input-type=module - \
  "$large_bundle_root" \
  "$large_image_id" \
  "$large_stream_source" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, imageId, streamSource] = process.argv.slice(2);
const manifestPath = path.join(bundleRoot, 'airgap-bundle-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const declaration = manifest.image_artifact_declarations.find((item) => item.id === imageId);
if (!declaration) {
  throw new Error(`missing image declaration: ${imageId}`);
}
const archivePath = path.join(bundleRoot, ...declaration.path.split('/'));
fs.copyFileSync(archivePath, streamSource);
const sourceBody = fs.readFileSync(streamSource);
declaration.sha256 = `sha256:${crypto.createHash('sha256').update(sourceBody).digest('hex')}`;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(archivePath);
console.log(declaration.target_digest);
NODE
)
large_archive_path="${large_archive_info[0]}"
large_target_digest="${large_archive_info[1]}"
cp "$large_stream_source" "$large_archive_path"
truncate -s "$LARGE_FIXTURE_SIZE" "$large_archive_path"
assert_larger_than_2g "$large_archive_path"
large_archive_output_dir="$TMP_DIR/out-image-archive-large"
PATH="$shim_dir:$PATH" \
NODE_OPTIONS="--require=$LARGE_READ_GUARD ${NODE_OPTIONS:-}" \
RELEASE_KIT_TEST_LARGE_STREAM_SOURCE="$large_stream_source" \
RELEASE_KIT_TEST_LARGE_IMAGE_ID="$large_image_id" \
RELEASE_KIT_TEST_LARGE_TARGET_DIGEST="$large_target_digest" \
  run_image_archive_check \
    "$large_bundle_root" \
    "$large_archive_output_dir" \
    "$LARGE_TARGET_DIGEST_PROBE" >"$TMP_DIR/image-archive-large.out"
assert_report "$large_archive_output_dir/$REPORT_FILE"
pass "airgap image archive check streamed >2GiB image artifact digest and OCI layout inspection"

kit_output_dir="$TMP_DIR/out-image-archive-kit"
PATH="$shim_dir:$PATH" run_image_archive_check \
  "$KIT_BUNDLE_ROOT" \
  "$kit_output_dir" \
  "$GOOD_PROBE" \
  "$KIT_AIRGAP_PROFILE" >"$TMP_DIR/image-archive-kit.out"
assert_report "$kit_output_dir/$REPORT_FILE" "$KIT_AIRGAP_PROFILE"
pass "valid kit airgap image archives matched target digests without calling registry tools"

top_index_output_dir="$TMP_DIR/out-image-archive-top-index"
PATH="$shim_dir:$PATH" run_image_archive_check_full \
  "$TOP_INDEX_BUNDLE_ROOT/components/image-map.json" \
  "$AIRGAP_PROFILE" \
  "$TOP_INDEX_BUNDLE_ROOT" \
  "$TOP_INDEX_BUNDLE_ROOT/airgap-bundle-manifest.json" \
  "$GOOD_PROBE" \
  "$top_index_output_dir" \
  "$TOP_INDEX_CONTRACT" \
  "$TOP_INDEX_DEPLOY_TEMPLATE_PACKAGE" >"$TMP_DIR/image-archive-top-index.out"
assert_report "$top_index_output_dir/$REPORT_FILE"
pass "top-level OCI image index archives matched target digests"

nested_index_output_dir="$TMP_DIR/out-image-archive-nested-index"
PATH="$shim_dir:$PATH" run_image_archive_check_full \
  "$NESTED_INDEX_BUNDLE_ROOT/components/image-map.json" \
  "$AIRGAP_PROFILE" \
  "$NESTED_INDEX_BUNDLE_ROOT" \
  "$NESTED_INDEX_BUNDLE_ROOT/airgap-bundle-manifest.json" \
  "$GOOD_PROBE" \
  "$nested_index_output_dir" \
  "$NESTED_INDEX_CONTRACT" \
  "$NESTED_INDEX_DEPLOY_TEMPLATE_PACKAGE" >"$TMP_DIR/image-archive-nested-index.out"
assert_report "$nested_index_output_dir/$REPORT_FILE"
pass "nested OCI image index archives matched target digests"

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE" \
  "alias-offline:$ALIAS_OFFLINE_PROFILE"; do
  label="${profile_case%%:*}"
  profile="${profile_case#*:}"
  expect_check_fail "unsupported-profile-$label" "$TMP_DIR/out-profile-$label" \
    run_image_archive_check "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-profile-$label" "$GOOD_PROBE" "$profile"
done

wrong_digest_bundle="$TMP_DIR/bundle-wrong-digest"
copy_valid_bundle "$wrong_digest_bundle"
mutate_image_archive_digest "$wrong_digest_bundle" agentsmith_app "sha256:7777777777777777777777777777777777777777777777777777777777777777"
expect_check_fail "probe-target-digest-mismatch" "$TMP_DIR/out-wrong-digest" \
  run_image_archive_check "$wrong_digest_bundle" "$TMP_DIR/out-wrong-digest" "$TARGET_ANNOTATION_PROBE"

archive_manifest_mismatch_bundle="$TMP_DIR/bundle-archive-manifest-mismatch"
copy_valid_bundle "$archive_manifest_mismatch_bundle"
mutate_image_archive_manifest_digest_mismatch "$archive_manifest_mismatch_bundle" agentsmith_app
expect_check_fail "archive-manifest-target-digest-mismatch" "$TMP_DIR/out-archive-manifest-mismatch" \
  run_image_archive_check "$archive_manifest_mismatch_bundle" "$TMP_DIR/out-archive-manifest-mismatch" "$TARGET_ANNOTATION_PROBE"
if ! grep -Fq 'archive top-level descriptor digest must match expected target_digest' "$TMP_DIR/archive-manifest-target-digest-mismatch.err"; then
  cat "$TMP_DIR/archive-manifest-target-digest-mismatch.err" >&2
  fail "archive top-level descriptor digest mismatch failure must explain target_digest alignment"
fi
pass "OCI archive descriptor digest check rejected probe target echo mismatch"

missing_layer_bundle="$TMP_DIR/bundle-missing-layer"
copy_valid_bundle "$missing_layer_bundle"
mutate_image_archive_missing_layer "$missing_layer_bundle" afscp
expect_check_fail "missing-layer-blob" "$TMP_DIR/out-missing-layer" \
  run_image_archive_check "$missing_layer_bundle" "$TMP_DIR/out-missing-layer"
if ! grep -Fq 'missing layer blob' "$TMP_DIR/missing-layer-blob.err"; then
  cat "$TMP_DIR/missing-layer-blob.err" >&2
  fail "missing layer blob failure must explain the missing layer/blob"
fi
pass "OCI archive structure check rejected missing layer blob"

manifest_only_bundle="$TMP_DIR/bundle-manifest-only"
copy_valid_bundle "$manifest_only_bundle"
mutate_image_archive_manifest_only "$manifest_only_bundle" asbcp
expect_check_fail "manifest-only-archive" "$TMP_DIR/out-manifest-only" \
  run_image_archive_check "$manifest_only_bundle" "$TMP_DIR/out-manifest-only"
if ! grep -Fq 'must declare at least one layer blob' "$TMP_DIR/manifest-only-archive.err"; then
  cat "$TMP_DIR/manifest-only-archive.err" >&2
  fail "manifest-only failure must explain the missing layer/blob"
fi
pass "OCI archive structure check rejected manifest-only archive"

nested_missing_layer_bundle="$TMP_DIR/bundle-nested-missing-layer"
copy_valid_bundle "$nested_missing_layer_bundle"
mutate_image_archive_nested_missing_layer "$nested_missing_layer_bundle" ingress_nginx_controller
expect_check_fail "nested-missing-layer-blob" "$TMP_DIR/out-nested-missing-layer" \
  run_image_archive_check "$nested_missing_layer_bundle" "$TMP_DIR/out-nested-missing-layer"
if ! grep -Fq 'missing layer blob' "$TMP_DIR/nested-missing-layer-blob.err"; then
  cat "$TMP_DIR/nested-missing-layer-blob.err" >&2
  fail "nested missing layer failure must explain the missing layer/blob"
fi
pass "recursive OCI archive structure check rejected nested missing layer blob"

nested_missing_config_bundle="$TMP_DIR/bundle-nested-missing-config"
copy_valid_bundle "$nested_missing_config_bundle"
mutate_image_archive_nested_missing_config "$nested_missing_config_bundle" ingress_nginx_certgen
expect_check_fail "nested-missing-config-blob" "$TMP_DIR/out-nested-missing-config" \
  run_image_archive_check "$nested_missing_config_bundle" "$TMP_DIR/out-nested-missing-config"
if ! grep -Fq 'missing config blob' "$TMP_DIR/nested-missing-config-blob.err"; then
  cat "$TMP_DIR/nested-missing-config-blob.err" >&2
  fail "nested missing config failure must explain the missing config/blob"
fi
pass "recursive OCI archive structure check rejected nested missing config blob"

nested_empty_index_bundle="$TMP_DIR/bundle-nested-empty-index"
copy_valid_bundle "$nested_empty_index_bundle"
mutate_image_archive_nested_empty_index "$nested_empty_index_bundle" managed_runner
expect_check_fail "nested-empty-index" "$TMP_DIR/out-nested-empty-index" \
  run_image_archive_check "$nested_empty_index_bundle" "$TMP_DIR/out-nested-empty-index"
if ! grep -Fq 'manifests must not be empty' "$TMP_DIR/nested-empty-index.err"; then
  cat "$TMP_DIR/nested-empty-index.err" >&2
  fail "nested empty index failure must explain the empty manifests"
fi
pass "recursive OCI archive structure check rejected nested empty image index"

unknown_media_type_bundle="$TMP_DIR/bundle-unknown-media-type"
copy_valid_bundle "$unknown_media_type_bundle"
mutate_image_archive_unknown_media_type "$unknown_media_type_bundle" agentsmith_app
expect_check_fail "unknown-media-type" "$TMP_DIR/out-unknown-media-type" \
  run_image_archive_check "$unknown_media_type_bundle" "$TMP_DIR/out-unknown-media-type"
if ! grep -Fq 'mediaType is not a supported OCI/Docker image manifest or index' "$TMP_DIR/unknown-media-type.err"; then
  cat "$TMP_DIR/unknown-media-type.err" >&2
  fail "unknown mediaType failure must explain unsupported descriptor mediaType"
fi
pass "OCI archive structure check rejected unknown descriptor mediaType"

placeholder_bundle="$TMP_DIR/bundle-placeholder"
copy_valid_bundle "$placeholder_bundle"
mutate_image_archive_placeholder "$placeholder_bundle" llmup
expect_check_fail "placeholder-archive-probe-invalid" "$TMP_DIR/out-placeholder" \
  run_image_archive_check "$placeholder_bundle" "$TMP_DIR/out-placeholder"

expect_check_fail "probe-multiple-digests" "$TMP_DIR/out-multiple-digests" \
  run_image_archive_check "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-multiple-digests" "$DOUBLE_OUTPUT_PROBE"

expect_check_fail "probe-timeout" "$TMP_DIR/out-timeout" \
  run_image_archive_check "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-timeout" "$TIMEOUT_PROBE"
if ! grep -Fq 'archive probe timed out for image id:' "$TMP_DIR/probe-timeout.err"; then
  cat "$TMP_DIR/probe-timeout.err" >&2
  fail "timeout failure must name image id"
fi
pass "timeout probe failed fast and named image id"

expect_check_fail "missing-archive-probe" "$TMP_DIR/out-missing-probe" \
  run_image_archive_check_full \
    "$VALID_BUNDLE_ROOT/components/image-map.json" \
    "$AIRGAP_PROFILE" \
    "$VALID_BUNDLE_ROOT" \
    "$VALID_BUNDLE_ROOT/airgap-bundle-manifest.json" \
    "" \
    "$TMP_DIR/out-missing-probe"

for forbidden_probe in docker skopeo oras kubectl curl wget; do
  expect_check_fail "forbidden-$forbidden_probe-probe" "$TMP_DIR/out-$forbidden_probe-probe" \
    run_image_archive_check "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-$forbidden_probe-probe" "$shim_dir/$forbidden_probe"
  if grep -Fq 'forbidden tool was called' "$TMP_DIR/forbidden-$forbidden_probe-probe.err"; then
    cat "$TMP_DIR/forbidden-$forbidden_probe-probe.err" >&2
    fail "forbidden $forbidden_probe probe must be rejected before execution"
  fi
  pass "forbidden $forbidden_probe probe executable was not executed"
done

pass "airgap image archive materiality focused diagnostic tests completed"
