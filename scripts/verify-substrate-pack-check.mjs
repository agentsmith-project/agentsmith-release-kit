#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  SUBSTRATE_CONNECTION_SCHEMA,
  assertNoUnsafeSubstratePayload,
  validateSubstrateConnectionTruth
} from './lib/substrate-truth-validation.mjs';
import { requirePlainSemver } from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'targetProfile',
  'substratePackManifest',
  'substrateTruth',
  'outputDir'
];
const MANIFEST_SCHEMA = 'agentsmith.substrate-pack-manifest/v1';
const REPORT_SCHEMA = 'agentsmith.substrate-pack-check-report/v1';
const REPORT_SCOPE = 'substrate_pack_check_only';
const REPORT_FILE = 'substrate-pack-check-report.json';
const INSTALLED_BY = 'agentsmith-release-kit';
const SUPPORTED_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
];
const SUPPORTED_TARGET_PROFILE_SET = new Set(SUPPORTED_TARGET_PROFILE_VALUES);
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
  node scripts/verify-substrate-pack-check.mjs \\
    --target-profile existing_kubernetes/kit_installed/<online|airgap> \\
    --substrate-pack-manifest <json> \\
    --substrate-truth <json> \\
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
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--substrate-pack-manifest':
        parsed.substratePackManifest = nextValue();
        break;
      case '--substrate-truth':
        parsed.substrateTruth = nextValue();
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

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
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

function assertAllowedKeys(object, allowedKeys, label) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function parseTargetProfile(value) {
  const text = requireString(value, 'target_profile');
  if (!SUPPORTED_TARGET_PROFILE_SET.has(text)) {
    fail(`--substrate-pack-check only accepts ${SUPPORTED_TARGET_PROFILE_VALUES.join(' or ')}`);
  }
  const [targetCluster, substrateSource, distribution] = text.split('/');
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function assertSafeRelativePackPath(value, label) {
  const text = requireString(value, label);
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

function assertMaterialString(value, label) {
  const text = requireString(value, label);
  if (DIGEST_RE.test(text)) {
    return { kind: 'digest' };
  }
  assertSafeRelativePackPath(text, label);
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

function assertNoUnsafeManifestPayload(value, label) {
  const issues = scanManifestPayload(value, label);
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function validateMaterialSection(value, label) {
  if (typeof value === 'string') {
    assertMaterialString(value, label);
    return 1;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      fail(`${label} must not be empty`);
    }
    return value.reduce(
      (count, item, index) => count + validateMaterialSection(item, `${label}[${index}]`),
      0
    );
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(value);
    if (entries.length === 0) {
      fail(`${label} must not be empty`);
    }
    return entries.reduce(
      (count, [key, nested]) => count + validateMaterialSection(nested, `${label}.${key}`),
      0
    );
  }
  fail(`${label} must contain sha256 digests or safe relative substrate pack paths`);
}

function imageDigestSuffix(image, label) {
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

function validateImages(value) {
  const images = requireObject(value, 'substrate_pack_manifest.images');
  for (const required of REQUIRED_SUBSTRATE_IMAGES) {
    if (!Object.prototype.hasOwnProperty.call(images, required)) {
      fail(`substrate_pack_manifest.images missing required image: ${required}`);
    }
  }
  const imageIds = Object.keys(images);
  if (imageIds.length === 0) {
    fail('substrate_pack_manifest.images must not be empty');
  }
  const seenRefs = new Set();
  const seenDigests = new Set();
  for (const [id, image] of Object.entries(images)) {
    const label = `substrate_pack_manifest.images.${id}`;
    const ref = requireString(image, label);
    const digest = imageDigestSuffix(ref, label);
    if (seenRefs.has(ref)) {
      fail(`substrate_pack_manifest.images contains duplicate image: ${id}`);
    }
    if (seenDigests.has(digest)) {
      fail(`substrate_pack_manifest.images contains duplicate digest: ${id}`);
    }
    seenRefs.add(ref);
    seenDigests.add(digest);
  }
  return {
    image_count: imageIds.length,
    required_images: [...REQUIRED_SUBSTRATE_IMAGES]
  };
}

function validateManifest(value, targetProfile) {
  assertNoUnsafeManifestPayload(value, 'substrate_pack_manifest');
  const manifest = requireObject(value, 'substrate_pack_manifest');
  assertAllowedKeys(manifest, MANIFEST_FIELDS, 'substrate_pack_manifest');
  assertStringEquals(
    manifest.schema_version,
    MANIFEST_SCHEMA,
    'substrate_pack_manifest.schema_version'
  );
  requirePlainSemver(
    manifest.release_kit_version,
    'substrate_pack_manifest.release_kit_version',
    fail
  );
  assertStringEquals(manifest.installed_by, INSTALLED_BY, 'substrate_pack_manifest.installed_by');
  assertStringEquals(
    manifest.target_profile,
    targetProfile.value,
    'substrate_pack_manifest.target_profile'
  );

  const imageSummary = validateImages(manifest.images);
  const materialSections = {};
  for (const section of MATERIAL_SECTIONS) {
    materialSections[section] = {
      entries_count: validateMaterialSection(
        manifest[section],
        `substrate_pack_manifest.${section}`
      )
    };
  }

  return {
    manifest,
    manifestSummary: {
      schema_version: MANIFEST_SCHEMA,
      installed_by: INSTALLED_BY,
      release_kit_version: manifest.release_kit_version,
      ...imageSummary,
      material_sections: materialSections
    }
  };
}

function buildReport({
  targetProfile,
  manifestInputDigest,
  substrateInputDigest,
  manifestSummary,
  serviceSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    target_profile: targetProfile,
    inputs: {
      substrate_pack_manifest: {
        schema_version: MANIFEST_SCHEMA,
        input_sha256: manifestInputDigest
      },
      substrate_truth: {
        schema_version: SUBSTRATE_CONNECTION_SCHEMA,
        input_sha256: substrateInputDigest
      }
    },
    summary: {
      installed_by: manifestSummary.installed_by,
      release_kit_version: manifestSummary.release_kit_version,
      required_images_count: manifestSummary.required_images.length,
      image_count: manifestSummary.image_count,
      material_sections: manifestSummary.material_sections,
      substrate_services_count: serviceSummary.services_count,
      substrate_services: serviceSummary.services
    }
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(path.join(outputDir, REPORT_FILE), `${JSON.stringify(report, null, 2)}\n`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(args.outputDir);
  const targetProfile = parseTargetProfile(args.targetProfile);
  const manifestInput = await readJson(args.substratePackManifest, 'substrate pack manifest');
  const substrateInput = await readJson(args.substrateTruth, 'substrate truth');

  const { manifestSummary } = validateManifest(manifestInput.value, targetProfile);
  assertNoUnsafeSubstratePayload(
    substrateInput.value,
    'substrate_truth',
    substrateInput.raw
  );
  const { serviceSummary } = validateSubstrateConnectionTruth(
    substrateInput.value,
    targetProfile,
    {
      label: 'substrate_truth',
      requiredSubstrateSource: 'kit_installed'
    }
  );

  await writeReport(
    args.outputDir,
    buildReport({
      targetProfile,
      manifestInputDigest: manifestInput.inputDigest,
      substrateInputDigest: substrateInput.inputDigest,
      manifestSummary,
      serviceSummary
    })
  );
  console.log('PASS: substrate pack manifest and truth accepted');
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
