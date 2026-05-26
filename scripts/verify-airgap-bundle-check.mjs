#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  CANONICAL_DECLARABLE_TARGET_PROFILE_SET,
  CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES,
  DISTRIBUTION_VALUES,
  SUBSTRATE_SOURCE_VALUES,
  TARGET_CLUSTER_VALUES
} from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'imageMap',
  'targetProfile',
  'bundleRoot',
  'bundleManifest',
  'outputDir'
];
const AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const IMAGE_ARRAY_SOURCES = [
  'product_images',
  'adopted_provider_images',
  'release_kit_prerequisite_images'
];
const IMAGE_SINGLETON_SOURCES = ['managed_runner_image'];
const IMAGE_SOURCES = [...IMAGE_ARRAY_SOURCES, ...IMAGE_SINGLETON_SOURCES];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_PACKAGE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const REPORT_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const REPORT_SCOPE = 'airgap_bundle_manifest_check_only';
const REPORT_FILE = 'airgap-bundle-check-report.json';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_COMPONENT_KINDS = new Set([
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'image_map'
]);
const BUNDLE_MANIFEST_KEYS = new Set([
  'schema_version',
  'release_id',
  'git_sha',
  'target_profile',
  'bindings',
  'components',
  'image_artifact_declarations',
  'payload_artifacts',
  'operator_prerequisites',
  'substrate'
]);
const BUNDLE_BINDING_KEYS = new Set([
  'release_contract_sha256',
  'deploy_template_package_sha256',
  'deploy_template_archive_sha256',
  'deploy_template_manifest_sha256',
  'image_map_sha256'
]);
const BUNDLE_COMPONENT_KEYS = new Set(['kind', 'path', 'sha256']);
const IMAGE_ARTIFACT_DECLARATION_KEYS = new Set([
  'id',
  'source_image',
  'source_digest',
  'target_image',
  'target_digest',
  'artifact_format',
  'path',
  'sha256'
]);
const PAYLOAD_ARTIFACT_KEYS = new Set(['id', 'kind', 'path', 'sha256']);
const PAYLOAD_ARTIFACT_KINDS = new Set([
  'runbook',
  'script',
  'profile_values_schema',
  'profile_values_example',
  'checksums'
]);
const REQUIRED_PAYLOAD_ARTIFACT_KINDS = new Set([
  'runbook',
  'script',
  'profile_values_schema',
  'checksums'
]);
const OPERATOR_PREREQUISITES_KEYS = new Set([
  'substrate_connection_truth_ref',
  'target_registry_proof_ref',
  'tools'
]);
const BUNDLED_TOOL_KEYS = new Set(['name', 'version', 'source', 'path', 'sha256']);
const OPERATOR_PREREQUISITE_TOOL_KEYS = new Set([
  'name',
  'version',
  'source',
  'location',
  'proof'
]);
const TARGET_PROFILE_KEYS = new Set([
  'value',
  'target_cluster',
  'substrate_source',
  'distribution'
]);
const BUNDLE_SUBSTRATE_KEYS = new Set(['mode', 'bundled']);
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const OPERATOR_REF_URI_SCHEME_RE = /\b[a-z][a-z0-9+.-]*:\/\/[^\s]*/i;
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:postgres|mongodb|redis):\/\/[^:\s]+:[^@\s]+@/i,
  /\b(?:password|token|secret|client_secret)\s*[:=]\s*["']?[^"'\s]{8,}/i,
  /\bexecution[_ -]?ticket\b/i,
  /\bmanaged_credentials\b/i,
  /\bkubeconfig\b/i
];
const DOWNLOAD_SEMANTICS_RE = /\b(?:public\s+download|public\s+url|https?\s+url|curl|wget|docker\s+pull|oras\s+pull|skopeo\s+copy)\b/i;

class CliError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 2;
  }
}

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

function usage() {
  return `Usage:
  node scripts/verify-airgap-bundle-check.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --image-map <json> \\
    --target-profile existing_kubernetes/external_declared/airgap \\
    --bundle-root <dir> \\
    --bundle-manifest <json> \\
    --output-dir <dir>`;
}

function cliFail(message) {
  throw new CliError(message);
}

function fail(message) {
  throw new ValidationError(message);
}

function toKebab(value) {
  return value.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--deploy-template-package':
        parsed.deployTemplatePackage = nextValue();
        break;
      case '--archive':
        parsed.archive = nextValue();
        break;
      case '--image-map':
        parsed.imageMap = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--bundle-root':
        parsed.bundleRoot = nextValue();
        break;
      case '--bundle-manifest':
        parsed.bundleManifest = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        cliFail(`unknown argument: ${arg}`);
    }
  }

  if (parsed.help) {
    return parsed;
  }

  for (const key of REQUIRED_ARGS) {
    if (!parsed[key]) {
      cliFail(`missing required argument: --${toKebab(key)}`);
    }
  }

  return parsed;
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function readJson(file, label) {
  let raw;
  try {
    raw = await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      value: JSON.parse(raw),
      raw,
      inputDigest: digestBuffer(Buffer.from(raw))
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function removeStaleReport(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
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

function requireBooleanFalse(value, label) {
  if (value !== false) {
    fail(`${label} must be false`);
  }
  return value;
}

function requireBooleanTrue(value, label) {
  if (value !== true) {
    fail(`${label} must be true`);
  }
  return value;
}

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') {
    fail(`${label} must be a boolean`);
  }
  return value;
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function requireGitSha(value, label) {
  const gitSha = requireString(value, label).toLowerCase();
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function assertStringEquals(value, expected, label) {
  const actual = requireString(value, label);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function requireEnumString(value, label, allowedValues) {
  const actual = requireString(value, label);
  if (!allowedValues.has(actual)) {
    fail(`${label} is invalid`);
  }
  return actual;
}

function assertAllowedKeys(object, allowedKeys, label) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function parseTargetProfile(value) {
  if (value !== AIRGAP_TARGET_PROFILE) {
    fail(`--airgap-bundle-check only accepts ${AIRGAP_TARGET_PROFILE}`);
  }

  return {
    value,
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'airgap'
  };
}

function assertTargetProfileObject(value, label) {
  const profile = requireObject(value, label);
  assertAllowedKeys(profile, TARGET_PROFILE_KEYS, label);
  assertStringEquals(profile.value, AIRGAP_TARGET_PROFILE, `${label}.value`);
  assertStringEquals(
    profile.target_cluster,
    'existing_kubernetes',
    `${label}.target_cluster`
  );
  assertStringEquals(
    profile.substrate_source,
    'external_declared',
    `${label}.substrate_source`
  );
  assertStringEquals(profile.distribution, 'airgap', `${label}.distribution`);

  return {
    value: AIRGAP_TARGET_PROFILE,
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'airgap'
  };
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

function assertSameJson(left, right, label) {
  if (JSON.stringify(stableJson(left)) !== JSON.stringify(stableJson(right))) {
    fail(`${label} mismatch`);
  }
}

function imageDigestSuffix(image, label) {
  if (/\s/.test(image)) {
    fail(`${label} must not contain whitespace`);
  }
  if (URI_SCHEME_RE.test(image)) {
    fail(`${label} must be an image reference, not a URI`);
  }
  if (/[?#]/.test(image)) {
    fail(`${label} must not contain query or hash text`);
  }

  const marker = '@sha256:';
  const index = image.lastIndexOf(marker);
  if (index < 0) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const imageWithoutDigest = image.slice(0, index);
  if (imageWithoutDigest === '') {
    fail(`${label} must include an image repository`);
  }
  if (imageWithoutDigest.includes('@')) {
    fail(`${label} must contain only one digest separator`);
  }

  const digest = `sha256:${image.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return { digest, imageWithoutDigest };
}

function buildDeployImageInventory(contract) {
  const items = requireArray(
    contract.deploy_image_inventory,
    'release_contract.deploy_image_inventory'
  );
  if (items.length === 0) {
    fail('release_contract.deploy_image_inventory must not be empty');
  }

  const byId = new Map();
  for (const [index, itemValue] of items.entries()) {
    const label = `release_contract.deploy_image_inventory[${index}]`;
    const item = requireObject(itemValue, label);
    const id = requireString(item.id, `${label}.id`);
    if (byId.has(id)) {
      fail(`release_contract.deploy_image_inventory contains duplicate image id: ${id}`);
    }
    const source = requireString(item.source, `${label}.source`);
    if (!IMAGE_SOURCES.includes(source)) {
      fail(`${label}.source is not a known image source`);
    }
    const sourceImage = requireString(item.image, `${label}.image`);
    const declaredDigest = requireDigest(item.digest, `${label}.digest`);
    const { digest } = imageDigestSuffix(sourceImage, `${label}.image`);
    if (digest !== declaredDigest) {
      fail(`${label}.digest must match image digest suffix`);
    }
    byId.set(id, {
      id,
      source,
      source_image: sourceImage,
      source_digest: declaredDigest
    });
  }

  const expectedItems = [
    ...IMAGE_ARRAY_SOURCES.flatMap((source) => {
      const group = requireArray(contract[source], `release_contract.${source}`);
      if (group.length === 0) {
        fail(`release_contract.${source} must not be empty`);
      }
      return group.map((itemValue, index) => {
        const label = `release_contract.${source}[${index}]`;
        const item = requireObject(itemValue, label);
        const image = requireString(item.image, `${label}.image`);
        const declaredDigest = requireDigest(item.digest, `${label}.digest`);
        const { digest } = imageDigestSuffix(image, `${label}.image`);
        if (digest !== declaredDigest) {
          fail(`${label}.digest must match image digest suffix`);
        }
        return {
          id: requireString(item.id, `${label}.id`),
          source,
          source_image: image,
          source_digest: declaredDigest
        };
      });
    }),
    ...IMAGE_SINGLETON_SOURCES.map((source) => {
      const label = `release_contract.${source}`;
      const item = requireObject(contract[source], label);
      const image = requireString(item.image, `${label}.image`);
      const declaredDigest = requireDigest(item.digest, `${label}.digest`);
      const { digest } = imageDigestSuffix(image, `${label}.image`);
      if (digest !== declaredDigest) {
        fail(`${label}.digest must match image digest suffix`);
      }
      return {
        id: requireString(item.id, `${label}.id`),
        source,
        source_image: image,
        source_digest: declaredDigest
      };
    })
  ];
  if (expectedItems.length !== byId.size) {
    fail('release_contract.deploy_image_inventory must match declared image sources');
  }
  for (const expected of expectedItems) {
    const actual = byId.get(expected.id);
    if (
      !actual ||
      actual.source !== expected.source ||
      actual.source_image !== expected.source_image ||
      actual.source_digest !== expected.source_digest
    ) {
      fail('release_contract.deploy_image_inventory must match declared image sources');
    }
  }

  return byId;
}

function normalizeRequiredImageIds(value, label) {
  const ids = requireArray(value, label);
  if (ids.length === 0) {
    fail(`${label} must not be empty`);
  }

  const seen = new Set();
  return ids.map((item, index) => {
    const id = requireString(item, `${label}[${index}]`);
    if (seen.has(id)) {
      fail(`${label} contains duplicate image id: ${id}`);
    }
    seen.add(id);
    return id;
  });
}

function assertSameStringSet(
  actual,
  expected,
  label,
  expectedLabel = 'release_contract.required_image_ids'
) {
  const actualSet = new Set(actual);
  const expectedSet = new Set(expected);
  if (actualSet.size !== expectedSet.size) {
    fail(`${label} must match ${expectedLabel}`);
  }
  for (const id of actualSet) {
    if (!expectedSet.has(id)) {
      fail(`${label} must match ${expectedLabel}`);
    }
  }
}

function assertRequiredImageIds(contract, deployTemplatePackage, deployImageInventoryById) {
  const contractRequiredImageIds = normalizeRequiredImageIds(
    contract.required_image_ids,
    'release_contract.required_image_ids'
  );
  const packageRequiredImageIds = normalizeRequiredImageIds(
    deployTemplatePackage.required_image_ids,
    'deploy_template_package.required_image_ids'
  );
  assertSameStringSet(
    packageRequiredImageIds,
    contractRequiredImageIds,
    'deploy_template_package.required_image_ids'
  );
  const inventoryIds = [...deployImageInventoryById.keys()];
  assertSameStringSet(
    contractRequiredImageIds,
    inventoryIds,
    'release_contract.required_image_ids',
    'release_contract.deploy_image_inventory ids'
  );
  assertSameStringSet(
    packageRequiredImageIds,
    inventoryIds,
    'deploy_template_package.required_image_ids',
    'release_contract.deploy_image_inventory ids'
  );
}

function assertReleaseContract(contract, deployTemplatePackage) {
  assertStringEquals(
    contract.schema_version,
    RELEASE_CONTRACT_SCHEMA,
    'release_contract.schema_version'
  );
  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const deployTemplateDigest = requireDigest(
    contract.deploy_template_digest,
    'release_contract.deploy_template_digest'
  );
  const embeddedPackage = requireObject(
    contract.deploy_template_package,
    'release_contract.deploy_template_package'
  );
  assertSameJson(
    embeddedPackage,
    deployTemplatePackage,
    'release_contract.deploy_template_package'
  );
  assertContractTargetProfiles(contract);
  const deployImageInventoryById = buildDeployImageInventory(contract);
  assertRequiredImageIds(contract, deployTemplatePackage, deployImageInventoryById);

  return { releaseId, gitSha, deployTemplateDigest, deployImageInventoryById };
}

function assertContractTargetProfiles(contract) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const seen = new Map();
  let hasAirgapProfile = false;

  for (const [index, profileValue] of profiles.entries()) {
    const label = `release_contract.target_profiles[${index}]`;
    const profile = requireObject(profileValue, label);
    const targetCluster = requireEnumString(
      profile.target_cluster,
      `${label}.target_cluster`,
      TARGET_CLUSTER_VALUES
    );
    const substrateSource = requireEnumString(
      profile.substrate_source,
      `${label}.substrate_source`,
      SUBSTRATE_SOURCE_VALUES
    );
    const distribution = requireEnumString(
      profile.distribution,
      `${label}.distribution`,
      DISTRIBUTION_VALUES
    );
    const tuple = `${targetCluster}/${substrateSource}/${distribution}`;
    if (!CANONICAL_DECLARABLE_TARGET_PROFILE_SET.has(tuple)) {
      fail(
        `${label} must be one of canonical profiles: ${CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES.join(
          ', '
        )}`
      );
    }
    if (Object.prototype.hasOwnProperty.call(profile, 'support_level')) {
      fail(`${label}.support_level is not allowed; use ${label}.required`);
    }
    if (!Object.prototype.hasOwnProperty.call(profile, 'required')) {
      fail(`${label}.required is required`);
    }
    const required = requireBoolean(profile.required, `${label}.required`);
    if (required) {
      fail(`${label}.required must be false during pre-GA`);
    }
    if (seen.has(tuple)) {
      fail(`${label} duplicates target profile tuple declared at ${seen.get(tuple)}`);
    }
    seen.set(tuple, label);
    if (tuple === AIRGAP_TARGET_PROFILE) {
      hasAirgapProfile = true;
    }
  }

  if (!hasAirgapProfile) {
    fail(`release_contract.target_profiles must include ${AIRGAP_TARGET_PROFILE}`);
  }
}

function assertDeployTemplatePackage(deployTemplatePackage, archiveSha256) {
  assertStringEquals(
    deployTemplatePackage.schema_version,
    DEPLOY_TEMPLATE_PACKAGE_SCHEMA,
    'deploy_template_package.schema_version'
  );
  const packageSha256 = requireDigest(
    deployTemplatePackage.package_sha256,
    'deploy_template_package.package_sha256'
  );
  const manifestSha256 = requireDigest(
    deployTemplatePackage.manifest_sha256,
    'deploy_template_package.manifest_sha256'
  );
  if (packageSha256 !== archiveSha256) {
    fail('deploy_template_package.package_sha256 must match archive sha256');
  }

  const artifactProvenance = requireObject(
    deployTemplatePackage.artifact_provenance,
    'deploy_template_package.artifact_provenance'
  );
  const artifactSha256 = requireDigest(
    artifactProvenance.artifact_sha256,
    'deploy_template_package.artifact_provenance.artifact_sha256'
  );
  if (artifactSha256 !== archiveSha256) {
    fail('deploy_template_package.artifact_provenance.artifact_sha256 must match archive sha256');
  }

  return { packageSha256, manifestSha256, artifactSha256 };
}

function assertReleaseAndPackageBinding(contractSummary, deployTemplateSummary) {
  if (contractSummary.deployTemplateDigest !== deployTemplateSummary.manifestSha256) {
    fail('release_contract.deploy_template_digest must match deploy_template_package.manifest_sha256');
  }
}

function assertImageMap({
  imageMap,
  imageMapInputDigest,
  releaseContractInputDigest,
  releaseId,
  gitSha,
  deployImageInventoryById
}) {
  assertStringEquals(imageMap.schema, IMAGE_MAP_SCHEMA, 'image_map.schema');
  assertStringEquals(imageMap.scope, 'image_map_only', 'image_map.scope');
  requireBooleanFalse(imageMap.readiness, 'image_map.readiness');
  assertStringEquals(imageMap.status, 'pass', 'image_map.status');
  assertStringEquals(imageMap.release_id, releaseId, 'image_map.release_id');
  assertStringEquals(imageMap.git_sha, gitSha, 'image_map.git_sha');
  assertTargetProfileObject(imageMap.target_profile, 'image_map.target_profile');
  requireBooleanTrue(imageMap.mirror_required, 'image_map.mirror_required');
  const targetRegistry = requireString(imageMap.target_registry, 'image_map.target_registry');

  const releaseContract = requireObject(
    imageMap.release_contract,
    'image_map.release_contract'
  );
  const imageMapReleaseContractSha = requireDigest(
    releaseContract.input_sha256,
    'image_map.release_contract.input_sha256'
  );
  if (imageMapReleaseContractSha !== releaseContractInputDigest) {
    fail('image_map.release_contract.input_sha256 must match release contract input sha256');
  }
  const inventoryCount = requireInteger(
    releaseContract.deploy_image_inventory_count,
    'image_map.release_contract.deploy_image_inventory_count'
  );
  if (inventoryCount !== deployImageInventoryById.size) {
    fail('image_map.release_contract.deploy_image_inventory_count must match release_contract.deploy_image_inventory length');
  }

  const mappings = requireArray(imageMap.mappings, 'image_map.mappings');
  if (mappings.length === 0) {
    fail('image_map.mappings must not be empty');
  }
  if (mappings.length !== deployImageInventoryById.size) {
    fail('image_map.mappings must match release_contract.deploy_image_inventory length');
  }
  if (imageMap.image_count !== mappings.length) {
    fail('image_map.image_count must match image_map.mappings length');
  }

  const byId = new Map();
  for (const [index, value] of mappings.entries()) {
    const label = `image_map.mappings[${index}]`;
    const mapping = requireObject(value, label);
    const id = requireString(mapping.id, `${label}.id`);
    if (byId.has(id)) {
      fail(`image_map.mappings contains duplicate id: ${id}`);
    }
    const inventoryItem = deployImageInventoryById.get(id);
    if (!inventoryItem) {
      fail(`${label}.id must exist in release_contract.deploy_image_inventory`);
    }
    assertStringEquals(mapping.source, inventoryItem.source, `${label}.source`);
    const sourceImage = requireString(mapping.source_image, `${label}.source_image`);
    if (sourceImage !== inventoryItem.source_image) {
      fail(`${label}.source_image must match release_contract.deploy_image_inventory`);
    }
    const sourceDigest = requireDigest(mapping.source_digest, `${label}.source_digest`);
    if (sourceDigest !== inventoryItem.source_digest) {
      fail(`${label}.source_digest must match release_contract.deploy_image_inventory`);
    }
    const targetImage = requireString(mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${label}.target_digest`);
    if (targetDigest !== sourceDigest) {
      fail(`${label}.target_digest must match source_digest`);
    }
    const { digest: targetImageDigest } = imageDigestSuffix(
      targetImage,
      `${label}.target_image`
    );
    if (!targetImage.startsWith(`${targetRegistry}/`)) {
      fail(`${label}.target_image must be under image_map.target_registry`);
    }
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
    assertStringEquals(mapping.action, 'mirror_required', `${label}.action`);

    byId.set(id, {
      id,
      source_image: sourceImage,
      source_digest: sourceDigest,
      target_image: targetImage,
      target_digest: targetDigest
    });
  }

  for (const id of deployImageInventoryById.keys()) {
    if (!byId.has(id)) {
      fail(`image_map.mappings is missing release_contract.deploy_image_inventory id: ${id}`);
    }
  }

  return {
    inputSha256: imageMapInputDigest,
    imageCount: mappings.length,
    mappingsById: byId
  };
}

async function canonicalBundleRoot(input) {
  const requested = path.resolve(input);
  let stat;
  try {
    stat = await fs.stat(requested);
  } catch (error) {
    fail(`cannot read bundle root: ${error.message}`);
  }
  if (!stat.isDirectory()) {
    fail('bundle root must be a directory');
  }

  try {
    return await fs.realpath(requested);
  } catch (error) {
    fail(`cannot resolve bundle root: ${error.message}`);
  }
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function validateSafeRelativePath(value, label) {
  const relativePath = requireString(value, label);
  if (relativePath.trim() !== relativePath) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (
    path.posix.isAbsolute(relativePath) ||
    path.isAbsolute(relativePath) ||
    WINDOWS_DRIVE_RE.test(relativePath)
  ) {
    fail(`${label} must be a relative bundle path`);
  }
  if (relativePath.includes('\\')) {
    fail(`${label} must use POSIX path separators`);
  }
  if (URI_SCHEME_RE.test(relativePath)) {
    fail(`${label} must be a relative bundle path, not a URI`);
  }

  const segments = relativePath.split('/');
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
    fail(`${label} must not contain empty, dot, or parent segments`);
  }

  return relativePath;
}

async function resolveBundleFile(bundleRoot, relativePath, label) {
  const safePath = validateSafeRelativePath(relativePath, label);
  const candidate = path.resolve(bundleRoot, ...safePath.split('/'));
  if (!isInsidePath(bundleRoot, candidate)) {
    fail(`${label} must stay under bundle root`);
  }

  let stat;
  try {
    stat = await fs.lstat(candidate);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a file`);
  }

  let realPath;
  try {
    realPath = await fs.realpath(candidate);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
  if (!isInsidePath(bundleRoot, realPath)) {
    fail(`${label} must resolve under bundle root`);
  }

  return realPath;
}

async function digestFile(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return digestBuffer(buffer);
}

async function assertBundleFileSha({ bundleRoot, relativePath, declaredSha256, label }) {
  const file = await resolveBundleFile(bundleRoot, relativePath, `${label}.path`);
  const actualSha256 = await digestFile(file, `${label}.path`);
  if (actualSha256 !== declaredSha256) {
    fail(`${label}.sha256 must match bundle file sha256`);
  }
}

function assertBindings({ bindings, expected }) {
  const bindingObject = requireObject(bindings, 'bundle_manifest.bindings');
  assertAllowedKeys(bindingObject, BUNDLE_BINDING_KEYS, 'bundle_manifest.bindings');
  for (const [key, expectedDigest] of Object.entries(expected)) {
    const actual = requireDigest(bindingObject[key], `bundle_manifest.bindings.${key}`);
    if (actual !== expectedDigest) {
      fail(`bundle_manifest.bindings.${key} must match expected sha256`);
    }
  }
}

async function assertComponents({ components, bundleRoot, expected }) {
  const items = requireArray(components, 'bundle_manifest.components');
  if (items.length !== SAFE_COMPONENT_KINDS.size) {
    fail('bundle_manifest.components must contain release_contract, deploy_template_package, deploy_template_archive, and image_map');
  }

  const seen = new Set();
  for (const [index, value] of items.entries()) {
    const label = `bundle_manifest.components[${index}]`;
    const component = requireObject(value, label);
    assertAllowedKeys(component, BUNDLE_COMPONENT_KEYS, label);
    const kind = requireString(component.kind, `${label}.kind`);
    if (!SAFE_COMPONENT_KINDS.has(kind)) {
      fail(`${label}.kind is invalid; expected release_contract, deploy_template_package, deploy_template_archive, or image_map`);
    }
    if (seen.has(kind)) {
      fail(`bundle_manifest.components contains duplicate kind: ${kind}`);
    }
    seen.add(kind);

    const declaredSha256 = requireDigest(component.sha256, `${label}.sha256`);
    if (declaredSha256 !== expected[kind]) {
      fail(`${label}.sha256 must match expected input sha256`);
    }
    const file = await resolveBundleFile(bundleRoot, component.path, `${label}.path`);
    const actualSha256 = await digestFile(file, `${label}.path`);
    if (actualSha256 !== declaredSha256) {
      fail(`${label}.sha256 must match component file sha256`);
    }
  }

  for (const kind of SAFE_COMPONENT_KINDS) {
    if (!seen.has(kind)) {
      fail(`bundle_manifest.components is missing ${kind}`);
    }
  }

  return items.length;
}

async function assertImageArtifactDeclarations({ declarations, bundleRoot, imageMapSummary }) {
  const items = requireArray(
    declarations,
    'bundle_manifest.image_artifact_declarations'
  );
  if (items.length !== imageMapSummary.mappingsById.size) {
    fail('bundle_manifest.image_artifact_declarations must match image_map.mappings length');
  }

  const seen = new Set();
  for (const [index, value] of items.entries()) {
    const label = `bundle_manifest.image_artifact_declarations[${index}]`;
    const declaration = requireObject(value, label);
    assertAllowedKeys(declaration, IMAGE_ARTIFACT_DECLARATION_KEYS, label);
    const id = requireString(declaration.id, `${label}.id`);
    if (seen.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations contains duplicate id: ${id}`);
    }
    seen.add(id);

    const mapping = imageMapSummary.mappingsById.get(id);
    if (!mapping) {
      fail(`${label}.id must exist in image_map.mappings`);
    }
    assertStringEquals(declaration.source_image, mapping.source_image, `${label}.source_image`);
    const sourceDigest = requireDigest(declaration.source_digest, `${label}.source_digest`);
    if (sourceDigest !== mapping.source_digest) {
      fail(`${label}.source_digest must match image_map mapping`);
    }
    assertStringEquals(declaration.target_image, mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(declaration.target_digest, `${label}.target_digest`);
    if (targetDigest !== mapping.target_digest) {
      fail(`${label}.target_digest must match image_map mapping`);
    }
    assertStringEquals(declaration.artifact_format, 'oci_layout_tar', `${label}.artifact_format`);

    const declaredSha256 = requireDigest(declaration.sha256, `${label}.sha256`);
    const file = await resolveBundleFile(bundleRoot, declaration.path, `${label}.path`);
    const actualSha256 = await digestFile(file, `${label}.path`);
    if (actualSha256 !== declaredSha256) {
      fail(`${label}.sha256 must match image artifact file sha256`);
    }
  }

  for (const id of imageMapSummary.mappingsById.keys()) {
    if (!seen.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations is missing ${id}`);
    }
  }

  return items.length;
}

async function assertPayloadArtifacts({ artifacts, bundleRoot }) {
  const items = requireArray(artifacts, 'bundle_manifest.payload_artifacts');
  const seenIds = new Set();
  const seenRequiredKinds = new Set();

  for (const [index, value] of items.entries()) {
    const label = `bundle_manifest.payload_artifacts[${index}]`;
    const artifact = requireObject(value, label);
    assertAllowedKeys(artifact, PAYLOAD_ARTIFACT_KEYS, label);
    const id = requireString(artifact.id, `${label}.id`);
    if (seenIds.has(id)) {
      fail(`bundle_manifest.payload_artifacts contains duplicate id: ${id}`);
    }
    seenIds.add(id);

    const kind = requireString(artifact.kind, `${label}.kind`);
    if (!PAYLOAD_ARTIFACT_KINDS.has(kind)) {
      fail(`${label}.kind is invalid`);
    }
    if (REQUIRED_PAYLOAD_ARTIFACT_KINDS.has(kind)) {
      seenRequiredKinds.add(kind);
    }

    const declaredSha256 = requireDigest(artifact.sha256, `${label}.sha256`);
    await assertBundleFileSha({
      bundleRoot,
      relativePath: artifact.path,
      declaredSha256,
      label
    });
  }

  for (const kind of REQUIRED_PAYLOAD_ARTIFACT_KINDS) {
    if (!seenRequiredKinds.has(kind)) {
      fail(`bundle_manifest.payload_artifacts is missing required payload type: ${kind}`);
    }
  }

  return items.length;
}

function assertOperatorRef(value, label) {
  const ref = requireString(value, label);
  if (ref.trim() !== ref) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (OPERATOR_REF_URI_SCHEME_RE.test(ref)) {
    fail(`${label} must be an operator-held reference, not a URI`);
  }
  if (DOWNLOAD_SEMANTICS_RE.test(ref)) {
    fail(`${label} must not describe public download semantics`);
  }
  if (SECRET_VALUE_RE.some((pattern) => pattern.test(ref))) {
    fail(`${label} must not contain secret-looking content`);
  }
  return ref;
}

async function assertOperatorPrerequisites({ prerequisites, bundleRoot }) {
  const object = requireObject(
    prerequisites,
    'bundle_manifest.operator_prerequisites'
  );
  assertAllowedKeys(
    object,
    OPERATOR_PREREQUISITES_KEYS,
    'bundle_manifest.operator_prerequisites'
  );
  assertOperatorRef(
    object.substrate_connection_truth_ref,
    'bundle_manifest.operator_prerequisites.substrate_connection_truth_ref'
  );
  assertOperatorRef(
    object.target_registry_proof_ref,
    'bundle_manifest.operator_prerequisites.target_registry_proof_ref'
  );

  const tools = requireArray(
    object.tools,
    'bundle_manifest.operator_prerequisites.tools'
  );
  if (tools.length === 0) {
    fail('bundle_manifest.operator_prerequisites.tools must not be empty');
  }

  let bundledToolCount = 0;
  let operatorPrerequisiteToolCount = 0;
  for (const [index, value] of tools.entries()) {
    const label = `bundle_manifest.operator_prerequisites.tools[${index}]`;
    const tool = requireObject(value, label);
    const source = requireString(tool.source, `${label}.source`);
    if (source === 'bundled') {
      assertAllowedKeys(tool, BUNDLED_TOOL_KEYS, label);
      requireString(tool.name, `${label}.name`);
      requireString(tool.version, `${label}.version`);
      const declaredSha256 = requireDigest(tool.sha256, `${label}.sha256`);
      await assertBundleFileSha({
        bundleRoot,
        relativePath: tool.path,
        declaredSha256,
        label
      });
      bundledToolCount += 1;
    } else if (source === 'operator_prerequisite') {
      assertAllowedKeys(tool, OPERATOR_PREREQUISITE_TOOL_KEYS, label);
      requireString(tool.name, `${label}.name`);
      requireString(tool.version, `${label}.version`);
      assertOperatorRef(tool.location, `${label}.location`);
      assertOperatorRef(tool.proof, `${label}.proof`);
      operatorPrerequisiteToolCount += 1;
    } else {
      fail(`${label}.source is invalid`);
    }
  }

  return {
    toolCount: tools.length,
    bundledToolCount,
    operatorPrerequisiteToolCount
  };
}

function assertSubstrate(value) {
  const substrate = requireObject(value, 'bundle_manifest.substrate');
  assertAllowedKeys(substrate, BUNDLE_SUBSTRATE_KEYS, 'bundle_manifest.substrate');
  assertStringEquals(substrate.mode, 'external_declared', 'bundle_manifest.substrate.mode');
  requireBooleanFalse(substrate.bundled, 'bundle_manifest.substrate.bundled');
}

async function assertBundleManifest({
  manifest,
  bundleRoot,
  releaseId,
  gitSha,
  expectedBindings,
  expectedComponentSha256,
  imageMapSummary
}) {
  assertAllowedKeys(manifest, BUNDLE_MANIFEST_KEYS, 'bundle_manifest');
  assertStringEquals(
    manifest.schema_version,
    BUNDLE_MANIFEST_SCHEMA,
    'bundle_manifest.schema_version'
  );
  assertStringEquals(manifest.release_id, releaseId, 'bundle_manifest.release_id');
  assertStringEquals(manifest.git_sha, gitSha, 'bundle_manifest.git_sha');
  assertTargetProfileObject(manifest.target_profile, 'bundle_manifest.target_profile');
  assertBindings({ bindings: manifest.bindings, expected: expectedBindings });
  const componentsCount = await assertComponents({
    components: manifest.components,
    bundleRoot,
    expected: expectedComponentSha256
  });
  const imageArtifactDeclarationCount = await assertImageArtifactDeclarations({
    declarations: manifest.image_artifact_declarations,
    bundleRoot,
    imageMapSummary
  });
  const payloadArtifactCount = await assertPayloadArtifacts({
    artifacts: manifest.payload_artifacts,
    bundleRoot
  });
  const operatorPrerequisiteSummary = await assertOperatorPrerequisites({
    prerequisites: manifest.operator_prerequisites,
    bundleRoot
  });
  assertSubstrate(manifest.substrate);

  return {
    componentsCount,
    imageArtifactDeclarationCount,
    payloadArtifactCount,
    ...operatorPrerequisiteSummary
  };
}

function buildReport({
  releaseId,
  gitSha,
  targetProfile,
  releaseContractInputDigest,
  deployTemplatePackageInputDigest,
  deployTemplateArchiveInputDigest,
  deployTemplateSummary,
  imageMapSummary,
  bundleManifestInputDigest,
  bundleSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: releaseId,
    git_sha: gitSha,
    target_profile: targetProfile,
    artifacts: {
      release_contract: {
        input_sha256: releaseContractInputDigest
      },
      deploy_template_package: {
        input_sha256: deployTemplatePackageInputDigest,
        package_sha256: deployTemplateSummary.packageSha256,
        manifest_sha256: deployTemplateSummary.manifestSha256,
        artifact_sha256: deployTemplateSummary.artifactSha256
      },
      deploy_template_archive: {
        input_sha256: deployTemplateArchiveInputDigest
      },
      image_map: {
        input_sha256: imageMapSummary.inputSha256,
        image_count: imageMapSummary.imageCount
      },
      bundle_manifest: {
        input_sha256: bundleManifestInputDigest,
        image_artifact_declaration_count: bundleSummary.imageArtifactDeclarationCount
      }
    },
    components_count: bundleSummary.componentsCount,
    image_artifact_declaration_count: bundleSummary.imageArtifactDeclarationCount,
    payload_artifact_count: bundleSummary.payloadArtifactCount,
    tool_count: bundleSummary.toolCount,
    bundled_tool_count: bundleSummary.bundledToolCount,
    operator_prerequisite_tool_count: bundleSummary.operatorPrerequisiteToolCount
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-bundle-check.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(args.outputDir);

  const targetProfile = parseTargetProfile(args.targetProfile);
  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const deployTemplatePackageInput = await readJson(
    args.deployTemplatePackage,
    'deploy template package'
  );
  const imageMapInput = await readJson(args.imageMap, 'image map');
  const bundleManifestInput = await readJson(args.bundleManifest, 'bundle manifest');
  const deployTemplateArchiveInputDigest = await digestFile(
    args.archive,
    'deploy template archive'
  );
  const bundleRoot = await canonicalBundleRoot(args.bundleRoot);

  const deployTemplatePackage = requireObject(
    deployTemplatePackageInput.value,
    'deploy_template_package'
  );
  const deployTemplateSummary = assertDeployTemplatePackage(
    deployTemplatePackage,
    deployTemplateArchiveInputDigest
  );
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const contractSummary = assertReleaseContract(contract, deployTemplatePackage);
  assertReleaseAndPackageBinding(contractSummary, deployTemplateSummary);

  const imageMap = requireObject(imageMapInput.value, 'image_map');
  const imageMapSummary = assertImageMap({
    imageMap,
    imageMapInputDigest: imageMapInput.inputDigest,
    releaseContractInputDigest: releaseContractInput.inputDigest,
    releaseId: contractSummary.releaseId,
    gitSha: contractSummary.gitSha,
    deployImageInventoryById: contractSummary.deployImageInventoryById
  });

  const bundleManifest = requireObject(bundleManifestInput.value, 'bundle_manifest');
  const bundleSummary = await assertBundleManifest({
    manifest: bundleManifest,
    bundleRoot,
    releaseId: contractSummary.releaseId,
    gitSha: contractSummary.gitSha,
    expectedBindings: {
      release_contract_sha256: releaseContractInput.inputDigest,
      deploy_template_package_sha256: deployTemplatePackageInput.inputDigest,
      deploy_template_archive_sha256: deployTemplateArchiveInputDigest,
      deploy_template_manifest_sha256: deployTemplateSummary.manifestSha256,
      image_map_sha256: imageMapInput.inputDigest
    },
    expectedComponentSha256: {
      release_contract: releaseContractInput.inputDigest,
      deploy_template_package: deployTemplatePackageInput.inputDigest,
      deploy_template_archive: deployTemplateArchiveInputDigest,
      image_map: imageMapInput.inputDigest
    },
    imageMapSummary
  });

  await writeReport(
    args.outputDir,
    buildReport({
      releaseId: contractSummary.releaseId,
      gitSha: contractSummary.gitSha,
      targetProfile,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      deployTemplatePackageInputDigest: deployTemplatePackageInput.inputDigest,
      deployTemplateArchiveInputDigest,
      deployTemplateSummary,
      imageMapSummary,
      bundleManifestInputDigest: bundleManifestInput.inputDigest,
      bundleSummary
    })
  );

  console.log('PASS: airgap bundle manifest/digest check accepted readiness=false');
}

main().catch((error) => {
  const exitCode = error.exitCode || 1;
  const prefix = exitCode === 2 ? 'error' : 'FAIL';
  console.error(`${prefix}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
