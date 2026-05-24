#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
ONLINE_PROFILE="existing_kubernetes/external_declared/online"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIND_PROFILE="kind_rehearsal/kit_installed/online"
AIRGAP_REGISTRY="registry.example.internal/releases"
REPORT_FILE="airgap-bundle-check-report.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
VALID_CONTRACT="$TMP_DIR/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/deploy-template-package.valid.json"
VALID_ARCHIVE="$TMP_DIR/agentsmith-deploy-template-package.tgz"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

run_image_map() {
  local output_dir="$1"
  local release_contract="${2:-$VALID_CONTRACT}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --image-map \
    --release-contract "$release_contract" \
    --target-profile "$AIRGAP_PROFILE" \
    --target-registry "$AIRGAP_REGISTRY" \
    --output-dir "$output_dir" >/dev/null
}

run_airgap_bundle_check() {
  local image_map="$1"
  local target_profile="$2"
  local bundle_root="$3"
  local bundle_manifest="$4"
  local output_dir="$5"
  local release_contract="${6:-$VALID_CONTRACT}"
  local deploy_template_package="${7:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"
  local archive="${8:-$VALID_ARCHIVE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --airgap-bundle-check \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --image-map "$image_map" \
    --target-profile "$target_profile" \
    --bundle-root "$bundle_root" \
    --bundle-manifest "$bundle_manifest" \
    --output-dir "$output_dir"
}

assert_no_report() {
  local report_file="$1"
  [[ ! -e "$report_file" ]] || fail "unexpected airgap bundle check report exists: $report_file"
}

write_stale_report() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' '{"stale":true}' >"$output_dir/$REPORT_FILE"
}

create_materials() {
  local release_contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local mutation="${4:-valid}"

  "$NODE_BIN" --input-type=module - \
    "$FIXTURE_CONTRACT" \
    "$FIXTURE_DEPLOY_TEMPLATE_PACKAGE" \
    "$release_contract" \
    "$deploy_template_package" \
    "$archive" \
    "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  fixtureContractPath,
  fixtureDeployTemplatePackagePath,
  releaseContractPath,
  deployTemplatePackagePath,
  archivePath,
  mutation
] = process.argv.slice(2);

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function writeText(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, value);
}

const archiveBody = [
  'agentsmith deploy template archive placeholder',
  'manifest.json',
  'templates/kubernetes/web.yaml',
  ''
].join('\n');
writeText(archivePath, archiveBody);

const archiveSha256 = digestFile(archivePath);
const deployTemplatePackage = JSON.parse(
  fs.readFileSync(fixtureDeployTemplatePackagePath, 'utf8')
);
deployTemplatePackage.package_sha256 = archiveSha256;
if (
  deployTemplatePackage.artifact_provenance &&
  typeof deployTemplatePackage.artifact_provenance === 'object'
) {
  deployTemplatePackage.artifact_provenance.artifact_sha256 = archiveSha256;
}

switch (mutation) {
  case 'valid':
    break;
  case 'provenance_artifact_sha_mismatch':
    deployTemplatePackage.artifact_provenance.artifact_sha256 = `sha256:${'7'.repeat(64)}`;
    break;
  default:
    throw new Error(`unknown material mutation: ${mutation}`);
}

const contract = JSON.parse(fs.readFileSync(fixtureContractPath, 'utf8'));
contract.deploy_template_package = deployTemplatePackage;
contract.deploy_template_digest = deployTemplatePackage.manifest_sha256;

writeText(deployTemplatePackagePath, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
writeText(releaseContractPath, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_image_map() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  "$NODE_BIN" --input-type=module - "$input" "$output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [input, output, mutation] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(input, 'utf8'));

switch (mutation) {
  case 'missing_target_registry':
    delete imageMap.target_registry;
    break;
  case 'online_target_profile':
    imageMap.target_profile = {
      value: 'existing_kubernetes/external_declared/online',
      target_cluster: 'existing_kubernetes',
      substrate_source: 'external_declared',
      distribution: 'online'
    };
    break;
  case 'mirror_required_false':
    imageMap.mirror_required = false;
    for (const mapping of imageMap.mappings) {
      mapping.action = 'use_source';
    }
    break;
  default:
    throw new Error(`unknown image-map mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(imageMap, null, 2)}\n`);
NODE
}

create_bundle() {
  local image_map="$1"
  local bundle_root="$2"
  local bundle_manifest="$3"
  local mutation="${4:-valid}"
  local release_contract="${5:-$VALID_CONTRACT}"
  local deploy_template_package="${6:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"
  local archive="${7:-$VALID_ARCHIVE}"

  "$NODE_BIN" --input-type=module - \
    "$release_contract" \
    "$deploy_template_package" \
    "$archive" \
    "$image_map" \
    "$bundle_root" \
    "$bundle_manifest" \
    "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  releaseContractPath,
  deployTemplatePackagePath,
  archivePath,
  imageMapPath,
  bundleRoot,
  bundleManifestPath,
  mutation
] = process.argv.slice(2);

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function writeText(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, value);
}

const contract = JSON.parse(fs.readFileSync(releaseContractPath, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(deployTemplatePackagePath, 'utf8'));
const imageMap = JSON.parse(fs.readFileSync(imageMapPath, 'utf8'));

fs.rmSync(bundleRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(bundleRoot, 'components'), { recursive: true });
fs.mkdirSync(path.join(bundleRoot, 'images'), { recursive: true });

const componentPaths = {
  release_contract: 'components/release-contract.json',
  deploy_template_package: 'components/deploy-template-package.json',
  deploy_template_archive: 'components/agentsmith-deploy-template-package.tgz',
  image_map: 'components/image-map.json'
};
fs.copyFileSync(releaseContractPath, path.join(bundleRoot, componentPaths.release_contract));
fs.copyFileSync(
  deployTemplatePackagePath,
  path.join(bundleRoot, componentPaths.deploy_template_package)
);
fs.copyFileSync(archivePath, path.join(bundleRoot, componentPaths.deploy_template_archive));
fs.copyFileSync(imageMapPath, path.join(bundleRoot, componentPaths.image_map));

const componentDigests = {
  release_contract: digestFile(path.join(bundleRoot, componentPaths.release_contract)),
  deploy_template_package: digestFile(path.join(bundleRoot, componentPaths.deploy_template_package)),
  deploy_template_archive: digestFile(path.join(bundleRoot, componentPaths.deploy_template_archive)),
  image_map: digestFile(path.join(bundleRoot, componentPaths.image_map))
};

const imageArtifactDeclarations = imageMap.mappings.map((mapping) => {
  const relativePath = `images/${mapping.id}.oci-layout.tar`;
  const artifactPath = path.join(bundleRoot, relativePath);
  writeText(
    artifactPath,
    [
      'oci-layout-tar-placeholder',
      `id=${mapping.id}`,
      `source_image=${mapping.source_image}`,
      `target_image=${mapping.target_image}`,
      ''
    ].join('\n')
  );

  return {
    id: mapping.id,
    source_image: mapping.source_image,
    source_digest: mapping.source_digest,
    target_image: mapping.target_image,
    target_digest: mapping.target_digest,
    artifact_format: 'oci_layout_tar',
    path: relativePath,
    sha256: digestFile(artifactPath)
  };
});

const manifest = {
  schema_version: 'agentsmith.airgap-bundle-manifest/v1',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  target_profile: imageMap.target_profile,
  bindings: {
    release_contract_sha256: componentDigests.release_contract,
    deploy_template_package_sha256: componentDigests.deploy_template_package,
    deploy_template_archive_sha256: componentDigests.deploy_template_archive,
    deploy_template_manifest_sha256: deployTemplatePackage.manifest_sha256,
    image_map_sha256: componentDigests.image_map
  },
  components: [
    {
      kind: 'release_contract',
      path: componentPaths.release_contract,
      sha256: componentDigests.release_contract
    },
    {
      kind: 'deploy_template_package',
      path: componentPaths.deploy_template_package,
      sha256: componentDigests.deploy_template_package
    },
    {
      kind: 'deploy_template_archive',
      path: componentPaths.deploy_template_archive,
      sha256: componentDigests.deploy_template_archive
    },
    {
      kind: 'image_map',
      path: componentPaths.image_map,
      sha256: componentDigests.image_map
    }
  ],
  image_artifact_declarations: imageArtifactDeclarations,
  substrate: {
    mode: 'external_declared',
    bundled: false
  }
};

switch (mutation) {
  case 'valid':
    break;
  case 'schema_field_instead_of_schema_version':
    manifest.schema = manifest.schema_version;
    delete manifest.schema_version;
    break;
  case 'component_id_instead_of_kind':
    for (const component of manifest.components) {
      component.id = component.kind;
      delete component.kind;
    }
    break;
  case 'missing_image_artifact_file':
    fs.rmSync(path.join(bundleRoot, manifest.image_artifact_declarations[0].path));
    break;
  case 'missing_component_file':
    fs.rmSync(path.join(bundleRoot, manifest.components[0].path));
    break;
  case 'missing_deploy_template_archive_component':
    manifest.components = manifest.components.filter(
      (component) => component.kind !== 'deploy_template_archive'
    );
    break;
  case 'archive_component_file_missing':
    fs.rmSync(
      path.join(
        bundleRoot,
        manifest.components.find((component) => component.kind === 'deploy_template_archive').path
      )
    );
    break;
  case 'image_sha_mismatch':
    manifest.image_artifact_declarations[0].sha256 = `sha256:${'9'.repeat(64)}`;
    break;
  case 'archive_sha_mismatch':
    manifest.components.find((component) => component.kind === 'deploy_template_archive').sha256 =
      `sha256:${'6'.repeat(64)}`;
    break;
  case 'component_sha_mismatch':
    manifest.components[0].sha256 = `sha256:${'8'.repeat(64)}`;
    break;
  case 'path_traversal':
    manifest.image_artifact_declarations[0].path = '../escape.tar';
    break;
  case 'absolute_path':
    manifest.components[0].path = '/tmp/release-contract.json';
    break;
  case 'backslash_path':
    manifest.image_artifact_declarations[0].path = 'images\\escape.tar';
    break;
  case 'empty_path_segment':
    manifest.image_artifact_declarations[0].path = 'images//escape.tar';
    break;
  case 'dot_path_segment':
    manifest.image_artifact_declarations[0].path = 'images/./escape.tar';
    break;
  case 'uri_path':
    manifest.components[0].path = 'https://example.invalid/release-contract.json';
    break;
  case 'symlink_path':
    manifest.image_artifact_declarations[0].path = 'images/symlink.oci-layout.tar';
    fs.symlinkSync(
      path.basename(manifest.image_artifact_declarations[1].path),
      path.join(bundleRoot, manifest.image_artifact_declarations[0].path)
    );
    break;
  case 'duplicate_component_kind':
    manifest.components[1].kind = manifest.components[0].kind;
    break;
  case 'missing_component':
    manifest.components.pop();
    break;
  case 'duplicate_image_declaration':
    manifest.image_artifact_declarations[1].id = manifest.image_artifact_declarations[0].id;
    break;
  case 'missing_image_declaration':
    manifest.image_artifact_declarations.shift();
    break;
  case 'bundle_manifest_online_target_profile':
    manifest.target_profile = {
      value: 'existing_kubernetes/external_declared/online',
      target_cluster: 'existing_kubernetes',
      substrate_source: 'external_declared',
      distribution: 'online'
    };
    break;
  default:
    throw new Error(`unknown bundle mutation: ${mutation}`);
}

writeText(bundleManifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

assert_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.airgap-bundle-check-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'airgap_bundle_manifest_check_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('airgap bundle check report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== 'existing_kubernetes/external_declared/airgap') {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.components_count !== 4) {
  throw new Error(`unexpected components count: ${report.components_count}`);
}
if (report.image_artifact_declaration_count !== 5) {
  throw new Error(`unexpected image artifact count: ${report.image_artifact_declaration_count}`);
}
if (report.artifacts?.image_map?.image_count !== 5) {
  throw new Error('image-map image count is missing');
}
for (const [label, digest] of [
  ['release contract', report.artifacts?.release_contract?.input_sha256],
  ['deploy template package input', report.artifacts?.deploy_template_package?.input_sha256],
  ['deploy template package package', report.artifacts?.deploy_template_package?.package_sha256],
  ['deploy template package manifest', report.artifacts?.deploy_template_package?.manifest_sha256],
  ['deploy template archive input', report.artifacts?.deploy_template_archive?.input_sha256],
  ['image map', report.artifacts?.image_map?.input_sha256],
  ['bundle manifest', report.artifacts?.bundle_manifest?.input_sha256]
]) {
  if (typeof digest !== 'string' || !digest.startsWith('sha256:')) {
    throw new Error(`${label} digest is missing`);
  }
}
if (
  /release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|registry_presence|image_load|docker|skopeo|oras|kubectl|pull|push|mirror|save|load/.test(serialized)
) {
  throw new Error('report must not claim readiness or verification verdict fields');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('report must not include AgentSmith product flow fields');
}
if (/password|token|secret|client_secret|kubeconfig|authorization|bearer/i.test(serialized)) {
  throw new Error('report must not include raw secret-ish payloads');
}
NODE
}

expect_bundle_fail() {
  local label="$1"
  local mutation="$2"
  local image_map_dir="$TMP_DIR/image-map-$label"
  local bundle_root="$TMP_DIR/bundle-$label"
  local bundle_manifest="$bundle_root/airgap-bundle-manifest.json"
  local output_dir="$TMP_DIR/out-$label"

  run_image_map "$image_map_dir"
  create_bundle "$image_map_dir/image-map.json" "$bundle_root" "$bundle_manifest" "$mutation"
  write_stale_report "$output_dir"

  if run_airgap_bundle_check "$image_map_dir/image-map.json" "$AIRGAP_PROFILE" "$bundle_root" "$bundle_manifest" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid airgap bundle case to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid airgap bundle rejected: $label"
}

expect_image_map_fail() {
  local label="$1"
  local mutation="$2"
  local image_map_dir="$TMP_DIR/image-map-$label"
  local image_map="$TMP_DIR/$label.image-map.json"
  local bundle_root="$TMP_DIR/bundle-$label"
  local bundle_manifest="$bundle_root/airgap-bundle-manifest.json"
  local output_dir="$TMP_DIR/out-$label"

  run_image_map "$image_map_dir"
  mutate_image_map "$image_map_dir/image-map.json" "$image_map" "$mutation"
  create_bundle "$image_map" "$bundle_root" "$bundle_manifest"
  write_stale_report "$output_dir"

  if run_airgap_bundle_check "$image_map" "$AIRGAP_PROFILE" "$bundle_root" "$bundle_manifest" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid image-map binding to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid airgap image-map rejected: $label"
}

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local image_map_dir="$TMP_DIR/image-map-profile-$label"
  local bundle_root="$TMP_DIR/bundle-profile-$label"
  local bundle_manifest="$bundle_root/airgap-bundle-manifest.json"
  local output_dir="$TMP_DIR/out-profile-$label"

  run_image_map "$image_map_dir"
  create_bundle "$image_map_dir/image-map.json" "$bundle_root" "$bundle_manifest"
  write_stale_report "$output_dir"

  if run_airgap_bundle_check "$image_map_dir/image-map.json" "$target_profile" "$bundle_root" "$bundle_manifest" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected unsupported target profile to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "airgap bundle target profile rejected: $label"
}

expect_archive_arg_fail() {
  local label="$1"
  local image_map_dir="$TMP_DIR/image-map-$label"
  local bundle_root="$TMP_DIR/bundle-$label"
  local bundle_manifest="$bundle_root/airgap-bundle-manifest.json"
  local output_dir="$TMP_DIR/out-$label"
  local bad_archive="$TMP_DIR/$label.bad.tgz"

  run_image_map "$image_map_dir"
  create_bundle "$image_map_dir/image-map.json" "$bundle_root" "$bundle_manifest"
  printf '%s\n' 'bad archive payload' >"$bad_archive"
  write_stale_report "$output_dir"

  if run_airgap_bundle_check "$image_map_dir/image-map.json" "$AIRGAP_PROFILE" "$bundle_root" "$bundle_manifest" "$output_dir" "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$bad_archive" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid archive argument to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid airgap archive rejected: $label"
}

expect_material_fail() {
  local label="$1"
  local mutation="$2"
  local release_contract="$TMP_DIR/$label.release-contract.json"
  local deploy_template_package="$TMP_DIR/$label.deploy-template-package.json"
  local archive="$TMP_DIR/$label.archive.tgz"
  local image_map_dir="$TMP_DIR/image-map-$label"
  local bundle_root="$TMP_DIR/bundle-$label"
  local bundle_manifest="$bundle_root/airgap-bundle-manifest.json"
  local output_dir="$TMP_DIR/out-$label"

  create_materials "$release_contract" "$deploy_template_package" "$archive" "$mutation"
  run_image_map "$image_map_dir" "$release_contract"
  create_bundle "$image_map_dir/image-map.json" "$bundle_root" "$bundle_manifest" valid "$release_contract" "$deploy_template_package" "$archive"
  write_stale_report "$output_dir"

  if run_airgap_bundle_check "$image_map_dir/image-map.json" "$AIRGAP_PROFILE" "$bundle_root" "$bundle_manifest" "$output_dir" "$release_contract" "$deploy_template_package" "$archive" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid airgap materials to fail: $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid airgap materials rejected: $label"
}

valid_image_map_dir="$TMP_DIR/image-map-valid"
valid_bundle_root="$TMP_DIR/bundle-valid"
valid_bundle_manifest="$valid_bundle_root/airgap-bundle-manifest.json"
valid_output_dir="$TMP_DIR/out-valid"

create_materials "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$VALID_ARCHIVE"
run_image_map "$valid_image_map_dir"
create_bundle "$valid_image_map_dir/image-map.json" "$valid_bundle_root" "$valid_bundle_manifest"
run_airgap_bundle_check "$valid_image_map_dir/image-map.json" "$AIRGAP_PROFILE" "$valid_bundle_root" "$valid_bundle_manifest" "$valid_output_dir" >/dev/null
assert_report "$valid_output_dir/$REPORT_FILE"
pass "valid airgap bundle manifest accepted with focused non-readiness report"

expect_image_map_fail missing-target-registry missing_target_registry
expect_image_map_fail image-map-not-airgap online_target_profile
expect_image_map_fail mirror-required-false mirror_required_false

expect_bundle_fail schema-field-instead-of-schema-version schema_field_instead_of_schema_version
expect_bundle_fail component-id-instead-of-kind component_id_instead_of_kind
expect_bundle_fail missing-image-artifact-file missing_image_artifact_file
expect_bundle_fail missing-component-file missing_component_file
expect_bundle_fail missing-deploy-template-archive-component missing_deploy_template_archive_component
expect_bundle_fail archive-component-file-missing archive_component_file_missing
expect_bundle_fail image-artifact-sha-mismatch image_sha_mismatch
expect_bundle_fail archive-sha-mismatch archive_sha_mismatch
expect_bundle_fail component-sha-mismatch component_sha_mismatch
expect_bundle_fail path-traversal path_traversal
expect_bundle_fail absolute-path absolute_path
expect_bundle_fail backslash-path backslash_path
expect_bundle_fail empty-path-segment empty_path_segment
expect_bundle_fail dot-path-segment dot_path_segment
expect_bundle_fail uri-path uri_path
expect_bundle_fail symlink-path symlink_path
expect_bundle_fail duplicate-component-kind duplicate_component_kind
expect_bundle_fail missing-component missing_component
expect_bundle_fail duplicate-image-declaration duplicate_image_declaration
expect_bundle_fail missing-image-declaration missing_image_declaration
expect_bundle_fail bundle-manifest-online-target-profile bundle_manifest_online_target_profile
expect_archive_arg_fail archive-argument-sha-mismatch
expect_material_fail provenance-artifact-sha-mismatch provenance_artifact_sha_mismatch

expect_profile_fail online "$ONLINE_PROFILE"
expect_profile_fail kind-rehearsal "$KIND_PROFILE"
expect_profile_fail alias-offline "existing_kubernetes/external_declared/offline"
expect_profile_fail alias-air-gapped "existing_kubernetes/external_declared/air-gapped"

pass "airgap bundle manifest/digest focused diagnostic tests completed"
