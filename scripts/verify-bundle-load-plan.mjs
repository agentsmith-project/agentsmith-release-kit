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
  'outputDir'
];
const AIRGAP_TARGET_PROFILE = 'existing_kubernetes/external_declared/airgap';
const IMAGE_MAP_SCHEMA = 'agentsmith.image-map/v1';
const BUNDLE_CHECK_REPORT_SCHEMA = 'agentsmith.airgap-bundle-check-report/v1';
const BUNDLE_CHECK_REPORT_SCOPE = 'airgap_bundle_manifest_check_only';
const REPORT_SCHEMA = 'agentsmith.airgap-bundle-load-plan-report/v1';
const REPORT_SCOPE = 'airgap_bundle_load_plan_only';
const REPORT_FILE = 'airgap-bundle-load-plan-report.json';
const SELF_CHECK_REPORT_FILE = 'airgap-bundle-check-report.json';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const DNS_HOST_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i;
const TARGET_NAMESPACE_COMPONENT_RE = /^[a-z0-9]+(?:(?:[._-]|__)[a-z0-9]+)*$/;
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
  node scripts/verify-bundle-load-plan.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --image-map <json> \\
    --target-profile existing_kubernetes/external_declared/airgap \\
    --bundle-root <dir> \\
    --bundle-manifest <json> \\
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
  await fs.rm(path.join(outputDir, SELF_CHECK_REPORT_FILE), { force: true });
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
  if (value !== AIRGAP_TARGET_PROFILE) {
    fail(`--bundle-load-plan only accepts ${AIRGAP_TARGET_PROFILE}`);
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

  return {
    value: AIRGAP_TARGET_PROFILE,
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'airgap'
  };
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
  return { digest, imageWithoutDigest };
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

function isSecretLookingRegistrySegment(segment) {
  return SECRET_VALUE_RE.some((pattern) => pattern.test(segment));
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
    if (isSecretLookingRegistrySegment(component)) {
      fail(`image_map.target_registry namespace component ${index + 1} must not contain secret-looking content`);
    }
    if (!TARGET_NAMESPACE_COMPONENT_RE.test(component)) {
      fail(`image_map.target_registry namespace component ${index + 1} is invalid`);
    }
  }

  return value;
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
  assertTargetProfileObject(checkReport.target_profile, 'airgap_bundle_check_report.target_profile');
  const artifacts = requireObject(checkReport.artifacts, 'airgap_bundle_check_report.artifacts');
  requireString(checkReport.release_id, 'airgap_bundle_check_report.release_id');
  requireString(checkReport.git_sha, 'airgap_bundle_check_report.git_sha');
  requireInteger(checkReport.image_artifact_declaration_count, 'airgap_bundle_check_report.image_artifact_declaration_count');
  requireInteger(checkReport.payload_artifact_count, 'airgap_bundle_check_report.payload_artifact_count');
  requireInteger(checkReport.tool_count, 'airgap_bundle_check_report.tool_count');
  requireInteger(checkReport.bundled_tool_count, 'airgap_bundle_check_report.bundled_tool_count');
  requireInteger(
    checkReport.operator_prerequisite_tool_count,
    'airgap_bundle_check_report.operator_prerequisite_tool_count'
  );

  return {
    releaseId: checkReport.release_id,
    gitSha: checkReport.git_sha,
    targetProfile,
    artifacts
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
    deploy_template_package_package_sha256: requireDigest(
      deployTemplatePackage.package_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_package.package_sha256'
    ),
    deploy_template_package_manifest_sha256: requireDigest(
      deployTemplatePackage.manifest_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_package.manifest_sha256'
    ),
    deploy_template_package_artifact_sha256: requireDigest(
      deployTemplatePackage.artifact_sha256,
      'airgap_bundle_check_report.artifacts.deploy_template_package.artifact_sha256'
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

function assertImageMap(imageMap) {
  assertStringEquals(imageMap.schema, IMAGE_MAP_SCHEMA, 'image_map.schema');
  assertStringEquals(imageMap.scope, 'image_map_only', 'image_map.scope');
  requireBooleanFalse(imageMap.readiness, 'image_map.readiness');
  assertStringEquals(imageMap.status, 'pass', 'image_map.status');
  assertTargetProfileObject(imageMap.target_profile, 'image_map.target_profile');
  requireBooleanTrue(imageMap.mirror_required, 'image_map.mirror_required');
  const targetRegistry = validateTargetRegistry(imageMap.target_registry);

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
    requireString(mapping.source_image, `${label}.source_image`);
    const sourceDigest = requireDigest(mapping.source_digest, `${label}.source_digest`);
    const targetImage = requireString(mapping.target_image, `${label}.target_image`);
    const targetDigest = requireDigest(mapping.target_digest, `${label}.target_digest`);
    if (targetDigest !== sourceDigest) {
      fail(`${label}.target_digest must match source_digest`);
    }
    const { digest: targetImageDigest } = imageDigestSuffix(
      targetImage,
      `${label}.target_image`
    );
    if (!targetImage.startsWith(`${targetRegistry}/`)) {
      fail(`${label}.target_image must be under image_map.target_registry`);
    }
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
    assertStringEquals(mapping.action, 'mirror_required', `${label}.action`);

    targetDigests.add(targetDigest);
    mappingsById.set(id, {
      id,
      source_image: mapping.source_image,
      source_digest: sourceDigest,
      target_image: targetImage,
      target_digest: targetDigest
    });
  }

  return {
    targetRegistry,
    imageCount: mappings.length,
    mappingsById,
    uniqueTargetDigestCount: targetDigests.size
  };
}

function assertImageArtifactDeclarations(declarations, imageMapSummary) {
  const items = requireArray(
    declarations,
    'bundle_manifest.image_artifact_declarations'
  );
  if (items.length !== imageMapSummary.mappingsById.size) {
    fail('bundle_manifest.image_artifact_declarations must match image_map.mappings length');
  }

  const seen = new Set();
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
    const { digest: targetImageDigest } = imageDigestSuffix(
      declaration.target_image,
      `${label}.target_image`
    );
    if (!declaration.target_image.startsWith(`${imageMapSummary.targetRegistry}/`)) {
      fail(`${label}.target_image must be under image_map.target_registry`);
    }
    if (targetImageDigest !== targetDigest) {
      fail(`${label}.target_image must be digest-pinned with target_digest`);
    }
  }

  for (const id of imageMapSummary.mappingsById.keys()) {
    if (!seen.has(id)) {
      fail(`bundle_manifest.image_artifact_declarations is missing ${id}`);
    }
  }

  return items.length;
}

function assertOperatorPrerequisites(value) {
  const prerequisites = requireObject(
    value,
    'bundle_manifest.operator_prerequisites'
  );
  requireString(
    prerequisites.target_registry_proof_ref,
    'bundle_manifest.operator_prerequisites.target_registry_proof_ref'
  );
  const tools = requireArray(
    prerequisites.tools,
    'bundle_manifest.operator_prerequisites.tools'
  );

  let operatorPrerequisiteToolCount = 0;
  for (const [index, value] of tools.entries()) {
    const label = `bundle_manifest.operator_prerequisites.tools[${index}]`;
    const tool = requireObject(value, label);
    const source = requireString(tool.source, `${label}.source`);
    if (source === 'operator_prerequisite') {
      requireString(tool.proof, `${label}.proof`);
      operatorPrerequisiteToolCount += 1;
    }
  }

  if (operatorPrerequisiteToolCount === 0) {
    fail('bundle_manifest.operator_prerequisites.tools must include an operator_prerequisite tool proof');
  }
}

function assertBundleManifest(manifest, imageMapSummary) {
  assertTargetProfileObject(manifest.target_profile, 'bundle_manifest.target_profile');
  const imageArtifactDeclarationCount = assertImageArtifactDeclarations(
    manifest.image_artifact_declarations,
    imageMapSummary
  );
  assertOperatorPrerequisites(manifest.operator_prerequisites);

  return {
    imageArtifactDeclarationCount
  };
}

function buildReport({
  checkSummary,
  checkReport,
  digestSummary,
  imageMapSummary,
  manifestSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: checkSummary.releaseId,
    git_sha: checkSummary.gitSha,
    target_profile: checkSummary.targetProfile,
    target_registry: imageMapSummary.targetRegistry,
    image_count: imageMapSummary.imageCount,
    digest_summary: digestSummary,
    target_registry_summary: {
      target_registry: imageMapSummary.targetRegistry,
      image_count: imageMapSummary.imageCount,
      target_digest_count: imageMapSummary.imageCount,
      unique_target_digest_count: imageMapSummary.uniqueTargetDigestCount,
      mirror_required_count: imageMapSummary.imageCount,
      image_artifact_declaration_count: manifestSummary.imageArtifactDeclarationCount
    },
    bundle_summary: {
      image_artifact_declaration_count: checkReport.image_artifact_declaration_count,
      payload_artifact_count: checkReport.payload_artifact_count,
      tool_count: checkReport.tool_count,
      bundled_tool_count: checkReport.bundled_tool_count,
      operator_prerequisite_tool_count: checkReport.operator_prerequisite_tool_count
    }
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.bundle-load-plan.${process.pid}.tmp`);
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
        args.outputDir
      ],
      'airgap bundle self-check'
    );

    const checkReportInput = await readJson(
      path.join(args.outputDir, SELF_CHECK_REPORT_FILE),
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
      requireObject(imageMapInput.value, 'image_map')
    );
    const manifestSummary = assertBundleManifest(
      requireObject(bundleManifestInput.value, 'bundle_manifest'),
      imageMapSummary
    );

    await writeReport(
      args.outputDir,
      buildReport({
        checkSummary,
        checkReport,
        digestSummary: readDigestSummary(
          checkSummary.artifacts,
          checkReportInput.inputDigest
        ),
        imageMapSummary,
        manifestSummary
      })
    );

    console.log('PASS: airgap bundle load plan accepted readiness=false');
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
