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
const templateOut = JSON.parse(JSON.stringify(template));

if (mutation === 'duplicate-required-image-id') {
  templateOut.required_image_ids = [
    templateOut.required_image_ids[0],
    templateOut.required_image_ids[0],
    ...templateOut.required_image_ids.slice(2)
  ];
}
if (mutation === 'contract-image-inventory-closure-drift') {
  contract.deploy_image_inventory = contract.deploy_image_inventory.slice(0, -1);
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

function jsonDigest(value) {
  return digest(Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

const contractDigest = jsonDigest(contract);
const templateDigest = jsonDigest(templateOut);

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
          bundle_manifest_input_sha256:
            mutation === 'image-load-bundle-manifest-digest-mismatch'
              ? sha('wrong-airgap-image-load-bundle-manifest')
              : bindings.bundleManifestDigest,
          airgap_bundle_check_report_input_sha256:
            mutation === 'image-load-bundle-check-digest-mismatch'
              ? sha('wrong-airgap-image-load-bundle-check')
              : bindings.bundleCheckDigest
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
          image_map_input_sha256:
            mutation === 'render-check-image-map-digest-mismatch'
              ? sha('wrong-airgap-render-image-map')
              : bindings.imageMapDigest,
          bundle_manifest_input_sha256:
            mutation === 'render-check-bundle-manifest-digest-mismatch'
              ? sha('wrong-airgap-render-bundle-manifest')
              : bindings.bundleManifestDigest,
          render_values_input_sha256: sha(`${profile}:render-values`),
          substrate_truth_input_sha256:
            mutation === 'render-check-substrate-truth-install-digest-mismatch'
              ? sha('wrong-airgap-render-substrate-truth')
              : sha(`${profile}:substrate-truth`),
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
  const report = mutation === 'step-status-only' && name === 'target-preflight'
    ? { status: 'pass' }
    : stepReport(name, profile, bindings);
  if (name === 'smoke') {
    report.rollout_report.input_sha256 =
      mutation === 'route-smoke-rollout-digest-mismatch'
        ? sha('wrong-route-smoke-rollout-report')
        : digest(fs.readFileSync(path.join(baseDir, 'rollout/rollout-report.json')));
  }
  if (mutation === 'empty-target-preflight-prerequisites' && name === 'target-preflight') {
    report.substrate_truth.services_count = 0;
    report.substrate_truth.services = [];
    report.target_prerequisites.substrate_secret_refs_count = 0;
  }
  if (mutation === 'step-formal-verdict' && name === 'smoke') {
    report.formal_verdict = 'issued';
  }
  if (mutation === 'source-report-forbidden-material' && name === 'smoke') {
    report.operator_note = {
      accessToken: {
        redacted: true
      }
    };
  }
  if (mutation === 'schema-shaped-render-check' && name === 'render-check') {
    report.images = [{}];
    report.manifests = [{}];
  }
  if (mutation === 'render-check-image-digest-legal-drift' && name === 'render-check') {
    driftRenderCheckDigest(report);
  }
  if (mutation === 'schema-shaped-apply' && name === 'apply') {
    report.resource_refs = [{}];
  }
  if (mutation === 'rollout-expected-digest-missing-digest' && name === 'rollout') {
    delete report.expected_image_digests[0].digest;
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
  const steps = [
    step(dir, 'target-preflight', 'target-preflight/target-preflight-report.json', profile),
    step(dir, 'render-check', 'render-check/render-report.json', profile),
    step(dir, 'apply', 'apply/apply-report.json', profile),
    step(dir, 'rollout', 'rollout/rollout-report.json', profile)
  ];
  if (mutation !== 'missing-smoke') {
    steps.push(step(dir, 'smoke', 'smoke/smoke-report.json', profile));
  }

  writeJson(path.join(dir, 'online-deployment-gate-report.json'), {
    schema: 'agentsmith.online-deployment-gate/v1',
    scope:
      mutation === 'source-gate-scope-mismatch'
        ? 'online_deployment_gate_wrong_scope'
        : 'online_deployment_gate_only',
    readiness: false,
    status: 'pass',
    mode: mutation === 'server-dry-run' ? 'server-dry-run' : 'apply',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract: {
      input_sha256: contractDigest
    },
    target_profile: targetProfile(profile),
    operator_run_id: 'operator-online-10001',
    steps
  });
}

function airgapGate(dir, profile, bindings) {
  const steps = [];
  if (mutation !== 'missing-airgap-target-preflight') {
    steps.push(step(dir, 'target-preflight', 'target-preflight/target-preflight-report.json', profile));
  }
  steps.push(
    step(dir, 'airgap-image-load', 'airgap-image-load/airgap-image-load-report.json', profile, bindings),
    step(dir, 'airgap-bundle-render-check', 'airgap-bundle-render-check/airgap-bundle-render-check-report.json', profile, bindings),
    step(dir, 'apply', 'apply/apply-report.json', profile),
    step(dir, 'rollout', 'rollout/rollout-report.json', profile),
    step(dir, 'smoke', 'smoke/smoke-report.json', profile)
  );

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
    steps
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
    scope:
      mutation === 'bundle-check-scope-mismatch'
        ? 'airgap_bundle_check_wrong_scope'
        : 'airgap_bundle_manifest_check_only',
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

function substrateInstall(dir, profile, operatorRunId) {
  // Fixture for the explicit substrate installer report consumed by
  // install_substrates finalization.
  const installInputDigest = sha(`${profile}:substrate-install-inputs`);
  const resourceListDigest = sha(`${profile}:substrate-resource-list`);
  const applyResourceListDigest =
    mutation === 'install-apply-resource-digest-mismatch'
      ? sha(`${profile}:wrong-apply-resource-list`)
      : sha(`${profile}:apply-resource-list`);
  const effectiveNamespace =
    mutation === 'install-effective-namespace-mismatch' ? 'other-ns' : 'agentsmith';
  const targetPrerequisitesDigest =
    mutation === 'install-target-prerequisites-digest-mismatch'
      ? sha(`${profile}:other-target-prerequisites`)
      : sha(`${profile}:target-prerequisites`);
  const resourceRefs = [
    {
      apiVersion: 'v1',
      group: '',
      kind: 'ConfigMap',
      resource: 'configmaps',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-config',
      document_index: 1
    },
    {
      apiVersion: 'v1',
      group: '',
      kind: 'Service',
      resource: 'services',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-service',
      document_index: 2
    },
    {
      apiVersion: 'networking.k8s.io/v1',
      group: 'networking.k8s.io',
      kind: 'NetworkPolicy',
      resource: 'networkpolicies.networking.k8s.io',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-network',
      document_index: 3
    },
    {
      apiVersion: 'apps/v1',
      group: 'apps',
      kind: 'Deployment',
      resource: 'deployments.apps',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-postgresql',
      document_index: 4
    },
    {
      apiVersion: 'apps/v1',
      group: 'apps',
      kind: 'StatefulSet',
      resource: 'statefulsets.apps',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-mongodb',
      document_index: 5
    },
    {
      apiVersion: 'batch/v1',
      group: 'batch',
      kind: 'Job',
      resource: 'jobs.batch',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-installer',
      document_index: 6
    },
    {
      apiVersion: 'v1',
      group: '',
      kind: 'PersistentVolumeClaim',
      resource: 'persistentvolumeclaims',
      namespace: effectiveNamespace,
      name: 'agentsmith-substrate-postgresql-data',
      document_index: 7
    }
  ];
  const kubectlResourceRefs = [
    'configmap/agentsmith-substrate-config',
    'service/agentsmith-substrate-service',
    'networkpolicy.networking.k8s.io/agentsmith-substrate-network',
    'deployment.apps/agentsmith-substrate-postgresql',
    'statefulset.apps/agentsmith-substrate-mongodb',
    'job.batch/agentsmith-substrate-installer',
    'persistentvolumeclaim/agentsmith-substrate-postgresql-data'
  ];
  const report = {
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
    mode: mutation === 'install-server-dry-run' ? 'server-dry-run' : 'apply',
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
          mutation === 'install-apply-resource-digest-mismatch'
            ? sha(`${profile}:apply-resource-list`)
            : applyResourceListDigest,
          effectiveNamespace
        )
      },
      target_prerequisites: {
        schema_version: 'agentsmith.target-prerequisites.truth/v1',
        input_sha256: targetPrerequisitesDigest,
        target_profile: profile,
        namespace: effectiveNamespace
      }
    },
    operator_run_id: operatorRunId,
    substrate_truth_digest: sha(`${profile}:substrate-truth`),
    installed_services: ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc'],
    resource_refs: resourceRefs,
    kubectl_resource_refs: kubectlResourceRefs,
    checks: {
      substrate_pack_manifest: 'pass',
      substrate_install_inputs: 'pass',
      target_prerequisites: 'pass',
      namespace_scope: {
        status: 'pass',
        namespace: effectiveNamespace,
        resource_count: resourceRefs.length,
        allowed_resource_count: resourceRefs.length
      },
      collision_guard: {
        status: 'pass',
        checked_resource_count: resourceRefs.length,
        kubectl_get_count: resourceRefs.length,
        not_found_count: resourceRefs.length,
        owned_resource_count: 0
      },
      kubectl_apply: {
        status: 'pass',
        mode: mutation === 'install-server-dry-run' ? 'server-dry-run' : 'apply',
        applied_resource_count: resourceRefs.length,
        kubectl_resource_count: kubectlResourceRefs.length,
        command_summary: {
          command: 'kubectl apply --server-side --namespace agentsmith -f <apply-resource-list> -o name',
          server_side: true,
          namespace: effectiveNamespace,
          output: 'name',
          dry_run: mutation === 'install-server-dry-run' ? 'server' : 'none'
        }
      }
    },
    summary: {
      release_kit_version: '0.1.0',
      substrate_pack_release_kit_version: '0.1.0',
      installed_by: 'agentsmith-release-kit',
      resources_count: resourceRefs.length,
      substrate_services_count: 5
    },
    output_substrate_truth_path: 'substrate-truth.json',
    output_substrate_truth_digest:
      mutation === 'install-output-substrate-truth-digest-mismatch'
        ? sha(`${profile}:wrong-output-substrate-truth`)
        : sha(`${profile}:substrate-truth`)
  };
  if (mutation === 'missing-install-release-contract-digest') {
    delete report.release_contract_digest;
  }
  if (mutation === 'missing-install-input-digests') {
    delete report.inputs;
  }
  if (mutation === 'missing-install-namespace-scope-check') {
    delete report.checks.namespace_scope;
  }
  if (mutation === 'missing-install-resource-refs') {
    delete report.resource_refs;
  }
  if (mutation === 'install-secret-resource-ref') {
    report.resource_refs[0] = {
      ...report.resource_refs[0],
      apiVersion: 'v1',
      group: '',
      kind: 'Secret',
      resource: 'secrets',
      name: 'agentsmith-substrate-secret'
    };
  }
  if (mutation === 'install-kubectl-secret-resource-ref') {
    report.kubectl_resource_refs = ['secret/agentsmith-substrate-config'];
  }
  if (mutation === 'install-resource-ref-namespace-mismatch') {
    report.resource_refs[0].namespace = 'other-ns';
  }
  if (mutation === 'missing-install-target-prerequisites') {
    delete report.inputs.target_prerequisites;
  }
  if (mutation === 'missing-install-apply-resource-digest') {
    delete report.inputs.substrate_install_inputs.apply_resource_list_sha256;
  }
  if (mutation === 'missing-install-effective-namespace') {
    delete report.inputs.substrate_install_inputs.effective_namespace;
  }
  if (mutation === 'missing-install-producer') {
    delete report.producer;
  }
  if (mutation === 'missing-install-installed-services') {
    delete report.installed_services;
  }
  if (mutation === 'missing-install-output-substrate-truth-digest') {
    delete report.output_substrate_truth_digest;
  }
  if (mutation === 'install-kubectl-apply-dry-run-summary') {
    report.checks.kubectl_apply.command_summary.dry_run = 'server';
  }
  if (mutation === 'install-kubectl-apply-dry-run-command') {
    report.checks.kubectl_apply.command_summary.command =
      `${report.checks.kubectl_apply.command_summary.command} --dry-run=server`;
  }
  writeJson(path.join(dir, 'substrate-install-report.json'), report);
}

fs.mkdirSync(outDir, { recursive: true });
writeJson(path.join(outDir, 'release-contract.json'), contract);
writeJson(path.join(outDir, 'deploy-template-package.json'), templateOut);

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
      source_evidence_path: `unified-deploy/product-flows/${spec.source_flow}.json`
    }
  ]));
}

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

VALID_DIR="$TMP_DIR/valid"
PATH_DIR="$TMP_DIR/path-reports"
write_fixture_set "$VALID_DIR" valid

run_online_path \
  "$VALID_DIR" \
  "online/use_existing" \
  "$VALID_DIR/online-use-existing" \
  "$PATH_DIR/online-use-existing"

run_online_path \
  "$VALID_DIR" \
  "online/install_substrates" \
  "$VALID_DIR/online-install-substrates" \
  "$PATH_DIR/online-install-substrates" \
  --substrate-install-report "$VALID_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001"

run_airgap_path \
  "$VALID_DIR" \
  "airgap/use_existing" \
  "$VALID_DIR/airgap-use-existing" \
  "$PATH_DIR/airgap-use-existing"

run_airgap_path \
  "$VALID_DIR" \
  "airgap/install_substrates" \
  "$VALID_DIR/airgap-install-substrates" \
  "$PATH_DIR/airgap-install-substrates" \
  --substrate-install-report "$VALID_DIR/airgap-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-airgap-install-10001"

"$NODE_BIN" --input-type=module - \
  "$PATH_DIR/online-use-existing/deployment-path-report.json" \
  "$VALID_DIR/online-use-existing/smoke/smoke-report.json" \
  "$VALID_DIR/online-use-existing/online-deployment-gate-report.json" \
  "$PATH_DIR/airgap-use-existing/deployment-path-report.json" \
  "$VALID_DIR/airgap-use-existing/airgap-bundle-manifest.json" \
  "$VALID_DIR/airgap-use-existing/airgap-bundle-check-report.json" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  onlinePathReportFile,
  smokeReportFile,
  onlineGateReportFile,
  airgapPathReportFile,
  bundleManifestFile,
  bundleCheckReportFile
] =
  process.argv.slice(2);

function digest(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

const online = JSON.parse(fs.readFileSync(onlinePathReportFile, 'utf8'));
const airgap = JSON.parse(fs.readFileSync(airgapPathReportFile, 'utf8'));
const onlineDir = path.dirname(onlinePathReportFile);
const airgapDir = path.dirname(airgapPathReportFile);
const onlineManifest = JSON.parse(
  fs.readFileSync(path.join(onlineDir, 'deployment-path-finalizer-manifest.json'), 'utf8')
);
const airgapManifest = JSON.parse(
  fs.readFileSync(path.join(airgapDir, 'deployment-path-finalizer-manifest.json'), 'utf8')
);

if (online.schema !== 'agentsmith.deployment-path-report/v1') {
  throw new Error('unexpected online schema');
}
if (onlineManifest.schema !== 'agentsmith.deployment-path-finalizer-manifest/v1') {
  throw new Error('missing online finalizer manifest');
}
if (onlineManifest.tool !== 'verify-deployment-path-report') {
  throw new Error('unexpected finalizer manifest tool');
}
if (onlineManifest.path_report_sha256 !== digest(onlinePathReportFile)) {
  throw new Error('online finalizer manifest did not bind path report bytes');
}
if (online.readiness !== false || airgap.readiness !== false) {
  throw new Error('deployment path reports must keep readiness=false');
}
if (Object.hasOwn(online, 'formal_verdict')) {
  throw new Error('deployment path report must not issue formal verdict');
}
const smokeStep = online.steps.find((step) => step.name === 'route-smoke');
if (!smokeStep || smokeStep.report_digest !== digest(smokeReportFile)) {
  throw new Error('route-smoke digest does not match source report');
}
if (online.source_evidence?.source_deployment_gate_report?.digest !== digest(onlineGateReportFile)) {
  throw new Error('source ledger did not bind the online deployment gate report digest');
}
const smokeLedger = online.source_evidence?.finalized_steps?.find((step) => step.name === 'route-smoke');
if (smokeLedger?.source_step !== 'smoke' || smokeLedger.report_digest !== smokeStep.report_digest) {
  throw new Error('source ledger did not bind route-smoke to the source smoke report digest');
}
const smokeMaterial = onlineManifest.source_evidence_files?.find(
  (entry) => entry.kind === 'finalized_step_report' && entry.step === 'route-smoke'
);
if (!smokeMaterial || digest(path.join(onlineDir, smokeMaterial.path)) !== smokeStep.report_digest) {
  throw new Error('finalizer manifest did not materialize route-smoke source evidence');
}
if (airgap.airgap_offline?.proof_scope !== 'release_kit_package_local_bundle_local_digest_bound_inputs_only') {
  throw new Error('airgap path must declare release-kit proof scope');
}
if (airgap.airgap_offline?.public_internet_downloads_observed_by_release_kit !== false) {
  throw new Error('airgap path must report no public internet downloads observed by release-kit');
}
if (airgap.airgap_offline?.public_internet_downloads !== false) {
  throw new Error('airgap path legacy public download field must stay false');
}
if (airgap.airgap_offline?.release_kit_inputs_package_local_digest_bound !== true) {
  throw new Error('airgap path must bind package-local/bundle-local inputs by digest');
}
if (airgap.airgap_offline?.release_kit_inputs_and_tools_package_local_or_bundle_local_digest_bound !== true) {
  throw new Error('airgap path must bind package-local/bundle-local inputs and tools by digest');
}
const limitations = new Set(airgap.airgap_offline?.proof_limitations || []);
if (
  !limitations.has('does_not_prove_physical_network_isolation') ||
  !limitations.has('does_not_prove_absence_of_public_internet_access_outside_release_kit')
) {
  throw new Error('airgap path must state release-kit proof limitations');
}
if (airgapManifest.path_report_sha256 !== digest(airgapPathReportFile)) {
  throw new Error('airgap finalizer manifest did not bind path report bytes');
}
if (airgap.airgap_offline.bundle_manifest_digest !== digest(bundleManifestFile)) {
  throw new Error('airgap bundle manifest digest mismatch');
}
if (airgap.source_evidence?.airgap?.bundle_check_report_digest !== digest(bundleCheckReportFile)) {
  throw new Error('airgap source ledger did not bind bundle-check report digest');
}
if (!airgap.source_evidence?.airgap?.image_map_input_sha256?.startsWith('sha256:')) {
  throw new Error('airgap source ledger must expose image_map input digest');
}
const imageMapMaterial = airgapManifest.source_evidence_files?.find(
  (entry) => entry.kind === 'airgap_image_map'
);
if (
  !imageMapMaterial ||
  digest(path.join(airgapDir, imageMapMaterial.path)) !== airgap.source_evidence.airgap.image_map_input_sha256
) {
  throw new Error('finalizer manifest did not materialize airgap image-map source evidence');
}
if (airgap.steps[0]?.name !== 'target-preflight' || airgap.steps[1]?.name !== 'bundle-check') {
  throw new Error('airgap path must retain target-preflight before bundle/image/deploy evidence');
}
NODE
pass "valid deployment path reports finalize focused producer evidence with materiality manifest"

"$NODE_BIN" --input-type=module - "$ROOT_DIR" <<'NODE'
import { pathToFileURL } from 'node:url';

const [rootDir] = process.argv.slice(2);
const scannerUrl = pathToFileURL(`${rootDir}/scripts/lib/report-forbidden-scan.mjs`).href;
const { scanReportForForbiddenContent } = await import(scannerUrl);

function assertForbidden(label, input) {
  try {
    scanReportForForbiddenContent({ label, ...input });
  } catch {
    return;
  }
  throw new Error(`${label} should be forbidden`);
}

function assertAllowed(label, value) {
  scanReportForForbiddenContent({ label, value });
}

assertForbidden('camel accessToken key', {
  value: { operator_note: { accessToken: { redacted: true } } }
});
assertForbidden('camel privateKey key', {
  value: { operator_note: { privateKey: { redacted: true } } }
});
assertForbidden('raw AWS secret access key', {
  value: {},
  buffer: Buffer.from('awsSecretAccessKey=abc123')
});
assertForbidden('kubeconfig admin.conf path', {
  value: { operator_note: { kubeconfig_path: '/etc/kubernetes/admin.conf' } }
});
assertForbidden('encoded home artifact uri', {
  value: {
    artifact_provenance: {
      artifact_uri: 'gh-artifact://agentsmith/report/10001/%2Fhome%2Fexample%2Freport.json'
    }
  }
});
assertForbidden('encoded kubeconfig artifact uri', {
  value: {
    artifact_provenance: {
      artifact_uri: 'artifact://agentsmith/report/10001/.kube%2Fconfig'
    }
  }
});
assertAllowed('ordinary artifact uri', {
  artifact_provenance: {
    artifact_uri: 'https://artifacts.example.test/agentsmith/report/10001/report.json'
  }
});
assertAllowed('ordinary business key', {
  inventory: {
    key: 'customer-routing',
    key_id: 'non-sensitive-id'
  }
});
NODE
pass "shared forbidden scanner rejects explicit credential/path forms without banning ordinary key fields"

run_ga_release "$VALID_DIR" "$PATH_DIR" "$TMP_DIR/out-ga"
pass "finalized deployment path reports feed GA aggregate"

MIRROR_RENDER_DIR="$TMP_DIR/render-check-target-registry-mirror"
write_fixture_set "$MIRROR_RENDER_DIR" render-check-target-registry-mirror
run_online_path \
  "$MIRROR_RENDER_DIR" \
  "online/use_existing" \
  "$MIRROR_RENDER_DIR/online-use-existing" \
  "$TMP_DIR/out-render-check-target-registry-mirror"
pass "render-check source validation accepts same inventory digest from target registry mirror"

ROLLOUT_EXTRA_DIGEST_DIR="$TMP_DIR/rollout-observed-extra-digest"
write_fixture_set "$ROLLOUT_EXTRA_DIGEST_DIR" rollout-observed-extra-digest
run_online_path \
  "$ROLLOUT_EXTRA_DIGEST_DIR" \
  "online/use_existing" \
  "$ROLLOUT_EXTRA_DIGEST_DIR/online-use-existing" \
  "$TMP_DIR/out-rollout-observed-extra-digest"
pass "rollout source validation allows extra observed sidecar digest"

SOURCE_FORBIDDEN_DIR="$TMP_DIR/source-report-forbidden-material"
STALE_OUTPUT_DIR="$TMP_DIR/out-stale-cleanup"
write_fixture_set "$SOURCE_FORBIDDEN_DIR" source-report-forbidden-material
run_online_path \
  "$VALID_DIR" \
  "online/use_existing" \
  "$VALID_DIR/online-use-existing" \
  "$STALE_OUTPUT_DIR"
[[ -f "$STALE_OUTPUT_DIR/deployment-path-report.json" ]] || fail "stale cleanup setup did not write path report"
[[ -f "$STALE_OUTPUT_DIR/deployment-path-finalizer-manifest.json" ]] || fail "stale cleanup setup did not write finalizer manifest"
[[ -d "$STALE_OUTPUT_DIR/source-evidence" ]] || fail "stale cleanup setup did not write source evidence"
if run_online_path \
  "$SOURCE_FORBIDDEN_DIR" \
  "online/use_existing" \
  "$SOURCE_FORBIDDEN_DIR/online-use-existing" \
  "$STALE_OUTPUT_DIR" >"$TMP_DIR/deployment-path-source-forbidden.out" 2>&1; then
  fail "source report with forbidden secret material should fail"
fi
grep -Fq "source evidence material finalized_step_report route-smoke" "$TMP_DIR/deployment-path-source-forbidden.out" || \
  fail "source report forbidden secret material failure message did not explain blocker"
[[ ! -e "$STALE_OUTPUT_DIR/deployment-path-report.json" ]] || fail "failed finalizer left stale deployment path report"
[[ ! -e "$STALE_OUTPUT_DIR/deployment-path-finalizer-manifest.json" ]] || fail "failed finalizer left stale finalizer manifest"
[[ ! -e "$STALE_OUTPUT_DIR/source-evidence" ]] || fail "failed finalizer left stale source evidence"
pass "finalizer scans source evidence before copy and rejects forbidden secret keys"

MISSING_SMOKE_DIR="$TMP_DIR/missing-smoke"
write_fixture_set "$MISSING_SMOKE_DIR" missing-smoke
if run_online_path \
  "$MISSING_SMOKE_DIR" \
  "online/use_existing" \
  "$MISSING_SMOKE_DIR/online-use-existing" \
  "$TMP_DIR/out-missing-smoke" >"$TMP_DIR/deployment-path-missing-smoke.out" 2>&1; then
  fail "missing smoke should fail"
fi
grep -Fq "missing required step: smoke" "$TMP_DIR/deployment-path-missing-smoke.out" || \
  fail "missing smoke failure message did not explain blocker"
pass "missing source step fails fast"

SERVER_DRY_RUN_DIR="$TMP_DIR/server-dry-run"
write_fixture_set "$SERVER_DRY_RUN_DIR" server-dry-run
if run_online_path \
  "$SERVER_DRY_RUN_DIR" \
  "online/use_existing" \
  "$SERVER_DRY_RUN_DIR/online-use-existing" \
  "$TMP_DIR/out-server-dry-run" >"$TMP_DIR/deployment-path-server-dry-run.out" 2>&1; then
  fail "server-dry-run should fail"
fi
grep -Fq "mode must be apply" "$TMP_DIR/deployment-path-server-dry-run.out" || \
  fail "server-dry-run failure message did not explain blocker"
pass "non-apply producer evidence fails fast"

SOURCE_GATE_SCOPE_DIR="$TMP_DIR/source-gate-scope-mismatch"
write_fixture_set "$SOURCE_GATE_SCOPE_DIR" source-gate-scope-mismatch
if run_online_path \
  "$SOURCE_GATE_SCOPE_DIR" \
  "online/use_existing" \
  "$SOURCE_GATE_SCOPE_DIR/online-use-existing" \
  "$TMP_DIR/out-source-gate-scope-mismatch" >"$TMP_DIR/deployment-path-source-gate-scope.out" 2>&1; then
  fail "source deployment gate report with wrong scope should fail"
fi
grep -Fq "online deployment gate report.scope must be online_deployment_gate_only" "$TMP_DIR/deployment-path-source-gate-scope.out" || \
  fail "source deployment gate scope failure message did not explain blocker"
pass "source deployment gate scope is bound before ledger finalization"

MISSING_AIRGAP_PREFLIGHT_DIR="$TMP_DIR/missing-airgap-target-preflight"
write_fixture_set "$MISSING_AIRGAP_PREFLIGHT_DIR" missing-airgap-target-preflight
if run_airgap_path \
  "$MISSING_AIRGAP_PREFLIGHT_DIR" \
  "airgap/use_existing" \
  "$MISSING_AIRGAP_PREFLIGHT_DIR/airgap-use-existing" \
  "$TMP_DIR/out-missing-airgap-target-preflight" >"$TMP_DIR/deployment-path-missing-airgap-preflight.out" 2>&1; then
  fail "missing airgap target-preflight should fail"
fi
grep -Fq "missing required step: target-preflight" "$TMP_DIR/deployment-path-missing-airgap-preflight.out" || \
  fail "missing airgap target-preflight failure message did not explain blocker"
pass "airgap path requires target-preflight source evidence"

if run_online_path \
  "$VALID_DIR" \
  "online/install_substrates" \
  "$VALID_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-confirmation" >"$TMP_DIR/deployment-path-install-confirmation.out" 2>&1; then
  fail "missing install confirmation should fail"
fi
grep -Fq "install_substrates paths require" "$TMP_DIR/deployment-path-install-confirmation.out" || \
  fail "missing install confirmation failure message did not explain blocker"
pass "install_substrates requires explicit install report and confirmation"

DUPLICATE_REQUIRED_IMAGE_DIR="$TMP_DIR/duplicate-required-image-id"
write_fixture_set "$DUPLICATE_REQUIRED_IMAGE_DIR" duplicate-required-image-id
if run_online_path \
  "$DUPLICATE_REQUIRED_IMAGE_DIR" \
  "online/use_existing" \
  "$DUPLICATE_REQUIRED_IMAGE_DIR/online-use-existing" \
  "$TMP_DIR/out-duplicate-required-image-id" >"$TMP_DIR/deployment-path-required-images.out" 2>&1; then
  fail "duplicate required image ids should fail"
fi
grep -Fq "required_image_ids must match" "$TMP_DIR/deployment-path-required-images.out" || \
  fail "duplicate required image ids failure message did not explain blocker"
pass "deploy template image set drift fails fast"

CONTRACT_IMAGE_CLOSURE_DIR="$TMP_DIR/contract-image-inventory-closure-drift"
write_fixture_set "$CONTRACT_IMAGE_CLOSURE_DIR" contract-image-inventory-closure-drift
if run_online_path \
  "$CONTRACT_IMAGE_CLOSURE_DIR" \
  "online/use_existing" \
  "$CONTRACT_IMAGE_CLOSURE_DIR/online-use-existing" \
  "$TMP_DIR/out-contract-image-inventory-closure" >"$TMP_DIR/deployment-path-contract-image-closure.out" 2>&1; then
  fail "release contract image inventory closure drift should fail"
fi
grep -Fq "release_contract.deploy_template_package.required_image_ids must exactly match release_contract.deploy_image_inventory ids" "$TMP_DIR/deployment-path-contract-image-closure.out" || \
  fail "release contract image inventory closure failure message did not explain blocker"
pass "release contract image inventory closure fails fast"

STEP_FORMAL_VERDICT_DIR="$TMP_DIR/step-formal-verdict"
write_fixture_set "$STEP_FORMAL_VERDICT_DIR" step-formal-verdict
if run_online_path \
  "$STEP_FORMAL_VERDICT_DIR" \
  "online/use_existing" \
  "$STEP_FORMAL_VERDICT_DIR/online-use-existing" \
  "$TMP_DIR/out-step-formal-verdict" >"$TMP_DIR/deployment-path-step-formal-verdict.out" 2>&1; then
  fail "step report formal verdict should fail"
fi
grep -Fq "step report must not issue formal_verdict" "$TMP_DIR/deployment-path-step-formal-verdict.out" || \
  fail "step formal verdict failure message did not explain blocker"
pass "step-level formal verdict fails fast"

STEP_STATUS_ONLY_DIR="$TMP_DIR/step-status-only"
write_fixture_set "$STEP_STATUS_ONLY_DIR" step-status-only
if run_online_path \
  "$STEP_STATUS_ONLY_DIR" \
  "online/use_existing" \
  "$STEP_STATUS_ONLY_DIR/online-use-existing" \
  "$TMP_DIR/out-step-status-only" >"$TMP_DIR/deployment-path-step-status-only.out" 2>&1; then
  fail "status-only step report should fail"
fi
grep -Fq "target-preflight step report.schema must be agentsmith.target-preflight-report/v1" "$TMP_DIR/deployment-path-step-status-only.out" || \
  fail "status-only step failure message did not explain schema blocker"
pass "source step reports require schema-bound evidence"

EMPTY_PREFLIGHT_DIR="$TMP_DIR/empty-target-preflight-prerequisites"
write_fixture_set "$EMPTY_PREFLIGHT_DIR" empty-target-preflight-prerequisites
if run_online_path \
  "$EMPTY_PREFLIGHT_DIR" \
  "online/use_existing" \
  "$EMPTY_PREFLIGHT_DIR/online-use-existing" \
  "$TMP_DIR/out-empty-target-preflight-prerequisites" >"$TMP_DIR/deployment-path-empty-preflight.out" 2>&1; then
  fail "empty target-preflight prerequisite evidence should fail"
fi
grep -Fq "target-preflight step report.substrate_truth.services_count must be greater than zero" "$TMP_DIR/deployment-path-empty-preflight.out" || \
  fail "empty target-preflight failure message did not explain blocker"
pass "target-preflight source reports reject empty substrate and prerequisite evidence"

BUNDLE_SCOPE_DIR="$TMP_DIR/bundle-check-scope-mismatch"
write_fixture_set "$BUNDLE_SCOPE_DIR" bundle-check-scope-mismatch
if run_airgap_path \
  "$BUNDLE_SCOPE_DIR" \
  "airgap/use_existing" \
  "$BUNDLE_SCOPE_DIR/airgap-use-existing" \
  "$TMP_DIR/out-bundle-check-scope-mismatch" >"$TMP_DIR/deployment-path-bundle-scope.out" 2>&1; then
  fail "bundle check report with wrong scope should fail"
fi
grep -Fq "airgap bundle check report.scope must be airgap_bundle_manifest_check_only" "$TMP_DIR/deployment-path-bundle-scope.out" || \
  fail "bundle check scope failure message did not explain blocker"
pass "airgap bundle-check source scope is bound before ledger finalization"

AIRGAP_IMAGE_MAP_SEMANTIC_DIR="$TMP_DIR/airgap-image-map-mirror-required-false"
write_fixture_set "$AIRGAP_IMAGE_MAP_SEMANTIC_DIR" airgap-image-map-mirror-required-false
if run_airgap_path \
  "$AIRGAP_IMAGE_MAP_SEMANTIC_DIR" \
  "airgap/use_existing" \
  "$AIRGAP_IMAGE_MAP_SEMANTIC_DIR/airgap-use-existing" \
  "$TMP_DIR/out-airgap-image-map-mirror-required-false" >"$TMP_DIR/deployment-path-airgap-image-map-semantic.out" 2>&1; then
  fail "airgap image-map with digest-refreshed bad mirror semantics should fail"
fi
grep -Fq "airgap image map.mirror_required must be true" "$TMP_DIR/deployment-path-airgap-image-map-semantic.out" || \
  fail "airgap image-map semantic failure message did not explain blocker"
pass "finalizer revalidates airgap image-map mirror semantics after digest refresh"

SCHEMA_RENDER_DIR="$TMP_DIR/schema-shaped-render-check"
write_fixture_set "$SCHEMA_RENDER_DIR" schema-shaped-render-check
if run_online_path \
  "$SCHEMA_RENDER_DIR" \
  "online/use_existing" \
  "$SCHEMA_RENDER_DIR/online-use-existing" \
  "$TMP_DIR/out-schema-shaped-render-check" >"$TMP_DIR/deployment-path-schema-render.out" 2>&1; then
  fail "render-check schema-shaped fake report should fail"
fi
grep -Fq "render-check step report.images[0].image is required" "$TMP_DIR/deployment-path-schema-render.out" || \
  fail "schema-shaped render-check failure message did not explain blocker"
pass "render-check source reports require manifest and image evidence"

RENDER_WRONG_DIGEST_DIR="$TMP_DIR/render-check-image-digest-legal-drift"
write_fixture_set "$RENDER_WRONG_DIGEST_DIR" render-check-image-digest-legal-drift
if run_online_path \
  "$RENDER_WRONG_DIGEST_DIR" \
  "online/use_existing" \
  "$RENDER_WRONG_DIGEST_DIR/online-use-existing" \
  "$TMP_DIR/out-render-check-image-digest-legal-drift" >"$TMP_DIR/deployment-path-render-check-wrong-digest.out" 2>&1; then
  fail "render-check same inventory_id with wrong digest should fail"
fi
grep -Fq "render-check step report.images[0].digest must match release contract deploy_image_inventory digest for inventory_id agentsmith_app" "$TMP_DIR/deployment-path-render-check-wrong-digest.out" || \
  fail "render-check wrong digest failure message did not explain blocker"
pass "render-check source validation rejects same inventory_id with wrong digest"

SCHEMA_APPLY_DIR="$TMP_DIR/schema-shaped-apply"
write_fixture_set "$SCHEMA_APPLY_DIR" schema-shaped-apply
if run_online_path \
  "$SCHEMA_APPLY_DIR" \
  "online/use_existing" \
  "$SCHEMA_APPLY_DIR/online-use-existing" \
  "$TMP_DIR/out-schema-shaped-apply" >"$TMP_DIR/deployment-path-schema-apply.out" 2>&1; then
  fail "apply schema-shaped fake report should fail"
fi
missing_apply_ref_field="kind"
grep -Fq "apply step report.resource_refs[0].${missing_apply_ref_field} is required" "$TMP_DIR/deployment-path-schema-apply.out" || \
  fail "schema-shaped apply failure message did not explain blocker"
pass "apply source reports require typed resource evidence"

ROLLOUT_EXPECTED_DIGESTS_DIR="$TMP_DIR/rollout-expected-digest-missing-digest"
write_fixture_set "$ROLLOUT_EXPECTED_DIGESTS_DIR" rollout-expected-digest-missing-digest
if run_online_path \
  "$ROLLOUT_EXPECTED_DIGESTS_DIR" \
  "online/use_existing" \
  "$ROLLOUT_EXPECTED_DIGESTS_DIR/online-use-existing" \
  "$TMP_DIR/out-rollout-missing-expected-image-digests" >"$TMP_DIR/deployment-path-rollout-expected-digests.out" 2>&1; then
  fail "rollout report with incomplete expected image digest object should fail"
fi
grep -Fq "rollout step report.expected_image_digests[0].digest is required" "$TMP_DIR/deployment-path-rollout-expected-digests.out" || \
  fail "rollout expected image digests failure message did not explain blocker"
pass "rollout source reports require expected image digest evidence"

ROUTE_SMOKE_ROLLOUT_BINDING_DIR="$TMP_DIR/route-smoke-rollout-digest-mismatch"
write_fixture_set "$ROUTE_SMOKE_ROLLOUT_BINDING_DIR" route-smoke-rollout-digest-mismatch
if run_online_path \
  "$ROUTE_SMOKE_ROLLOUT_BINDING_DIR" \
  "online/use_existing" \
  "$ROUTE_SMOKE_ROLLOUT_BINDING_DIR/online-use-existing" \
  "$TMP_DIR/out-route-smoke-rollout-digest-mismatch" >"$TMP_DIR/deployment-path-smoke-rollout-binding.out" 2>&1; then
  fail "route smoke rollout report digest mismatch should fail"
fi
grep -Fq "smoke step report.rollout_report.input_sha256 must match rollout step report digest" "$TMP_DIR/deployment-path-smoke-rollout-binding.out" || \
  fail "route smoke rollout digest binding failure message did not explain blocker"
pass "route-smoke source report is bound to same-path rollout report digest"

AIRGAP_RENDER_BINDING_DIR="$TMP_DIR/render-check-bundle-manifest-digest-mismatch"
write_fixture_set "$AIRGAP_RENDER_BINDING_DIR" render-check-bundle-manifest-digest-mismatch
if run_airgap_path \
  "$AIRGAP_RENDER_BINDING_DIR" \
  "airgap/use_existing" \
  "$AIRGAP_RENDER_BINDING_DIR/airgap-use-existing" \
  "$TMP_DIR/out-render-check-bundle-manifest-digest-mismatch" >"$TMP_DIR/deployment-path-render-binding.out" 2>&1; then
  fail "airgap bundle render-check manifest digest mismatch should fail"
fi
grep -Fq "airgap-bundle-render-check step report.digest_summary.bundle_manifest_input_sha256 must match bound input" "$TMP_DIR/deployment-path-render-binding.out" || \
  fail "airgap render-check binding failure message did not explain blocker"
pass "airgap bundle render-check is bound to bundle manifest digest"

AIRGAP_LOAD_BINDING_DIR="$TMP_DIR/image-load-bundle-check-digest-mismatch"
write_fixture_set "$AIRGAP_LOAD_BINDING_DIR" image-load-bundle-check-digest-mismatch
if run_airgap_path \
  "$AIRGAP_LOAD_BINDING_DIR" \
  "airgap/use_existing" \
  "$AIRGAP_LOAD_BINDING_DIR/airgap-use-existing" \
  "$TMP_DIR/out-image-load-bundle-check-digest-mismatch" >"$TMP_DIR/deployment-path-image-load-binding.out" 2>&1; then
  fail "airgap image load bundle-check digest mismatch should fail"
fi
grep -Fq "airgap-image-load step report.digest_summary.airgap_bundle_check_report_input_sha256 must match bound input" "$TMP_DIR/deployment-path-image-load-binding.out" || \
  fail "airgap image-load binding failure message did not explain blocker"
pass "airgap image load is bound to bundle check digest"

MISSING_INSTALL_CONTRACT_DIGEST_DIR="$TMP_DIR/missing-install-release-contract-digest"
write_fixture_set "$MISSING_INSTALL_CONTRACT_DIGEST_DIR" missing-install-release-contract-digest
if run_online_path \
  "$MISSING_INSTALL_CONTRACT_DIGEST_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_CONTRACT_DIGEST_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-release-contract-digest" \
  --substrate-install-report "$MISSING_INSTALL_CONTRACT_DIGEST_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-contract-digest.out" 2>&1; then
  fail "substrate install report missing release contract digest should fail"
fi
grep -Fq "substrate install report.release_contract_digest is required" "$TMP_DIR/deployment-path-install-contract-digest.out" || \
  fail "missing install release contract digest failure message did not explain blocker"
pass "install_substrates requires release contract digest binding"

INSTALL_SERVER_DRY_RUN_DIR="$TMP_DIR/install-server-dry-run"
write_fixture_set "$INSTALL_SERVER_DRY_RUN_DIR" install-server-dry-run
if run_online_path \
  "$INSTALL_SERVER_DRY_RUN_DIR" \
  "online/install_substrates" \
  "$INSTALL_SERVER_DRY_RUN_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-server-dry-run" \
  --substrate-install-report "$INSTALL_SERVER_DRY_RUN_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-server-dry-run.out" 2>&1; then
  fail "server-dry-run substrate install report should fail"
fi
grep -Fq "substrate_install_report.mode must be apply" "$TMP_DIR/deployment-path-install-server-dry-run.out" || \
  fail "server-dry-run substrate install failure message did not explain blocker"
pass "install_substrates rejects substrate install server-dry-run proof"

INSTALL_DRY_RUN_SUMMARY_DIR="$TMP_DIR/install-kubectl-apply-dry-run-summary"
write_fixture_set "$INSTALL_DRY_RUN_SUMMARY_DIR" install-kubectl-apply-dry-run-summary
if run_online_path \
  "$INSTALL_DRY_RUN_SUMMARY_DIR" \
  "online/install_substrates" \
  "$INSTALL_DRY_RUN_SUMMARY_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-kubectl-apply-dry-run-summary" \
  --substrate-install-report "$INSTALL_DRY_RUN_SUMMARY_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-kubectl-apply-dry-run-summary.out" 2>&1; then
  fail "apply-mode substrate install report with dry_run server should fail"
fi
grep -Fq "substrate_install_report.checks.kubectl_apply.command_summary.dry_run must be none for apply" "$TMP_DIR/deployment-path-install-kubectl-apply-dry-run-summary.out" || \
  fail "installer apply dry_run summary failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/deployment-path-install-kubectl-apply-dry-run-summary.out"; then
  fail "installer dry_run summary negative hit digest mismatch instead of semantic validation"
fi
pass "install_substrates finalizer rejects apply-mode installer reports with dry_run server"

INSTALL_DRY_RUN_COMMAND_DIR="$TMP_DIR/install-kubectl-apply-dry-run-command"
write_fixture_set "$INSTALL_DRY_RUN_COMMAND_DIR" install-kubectl-apply-dry-run-command
if run_online_path \
  "$INSTALL_DRY_RUN_COMMAND_DIR" \
  "online/install_substrates" \
  "$INSTALL_DRY_RUN_COMMAND_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-kubectl-apply-dry-run-command" \
  --substrate-install-report "$INSTALL_DRY_RUN_COMMAND_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-kubectl-apply-dry-run-command.out" 2>&1; then
  fail "apply-mode substrate install report with --dry-run command should fail"
fi
grep -Fq "substrate_install_report.checks.kubectl_apply.command_summary.command must not include --dry-run for apply" "$TMP_DIR/deployment-path-install-kubectl-apply-dry-run-command.out" || \
  fail "installer apply dry-run command failure message did not explain blocker"
if grep -Fq "sha256 must match" "$TMP_DIR/deployment-path-install-kubectl-apply-dry-run-command.out"; then
  fail "installer dry-run command negative hit digest mismatch instead of semantic validation"
fi
pass "install_substrates finalizer rejects apply-mode installer reports whose command dry-runs"

MISSING_INSTALL_INPUT_DIGESTS_DIR="$TMP_DIR/missing-install-input-digests"
write_fixture_set "$MISSING_INSTALL_INPUT_DIGESTS_DIR" missing-install-input-digests
if run_online_path \
  "$MISSING_INSTALL_INPUT_DIGESTS_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_INPUT_DIGESTS_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-input-digests" \
  --substrate-install-report "$MISSING_INSTALL_INPUT_DIGESTS_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-input-digests.out" 2>&1; then
  fail "substrate install report missing input digest bindings should fail"
fi
grep -Fq "substrate_install_report.inputs must be an object" "$TMP_DIR/deployment-path-install-input-digests.out" || \
  fail "missing install input digest failure message did not explain blocker"
pass "install_substrates finalizer requires substrate install input digest bindings"

MISSING_INSTALL_NAMESPACE_SCOPE_DIR="$TMP_DIR/missing-install-namespace-scope-check"
write_fixture_set "$MISSING_INSTALL_NAMESPACE_SCOPE_DIR" missing-install-namespace-scope-check
if run_online_path \
  "$MISSING_INSTALL_NAMESPACE_SCOPE_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_NAMESPACE_SCOPE_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-namespace-scope" \
  --substrate-install-report "$MISSING_INSTALL_NAMESPACE_SCOPE_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-namespace-scope.out" 2>&1; then
  fail "substrate install report missing namespace scope proof should fail"
fi
grep -Fq "substrate_install_report.checks.namespace_scope must be an object" "$TMP_DIR/deployment-path-install-namespace-scope.out" || \
  fail "missing install namespace scope proof failure message did not explain blocker"
pass "install_substrates finalizer requires namespace scope proof summary"

MISSING_INSTALL_RESOURCE_REFS_DIR="$TMP_DIR/missing-install-resource-refs"
write_fixture_set "$MISSING_INSTALL_RESOURCE_REFS_DIR" missing-install-resource-refs
if run_online_path \
  "$MISSING_INSTALL_RESOURCE_REFS_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_RESOURCE_REFS_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-resource-refs" \
  --substrate-install-report "$MISSING_INSTALL_RESOURCE_REFS_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-resource-refs.out" 2>&1; then
  fail "substrate install report missing resource refs should fail"
fi
grep -Fq "substrate_install_report.resource_refs must be an array" "$TMP_DIR/deployment-path-install-resource-refs.out" || \
  fail "missing install resource refs failure message did not explain blocker"
pass "install_substrates finalizer requires resource refs materiality"

INSTALL_SECRET_RESOURCE_REF_DIR="$TMP_DIR/install-secret-resource-ref"
write_fixture_set "$INSTALL_SECRET_RESOURCE_REF_DIR" install-secret-resource-ref
if run_online_path \
  "$INSTALL_SECRET_RESOURCE_REF_DIR" \
  "online/install_substrates" \
  "$INSTALL_SECRET_RESOURCE_REF_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-secret-resource-ref" \
  --substrate-install-report "$INSTALL_SECRET_RESOURCE_REF_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-secret-resource-ref.out" 2>&1; then
  fail "substrate install report Secret resource_ref should fail"
fi
grep -Fq "substrate_install_report.resource_refs[0].kind Secret is not allowed for substrate install" "$TMP_DIR/deployment-path-install-secret-resource-ref.out" || \
  fail "Secret installer resource_ref failure message did not explain allowlist blocker"
pass "install_substrates finalizer rejects Secret resource_refs"

INSTALL_KUBECTL_SECRET_REF_DIR="$TMP_DIR/install-kubectl-secret-resource-ref"
write_fixture_set "$INSTALL_KUBECTL_SECRET_REF_DIR" install-kubectl-secret-resource-ref
if run_online_path \
  "$INSTALL_KUBECTL_SECRET_REF_DIR" \
  "online/install_substrates" \
  "$INSTALL_KUBECTL_SECRET_REF_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-kubectl-secret-resource-ref" \
  --substrate-install-report "$INSTALL_KUBECTL_SECRET_REF_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-kubectl-secret-resource-ref.out" 2>&1; then
  fail "substrate install report Secret kubectl_resource_ref should fail"
fi
grep -Fq "substrate_install_report.kubectl_resource_refs[0] resource secret is not allowed for substrate install" "$TMP_DIR/deployment-path-install-kubectl-secret-resource-ref.out" || \
  fail "Secret installer kubectl_resource_ref failure message did not explain allowlist blocker"
pass "install_substrates finalizer rejects Secret kubectl_resource_refs"

INSTALL_RESOURCE_REF_NAMESPACE_DIR="$TMP_DIR/install-resource-ref-namespace-mismatch"
write_fixture_set "$INSTALL_RESOURCE_REF_NAMESPACE_DIR" install-resource-ref-namespace-mismatch
if run_online_path \
  "$INSTALL_RESOURCE_REF_NAMESPACE_DIR" \
  "online/install_substrates" \
  "$INSTALL_RESOURCE_REF_NAMESPACE_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-resource-ref-namespace" \
  --substrate-install-report "$INSTALL_RESOURCE_REF_NAMESPACE_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-resource-ref-namespace.out" 2>&1; then
  fail "substrate install report resource_ref namespace mismatch should fail"
fi
grep -Fq "substrate_install_report.resource_refs[0].namespace must match substrate install effective namespace" "$TMP_DIR/deployment-path-install-resource-ref-namespace.out" || \
  fail "installer resource_ref namespace mismatch failure message did not explain blocker"
pass "install_substrates finalizer rejects resource_refs outside effective namespace"

MISSING_INSTALL_TARGET_PREREQUISITES_DIR="$TMP_DIR/missing-install-target-prerequisites"
write_fixture_set "$MISSING_INSTALL_TARGET_PREREQUISITES_DIR" missing-install-target-prerequisites
if run_online_path \
  "$MISSING_INSTALL_TARGET_PREREQUISITES_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_TARGET_PREREQUISITES_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-target-prerequisites" \
  --substrate-install-report "$MISSING_INSTALL_TARGET_PREREQUISITES_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-target-prerequisites.out" 2>&1; then
  fail "substrate install report missing target prerequisites binding should fail"
fi
grep -Fq "substrate_install_report.inputs.target_prerequisites must be an object" "$TMP_DIR/deployment-path-install-target-prerequisites.out" || \
  fail "missing install target prerequisites failure message did not explain blocker"
pass "install_substrates finalizer requires target prerequisites input binding"

INSTALL_TARGET_PREREQUISITES_DIGEST_DIR="$TMP_DIR/install-target-prerequisites-digest-mismatch"
write_fixture_set "$INSTALL_TARGET_PREREQUISITES_DIGEST_DIR" install-target-prerequisites-digest-mismatch
if run_online_path \
  "$INSTALL_TARGET_PREREQUISITES_DIGEST_DIR" \
  "online/install_substrates" \
  "$INSTALL_TARGET_PREREQUISITES_DIGEST_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-target-prerequisites-digest" \
  --substrate-install-report "$INSTALL_TARGET_PREREQUISITES_DIGEST_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-target-prerequisites-digest.out" 2>&1; then
  fail "substrate install report target prerequisites digest mismatch should fail"
fi
grep -Fq "substrate_install_report.inputs.target_prerequisites.input_sha256 must match target-preflight step report.target_prerequisites.input_sha256" "$TMP_DIR/deployment-path-install-target-prerequisites-digest.out" || \
  fail "target prerequisites digest mismatch failure message did not explain blocker"
pass "install_substrates finalizer binds installer target prerequisites digest to target preflight"

MISSING_INSTALL_APPLY_DIGEST_DIR="$TMP_DIR/missing-install-apply-resource-digest"
write_fixture_set "$MISSING_INSTALL_APPLY_DIGEST_DIR" missing-install-apply-resource-digest
if run_online_path \
  "$MISSING_INSTALL_APPLY_DIGEST_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_APPLY_DIGEST_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-apply-resource-digest" \
  --substrate-install-report "$MISSING_INSTALL_APPLY_DIGEST_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-apply-digest-missing.out" 2>&1; then
  fail "substrate install report missing apply artifact digest should fail"
fi
grep -Fq "substrate_install_report.inputs.substrate_install_inputs.apply_resource_list_sha256 is required" "$TMP_DIR/deployment-path-install-apply-digest-missing.out" || \
  fail "missing install apply artifact digest failure message did not explain blocker"
pass "install_substrates finalizer requires apply artifact digest binding"

INSTALL_APPLY_DIGEST_MISMATCH_DIR="$TMP_DIR/install-apply-resource-digest-mismatch"
write_fixture_set "$INSTALL_APPLY_DIGEST_MISMATCH_DIR" install-apply-resource-digest-mismatch
if run_online_path \
  "$INSTALL_APPLY_DIGEST_MISMATCH_DIR" \
  "online/install_substrates" \
  "$INSTALL_APPLY_DIGEST_MISMATCH_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-apply-resource-digest-mismatch" \
  --substrate-install-report "$INSTALL_APPLY_DIGEST_MISMATCH_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-apply-digest-mismatch.out" 2>&1; then
  fail "substrate install report apply artifact digest mismatch should fail"
fi
grep -Fq "install_parameters_sha256 must bind install input, resource list, apply artifact, and effective namespace" "$TMP_DIR/deployment-path-install-apply-digest-mismatch.out" || \
  fail "install apply artifact digest mismatch failure message did not explain blocker"
pass "install_substrates finalizer binds install parameters to exact apply artifact digest"

INSTALL_EFFECTIVE_NAMESPACE_MISMATCH_DIR="$TMP_DIR/install-effective-namespace-mismatch"
write_fixture_set "$INSTALL_EFFECTIVE_NAMESPACE_MISMATCH_DIR" install-effective-namespace-mismatch
if run_online_path \
  "$INSTALL_EFFECTIVE_NAMESPACE_MISMATCH_DIR" \
  "online/install_substrates" \
  "$INSTALL_EFFECTIVE_NAMESPACE_MISMATCH_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-effective-namespace-mismatch" \
  --substrate-install-report "$INSTALL_EFFECTIVE_NAMESPACE_MISMATCH_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-effective-namespace.out" 2>&1; then
  fail "substrate install report effective namespace mismatch should fail"
fi
grep -Fq "effective_namespace must match target-preflight step report.target_prerequisites.namespace" "$TMP_DIR/deployment-path-install-effective-namespace.out" || \
  fail "install effective namespace mismatch failure message did not explain blocker"
pass "install_substrates finalizer binds effective namespace to target preflight namespace"

MISSING_INSTALL_SERVICES_DIR="$TMP_DIR/missing-install-installed-services"
write_fixture_set "$MISSING_INSTALL_SERVICES_DIR" missing-install-installed-services
if run_online_path \
  "$MISSING_INSTALL_SERVICES_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_SERVICES_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-installed-services" \
  --substrate-install-report "$MISSING_INSTALL_SERVICES_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-services.out" 2>&1; then
  fail "substrate install report missing installed services should fail"
fi
grep -Fq "substrate_install_report.installed_services must be an array" "$TMP_DIR/deployment-path-install-services.out" || \
  fail "missing install services failure message did not explain blocker"
pass "install_substrates requires installed service names"

MISSING_INSTALL_PRODUCER_DIR="$TMP_DIR/missing-install-producer"
write_fixture_set "$MISSING_INSTALL_PRODUCER_DIR" missing-install-producer
if run_online_path \
  "$MISSING_INSTALL_PRODUCER_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_PRODUCER_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-producer" \
  --substrate-install-report "$MISSING_INSTALL_PRODUCER_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-producer.out" 2>&1; then
  fail "substrate install report without repo-owned producer marker should fail"
fi
grep -Fq "substrate_install_report.producer is required" "$TMP_DIR/deployment-path-install-producer.out" || \
  fail "missing install producer failure message did not explain blocker"
pass "install_substrates requires repo-owned installer producer marker"

MISSING_INSTALL_OUTPUT_TRUTH_DIR="$TMP_DIR/missing-install-output-substrate-truth-digest"
write_fixture_set "$MISSING_INSTALL_OUTPUT_TRUTH_DIR" missing-install-output-substrate-truth-digest
if run_online_path \
  "$MISSING_INSTALL_OUTPUT_TRUTH_DIR" \
  "online/install_substrates" \
  "$MISSING_INSTALL_OUTPUT_TRUTH_DIR/online-install-substrates" \
  "$TMP_DIR/out-missing-install-output-truth" \
  --substrate-install-report "$MISSING_INSTALL_OUTPUT_TRUTH_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-output-truth.out" 2>&1; then
  fail "substrate install report missing output substrate truth digest should fail"
fi
grep -Fq "substrate_install_report.output_substrate_truth_digest is required" "$TMP_DIR/deployment-path-install-output-truth.out" || \
  fail "missing output substrate truth digest failure message did not explain blocker"
pass "install_substrates requires output substrate truth digest"

INSTALL_OUTPUT_TRUTH_BINDING_DIR="$TMP_DIR/install-output-substrate-truth-digest-mismatch"
write_fixture_set "$INSTALL_OUTPUT_TRUTH_BINDING_DIR" install-output-substrate-truth-digest-mismatch
if run_online_path \
  "$INSTALL_OUTPUT_TRUTH_BINDING_DIR" \
  "online/install_substrates" \
  "$INSTALL_OUTPUT_TRUTH_BINDING_DIR/online-install-substrates" \
  "$TMP_DIR/out-install-output-truth-binding" \
  --substrate-install-report "$INSTALL_OUTPUT_TRUTH_BINDING_DIR/online-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-online-install-10001" >"$TMP_DIR/deployment-path-install-output-truth-binding.out" 2>&1; then
  fail "substrate install output truth digest mismatch should fail"
fi
grep -Fq "substrate_install_report.output_substrate_truth_digest must match target-preflight step report.substrate_truth.input_sha256" "$TMP_DIR/deployment-path-install-output-truth-binding.out" || \
  fail "install output substrate truth binding failure message did not explain blocker"
pass "install_substrates output truth digest is bound to same-path target-preflight truth input"

AIRGAP_RENDER_INSTALL_TRUTH_BINDING_DIR="$TMP_DIR/render-check-substrate-truth-install-digest-mismatch"
write_fixture_set "$AIRGAP_RENDER_INSTALL_TRUTH_BINDING_DIR" render-check-substrate-truth-install-digest-mismatch
if run_airgap_path \
  "$AIRGAP_RENDER_INSTALL_TRUTH_BINDING_DIR" \
  "airgap/install_substrates" \
  "$AIRGAP_RENDER_INSTALL_TRUTH_BINDING_DIR/airgap-install-substrates" \
  "$TMP_DIR/out-render-check-substrate-truth-install-digest-mismatch" \
  --substrate-install-report "$AIRGAP_RENDER_INSTALL_TRUTH_BINDING_DIR/airgap-install-substrates/substrate-install-report.json" \
  --confirm-install-substrates "operator-airgap-install-10001" >"$TMP_DIR/deployment-path-render-install-truth-binding.out" 2>&1; then
  fail "airgap render-check substrate truth digest mismatch should fail"
fi
grep -Fq "airgap-bundle-render-check step report.digest_summary.substrate_truth_input_sha256 must match substrate_install_report.output_substrate_truth_digest" "$TMP_DIR/deployment-path-render-install-truth-binding.out" || \
  fail "airgap render-check substrate truth digest mismatch failure message did not explain blocker"
pass "airgap install_substrates binds offline render-check substrate truth digest to installer output truth"

echo "PASS: deployment path report finalization focused guard"
