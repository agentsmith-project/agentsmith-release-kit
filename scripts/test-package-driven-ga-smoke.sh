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

assert_ga_failure_report() {
  local output_dir="$1"
  local expected_message="$2"

  "$NODE_BIN" --input-type=module - \
    "$output_dir/ga-release-report.json" \
    "$output_dir/ga-release-summary.md" \
    "$output_dir/ga-evidence-index.json" \
    "$expected_message" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile, summaryFile, evidenceIndexFile, expectedMessage] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const summary = fs.readFileSync(summaryFile, 'utf8');
const evidenceIndex = JSON.parse(fs.readFileSync(evidenceIndexFile, 'utf8'));

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

function canonicalDigest(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

if (report.schema !== 'agentsmith.ga-release-report/v1') {
  throw new Error(`unexpected failure report schema: ${report.schema}`);
}
if (report.status !== 'fail' || report.formal_verdict !== 'not_issued') {
  throw new Error(`failure report must be non-verdict fail; got ${report.status}/${report.formal_verdict}`);
}
if (!Array.isArray(report.blockers) || report.blockers.length === 0) {
  throw new Error('failure report must include blockers');
}
if (!report.blockers.some((entry) => String(entry.message || '').includes(expectedMessage))) {
  throw new Error(`failure report blockers did not include: ${expectedMessage}`);
}
if (!summary.includes('Formal verdict: not_issued') || !summary.includes(expectedMessage)) {
  throw new Error('failure summary must include not_issued verdict and blocker message');
}
if (evidenceIndex.schema !== 'agentsmith.ga-evidence-index/v1') {
  throw new Error(`unexpected evidence index schema: ${evidenceIndex.schema}`);
}
if (
  evidenceIndex.source_report?.path !== 'ga-release-report.json' ||
  evidenceIndex.source_report?.digest !== canonicalDigest(report) ||
  evidenceIndex.source_report?.status !== report.status ||
  evidenceIndex.source_report?.formal_verdict !== report.formal_verdict
) {
  throw new Error('evidence index must bind the failure GA report');
}
if (!Array.isArray(evidenceIndex.blockers) || !evidenceIndex.blockers.some((entry) => String(entry.message || '').includes(expectedMessage))) {
  throw new Error('evidence index must carry the failure blockers from the source report');
}
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
    run_id: '10001',
    run_attempt: '1',
    run_url: 'https://github.com/agentsmith-project/agentsmith/actions/runs/10001/attempts/1',
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
  deployment_target: {
    profile: 'existing_kubernetes/external_declared/online',
    public_base_url: 'https://agentsmith.example.com',
    api_base_url: 'https://agentsmith.example.com/api/v1',
    site_env: {
      path: 'unified-deploy/site.env',
      sha256: digest('post-deploy-product-smoke:site-env')
    },
    substrate_truth: {
      path: 'unified-deploy/substrate-truth.json',
      sha256: digest('post-deploy-product-smoke:substrate-truth')
    }
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
  shift

  "$NODE_BIN" --input-type=module - "$report_file" "$@" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [reportFile, ...packageDirs] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const digest = (label) => `sha256:${crypto.createHash('sha256').update(label).digest('hex')}`;
const fileDigest = (file) => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
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
const canonicalDigest = (value) =>
  `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
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
if (typeof report.generated_at !== 'string' || Number.isNaN(Date.parse(report.generated_at))) {
  throw new Error('GA report must include an ISO generated_at timestamp');
}
const evidenceIndex = JSON.parse(fs.readFileSync(path.join(path.dirname(reportFile), 'ga-evidence-index.json'), 'utf8'));
if (evidenceIndex.schema !== 'agentsmith.ga-evidence-index/v1') {
  throw new Error(`unexpected GA evidence index schema: ${evidenceIndex.schema}`);
}
if (evidenceIndex.generated_at !== report.generated_at) {
  throw new Error('GA evidence index generated_at must match the source report generated_at');
}
if (
  evidenceIndex.source_report?.path !== 'ga-release-report.json' ||
  evidenceIndex.source_report?.digest !== canonicalDigest(report) ||
  evidenceIndex.source_report?.status !== report.status ||
  evidenceIndex.source_report?.formal_verdict !== report.formal_verdict
) {
  throw new Error('GA evidence index must bind the final GA report');
}
if (JSON.stringify(stableJson(evidenceIndex.artifact_index)) !== JSON.stringify(stableJson(report.artifact_index))) {
  throw new Error('GA evidence index artifact_index must match the final GA report artifact_index');
}
if (
  JSON.stringify(stableJson(report.artifact_index?.canonical_repos)) !==
  JSON.stringify(stableJson(report.canonical_repos))
) {
  throw new Error('GA report artifact index must archive canonical repo provenance/freshness entries');
}
if (!Array.isArray(evidenceIndex.deployment_paths) || evidenceIndex.deployment_paths.length !== expectedPaths.size) {
  throw new Error('GA evidence index must archive four deployment path evidence entries');
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
if (packageDirs.length !== expectedPaths.size) {
  throw new Error('package-driven GA assertion requires four operator-inputs package dirs');
}
const plansByPath = new Map(packageDirs.map((packageDir) => {
  const plan = JSON.parse(fs.readFileSync(path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json'), 'utf8'));
  return [plan.deployment_path, plan];
}));
const firstPlan = plansByPath.values().next().value;
const contract = JSON.parse(fs.readFileSync(firstPlan.input_refs.release_contract.absolute_path, 'utf8'));
const packageIndex = report.artifact_index?.operator_inputs_packages;
if (!Array.isArray(packageIndex) || packageIndex.length !== expectedPaths.size) {
  throw new Error('GA report artifact index must cover four operator-inputs packages');
}
const serializedPackageIndex = JSON.stringify(packageIndex);
const serializedEvidenceIndex = JSON.stringify(evidenceIndex);
for (const packageDir of packageDirs) {
  if (serializedPackageIndex.includes(packageDir)) {
    throw new Error('GA report operator-inputs package index must not expose local package dirs');
  }
  if (serializedEvidenceIndex.includes(packageDir)) {
    throw new Error('GA evidence index must not expose local package dirs');
  }
}
if (serializedPackageIndex.includes('.release-kit-internal')) {
  throw new Error('GA report operator-inputs package index must not expose internal output paths');
}
if (serializedEvidenceIndex.includes('.release-kit-internal')) {
  throw new Error('GA evidence index must not expose internal output paths');
}
for (const entry of packageIndex) {
  const plan = plansByPath.get(entry.operator_path);
  if (!plan) {
    throw new Error(`GA report operator-inputs package index has unexpected path: ${entry.operator_path}`);
  }
  if (entry.package_manifest?.path !== plan.package?.manifest_relative_path) {
    throw new Error(`GA report operator-inputs manifest path mismatch: ${entry.operator_path}`);
  }
  if (entry.package_manifest?.schema !== 'agentsmith.operator-inputs/v1') {
    throw new Error(`GA report operator-inputs manifest schema mismatch: ${entry.operator_path}`);
  }
  if (entry.package_manifest?.digest !== plan.package?.manifest_sha256) {
    throw new Error(`GA report operator-inputs manifest digest mismatch: ${entry.operator_path}`);
  }
  if (entry.package_plan?.schema !== 'agentsmith.operator-inputs-plan/v1') {
    throw new Error(`GA report operator-inputs plan schema mismatch: ${entry.operator_path}`);
  }
  if (entry.package_plan?.scope !== 'operator_inputs_intake_only') {
    throw new Error(`GA report operator-inputs plan scope mismatch: ${entry.operator_path}`);
  }
  if (entry.package_plan?.digest !== plan.plan_sha256) {
    throw new Error(`GA report operator-inputs plan digest mismatch: ${entry.operator_path}`);
  }
  if (entry.release_materials?.release_contract?.path !== plan.input_refs?.release_contract?.path) {
    throw new Error(`GA report operator-inputs release contract path mismatch: ${entry.operator_path}`);
  }
  if (entry.release_materials?.release_contract?.digest !== fileDigest(plan.input_refs.release_contract.absolute_path)) {
    throw new Error(`GA report operator-inputs release contract digest mismatch: ${entry.operator_path}`);
  }
  if (entry.release_materials?.deploy_template_package?.path !== plan.input_refs?.deploy_template_package?.path) {
    throw new Error(`GA report operator-inputs deploy template package path mismatch: ${entry.operator_path}`);
  }
  if (entry.release_materials?.deploy_template_package?.digest !== fileDigest(plan.input_refs.deploy_template_package.absolute_path)) {
    throw new Error(`GA report operator-inputs deploy template package digest mismatch: ${entry.operator_path}`);
  }
  const deploymentPathEntry = report.deployment_paths.find((pathEntry) => pathEntry.operator_path === entry.operator_path);
  if (entry.deployment_path_report?.digest !== deploymentPathEntry?.report_digest) {
    throw new Error(`GA report operator-inputs package index must bind deployment path report digest: ${entry.operator_path}`);
  }
}
const runnerManifest = report.images?.runner_release_manifest;
const runnerProvenance = contract.deploy_image_inventory
  .find((entry) => entry.id === 'managed_runner')
  ?.source_provenance;
if (runnerManifest?.artifact_uri !== runnerProvenance?.runner_release_manifest_uri) {
  throw new Error('GA report runner release manifest URI mismatch');
}
if (runnerManifest?.subject_sha256 !== runnerProvenance?.runner_release_manifest_subject_sha256) {
  throw new Error('GA report runner release manifest subject digest mismatch');
}
if (runnerManifest?.artifact_sha256 !== runnerProvenance?.runner_release_manifest_artifact_sha256) {
  throw new Error('GA report runner release manifest artifact digest mismatch');
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
if (report.post_deploy_product_smoke?.deployment_target?.profile !== 'existing_kubernetes/external_declared/online') {
  throw new Error('GA report must bind product smoke deployment target profile');
}
if (report.post_deploy_product_smoke?.deployment_path_binding?.operator_path !== 'online/use_existing') {
  throw new Error('GA report must bind product smoke to a finalized deployment path');
}
if (
  report.post_deploy_product_smoke?.deployment_path_binding?.target_profile !==
  report.post_deploy_product_smoke?.deployment_target?.profile
) {
  throw new Error('GA report product smoke deployment path binding target profile mismatch');
}
if (report.post_deploy_product_smoke?.deployment_target?.site_env?.sha256 !== digest('post-deploy-product-smoke:site-env')) {
  throw new Error('GA report must bind product smoke site env digest');
}
if (report.post_deploy_product_smoke?.deployment_target?.substrate_truth?.sha256 !== digest('post-deploy-product-smoke:substrate-truth')) {
  throw new Error('GA report must bind product smoke substrate truth digest');
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
assert_ga_report \
  "$ga_output_dir/ga-release-report.json" \
  "$online_package" \
  "$online_install_package" \
  "$airgap_package" \
  "$airgap_install_package"

seed_stale_ga_outputs() {
  local output_dir="$1"

  mkdir -p "$output_dir"
  cp "$ga_output_dir/ga-release-report.json" "$output_dir/ga-release-report.json"
  cp "$ga_output_dir/ga-release-summary.md" "$output_dir/ga-release-summary.md"
  cp "$ga_output_dir/ga-evidence-index.json" "$output_dir/ga-evidence-index.json"
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
assert_ga_failure_report "$missing_package_output" 'requires exactly 4 --operator-inputs packages'

missing_package_summary_failure_output="$TMP_DIR/ga-output-missing-package-summary-failure"
missing_package_summary_failure_preload="$TMP_DIR/fail-facade-ga-summary-write.mjs"
seed_stale_ga_outputs "$missing_package_summary_failure_output"
cat >"$missing_package_summary_failure_preload" <<'NODE'
import fs from 'node:fs/promises';

const originalWriteFile = fs.writeFile;
fs.writeFile = async function writeFileWithInjectedFacadeSummaryFailure(file, ...args) {
  if (String(file).includes('ga-release-summary.md')) {
    throw new Error('injected facade summary write failure');
  }
  return originalWriteFile.call(this, file, ...args);
};
NODE
if NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--import=$missing_package_summary_failure_preload" \
  bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
    --operator-inputs "$online_package" \
    --operator-inputs "$online_install_package" \
    --operator-inputs "$airgap_package" \
    --product-readiness-report "$product_dir/product-readiness-report.json" \
    --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
    --output-dir "$missing_package_summary_failure_output" >"$TMP_DIR/ga-missing-package-summary-failure.out" 2>&1; then
  fail "operator GA facade should fail when its own failure summary cannot be written"
fi
grep -Fq 'injected facade summary write failure' "$TMP_DIR/ga-missing-package-summary-failure.out" ||
  fail "facade summary write failure did not reach operator GA facade output"
for final_output in ga-release-report.json ga-release-summary.md ga-evidence-index.json; do
  if [[ -e "$missing_package_summary_failure_output/$final_output" ]]; then
    fail "facade failure summary write must not leave $final_output"
  fi
done

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
assert_ga_failure_report "$duplicate_path_output" 'duplicate deployment_path online/use_existing'

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
assert_ga_failure_report "$missing_path_output" 'finalized path evidence is missing for online/use_existing'

verifier_summary_failure_output="$TMP_DIR/ga-output-verifier-summary-failure"
verifier_summary_failure_preload="$TMP_DIR/fail-child-ga-summary-write.mjs"
seed_stale_ga_outputs "$verifier_summary_failure_output"
cat >"$verifier_summary_failure_preload" <<'NODE'
import fs from 'node:fs/promises';

if (process.argv.some((arg) => String(arg).endsWith('verify-ga-release.mjs'))) {
  const originalWriteFile = fs.writeFile;
  fs.writeFile = async function writeFileWithInjectedChildSummaryFailure(file, ...args) {
    if (String(file).includes('ga-release-summary.md')) {
      throw new Error('injected child summary write failure');
    }
    return originalWriteFile.call(this, file, ...args);
  };
}
NODE
if NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--import=$verifier_summary_failure_preload" \
  bash "$ROOT_DIR/scripts/operator-release.sh" --ga-report \
    --operator-inputs "$online_package" \
    --operator-inputs "$online_install_package" \
    --operator-inputs "$airgap_package" \
    --operator-inputs "$airgap_install_package" \
    --product-readiness-report "$product_dir/product-readiness-report.json" \
    --post-deploy-product-smoke-report "$product_dir/post-deploy-product-smoke-report.json" \
    --output-dir "$verifier_summary_failure_output" >"$TMP_DIR/ga-verifier-summary-failure.out" 2>&1; then
  fail "operator GA facade should fail when child verifier cannot write the summary"
fi
grep -Fq 'injected child summary write failure' "$TMP_DIR/ga-verifier-summary-failure.out" ||
  fail "child verifier summary failure did not reach operator GA facade output"
assert_ga_failure_report "$verifier_summary_failure_output" 'injected child summary write failure'

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
