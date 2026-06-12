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
NONCANONICAL_PROFILE="local-kind/external_declared/airgap"
ALIAS_OFFLINE_PROFILE="existing_kubernetes/external_declared/offline"
AIRGAP_REGISTRY="registry.example.internal/releases"
REPORT_FILE="airgap-image-load-report.json"
ARCHIVE_CHECK_DIR="airgap-image-archive-check"
ARCHIVE_CHECK_REPORT_FILE="airgap-image-archive-check-report.json"
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
KIT_SUBSTRATE_PACK_MANIFEST="$TMP_DIR/substrate-pack-manifest.kit-airgap.json"
KIT_SUBSTRATE_INSTALL_INPUTS="$TMP_DIR/substrate-install-inputs.kit-airgap.json"
GOOD_PROBE="$TMP_DIR/tools/archive-digest-probe"
GOOD_LOADER="$TMP_DIR/tools/image-loader"
NONZERO_LOADER="$TMP_DIR/tools/nonzero-image-loader"
WRONG_DIGEST_LOADER="$TMP_DIR/tools/wrong-digest-image-loader"
EXTRA_STDOUT_LOADER="$TMP_DIR/tools/extra-stdout-image-loader"
STDERR_LOADER="$TMP_DIR/tools/stderr-image-loader"
LOAD_LOG="$TMP_DIR/image-load.log"

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
const matches = [
  ...body.matchAll(/"io\.agentsmith\.fixture\.target_digest"\s*:\s*"(sha256:[0-9a-f]{64})"/g)
];
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
const matches = [
  ...body.matchAll(/"io\.agentsmith\.fixture\.target_digest"\s*:\s*"(sha256:[0-9a-f]{64})"/g)
];
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

  cat >"$NONZERO_LOADER" <<'NODE'
#!/usr/bin/env node
process.exit(7);
NODE
  chmod +x "$NONZERO_LOADER"

  cat >"$WRONG_DIGEST_LOADER" <<'NODE'
#!/usr/bin/env node
console.log(`sha256:${'9'.repeat(64)}`);
NODE
  chmod +x "$WRONG_DIGEST_LOADER"

  cat >"$EXTRA_STDOUT_LOADER" <<'NODE'
#!/usr/bin/env node
const [, , targetDigest] = process.argv.slice(2);
console.log(targetDigest);
console.log('extra loader progress line');
NODE
  chmod +x "$EXTRA_STDOUT_LOADER"

  cat >"$STDERR_LOADER" <<'NODE'
#!/usr/bin/env node
const [, , targetDigest] = process.argv.slice(2);
console.error('loader progress on stderr');
console.log(targetDigest);
NODE
  chmod +x "$STDERR_LOADER"
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

  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    image_archive_args+=(--image-archive "$id=$image_dir/$id.oci-layout.tar")
  done
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

run_image_load_full() {
  local image_map="$1"
  local target_profile="$2"
  local bundle_root="$3"
  local bundle_manifest="$4"
  local archive_probe="$5"
  local image_loader="$6"
  local output_dir="$7"
  local release_contract="${8:-$VALID_CONTRACT}"
  local deploy_template_package="${9:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-image-load \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$VALID_ARCHIVE" \
    --image-map "$image_map" \
    --target-profile "$target_profile" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_manifest" \
    --archive-probe "$archive_probe" \
    --image-loader "$image_loader" \
    --output-dir "$output_dir"
}

run_image_load() {
  local bundle_root="$1"
  local output_dir="$2"
  local image_loader="${3:-$GOOD_LOADER}"
  local target_profile="${4:-$AIRGAP_PROFILE}"

  run_image_load_full \
    "$bundle_root/components/image-map.json" \
    "$target_profile" \
    "$bundle_root" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$GOOD_PROBE" \
    "$image_loader" \
    "$output_dir"
}

write_stale_reports() {
  local output_dir="$1"

  mkdir -p "$output_dir/$ARCHIVE_CHECK_DIR"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
  printf '%s\n' '{"stale":true}' >"$output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE"
}

assert_no_reports() {
  local output_dir="$1"

  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "unexpected airgap image load report exists: $output_dir/$REPORT_FILE"
  [[ ! -e "$output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE" ]] || fail "unexpected nested archive check report exists: $output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE"
}

copy_valid_bundle() {
  local destination="$1"

  rm -rf "$destination"
  cp -R "$VALID_BUNDLE_ROOT" "$destination"
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
  local archive_check_report_file="$2"
  local expected_profile="${3:-$AIRGAP_PROFILE}"

  "$NODE_BIN" --input-type=module - "$report_file" "$archive_check_report_file" "$VALID_CONTRACT" "$GOOD_LOADER" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, archiveCheckReportFile, validContract, loaderPath, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const archiveCheckReport = JSON.parse(fs.readFileSync(archiveCheckReportFile, 'utf8'));
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
      key === 'loader' ||
      key === 'image_loader' ||
      key === 'loader_path' ||
      key === 'raw_loader_output' ||
      key === 'loader_stdout' ||
      key === 'loader_stderr' ||
      key === 'stdout' ||
      key === 'stderr' ||
      key === 'archive_path' ||
      key === 'bundle_root' ||
      key === 'bundleRoot' ||
      key === 'target_image' ||
      key === 'target_registry' ||
      key === 'location' ||
      key === 'proof'
    ) {
      throw new Error(`airgap image load report must not include leak-prone key: ${path}.${key}`);
    }
    assertNoLeakKeys(item, `${path}.${key}`);
  }
}

if (report.schema !== 'agentsmith.airgap-image-load-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'airgap_image_load_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('airgap image load report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.load_count !== expectedImageCount) {
  throw new Error(`unexpected load count: ${report.load_count}`);
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
  throw new Error('report must summarize each image load');
}
for (const [label, digest] of Object.entries(report.digest_summary || {})) {
  if (!digestRe.test(digest)) {
    throw new Error(`digest summary missing sha256 for ${label}`);
  }
}
if (!digestRe.test(report.digest_summary?.airgap_image_archive_check_report_input_sha256)) {
  throw new Error('load report must bind nested archive-check report digest');
}
for (const image of report.images) {
  if (!report.image_ids.includes(image.id)) {
    throw new Error(`unexpected image id in summary: ${image.id}`);
  }
  for (const field of ['target_digest', 'archive_sha256', 'loader_digest']) {
    if (!digestRe.test(image[field])) {
      throw new Error(`image ${image.id} missing ${field}`);
    }
  }
  if (image.loader_digest !== image.target_digest) {
    throw new Error(`loader digest must match target digest for ${image.id}`);
  }
}
if (report.image_load_summary?.load_count !== expectedImageCount) {
  throw new Error('image load summary must count loads');
}
if (report.image_load_summary?.loader_digest_count !== expectedImageCount) {
  throw new Error('image load summary must count loader digests');
}
if (archiveCheckReport.schema !== 'agentsmith.airgap-image-archive-check-report/v1') {
  throw new Error(`unexpected nested archive-check schema: ${archiveCheckReport.schema}`);
}
if (archiveCheckReport.readiness !== false) {
  throw new Error('nested archive-check report must keep readiness=false');
}
assertNoLeakKeys(report);
if (
  serialized.includes('/tmp/') ||
  serialized.includes(loaderPath) ||
  /operator held|operator workstation|signed operator prerequisite/.test(serialized)
) {
  throw new Error('airgap image load report must not leak paths, loader path, or operator refs');
}
if (
  /\b(?:release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|registry_presence|image_push|push_success|import_success|load_success|deploy_success)\b/.test(
    serialized
  )
) {
  throw new Error('airgap image load report must not claim deploy/package/release readiness');
}
NODE
}

expect_load_fail() {
  local label="$1"
  local output_dir="$2"
  shift 2

  write_stale_reports "$output_dir"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap image load failure: $label"
  fi

  assert_no_reports "$output_dir"
  pass "airgap image load rejected invalid case: $label"
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
write_tools

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

valid_output_dir="$TMP_DIR/out-image-load-valid"
PATH="$shim_dir:$PATH" AGENTSMITH_LOAD_LOG="$LOAD_LOG" run_image_load "$VALID_BUNDLE_ROOT" "$valid_output_dir" >"$TMP_DIR/image-load-valid.out"
assert_report "$valid_output_dir/$REPORT_FILE" "$valid_output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE"
load_count="$(grep -c '^sha256:' "$LOAD_LOG")"
[[ "$load_count" -eq "${#RELEASE_IMAGE_IDS[@]}" ]] || fail "image loader must run exactly once per image"
if ! tail -n 1 "$TMP_DIR/image-load-valid.out" | grep -q 'airgap image load mode is not release readiness; readiness=false'; then
  cat "$TMP_DIR/image-load-valid.out" >&2
  fail "airgap image load stdout must end with non-readiness wording"
fi
pass "valid airgap image archives loaded through operator loader without release readiness"

: >"$LOAD_LOG"
kit_output_dir="$TMP_DIR/out-image-load-kit"
PATH="$shim_dir:$PATH" AGENTSMITH_LOAD_LOG="$LOAD_LOG" run_image_load \
  "$KIT_BUNDLE_ROOT" \
  "$kit_output_dir" \
  "$GOOD_LOADER" \
  "$KIT_AIRGAP_PROFILE" >"$TMP_DIR/image-load-kit.out"
assert_report \
  "$kit_output_dir/$REPORT_FILE" \
  "$kit_output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE" \
  "$KIT_AIRGAP_PROFILE"
kit_load_count="$(grep -c '^sha256:' "$LOAD_LOG")"
[[ "$kit_load_count" -eq "$((${#RELEASE_IMAGE_IDS[@]} + 5))" ]] || fail "kit image loader must run exactly once per release and substrate image"
pass "valid kit airgap image archives loaded through operator loader without release readiness"

: >"$LOAD_LOG"
top_index_output_dir="$TMP_DIR/out-image-load-top-index"
PATH="$shim_dir:$PATH" AGENTSMITH_LOAD_LOG="$LOAD_LOG" run_image_load_full \
  "$TOP_INDEX_BUNDLE_ROOT/components/image-map.json" \
  "$AIRGAP_PROFILE" \
  "$TOP_INDEX_BUNDLE_ROOT" \
  "$TOP_INDEX_BUNDLE_ROOT/airgap-bundle-manifest.json" \
  "$GOOD_PROBE" \
  "$GOOD_LOADER" \
  "$top_index_output_dir" \
  "$TOP_INDEX_CONTRACT" \
  "$TOP_INDEX_DEPLOY_TEMPLATE_PACKAGE" >"$TMP_DIR/image-load-top-index.out"
assert_report \
  "$top_index_output_dir/$REPORT_FILE" \
  "$top_index_output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE"
top_index_load_count="$(grep -c '^sha256:' "$LOAD_LOG")"
[[ "$top_index_load_count" -eq "${#RELEASE_IMAGE_IDS[@]}" ]] || fail "top-level index image loader must run exactly once per image"
pass "top-level OCI image index archives loaded through operator loader without release readiness"

: >"$LOAD_LOG"
nested_index_output_dir="$TMP_DIR/out-image-load-nested-index"
PATH="$shim_dir:$PATH" AGENTSMITH_LOAD_LOG="$LOAD_LOG" run_image_load_full \
  "$NESTED_INDEX_BUNDLE_ROOT/components/image-map.json" \
  "$AIRGAP_PROFILE" \
  "$NESTED_INDEX_BUNDLE_ROOT" \
  "$NESTED_INDEX_BUNDLE_ROOT/airgap-bundle-manifest.json" \
  "$GOOD_PROBE" \
  "$GOOD_LOADER" \
  "$nested_index_output_dir" \
  "$NESTED_INDEX_CONTRACT" \
  "$NESTED_INDEX_DEPLOY_TEMPLATE_PACKAGE" >"$TMP_DIR/image-load-nested-index.out"
assert_report \
  "$nested_index_output_dir/$REPORT_FILE" \
  "$nested_index_output_dir/$ARCHIVE_CHECK_DIR/$ARCHIVE_CHECK_REPORT_FILE"
nested_index_load_count="$(grep -c '^sha256:' "$LOAD_LOG")"
[[ "$nested_index_load_count" -eq "${#RELEASE_IMAGE_IDS[@]}" ]] || fail "nested index image loader must run exactly once per image"
pass "nested OCI image index archives loaded through operator loader without release readiness"

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE" \
  "noncanonical:$NONCANONICAL_PROFILE" \
  "alias-offline:$ALIAS_OFFLINE_PROFILE"; do
  label="${profile_case%%:*}"
  profile="${profile_case#*:}"
  expect_load_fail "unsupported-profile-$label" "$TMP_DIR/out-profile-$label" \
    run_image_load "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-profile-$label" "$GOOD_LOADER" "$profile"
done

placeholder_bundle="$TMP_DIR/bundle-placeholder"
copy_valid_bundle "$placeholder_bundle"
mutate_image_archive_placeholder "$placeholder_bundle" llmup
expect_load_fail "missing-archive-materiality" "$TMP_DIR/out-placeholder" \
  run_image_load "$placeholder_bundle" "$TMP_DIR/out-placeholder"

expect_load_fail "loader-nonzero" "$TMP_DIR/out-loader-nonzero" \
  run_image_load "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-loader-nonzero" "$NONZERO_LOADER"

expect_load_fail "loader-target-digest-mismatch" "$TMP_DIR/out-loader-digest-mismatch" \
  run_image_load "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-loader-digest-mismatch" "$WRONG_DIGEST_LOADER"

expect_load_fail "loader-extra-stdout" "$TMP_DIR/out-loader-extra-stdout" \
  run_image_load "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-loader-extra-stdout" "$EXTRA_STDOUT_LOADER"

expect_load_fail "loader-stderr" "$TMP_DIR/out-loader-stderr" \
  run_image_load "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-loader-stderr" "$STDERR_LOADER"

pass "airgap image load focused diagnostic tests completed"
