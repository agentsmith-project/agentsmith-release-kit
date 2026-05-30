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
  'outputDir'
];
const EXTERNAL_AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const KIT_AIRGAP_TARGET_PROFILE = 'existing_kubernetes/kit_installed/airgap';
const AIRGAP_TARGET_PROFILE_VALUES = [
  EXTERNAL_AIRGAP_TARGET_PROFILE,
  KIT_AIRGAP_TARGET_PROFILE
];
const AIRGAP_TARGET_PROFILE_SET = new Set(AIRGAP_TARGET_PROFILE_VALUES);
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const BUNDLE_CHECK_REPORT_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const BUNDLE_CHECK_REPORT_SCOPE = 'airgap_bundle_manifest_check_only';
const REPORT_SCHEMA = 'agentsmith.airgap-image-archive-check-report/v1';
const REPORT_SCOPE = 'airgap_image_archive_content_check_only';
const REPORT_FILE = 'airgap-image-archive-check-report.json';
const SELF_CHECK_DIR = 'airgap-bundle-check';
const SELF_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const PROBE_TIMEOUT_MS = 5000;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const FORBIDDEN_PROBE_BASENAMES = new Set([
  'docker',
  'skopeo',
  'oras',
  'kubectl',
  'curl',
  'wget'
]);
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
  node scripts/verify-airgap-image-archive-check.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --image-map <json> \\
    --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap \\
    --bundle-root <dir> \\
    --bundle-manifest <json> \\
    --archive-probe <executable> \\
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

async function digestFile(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return digestBuffer(buffer);
}

async function removeManagedReports(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, SELF_CHECK_DIR), { recursive: true, force: true });
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
  const tuple = text.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!AIRGAP_TARGET_PROFILE_SET.has(normalized)) {
    fail(`--airgap-image-archive-check only accepts ${AIRGAP_TARGET_PROFILE_VALUES.join(' or ')}`);
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function assertTargetProfileObject(value, label, targetProfile) {
  const profile = requireObject(value, label);
  assertAllowedKeys(profile, TARGET_PROFILE_KEYS, label);
  assertStringEquals(profile.value, targetProfile.value, `${label}.value`);
  assertStringEquals(profile.target_cluster, targetProfile.target_cluster, `${label}.target_cluster`);
  assertStringEquals(profile.substrate_source, targetProfile.substrate_source, `${label}.substrate_source`);
  assertStringEquals(profile.distribution, targetProfile.distribution, `${label}.distribution`);
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

async function canonicalProbeExecutable(input) {
  const value = requireString(input, 'archive_probe');
  rejectUriOrWindowsPath(value, 'archive_probe');
  const requestedBasename = path.basename(value);
  if (FORBIDDEN_PROBE_BASENAMES.has(requestedBasename)) {
    fail('archive_probe must not be docker, skopeo, oras, kubectl, curl, or wget');
  }

  const resolved = path.resolve(value);
  let stat;
  try {
    stat = await fs.lstat(resolved);
  } catch (error) {
    fail(`cannot read archive_probe: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('archive_probe must not be a symlink');
  }
  if (!stat.isFile()) {
    fail('archive_probe must point to a file');
  }
  if ((stat.mode & 0o111) === 0) {
    fail('archive_probe must be executable');
  }

  let realPath;
  try {
    realPath = await fs.realpath(resolved);
  } catch (error) {
    fail(`cannot resolve archive_probe: ${error.message}`);
  }
  if (FORBIDDEN_PROBE_BASENAMES.has(path.basename(realPath))) {
    fail('archive_probe must not be docker, skopeo, oras, kubectl, curl, or wget');
  }
  return realPath;
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

function assertCheckReport(checkReport, targetProfile) {
  assertStringEquals(checkReport.schema, BUNDLE_CHECK_REPORT_SCHEMA, 'airgap_bundle_check_report.schema');
  assertStringEquals(checkReport.scope, BUNDLE_CHECK_REPORT_SCOPE, 'airgap_bundle_check_report.scope');
  requireBooleanFalse(checkReport.readiness, 'airgap_bundle_check_report.readiness');
  assertStringEquals(checkReport.status, 'pass', 'airgap_bundle_check_report.status');
  requireString(checkReport.release_id, 'airgap_bundle_check_report.release_id');
  requireString(checkReport.git_sha, 'airgap_bundle_check_report.git_sha');
  assertTargetProfileObject(
    checkReport.target_profile,
    'airgap_bundle_check_report.target_profile',
    targetProfile
  );
  if (checkReport.target_profile.value !== targetProfile.value) {
    fail('airgap_bundle_check_report.target_profile must match target_profile');
  }
  requireInteger(
    checkReport.image_artifact_declaration_count,
    'airgap_bundle_check_report.image_artifact_declaration_count'
  );

  return {
    releaseId: checkReport.release_id,
    gitSha: checkReport.git_sha,
    artifacts: requireObject(checkReport.artifacts, 'airgap_bundle_check_report.artifacts')
  };
}

function readDigestSummary(artifacts, checkReportInputDigest) {
  const releaseContract = requireObject(
    artifacts.release_contract,
    'airgap_bundle_check_report.artifacts.release_contract'
  );
  const deployTemplatePackage = requireObject(
    artifacts.deploy_template_package,
    'airgap_bundle_check_report.artifacts.deploy_template_package'
  );
  const deployTemplateArchive = requireObject(
    artifacts.deploy_template_archive,
    'airgap_bundle_check_report.artifacts.deploy_template_archive'
  );
  const imageMap = requireObject(
    artifacts.image_map,
    'airgap_bundle_check_report.artifacts.image_map'
  );
  const bundleManifest = requireObject(
    artifacts.bundle_manifest,
    'airgap_bundle_check_report.artifacts.bundle_manifest'
  );

  return {
    release_contract_input_sha256: requireDigest(
      releaseContract.input_sha256,
      'airgap_bundle_check_report.artifacts.release_contract.input_sha256'
    ),
    deploy_template_package_input_sha256: requireDigest(
      deployTemplatePackage.input_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_package.input_sha256'
    ),
    deploy_template_archive_input_sha256: requireDigest(
      deployTemplateArchive.input_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_archive.input_sha256'
    ),
    image_map_input_sha256: requireDigest(
      imageMap.input_sha256,
      'airgap_bundle_check_report.artifacts.image_map.input_sha256'
    ),
    bundle_manifest_input_sha256: requireDigest(
      bundleManifest.input_sha256,
      'airgap_bundle_check_report.artifacts.bundle_manifest.input_sha256'
    ),
    airgap_bundle_check_report_input_sha256: checkReportInputDigest
  };
}

function assertImageMap(imageMap, targetProfile) {
  assertStringEquals(imageMap.schema, IMAGE_MAP_SCHEMA, 'image_map.schema');
  assertStringEquals(imageMap.scope, 'image_map_only', 'image_map.scope');
  requireBooleanFalse(imageMap.readiness, 'image_map.readiness');
  assertStringEquals(imageMap.status, 'pass', 'image_map.status');
  assertTargetProfileObject(imageMap.target_profile, 'image_map.target_profile', targetProfile);
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

    const sourceImage = requireString(mapping.source_image, `${label}.source_image`);
    const sourceDigest = requireDigest(mapping.source_digest, `${label}.source_digest`);
    const sourceImageDigest = imageDigestSuffix(sourceImage, `${label}.source_image`);
    if (sourceImageDigest !== sourceDigest) {
      fail(`${label}.source_image must be digest-pinned with source_digest`);
    }

    const targetImage = requireString(mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${label}.target_digest`);
    if (targetDigest !== sourceDigest) {
      fail(`${label}.target_digest must match source_digest`);
    }
    const targetImageDigest = imageDigestSuffix(targetImage, `${label}.target_image`);
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
    assertStringEquals(mapping.action, 'mirror_required', `${label}.action`);

    targetDigests.add(targetDigest);
    mappingsById.set(id, {
      id,
      source_image: sourceImage,
      source_digest: sourceDigest,
      target_image: targetImage,
      target_digest: targetDigest
    });
  }

  return {
    imageCount: mappings.length,
    mappingsById,
    uniqueTargetDigestCount: targetDigests.size
  };
}

function parseProbeDigestOutput(stdout, stderr, id) {
  if (stderr.trim() !== '') {
    fail(`archive probe must not write stderr for image id: ${id}`);
  }

  const output = stdout.trim();
  const matches = output.match(/sha256:[0-9a-f]{64}/g) || [];
  if (matches.length !== 1 || output !== matches[0]) {
    fail(`archive probe output must be exactly one sha256 digest for image id: ${id}`);
  }
  return matches[0];
}

function runArchiveProbe({ archiveProbe, archivePath, id }) {
  const result = spawnSync(archiveProbe, [archivePath], {
    cwd: path.dirname(archivePath),
    env: {
      ...process.env,
      AGENTSMITH_IMAGE_ARCHIVE_PATH: archivePath,
      AGENTSMITH_IMAGE_ID: id
    },
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
    timeout: PROBE_TIMEOUT_MS
  });

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      fail(`archive probe timed out for image id: ${id}`);
    }
    fail(`archive probe could not be executed for image id: ${id}`);
  }
  if (result.signal) {
    fail(`archive probe was interrupted for image id: ${id}`);
  }
  if (result.status !== 0) {
    fail(`archive probe returned non-zero status for image id: ${id}`);
  }

  return parseProbeDigestOutput(result.stdout || '', result.stderr || '', id);
}

async function assertImageArtifactDeclarations({
  declarations,
  bundleRoot,
  imageMapSummary,
  archiveProbe
}) {
  const items = requireArray(
    declarations,
    'bundle_manifest.image_artifact_declarations'
  );
  if (items.length !== imageMapSummary.mappingsById.size) {
    fail('bundle_manifest.image_artifact_declarations must match image_map.mappings length');
  }

  const seen = new Set();
  const imageSummaries = [];
  const archiveDigests = new Set();
  const probeDigests = new Set();
  for (const [index, value] of items.entries()) {
    const label = `bundle_manifest.image_artifact_declarations[${index}]`;
    const declaration = requireObject(value, label);
    const id = requireString(declaration.id, `${label}.id`);
    if (seen.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations contains duplicate id: ${id}`);
    }
    seen.add(id);

    const mapping = imageMapSummary.mappingsById.get(id);
    if (!mapping) {
      fail(`${label}.id must exist in image_map.mappings`);
    }
    assertStringEquals(declaration.source_image, mapping.source_image, `${label}.source_image`);
    const sourceDigest = requireDigest(declaration.source_digest, `${label}.source_digest`);
    if (sourceDigest !== mapping.source_digest) {
      fail(`${label}.source_digest must match image_map mapping`);
    }
    assertStringEquals(declaration.target_image, mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(declaration.target_digest, `${label}.target_digest`);
    if (targetDigest !== mapping.target_digest) {
      fail(`${label}.target_digest must match image_map mapping`);
    }
    assertStringEquals(declaration.artifact_format, 'oci_layout_tar', `${label}.artifact_format`);

    const archiveSha256 = requireDigest(declaration.sha256, `${label}.sha256`);
    const archivePath = await resolveBundleFile(bundleRoot, declaration.path, `${label}.path`);
    const actualArchiveSha256 = await digestFile(archivePath, `${label}.path`);
    if (actualArchiveSha256 !== archiveSha256) {
      fail(`${label}.sha256 must match image artifact file sha256`);
    }

    const probeDigest = runArchiveProbe({ archiveProbe, archivePath, id });
    if (probeDigest !== targetDigest) {
      fail(`${label} archive probe digest must match image_map target_digest`);
    }

    archiveDigests.add(archiveSha256);
    probeDigests.add(probeDigest);
    imageSummaries.push({
      id,
      source_digest: sourceDigest,
      target_digest: targetDigest,
      archive_sha256: archiveSha256,
      probe_digest: probeDigest
    });
  }

  for (const id of imageMapSummary.mappingsById.keys()) {
    if (!seen.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations is missing ${id}`);
    }
  }

  imageSummaries.sort((left, right) => left.id.localeCompare(right.id));
  return {
    images: imageSummaries,
    archiveCount: imageSummaries.length,
    uniqueArchiveSha256Count: archiveDigests.size,
    uniqueProbeDigestCount: probeDigests.size
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-image-archive-check.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

function buildReport({
  checkSummary,
  targetProfile,
  digestSummary,
  imageMapSummary,
  archiveSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: checkSummary.releaseId,
    git_sha: checkSummary.gitSha,
    target_profile: targetProfile,
    archive_count: archiveSummary.archiveCount,
    image_ids: archiveSummary.images.map((image) => image.id),
    digest_summary: digestSummary,
    archive_digest_summary: {
      archive_count: archiveSummary.archiveCount,
      archive_sha256_count: archiveSummary.archiveCount,
      unique_archive_sha256_count: archiveSummary.uniqueArchiveSha256Count,
      probe_digest_count: archiveSummary.archiveCount,
      unique_probe_digest_count: archiveSummary.uniqueProbeDigestCount,
      image_map_target_digest_count: imageMapSummary.imageCount,
      unique_image_map_target_digest_count: imageMapSummary.uniqueTargetDigestCount
    },
    images: archiveSummary.images
  };
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
    const archiveProbe = await canonicalProbeExecutable(args.archiveProbe);
    const bundleRoot = await canonicalBundleRoot(args.bundleRoot);
    const checkOutputDir = path.join(args.outputDir, SELF_CHECK_DIR);

    runNodeScript(
      'verify-airgap-bundle-check.mjs',
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
        '--output-dir',
        checkOutputDir
      ],
      'airgap bundle self-check'
    );

    const checkReportInput = await readJson(
      path.join(checkOutputDir, SELF_CHECK_REPORT_FILE),
      'airgap bundle check report'
    );
    const imageMapInput = await readJson(args.imageMap, 'image map');
    const bundleManifestInput = await readJson(args.bundleManifest, 'bundle manifest');

    const checkReport = requireObject(
      checkReportInput.value,
      'airgap_bundle_check_report'
    );
    const checkSummary = assertCheckReport(checkReport, targetProfile);
    const imageMapSummary = assertImageMap(
      requireObject(imageMapInput.value, 'image_map'),
      targetProfile
    );
    const bundleManifest = requireObject(bundleManifestInput.value, 'bundle_manifest');
    assertTargetProfileObject(
      bundleManifest.target_profile,
      'bundle_manifest.target_profile',
      targetProfile
    );
    const archiveSummary = await assertImageArtifactDeclarations({
      declarations: bundleManifest.image_artifact_declarations,
      bundleRoot,
      imageMapSummary,
      archiveProbe
    });

    await writeReport(
      args.outputDir,
      buildReport({
        checkSummary,
        targetProfile,
        digestSummary: readDigestSummary(
          checkSummary.artifacts,
          checkReportInput.inputDigest
        ),
        imageMapSummary,
        archiveSummary
      })
    );

    console.log('PASS: airgap image archive materiality check accepted readiness=false');
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
