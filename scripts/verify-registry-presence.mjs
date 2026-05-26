#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';

import { validateContractTargetProfileEntry } from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'releaseContract',
  'imageMap',
  'targetProfile',
  'registryProbe',
  'outputDir'
];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const IMAGE_MAP_SCOPE = 'image_map_only';
const REPORT_SCHEMA = 'agentsmith.registry-presence/v1';
const REPORT_SCOPE = 'registry_presence_only';
const SUPPORTED_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const PROBE_TIMEOUT_MS = 5000;
const APP_CURRENT_REQUIRED_IMAGE_IDS = [
  'agentsmith_app',
  'llmup',
  'afscp',
  'asbcp',
  'ingress_nginx_controller',
  'ingress_nginx_certgen'
];
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const DNS_HOST_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i;
const TARGET_NAMESPACE_COMPONENT_RE = /^[a-z0-9]+(?:(?:[._-]|__)[a-z0-9]+)*$/;

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

let parsedArgs;

function usage() {
  return `Usage:
  node scripts/verify-registry-presence.mjs \\
    --release-contract <json> \\
    --image-map <json> \\
    --target-profile existing_kubernetes/external_declared/online \\
    --registry-probe <executable> \\
    --output-dir <dir>

Probe interface:
  <executable> <target_image> <expected_digest>
  stdout must contain exactly one sha256 digest.`;
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
      case '--image-map':
        parsed.imageMap = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--registry-probe':
        parsed.registryProbe = nextValue();
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
  await fs.rm(path.join(outputDir, 'registry-presence-report.json'), { force: true });
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
  const text = requireString(value, label);
  if (text !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return text;
}

function assertSchemaVersion(value, expected, label) {
  assertStringEquals(value, expected, label);
}

function parseTargetProfile(value) {
  requireString(value, 'target_profile');
  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (normalized !== SUPPORTED_TARGET_PROFILE) {
    fail(`--registry-presence only accepts ${SUPPORTED_TARGET_PROFILE}`);
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function assertTargetProfileObjectMatches(value, expected, label) {
  const object = requireObject(value, label);
  const declaredValue = requireString(object.value, `${label}.value`);
  const targetCluster = requireString(object.target_cluster, `${label}.target_cluster`);
  const substrateSource = requireString(object.substrate_source, `${label}.substrate_source`);
  const distribution = requireString(object.distribution, `${label}.distribution`);
  const computedValue = `${targetCluster}/${substrateSource}/${distribution}`;

  if (declaredValue !== computedValue) {
    fail(`${label}.value must match target profile axes`);
  }
  if (computedValue !== expected.value) {
    fail(`${label} must match CLI target_profile`);
  }
}

function assertContractTargetProfile(contract, targetProfile) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const seen = new Map();
  let matched = false;

  for (const [index, value] of profiles.entries()) {
    const label = `release_contract.target_profiles[${index}]`;
    const profile = validateContractTargetProfileEntry(value, fail, label);
    if (seen.has(profile.value)) {
      fail(`${label} duplicates target profile tuple declared at ${seen.get(profile.value)}`);
    }
    seen.set(profile.value, label);
    if (profile.value === targetProfile.value) {
      matched = true;
    }
  }

  if (!matched) {
    fail(`release_contract.target_profiles must include ${targetProfile.value}`);
  }
}

function parseImageDigestRef(image, label) {
  const value = requireString(image, label);
  if (/\s/.test(value)) {
    fail(`${label} must not contain whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be an image reference, not a URI`);
  }
  if (/[?#]/.test(value)) {
    fail(`${label} must not contain query or hash text`);
  }

  const marker = '@sha256:';
  const index = value.lastIndexOf(marker);
  if (index < 0) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const imageWithoutDigest = value.slice(0, index);
  if (imageWithoutDigest === '') {
    fail(`${label} must include an image repository`);
  }
  if (imageWithoutDigest.includes('@')) {
    fail(`${label} must contain only one digest separator`);
  }
  const digest = `sha256:${value.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return { digest, imageWithoutDigest };
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

function assertAppCurrentRequiredImageIds(ids, label) {
  const expected = new Set(APP_CURRENT_REQUIRED_IMAGE_IDS);
  if (ids.length !== expected.size) {
    fail(`${label} must match current app image ids: ${APP_CURRENT_REQUIRED_IMAGE_IDS.join(', ')}`);
  }
  for (const id of ids) {
    if (!expected.has(id)) {
      fail(`${label} must match current app image ids: ${APP_CURRENT_REQUIRED_IMAGE_IDS.join(', ')}`);
    }
  }
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

  return items.map((itemValue, index) => {
    const label = `release_contract.deploy_image_inventory[${index}]`;
    const item = requireObject(itemValue, label);
    const id = requireString(item.id, `${label}.id`);
    const source = requireString(item.source, `${label}.source`);
    const image = requireString(item.image, `${label}.image`);
    const digest = requireDigest(item.digest, `${label}.digest`);
    const parsedImage = parseImageDigestRef(image, `${label}.image`);

    if (parsedImage.digest !== digest) {
      fail(`${label}.digest must match image digest suffix`);
    }

    assertNoDuplicate(id, seenIds, 'release_contract.deploy_image_inventory contains duplicate image id');
    assertNoDuplicate(image, seenImages, 'release_contract.deploy_image_inventory contains duplicate image');
    assertNoDuplicate(digest, seenDigests, 'release_contract.deploy_image_inventory contains duplicate digest');

    return {
      id,
      source,
      image,
      digest,
      image_without_digest: parsedImage.imageWithoutDigest
    };
  });
}

function assertReleaseContractRequiredImageIds(contract, inventory) {
  const requiredImageIds = normalizeRequiredImageIds(
    contract.required_image_ids,
    'release_contract.required_image_ids'
  );
  assertAppCurrentRequiredImageIds(
    requiredImageIds,
    'release_contract.required_image_ids'
  );

  const inventoryIds = new Set(inventory.map((item) => item.id));
  for (const id of requiredImageIds) {
    if (!inventoryIds.has(id)) {
      fail(`release_contract.required_image_ids contains id missing from release_contract.deploy_image_inventory: ${id}`);
    }
  }
}

function parseRegistryHostPort(hostPort, label) {
  if (hostPort.startsWith('[') || hostPort.includes(']')) {
    fail(`${label} must use a DNS host or IPv4 address, not an IPv6 literal`);
  }

  const colonParts = hostPort.split(':');
  if (colonParts.length > 2) {
    fail(`${label} must use a DNS host or IPv4 address with optional port`);
  }

  const [host, port] = colonParts;
  if (!host) {
    fail(`${label} host is required`);
  }
  if (port !== undefined) {
    if (!/^[0-9]+$/.test(port)) {
      fail(`${label} port must be numeric`);
    }
    const portNumber = Number(port);
    if (portNumber < 1 || portNumber > 65535) {
      fail(`${label} port must be between 1 and 65535`);
    }
  }

  return host;
}

function isIpv4Address(host) {
  const parts = host.split('.');
  return (
    parts.length === 4 &&
    parts.every((part) => /^[0-9]+$/.test(part) && Number(part) >= 0 && Number(part) <= 255)
  );
}

function isLocalRegistryHost(host) {
  const normalized = host.toLowerCase();
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::1' ||
    normalized === '0.0.0.0' ||
    /^127\./.test(normalized)
  );
}

function validateTargetRegistry(input, label = 'image_map.target_registry') {
  const value = requireString(input, label);
  if (value.trim() !== value || /\s/.test(value)) {
    fail(`${label} must not contain whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must not include a URI scheme`);
  }
  if (value.includes('@')) {
    fail(`${label} must not include userinfo`);
  }
  if (/[?#]/.test(value)) {
    fail(`${label} must not include query or hash text`);
  }
  if (value.includes('\\') || value.startsWith('/') || value.endsWith('/') || value.includes('//')) {
    fail(`${label} must be <registry-host[/namespace]>`);
  }

  const parts = value.split('/');
  const host = parseRegistryHostPort(parts[0], label);
  const hostName = host.toLowerCase();
  if (isLocalRegistryHost(hostName)) {
    fail(`${label} must not point at localhost, loopback, or host.docker.internal`);
  }
  if (!isIpv4Address(hostName) && !DNS_HOST_RE.test(hostName)) {
    fail(`${label} host must be a DNS name or IPv4 address`);
  }

  for (const [index, component] of parts.slice(1).entries()) {
    if (!TARGET_NAMESPACE_COMPONENT_RE.test(component)) {
      fail(`${label} namespace component ${index + 1} is invalid`);
    }
  }

  return value;
}

function stripTag(imageWithoutDigest) {
  const lastSlash = imageWithoutDigest.lastIndexOf('/');
  const lastColon = imageWithoutDigest.lastIndexOf(':');
  if (lastColon > lastSlash) {
    return imageWithoutDigest.slice(0, lastColon);
  }
  return imageWithoutDigest;
}

function firstPathComponentLooksLikeRegistry(component) {
  return (
    component.includes('.') ||
    component.includes(':') ||
    component === 'localhost' ||
    component === 'host.docker.internal'
  );
}

function sourceRepositoryPath(imageWithoutDigest, label) {
  const withoutTag = stripTag(imageWithoutDigest);
  const parts = withoutTag.split('/');
  if (parts.some((part) => part === '')) {
    fail(`${label} must not contain empty repository path components`);
  }
  if (parts.length > 1 && firstPathComponentLooksLikeRegistry(parts[0])) {
    return parts.slice(1).join('/');
  }
  return withoutTag;
}

function targetImageFor(inventoryItem, targetRegistry) {
  const repositoryPath = sourceRepositoryPath(
    inventoryItem.image_without_digest,
    `image ${inventoryItem.id}`
  );
  return `${targetRegistry}/${repositoryPath}@${inventoryItem.digest}`;
}

function assertImageMap({
  imageMap,
  imageMapInputDigest,
  contract,
  releaseContractInputDigest,
  inventory,
  targetProfile
}) {
  assertStringEquals(imageMap.schema, IMAGE_MAP_SCHEMA, 'image_map.schema');
  assertStringEquals(imageMap.scope, IMAGE_MAP_SCOPE, 'image_map.scope');
  requireBooleanFalse(imageMap.readiness, 'image_map.readiness');
  assertStringEquals(imageMap.status, 'pass', 'image_map.status');
  assertStringEquals(imageMap.release_id, contract.release_id, 'image_map.release_id');
  assertStringEquals(imageMap.git_sha, contract.git_sha, 'image_map.git_sha');
  assertTargetProfileObjectMatches(imageMap.target_profile, targetProfile, 'image_map.target_profile');

  const releaseContract = requireObject(imageMap.release_contract, 'image_map.release_contract');
  const imageMapReleaseContractDigest = requireDigest(
    releaseContract.input_sha256,
    'image_map.release_contract.input_sha256'
  );
  if (imageMapReleaseContractDigest !== releaseContractInputDigest) {
    fail('image_map.release_contract.input_sha256 must match release contract input sha256');
  }
  const inventoryCount = requireInteger(
    releaseContract.deploy_image_inventory_count,
    'image_map.release_contract.deploy_image_inventory_count'
  );
  if (inventoryCount !== inventory.length) {
    fail('image_map.release_contract.deploy_image_inventory_count must match release_contract.deploy_image_inventory length');
  }

  if (imageMap.mirror_required !== true) {
    fail('image_map.mirror_required must be true');
  }
  const targetRegistry = validateTargetRegistry(
    imageMap.target_registry,
    'image_map.target_registry'
  );

  const mappings = requireArray(imageMap.mappings, 'image_map.mappings');
  const imageCount = requireInteger(imageMap.image_count, 'image_map.image_count');
  if (imageCount !== mappings.length) {
    fail('image_map.image_count must match image_map.mappings length');
  }
  if (mappings.length !== inventory.length) {
    fail('image_map.mappings must match release_contract.deploy_image_inventory length');
  }

  const inventoryById = new Map(inventory.map((item) => [item.id, item]));
  const seenMappingIds = new Set();
  const normalizedMappings = [];

  for (const [index, value] of mappings.entries()) {
    const label = `image_map.mappings[${index}]`;
    const mapping = requireObject(value, label);
    const id = requireString(mapping.id, `${label}.id`);
    if (seenMappingIds.has(id)) {
      fail(`image_map.mappings contains duplicate id: ${id}`);
    }
    seenMappingIds.add(id);

    const inventoryItem = inventoryById.get(id);
    if (!inventoryItem) {
      fail(`${label}.id must exist in release_contract.deploy_image_inventory`);
    }

    assertStringEquals(mapping.source, inventoryItem.source, `${label}.source`);
    assertStringEquals(mapping.source_image, inventoryItem.image, `${label}.source_image`);
    const sourceDigest = requireDigest(mapping.source_digest, `${label}.source_digest`);
    if (sourceDigest !== inventoryItem.digest) {
      fail(`${label}.source_digest must match release_contract.deploy_image_inventory`);
    }
    const sourceImageDigest = parseImageDigestRef(mapping.source_image, `${label}.source_image`).digest;
    if (sourceImageDigest !== sourceDigest) {
      fail(`${label}.source_image must be digest-pinned with source_digest`);
    }

    const targetImage = requireString(mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${label}.target_digest`);
    if (targetDigest !== sourceDigest) {
      fail(`${label}.target_digest must match source_digest`);
    }
    const targetImageDigest = parseImageDigestRef(targetImage, `${label}.target_image`).digest;
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
    const expectedTargetImage = targetImageFor(inventoryItem, targetRegistry);
    if (targetImage !== expectedTargetImage) {
      fail(`${label}.target_image must match deterministic image_map.target_registry mirror ref`);
    }
    assertStringEquals(mapping.action, 'mirror_required', `${label}.action`);

    normalizedMappings.push({
      id,
      target_image: targetImage,
      target_digest: targetDigest
    });
  }

  for (const item of inventory) {
    if (!seenMappingIds.has(item.id)) {
      fail(`image_map.mappings is missing release_contract.deploy_image_inventory id: ${item.id}`);
    }
  }

  return {
    inputDigest: imageMapInputDigest,
    targetRegistry,
    imageCount,
    mappings: normalizedMappings
  };
}

async function assertProbeExecutable(probe) {
  requireString(probe, 'registry_probe');
  let stat;
  try {
    stat = await fs.stat(probe);
    await fs.access(probe, fsConstants.X_OK);
  } catch {
    fail('registry_probe must be an executable file');
  }
  if (!stat.isFile()) {
    fail('registry_probe must be an executable file');
  }
}

function runRegistryProbe(probe, mapping) {
  const result = spawnSync(probe, [mapping.target_image, mapping.target_digest], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024,
    timeout: PROBE_TIMEOUT_MS
  });

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      fail(`registry probe timed out for image id ${mapping.id}`);
    }
    fail(`registry probe could not be executed for image id ${mapping.id}`);
  }
  if (result.signal) {
    fail(`registry probe was interrupted for image id ${mapping.id}`);
  }
  if (result.status !== 0) {
    fail(`registry probe returned non-zero status for image id ${mapping.id}`);
  }

  const stdout = typeof result.stdout === 'string' ? result.stdout : '';
  if (!/^\s*sha256:[0-9a-f]{64}\s*$/.test(stdout)) {
    fail(`registry probe stdout for image id ${mapping.id} must be exactly one sha256 digest`);
  }

  const probeDigest = stdout.trim();
  if (probeDigest !== mapping.target_digest) {
    fail(`registry probe digest mismatch for image id ${mapping.id}`);
  }

  return {
    id: mapping.id,
    target_digest: mapping.target_digest,
    probe_digest: probeDigest
  };
}

function buildReport({
  contract,
  releaseContractInputDigest,
  imageMapSummary,
  targetProfile,
  probeResults
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile,
    target_registry: imageMapSummary.targetRegistry,
    release_contract: {
      input_sha256: releaseContractInputDigest,
      deploy_image_inventory_count: imageMapSummary.imageCount
    },
    image_map: {
      input_sha256: imageMapSummary.inputDigest,
      image_count: imageMapSummary.imageCount,
      mirror_required: true
    },
    image_count: probeResults.length,
    present_digest_summary: {
      matched_count: probeResults.length,
      unique_digest_count: new Set(probeResults.map((result) => result.probe_digest)).size
    },
    mappings: probeResults
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'registry-presence-report.json');
  const tempFile = path.join(outputDir, `.registry-presence-report.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  parsedArgs = parseArgs(process.argv.slice(2));
  if (parsedArgs.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(parsedArgs.outputDir);
  const targetProfile = parseTargetProfile(parsedArgs.targetProfile);
  await assertProbeExecutable(parsedArgs.registryProbe);

  const releaseContractInput = await readJson(parsedArgs.releaseContract, 'release contract');
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

  const imageMapInput = await readJson(parsedArgs.imageMap, 'image map');
  const imageMapSummary = assertImageMap({
    imageMap: requireObject(imageMapInput.value, 'image_map'),
    imageMapInputDigest: imageMapInput.inputDigest,
    contract,
    releaseContractInputDigest: releaseContractInput.inputDigest,
    inventory,
    targetProfile
  });

  const probeResults = imageMapSummary.mappings.map((mapping) =>
    runRegistryProbe(parsedArgs.registryProbe, mapping)
  );

  await writeReport(
    parsedArgs.outputDir,
    buildReport({
      contract,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      imageMapSummary,
      targetProfile,
      probeResults
    })
  );

  console.log('PASS: registry presence accepted image-map target digest refs');
}

main().catch(async (error) => {
  if (parsedArgs?.outputDir) {
    await removeStaleReport(parsedArgs.outputDir).catch(() => {});
  }
  const exitCode = error.exitCode || 1;
  const prefix = exitCode === 2 ? 'error' : 'FAIL';
  console.error(`${prefix}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
