#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const REQUIRED_ARGS = ['releaseContract', 'outputDir'];
const RECEIPT_FILE = 'airgap-image-archive-export.json';
const RECEIPT_SCHEMA_VERSION = 'agentsmith.airgap-image-archive-export/v1';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const SAFE_SEGMENT_RE = /^[A-Za-z0-9_.-]+$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;

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
  node scripts/export-airgap-image-archives.mjs \\
    --release-contract <json> \\
    --output-dir <dir> \\
    [--skopeo <path-or-command>]

Maintainer-only helper. Exports release contract image refs into local OCI layout
tar archives for later --bundle-create consumption. It pulls from registries via
skopeo and is not an operator path or release readiness verdict. Requires
registry access and local skopeo (or --skopeo <path>); --output-dir must be a
new/non-existing directory.`;
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
  const parsed = {
    skopeo: 'skopeo'
  };

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
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--skopeo':
        parsed.skopeo = nextValue();
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
  if (!parsed.skopeo || parsed.skopeo.trim() === '') {
    cliFail('--skopeo must not be empty');
  }

  return parsed;
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function digestFile(file, label) {
  return await new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = createReadStream(file);
    stream.on('error', (error) => {
      reject(new ValidationError(`cannot read ${label}: ${error.message}`));
    });
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(`sha256:${hash.digest('hex')}`));
  });
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
      inputDigest: digestBuffer(Buffer.from(raw))
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
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

function assertSafeSegment(value, label) {
  const segment = requireString(value, label);
  if (
    segment !== segment.trim() ||
    segment === '.' ||
    segment === '..' ||
    !SAFE_SEGMENT_RE.test(segment) ||
    segment.includes('/') ||
    segment.includes('\\') ||
    URI_SCHEME_RE.test(segment)
  ) {
    fail(`${label} must be a safe file name segment`);
  }
  return segment;
}

function parseImageDigestRef(image, label) {
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

  const digest = `sha256:${value.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return {
    digest,
    imageWithoutDigest
  };
}

function stripTag(imageWithoutDigest, label) {
  const lastSlash = imageWithoutDigest.lastIndexOf('/');
  const lastColon = imageWithoutDigest.lastIndexOf(':');
  const repository = lastColon > lastSlash
    ? imageWithoutDigest.slice(0, lastColon)
    : imageWithoutDigest;
  if (!repository || repository.endsWith('/')) {
    fail(`${label} must include an image repository`);
  }
  return repository;
}

function imageExportSpec(item, index) {
  const label = `release_contract.deploy_image_inventory[${index}]`;
  const image = requireObject(item, label);
  const id = assertSafeSegment(image.id, `${label}.id`);
  const expectedDigest = requireDigest(image.digest, `${label}.digest`);
  const parsedRef = parseImageDigestRef(image.image, `${label}.image`);
  if (parsedRef.digest !== expectedDigest) {
    fail(`${label}.image digest must match ${label}.digest`);
  }

  const repository = stripTag(parsedRef.imageWithoutDigest, `${label}.image`);
  const sourceRef = `docker://${repository}@${expectedDigest}`;
  return {
    id,
    sourceRef,
    expectedDigest
  };
}

function normalizeInventory(contract) {
  const releaseContract = requireObject(contract, 'release contract');
  const inventory = requireArray(
    releaseContract.deploy_image_inventory,
    'release_contract.deploy_image_inventory'
  );
  if (inventory.length === 0) {
    fail('release_contract.deploy_image_inventory must not be empty');
  }

  const seen = new Set();
  return inventory.map((item, index) => {
    const spec = imageExportSpec(item, index);
    if (seen.has(spec.id)) {
      fail(`release_contract.deploy_image_inventory contains duplicate image id: ${spec.id}`);
    }
    seen.add(spec.id);
    return spec;
  });
}

async function canonicalOutputDir(input) {
  const requestedOutputDir = path.resolve(input);
  let stat;
  try {
    stat = await fs.lstat(requestedOutputDir);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      fail(`cannot inspect output dir: ${error.message}`);
    }
  }

  if (stat) {
    fail('output dir must not already exist');
  }

  const parentDir = path.dirname(requestedOutputDir);
  let parentStat;
  try {
    parentStat = await fs.lstat(parentDir);
  } catch (error) {
    fail(`cannot inspect output dir parent: ${error.message}`);
  }
  if (parentStat.isSymbolicLink()) {
    fail('output dir parent must not be a symlink');
  }
  if (!parentStat.isDirectory()) {
    fail('output dir parent must be a directory');
  }

  let realParentDir;
  try {
    realParentDir = await fs.realpath(parentDir);
  } catch (error) {
    fail(`cannot resolve output dir parent: ${error.message}`);
  }

  const outputDir = path.join(realParentDir, path.basename(requestedOutputDir));
  try {
    await fs.mkdir(outputDir, { mode: 0o700 });
    await fs.chmod(outputDir, 0o700);
  } catch (error) {
    if (error.code === 'EEXIST') {
      fail('output dir must not already exist');
    }
    fail(`cannot create output dir: ${error.message}`);
  }

  try {
    return await fs.realpath(outputDir);
  } catch (error) {
    fail(`cannot resolve output dir: ${error.message}`);
  }
}

async function assertArchivePathPreflight(archivePath, id) {
  let stat;
  try {
    stat = await fs.lstat(archivePath);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      fail(`cannot inspect archive path for image id ${id}: ${error.message}`);
    }
    return;
  }

  if (stat.isSymbolicLink()) {
    fail(`archive path for image id ${id} must not be a symlink`);
  }
  if (stat.isDirectory()) {
    fail(`archive path for image id ${id} must not be a directory`);
  }
}

function runCommand(command, args, label, options = {}) {
  const result = spawnSync(command, args, {
    cwd: ROOT_DIR,
    encoding: options.encoding,
    maxBuffer: options.maxBuffer || 1024 * 1024,
    stdio: options.stdio
  });
  if (result.error) {
    if (result.error.code === 'ENOENT' && label.includes('skopeo')) {
      fail(
        `skopeo not found; install skopeo or pass --skopeo <path>: ${result.error.message}`
      );
    }
    fail(`${label} failed to start: ${result.error.message}`);
  }
  if (result.signal) {
    fail(`${label} was interrupted by signal ${result.signal}`);
  }
  if (result.status !== 0) {
    fail(`${label} failed with exit code ${result.status}`);
  }
  return result;
}

function readSkopeoVersion(skopeo) {
  const result = runCommand(skopeo, ['--version'], 'skopeo --version', {
    encoding: 'utf8'
  });
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
  return output || 'unknown';
}

function readArchiveDescriptorDigest(archivePath, id) {
  const result = runCommand('tar', ['-xOf', archivePath, 'index.json'], `tar index.json for image id ${id}`, {
    encoding: 'utf8',
    maxBuffer: 5 * 1024 * 1024
  });

  let index;
  try {
    index = JSON.parse(result.stdout);
  } catch (error) {
    fail(`index.json for image id ${id} must be valid JSON: ${error.message}`);
  }

  const manifests = requireArray(index.manifests, `index.json for image id ${id}.manifests`);
  if (manifests.length === 0) {
    fail(`index.json for image id ${id}.manifests must not be empty`);
  }
  const descriptor = requireObject(manifests[0], `index.json for image id ${id}.manifests[0]`);
  return requireDigest(descriptor.digest, `index.json for image id ${id}.manifests[0].digest`);
}

async function exportImage({ skopeo, outputDir, spec }) {
  const archivePath = path.join(outputDir, `${spec.id}.oci-layout.tar`);
  await assertArchivePathPreflight(archivePath, spec.id);
  const destinationRef = `oci-archive:${archivePath}:${spec.id}`;
  const commandArgs = [
    'copy',
    '--all',
    '--preserve-digests',
    spec.sourceRef,
    destinationRef
  ];

  runCommand(skopeo, commandArgs, `skopeo copy for image id ${spec.id}`, {
    stdio: 'inherit'
  });

  const descriptorDigest = readArchiveDescriptorDigest(archivePath, spec.id);
  if (descriptorDigest !== spec.expectedDigest) {
    fail(
      `archive descriptor digest for image id ${spec.id} must match expected digest: ` +
        `${descriptorDigest} !== ${spec.expectedDigest}`
    );
  }
  const archiveSha256 = await digestFile(archivePath, `archive for image id ${spec.id}`);

  return {
    id: spec.id,
    source_ref: spec.sourceRef,
    expected_digest: spec.expectedDigest,
    archive_path: archivePath,
    archive_sha256: archiveSha256,
    descriptor_digest: descriptorDigest,
    command_args: commandArgs
  };
}

async function writeReceipt(outputDir, receipt) {
  const receiptPath = path.join(outputDir, RECEIPT_FILE);
  const tempToken = `${process.pid}.${Date.now()}.${crypto.randomBytes(12).toString('hex')}`;
  const tempPath = path.join(outputDir, `.${RECEIPT_FILE}.${tempToken}.tmp`);
  try {
    try {
      await fs.lstat(receiptPath);
      fail('export receipt must not already exist');
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }
    await fs.writeFile(tempPath, `${JSON.stringify(receipt, null, 2)}\n`, {
      flag: 'wx',
      mode: 0o600
    });
    await fs.rename(tempPath, receiptPath);
  } catch (error) {
    await fs.rm(tempPath, { force: true }).catch(() => {});
    fail(`cannot write export receipt: ${error.message}`);
  }
  return receiptPath;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const contractInput = await readJson(args.releaseContract, 'release contract');
  const specs = normalizeInventory(contractInput.value);
  const skopeoVersion = readSkopeoVersion(args.skopeo);
  const outputDir = await canonicalOutputDir(args.outputDir);

  const images = [];
  for (const spec of specs) {
    images.push(await exportImage({ skopeo: args.skopeo, outputDir, spec }));
  }

  const receipt = {
    schema_version: RECEIPT_SCHEMA_VERSION,
    release_id: requireString(contractInput.value.release_id, 'release_contract.release_id'),
    git_sha: requireString(contractInput.value.git_sha, 'release_contract.git_sha'),
    generated_at: new Date().toISOString(),
    skopeo_version: skopeoVersion,
    release_contract_sha256: contractInput.inputDigest,
    images
  };
  const receiptPath = await writeReceipt(outputDir, receipt);

  console.log(
    `Exported ${images.length} OCI image archive(s) for ${receipt.release_id} to ${outputDir}`
  );
  console.log(`Receipt: ${receiptPath}`);
}

main().catch((error) => {
  if (error instanceof CliError || error instanceof ValidationError) {
    console.error(`error: ${error.message}`);
    process.exit(error.exitCode);
  }
  console.error(`error: ${error.stack || error.message}`);
  process.exit(1);
});
