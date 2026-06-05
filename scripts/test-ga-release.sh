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
if (evidenceIndex.source_report?.path !== 'ga-release-report.json') {
  throw new Error('evidence index must point at ga-release-report.json');
}
if (evidenceIndex.source_report?.digest !== canonicalDigest(report)) {
  throw new Error('evidence index source_report digest must bind the failure report');
}
if (
  evidenceIndex.source_report?.status !== report.status ||
  evidenceIndex.source_report?.formal_verdict !== report.formal_verdict
) {
  throw new Error('evidence index must mirror the failure report status/verdict');
}
if (!Array.isArray(evidenceIndex.blockers) || !evidenceIndex.blockers.some((entry) => String(entry.message || '').includes(expectedMessage))) {
  throw new Error('evidence index must carry the failure blockers from the source report');
}
NODE
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
    output_substrate_truth_path: 'substrate-truth.json',
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
    run_url: 'https://github.com/agentsmith-project/agentsmith/actions/runs/10001/attempts/1',
    job: subjectName,
    artifact_uri: `gh-artifact://agentsmith/${subjectName}/10001/${subjectName}.json`,
    artifact_sha256: sha(`${subjectName}:artifact`),
    generated_at: '2026-05-31T12:00:00.000Z',
    generator_command: 'focused fixture',
    generator_version: 'test',
    attestation: 'none'
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
      source_evidence_sha256: sha(`product-smoke:${spec.source_flow}`)
    }
  ]));
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
  schema_version: 'agentsmith.post-deploy-product-smoke-report/v1',
  producer: 'agentsmith-post-deploy-product-smoke',
  owner: 'agentsmith',
  repo: 'github.com/agentsmith-project/agentsmith',
  release_contract: {
    path: 'release-contract.json',
    input_sha256: contractDigest,
    release_id: contract.release_id,
    git_sha: contract.git_sha
  },
  status: 'passed',
  generated_at: '2026-05-31T12:00:00.000Z',
  source: {
    product_flows_path: 'unified-deploy/product-flows/product-flows-aggregate.json',
    product_flows_sha256: sha('post-deploy-product-smoke:product-flows'),
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
      sha256: sha('post-deploy-product-smoke:site-env')
    },
    substrate_truth: {
      path: 'unified-deploy/substrate-truth.json',
      sha256: sha('post-deploy-product-smoke:substrate-truth')
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

write_operator_inputs_plan_set() {
  local fixture_dir="$1"
  local plan_dir="$2"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$fixture_dir" "$plan_dir" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [fixtureDir, planDir, mutation] = process.argv.slice(2);
const deploymentPaths = [
  'online/use_existing',
  'online/install_substrates',
  'airgap/use_existing',
  'airgap/install_substrates'
];
const wrongDigest = `sha256:${'0'.repeat(64)}`;

function digest(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

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
  return digest(Buffer.from(JSON.stringify(stableJson(value))));
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function copyMaterial(source, target) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
}

function fileDigest(file) {
  return digest(fs.readFileSync(file));
}

function slug(operatorPath) {
  return operatorPath.replace(/[/_]+/g, '-');
}

for (const operatorPath of deploymentPaths) {
  const packageRoot = path.resolve(planDir, slug(operatorPath));
  fs.mkdirSync(packageRoot, { recursive: true });
  const manifestPath = path.join(packageRoot, 'operator-inputs.json');
  const releaseContractPath = path.join(packageRoot, 'release-contract.json');
  const deployTemplatePackagePath = path.join(packageRoot, 'deploy-template-package.json');

  copyMaterial(path.join(fixtureDir, 'release-contract.json'), releaseContractPath);
  copyMaterial(path.join(fixtureDir, 'deploy-template-package.json'), deployTemplatePackagePath);

  const manifest = {
    schema_version: 'agentsmith.operator-inputs/v1',
    operator_inputs_version: 1,
    deployment_path: operatorPath
  };
  writeJson(manifestPath, manifest);

  const releaseContractDigest = fileDigest(releaseContractPath);
  const plan = {
    schema_version: 'agentsmith.operator-inputs-plan/v1',
    scope: 'operator_inputs_intake_only',
    status: 'pass',
    repo_root: path.resolve(fixtureDir, '..'),
    operator_inputs_root: packageRoot,
    argv_path_mode: 'absolute',
    deployment_path: operatorPath,
    mode: 'apply',
    package: {
      manifest_path: manifestPath,
      manifest_relative_path: 'operator-inputs.json',
      manifest_sha256: fileDigest(manifestPath)
    },
    input_refs: {
      release_contract: {
        kind: 'file',
        path: 'release-contract.json',
        absolute_path: releaseContractPath,
        sha256: mutation === 'stale-release-contract-ref'
          ? wrongDigest
          : releaseContractDigest
      },
      deploy_template_package: {
        kind: 'file',
        path: 'deploy-template-package.json',
        absolute_path: deployTemplatePackagePath,
        sha256: fileDigest(deployTemplatePackagePath)
      }
    },
    plan_sha256: null
  };
  plan.plan_sha256 = canonicalDigest({ ...plan, plan_sha256: null });
  writeJson(path.join(packageRoot, '.release-kit-internal/operator-inputs-plan.json'), plan);
}
NODE
}

run_ga_release_with_operator_plans() {
  local fixture_dir="$1"
  local path_dir="$2"
  local plan_dir="$3"
  local output_dir="$4"

  bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
    --release-contract "$fixture_dir/release-contract.json" \
    --deploy-template-package "$fixture_dir/deploy-template-package.json" \
    --deployment-path-report "$path_dir/online-use-existing/deployment-path-report.json" \
    --deployment-path-report "$path_dir/online-install-substrates/deployment-path-report.json" \
    --deployment-path-report "$path_dir/airgap-use-existing/deployment-path-report.json" \
    --deployment-path-report "$path_dir/airgap-install-substrates/deployment-path-report.json" \
    --operator-inputs-plan "$plan_dir/online-use-existing/.release-kit-internal/operator-inputs-plan.json" \
    --operator-inputs-plan "$plan_dir/online-install-substrates/.release-kit-internal/operator-inputs-plan.json" \
    --operator-inputs-plan "$plan_dir/airgap-use-existing/.release-kit-internal/operator-inputs-plan.json" \
    --operator-inputs-plan "$plan_dir/airgap-install-substrates/.release-kit-internal/operator-inputs-plan.json" \
    --product-readiness-report "$fixture_dir/product-readiness-report.json" \
    --post-deploy-product-smoke-report "$fixture_dir/post-deploy-product-smoke-report.json" \
    --output-dir "$output_dir"
}

run_ga_release_with_summary_write_failure() {
  local fixture_dir="$1"
  local path_dir="$2"
  local output_dir="$3"
  local preload_file="$4"

  NODE_OPTIONS="--import $preload_file" bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
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

run_ga_release_without_release_kit_provenance() {
  local fixture_dir="$1"
  local path_dir="$2"
  local output_dir="$3"
  local bash_bin
  local dirname_bin
  local node_bin

  bash_bin="$(command -v bash)"
  dirname_bin="$(command -v dirname)"
  node_bin="$(command -v "$NODE_BIN")"
  mkdir -p "$TMP_DIR/no-git-path"
  ln -sf "$dirname_bin" "$TMP_DIR/no-git-path/dirname"

  env \
    -u GITHUB_REPOSITORY \
    -u GITHUB_SHA \
    -u GITHUB_RUN_ID \
    -u GITHUB_RUN_ATTEMPT \
    NODE="$node_bin" \
    PATH="$TMP_DIR/no-git-path" \
    "$bash_bin" "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
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
} else if (mutation === 'missing-run-url') {
  delete report.artifact_provenance.run_url;
} else if (mutation === 'run-url-mismatch') {
  report.artifact_provenance.run_url =
    'https://github.com/agentsmith-project/agentsmith/actions/runs/99999/attempts/1';
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
  local report_file="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$mutation" <<'NODE'
import fs from 'node:fs';

const [reportFile, mutation] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));

if (mutation === 'legacy-surrogate-shape') {
  const legacy = {
    schema: 'agentsmith.post-deploy-product-smoke/v1',
    status: 'pass',
    release_id: 'agentsmith-ga-2026-05-31',
    git_sha: '1'.repeat(40),
    release_contract_digest: `sha256:${'1'.repeat(64)}`,
    artifact_provenance: {
      schema_version: 'agentsmith.artifact-provenance/v1',
      provenance_kind: 'ci_artifact',
      producer_repo: 'github.com/agentsmith-project/agentsmith',
      normalized_remote: 'github.com/agentsmith-project/agentsmith',
      commit_sha: '1'.repeat(40),
      run_id: 'legacy-10001',
      run_attempt: '1',
      subject_sha256: `sha256:${'2'.repeat(64)}`,
      generated_at: '2026-05-31T12:00:00.000Z'
    },
    covered_flows: [
      'auth_profile',
      'workspace_project',
      'files',
      'managed_runner_agent_task',
      'provider_neutral_endpoint',
      'audit_usage_readback'
    ]
  };
  fs.writeFileSync(reportFile, `${JSON.stringify(legacy, null, 2)}\n`);
  process.exit(0);
} else if (mutation === 'mixed-surrogate-schema') {
  report.schema = 'agentsmith.post-deploy-product-smoke/v1';
} else if (mutation === 'legacy-fields-mixed') {
  report.covered_flows = [
    'auth_profile',
    'workspace_project',
    'files',
    'managed_runner_agent_task',
    'provider_neutral_endpoint',
    'audit_usage_readback'
  ];
  report.artifact_provenance = {
    schema_version: 'agentsmith.artifact-provenance/v1',
    provenance_kind: 'ci_artifact',
    producer_repo: 'github.com/agentsmith-project/agentsmith',
    normalized_remote: 'github.com/agentsmith-project/agentsmith',
    commit_sha: '1'.repeat(40),
    run_id: 'legacy-10001',
    run_attempt: '1',
    subject_sha256: `sha256:${'2'.repeat(64)}`,
    generated_at: '2026-05-31T12:00:00.000Z'
  };
  report.release_id = 'agentsmith-ga-2026-05-31';
  report.git_sha = '1'.repeat(40);
  report.release_contract_digest = `sha256:${'1'.repeat(64)}`;
} else if (mutation === 'missing-release-contract') {
  delete report.release_contract;
} else if (mutation === 'release-contract-digest-mismatch') {
  report.release_contract.input_sha256 = `sha256:${'9'.repeat(64)}`;
} else if (mutation === 'release-contract-release-id-mismatch') {
  report.release_contract.release_id = `${report.release_contract.release_id}-other`;
} else if (mutation === 'release-contract-git-sha-mismatch') {
  report.release_contract.git_sha = '9'.repeat(40);
} else if (mutation === 'release-contract-missing-path') {
  delete report.release_contract.path;
} else if (mutation === 'release-contract-empty-path') {
  report.release_contract.path = '';
} else if (mutation === 'release-contract-absolute-path') {
  report.release_contract.path = '/reports/release-contract.json';
} else if (mutation === 'release-contract-parent-escape-path') {
  report.release_contract.path = '../release-contract.json';
} else if (mutation === 'release-contract-backslash-path') {
  report.release_contract.path = 'reports\\release-contract.json';
} else if (mutation === 'release-contract-nested-legacy-field') {
  report.release_contract.release_contract_digest = report.release_contract.input_sha256;
} else if (mutation === 'missing-product-flows-source') {
  delete report.source;
} else if (mutation === 'missing-product-flows-sha256') {
  delete report.source.product_flows_sha256;
} else if (mutation === 'malformed-product-flows-sha256') {
  report.source.product_flows_sha256 = 'sha256:not-a-digest';
} else if (mutation === 'wrong-product-flows-schema') {
  report.source.aggregate_schema_version = 'agentsmith.unified-deploy.product-flows.aggregate/v0';
} else if (mutation === 'wrong-product-flows-producer') {
  report.source.aggregate_producer = 'release-kit-product-flows';
} else if (mutation === 'missing-deployment-target') {
  delete report.deployment_target;
} else if (mutation === 'missing-deployment-target-profile') {
  delete report.deployment_target.profile;
} else if (mutation === 'unknown-deployment-target-profile') {
  report.deployment_target.profile = 'existing_kubernetes/external_declared/preview';
} else if (mutation === 'missing-deployment-target-site-env-digest') {
  delete report.deployment_target.site_env.sha256;
} else if (mutation === 'malformed-deployment-target-site-env-digest') {
  report.deployment_target.site_env.sha256 = 'sha256:not-a-digest';
} else if (mutation === 'deployment-target-site-env-backslash-path') {
  report.deployment_target.site_env.path = 'reports\\site.env';
} else if (mutation === 'missing-deployment-target-substrate-truth') {
  delete report.deployment_target.substrate_truth;
} else if (mutation === 'missing-canonical-smoke') {
  delete report.smoke_results.usage;
} else if (mutation === 'missing-source-evidence-path') {
  delete report.smoke_results.files.source_evidence_path;
} else if (mutation === 'missing-source-evidence-sha256') {
  delete report.smoke_results.files.source_evidence_sha256;
} else if (mutation === 'malformed-source-evidence-sha256') {
  report.smoke_results.files.source_evidence_sha256 = 'sha256:not-a-digest';
} else if (mutation === 'wrong-entry-id') {
  report.smoke_results.files.id = 'workspace_project';
} else if (mutation === 'wrong-source-flow') {
  report.smoke_results.provider_neutral_endpoint.source_flow = 'provider_neutral_endpoint';
} else if (mutation === 'wrong-source-evidence-path') {
  report.smoke_results.provider_neutral_endpoint.source_evidence_path =
    'unified-deploy/product-flows/provider_neutral_endpoint.json';
} else if (mutation === 'absolute-product-flows-path') {
  report.source.product_flows_path = [
    '',
    'home',
    'percy',
    'works',
    'mbos-v1',
    'agentsmith',
    '.artifacts',
    'product-flows-aggregate.json'
  ].join('/');
} else if (mutation === 'absolute-source-evidence-path') {
  report.smoke_results.files.source_evidence_path = [
    '',
    'tmp',
    'agentsmith',
    'product-flows',
    'files.json'
  ].join('/');
} else if (mutation === 'file-uri-product-flows-path') {
  report.source.product_flows_path =
    'file://agentsmith/unified-deploy/product-flows/product-flows-aggregate.json';
} else {
  throw new Error(`unknown product smoke report mutation: ${mutation}`);
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

mutate_release_contract_target_profiles() {
  local contract_file="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$contract_file" "$mutation" <<'NODE'
import fs from 'node:fs';

const [contractFile, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractFile, 'utf8'));

if (mutation === 'kind-target-profile') {
  contract.target_profiles.push({
    target_cluster: 'kind_rehearsal',
    substrate_source: 'kit_installed',
    distribution: 'online',
    required: false,
    prerequisites: {
      namespace: 'agentsmith',
      rbac: 'local_admin',
      ingress: 'local',
      tls: 'optional',
      storage_class: 'standard',
      registry: 'local_kind_import',
      pull_secret_ref: 'not_required'
    }
  });
} else if (mutation === 'kit-provided-prerequisite') {
  const profile = contract.target_profiles.find((entry) =>
    entry.target_cluster === 'existing_kubernetes' &&
    entry.substrate_source === 'kit_installed' &&
    entry.distribution === 'online'
  );
  if (!profile) {
    throw new Error('missing kit installed online target profile');
  }
  profile.prerequisites.ingress = 'kit_provided';
} else {
  throw new Error(`unknown release contract target profile mutation: ${mutation}`);
}

fs.writeFileSync(contractFile, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_release_contract_source_provenance() {
  local contract_file="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$contract_file" "$mutation" <<'NODE'
import fs from 'node:fs';

const [contractFile, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractFile, 'utf8'));

function inventory(id) {
  const image = contract.deploy_image_inventory.find((entry) => entry.id === id);
  if (!image) {
    throw new Error(`missing inventory id: ${id}`);
  }
  return image;
}

if (mutation === 'missing-runner-source-provenance') {
  delete inventory('managed_runner').source_provenance;
} else if (mutation === 'missing-runner-release-manifest-digest') {
  delete inventory('managed_runner').source_provenance.runner_release_manifest_subject_sha256;
} else if (mutation === 'runner-release-manifest-uri-mismatch') {
  inventory('managed_runner').source_provenance.runner_release_manifest_uri =
    'gh-artifact://agentsmith-project/agentsmith-runner/runner-release-manifest/99999/runner-release-manifest.json';
} else if (mutation === 'runner-release-manifest-digest-mismatch') {
  inventory('managed_runner').source_provenance.runner_release_manifest_artifact_sha256 = `sha256:${'8'.repeat(64)}`;
} else if (mutation === 'missing-dependency-source-provenance') {
  delete inventory('llmup').source_provenance;
} else if (mutation === 'non-canonical-source-repo') {
  const provenance = inventory('afscp').source_provenance;
  provenance.producer_repo = 'github.com/example/agentsmith-fs-control-plane';
  provenance.normalized_remote = 'github.com/example/agentsmith-fs-control-plane';
} else if (mutation === 'missing-dependency-run-evidence') {
  delete inventory('llmup').source_provenance.run_id;
} else if (mutation === 'missing-dependency-run-url') {
  delete inventory('llmup').source_provenance.run_url;
} else if (mutation === 'dependency-run-url-mismatch') {
  inventory('llmup').source_provenance.run_url =
    'https://github.com/agentsmith-project/llm-universal-proxy/actions/runs/99999/attempts/1';
} else if (mutation === 'missing-dependency-artifact-uri') {
  delete inventory('llmup').source_provenance.artifact_uri;
} else if (mutation === 'dependency-tag-mismatch') {
  inventory('llmup').source_provenance.tag = 'not-the-release-tag';
} else if (mutation === 'dependency-digest-mismatch') {
  inventory('llmup').source_provenance.artifact_sha256 = `sha256:${'9'.repeat(64)}`;
} else {
  throw new Error(`unknown source provenance mutation: ${mutation}`);
}

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
  report.airgap_offline.public_internet_downloads_observed_by_release_kit = true;
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

remove_manifest_source_evidence_entry() {
  local report_dir="$1"
  local kind="$2"

  "$NODE_BIN" --input-type=module - "$report_dir/deployment-path-finalizer-manifest.json" "$kind" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [manifestFile, kind] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const reportDir = path.dirname(manifestFile);
const removedEntries = manifest.source_evidence_files.filter((entry) => entry.kind === kind);
manifest.source_evidence_files = manifest.source_evidence_files.filter((entry) => entry.kind !== kind);
for (const entry of removedEntries) {
  fs.rmSync(path.join(reportDir, entry.path), { force: true });
}
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

"$NODE_BIN" --input-type=module - \
  "$TMP_DIR/out-valid/ga-release-report.json" \
  "$TMP_DIR/out-valid/ga-evidence-index.json" \
  "$VALID_DIR/release-contract.json" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile, evidenceIndexFile, releaseContractFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const evidenceIndex = JSON.parse(fs.readFileSync(evidenceIndexFile, 'utf8'));
const releaseContractBytes = fs.readFileSync(releaseContractFile);
const releaseContract = JSON.parse(releaseContractBytes.toString('utf8'));
const releaseContractDigest =
  `sha256:${crypto.createHash('sha256').update(releaseContractBytes).digest('hex')}`;
const sha = (label) => `sha256:${crypto.createHash('sha256').update(label).digest('hex')}`;
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
  throw new Error('unexpected schema');
}
if (report.status !== 'pass' || report.formal_verdict !== 'issued') {
  throw new Error('GA report did not issue pass verdict');
}
if (evidenceIndex.schema !== 'agentsmith.ga-evidence-index/v1') {
  throw new Error('GA evidence index used an unexpected schema');
}
if (evidenceIndex.role !== 'derived_from_ga_release_report') {
  throw new Error('GA evidence index must be marked as derived from the GA report');
}
if (
  evidenceIndex.source_report?.path !== 'ga-release-report.json' ||
  evidenceIndex.source_report?.schema !== report.schema ||
  evidenceIndex.source_report?.digest !== canonicalDigest(report) ||
  evidenceIndex.source_report?.status !== report.status ||
  evidenceIndex.source_report?.formal_verdict !== report.formal_verdict
) {
  throw new Error('GA evidence index must bind the final GA report status, verdict, schema, and digest');
}
if (JSON.stringify(stableJson(evidenceIndex.artifact_index)) !== JSON.stringify(stableJson(report.artifact_index))) {
  throw new Error('GA evidence index artifact_index must match the final GA report artifact_index');
}
if (!Array.isArray(evidenceIndex.deployment_paths) || evidenceIndex.deployment_paths.length !== 4) {
  throw new Error('GA evidence index must archive four deployment path evidence entries');
}
if (!Array.isArray(report.deployment_paths) || report.deployment_paths.length !== 4) {
  throw new Error('expected four deployment paths');
}
if (!Array.isArray(report.artifact_index?.deployment_paths) || report.artifact_index.deployment_paths.length !== 4) {
  throw new Error('GA report artifact index must cover four deployment paths');
}
for (const indexedPath of report.artifact_index.deployment_paths) {
  if (!indexedPath.operator_path || !indexedPath.digest?.startsWith('sha256:')) {
    throw new Error('GA report artifact index deployment path missing digest binding');
  }
  if (indexedPath.finalizer_manifest?.path !== 'deployment-path-finalizer-manifest.json') {
    throw new Error(`GA report artifact index missing finalizer manifest path: ${indexedPath.operator_path}`);
  }
  if (!indexedPath.finalizer_manifest?.digest?.startsWith('sha256:')) {
    throw new Error(`GA report artifact index missing finalizer manifest digest: ${indexedPath.operator_path}`);
  }
  if (!Array.isArray(indexedPath.source_evidence_files) || indexedPath.source_evidence_files.length === 0) {
    throw new Error(`GA report artifact index missing source evidence files: ${indexedPath.operator_path}`);
  }
  for (const sourceFile of indexedPath.source_evidence_files) {
    if (!sourceFile.path?.startsWith('source-evidence/') || !sourceFile.sha256?.startsWith('sha256:')) {
      throw new Error(`GA report artifact index source evidence file missing path/digest: ${indexedPath.operator_path}`);
    }
    if (!sourceFile.kind || !sourceFile.schema) {
      throw new Error(`GA report artifact index source evidence file missing kind/schema: ${indexedPath.operator_path}`);
    }
  }
  const sourceKinds = indexedPath.source_evidence_files.map((entry) => entry.kind).sort();
  if (indexedPath.operator_path.startsWith('airgap/')) {
    for (const kind of ['airgap_bundle_manifest', 'airgap_image_map']) {
      if (!sourceKinds.includes(kind)) {
        throw new Error(`GA report artifact index airgap path missing ${kind}: ${indexedPath.operator_path}`);
      }
    }
  }
}
const airgapPaths = report.deployment_paths.filter((entry) => entry.operator_path?.startsWith('airgap/'));
if (airgapPaths.length !== 2) {
  throw new Error('GA report must include two airgap deployment paths');
}
for (const pathEntry of airgapPaths) {
  const offline = pathEntry.airgap_offline;
  if (offline?.proof_scope !== 'release_kit_package_local_bundle_local_digest_bound_inputs_only') {
    throw new Error(`GA report airgap path missing scoped offline proof: ${pathEntry.operator_path}`);
  }
  if (offline.public_internet_downloads_observed_by_release_kit !== false) {
    throw new Error(`GA report airgap path must only report release-kit observed downloads: ${pathEntry.operator_path}`);
  }
  if (offline.release_kit_inputs_package_local_digest_bound !== true) {
    throw new Error(`GA report airgap path must bind package-local/bundle-local inputs: ${pathEntry.operator_path}`);
  }
  if (offline.release_kit_inputs_and_tools_package_local_or_bundle_local_digest_bound !== true) {
    throw new Error(`GA report airgap path must bind package-local/bundle-local inputs and tools: ${pathEntry.operator_path}`);
  }
}
const expectedCanonicalRepos = [
  'github.com/agentsmith-project/agentsmith',
  'github.com/agentsmith-project/agentsmith-fs-control-plane',
  'github.com/agentsmith-project/agentsmith-release-kit',
  'github.com/agentsmith-project/agentsmith-runner',
  'github.com/agentsmith-project/agentsmith-sandbox-control-plane',
  'github.com/agentsmith-project/llm-universal-proxy'
];
const canonicalRepos = report.canonical_repos || [];
const actualCanonicalRepos = canonicalRepos.map((entry) => entry.repo).sort();
if (JSON.stringify(actualCanonicalRepos) !== JSON.stringify(expectedCanonicalRepos)) {
  throw new Error(`GA report canonical_repos must exactly cover six repos: ${actualCanonicalRepos.join(', ')}`);
}
for (const repo of canonicalRepos) {
  if (!/^[0-9a-f]{40}$/.test(repo.commit_sha || '')) {
    throw new Error(`canonical repo missing commit sha: ${repo.repo}`);
  }
  if (!repo.freshness_key || !repo.freshness_key.includes(repo.commit_sha)) {
    throw new Error(`canonical repo missing freshness key: ${repo.repo}`);
  }
  if (repo.repo !== 'github.com/agentsmith-project/agentsmith-release-kit') {
    if (!Array.isArray(repo.image_digests) || repo.image_digests.length === 0) {
      throw new Error(`image-backed canonical repo missing image digest: ${repo.repo}`);
    }
    if (!Array.isArray(repo.image_tags) || repo.image_tags[0] !== releaseContract.release_id) {
      throw new Error(`image-backed canonical repo missing image tag: ${repo.repo}`);
    }
    if (!repo.run_id || !repo.run_attempt) {
      throw new Error(`image-backed canonical repo missing run evidence: ${repo.repo}`);
    }
    if (typeof repo.run_url !== 'string' || !repo.run_url.startsWith(`https://${repo.repo}/actions/runs/`)) {
      throw new Error(`image-backed canonical repo missing run url: ${repo.repo}`);
    }
    const imageProvenance = Object.values(repo.provenance || {});
    if (imageProvenance.length === 0) {
      throw new Error(`image-backed canonical repo missing provenance entries: ${repo.repo}`);
    }
    for (const provenance of imageProvenance) {
      if (typeof provenance.artifact_uri !== 'string' || !provenance.artifact_uri.startsWith('gh-artifact://')) {
        throw new Error(`image-backed canonical repo missing artifact uri trace: ${repo.repo}`);
      }
      if (provenance.run_url !== repo.run_url) {
        throw new Error(`image-backed canonical repo provenance run url mismatch: ${repo.repo}`);
      }
    }
  }
}
const smoke = report.post_deploy_product_smoke;
const expectedSmokeIds = [
  'login_profile',
  'workspace_project',
  'provider_neutral_endpoint',
  'agent_task_managed_runner',
  'files',
  'audit',
  'usage'
];
const expectedSourceEvidencePaths = {
  login_profile: 'unified-deploy/product-flows/login_profile.json',
  workspace_project: 'unified-deploy/product-flows/workspace_project.json',
  provider_neutral_endpoint: 'unified-deploy/product-flows/chat_via_llmup.json',
  agent_task_managed_runner: 'unified-deploy/product-flows/agent_task_managed_runner.json',
  files: 'unified-deploy/product-flows/files.json',
  audit: 'unified-deploy/product-flows/audit.json',
  usage: 'unified-deploy/product-flows/usage.json'
};
const expectedSourceEvidenceDigests = {
  login_profile: sha('product-smoke:login_profile'),
  workspace_project: sha('product-smoke:workspace_project'),
  provider_neutral_endpoint: sha('product-smoke:chat_via_llmup'),
  agent_task_managed_runner: sha('product-smoke:agent_task_managed_runner'),
  files: sha('product-smoke:files'),
  audit: sha('product-smoke:audit'),
  usage: sha('product-smoke:usage')
};
if (smoke?.schema !== 'agentsmith.post-deploy-product-smoke-report/v1') {
  throw new Error('GA report did not bind canonical product smoke schema');
}
if (smoke?.producer !== 'agentsmith-post-deploy-product-smoke') {
  throw new Error('GA report did not bind canonical product smoke producer');
}
if (smoke?.release_contract?.path !== 'release-contract.json') {
  throw new Error('GA report did not keep product smoke release contract path');
}
if (smoke?.release_contract?.input_sha256 !== releaseContractDigest) {
  throw new Error('GA report did not bind product smoke to release contract digest');
}
if (
  smoke?.release_contract?.release_id !== releaseContract.release_id ||
  smoke?.release_contract?.release_id !== report.release.release_id
) {
  throw new Error('GA report did not bind product smoke to release id');
}
if (
  smoke?.release_contract?.git_sha !== releaseContract.git_sha ||
  smoke?.release_contract?.git_sha !== report.release.git_sha
) {
  throw new Error('GA report did not bind product smoke to git sha');
}
if (JSON.stringify(smoke?.canonical_smoke_ids) !== JSON.stringify(expectedSmokeIds)) {
  throw new Error('GA report did not bind canonical product smoke ids');
}
if (smoke?.source?.product_flows_path !== 'unified-deploy/product-flows/product-flows-aggregate.json') {
  throw new Error('GA report did not bind product smoke aggregate path');
}
if (smoke?.source?.product_flows_sha256 !== sha('post-deploy-product-smoke:product-flows')) {
  throw new Error('GA report did not bind product smoke aggregate digest');
}
if (smoke?.source?.aggregate_schema_version !== 'agentsmith.unified-deploy.product-flows.aggregate/v1') {
  throw new Error('GA report did not bind product smoke aggregate schema');
}
if (smoke?.source?.aggregate_producer !== 'unified-deploy-product-flows') {
  throw new Error('GA report did not bind product smoke aggregate producer');
}
if (smoke?.deployment_target?.profile !== 'existing_kubernetes/external_declared/online') {
  throw new Error('GA report did not bind product smoke deployment target profile');
}
if (smoke?.deployment_path_binding?.operator_path !== 'online/use_existing') {
  throw new Error('GA report did not bind product smoke target to finalized deployment path');
}
if (smoke?.deployment_path_binding?.target_profile !== smoke.deployment_target.profile) {
  throw new Error('GA report product smoke deployment path binding target profile mismatch');
}
if (smoke?.deployment_target?.public_base_url !== 'https://agentsmith.example.com') {
  throw new Error('GA report did not bind product smoke public base URL');
}
if (smoke?.deployment_target?.api_base_url !== 'https://agentsmith.example.com/api/v1') {
  throw new Error('GA report did not bind product smoke API base URL');
}
if (smoke?.deployment_target?.site_env?.path !== 'unified-deploy/site.env') {
  throw new Error('GA report did not bind product smoke site env path');
}
if (smoke?.deployment_target?.site_env?.sha256 !== sha('post-deploy-product-smoke:site-env')) {
  throw new Error('GA report did not bind product smoke site env digest');
}
if (smoke?.deployment_target?.substrate_truth?.path !== 'unified-deploy/substrate-truth.json') {
  throw new Error('GA report did not bind product smoke substrate truth path');
}
if (smoke?.deployment_target?.substrate_truth?.sha256 !== sha('post-deploy-product-smoke:substrate-truth')) {
  throw new Error('GA report did not bind product smoke substrate truth digest');
}
for (const id of expectedSmokeIds) {
  if (smoke?.source_evidence_paths?.[id] !== expectedSourceEvidencePaths[id]) {
    throw new Error(`GA report did not bind source evidence path for product smoke id: ${id}`);
  }
  if (smoke?.source_evidence_sha256?.[id] !== expectedSourceEvidenceDigests[id]) {
    throw new Error(`GA report did not bind source evidence digest for product smoke id: ${id}`);
  }
}
if (Object.hasOwn(report.summary || {}, 'product_smoke_flows')) {
  throw new Error('GA report must not expose covered_flows as product smoke truth');
}
NODE
[[ -f "$TMP_DIR/out-valid/ga-release-summary.md" ]] || fail "missing human summary"
[[ -f "$TMP_DIR/out-valid/ga-evidence-index.json" ]] || fail "missing GA evidence index"
pass "valid GA aggregate consumes finalizer-generated path bundles"

PLAN_DIR="$TMP_DIR/operator-input-plans-valid"
write_operator_inputs_plan_set "$VALID_DIR" "$PLAN_DIR" valid
run_ga_release_with_operator_plans "$VALID_DIR" "$PATH_DIR" "$PLAN_DIR" "$TMP_DIR/out-valid-with-operator-plans"

"$NODE_BIN" --input-type=module - \
  "$TMP_DIR/out-valid-with-operator-plans/ga-release-report.json" \
  "$VALID_DIR/release-contract.json" \
  "$VALID_DIR/deploy-template-package.json" \
  "$PLAN_DIR" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile, releaseContractFile, deployTemplatePackageFile, planDir] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const digest = (file) => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
const releaseContractDigest = digest(releaseContractFile);
const deployTemplatePackageDigest = digest(deployTemplatePackageFile);
const packageIndex = report.artifact_index?.operator_inputs_packages;

if (!Array.isArray(packageIndex) || packageIndex.length !== 4) {
  throw new Error('GA report must index four operator-inputs packages when plans are provided');
}
if (JSON.stringify(packageIndex).includes(planDir)) {
  throw new Error('GA report operator-inputs package index must not expose local plan dir');
}
for (const entry of packageIndex) {
  if (entry.release_materials?.release_contract?.path !== 'release-contract.json') {
    throw new Error(`operator-inputs package index missing release contract path: ${entry.operator_path}`);
  }
  if (entry.release_materials?.release_contract?.digest !== releaseContractDigest) {
    throw new Error(`operator-inputs package index missing release contract digest: ${entry.operator_path}`);
  }
  if (entry.release_materials?.deploy_template_package?.path !== 'deploy-template-package.json') {
    throw new Error(`operator-inputs package index missing deploy template package path: ${entry.operator_path}`);
  }
  if (entry.release_materials?.deploy_template_package?.digest !== deployTemplatePackageDigest) {
    throw new Error(`operator-inputs package index missing deploy template package digest: ${entry.operator_path}`);
  }
}
NODE
pass "GA aggregate binds operator-inputs package release materials"

STALE_PLAN_DIR="$TMP_DIR/operator-input-plans-stale-release-ref"
write_operator_inputs_plan_set "$VALID_DIR" "$STALE_PLAN_DIR" stale-release-contract-ref
if run_ga_release_with_operator_plans \
  "$VALID_DIR" \
  "$PATH_DIR" \
  "$STALE_PLAN_DIR" \
  "$TMP_DIR/out-stale-operator-plan-ref" >"$TMP_DIR/ga-stale-operator-plan-ref.out" 2>&1; then
  fail "GA aggregate should reject operator-inputs plan with stale release contract ref digest"
fi
grep -Fq 'operator_inputs_plan.input_refs.release_contract.sha256 must match file digest for online/use_existing' \
  "$TMP_DIR/ga-stale-operator-plan-ref.out" ||
  fail "stale operator-inputs plan ref failure did not name release contract digest binding"

STALE_FAILURE_DIR="$TMP_DIR/stale-failure"
STALE_OUTPUT_DIR="$TMP_DIR/out-stale-failure"
cp -R "$VALID_DIR" "$STALE_FAILURE_DIR"
mkdir -p "$STALE_OUTPUT_DIR"
cp "$TMP_DIR/out-valid/ga-release-report.json" "$STALE_OUTPUT_DIR/ga-release-report.json"
cp "$TMP_DIR/out-valid/ga-release-summary.md" "$STALE_OUTPUT_DIR/ga-release-summary.md"
cp "$TMP_DIR/out-valid/ga-evidence-index.json" "$STALE_OUTPUT_DIR/ga-evidence-index.json"
mutate_product_report "$STALE_FAILURE_DIR/product-readiness-report.json" wrong-repo
if run_ga_release "$STALE_FAILURE_DIR" "$PATH_DIR" "$STALE_OUTPUT_DIR" >"$TMP_DIR/ga-release-stale-failure.out" 2>&1; then
  fail "GA aggregate with invalid product readiness should fail"
fi
assert_ga_failure_report "$STALE_OUTPUT_DIR" "product_readiness_report.artifact_provenance.producer_repo must match product_readiness_report.artifact_provenance.normalized_remote"
pass "failed GA aggregate replaces stale pass outputs with not-issued failure report"

SUMMARY_FAILURE_OUTPUT_DIR="$TMP_DIR/out-summary-write-failure"
SUMMARY_FAILURE_PRELOAD="$TMP_DIR/fail-summary-write.mjs"
cat >"$SUMMARY_FAILURE_PRELOAD" <<'NODE'
import fs from 'node:fs/promises';

const originalWriteFile = fs.writeFile;
fs.writeFile = async function writeFileWithInjectedSummaryFailure(file, ...args) {
  if (String(file).includes('ga-release-summary.md')) {
    throw new Error('injected summary write failure');
  }
  return originalWriteFile.call(this, file, ...args);
};
NODE
if run_ga_release_with_summary_write_failure "$VALID_DIR" "$PATH_DIR" "$SUMMARY_FAILURE_OUTPUT_DIR" "$SUMMARY_FAILURE_PRELOAD" >"$TMP_DIR/ga-release-summary-write-failure.out" 2>&1; then
  fail "GA aggregate with summary write failure should fail"
fi
grep -Fq "injected summary write failure" "$TMP_DIR/ga-release-summary-write-failure.out" || \
  fail "summary write failure did not reach finalizer output"
if [[ -e "$SUMMARY_FAILURE_OUTPUT_DIR/ga-release-report.json" ]]; then
  fail "failed GA aggregate summary write must not leave ga-release-report.json"
fi
if [[ -e "$SUMMARY_FAILURE_OUTPUT_DIR/ga-evidence-index.json" ]]; then
  fail "failed GA aggregate summary write must not leave ga-evidence-index.json"
fi
pass "failed GA aggregate summary write does not leave formal report"

if run_ga_release_without_release_kit_provenance "$VALID_DIR" "$PATH_DIR" "$TMP_DIR/out-missing-release-kit-provenance" >"$TMP_DIR/ga-release-missing-release-kit-provenance.out" 2>&1; then
  fail "missing release-kit finalizer provenance should fail"
fi
grep -Fq "release-kit finalizer provenance requires GITHUB_REPOSITORY or git origin remote" "$TMP_DIR/ga-release-missing-release-kit-provenance.out" || \
  fail "missing release-kit finalizer provenance failure message did not explain blocker"
pass "GA aggregate requires release-kit finalizer provenance from CI env or git"

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

MISSING_HANDOFF_ARTIFACT_RUN_URL_DIR="$TMP_DIR/missing-handoff-artifact-run-url"
write_fixture_set "$MISSING_HANDOFF_ARTIFACT_RUN_URL_DIR" valid
"$NODE_BIN" --input-type=module - "$MISSING_HANDOFF_ARTIFACT_RUN_URL_DIR/deploy-template-package.json" <<'NODE'
import fs from 'node:fs';

const [templateFile] = process.argv.slice(2);
const template = JSON.parse(fs.readFileSync(templateFile, 'utf8'));
delete template.artifact_provenance.run_url;
fs.writeFileSync(templateFile, `${JSON.stringify(template, null, 2)}\n`);
NODE
if run_ga_release "$MISSING_HANDOFF_ARTIFACT_RUN_URL_DIR" "$PATH_DIR" "$TMP_DIR/out-missing-handoff-artifact-run-url" >"$TMP_DIR/ga-release-missing-handoff-artifact-run-url.out" 2>&1; then
  fail "GA aggregate should reject handoff artifact provenance without run_url"
fi
grep -Fq "deploy_template_package.artifact_provenance.run_url is required" "$TMP_DIR/ga-release-missing-handoff-artifact-run-url.out" || \
  fail "missing handoff artifact run_url failure message did not explain blocker"
pass "GA aggregate requires handoff artifact CI run URLs"

product_report_cases=(
  "product-readiness-report.json|product_readiness_report.artifact_provenance|product readiness"
)
product_provenance_mutations=(
  missing-provenance
  four-field-provenance
  missing-schema
  missing-kind
  wrong-repo
  wrong-sha
  non-iso-generated-at
  missing-run-url
  run-url-mismatch
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
      missing-run-url)
        expected_message="$provenance_label.run_url is required"
        ;;
      run-url-mismatch)
        expected_message="$provenance_label.run_url run id must match $provenance_label.run_id"
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
pass "GA aggregate requires full product readiness provenance shape"
pass "GA aggregate accepts product readiness artifact_uri as the sole artifact binding"

product_smoke_mutations=(
  legacy-surrogate-shape
  mixed-surrogate-schema
  legacy-fields-mixed
  missing-release-contract
  release-contract-digest-mismatch
  release-contract-release-id-mismatch
  release-contract-git-sha-mismatch
  release-contract-missing-path
  release-contract-empty-path
  release-contract-absolute-path
  release-contract-parent-escape-path
  release-contract-backslash-path
  release-contract-nested-legacy-field
  missing-product-flows-source
  missing-product-flows-sha256
  malformed-product-flows-sha256
  wrong-product-flows-schema
  wrong-product-flows-producer
  missing-deployment-target
  missing-deployment-target-profile
  unknown-deployment-target-profile
  missing-deployment-target-site-env-digest
  malformed-deployment-target-site-env-digest
  deployment-target-site-env-backslash-path
  missing-deployment-target-substrate-truth
  missing-canonical-smoke
  missing-source-evidence-path
  missing-source-evidence-sha256
  malformed-source-evidence-sha256
  wrong-entry-id
  wrong-source-flow
  wrong-source-evidence-path
)
for mutation in "${product_smoke_mutations[@]}"; do
  PRODUCT_SMOKE_DIR="$TMP_DIR/product-smoke-$mutation"
  write_fixture_set "$PRODUCT_SMOKE_DIR" valid
  mutate_product_smoke_report "$PRODUCT_SMOKE_DIR/post-deploy-product-smoke-report.json" "$mutation"
  if run_ga_release "$PRODUCT_SMOKE_DIR" "$PATH_DIR" "$TMP_DIR/out-product-smoke-$mutation" >"$TMP_DIR/ga-release-product-smoke-$mutation.out" 2>&1; then
    fail "product smoke $mutation should fail"
  fi
  case "$mutation" in
    legacy-surrogate-shape)
      expected_message="post_deploy_product_smoke.schema must not be present; use schema_version"
      ;;
    mixed-surrogate-schema)
      expected_message="post_deploy_product_smoke.schema must not be present; use schema_version"
      ;;
    legacy-fields-mixed)
      expected_message="post_deploy_product_smoke.covered_flows must not be present"
      ;;
    missing-release-contract)
      expected_message="post_deploy_product_smoke.release_contract must be an object"
      ;;
    release-contract-digest-mismatch)
      expected_message="post_deploy_product_smoke.release_contract.input_sha256 must match release contract digest"
      ;;
    release-contract-release-id-mismatch)
      expected_message="post_deploy_product_smoke.release_contract.release_id must match release contract"
      ;;
    release-contract-git-sha-mismatch)
      expected_message="post_deploy_product_smoke.release_contract.git_sha must match release contract"
      ;;
    release-contract-missing-path|release-contract-empty-path)
      expected_message="post_deploy_product_smoke.release_contract.path is required"
      ;;
    release-contract-absolute-path|release-contract-backslash-path)
      expected_message="post_deploy_product_smoke.release_contract.path must be a portable relative path"
      ;;
    release-contract-parent-escape-path)
      expected_message="post_deploy_product_smoke.release_contract.path must not contain empty, current, or parent segments"
      ;;
    release-contract-nested-legacy-field)
      expected_message="post_deploy_product_smoke.release_contract contains unknown field: release_contract_digest"
      ;;
    missing-product-flows-source)
      expected_message="post_deploy_product_smoke.source must be an object"
      ;;
    missing-product-flows-sha256)
      expected_message="post_deploy_product_smoke.source.product_flows_sha256 is required"
      ;;
    malformed-product-flows-sha256)
      expected_message="post_deploy_product_smoke.source.product_flows_sha256 must be a sha256 digest"
      ;;
    wrong-product-flows-schema)
      expected_message="post_deploy_product_smoke.source.aggregate_schema_version must be agentsmith.unified-deploy.product-flows.aggregate/v1"
      ;;
    wrong-product-flows-producer)
      expected_message="post_deploy_product_smoke.source.aggregate_producer must be unified-deploy-product-flows"
      ;;
    missing-deployment-target)
      expected_message="post_deploy_product_smoke.deployment_target must be an object"
      ;;
    missing-deployment-target-profile)
      expected_message="post_deploy_product_smoke.deployment_target.profile is required"
      ;;
    unknown-deployment-target-profile)
      expected_message="post_deploy_product_smoke.deployment_target.profile must match one finalized deployment path target_profile"
      ;;
    missing-deployment-target-site-env-digest)
      expected_message="post_deploy_product_smoke.deployment_target.site_env.sha256 is required"
      ;;
    malformed-deployment-target-site-env-digest)
      expected_message="post_deploy_product_smoke.deployment_target.site_env.sha256 must be a sha256 digest"
      ;;
    deployment-target-site-env-backslash-path)
      expected_message="post_deploy_product_smoke.deployment_target.site_env.path must be a portable relative path"
      ;;
    missing-deployment-target-substrate-truth)
      expected_message="post_deploy_product_smoke.deployment_target.substrate_truth must be an object"
      ;;
    missing-canonical-smoke)
      expected_message="post-deploy product smoke missing canonical smoke id: usage"
      ;;
    missing-source-evidence-path)
      expected_message="post_deploy_product_smoke.smoke_results.files.source_evidence_path is required"
      ;;
    missing-source-evidence-sha256)
      expected_message="post_deploy_product_smoke.smoke_results.files.source_evidence_sha256 is required"
      ;;
    malformed-source-evidence-sha256)
      expected_message="post_deploy_product_smoke.smoke_results.files.source_evidence_sha256 must be a sha256 digest"
      ;;
    wrong-entry-id)
      expected_message="post_deploy_product_smoke.smoke_results.files.id must be files"
      ;;
    wrong-source-flow)
      expected_message="post_deploy_product_smoke.smoke_results.provider_neutral_endpoint.source_flow must be chat_via_llmup"
      ;;
    wrong-source-evidence-path)
      expected_message="post_deploy_product_smoke.smoke_results.provider_neutral_endpoint.source_evidence_path must be unified-deploy/product-flows/chat_via_llmup.json"
      ;;
    *)
      fail "missing expected message for product smoke mutation: $mutation"
      ;;
  esac
  grep -Fq "$expected_message" "$TMP_DIR/ga-release-product-smoke-$mutation.out" || \
    fail "product smoke $mutation failure message did not explain blocker"
done
pass "GA aggregate requires AgentSmith canonical product smoke report shape"

product_smoke_forbidden_path_mutations=(
  absolute-product-flows-path
  absolute-source-evidence-path
  file-uri-product-flows-path
)
for mutation in "${product_smoke_forbidden_path_mutations[@]}"; do
  PRODUCT_SMOKE_DIR="$TMP_DIR/product-smoke-$mutation"
  write_fixture_set "$PRODUCT_SMOKE_DIR" valid
  mutate_product_smoke_report "$PRODUCT_SMOKE_DIR/post-deploy-product-smoke-report.json" "$mutation"
  if run_ga_release "$PRODUCT_SMOKE_DIR" "$PATH_DIR" "$TMP_DIR/out-product-smoke-$mutation" >"$TMP_DIR/ga-release-product-smoke-$mutation.out" 2>&1; then
    fail "product smoke $mutation should fail"
  fi
  grep -Fq "input report contains forbidden local path or secret-like text" "$TMP_DIR/ga-release-product-smoke-$mutation.out" || \
    fail "product smoke $mutation failure message did not come from release-kit scanner"
done
pass "GA aggregate rejects local absolute paths in canonical product smoke input"

IMAGE_CLOSURE_DIR="$TMP_DIR/release-contract-image-closure"
write_fixture_set "$IMAGE_CLOSURE_DIR" valid
mutate_release_contract_image_closure "$IMAGE_CLOSURE_DIR/release-contract.json"
if run_ga_release "$IMAGE_CLOSURE_DIR" "$PATH_DIR" "$TMP_DIR/out-release-contract-image-closure" >"$TMP_DIR/ga-release-image-closure.out" 2>&1; then
  fail "release contract image closure drift should fail"
fi
grep -Fq "release_contract.deploy_template_package.required_image_ids must exactly match release_contract.deploy_image_inventory ids" "$TMP_DIR/ga-release-image-closure.out" || \
  fail "release contract image closure failure message did not explain blocker"
pass "GA aggregate rejects release contract required image closure drift"

target_profile_cases=(
  "kind-target-profile|release_contract.target_profiles must not include non-GA target profile kind_rehearsal/kit_installed/online"
  "kit-provided-prerequisite|must use GA install_substrates/kit_installed wording, not kit_provided"
)
for target_profile_case in "${target_profile_cases[@]}"; do
  IFS='|' read -r mutation expected_message <<< "$target_profile_case"
  TARGET_PROFILE_DIR="$TMP_DIR/release-contract-target-profile-$mutation"
  write_fixture_set "$TARGET_PROFILE_DIR" valid
  mutate_release_contract_target_profiles "$TARGET_PROFILE_DIR/release-contract.json" "$mutation"
  if run_ga_release "$TARGET_PROFILE_DIR" "$PATH_DIR" "$TMP_DIR/out-target-profile-$mutation" >"$TMP_DIR/ga-release-target-profile-$mutation.out" 2>&1; then
    fail "release contract target profile $mutation should fail"
  fi
  grep -Fq "$expected_message" "$TMP_DIR/ga-release-target-profile-$mutation.out" || \
    fail "release contract target profile $mutation failure message did not explain blocker"
done
pass "GA aggregate rejects non-GA release contract target profiles and stale prerequisites"

source_provenance_cases=(
  "missing-runner-source-provenance|release_contract.deploy_image_inventory.managed_runner.source_provenance must be an object"
  "missing-runner-release-manifest-digest|release_contract.deploy_image_inventory.managed_runner.source_provenance.runner_release_manifest_subject_sha256 is required"
  "runner-release-manifest-uri-mismatch|release_contract.deploy_image_inventory.managed_runner.source_provenance.runner_release_manifest_uri run id must match release_contract.deploy_image_inventory.managed_runner.source_provenance.run_id"
  "runner-release-manifest-digest-mismatch|release_contract.deploy_image_inventory.managed_runner.source_provenance.runner_release_manifest_artifact_sha256 must match release_contract.deploy_image_inventory.managed_runner.source_provenance.runner_release_manifest_subject_sha256"
  "missing-dependency-source-provenance|release_contract.deploy_image_inventory.llmup.source_provenance must be an object"
  "non-canonical-source-repo|release_contract.deploy_image_inventory.afscp.source_provenance.normalized_remote must be canonical repo github.com/agentsmith-project/agentsmith-fs-control-plane"
  "missing-dependency-run-evidence|release_contract.deploy_image_inventory.llmup.source_provenance.run_id is required"
  "missing-dependency-run-url|release_contract.deploy_image_inventory.llmup.source_provenance.run_url is required"
  "dependency-run-url-mismatch|release_contract.deploy_image_inventory.llmup.source_provenance.run_url run id must match release_contract.deploy_image_inventory.llmup.source_provenance.run_id"
  "missing-dependency-artifact-uri|release_contract.deploy_image_inventory.llmup.source_provenance.artifact_uri is required"
  "dependency-tag-mismatch|release_contract.deploy_image_inventory.llmup.source_provenance.tag must match release_contract.deploy_image_inventory.llmup.image tag"
  "dependency-digest-mismatch|release_contract.deploy_image_inventory.llmup.source_provenance.artifact_sha256 must match release_contract.deploy_image_inventory.llmup.digest"
)
for source_case in "${source_provenance_cases[@]}"; do
  IFS='|' read -r mutation expected_message <<< "$source_case"
  SOURCE_PROVENANCE_DIR="$TMP_DIR/source-provenance-$mutation"
  write_fixture_set "$SOURCE_PROVENANCE_DIR" valid
  mutate_release_contract_source_provenance "$SOURCE_PROVENANCE_DIR/release-contract.json" "$mutation"
  if run_ga_release "$SOURCE_PROVENANCE_DIR" "$PATH_DIR" "$TMP_DIR/out-source-provenance-$mutation" >"$TMP_DIR/ga-release-source-provenance-$mutation.out" 2>&1; then
    fail "release contract source provenance $mutation should fail"
  fi
  grep -Fq "$expected_message" "$TMP_DIR/ga-release-source-provenance-$mutation.out" || \
    fail "release contract source provenance $mutation failure message did not explain blocker"
done
pass "GA aggregate requires canonical runner and dependency source provenance"

MISSING_DIR="$TMP_DIR/missing"
write_fixture_set "$MISSING_DIR" valid
generate_path_bundles "$MISSING_DIR" "$TMP_DIR/path-missing"
MISSING_OUTPUT_DIR="$TMP_DIR/out-missing"
mkdir -p "$MISSING_OUTPUT_DIR"
cp "$TMP_DIR/out-valid/ga-release-report.json" "$MISSING_OUTPUT_DIR/ga-release-report.json"
cp "$TMP_DIR/out-valid/ga-release-summary.md" "$MISSING_OUTPUT_DIR/ga-release-summary.md"
cp "$TMP_DIR/out-valid/ga-evidence-index.json" "$MISSING_OUTPUT_DIR/ga-evidence-index.json"
if bash "$ROOT_DIR/scripts/verify-release.sh" --ga-release \
  --release-contract "$MISSING_DIR/release-contract.json" \
  --deploy-template-package "$MISSING_DIR/deploy-template-package.json" \
  --deployment-path-report "$TMP_DIR/path-missing/online-use-existing/deployment-path-report.json" \
  --deployment-path-report "$TMP_DIR/path-missing/online-install-substrates/deployment-path-report.json" \
  --deployment-path-report "$TMP_DIR/path-missing/airgap-use-existing/deployment-path-report.json" \
  --product-readiness-report "$MISSING_DIR/product-readiness-report.json" \
  --post-deploy-product-smoke-report "$MISSING_DIR/post-deploy-product-smoke-report.json" \
  --output-dir "$MISSING_OUTPUT_DIR" >"$TMP_DIR/ga-release-missing.out" 2>&1; then
  fail "missing path report should fail"
fi
grep -Fq "expected exactly 4 --deployment-path-report inputs" "$TMP_DIR/ga-release-missing.out" || \
  fail "missing path report failure message did not explain blocker"
assert_ga_failure_report "$MISSING_OUTPUT_DIR" "expected exactly 4 --deployment-path-report inputs"
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

AIRGAP_SOURCE_MISSING_DIR="$TMP_DIR/airgap-source-missing-image-map"
write_fixture_set "$AIRGAP_SOURCE_MISSING_DIR" valid
generate_path_bundles "$AIRGAP_SOURCE_MISSING_DIR" "$TMP_DIR/path-airgap-source-missing-image-map"
remove_manifest_source_evidence_entry "$TMP_DIR/path-airgap-source-missing-image-map/airgap-use-existing" airgap_image_map
if run_ga_release "$AIRGAP_SOURCE_MISSING_DIR" "$TMP_DIR/path-airgap-source-missing-image-map" "$TMP_DIR/out-airgap-source-missing-image-map" >"$TMP_DIR/ga-release-airgap-source-missing-image-map.out" 2>&1; then
  fail "airgap path missing image-map source evidence should fail"
fi
grep -Fq "finalizer_manifest.source_evidence_files must exactly cover path report source evidence" "$TMP_DIR/ga-release-airgap-source-missing-image-map.out" || \
  fail "airgap missing source evidence failure message did not explain blocker"
old_airgap_claim_a="must "
old_airgap_claim_b="prove "
old_airgap_claim_c="no public internet downloads"
if grep -Fq "${old_airgap_claim_a}${old_airgap_claim_b}${old_airgap_claim_c}" "$TMP_DIR/ga-release-airgap-source-missing-image-map.out"; then
  fail "airgap missing source evidence failure must not claim network isolation proof"
fi
pass "GA aggregate rejects missing airgap package-local digest-bound source evidence"

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
old_airgap_claim_a="must "
old_airgap_claim_b="prove "
old_airgap_claim_c="no public internet downloads"
if grep -Fq "${old_airgap_claim_a}${old_airgap_claim_b}${old_airgap_claim_c}" "$TMP_DIR/ga-release-source-airgap-image-map-empty.out"; then
  fail "airgap source image-map semantic failure must not claim network isolation proof"
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
grep -Fq "reports public internet downloads observed by release-kit" "$TMP_DIR/ga-release-airgap-download.out" || \
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
