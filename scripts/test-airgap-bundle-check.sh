#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
ONLINE_PROFILE="existing_kubernetes/external_declared/online"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIND_PROFILE="kind_rehearsal/kit_installed/online"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
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
const fixtureContract = JSON.parse(fs.readFileSync(fixtureContractPath, 'utf8'));
const staleSixImageIds = fixtureContract.required_image_ids.filter(
  (id) => id !== 'managed_runner'
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
  case 'missing_artifact_provenance':
    delete deployTemplatePackage.artifact_provenance;
    break;
  case 'artifact_provenance_non_object':
    deployTemplatePackage.artifact_provenance = 'not-an-object';
    break;
  case 'missing_artifact_sha256':
    delete deployTemplatePackage.artifact_provenance.artifact_sha256;
    break;
  case 'artifact_sha_invalid_format':
    deployTemplatePackage.artifact_provenance.artifact_sha256 = 'sha256:not-a-valid-digest';
    break;
  case 'provenance_artifact_sha_mismatch':
    deployTemplatePackage.artifact_provenance.artifact_sha256 = `sha256:${'7'.repeat(64)}`;
    break;
  case 'missing_deploy_package_required_image_ids':
    delete deployTemplatePackage.required_image_ids;
    break;
  case 'empty_deploy_package_required_image_ids':
    deployTemplatePackage.required_image_ids = [];
    break;
  case 'non_array_deploy_package_required_image_ids':
    deployTemplatePackage.required_image_ids = 'agentsmith_app';
    break;
  case 'target_profiles_not_array':
  case 'target_profiles_missing_airgap':
  case 'target_profiles_noncanonical_synonym':
  case 'target_required_missing':
  case 'target_required_string':
  case 'target_required_true':
  case 'target_support_level':
  case 'kind_required_target_profile':
  case 'duplicate_target_profile_tuple':
  case 'missing_release_required_image_ids':
  case 'required_image_ids_mismatch':
  case 'stale_six_image_required_image_ids':
  case 'required_image_id_missing_in_inventory':
  case 'required_current_image_id_absent_from_inventory':
    break;
  default:
    throw new Error(`unknown material mutation: ${mutation}`);
}

const contract = fixtureContract;
contract.deploy_template_package = deployTemplatePackage;
contract.deploy_template_digest = deployTemplatePackage.manifest_sha256;

switch (mutation) {
  case 'target_profiles_not_array':
    contract.target_profiles = { value: 'existing_kubernetes/external_declared/airgap' };
    break;
  case 'target_profiles_missing_airgap':
    contract.target_profiles = contract.target_profiles.filter(
      (profile) => profile.distribution !== 'airgap'
    );
    break;
  case 'target_profiles_noncanonical_synonym':
    contract.target_profiles[1].distribution = 'offline';
    break;
  case 'target_required_missing':
    delete contract.target_profiles[1].required;
    break;
  case 'target_required_string':
    contract.target_profiles[1].required = 'false';
    break;
  case 'target_required_true':
    contract.target_profiles[1].required = true;
    break;
  case 'target_support_level':
    contract.target_profiles[1].support_level = 'optional';
    break;
  case 'kind_required_target_profile':
    contract.target_profiles[2].required = true;
    break;
  case 'duplicate_target_profile_tuple':
    contract.target_profiles.push({ ...contract.target_profiles[1] });
    break;
  case 'missing_release_required_image_ids':
    delete contract.required_image_ids;
    break;
  case 'required_image_ids_mismatch':
    contract.required_image_ids = contract.required_image_ids.slice(0, -1);
    break;
  case 'stale_six_image_required_image_ids':
    contract.required_image_ids = staleSixImageIds;
    contract.deploy_template_package.required_image_ids = staleSixImageIds;
    deployTemplatePackage.required_image_ids = staleSixImageIds;
    break;
  case 'required_image_id_missing_in_inventory':
    contract.required_image_ids = [...contract.required_image_ids, 'missing_component'];
    contract.deploy_template_package.required_image_ids = [...contract.required_image_ids];
    deployTemplatePackage.required_image_ids = [...contract.required_image_ids];
    break;
  case 'required_current_image_id_absent_from_inventory':
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.id !== 'asbcp'
    );
    break;
  default:
    break;
}

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
  case 'mapping_source_image_mismatch':
    imageMap.mappings[0].source_image = imageMap.mappings[0].source_image.replace(
      'agentsmith-app',
      'agentsmith-app-drift'
    );
    break;
  case 'mapping_source_digest_mismatch':
    imageMap.mappings[0].source_digest = `sha256:${'5'.repeat(64)}`;
    break;
  case 'mapping_id_missing':
    imageMap.mappings[0].id = `${imageMap.mappings[0].id}-missing`;
    break;
  case 'duplicate_mapping_id':
    imageMap.mappings[1].id = imageMap.mappings[0].id;
    break;
  case 'image_count_mismatch':
    imageMap.image_count += 1;
    break;
  case 'release_contract_inventory_count_mismatch':
    imageMap.release_contract.deploy_image_inventory_count += 1;
    break;
  case 'mapping_target_digest_mismatch':
    imageMap.mappings[0].target_digest = `sha256:${'2'.repeat(64)}`;
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /@sha256:[0-9a-f]{64}$/,
      `@${imageMap.mappings[0].target_digest}`
    );
    break;
  case 'target_image_digest_suffix_mismatch':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /@sha256:[0-9a-f]{64}$/,
      `@sha256:${'6'.repeat(64)}`
    );
    break;
  case 'target_image_outside_registry':
    imageMap.mappings[0].target_image =
      `registry.evil.example/releases/${imageMap.mappings[0].id}@${imageMap.mappings[0].target_digest}`;
    break;
  case 'target_image_missing_digest':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /@sha256:[0-9a-f]{64}$/,
      ''
    );
    break;
  default:
    throw new Error(`unknown image-map mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(imageMap, null, 2)}\n`);
NODE
}

rebind_image_map_release_contract_digest() {
  local image_map="$1"
  local release_contract="$2"

  "$NODE_BIN" --input-type=module - "$image_map" "$release_contract" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [imageMapPath, releaseContractPath] = process.argv.slice(2);

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

const imageMap = JSON.parse(fs.readFileSync(imageMapPath, 'utf8'));
if (
  !imageMap.release_contract ||
  typeof imageMap.release_contract !== 'object' ||
  Array.isArray(imageMap.release_contract)
) {
  throw new Error('image_map.release_contract must be an object');
}

imageMap.release_contract.input_sha256 = digestFile(releaseContractPath);
fs.writeFileSync(imageMapPath, `${JSON.stringify(imageMap, null, 2)}\n`);
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

function writeBundleText(relativePath, value) {
  const file = path.join(bundleRoot, relativePath);
  writeText(file, value);
  return {
    path: relativePath,
    sha256: digestFile(file)
  };
}

const runbookArtifact = writeBundleText(
  'payload/runbook.md',
  '# AgentSmith airgap operator runbook\n\nFollow the approved local install procedure.\n'
);
const scriptArtifact = writeBundleText(
  'payload/install.sh',
  '#!/usr/bin/env sh\nset -eu\nprintf "%s\\n" "operator-reviewed local script placeholder"\n'
);
const schemaArtifact = writeBundleText(
  'payload/profile-values.schema.json',
  JSON.stringify({ type: 'object', additionalProperties: false }, null, 2) + '\n'
);
const exampleArtifact = writeBundleText(
  'payload/profile-values.example.yaml',
  'namespace: agentsmith\n'
);
const checksumsArtifact = writeBundleText(
  'payload/checksums.txt',
  'checksums are bound by airgap-bundle-manifest sha256 declarations\n'
);
const bundledToolArtifact = writeBundleText(
  'tools/kubectl-placeholder.txt',
  'bundled tool placeholder; this diagnostic only checks file sha256\n'
);

const payloadArtifacts = [
  {
    id: 'operator_runbook',
    kind: 'runbook',
    path: runbookArtifact.path,
    sha256: runbookArtifact.sha256
  },
  {
    id: 'install_script',
    kind: 'script',
    path: scriptArtifact.path,
    sha256: scriptArtifact.sha256
  },
  {
    id: 'profile_values_schema',
    kind: 'profile_values_schema',
    path: schemaArtifact.path,
    sha256: schemaArtifact.sha256
  },
  {
    id: 'profile_values_example',
    kind: 'profile_values_example',
    path: exampleArtifact.path,
    sha256: exampleArtifact.sha256
  },
  {
    id: 'bundle_checksums',
    kind: 'checksums',
    path: checksumsArtifact.path,
    sha256: checksumsArtifact.sha256
  }
];

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
  payload_artifacts: payloadArtifacts,
  operator_prerequisites: {
    substrate_connection_truth_ref: 'operator note: substrate truth evidence in internal record',
    target_registry_proof_ref: 'operator note: target registry proof in internal record',
    tools: [
      {
        name: 'kubectl',
        version: '1.30.0',
        source: 'bundled',
        path: bundledToolArtifact.path,
        sha256: bundledToolArtifact.sha256
      },
      {
        name: 'skopeo',
        version: '1.16.0',
        source: 'operator_prerequisite',
        location: 'operator provided workstation inventory: skopeo',
        proof: 'signed operator prerequisite proof: skopeo'
      }
    ]
  },
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
  case 'extra_top_level_schema_with_schema_version':
    manifest.schema = manifest.schema_version;
    break;
  case 'component_id_instead_of_kind':
    for (const component of manifest.components) {
      component.id = component.kind;
      delete component.kind;
    }
    break;
  case 'component_id_with_kind':
    manifest.components[0].id = manifest.components[0].kind;
    break;
  case 'unexpected_binding_field':
    manifest.bindings.extra_sha256 = componentDigests.image_map;
    break;
  case 'unexpected_image_declaration_field':
    manifest.image_artifact_declarations[0].extra_field = 'not-allowed';
    break;
  case 'unexpected_substrate_field':
    manifest.substrate.extra_field = 'not-allowed';
    break;
  case 'missing_payload_artifacts':
    delete manifest.payload_artifacts;
    break;
  case 'missing_required_payload_kind':
    manifest.payload_artifacts = manifest.payload_artifacts.filter(
      (artifact) => artifact.kind !== 'checksums'
    );
    break;
  case 'payload_sha_mismatch':
    manifest.payload_artifacts[0].sha256 = `sha256:${'3'.repeat(64)}`;
    break;
  case 'unexpected_payload_field':
    manifest.payload_artifacts[0].extra_field = 'not-allowed';
    break;
  case 'payload_unknown_kind':
    manifest.payload_artifacts[0].kind = 'readme';
    break;
  case 'missing_payload_file':
    fs.rmSync(path.join(bundleRoot, manifest.payload_artifacts[0].path));
    break;
  case 'payload_path_traversal':
    manifest.payload_artifacts[0].path = '../runbook.md';
    break;
  case 'duplicate_payload_id':
    manifest.payload_artifacts[1].id = manifest.payload_artifacts[0].id;
    break;
  case 'unexpected_operator_field':
    manifest.operator_prerequisites.extra_field = 'not-allowed';
    break;
  case 'missing_operator_prerequisites':
    delete manifest.operator_prerequisites;
    break;
  case 'operator_tools_empty':
    manifest.operator_prerequisites.tools = [];
    break;
  case 'operator_ref_empty':
    manifest.operator_prerequisites.substrate_connection_truth_ref = ' ';
    break;
  case 'unexpected_tool_field':
    manifest.operator_prerequisites.tools[0].extra_field = 'not-allowed';
    break;
  case 'bundled_tool_sha_mismatch':
    manifest.operator_prerequisites.tools[0].sha256 = `sha256:${'4'.repeat(64)}`;
    break;
  case 'operator_tool_missing_proof':
    delete manifest.operator_prerequisites.tools[1].proof;
    break;
  case 'tool_source_unknown':
    manifest.operator_prerequisites.tools[0].source = 'download';
    break;
  case 'tool_source_missing':
    delete manifest.operator_prerequisites.tools[0].source;
    break;
  case 'tool_field_mixing':
    manifest.operator_prerequisites.tools[0].location = 'operator provided workstation inventory kubectl';
    break;
  case 'bundled_tool_missing_path':
    delete manifest.operator_prerequisites.tools[0].path;
    break;
  case 'bundled_tool_missing_sha':
    delete manifest.operator_prerequisites.tools[0].sha256;
    break;
  case 'operator_tool_missing_version':
    delete manifest.operator_prerequisites.tools[1].version;
    break;
  case 'operator_ref_https':
    manifest.operator_prerequisites.substrate_connection_truth_ref =
      'https://example.invalid/substrate-truth.json';
    break;
  case 'operator_ref_embedded_https':
    manifest.operator_prerequisites.target_registry_proof_ref =
      'operator proof at https://example.invalid/proof';
    break;
  case 'operator_ref_token':
    manifest.operator_prerequisites.target_registry_proof_ref =
      'token=abcdefghijklmnop';
    break;
  case 'operator_ref_public_download':
    manifest.operator_prerequisites.substrate_connection_truth_ref =
      'operator public download evidence record';
    break;
  case 'operator_ref_wget':
    manifest.operator_prerequisites.target_registry_proof_ref =
      'operator evidence: wget example.invalid/proof';
    break;
  case 'operator_tool_location_https':
    manifest.operator_prerequisites.tools[1].location = 'https://example.invalid/skopeo';
    break;
  case 'operator_tool_location_embedded_oras':
    manifest.operator_prerequisites.tools[1].location =
      'location see oras://registry.invalid/tool';
    break;
  case 'operator_tool_location_wget':
    manifest.operator_prerequisites.tools[1].location =
      'operator location: wget example.invalid/skopeo';
    break;
  case 'operator_tool_proof_https':
    manifest.operator_prerequisites.tools[1].proof = 'https://example.invalid/proof';
    break;
  case 'operator_tool_proof_embedded_https':
    manifest.operator_prerequisites.tools[1].proof =
      'operator proof at https://example.invalid/proof';
    break;
  case 'operator_tool_proof_docker_pull':
    manifest.operator_prerequisites.tools[1].proof =
      'operator proof: docker pull registry.invalid/skopeo:1.16';
    break;
  case 'operator_tool_proof_skopeo_copy':
    manifest.operator_prerequisites.tools[1].proof =
      'operator proof: skopeo copy source image into offline archive';
    break;
  case 'operator_tool_proof_token':
    manifest.operator_prerequisites.tools[1].proof = 'Bearer abcdefghijklmnop';
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

  "$NODE_BIN" --input-type=module - "$report_file" "$VALID_CONTRACT" <<'NODE'
import fs from 'node:fs';

const [reportFile, validContract] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const expectedImageCount = JSON.parse(
  fs.readFileSync(validContract, 'utf8')
).deploy_image_inventory.length;

function assertNoLeakKeys(value, path = 'report') {
  if (!value || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    for (const [index, item] of value.entries()) {
      assertNoLeakKeys(item, `${path}[${index}]`);
    }
    return;
  }

  for (const [key, item] of Object.entries(value)) {
    if (key === 'path' || key === 'location' || key === 'proof' || key.endsWith('_ref')) {
      throw new Error(`report must not include leak-prone key: ${path}.${key}`);
    }
    assertNoLeakKeys(item, `${path}.${key}`);
  }
}

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
const imageMapCount = report.artifacts?.image_map?.image_count;
if (imageMapCount !== expectedImageCount) {
  throw new Error(`image-map image count must match release contract inventory: ${imageMapCount}`);
}
if (report.image_artifact_declaration_count !== imageMapCount) {
  throw new Error(`unexpected image artifact count: ${report.image_artifact_declaration_count}`);
}
if (report.payload_artifact_count !== 5) {
  throw new Error(`unexpected payload artifact count: ${report.payload_artifact_count}`);
}
if (report.tool_count !== 2) {
  throw new Error(`unexpected tool count: ${report.tool_count}`);
}
if (report.bundled_tool_count !== 1) {
  throw new Error(`unexpected bundled tool count: ${report.bundled_tool_count}`);
}
if (report.operator_prerequisite_tool_count !== 1) {
  throw new Error(
    `unexpected operator prerequisite tool count: ${report.operator_prerequisite_tool_count}`
  );
}
assertNoLeakKeys(report);
for (const [label, digest] of [
  ['release contract', report.artifacts?.release_contract?.input_sha256],
  ['deploy template package input', report.artifacts?.deploy_template_package?.input_sha256],
  ['deploy template package package', report.artifacts?.deploy_template_package?.package_sha256],
  ['deploy template package manifest', report.artifacts?.deploy_template_package?.manifest_sha256],
  ['deploy template package artifact', report.artifacts?.deploy_template_package?.artifact_sha256],
  ['deploy template archive input', report.artifacts?.deploy_template_archive?.input_sha256],
  ['image map', report.artifacts?.image_map?.input_sha256],
  ['bundle manifest', report.artifacts?.bundle_manifest?.input_sha256]
]) {
  if (typeof digest !== 'string' || !digest.startsWith('sha256:')) {
    throw new Error(`${label} digest is missing`);
  }
}
if (
  /\b(?:release_verdict|verdict|deploy_readiness|release_readiness|package_readiness|offline_install_readiness|offline_install_ready|registry_presence|image_load|docker|skopeo|oras|kubectl|pull|push|mirror|save|load)\b/.test(
    serialized
  )
) {
  throw new Error('report must not claim readiness or verification verdict fields');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('report must not include AgentSmith product flow fields');
}
if (/password|token|secret|client_secret|kubeconfig|authorization|bearer/i.test(serialized)) {
  throw new Error('report must not include raw secret-ish payloads');
}
if (
  /payload\/|tools\/|operator note:|operator provided workstation|signed operator prerequisite/.test(
    serialized
  )
) {
  throw new Error('report must not include raw payload paths or operator proof/location refs');
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

expect_contract_fail() {
  local label="$1"
  local mutation="$2"
  local expected_stderr="${3:-}"
  local release_contract="$TMP_DIR/$label.release-contract.json"
  local deploy_template_package="$TMP_DIR/$label.deploy-template-package.json"
  local archive="$TMP_DIR/$label.archive.tgz"
  local image_map_dir="$TMP_DIR/image-map-$label"
  local bundle_root="$TMP_DIR/bundle-$label"
  local bundle_manifest="$bundle_root/airgap-bundle-manifest.json"
  local output_dir="$TMP_DIR/out-$label"

  create_materials "$release_contract" "$deploy_template_package" "$archive" "$mutation"
  run_image_map "$image_map_dir"
  rebind_image_map_release_contract_digest "$image_map_dir/image-map.json" "$release_contract"
  create_bundle "$image_map_dir/image-map.json" "$bundle_root" "$bundle_manifest" valid "$release_contract" "$deploy_template_package" "$archive"
  write_stale_report "$output_dir"

  if run_airgap_bundle_check "$image_map_dir/image-map.json" "$AIRGAP_PROFILE" "$bundle_root" "$bundle_manifest" "$output_dir" "$release_contract" "$deploy_template_package" "$archive" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid release contract to fail: $label"
  fi

  if [[ -n "$expected_stderr" ]] && ! grep -Fq "$expected_stderr" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected airgap bundle check stderr to contain '$expected_stderr': $label"
  fi

  assert_no_report "$output_dir/$REPORT_FILE"
  pass "invalid release contract rejected: $label"
}

valid_image_map_dir="$TMP_DIR/image-map-valid"
valid_bundle_root="$TMP_DIR/bundle-valid"
valid_bundle_manifest="$valid_bundle_root/airgap-bundle-manifest.json"
valid_output_dir="$TMP_DIR/out-valid"

create_materials "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$VALID_ARCHIVE"
run_image_map "$valid_image_map_dir"
create_bundle "$valid_image_map_dir/image-map.json" "$valid_bundle_root" "$valid_bundle_manifest"
run_airgap_bundle_check "$valid_image_map_dir/image-map.json" "$AIRGAP_PROFILE" "$valid_bundle_root" "$valid_bundle_manifest" "$valid_output_dir" >"$TMP_DIR/valid-airgap.out"
assert_report "$valid_output_dir/$REPORT_FILE"
if ! tail -n 1 "$TMP_DIR/valid-airgap.out" | grep -q 'readiness=false'; then
  cat "$TMP_DIR/valid-airgap.out" >&2
  fail "airgap bundle check stdout must end with readiness=false"
fi
pass "valid airgap bundle manifest accepted with focused non-readiness report"

expect_image_map_fail missing-target-registry missing_target_registry
expect_image_map_fail image-map-not-airgap online_target_profile
expect_image_map_fail mirror-required-false mirror_required_false
expect_image_map_fail image-map-inventory-source-mismatch mapping_source_image_mismatch
expect_image_map_fail image-map-source-digest-mismatch mapping_source_digest_mismatch
expect_image_map_fail image-map-mapping-id-missing mapping_id_missing
expect_image_map_fail image-map-duplicate-mapping-id duplicate_mapping_id
expect_image_map_fail image-map-image-count-mismatch image_count_mismatch
expect_image_map_fail \
  image-map-release-contract-inventory-count-mismatch \
  release_contract_inventory_count_mismatch
expect_image_map_fail image-map-target-digest-mismatch mapping_target_digest_mismatch
expect_image_map_fail image-map-target-image-digest-suffix-mismatch target_image_digest_suffix_mismatch
expect_image_map_fail target-image-outside-registry target_image_outside_registry
expect_image_map_fail target-image-missing-digest target_image_missing_digest

expect_bundle_fail schema-field-instead-of-schema-version schema_field_instead_of_schema_version
expect_bundle_fail extra-top-level-schema-with-schema-version extra_top_level_schema_with_schema_version
expect_bundle_fail component-id-instead-of-kind component_id_instead_of_kind
expect_bundle_fail component-id-with-kind component_id_with_kind
expect_bundle_fail unexpected-binding-field unexpected_binding_field
expect_bundle_fail unexpected-image-declaration-field unexpected_image_declaration_field
expect_bundle_fail unexpected-substrate-field unexpected_substrate_field
expect_bundle_fail missing-payload-artifacts missing_payload_artifacts
expect_bundle_fail missing-required-payload-kind missing_required_payload_kind
expect_bundle_fail payload-sha-mismatch payload_sha_mismatch
expect_bundle_fail unexpected-payload-field unexpected_payload_field
expect_bundle_fail payload-unknown-kind payload_unknown_kind
expect_bundle_fail missing-payload-file missing_payload_file
expect_bundle_fail payload-path-traversal payload_path_traversal
expect_bundle_fail duplicate-payload-id duplicate_payload_id
expect_bundle_fail unexpected-operator-field unexpected_operator_field
expect_bundle_fail missing-operator-prerequisites missing_operator_prerequisites
expect_bundle_fail operator-tools-empty operator_tools_empty
expect_bundle_fail operator-ref-empty operator_ref_empty
expect_bundle_fail unexpected-tool-field unexpected_tool_field
expect_bundle_fail bundled-tool-sha-mismatch bundled_tool_sha_mismatch
expect_bundle_fail operator-tool-missing-proof operator_tool_missing_proof
expect_bundle_fail tool-source-unknown tool_source_unknown
expect_bundle_fail tool-source-missing tool_source_missing
expect_bundle_fail tool-field-mixing tool_field_mixing
expect_bundle_fail bundled-tool-missing-path bundled_tool_missing_path
expect_bundle_fail bundled-tool-missing-sha bundled_tool_missing_sha
expect_bundle_fail operator-tool-missing-version operator_tool_missing_version
expect_bundle_fail operator-ref-https operator_ref_https
expect_bundle_fail operator-ref-embedded-https operator_ref_embedded_https
expect_bundle_fail operator-ref-token operator_ref_token
expect_bundle_fail operator-ref-public-download operator_ref_public_download
expect_bundle_fail operator-ref-wget operator_ref_wget
expect_bundle_fail operator-tool-location-https operator_tool_location_https
expect_bundle_fail operator-tool-location-embedded-oras operator_tool_location_embedded_oras
expect_bundle_fail operator-tool-location-wget operator_tool_location_wget
expect_bundle_fail operator-tool-proof-https operator_tool_proof_https
expect_bundle_fail operator-tool-proof-embedded-https operator_tool_proof_embedded_https
expect_bundle_fail operator-tool-proof-docker-pull operator_tool_proof_docker_pull
expect_bundle_fail operator-tool-proof-skopeo-copy operator_tool_proof_skopeo_copy
expect_bundle_fail operator-tool-proof-token operator_tool_proof_token
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
expect_material_fail missing-artifact-provenance missing_artifact_provenance
expect_material_fail artifact-provenance-non-object artifact_provenance_non_object
expect_material_fail missing-artifact-sha256 missing_artifact_sha256
expect_material_fail artifact-sha-invalid-format artifact_sha_invalid_format
expect_material_fail provenance-artifact-sha-mismatch provenance_artifact_sha_mismatch
expect_material_fail missing-deploy-package-required-image-ids missing_deploy_package_required_image_ids
expect_material_fail empty-deploy-package-required-image-ids empty_deploy_package_required_image_ids
expect_material_fail non-array-deploy-package-required-image-ids non_array_deploy_package_required_image_ids
expect_contract_fail target-profiles-not-array target_profiles_not_array
expect_contract_fail contract-missing-airgap-target-profile target_profiles_missing_airgap
expect_contract_fail contract-noncanonical-target-tuple target_profiles_noncanonical_synonym
expect_contract_fail target-required-missing target_required_missing
expect_contract_fail target-required-string target_required_string
expect_contract_fail target-required-true target_required_true
expect_contract_fail target-support-level-present target_support_level
expect_contract_fail kind-required-target-profile kind_required_target_profile
expect_contract_fail duplicate-target-profile-tuple duplicate_target_profile_tuple
expect_contract_fail missing-release-required-image-ids missing_release_required_image_ids
expect_contract_fail required-image-ids-mismatch required_image_ids_mismatch
expect_contract_fail stale-six-image-required-image-ids stale_six_image_required_image_ids
expect_contract_fail required-image-id-missing-in-inventory required_image_id_missing_in_inventory
expect_contract_fail \
  required-current-image-id-absent-from-inventory \
  required_current_image_id_absent_from_inventory \
  "release_contract.deploy_image_inventory must match declared image sources"

expect_profile_fail online "$ONLINE_PROFILE"
expect_profile_fail kind-rehearsal "$KIND_PROFILE"
expect_profile_fail kit-installed-airgap "$KIT_AIRGAP_PROFILE"
expect_profile_fail alias-offline "existing_kubernetes/external_declared/offline"
expect_profile_fail alias-air-gapped "existing_kubernetes/external_declared/air-gapped"

pass "airgap bundle manifest/digest focused diagnostic tests completed"
