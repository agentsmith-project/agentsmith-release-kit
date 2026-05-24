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
const REPORT_SCHEMA = 'agentsmith.manifest-render-report/v1';
const TARGET_CLUSTER_VALUES = new Set(['existing_kubernetes', 'kind_rehearsal']);
const SUBSTRATE_SOURCE_VALUES = new Set(['external_declared', 'kit_installed']);
const DISTRIBUTION_VALUES = new Set(['online', 'airgap']);
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
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const TEMPLATE_EXPR_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_-]+)*$/;
const TEMPLATE_PLACEHOLDER_RE = /\$\{\{([\s\S]*?)\}\}/g;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
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

function requireEnumString(value, label, allowedValues) {
  const text = requireString(value, label);
  if (!allowedValues.has(text)) {
    fail(`${label} must be one of: ${[...allowedValues].join(', ')}`);
  }
  return text;
}

function assertSchemaVersion(value, expected, label) {
  const schemaVersion = requireString(value, label);
  if (schemaVersion !== expected) {
    fail(`${label} must be ${expected}`);
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
  requireString(targetProfile, 'target_profile');
  const tuple = targetProfile.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const value = `${targetCluster}/${substrateSource}/${distribution}`;
  return {
    value,
    target_cluster: requireEnumString(
      targetCluster,
      'target_profile.target_cluster',
      TARGET_CLUSTER_VALUES
    ),
    substrate_source: requireEnumString(
      substrateSource,
      'target_profile.substrate_source',
      SUBSTRATE_SOURCE_VALUES
    ),
    distribution: requireEnumString(
      distribution,
      'target_profile.distribution',
      DISTRIBUTION_VALUES
    )
  };
}

function assertContractTargetProfiles(contract, targetProfile) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  let matched = false;

  for (const [index, profileValue] of profiles.entries()) {
    const profile = requireObject(profileValue, `release_contract.target_profiles[${index}]`);
    const targetCluster = requireEnumString(
      profile.target_cluster,
      `release_contract.target_profiles[${index}].target_cluster`,
      TARGET_CLUSTER_VALUES
    );
    const substrateSource = requireEnumString(
      profile.substrate_source,
      `release_contract.target_profiles[${index}].substrate_source`,
      SUBSTRATE_SOURCE_VALUES
    );
    const distribution = requireEnumString(
      profile.distribution,
      `release_contract.target_profiles[${index}].distribution`,
      DISTRIBUTION_VALUES
    );
    if (Object.prototype.hasOwnProperty.call(profile, 'support_level')) {
      fail(`release_contract.target_profiles[${index}].support_level is not allowed; use release_contract.target_profiles[${index}].required`);
    }
    if (!Object.prototype.hasOwnProperty.call(profile, 'required')) {
      fail(`release_contract.target_profiles[${index}].required is required`);
    }
    const required = requireBoolean(
      profile.required,
      `release_contract.target_profiles[${index}].required`
    );
    if (targetCluster === 'kind_rehearsal' && required) {
      fail(`release_contract.target_profiles[${index}]: kind_rehearsal target profile must not be required`);
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

function imageDigestSuffix(image, label) {
  const marker = '@sha256:';
  const index = image.lastIndexOf(marker);
  if (index < 0) {
    fail(`${label} must be digest-pinned with @sha256`);
  }

  const digest = `sha256:${image.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return { digest, image_without_digest: image.slice(0, index) };
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

    const normalized = {
      id,
      image,
      digest,
      source: typeof item.source === 'string' ? item.source : undefined
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

  return { byExact, byDigest, byImageWithoutDigest, byId };
}

function buildRenderContext({
  contract,
  inventory,
  targetProfile,
  renderValues,
  substrateTruth
}) {
  const images = {};
  for (const [id, item] of inventory.byId.entries()) {
    images[id] = {
      image: item.image,
      digest: item.digest,
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

  const releaseContractInput = await readJson(releaseContractPath, 'release contract');
  const deployTemplatePackageInput = await readJson(
    deployTemplatePackagePath,
    'deploy template package'
  );
  const renderValuesInput = await readJson(renderValuesPath, 'render values');
  const substrateTruthInput = await readJson(substrateTruthPath, 'substrate truth');
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
  const entries = templateEntries(archive);
  const context = buildRenderContext({
    contract,
    inventory,
    targetProfile,
    renderValues,
    substrateTruth
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
