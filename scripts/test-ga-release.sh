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

function installParametersDigest(
  installInputDigest,
  resourceListDigest,
  applyResourceListDigest,
  effectiveNamespace
) {
  return digest(Buffer.from([
    'agentsmith.substrate-install-parameters/v1',
    `substrate_install_inputs=${installInputDigest}`,
    `resource_list=${resourceListDigest}`,
    `apply_resource_list=${applyResourceListDigest}`,
    `effective_namespace=${effectiveNamespace}`
  ].join('\n')));
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

function inventoryImage(id) {
  const image = contract.deploy_image_inventory.find((entry) => entry.id === id);
  if (!image) {
    throw new Error(`missing deploy image inventory id: ${id}`);
  }
  return image;
}

function imageRepository(image) {
  const withoutDigest = image.split('@sha256:')[0];
  const lastSlash = withoutDigest.lastIndexOf('/');
  const lastColon = withoutDigest.lastIndexOf(':');
  return lastColon > lastSlash ? withoutDigest.slice(0, lastColon) : withoutDigest;
}

function digestPinnedImage(image) {
  return `${imageRepository(image.image)}@${image.digest}`;
}

function sourceRepositoryPath(image) {
  const withoutDigest = image.image.split('@sha256:')[0];
  const lastSlash = withoutDigest.lastIndexOf('/');
  const lastColon = withoutDigest.lastIndexOf(':');
  const withoutTag = lastColon > lastSlash ? withoutDigest.slice(0, lastColon) : withoutDigest;
  const parts = withoutTag.split('/');
  if (parts.length > 1 && (parts[0].includes('.') || parts[0].includes(':') || parts[0] === 'localhost')) {
    return parts.slice(1).join('/');
  }
  return withoutTag;
}

function targetImage(image) {
  return `registry.example.test/agentsmith/${sourceRepositoryPath(image)}@${image.digest}`;
}

const appImage = inventoryImage('agentsmith_app');
const sidecarDigest = `sha256:${'f'.repeat(64)}`;
const renderCheckImageRef =
  mutation === 'render-check-target-registry-mirror'
    ? `registry.example.test/mirror/agentsmith-app@${appImage.digest}`
    : digestPinnedImage(appImage);
const renderCheckMatchedBy =
  mutation === 'render-check-target-registry-mirror' ? 'digest' : 'exact_ref';

function addObservedExtraDigest(summary) {
  summary.status_entries_count += 1;
  summary.image_id_count += 1;
  summary.observed_digests = [...new Set([...summary.observed_digests, sidecarDigest])].sort();
  summary.observed_digest_count = summary.observed_digests.length;
}

function driftRenderCheckDigest(report) {
  const replacementDigest = `sha256:${'b'.repeat(64)}`;
  const replacementImage = (image) => image.replace(/@sha256:[0-9a-f]{64}/, `@${replacementDigest}`);
  for (const image of report.images || []) {
    image.image = replacementImage(image.image);
    image.digest = replacementDigest;
  }
  for (const manifest of report.manifests || []) {
    for (const image of manifest.images || []) {
      image.image = replacementImage(image.image);
      image.digest = replacementDigest;
    }
  }
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
            image: renderCheckImageRef,
            digest: appImage.digest,
            inventory_id: 'agentsmith_app',
            matched_by: renderCheckMatchedBy
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
                image: renderCheckImageRef,
                digest: appImage.digest,
                inventory_id: 'agentsmith_app',
                matched_by: renderCheckMatchedBy
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
            digest: appImage.digest,
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
          observed_digests: [appImage.digest],
          matched_expected_digests: [appImage.digest]
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
                digest: appImage.digest,
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
              observed_digests: [appImage.digest],
              matched_expected_digests: [appImage.digest]
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
  if (mutation === 'render-check-image-digest-legal-drift' && name === 'render-check') {
    driftRenderCheckDigest(report);
  }
  if (mutation === 'rollout-observed-extra-digest' && name === 'rollout') {
    addObservedExtraDigest(report.observed_live_image_digest_summary);
    addObservedExtraDigest(report.workload_summaries[0].observed_live_image_digest_summary);
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
  const mappings = contract.deploy_image_inventory.map((image) => ({
    id: image.id,
    source: image.source,
    source_image: image.image,
    source_digest: image.digest,
    target_image: targetImage(image),
    target_digest: image.digest,
    action: 'mirror_required'
  }));
  fs.mkdirSync(path.join(dir, 'components'), { recursive: true });
  const imageMap = {
    schema: 'agentsmith.image-map/v1',
    scope: 'image_map_only',
    readiness: false,
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile(profile),
    mirror_required: true,
    target_registry: 'registry.example.test/agentsmith',
    release_contract: {
      input_sha256: contractDigest,
      deploy_image_inventory_count: contract.deploy_image_inventory.length
    },
    image_count: mappings.length,
    mappings
  };
  if (mutation === 'airgap-image-map-mirror-required-false') {
    imageMap.mirror_required = false;
    imageMap.mappings = imageMap.mappings.map((mapping) => ({
      ...mapping,
      action: 'use_source'
    }));
  }
  if (mutation === 'airgap-image-map-empty-mappings') {
    imageMap.image_count = 0;
    imageMap.mappings = [];
  }
  writeJson(path.join(dir, imageMapPath), imageMap);
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
  const installInputDigest = sha(`${profile}:substrate-install-inputs`);
  const resourceListDigest = sha(`${profile}:substrate-resource-list`);
  const applyResourceListDigest = sha(`${profile}:apply-resource-list`);
  const effectiveNamespace = 'agentsmith';
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
    namespace: effectiveNamespace,
    mode: 'apply',
    inputs: {
      substrate_pack_manifest: {
        schema_version: 'agentsmith.substrate-pack-manifest/v1',
        input_sha256: sha(`${profile}:substrate-pack-manifest`),
        target_profile: profile,
        release_contract_digest: contractDigest,
        deploy_template_package_digest: templateDigest
      },
      substrate_install_inputs: {
        schema_version: 'agentsmith.substrate-install-inputs/v1',
        input_sha256: installInputDigest,
        resource_source: 'inline',
        resource_list_sha256: resourceListDigest,
        apply_resource_list_sha256: applyResourceListDigest,
        effective_namespace: effectiveNamespace,
        install_parameters_sha256: installParametersDigest(
          installInputDigest,
          resourceListDigest,
          applyResourceListDigest,
          effectiveNamespace
        )
      },
      target_prerequisites: {
        schema_version: 'agentsmith.target-prerequisites.truth/v1',
        input_sha256: sha(`${profile}:target-prerequisites`),
        target_profile: profile,
        namespace: effectiveNamespace
      }
    },
    operator_run_id: operatorRunId,
    substrate_truth_digest: sha(`${profile}:substrate-truth`),
    installed_services: ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc'],
    resource_refs: [
      {
        apiVersion: 'v1',
        group: '',
        kind: 'ConfigMap',
        resource: 'configmaps',
        namespace: effectiveNamespace,
        name: 'agentsmith-substrate-config',
        document_index: 1
      }
    ],
    kubectl_resource_refs: ['configmap/agentsmith-substrate-config'],
    checks: {
      substrate_pack_manifest: 'pass',
      substrate_install_inputs: 'pass',
      target_prerequisites: 'pass',
      namespace_scope: {
        status: 'pass',
        namespace: effectiveNamespace,
        resource_count: 1,
        allowed_resource_count: 1
      },
      collision_guard: {
        status: 'pass',
        checked_resource_count: 1,
        kubectl_get_count: 1,
        not_found_count: 1,
        owned_resource_count: 0
      },
      kubectl_apply: {
        status: 'pass',
        mode: 'apply',
        applied_resource_count: 1,
        kubectl_resource_count: 1,
        command_summary: {
          command: 'kubectl apply --server-side --namespace agentsmith -f <apply-resource-list> -o name',
          server_side: true,
          namespace: effectiveNamespace,
          output: 'name',
          dry_run: 'none'
        }
      }
    },
    summary: {
      release_kit_version: '0.1.0',
      substrate_pack_release_kit_version: '0.1.0',
      installed_by: 'agentsmith-release-kit',
      resources_count: 1,
      substrate_services_count: 5
    },
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

mutate_product_report() {
  local report_file="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$mutation" <<'NODE'
import fs from 'node:fs';

const [reportFile, mutation] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));

if (mutation === 'missing-provenance') {
  delete report.artifact_provenance;
} else if (mutation === 'four-field-provenance') {
  report.artifact_provenance = {
    producer_repo: 'github.com/agentsmith-project/agentsmith',
    commit_sha: report.git_sha,
    run_id: '10001',
    run_attempt: '1'
  };
} else if (mutation === 'missing-schema') {
  delete report.artifact_provenance.schema_version;
} else if (mutation === 'missing-kind') {
  delete report.artifact_provenance.provenance_kind;
} else if (mutation === 'wrong-repo') {
  report.artifact_provenance.producer_repo = 'github.com/example/not-agentsmith';
} else if (mutation === 'wrong-sha') {
  report.artifact_provenance.commit_sha = `${'9'.repeat(40)}`;
} else if (mutation === 'non-iso-generated-at') {
  report.artifact_provenance.generated_at = 'not-an-iso-timestamp';
} else if (mutation === 'missing-artifact-binding') {
  delete report.artifact_provenance.subject_sha256;
  delete report.artifact_provenance.artifact_sha256;
  delete report.artifact_provenance.artifact_uri;
} else if (mutation === 'artifact-uri-only') {
  delete report.artifact_provenance.subject_sha256;
  delete report.artifact_provenance.artifact_sha256;
} else if (mutation === 'encoded-home-artifact-uri') {
  report.artifact_provenance.artifact_uri =
    'gh-artifact://agentsmith/product-readiness/10001/%2Fhome%2Fexample%2Freport.json';
} else if (mutation === 'encoded-tmp-artifact-uri') {
  report.artifact_provenance.artifact_uri =
    'gh-artifact://agentsmith/product-readiness/10001/%2Ftmp%2Fagentsmith%2Freport.json';
} else if (mutation === 'encoded-private-artifact-uri') {
  report.artifact_provenance.artifact_uri =
    'gh-artifact://agentsmith/product-readiness/10001/%2Fprivate%2Ftmp%2Freport.json';
} else if (mutation === 'encoded-kubeconfig-artifact-uri') {
  report.artifact_provenance.artifact_uri =
    'artifact://agentsmith/product-readiness/10001/.kube%2Fconfig';
} else {
  throw new Error(`unknown product report mutation: ${mutation}`);
}

fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`);
NODE
}

mutate_product_smoke_report() {
  mutate_product_report "$@"
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
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile, mutation] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));

function digest(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function installParametersDigest({
  installInputDigest,
  resourceListDigest,
  applyResourceListDigest,
  effectiveNamespace
}) {
  return digest(Buffer.from([
    'agentsmith.substrate-install-parameters/v1',
    `substrate_install_inputs=${installInputDigest}`,
    `resource_list=${resourceListDigest}`,
    `apply_resource_list=${applyResourceListDigest}`,
    `effective_namespace=${effectiveNamespace}`
  ].join('\n')));
}

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
} else if (mutation === 'source-ledger-install-input-digest-mismatch') {
  const install = report.source_evidence.substrate_install;
  install.substrate_install_inputs_sha256 = `sha256:${'7'.repeat(64)}`;
  install.install_parameters_sha256 = installParametersDigest({
    installInputDigest: install.substrate_install_inputs_sha256,
    resourceListDigest: install.resource_list_sha256,
    applyResourceListDigest: install.apply_resource_list_sha256,
    effectiveNamespace: install.effective_namespace
  });
} else if (mutation === 'source-ledger-output-truth-digest-mismatch') {
  report.source_evidence.substrate_install.output_substrate_truth_digest =
    `sha256:${'6'.repeat(64)}`;
} else if (mutation === 'source-ledger-service-count-mismatch') {
  report.source_evidence.substrate_install.service_count += 1;
} else if (mutation === 'source-ledger-apply-digest-missing') {
  delete report.source_evidence.substrate_install.apply_resource_list_sha256;
} else if (mutation === 'source-ledger-target-prerequisites-digest-mismatch') {
  report.source_evidence.substrate_install.target_prerequisites_sha256 =
    `sha256:${'8'.repeat(64)}`;
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

add_unlisted_source_evidence_note() {
  local report_dir="$1"

  "$NODE_BIN" --input-type=module - "$report_dir" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const reportDir = process.argv[2];
fs.writeFileSync(path.join(reportDir, 'source-evidence', 'note.txt'), 'operator note\n');
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
let substrateInstallTargetPrerequisitesDigestOverride;
if (mutation === 'forbidden-local-material') {
  material.operator_note = {
    kubeconfig_path: '/etc/kubernetes/admin.conf'
  };
} else if (mutation === 'schema-shaped-render-check') {
  material.images = [{}];
  material.manifests = [{}];
} else if (mutation === 'render-check-image-digest-legal-drift') {
  const replacementDigest = `sha256:${'a'.repeat(64)}`;
  const replacementImage = (image) => image.replace(/@sha256:[0-9a-f]{64}/, `@${replacementDigest}`);
  for (const image of material.images || []) {
    image.image = replacementImage(image.image);
    image.digest = replacementDigest;
  }
  for (const manifest of material.manifests || []) {
    for (const image of manifest.images || []) {
      image.image = replacementImage(image.image);
      image.digest = replacementDigest;
    }
  }
} else if (mutation === 'substrate-install-missing-input-digests') {
  delete material.inputs;
} else if (mutation === 'substrate-install-missing-kubectl-apply-check') {
  delete material.checks.kubectl_apply;
} else if (mutation === 'substrate-install-kubectl-apply-dry-run-summary') {
  material.checks.kubectl_apply.command_summary.dry_run = 'server';
} else if (mutation === 'substrate-install-kubectl-apply-dry-run-command') {
  material.checks.kubectl_apply.command_summary.command =
    `${material.checks.kubectl_apply.command_summary.command} --dry-run=server`;
} else if (mutation === 'substrate-install-missing-kubectl-resource-refs') {
  delete material.kubectl_resource_refs;
} else if (mutation === 'substrate-install-target-prerequisites-digest-mismatch') {
  substrateInstallTargetPrerequisitesDigestOverride = `sha256:${'b'.repeat(64)}`;
  material.inputs.target_prerequisites.input_sha256 =
    substrateInstallTargetPrerequisitesDigestOverride;
} else if (mutation === 'substrate-install-secret-resource-ref') {
  material.resource_refs[0] = {
    ...material.resource_refs[0],
    apiVersion: 'v1',
    group: '',
    kind: 'Secret',
    resource: 'secrets',
    name: 'agentsmith-substrate-secret'
  };
} else if (mutation === 'substrate-install-resource-ref-namespace-mismatch') {
  material.resource_refs[0].namespace = 'other-ns';
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
if (stepName === 'substrate-install') {
  report.source_evidence.substrate_install.report_digest = materialDigest;
  report.install_substrates_confirmation.substrate_install_report_digest = materialDigest;
  if (substrateInstallTargetPrerequisitesDigestOverride) {
    report.source_evidence.substrate_install.target_prerequisites_sha256 =
      substrateInstallTargetPrerequisitesDigestOverride;
  }
}
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

drift_render_check_image_digest_with_digest_refresh() {
  mutate_source_evidence_file_with_digest_refresh "$1" render-check render-check-image-digest-legal-drift
}

mutate_airgap_image_map_source_evidence_with_digest_refresh() {
  local report_dir="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$report_dir" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [reportDir, mutation] = process.argv.slice(2);
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

function manifestEntry(kind, step) {
  const entry = manifest.source_evidence_files.find(
    (item) => item.kind === kind && (step === undefined || item.step === step)
  );
  if (!entry) {
    throw new Error(`missing source evidence entry: ${kind}${step ? `/${step}` : ''}`);
  }
  return entry;
}

function materialFor(entry) {
  const file = path.join(reportDir, entry.path);
  return {
    file,
    value: JSON.parse(fs.readFileSync(file, 'utf8'))
  };
}

function updateStepDigest(stepName, materialDigest) {
  const pathStep = report.steps.find((step) => step.name === stepName);
  const ledgerStep = report.source_evidence.finalized_steps.find((step) => step.name === stepName);
  if (!pathStep || !ledgerStep) {
    throw new Error(`missing deployment path step for ${stepName}`);
  }
  pathStep.report_digest = materialDigest;
  ledgerStep.report_digest = materialDigest;
}

function refreshMaterial(entry, value) {
  const file = path.join(reportDir, entry.path);
  writeJson(file, value);
  entry.sha256 = digest(file);
  return entry.sha256;
}

const imageMapEntry = manifestEntry('airgap_image_map');
const imageMapMaterial = materialFor(imageMapEntry);
if (mutation === 'empty-mappings') {
  imageMapMaterial.value.image_count = 0;
  imageMapMaterial.value.mappings = [];
} else if (mutation === 'mirror-required-false') {
  imageMapMaterial.value.mirror_required = false;
  imageMapMaterial.value.mappings = imageMapMaterial.value.mappings.map((mapping) => ({
    ...mapping,
    action: 'use_source'
  }));
} else {
  throw new Error(`unknown airgap image-map source evidence mutation: ${mutation}`);
}
const imageMapDigest = refreshMaterial(imageMapEntry, imageMapMaterial.value);
report.source_evidence.airgap.image_map_input_sha256 = imageMapDigest;

const bundleManifestEntry = manifestEntry('airgap_bundle_manifest');
const bundleManifestMaterial = materialFor(bundleManifestEntry);
if (bundleManifestMaterial.value.bindings?.image_map_sha256 !== undefined) {
  bundleManifestMaterial.value.bindings.image_map_sha256 = imageMapDigest;
}
const imageMapComponent = bundleManifestMaterial.value.components.find(
  (component) => component.kind === 'image_map'
);
if (!imageMapComponent) {
  throw new Error('missing image_map component in airgap bundle manifest material');
}
imageMapComponent.sha256 = imageMapDigest;
const bundleManifestDigest = refreshMaterial(bundleManifestEntry, bundleManifestMaterial.value);
report.source_evidence.airgap.bundle_manifest_digest = bundleManifestDigest;
report.airgap_offline.bundle_manifest_digest = bundleManifestDigest;

const bundleCheckEntry = manifestEntry('finalized_step_report', 'bundle-check');
const bundleCheckMaterial = materialFor(bundleCheckEntry);
bundleCheckMaterial.value.artifacts.image_map.input_sha256 = imageMapDigest;
bundleCheckMaterial.value.artifacts.bundle_manifest.input_sha256 = bundleManifestDigest;
const bundleCheckDigest = refreshMaterial(bundleCheckEntry, bundleCheckMaterial.value);
updateStepDigest('bundle-check', bundleCheckDigest);
report.source_evidence.airgap.bundle_check_report_digest = bundleCheckDigest;

const imageLoadEntry = manifestEntry('finalized_step_report', 'image-load');
const imageLoadMaterial = materialFor(imageLoadEntry);
imageLoadMaterial.value.digest_summary.image_map_input_sha256 = imageMapDigest;
imageLoadMaterial.value.digest_summary.bundle_manifest_input_sha256 = bundleManifestDigest;
imageLoadMaterial.value.digest_summary.airgap_bundle_check_report_input_sha256 = bundleCheckDigest;
const imageLoadDigest = refreshMaterial(imageLoadEntry, imageLoadMaterial.value);
updateStepDigest('image-load', imageLoadDigest);
report.airgap_offline.image_load_report_digest = imageLoadDigest;

const offlineRenderEntry = manifestEntry('finalized_step_report', 'offline-render-check');
const offlineRenderMaterial = materialFor(offlineRenderEntry);
offlineRenderMaterial.value.digest_summary.image_map_input_sha256 = imageMapDigest;
offlineRenderMaterial.value.digest_summary.bundle_manifest_input_sha256 = bundleManifestDigest;
offlineRenderMaterial.value.digest_summary.airgap_bundle_check_report_input_sha256 = bundleCheckDigest;
const offlineRenderDigest = refreshMaterial(offlineRenderEntry, offlineRenderMaterial.value);
updateStepDigest('offline-render-check', offlineRenderDigest);
report.airgap_offline.offline_render_report_digest = offlineRenderDigest;

writeJson(reportFile, report);
manifest.path_report_sha256 = digest(reportFile);
writeJson(manifestFile, manifest);
NODE
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

MIRROR_RENDER_DIR="$TMP_DIR/render-check-target-registry-mirror"
write_fixture_set "$MIRROR_RENDER_DIR" render-check-target-registry-mirror
generate_path_bundles "$MIRROR_RENDER_DIR" "$TMP_DIR/path-render-check-target-registry-mirror"
run_ga_release "$MIRROR_RENDER_DIR" "$TMP_DIR/path-render-check-target-registry-mirror" "$TMP_DIR/out-render-check-target-registry-mirror"
pass "GA aggregate accepts render-check same inventory digest from target registry mirror"

ROLLOUT_EXTRA_DIGEST_DIR="$TMP_DIR/rollout-observed-extra-digest"
write_fixture_set "$ROLLOUT_EXTRA_DIGEST_DIR" rollout-observed-extra-digest
generate_path_bundles "$ROLLOUT_EXTRA_DIGEST_DIR" "$TMP_DIR/path-rollout-observed-extra-digest"
run_ga_release "$ROLLOUT_EXTRA_DIGEST_DIR" "$TMP_DIR/path-rollout-observed-extra-digest" "$TMP_DIR/out-rollout-observed-extra-digest"
pass "GA aggregate allows rollout observed sidecar digest extras"

product_report_cases=(
  "product-readiness-report.json|product_readiness_report.artifact_provenance|product readiness"
  "post-deploy-product-smoke-report.json|post_deploy_product_smoke.artifact_provenance|post-deploy product smoke"
)
product_provenance_mutations=(
  missing-provenance
  four-field-provenance
  missing-schema
  missing-kind
  wrong-repo
  wrong-sha
  non-iso-generated-at
  missing-artifact-binding
  encoded-home-artifact-uri
  encoded-tmp-artifact-uri
  encoded-private-artifact-uri
  encoded-kubeconfig-artifact-uri
)
for report_case in "${product_report_cases[@]}"; do
  IFS='|' read -r report_file provenance_label report_label <<< "$report_case"
  PRODUCT_URI_ONLY_DIR="$TMP_DIR/${report_file%.json}-artifact-uri-only"
  write_fixture_set "$PRODUCT_URI_ONLY_DIR" valid
  mutate_product_report "$PRODUCT_URI_ONLY_DIR/$report_file" artifact-uri-only
  run_ga_release "$PRODUCT_URI_ONLY_DIR" "$PATH_DIR" "$TMP_DIR/out-${report_file%.json}-artifact-uri-only"
  for mutation in "${product_provenance_mutations[@]}"; do
    PRODUCT_PROVENANCE_DIR="$TMP_DIR/${report_file%.json}-$mutation"
    write_fixture_set "$PRODUCT_PROVENANCE_DIR" valid
    mutate_product_report "$PRODUCT_PROVENANCE_DIR/$report_file" "$mutation"
    if run_ga_release "$PRODUCT_PROVENANCE_DIR" "$PATH_DIR" "$TMP_DIR/out-${report_file%.json}-$mutation" >"$TMP_DIR/ga-release-${report_file%.json}-$mutation.out" 2>&1; then
      fail "$report_label $mutation should fail"
    fi
    case "$mutation" in
      missing-provenance)
        expected_message="$provenance_label must be an object"
        ;;
      four-field-provenance|missing-schema)
        expected_message="$provenance_label.schema_version is required"
        ;;
      missing-kind)
        expected_message="$provenance_label.provenance_kind is required"
        ;;
      wrong-repo)
        expected_message="$provenance_label.producer_repo must match $provenance_label.normalized_remote"
        ;;
      wrong-sha)
        expected_message="$report_label provenance must match AgentSmith repo and git sha"
        ;;
      non-iso-generated-at)
        expected_message="$provenance_label.generated_at must be an ISO timestamp"
        ;;
      missing-artifact-binding)
        expected_message="$provenance_label must include subject_sha256, artifact_sha256, or artifact_uri"
        ;;
      encoded-home-artifact-uri|encoded-tmp-artifact-uri|encoded-private-artifact-uri|encoded-kubeconfig-artifact-uri)
        expected_message="input report contains forbidden local path or secret-like text"
        ;;
      *)
        fail "missing expected message for product provenance mutation: $mutation"
        ;;
    esac
    grep -Fq "$expected_message" "$TMP_DIR/ga-release-${report_file%.json}-$mutation.out" || \
      fail "$report_label $mutation failure message did not explain blocker"
  done
done
pass "GA aggregate requires full product readiness and product smoke provenance shape"
pass "GA aggregate accepts product artifact_uri as the sole artifact binding"

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
grep -Fq "source evidence directory contains unlisted file: source-evidence/unlisted-source-material.json" "$TMP_DIR/ga-release-source-extra.out" || \
  fail "unlisted source evidence failure message did not explain blocker"
pass "GA aggregate rejects unlisted source evidence JSON material"

SOURCE_EXTRA_NOTE_DIR="$TMP_DIR/source-extra-note"
write_fixture_set "$SOURCE_EXTRA_NOTE_DIR" valid
generate_path_bundles "$SOURCE_EXTRA_NOTE_DIR" "$TMP_DIR/path-source-extra-note"
add_unlisted_source_evidence_note "$TMP_DIR/path-source-extra-note/online-use-existing"
if run_ga_release "$SOURCE_EXTRA_NOTE_DIR" "$TMP_DIR/path-source-extra-note" "$TMP_DIR/out-source-extra-note" >"$TMP_DIR/ga-release-source-extra-note.out" 2>&1; then
  fail "unlisted source evidence note should fail"
fi
grep -Fq "source evidence directory contains unlisted file: source-evidence/note.txt" "$TMP_DIR/ga-release-source-extra-note.out" || \
  fail "unlisted source evidence note failure message did not explain blocker"
pass "GA aggregate rejects unlisted non-JSON source evidence material"

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

SOURCE_SUBSTRATE_INPUT_DIGESTS_DIR="$TMP_DIR/source-substrate-install-input-digests"
write_fixture_set "$SOURCE_SUBSTRATE_INPUT_DIGESTS_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_INPUT_DIGESTS_DIR" "$TMP_DIR/path-source-substrate-install-input-digests"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-input-digests/online-install-substrates" \
  substrate-install \
  substrate-install-missing-input-digests
if run_ga_release "$SOURCE_SUBSTRATE_INPUT_DIGESTS_DIR" "$TMP_DIR/path-source-substrate-install-input-digests" "$TMP_DIR/out-source-substrate-install-input-digests" >"$TMP_DIR/ga-release-source-substrate-install-input-digests.out" 2>&1; then
  fail "substrate install source evidence without input digests should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.inputs must be an object" "$TMP_DIR/ga-release-source-substrate-install-input-digests.out" || \
  fail "source substrate install input digest failure message did not explain blocker"
pass "GA aggregate revalidates materialized substrate install input digest bindings"

SOURCE_SUBSTRATE_KUBECTL_APPLY_DIR="$TMP_DIR/source-substrate-install-kubectl-apply"
write_fixture_set "$SOURCE_SUBSTRATE_KUBECTL_APPLY_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_KUBECTL_APPLY_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-apply"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-kubectl-apply/online-install-substrates" \
  substrate-install \
  substrate-install-missing-kubectl-apply-check
if run_ga_release "$SOURCE_SUBSTRATE_KUBECTL_APPLY_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-apply" "$TMP_DIR/out-source-substrate-install-kubectl-apply" >"$TMP_DIR/ga-release-source-substrate-install-kubectl-apply.out" 2>&1; then
  fail "digest-refreshed substrate install source evidence without kubectl apply proof should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.checks.kubectl_apply must be an object" "$TMP_DIR/ga-release-source-substrate-install-kubectl-apply.out" || \
  fail "source substrate install kubectl apply proof failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-kubectl-apply.out"; then
  fail "source substrate install kubectl apply negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate revalidates digest-refreshed substrate install kubectl apply proof"

SOURCE_SUBSTRATE_DRY_RUN_SUMMARY_DIR="$TMP_DIR/source-substrate-install-kubectl-apply-dry-run-summary"
write_fixture_set "$SOURCE_SUBSTRATE_DRY_RUN_SUMMARY_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_DRY_RUN_SUMMARY_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-apply-dry-run-summary"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-kubectl-apply-dry-run-summary/online-install-substrates" \
  substrate-install \
  substrate-install-kubectl-apply-dry-run-summary
if run_ga_release "$SOURCE_SUBSTRATE_DRY_RUN_SUMMARY_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-apply-dry-run-summary" "$TMP_DIR/out-source-substrate-install-kubectl-apply-dry-run-summary" >"$TMP_DIR/ga-release-source-substrate-install-kubectl-apply-dry-run-summary.out" 2>&1; then
  fail "digest-refreshed apply-mode substrate install source evidence with dry_run server should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.checks.kubectl_apply.command_summary.dry_run must be none for apply" "$TMP_DIR/ga-release-source-substrate-install-kubectl-apply-dry-run-summary.out" || \
  fail "source substrate install apply dry_run summary failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-kubectl-apply-dry-run-summary.out"; then
  fail "source substrate install dry_run summary negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate rejects digest-refreshed apply-mode installer proof with dry_run server"

SOURCE_SUBSTRATE_DRY_RUN_COMMAND_DIR="$TMP_DIR/source-substrate-install-kubectl-apply-dry-run-command"
write_fixture_set "$SOURCE_SUBSTRATE_DRY_RUN_COMMAND_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_DRY_RUN_COMMAND_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-apply-dry-run-command"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-kubectl-apply-dry-run-command/online-install-substrates" \
  substrate-install \
  substrate-install-kubectl-apply-dry-run-command
if run_ga_release "$SOURCE_SUBSTRATE_DRY_RUN_COMMAND_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-apply-dry-run-command" "$TMP_DIR/out-source-substrate-install-kubectl-apply-dry-run-command" >"$TMP_DIR/ga-release-source-substrate-install-kubectl-apply-dry-run-command.out" 2>&1; then
  fail "digest-refreshed apply-mode substrate install source evidence with --dry-run command should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.checks.kubectl_apply.command_summary.command must not include --dry-run for apply" "$TMP_DIR/ga-release-source-substrate-install-kubectl-apply-dry-run-command.out" || \
  fail "source substrate install apply dry-run command failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-kubectl-apply-dry-run-command.out"; then
  fail "source substrate install dry-run command negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate rejects digest-refreshed apply-mode installer proof whose command dry-runs"

SOURCE_SUBSTRATE_KUBECTL_REFS_DIR="$TMP_DIR/source-substrate-install-kubectl-refs"
write_fixture_set "$SOURCE_SUBSTRATE_KUBECTL_REFS_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_KUBECTL_REFS_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-refs"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-kubectl-refs/online-install-substrates" \
  substrate-install \
  substrate-install-missing-kubectl-resource-refs
if run_ga_release "$SOURCE_SUBSTRATE_KUBECTL_REFS_DIR" "$TMP_DIR/path-source-substrate-install-kubectl-refs" "$TMP_DIR/out-source-substrate-install-kubectl-refs" >"$TMP_DIR/ga-release-source-substrate-install-kubectl-refs.out" 2>&1; then
  fail "digest-refreshed substrate install source evidence without kubectl resource refs should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.kubectl_resource_refs must be an array" "$TMP_DIR/ga-release-source-substrate-install-kubectl-refs.out" || \
  fail "source substrate install kubectl refs failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-kubectl-refs.out"; then
  fail "source substrate install kubectl refs negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate revalidates digest-refreshed substrate install kubectl resource refs"

SOURCE_SUBSTRATE_TARGET_PREREQ_DIR="$TMP_DIR/source-substrate-install-target-prerequisites"
write_fixture_set "$SOURCE_SUBSTRATE_TARGET_PREREQ_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_TARGET_PREREQ_DIR" "$TMP_DIR/path-source-substrate-install-target-prerequisites"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-target-prerequisites/online-install-substrates" \
  substrate-install \
  substrate-install-target-prerequisites-digest-mismatch
if run_ga_release "$SOURCE_SUBSTRATE_TARGET_PREREQ_DIR" "$TMP_DIR/path-source-substrate-install-target-prerequisites" "$TMP_DIR/out-source-substrate-install-target-prerequisites" >"$TMP_DIR/ga-release-source-substrate-install-target-prerequisites.out" 2>&1; then
  fail "digest-refreshed substrate install source evidence with target prerequisites digest drift should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.inputs.target_prerequisites.input_sha256 must match target-preflight step report.target_prerequisites.input_sha256" "$TMP_DIR/ga-release-source-substrate-install-target-prerequisites.out" || \
  fail "source substrate install target prerequisites digest failure message did not explain blocker"
if grep -Fq "finalizer_manifest.source_evidence_files substrate-install sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-target-prerequisites.out"; then
  fail "source substrate install target prerequisites negative hit finalizer digest mismatch instead of semantic validation"
fi
pass "GA aggregate cross-checks digest-refreshed installer target prerequisites against target preflight"

SOURCE_SUBSTRATE_RESOURCE_KIND_DIR="$TMP_DIR/source-substrate-install-resource-kind"
write_fixture_set "$SOURCE_SUBSTRATE_RESOURCE_KIND_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_RESOURCE_KIND_DIR" "$TMP_DIR/path-source-substrate-install-resource-kind"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-resource-kind/online-install-substrates" \
  substrate-install \
  substrate-install-secret-resource-ref
if run_ga_release "$SOURCE_SUBSTRATE_RESOURCE_KIND_DIR" "$TMP_DIR/path-source-substrate-install-resource-kind" "$TMP_DIR/out-source-substrate-install-resource-kind" >"$TMP_DIR/ga-release-source-substrate-install-resource-kind.out" 2>&1; then
  fail "digest-refreshed substrate install source evidence with Secret resource_ref should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.resource_refs[0].kind Secret is not allowed for substrate install" "$TMP_DIR/ga-release-source-substrate-install-resource-kind.out" || \
  fail "source substrate install resource kind failure message did not explain allowlist blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-resource-kind.out"; then
  fail "source substrate install resource kind negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate revalidates digest-refreshed installer resource_refs kind allowlist"

SOURCE_SUBSTRATE_RESOURCE_NAMESPACE_DIR="$TMP_DIR/source-substrate-install-resource-namespace"
write_fixture_set "$SOURCE_SUBSTRATE_RESOURCE_NAMESPACE_DIR" valid
generate_path_bundles "$SOURCE_SUBSTRATE_RESOURCE_NAMESPACE_DIR" "$TMP_DIR/path-source-substrate-install-resource-namespace"
mutate_source_evidence_file_with_digest_refresh \
  "$TMP_DIR/path-source-substrate-install-resource-namespace/online-install-substrates" \
  substrate-install \
  substrate-install-resource-ref-namespace-mismatch
if run_ga_release "$SOURCE_SUBSTRATE_RESOURCE_NAMESPACE_DIR" "$TMP_DIR/path-source-substrate-install-resource-namespace" "$TMP_DIR/out-source-substrate-install-resource-namespace" >"$TMP_DIR/ga-release-source-substrate-install-resource-namespace.out" 2>&1; then
  fail "digest-refreshed substrate install source evidence with resource_ref namespace drift should fail semantic revalidation"
fi
grep -Fq "substrate_install_report.resource_refs[0].namespace must match substrate install effective namespace" "$TMP_DIR/ga-release-source-substrate-install-resource-namespace.out" || \
  fail "source substrate install resource namespace failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-substrate-install-resource-namespace.out"; then
  fail "source substrate install resource namespace negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate revalidates digest-refreshed installer resource_refs namespace"

SOURCE_IMAGE_CLOSURE_DIR="$TMP_DIR/source-image-closure-digest-refresh"
write_fixture_set "$SOURCE_IMAGE_CLOSURE_DIR" valid
generate_path_bundles "$SOURCE_IMAGE_CLOSURE_DIR" "$TMP_DIR/path-source-image-closure"
drift_render_check_image_digest_with_digest_refresh "$TMP_DIR/path-source-image-closure/online-use-existing"
if run_ga_release "$SOURCE_IMAGE_CLOSURE_DIR" "$TMP_DIR/path-source-image-closure" "$TMP_DIR/out-source-image-closure" >"$TMP_DIR/ga-release-source-image-closure.out" 2>&1; then
  fail "source render-check image digest closure drift should fail"
fi
grep -Fq "render-check step report.images[0].digest must match release contract deploy_image_inventory digest for inventory_id agentsmith_app" "$TMP_DIR/ga-release-source-image-closure.out" || \
  fail "source render-check image closure failure message did not explain blocker"
pass "GA aggregate rejects digest-refreshed source image closure drift"

AIRGAP_IMAGE_MAP_SOURCE_DIR="$TMP_DIR/source-airgap-image-map-empty-mappings"
write_fixture_set "$AIRGAP_IMAGE_MAP_SOURCE_DIR" valid
generate_path_bundles "$AIRGAP_IMAGE_MAP_SOURCE_DIR" "$TMP_DIR/path-source-airgap-image-map-empty"
mutate_airgap_image_map_source_evidence_with_digest_refresh \
  "$TMP_DIR/path-source-airgap-image-map-empty/airgap-use-existing" \
  empty-mappings
if run_ga_release "$AIRGAP_IMAGE_MAP_SOURCE_DIR" "$TMP_DIR/path-source-airgap-image-map-empty" "$TMP_DIR/out-source-airgap-image-map-empty" >"$TMP_DIR/ga-release-source-airgap-image-map-empty.out" 2>&1; then
  fail "digest-refreshed airgap source image-map with empty mappings should fail semantic revalidation"
fi
grep -Fq "airgap image map.mappings must not be empty" "$TMP_DIR/ga-release-source-airgap-image-map-empty.out" || \
  { cat "$TMP_DIR/ga-release-source-airgap-image-map-empty.out" >&2; fail "airgap source image-map semantic failure message did not explain blocker"; }
if grep -Fq "sha256 must match" "$TMP_DIR/ga-release-source-airgap-image-map-empty.out"; then
  fail "airgap source image-map negative hit digest mismatch instead of semantic validation"
fi
pass "GA aggregate revalidates digest-refreshed airgap source image-map semantics"

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

LEDGER_APPLY_DIGEST_MISSING_DIR="$TMP_DIR/source-ledger-apply-digest-missing"
write_fixture_set "$LEDGER_APPLY_DIGEST_MISSING_DIR" valid
generate_path_bundles "$LEDGER_APPLY_DIGEST_MISSING_DIR" "$TMP_DIR/path-ledger-apply-digest-missing"
mutate_path_report \
  "$TMP_DIR/path-ledger-apply-digest-missing/online-install-substrates/deployment-path-report.json" \
  source-ledger-apply-digest-missing
if run_ga_release "$LEDGER_APPLY_DIGEST_MISSING_DIR" "$TMP_DIR/path-ledger-apply-digest-missing" "$TMP_DIR/out-source-ledger-apply-digest-missing" >"$TMP_DIR/ga-release-ledger-apply-digest-missing.out" 2>&1; then
  fail "source ledger missing substrate apply artifact digest should fail"
fi
grep -Fq "source_evidence.substrate_install.apply_resource_list_sha256 is required" "$TMP_DIR/ga-release-ledger-apply-digest-missing.out" || \
  fail "source ledger apply artifact digest missing failure message did not explain blocker"
pass "GA aggregate requires source ledger substrate apply artifact digest"

LEDGER_TARGET_PREREQUISITES_MISMATCH_DIR="$TMP_DIR/source-ledger-target-prerequisites-digest-mismatch"
write_fixture_set "$LEDGER_TARGET_PREREQUISITES_MISMATCH_DIR" valid
generate_path_bundles "$LEDGER_TARGET_PREREQUISITES_MISMATCH_DIR" "$TMP_DIR/path-ledger-target-prerequisites-digest"
mutate_path_report \
  "$TMP_DIR/path-ledger-target-prerequisites-digest/online-install-substrates/deployment-path-report.json" \
  source-ledger-target-prerequisites-digest-mismatch
if run_ga_release "$LEDGER_TARGET_PREREQUISITES_MISMATCH_DIR" "$TMP_DIR/path-ledger-target-prerequisites-digest" "$TMP_DIR/out-source-ledger-target-prerequisites-digest-mismatch" >"$TMP_DIR/ga-release-ledger-target-prerequisites-digest.out" 2>&1; then
  fail "fake substrate target prerequisites digest in source ledger should fail"
fi
grep -Fq "source_evidence.substrate_install.target_prerequisites_sha256 must match materialized substrate install report" "$TMP_DIR/ga-release-ledger-target-prerequisites-digest.out" || \
  fail "source ledger substrate target prerequisites digest mismatch failure message did not explain blocker"
pass "GA aggregate compares source ledger target prerequisites digest with materialized installer report"

LEDGER_INSTALL_INPUT_MISMATCH_DIR="$TMP_DIR/source-ledger-install-input-digest-mismatch"
write_fixture_set "$LEDGER_INSTALL_INPUT_MISMATCH_DIR" valid
generate_path_bundles "$LEDGER_INSTALL_INPUT_MISMATCH_DIR" "$TMP_DIR/path-ledger-install-input-digest"
mutate_path_report \
  "$TMP_DIR/path-ledger-install-input-digest/online-install-substrates/deployment-path-report.json" \
  source-ledger-install-input-digest-mismatch
if run_ga_release "$LEDGER_INSTALL_INPUT_MISMATCH_DIR" "$TMP_DIR/path-ledger-install-input-digest" "$TMP_DIR/out-source-ledger-install-input-digest-mismatch" >"$TMP_DIR/ga-release-ledger-install-input-digest.out" 2>&1; then
  fail "digest-refreshed fake substrate install input digest in source ledger should fail"
fi
grep -Fq "source_evidence.substrate_install.substrate_install_inputs_sha256 must match materialized substrate install report" "$TMP_DIR/ga-release-ledger-install-input-digest.out" || \
  fail "source ledger substrate install digest mismatch failure message did not explain blocker"
pass "GA aggregate compares source ledger substrate install digests with materialized installer report"

LEDGER_OUTPUT_TRUTH_MISMATCH_DIR="$TMP_DIR/source-ledger-output-truth-digest-mismatch"
write_fixture_set "$LEDGER_OUTPUT_TRUTH_MISMATCH_DIR" valid
generate_path_bundles "$LEDGER_OUTPUT_TRUTH_MISMATCH_DIR" "$TMP_DIR/path-ledger-output-truth-digest"
mutate_path_report \
  "$TMP_DIR/path-ledger-output-truth-digest/online-install-substrates/deployment-path-report.json" \
  source-ledger-output-truth-digest-mismatch
if run_ga_release "$LEDGER_OUTPUT_TRUTH_MISMATCH_DIR" "$TMP_DIR/path-ledger-output-truth-digest" "$TMP_DIR/out-source-ledger-output-truth-digest-mismatch" >"$TMP_DIR/ga-release-ledger-output-truth-digest.out" 2>&1; then
  fail "digest-refreshed fake substrate output truth digest in source ledger should fail"
fi
grep -Fq "source_evidence.substrate_install.output_substrate_truth_digest must match materialized substrate install report" "$TMP_DIR/ga-release-ledger-output-truth-digest.out" || \
  fail "source ledger substrate output truth digest mismatch failure message did not explain blocker"
pass "GA aggregate compares source ledger substrate truth digest with materialized installer report"

LEDGER_SERVICE_COUNT_MISMATCH_DIR="$TMP_DIR/source-ledger-service-count-mismatch"
write_fixture_set "$LEDGER_SERVICE_COUNT_MISMATCH_DIR" valid
generate_path_bundles "$LEDGER_SERVICE_COUNT_MISMATCH_DIR" "$TMP_DIR/path-ledger-service-count"
mutate_path_report \
  "$TMP_DIR/path-ledger-service-count/online-install-substrates/deployment-path-report.json" \
  source-ledger-service-count-mismatch
if run_ga_release "$LEDGER_SERVICE_COUNT_MISMATCH_DIR" "$TMP_DIR/path-ledger-service-count" "$TMP_DIR/out-source-ledger-service-count-mismatch" >"$TMP_DIR/ga-release-ledger-service-count.out" 2>&1; then
  fail "digest-refreshed fake substrate service_count in source ledger should fail"
fi
grep -Fq "source_evidence.substrate_install.service_count must match materialized substrate install report" "$TMP_DIR/ga-release-ledger-service-count.out" || \
  fail "source ledger substrate service_count mismatch failure message did not explain blocker"
pass "GA aggregate compares source ledger substrate service_count with materialized installer report"

MUTABLE_DIR="$TMP_DIR/mutable"
write_fixture_set "$MUTABLE_DIR" mutable-image
if run_ga_release "$MUTABLE_DIR" "$PATH_DIR" "$TMP_DIR/out-mutable" >"$TMP_DIR/ga-release-mutable.out" 2>&1; then
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
