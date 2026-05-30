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
  report.artifacts?.airgap_bundle_check_report?.input_sha256
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

assert_kit_bundle_and_report() {
  local bundle_root="$1"
  local output_dir="$2"
  local substrate_pack_manifest="$3"

  "$NODE_BIN" --input-type=module - \
    "$bundle_root" \
    "$output_dir/$REPORT_FILE" \
    "$output_dir/$CHECK_REPORT_FILE" \
    "$substrate_pack_manifest" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, reportFile, checkReportFile, substratePackManifest] =
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
const packComponent = manifest.components.find((component) => (
  component.kind === 'substrate_pack_manifest'
));

if (report.target_profile?.value !== 'existing_kubernetes/kit_installed/airgap') {
  throw new Error(`unexpected kit create target profile: ${report.target_profile?.value}`);
}
if (checkReport.target_profile?.value !== 'existing_kubernetes/kit_installed/airgap') {
  throw new Error(`unexpected kit bundle-check target profile: ${checkReport.target_profile?.value}`);
}
if (manifest.target_profile?.value !== 'existing_kubernetes/kit_installed/airgap') {
  throw new Error(`unexpected kit manifest target profile: ${manifest.target_profile?.value}`);
}
if (manifest.substrate?.mode !== 'kit_installed' || manifest.substrate?.bundled !== true) {
  throw new Error('kit airgap manifest substrate summary must be kit_installed and bundled');
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
if (report.components_count !== 5 || checkReport.components_count !== 5) {
  throw new Error('kit airgap reports must count the substrate pack component');
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

manifest_sha="$(create_plain_archive "$VALID_ARCHIVE")"
archive_sha="$(sha256_file "$VALID_ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha"
create_payloads
create_image_archives
write_operator_prerequisites "$OPERATOR_PREREQUISITES"
write_kit_substrate_pack_manifest "$KIT_SUBSTRATE_PACK" "$KIT_AIRGAP_PROFILE"
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

valid_kit_bundle_root="$TMP_DIR/bundle-valid-kit"
valid_kit_output_dir="$TMP_DIR/out-valid-kit"
run_bundle_create_full "$KIT_AIRGAP_PROFILE" "$AIRGAP_REGISTRY" "$valid_kit_bundle_root" "$valid_kit_output_dir" \
  "${default_image_args[@]}" \
  "${common_payload_args[@]}" \
  --substrate-pack-manifest "$KIT_SUBSTRATE_PACK" >"$TMP_DIR/valid-create-kit.out"
assert_kit_bundle_and_report "$valid_kit_bundle_root" "$valid_kit_output_dir" "$KIT_SUBSTRATE_PACK"
pass "valid kit-installed airgap bundle create binds substrate pack manifest"

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
    "${common_payload_args[@]}"

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
