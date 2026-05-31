export const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
export const IMAGE_MAP_SCOPE = 'image_map_only';

const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const DNS_HOST_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i;
const TARGET_NAMESPACE_COMPONENT_RE = /^[a-z0-9]+(?:(?:[._-]|__)[a-z0-9]+)*$/;

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

function requireNonEmptyArray(value, label) {
  const array = requireArray(value, label);
  if (array.length === 0) {
    fail(`${label} must not be empty`);
  }
  return array;
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

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function requireSchema(report, schema, label) {
  if (report.schema !== schema && report.schema_version !== schema) {
    fail(`${label}.schema must be ${schema}`);
  }
}

function requireScope(report, expectedScope, label) {
  if (requireString(report.scope, `${label}.scope`) !== expectedScope) {
    fail(`${label}.scope must be ${expectedScope}`);
  }
}

function requireReadinessFalse(report, label) {
  if (report.readiness !== false) {
    fail(`${label}.readiness must be false`);
  }
}

function requireStatusPass(report, label) {
  if (report.status !== 'pass') {
    fail(`${label}.status must be pass`);
  }
}

function requireStringEquals(value, expected, label) {
  const actual = requireString(value, label);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function targetProfileObject(expectedTargetProfile, label) {
  if (typeof expectedTargetProfile === 'string') {
    return parseTargetProfile(expectedTargetProfile, label);
  }
  const object = requireObject(expectedTargetProfile, label);
  return parseTargetProfile(requireString(object.value, `${label}.value`), `${label}.value`);
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

function requireTargetProfile(value, expectedTargetProfile, label) {
  const expected = targetProfileObject(expectedTargetProfile, 'expected target_profile');
  const profile = requireObject(value, label);
  const parsed = parseTargetProfile(profile.value, `${label}.value`);
  if (parsed.value !== expected.value) {
    fail(`${label}.value must be ${expected.value}`);
  }
  for (const key of ['target_cluster', 'substrate_source', 'distribution']) {
    if (profile[key] !== parsed[key]) {
      fail(`${label}.${key} must match ${label}.value`);
    }
  }
  return parsed;
}

function requireCommonReleaseFields(report, release, label) {
  if (release?.release_id !== undefined) {
    requireStringEquals(report.release_id, release.release_id, `${label}.release_id`);
  }
  if (release?.git_sha !== undefined) {
    requireStringEquals(report.git_sha, release.git_sha, `${label}.git_sha`);
  }
}

export function imageDigestSuffix(image, label) {
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
  return {
    digest,
    image_without_digest: imageWithoutDigest,
    imageWithoutDigest
  };
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

export function validateTargetRegistry(input, label = 'target_registry') {
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

export function targetImageFor(sourceItem, targetRegistry) {
  if (!targetRegistry) {
    return sourceItem.source_image ?? sourceItem.image;
  }

  const sourceImage = sourceItem.source_image ?? sourceItem.image;
  const sourceDigest = sourceItem.source_digest ?? sourceItem.digest;
  const imageWithoutDigest =
    sourceItem.image_without_digest ??
    sourceItem.imageWithoutDigest ??
    imageDigestSuffix(sourceImage, `image ${sourceItem.id}`).image_without_digest;
  const repositoryPath = sourceRepositoryPath(
    imageWithoutDigest,
    `image ${sourceItem.id}`
  );
  return `${targetRegistry}/${repositoryPath}@${sourceDigest}`;
}

function releaseDeployImageInventory(release) {
  const inventory = release?.deploy_image_inventory ?? release?.images?.inventory;
  const entries = requireNonEmptyArray(inventory, 'release contract deploy_image_inventory');
  const byId = new Map();
  for (const [index, value] of entries.entries()) {
    const label = `release contract deploy_image_inventory[${index}]`;
    const image = requireObject(value, label);
    const id = requireString(image.id, `${label}.id`);
    if (byId.has(id)) {
      fail(`release contract deploy_image_inventory contains duplicate image id: ${id}`);
    }
    const sourceImage = requireString(
      image.image ?? image.source_image,
      `${label}.image`
    );
    const sourceDigest = requireDigest(
      image.digest ?? image.source_digest,
      `${label}.digest`
    );
    const { digest, image_without_digest: imageWithoutDigest } = imageDigestSuffix(
      sourceImage,
      `${label}.image`
    );
    if (digest !== sourceDigest) {
      fail(`${label}.digest must match image digest suffix`);
    }
    const source = image.source === undefined ? undefined : requireString(image.source, `${label}.source`);
    byId.set(id, {
      id,
      source,
      image: sourceImage,
      digest: sourceDigest,
      image_without_digest: imageWithoutDigest
    });
  }
  return { byId };
}

function validateReleaseContractBinding({
  imageMap,
  release,
  imageInventory,
  label,
  requireReleaseContractBinding
}) {
  if (!requireReleaseContractBinding && imageMap.release_contract === undefined) {
    return;
  }
  const releaseContract = requireObject(imageMap.release_contract, `${label}.release_contract`);
  const releaseContractDigest = release?.release_contract_digest;
  if (releaseContractDigest !== undefined) {
    const imageMapReleaseContractDigest = requireDigest(
      releaseContract.input_sha256,
      `${label}.release_contract.input_sha256`
    );
    if (imageMapReleaseContractDigest !== releaseContractDigest) {
      fail(`${label}.release_contract.input_sha256 must match release contract input sha256`);
    }
  }
  const inventoryCount = requireInteger(
    releaseContract.deploy_image_inventory_count,
    `${label}.release_contract.deploy_image_inventory_count`
  );
  if (inventoryCount !== imageInventory.byId.size) {
    fail(`${label}.release_contract.deploy_image_inventory_count must match release_contract.deploy_image_inventory length`);
  }
}

function validateMirrorMode({ imageMap, expectedTargetRegistry, expectedTargetProfile, label, requireMirror }) {
  const mirrorRequired = imageMap.mirror_required;
  if (typeof mirrorRequired !== 'boolean') {
    fail(`${label}.mirror_required must be a boolean`);
  }

  const profile = requireTargetProfile(
    imageMap.target_profile,
    expectedTargetProfile,
    `${label}.target_profile`
  );
  if (profile.distribution === 'airgap' && mirrorRequired !== true) {
    fail(`${label}.mirror_required must be true for airgap target_profile`);
  }
  if (requireMirror === true && mirrorRequired !== true) {
    fail(`${label}.mirror_required must be true`);
  }
  if (requireMirror === false && mirrorRequired !== false) {
    fail(`${label}.mirror_required must be false`);
  }

  if (!mirrorRequired) {
    if (Object.prototype.hasOwnProperty.call(imageMap, 'target_registry')) {
      fail(`${label}.target_registry must be omitted when mirror_required is false`);
    }
    return { mirrorRequired, targetRegistry: undefined };
  }

  const targetRegistry = validateTargetRegistry(imageMap.target_registry, `${label}.target_registry`);
  if (expectedTargetRegistry !== undefined && targetRegistry !== expectedTargetRegistry) {
    fail(`${label}.target_registry must match expected target registry`);
  }
  return { mirrorRequired, targetRegistry };
}

export function validateImageMapEvidence({
  imageMap,
  release,
  expectedTargetProfile,
  expectedTargetRegistry,
  label = 'image_map',
  requireMirror,
  requireReleaseContractBinding = false
}) {
  const report = requireObject(imageMap, label);
  requireSchema(report, IMAGE_MAP_SCHEMA, label);
  requireScope(report, IMAGE_MAP_SCOPE, label);
  requireReadinessFalse(report, label);
  requireStatusPass(report, label);
  requireCommonReleaseFields(report, release, label);

  const imageInventory = releaseDeployImageInventory(release);
  const { mirrorRequired, targetRegistry } = validateMirrorMode({
    imageMap: report,
    expectedTargetProfile,
    expectedTargetRegistry,
    label,
    requireMirror
  });
  validateReleaseContractBinding({
    imageMap: report,
    release,
    imageInventory,
    label,
    requireReleaseContractBinding
  });

  const mappings = requireNonEmptyArray(report.mappings, `${label}.mappings`);
  if (mappings.length !== imageInventory.byId.size) {
    fail(`${label}.mappings must match release_contract.deploy_image_inventory length`);
  }
  if (requireInteger(report.image_count, `${label}.image_count`) !== mappings.length) {
    fail(`${label}.image_count must match ${label}.mappings length`);
  }

  const byId = new Map();
  const targetDigests = new Set();
  for (const [index, value] of mappings.entries()) {
    const mappingLabel = `${label}.mappings[${index}]`;
    const mapping = requireObject(value, mappingLabel);
    const id = requireString(mapping.id, `${mappingLabel}.id`);
    if (byId.has(id)) {
      fail(`${label}.mappings contains duplicate id: ${id}`);
    }

    const inventoryItem = imageInventory.byId.get(id);
    if (!inventoryItem) {
      fail(`${mappingLabel}.id must exist in release_contract.deploy_image_inventory`);
    }
    if (inventoryItem.source !== undefined) {
      requireStringEquals(mapping.source, inventoryItem.source, `${mappingLabel}.source`);
    } else if (mapping.source !== undefined) {
      requireString(mapping.source, `${mappingLabel}.source`);
    }

    const sourceImage = requireString(mapping.source_image, `${mappingLabel}.source_image`);
    if (sourceImage !== inventoryItem.image) {
      fail(`${mappingLabel}.source_image must match release_contract.deploy_image_inventory`);
    }
    const sourceDigest = requireDigest(mapping.source_digest, `${mappingLabel}.source_digest`);
    if (sourceDigest !== inventoryItem.digest) {
      fail(`${mappingLabel}.source_digest must match release_contract.deploy_image_inventory`);
    }
    const { digest: sourceImageDigest } = imageDigestSuffix(sourceImage, `${mappingLabel}.source_image`);
    if (sourceImageDigest !== sourceDigest) {
      fail(`${mappingLabel}.source_image must be digest-pinned with source_digest`);
    }

    const targetImage = requireString(mapping.target_image, `${mappingLabel}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${mappingLabel}.target_digest`);
    if (targetDigest !== sourceDigest) {
      fail(`${mappingLabel}.target_digest must match source_digest`);
    }

    const expectedTargetImage = targetImageFor(
      {
        id,
        image: inventoryItem.image,
        digest: inventoryItem.digest,
        image_without_digest: inventoryItem.image_without_digest
      },
      targetRegistry
    );
    if (targetImage !== expectedTargetImage) {
      fail(`${mappingLabel}.target_image must match deterministic image_map target ref`);
    }
    const { digest: targetImageDigest } = imageDigestSuffix(targetImage, `${mappingLabel}.target_image`);
    if (targetImageDigest !== targetDigest) {
      fail(`${mappingLabel}.target_image must be digest-pinned with target_digest`);
    }

    requireStringEquals(
      mapping.action,
      mirrorRequired ? 'mirror_required' : 'use_source',
      `${mappingLabel}.action`
    );

    byId.set(id, {
      id,
      source_image: sourceImage,
      source_digest: sourceDigest,
      target_image: targetImage,
      target_digest: targetDigest
    });
    targetDigests.add(targetDigest);
  }

  for (const id of imageInventory.byId.keys()) {
    if (!byId.has(id)) {
      fail(`${label}.mappings is missing release_contract.deploy_image_inventory id: ${id}`);
    }
  }

  return {
    imageCount: mappings.length,
    mappingsById: byId,
    targetRegistry,
    uniqueTargetDigestCount: targetDigests.size
  };
}
