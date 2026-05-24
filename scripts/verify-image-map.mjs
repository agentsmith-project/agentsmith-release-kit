#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = ['releaseContract', 'targetProfile', 'outputDir'];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const REPORT_SCHEMA = 'agentsmith.image-map/v1';
const IMAGE_MAP_SCOPE = 'image_map_only';
const SUPPORTED_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap'
];
const SUPPORTED_TARGET_PROFILE_SET = new Set(SUPPORTED_TARGET_PROFILE_VALUES);
const CANONICAL_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'kind_rehearsal/kit_installed/online'
];
const CANONICAL_TARGET_PROFILE_SET = new Set(CANONICAL_TARGET_PROFILE_VALUES);
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
  if (!SUPPORTED_TARGET_PROFILE_SET.has(normalized)) {
    fail(`--image-map only accepts ${SUPPORTED_TARGET_PROFILE_VALUES.join(' or ')}`);
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
    if (!CANONICAL_TARGET_PROFILE_SET.has(profileTuple)) {
      fail(
        `release_contract.target_profiles[${index}] must be one of canonical profiles: ${CANONICAL_TARGET_PROFILE_VALUES.join(
          ', '
        )}`
      );
    }
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
  return { digest, image_without_digest: imageWithoutDigest };
}

function assertNoDuplicate(value, seen, duplicateLabel) {
  if (seen.has(value)) {
    fail(`${duplicateLabel}: ${value}`);
  }
  seen.add(value);
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

function validateTargetRegistry(input) {
  const value = requireString(input, 'target_registry');
  if (value.trim() !== value || /\s/.test(value)) {
    fail('target_registry must not contain whitespace');
  }
  if (URI_SCHEME_RE.test(value)) {
    fail('target_registry must not include a URI scheme');
  }
  if (value.includes('@')) {
    fail('target_registry must not include userinfo');
  }
  if (/[?#]/.test(value)) {
    fail('target_registry must not include query or hash text');
  }
  if (value.includes('\\') || value.startsWith('/') || value.endsWith('/') || value.includes('//')) {
    fail('target_registry must be <registry-host[/namespace]>');
  }

  const parts = value.split('/');
  const host = parseRegistryHostPort(parts[0], 'target_registry');
  const hostName = host.toLowerCase();

  if (isLocalRegistryHost(hostName)) {
    fail('target_registry must not point at localhost, loopback, or host.docker.internal');
  }
  if (!isIpv4Address(hostName) && !DNS_HOST_RE.test(hostName)) {
    fail('target_registry host must be a DNS name or IPv4 address');
  }

  for (const [index, component] of parts.slice(1).entries()) {
    if (!TARGET_NAMESPACE_COMPONENT_RE.test(component)) {
      fail(`target_registry namespace component ${index + 1} is invalid`);
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

function targetImageFor(sourceItem, targetRegistry) {
  if (!targetRegistry) {
    return sourceItem.source_image;
  }

  const repositoryPath = sourceRepositoryPath(
    sourceItem.image_without_digest,
    `image ${sourceItem.id}`
  );
  return `${targetRegistry}/${repositoryPath}@${sourceItem.source_digest}`;
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

  await writeReport(
    args.outputDir,
    buildReport({
      contract,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      targetProfile,
      targetRegistry,
      inventory
    })
  );

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
