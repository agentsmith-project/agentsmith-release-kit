#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
EXTERNAL_AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIT_ONLINE_PROFILE="existing_kubernetes/kit_installed/online"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
# Repo-local fixture snapshots are copied from AgentSmith generated release-boundary
# fixtures. Keep this test independent from the sibling repo path at runtime.

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

run_inputs() {
  local contract="$1"
  local deploy_template_package="$2"
  local output_dir="$3"
  local target_profile="${4:-$TARGET_PROFILE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --inputs \
    --release-contract "$contract" \
    --deploy-template-package "$deploy_template_package" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local contract="$2"
  local deploy_template_package="${3:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"
  local target_profile="${4:-$TARGET_PROFILE}"
  local output_dir="$TMP_DIR/out-$label"

  if run_inputs "$contract" "$deploy_template_package" "$output_dir" "$target_profile" >/dev/null 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid case to fail: $label"
  fi

  pass "invalid case rejected: $label"
}

expect_target_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local output_dir="$TMP_DIR/out-$label"

  if run_inputs "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$output_dir" "$target_profile" >/dev/null 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  pass "invalid target profile rejected: $label"
}

mutate_contract() {
  local label="$1"
  local output="$2"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$output" "$label" "$ROOT_DIR" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [input, output, label, rootDir] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(input, 'utf8'));
const digestE = `sha256:${'e'.repeat(64)}`;
const digestUpperA = `sha256:${'A'.repeat(64)}`;
const staleSixImageIds = contract.required_image_ids.filter((id) => id !== 'managed_runner');

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

function refreshContractSubjectDigest() {
  contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
}

function refreshContractArtifactDigest() {
  contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);
}

  switch (label) {
  case 'tag-only-image':
    contract.product_images[0].image = 'ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0';
    break;
  case 'digest-mismatch':
    contract.product_images[0].digest = digestE;
    break;
  case 'missing-provenance':
    delete contract.artifact_provenance;
    break;
  case 'missing-provenance-workflow-name':
    delete contract.artifact_provenance.workflow_name;
    break;
  case 'bad-subject-sha256':
    contract.artifact_provenance.subject_sha256 = digestE;
    break;
  case 'bad-contract-artifact-sha256':
    contract.artifact_provenance.artifact_sha256 = `sha256:${'9'.repeat(64)}`;
    break;
  case 'local-subject-uri':
    contract.artifact_provenance.subject_uri = 'file:///tmp/release-contract.json';
    break;
  case 'github-source-subject-uri':
    contract.artifact_provenance.subject_uri =
      'https://github.com/agentsmith-project/agentsmith/blob/main/release-contract.json';
    break;
  case 'deploy-package-bad-subject-sha256':
    contract.deploy_template_package.artifact_provenance.subject_sha256 = digestE;
    refreshContractSubjectDigest();
    break;
  case 'missing-attestation':
    delete contract.artifact_provenance.attestation;
    delete contract.deploy_template_package.artifact_provenance.attestation;
    break;
  case 'deploy-package-missing-attestation':
    delete contract.deploy_template_package.artifact_provenance.attestation;
    break;
  case 'bad-artifact-provenance-schema':
    contract.artifact_provenance.schema_version = 'agentsmith.artifact-provenance/v0';
    contract.deploy_template_package.artifact_provenance.schema_version =
      'agentsmith.artifact-provenance/v0';
    break;
  case 'deploy-package-bad-artifact-provenance-schema':
    contract.deploy_template_package.artifact_provenance.schema_version =
      'agentsmith.artifact-provenance/v0';
    break;
  case 'bad-provenance-kind':
    contract.artifact_provenance.provenance_kind = 'local_build';
    contract.deploy_template_package.artifact_provenance.provenance_kind = 'local_build';
    break;
  case 'template-digest-drift':
    contract.deploy_template_digest = `sha256:${'2'.repeat(64)}`;
    break;
  case 'package-provenance-artifact-drift':
    contract.deploy_template_package.artifact_provenance.artifact_uri =
      'gh-artifact://agentsmith/deploy-template-package/10001/drift.tgz';
    break;
  case 'missing-target-profile':
    contract.target_profiles = contract.target_profiles.filter((profile) =>
      !(
        profile.target_cluster === 'existing_kubernetes' &&
        profile.substrate_source === 'external_declared' &&
        profile.distribution === 'online'
      )
    );
    break;
  case 'missing-target-profile-required':
    delete contract.target_profiles[0].required;
    break;
  case 'target-profile-support-level-substitute':
    delete contract.target_profiles[0].required;
    contract.target_profiles[0].support_level = 'primary';
    break;
  case 'target-profile-support-level-present':
    contract.target_profiles[0].support_level = 'primary';
    break;
  case 'duplicate-target-profile-tuple':
    contract.target_profiles[2].target_cluster = contract.target_profiles[0].target_cluster;
    contract.target_profiles[2].substrate_source = contract.target_profiles[0].substrate_source;
    contract.target_profiles[2].distribution = contract.target_profiles[0].distribution;
    break;
  case 'pre-ga-required-target-profile':
    contract.target_profiles[0].required = true;
    break;
  case 'kind-required-target-profile':
    contract.target_profiles[2].required = true;
    refreshContractSubjectDigest();
    refreshContractArtifactDigest();
    break;
  case 'noncanonical-contract-profile-local-kind':
    contract.target_profiles[2].target_cluster = 'local-kind';
    break;
  case 'noncanonical-contract-profile-existing-cluster':
    contract.target_profiles[0].target_cluster = 'existing-cluster';
    break;
  case 'noncanonical-contract-profile-real-k8s':
    contract.target_profiles[0].target_cluster = 'real-k8s';
    break;
  case 'noncanonical-contract-profile-substrate-cluster':
    contract.target_profiles[0].substrate_source = 'cluster';
    break;
  case 'noncanonical-contract-profile-distribution-cluster':
    contract.target_profiles[0].distribution = 'cluster';
    break;
  case 'non-agentsmith-repo-provenance':
    contract.artifact_provenance.producer_repo = 'https://github.com/example/not-agentsmith';
    contract.artifact_provenance.normalized_remote = 'https://github.com/example/not-agentsmith';
    contract.deploy_template_package.artifact_provenance.producer_repo =
      'https://github.com/example/not-agentsmith';
    contract.deploy_template_package.artifact_provenance.normalized_remote =
      'https://github.com/example/not-agentsmith';
    break;
  case 'non-agentsmith-product':
    contract.product = 'not-agentsmith';
    break;
  case 'missing-openapi-digest':
    delete contract.openapi_digest;
    break;
  case 'missing-asyncapi-digest':
    delete contract.asyncapi_digest;
    break;
  case 'missing-substrate-connection-schema':
    delete contract.substrate_connection_schema;
    break;
  case 'missing-min-release-kit-version':
    delete contract.min_release_kit_version;
    break;
  case 'bad-openapi-digest':
    contract.openapi_digest = 'sha256:not-a-digest';
    break;
  case 'bad-substrate-connection-schema':
    contract.substrate_connection_schema = 'agentsmith.substrate-connection.truth/v0';
    break;
  case 'bad-min-release-kit-version':
    contract.min_release_kit_version = 1;
    break;
  case 'v-prefixed-min-release-kit-version':
    contract.min_release_kit_version = 'v0.1.0';
    break;
  case 'short-min-release-kit-version':
    contract.min_release_kit_version = '0.1';
    break;
  case 'leading-zero-min-release-kit-version':
    contract.min_release_kit_version = '0.01.0';
    break;
  case 'future-min-release-kit-version':
    contract.min_release_kit_version = '0.2.0';
    break;
  case 'localhost-artifact-uri':
    contract.artifact_provenance.artifact_uri = 'http://localhost:8080/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'ipv4-loopback-artifact-uri':
    contract.artifact_provenance.artifact_uri = 'https://127.0.0.2/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'ipv4-unspecified-artifact-uri':
    contract.artifact_provenance.artifact_uri = 'https://0.1.2.3/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'ipv6-unspecified-artifact-uri':
    contract.artifact_provenance.artifact_uri = 'https://[::]/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'github-api-source-artifact-uri':
    contract.artifact_provenance.artifact_uri =
      'https://api.github.com/repos/agentsmith-project/agentsmith/contents/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'github-api-percent-encoded-contents-artifact-uri':
    contract.artifact_provenance.artifact_uri =
      'https://api.github.com/repos/agentsmith-project/agentsmith/cont%65nts/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'github-source-identity-artifact-uri':
    contract.artifact_provenance.artifact_uri =
      'https://github.com/agentsmith-project/agentsmith/commit/0123456789abcdef0123456789abcdef01234567';
    refreshContractArtifactDigest();
    break;
  case 'github-repo-root-artifact-uri':
    contract.artifact_provenance.artifact_uri =
      'https://github.com/agentsmith-project/agentsmith';
    refreshContractArtifactDigest();
    break;
  case 'github-dotgit-artifact-uri':
    contract.artifact_provenance.artifact_uri =
      'https://github.com/agentsmith-project/agentsmith.git';
    refreshContractArtifactDigest();
    break;
  case 'github-percent-encoded-blob-artifact-uri':
    contract.artifact_provenance.artifact_uri =
      'https://github.com/agentsmith-project/agentsmith/bl%6fb/main/release-contract.json';
    refreshContractArtifactDigest();
    break;
  case 'missing-target-prerequisites':
    delete contract.target_profiles[0].prerequisites;
    break;
  case 'lowercase-secretref-pull-secret-ref':
    contract.target_profiles[0].prerequisites.pull_secret_ref =
      'secretref:workspace/release-pull-secret';
    break;
  case 'ref-pull-secret-ref':
    contract.target_profiles[0].prerequisites.pull_secret_ref =
      'ref:workspace/release-pull-secret';
    break;
  case 'colon-only-secretref-pull-secret-ref':
    contract.target_profiles[0].prerequisites.pull_secret_ref = 'secretRef:   :   ';
    refreshContractSubjectDigest();
    refreshContractArtifactDigest();
    break;
  case 'duplicate-image-id':
    contract.adopted_provider_images[0].id = contract.product_images[0].id;
    contract.deploy_image_inventory[1].id = contract.deploy_image_inventory[0].id;
    break;
  case 'missing-release-required-image-ids':
    delete contract.required_image_ids;
    break;
  case 'required-image-ids-mismatch':
    contract.required_image_ids = contract.required_image_ids.slice(0, -1);
    break;
  case 'stale-six-image-required-image-ids':
    contract.required_image_ids = staleSixImageIds;
    contract.deploy_template_package.required_image_ids = staleSixImageIds;
    break;
  case 'missing-deploy-package-required-image-ids':
    delete contract.deploy_template_package.required_image_ids;
    break;
  case 'empty-deploy-package-required-image-ids':
    contract.deploy_template_package.required_image_ids = [];
    break;
  case 'non-array-deploy-package-required-image-ids':
    contract.deploy_template_package.required_image_ids = 'agentsmith_app';
    break;
  case 'duplicate-deploy-package-required-image-id':
    contract.deploy_template_package.required_image_ids = [
      ...contract.deploy_template_package.required_image_ids,
      contract.deploy_template_package.required_image_ids[0]
    ];
    break;
  case 'required-image-id-missing-in-inventory':
    contract.required_image_ids = [...contract.required_image_ids, 'missing_component'];
    contract.deploy_template_package.required_image_ids = [...contract.required_image_ids];
    break;
  case 'required-current-image-id-absent-from-inventory':
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.id !== 'asbcp'
    );
    break;
  case 'uppercase-image-digest':
    contract.product_images[0].image = contract.product_images[0].image.replace(
      /@sha256:[0-9a-f]{64}$/,
      `@${digestUpperA}`
    );
    contract.product_images[0].digest = digestUpperA;
    contract.deploy_image_inventory[0].image = contract.product_images[0].image;
    contract.deploy_image_inventory[0].digest = digestUpperA;
    break;
  case 'empty-provider-images':
    contract.adopted_provider_images = [];
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.source !== 'adopted_provider_images'
    );
    break;
  case 'empty-required-product-flows':
    contract.required_product_flows = [];
    break;
  case 'bad-required-product-flow':
    contract.required_product_flows = ['workspace_project', ''];
    break;
  case 'bearer-token':
    contract.operator_inputs = {
      authorization: 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fake-signature'
    };
    break;
  case 'invalid-attestation-uri':
    contract.artifact_provenance.attestation = {
      attestation_uri: 'http://127.0.0.1:8080/attestation.intoto.jsonl',
      attestation_sha256: digestE
    };
    break;
  case 'retired-attestation-fields':
    contract.artifact_provenance.attestation = {
      artifact_uri: 'gh-artifact://agentsmith/release-contract/10001/attestation.intoto.jsonl',
      artifact_sha256: digestE
    };
    break;
  case 'local-source-uri':
    contract.operator_inputs = {
      source_uri: `file://${rootDir}/../${'agent'}${'smith'}`
    };
    break;
  case 'github-source-operator-input-uri':
    contract.operator_inputs = {
      source_uri:
        'https://github.com/agentsmith-project/agentsmith/blob/main/release-contract.json'
    };
    refreshContractSubjectDigest();
    refreshContractArtifactDigest();
    break;
  case 'absolute-source-path':
    contract.operator_inputs = {
      source_uri: '/tmp/agentsmith/release-contract.json'
    };
    break;
  case 'relative-source-path':
    contract.operator_inputs = {
      source_uri: 'artifacts/release-contract.json'
    };
    break;
  case 'secret-leak':
    contract.operator_inputs = {
      api_key: `sk-${'1234567890abcdef'}`
    };
    break;
  default:
    throw new Error(`unknown mutation: ${label}`);
}

fs.writeFileSync(output, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

write_attested_inputs() {
  local contract_output="$1"
  local deploy_template_package_output="$2"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    "$contract_output" \
    "$deploy_template_package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  contractInput,
  deployTemplatePackageInput,
  contractOutput,
  deployTemplatePackageOutput
] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(deployTemplatePackageInput, 'utf8'));
const contractAttestation = {
  attestation_uri: 'gh-artifact://agentsmith/release-contract/10001/attestation.intoto.jsonl',
  attestation_sha256: `sha256:${'9'.repeat(64)}`
};
const packageAttestation = {
  attestation_uri: 'gh-artifact://agentsmith/deploy-template-package/10001/attestation.intoto.jsonl',
  attestation_sha256: `sha256:${'8'.repeat(64)}`
};

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

contract.artifact_provenance.attestation = contractAttestation;
contract.deploy_template_package.artifact_provenance.attestation = packageAttestation;
deployTemplatePackage.artifact_provenance.attestation = packageAttestation;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
fs.writeFileSync(deployTemplatePackageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
NODE
}

write_secret_ref_inputs() {
  local contract_output="$1"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$contract_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [contractInput, contractOutput] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));

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

contract.target_profiles[0].prerequisites.pull_secret_ref =
  'secretRef:workspace/release-pull-secret';
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

write_github_actions_artifact_api_inputs() {
  local contract_output="$1"
  local deploy_template_package_output="$2"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    "$contract_output" \
    "$deploy_template_package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  contractInput,
  deployTemplatePackageInput,
  contractOutput,
  deployTemplatePackageOutput
] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(deployTemplatePackageInput, 'utf8'));
const contractArtifactUri =
  'https://api.github.com/repos/agentsmith-project/agentsmith/actions/artifacts/10001/zip';
const packageArtifactUri =
  'https://api.github.com/repos/agentsmith-project/agentsmith/actions/artifacts/10002/zip';

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

contract.artifact_provenance.artifact_uri = contractArtifactUri;
deployTemplatePackage.package_uri = packageArtifactUri;
deployTemplatePackage.artifact_provenance.artifact_uri = packageArtifactUri;
deployTemplatePackage.artifact_provenance.subject_sha256 = subjectDigest(deployTemplatePackage);
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
fs.writeFileSync(deployTemplatePackageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
NODE
}

write_github_release_download_inputs() {
  local contract_output="$1"
  local deploy_template_package_output="$2"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    "$contract_output" \
    "$deploy_template_package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  contractInput,
  deployTemplatePackageInput,
  contractOutput,
  deployTemplatePackageOutput
] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(deployTemplatePackageInput, 'utf8'));
const contractArtifactUri =
  'https://github.com/agentsmith-project/agentsmith/releases/download/v2026.05.23/release-contract.json';
const packageArtifactUri =
  'https://github.com/agentsmith-project/agentsmith/releases/download/v2026.05.23/agentsmith-deploy-template-package.tgz';

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

contract.artifact_provenance.artifact_uri = contractArtifactUri;
deployTemplatePackage.package_uri = packageArtifactUri;
deployTemplatePackage.artifact_provenance.artifact_uri = packageArtifactUri;
deployTemplatePackage.artifact_provenance.subject_sha256 = subjectDigest(deployTemplatePackage);
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
fs.writeFileSync(deployTemplatePackageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
NODE
}

mutate_deploy_template_package() {
  local label="$1"
  local output="$2"

  "$NODE_BIN" --input-type=module - "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$output" "$label" <<'NODE'
import fs from 'node:fs';

const [input, output, label] = process.argv.slice(2);
const deployTemplatePackage = JSON.parse(fs.readFileSync(input, 'utf8'));
const staleSixImageIds = deployTemplatePackage.required_image_ids.filter(
  (id) => id !== 'managed_runner'
);

switch (label) {
  case 'deploy-package-bad-subject-sha256':
    deployTemplatePackage.artifact_provenance.subject_sha256 = `sha256:${'e'.repeat(64)}`;
    break;
  case 'bad-provenance-kind':
    deployTemplatePackage.artifact_provenance.provenance_kind = 'local_build';
    break;
  case 'missing-attestation':
  case 'deploy-package-missing-attestation':
    delete deployTemplatePackage.artifact_provenance.attestation;
    break;
  case 'bad-artifact-provenance-schema':
  case 'deploy-package-bad-artifact-provenance-schema':
    deployTemplatePackage.artifact_provenance.schema_version =
      'agentsmith.artifact-provenance/v0';
    break;
  case 'non-agentsmith-repo-provenance':
    deployTemplatePackage.artifact_provenance.producer_repo =
      'https://github.com/example/not-agentsmith';
    deployTemplatePackage.artifact_provenance.normalized_remote =
      'https://github.com/example/not-agentsmith';
    break;
  case 'package-provenance-artifact-drift':
    deployTemplatePackage.artifact_provenance.artifact_uri =
      'gh-artifact://agentsmith/deploy-template-package/10001/drift.tgz';
    break;
  case 'stale-six-image-required-image-ids':
    deployTemplatePackage.required_image_ids = staleSixImageIds;
    break;
  case 'missing-deploy-package-required-image-ids':
    delete deployTemplatePackage.required_image_ids;
    break;
  case 'empty-deploy-package-required-image-ids':
    deployTemplatePackage.required_image_ids = [];
    break;
  case 'non-array-deploy-package-required-image-ids':
    deployTemplatePackage.required_image_ids = 'agentsmith_app';
    break;
  case 'duplicate-deploy-package-required-image-id':
    deployTemplatePackage.required_image_ids = [
      ...deployTemplatePackage.required_image_ids,
      deployTemplatePackage.required_image_ids[0]
    ];
    break;
  case 'required-image-id-missing-in-inventory':
    deployTemplatePackage.required_image_ids = [
      ...deployTemplatePackage.required_image_ids,
      'missing_component'
    ];
    break;
  default:
    throw new Error(`unknown mutation: ${label}`);
}

fs.writeFileSync(output, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
NODE
}

assert_outputs() {
  local output_dir="$1"
  local expected_profile="${2:-$TARGET_PROFILE}"
  local expected_required="${3:-false}"
  local expected_contract="${4:-$VALID_CONTRACT}"

  "$NODE_BIN" --input-type=module - "$output_dir" "$expected_profile" "$expected_required" "$expected_contract" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [outputDir, expectedProfile, expectedRequiredText, expectedContract] =
  process.argv.slice(2);
const [expectedTargetCluster, expectedSubstrateSource, expectedDistribution] =
  expectedProfile.split('/');
const expectedRequired = expectedRequiredText === 'true';
const contract = JSON.parse(fs.readFileSync(expectedContract, 'utf8'));
const expectedImageIds = contract.deploy_image_inventory.map((item) => item.id);
const allowedKeys = [
  'artifacts',
  'digests',
  'git_sha',
  'images',
  'readiness',
  'release_id',
  'scope',
  'status',
  'target_profile'
];

for (const file of ['intake-report.json', 'image-digest-plan.json']) {
  const payload = JSON.parse(fs.readFileSync(path.join(outputDir, file), 'utf8'));
  const keys = Object.keys(payload).sort();
  const expected = [...allowedKeys].sort();
  if (JSON.stringify(keys) !== JSON.stringify(expected)) {
    throw new Error(`${file} has unexpected keys: ${keys.join(',')}`);
  }
  if (payload.status !== 'pass') {
    throw new Error(`${file} did not record pass status`);
  }
  if (payload.scope !== 'contract_intake_only') {
    throw new Error(`${file} did not declare contract_intake_only scope`);
  }
  if (payload.readiness !== false) {
    throw new Error(`${file} must not claim release readiness`);
  }
  if (!payload.artifacts?.release_contract?.input_sha256) {
    throw new Error(`${file} did not include release contract input digest`);
  }
  if (!payload.artifacts?.deploy_template_package?.input_sha256) {
    throw new Error(`${file} did not include deploy template package input digest`);
  }
  if (!payload.artifacts?.deploy_template_package?.package_sha256) {
    throw new Error(`${file} did not include package_sha256`);
  }
  if (!payload.artifacts?.deploy_template_package?.manifest_sha256) {
    throw new Error(`${file} did not include manifest_sha256`);
  }
  if (payload.target_profile?.target_cluster !== expectedTargetCluster) {
    throw new Error(`${file} did not split target profile fields`);
  }
  if (payload.target_profile?.substrate_source !== expectedSubstrateSource) {
    throw new Error(`${file} did not split target profile fields`);
  }
  if (payload.target_profile?.distribution !== expectedDistribution) {
    throw new Error(`${file} did not split target profile fields`);
  }
  if (payload.target_profile?.required !== expectedRequired) {
    throw new Error(`${file} did not preserve target profile required metadata`);
  }
  if (!Array.isArray(payload.images)) {
    throw new Error(`${file} did not include expected image inventory`);
  }
  if (!Array.isArray(payload.digests) || payload.digests.length !== payload.images.length) {
    throw new Error(`${file} did not include expected digest plan`);
  }
  const imageIds = payload.images.map((item) => item.id);
  const digestIds = payload.digests.map((item) => item.id);
  if (JSON.stringify(imageIds) !== JSON.stringify(expectedImageIds)) {
    throw new Error(`${file} did not include release contract image inventory: ${imageIds.join(',')}`);
  }
  if (JSON.stringify(digestIds) !== JSON.stringify(expectedImageIds)) {
    throw new Error(`${file} did not include release contract digest plan: ${digestIds.join(',')}`);
  }
}
NODE
}

assert_coverage_report() {
  local output_dir="$1"
  local expected_status="${2:-pass}"
  local expected_missing="${3:-}"

  "$NODE_BIN" --input-type=module - "$output_dir" "$expected_status" "$expected_missing" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [outputDir, expectedStatus, expectedMissing] = process.argv.slice(2);
const report = JSON.parse(
  fs.readFileSync(path.join(outputDir, 'target-profile-coverage-report.json'), 'utf8')
);
if (report.scope !== 'target_profile_coverage_intake_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('target profile coverage report must keep readiness=false');
}
if (report.status !== expectedStatus) {
  throw new Error(`unexpected status: ${report.status}`);
}
if ('release_verdict' in report || 'verdict' in report) {
  throw new Error('target profile coverage report must not claim a release verdict');
}
const declarableValues = new Set((report.declarable_profiles || []).map((profile) => profile.value));
const intakeValues = new Set((report.intake_supported_profiles || []).map((profile) => profile.value));
for (const value of [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap',
  'kind_rehearsal/kit_installed/online'
]) {
  if (!declarableValues.has(value)) {
    throw new Error(`declarable profile missing from report: ${value}`);
  }
  if (!intakeValues.has(value)) {
    throw new Error(`intake-supported profile missing from report: ${value}`);
  }
}
const executableValues = new Set((report.executable_profiles || []).map((profile) => profile.value));
if (
  executableValues.size !== 2 ||
  !executableValues.has('existing_kubernetes/external_declared/online') ||
  !executableValues.has('existing_kubernetes/kit_installed/online')
) {
  throw new Error('external-declared online and kit-installed online profiles must be executable in pre-GA');
}
for (const value of [
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/airgap',
  'kind_rehearsal/kit_installed/online'
]) {
  if (executableValues.has(value)) {
    throw new Error(`non-executable profile incorrectly listed as executable: ${value}`);
  }
}
const evidenceValues = new Set((report.evidence_supported_profiles || []).map((profile) => profile.value));
if (evidenceValues.size !== 2) {
  throw new Error('pre-GA evidence-supported profile set must stay narrow');
}
for (const value of [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap'
]) {
  if (!evidenceValues.has(value)) {
    throw new Error(`evidence-supported profile missing from report: ${value}`);
  }
}
for (const value of [
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap',
  'kind_rehearsal/kit_installed/online'
]) {
  if (evidenceValues.has(value)) {
    throw new Error(`intake-only profile incorrectly listed as evidence-supported: ${value}`);
  }
}
if (!Array.isArray(report.required_profiles)) {
  throw new Error('target profile coverage report must list required_profiles');
}
if (!Array.isArray(report.forbidden_required_profiles)) {
  throw new Error('target profile coverage report must list forbidden_required_profiles');
}
if (expectedStatus === 'pass' && report.forbidden_required_profiles.length !== 0) {
  throw new Error('passing target profile coverage report must not list forbidden required profiles');
}
if (expectedStatus === 'failed') {
  if (report.failure_class !== 'pre_ga_required_target_profile') {
    throw new Error(`unexpected failure_class: ${report.failure_class}`);
  }
  const forbiddenValues = new Set(report.forbidden_required_profiles.map((profile) => profile.value));
  if (!forbiddenValues.has(expectedMissing)) {
    throw new Error(`forbidden required profile not recorded: ${expectedMissing}`);
  }
}
NODE
}

expect_pre_ga_required_target_profile() {
  local contract="$TMP_DIR/pre-ga-required-target-profile.release-contract.json"
  local output_dir="$TMP_DIR/out-pre-ga-required-target-profile"

  mutate_contract pre-ga-required-target-profile "$contract"

  if run_inputs "$contract" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$output_dir" \
    >"$TMP_DIR/pre-ga-required-target-profile.out" \
    2>"$TMP_DIR/pre-ga-required-target-profile.err"; then
    cat "$TMP_DIR/pre-ga-required-target-profile.out" >&2
    cat "$TMP_DIR/pre-ga-required-target-profile.err" >&2
    fail "expected pre-GA required target profile to fail"
  fi

  assert_coverage_report \
    "$output_dir" \
    failed \
    existing_kubernetes/external_declared/online
  pass "pre-GA required target profile rejected with coverage report"
}

expect_kind_required_target_profile() {
  local contract="$TMP_DIR/kind-required-target-profile.release-contract.json"
  local output_dir="$TMP_DIR/out-kind-required-target-profile"

  mutate_contract kind-required-target-profile "$contract"

  if run_inputs "$contract" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$output_dir" \
    >"$TMP_DIR/kind-required-target-profile.out" \
    2>"$TMP_DIR/kind-required-target-profile.err"; then
    cat "$TMP_DIR/kind-required-target-profile.out" >&2
    cat "$TMP_DIR/kind-required-target-profile.err" >&2
    fail "expected kind required target profile to fail"
  fi

  if ! grep -q 'target_profiles.required must be false during pre-GA' \
    "$TMP_DIR/kind-required-target-profile.err"; then
    cat "$TMP_DIR/kind-required-target-profile.out" >&2
    cat "$TMP_DIR/kind-required-target-profile.err" >&2
    fail "kind required target profile failure must explain pre-GA required policy"
  fi

  pass "kind rehearsal required target profile rejected by pre-GA policy"
}

VALID_OUT="$TMP_DIR/valid"
run_inputs "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$VALID_OUT" >/dev/null
assert_outputs "$VALID_OUT"
assert_coverage_report "$VALID_OUT"
pass "valid AgentSmith generated artifact fixtures accepted"

EXTERNAL_AIRGAP_OUT="$TMP_DIR/valid-external-airgap"
run_inputs \
  "$VALID_CONTRACT" \
  "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
  "$EXTERNAL_AIRGAP_OUT" \
  "$EXTERNAL_AIRGAP_PROFILE" >/dev/null
assert_outputs "$EXTERNAL_AIRGAP_OUT" "$EXTERNAL_AIRGAP_PROFILE" false
assert_coverage_report "$EXTERNAL_AIRGAP_OUT"
pass "external-declared airgap intake profile accepted"

KIT_ONLINE_OUT="$TMP_DIR/valid-kit-online"
run_inputs \
  "$VALID_CONTRACT" \
  "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
  "$KIT_ONLINE_OUT" \
  "$KIT_ONLINE_PROFILE" >/dev/null
assert_outputs "$KIT_ONLINE_OUT" "$KIT_ONLINE_PROFILE" false
assert_coverage_report "$KIT_ONLINE_OUT"
pass "kit-installed online intake profile accepted"

KIT_AIRGAP_OUT="$TMP_DIR/valid-kit-airgap"
run_inputs \
  "$VALID_CONTRACT" \
  "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
  "$KIT_AIRGAP_OUT" \
  "$KIT_AIRGAP_PROFILE" >/dev/null
assert_outputs "$KIT_AIRGAP_OUT" "$KIT_AIRGAP_PROFILE" false
assert_coverage_report "$KIT_AIRGAP_OUT"
pass "kit-installed airgap intake profile accepted"

ATTESTED_CONTRACT="$TMP_DIR/valid-attested.release-contract.json"
ATTESTED_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/valid-attested.deploy-template-package.json"
ATTESTED_OUT="$TMP_DIR/valid-attested"
write_attested_inputs "$ATTESTED_CONTRACT" "$ATTESTED_DEPLOY_TEMPLATE_PACKAGE"
run_inputs "$ATTESTED_CONTRACT" "$ATTESTED_DEPLOY_TEMPLATE_PACKAGE" "$ATTESTED_OUT" >/dev/null
assert_outputs "$ATTESTED_OUT"
assert_coverage_report "$ATTESTED_OUT"
pass "valid AgentSmith attestation fields accepted"

GITHUB_API_CONTRACT="$TMP_DIR/valid-github-actions-api.release-contract.json"
GITHUB_API_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/valid-github-actions-api.deploy-template-package.json"
GITHUB_API_OUT="$TMP_DIR/valid-github-actions-api"
write_github_actions_artifact_api_inputs "$GITHUB_API_CONTRACT" "$GITHUB_API_DEPLOY_TEMPLATE_PACKAGE"
run_inputs "$GITHUB_API_CONTRACT" "$GITHUB_API_DEPLOY_TEMPLATE_PACKAGE" "$GITHUB_API_OUT" >/dev/null
assert_outputs "$GITHUB_API_OUT"
assert_coverage_report "$GITHUB_API_OUT"
pass "valid GitHub Actions artifact API URIs accepted"

GITHUB_RELEASE_CONTRACT="$TMP_DIR/valid-github-release-download.release-contract.json"
GITHUB_RELEASE_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/valid-github-release-download.deploy-template-package.json"
GITHUB_RELEASE_OUT="$TMP_DIR/valid-github-release-download"
write_github_release_download_inputs "$GITHUB_RELEASE_CONTRACT" "$GITHUB_RELEASE_DEPLOY_TEMPLATE_PACKAGE"
run_inputs "$GITHUB_RELEASE_CONTRACT" "$GITHUB_RELEASE_DEPLOY_TEMPLATE_PACKAGE" "$GITHUB_RELEASE_OUT" >/dev/null
assert_outputs "$GITHUB_RELEASE_OUT"
assert_coverage_report "$GITHUB_RELEASE_OUT"
pass "valid GitHub releases/download artifact URIs accepted"

SECRET_REF_CONTRACT="$TMP_DIR/valid-secret-ref.release-contract.json"
SECRET_REF_OUT="$TMP_DIR/valid-secret-ref"
write_secret_ref_inputs "$SECRET_REF_CONTRACT"
run_inputs "$SECRET_REF_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$SECRET_REF_OUT" >/dev/null
assert_outputs "$SECRET_REF_OUT"
assert_coverage_report "$SECRET_REF_OUT"
pass "valid secretRef pull_secret_ref accepted"

expect_pre_ga_required_target_profile
expect_kind_required_target_profile

expect_target_profile_fail "noncanonical-target-profile-local-kind" \
  "local-kind/external_declared/online"
expect_target_profile_fail "noncanonical-target-profile-existing-cluster" \
  "existing-cluster/external_declared/online"
expect_target_profile_fail "noncanonical-target-profile-real-k8s" \
  "real-k8s/external_declared/online"
expect_target_profile_fail "synonym-target-profile-kind" \
  "kind/external_declared/online"
expect_target_profile_fail "synonym-target-profile-substrate-cluster" \
  "existing_kubernetes/cluster/online"
expect_target_profile_fail "synonym-target-profile-distribution-cluster" \
  "existing_kubernetes/external_declared/cluster"

for label in \
  tag-only-image \
  digest-mismatch \
  missing-provenance \
  missing-provenance-workflow-name \
  bad-subject-sha256 \
  bad-contract-artifact-sha256 \
  local-subject-uri \
  github-source-subject-uri \
  deploy-package-bad-subject-sha256 \
  missing-attestation \
  deploy-package-missing-attestation \
  bad-artifact-provenance-schema \
  deploy-package-bad-artifact-provenance-schema \
  bad-provenance-kind \
  template-digest-drift \
  package-provenance-artifact-drift \
  missing-target-profile \
  missing-target-profile-required \
  target-profile-support-level-substitute \
  target-profile-support-level-present \
  duplicate-target-profile-tuple \
  noncanonical-contract-profile-local-kind \
  noncanonical-contract-profile-existing-cluster \
  noncanonical-contract-profile-real-k8s \
  noncanonical-contract-profile-substrate-cluster \
  noncanonical-contract-profile-distribution-cluster \
  non-agentsmith-repo-provenance \
  non-agentsmith-product \
  missing-openapi-digest \
  missing-asyncapi-digest \
  missing-substrate-connection-schema \
  missing-min-release-kit-version \
  bad-openapi-digest \
  bad-substrate-connection-schema \
  bad-min-release-kit-version \
  v-prefixed-min-release-kit-version \
  short-min-release-kit-version \
  leading-zero-min-release-kit-version \
  future-min-release-kit-version \
  localhost-artifact-uri \
  ipv4-loopback-artifact-uri \
  ipv4-unspecified-artifact-uri \
  ipv6-unspecified-artifact-uri \
  github-api-source-artifact-uri \
  github-api-percent-encoded-contents-artifact-uri \
  github-source-identity-artifact-uri \
  github-repo-root-artifact-uri \
  github-dotgit-artifact-uri \
  github-percent-encoded-blob-artifact-uri \
  missing-target-prerequisites \
  lowercase-secretref-pull-secret-ref \
  ref-pull-secret-ref \
  colon-only-secretref-pull-secret-ref \
  duplicate-image-id \
  missing-release-required-image-ids \
  required-image-ids-mismatch \
  stale-six-image-required-image-ids \
  missing-deploy-package-required-image-ids \
  empty-deploy-package-required-image-ids \
  non-array-deploy-package-required-image-ids \
  duplicate-deploy-package-required-image-id \
  required-image-id-missing-in-inventory \
  required-current-image-id-absent-from-inventory \
  uppercase-image-digest \
  empty-provider-images \
  empty-required-product-flows \
  bad-required-product-flow \
  bearer-token \
  invalid-attestation-uri \
  retired-attestation-fields \
  local-source-uri \
  github-source-operator-input-uri \
  absolute-source-path \
  relative-source-path \
  secret-leak
do
  mutated="$TMP_DIR/$label.release-contract.json"
  deploy_template_package="$VALID_DEPLOY_TEMPLATE_PACKAGE"
  mutate_contract "$label" "$mutated"

  case "$label" in
    bad-provenance-kind|deploy-package-bad-subject-sha256|missing-attestation|deploy-package-missing-attestation|bad-artifact-provenance-schema|deploy-package-bad-artifact-provenance-schema|non-agentsmith-repo-provenance|package-provenance-artifact-drift|stale-six-image-required-image-ids|missing-deploy-package-required-image-ids|empty-deploy-package-required-image-ids|non-array-deploy-package-required-image-ids|duplicate-deploy-package-required-image-id|required-image-id-missing-in-inventory)
      deploy_template_package="$TMP_DIR/$label.deploy-template-package.json"
      mutate_deploy_template_package "$label" "$deploy_template_package"
      ;;
  esac

  expect_fail "$label" "$mutated" "$deploy_template_package"
done

pass "release contract intake focused tests"
