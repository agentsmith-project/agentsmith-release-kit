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

  write_online_install_operator_inputs "$package_dir" apply "" /ok
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

  write_airgap_install_operator_inputs "$package_dir" apply "" /ok
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

function canonicalSmokeResults() {
  const specs = [
    { id: 'login_profile', source_flow: 'login_profile', label: 'login/profile' },
    { id: 'workspace_project', source_flow: 'workspace_project', label: 'workspace/project' },
    { id: 'provider_neutral_endpoint', source_flow: 'chat_via_llmup', label: 'provider-neutral Endpoint' },
    { id: 'agent_task_managed_runner', source_flow: 'agent_task_managed_runner', label: 'Agent task managed runner' },
    { id: 'files', source_flow: 'files', label: 'Files' },
    { id: 'audit', source_flow: 'audit', label: 'audit' },
    { id: 'usage', source_flow: 'usage', label: 'usage' }
  ];
  return Object.fromEntries(specs.map((spec) => [
    spec.id,
    {
      id: spec.id,
      status: 'passed',
      label: spec.label,
      source_flow: spec.source_flow,
      source_evidence_path: `unified-deploy/product-flows/${spec.source_flow}.json`,
      source_evidence_sha256: digest(`product-smoke:${spec.source_flow}`)
    }
  ]));
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
  schema_version: 'agentsmith.post-deploy-product-smoke-report/v1',
  producer: 'agentsmith-post-deploy-product-smoke',
  owner: 'agentsmith',
  repo: 'github.com/agentsmith-project/agentsmith',
  release_contract: {
    path: 'release-contract.json',
    input_sha256: releaseContractDigest,
    release_id: contract.release_id,
    git_sha: contract.git_sha
  },
  status: 'passed',
  generated_at: '2026-05-31T12:00:00.000Z',
  source: {
    product_flows_path: 'unified-deploy/product-flows/product-flows-aggregate.json',
    product_flows_sha256: digest('post-deploy-product-smoke:product-flows'),
    aggregate_schema_version: 'agentsmith.unified-deploy.product-flows.aggregate/v1',
    aggregate_producer: 'unified-deploy-product-flows',
    aggregate_generated_at: '2026-05-31T12:00:00.000Z',
    aggregate_command: 'focused fixture'
  },
  smoke_results: canonicalSmokeResults(),
  failures: [],
  paths: {
    report_path: 'post-deploy-product-smoke/post-deploy-product-smoke-report.json'
  }
});
NODE
}

assert_ga_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const digest = (label) => `sha256:${crypto.createHash('sha256').update(label).digest('hex')}`;
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
const expectedSmokeIds = [
  'login_profile',
  'workspace_project',
  'provider_neutral_endpoint',
  'agent_task_managed_runner',
  'files',
  'audit',
  'usage'
];
if (report.post_deploy_product_smoke?.schema !== 'agentsmith.post-deploy-product-smoke-report/v1') {
  throw new Error('GA report must bind canonical product smoke schema');
}
if (report.post_deploy_product_smoke?.producer !== 'agentsmith-post-deploy-product-smoke') {
  throw new Error('GA report must bind canonical product smoke producer');
}
if (report.post_deploy_product_smoke?.release_contract?.input_sha256 !== report.release?.release_contract_digest) {
  throw new Error('GA report must keep product smoke release contract digest binding');
}
if (report.post_deploy_product_smoke?.release_contract?.release_id !== report.release?.release_id) {
  throw new Error('GA report must keep product smoke release id binding');
}
if (report.post_deploy_product_smoke?.release_contract?.git_sha !== report.release?.git_sha) {
  throw new Error('GA report must keep product smoke git sha binding');
}
if (report.post_deploy_product_smoke?.release_contract?.path !== 'release-contract.json') {
  throw new Error('GA report must keep product smoke release contract path');
}
if (JSON.stringify(report.post_deploy_product_smoke?.canonical_smoke_ids) !== JSON.stringify(expectedSmokeIds)) {
  throw new Error('GA report must bind canonical product smoke ids');
}
if (report.post_deploy_product_smoke?.source?.product_flows_path !== 'unified-deploy/product-flows/product-flows-aggregate.json') {
  throw new Error('GA report must bind product smoke aggregate path');
}
if (report.post_deploy_product_smoke?.source?.product_flows_sha256 !== digest('post-deploy-product-smoke:product-flows')) {
  throw new Error('GA report must bind product smoke aggregate digest');
}
const expectedSmokeDigests = Object.fromEntries([
  ['login_profile', 'login_profile'],
  ['workspace_project', 'workspace_project'],
  ['provider_neutral_endpoint', 'chat_via_llmup'],
  ['agent_task_managed_runner', 'agent_task_managed_runner'],
  ['files', 'files'],
  ['audit', 'audit'],
  ['usage', 'usage']
].map(([id, sourceFlow]) => [id, digest(`product-smoke:${sourceFlow}`)]));
for (const id of expectedSmokeIds) {
  if (report.post_deploy_product_smoke?.source_evidence_sha256?.[id] !== expectedSmokeDigests[id]) {
    throw new Error(`GA report must bind product smoke source evidence digest: ${id}`);
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

if ! bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
  --operator-inputs "$online_package" \
  --operator-inputs "$online_install_package" \
  --operator-inputs "$airgap_package" \
  --operator-inputs "$airgap_install_package" \
  --product-readiness-report "$product_dir/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
  --output-dir "$ga_output_dir" >"$TMP_DIR/ga-release.out" 2>"$TMP_DIR/ga-release.err"; then
  cat "$TMP_DIR/ga-release.out" >&2
  cat "$TMP_DIR/ga-release.err" >&2
  fail "package-driven operator GA facade failed"
fi

grep -Fq "$ga_output_dir/ga-release-report.json" "$TMP_DIR/ga-release.out" ||
  fail "operator GA facade did not print final ga-release-report.json location"
if grep -Fq '.release-kit-internal' "$TMP_DIR/ga-release.out"; then
  cat "$TMP_DIR/ga-release.out" >&2
  fail "operator GA facade success output exposed internal path evidence"
fi
assert_ga_report "$ga_output_dir/ga-release-report.json"

seed_stale_ga_outputs() {
  local output_dir="$1"

  mkdir -p "$output_dir"
  cp "$ga_output_dir/ga-release-report.json" "$output_dir/ga-release-report.json"
  cp "$ga_output_dir/ga-release-summary.md" "$output_dir/ga-release-summary.md"
}

missing_package_output="$TMP_DIR/ga-output-missing-package"
seed_stale_ga_outputs "$missing_package_output"
if bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
  --operator-inputs "$online_package" \
  --operator-inputs "$online_install_package" \
  --operator-inputs "$airgap_package" \
  --product-readiness-report "$product_dir/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
  --output-dir "$missing_package_output" >"$TMP_DIR/ga-missing-package.out" 2>&1; then
  fail "operator GA facade should fail when a package is missing"
fi
grep -Fq 'requires exactly 4 --operator-inputs packages' "$TMP_DIR/ga-missing-package.out" ||
  fail "missing package failure did not explain required package count"
if [[ -e "$missing_package_output/ga-release-report.json" || -e "$missing_package_output/ga-release-summary.md" ]]; then
  fail "operator GA facade missing package failure must remove stale final GA outputs"
fi

duplicate_path_output="$TMP_DIR/ga-output-duplicate-path"
seed_stale_ga_outputs "$duplicate_path_output"
if bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
  --operator-inputs "$online_package" \
  --operator-inputs "$online_package" \
  --operator-inputs "$airgap_package" \
  --operator-inputs "$airgap_install_package" \
  --product-readiness-report "$product_dir/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
  --output-dir "$duplicate_path_output" >"$TMP_DIR/ga-duplicate-path.out" 2>&1; then
  fail "operator GA facade should fail on duplicate deployment_path packages"
fi
grep -Fq 'duplicate deployment_path online/use_existing' "$TMP_DIR/ga-duplicate-path.out" ||
  fail "duplicate deployment_path failure did not explain duplicate package"
if [[ -e "$duplicate_path_output/ga-release-report.json" || -e "$duplicate_path_output/ga-release-summary.md" ]]; then
  fail "operator GA facade duplicate path failure must remove stale final GA outputs"
fi

missing_report_package="$TMP_DIR/pkg-online-use-existing-missing-report"
cp -R "$online_package" "$missing_report_package"
rm "$missing_report_package/.release-kit-internal/online-use-existing/deployment-path/deployment-path-report.json"
missing_path_output="$TMP_DIR/ga-output-missing-path-report"
seed_stale_ga_outputs "$missing_path_output"
if bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
  --operator-inputs "$missing_report_package" \
  --operator-inputs "$online_install_package" \
  --operator-inputs "$airgap_package" \
  --operator-inputs "$airgap_install_package" \
  --product-readiness-report "$product_dir/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
  --output-dir "$missing_path_output" >"$TMP_DIR/ga-missing-path-report.out" 2>&1; then
  fail "operator GA facade should fail when finalized path report is missing"
fi
grep -Fq 'finalized path evidence is missing for online/use_existing' "$TMP_DIR/ga-missing-path-report.out" ||
  fail "missing path report failure did not name the affected deployment path"
grep -Fq 'bash scripts/operator-release.sh --operator-inputs' "$TMP_DIR/ga-missing-path-report.out" ||
  fail "missing path report failure did not point operator to rerun the package"
if [[ -e "$missing_path_output/ga-release-report.json" || -e "$missing_path_output/ga-release-summary.md" ]]; then
  fail "operator GA facade missing path evidence failure must remove stale final GA outputs"
fi

if bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
  --deployment-path-report "$online_package/.release-kit-internal/online-use-existing/deployment-path/deployment-path-report.json" \
  --operator-inputs "$online_package" \
  --operator-inputs "$online_install_package" \
  --operator-inputs "$airgap_package" \
  --operator-inputs "$airgap_install_package" \
  --product-readiness-report "$product_dir/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
  --output-dir "$TMP_DIR/ga-output-internal-report-arg" >"$TMP_DIR/ga-internal-report-arg.out" 2>&1; then
  fail "operator GA facade should reject internal deployment-path-report arguments"
fi
grep -Fq 'does not accept --deployment-path-report' "$TMP_DIR/ga-internal-report-arg.out" ||
  fail "internal deployment-path-report rejection did not explain operator package surface"

pass "package-driven GA smoke consumed four operator-inputs packages and issued final GA report"
