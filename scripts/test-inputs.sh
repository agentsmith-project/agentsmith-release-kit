#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
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

  bash "$ROOT_DIR/scripts/verify-release.sh" --inputs \
    --release-contract "$contract" \
    --deploy-template-package "$deploy_template_package" \
    --target-profile "$TARGET_PROFILE" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local contract="$2"
  local deploy_template_package="${3:-$VALID_DEPLOY_TEMPLATE_PACKAGE}"
  local output_dir="$TMP_DIR/out-$label"

  if run_inputs "$contract" "$deploy_template_package" "$output_dir" >/dev/null 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid case to fail: $label"
  fi

  pass "invalid case rejected: $label"
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
    contract.product_images[0].image = 'ghcr.io/agentsmith-project/agentsmith-web:2026.05.23-p0';
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
    contract.product_images[1].id = contract.product_images[0].id;
    contract.deploy_image_inventory[1].id = contract.deploy_image_inventory[0].id;
    break;
  case 'uppercase-image-digest':
    contract.product_images[0].image =
      `ghcr.io/agentsmith-project/agentsmith-web:2026.05.23-p0@${digestUpperA}`;
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
  case 'missing-required-flow':
    contract.required_product_flows = contract.required_product_flows.filter(
      (flow) => flow !== 'files'
    );
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
  case 'legacy-attestation-fields':
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
  default:
    throw new Error(`unknown mutation: ${label}`);
}

fs.writeFileSync(output, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
NODE
}

assert_outputs() {
  local output_dir="$1"

  "$NODE_BIN" --input-type=module - "$output_dir" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [outputDir] = process.argv.slice(2);
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
  if (payload.target_profile?.target_cluster !== 'existing_kubernetes') {
    throw new Error(`${file} did not split target profile fields`);
  }
  if (payload.target_profile?.substrate_source !== 'external_declared') {
    throw new Error(`${file} did not split target profile fields`);
  }
  if (payload.target_profile?.distribution !== 'online') {
    throw new Error(`${file} did not split target profile fields`);
  }
  if (!Array.isArray(payload.images) || payload.images.length !== 5) {
    throw new Error(`${file} did not include expected image inventory`);
  }
  if (!Array.isArray(payload.digests) || payload.digests.length !== 5) {
    throw new Error(`${file} did not include expected digest plan`);
  }
  if (!payload.images.every((item) => typeof item.id === 'string')) {
    throw new Error(`${file} did not include expected image inventory`);
  }
  if (!payload.digests.every((item) => typeof item.id === 'string')) {
    throw new Error(`${file} did not include id-bound digest plan`);
  }
}
NODE
}

VALID_OUT="$TMP_DIR/valid"
run_inputs "$VALID_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$VALID_OUT" >/dev/null
assert_outputs "$VALID_OUT"
pass "valid AgentSmith generated artifact fixtures accepted"

ATTESTED_CONTRACT="$TMP_DIR/valid-attested.release-contract.json"
ATTESTED_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/valid-attested.deploy-template-package.json"
ATTESTED_OUT="$TMP_DIR/valid-attested"
write_attested_inputs "$ATTESTED_CONTRACT" "$ATTESTED_DEPLOY_TEMPLATE_PACKAGE"
run_inputs "$ATTESTED_CONTRACT" "$ATTESTED_DEPLOY_TEMPLATE_PACKAGE" "$ATTESTED_OUT" >/dev/null
assert_outputs "$ATTESTED_OUT"
pass "valid AgentSmith attestation fields accepted"

GITHUB_API_CONTRACT="$TMP_DIR/valid-github-actions-api.release-contract.json"
GITHUB_API_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/valid-github-actions-api.deploy-template-package.json"
GITHUB_API_OUT="$TMP_DIR/valid-github-actions-api"
write_github_actions_artifact_api_inputs "$GITHUB_API_CONTRACT" "$GITHUB_API_DEPLOY_TEMPLATE_PACKAGE"
run_inputs "$GITHUB_API_CONTRACT" "$GITHUB_API_DEPLOY_TEMPLATE_PACKAGE" "$GITHUB_API_OUT" >/dev/null
assert_outputs "$GITHUB_API_OUT"
pass "valid GitHub Actions artifact API URIs accepted"

GITHUB_RELEASE_CONTRACT="$TMP_DIR/valid-github-release-download.release-contract.json"
GITHUB_RELEASE_DEPLOY_TEMPLATE_PACKAGE="$TMP_DIR/valid-github-release-download.deploy-template-package.json"
GITHUB_RELEASE_OUT="$TMP_DIR/valid-github-release-download"
write_github_release_download_inputs "$GITHUB_RELEASE_CONTRACT" "$GITHUB_RELEASE_DEPLOY_TEMPLATE_PACKAGE"
run_inputs "$GITHUB_RELEASE_CONTRACT" "$GITHUB_RELEASE_DEPLOY_TEMPLATE_PACKAGE" "$GITHUB_RELEASE_OUT" >/dev/null
assert_outputs "$GITHUB_RELEASE_OUT"
pass "valid GitHub releases/download artifact URIs accepted"

SECRET_REF_CONTRACT="$TMP_DIR/valid-secret-ref.release-contract.json"
SECRET_REF_OUT="$TMP_DIR/valid-secret-ref"
write_secret_ref_inputs "$SECRET_REF_CONTRACT"
run_inputs "$SECRET_REF_CONTRACT" "$VALID_DEPLOY_TEMPLATE_PACKAGE" "$SECRET_REF_OUT" >/dev/null
assert_outputs "$SECRET_REF_OUT"
pass "valid secretRef pull_secret_ref accepted"

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
  non-agentsmith-repo-provenance \
  non-agentsmith-product \
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
  uppercase-image-digest \
  empty-provider-images \
  missing-required-flow \
  bearer-token \
  invalid-attestation-uri \
  legacy-attestation-fields \
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
    bad-provenance-kind|deploy-package-bad-subject-sha256|missing-attestation|deploy-package-missing-attestation|bad-artifact-provenance-schema|deploy-package-bad-artifact-provenance-schema|non-agentsmith-repo-provenance|package-provenance-artifact-drift)
      deploy_template_package="$TMP_DIR/$label.deploy-template-package.json"
      mutate_deploy_template_package "$label" "$deploy_template_package"
      ;;
  esac

  expect_fail "$label" "$mutated" "$deploy_template_package"
done

pass "release contract intake focused tests"
