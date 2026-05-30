import { requirePlainSemver } from './release-kit-version-policy.mjs';

export const SUBSTRATE_PACK_MANIFEST_SCHEMA = 'agentsmith.substrate-pack-manifest/v1';
export const SUBSTRATE_PACK_INSTALLED_BY = 'agentsmith-release-kit';

const REQUIRED_SUBSTRATE_IMAGES = [
  'postgresql',
  'mongodb',
  'redis',
  'object_storage',
  'oidc'
];
const MATERIAL_SECTIONS = ['payload', 'templates', 'tools', 'checksums'];
const MANIFEST_FIELDS = new Set([
  'schema_version',
  'release_kit_version',
  'installed_by',
  'target_profile',
  'images',
  ...MATERIAL_SECTIONS
]);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCAL_SCHEME_RE = /^(?:file|local|source|git\+file):/i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|0\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[?(?:::|::1)\]?|host\.docker\.internal)(?::\d+)?(?:[/?#]|$)/i;
const HOST_DOCKER_INTERNAL_RE = /(^|[^A-Za-z0-9.-])host\.docker\.internal(?=$|[^A-Za-z0-9.-])/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const AGENTSMITH_SOURCE_PATH_RE = /\/home\/[^/]+\/works\/[^/]+\/agentsmith(?:\/|$)/i;
const SECRET_KEY_RE = /(^|[_-])(password|passwd|pwd|token|secret|client_secret|private_key|kubeconfig|access_key|api_key|credential)([_-]|$)/i;
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
const DOWNLOAD_SEMANTICS_RE = /\b(?:public[\s_-]+download|public[\s_-]+url|https?[\s_-]+url|curl|wget|docker[\s_-]+pull|oras[\s_-]+pull|skopeo[\s_-]+copy)\b/i;

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

function defaultFail(message) {
  throw new ValidationError(message);
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

function assertStringEquals(value, expected, label, fail) {
  const actual = requireString(value, label, fail);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function assertAllowedKeys(object, allowedKeys, label, fail) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function targetProfileValue(targetProfile, fail) {
  if (typeof targetProfile === 'string') {
    return requireString(targetProfile, 'target_profile', fail);
  }
  const profile = requireObject(targetProfile, 'target_profile', fail);
  return requireString(profile.value, 'target_profile.value', fail);
}

function assertSafeRelativePackPath(value, label, fail) {
  const text = requireString(value, label, fail);
  if (
    text !== text.trim() ||
    text.startsWith('/') ||
    /^[A-Za-z]:[\\/]/.test(text) ||
    text.includes('\\') ||
    text.includes('//') ||
    text.split('/').some((part) => part === '' || part === '.' || part === '..') ||
    URI_SCHEME_RE.test(text) ||
    LOCAL_SCHEME_RE.test(text) ||
    !SAFE_RELATIVE_PATH_RE.test(text)
  ) {
    fail(`${label} must be a sha256 digest or safe relative substrate pack path`);
  }
  return text;
}

function assertMaterialString(value, label, fail) {
  const text = requireString(value, label, fail);
  if (DIGEST_RE.test(text)) {
    return { kind: 'digest' };
  }
  assertSafeRelativePackPath(text, label, fail);
  return { kind: 'path' };
}

function scanUnsafeManifestString(value, label, issues) {
  if (
    LOCAL_SCHEME_RE.test(value) ||
    LOCAL_URI_RE.test(value) ||
    LOCALHOST_URI_RE.test(value) ||
    HOST_DOCKER_INTERNAL_RE.test(value) ||
    URI_SCHEME_RE.test(value) ||
    ABSOLUTE_LOCAL_PATH_RE.test(value) ||
    RELATIVE_URI_RE.test(value) ||
    AGENTSMITH_SOURCE_PATH_RE.test(value)
  ) {
    issues.push(`${label} contains an unsafe URI or local/source path`);
  }
  if (DOWNLOAD_SEMANTICS_RE.test(value)) {
    issues.push(`${label} must not describe public download semantics`);
  }
  if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
    issues.push(`${label} contains a secret-looking value`);
  }
}

function scanManifestPayload(value, label, issues = []) {
  if (typeof value === 'string') {
    scanUnsafeManifestString(value, label, issues);
    return issues;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      scanManifestPayload(item, `${label}[${index}]`, issues);
    });
    return issues;
  }
  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      const nestedLabel = `${label}.${key}`;
      scanUnsafeManifestString(key, `${nestedLabel} key`, issues);
      if (SECRET_KEY_RE.test(key)) {
        issues.push(`${nestedLabel} is not allowed in substrate pack manifest`);
      }
      scanManifestPayload(nested, nestedLabel, issues);
    }
  }
  return issues;
}

function isLoopbackRegistryComponent(value) {
  const bracketedIpv6 = value.toLowerCase().match(/^\[([^\]]+)\](?::[^/]+)?$/);
  if (!bracketedIpv6) {
    return false;
  }
  try {
    const registryHost = new URL(`http://[${bracketedIpv6[1]}]/`).hostname
      .replace(/^\[|\]$/g, '')
      .toLowerCase();
    return registryHost === '::' || registryHost === '::1';
  } catch {
    return false;
  }
}

function assertNoUnsafeManifestPayload(value, label, fail) {
  const issues = scanManifestPayload(value, label);
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function validateMaterialSection(value, label, fail) {
  if (typeof value === 'string') {
    assertMaterialString(value, label, fail);
    return 1;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      fail(`${label} must not be empty`);
    }
    return value.reduce(
      (count, item, index) => count + validateMaterialSection(item, `${label}[${index}]`, fail),
      0
    );
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(value);
    if (entries.length === 0) {
      fail(`${label} must not be empty`);
    }
    return entries.reduce(
      (count, [key, nested]) => count + validateMaterialSection(nested, `${label}.${key}`, fail),
      0
    );
  }
  fail(`${label} must contain sha256 digests or safe relative substrate pack paths`);
}

function imageDigestSuffix(image, label, fail) {
  const value = requireString(image, label, fail);
  if (/\s/.test(value)) {
    fail(`${label} must not contain whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be an image reference, not a URI`);
  }
  if (/[?#]/.test(value)) {
    fail(`${label} must not contain query or hash text`);
  }
  if (
    value.startsWith('/') ||
    value.startsWith('~/') ||
    /^[A-Za-z]:[\\/]/.test(value) ||
    value.includes('\\') ||
    value.includes('../') ||
    value.includes('/../') ||
    value.includes('/./') ||
    value.startsWith('./')
  ) {
    fail(`${label} must not be a local or source path`);
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
  if (/(^|:)latest$/i.test(imageWithoutDigest)) {
    fail(`${label} must not use latest`);
  }
  const firstComponent = imageWithoutDigest.split('/')[0].toLowerCase();
  if (
    firstComponent === 'localhost' ||
    firstComponent.startsWith('localhost:') ||
    firstComponent === 'host.docker.internal' ||
    firstComponent === 'source' ||
    firstComponent === 'local' ||
    /^127\./.test(firstComponent) ||
    /^0\./.test(firstComponent) ||
    isLoopbackRegistryComponent(firstComponent)
  ) {
    fail(`${label} must not use a local, localhost, or source image path`);
  }
  if (imageWithoutDigest.split('/').some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must not contain empty or relative repository path components`);
  }

  const digest = `sha256:${value.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return digest;
}

function validateImages(value, label, fail) {
  const images = requireObject(value, `${label}.images`, fail);
  for (const required of REQUIRED_SUBSTRATE_IMAGES) {
    if (!Object.prototype.hasOwnProperty.call(images, required)) {
      fail(`${label}.images missing required image: ${required}`);
    }
  }
  const imageIds = Object.keys(images);
  if (imageIds.length === 0) {
    fail(`${label}.images must not be empty`);
  }
  const seenRefs = new Set();
  const seenDigests = new Set();
  for (const [id, image] of Object.entries(images)) {
    const imageLabel = `${label}.images.${id}`;
    const ref = requireString(image, imageLabel, fail);
    const digest = imageDigestSuffix(ref, imageLabel, fail);
    if (seenRefs.has(ref)) {
      fail(`${label}.images contains duplicate image: ${id}`);
    }
    if (seenDigests.has(digest)) {
      fail(`${label}.images contains duplicate digest: ${id}`);
    }
    seenRefs.add(ref);
    seenDigests.add(digest);
  }
  return {
    image_count: imageIds.length,
    required_images: [...REQUIRED_SUBSTRATE_IMAGES]
  };
}

export function validateSubstratePackManifest(value, targetProfile, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'substrate_pack_manifest';
  const expectedTargetProfile = targetProfileValue(targetProfile, fail);

  assertNoUnsafeManifestPayload(value, label, fail);
  const manifest = requireObject(value, label, fail);
  assertAllowedKeys(manifest, MANIFEST_FIELDS, label, fail);
  assertStringEquals(
    manifest.schema_version,
    SUBSTRATE_PACK_MANIFEST_SCHEMA,
    `${label}.schema_version`,
    fail
  );
  requirePlainSemver(manifest.release_kit_version, `${label}.release_kit_version`, fail);
  assertStringEquals(
    manifest.installed_by,
    SUBSTRATE_PACK_INSTALLED_BY,
    `${label}.installed_by`,
    fail
  );
  assertStringEquals(manifest.target_profile, expectedTargetProfile, `${label}.target_profile`, fail);

  const imageSummary = validateImages(manifest.images, label, fail);
  const materialSections = {};
  for (const section of MATERIAL_SECTIONS) {
    materialSections[section] = {
      entries_count: validateMaterialSection(manifest[section], `${label}.${section}`, fail)
    };
  }

  return {
    manifest,
    manifestSummary: {
      schema_version: SUBSTRATE_PACK_MANIFEST_SCHEMA,
      installed_by: SUBSTRATE_PACK_INSTALLED_BY,
      release_kit_version: manifest.release_kit_version,
      ...imageSummary,
      material_sections: materialSections
    }
  };
}
