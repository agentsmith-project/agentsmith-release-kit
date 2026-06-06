import crypto from 'node:crypto';
import path from 'node:path';

import { validateImageMapEvidence } from './image-map-validation.mjs';
import {
  SUBSTRATE_INSTALL_RESOURCE_ALLOWLIST_BY_KIND,
  substrateInstallAllowedKindList,
  substrateInstallAllowedKubectlResourceList
} from './kubernetes-namespace-scope-guard.mjs';

export const ONLINE_GATE_SCHEMA = 'agentsmith.online-deployment-gate/v1';
export const AIRGAP_GATE_SCHEMA = 'agentsmith.airgap-deployment-gate/v1';
export const AIRGAP_BUNDLE_CHECK_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
export const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
export const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
export const IMAGE_MAP_SCOPE = 'image_map_only';
export const SUBSTRATE_INSTALL_SCHEMA = 'agentsmith.substrate-install-report/v1';
export const SUBSTRATE_INSTALL_SCOPE = 'substrate_install_only';
export const TARGET_PREFLIGHT_SCHEMA = 'agentsmith.target-preflight-report/v1';
export const RENDER_CHECK_SCHEMA = 'agentsmith.render-check-report/v1';
export const APPLY_SCHEMA = 'agentsmith.kubernetes-apply-report/v1';
export const ROLLOUT_SCHEMA = 'agentsmith.kubernetes-rollout-report/v1';
export const ROUTE_SMOKE_SCHEMA = 'agentsmith.route-smoke-report/v1';
export const AIRGAP_IMAGE_LOAD_SCHEMA = 'agentsmith.airgap-image-load-report/v1';
export const AIRGAP_BUNDLE_RENDER_CHECK_SCHEMA = 'agentsmith.airgap-bundle-render-check-report/v1';
export const AIRGAP_BUNDLE_CHECK_SCOPE = 'airgap_bundle_manifest_check_only';

const SUBSTRATE_CONNECTION_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
const TARGET_PREREQUISITES_SCHEMA = 'agentsmith.target-prerequisites.truth/v1';
const SUBSTRATE_PACK_MANIFEST_SCHEMA = 'agentsmith.substrate-pack-manifest/v1';
const SUBSTRATE_INSTALL_INPUTS_SCHEMA = 'agentsmith.substrate-install-inputs/v1';
const SUBSTRATE_INSTALL_PRODUCER = 'agentsmith-release-kit-substrate-installer';
const SUBSTRATE_INSTALL_OUTPUT_TRUTH_FILE = 'substrate-truth.json';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const KUBERNETES_NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const SERVICE_NAME_RE = /^[a-z][a-z0-9_-]{0,63}$/;
const SUBSTRATE_INSTALL_ALLOWED_KINDS = substrateInstallAllowedKindList();
const SUBSTRATE_INSTALL_ALLOWED_KUBECTL_RESOURCES = substrateInstallAllowedKubectlResourceList();
const TARGET_PREFLIGHT_SUBSTRATE_SERVICES = [
  'postgresql',
  'mongodb',
  'redis',
  'object_storage',
  'oidc'
];

export const SOURCE_STEP_REPORTS = new Map([
  ['target-preflight', {
    schema: TARGET_PREFLIGHT_SCHEMA,
    scope: 'target_preflight_prerequisite_only'
  }],
  ['render-check', {
    schema: RENDER_CHECK_SCHEMA,
    scope: 'render_check_image_inventory_only'
  }],
  ['apply', {
    schema: APPLY_SCHEMA,
    scope: 'kubernetes_apply_only',
    mode: 'apply'
  }],
  ['rollout', {
    schema: ROLLOUT_SCHEMA,
    scope: 'kubernetes_rollout_imageid_only'
  }],
  ['smoke', {
    schema: ROUTE_SMOKE_SCHEMA,
    scope: 'route_smoke_only'
  }],
  ['airgap-image-load', {
    schema: AIRGAP_IMAGE_LOAD_SCHEMA,
    scope: 'airgap_image_load_only'
  }],
  ['airgap-bundle-render-check', {
    schema: AIRGAP_BUNDLE_RENDER_CHECK_SCHEMA,
    scope: 'airgap_bundle_render_check_only'
  }]
]);

export const FINALIZED_STEP_SOURCE_REPORTS = new Map([
  ['target-preflight', {
    source_step: 'target-preflight',
    source_schema: TARGET_PREFLIGHT_SCHEMA,
    source_scope: 'target_preflight_prerequisite_only'
  }],
  ['render-check', {
    source_step: 'render-check',
    source_schema: RENDER_CHECK_SCHEMA,
    source_scope: 'render_check_image_inventory_only'
  }],
  ['apply', {
    source_step: 'apply',
    source_schema: APPLY_SCHEMA,
    source_scope: 'kubernetes_apply_only'
  }],
  ['rollout', {
    source_step: 'rollout',
    source_schema: ROLLOUT_SCHEMA,
    source_scope: 'kubernetes_rollout_imageid_only'
  }],
  ['route-smoke', {
    source_step: 'smoke',
    source_schema: ROUTE_SMOKE_SCHEMA,
    source_scope: 'route_smoke_only'
  }],
  ['bundle-check', {
    source_step: 'airgap-bundle-check',
    source_schema: AIRGAP_BUNDLE_CHECK_SCHEMA,
    source_scope: AIRGAP_BUNDLE_CHECK_SCOPE
  }],
  ['image-load', {
    source_step: 'airgap-image-load',
    source_schema: AIRGAP_IMAGE_LOAD_SCHEMA,
    source_scope: 'airgap_image_load_only'
  }],
  ['offline-render-check', {
    source_step: 'airgap-bundle-render-check',
    source_schema: AIRGAP_BUNDLE_RENDER_CHECK_SCHEMA,
    source_scope: 'airgap_bundle_render_check_only'
  }],
  ['substrate-install', {
    source_step: 'substrate-install',
    source_schema: SUBSTRATE_INSTALL_SCHEMA,
    source_scope: SUBSTRATE_INSTALL_SCOPE
  }]
]);

export const DEPLOYMENT_GATE_BY_SOURCE = new Map([
  ['online', {
    schema: ONLINE_GATE_SCHEMA,
    scope: 'online_deployment_gate_only'
  }],
  ['airgap', {
    schema: AIRGAP_GATE_SCHEMA,
    scope: 'airgap_deployment_gate_only'
  }]
]);

export const DEPLOYMENT_PATHS = new Map([
  [
    'online/use_existing',
    {
      source: 'online',
      targetProfile: 'existing_kubernetes/external_declared/online',
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['render-check', 'render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ],
  [
    'online/install_substrates',
    {
      source: 'online',
      targetProfile: 'existing_kubernetes/kit_installed/online',
      installSubstrates: true,
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['render-check', 'render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ],
  [
    'airgap/use_existing',
    {
      source: 'airgap',
      targetProfile: 'existing_kubernetes/external_declared/airgap',
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['image-load', 'airgap-image-load'],
        ['offline-render-check', 'airgap-bundle-render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ],
  [
    'airgap/install_substrates',
    {
      source: 'airgap',
      targetProfile: 'existing_kubernetes/kit_installed/airgap',
      installSubstrates: true,
      sourceSteps: [
        ['target-preflight', 'target-preflight'],
        ['image-load', 'airgap-image-load'],
        ['offline-render-check', 'airgap-bundle-render-check'],
        ['apply', 'apply'],
        ['rollout', 'rollout'],
        ['route-smoke', 'smoke']
      ]
    }
  ]
]);

export function deploymentPathReportStepNames(requirement) {
  const sourceStepNames = requireNonEmptyArray(requirement?.sourceSteps, 'deployment path requirement.sourceSteps')
    .map((entry, index) => {
      const step = requireArray(entry, `deployment path requirement.sourceSteps[${index}]`);
      return requireString(step[0], `deployment path requirement.sourceSteps[${index}].report_step`);
    });

  if (requirement.source === 'airgap') {
    const steps = [sourceStepNames[0], 'bundle-check', ...sourceStepNames.slice(1)];
    if (requirement.installSubstrates) {
      const imageLoadIndex = steps.indexOf('image-load');
      if (imageLoadIndex === -1) {
        fail('airgap deployment path requirement must include image-load before substrate-install');
      }
      steps.splice(imageLoadIndex + 1, 0, 'substrate-install');
    }
    return steps;
  }

  if (requirement.installSubstrates) {
    return ['substrate-install', ...sourceStepNames];
  }

  return sourceStepNames;
}

function fail(message) {
  throw new Error(message);
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireArray(value, label) {
  if (!Array.isArray(value)) {
    fail(`${label} must be an array`);
  }
  return value;
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function requirePositiveInteger(value, label) {
  const integer = requireInteger(value, label);
  if (integer <= 0) {
    fail(`${label} must be greater than zero`);
  }
  return integer;
}

function requireNonEmptyArray(value, label) {
  const array = requireArray(value, label);
  if (array.length === 0) {
    fail(`${label} must not be empty`);
  }
  return array;
}

function requireNonEmptyStringArray(value, label) {
  const array = requireNonEmptyArray(value, label);
  for (const [index, item] of array.entries()) {
    requireString(item, `${label}[${index}]`);
  }
  return array;
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function digestText(value) {
  return `sha256:${crypto.createHash('sha256').update(Buffer.from(value)).digest('hex')}`;
}

function requireKubernetesNamespace(value, label) {
  const namespace = requireString(value, label);
  if (namespace.length > 63 || !KUBERNETES_NAMESPACE_RE.test(namespace)) {
    fail(`${label} must be a Kubernetes namespace name`);
  }
  return namespace;
}

function installParametersDigest({
  installInputDigest,
  resourceListDigest,
  applyResourceListDigest,
  effectiveNamespace
}) {
  return digestText(
    [
      'agentsmith.substrate-install-parameters/v1',
      `substrate_install_inputs=${installInputDigest}`,
      `resource_list=${resourceListDigest}`,
      `apply_resource_list=${applyResourceListDigest}`,
      `effective_namespace=${effectiveNamespace}`
    ].join('\n')
  );
}

function requireGitSha(value, label) {
  const gitSha = requireString(value, label);
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function requireOperatorRunId(value, label) {
  const runId = requireString(value, label);
  if (!OPERATOR_RUN_ID_RE.test(runId)) {
    fail(`${label} must be a safe operator run id`);
  }
  return runId;
}

function requireStatusPass(report, label) {
  if (report.status !== 'pass') {
    fail(`${label}.status must be pass`);
  }
}

function requireCheckPass(value, label) {
  if (value !== 'pass') {
    fail(`${label} must be pass`);
  }
}

function requireCheckObjectPass(value, label) {
  const check = requireObject(value, label);
  requireStatusPass(check, label);
  return check;
}

function requireSchema(report, schema, label) {
  if (report.schema !== schema && report.schema_version !== schema) {
    fail(`${label}.schema must be ${schema}`);
  }
}

export function reportSchema(report) {
  return report.schema ?? report.schema_version;
}

function requireReadinessFalse(report, label) {
  if (report.readiness !== false) {
    fail(`${label}.readiness must be false`);
  }
}

function requireNoFormalVerdict(report, label) {
  if (Object.prototype.hasOwnProperty.call(report, 'formal_verdict')) {
    fail(`${label} must not issue formal_verdict`);
  }
}

function parseTargetProfile(value, label) {
  const text = requireString(value, label);
  const tuple = text.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail(`${label} must be <target_cluster>/<substrate_source>/<distribution>`);
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function requireTargetProfile(value, expected, label) {
  const profile = requireObject(value, label);
  const parsed = parseTargetProfile(profile.value, `${label}.value`);
  if (parsed.value !== expected) {
    fail(`${label}.value must be ${expected}`);
  }
  for (const key of ['target_cluster', 'substrate_source', 'distribution']) {
    if (profile[key] !== parsed[key]) {
      fail(`${label}.${key} must match ${label}.value`);
    }
  }
  return parsed;
}

function requireTargetProfileString(value, expected, label) {
  const parsed = parseTargetProfile(requireString(value, label), label);
  if (parsed.value !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return parsed;
}

function sameArraySet(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) {
    return false;
  }
  const leftSet = new Set(left);
  const rightSet = new Set(right);
  if (leftSet.size !== left.length || rightSet.size !== right.length || leftSet.size !== rightSet.size) {
    return false;
  }
  return [...leftSet].every((item) => rightSet.has(item));
}

function releaseDeployImageInventory(release) {
  const inventory = release.deploy_image_inventory ?? release.images?.inventory;
  const entries = requireNonEmptyArray(inventory, 'release contract deploy_image_inventory');
  const byId = new Map();
  const digestSet = new Set();
  for (const [index, entry] of entries.entries()) {
    const image = requireObject(entry, `release contract deploy_image_inventory[${index}]`);
    const id = requireString(image.id, `release contract deploy_image_inventory[${index}].id`);
    if (byId.has(id)) {
      fail(`release contract deploy_image_inventory contains duplicate image id: ${id}`);
    }
    const digest = requireDigest(image.digest, `release contract deploy_image_inventory[${index}].digest`);
    byId.set(id, {
      id,
      image: requireString(image.image, `release contract deploy_image_inventory[${index}].image`),
      digest
    });
    digestSet.add(digest);
  }
  return { byId, digestSet };
}

function requireInventoryIdDigestMatch({ imageInventory, inventoryId, digest, label }) {
  const inventoryEntry = imageInventory.byId.get(inventoryId);
  if (!inventoryEntry) {
    fail(`${label}.inventory_id must exist in release contract deploy_image_inventory`);
  }
  if (digest !== inventoryEntry.digest) {
    fail(`${label}.digest must match release contract deploy_image_inventory digest for inventory_id ${inventoryId}`);
  }
  return inventoryEntry;
}

function imageDigestSuffix(value, label) {
  const image = requireString(value, label);
  const marker = '@sha256:';
  const index = image.lastIndexOf(marker);
  if (index === -1) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const digest = `sha256:${image.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must include a sha256 digest`);
  }
  return digest;
}

function requireRenderImageInventoryClosure({ imageInventory, image, digest, inventoryId, matchedBy, label }) {
  requireInventoryIdDigestMatch({ imageInventory, inventoryId, digest, label });
  if (imageDigestSuffix(image, `${label}.image`) !== digest) {
    fail(`${label}.image digest must match ${label}.digest`);
  }
  if (matchedBy !== undefined) {
    const value = requireString(matchedBy, `${label}.matched_by`);
    if (!new Set(['image', 'exact_ref', 'digest']).has(value)) {
      fail(`${label}.matched_by must be image, exact_ref, or digest`);
    }
  }
}

function requireDigestSubsetOfInventory(digests, imageInventory, label) {
  for (const [index, digest] of digests.entries()) {
    if (!imageInventory.digestSet.has(digest)) {
      fail(`${label}[${index}] must be included in release contract deploy_image_inventory digests`);
    }
  }
}

function requireDigestSubset(digests, allowed, label, allowedLabel) {
  for (const [index, digest] of digests.entries()) {
    if (!allowed.has(digest)) {
      fail(`${label}[${index}] must be included in ${allowedLabel}`);
    }
  }
}

function requireDigestSetCovers(requiredDigests, actualDigests, actualLabel, requiredLabel) {
  for (const digest of requiredDigests) {
    if (!actualDigests.has(digest)) {
      fail(`${actualLabel} must include ${requiredLabel} digest ${digest}`);
    }
  }
}

function requireCommonReleaseFields(report, release, label) {
  if (requireString(report.release_id, `${label}.release_id`) !== release.release_id) {
    fail(`${label}.release_id must match release contract`);
  }
  if (requireGitSha(report.git_sha, `${label}.git_sha`) !== release.git_sha) {
    fail(`${label}.git_sha must match release contract`);
  }
}

function requireReleaseContractDigest(report, release, label) {
  const container = requireObject(report.release_contract, `${label}.release_contract`);
  if (
    requireDigest(container.input_sha256, `${label}.release_contract.input_sha256`) !==
    release.release_contract_digest
  ) {
    fail(`${label}.release_contract.input_sha256 must match release contract input`);
  }
}

function requireReportReleaseContractDigest(report, release, label) {
  const digest = report.release_contract_digest ?? report.release_contract?.input_sha256;
  if (requireDigest(digest, `${label}.release_contract_digest`) !== release.release_contract_digest) {
    fail(`${label} release contract digest must match release contract input`);
  }
}

function requireReportDeployTemplateDigest(report, release, label) {
  const digest = report.deploy_template_package_digest ?? report.deploy_template_package?.input_sha256;
  if (requireDigest(digest, `${label}.deploy_template_package_digest`) !== release.deploy_template_package_digest) {
    fail(`${label} deploy template package digest must match input`);
  }
}

function requireReportSubstrateTruthDigest(report, label) {
  const digest = report.substrate_truth_digest ?? report.substrate_truth?.input_sha256;
  return requireDigest(digest, `${label}.substrate_truth_digest`);
}

function requireSubstrateInstallInputDigests(report) {
  const inputs = requireObject(report.inputs, 'substrate_install_report.inputs');
  const installInputs = requireObject(
    inputs.substrate_install_inputs,
    'substrate_install_report.inputs.substrate_install_inputs'
  );
  const schemaVersion = requireString(
    installInputs.schema_version,
    'substrate_install_report.inputs.substrate_install_inputs.schema_version'
  );
  if (schemaVersion !== SUBSTRATE_INSTALL_INPUTS_SCHEMA) {
    fail(
      `substrate_install_report.inputs.substrate_install_inputs.schema_version must be ${SUBSTRATE_INSTALL_INPUTS_SCHEMA}`
    );
  }
  const resourceSource = requireString(
    installInputs.resource_source,
    'substrate_install_report.inputs.substrate_install_inputs.resource_source'
  );
  if (!new Set(['inline', 'resource_list_path']).has(resourceSource)) {
    fail('substrate_install_report.inputs.substrate_install_inputs.resource_source must be inline or resource_list_path');
  }
  if (resourceSource === 'resource_list_path') {
    requireString(
      installInputs.resource_list_path,
      'substrate_install_report.inputs.substrate_install_inputs.resource_list_path'
    );
  }
  const inputSha256 = requireDigest(
    installInputs.input_sha256,
    'substrate_install_report.inputs.substrate_install_inputs.input_sha256'
  );
  const resourceListSha256 = requireDigest(
    installInputs.resource_list_sha256,
    'substrate_install_report.inputs.substrate_install_inputs.resource_list_sha256'
  );
  const applyResourceListSha256 = requireDigest(
    installInputs.apply_resource_list_sha256,
    'substrate_install_report.inputs.substrate_install_inputs.apply_resource_list_sha256'
  );
  const effectiveNamespace = requireKubernetesNamespace(
    installInputs.effective_namespace,
    'substrate_install_report.inputs.substrate_install_inputs.effective_namespace'
  );
  const installParametersSha256 = requireDigest(
    installInputs.install_parameters_sha256,
    'substrate_install_report.inputs.substrate_install_inputs.install_parameters_sha256'
  );
  if (
    installParametersSha256 !==
    installParametersDigest({
      installInputDigest: inputSha256,
      resourceListDigest: resourceListSha256,
      applyResourceListDigest: applyResourceListSha256,
      effectiveNamespace
    })
  ) {
    fail('substrate_install_report.inputs.substrate_install_inputs.install_parameters_sha256 must bind install input, resource list, apply artifact, and effective namespace');
  }
  return {
    input_sha256: inputSha256,
    resource_list_sha256: resourceListSha256,
    apply_resource_list_sha256: applyResourceListSha256,
    effective_namespace: effectiveNamespace,
    install_parameters_sha256: installParametersSha256,
    resource_source: resourceSource
  };
}

function requireInputBindingDigest(binding, label) {
  for (const key of ['input_sha256', 'digest', 'sha256']) {
    if (Object.prototype.hasOwnProperty.call(binding, key)) {
      return requireDigest(binding[key], `${label}.${key}`);
    }
  }
  return requireDigest(undefined, `${label}.input_sha256`);
}

function requireTargetProfileBinding(value, expected, label) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return requireTargetProfile(value, expected, label);
  }
  return requireTargetProfileString(value, expected, label);
}

function requireCountEquals(value, expected, label, expectedLabel) {
  const count = requirePositiveInteger(value, label);
  if (count !== expected) {
    fail(`${label} must match ${expectedLabel}`);
  }
  return count;
}

function containsKubectlDryRunFlag(value) {
  return /(?:^|\s)--dry-run(?:=|\s|$)/.test(value);
}

function assertNoDryRunFlag(value, label) {
  if (typeof value === 'string') {
    if (containsKubectlDryRunFlag(value)) {
      fail(`${label} must not include --dry-run for apply`);
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const [index, item] of value.entries()) {
      assertNoDryRunFlag(item, `${label}[${index}]`);
    }
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) {
      assertNoDryRunFlag(item, `${label}.${key}`);
    }
  }
}

function validateSubstrateInstallInputBindings({ report, release, expectedTargetProfile, effectiveNamespace }) {
  const inputs = requireObject(report.inputs, 'substrate_install_report.inputs');

  const packManifest = requireObject(
    inputs.substrate_pack_manifest,
    'substrate_install_report.inputs.substrate_pack_manifest'
  );
  requireSchema(
    packManifest,
    SUBSTRATE_PACK_MANIFEST_SCHEMA,
    'substrate_install_report.inputs.substrate_pack_manifest'
  );
  const packManifestDigest = requireInputBindingDigest(
    packManifest,
    'substrate_install_report.inputs.substrate_pack_manifest'
  );
  requireTargetProfileBinding(
    packManifest.target_profile,
    expectedTargetProfile,
    'substrate_install_report.inputs.substrate_pack_manifest.target_profile'
  );
  if (
    requireDigest(
      packManifest.release_contract_digest,
      'substrate_install_report.inputs.substrate_pack_manifest.release_contract_digest'
    ) !== release.release_contract_digest
  ) {
    fail('substrate_install_report.inputs.substrate_pack_manifest.release_contract_digest must match release contract input');
  }
  if (
    requireDigest(
      packManifest.deploy_template_package_digest,
      'substrate_install_report.inputs.substrate_pack_manifest.deploy_template_package_digest'
    ) !== release.deploy_template_package_digest
  ) {
    fail('substrate_install_report.inputs.substrate_pack_manifest.deploy_template_package_digest must match deploy template package input');
  }

  const targetPrerequisites = requireObject(
    inputs.target_prerequisites,
    'substrate_install_report.inputs.target_prerequisites'
  );
  requireSchema(
    targetPrerequisites,
    TARGET_PREREQUISITES_SCHEMA,
    'substrate_install_report.inputs.target_prerequisites'
  );
  const targetPrerequisitesDigest = requireInputBindingDigest(
    targetPrerequisites,
    'substrate_install_report.inputs.target_prerequisites'
  );
  requireTargetProfileBinding(
    targetPrerequisites.target_profile,
    expectedTargetProfile,
    'substrate_install_report.inputs.target_prerequisites.target_profile'
  );
  if (
    requireKubernetesNamespace(
      targetPrerequisites.namespace,
      'substrate_install_report.inputs.target_prerequisites.namespace'
    ) !== effectiveNamespace
  ) {
    fail('substrate_install_report.inputs.target_prerequisites.namespace must match substrate install effective namespace');
  }

  return {
    substrate_pack_manifest_sha256: packManifestDigest,
    target_prerequisites_sha256: targetPrerequisitesDigest
  };
}

function validateSubstrateInstallProof({ report, effectiveNamespace, resourceRefs, kubectlResourceRefs }) {
  const resourceCount = resourceRefs.length;
  const kubectlResourceCount = kubectlResourceRefs.length;
  if (resourceCount !== kubectlResourceCount) {
    fail('substrate_install_report.kubectl_resource_refs length must match resource_refs length');
  }

  const checks = requireObject(report.checks, 'substrate_install_report.checks');
  const namespaceScope = requireCheckObjectPass(
    checks.namespace_scope,
    'substrate_install_report.checks.namespace_scope'
  );
  requireCountEquals(
    namespaceScope.resource_count,
    resourceCount,
    'substrate_install_report.checks.namespace_scope.resource_count',
    'substrate_install_report.resource_refs length'
  );
  requireCountEquals(
    namespaceScope.allowed_resource_count,
    resourceCount,
    'substrate_install_report.checks.namespace_scope.allowed_resource_count',
    'substrate_install_report.resource_refs length'
  );
  if (
    requireKubernetesNamespace(
      namespaceScope.namespace,
      'substrate_install_report.checks.namespace_scope.namespace'
    ) !== effectiveNamespace
  ) {
    fail('substrate_install_report.checks.namespace_scope.namespace must match substrate install effective namespace');
  }

  const collisionGuard = requireCheckObjectPass(
    checks.collision_guard,
    'substrate_install_report.checks.collision_guard'
  );
  requireCountEquals(
    collisionGuard.checked_resource_count,
    resourceCount,
    'substrate_install_report.checks.collision_guard.checked_resource_count',
    'substrate_install_report.resource_refs length'
  );
  requireCountEquals(
    collisionGuard.kubectl_get_count,
    resourceCount,
    'substrate_install_report.checks.collision_guard.kubectl_get_count',
    'substrate_install_report.resource_refs length'
  );

  const kubectlApply = requireCheckObjectPass(
    checks.kubectl_apply,
    'substrate_install_report.checks.kubectl_apply'
  );
  if (requireString(kubectlApply.mode, 'substrate_install_report.checks.kubectl_apply.mode') !== 'apply') {
    fail('substrate_install_report.checks.kubectl_apply.mode must be apply');
  }
  requireCountEquals(
    kubectlApply.applied_resource_count,
    resourceCount,
    'substrate_install_report.checks.kubectl_apply.applied_resource_count',
    'substrate_install_report.resource_refs length'
  );
  requireCountEquals(
    kubectlApply.kubectl_resource_count,
    kubectlResourceCount,
    'substrate_install_report.checks.kubectl_apply.kubectl_resource_count',
    'substrate_install_report.kubectl_resource_refs length'
  );
  const commandSummary = requireObject(
    kubectlApply.command_summary,
    'substrate_install_report.checks.kubectl_apply.command_summary'
  );
  requireString(commandSummary.command, 'substrate_install_report.checks.kubectl_apply.command_summary.command');
  if (
    requireString(
      commandSummary.dry_run,
      'substrate_install_report.checks.kubectl_apply.command_summary.dry_run'
    ) !== 'none'
  ) {
    fail('substrate_install_report.checks.kubectl_apply.command_summary.dry_run must be none for apply');
  }
  assertNoDryRunFlag(kubectlApply, 'substrate_install_report.checks.kubectl_apply');
  if (commandSummary.server_side !== true) {
    fail('substrate_install_report.checks.kubectl_apply.command_summary.server_side must be true');
  }
  if (
    requireKubernetesNamespace(
      commandSummary.namespace,
      'substrate_install_report.checks.kubectl_apply.command_summary.namespace'
    ) !== effectiveNamespace
  ) {
    fail('substrate_install_report.checks.kubectl_apply.command_summary.namespace must match substrate install effective namespace');
  }

  return {
    resource_count: resourceCount,
    kubectl_resource_count: kubectlResourceCount,
    namespace_scope_allowed_resource_count: namespaceScope.allowed_resource_count,
    collision_checked_resource_count: collisionGuard.checked_resource_count,
    kubectl_apply_applied_resource_count: kubectlApply.applied_resource_count
  };
}

function requireScope(report, expectedScope, label) {
  if (requireString(report.scope, `${label}.scope`) !== expectedScope) {
    fail(`${label}.scope must be ${expectedScope}`);
  }
}

function validateDigestArray(value, label) {
  const digests = requireNonEmptyArray(value, label);
  for (const [index, digest] of digests.entries()) {
    requireDigest(digest, `${label}[${index}]`);
  }
  return digests;
}

function validateExpectedImageDigestEntry(value, label, imageInventory) {
  const entry = requireObject(value, label);
  const digest = requireDigest(entry.digest, `${label}.digest`);
  const inventoryIds = requireNonEmptyStringArray(entry.inventory_ids, `${label}.inventory_ids`);
  requirePositiveInteger(entry.images_count, `${label}.images_count`);
  for (const inventoryId of inventoryIds) {
    requireInventoryIdDigestMatch({ imageInventory, inventoryId, digest, label });
  }
  return digest;
}

function validateExpectedImageDigestEntries(value, label, imageInventory) {
  const entries = requireNonEmptyArray(value, label);
  const digestSet = new Set();
  for (const [index, entry] of entries.entries()) {
    digestSet.add(validateExpectedImageDigestEntry(entry, `${label}[${index}]`, imageInventory));
  }
  return digestSet;
}

function validateRenderImageEntry(value, label, imageInventory) {
  const image = requireObject(value, label);
  const imageRef = requireString(image.image, `${label}.image`);
  const digest = requireDigest(image.digest, `${label}.digest`);
  const inventoryId = requireString(image.inventory_id, `${label}.inventory_id`);
  requireRenderImageInventoryClosure({
    imageInventory,
    image: imageRef,
    digest,
    inventoryId,
    matchedBy: image.matched_by,
    label
  });
}

function validateRenderImageEntries(value, label, imageInventory) {
  const images = requireNonEmptyArray(value, label);
  for (const [index, image] of images.entries()) {
    validateRenderImageEntry(image, `${label}[${index}]`, imageInventory);
  }
}

function validateRenderManifestEntry(value, label, imageInventory) {
  const manifest = requireObject(value, label);
  requireString(manifest.path, `${label}.path`);
  requirePositiveInteger(manifest.document_index, `${label}.document_index`);
  requireString(manifest.kind, `${label}.kind`);
  requireDigest(manifest.sha256, `${label}.sha256`);
  validateRenderImageEntries(manifest.images, `${label}.images`, imageInventory);
}

function validateResourceRef(value, label, options = {}) {
  const ref = requireObject(value, label);
  requireString(ref.kind, `${label}.kind`);
  requireString(ref.name, `${label}.name`);
  requireString(ref.namespace, `${label}.namespace`);
  if (options.requireSelector) {
    requireString(ref.selector, `${label}.selector`);
  }
  if (Object.prototype.hasOwnProperty.call(ref, 'path')) {
    requireString(ref.path, `${label}.path`);
  }
  if (Object.prototype.hasOwnProperty.call(ref, 'document_index')) {
    requirePositiveInteger(ref.document_index, `${label}.document_index`);
  }
  return ref;
}

function validateResourceRefs(value, label, options = {}) {
  const refs = requireNonEmptyArray(value, label);
  for (const [index, ref] of refs.entries()) {
    validateResourceRef(ref, `${label}[${index}]`, options);
  }
  return refs;
}

function validateSubstrateInstallResourceRefs(value, label, effectiveNamespace) {
  const refs = validateResourceRefs(value, label);
  for (const [index, ref] of refs.entries()) {
    const itemLabel = `${label}[${index}]`;
    const kind = requireString(ref.kind, `${itemLabel}.kind`);
    const identity = SUBSTRATE_INSTALL_RESOURCE_ALLOWLIST_BY_KIND.get(kind);
    if (!identity) {
      fail(`${itemLabel}.kind ${kind} is not allowed for substrate install; allowed kinds are ${SUBSTRATE_INSTALL_ALLOWED_KINDS}`);
    }
    if (requireString(ref.apiVersion, `${itemLabel}.apiVersion`) !== identity.apiVersion) {
      fail(`${itemLabel}.apiVersion must match substrate install resource kind ${kind}`);
    }
    if (typeof ref.group !== 'string') {
      fail(`${itemLabel}.group must be a string`);
    }
    if (ref.group !== identity.group) {
      fail(`${itemLabel}.group must match substrate install resource kind ${kind}`);
    }
    if (requireString(ref.resource, `${itemLabel}.resource`) !== identity.resource) {
      fail(`${itemLabel}.resource must match substrate install resource kind ${kind}`);
    }
    if (
      requireKubernetesNamespace(ref.namespace, `${itemLabel}.namespace`) !==
      effectiveNamespace
    ) {
      fail(`${itemLabel}.namespace must match substrate install effective namespace`);
    }
  }
  return refs;
}

function substrateInstallRefKey({ kind, namespace, name }) {
  return `${kind}\0${namespace}\0${name}`;
}

function incrementCount(map, key) {
  map.set(key, (map.get(key) || 0) + 1);
}

function decrementCount(map, key) {
  const current = map.get(key) || 0;
  if (current <= 0) {
    return false;
  }
  if (current === 1) {
    map.delete(key);
  } else {
    map.set(key, current - 1);
  }
  return true;
}

function substrateInstallKindFromKubectlResource(resource) {
  for (const [kind, identity] of SUBSTRATE_INSTALL_RESOURCE_ALLOWLIST_BY_KIND) {
    if (identity.kubectlResources.has(resource)) {
      return kind;
    }
  }
  return undefined;
}

function parseSubstrateInstallKubectlResourceRef(value, label) {
  const ref = requireString(value, label);
  const parts = ref.split('/');
  if (parts.length !== 2 || parts[0] === '' || parts[1] === '') {
    fail(`${label} must be a kubectl resource/name reference`);
  }
  const [resource, name] = parts;
  const kind = substrateInstallKindFromKubectlResource(resource);
  if (!kind) {
    fail(`${label} resource ${resource} is not allowed for substrate install; allowed resources are ${SUBSTRATE_INSTALL_ALLOWED_KUBECTL_RESOURCES}`);
  }
  return { kind, name };
}

function validateSubstrateInstallKubectlResourceRefs(value, label, resourceRefs, effectiveNamespace) {
  const kubectlRefs = requireNonEmptyStringArray(value, label);
  const expectedRefs = new Map();
  for (const ref of resourceRefs) {
    incrementCount(
      expectedRefs,
      substrateInstallRefKey({
        kind: ref.kind,
        namespace: effectiveNamespace,
        name: ref.name
      })
    );
  }

  for (const [index, rawRef] of kubectlRefs.entries()) {
    const parsed = parseSubstrateInstallKubectlResourceRef(rawRef, `${label}[${index}]`);
    const key = substrateInstallRefKey({
      kind: parsed.kind,
      namespace: effectiveNamespace,
      name: parsed.name
    });
    if (!decrementCount(expectedRefs, key)) {
      fail(`${label}[${index}] must match substrate_install_report.resource_refs`);
    }
  }

  if (expectedRefs.size > 0) {
    fail(`${label} must exactly match substrate_install_report.resource_refs`);
  }
  return kubectlRefs;
}

function validateLiveDigestSummary(value, label, imageInventory, expectedDigestSet) {
  const summary = requireObject(value, label);
  requirePositiveInteger(summary.observed_digest_count, `${label}.observed_digest_count`);
  const observedDigests = validateDigestArray(summary.observed_digests, `${label}.observed_digests`);
  const matchedExpectedDigests = validateDigestArray(
    summary.matched_expected_digests,
    `${label}.matched_expected_digests`
  );
  requireDigestSubsetOfInventory(
    matchedExpectedDigests,
    imageInventory,
    `${label}.matched_expected_digests`
  );
  requireDigestSubset(
    matchedExpectedDigests,
    expectedDigestSet,
    `${label}.matched_expected_digests`,
    `${label.replace(/\.observed_live_image_digest_summary$/, '')}.expected_image_digests`
  );
  const expectedLabel = `${label.replace(/\.observed_live_image_digest_summary$/, '')}.expected_image_digests`;
  requireDigestSetCovers(
    expectedDigestSet,
    new Set(observedDigests),
    `${label}.observed_digests`,
    expectedLabel
  );
  requireDigestSetCovers(
    expectedDigestSet,
    new Set(matchedExpectedDigests),
    `${label}.matched_expected_digests`,
    expectedLabel
  );
}

export function stepMap(steps, label) {
  const byName = new Map();
  for (const [index, rawStep] of requireArray(steps, `${label}.steps`).entries()) {
    const step = requireObject(rawStep, `${label}.steps[${index}]`);
    const name = requireString(step.name, `${label}.steps[${index}].name`);
    if (byName.has(name)) {
      fail(`${label}.steps contains duplicate step: ${name}`);
    }
    requireStatusPass(step, `${label}.steps[${index}]`);
    byName.set(name, step);
  }
  return byName;
}

export function safeRelativeReportPath(value, label) {
  const relative = requireString(value, label);
  if (relative.includes('\\') || path.isAbsolute(relative)) {
    fail(`${label} must be a portable relative path`);
  }
  const parts = relative.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not contain empty, current, or parent segments`);
  }
  return relative;
}

export function reportPathForStep(step, label) {
  const paths = requireArray(step.report_paths, `${label}.report_paths`);
  if (paths.length !== 1) {
    fail(`${label}.report_paths must contain exactly one report`);
  }
  return safeRelativeReportPath(paths[0], `${label}.report_paths[0]`);
}

function requireSourceInput(sourceInputsByStep, stepName) {
  const input = sourceInputsByStep.get(stepName);
  if (!input) {
    fail(`missing source input materiality for finalized step: ${stepName}`);
  }
  return input;
}

function requireInputReport(input, label) {
  return requireObject(input?.value, label);
}

export function validateSourceStepReport({
  report,
  sourceStep,
  release,
  expectedTargetProfile,
  airgapContext
}) {
  const expected = SOURCE_STEP_REPORTS.get(sourceStep);
  if (!expected) {
    fail(`unsupported source step report type: ${sourceStep}`);
  }
  const label = `${sourceStep} step report`;
  requireSchema(report, expected.schema, label);
  requireScope(report, expected.scope, label);
  requireReadinessFalse(report, label);
  requireStatusPass(report, label);
  requireNoFormalVerdict(report, label);
  requireCommonReleaseFields(report, release, label);
  requireTargetProfile(report.target_profile, expectedTargetProfile, `${label}.target_profile`);
  if (expected.mode && report.mode !== expected.mode) {
    fail(`${label}.mode must be ${expected.mode}`);
  }

  if (sourceStep === 'target-preflight') {
    requireReleaseContractDigest(report, release, label);
    validateTargetPreflightStepReport(report, expectedTargetProfile);
  }

  if (sourceStep === 'render-check') {
    requireReleaseContractDigest(report, release, label);
    validateRenderCheckStepReport(report, release);
  }
  if (sourceStep === 'apply') {
    requireReleaseContractDigest(report, release, label);
    validateApplyStepReport(report);
  }
  if (sourceStep === 'rollout') {
    requireReleaseContractDigest(report, release, label);
    validateRolloutStepReport(report, release);
  }
  if (sourceStep === 'smoke') {
    requireReleaseContractDigest(report, release, label);
    validateSmokeStepReport(report);
  }

  if (sourceStep === 'airgap-image-load') {
    validateAirgapImageLoadStepReport(report, release, airgapContext);
  }
  if (sourceStep === 'airgap-bundle-render-check') {
    validateAirgapBundleRenderCheckStepReport(report, release, airgapContext);
  }
}

function validateTargetPreflightStepReport(report, expectedTargetProfile) {
  const substrateTruth = requireObject(report.substrate_truth, 'target-preflight step report.substrate_truth');
  requireSchema(substrateTruth, SUBSTRATE_CONNECTION_SCHEMA, 'target-preflight step report.substrate_truth');
  requireDigest(
    substrateTruth.input_sha256,
    'target-preflight step report.substrate_truth.input_sha256'
  );
  requireTargetProfile(
    substrateTruth.target_profile,
    expectedTargetProfile,
    'target-preflight step report.substrate_truth.target_profile'
  );
  const servicesCount = requirePositiveInteger(
    substrateTruth.services_count,
    'target-preflight step report.substrate_truth.services_count'
  );
  const services = requireNonEmptyStringArray(
    substrateTruth.services,
    'target-preflight step report.substrate_truth.services'
  );
  if (services.length !== servicesCount) {
    fail('target-preflight step report.substrate_truth.services_count must match services length');
  }
  for (const [index, service] of services.entries()) {
    if (!SERVICE_NAME_RE.test(service)) {
      fail(`target-preflight step report.substrate_truth.services[${index}] must be a service name`);
    }
  }
  if (!sameArraySet(services, TARGET_PREFLIGHT_SUBSTRATE_SERVICES)) {
    fail('target-preflight step report.substrate_truth.services must match target-preflight producer service summary');
  }

  const prerequisites = requireObject(
    report.target_prerequisites,
    'target-preflight step report.target_prerequisites'
  );
  requireSchema(
    prerequisites,
    TARGET_PREREQUISITES_SCHEMA,
    'target-preflight step report.target_prerequisites'
  );
  requireDigest(
    prerequisites.input_sha256,
    'target-preflight step report.target_prerequisites.input_sha256'
  );
  requireTargetProfileString(
    prerequisites.target_profile,
    expectedTargetProfile,
    'target-preflight step report.target_prerequisites.target_profile'
  );
  requireKubernetesNamespace(
    prerequisites.namespace,
    'target-preflight step report.target_prerequisites.namespace'
  );
  requireString(
    prerequisites.ingress_host,
    'target-preflight step report.target_prerequisites.ingress_host'
  );
  requirePositiveInteger(
    prerequisites.substrate_secret_refs_count,
    'target-preflight step report.target_prerequisites.substrate_secret_refs_count'
  );

  const checks = requireObject(report.checks, 'target-preflight step report.checks');
  for (const key of [
    'schema',
    'target_axes',
    'service_contracts',
    'target_prerequisites',
    'secret_references',
    'tls_or_sslmode',
    'reachability'
  ]) {
    requireCheckPass(checks[key], `target-preflight step report.checks.${key}`);
  }
}

function validateRenderCheckStepReport(report, release) {
  const imageInventory = releaseDeployImageInventory(release);
  const renderedManifests = requireObject(
    report.rendered_manifests,
    'render-check step report.rendered_manifests'
  );
  requireInteger(renderedManifests.files_count, 'render-check step report.rendered_manifests.files_count');
  requireInteger(
    renderedManifests.workload_count,
    'render-check step report.rendered_manifests.workload_count'
  );
  validateRenderImageEntries(report.images, 'render-check step report.images', imageInventory);
  const manifests = requireNonEmptyArray(report.manifests, 'render-check step report.manifests');
  for (const [index, manifest] of manifests.entries()) {
    validateRenderManifestEntry(
      manifest,
      `render-check step report.manifests[${index}]`,
      imageInventory
    );
  }
}

function validateApplyStepReport(report) {
  requireOperatorRunId(report.operator_run_id, 'apply step report.operator_run_id');
  validateResourceRefs(report.resource_refs, 'apply step report.resource_refs');
  requireNonEmptyStringArray(report.kubectl_resource_refs, 'apply step report.kubectl_resource_refs');
  validateRenderCheckSummary(report.render_check, 'apply step report.render_check');
}

function validateRolloutStepReport(report, release) {
  const imageInventory = releaseDeployImageInventory(release);
  validateResourceRefs(
    report.rollout_resource_refs,
    'rollout step report.rollout_resource_refs',
    { requireSelector: true }
  );
  const expectedDigestSet = validateExpectedImageDigestEntries(
    report.expected_image_digests,
    'rollout step report.expected_image_digests',
    imageInventory
  );
  validateLiveDigestSummary(
    report.observed_live_image_digest_summary,
    'rollout step report.observed_live_image_digest_summary',
    imageInventory,
    expectedDigestSet
  );
  const workloads = requireNonEmptyArray(report.workload_summaries, 'rollout step report.workload_summaries');
  for (const [index, workload] of workloads.entries()) {
    validateRolloutWorkloadSummary(
      workload,
      `rollout step report.workload_summaries[${index}]`,
      imageInventory
    );
  }
}

function validateRolloutWorkloadSummary(value, label, imageInventory) {
  const workload = requireObject(value, label);
  validateResourceRef(workload.resource_ref, `${label}.resource_ref`, {
    requireSelector: true
  });
  const expectedDigestSet = validateExpectedImageDigestEntries(
    workload.expected_image_digests,
    `${label}.expected_image_digests`,
    imageInventory
  );
  validateLiveDigestSummary(
    workload.observed_live_image_digest_summary,
    `${label}.observed_live_image_digest_summary`,
    imageInventory,
    expectedDigestSet
  );
}

function validateRenderCheckSummary(value, label) {
  const summary = requireObject(value, label);
  requireSchema(summary, RENDER_CHECK_SCHEMA, label);
  requireScope(summary, 'render_check_image_inventory_only', label);
  requireStatusPass(summary, label);
  requirePositiveInteger(summary.images_count, `${label}.images_count`);
  requirePositiveInteger(summary.workload_count, `${label}.workload_count`);
}

function validateSmokeStepReport(report) {
  const route = requireObject(report.route, 'smoke step report.route');
  requireString(route.scheme, 'smoke step report.route.scheme');
  requireString(route.origin, 'smoke step report.route.origin');
  requireString(route.host, 'smoke step report.route.host');
  requireString(route.path, 'smoke step report.route.path');
  const expectedStatus = requireInteger(report.expected_status, 'smoke step report.expected_status');
  if (expectedStatus < 100 || expectedStatus > 599) {
    fail('smoke step report.expected_status must be an HTTP status code');
  }
  const statusCode = requireInteger(report.status_code, 'smoke step report.status_code');
  if (statusCode < 100 || statusCode > 599) {
    fail('smoke step report.status_code must be an HTTP status code');
  }
  requireInteger(report.duration_ms, 'smoke step report.duration_ms');
  const rolloutReport = requireObject(report.rollout_report, 'smoke step report.rollout_report');
  requireDigest(rolloutReport.input_sha256, 'smoke step report.rollout_report.input_sha256');
  requireSchema(rolloutReport, ROLLOUT_SCHEMA, 'smoke step report.rollout_report');
  requireScope(rolloutReport, 'kubernetes_rollout_imageid_only', 'smoke step report.rollout_report');
  requireStatusPass(rolloutReport, 'smoke step report.rollout_report');
}

export function validateInstallSubstrateTruthBinding(installSummary, sourceInputsByStep) {
  if (!installSummary) {
    return;
  }
  const outputSubstrateTruthDigest = requireDigest(
    installSummary.output_substrate_truth_digest,
    'substrate_install_report.output_substrate_truth_digest'
  );
  const targetPreflightInput = requireSourceInput(sourceInputsByStep, 'target-preflight');
  const targetPreflightReport = requireInputReport(
    targetPreflightInput,
    'target-preflight step report'
  );
  const substrateTruth = requireObject(
    targetPreflightReport.substrate_truth,
    'target-preflight step report.substrate_truth'
  );
  const targetPreflightSubstrateTruthDigest = requireDigest(
    substrateTruth.input_sha256,
    'target-preflight step report.substrate_truth.input_sha256'
  );
  if (outputSubstrateTruthDigest !== targetPreflightSubstrateTruthDigest) {
    fail(
      'substrate_install_report.output_substrate_truth_digest must match target-preflight step report.substrate_truth.input_sha256'
    );
  }
  const offlineRenderInput = sourceInputsByStep.get('offline-render-check');
  if (offlineRenderInput) {
    const offlineRenderReport = requireInputReport(
      offlineRenderInput,
      'airgap-bundle-render-check step report'
    );
    const digestSummary = requireDigestSummary(
      offlineRenderReport,
      'airgap-bundle-render-check step report'
    );
    if (
      requireDigest(
        digestSummary.substrate_truth_input_sha256,
        'airgap-bundle-render-check step report.digest_summary.substrate_truth_input_sha256'
      ) !== outputSubstrateTruthDigest
    ) {
      fail(
        'airgap-bundle-render-check step report.digest_summary.substrate_truth_input_sha256 must match substrate_install_report.output_substrate_truth_digest'
      );
    }
  }
  const prerequisites = requireObject(
    targetPreflightReport.target_prerequisites,
    'target-preflight step report.target_prerequisites'
  );
  const targetPreflightNamespace = requireKubernetesNamespace(
    prerequisites.namespace,
    'target-preflight step report.target_prerequisites.namespace'
  );
  const targetPreflightPrerequisitesDigest = requireDigest(
    prerequisites.input_sha256,
    'target-preflight step report.target_prerequisites.input_sha256'
  );
  if (installSummary.input_digests.effective_namespace !== targetPreflightNamespace) {
    fail(
      'substrate_install_report.inputs.substrate_install_inputs.effective_namespace must match target-preflight step report.target_prerequisites.namespace'
    );
  }
  if (
    installSummary.input_bindings.target_prerequisites_sha256 !==
    targetPreflightPrerequisitesDigest
  ) {
    fail(
      'substrate_install_report.inputs.target_prerequisites.input_sha256 must match target-preflight step report.target_prerequisites.input_sha256'
    );
  }
}

export function validateRouteSmokeRolloutBinding(sourceInputsByStep) {
  const rolloutInput = requireSourceInput(sourceInputsByStep, 'rollout');
  const smokeInput = requireSourceInput(sourceInputsByStep, 'route-smoke');
  const smokeReport = requireInputReport(smokeInput, 'smoke step report');
  const rolloutReport = requireObject(
    smokeReport.rollout_report,
    'smoke step report.rollout_report'
  );
  if (
    requireDigest(
      rolloutReport.input_sha256,
      'smoke step report.rollout_report.input_sha256'
    ) !== rolloutInput.digest
  ) {
    fail('smoke step report.rollout_report.input_sha256 must match rollout step report digest');
  }
}

function requireDigestSummary(report, label) {
  return requireObject(report.digest_summary, `${label}.digest_summary`);
}

function requireDigestSummaryMatch(summary, key, expectedDigest, label) {
  if (requireDigest(summary[key], `${label}.digest_summary.${key}`) !== expectedDigest) {
    fail(`${label}.digest_summary.${key} must match bound input`);
  }
}

function validateAirgapImageLoadStepReport(report, release, airgapContext) {
  if (!airgapContext) {
    fail('airgap image load validation requires airgap context');
  }
  const label = 'airgap-image-load step report';
  const summary = requireDigestSummary(report, label);
  requireDigestSummaryMatch(summary, 'release_contract_input_sha256', release.release_contract_digest, label);
  requireDigestSummaryMatch(
    summary,
    'deploy_template_package_input_sha256',
    release.deploy_template_package_digest,
    label
  );
  requireDigestSummaryMatch(summary, 'bundle_manifest_input_sha256', airgapContext.bundleManifestDigest, label);
  requireDigestSummaryMatch(
    summary,
    'airgap_bundle_check_report_input_sha256',
    airgapContext.bundleCheckDigest,
    label
  );
  requireDigestSummaryMatch(summary, 'image_map_input_sha256', airgapContext.imageMapInputSha256, label);
}

function validateAirgapBundleRenderCheckStepReport(report, release, airgapContext) {
  if (!airgapContext) {
    fail('airgap bundle render-check validation requires airgap context');
  }
  const label = 'airgap-bundle-render-check step report';
  const summary = requireDigestSummary(report, label);
  requireDigestSummaryMatch(summary, 'release_contract_input_sha256', release.release_contract_digest, label);
  requireDigestSummaryMatch(
    summary,
    'deploy_template_package_input_sha256',
    release.deploy_template_package_digest,
    label
  );
  requireDigestSummaryMatch(summary, 'bundle_manifest_input_sha256', airgapContext.bundleManifestDigest, label);
  requireDigestSummaryMatch(
    summary,
    'airgap_bundle_check_report_input_sha256',
    airgapContext.bundleCheckDigest,
    label
  );
  requireDigestSummaryMatch(summary, 'image_map_input_sha256', airgapContext.imageMapInputSha256, label);
  const loadImageMapDigest = airgapContext.imageLoadReport?.digest_summary?.image_map_input_sha256;
  if (loadImageMapDigest !== undefined) {
    const renderImageMapDigest = requireDigest(
      summary.image_map_input_sha256,
      `${label}.digest_summary.image_map_input_sha256`
    );
    if (
      renderImageMapDigest !==
      requireDigest(loadImageMapDigest, 'airgap-image-load step report.digest_summary.image_map_input_sha256')
    ) {
      fail('airgap image-load and bundle render-check image_map digests must match');
    }
  }
}

export function validateDeploymentGateReport({ report, source, release, expectedTargetProfile }) {
  const label = `${source} deployment gate report`;
  const expectedGate = DEPLOYMENT_GATE_BY_SOURCE.get(source);
  if (!expectedGate) {
    fail(`unsupported deployment gate source: ${source}`);
  }
  requireSchema(report, expectedGate.schema, label);
  requireScope(report, expectedGate.scope, label);
  requireReadinessFalse(report, label);
  requireNoFormalVerdict(report, label);
  requireStatusPass(report, label);
  requireCommonReleaseFields(report, release, label);
  requireReleaseContractDigest(report, release, label);
  if (report.mode !== 'apply') {
    fail(`${label}.mode must be apply for GA deployment path evidence`);
  }
  requireOperatorRunId(report.operator_run_id, `${label}.operator_run_id`);
  requireTargetProfile(report.target_profile, expectedTargetProfile, `${label}.target_profile`);
}

export function validateDeploymentGateSourceStepPaths({ gateReport, requirement }) {
  const steps = stepMap(gateReport.steps, 'deployment gate report');
  for (const [, sourceStep] of requirement.sourceSteps) {
    const step = steps.get(sourceStep);
    if (!step) {
      fail(`deployment gate report missing required step: ${sourceStep}`);
    }
    reportPathForStep(step, `deployment gate report step ${sourceStep}`);
  }
}

export function validateSubstrateInstallReport(report, release, expectedTargetProfile, operatorRunId) {
  requireSchema(report, SUBSTRATE_INSTALL_SCHEMA, 'substrate install report');
  requireScope(report, SUBSTRATE_INSTALL_SCOPE, 'substrate install report');
  requireReadinessFalse(report, 'substrate install report');
  requireNoFormalVerdict(report, 'substrate install report');
  requireStatusPass(report, 'substrate install report');
  requireCommonReleaseFields(report, release, 'substrate install report');
  const producer = requireString(report.producer ?? report.producer_id, 'substrate_install_report.producer');
  if (producer !== SUBSTRATE_INSTALL_PRODUCER) {
    fail(`substrate_install_report.producer must be ${SUBSTRATE_INSTALL_PRODUCER}`);
  }
  requireTargetProfile(report.target_profile, expectedTargetProfile, 'substrate_install_report.target_profile');
  if (report.mode !== 'apply') {
    fail('substrate_install_report.mode must be apply');
  }
  if (operatorRunId !== undefined && requireOperatorRunId(report.operator_run_id, 'substrate_install_report.operator_run_id') !== operatorRunId) {
    fail('substrate install report operator_run_id must match install_confirmation.operator_run_id');
  }
  if (operatorRunId === undefined) {
    requireOperatorRunId(report.operator_run_id, 'substrate_install_report.operator_run_id');
  }
  requireReportReleaseContractDigest(report, release, 'substrate install report');
  requireReportDeployTemplateDigest(report, release, 'substrate install report');
  requireReportSubstrateTruthDigest(report, 'substrate install report');
  const inputDigests = requireSubstrateInstallInputDigests(report);
  if (
    requireKubernetesNamespace(report.namespace, 'substrate_install_report.namespace') !==
    inputDigests.effective_namespace
  ) {
    fail('substrate_install_report.namespace must match substrate install effective namespace');
  }
  const inputBindings = validateSubstrateInstallInputBindings({
    report,
    release,
    expectedTargetProfile,
    effectiveNamespace: inputDigests.effective_namespace
  });
  const resourceRefs = validateSubstrateInstallResourceRefs(
    report.resource_refs,
    'substrate_install_report.resource_refs',
    inputDigests.effective_namespace
  );
  const kubectlResourceRefs = validateSubstrateInstallKubectlResourceRefs(
    report.kubectl_resource_refs,
    'substrate_install_report.kubectl_resource_refs',
    resourceRefs,
    inputDigests.effective_namespace
  );
  const proof = validateSubstrateInstallProof({
    report,
    effectiveNamespace: inputDigests.effective_namespace,
    resourceRefs,
    kubectlResourceRefs
  });
  const installedServices = requireArray(report.installed_services, 'substrate_install_report.installed_services');
  if (installedServices.length === 0) {
    fail('substrate_install_report.installed_services must not be empty');
  }
  const seenServices = new Set();
  for (const [index, value] of installedServices.entries()) {
    const service = requireString(value, `substrate_install_report.installed_services[${index}]`);
    if (!SERVICE_NAME_RE.test(service)) {
      fail(`substrate_install_report.installed_services[${index}] must be a service name`);
    }
    if (seenServices.has(service)) {
      fail(`substrate_install_report.installed_services contains duplicate service: ${service}`);
    }
    seenServices.add(service);
  }
  if (
    requireString(report.output_substrate_truth_path, 'substrate_install_report.output_substrate_truth_path') !==
    SUBSTRATE_INSTALL_OUTPUT_TRUTH_FILE
  ) {
    fail(`substrate_install_report.output_substrate_truth_path must be ${SUBSTRATE_INSTALL_OUTPUT_TRUTH_FILE}`);
  }
  requireDigest(
    report.output_substrate_truth_digest,
    'substrate_install_report.output_substrate_truth_digest'
  );
  const summary = requireObject(report.summary, 'substrate_install_report.summary');
  if (
    requireString(summary.installed_by, 'substrate_install_report.summary.installed_by') !==
    'agentsmith-release-kit'
  ) {
    fail('substrate_install_report.summary.installed_by must be agentsmith-release-kit');
  }
  if (
    requirePositiveInteger(summary.resources_count, 'substrate_install_report.summary.resources_count') !==
    proof.resource_count
  ) {
    fail('substrate_install_report.summary.resources_count must match resource_refs length');
  }
  if (
    requirePositiveInteger(
      summary.substrate_services_count,
      'substrate_install_report.summary.substrate_services_count'
    ) !== installedServices.length
  ) {
    fail('substrate_install_report.summary.substrate_services_count must match installed_services length');
  }
  return {
    schema: reportSchema(report),
    scope: report.scope,
    output_substrate_truth_digest: report.output_substrate_truth_digest,
    service_count: installedServices.length,
    input_digests: inputDigests,
    input_bindings: inputBindings,
    proof
  };
}

export function validateAirgapBundleCheckReport(report, release, expectedTargetProfile, bundleManifestDigest) {
  requireSchema(report, AIRGAP_BUNDLE_CHECK_SCHEMA, 'airgap bundle check report');
  requireScope(report, AIRGAP_BUNDLE_CHECK_SCOPE, 'airgap bundle check report');
  requireReadinessFalse(report, 'airgap bundle check report');
  requireNoFormalVerdict(report, 'airgap bundle check report');
  requireStatusPass(report, 'airgap bundle check report');
  requireCommonReleaseFields(report, release, 'airgap bundle check report');
  requireTargetProfile(report.target_profile, expectedTargetProfile, 'airgap_bundle_check_report.target_profile');
  const artifacts = requireObject(report.artifacts, 'airgap_bundle_check_report.artifacts');
  const releaseContract = requireObject(
    artifacts.release_contract,
    'airgap_bundle_check_report.artifacts.release_contract'
  );
  if (
    requireDigest(
      releaseContract.input_sha256,
      'airgap_bundle_check_report.artifacts.release_contract.input_sha256'
    ) !== release.release_contract_digest
  ) {
    fail('airgap bundle check release contract digest must match release contract input');
  }
  const deployTemplatePackage = requireObject(
    artifacts.deploy_template_package,
    'airgap_bundle_check_report.artifacts.deploy_template_package'
  );
  if (
    requireDigest(
      deployTemplatePackage.input_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_package.input_sha256'
    ) !== release.deploy_template_package_digest
  ) {
    fail('airgap bundle check deploy template package digest must match input');
  }
  const imageMap = requireObject(
    artifacts.image_map,
    'airgap_bundle_check_report.artifacts.image_map'
  );
  const imageMapInputSha256 = requireDigest(
    imageMap.input_sha256,
    'airgap_bundle_check_report.artifacts.image_map.input_sha256'
  );
  const bundleManifest = requireObject(
    artifacts.bundle_manifest,
    'airgap_bundle_check_report.artifacts.bundle_manifest'
  );
  if (
    requireDigest(
      bundleManifest.input_sha256,
      'airgap_bundle_check_report.artifacts.bundle_manifest.input_sha256'
    ) !== bundleManifestDigest
  ) {
    fail('airgap bundle check bundle manifest digest must match input');
  }
  return { imageMapInputSha256 };
}

export function validateAirgapBundleManifest(report, release, expectedTargetProfile) {
  requireSchema(report, AIRGAP_BUNDLE_MANIFEST_SCHEMA, 'airgap bundle manifest');
  requireCommonReleaseFields(report, release, 'airgap bundle manifest');
  if (Object.hasOwn(report, 'target_profile')) {
    requireTargetProfile(report.target_profile, expectedTargetProfile, 'airgap_bundle_manifest.target_profile');
  }
}

export function imageMapComponentFromBundleManifest(report) {
  const components = requireArray(report.components, 'airgap_bundle_manifest.components');
  let imageMapComponent;
  for (const [index, rawComponent] of components.entries()) {
    const component = requireObject(rawComponent, `airgap_bundle_manifest.components[${index}]`);
    const kind = requireString(component.kind, `airgap_bundle_manifest.components[${index}].kind`);
    if (kind !== 'image_map') {
      continue;
    }
    if (imageMapComponent) {
      fail('airgap_bundle_manifest.components must contain only one image_map component');
    }
    imageMapComponent = component;
  }
  if (!imageMapComponent) {
    fail('airgap_bundle_manifest.components must include image_map');
  }
  return imageMapComponent;
}

export function airgapImageMapPathFromBundleManifest(report) {
  const component = imageMapComponentFromBundleManifest(report);
  return safeRelativeReportPath(
    component.path,
    'airgap_bundle_manifest.components.image_map.path'
  );
}

export function validateAirgapImageMapEvidence({
  bundleManifestReport,
  imageMapReport,
  imageMapDigest,
  expectedDigest,
  release,
  expectedTargetProfile
}) {
  const component = imageMapComponentFromBundleManifest(bundleManifestReport);
  safeRelativeReportPath(component.path, 'airgap_bundle_manifest.components.image_map.path');
  const componentDigest = requireDigest(
    component.sha256,
    'airgap_bundle_manifest.components.image_map.sha256'
  );
  if (componentDigest !== expectedDigest) {
    fail('airgap bundle manifest image_map sha256 must match airgap bundle check report');
  }
  if (imageMapDigest !== expectedDigest) {
    fail('airgap image map file sha256 must match airgap bundle check report');
  }

  const imageMap = requireObject(imageMapReport, 'airgap image map');
  validateImageMapEvidence({
    imageMap,
    release,
    expectedTargetProfile,
    label: 'airgap image map',
    requireMirror: true,
    requireReleaseContractBinding: true
  });
}

export function validateMaterializedDeploymentPathSourceEvidence({
  operatorPath,
  release,
  sourceDeploymentGateInput,
  sourceInputsByStep,
  airgapBundleManifestInput,
  airgapImageMapInput,
  installOperatorRunId
}) {
  const requirement = DEPLOYMENT_PATHS.get(operatorPath);
  if (!requirement) {
    fail(`unsupported operator path: ${operatorPath}`);
  }

  const gateReport = requireInputReport(
    sourceDeploymentGateInput,
    `${requirement.source} deployment gate report`
  );
  validateDeploymentGateReport({
    report: gateReport,
    source: requirement.source,
    release,
    expectedTargetProfile: requirement.targetProfile
  });
  validateDeploymentGateSourceStepPaths({ gateReport, requirement });

  let airgapContext;
  if (requirement.source === 'airgap') {
    const bundleManifestReport = requireInputReport(airgapBundleManifestInput, 'airgap bundle manifest');
    validateAirgapBundleManifest(bundleManifestReport, release, requirement.targetProfile);
    const bundleCheckInput = requireSourceInput(sourceInputsByStep, 'bundle-check');
    const bundleCheckReport = requireInputReport(bundleCheckInput, 'airgap bundle check report');
    const bundleCheckSummary = validateAirgapBundleCheckReport(
      bundleCheckReport,
      release,
      requirement.targetProfile,
      airgapBundleManifestInput.digest
    );
    const imageMapReport = requireInputReport(airgapImageMapInput, 'airgap image map');
    validateAirgapImageMapEvidence({
      bundleManifestReport,
      imageMapReport,
      imageMapDigest: airgapImageMapInput.digest,
      expectedDigest: bundleCheckSummary.imageMapInputSha256,
      release,
      expectedTargetProfile: requirement.targetProfile
    });
    airgapContext = {
      bundleManifestDigest: airgapBundleManifestInput.digest,
      bundleCheckDigest: bundleCheckInput.digest,
      imageMapInputSha256: bundleCheckSummary.imageMapInputSha256
    };
  }

  let installSummary;
  if (requirement.installSubstrates) {
    const installInput = requireSourceInput(sourceInputsByStep, 'substrate-install');
    installSummary = validateSubstrateInstallReport(
      requireInputReport(installInput, 'substrate install report'),
      release,
      requirement.targetProfile,
      installOperatorRunId
    );
  }

  for (const [reportStep, sourceStep] of requirement.sourceSteps) {
    const sourceInput = requireSourceInput(sourceInputsByStep, reportStep);
    const sourceReport = requireInputReport(sourceInput, `${sourceStep} step report`);
    validateSourceStepReport({
      report: sourceReport,
      sourceStep,
      release,
      expectedTargetProfile: requirement.targetProfile,
      airgapContext
    });
    if (sourceStep === 'airgap-image-load' && airgapContext) {
      airgapContext.imageLoadReport = sourceReport;
    }
  }

  validateInstallSubstrateTruthBinding(installSummary, sourceInputsByStep);
  validateRouteSmokeRolloutBinding(sourceInputsByStep);
  return {
    substrateInstallSummary: installSummary
  };
}
