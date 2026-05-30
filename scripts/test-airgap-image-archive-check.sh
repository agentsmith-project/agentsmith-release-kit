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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VALID_CONTRACT="$TMP_DIR/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.valid.json"
VALID_ARCHIVE="$TMP_DIR/agentsmith-deploy-template-package.tgz"
PAYLOAD_DIR="$TMP_DIR/payload"
IMAGE_DIR="$TMP_DIR/image-archives"
OPERATOR_PREREQUISITES="$TMP_DIR/operator-prerequisites.json"
KIT_SUBSTRATE_PACK_MANIFEST="$TMP_DIR/substrate-pack-manifest.kit-airgap.json"
GOOD_PROBE="$TMP_DIR/probes/archive-digest-probe"
DOUBLE_OUTPUT_PROBE="$TMP_DIR/probes/double-output-probe"
TIMEOUT_PROBE="$TMP_DIR/probes/timeout-probe"

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

write_probes() {
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
}

run_bundle_create() {
  local bundle_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$AIRGAP_PROFILE}"
  local substrate_pack_manifest="${4:-}"
  local image_archive_args=()
  local substrate_pack_args=()

  while IFS= read -r id; do
    image_archive_args+=(--image-archive "$id=$IMAGE_DIR/$id.oci-layout.tar")
  done < <("$NODE_BIN" --input-type=module - "$VALID_CONTRACT" <<'NODE'
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
  fi

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
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
}

run_image_archive_check_full() {
  local image_map="$1"
  local target_profile="$2"
  local bundle_root="$3"
  local bundle_manifest="$4"
  local archive_probe="$5"
  local output_dir="$6"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-image-archive-check \
    --release-contract "$VALID_CONTRACT" \
    --deploy-template-package "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
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

  "$NODE_BIN" --input-type=module - "$bundle_root" "$image_id" "$digest" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot, imageId, digest] = process.argv.slice(2);
const manifestPath = path.join(bundleRoot, 'airgap-bundle-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const declaration = manifest.image_artifact_declarations.find((item) => item.id === imageId);
if (!declaration) {
  throw new Error(`missing image declaration: ${imageId}`);
}
const archivePath = path.join(bundleRoot, ...declaration.path.split('/'));
fs.writeFileSync(
  archivePath,
  [
    'local oci layout tar fixture',
    `id=${imageId}`,
    `target_digest=${digest}`,
    ''
  ].join('\n')
);
declaration.sha256 = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(archivePath)).digest('hex')}`;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
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
  for (const field of ['source_digest', 'target_digest', 'archive_sha256', 'probe_digest']) {
    if (!digestRe.test(image[field])) {
      throw new Error(`image ${image.id} missing ${field}`);
    }
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
  "$KIT_SUBSTRATE_PACK_MANIFEST" >"$TMP_DIR/create-kit-valid.out"

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

kit_output_dir="$TMP_DIR/out-image-archive-kit"
PATH="$shim_dir:$PATH" run_image_archive_check \
  "$KIT_BUNDLE_ROOT" \
  "$kit_output_dir" \
  "$GOOD_PROBE" \
  "$KIT_AIRGAP_PROFILE" >"$TMP_DIR/image-archive-kit.out"
assert_report "$kit_output_dir/$REPORT_FILE" "$KIT_AIRGAP_PROFILE"
pass "valid kit airgap image archives matched target digests without calling registry tools"

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
  run_image_archive_check "$wrong_digest_bundle" "$TMP_DIR/out-wrong-digest"

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
