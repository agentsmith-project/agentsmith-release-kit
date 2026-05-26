#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

import {
  assertNoUnsafeSubstratePayload,
  validateSubstrateConnectionTruth
} from './lib/substrate-truth-validation.mjs';
import {
  parseCanonicalTargetProfile,
  validateContractTargetProfileEntry
} from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'targetProfile',
  'renderValues',
  'substrateTruth',
  'outputDir'
];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_PACKAGE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const DEPLOY_TEMPLATE_MANIFEST_SCHEMA = 'agentsmith.deploy-template-manifest/v1';
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const IMAGE_MAP_SCOPE = 'image_map_only';
const REPORT_SCHEMA = 'agentsmith.manifest-render-report/v1';
const IMAGE_ARRAY_SOURCES = [
  'product_images',
  'adopted_provider_images',
  'release_kit_prerequisite_images'
];
const IMAGE_SINGLETON_SOURCES = ['managed_runner_image'];
const IMAGE_SOURCES = [...IMAGE_ARRAY_SOURCES, ...IMAGE_SINGLETON_SOURCES];
const WORKLOAD_KINDS = new Set([
  'Deployment',
  'StatefulSet',
  'DaemonSet',
  'ReplicaSet',
  'Job',
  'CronJob',
  'Pod'
]);
const MANIFEST_EXTENSIONS = new Set(['.json', '.yaml', '.yml']);
const IMAGE_MAP_ACTIONS = new Set(['use_source', 'mirror_required']);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const TEMPLATE_EXPR_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_-]+)*$/;
const TEMPLATE_PLACEHOLDER_RE = /\$\{\{([\s\S]*?)\}\}/g;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const DNS_HOST_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i;
const TARGET_NAMESPACE_COMPONENT_RE = /^[a-z0-9]+(?:(?:[._-]|__)[a-z0-9]+)*$/;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|\[?::1\]?|host\.docker\.internal)(?::\d+)?(?:[/?#]|$)/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const SOURCE_LIKE_LABEL_RE = /(?:^|\.)(?:source_uri|source_path|artifact_uri|package_uri|local_path|path|file|dir|kubeconfig)$/;
const WORKSPACE_SOURCE_RE = /\/home\/[^/]+\/works\/[^/]+\/agentsmith(?:\/|$)/i;
const SECRET_REF_PREFIX = 'secretRef:';
const SECRET_KEY_RE = /(^|[_-])(password|passwd|pwd|token|secret|client_secret|private_key|kubeconfig|access_key|api_key)([_-]|$)/i;
const YAML_IMAGE_KEY_RE = /(?:^|[{,\s\[])\s*(?:-\s*)?image\s*:\s*(?:"([^"]+)"|'([^']+)'|([^,\]}\s#]+))/g;
const SECRET_KEY_VALUE_RE = /(?:^|[{,\s\[])[ \t]*["']?([A-Za-z0-9_.-]+)["']?[ \t]*[:=][ \t]*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^,}\]\r\n#]*))/g;
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
  /\bkubeconfig\b/i
];
const SAFE_REDACTED_SECRET_RE = /^(redacted|\*+)$/i;
const SAFE_SECRET_REF_VALUE_RE = /^[A-Za-z0-9_.-]*secret_ref$/;
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_FORBIDDEN_SOURCE_ROOTS = [path.resolve(REPO_ROOT, '..', 'agentsmith')];
const IMAGE_MAP_FIELDS = new Set([
  'schema',
  'scope',
  'readiness',
  'status',
  'release_id',
  'git_sha',
  'release_contract',
  'target_profile',
  'mirror_required',
  'target_registry',
  'image_count',
  'mappings'
]);
const IMAGE_MAP_RELEASE_CONTRACT_FIELDS = new Set([
  'input_sha256',
  'deploy_image_inventory_count'
]);
const TARGET_PROFILE_FIELDS = new Set([
  'value',
  'target_cluster',
  'substrate_source',
  'distribution'
]);
const IMAGE_MAP_MAPPING_FIELDS = new Set([
  'id',
  'source',
  'source_image',
  'source_digest',
  'target_image',
  'target_digest',
  'action'
]);

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
  node scripts/verify-render.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --target-profile <target_cluster>/<substrate_source>/<distribution> \\
    --render-values <json> \\
    --substrate-truth <json> \\
    --output-dir <dir> \\
    [--image-map <json>] \\
    [--forbidden-source-root <dir>]`;
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

function parseArgs(argv) {
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = argv[index + 1];
      if (!value || value.trim() === '' || value.startsWith('--')) {
        cliFail(`missing value for ${arg}`);
      }
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
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--render-values':
        parsed.renderValues = nextValue();
        break;
      case '--substrate-truth':
        parsed.substrateTruth = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--image-map':
        parsed.imageMap = nextValue();
        break;
      case '--forbidden-source-root':
        if (!parsed.forbiddenSourceRoots) {
          parsed.forbiddenSourceRoots = [];
        }
        parsed.forbiddenSourceRoots.push(nextValue());
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

async function readText(file, label) {
  try {
    return await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function readJson(file, label) {
  const raw = await readText(file, label);
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

async function readArchive(file) {
  try {
    return await fs.readFile(file);
  } catch (error) {
    fail(`cannot read archive: ${error.message}`);
  }
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

async function canonicalForbiddenSourceRoots(inputRoots) {
  const roots = [];

  for (const input of inputRoots) {
    const requested = path.resolve(input);
    let stat;
    try {
      stat = await fs.stat(requested);
    } catch {
      cliFail(`forbidden source root must exist: ${input}`);
    }

    if (!stat.isDirectory()) {
      cliFail(`forbidden source root must be a directory: ${input}`);
    }

    try {
      roots.push(await fs.realpath(requested));
    } catch (error) {
      cliFail(`cannot resolve forbidden source root: ${error.message}`);
    }
  }

  return roots;
}

async function existingDefaultForbiddenSourceRoots() {
  const roots = [];

  for (const root of DEFAULT_FORBIDDEN_SOURCE_ROOTS) {
    let stat;
    try {
      stat = await fs.stat(root);
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') {
        continue;
      }
      cliFail(`cannot inspect default forbidden source root: ${error.message}`);
    }

    if (stat.isDirectory()) {
      roots.push(root);
    }
  }

  return roots;
}

function assertNotForbiddenSourcePath(candidate, label, forbiddenSourceRoots) {
  const resolved = path.resolve(candidate);
  for (const root of forbiddenSourceRoots) {
    if (isInsidePath(root, resolved)) {
      fail(`${label} must not point to a configured forbidden product source tree`);
    }
  }
}

async function assertPathBoundary(input, label, forbiddenSourceRoots) {
  const requested = path.resolve(input);
  assertNotForbiddenSourcePath(requested, `${label} path`, forbiddenSourceRoots);

  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch {
    return requested;
  }

  if (stat.isSymbolicLink()) {
    let target;
    try {
      target = await fs.readlink(requested);
    } catch (error) {
      fail(`cannot read ${label} symlink: ${error.message}`);
    }
    const targetPath = path.resolve(path.dirname(requested), target);
    assertNotForbiddenSourcePath(targetPath, `${label} symlink target`, forbiddenSourceRoots);
  }

  try {
    const real = await fs.realpath(requested);
    assertNotForbiddenSourcePath(real, `${label} real path`, forbiddenSourceRoots);
  } catch {
    return requested;
  }

  return requested;
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

function requireInteger(value, label) {
  if (!Number.isInteger(value)) {
    fail(`${label} must be an integer`);
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

function assertAllowedObjectFields(value, allowedFields, label) {
  for (const field of Object.keys(value)) {
    if (!allowedFields.has(field)) {
      fail(`${label}.${field} is not allowed`);
    }
  }
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
  const leftStable = JSON.stringify(stableJson(left));
  const rightStable = JSON.stringify(stableJson(right));
  if (leftStable !== rightStable) {
    fail(`${label} mismatch`);
  }
}

function parseTargetProfile(targetProfile) {
  return parseCanonicalTargetProfile(targetProfile, fail);
}

function assertContractTargetProfiles(contract, targetProfile) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const seen = new Map();
  let matched = false;

  for (const [index, profileValue] of profiles.entries()) {
    const label = `release_contract.target_profiles[${index}]`;
    const profile = validateContractTargetProfileEntry(profileValue, fail, label);

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

function isSecretRefValue(value) {
  if (typeof value !== 'string' || !value.startsWith(SECRET_REF_PREFIX)) {
    return false;
  }
  const ref = value.slice(SECRET_REF_PREFIX.length);
  return ref.trim() !== '' && !/[\r\n]/.test(ref) && !/^[\s:]+$/.test(ref);
}

function isSafeSecretReference(value) {
  return (
    SAFE_REDACTED_SECRET_RE.test(value) ||
    SAFE_SECRET_REF_VALUE_RE.test(value) ||
    value === 'not_required' ||
    value === 'operator_secret_ref' ||
    isSecretRefValue(value)
  );
}

function isRelativeSourcePath(value, label) {
  const trimmed = value.trim();
  return (
    SOURCE_LIKE_LABEL_RE.test(label) &&
    !URI_SCHEME_RE.test(trimmed) &&
    /^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)+$/.test(trimmed)
  );
}

function isPackageManifestPathLabel(label) {
  return label.startsWith('archive.manifest_json.') && SOURCE_LIKE_LABEL_RE.test(label);
}

function scanUnsafeString(value, label, issues) {
  if (
    LOCAL_URI_RE.test(value) ||
    LOCALHOST_URI_RE.test(value) ||
    ABSOLUTE_LOCAL_PATH_RE.test(value) ||
    RELATIVE_URI_RE.test(value) ||
    (!isPackageManifestPathLabel(label) && isRelativeSourcePath(value, label)) ||
    WORKSPACE_SOURCE_RE.test(value)
  ) {
    issues.push(`${label} contains a local or source URI`);
  }

  if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
    issues.push(`${label} contains a secret-looking value`);
  }
}

function scanForUnsafePayload(value, label, issues = []) {
  if (typeof value === 'string') {
    scanUnsafeString(value, label, issues);
    return issues;
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      scanForUnsafePayload(item, `${label}[${index}]`, issues);
    });
    return issues;
  }

  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      const nestedLabel = `${label}.${key}`;
      if (
        SECRET_KEY_RE.test(key) &&
        typeof nested === 'string' &&
        !isSafeSecretReference(nested)
      ) {
        issues.push(`${nestedLabel} contains a secret-looking payload`);
      }
      scanForUnsafePayload(nested, nestedLabel, issues);
    }
  }

  return issues;
}

function assertNoUnsafePayload(...payloads) {
  const issues = [];
  for (const [value, label] of payloads) {
    scanForUnsafePayload(value, label, issues);
  }

  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function stripInlineComment(value) {
  return value.replace(/\s+#.*$/, '').trim();
}

function stripQuotes(value) {
  const text = value.trim();
  if (
    (text.startsWith('"') && text.endsWith('"')) ||
    (text.startsWith("'") && text.endsWith("'"))
  ) {
    return text.slice(1, -1);
  }
  return text;
}

function normalizedScalar(value) {
  return stripQuotes(value.trim().replace(/[,\]}]\s*$/, '').trim());
}

function assertNoRenderedUnsafePayload(raw, label) {
  const issues = [];
  scanUnsafeString(raw, label, issues);
  if (issues.length > 0) {
    fail(issues[0]);
  }

  for (const pattern of SECRET_VALUE_RE) {
    if (pattern.test(raw)) {
      fail(`${label} contains a secret-looking value`);
    }
  }

  for (const match of raw.matchAll(SECRET_KEY_VALUE_RE)) {
    const key = match[1];
    const value = normalizedScalar(match[2] || match[3] || match[4] || '');
    if (
      SECRET_KEY_RE.test(key) &&
      value !== '' &&
      value !== '{}' &&
      value !== '[]' &&
      !isSafeSecretReference(value)
    ) {
      fail(`${label} contains a secret-looking payload`);
    }
  }
}

function readTarString(block, start, length) {
  const slice = block.subarray(start, start + length);
  const end = slice.indexOf(0);
  return slice.subarray(0, end === -1 ? slice.length : end).toString('utf8').trim();
}

function parseTarOctal(block, start, length, label) {
  const raw = readTarString(block, start, length).trim();
  if (raw === '') {
    return 0;
  }
  if (!/^[0-7]+$/.test(raw)) {
    fail(`${label} has invalid tar size`);
  }
  return Number.parseInt(raw, 8);
}

function isZeroBlock(block) {
  return block.every((byte) => byte === 0);
}

function normalizeEntryPath(entryPath) {
  if (entryPath.includes('\\')) {
    fail(`archive entry path is not portable: ${entryPath}`);
  }
  if (entryPath.startsWith('/') || /^[A-Za-z]:[\\/]/.test(entryPath)) {
    fail(`archive entry path must be relative: ${entryPath}`);
  }

  const parts = entryPath.split('/');
  const normalizedParts = [];
  for (const part of parts) {
    if (part === '' || part === '.') {
      continue;
    }
    if (part === '..') {
      fail(`archive entry path escapes package root: ${entryPath}`);
    }
    normalizedParts.push(part);
  }

  const normalized = normalizedParts.join('/');
  if (!normalized) {
    fail(`archive entry path is empty: ${entryPath}`);
  }
  return normalized;
}

function isTextPayload(buffer) {
  if (buffer.length === 0) {
    return true;
  }
  return !buffer.subarray(0, Math.min(buffer.length, 8192)).includes(0);
}

function scanArchiveFileContent(content, entryPath) {
  if (!isTextPayload(content)) {
    return;
  }
  const issues = [];
  scanUnsafeString(content.toString('utf8'), `archive.${entryPath}`, issues);
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function parseManifest(content) {
  try {
    return requireObject(JSON.parse(content.toString('utf8')), 'archive.manifest_json');
  } catch (error) {
    fail(`archive manifest.json must be valid JSON: ${error.message}`);
  }
}

function parseTarGz(archiveBuffer) {
  let tarBuffer;
  try {
    tarBuffer = zlib.gunzipSync(archiveBuffer);
  } catch (error) {
    fail(`archive must be a readable .tgz: ${error.message}`);
  }

  const entries = [];
  const files = new Map();
  let manifestContent;
  let offset = 0;
  let zeroBlocks = 0;

  while (offset + 512 <= tarBuffer.length) {
    const block = tarBuffer.subarray(offset, offset + 512);
    if (isZeroBlock(block)) {
      zeroBlocks += 1;
      offset += 512;
      if (zeroBlocks >= 2) {
        break;
      }
      continue;
    }
    zeroBlocks = 0;

    const name = readTarString(block, 0, 100);
    const prefix = readTarString(block, 345, 155);
    const entryPath = normalizeEntryPath(prefix ? `${prefix}/${name}` : name);
    const typeFlag = block[156] === 0 ? '0' : String.fromCharCode(block[156]);
    const size = parseTarOctal(block, 124, 12, `archive entry ${entryPath}`);
    const contentStart = offset + 512;
    const contentEnd = contentStart + size;
    if (contentEnd > tarBuffer.length) {
      fail(`archive entry is truncated: ${entryPath}`);
    }

    if (typeFlag === '2') {
      fail(`archive symlink entries are not allowed: ${entryPath}`);
    }
    if (typeFlag === '1') {
      fail(`archive hardlink entries are not allowed: ${entryPath}`);
    }
    if (['x', 'g', 'L', 'K'].includes(typeFlag)) {
      fail(`archive extended tar metadata is not allowed: ${entryPath}`);
    }
    if (!['0', '5'].includes(typeFlag)) {
      fail(`archive entry type is not allowed: ${entryPath}`);
    }

    const type = typeFlag === '5' ? 'directory' : 'file';
    if (type === 'file') {
      if (files.has(entryPath)) {
        fail(`archive contains duplicate file entry: ${entryPath}`);
      }
      const content = tarBuffer.subarray(contentStart, contentEnd);
      scanArchiveFileContent(content, entryPath);
      files.set(entryPath, content);
      if (entryPath === 'manifest.json') {
        if (manifestContent) {
          fail('archive contains duplicate manifest.json entries');
        }
        manifestContent = content;
      }
    }

    entries.push({
      path: entryPath,
      type,
      size
    });

    offset = contentStart + Math.ceil(size / 512) * 512;
  }

  if (!manifestContent) {
    fail('archive must contain manifest.json at package root');
  }

  const manifest = parseManifest(manifestContent);
  assertNoUnsafePayload([manifest, 'archive.manifest_json']);

  return {
    entries,
    files,
    manifest,
    manifestSha256: digestBuffer(manifestContent)
  };
}

function assertDescriptorBoundary(contract, deployTemplatePackage) {
  const embedded = requireObject(
    contract.deploy_template_package,
    'release_contract.deploy_template_package'
  );
  assertSameJson(
    embedded,
    deployTemplatePackage,
    'release_contract.deploy_template_package'
  );

  const contractManifestDigest = requireDigest(
    contract.deploy_template_digest,
    'release_contract.deploy_template_digest'
  );
  const descriptorManifestDigest = requireDigest(
    deployTemplatePackage.manifest_sha256,
    'deploy_template_package.manifest_sha256'
  );
  if (contractManifestDigest !== descriptorManifestDigest) {
    fail('release_contract.deploy_template_digest must match deploy_template_package.manifest_sha256');
  }
}

function assertArchiveDigests(deployTemplatePackage, archiveSha256) {
  const packageSha256 = requireDigest(
    deployTemplatePackage.package_sha256,
    'deploy_template_package.package_sha256'
  );
  if (archiveSha256 !== packageSha256) {
    fail('archive sha256 must match deploy_template_package.package_sha256');
  }

  if (
    deployTemplatePackage.artifact_provenance &&
    Object.prototype.hasOwnProperty.call(
      deployTemplatePackage.artifact_provenance,
      'artifact_sha256'
    )
  ) {
    const provenanceArtifactSha256 = requireDigest(
      deployTemplatePackage.artifact_provenance.artifact_sha256,
      'deploy_template_package.artifact_provenance.artifact_sha256'
    );
    if (archiveSha256 !== provenanceArtifactSha256) {
      fail('archive sha256 must match deploy_template_package.artifact_provenance.artifact_sha256');
    }
  }
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

function assertRequiredImageIds(contract, deployTemplatePackage, inventoryById) {
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
  const inventoryIds = [...inventoryById.keys()];
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
    image,
    digest,
    image_without_digest: imageWithoutDigest,
    source
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

function buildInventory(contract) {
  const items = requireArray(
    contract.deploy_image_inventory,
    'release_contract.deploy_image_inventory'
  );
  const byExact = new Map();
  const byDigest = new Map();
  const byImageWithoutDigest = new Map();
  const byId = new Map();

  for (const [index, itemValue] of items.entries()) {
    const label = `release_contract.deploy_image_inventory[${index}]`;
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
    if (byExact.has(image)) {
      fail(`release_contract.deploy_image_inventory contains duplicate image: ${image}`);
    }
    if (byId.has(id)) {
      fail(`release_contract.deploy_image_inventory contains duplicate id: ${id}`);
    }

    const source = requireString(item.source, `${label}.source`);
    if (!IMAGE_SOURCES.includes(source)) {
      fail(`${label}.source is not a known image source`);
    }

    const normalized = {
      id,
      image,
      digest,
      image_without_digest: imageWithoutDigest,
      source
    };
    byExact.set(image, normalized);
    byId.set(id, normalized);
    if (!byDigest.has(digest)) {
      byDigest.set(digest, []);
    }
    byDigest.get(digest).push(normalized);
    if (!byImageWithoutDigest.has(imageWithoutDigest)) {
      byImageWithoutDigest.set(imageWithoutDigest, []);
    }
    byImageWithoutDigest.get(imageWithoutDigest).push(normalized);
  }

  if (byExact.size === 0) {
    fail('release_contract.deploy_image_inventory must not be empty');
  }

  const expected = declaredInventory(contract);
  if (expected.length !== byId.size) {
    fail('release_contract.deploy_image_inventory must match declared image sources');
  }
  for (const expectedItem of expected) {
    const actual = byId.get(expectedItem.id);
    if (
      !actual ||
      actual.source !== expectedItem.source ||
      actual.image !== expectedItem.image ||
      actual.digest !== expectedItem.digest
    ) {
      fail('release_contract.deploy_image_inventory must match declared image sources');
    }
  }

  return { byExact, byDigest, byImageWithoutDigest, byId };
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
  const value = requireString(input, 'image_map.target_registry');
  if (value.trim() !== value || /\s/.test(value)) {
    fail('image_map.target_registry must not contain whitespace');
  }
  if (URI_SCHEME_RE.test(value)) {
    fail('image_map.target_registry must not include a URI scheme');
  }
  if (value.includes('@')) {
    fail('image_map.target_registry must not include userinfo');
  }
  if (/[?#]/.test(value)) {
    fail('image_map.target_registry must not include query or hash text');
  }
  if (value.includes('\\') || value.startsWith('/') || value.endsWith('/') || value.includes('//')) {
    fail('image_map.target_registry must be <registry-host[/namespace]>');
  }

  const parts = value.split('/');
  const host = parseRegistryHostPort(parts[0], 'image_map.target_registry');
  const hostName = host.toLowerCase();

  if (isLocalRegistryHost(hostName)) {
    fail('image_map.target_registry must not point at localhost, loopback, or host.docker.internal');
  }
  if (!isIpv4Address(hostName) && !DNS_HOST_RE.test(hostName)) {
    fail('image_map.target_registry host must be a DNS name or IPv4 address');
  }

  for (const [index, component] of parts.slice(1).entries()) {
    if (!TARGET_NAMESPACE_COMPONENT_RE.test(component)) {
      fail(`image_map.target_registry namespace component ${index + 1} is invalid`);
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

function assertImageMapTargetProfile(imageMapTargetProfile, targetProfile) {
  const profile = requireObject(imageMapTargetProfile, 'image_map.target_profile');
  assertAllowedObjectFields(profile, TARGET_PROFILE_FIELDS, 'image_map.target_profile');

  if (requireString(profile.value, 'image_map.target_profile.value') !== targetProfile.value) {
    fail('image_map.target_profile.value must match --target-profile');
  }
  if (
    requireString(profile.target_cluster, 'image_map.target_profile.target_cluster') !==
    targetProfile.target_cluster
  ) {
    fail('image_map.target_profile.target_cluster must match --target-profile');
  }
  if (
    requireString(profile.substrate_source, 'image_map.target_profile.substrate_source') !==
    targetProfile.substrate_source
  ) {
    fail('image_map.target_profile.substrate_source must match --target-profile');
  }
  if (
    requireString(profile.distribution, 'image_map.target_profile.distribution') !==
    targetProfile.distribution
  ) {
    fail('image_map.target_profile.distribution must match --target-profile');
  }
}

function validateImageMapMapping({
  mappingValue,
  index,
  inventoryItem,
  mirrorRequired,
  targetRegistry
}) {
  const label = `image_map.mappings[${index}]`;
  const mapping = requireObject(mappingValue, label);
  assertAllowedObjectFields(mapping, IMAGE_MAP_MAPPING_FIELDS, label);

  const id = requireString(mapping.id, `${label}.id`);
  if (id !== inventoryItem.id) {
    fail(`${label}.id must match release_contract.deploy_image_inventory`);
  }

  const source = requireString(mapping.source, `${label}.source`);
  if (source !== inventoryItem.source) {
    fail(`${label}.source must match release_contract.deploy_image_inventory`);
  }

  const sourceImage = requireString(mapping.source_image, `${label}.source_image`);
  if (sourceImage !== inventoryItem.image) {
    fail(`${label}.source_image must match release_contract.deploy_image_inventory`);
  }

  const sourceDigest = requireDigest(mapping.source_digest, `${label}.source_digest`);
  if (sourceDigest !== inventoryItem.digest) {
    fail(`${label}.source_digest must match release_contract.deploy_image_inventory`);
  }

  const targetDigest = requireDigest(mapping.target_digest, `${label}.target_digest`);
  if (targetDigest !== sourceDigest) {
    fail(`${label}.target_digest must match ${label}.source_digest`);
  }

  const targetImage = requireString(mapping.target_image, `${label}.target_image`);
  const { digest: targetImageDigest } = imageDigestSuffix(targetImage, `${label}.target_image`);
  if (targetImageDigest !== targetDigest) {
    fail(`${label}.target_image digest must match ${label}.target_digest`);
  }

  const action = requireString(mapping.action, `${label}.action`);
  if (!IMAGE_MAP_ACTIONS.has(action)) {
    fail(`${label}.action must be use_source or mirror_required`);
  }
  if (mirrorRequired && action !== 'mirror_required') {
    fail(`${label}.action must be mirror_required when image_map.mirror_required is true`);
  }
  if (!mirrorRequired && action !== 'use_source') {
    fail(`${label}.action must be use_source when image_map.mirror_required is false`);
  }
  if (!mirrorRequired && targetImage !== sourceImage) {
    fail(`${label}.target_image must match source_image when image_map.mirror_required is false`);
  }
  if (mirrorRequired) {
    const expectedTargetImage = targetImageFor(inventoryItem, targetRegistry);
    if (targetImage !== expectedTargetImage) {
      fail(`${label}.target_image must match deterministic image_map.target_registry mirror ref`);
    }
  }

  return {
    id,
    image: targetImage,
    digest: targetDigest,
    source
  };
}

function validateImageMap({
  imageMap,
  contract,
  releaseContractInputDigest,
  inventory,
  targetProfile
}) {
  const report = requireObject(imageMap, 'image_map');
  assertAllowedObjectFields(report, IMAGE_MAP_FIELDS, 'image_map');
  assertSchemaVersion(report.schema, IMAGE_MAP_SCHEMA, 'image_map.schema');

  if (requireString(report.scope, 'image_map.scope') !== IMAGE_MAP_SCOPE) {
    fail(`image_map.scope must be ${IMAGE_MAP_SCOPE}`);
  }
  if (report.readiness !== false) {
    fail('image_map.readiness must be false');
  }
  if (requireString(report.status, 'image_map.status') !== 'pass') {
    fail('image_map.status must be pass');
  }
  if (requireString(report.release_id, 'image_map.release_id') !== contract.release_id) {
    fail('image_map.release_id must match release_contract.release_id');
  }
  if (requireGitSha(report.git_sha, 'image_map.git_sha') !== contract.git_sha) {
    fail('image_map.git_sha must match release_contract.git_sha');
  }

  const releaseContract = requireObject(
    report.release_contract,
    'image_map.release_contract'
  );
  assertAllowedObjectFields(
    releaseContract,
    IMAGE_MAP_RELEASE_CONTRACT_FIELDS,
    'image_map.release_contract'
  );
  if (
    requireDigest(
      releaseContract.input_sha256,
      'image_map.release_contract.input_sha256'
    ) !== releaseContractInputDigest
  ) {
    fail('image_map.release_contract.input_sha256 must match release contract input sha256');
  }
  if (
    requireInteger(
      releaseContract.deploy_image_inventory_count,
      'image_map.release_contract.deploy_image_inventory_count'
    ) !== inventory.byId.size
  ) {
    fail('image_map.release_contract.deploy_image_inventory_count must match release_contract.deploy_image_inventory');
  }

  assertImageMapTargetProfile(report.target_profile, targetProfile);

  const mirrorRequired = requireBoolean(report.mirror_required, 'image_map.mirror_required');
  const hasTargetRegistry = Object.prototype.hasOwnProperty.call(report, 'target_registry');
  let targetRegistry;
  if (mirrorRequired && !hasTargetRegistry) {
    fail('image_map.target_registry is required when image_map.mirror_required is true');
  }
  if (!mirrorRequired && hasTargetRegistry) {
    fail('image_map.target_registry is only allowed when image_map.mirror_required is true');
  }
  if (mirrorRequired) {
    targetRegistry = validateTargetRegistry(report.target_registry);
  }

  const mappings = requireArray(report.mappings, 'image_map.mappings');
  const imageCount = requireInteger(report.image_count, 'image_map.image_count');
  if (imageCount !== mappings.length) {
    fail('image_map.image_count must match image_map.mappings length');
  }
  if (mappings.length !== inventory.byId.size) {
    fail('image_map.mappings must match release_contract.deploy_image_inventory one-to-one');
  }

  const seenIds = new Set();
  const imagesById = new Map();

  for (const [index, mappingValue] of mappings.entries()) {
    const mapping = requireObject(mappingValue, `image_map.mappings[${index}]`);
    const id = requireString(mapping.id, `image_map.mappings[${index}].id`);
    if (seenIds.has(id)) {
      fail(`image_map.mappings contains duplicate id: ${id}`);
    }
    seenIds.add(id);

    const inventoryItem = inventory.byId.get(id);
    if (!inventoryItem) {
      fail(`image_map.mappings[${index}].id is not listed in release_contract.deploy_image_inventory`);
    }

    imagesById.set(
      id,
      validateImageMapMapping({
        mappingValue,
        index,
        inventoryItem,
        mirrorRequired,
        targetRegistry
      })
    );
  }

  for (const id of inventory.byId.keys()) {
    if (!seenIds.has(id)) {
      fail(`image_map.mappings missing release_contract.deploy_image_inventory id: ${id}`);
    }
  }

  return imagesById;
}

function buildRenderContext({
  contract,
  inventory,
  targetProfile,
  renderValues,
  substrateTruth,
  imageMapImages
}) {
  const images = {};
  for (const [id, item] of inventory.byId.entries()) {
    const mappedImage = imageMapImages?.get(id);
    images[id] = {
      image: mappedImage?.image || item.image,
      digest: mappedImage?.digest || item.digest,
      source: item.source
    };
  }

  return {
    values: renderValues,
    images,
    target: targetProfile,
    substrate: substrateTruth,
    release: {
      product: contract.product,
      release_id: contract.release_id,
      git_sha: contract.git_sha,
      deploy_template_digest: contract.deploy_template_digest
    }
  };
}

function resolveTemplateValue(context, expression) {
  const parts = expression.split('.');
  let current = context;

  for (const part of parts) {
    if (
      current &&
      typeof current === 'object' &&
      !Array.isArray(current) &&
      Object.prototype.hasOwnProperty.call(current, part)
    ) {
      current = current[part];
      continue;
    }

    if (Array.isArray(current) && /^[0-9]+$/.test(part)) {
      current = current[Number(part)];
      continue;
    }

    fail(`unknown template placeholder: ${expression}`);
  }

  if (
    current === null ||
    current === undefined ||
    (typeof current === 'object' && !Array.isArray(current))
  ) {
    fail(`template placeholder must resolve to a scalar: ${expression}`);
  }
  if (Array.isArray(current)) {
    fail(`template placeholder must resolve to a scalar: ${expression}`);
  }
  return String(current);
}

function renderTemplate(raw, context, templatePath) {
  const openCount = raw.match(/\$\{\{/g)?.length || 0;
  let matchedCount = 0;

  const rendered = raw.replace(TEMPLATE_PLACEHOLDER_RE, (_match, expressionRaw) => {
    matchedCount += 1;
    const expression = expressionRaw.trim();
    if (!TEMPLATE_EXPR_RE.test(expression)) {
      fail(`malformed template placeholder in ${templatePath}: ${expression}`);
    }
    return resolveTemplateValue(context, expression);
  });

  if (openCount !== matchedCount || rendered.includes('${{')) {
    fail(`template contains an unterminated placeholder: ${templatePath}`);
  }

  return rendered;
}

function templateEntries(archive) {
  const manifest = requireObject(archive.manifest, 'archive.manifest_json');
  assertSchemaVersion(
    manifest.schema_version,
    DEPLOY_TEMPLATE_MANIFEST_SCHEMA,
    'archive.manifest_json.schema_version'
  );
  const templates = requireArray(manifest.templates, 'archive.manifest_json.templates');
  const entries = [];
  const seenPaths = new Set();

  for (const [index, templateValue] of templates.entries()) {
    const label = `archive.manifest_json.templates[${index}]`;
    const template = requireObject(templateValue, label);
    const kind = requireString(template.kind, `${label}.kind`);
    if (kind !== 'kubernetes') {
      continue;
    }
    const templatePath = normalizeEntryPath(requireString(template.path, `${label}.path`));
    if (seenPaths.has(templatePath)) {
      fail(`archive manifest declares duplicate template path: ${templatePath}`);
    }
    seenPaths.add(templatePath);
    if (!MANIFEST_EXTENSIONS.has(path.extname(templatePath).toLowerCase())) {
      fail(`${label}.path must be a yaml, yml, or json manifest template`);
    }
    if (!archive.files.has(templatePath)) {
      fail(`archive manifest declares missing template file: ${templatePath}`);
    }
    entries.push({
      path: templatePath,
      content: archive.files.get(templatePath)
    });
  }

  if (entries.length === 0) {
    fail('archive manifest must declare at least one Kubernetes template');
  }
  return entries;
}

function assertInsideRoot(rootDir, file, label) {
  const relative = path.relative(rootDir, file);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must stay inside rendered manifests root`);
  }
}

async function prepareRenderedRoot(outputDirInput, forbiddenSourceRoots) {
  const outputDir = await assertPathBoundary(outputDirInput, 'output dir', forbiddenSourceRoots);
  await fs.mkdir(outputDir, { recursive: true });

  let outputReal;
  try {
    outputReal = await fs.realpath(outputDir);
  } catch (error) {
    fail(`cannot resolve output dir: ${error.message}`);
  }
  assertNotForbiddenSourcePath(outputReal, 'output dir real path', forbiddenSourceRoots);

  const renderedRoot = path.join(outputReal, 'rendered-manifests');
  let stat;
  try {
    stat = await fs.lstat(renderedRoot);
  } catch {
    stat = undefined;
  }
  if (stat?.isSymbolicLink()) {
    fail('rendered manifests output must not be a symlink');
  }

  await fs.rm(renderedRoot, { recursive: true, force: true });
  await fs.mkdir(renderedRoot, { recursive: true });
  return renderedRoot;
}

async function writeRenderedTemplates({ entries, context, renderedRoot }) {
  const renderedFiles = [];

  for (const entry of entries) {
    const raw = entry.content.toString('utf8');
    const rendered = renderTemplate(raw, context, entry.path);
    assertNoRenderedUnsafePayload(rendered, `rendered manifest ${entry.path}`);

    const outputPath = path.join(renderedRoot, entry.path);
    assertInsideRoot(renderedRoot, outputPath, `rendered manifest ${entry.path}`);
    await fs.mkdir(path.dirname(outputPath), { recursive: true });
    await fs.writeFile(outputPath, rendered);
    renderedFiles.push({
      path: entry.path,
      source_template: entry.path,
      sha256: digestBuffer(Buffer.from(rendered)),
      bytes: Buffer.byteLength(rendered)
    });
  }

  return renderedFiles;
}

function getResourceName(resource) {
  if (
    resource.metadata &&
    typeof resource.metadata === 'object' &&
    !Array.isArray(resource.metadata) &&
    typeof resource.metadata.name === 'string'
  ) {
    return resource.metadata.name;
  }
  return undefined;
}

function workloadPodSpec(resource, kind) {
  switch (kind) {
    case 'Pod':
      return resource.spec;
    case 'Deployment':
    case 'StatefulSet':
    case 'DaemonSet':
    case 'ReplicaSet':
    case 'Job':
      return resource.spec?.template?.spec;
    case 'CronJob':
      return resource.spec?.jobTemplate?.spec?.template?.spec;
    default:
      return undefined;
  }
}

function extractJsonWorkload(resource, label) {
  if (!resource || typeof resource !== 'object' || Array.isArray(resource)) {
    return [];
  }
  if (resource.kind === 'List' && Array.isArray(resource.items)) {
    return resource.items.flatMap((item, index) => {
      return extractJsonWorkload(item, `${label}.items[${index}]`);
    });
  }

  const kind = typeof resource.kind === 'string' ? resource.kind : undefined;
  if (!WORKLOAD_KINDS.has(kind)) {
    return [];
  }

  const podSpec = workloadPodSpec(resource, kind);
  const spec = requireObject(podSpec, `${label}.spec.template.spec`);
  const images = [];

  for (const field of ['initContainers', 'containers']) {
    if (!Object.prototype.hasOwnProperty.call(spec, field)) {
      continue;
    }
    const containers = requireArray(spec[field], `${label}.${field}`);
    for (const [index, containerValue] of containers.entries()) {
      const container = requireObject(containerValue, `${label}.${field}[${index}]`);
      images.push({
        image: requireString(container.image, `${label}.${field}[${index}].image`),
        container: typeof container.name === 'string' ? container.name : undefined,
        field
      });
    }
  }

  if (images.length === 0) {
    fail(`${label} workload must include containers or initContainers images`);
  }

  return [{
    kind,
    name: getResourceName(resource),
    images
  }];
}

function parseJsonManifest(raw, relativePath) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    fail(`invalid JSON manifest ${relativePath}: ${error.message}`);
  }

  return extractJsonWorkload(parsed, `manifest ${relativePath}`);
}

function yamlDocuments(raw) {
  return raw
    .split(/^---[ \t]*(?:#.*)?$/m)
    .map((document) => document.trim())
    .filter((document) => document !== '');
}

function yamlKind(document) {
  const match = document.match(/^kind:\s*["']?([A-Za-z]+)["']?\s*$/m);
  return match ? match[1] : undefined;
}

function yamlImagesInText(text) {
  return [...text.matchAll(YAML_IMAGE_KEY_RE)].map((match) => {
    return stripQuotes(stripInlineComment(match[1] || match[2] || match[3] || ''));
  }).filter((image) => image !== '');
}

function yamlName(document) {
  const lines = document.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    if (/^metadata:\s*$/.test(lines[index])) {
      const metadataIndent = 0;
      for (let nested = index + 1; nested < lines.length; nested += 1) {
        const line = lines[nested];
        if (line.trim() === '' || line.trim().startsWith('#')) {
          continue;
        }
        const indent = line.match(/^\s*/)[0].length;
        if (indent <= metadataIndent) {
          break;
        }
        const match = line.match(/^\s+name:\s*(.+?)\s*$/);
        if (match) {
          return stripQuotes(stripInlineComment(match[1]));
        }
      }
    }
  }
  return undefined;
}

function yamlContainerImages(document) {
  const images = [];
  const lines = document.split(/\r?\n/);
  let block = null;

  for (const [index, line] of lines.entries()) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) {
      continue;
    }

    const indent = line.match(/^\s*/)[0].length;
    if (block && indent <= block.indent) {
      block = null;
    }

    const blockMatch = line.match(/^(\s*)(containers|initContainers):\s*(.*)$/);
    if (blockMatch) {
      const field = blockMatch[2];
      for (const image of yamlImagesInText(blockMatch[3])) {
        images.push({
          image,
          field,
          line: index + 1
        });
      }
      block = {
        field,
        indent: blockMatch[1].length
      };
      continue;
    }

    if (!block) {
      continue;
    }

    for (const image of yamlImagesInText(line)) {
      images.push({
        image,
        field: block.field,
        line: index + 1
      });
    }
  }

  return images;
}

function parseYamlManifest(raw, relativePath) {
  const workloads = [];
  const documents = yamlDocuments(raw);

  documents.forEach((document, index) => {
    const kind = yamlKind(document);
    if (kind === 'List') {
      const images = yamlContainerImages(document);
      if (images.length > 0) {
        workloads.push({
          kind,
          name: yamlName(document),
          document_index: index + 1,
          images
        });
      }
      return;
    }

    if (!WORKLOAD_KINDS.has(kind)) {
      return;
    }

    const images = yamlContainerImages(document);
    if (images.length === 0) {
      fail(`manifest ${relativePath}#${index + 1} workload must include container images`);
    }
    workloads.push({
      kind,
      name: yamlName(document),
      document_index: index + 1,
      images
    });
  });

  return workloads;
}

function parseRenderedManifest(raw, relativePath) {
  if (path.extname(relativePath).toLowerCase() === '.json') {
    return parseJsonManifest(raw, relativePath);
  }

  const trimmed = raw.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return parseJsonManifest(raw, relativePath);
  }
  return parseYamlManifest(raw, relativePath);
}

function validateImage(imageEntry, inventory, label) {
  const image = requireString(imageEntry.image, label);
  const { digest, image_without_digest: imageWithoutDigest } = imageDigestSuffix(image, label);

  const exact = inventory.byExact.get(image);
  if (exact) {
    return {
      image,
      digest,
      inventory_id: exact.id,
      source: exact.source
    };
  }

  const digestMatches = inventory.byDigest.get(digest);
  if (digestMatches?.length > 0) {
    const match = digestMatches[0];
    return {
      image,
      digest,
      inventory_id: match.id,
      source: match.source,
      matched_by: 'digest'
    };
  }

  if (inventory.byImageWithoutDigest.has(imageWithoutDigest)) {
    fail(`${label} digest does not match release_contract.deploy_image_inventory`);
  }
  fail(`${label} is not listed in release_contract.deploy_image_inventory`);
}

async function validateRenderedManifests(renderedRoot, renderedFiles, inventory) {
  if (renderedFiles.length === 0) {
    fail('render must produce at least one manifest');
  }

  const manifests = [];
  const usedImages = new Map();

  for (const file of renderedFiles) {
    const filePath = path.join(renderedRoot, file.path);
    assertInsideRoot(renderedRoot, filePath, `rendered manifest ${file.path}`);
    const raw = await readText(filePath, `rendered manifest ${file.path}`);
    assertNoRenderedUnsafePayload(raw, `rendered manifest ${file.path}`);
    const workloads = parseRenderedManifest(raw, file.path);

    for (const [workloadIndex, workload] of workloads.entries()) {
      const manifestImages = workload.images.map((entry, imageIndex) => {
        const label = `rendered manifest ${file.path} workload ${workload.kind} image ${imageIndex + 1}`;
        const normalized = validateImage(entry, inventory, label);
        const imageReport = {
          field: entry.field,
          container: entry.container,
          image: normalized.image,
          digest: normalized.digest,
          inventory_id: normalized.inventory_id,
          source: normalized.source,
          matched_by: normalized.matched_by || 'exact_ref'
        };
        usedImages.set(normalized.image, {
          image: normalized.image,
          digest: normalized.digest,
          inventory_id: normalized.inventory_id,
          source: normalized.source
        });
        return imageReport;
      });

      manifests.push({
        path: file.path,
        document_index: workload.document_index || workloadIndex + 1,
        kind: workload.kind,
        name: workload.name,
        sha256: file.sha256,
        images: manifestImages
      });
    }
  }

  if (manifests.length === 0) {
    fail('rendered manifests must contain at least one supported Kubernetes workload');
  }

  return {
    workload_count: manifests.length,
    manifests,
    images: [...usedImages.values()].sort((left, right) => {
      return left.image.localeCompare(right.image);
    })
  };
}

function buildReport({
  contract,
  releaseContractInputDigest,
  deployTemplatePackage,
  deployTemplatePackageInputDigest,
  archiveSha256,
  archive,
  targetProfile,
  renderValuesInputDigest,
  substrateTruthInputDigest,
  renderedFiles,
  manifestSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: 'manifest_render_only',
    readiness: false,
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile,
    artifacts: {
      release_contract: {
        input_sha256: releaseContractInputDigest,
        deploy_template_digest: contract.deploy_template_digest,
        deploy_image_inventory_count: contract.deploy_image_inventory.length
      },
      deploy_template_package: {
        input_sha256: deployTemplatePackageInputDigest,
        package_sha256: deployTemplatePackage.package_sha256,
        manifest_sha256: deployTemplatePackage.manifest_sha256
      },
      archive: {
        archive_sha256: archiveSha256,
        manifest_sha256: archive.manifestSha256,
        entry_count: archive.entries.length
      },
      render_values: {
        input_sha256: renderValuesInputDigest
      },
      substrate_truth: {
        input_sha256: substrateTruthInputDigest
      }
    },
    rendered_manifests: {
      output_dir: 'rendered-manifests',
      files_count: renderedFiles.length,
      workload_count: manifestSummary.workload_count
    },
    rendered_files: renderedFiles,
    images: manifestSummary.images,
    manifests: manifestSummary.manifests,
    status: 'pass'
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(
    path.join(outputDir, 'manifest-render-report.json'),
    `${JSON.stringify(report, null, 2)}\n`
  );
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const targetProfile = parseTargetProfile(args.targetProfile);
  const forbiddenSourceRootInputs = [
    ...(await existingDefaultForbiddenSourceRoots()),
    ...(args.forbiddenSourceRoots || [])
  ];
  const forbiddenSourceRoots = await canonicalForbiddenSourceRoots(forbiddenSourceRootInputs);
  const releaseContractPath = await assertPathBoundary(
    args.releaseContract,
    'release contract',
    forbiddenSourceRoots
  );
  const deployTemplatePackagePath = await assertPathBoundary(
    args.deployTemplatePackage,
    'deploy template package',
    forbiddenSourceRoots
  );
  const archivePath = await assertPathBoundary(args.archive, 'archive', forbiddenSourceRoots);
  const renderValuesPath = await assertPathBoundary(
    args.renderValues,
    'render values',
    forbiddenSourceRoots
  );
  const substrateTruthPath = await assertPathBoundary(
    args.substrateTruth,
    'substrate truth',
    forbiddenSourceRoots
  );
  const imageMapPath = args.imageMap
    ? await assertPathBoundary(args.imageMap, 'image map', forbiddenSourceRoots)
    : undefined;

  const releaseContractInput = await readJson(releaseContractPath, 'release contract');
  const deployTemplatePackageInput = await readJson(
    deployTemplatePackagePath,
    'deploy template package'
  );
  const renderValuesInput = await readJson(renderValuesPath, 'render values');
  const substrateTruthInput = await readJson(substrateTruthPath, 'substrate truth');
  const imageMapInput = imageMapPath
    ? await readJson(imageMapPath, 'image map')
    : undefined;
  const archiveBuffer = await readArchive(archivePath);
  const archiveSha256 = digestBuffer(archiveBuffer);

  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const deployTemplatePackage = requireObject(
    deployTemplatePackageInput.value,
    'deploy_template_package'
  );
  const renderValues = requireObject(renderValuesInput.value, 'render_values');
  const substrateTruth = requireObject(substrateTruthInput.value, 'substrate_truth');

  assertSchemaVersion(
    contract.schema_version,
    RELEASE_CONTRACT_SCHEMA,
    'release_contract.schema_version'
  );
  assertSchemaVersion(
    deployTemplatePackage.schema_version,
    DEPLOY_TEMPLATE_PACKAGE_SCHEMA,
    'deploy_template_package.schema_version'
  );
  requireString(contract.release_id, 'release_contract.release_id');
  contract.git_sha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  assertContractTargetProfiles(contract, targetProfile);

  assertNoUnsafePayload(
    [contract, 'release_contract'],
    [deployTemplatePackage, 'deploy_template_package'],
    [renderValues, 'render_values']
  );
  assertNoUnsafeSubstratePayload(substrateTruth, 'substrate_truth', substrateTruthInput.raw);
  validateSubstrateConnectionTruth(substrateTruth, targetProfile, { label: 'substrate_truth' });

  assertDescriptorBoundary(contract, deployTemplatePackage);
  assertArchiveDigests(deployTemplatePackage, archiveSha256);

  const archive = parseTarGz(archiveBuffer);
  const descriptorManifestDigest = requireDigest(
    deployTemplatePackage.manifest_sha256,
    'deploy_template_package.manifest_sha256'
  );
  if (archive.manifestSha256 !== descriptorManifestDigest) {
    fail('archive manifest.json sha256 must match deploy_template_package.manifest_sha256');
  }

  const inventory = buildInventory(contract);
  assertRequiredImageIds(contract, deployTemplatePackage, inventory.byId);
  const imageMapImages = imageMapInput
    ? validateImageMap({
        imageMap: imageMapInput.value,
        contract,
        releaseContractInputDigest: releaseContractInput.inputDigest,
        inventory,
        targetProfile
      })
    : undefined;
  const entries = templateEntries(archive);
  const context = buildRenderContext({
    contract,
    inventory,
    targetProfile,
    renderValues,
    substrateTruth,
    imageMapImages
  });
  const renderedRoot = await prepareRenderedRoot(args.outputDir, forbiddenSourceRoots);
  const renderedFiles = await writeRenderedTemplates({
    entries,
    context,
    renderedRoot
  });
  const manifestSummary = await validateRenderedManifests(
    renderedRoot,
    renderedFiles,
    inventory
  );

  await writeReport(
    args.outputDir,
    buildReport({
      contract,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      deployTemplatePackage,
      deployTemplatePackageInputDigest: deployTemplatePackageInput.inputDigest,
      archiveSha256,
      archive,
      targetProfile,
      renderValuesInputDigest: renderValuesInput.inputDigest,
      substrateTruthInputDigest: substrateTruthInput.inputDigest,
      renderedFiles,
      manifestSummary
    })
  );
  console.log('PASS: deploy templates rendered into manifest files');
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
