#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  CANONICAL_DECLARABLE_TARGET_PROFILE_SET,
  CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES,
  IMAGE_MAP_TARGET_PROFILE_SET,
  IMAGE_MAP_TARGET_PROFILE_VALUES,
  REQUIRED_TARGET_PROFILE_FOCUSED_DIAGNOSTIC_MESSAGE
} from './lib/release-kit-version-policy.mjs';
import {
  imageDigestSuffix,
  targetImageFor,
  validateImageMapEvidence,
  validateTargetRegistry
} from './lib/image-map-validation.mjs';

const REQUIRED_ARGS = ['releaseContract', 'targetProfile', 'outputDir'];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const REPORT_SCHEMA = 'agentsmith.image-map/v1';
const IMAGE_MAP_SCOPE = 'image_map_only';
const IMAGE_ARRAY_SOURCES = [
  'product_images',
  'adopted_provider_images',
  'release_kit_prerequisite_images'
];
const IMAGE_SINGLETON_SOURCES = ['managed_runner_image'];
const IMAGE_SOURCES = [...IMAGE_ARRAY_SOURCES, ...IMAGE_SINGLETON_SOURCES];
const MANAGED_RUNNER_IMAGE_SOURCE = 'managed_runner_image';
const DECLARED_MANAGED_RUNNER_IMAGE_ID = 'agentsmith-runner';
const DEPLOY_MANAGED_RUNNER_IMAGE_ID = 'managed_runner';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;

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
  node scripts/verify-image-map.mjs \\
    --release-contract <json> \\
    --target-profile <target_cluster>/<substrate_source>/<distribution> \\
    --output-dir <dir> \\
    [--target-registry <registry-host[/namespace]>]`;
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
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--target-registry':
        parsed.targetRegistry = nextValue();
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
  await fs.rm(path.join(outputDir, 'image-map.json'), { force: true });
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

function assertSchemaVersion(value, expected, label) {
  const schemaVersion = requireString(value, label);
  if (schemaVersion !== expected) {
    fail(`${label} must be ${expected}`);
  }
}

function parseTargetProfile(value) {
  requireString(value, 'target_profile');
  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!IMAGE_MAP_TARGET_PROFILE_SET.has(normalized)) {
    fail(`--image-map only accepts ${IMAGE_MAP_TARGET_PROFILE_VALUES.join(' or ')}`);
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function assertContractTargetProfile(contract, targetProfile) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const seen = new Map();
  let matched = false;

  for (const [index, profileValue] of profiles.entries()) {
    const profile = requireObject(profileValue, `release_contract.target_profiles[${index}]`);
    const targetCluster = requireString(
      profile.target_cluster,
      `release_contract.target_profiles[${index}].target_cluster`
    );
    const substrateSource = requireString(
      profile.substrate_source,
      `release_contract.target_profiles[${index}].substrate_source`
    );
    const distribution = requireString(
      profile.distribution,
      `release_contract.target_profiles[${index}].distribution`
    );
    const profileTuple = `${targetCluster}/${substrateSource}/${distribution}`;
    if (!CANONICAL_DECLARABLE_TARGET_PROFILE_SET.has(profileTuple)) {
      fail(
        `release_contract.target_profiles[${index}] must be one of canonical profiles: ${CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES.join(
          ', '
        )}`
      );
    }
    if (Object.prototype.hasOwnProperty.call(profile, 'support_level')) {
      fail(
        `release_contract.target_profiles[${index}].support_level is not allowed; use release_contract.target_profiles[${index}].required`
      );
    }
    if (!Object.prototype.hasOwnProperty.call(profile, 'required')) {
      fail(`release_contract.target_profiles[${index}].required is required`);
    }
    const required = requireBoolean(
      profile.required,
      `release_contract.target_profiles[${index}].required`
    );
    if (required) {
      fail(
        `release_contract.target_profiles[${index}].required ${REQUIRED_TARGET_PROFILE_FOCUSED_DIAGNOSTIC_MESSAGE}`
      );
    }
    if (seen.has(profileTuple)) {
      fail(
        `release_contract.target_profiles[${index}] duplicates target profile tuple declared at ${seen.get(
          profileTuple
        )}`
      );
    }
    seen.set(profileTuple, `release_contract.target_profiles[${index}]`);
    if (
      targetCluster === targetProfile.target_cluster &&
      substrateSource === targetProfile.substrate_source &&
      distribution === targetProfile.distribution
    ) {
      matched = true;
    }
  }

  if (!matched) {
    fail(`release_contract.target_profiles must include ${targetProfile.value}`);
  }
}

function assertNoDuplicate(value, seen, duplicateLabel) {
  if (seen.has(value)) {
    fail(`${duplicateLabel}: ${value}`);
  }
  seen.add(value);
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

function assertReleaseContractRequiredImageIds(contract, inventory) {
  const contractDeployTemplatePackage = requireObject(
    contract.deploy_template_package,
    'release_contract.deploy_template_package'
  );
  const requiredImageIds = normalizeRequiredImageIds(
    contractDeployTemplatePackage.required_image_ids,
    'release_contract.deploy_template_package.required_image_ids'
  );
  const inventoryIds = new Set(inventory.map((item) => item.id));
  if (requiredImageIds.length !== inventoryIds.size) {
    fail('release_contract.deploy_template_package.required_image_ids must match release_contract.deploy_image_inventory ids');
  }
  for (const id of requiredImageIds) {
    if (!inventoryIds.has(id)) {
      fail('release_contract.deploy_template_package.required_image_ids must match release_contract.deploy_image_inventory ids');
    }
  }
}

function normalizeDeclaredImageItem(itemValue, source, label) {
  const item = requireObject(itemValue, label);
  const id = requireString(item.id, `${label}.id`);
  const image = requireString(item.image, `${label}.image`);
  const declaredDigest = requireDigest(item.digest, `${label}.digest`);
  const { digest, image_without_digest: imageWithoutDigest } = imageDigestSuffix(
    image,
    `${label}.image`
  );

  if (digest !== declaredDigest) {
    fail(`${label}.digest must match image digest suffix`);
  }

  return {
    id,
    source,
    source_image: image,
    source_digest: digest,
    image_without_digest: imageWithoutDigest
  };
}

function declaredInventory(contract) {
  return [
    ...IMAGE_ARRAY_SOURCES.flatMap((source) => {
      const items = requireArray(contract[source], `release_contract.${source}`);
      if (items.length === 0) {
        fail(`release_contract.${source} must not be empty`);
      }
      return items.map((item, index) =>
        normalizeDeclaredImageItem(item, source, `release_contract.${source}[${index}]`)
      );
    }),
    ...IMAGE_SINGLETON_SOURCES.map((source) =>
      normalizeDeclaredImageItem(contract[source], source, `release_contract.${source}`)
    )
  ];
}

function deployInventoryItemForDeclared(item) {
  if (item.source !== MANAGED_RUNNER_IMAGE_SOURCE) {
    return item;
  }
  if (item.id !== DECLARED_MANAGED_RUNNER_IMAGE_ID) {
    fail(`release_contract.${MANAGED_RUNNER_IMAGE_SOURCE}.id must be ${DECLARED_MANAGED_RUNNER_IMAGE_ID}`);
  }
  return {
    ...item,
    id: DEPLOY_MANAGED_RUNNER_IMAGE_ID
  };
}

function deployInventoryKey(item) {
  return `${item.source}\u0000${item.id}\u0000${item.source_image}\u0000${item.source_digest}`;
}

function buildInventory(contract) {
  const items = requireArray(
    contract.deploy_image_inventory,
    'release_contract.deploy_image_inventory'
  );
  if (items.length === 0) {
    fail('release_contract.deploy_image_inventory must not be empty');
  }

  const seenIds = new Set();
  const seenImages = new Set();
  const seenDigests = new Set();

  const normalized = items.map((itemValue, index) => {
    const label = `release_contract.deploy_image_inventory[${index}]`;
    const item = requireObject(itemValue, label);
    const id = requireString(item.id, `${label}.id`);
    const source = requireString(item.source, `${label}.source`);
    if (!IMAGE_SOURCES.includes(source)) {
      fail(`${label}.source is not a known image source`);
    }
    const sourceImage = requireString(item.image, `${label}.image`);
    const declaredDigest = requireDigest(item.digest, `${label}.digest`);
    const { digest, image_without_digest: imageWithoutDigest } = imageDigestSuffix(
      sourceImage,
      `${label}.image`
    );

    if (digest !== declaredDigest) {
      fail(`${label}.digest must match image digest suffix`);
    }

    assertNoDuplicate(
      id,
      seenIds,
      'release_contract.deploy_image_inventory contains duplicate image id'
    );
    assertNoDuplicate(
      sourceImage,
      seenImages,
      'release_contract.deploy_image_inventory contains duplicate image'
    );
    assertNoDuplicate(
      digest,
      seenDigests,
      'release_contract.deploy_image_inventory contains duplicate digest'
    );

    return {
      id,
      source,
      source_image: sourceImage,
      source_digest: digest,
      image_without_digest: imageWithoutDigest
    };
  });

  const expected = declaredInventory(contract).map(deployInventoryItemForDeclared);
  if (expected.length !== items.length) {
    fail('release_contract.deploy_image_inventory must match declared image sources');
  }
  const actualSet = new Set(normalized.map(deployInventoryKey));
  for (const expectedItem of expected) {
    if (!actualSet.has(deployInventoryKey(expectedItem))) {
      fail('release_contract.deploy_image_inventory must match declared image sources');
    }
  }

  return normalized;
}

function buildReport({
  contract,
  releaseContractInputDigest,
  targetProfile,
  targetRegistry,
  inventory
}) {
  const mirrorRequired = Boolean(targetRegistry);
  const mappings = inventory.map((item) => ({
    id: item.id,
    source: item.source,
    source_image: item.source_image,
    source_digest: item.source_digest,
    target_image: targetImageFor(item, targetRegistry),
    target_digest: item.source_digest,
    action: mirrorRequired ? 'mirror_required' : 'use_source'
  }));

  const report = {
    schema: REPORT_SCHEMA,
    scope: IMAGE_MAP_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract: {
      input_sha256: releaseContractInputDigest,
      deploy_image_inventory_count: inventory.length
    },
    target_profile: targetProfile,
    mirror_required: mirrorRequired,
    image_count: mappings.length,
    mappings
  };

  if (targetRegistry) {
    report.target_registry = targetRegistry;
  }

  return report;
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'image-map.json');
  const tempFile = path.join(outputDir, `.image-map.${process.pid}.tmp`);
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
  const targetRegistry =
    args.targetRegistry === undefined ? undefined : validateTargetRegistry(args.targetRegistry);
  if (targetProfile.distribution === 'airgap' && !targetRegistry) {
    fail('--target-registry is required for existing_kubernetes/external_declared/airgap');
  }

  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  assertSchemaVersion(
    contract.schema_version,
    RELEASE_CONTRACT_SCHEMA,
    'release_contract.schema_version'
  );
  contract.release_id = requireString(contract.release_id, 'release_contract.release_id');
  contract.git_sha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  assertContractTargetProfile(contract, targetProfile);
  const inventory = buildInventory(contract);
  assertReleaseContractRequiredImageIds(contract, inventory);

  const report = buildReport({
    contract,
    releaseContractInputDigest: releaseContractInput.inputDigest,
    targetProfile,
    targetRegistry,
    inventory
  });
  validateImageMapEvidence({
    imageMap: report,
    release: {
      ...contract,
      release_contract_digest: releaseContractInput.inputDigest
    },
    expectedTargetProfile: targetProfile,
    expectedTargetRegistry: targetRegistry,
    requireMirror: Boolean(targetRegistry),
    requireReleaseContractBinding: true
  });

  await writeReport(args.outputDir, report);

  console.log('PASS: image map accepted release contract image inventory');
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
