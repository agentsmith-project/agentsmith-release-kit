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
const contract = JSON.parse(fs.readFileSync(contractFile, 'utf8'));
const template = JSON.parse(fs.readFileSync(templateFile, 'utf8'));

if (mutation === 'mutable-image') {
  const mutableTag = `:late${'st'}`;
  contract.deploy_image_inventory[0].image = `ghcr.io/agentsmith-project/agentsmith-app${mutableTag}`;
}

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

function jsonDigest(value) {
  return digest(Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}

const contractDigest = jsonDigest(contract);
const templateDigest = jsonDigest(template);

function targetProfile(value) {
  const [target_cluster, substrate_source, distribution] = value.split('/');
  return {
    value,
    target_cluster,
    substrate_source,
    distribution
  };
}

function releaseFields(profile) {
  return {
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract: {
      input_sha256: contractDigest
    },
    target_profile: targetProfile(profile)
  };
}

function baseStepReport(profile, schema, scope) {
  return {
    schema,
    scope,
    readiness: false,
    status: 'pass',
    ...releaseFields(profile)
  };
}

function stepReport(name, profile, bindings = {}) {
  switch (name) {
    case 'target-preflight':
      return {
        ...baseStepReport(
          profile,
          'agentsmith.target-preflight-report/v1',
          'target_preflight_prerequisite_only'
        ),
        substrate_truth: {
          schema_version: 'agentsmith.substrate-connection.truth/v1',
          input_sha256: sha(`${profile}:substrate-truth`),
          target_profile: targetProfile(profile),
          services_count: 5,
          services: ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc']
        },
        target_prerequisites: {
          schema_version: 'agentsmith.target-prerequisites.truth/v1',
          input_sha256: sha(`${profile}:target-prerequisites`),
          target_profile: profile,
          namespace: 'agentsmith',
          ingress_host: 'agentsmith.example.test',
          substrate_secret_refs_count: 11
        },
        checks: {
          schema: 'pass',
          target_axes: 'pass',
          service_contracts: 'pass',
          target_prerequisites: 'pass',
          secret_references: 'pass',
          tls_or_sslmode: 'pass',
          reachability: 'pass'
        }
      };
    case 'render-check':
      return {
        ...baseStepReport(
          profile,
          'agentsmith.render-check-report/v1',
          'render_check_image_inventory_only'
        ),
        rendered_manifests: {
          files_count: 1,
          workload_count: 1
        },
        images: [
          {
            image: 'ghcr.io/agentsmith-project/agentsmith-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            inventory_id: 'agentsmith_app',
            matched_by: 'exact_ref'
          }
        ],
        manifests: [
          {
            path: 'agentsmith-web.yaml',
            document_index: 1,
            kind: 'Deployment',
            name: 'agentsmith-web',
            sha256: sha(`${profile}:manifest:agentsmith-web`),
            images: [
              {
                field: 'containers',
                container: 'app',
                image: 'ghcr.io/agentsmith-project/agentsmith-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                inventory_id: 'agentsmith_app',
                matched_by: 'exact_ref'
              }
            ]
          }
        ]
      };
    case 'apply':
      return {
        schema_version: 'agentsmith.kubernetes-apply-report/v1',
        scope: 'kubernetes_apply_only',
        readiness: false,
        status: 'pass',
        ...releaseFields(profile),
        mode: 'apply',
        operator_run_id: `operator-apply-${profile.replaceAll('/', '-')}`,
        resource_refs: [
          {
            kind: 'Deployment',
            namespace: 'agentsmith',
            name: 'agentsmith-web',
            path: 'agentsmith-web.yaml',
            document_index: 1
          }
        ],
        kubectl_resource_refs: ['deployment.apps/agentsmith-web'],
        render_check: {
          schema: 'agentsmith.render-check-report/v1',
          scope: 'render_check_image_inventory_only',
          status: 'pass',
          images_count: 1,
          workload_count: 1
        }
      };
    case 'rollout':
      return {
        ...baseStepReport(
          profile,
          'agentsmith.kubernetes-rollout-report/v1',
          'kubernetes_rollout_imageid_only'
        ),
        rollout_resource_refs: [
          {
            kind: 'Deployment',
            namespace: 'agentsmith',
            name: 'agentsmith-web',
            path: 'agentsmith-web.yaml',
            document_index: 1,
            selector: 'app.kubernetes.io/name=agentsmith-web'
          }
        ],
        expected_image_digests: [
          {
            digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            inventory_ids: ['agentsmith_app'],
            images_count: 1
          }
        ],
        observed_live_image_digest_summary: {
          pods_count: 1,
          status_entries_count: 1,
          image_id_count: 1,
          image_field_fallback_count: 0,
          missing_digest_count: 0,
          observed_digest_count: 1,
          observed_digests: ['sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'],
          matched_expected_digests: ['sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']
        },
        workload_summaries: [
          {
            resource_ref: {
              kind: 'Deployment',
              namespace: 'agentsmith',
              name: 'agentsmith-web',
              path: 'agentsmith-web.yaml',
              document_index: 1,
              selector: 'app.kubernetes.io/name=agentsmith-web'
            },
            expected_image_digests: [
              {
                digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                inventory_ids: ['agentsmith_app'],
                images_count: 1
              }
            ],
            observed_live_image_digest_summary: {
              pods_count: 1,
              status_entries_count: 1,
              image_id_count: 1,
              image_field_fallback_count: 0,
              missing_digest_count: 0,
              observed_digest_count: 1,
              observed_digests: ['sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'],
              matched_expected_digests: ['sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']
            }
          }
        ]
      };
    case 'smoke':
      return {
        ...baseStepReport(
          profile,
          'agentsmith.route-smoke-report/v1',
          'route_smoke_only'
        ),
        route: {
          scheme: 'https',
          origin: 'https://agentsmith.example.test',
          host: 'agentsmith.example.test',
          path: '/healthz'
        },
        expected_status: 200,
        status_code: 200,
        duration_ms: 1,
        rollout_report: {
          input_sha256: sha(`${profile}:rollout-report`),
          schema: 'agentsmith.kubernetes-rollout-report/v1',
          scope: 'kubernetes_rollout_imageid_only',
          status: 'pass'
        }
      };
    case 'airgap-image-load':
      return {
        ...baseStepReport(
          profile,
          'agentsmith.airgap-image-load-report/v1',
          'airgap_image_load_only'
        ),
        digest_summary: {
          release_contract_input_sha256: contractDigest,
          deploy_template_package_input_sha256: templateDigest,
          deploy_template_archive_input_sha256: sha(`${profile}:archive`),
          image_map_input_sha256: bindings.imageMapDigest,
          bundle_manifest_input_sha256: bindings.bundleManifestDigest,
          airgap_bundle_check_report_input_sha256: bindings.bundleCheckDigest
        }
      };
    case 'airgap-bundle-render-check':
      return {
        ...baseStepReport(
          profile,
          'agentsmith.airgap-bundle-render-check-report/v1',
          'airgap_bundle_render_check_only'
        ),
        digest_summary: {
          release_contract_input_sha256: contractDigest,
          deploy_template_package_input_sha256: templateDigest,
          deploy_template_archive_input_sha256: sha(`${profile}:archive`),
          image_map_input_sha256: bindings.imageMapDigest,
          bundle_manifest_input_sha256: bindings.bundleManifestDigest,
          render_values_input_sha256: sha(`${profile}:render-values`),
          substrate_truth_input_sha256: sha(`${profile}:substrate-truth`),
          airgap_bundle_check_report_input_sha256: bindings.bundleCheckDigest,
          manifest_render_report_input_sha256: sha(`${profile}:render-report`),
          render_check_report_input_sha256: sha(`${profile}:render-check-report`)
        }
      };
    default:
      throw new Error(`unsupported step fixture: ${name}`);
  }
}

function step(baseDir, name, relativePath, profile, bindings = {}) {
  const report = stepReport(name, profile, bindings);
  if (name === 'smoke') {
    report.rollout_report.input_sha256 = digest(
      fs.readFileSync(path.join(baseDir, 'rollout/rollout-report.json'))
    );
  }
  writeJson(path.join(baseDir, relativePath), report);
  return {
    name,
    status: 'pass',
    report_paths: [relativePath]
  };
}

function onlineGate(dir, profile) {
  writeJson(path.join(dir, 'online-deployment-gate-report.json'), {
    schema: 'agentsmith.online-deployment-gate/v1',
    scope: 'online_deployment_gate_only',
    readiness: false,
    status: 'pass',
    mode: 'apply',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract: {
      input_sha256: contractDigest
    },
    target_profile: targetProfile(profile),
    operator_run_id: 'operator-online-10001',
    steps: [
      step(dir, 'target-preflight', 'target-preflight/target-preflight-report.json', profile),
      step(dir, 'render-check', 'render-check/render-report.json', profile),
      step(dir, 'apply', 'apply/apply-report.json', profile),
      step(dir, 'rollout', 'rollout/rollout-report.json', profile),
      step(dir, 'smoke', 'smoke/smoke-report.json', profile)
    ]
  });
}

function airgapBundle(dir, profile) {
  const imageMapPath = 'components/image-map.json';
  fs.mkdirSync(path.join(dir, 'components'), { recursive: true });
  writeJson(path.join(dir, imageMapPath), {
    schema: 'agentsmith.image-map/v1',
    scope: 'image_map_only',
    readiness: false,
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile(profile),
    mirror_required: true,
    target_registry: 'registry.example.test/agentsmith',
    image_count: 1,
    mappings: [
      {
        id: 'agentsmith_app',
        source_image: 'ghcr.io/agentsmith-project/agentsmith-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        source_digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        target_image: 'registry.example.test/agentsmith/agentsmith-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        target_digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      }
    ]
  });
  const imageMapDigest = digest(fs.readFileSync(path.join(dir, imageMapPath)));
  const manifest = {
    schema_version: 'agentsmith.airgap-bundle-manifest/v1',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile(profile),
    bindings: {
      image_map_sha256: imageMapDigest
    },
    components: [
      {
        kind: 'image_map',
        path: imageMapPath,
        sha256: imageMapDigest
      }
    ]
  };
  const manifestPath = path.join(dir, 'airgap-bundle-manifest.json');
  writeJson(manifestPath, manifest);
  const manifestDigest = digest(fs.readFileSync(manifestPath));

  const checkPath = path.join(dir, 'airgap-bundle-check-report.json');
  writeJson(checkPath, {
    schema: 'agentsmith.airgap-bundle-check-report/v1',
    scope: 'airgap_bundle_manifest_check_only',
    readiness: false,
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile(profile),
    artifacts: {
      release_contract: {
        input_sha256: contractDigest
      },
      deploy_template_package: {
        input_sha256: templateDigest
      },
      deploy_template_archive: {
        input_sha256: sha(`${profile}:archive`)
      },
      image_map: {
        input_sha256: imageMapDigest
      },
      bundle_manifest: {
        input_sha256: manifestDigest
      }
    }
  });
  return {
    bundleManifestDigest: manifestDigest,
    bundleCheckDigest: digest(fs.readFileSync(checkPath)),
    imageMapDigest
  };
}

function airgapGate(dir, profile, bindings) {
  writeJson(path.join(dir, 'airgap-deployment-gate-report.json'), {
    schema: 'agentsmith.airgap-deployment-gate/v1',
    scope: 'airgap_deployment_gate_only',
    readiness: false,
    status: 'pass',
    mode: 'apply',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract: {
      input_sha256: contractDigest
    },
    target_profile: targetProfile(profile),
    operator_run_id: 'operator-airgap-10001',
    steps: [
      step(dir, 'target-preflight', 'target-preflight/target-preflight-report.json', profile),
      step(dir, 'airgap-image-load', 'airgap-image-load/airgap-image-load-report.json', profile, bindings),
      step(dir, 'airgap-bundle-render-check', 'airgap-bundle-render-check/airgap-bundle-render-check-report.json', profile, bindings),
      step(dir, 'apply', 'apply/apply-report.json', profile),
      step(dir, 'rollout', 'rollout/rollout-report.json', profile),
      step(dir, 'smoke', 'smoke/smoke-report.json', profile)
    ]
  });
}

function substrateInstall(dir, profile, operatorRunId) {
  writeJson(path.join(dir, 'substrate-install-report.json'), {
    schema: 'agentsmith.substrate-install-report/v1',
    scope: 'substrate_install_only',
    readiness: false,
    status: 'pass',
    producer: 'agentsmith-release-kit-substrate-installer',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract_digest: contractDigest,
    deploy_template_package_digest: templateDigest,
    target_profile: targetProfile(profile),
    operator_run_id: operatorRunId,
    substrate_truth_digest: sha(`${profile}:substrate-truth`),
    installed_services: ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc'],
    output_substrate_truth_digest: sha(`${profile}:substrate-truth`)
  });
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

fs.mkdirSync(outDir, { recursive: true });
writeJson(path.join(outDir, 'release-contract.json'), contract);
writeJson(path.join(outDir, 'deploy-template-package.json'), template);

const onlineUse = path.join(outDir, 'online-use-existing');
const onlineInstall = path.join(outDir, 'online-install-substrates');
const airgapUse = path.join(outDir, 'airgap-use-existing');
const airgapInstall = path.join(outDir, 'airgap-install-substrates');

onlineGate(onlineUse, 'existing_kubernetes/external_declared/online');
onlineGate(onlineInstall, 'existing_kubernetes/kit_installed/online');
substrateInstall(
  onlineInstall,
  'existing_kubernetes/kit_installed/online',
  'operator-online-install-10001'
);

const airgapUseBindings = airgapBundle(airgapUse, 'existing_kubernetes/external_declared/airgap');
airgapGate(airgapUse, 'existing_kubernetes/external_declared/airgap', airgapUseBindings);
const airgapInstallBindings = airgapBundle(airgapInstall, 'existing_kubernetes/kit_installed/airgap');
airgapGate(airgapInstall, 'existing_kubernetes/kit_installed/airgap', airgapInstallBindings);
substrateInstall(
  airgapInstall,
  'existing_kubernetes/kit_installed/airgap',
  'operator-airgap-install-10001'
);

writeJson(path.join(outDir, 'product-readiness-report.json'), {
  schema: 'agentsmith.product-readiness-report/v1',
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: contractDigest,
  artifact_provenance: provenance('product-readiness-report')
});

writeJson(path.join(outDir, 'post-deploy-product-smoke-report.json'), {
  schema: 'agentsmith.post-deploy-product-smoke/v1',
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract_digest: contractDigest,
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

run_online_path() {
  local fixture_dir="$1"
  local operator_path="$2"
  local source_dir="$3"
  local output_dir="$4"
  shift 4

  bash "$ROOT_DIR/scripts/verify-release.sh" --deployment-path \
    --operator-path "$operator_path" \
    --release-contract "$fixture_dir/release-contract.json" \
    --deploy-template-package "$fixture_dir/deploy-template-package.json" \
    --online-deployment-gate-report "$source_dir/online-deployment-gate-report.json" \
    --output-dir "$output_dir" \
    "$@"
}

run_airgap_path() {
  local fixture_dir="$1"
  local operator_path="$2"
  local source_dir="$3"
  local output_dir="$4"
  shift 4

  bash "$ROOT_DIR/scripts/verify-release.sh" --deployment-path \
    --operator-path "$operator_path" \
    --release-contract "$fixture_dir/release-contract.json" \
    --deploy-template-package "$fixture_dir/deploy-template-package.json" \
    --airgap-deployment-gate-report "$source_dir/airgap-deployment-gate-report.json" \
    --airgap-bundle-check-report "$source_dir/airgap-bundle-check-report.json" \
    --airgap-bundle-manifest "$source_dir/airgap-bundle-manifest.json" \
    --output-dir "$output_dir" \
    "$@"
}

generate_path_bundles() {
  local fixture_dir="$1"
  local path_dir="$2"

  run_online_path \
    "$fixture_dir" \
    "online/use_existing" \
    "$fixture_dir/online-use-existing" \
    "$path_dir/online-use-existing"

  run_online_path \
    "$fixture_dir" \
    "online/install_substrates" \
    "$fixture_dir/online-install-substrates" \
    "$path_dir/online-install-substrates" \
    --substrate-install-report "$fixture_dir/online-install-substrates/substrate-install-report.json" \
    --confirm-install-substrates "operator-online-install-10001"

  run_airgap_path \
    "$fixture_dir" \
    "airgap/use_existing" \
    "$fixture_dir/airgap-use-existing" \
    "$path_dir/airgap-use-existing"

  run_airgap_path \
    "$fixture_dir" \
    "airgap/install_substrates" \
    "$fixture_dir/airgap-install-substrates" \
    "$path_dir/airgap-install-substrates" \
    --substrate-install-report "$fixture_dir/airgap-install-substrates/substrate-install-report.json" \
    --confirm-install-substrates "operator-airgap-install-10001"
}

run_ga_release() {
  local fixture_dir="$1"
  local path_dir="$2"
  local output_dir="$3"

  bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
    --release-contract "$fixture_dir/release-contract.json" \
    --deploy-template-package "$fixture_dir/deploy-template-package.json" \
    --deployment-path-report "$path_dir/online-use-existing/deployment-path-report.json" \
    --deployment-path-report "$path_dir/online-install-substrates/deployment-path-report.json" \
    --deployment-path-report "$path_dir/airgap-use-existing/deployment-path-report.json" \
    --deployment-path-report "$path_dir/airgap-install-substrates/deployment-path-report.json" \
    --product-readiness-report "$fixture_dir/product-readiness-report.json" \
    --post-deploy-product-smoke-report "$fixture_dir/post-deploy-product-smoke-report.json" \
    --output-dir "$output_dir"
}

refresh_manifest_path_digest() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const reportFile = process.argv[2];
const manifestFile = path.join(path.dirname(reportFile), 'deployment-path-finalizer-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
manifest.path_report_sha256 =
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(reportFile)).digest('hex')}`;
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

mutate_product_smoke_report() {
  local report_file="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$mutation" <<'NODE'
import fs from 'node:fs';

const [reportFile, mutation] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));

if (mutation === 'missing-provenance') {
  delete report.artifact_provenance;
} else if (mutation === 'wrong-repo') {
  report.artifact_provenance.producer_repo = 'github.com/example/not-agentsmith';
  report.artifact_provenance.normalized_remote = 'github.com/example/not-agentsmith';
} else if (mutation === 'wrong-sha') {
  report.artifact_provenance.commit_sha = `${'9'.repeat(40)}`;
} else {
  throw new Error(`unknown product smoke mutation: ${mutation}`);
}

fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

mutate_release_contract_image_closure() {
  local contract_file="$1"

  "$NODE_BIN" --input-type=module - "$contract_file" <<'NODE'
import fs from 'node:fs';

const contractFile = process.argv[2];
const contract = JSON.parse(fs.readFileSync(contractFile, 'utf8'));
contract.deploy_template_package.required_image_ids =
  contract.deploy_template_package.required_image_ids.slice(0, -1);
fs.writeFileSync(contractFile, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_path_report() {
  local report_file="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$mutation" <<'NODE'
import fs from 'node:fs';

const [reportFile, mutation] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));

if (mutation === 'missing-install-confirmation') {
  report.install_substrates_confirmation.confirmed = false;
} else if (mutation === 'airgap-download') {
  report.airgap_offline.public_internet_downloads = true;
} else if (mutation === 'airgap-missing-target-preflight') {
  report.steps = report.steps.filter((step) => step.name !== 'target-preflight');
  report.source_evidence.finalized_steps = report.source_evidence.finalized_steps.filter(
    (step) => step.name !== 'target-preflight'
  );
} else if (mutation === 'path-readiness-true') {
  report.readiness = true;
} else if (mutation === 'source-ledger-step-digest-mismatch') {
  report.source_evidence.finalized_steps[0].report_digest =
    `sha256:${'9'.repeat(64)}`;
} else {
  throw new Error(`unknown mutation: ${mutation}`);
}

fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`);
NODE
  refresh_manifest_path_digest "$report_file"
}

corrupt_manifest_path_digest() {
  local report_dir="$1"

  "$NODE_BIN" --input-type=module - "$report_dir/deployment-path-finalizer-manifest.json" <<'NODE'
import fs from 'node:fs';

const manifestFile = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
manifest.path_report_sha256 = `sha256:${'8'.repeat(64)}`;
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

mutate_manifest_created_at() {
  local report_dir="$1"
  local created_at="$2"

  "$NODE_BIN" --input-type=module - "$report_dir/deployment-path-finalizer-manifest.json" "$created_at" <<'NODE'
import fs from 'node:fs';

const [manifestFile, createdAt] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
manifest.created_at = createdAt;
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

add_manifest_secret_like_field() {
  local report_dir="$1"

  "$NODE_BIN" --input-type=module - "$report_dir/deployment-path-finalizer-manifest.json" <<'NODE'
import fs from 'node:fs';

const manifestFile = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
manifest.private_key = 'leaked-private-key-material';
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

add_manifest_unknown_entry_field() {
  local report_dir="$1"

  "$NODE_BIN" --input-type=module - "$report_dir/deployment-path-finalizer-manifest.json" <<'NODE'
import fs from 'node:fs';

const manifestFile = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
manifest.source_evidence_files[0].operator_note = 'ordinary diagnostic note';
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

corrupt_source_evidence_file() {
  local report_dir="$1"
  local step_name="$2"

  "$NODE_BIN" --input-type=module - "$report_dir/deployment-path-finalizer-manifest.json" "$report_dir" "$step_name" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [manifestFile, reportDir, stepName] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const entry = manifest.source_evidence_files.find(
  (item) => item.kind === 'finalized_step_report' && item.step === stepName
);
if (!entry) {
  throw new Error(`missing source evidence file entry for ${stepName}`);
}
fs.appendFileSync(path.join(reportDir, entry.path), '\n');
NODE
}

add_unlisted_source_evidence_json() {
  local report_dir="$1"

  "$NODE_BIN" --input-type=module - "$report_dir" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const reportDir = process.argv[2];
const file = path.join(reportDir, 'source-evidence', 'unlisted-source-material.json');
fs.writeFileSync(
  file,
  `${JSON.stringify({ schema: 'agentsmith.unlisted-source-material/v1' }, null, 2)}\n`
);
NODE
}

mutate_source_evidence_file_with_digest_refresh() {
  local report_dir="$1"
  local step_name="$2"
  local mutation="$3"

  "$NODE_BIN" --input-type=module - "$report_dir" "$step_name" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [reportDir, stepName, mutation] = process.argv.slice(2);
const reportFile = path.join(reportDir, 'deployment-path-report.json');
const manifestFile = path.join(reportDir, 'deployment-path-finalizer-manifest.json');
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));

function digest(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

const entry = manifest.source_evidence_files.find(
  (item) => item.kind === 'finalized_step_report' && item.step === stepName
);
if (!entry) {
  throw new Error(`missing source evidence file entry for ${stepName}`);
}

const materialFile = path.join(reportDir, entry.path);
const material = JSON.parse(fs.readFileSync(materialFile, 'utf8'));
if (mutation === 'forbidden-local-material') {
  material.operator_note = {
    kubeconfig_path: '/etc/kubernetes/admin.conf'
  };
} else if (mutation === 'schema-shaped-render-check') {
  material.images = [{}];
  material.manifests = [{}];
} else {
  throw new Error(`unknown source evidence mutation: ${mutation}`);
}
writeJson(materialFile, material);
const materialDigest = digest(materialFile);

entry.sha256 = materialDigest;
const pathStep = report.steps.find((step) => step.name === stepName);
const ledgerStep = report.source_evidence.finalized_steps.find((step) => step.name === stepName);
if (!pathStep || !ledgerStep) {
  throw new Error(`missing deployment path step for ${stepName}`);
}
pathStep.report_digest = materialDigest;
ledgerStep.report_digest = materialDigest;
writeJson(reportFile, report);

manifest.path_report_sha256 = digest(reportFile);
writeJson(manifestFile, manifest);
NODE
}

poison_source_evidence_file_with_digest_refresh() {
  mutate_source_evidence_file_with_digest_refresh "$1" "$2" forbidden-local-material
}

fake_render_check_source_evidence_with_digest_refresh() {
  mutate_source_evidence_file_with_digest_refresh "$1" render-check schema-shaped-render-check
}

VALID_DIR="$TMP_DIR/valid"
PATH_DIR="$TMP_DIR/path-reports"
write_fixture_set "$VALID_DIR" valid
generate_path_bundles "$VALID_DIR" "$PATH_DIR"
run_ga_release "$VALID_DIR" "$PATH_DIR" "$TMP_DIR/out-valid"

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
pass "valid GA aggregate consumes finalizer-generated path bundles"

for mutation in missing-provenance wrong-repo wrong-sha; do
  PRODUCT_SMOKE_DIR="$TMP_DIR/product-smoke-$mutation"
  write_fixture_set "$PRODUCT_SMOKE_DIR" valid
  mutate_product_smoke_report "$PRODUCT_SMOKE_DIR/post-deploy-product-smoke-report.json" "$mutation"
  if run_ga_release "$PRODUCT_SMOKE_DIR" "$PATH_DIR" "$TMP_DIR/out-product-smoke-$mutation" >"$TMP_DIR/ga-release-product-smoke-$mutation.out" 2>&1; then
    fail "product smoke $mutation should fail"
  fi
  if [[ "$mutation" == "missing-provenance" ]]; then
    grep -Fq "post_deploy_product_smoke.artifact_provenance must be an object" "$TMP_DIR/ga-release-product-smoke-$mutation.out" || \
      fail "product smoke missing provenance failure message did not explain blocker"
  else
    grep -Fq "post-deploy product smoke provenance must match AgentSmith repo and git sha" "$TMP_DIR/ga-release-product-smoke-$mutation.out" || \
      fail "product smoke provenance drift failure message did not explain blocker"
  fi
done
pass "GA aggregate requires post-deploy product smoke AgentSmith provenance"

IMAGE_CLOSURE_DIR="$TMP_DIR/release-contract-image-closure"
write_fixture_set "$IMAGE_CLOSURE_DIR" valid
mutate_release_contract_image_closure "$IMAGE_CLOSURE_DIR/release-contract.json"
if run_ga_release "$IMAGE_CLOSURE_DIR" "$PATH_DIR" "$TMP_DIR/out-release-contract-image-closure" >"$TMP_DIR/ga-release-image-closure.out" 2>&1; then
  fail "release contract image closure drift should fail"
fi
grep -Fq "release_contract.deploy_template_package.required_image_ids must exactly match release_contract.deploy_image_inventory ids" "$TMP_DIR/ga-release-image-closure.out" || \
  fail "release contract image closure failure message did not explain blocker"
pass "GA aggregate rejects release contract required image closure drift"

MISSING_DIR="$TMP_DIR/missing"
write_fixture_set "$MISSING_DIR" valid
generate_path_bundles "$MISSING_DIR" "$TMP_DIR/path-missing"
if bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
  --release-contract "$MISSING_DIR/release-contract.json" \
  --deploy-template-package "$MISSING_DIR/deploy-template-package.json" \
  --deployment-path-report "$TMP_DIR/path-missing/online-use-existing/deployment-path-report.json" \
  --deployment-path-report "$TMP_DIR/path-missing/online-install-substrates/deployment-path-report.json" \
  --deployment-path-report "$TMP_DIR/path-missing/airgap-use-existing/deployment-path-report.json" \
  --product-readiness-report "$MISSING_DIR/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$MISSING_DIR/post-deploy-product-smoke-report.json" \
  --output-dir "$TMP_DIR/out-missing" >"$TMP_DIR/ga-release-missing.out" 2>&1; then
  fail "missing path report should fail"
fi
grep -Fq "expected exactly 4 --deployment-path-report inputs" "$TMP_DIR/ga-release-missing.out" || \
  fail "missing path report failure message did not explain blocker"
pass "missing path report fails fast"

NO_MANIFEST_DIR="$TMP_DIR/missing-manifest"
write_fixture_set "$NO_MANIFEST_DIR" valid
generate_path_bundles "$NO_MANIFEST_DIR" "$TMP_DIR/path-missing-manifest"
rm "$TMP_DIR/path-missing-manifest/online-use-existing/deployment-path-finalizer-manifest.json"
if run_ga_release "$NO_MANIFEST_DIR" "$TMP_DIR/path-missing-manifest" "$TMP_DIR/out-missing-manifest" >"$TMP_DIR/ga-release-missing-manifest.out" 2>&1; then
  fail "path report without sibling manifest should fail"
fi
grep -Fq "cannot read deployment path finalizer manifest" "$TMP_DIR/ga-release-missing-manifest.out" || \
  fail "missing manifest failure message did not explain blocker"
pass "GA aggregate rejects path reports without sibling manifest"

MANIFEST_DRIFT_DIR="$TMP_DIR/manifest-drift"
write_fixture_set "$MANIFEST_DRIFT_DIR" valid
generate_path_bundles "$MANIFEST_DRIFT_DIR" "$TMP_DIR/path-manifest-drift"
corrupt_manifest_path_digest "$TMP_DIR/path-manifest-drift/online-use-existing"
if run_ga_release "$MANIFEST_DRIFT_DIR" "$TMP_DIR/path-manifest-drift" "$TMP_DIR/out-manifest-drift" >"$TMP_DIR/ga-release-manifest-drift.out" 2>&1; then
  fail "manifest path_report_sha256 drift should fail"
fi
grep -Fq "finalizer_manifest.path_report_sha256 must match deployment path report bytes" "$TMP_DIR/ga-release-manifest-drift.out" || \
  fail "manifest path digest drift failure message did not explain blocker"
pass "GA aggregate rejects manifest path report digest drift"

MANIFEST_CREATED_AT_DIR="$TMP_DIR/manifest-created-at"
write_fixture_set "$MANIFEST_CREATED_AT_DIR" valid
generate_path_bundles "$MANIFEST_CREATED_AT_DIR" "$TMP_DIR/path-manifest-created-at"
mutate_manifest_created_at "$TMP_DIR/path-manifest-created-at/online-use-existing" "not-an-iso-timestamp"
if run_ga_release "$MANIFEST_CREATED_AT_DIR" "$TMP_DIR/path-manifest-created-at" "$TMP_DIR/out-manifest-created-at" >"$TMP_DIR/ga-release-manifest-created-at.out" 2>&1; then
  fail "manifest created_at with non-ISO text should fail"
fi
grep -Fq "finalizer_manifest.created_at must be an ISO timestamp" "$TMP_DIR/ga-release-manifest-created-at.out" || \
  fail "manifest created_at failure message did not explain blocker"
pass "GA aggregate rejects non-ISO finalizer manifest created_at"

MANIFEST_SECRET_DIR="$TMP_DIR/manifest-secret-like-field"
write_fixture_set "$MANIFEST_SECRET_DIR" valid
generate_path_bundles "$MANIFEST_SECRET_DIR" "$TMP_DIR/path-manifest-secret-like-field"
add_manifest_secret_like_field "$TMP_DIR/path-manifest-secret-like-field/online-use-existing"
if run_ga_release "$MANIFEST_SECRET_DIR" "$TMP_DIR/path-manifest-secret-like-field" "$TMP_DIR/out-manifest-secret-like-field" >"$TMP_DIR/ga-release-manifest-secret.out" 2>&1; then
  fail "manifest secret-like field should fail"
fi
grep -Fq "deployment path finalizer manifest contains forbidden local path or secret-like text" "$TMP_DIR/ga-release-manifest-secret.out" || \
  fail "manifest secret-like field failure message did not explain blocker"
pass "GA aggregate scans finalizer manifest before acceptance"

MANIFEST_UNKNOWN_DIR="$TMP_DIR/manifest-unknown-entry-field"
write_fixture_set "$MANIFEST_UNKNOWN_DIR" valid
generate_path_bundles "$MANIFEST_UNKNOWN_DIR" "$TMP_DIR/path-manifest-unknown-entry-field"
add_manifest_unknown_entry_field "$TMP_DIR/path-manifest-unknown-entry-field/online-use-existing"
if run_ga_release "$MANIFEST_UNKNOWN_DIR" "$TMP_DIR/path-manifest-unknown-entry-field" "$TMP_DIR/out-manifest-unknown-entry-field" >"$TMP_DIR/ga-release-manifest-unknown.out" 2>&1; then
  fail "manifest unknown source evidence field should fail"
fi
grep -Fq "finalizer_manifest.source_evidence_files[0] contains unknown field: operator_note" "$TMP_DIR/ga-release-manifest-unknown.out" || \
  fail "manifest unknown source evidence field failure message did not explain blocker"
pass "GA aggregate rejects unknown finalizer manifest entry fields"

SOURCE_DRIFT_DIR="$TMP_DIR/source-drift"
write_fixture_set "$SOURCE_DRIFT_DIR" valid
generate_path_bundles "$SOURCE_DRIFT_DIR" "$TMP_DIR/path-source-drift"
corrupt_source_evidence_file "$TMP_DIR/path-source-drift/online-use-existing" "route-smoke"
if run_ga_release "$SOURCE_DRIFT_DIR" "$TMP_DIR/path-source-drift" "$TMP_DIR/out-source-drift" >"$TMP_DIR/ga-release-source-drift.out" 2>&1; then
  fail "source evidence file digest drift should fail"
fi
grep -Fq "source evidence file source-evidence/route-smoke-report.json sha256 must match finalizer manifest" "$TMP_DIR/ga-release-source-drift.out" || \
  fail "source evidence digest drift failure message did not explain blocker"
pass "GA aggregate rejects source evidence file digest drift"

SOURCE_EXTRA_DIR="$TMP_DIR/source-extra-material"
write_fixture_set "$SOURCE_EXTRA_DIR" valid
generate_path_bundles "$SOURCE_EXTRA_DIR" "$TMP_DIR/path-source-extra-material"
add_unlisted_source_evidence_json "$TMP_DIR/path-source-extra-material/online-use-existing"
if run_ga_release "$SOURCE_EXTRA_DIR" "$TMP_DIR/path-source-extra-material" "$TMP_DIR/out-source-extra-material" >"$TMP_DIR/ga-release-source-extra.out" 2>&1; then
  fail "unlisted source evidence JSON should fail"
fi
grep -Fq "source evidence directory contains unlisted JSON file: source-evidence/unlisted-source-material.json" "$TMP_DIR/ga-release-source-extra.out" || \
  fail "unlisted source evidence failure message did not explain blocker"
pass "GA aggregate rejects unlisted source evidence JSON material"

SOURCE_FORBIDDEN_DIR="$TMP_DIR/source-forbidden-material"
write_fixture_set "$SOURCE_FORBIDDEN_DIR" valid
generate_path_bundles "$SOURCE_FORBIDDEN_DIR" "$TMP_DIR/path-source-forbidden-material"
poison_source_evidence_file_with_digest_refresh "$TMP_DIR/path-source-forbidden-material/online-use-existing" "route-smoke"
if run_ga_release "$SOURCE_FORBIDDEN_DIR" "$TMP_DIR/path-source-forbidden-material" "$TMP_DIR/out-source-forbidden-material" >"$TMP_DIR/ga-release-source-forbidden.out" 2>&1; then
  fail "source evidence file with forbidden local material should fail"
fi
grep -Fq "source evidence file source-evidence/route-smoke-report.json contains forbidden local path or secret-like text" "$TMP_DIR/ga-release-source-forbidden.out" || \
  fail "source evidence forbidden material failure message did not explain blocker"
pass "GA aggregate scans materialized source evidence before acceptance"

SOURCE_SEMANTIC_DIR="$TMP_DIR/source-semantic-render-check"
write_fixture_set "$SOURCE_SEMANTIC_DIR" valid
generate_path_bundles "$SOURCE_SEMANTIC_DIR" "$TMP_DIR/path-source-semantic-render-check"
fake_render_check_source_evidence_with_digest_refresh "$TMP_DIR/path-source-semantic-render-check/online-use-existing"
if run_ga_release "$SOURCE_SEMANTIC_DIR" "$TMP_DIR/path-source-semantic-render-check" "$TMP_DIR/out-source-semantic-render-check" >"$TMP_DIR/ga-release-source-semantic-render.out" 2>&1; then
  fail "schema-shaped source render-check evidence should fail semantic revalidation"
fi
grep -Fq "render-check step report.images[0].image is required" "$TMP_DIR/ga-release-source-semantic-render.out" || \
  fail "source render-check semantic failure message did not explain blocker"
pass "GA aggregate revalidates materialized render-check source semantics"

LEDGER_DIGEST_MISMATCH_DIR="$TMP_DIR/source-ledger-step-digest-mismatch"
write_fixture_set "$LEDGER_DIGEST_MISMATCH_DIR" valid
generate_path_bundles "$LEDGER_DIGEST_MISMATCH_DIR" "$TMP_DIR/path-ledger-digest"
mutate_path_report "$TMP_DIR/path-ledger-digest/online-use-existing/deployment-path-report.json" source-ledger-step-digest-mismatch
if run_ga_release "$LEDGER_DIGEST_MISMATCH_DIR" "$TMP_DIR/path-ledger-digest" "$TMP_DIR/out-source-ledger-step-digest-mismatch" >"$TMP_DIR/ga-release-ledger-digest.out" 2>&1; then
  fail "source ledger step digest mismatch should fail"
fi
grep -Fq "source_evidence.finalized_steps target-preflight report_digest must match steps[]" "$TMP_DIR/ga-release-ledger-digest.out" || \
  fail "source ledger digest mismatch failure message did not explain blocker"
pass "GA aggregate rejects source ledger step digest drift"

MUTABLE_DIR="$TMP_DIR/mutable"
write_fixture_set "$MUTABLE_DIR" mutable-image
generate_path_bundles "$MUTABLE_DIR" "$TMP_DIR/path-mutable"
if run_ga_release "$MUTABLE_DIR" "$TMP_DIR/path-mutable" "$TMP_DIR/out-mutable" >"$TMP_DIR/ga-release-mutable.out" 2>&1; then
  fail "mutable image should fail"
fi
grep -Fq "image must include its digest" "$TMP_DIR/ga-release-mutable.out" || \
  fail "mutable image failure message did not explain blocker"
pass "mutable image fails fast"

INSTALL_DIR="$TMP_DIR/install-confirmation"
write_fixture_set "$INSTALL_DIR" valid
generate_path_bundles "$INSTALL_DIR" "$TMP_DIR/path-install-confirmation"
mutate_path_report "$TMP_DIR/path-install-confirmation/online-install-substrates/deployment-path-report.json" missing-install-confirmation
if run_ga_release "$INSTALL_DIR" "$TMP_DIR/path-install-confirmation" "$TMP_DIR/out-install-confirmation" >"$TMP_DIR/ga-release-install-confirmation.out" 2>&1; then
  fail "missing install confirmation should fail"
fi
grep -Fq "requires explicit install_substrates confirmation" "$TMP_DIR/ga-release-install-confirmation.out" || \
  fail "install confirmation failure message did not explain blocker"
pass "install_substrates confirmation fails fast"

AIRGAP_DIR="$TMP_DIR/airgap-download"
write_fixture_set "$AIRGAP_DIR" valid
generate_path_bundles "$AIRGAP_DIR" "$TMP_DIR/path-airgap-download"
mutate_path_report "$TMP_DIR/path-airgap-download/airgap-use-existing/deployment-path-report.json" airgap-download
if run_ga_release "$AIRGAP_DIR" "$TMP_DIR/path-airgap-download" "$TMP_DIR/out-airgap-download" >"$TMP_DIR/ga-release-airgap-download.out" 2>&1; then
  fail "airgap public download should fail"
fi
grep -Fq "must prove no public internet downloads" "$TMP_DIR/ga-release-airgap-download.out" || \
  fail "airgap offline failure message did not explain blocker"
pass "airgap public download fails fast"

AIRGAP_PREFLIGHT_DIR="$TMP_DIR/airgap-missing-target-preflight"
write_fixture_set "$AIRGAP_PREFLIGHT_DIR" valid
generate_path_bundles "$AIRGAP_PREFLIGHT_DIR" "$TMP_DIR/path-airgap-missing-target-preflight"
mutate_path_report "$TMP_DIR/path-airgap-missing-target-preflight/airgap-use-existing/deployment-path-report.json" airgap-missing-target-preflight
if run_ga_release "$AIRGAP_PREFLIGHT_DIR" "$TMP_DIR/path-airgap-missing-target-preflight" "$TMP_DIR/out-airgap-missing-target-preflight" >"$TMP_DIR/ga-release-airgap-preflight.out" 2>&1; then
  fail "airgap path missing target-preflight should fail"
fi
grep -Fq "deployment path airgap/use_existing missing required step: target-preflight" "$TMP_DIR/ga-release-airgap-preflight.out" || \
  fail "airgap target-preflight failure message did not explain blocker"
pass "GA aggregate requires airgap target-preflight evidence"

PATH_READINESS_DIR="$TMP_DIR/path-readiness-true"
write_fixture_set "$PATH_READINESS_DIR" valid
generate_path_bundles "$PATH_READINESS_DIR" "$TMP_DIR/path-readiness"
mutate_path_report "$TMP_DIR/path-readiness/online-use-existing/deployment-path-report.json" path-readiness-true
if run_ga_release "$PATH_READINESS_DIR" "$TMP_DIR/path-readiness" "$TMP_DIR/out-path-readiness" >"$TMP_DIR/ga-release-path-readiness.out" 2>&1; then
  fail "deployment path readiness=true should fail"
fi
grep -Fq "deployment path report readiness must be false" "$TMP_DIR/ga-release-path-readiness.out" || \
  fail "path readiness failure message did not explain blocker"
pass "GA aggregate requires deployment path readiness=false"

echo "PASS: ga-release aggregate focused guard"
