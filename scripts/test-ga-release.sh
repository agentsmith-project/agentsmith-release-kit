#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_TEMPLATE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_fixture_set() {
  local dir="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$VALID_TEMPLATE" "$dir" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [contractFile, templateFile, outDir, mutation] = process.argv.slice(2);
const contractRaw = fs.readFileSync(contractFile);
const templateRaw = fs.readFileSync(templateFile);
const contract = JSON.parse(contractRaw.toString('utf8'));
const template = JSON.parse(templateRaw.toString('utf8'));
const contractDigest = digest(contractRaw);
const templateDigest = digest(templateRaw);

fs.mkdirSync(outDir, { recursive: true });

function digest(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function sha(label) {
  return digest(Buffer.from(label));
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function provenance(subjectName) {
  return {
    schema_version: 'agentsmith.artifact-provenance/v1',
    provenance_kind: 'ci_artifact',
    producer_repo: 'github.com/agentsmith-project/agentsmith',
    normalized_remote: 'github.com/agentsmith-project/agentsmith',
    commit_sha: contract.git_sha,
    subject_name: subjectName,
    subject_sha256: sha(subjectName),
    subject_uri: `${subjectName}.json`,
    workflow_name: 'GA',
    run_id: '10001',
    run_attempt: '1',
    job: subjectName,
    artifact_uri: `gh-artifact://agentsmith/${subjectName}/10001/${subjectName}.json`,
    artifact_sha256: sha(`${subjectName}:artifact`),
    generated_at: '2026-05-31T12:00:00.000Z',
    generator_command: 'focused fixture',
    generator_version: 'test',
    attestation: 'none'
  };
}

function targetProfile(value) {
  const [target_cluster, substrate_source, distribution] = value.split('/');
  return {
    value,
    target_cluster,
    substrate_source,
    distribution
  };
}

function step(name, operatorPath) {
  return {
    name,
    status: 'pass',
    report_digest: sha(`${operatorPath}:${name}`)
  };
}

function pathReport(operatorPath, profile, steps) {
  const report = {
    schema: 'agentsmith.deployment-path-report/v1',
    scope: 'deployment_path_ga_evidence',
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract_digest: contractDigest,
    deploy_template_package_digest: templateDigest,
    operator_path: operatorPath,
    target_profile: targetProfile(profile),
    steps: steps.map((name) => step(name, operatorPath))
  };

  if (operatorPath.includes('install_substrates')) {
    report.install_substrates_confirmation = {
      confirmed: mutation === 'missing-install-confirmation' ? false : true,
      operator_run_id: `operator-${operatorPath.replaceAll('/', '-')}`,
      substrate_install_report_digest: sha(`${operatorPath}:substrate-install-report`)
    };
  }

  if (operatorPath.startsWith('airgap/')) {
    report.airgap_offline = {
      public_internet_downloads: mutation === 'airgap-download' && operatorPath === 'airgap/use_existing',
      bundle_manifest_digest: sha(`${operatorPath}:bundle-manifest`),
      image_load_report_digest: sha(`${operatorPath}:image-load`),
      offline_render_report_digest: sha(`${operatorPath}:offline-render`)
    };
  }

  return report;
}

const reports = {
  'online-use-existing.json': pathReport(
    'online/use_existing',
    'existing_kubernetes/external_declared/online',
    ['target-preflight', 'render-check', 'apply', 'rollout', 'route-smoke']
  ),
  'online-install-substrates.json': pathReport(
    'online/install_substrates',
    'existing_kubernetes/kit_installed/online',
    ['substrate-install', 'target-preflight', 'render-check', 'apply', 'rollout', 'route-smoke']
  ),
  'airgap-use-existing.json': pathReport(
    'airgap/use_existing',
    'existing_kubernetes/external_declared/airgap',
    ['bundle-check', 'image-load', 'offline-render-check', 'apply', 'rollout', 'route-smoke']
  ),
  'airgap-install-substrates.json': pathReport(
    'airgap/install_substrates',
    'existing_kubernetes/kit_installed/airgap',
    ['bundle-check', 'image-load', 'substrate-install', 'offline-render-check', 'apply', 'rollout', 'route-smoke']
  )
};

const productReady = {
  schema: 'agentsmith.product-readiness-report/v1',
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: contractDigest,
  artifact_provenance: provenance('product-readiness-report')
};

const productSmoke = {
  schema: 'agentsmith.post-deploy-product-smoke/v1',
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: contractDigest,
  covered_flows: [
    'auth_profile',
    'workspace_project',
    'files',
    'managed_runner_agent_task',
    'provider_neutral_endpoint',
    'audit_usage_readback'
  ]
};

const contractOut = structuredClone(contract);
if (mutation === 'mutable-image') {
  const mutableTag = `:late${'st'}`;
  contractOut.deploy_image_inventory[0].image = `ghcr.io/agentsmith-project/agentsmith-app${mutableTag}`;
}

writeJson(path.join(outDir, 'release-contract.json'), contractOut);
writeJson(path.join(outDir, 'deploy-template-package.json'), template);
writeJson(path.join(outDir, 'product-readiness-report.json'), productReady);
writeJson(path.join(outDir, 'post-deploy-product-smoke-report.json'), productSmoke);

for (const [file, report] of Object.entries(reports)) {
  writeJson(path.join(outDir, file), report);
}
NODE
}

run_ga_release() {
  local fixture_dir="$1"
  local output_dir="$2"

  bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
    --release-contract "$fixture_dir/release-contract.json" \
    --deploy-template-package "$fixture_dir/deploy-template-package.json" \
    --deployment-path-report "$fixture_dir/online-use-existing.json" \
    --deployment-path-report "$fixture_dir/online-install-substrates.json" \
    --deployment-path-report "$fixture_dir/airgap-use-existing.json" \
    --deployment-path-report "$fixture_dir/airgap-install-substrates.json" \
    --product-readiness-report "$fixture_dir/product-readiness-report.json" \
    --post-deploy-product-smoke-report "$fixture_dir/post-deploy-product-smoke-report.json" \
    --output-dir "$output_dir"
}

VALID_DIR="$TMP_DIR/valid"
write_fixture_set "$VALID_DIR" valid
run_ga_release "$VALID_DIR" "$TMP_DIR/out-valid"

"$NODE_BIN" --input-type=module - "$TMP_DIR/out-valid/ga-release-report.json" <<'NODE'
import fs from 'node:fs';

const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.schema !== 'agentsmith.ga-release-report/v1') {
  throw new Error('unexpected schema');
}
if (report.status !== 'pass' || report.formal_verdict !== 'issued') {
  throw new Error('GA report did not issue pass verdict');
}
if (!Array.isArray(report.deployment_paths) || report.deployment_paths.length !== 4) {
  throw new Error('expected four deployment paths');
}
NODE
[[ -f "$TMP_DIR/out-valid/ga-release-summary.md" ]] || fail "missing human summary"
pass "valid GA aggregate writes final report"

MISSING_DIR="$TMP_DIR/missing"
write_fixture_set "$MISSING_DIR" valid
if bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
  --release-contract "$MISSING_DIR/release-contract.json" \
  --deploy-template-package "$MISSING_DIR/deploy-template-package.json" \
  --deployment-path-report "$MISSING_DIR/online-use-existing.json" \
  --deployment-path-report "$MISSING_DIR/online-install-substrates.json" \
  --deployment-path-report "$MISSING_DIR/airgap-use-existing.json" \
  --product-readiness-report "$MISSING_DIR/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$MISSING_DIR/post-deploy-product-smoke-report.json" \
  --output-dir "$TMP_DIR/out-missing" >/tmp/ga-release-missing.out 2>&1; then
  fail "missing path report should fail"
fi
grep -Fq "expected exactly 4 --deployment-path-report inputs" /tmp/ga-release-missing.out || \
  fail "missing path report failure message did not explain blocker"
pass "missing path report fails fast"

MUTABLE_DIR="$TMP_DIR/mutable"
write_fixture_set "$MUTABLE_DIR" mutable-image
if run_ga_release "$MUTABLE_DIR" "$TMP_DIR/out-mutable" >/tmp/ga-release-mutable.out 2>&1; then
  fail "mutable image should fail"
fi
grep -Fq "image must include its digest" /tmp/ga-release-mutable.out || \
  fail "mutable image failure message did not explain blocker"
pass "mutable image fails fast"

INSTALL_DIR="$TMP_DIR/install-confirmation"
write_fixture_set "$INSTALL_DIR" missing-install-confirmation
if run_ga_release "$INSTALL_DIR" "$TMP_DIR/out-install-confirmation" >/tmp/ga-release-install-confirmation.out 2>&1; then
  fail "missing install confirmation should fail"
fi
grep -Fq "requires explicit install_substrates confirmation" /tmp/ga-release-install-confirmation.out || \
  fail "install confirmation failure message did not explain blocker"
pass "install_substrates confirmation fails fast"

AIRGAP_DIR="$TMP_DIR/airgap-download"
write_fixture_set "$AIRGAP_DIR" airgap-download
if run_ga_release "$AIRGAP_DIR" "$TMP_DIR/out-airgap-download" >/tmp/ga-release-airgap-download.out 2>&1; then
  fail "airgap public download should fail"
fi
grep -Fq "must prove no public internet downloads" /tmp/ga-release-airgap-download.out || \
  fail "airgap offline failure message did not explain blocker"
pass "airgap public download fails fast"

echo "PASS: ga-release aggregate focused guard"
