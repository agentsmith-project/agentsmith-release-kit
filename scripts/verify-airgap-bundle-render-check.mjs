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
  'renderValues',
  'substrateTruth',
  'outputDir'
];
const AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const REPORT_SCHEMA = 'agentsmith.airgap-bundle-render-check-report/v1';
const REPORT_SCOPE = 'airgap_bundle_render_check_only';
const REPORT_FILE = 'airgap-bundle-render-check-report.json';
const BUNDLE_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const RENDER_REPORT_FILE = 'manifest-render-report.json';
const RENDER_CHECK_REPORT_FILE = 'render-report.json';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i;
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /\bBearer\b/i,
  /\b(?:password|token|secret|client_secret)\b/i,
  /\b(?:password|token|secret|client_secret)\s*[:=]\s*["']?[^"'\s]{8,}/i
];
const TARGET_PROFILE_KEYS = new Set([
  'value',
  'target_cluster',
  'substrate_source',
  'distribution'
]);
const COMPONENT_KINDS = new Set([
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'image_map'
]);
const COMPONENT_ARG_BY_KIND = {
  release_contract: 'releaseContract',
  deploy_template_package: 'deployTemplatePackage',
  deploy_template_archive: 'archive',
  image_map: 'imageMap'
};

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
  node scripts/verify-airgap-bundle-render-check.mjs \\
    --release-contract <bundle-local-json> \\
    --deploy-template-package <bundle-local-json> \\
    --archive <bundle-local-tgz> \\
    --image-map <bundle-local-json> \\
    --target-profile existing_kubernetes/external_declared/airgap \\
    --bundle-root <dir> \\
    --bundle-manifest <bundle-local-json> \\
    --render-values <bundle-local-json> \\
    --substrate-truth <bundle-local-json> \\
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
      case '--render-values':
        parsed.renderValues = nextValue();
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

async function digestFile(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return digestBuffer(buffer);
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
  await fs.rm(path.join(outputDir, 'airgap-bundle-check'), {
    recursive: true,
    force: true
  });
  await fs.rm(path.join(outputDir, 'render'), { recursive: true, force: true });
  await fs.rm(path.join(outputDir, 'render-check'), { recursive: true, force: true });
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
  return value;
}

function requireBooleanTrue(value, label) {
  if (value !== true) {
    fail(`${label} must be true`);
  }
  return value;
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

function rejectUriOrWindowsPath(value, label) {
  if (value.trim() !== value) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (value.startsWith('//')) {
    fail(`${label} must be a local POSIX path`);
  }
  if (WINDOWS_DRIVE_RE.test(value)) {
    fail(`${label} must be a local POSIX path`);
  }
  if (value.includes('\\')) {
    fail(`${label} must use POSIX path separators`);
  }
  if (URI_SCHEME_RE.test(value)) {
    fail(`${label} must be a local bundle file path, not a URI`);
  }
  if (value.split('/').includes('..')) {
    fail(`${label} must not contain parent path segments`);
  }
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function parseTargetProfile(value) {
  if (value !== AIRGAP_TARGET_PROFILE) {
    fail(`--airgap-bundle-render-check only accepts ${AIRGAP_TARGET_PROFILE}`);
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

function assertNonSensitiveTargetRegistry(value, label) {
  for (const segment of value.split('/')) {
    if (SECRET_VALUE_RE.some((pattern) => pattern.test(segment))) {
      fail(`${label} must not contain secret-looking content`);
    }
  }
}

async function canonicalBundleRoot(input) {
  const value = requireString(input, 'bundle_root');
  rejectUriOrWindowsPath(value, 'bundle_root');
  const resolved = path.resolve(value);

  let stat;
  try {
    stat = await fs.lstat(resolved);
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
    return await fs.realpath(resolved);
  } catch (error) {
    fail(`cannot resolve bundle root: ${error.message}`);
  }
}

async function assertNoSymlinkParents(file, label, bundleRoot) {
  const relative = path.relative(bundleRoot, file);
  const segments = relative.split(path.sep).filter(Boolean);
  let current = bundleRoot;

  for (const segment of segments.slice(0, -1)) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = await fs.lstat(current);
    } catch (error) {
      fail(`cannot read ${label} parent path: ${error.message}`);
    }
    if (stat.isSymbolicLink()) {
      fail(`${label} parent path must not contain symlinks`);
    }
    if (!stat.isDirectory()) {
      fail(`${label} parent path must be a directory`);
    }
  }
}

async function bundleLocalFile(input, label, bundleRoot) {
  const value = requireString(input, label);
  rejectUriOrWindowsPath(value, label);
  const requested = path.resolve(value);
  if (!isInsidePath(bundleRoot, requested)) {
    fail(`${label} must be inside bundle root`);
  }
  await assertNoSymlinkParents(requested, label, bundleRoot);

  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a bundle-local file`);
  }

  let realPath;
  try {
    realPath = await fs.realpath(requested);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
  if (!isInsidePath(bundleRoot, realPath)) {
    fail(`${label} must resolve inside bundle root`);
  }
  return realPath;
}

function validateSafeRelativeBundlePath(value, label) {
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

async function bundleManifestComponentPath(bundleRoot, component) {
  const relativePath = validateSafeRelativeBundlePath(
    component.path,
    `bundle_manifest.components.${component.kind}.path`
  );
  const candidate = path.resolve(bundleRoot, ...relativePath.split('/'));
  if (!isInsidePath(bundleRoot, candidate)) {
    fail(`bundle_manifest.components.${component.kind}.path must stay inside bundle root`);
  }
  await assertNoSymlinkParents(
    candidate,
    `bundle_manifest.components.${component.kind}.path`,
    bundleRoot
  );
  let stat;
  try {
    stat = await fs.lstat(candidate);
  } catch (error) {
    fail(`cannot read bundle_manifest.components.${component.kind}.path: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`bundle_manifest.components.${component.kind}.path must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`bundle_manifest.components.${component.kind}.path must point to a file`);
  }
  return fs.realpath(candidate);
}

async function assertBundleInputsMatchManifest({
  bundleManifest,
  bundleRoot,
  bundleLocalPaths
}) {
  const manifest = requireObject(bundleManifest, 'bundle_manifest');
  const components = requireArray(manifest.components, 'bundle_manifest.components');
  const seen = new Set();
  const summary = [];

  for (const [index, value] of components.entries()) {
    const label = `bundle_manifest.components[${index}]`;
    const component = requireObject(value, label);
    const kind = requireString(component.kind, `${label}.kind`);
    if (!COMPONENT_KINDS.has(kind)) {
      continue;
    }
    if (seen.has(kind)) {
      fail(`bundle_manifest.components contains duplicate kind: ${kind}`);
    }
    seen.add(kind);

    const componentRealPath = await bundleManifestComponentPath(bundleRoot, component);
    const argKey = COMPONENT_ARG_BY_KIND[kind];
    if (componentRealPath !== bundleLocalPaths[argKey]) {
      fail(`${toKebab(argKey)} must point at bundle_manifest.components ${kind} path`);
    }
    summary.push({
      kind,
      path: validateSafeRelativeBundlePath(component.path, `${label}.path`),
      sha256: requireDigest(component.sha256, `${label}.sha256`)
    });
  }

  for (const kind of COMPONENT_KINDS) {
    if (!seen.has(kind)) {
      fail(`bundle_manifest.components is missing ${kind}`);
    }
  }

  return summary.sort((left, right) => left.kind.localeCompare(right.kind));
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

function assertReportEnvelope(report, expected, label) {
  assertStringEquals(report.schema, expected.schema, `${label}.schema`);
  assertStringEquals(report.scope, expected.scope, `${label}.scope`);
  requireBooleanFalse(report.readiness, `${label}.readiness`);
  assertStringEquals(report.status, 'pass', `${label}.status`);
  assertStringEquals(report.release_id, expected.releaseId, `${label}.release_id`);
  assertStringEquals(report.git_sha, expected.gitSha, `${label}.git_sha`);
  assertTargetProfileObject(report.target_profile, `${label}.target_profile`);
}

function assertImageMap(imageMap, expectedReleaseId, expectedGitSha) {
  const report = requireObject(imageMap, 'image_map');
  assertStringEquals(report.schema, 'agentsmith.image-map/v1', 'image_map.schema');
  assertStringEquals(report.scope, 'image_map_only', 'image_map.scope');
  requireBooleanFalse(report.readiness, 'image_map.readiness');
  assertStringEquals(report.status, 'pass', 'image_map.status');
  assertStringEquals(report.release_id, expectedReleaseId, 'image_map.release_id');
  assertStringEquals(report.git_sha, expectedGitSha, 'image_map.git_sha');
  assertTargetProfileObject(report.target_profile, 'image_map.target_profile');
  requireBooleanTrue(report.mirror_required, 'image_map.mirror_required');
  const targetRegistry = requireString(report.target_registry, 'image_map.target_registry');
  assertNonSensitiveTargetRegistry(targetRegistry, 'image_map.target_registry');
  const mappings = requireArray(report.mappings, 'image_map.mappings');
  if (mappings.length === 0) {
    fail('image_map.mappings must not be empty');
  }
  if (requireInteger(report.image_count, 'image_map.image_count') !== mappings.length) {
    fail('image_map.image_count must match image_map.mappings length');
  }

  const targetImages = new Set();
  const sourceImages = new Set();
  const targetImagesById = new Map();
  for (const [index, value] of mappings.entries()) {
    const label = `image_map.mappings[${index}]`;
    const mapping = requireObject(value, label);
    const id = requireString(mapping.id, `${label}.id`);
    if (targetImagesById.has(id)) {
      fail(`image_map.mappings contains duplicate id: ${id}`);
    }
    const sourceImage = requireString(mapping.source_image, `${label}.source_image`);
    const targetImage = requireString(mapping.target_image, `${label}.target_image`);
    requireDigest(mapping.source_digest, `${label}.source_digest`);
    requireDigest(mapping.target_digest, `${label}.target_digest`);
    assertStringEquals(mapping.action, 'mirror_required', `${label}.action`);
    if (!targetImage.startsWith(`${targetRegistry}/`)) {
      fail(`${label}.target_image must be under image_map.target_registry`);
    }
    sourceImages.add(sourceImage);
    targetImages.add(targetImage);
    targetImagesById.set(id, targetImage);
  }

  return {
    targetRegistry,
    imageCount: mappings.length,
    targetImages,
    sourceImages,
    targetImagesById
  };
}

function reportImages(report, label) {
  const images = requireArray(report.images, `${label}.images`);
  if (images.length === 0) {
    fail(`${label}.images must not be empty`);
  }
  return images.map((value, index) => {
    const item = requireObject(value, `${label}.images[${index}]`);
    return requireString(item.image, `${label}.images[${index}].image`);
  });
}

function assertRenderedImagesUseTargets({ renderReport, renderCheckReport, imageMapSummary }) {
  const renderImages = reportImages(renderReport, 'manifest_render_report');
  const renderCheckImages = reportImages(renderCheckReport, 'render_check_report');
  const renderImageSet = new Set(renderImages);
  const renderCheckImageSet = new Set(renderCheckImages);

  if (renderImageSet.size !== renderCheckImageSet.size) {
    fail('manifest render report and render-check report image inventory counts must match');
  }
  for (const image of renderImageSet) {
    if (!renderCheckImageSet.has(image)) {
      fail('manifest render report and render-check report image inventories must match');
    }
  }

  for (const image of renderImageSet) {
    if (imageMapSummary.sourceImages.has(image)) {
      fail('rendered manifests must use image_map target_image refs, not source_image refs');
    }
    if (!imageMapSummary.targetImages.has(image)) {
      fail('rendered manifests must use image_map target_image refs');
    }
  }

  return {
    renderedImageCount: renderImageSet.size,
    renderedTargetImageCount: [...renderImageSet].filter((image) => {
      return imageMapSummary.targetImages.has(image);
    }).length
  };
}

function reportPath(...parts) {
  return parts.join('/');
}

function buildReport({
  checkReport,
  checkReportDigest,
  renderReport,
  renderReportDigest,
  renderCheckReport,
  renderCheckReportDigest,
  renderValuesDigest,
  substrateTruthDigest,
  imageMapSummary,
  bundleComponents,
  imageInventorySummary
}) {
  const checkArtifacts = requireObject(
    checkReport.artifacts,
    'airgap_bundle_check_report.artifacts'
  );
  const renderArtifacts = requireObject(renderReport.artifacts, 'manifest_render_report.artifacts');
  const renderedManifests = requireObject(
    renderReport.rendered_manifests,
    'manifest_render_report.rendered_manifests'
  );
  const renderCheckManifests = requireObject(
    renderCheckReport.rendered_manifests,
    'render_check_report.rendered_manifests'
  );

  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: checkReport.release_id,
    git_sha: checkReport.git_sha,
    target_profile: checkReport.target_profile,
    digest_summary: {
      release_contract_input_sha256: requireDigest(
        checkArtifacts.release_contract?.input_sha256,
        'airgap_bundle_check_report.artifacts.release_contract.input_sha256'
      ),
      deploy_template_package_input_sha256: requireDigest(
        checkArtifacts.deploy_template_package?.input_sha256,
        'airgap_bundle_check_report.artifacts.deploy_template_package.input_sha256'
      ),
      deploy_template_archive_input_sha256: requireDigest(
        checkArtifacts.deploy_template_archive?.input_sha256,
        'airgap_bundle_check_report.artifacts.deploy_template_archive.input_sha256'
      ),
      image_map_input_sha256: requireDigest(
        checkArtifacts.image_map?.input_sha256,
        'airgap_bundle_check_report.artifacts.image_map.input_sha256'
      ),
      bundle_manifest_input_sha256: requireDigest(
        checkArtifacts.bundle_manifest?.input_sha256,
        'airgap_bundle_check_report.artifacts.bundle_manifest.input_sha256'
      ),
      render_values_input_sha256: renderValuesDigest,
      substrate_truth_input_sha256: substrateTruthDigest,
      airgap_bundle_check_report_input_sha256: checkReportDigest,
      manifest_render_report_input_sha256: renderReportDigest,
      render_check_report_input_sha256: renderCheckReportDigest
    },
    bundle_components: bundleComponents,
    report_paths: {
      airgap_bundle_check: reportPath('airgap-bundle-check', BUNDLE_CHECK_REPORT_FILE),
      manifest_render: reportPath('render', RENDER_REPORT_FILE),
      render_check: reportPath('render-check', RENDER_CHECK_REPORT_FILE)
    },
    rendered_manifests: {
      path: reportPath('render', 'rendered-manifests'),
      files_count: requireInteger(renderedManifests.files_count, 'manifest_render_report.rendered_manifests.files_count'),
      workload_count: requireInteger(renderCheckManifests.workload_count, 'render_check_report.rendered_manifests.workload_count')
    },
    image_inventory: {
      image_map_image_count: imageMapSummary.imageCount,
      rendered_image_count: imageInventorySummary.renderedImageCount,
      rendered_target_image_count: imageInventorySummary.renderedTargetImageCount
    },
    artifact_counts: {
      archive_entry_count: requireInteger(
        renderArtifacts.archive?.entry_count,
        'manifest_render_report.artifacts.archive.entry_count'
      ),
      bundle_component_count: bundleComponents.length,
      rendered_file_count: requireInteger(
        renderedManifests.files_count,
        'manifest_render_report.rendered_manifests.files_count'
      ),
      rendered_workload_count: requireInteger(
        renderCheckManifests.workload_count,
        'render_check_report.rendered_manifests.workload_count'
      )
    }
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.airgap-bundle-render-check.${process.pid}.tmp`);
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
    const bundleRoot = await canonicalBundleRoot(args.bundleRoot);
    const bundleLocalPaths = {
      releaseContract: await bundleLocalFile(args.releaseContract, 'release contract', bundleRoot),
      deployTemplatePackage: await bundleLocalFile(
        args.deployTemplatePackage,
        'deploy template package',
        bundleRoot
      ),
      archive: await bundleLocalFile(args.archive, 'deploy template archive', bundleRoot),
      imageMap: await bundleLocalFile(args.imageMap, 'image map', bundleRoot),
      bundleManifest: await bundleLocalFile(args.bundleManifest, 'bundle manifest', bundleRoot),
      renderValues: await bundleLocalFile(args.renderValues, 'render values', bundleRoot),
      substrateTruth: await bundleLocalFile(args.substrateTruth, 'substrate truth', bundleRoot)
    };

    const bundleManifestInput = await readJson(bundleLocalPaths.bundleManifest, 'bundle manifest');
    const bundleComponents = await assertBundleInputsMatchManifest({
      bundleManifest: bundleManifestInput.value,
      bundleRoot,
      bundleLocalPaths
    });

    const bundleCheckDir = path.join(args.outputDir, 'airgap-bundle-check');
    const renderDir = path.join(args.outputDir, 'render');
    const renderCheckDir = path.join(args.outputDir, 'render-check');

    runNodeScript(
      'verify-airgap-bundle-check.mjs',
      [
        '--release-contract',
        bundleLocalPaths.releaseContract,
        '--deploy-template-package',
        bundleLocalPaths.deployTemplatePackage,
        '--archive',
        bundleLocalPaths.archive,
        '--image-map',
        bundleLocalPaths.imageMap,
        '--target-profile',
        targetProfile.value,
        '--bundle-root',
        bundleRoot,
        '--bundle-manifest',
        bundleLocalPaths.bundleManifest,
        '--output-dir',
        bundleCheckDir
      ],
      'airgap bundle self-check'
    );

    runNodeScript(
      'verify-render.mjs',
      [
        '--release-contract',
        bundleLocalPaths.releaseContract,
        '--deploy-template-package',
        bundleLocalPaths.deployTemplatePackage,
        '--archive',
        bundleLocalPaths.archive,
        '--target-profile',
        targetProfile.value,
        '--render-values',
        bundleLocalPaths.renderValues,
        '--substrate-truth',
        bundleLocalPaths.substrateTruth,
        '--image-map',
        bundleLocalPaths.imageMap,
        '--output-dir',
        renderDir
      ],
      'airgap bundle render'
    );

    runNodeScript(
      'verify-render-check.mjs',
      [
        '--release-contract',
        bundleLocalPaths.releaseContract,
        '--rendered-manifests',
        path.join(renderDir, 'rendered-manifests'),
        '--target-profile',
        targetProfile.value,
        '--output-dir',
        renderCheckDir
      ],
      'airgap bundle rendered manifest check'
    );

    const checkReportPath = path.join(bundleCheckDir, BUNDLE_CHECK_REPORT_FILE);
    const renderReportPath = path.join(renderDir, RENDER_REPORT_FILE);
    const renderCheckReportPath = path.join(renderCheckDir, RENDER_CHECK_REPORT_FILE);
    const checkReportInput = await readJson(checkReportPath, 'airgap bundle check report');
    const renderReportInput = await readJson(renderReportPath, 'manifest render report');
    const renderCheckReportInput = await readJson(renderCheckReportPath, 'render check report');
    const imageMapInput = await readJson(bundleLocalPaths.imageMap, 'image map');

    const checkReport = requireObject(
      checkReportInput.value,
      'airgap_bundle_check_report'
    );
    assertReportEnvelope(
      checkReport,
      {
        schema: 'agentsmith.airgap-bundle-check-report/v1',
        scope: 'airgap_bundle_manifest_check_only',
        releaseId: checkReport.release_id,
        gitSha: checkReport.git_sha
      },
      'airgap_bundle_check_report'
    );

    const expected = {
      releaseId: checkReport.release_id,
      gitSha: checkReport.git_sha
    };
    const renderReport = requireObject(renderReportInput.value, 'manifest_render_report');
    assertReportEnvelope(
      renderReport,
      {
        schema: 'agentsmith.manifest-render-report/v1',
        scope: 'manifest_render_only',
        ...expected
      },
      'manifest_render_report'
    );
    const renderCheckReport = requireObject(
      renderCheckReportInput.value,
      'render_check_report'
    );
    assertReportEnvelope(
      renderCheckReport,
      {
        schema: 'agentsmith.render-check-report/v1',
        scope: 'render_check_image_inventory_only',
        ...expected
      },
      'render_check_report'
    );

    const imageMapSummary = assertImageMap(
      imageMapInput.value,
      expected.releaseId,
      expected.gitSha
    );
    const imageInventorySummary = assertRenderedImagesUseTargets({
      renderReport,
      renderCheckReport,
      imageMapSummary
    });

    await writeReport(
      args.outputDir,
      buildReport({
        checkReport,
        checkReportDigest: checkReportInput.inputDigest,
        renderReport,
        renderReportDigest: renderReportInput.inputDigest,
        renderCheckReport,
        renderCheckReportDigest: renderCheckReportInput.inputDigest,
        renderValuesDigest: await digestFile(bundleLocalPaths.renderValues, 'render values'),
        substrateTruthDigest: await digestFile(bundleLocalPaths.substrateTruth, 'substrate truth'),
        imageMapSummary,
        bundleComponents,
        imageInventorySummary
      })
    );

    console.log('PASS: airgap bundle rendered offline and matched target image inventory readiness=false');
  } catch (error) {
    await removeManagedReports(args.outputDir);
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
