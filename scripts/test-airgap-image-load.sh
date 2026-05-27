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

function digest(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
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

run_image_load_full() {
  local image_map="$1"
  local target_profile="$2"
  local bundle_root="$3"
  local bundle_manifest="$4"
  local archive_probe="$5"
  local image_loader="$6"
  local output_dir="$7"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-image-load \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
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

  "$NODE_BIN" --input-type=module - "$report_file" "$archive_check_report_file" "$VALID_CONTRACT" "$GOOD_LOADER" <<'NODE'
import fs from 'node:fs';

const [reportFile, archiveCheckReportFile, validContract, loaderPath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const archiveCheckReport = JSON.parse(fs.readFileSync(archiveCheckReportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedImageCount = JSON.parse(
  fs.readFileSync(validContract, 'utf8')
).deploy_image_inventory.length;
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
if (report.target_profile?.value !== 'existing_kubernetes/external_declared/airgap') {
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
write_tools

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

for profile_case in \
  "online:$ONLINE_PROFILE" \
  "kind:$KIND_PROFILE" \
  "kit-airgap:$KIT_AIRGAP_PROFILE" \
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
