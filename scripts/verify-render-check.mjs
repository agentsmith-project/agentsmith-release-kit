#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import { parseCanonicalTargetProfile } from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'releaseContract',
  'renderedManifests',
  'targetProfile',
  'outputDir'
];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const REPORT_SCHEMA = 'agentsmith.render-check-report/v1';
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
  /\b(?:postgres|mongodb|redis):\/\/[^:\s]+:[^@\s]+@/i
];
const SAFE_REDACTED_SECRET_RE = /^(redacted|\*+)$/i;
const SAFE_SECRET_REF_VALUE_RE = /^[A-Za-z0-9_.-]*secret_ref$/;

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
  node scripts/verify-render-check.mjs \\
    --release-contract <json> \\
    --rendered-manifests <dir> \\
    --target-profile <target_cluster>/<substrate_source>/<distribution> \\
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
      case '--rendered-manifests':
        parsed.renderedManifests = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
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

function parseTargetProfile(targetProfile) {
  return parseCanonicalTargetProfile(targetProfile, fail);
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

    const normalized = {
      id,
      image,
      digest,
      source: typeof item.source === 'string' ? item.source : undefined
    };
    byExact.set(image, normalized);
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

  return { byExact, byDigest, byImageWithoutDigest };
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

function assertNoSecretPayload(raw, label) {
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

function assertInsideRoot(rootDir, file, label) {
  const relative = path.relative(rootDir, file);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must stay inside rendered manifests root`);
  }
}

async function renderedRoot(input, forbiddenSourceRoots) {
  await assertPathBoundary(input, 'rendered manifests root', forbiddenSourceRoots);

  let root;
  try {
    root = await fs.realpath(input);
  } catch (error) {
    fail(`cannot read rendered manifests root: ${error.message}`);
  }

  let stat;
  try {
    stat = await fs.stat(root);
  } catch (error) {
    fail(`cannot stat rendered manifests root: ${error.message}`);
  }
  if (!stat.isDirectory()) {
    fail('rendered manifests root must be a directory');
  }
  return root;
}

function isManifestFile(file) {
  return MANIFEST_EXTENSIONS.has(path.extname(file).toLowerCase());
}

async function collectManifestFiles(root, dir = root, files = []) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch (error) {
    fail(`cannot read rendered manifests directory: ${error.message}`);
  }
  entries.sort((left, right) => left.name.localeCompare(right.name));

  for (const entry of entries) {
    const file = path.join(dir, entry.name);
    let stat;
    try {
      stat = await fs.lstat(file);
    } catch (error) {
      fail(`cannot stat rendered manifest path: ${error.message}`);
    }

    if (stat.isSymbolicLink()) {
      let target;
      try {
        target = await fs.realpath(file);
      } catch (error) {
        fail(`rendered manifest symlink cannot be resolved: ${error.message}`);
      }
      assertInsideRoot(root, target, `rendered manifest symlink ${path.relative(root, file)}`);
      fail(`rendered manifest path must not be a symlink: ${path.relative(root, file)}`);
    }

    if (stat.isDirectory()) {
      const realDir = await fs.realpath(file);
      assertInsideRoot(root, realDir, `rendered manifest directory ${path.relative(root, file)}`);
      await collectManifestFiles(root, file, files);
      continue;
    }

    if (!stat.isFile() || !isManifestFile(file)) {
      continue;
    }

    const realFile = await fs.realpath(file);
    assertInsideRoot(root, realFile, `rendered manifest ${path.relative(root, file)}`);
    files.push(file);
  }

  return files;
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

function parseManifest(raw, relativePath) {
  if (path.extname(relativePath).toLowerCase() === '.json') {
    return parseJsonManifest(raw, relativePath);
  }

  const trimmed = raw.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return parseJsonManifest(raw, relativePath);
  }
  return parseYamlManifest(raw, relativePath);
}

async function readManifestFile(root, file) {
  const relativePath = path.relative(root, file).split(path.sep).join('/');
  const raw = await readText(file, `rendered manifest ${relativePath}`);
  assertNoSecretPayload(raw, `rendered manifest ${relativePath}`);
  return {
    relativePath,
    raw,
    sha256: digestBuffer(Buffer.from(raw))
  };
}

async function validateManifests(root, inventory) {
  const files = await collectManifestFiles(root);
  if (files.length === 0) {
    fail('rendered manifests root must contain yaml, yml, or json manifests');
  }

  const manifests = [];
  const usedImages = new Map();

  for (const file of files) {
    const input = await readManifestFile(root, file);
    const workloads = parseManifest(input.raw, input.relativePath);

    for (const [workloadIndex, workload] of workloads.entries()) {
      const manifestImages = workload.images.map((entry, imageIndex) => {
        const label = `manifest ${input.relativePath} workload ${workload.kind} image ${imageIndex + 1}`;
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
        path: input.relativePath,
        document_index: workload.document_index || workloadIndex + 1,
        kind: workload.kind,
        name: workload.name,
        sha256: input.sha256,
        images: manifestImages
      });
    }
  }

  if (manifests.length === 0) {
    fail('rendered manifests root must contain at least one supported Kubernetes workload');
  }

  return {
    files_count: files.length,
    manifests,
    images: [...usedImages.values()].sort((left, right) => {
      return left.image.localeCompare(right.image);
    })
  };
}

function buildReport({
  contract,
  releaseContractInputDigest,
  targetProfile,
  manifestSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: 'render_check_image_inventory_only',
    readiness: false,
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile,
    release_contract: {
      input_sha256: releaseContractInputDigest,
      deploy_image_inventory_count: contract.deploy_image_inventory.length
    },
    rendered_manifests: {
      files_count: manifestSummary.files_count,
      workload_count: manifestSummary.manifests.length
    },
    images: manifestSummary.images,
    manifests: manifestSummary.manifests,
    generated_at: new Date().toISOString(),
    status: 'pass'
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(
    path.join(outputDir, 'render-report.json'),
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
  const forbiddenSourceRoots = await canonicalForbiddenSourceRoots(args.forbiddenSourceRoots || []);
  const releaseContractPath = await assertPathBoundary(
    args.releaseContract,
    'release contract',
    forbiddenSourceRoots
  );
  const releaseContractInput = await readJson(releaseContractPath, 'release contract');
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  assertSchemaVersion(
    contract.schema_version,
    RELEASE_CONTRACT_SCHEMA,
    'release_contract.schema_version'
  );
  requireString(contract.release_id, 'release_contract.release_id');
  contract.git_sha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  assertContractTargetProfiles(contract, targetProfile);
  const inventory = buildInventory(contract);
  const root = await renderedRoot(args.renderedManifests, forbiddenSourceRoots);
  const manifestSummary = await validateManifests(root, inventory);

  await writeReport(
    args.outputDir,
    buildReport({
      contract,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      targetProfile,
      manifestSummary
    })
  );
  console.log('PASS: rendered manifests match release contract image inventory');
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
