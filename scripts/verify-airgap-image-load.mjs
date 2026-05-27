#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'imageMap',
  'targetProfile',
  'bundleRoot',
  'bundleManifest',
  'archiveProbe',
  'imageLoader',
  'outputDir'
];
const AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const ARCHIVE_CHECK_REPORT_SCHEMA = 'agentsmith.airgap-image-archive-check-report/v1';
const ARCHIVE_CHECK_REPORT_SCOPE = 'airgap_image_archive_content_check_only';
const REPORT_SCHEMA = 'agentsmith.airgap-image-load-report/v1';
const REPORT_SCOPE = 'airgap_image_load_only';
const REPORT_FILE = 'airgap-image-load-report.json';
const ARCHIVE_CHECK_DIR = 'airgap-image-archive-check';
const ARCHIVE_CHECK_REPORT_FILE = 'airgap-image-archive-check-report.json';
const LOADER_TIMEOUT_MS = 30000;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const TARGET_PROFILE_KEYS = new Set([
  'value',
  'target_cluster',
  'substrate_source',
  'distribution'
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
  node scripts/verify-airgap-image-load.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --image-map <json> \\
    --target-profile existing_kubernetes/external_declared/airgap \\
    --bundle-root <dir> \\
    --bundle-manifest <json> \\
    --archive-probe <executable> \\
    --image-loader <executable> \\
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
      case '--archive-probe':
        parsed.archiveProbe = nextValue();
        break;
      case '--image-loader':
        parsed.imageLoader = nextValue();
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

function findOutputDirArg(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (value && value.trim() !== '' && !value.startsWith('--')) {
      return value;
    }
  }
  return undefined;
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

async function removeManagedReports(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, ARCHIVE_CHECK_DIR), {
    recursive: true,
    force: true
  });
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

function requireBooleanTrue(value, label) {
  if (value !== true) {
    fail(`${label} must be true`);
  }
}

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
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
  if (value !== AIRGAP_TARGET_PROFILE) {
    fail(`--airgap-image-load only accepts ${AIRGAP_TARGET_PROFILE}`);
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
}

function rejectUriOrWindowsPath(value, label) {
  if (value.trim() !== value) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be a local POSIX path, not a URI`);
  }
  if (WINDOWS_DRIVE_RE.test(value)) {
    fail(`${label} must be a local POSIX path`);
  }
  if (value.includes('\\')) {
    fail(`${label} must use POSIX path separators`);
  }
}

async function canonicalExecutable(input, label) {
  const value = requireString(input, label);
  rejectUriOrWindowsPath(value, label);
  const resolved = path.resolve(value);

  let stat;
  try {
    stat = await fs.lstat(resolved);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a file`);
  }
  if ((stat.mode & 0o111) === 0) {
    fail(`${label} must be executable`);
  }

  try {
    return await fs.realpath(resolved);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

async function canonicalBundleRoot(input) {
  const requested = path.resolve(input);
  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read bundle root: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('bundle root must not be a symlink');
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
  return digest;
}

function runNodeScript(scriptName, args, label) {
  const result = spawnSync(process.execPath, [path.join(SCRIPT_DIR, scriptName), ...args], {
    cwd: ROOT_DIR,
    stdio: 'inherit'
  });
  if (result.error) {
    fail(`${label} failed to start: ${result.error.message}`);
  }
  if (result.status !== 0) {
    fail(`${label} failed`);
  }
}

function assertArchiveCheckReport(report, targetProfile) {
  assertStringEquals(
    report.schema,
    ARCHIVE_CHECK_REPORT_SCHEMA,
    'airgap_image_archive_check_report.schema'
  );
  assertStringEquals(
    report.scope,
    ARCHIVE_CHECK_REPORT_SCOPE,
    'airgap_image_archive_check_report.scope'
  );
  requireBooleanFalse(report.readiness, 'airgap_image_archive_check_report.readiness');
  assertStringEquals(report.status, 'pass', 'airgap_image_archive_check_report.status');
  requireString(report.release_id, 'airgap_image_archive_check_report.release_id');
  requireString(report.git_sha, 'airgap_image_archive_check_report.git_sha');
  assertTargetProfileObject(
    report.target_profile,
    'airgap_image_archive_check_report.target_profile'
  );
  if (report.target_profile.value !== targetProfile.value) {
    fail('airgap_image_archive_check_report.target_profile must match target_profile');
  }

  const imageIds = requireArray(report.image_ids, 'airgap_image_archive_check_report.image_ids');
  const images = requireArray(report.images, 'airgap_image_archive_check_report.images');
  const archiveCount = requireInteger(
    report.archive_count,
    'airgap_image_archive_check_report.archive_count'
  );
  if (imageIds.length !== archiveCount || images.length !== archiveCount) {
    fail('airgap_image_archive_check_report image counts must match archive_count');
  }

  const imageIdsSet = new Set(imageIds);
  if (imageIdsSet.size !== imageIds.length) {
    fail('airgap_image_archive_check_report.image_ids must be unique');
  }

  const imageSummariesById = new Map();
  const targetDigests = new Set();
  for (const [index, value] of images.entries()) {
    const label = `airgap_image_archive_check_report.images[${index}]`;
    const image = requireObject(value, label);
    const id = requireString(image.id, `${label}.id`);
    if (!imageIdsSet.has(id)) {
      fail(`${label}.id must be listed in image_ids`);
    }
    if (imageSummariesById.has(id)) {
      fail(`airgap_image_archive_check_report.images contains duplicate id: ${id}`);
    }
    const targetDigest = requireDigest(image.target_digest, `${label}.target_digest`);
    const archiveSha256 = requireDigest(image.archive_sha256, `${label}.archive_sha256`);
    const probeDigest = requireDigest(image.probe_digest, `${label}.probe_digest`);
    if (probeDigest !== targetDigest) {
      fail(`${label}.probe_digest must match target_digest`);
    }
    imageSummariesById.set(id, {
      id,
      target_digest: targetDigest,
      archive_sha256: archiveSha256,
      probe_digest: probeDigest
    });
    targetDigests.add(targetDigest);
  }

  const digestSummary = requireObject(
    report.digest_summary,
    'airgap_image_archive_check_report.digest_summary'
  );
  const archiveDigestSummary = requireObject(
    report.archive_digest_summary,
    'airgap_image_archive_check_report.archive_digest_summary'
  );

  return {
    releaseId: report.release_id,
    gitSha: report.git_sha,
    archiveCount,
    imageIds: [...imageIds].sort((left, right) => left.localeCompare(right)),
    imageSummariesById,
    uniqueTargetDigestCount: targetDigests.size,
    digestSummary,
    archiveDigestSummary
  };
}

function readDigestSummary(archiveCheckSummary, archiveCheckReportInputDigest) {
  const summary = {};
  for (const [key, value] of Object.entries(archiveCheckSummary.digestSummary)) {
    summary[key] = requireDigest(
      value,
      `airgap_image_archive_check_report.digest_summary.${key}`
    );
  }
  summary.airgap_image_archive_check_report_input_sha256 = archiveCheckReportInputDigest;
  return summary;
}

function assertImageMap(imageMap) {
  assertStringEquals(imageMap.schema, IMAGE_MAP_SCHEMA, 'image_map.schema');
  assertStringEquals(imageMap.scope, 'image_map_only', 'image_map.scope');
  requireBooleanFalse(imageMap.readiness, 'image_map.readiness');
  assertStringEquals(imageMap.status, 'pass', 'image_map.status');
  assertTargetProfileObject(imageMap.target_profile, 'image_map.target_profile');
  requireBooleanTrue(imageMap.mirror_required, 'image_map.mirror_required');
  requireString(imageMap.target_registry, 'image_map.target_registry');

  const mappings = requireArray(imageMap.mappings, 'image_map.mappings');
  if (mappings.length === 0) {
    fail('image_map.mappings must not be empty');
  }
  if (imageMap.image_count !== mappings.length) {
    fail('image_map.image_count must match image_map.mappings length');
  }

  const mappingsById = new Map();
  const targetDigests = new Set();
  for (const [index, value] of mappings.entries()) {
    const label = `image_map.mappings[${index}]`;
    const mapping = requireObject(value, label);
    const id = requireString(mapping.id, `${label}.id`);
    if (mappingsById.has(id)) {
      fail(`image_map.mappings contains duplicate id: ${id}`);
    }
    const targetImage = requireString(mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${label}.target_digest`);
    const targetImageDigest = imageDigestSuffix(targetImage, `${label}.target_image`);
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
    assertStringEquals(mapping.action, 'mirror_required', `${label}.action`);
    mappingsById.set(id, {
      id,
      target_image: targetImage,
      target_digest: targetDigest
    });
    targetDigests.add(targetDigest);
  }

  return {
    imageCount: mappings.length,
    mappingsById,
    uniqueTargetDigestCount: targetDigests.size
  };
}

async function readImageLoadInputs({
  bundleManifest,
  bundleRoot,
  archiveCheckSummary,
  imageMapSummary
}) {
  const manifest = requireObject(bundleManifest, 'bundle_manifest');
  assertTargetProfileObject(manifest.target_profile, 'bundle_manifest.target_profile');
  const declarations = requireArray(
    manifest.image_artifact_declarations,
    'bundle_manifest.image_artifact_declarations'
  );
  if (declarations.length !== archiveCheckSummary.archiveCount) {
    fail('bundle_manifest.image_artifact_declarations must match archive check image count');
  }

  const inputsById = new Map();
  for (const [index, value] of declarations.entries()) {
    const label = `bundle_manifest.image_artifact_declarations[${index}]`;
    const declaration = requireObject(value, label);
    const id = requireString(declaration.id, `${label}.id`);
    if (inputsById.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations contains duplicate id: ${id}`);
    }

    const archiveSummary = archiveCheckSummary.imageSummariesById.get(id);
    if (!archiveSummary) {
      fail(`${label}.id must exist in airgap image archive check report`);
    }
    const mapping = imageMapSummary.mappingsById.get(id);
    if (!mapping) {
      fail(`${label}.id must exist in image_map.mappings`);
    }

    assertStringEquals(declaration.target_image, mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(declaration.target_digest, `${label}.target_digest`);
    if (targetDigest !== mapping.target_digest) {
      fail(`${label}.target_digest must match image_map mapping`);
    }
    if (targetDigest !== archiveSummary.target_digest) {
      fail(`${label}.target_digest must match archive check target_digest`);
    }
    assertStringEquals(declaration.artifact_format, 'oci_layout_tar', `${label}.artifact_format`);
    const archiveSha256 = requireDigest(declaration.sha256, `${label}.sha256`);
    if (archiveSha256 !== archiveSummary.archive_sha256) {
      fail(`${label}.sha256 must match archive check archive_sha256`);
    }

    inputsById.set(id, {
      id,
      archivePath: await resolveBundleFile(bundleRoot, declaration.path, `${label}.path`),
      targetImage: mapping.target_image,
      targetDigest,
      archiveSha256
    });
  }

  for (const id of archiveCheckSummary.imageSummariesById.keys()) {
    if (!inputsById.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations is missing ${id}`);
    }
  }

  return archiveCheckSummary.imageIds.map((id) => inputsById.get(id));
}

function parseLoaderDigestOutput(stdout, stderr, id) {
  if (stderr.trim() !== '') {
    fail(`image loader must not write stderr for image id: ${id}`);
  }

  const output = stdout.trim();
  const matches = output.match(/sha256:[0-9a-f]{64}/g) || [];
  if (matches.length !== 1 || output !== matches[0]) {
    fail(`image loader output must be exactly one sha256 digest for image id: ${id}`);
  }
  return matches[0];
}

function runImageLoader({ imageLoader, image }) {
  const result = spawnSync(
    imageLoader,
    [image.archivePath, image.targetImage, image.targetDigest],
    {
      cwd: path.dirname(image.archivePath),
      env: {
        ...process.env,
        AGENTSMITH_IMAGE_ARCHIVE_PATH: image.archivePath,
        AGENTSMITH_IMAGE_ID: image.id,
        AGENTSMITH_TARGET_IMAGE: image.targetImage,
        AGENTSMITH_TARGET_DIGEST: image.targetDigest
      },
      encoding: 'utf8',
      maxBuffer: 1024 * 1024,
      timeout: LOADER_TIMEOUT_MS
    }
  );

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      fail(`image loader timed out for image id: ${image.id}`);
    }
    fail(`image loader could not be executed for image id: ${image.id}`);
  }
  if (result.signal) {
    fail(`image loader was interrupted for image id: ${image.id}`);
  }
  if (result.status !== 0) {
    fail(`image loader returned non-zero status for image id: ${image.id}`);
  }

  const loaderDigest = parseLoaderDigestOutput(
    result.stdout || '',
    result.stderr || '',
    image.id
  );
  if (loaderDigest !== image.targetDigest) {
    fail(`image loader digest must match target_digest for image id: ${image.id}`);
  }
  return loaderDigest;
}

function runImageLoads({ imageLoader, images }) {
  const loaderDigests = new Set();
  const loadedImages = [];

  for (const image of images) {
    const loaderDigest = runImageLoader({ imageLoader, image });
    loaderDigests.add(loaderDigest);
    loadedImages.push({
      id: image.id,
      target_digest: image.targetDigest,
      archive_sha256: image.archiveSha256,
      loader_digest: loaderDigest
    });
  }

  return {
    images: loadedImages,
    loadCount: loadedImages.length,
    uniqueLoaderDigestCount: loaderDigests.size
  };
}

function buildReport({
  archiveCheckSummary,
  archiveCheckReportInputDigest,
  targetProfile,
  imageMapSummary,
  loadSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: archiveCheckSummary.releaseId,
    git_sha: archiveCheckSummary.gitSha,
    target_profile: targetProfile,
    load_count: loadSummary.loadCount,
    image_ids: loadSummary.images.map((image) => image.id),
    digest_summary: readDigestSummary(
      archiveCheckSummary,
      archiveCheckReportInputDigest
    ),
    image_load_summary: {
      load_count: loadSummary.loadCount,
      archive_count: archiveCheckSummary.archiveCount,
      archive_sha256_count: archiveCheckSummary.archiveCount,
      loader_digest_count: loadSummary.loadCount,
      unique_loader_digest_count: loadSummary.uniqueLoaderDigestCount,
      image_map_target_digest_count: imageMapSummary.imageCount,
      unique_image_map_target_digest_count: imageMapSummary.uniqueTargetDigestCount
    },
    images: loadSummary.images
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-image-load.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  const argv = process.argv.slice(2);
  const startupOutputDir = findOutputDirArg(argv);
  if (startupOutputDir) {
    await removeManagedReports(startupOutputDir);
  }

  const args = parseArgs(argv);
  if (args.help) {
    console.log(usage());
    return;
  }

  if (!startupOutputDir) {
    await removeManagedReports(args.outputDir);
  }

  try {
    const targetProfile = parseTargetProfile(args.targetProfile);
    await canonicalExecutable(args.archiveProbe, 'archive_probe');
    const imageLoader = await canonicalExecutable(args.imageLoader, 'image_loader');
    const bundleRoot = await canonicalBundleRoot(args.bundleRoot);
    const archiveCheckOutputDir = path.join(args.outputDir, ARCHIVE_CHECK_DIR);

    runNodeScript(
      'verify-airgap-image-archive-check.mjs',
      [
        '--release-contract',
        args.releaseContract,
        '--deploy-template-package',
        args.deployTemplatePackage,
        '--archive',
        args.archive,
        '--image-map',
        args.imageMap,
        '--target-profile',
        args.targetProfile,
        '--bundle-root',
        args.bundleRoot,
        '--bundle-manifest',
        args.bundleManifest,
        '--archive-probe',
        args.archiveProbe,
        '--output-dir',
        archiveCheckOutputDir
      ],
      'airgap image archive self-check'
    );

    const archiveCheckReportInput = await readJson(
      path.join(archiveCheckOutputDir, ARCHIVE_CHECK_REPORT_FILE),
      'airgap image archive check report'
    );
    const imageMapInput = await readJson(args.imageMap, 'image map');
    const bundleManifestInput = await readJson(args.bundleManifest, 'bundle manifest');
    const archiveCheckReport = requireObject(
      archiveCheckReportInput.value,
      'airgap_image_archive_check_report'
    );
    const archiveCheckSummary = assertArchiveCheckReport(
      archiveCheckReport,
      targetProfile
    );
    const imageMapSummary = assertImageMap(
      requireObject(imageMapInput.value, 'image_map')
    );
    const imageLoadInputs = await readImageLoadInputs({
      bundleManifest: bundleManifestInput.value,
      bundleRoot,
      archiveCheckSummary,
      imageMapSummary
    });
    const loadSummary = runImageLoads({
      imageLoader,
      images: imageLoadInputs
    });

    await writeReport(
      args.outputDir,
      buildReport({
        archiveCheckSummary,
        archiveCheckReportInputDigest: archiveCheckReportInput.inputDigest,
        targetProfile,
        imageMapSummary,
        loadSummary
      })
    );

    console.log('PASS: airgap image load diagnostic accepted readiness=false');
  } catch (error) {
    if (args && args.outputDir) {
      await removeManagedReports(args.outputDir);
    }
    throw error;
  }
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
