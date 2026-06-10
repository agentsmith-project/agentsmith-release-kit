#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
EXPORT_SCRIPT="$ROOT_DIR/scripts/export-airgap-image-archives.mjs"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_HELPER="$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_contract() {
  local output="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - \
    "$FIXTURE_CONTRACT" \
    "$output" \
    "$FIXTURE_HELPER" \
    "$mutation" <<'NODE'
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const [fixtureContract, output, fixtureHelper, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(fixtureContract, 'utf8'));

function digest(char) {
  return `sha256:${char.repeat(64)}`;
}

function fixtureDigest(imageId) {
  const result = spawnSync(
    process.execPath,
    [fixtureHelper, '--print-target-digest', '--image-id', imageId],
    { encoding: 'utf8' }
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(result.stderr || `fixture digest failed for ${imageId}`);
  }
  return result.stdout.trim();
}

function replaceImageDigest(image, nextDigest) {
  return image.replace(/@sha256:[0-9a-f]{64}$/i, `@${nextDigest}`);
}

for (const item of contract.deploy_image_inventory || []) {
  const nextDigest = fixtureDigest(item.id);
  item.digest = nextDigest;
  item.image = replaceImageDigest(item.image, nextDigest);
}

switch (mutation) {
  case 'valid':
    break;
  case 'descriptor_mismatch':
    contract.deploy_image_inventory[0].digest = digest('b');
    contract.deploy_image_inventory[0].image = replaceImageDigest(
      contract.deploy_image_inventory[0].image,
      digest('b')
    );
    break;
  case 'unsafe_id':
    contract.deploy_image_inventory[0].id = '../bad';
    break;
  case 'missing_inventory':
    delete contract.deploy_image_inventory;
    break;
  case 'image_digest_mismatch':
    contract.deploy_image_inventory[0].image = replaceImageDigest(
      contract.deploy_image_inventory[0].image,
      digest('c')
    );
    break;
  case 'uppercase_digest':
    contract.deploy_image_inventory[0].digest = `sha256:${'A'.repeat(64)}`;
    contract.deploy_image_inventory[0].image = replaceImageDigest(
      contract.deploy_image_inventory[0].image,
      `sha256:${'A'.repeat(64)}`
    );
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

write_fake_skopeo() {
  local output="$1"

  cat >"$output" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "skopeo version 1.99.0-fake"
  exit 0
fi

: "${FAKE_SKOPEO_LOG:?}"
: "${FAKE_OCI_FIXTURE:?}"
NODE_BIN="${NODE_BIN:-node}"

if [[ "$#" -ne 5 || "${1:-}" != "copy" || "${2:-}" != "--all" || "${3:-}" != "--preserve-digests" ]]; then
  printf '%s\n' "fake skopeo expected: copy --all --preserve-digests <source> <destination>" >&2
  exit 64
fi

source_ref="$4"
destination_ref="$5"
if [[ "$source_ref" != docker://*@sha256:* ]]; then
  printf '%s\n' "fake skopeo expected digest-only docker source" >&2
  exit 65
fi

repo_and_digest="${source_ref#docker://}"
repository="${repo_and_digest%@sha256:*}"
digest="sha256:${repo_and_digest##*@sha256:}"
last_component="${repository##*/}"
if [[ "$last_component" == *:* ]]; then
  printf '%s\n' "fake skopeo rejected tag-bearing source ref" >&2
  exit 66
fi
if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf '%s\n' "fake skopeo expected lowercase sha256 digest" >&2
  exit 67
fi
if [[ "$destination_ref" != oci-archive:*:* ]]; then
  printf '%s\n' "fake skopeo expected oci-archive destination" >&2
  exit 68
fi

destination="${destination_ref#oci-archive:}"
archive_path="${destination%:*}"
image_id="${destination##*:}"

printf '%s\n' "$source_ref $destination_ref" >>"$FAKE_SKOPEO_LOG"
"$NODE_BIN" "$FAKE_OCI_FIXTURE" \
  --archive "$archive_path" \
  --image-id "$image_id" \
  --target-digest "$digest"
SH
  chmod +x "$output"
}

run_export() {
  local contract="$1"
  local output_dir="$2"
  local fake_skopeo="$3"
  local fake_log="$4"

  FAKE_SKOPEO_LOG="$fake_log" \
  FAKE_OCI_FIXTURE="$FIXTURE_HELPER" \
  NODE_BIN="$NODE_BIN" \
    "$NODE_BIN" "$EXPORT_SCRIPT" \
      --release-contract "$contract" \
      --output-dir "$output_dir" \
      --skopeo "$fake_skopeo"
}

expect_fail() {
  local label="$1"
  local contract="$2"
  local output_dir="$3"
  local fake_skopeo="$4"
  local fake_log="$5"
  local pattern="$6"

  if run_export "$contract" "$output_dir" "$fake_skopeo" "$fake_log" \
    >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    fail "expected export to fail: $label"
  fi
  if ! grep -E "$pattern" "$TMP_DIR/$label.err" >/dev/null; then
    echo "--- stdout ---" >&2
    cat "$TMP_DIR/$label.out" >&2
    echo "--- stderr ---" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected failure pattern for $label: $pattern"
  fi
  pass "export rejected $label"
}

assert_success_receipt() {
  local contract="$1"
  local output_dir="$2"
  local fake_log="$3"

  "$NODE_BIN" --input-type=module - "$contract" "$output_dir" "$fake_log" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractPath, outputDir, fakeLog] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractPath, 'utf8'));
const receipt = JSON.parse(
  fs.readFileSync(path.join(outputDir, 'airgap-image-archive-export.json'), 'utf8')
);
const outputDirMode = fs.statSync(outputDir).mode & 0o777;
if (outputDirMode !== 0o700) {
  throw new Error(`output dir mode must be 0700, got ${outputDirMode.toString(8)}`);
}
const tempEntries = fs.readdirSync(outputDir).filter(
  (entry) => entry.includes('airgap-image-archive-export') && entry.endsWith('.tmp')
);
if (tempEntries.length !== 0) {
  throw new Error(`receipt temp files must not remain: ${tempEntries.join(', ')}`);
}
const forbidden = ['readiness', 'status', 'final', 'formal_verdict'];
for (const field of forbidden) {
  if (Object.prototype.hasOwnProperty.call(receipt, field)) {
    throw new Error(`receipt must not include ${field}`);
  }
}
if (receipt.schema_version !== 'agentsmith.airgap-image-archive-export/v1') {
  throw new Error('receipt schema_version mismatch');
}
if (receipt.release_id !== contract.release_id || receipt.git_sha !== contract.git_sha) {
  throw new Error('receipt release identity mismatch');
}
if (receipt.skopeo_version !== 'skopeo version 1.99.0-fake') {
  throw new Error('receipt skopeo_version mismatch');
}
if (!Array.isArray(receipt.images) || receipt.images.length !== contract.deploy_image_inventory.length) {
  throw new Error('receipt image count mismatch');
}

const logLines = fs.readFileSync(fakeLog, 'utf8').trim().split('\n').filter(Boolean);
if (logLines.length !== receipt.images.length) {
  throw new Error('fake skopeo call count mismatch');
}

for (const image of receipt.images) {
  const inventoryItem = contract.deploy_image_inventory.find((item) => item.id === image.id);
  if (!inventoryItem) {
    throw new Error(`unexpected image id in receipt: ${image.id}`);
  }
  if (image.expected_digest !== inventoryItem.digest || image.descriptor_digest !== inventoryItem.digest) {
    throw new Error(`digest mismatch for ${image.id}`);
  }
  if (!image.source_ref.startsWith('docker://') || !image.source_ref.endsWith(`@${image.expected_digest}`)) {
    throw new Error(`source_ref must be digest-only for ${image.id}`);
  }
  const repository = image.source_ref.slice('docker://'.length).split('@')[0];
  const lastComponent = repository.slice(repository.lastIndexOf('/') + 1);
  if (lastComponent.includes(':')) {
    throw new Error(`source_ref must not carry tag for ${image.id}`);
  }
  if (!fs.existsSync(image.archive_path)) {
    throw new Error(`archive missing for ${image.id}`);
  }
  if (!/^sha256:[0-9a-f]{64}$/.test(image.archive_sha256)) {
    throw new Error(`archive_sha256 invalid for ${image.id}`);
  }
  const expectedArgs = [
    'copy',
    '--all',
    '--preserve-digests',
    image.source_ref,
    `oci-archive:${image.archive_path}:${image.id}`
  ];
  if (JSON.stringify(image.command_args) !== JSON.stringify(expectedArgs)) {
    throw new Error(`command_args mismatch for ${image.id}`);
  }
}
NODE
}

"$NODE_BIN" "$EXPORT_SCRIPT" --help | grep -q 'Maintainer-only helper' ||
  fail "help output should describe maintainer-only usage"
"$NODE_BIN" "$EXPORT_SCRIPT" --help | grep -q 'registry access and local skopeo' ||
  fail "help output should describe skopeo and output-dir requirements"
pass "help output is available"

fake_skopeo="$TMP_DIR/fake-skopeo"
write_fake_skopeo "$fake_skopeo"

valid_contract="$TMP_DIR/release-contract.valid.json"
valid_output="$TMP_DIR/export-valid"
valid_log="$TMP_DIR/export-valid.log"
write_contract "$valid_contract" valid

missing_skopeo_output="$TMP_DIR/export-missing-skopeo"
if run_export "$valid_contract" "$missing_skopeo_output" "$TMP_DIR/missing-skopeo" "$TMP_DIR/export-missing-skopeo.log" \
  >"$TMP_DIR/missing-skopeo.out" 2>"$TMP_DIR/missing-skopeo.err"; then
  fail "expected export to fail when skopeo is missing"
fi
grep -F 'skopeo not found; install skopeo or pass --skopeo <path>' "$TMP_DIR/missing-skopeo.err" >/dev/null ||
  fail "missing skopeo failure should explain maintainer action"
[[ ! -e "$missing_skopeo_output" ]] ||
  fail "missing skopeo failure must not create output dir"
pass "missing skopeo fails clearly without creating output dir"

run_export "$valid_contract" "$valid_output" "$fake_skopeo" "$valid_log" \
  >"$TMP_DIR/export-valid.out"
assert_success_receipt "$valid_contract" "$valid_output" "$valid_log"
pass "export writes digest-bound OCI archives and receipt"

preexisting_output="$TMP_DIR/export-preexisting"
mkdir -p "$preexisting_output"
expect_fail \
  pre-existing-output \
  "$valid_contract" \
  "$preexisting_output" \
  "$fake_skopeo" \
  "$TMP_DIR/export-preexisting.log" \
  'output dir must not already exist'

mismatch_contract="$TMP_DIR/release-contract.descriptor-mismatch.json"
write_contract "$mismatch_contract" descriptor_mismatch
expect_fail \
  descriptor-mismatch \
  "$mismatch_contract" \
  "$TMP_DIR/export-descriptor-mismatch" \
  "$fake_skopeo" \
  "$TMP_DIR/export-descriptor-mismatch.log" \
  'archive descriptor digest .* must match expected digest'

unsafe_contract="$TMP_DIR/release-contract.unsafe-id.json"
write_contract "$unsafe_contract" unsafe_id
expect_fail \
  unsafe-id \
  "$unsafe_contract" \
  "$TMP_DIR/export-unsafe-id" \
  "$fake_skopeo" \
  "$TMP_DIR/export-unsafe-id.log" \
  'safe file name segment'

missing_contract="$TMP_DIR/release-contract.missing-inventory.json"
write_contract "$missing_contract" missing_inventory
expect_fail \
  missing-inventory \
  "$missing_contract" \
  "$TMP_DIR/export-missing-inventory" \
  "$fake_skopeo" \
  "$TMP_DIR/export-missing-inventory.log" \
  'deploy_image_inventory must be an array'

mismatch_ref_contract="$TMP_DIR/release-contract.image-digest-mismatch.json"
write_contract "$mismatch_ref_contract" image_digest_mismatch
expect_fail \
  image-digest-mismatch \
  "$mismatch_ref_contract" \
  "$TMP_DIR/export-image-digest-mismatch" \
  "$fake_skopeo" \
  "$TMP_DIR/export-image-digest-mismatch.log" \
  'image digest must match'

uppercase_contract="$TMP_DIR/release-contract.uppercase-digest.json"
write_contract "$uppercase_contract" uppercase_digest
expect_fail \
  uppercase-digest \
  "$uppercase_contract" \
  "$TMP_DIR/export-uppercase-digest" \
  "$fake_skopeo" \
  "$TMP_DIR/export-uppercase-digest.log" \
  'sha256 digest'

echo "PASS: airgap image archive export helper tests passed"
