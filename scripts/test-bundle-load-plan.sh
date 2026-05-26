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
REPORT_FILE="airgap-bundle-load-plan-report.json"
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
  local bundle_root="$1"
  local output_dir="$2"
  local image_archive_args=()

  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    image_archive_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
  done

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    --archive "$VALID_ARCHIVE" \
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

run_bundle_load_plan_full() {
  local image_map="$1"
  local target_profile="$2"
  local bundle_root="$3"
  local bundle_manifest="$4"
  local output_dir="$5"

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-load-plan \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    --archive "$VALID_ARCHIVE" \
    --image-map "$image_map" \
    --target-profile "$target_profile" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_manifest" \
    --output-dir "$output_dir"
}

run_bundle_load_plan() {
  local bundle_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$AIRGAP_PROFILE}"

  run_bundle_load_plan_full \
    "$bundle_root/components/image-map.json" \
    "$target_profile" \
    "$bundle_root" \
    "$bundle_root/airgap-bundle-manifest.json" \
    "$output_dir"
}

write_stale_reports() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
  printf '%s\n' '{"stale":true}' >"$output_dir/$CHECK_REPORT_FILE"
}

assert_no_reports() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "unexpected bundle load plan report exists: $output_dir/$REPORT_FILE"
  [[ ! -e "$output_dir/$CHECK_REPORT_FILE" ]] || fail "unexpected airgap bundle check report exists: $output_dir/$CHECK_REPORT_FILE"
}

copy_valid_bundle() {
  local destination="$1"

  rm -rf "$destination"
  cp -R "$VALID_BUNDLE_ROOT" "$destination"
}

mutate_bundle() {
  local bundle_root="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$bundle_root" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, mutation] = process.argv.slice(2);
const manifestPath = path.join(bundleRoot, 'airgap-bundle-manifest.json');
const imageMapPath = path.join(bundleRoot, 'components/image-map.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const imageMap = JSON.parse(fs.readFileSync(imageMapPath, 'utf8'));

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function rewriteImageMap() {
  fs.writeFileSync(imageMapPath, `${JSON.stringify(imageMap, null, 2)}\n`);
  const imageMapSha = digestFile(imageMapPath);
  manifest.bindings.image_map_sha256 = imageMapSha;
  const imageMapComponent = manifest.components.find((component) => component.kind === 'image_map');
  imageMapComponent.sha256 = imageMapSha;
}

function rewriteTargetRegistry(targetRegistry) {
  const previousTargetRegistry = imageMap.target_registry;
  imageMap.target_registry = targetRegistry;
  for (const mapping of imageMap.mappings) {
    mapping.target_image = mapping.target_image.replace(
      `${previousTargetRegistry}/`,
      `${targetRegistry}/`
    );
    const declaration = manifest.image_artifact_declarations.find(
      (item) => item.id === mapping.id
    );
    declaration.target_image = mapping.target_image;
  }
  rewriteImageMap();
}

switch (mutation) {
  case 'missing_image_artifact':
    manifest.image_artifact_declarations.shift();
    break;
  case 'target_registry_mismatch':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      imageMap.target_registry,
      'registry.invalid.example/releases'
    );
    manifest.image_artifact_declarations[0].target_image = imageMap.mappings[0].target_image;
    rewriteImageMap();
    break;
  case 'secret_target_registry':
    rewriteTargetRegistry(
      `registry.example.internal/${'s'}${'k'}-${'abcdefghijklmnopqrstuvwxyz123456'}`
    );
    break;
  case 'target_digest_mismatch':
    imageMap.mappings[0].target_digest = `sha256:${'2'.repeat(64)}`;
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /@sha256:[0-9a-f]{64}$/,
      `@${imageMap.mappings[0].target_digest}`
    );
    manifest.image_artifact_declarations[0].target_digest = imageMap.mappings[0].target_digest;
    manifest.image_artifact_declarations[0].target_image = imageMap.mappings[0].target_image;
    rewriteImageMap();
    break;
  case 'mirror_required_false':
    imageMap.mirror_required = false;
    rewriteImageMap();
    break;
  case 'action_mismatch':
    imageMap.mappings[0].action = 'use_source';
    rewriteImageMap();
    break;
  case 'missing_registry_proof':
    delete manifest.operator_prerequisites.target_registry_proof_ref;
    break;
  case 'missing_tool_proof':
    delete manifest.operator_prerequisites.tools.find(
      (tool) => tool.source === 'operator_prerequisite'
    ).proof;
    break;
  case 'bundled_tool_sha_mismatch':
    manifest.operator_prerequisites.tools.find(
      (tool) => tool.source === 'bundled'
    ).sha256 = `sha256:${'4'.repeat(64)}`;
    break;
  case 'tool_path_uri':
    manifest.operator_prerequisites.tools.find(
      (tool) => tool.source === 'bundled'
    ).path = 'https://example.invalid/kubectl';
    break;
  case 'tool_path_symlink':
    fs.symlinkSync('kubectl', path.join(bundleRoot, 'tools', 'kubectl-link'));
    manifest.operator_prerequisites.tools.find(
      (tool) => tool.source === 'bundled'
    ).path = 'tools/kubectl-link';
    break;
  case 'tool_path_escape':
    manifest.operator_prerequisites.tools.find(
      (tool) => tool.source === 'bundled'
    ).path = '../kubectl';
    break;
  default:
    throw new Error(`unknown bundle mutation: ${mutation}`);
}

fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"
  local check_report_file="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$check_report_file" "$AIRGAP_REGISTRY" "$VALID_CONTRACT" <<'NODE'
import fs from 'node:fs';

const [reportFile, checkReportFile, expectedRegistry, validContract] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const checkReport = JSON.parse(fs.readFileSync(checkReportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedImageCount = JSON.parse(
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
      key === 'path' ||
      key === 'location' ||
      key === 'proof' ||
      key.endsWith('_ref') ||
      key === 'bundle_root' ||
      key === 'bundleRoot'
    ) {
      throw new Error(`bundle load plan report must not include leak-prone key: ${path}.${key}`);
    }
    assertNoLeakKeys(item, `${path}.${key}`);
  }
}

if (report.schema !== 'agentsmith.airgap-bundle-load-plan-report/v1') {
  throw new Error(`unexpected load plan schema: ${report.schema}`);
}
if (report.scope !== 'airgap_bundle_load_plan_only') {
  throw new Error(`unexpected load plan scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('bundle load plan report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== 'existing_kubernetes/external_declared/airgap') {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.target_registry !== expectedRegistry) {
  throw new Error(`unexpected target registry: ${report.target_registry}`);
}
if (report.image_count !== expectedImageCount) {
  throw new Error(`unexpected image count: ${report.image_count}`);
}
if (report.target_registry_summary?.target_registry !== expectedRegistry) {
  throw new Error('target registry summary is missing target registry');
}
if (report.target_registry_summary?.target_digest_count !== expectedImageCount) {
  throw new Error('target registry summary must count target digest refs');
}
if (report.target_registry_summary?.mirror_required_count !== expectedImageCount) {
  throw new Error('target registry summary must count mirror-required mappings');
}
if (report.digest_summary?.airgap_bundle_check_report_input_sha256 === undefined) {
  throw new Error('load plan report must bind airgap bundle check report digest');
}
for (const [label, digest] of Object.entries(report.digest_summary || {})) {
  if (typeof digest !== 'string' || !digest.startsWith('sha256:')) {
    throw new Error(`digest summary missing sha256 for ${label}`);
  }
}
if (checkReport.schema !== 'agentsmith.airgap-bundle-check-report/v1') {
  throw new Error(`unexpected self-check schema: ${checkReport.schema}`);
}
if (checkReport.readiness !== false) {
  throw new Error('self-check report must keep readiness=false');
}
assertNoLeakKeys(report);
if (
  /\b(?:release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|registry_presence|image_load|image_import|image_push|push_success|import_success|load_success)\b/.test(
    serialized
  )
) {
  throw new Error('bundle load plan report must not claim readiness or registry execution evidence');
}
if (/payload\/|tools\/|components\/|operator held|operator workstation|signed operator prerequisite|\/tmp\//.test(serialized)) {
  throw new Error('bundle load plan report must not leak paths or operator refs');
}
NODE
}

expect_load_plan_fail() {
  local label="$1"
  local bundle_root="$2"
  local output_dir="$3"
  shift 3

  write_stale_reports "$output_dir"
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected bundle load plan failure: $label"
  fi

  assert_no_reports "$output_dir"
  pass "bundle load plan rejected invalid case: $label"
}

manifest_sha="$(create_plain_archive "$VALID_ARCHIVE")"
archive_sha="$(sha256_file "$VALID_ARCHIVE")"
write_materials "$manifest_sha" "$archive_sha"
create_payloads
create_image_archives
write_operator_prerequisites "$OPERATOR_PREREQUISITES"

VALID_BUNDLE_ROOT="$TMP_DIR/bundle-valid"
VALID_CREATE_OUTPUT="$TMP_DIR/out-create-valid"
run_bundle_create "$VALID_BUNDLE_ROOT" "$VALID_CREATE_OUTPUT" >"$TMP_DIR/create-valid.out"

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

valid_output_dir="$TMP_DIR/out-load-valid"
PATH="$shim_dir:$PATH" run_bundle_load_plan "$VALID_BUNDLE_ROOT" "$valid_output_dir" >"$TMP_DIR/load-valid.out"
assert_report "$valid_output_dir/$REPORT_FILE" "$valid_output_dir/$CHECK_REPORT_FILE"
if ! tail -n 1 "$TMP_DIR/load-valid.out" | grep -q 'bundle load plan mode is not release readiness; readiness=false'; then
  cat "$TMP_DIR/load-valid.out" >&2
  fail "bundle load plan stdout must end with non-readiness wording"
fi
pass "valid bundle-create artifact passed load plan without calling network or tool binaries"

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE" \
  "kit-airgap:$KIT_AIRGAP_PROFILE" \
  "noncanonical:$NONCANONICAL_PROFILE" \
  "alias-offline:$ALIAS_OFFLINE_PROFILE"; do
  label="${profile_case%%:*}"
  profile="${profile_case#*:}"
  expect_load_plan_fail "unsupported-profile-$label" "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-profile-$label" \
    run_bundle_load_plan "$VALID_BUNDLE_ROOT" "$TMP_DIR/out-profile-$label" "$profile"
done

for mutation_case in \
  "missing-image-artifact:missing_image_artifact" \
  "image-map-target-registry-mismatch:target_registry_mismatch" \
  "secret-looking-target-registry:secret_target_registry" \
  "target-digest-mismatch:target_digest_mismatch" \
  "mirror-required-false:mirror_required_false" \
  "mapping-action-mismatch:action_mismatch" \
  "missing-registry-proof:missing_registry_proof" \
  "missing-tool-proof:missing_tool_proof" \
  "bundled-tool-sha-mismatch:bundled_tool_sha_mismatch" \
  "tool-path-uri:tool_path_uri" \
  "tool-path-symlink:tool_path_symlink" \
  "tool-path-escape:tool_path_escape"; do
  label="${mutation_case%%:*}"
  mutation="${mutation_case#*:}"
  bundle_root="$TMP_DIR/bundle-$label"
  output_dir="$TMP_DIR/out-$label"
  copy_valid_bundle "$bundle_root"
  mutate_bundle "$bundle_root" "$mutation"
  expect_load_plan_fail "$label" "$bundle_root" "$output_dir" \
    run_bundle_load_plan "$bundle_root" "$output_dir"
done

pass "bundle-load-plan focused diagnostic tests completed"
