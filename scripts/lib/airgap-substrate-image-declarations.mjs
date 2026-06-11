const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const SAFE_SEGMENT_RE = /^[A-Za-z0-9_.-]+$/;

function defaultFail(message) {
  throw new Error(message);
}

function requireObject(value, label, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireString(value, label, fail) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function imageDigestSuffix(value, label, fail) {
  const marker = '@sha256:';
  const index = value.lastIndexOf(marker);
  if (index < 1) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const digest = `sha256:${value.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return digest;
}

export function substrateImageId(key, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'substrate image key';
  const safeKey = requireString(key, label, fail);
  if (!SAFE_SEGMENT_RE.test(safeKey)) {
    fail(`${label} must be a safe segment`);
  }
  return `substrate_${safeKey}`;
}

export function substrateImageDeclarationsFromPackManifest(value, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'substrate_pack_manifest';
  const manifest = requireObject(value, label, fail);
  const images = requireObject(manifest.images, `${label}.images`, fail);

  return Object.entries(images)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, imageValue]) => {
      const imageLabel = `${label}.images.${key}`;
      const image = requireString(imageValue, imageLabel, fail);
      const digest = imageDigestSuffix(image, imageLabel, fail);
      return {
        id: substrateImageId(key, { fail, label: `${imageLabel} key` }),
        source_image: image,
        source_digest: digest,
        target_image: image,
        target_digest: digest
      };
    });
}

export function expectedImageDeclarationsById({
  imageMapDeclarations,
  substrateImageDeclarations = [],
  fail = defaultFail
}) {
  const expectedById = new Map();
  for (const declaration of imageMapDeclarations) {
    expectedById.set(declaration.id, declaration);
  }
  for (const declaration of substrateImageDeclarations) {
    if (expectedById.has(declaration.id)) {
      fail(`substrate image id collides with image_map mapping id: ${declaration.id}`);
    }
    expectedById.set(declaration.id, declaration);
  }
  return expectedById;
}

export function expectedImageDeclarationSourceLabel(substrateImageDeclarations = []) {
  return substrateImageDeclarations.length > 0
    ? 'image_map.mappings and substrate_pack_manifest.images'
    : 'image_map.mappings';
}
