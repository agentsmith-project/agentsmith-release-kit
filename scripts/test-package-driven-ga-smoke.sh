#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGENTSMITH_OPERATOR_INPUTS_ORCHESTRATION_LIB_ONLY=1
# Reuse the package builders and fake runtime probes from the orchestration test.
source "$ROOT_DIR/scripts/test-operator-inputs-orchestration.sh"
unset AGENTSMITH_OPERATOR_INPUTS_ORCHESTRATION_LIB_ONLY

prepare_common_release_materials() {
  local materials_dir="$1"

  mkdir -p "$materials_dir"
  local archive="$materials_dir/deploy-template-package.tgz"
  local manifest_sha
  manifest_sha="$(create_archive package-driven-ga "$archive")"
  local archive_sha
  archive_sha="$(sha256_file "$archive")"

  write_materials "$manifest_sha" "$archive_sha" \
    "$materials_dir/release-contract.json" \
    "$materials_dir/deploy-template-package.json"
}

copy_common_release_materials() {
  local materials_dir="$1"
  local package_dir="$2"

  cp "$materials_dir/release-contract.json" "$package_dir/release-contract.json"
  cp "$materials_dir/deploy-template-package.json" "$package_dir/deploy-template-package.json"
  cp "$materials_dir/deploy-template-package.tgz" "$package_dir/deploy-template-package.tgz"
}

prepare_package_online_use_existing() {
  local package_dir="$1"
  local materials_dir="$2"

  mkdir -p "$package_dir/tools"
  copy_common_release_materials "$materials_dir" "$package_dir"
  write_render_values "$package_dir/render-values.json"
  write_truth "$package_dir/substrate-truth.json" "$TARGET_PROFILE"
  write_prerequisites "$package_dir/target-prerequisites.json" "$TARGET_PROFILE"
  write_fake_kubectl "$package_dir/tools/kubectl"
  write_online_operator_inputs "$package_dir" apply /ok
}

prepare_package_online_install_substrates() {
  local package_dir="$1"
  local materials_dir="$2"

  mkdir -p "$package_dir/tools"
  copy_common_release_materials "$materials_dir" "$package_dir"
  write_render_values "$package_dir/render-values.json"
  write_truth "$package_dir/substrate-truth.json" "$KIT_ONLINE_TARGET_PROFILE"
  write_prerequisites "$package_dir/target-prerequisites.json" "$KIT_ONLINE_TARGET_PROFILE"
  write_substrate_install_materials "$package_dir" "$KIT_ONLINE_TARGET_PROFILE"
  write_fake_kubectl "$package_dir/tools/kubectl"
  write_fake_routability_probe "$package_dir/tools/routability-probe"

  local install_parameters_sha256
  install_parameters_sha256="$(install_parameters_digest "$package_dir/substrate-install-inputs.json" agentsmith)"
  write_online_install_operator_inputs "$package_dir" apply "$install_parameters_sha256" /ok
}

prepare_package_airgap_use_existing() {
  local package_dir="$1"
  local materials_dir="$2"

  mkdir -p "$package_dir/tools" "$package_dir/bundle"
  copy_common_release_materials "$materials_dir" "$package_dir"
  create_airgap_payloads "$package_dir"
  create_airgap_image_archives "$package_dir" "$package_dir/release-contract.json"
  write_airgap_operator_prerequisites "$package_dir" "$package_dir/operator-prerequisites.json"
  run_airgap_bundle_create \
    "$package_dir" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json" \
    "$package_dir/deploy-template-package.tgz" \
    "$package_dir/bundle" \
    "$package_dir/bundle-create-output" >"$package_dir/bundle-create.out"
  write_bundle_operator_inputs "$package_dir/bundle"
  write_fake_airgap_kubectl "$package_dir/tools/kubectl"
  write_fake_airgap_archive_probe "$package_dir/tools/archive-probe"
  write_fake_airgap_image_loader "$package_dir/tools/image-loader"
  write_airgap_operator_inputs "$package_dir" apply /ok
}

prepare_package_airgap_install_substrates() {
  local package_dir="$1"
  local materials_dir="$2"

  mkdir -p "$package_dir/tools" "$package_dir/bundle"
  copy_common_release_materials "$materials_dir" "$package_dir"
  create_airgap_payloads "$package_dir"
  create_airgap_image_archives "$package_dir" "$package_dir/release-contract.json"
  write_airgap_operator_prerequisites "$package_dir" "$package_dir/operator-prerequisites.json"
  write_substrate_install_materials "$package_dir" "$KIT_AIRGAP_PROFILE"
  run_airgap_bundle_create \
    "$package_dir" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json" \
    "$package_dir/deploy-template-package.tgz" \
    "$package_dir/bundle" \
    "$package_dir/bundle-create-output" \
    "$KIT_AIRGAP_PROFILE" \
    "$package_dir/substrate-pack-manifest.json" >"$package_dir/bundle-create.out"
  write_bundle_operator_inputs "$package_dir/bundle" "$KIT_AIRGAP_PROFILE"
  cp "$package_dir/substrate-install-inputs.json" \
    "$package_dir/bundle/operator-inputs/substrate-install-inputs.json"
  write_fake_airgap_kubectl "$package_dir/tools/kubectl"
  write_fake_airgap_archive_probe "$package_dir/tools/archive-probe"
  write_fake_airgap_image_loader "$package_dir/tools/image-loader"

  local install_parameters_sha256
  install_parameters_sha256="$(
    install_parameters_digest "$package_dir/bundle/operator-inputs/substrate-install-inputs.json" agentsmith
  )"
  write_airgap_install_operator_inputs "$package_dir" apply "$install_parameters_sha256" /ok
}

assert_no_formal_ga_verdict_outputs() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [packageRoot] = process.argv.slice(2);

function fail(message) {
  throw new Error(message);
}

function walk(value, label) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => walk(item, `${label}[${index}]`));
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    if (key === 'formal_verdict') {
      fail(`${label}.${key} must not be written by package-driven operator-inputs runs`);
    }
    walk(child, `${label}.${key}`);
  }
}

function scanDir(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const absolutePath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      scanDir(absolutePath);
      continue;
    }
    if (!entry.isFile()) {
      continue;
    }
    if (entry.name === 'ga-release-report.json') {
      fail('package-driven operator-inputs run must not write ga-release-report.json');
    }
    if (!entry.name.endsWith('.json')) {
      continue;
    }
    const relative = path.relative(packageRoot, absolutePath).split(path.sep).join('/');
    walk(JSON.parse(fs.readFileSync(absolutePath, 'utf8')), relative);
  }
}

scanDir(packageRoot);
NODE
}

write_product_reports() {
  local release_contract="$1"
  local output_dir="$2"

  "$NODE_BIN" --input-type=module - "$release_contract" "$output_dir" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [releaseContractFile, outputDir] = process.argv.slice(2);
const contractBytes = fs.readFileSync(releaseContractFile);
const contract = JSON.parse(contractBytes.toString('utf8'));
const releaseContractDigest = `sha256:${crypto.createHash('sha256').update(contractBytes).digest('hex')}`;
const digest = (label) => `sha256:${crypto.createHash('sha256').update(label).digest('hex')}`;

function provenance(subjectName) {
  return {
    schema_version: 'agentsmith.artifact-provenance/v1',
    provenance_kind: 'ci_artifact',
    producer_repo: 'github.com/agentsmith-project/agentsmith',
    normalized_remote: 'github.com/agentsmith-project/agentsmith',
    commit_sha: contract.git_sha,
    subject_name: subjectName,
    subject_sha256: digest(`package-driven-ga-smoke:${subjectName}:subject`),
    artifact_sha256: digest(`package-driven-ga-smoke:${subjectName}:artifact`),
    artifact_uri: `gh-artifact://agentsmith/package-driven-ga-smoke/${subjectName}.json`,
    run_id: 'package-driven-ga-smoke-1001',
    run_attempt: '1',
    generated_at: '2026-05-31T12:00:00.000Z'
  };
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

writeJson(path.join(outputDir, 'product-readiness-report.json'), {
  schema: 'agentsmith.product-readiness-report/v1',
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: releaseContractDigest,
  artifact_provenance: provenance('product-readiness-report')
});

writeJson(path.join(outputDir, 'post-deploy-product-smoke-report.json'), {
  schema: 'agentsmith.post-deploy-product-smoke/v1',
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: releaseContractDigest,
  artifact_provenance: provenance('post-deploy-product-smoke-report'),
  covered_flows: [
    'auth_profile',
    'workspace_project',
    'files',
    'managed_runner_agent_task',
    'provider_neutral_endpoint',
    'audit_usage_readback'
  ]
});
NODE
}

assert_ga_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const expectedPaths = new Set([
  'online/use_existing',
  'online/install_substrates',
  'airgap/use_existing',
  'airgap/install_substrates'
]);

if (report.schema !== 'agentsmith.ga-release-report/v1') {
  throw new Error(`unexpected GA report schema: ${report.schema}`);
}
if (report.status !== 'pass') {
  throw new Error(`unexpected GA report status: ${report.status}`);
}
if (report.formal_verdict !== 'issued') {
  throw new Error(`unexpected GA formal_verdict: ${report.formal_verdict}`);
}
const actualPaths = new Set((report.deployment_paths || []).map((entry) => entry.operator_path));
if (actualPaths.size !== expectedPaths.size) {
  throw new Error('GA report must include exactly four deployment paths');
}
for (const expected of expectedPaths) {
  if (!actualPaths.has(expected)) {
    throw new Error(`GA report missing deployment path: ${expected}`);
  }
}
NODE
}

run_online_package() {
  local package_dir="$1"
  local label="$2"

  if ! run_operator_inputs "$package_dir" "$label" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "package-driven run failed: $label"
  fi
}

run_airgap_package() {
  local package_dir="$1"
  local label="$2"

  if ! run_airgap_operator_inputs "$package_dir" "$label" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "package-driven airgap run failed: $label"
  fi
}

start_server

materials_dir="$TMP_DIR/common-release-materials"
product_dir="$TMP_DIR/product-reports"
ga_output_dir="$TMP_DIR/ga-output"
online_package="$TMP_DIR/pkg-online-use-existing"
online_install_package="$TMP_DIR/pkg-online-install-substrates"
airgap_package="$TMP_DIR/pkg-airgap-use-existing"
airgap_install_package="$TMP_DIR/pkg-airgap-install-substrates"

prepare_common_release_materials "$materials_dir"
prepare_package_online_use_existing "$online_package" "$materials_dir"
prepare_package_online_install_substrates "$online_install_package" "$materials_dir"
prepare_package_airgap_use_existing "$airgap_package" "$materials_dir"
prepare_package_airgap_install_substrates "$airgap_install_package" "$materials_dir"

run_online_package "$online_package" package-online-use-existing
assert_path_evidence "$online_package"
assert_no_formal_ga_verdict_outputs "$online_package"

run_online_package "$online_install_package" package-online-install-substrates
assert_install_path_evidence "$online_install_package"
assert_no_formal_ga_verdict_outputs "$online_install_package"

run_airgap_package "$airgap_package" package-airgap-use-existing
assert_airgap_path_evidence "$airgap_package"
assert_no_formal_ga_verdict_outputs "$airgap_package"

run_airgap_package "$airgap_install_package" package-airgap-install-substrates
assert_airgap_install_path_evidence "$airgap_install_package"
assert_no_formal_ga_verdict_outputs "$airgap_install_package"

write_product_reports "$materials_dir/release-contract.json" "$product_dir"

if ! bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
  --release-contract "$materials_dir/release-contract.json" \
  --deploy-template-package "$materials_dir/deploy-template-package.json" \
  --deployment-path-report "$online_package/.release-kit-internal/online-use-existing/deployment-path/deployment-path-report.json" \
  --deployment-path-report "$online_install_package/.release-kit-internal/online-install-substrates/deployment-path/deployment-path-report.json" \
  --deployment-path-report "$airgap_package/.release-kit-internal/airgap-use-existing/deployment-path/deployment-path-report.json" \
  --deployment-path-report "$airgap_install_package/.release-kit-internal/airgap-install-substrates/deployment-path/deployment-path-report.json" \
  --product-readiness-report "$product_dir/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
  --output-dir "$ga_output_dir" >"$TMP_DIR/ga-release.out" 2>"$TMP_DIR/ga-release.err"; then
  cat "$TMP_DIR/ga-release.out" >&2
  cat "$TMP_DIR/ga-release.err" >&2
  fail "package-driven GA aggregate failed"
fi

assert_ga_report "$ga_output_dir/ga-release-report.json"
pass "package-driven GA smoke consumed four finalized path reports and issued final GA report"
