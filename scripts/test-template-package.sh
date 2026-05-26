#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
  local label="$1"
  local archive="$2"
  local extra_file="${3:-}"
  local extra_content="${4:-extra diagnostic file}"
  local package_dir="$TMP_DIR/package-$label"

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

  if [[ -n "$extra_file" ]]; then
    printf '%s\n' "$extra_content" >"$package_dir/$extra_file"
    tar -czf "$archive" -C "$package_dir" manifest.json templates/deployment.yaml "$extra_file"
  else
    tar -czf "$archive" -C "$package_dir" manifest.json templates/deployment.yaml
  fi

  sha256_file "$package_dir/manifest.json"
}

create_absolute_path_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-absolute-path"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  printf 'absolute path entry\n' >"$package_dir/absolute.txt"
  tar -P -czf "$archive" -C "$package_dir" manifest.json --transform='s#^absolute.txt$#/absolute.txt#' absolute.txt

  sha256_file "$package_dir/manifest.json"
}

create_traversal_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-traversal"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  printf 'escape\n' >"$package_dir/escape.txt"
  tar -czf "$archive" -C "$package_dir" manifest.json --transform='s#^escape.txt$#../escape.txt#' escape.txt

  sha256_file "$package_dir/manifest.json"
}

create_symlink_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-symlink"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  ln -s manifest.json "$package_dir/manifest-link.json"
  tar -czf "$archive" -C "$package_dir" manifest.json manifest-link.json

  sha256_file "$package_dir/manifest.json"
}

create_hardlink_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-hardlink"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  ln "$package_dir/manifest.json" "$package_dir/manifest-hardlink.json"
  tar -czf "$archive" -C "$package_dir" manifest.json manifest-hardlink.json

  sha256_file "$package_dir/manifest.json"
}

write_materials() {
  local manifest_sha="$1"
  local archive_sha="$2"
  local contract_output="$3"
  local deploy_template_package_output="$4"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
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

mutate_manifest_sha() {
  local contract_input="$1"
  local package_input="$2"
  local contract_output="$3"
  local package_output="$4"

  "$NODE_BIN" --input-type=module - "$contract_input" "$package_input" "$contract_output" "$package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [contractInput, packageInput, contractOutput, packageOutput] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));
const driftDigest = `sha256:${'6'.repeat(63)}7`;

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

deployTemplatePackage.manifest_sha256 = driftDigest;
deployTemplatePackage.artifact_provenance.subject_sha256 = subjectDigest(deployTemplatePackage);
contract.deploy_template_digest = driftDigest;
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_artifact_provenance_sha() {
  local contract_input="$1"
  local package_input="$2"
  local contract_output="$3"
  local package_output="$4"

  "$NODE_BIN" --input-type=module - "$contract_input" "$package_input" "$contract_output" "$package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [contractInput, packageInput, contractOutput, packageOutput] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));
const driftDigest = `sha256:${'7'.repeat(63)}8`;

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

deployTemplatePackage.artifact_provenance.artifact_sha256 = driftDigest;
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_descriptor_only() {
  local package_input="$1"
  local package_output="$2"

  "$NODE_BIN" --input-type=module - "$package_input" "$package_output" <<'NODE'
import fs from 'node:fs';

const [packageInput, packageOutput] = process.argv.slice(2);
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));
deployTemplatePackage.package_uri =
  'gh-artifact://agentsmith/deploy-template-package/10001/descriptor-drift.tgz';
fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
NODE
}

mutate_required_image_ids() {
  local contract_input="$1"
  local package_input="$2"
  local contract_output="$3"
  local package_output="$4"
  local mutation="$5"

  "$NODE_BIN" --input-type=module - "$contract_input" "$package_input" "$contract_output" "$package_output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [contractInput, packageInput, contractOutput, packageOutput, mutation] =
  process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));
const staleSixImageIds = contract.required_image_ids.filter((id) => id !== 'managed_runner');

switch (mutation) {
  case 'missing-release-required-image-ids':
    delete contract.required_image_ids;
    break;
  case 'required-image-ids-mismatch':
    contract.required_image_ids = contract.required_image_ids.slice(0, -1);
    break;
  case 'stale-six-image-required-image-ids':
    contract.required_image_ids = staleSixImageIds;
    contract.deploy_template_package.required_image_ids = staleSixImageIds;
    deployTemplatePackage.required_image_ids = staleSixImageIds;
    break;
  case 'missing-deploy-package-required-image-ids':
    delete contract.deploy_template_package.required_image_ids;
    delete deployTemplatePackage.required_image_ids;
    break;
  case 'empty-deploy-package-required-image-ids':
    contract.deploy_template_package.required_image_ids = [];
    deployTemplatePackage.required_image_ids = [];
    break;
  case 'non-array-deploy-package-required-image-ids':
    contract.deploy_template_package.required_image_ids = 'agentsmith_app';
    deployTemplatePackage.required_image_ids = 'agentsmith_app';
    break;
  case 'required-image-id-missing-in-inventory':
    contract.required_image_ids = [...contract.required_image_ids, 'missing_component'];
    contract.deploy_template_package.required_image_ids = [...contract.required_image_ids];
    deployTemplatePackage.required_image_ids = [...contract.required_image_ids];
    break;
  case 'required-current-image-id-absent-from-inventory':
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.id !== 'asbcp'
    );
    break;
  default:
    throw new Error(`unknown required_image_ids mutation: ${mutation}`);
}

fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

run_template_package() {
  local contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local output_dir="$4"

  bash "$ROOT_DIR/scripts/verify-release.sh" --template-package \
    --release-contract "$contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local contract="$2"
  local deploy_template_package="$3"
  local archive="$4"
  local expected_stderr="${5:-}"
  local output_dir="$TMP_DIR/out-$label"

  if run_template_package "$contract" "$deploy_template_package" "$archive" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid template package case to fail: $label"
  fi

  if [[ -n "$expected_stderr" ]] && ! grep -Fq "$expected_stderr" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected template package stderr to contain '$expected_stderr': $label"
  fi

  pass "invalid template package rejected: $label"
}

VALID_ARCHIVE="$TMP_DIR/valid.tgz"
VALID_MANIFEST_SHA="$(create_plain_archive valid "$VALID_ARCHIVE")"
VALID_ARCHIVE_SHA="$(sha256_file "$VALID_ARCHIVE")"
VALID_CONTRACT_MATERIAL="$TMP_DIR/release-contract.material.json"
VALID_PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.material.json"
write_materials "$VALID_MANIFEST_SHA" "$VALID_ARCHIVE_SHA" "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL"

VALID_OUT="$TMP_DIR/out-valid"
run_template_package "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$VALID_ARCHIVE" "$VALID_OUT" >/dev/null
"$NODE_BIN" --input-type=module - "$VALID_OUT/template-package-report.json" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (report.scope !== 'template_package_intake_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('template package report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if ('release_verdict' in report || 'verdict' in report) {
  throw new Error('template package report must not claim a release verdict');
}
NODE
pass "valid template package accepted with focused non-readiness report"

DRIFT_ARCHIVE="$TMP_DIR/archive-drift.tgz"
create_plain_archive archive-drift "$DRIFT_ARCHIVE" notes.txt >/dev/null
expect_fail archive-sha-mismatch "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$DRIFT_ARCHIVE"

ARTIFACT_PROVENANCE_DRIFT_CONTRACT="$TMP_DIR/release-contract.artifact-provenance-drift.json"
ARTIFACT_PROVENANCE_DRIFT_PACKAGE="$TMP_DIR/deploy-template-package.artifact-provenance-drift.json"
mutate_artifact_provenance_sha \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$ARTIFACT_PROVENANCE_DRIFT_CONTRACT" \
  "$ARTIFACT_PROVENANCE_DRIFT_PACKAGE"
expect_fail artifact-provenance-sha-drift "$ARTIFACT_PROVENANCE_DRIFT_CONTRACT" "$ARTIFACT_PROVENANCE_DRIFT_PACKAGE" "$VALID_ARCHIVE"

MANIFEST_DRIFT_CONTRACT="$TMP_DIR/release-contract.manifest-drift.json"
MANIFEST_DRIFT_PACKAGE="$TMP_DIR/deploy-template-package.manifest-drift.json"
mutate_manifest_sha \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$MANIFEST_DRIFT_CONTRACT" \
  "$MANIFEST_DRIFT_PACKAGE"
expect_fail manifest-sha-drift "$MANIFEST_DRIFT_CONTRACT" "$MANIFEST_DRIFT_PACKAGE" "$VALID_ARCHIVE"

DESCRIPTOR_DRIFT_PACKAGE="$TMP_DIR/deploy-template-package.descriptor-drift.json"
mutate_descriptor_only "$VALID_PACKAGE_MATERIAL" "$DESCRIPTOR_DRIFT_PACKAGE"
expect_fail descriptor-mismatch "$VALID_CONTRACT_MATERIAL" "$DESCRIPTOR_DRIFT_PACKAGE" "$VALID_ARCHIVE"

for mutation in \
  missing-release-required-image-ids \
  required-image-ids-mismatch \
  stale-six-image-required-image-ids \
  missing-deploy-package-required-image-ids \
  empty-deploy-package-required-image-ids \
  non-array-deploy-package-required-image-ids \
  required-image-id-missing-in-inventory; do
  REQUIRED_IDS_CONTRACT="$TMP_DIR/release-contract.$mutation.json"
  REQUIRED_IDS_PACKAGE="$TMP_DIR/deploy-template-package.$mutation.json"
  mutate_required_image_ids \
    "$VALID_CONTRACT_MATERIAL" \
    "$VALID_PACKAGE_MATERIAL" \
    "$REQUIRED_IDS_CONTRACT" \
    "$REQUIRED_IDS_PACKAGE" \
    "$mutation"
  expect_fail \
    "$mutation" \
    "$REQUIRED_IDS_CONTRACT" \
    "$REQUIRED_IDS_PACKAGE" \
    "$VALID_ARCHIVE"
done

for mutation in required-current-image-id-absent-from-inventory; do
  REQUIRED_IDS_CONTRACT="$TMP_DIR/release-contract.$mutation.json"
  REQUIRED_IDS_PACKAGE="$TMP_DIR/deploy-template-package.$mutation.json"
  mutate_required_image_ids \
    "$VALID_CONTRACT_MATERIAL" \
    "$VALID_PACKAGE_MATERIAL" \
    "$REQUIRED_IDS_CONTRACT" \
    "$REQUIRED_IDS_PACKAGE" \
    "$mutation"
  expect_fail \
    "$mutation" \
    "$REQUIRED_IDS_CONTRACT" \
    "$REQUIRED_IDS_PACKAGE" \
    "$VALID_ARCHIVE" \
    "release_contract.deploy_image_inventory must match declared image sources"
done

expect_fail missing-archive "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL" "$TMP_DIR/missing.tgz"

TRAVERSAL_ARCHIVE="$TMP_DIR/path-traversal.tgz"
TRAVERSAL_MANIFEST_SHA="$(create_traversal_archive "$TRAVERSAL_ARCHIVE")"
TRAVERSAL_ARCHIVE_SHA="$(sha256_file "$TRAVERSAL_ARCHIVE")"
TRAVERSAL_CONTRACT="$TMP_DIR/release-contract.traversal.json"
TRAVERSAL_PACKAGE="$TMP_DIR/deploy-template-package.traversal.json"
write_materials "$TRAVERSAL_MANIFEST_SHA" "$TRAVERSAL_ARCHIVE_SHA" "$TRAVERSAL_CONTRACT" "$TRAVERSAL_PACKAGE"
expect_fail path-traversal "$TRAVERSAL_CONTRACT" "$TRAVERSAL_PACKAGE" "$TRAVERSAL_ARCHIVE"

ABSOLUTE_ARCHIVE="$TMP_DIR/absolute-path.tgz"
ABSOLUTE_MANIFEST_SHA="$(create_absolute_path_archive "$ABSOLUTE_ARCHIVE")"
ABSOLUTE_ARCHIVE_SHA="$(sha256_file "$ABSOLUTE_ARCHIVE")"
ABSOLUTE_CONTRACT="$TMP_DIR/release-contract.absolute-path.json"
ABSOLUTE_PACKAGE="$TMP_DIR/deploy-template-package.absolute-path.json"
write_materials "$ABSOLUTE_MANIFEST_SHA" "$ABSOLUTE_ARCHIVE_SHA" "$ABSOLUTE_CONTRACT" "$ABSOLUTE_PACKAGE"
expect_fail absolute-path "$ABSOLUTE_CONTRACT" "$ABSOLUTE_PACKAGE" "$ABSOLUTE_ARCHIVE"

SECRET_PAYLOAD_ARCHIVE="$TMP_DIR/secret-payload.tgz"
secret_payload_content="$(
  printf '%s%s%s%s%s\n' \
    'postgres://user:' \
    'password' \
    '@db.example.internal' \
    ':5432/' \
    'appdb'
)"
SECRET_PAYLOAD_MANIFEST_SHA="$(create_plain_archive secret-payload "$SECRET_PAYLOAD_ARCHIVE" secret.txt "$secret_payload_content")"
SECRET_PAYLOAD_ARCHIVE_SHA="$(sha256_file "$SECRET_PAYLOAD_ARCHIVE")"
SECRET_PAYLOAD_CONTRACT="$TMP_DIR/release-contract.secret-payload.json"
SECRET_PAYLOAD_PACKAGE="$TMP_DIR/deploy-template-package.secret-payload.json"
write_materials "$SECRET_PAYLOAD_MANIFEST_SHA" "$SECRET_PAYLOAD_ARCHIVE_SHA" "$SECRET_PAYLOAD_CONTRACT" "$SECRET_PAYLOAD_PACKAGE"
expect_fail secret-payload "$SECRET_PAYLOAD_CONTRACT" "$SECRET_PAYLOAD_PACKAGE" "$SECRET_PAYLOAD_ARCHIVE"

SYMLINK_ARCHIVE="$TMP_DIR/symlink.tgz"
SYMLINK_MANIFEST_SHA="$(create_symlink_archive "$SYMLINK_ARCHIVE")"
SYMLINK_ARCHIVE_SHA="$(sha256_file "$SYMLINK_ARCHIVE")"
SYMLINK_CONTRACT="$TMP_DIR/release-contract.symlink.json"
SYMLINK_PACKAGE="$TMP_DIR/deploy-template-package.symlink.json"
write_materials "$SYMLINK_MANIFEST_SHA" "$SYMLINK_ARCHIVE_SHA" "$SYMLINK_CONTRACT" "$SYMLINK_PACKAGE"
expect_fail symlink "$SYMLINK_CONTRACT" "$SYMLINK_PACKAGE" "$SYMLINK_ARCHIVE"

HARDLINK_ARCHIVE="$TMP_DIR/hardlink.tgz"
HARDLINK_MANIFEST_SHA="$(create_hardlink_archive "$HARDLINK_ARCHIVE")"
HARDLINK_ARCHIVE_SHA="$(sha256_file "$HARDLINK_ARCHIVE")"
HARDLINK_CONTRACT="$TMP_DIR/release-contract.hardlink.json"
HARDLINK_PACKAGE="$TMP_DIR/deploy-template-package.hardlink.json"
write_materials "$HARDLINK_MANIFEST_SHA" "$HARDLINK_ARCHIVE_SHA" "$HARDLINK_CONTRACT" "$HARDLINK_PACKAGE"
expect_fail hardlink "$HARDLINK_CONTRACT" "$HARDLINK_PACKAGE" "$HARDLINK_ARCHIVE"

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "template package diagnostic is not release readiness"
