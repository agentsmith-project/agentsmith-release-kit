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
AIRGAP_REGISTRY="registry.example.internal/releases"
REPORT_FILE="airgap-bundle-render-check-report.json"
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

PAYLOAD_DIR="$TMP_DIR/payload"
IMAGE_DIR="$TMP_DIR/image-archives"
OPERATOR_PREREQUISITES="$TMP_DIR/operator-prerequisites.json"
KIT_SUBSTRATE_PACK_MANIFEST="$TMP_DIR/substrate-pack-manifest.kit-airgap.json"

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

if (substrateSource === 'kit_installed') {
  truth.installed_by = 'agentsmith-release-kit';
  truth.release_kit_version = '0.1.0';
  truth.installation_id = 'kit-install-10001';
}

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_kit_substrate_pack_manifest() {
  local output="$1"

  "$NODE_BIN" --input-type=module - "$output" "$KIT_AIRGAP_PROFILE" <<'NODE'
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
    checks: {
      path: 'tools/substrate-checks.txt',
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

write_render_values() {
  local output="$1"

  "$NODE_BIN" --input-type=module - "$output" <<'NODE'
import fs from 'node:fs';

const [output] = process.argv.slice(2);
const values = {
  namespace: 'agentsmith',
  replicas: 2,
  release_channel: 'stable'
};

fs.writeFileSync(output, `${JSON.stringify(values, null, 2)}\n`);
NODE
}

create_render_archive() {
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
  labels:
    release: ${{ release.release_id }}
    distribution: ${{ target.distribution }}
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
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: agentsmith-maintenance
  namespace: ${{ values.namespace }}
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: llmup
              image: ${{ images.llmup.image }}
YAML
      ;;
    hardcoded_source_image)
      "$NODE_BIN" --input-type=module - "$FIXTURE_CONTRACT" "$package_dir/templates/workloads.yaml" <<'NODE'
import fs from 'node:fs';

const [contractInput, output] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const sourceImage = contract.deploy_image_inventory.find((item) => item.id === 'agentsmith_app').image;
const yaml = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-image-hardcoded
  namespace: \${{ values.namespace }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${sourceImage}
`;

fs.writeFileSync(output, yaml);
NODE
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
  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    printf 'local oci layout tar placeholder for %s\n' "$id" >"$IMAGE_DIR/$id.oci-layout.tar"
  done
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

run_bundle_create() {
  local release_contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local bundle_root="$4"
  local output_dir="$5"
  local target_profile="${6:-$AIRGAP_PROFILE}"
  local substrate_pack_manifest="${7:-}"
  local image_archive_args=()
  local substrate_pack_args=()

  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    image_archive_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
  done
  if [[ -n "$substrate_pack_manifest" ]]; then
    substrate_pack_args+=(--substrate-pack-manifest "$substrate_pack_manifest")
  fi

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
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
}

write_bundle_render_inputs() {
  local bundle_root="$1"
  local target_profile="${2:-$AIRGAP_PROFILE}"

  mkdir -p "$bundle_root/operator-inputs"
  write_render_values "$bundle_root/operator-inputs/render-values.json"
  write_truth "$bundle_root/operator-inputs/substrate-truth.json" "$target_profile"
}

run_airgap_bundle_render_check() {
  local bundle_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$AIRGAP_PROFILE}"
  local release_contract="${4:-$bundle_root/components/release-contract.json}"
  local deploy_template_package="${5:-$bundle_root/components/deploy-template-package.json}"
  local archive="${6:-$bundle_root/components/agentsmith-deploy-template-package.tgz}"
  local image_map="${7:-$bundle_root/components/image-map.json}"
  local bundle_manifest="${8:-$bundle_root/airgap-bundle-manifest.json}"
  local render_values="${9:-$bundle_root/operator-inputs/render-values.json}"
  local substrate_truth="${10:-$bundle_root/operator-inputs/substrate-truth.json}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-bundle-render-check \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --image-map "$image_map" \
    --target-profile "$target_profile" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_manifest" \
    --render-values "$render_values" \
    --substrate-truth "$substrate_truth" \
    --output-dir "$output_dir"
}

assert_no_report() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "unexpected airgap bundle render-check report exists: $output_dir/$REPORT_FILE"
}

write_stale_report() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
}

copy_valid_bundle() {
  local destination="$1"

  rm -rf "$destination"
  cp -R "$VALID_BUNDLE_ROOT" "$destination"
}

mutate_bundle_manifest() {
  local bundle_root="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$bundle_root" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, mutation] = process.argv.slice(2);
const manifestPath = path.join(bundleRoot, 'airgap-bundle-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

switch (mutation) {
  case 'component_sha_mismatch':
    manifest.components[0].sha256 = `sha256:${'8'.repeat(64)}`;
    break;
  default:
    throw new Error(`unknown bundle manifest mutation: ${mutation}`);
}

fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"
  local expected_profile="${2:-$AIRGAP_PROFILE}"

  "$NODE_BIN" --input-type=module - "$report_file" "$AIRGAP_REGISTRY" "$VALID_CONTRACT" "$expected_profile" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedRegistry, validContract, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedImageMapCount = JSON.parse(
  fs.readFileSync(validContract, 'utf8')
).deploy_image_inventory.length;

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
      key === 'bundle_root' ||
      key === 'bundleRoot' ||
      key === 'location' ||
      key === 'proof' ||
      key.endsWith('_ref')
    ) {
      throw new Error(`airgap bundle render-check report must not include leak-prone key: ${path}.${key}`);
    }
    assertNoLeakKeys(item, `${path}.${key}`);
  }
}

if (report.schema !== 'agentsmith.airgap-bundle-render-check-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'airgap_bundle_render_check_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('airgap bundle render-check report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (Object.prototype.hasOwnProperty.call(report, 'target_registry')) {
  throw new Error('airgap bundle render-check report must not include target_registry');
}
if (report.image_inventory?.image_map_image_count !== expectedImageMapCount) {
  throw new Error(`unexpected image-map image count: ${report.image_inventory?.image_map_image_count}`);
}
if (report.image_inventory?.rendered_image_count !== 2) {
  throw new Error(`unexpected rendered image count: ${report.image_inventory?.rendered_image_count}`);
}
if (report.image_inventory?.rendered_target_image_count !== report.image_inventory?.rendered_image_count) {
  throw new Error('rendered target image count must match rendered image count');
}
if (serialized.includes(expectedRegistry)) {
  throw new Error('airgap bundle render-check report must not include target registry topology');
}
for (const [label, digest] of Object.entries(report.digest_summary || {})) {
  if (typeof digest !== 'string' || !digest.startsWith('sha256:')) {
    throw new Error(`digest summary missing sha256 for ${label}`);
  }
}
const expectedComponentCount = expectedProfile.includes('/kit_installed/') ? 5 : 4;
if (!Array.isArray(report.bundle_components) || report.bundle_components.length !== expectedComponentCount) {
  throw new Error(`report must summarize ${expectedComponentCount} bundle component paths`);
}
assertNoLeakKeys(report);
if (
  /\b(?:release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|deploy_ready|package_ready|registry_presence|registry_present|image_load|image_import|image_push|push_success|import_success|load_success|kubectl_apply|smoke_success)\b/.test(
    serialized
  )
) {
  throw new Error('airgap bundle render-check report must not claim readiness, install, registry, apply, or smoke evidence');
}
if (/\/tmp\/|operator held|operator workstation|signed operator prerequisite/.test(serialized)) {
  throw new Error('airgap bundle render-check report must not leak absolute paths or operator refs');
}
NODE
}

expect_render_check_fail() {
  local label="$1"
  local output_dir="$2"
  shift 2

  write_stale_report "$output_dir"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap bundle render-check failure: $label"
  fi

  assert_no_report "$output_dir"
  pass "airgap bundle render-check rejected invalid case: $label"
}

expect_render_check_fail_with_stderr() {
  local label="$1"
  local output_dir="$2"
  local expected_stderr="$3"
  shift 3

  write_stale_report "$output_dir"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap bundle render-check failure: $label"
  fi

  if ! grep -Fq "$expected_stderr" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap bundle render-check stderr to contain '$expected_stderr': $label"
  fi

  assert_no_report "$output_dir"
  pass "airgap bundle render-check rejected invalid case: $label"
}

create_payloads
create_image_archives
write_operator_prerequisites "$OPERATOR_PREREQUISITES"
write_kit_substrate_pack_manifest "$KIT_SUBSTRATE_PACK_MANIFEST"

VALID_ARCHIVE="$TMP_DIR/valid.tgz"
VALID_MANIFEST_SHA="$(create_render_archive valid "$VALID_ARCHIVE" valid)"
VALID_ARCHIVE_SHA="$(sha256_file "$VALID_ARCHIVE")"
VALID_CONTRACT="$TMP_DIR/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.valid.json"
write_materials "$VALID_MANIFEST_SHA" "$VALID_ARCHIVE_SHA" "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE"

VALID_BUNDLE_ROOT="$TMP_DIR/bundle-valid"
VALID_CREATE_OUTPUT="$TMP_DIR/out-create-valid"
run_bundle_create \
  "$VALID_CONTRACT" \
  "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$VALID_BUNDLE_ROOT" \
  "$VALID_CREATE_OUTPUT" >"$TMP_DIR/create-valid.out"
write_bundle_render_inputs "$VALID_BUNDLE_ROOT"

KIT_BUNDLE_ROOT="$TMP_DIR/bundle-kit-valid"
KIT_CREATE_OUTPUT="$TMP_DIR/out-create-kit-valid"
run_bundle_create \
  "$VALID_CONTRACT" \
  "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$KIT_BUNDLE_ROOT" \
  "$KIT_CREATE_OUTPUT" \
  "$KIT_AIRGAP_PROFILE" \
  "$KIT_SUBSTRATE_PACK_MANIFEST" >"$TMP_DIR/create-kit-valid.out"
write_bundle_render_inputs "$KIT_BUNDLE_ROOT" "$KIT_AIRGAP_PROFILE"

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

valid_output_dir="$TMP_DIR/out-render-check-valid"
PATH="$shim_dir:$PATH" run_airgap_bundle_render_check "$VALID_BUNDLE_ROOT" "$valid_output_dir" >"$TMP_DIR/render-check-valid.out"
assert_report "$valid_output_dir/$REPORT_FILE"
if ! tail -n 1 "$TMP_DIR/render-check-valid.out" | grep -q 'airgap bundle render check mode is not release readiness; readiness=false'; then
  cat "$TMP_DIR/render-check-valid.out" >&2
  fail "airgap bundle render-check stdout must end with non-readiness wording"
fi
pass "valid airgap bundle rendered offline and passed target image inventory check"

kit_output_dir="$TMP_DIR/out-render-check-kit"
PATH="$shim_dir:$PATH" run_airgap_bundle_render_check \
  "$KIT_BUNDLE_ROOT" \
  "$kit_output_dir" \
  "$KIT_AIRGAP_PROFILE" >"$TMP_DIR/render-check-kit.out"
assert_report "$kit_output_dir/$REPORT_FILE" "$KIT_AIRGAP_PROFILE"
pass "valid kit airgap bundle rendered offline and passed target image inventory check"

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE"; do
  label="${profile_case%%:*}"
  profile="${profile_case#*:}"
  expect_render_check_fail "unsupported-profile-$label" "$TMP_DIR/out-profile-$label" \
    run_airgap_bundle_render_check "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-profile-$label" "$profile"
done

outside_contract="$TMP_DIR/outside-release-contract.json"
cp "$VALID_BUNDLE_ROOT/components/release-contract.json" "$outside_contract"
expect_render_check_fail "release-contract-outside-bundle" "$TMP_DIR/out-outside-contract" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-outside-contract" \
    "$AIRGAP_PROFILE" \
    "$outside_contract"

outside_values="$TMP_DIR/render-values.outside.json"
write_render_values "$outside_values"
expect_render_check_fail "render-values-outside-bundle" "$TMP_DIR/out-outside-values" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-outside-values" \
    "$AIRGAP_PROFILE" \
    "$VALID_BUNDLE_ROOT/components/release-contract.json" \
    "$VALID_BUNDLE_ROOT/components/deploy-template-package.json" \
    "$VALID_BUNDLE_ROOT/components/agentsmith-deploy-template-package.tgz" \
    "$VALID_BUNDLE_ROOT/components/image-map.json" \
    "$VALID_BUNDLE_ROOT/airgap-bundle-manifest.json" \
    "$outside_values"

outside_truth="$TMP_DIR/substrate-truth.outside.json"
write_truth "$outside_truth"
expect_render_check_fail "substrate-truth-outside-bundle" "$TMP_DIR/out-outside-truth" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-outside-truth" \
    "$AIRGAP_PROFILE" \
    "$VALID_BUNDLE_ROOT/components/release-contract.json" \
    "$VALID_BUNDLE_ROOT/components/deploy-template-package.json" \
    "$VALID_BUNDLE_ROOT/components/agentsmith-deploy-template-package.tgz" \
    "$VALID_BUNDLE_ROOT/components/image-map.json" \
    "$VALID_BUNDLE_ROOT/airgap-bundle-manifest.json" \
    "$VALID_BUNDLE_ROOT/operator-inputs/render-values.json" \
    "$outside_truth"

final_symlink_bundle="$TMP_DIR/bundle-final-symlink"
copy_valid_bundle "$final_symlink_bundle"
ln -s "$final_symlink_bundle/components/release-contract.json" \
  "$final_symlink_bundle/components/release-contract-link.json"
expect_render_check_fail "release-contract-final-symlink" "$TMP_DIR/out-final-symlink" \
  run_airgap_bundle_render_check \
    "$final_symlink_bundle" \
    "$TMP_DIR/out-final-symlink" \
    "$AIRGAP_PROFILE" \
    "$final_symlink_bundle/components/release-contract-link.json"

parent_symlink_bundle="$TMP_DIR/bundle-parent-symlink"
copy_valid_bundle "$parent_symlink_bundle"
escaped_parent="$TMP_DIR/escaped-parent"
mkdir -p "$escaped_parent"
cp "$parent_symlink_bundle/components/release-contract.json" "$escaped_parent/release-contract.json"
ln -s "$escaped_parent" "$parent_symlink_bundle/components-link"
expect_render_check_fail "release-contract-parent-symlink-path-escape" "$TMP_DIR/out-parent-symlink" \
  run_airgap_bundle_render_check \
    "$parent_symlink_bundle" \
    "$TMP_DIR/out-parent-symlink" \
    "$AIRGAP_PROFILE" \
    "$parent_symlink_bundle/components-link/release-contract.json"

expect_render_check_fail "release-contract-parent-segment" "$TMP_DIR/out-parent-segment" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-parent-segment" \
    "$AIRGAP_PROFILE" \
    "$VALID_BUNDLE_ROOT/components/../components/release-contract.json"

expect_render_check_fail "release-contract-file-uri-double-slash" "$TMP_DIR/out-file-uri-double-slash" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-file-uri-double-slash" \
    "$AIRGAP_PROFILE" \
    "file://$VALID_BUNDLE_ROOT/components/release-contract.json"

expect_render_check_fail "release-contract-file-uri-single-slash" "$TMP_DIR/out-file-uri-single-slash" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-file-uri-single-slash" \
    "$AIRGAP_PROFILE" \
    "file:$VALID_BUNDLE_ROOT/components/release-contract.json"

expect_render_check_fail "release-contract-windows-drive-path" "$TMP_DIR/out-windows-drive" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-windows-drive" \
    "$AIRGAP_PROFILE" \
    'C:\release\release-contract.json'

expect_render_check_fail "release-contract-unc-path" "$TMP_DIR/out-unc-path" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-unc-path" \
    "$AIRGAP_PROFILE" \
    '\\server\share\release-contract.json'

expect_render_check_fail_with_stderr "release-contract-forward-slash-unc-path" "$TMP_DIR/out-forward-slash-unc-path" \
  "release contract must be a local POSIX path" \
  run_airgap_bundle_render_check \
    "$VALID_BUNDLE_ROOT" \
    "$TMP_DIR/out-forward-slash-unc-path" \
    "$AIRGAP_PROFILE" \
    '//server/share/release-contract.json'

missing_component_bundle="$TMP_DIR/bundle-missing-component"
copy_valid_bundle "$missing_component_bundle"
rm "$missing_component_bundle/components/agentsmith-deploy-template-package.tgz"
expect_render_check_fail "missing-archive-component" "$TMP_DIR/out-missing-component" \
  run_airgap_bundle_render_check "$missing_component_bundle" "$TMP_DIR/out-missing-component"

digest_mismatch_bundle="$TMP_DIR/bundle-digest-mismatch"
copy_valid_bundle "$digest_mismatch_bundle"
mutate_bundle_manifest "$digest_mismatch_bundle" component_sha_mismatch
expect_render_check_fail "bundle-digest-mismatch" "$TMP_DIR/out-digest-mismatch" \
  run_airgap_bundle_render_check "$digest_mismatch_bundle" "$TMP_DIR/out-digest-mismatch"

SOURCE_ARCHIVE="$TMP_DIR/hardcoded-source.tgz"
SOURCE_MANIFEST_SHA="$(create_render_archive hardcoded-source "$SOURCE_ARCHIVE" hardcoded_source_image)"
SOURCE_ARCHIVE_SHA="$(sha256_file "$SOURCE_ARCHIVE")"
SOURCE_CONTRACT="$TMP_DIR/release-contract.hardcoded-source.json"
SOURCE_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.hardcoded-source.json"
write_materials "$SOURCE_MANIFEST_SHA" "$SOURCE_ARCHIVE_SHA" "$SOURCE_CONTRACT" "$SOURCE_DEPLOY_TEMPLATE_PACKAGE"

SOURCE_BUNDLE_ROOT="$TMP_DIR/bundle-hardcoded-source"
SOURCE_CREATE_OUTPUT="$TMP_DIR/out-create-hardcoded-source"
run_bundle_create \
  "$SOURCE_CONTRACT" \
  "$SOURCE_DEPLOY_TEMPLATE_PACKAGE" \
  "$SOURCE_ARCHIVE" \
  "$SOURCE_BUNDLE_ROOT" \
  "$SOURCE_CREATE_OUTPUT" >"$TMP_DIR/create-hardcoded-source.out"
write_bundle_render_inputs "$SOURCE_BUNDLE_ROOT"
expect_render_check_fail "rendered-source-image-not-target" "$TMP_DIR/out-source-image" \
  run_airgap_bundle_render_check "$SOURCE_BUNDLE_ROOT" "$TMP_DIR/out-source-image"

pass "airgap-bundle-render-check focused diagnostic tests completed"
