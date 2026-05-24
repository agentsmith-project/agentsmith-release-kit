#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import zlib from 'node:zlib';

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'outputDir'
];
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?(?:[/?#]|$)/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const SOURCE_LIKE_LABEL_RE = /(?:^|\.)(?:source_uri|source_path|artifact_uri|package_uri|local_path|path|file|dir|kubeconfig)$/;
const WORKSPACE_SOURCE_RE = /\/home\/[^/]+\/works\/[^/]+\/agent(?:smith)?(?:\/|$)/i;
const SECRET_KEY_RE = /(^|[_-])(password|passwd|pwd|token|secret|client_secret|private_key|kubeconfig|access_key|api_key)([_-]|$)/i;
const SAFE_REDACTED_SECRET_RE = /^(redacted|\*+)$/i;
const SAFE_SECRET_REF_VALUE_RE = /^[A-Za-z0-9_.-]*secret_ref$/;
const SECRET_REF_PREFIX = 'secretRef:';
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:postgres|mongodb|redis):\/\/[^:\s]+:[^@\s]+@/i,
  /\b(?:password|token|secret|client_secret)\s*[:=]\s*["']?[^"'\s]{8,}/i
];

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
  node scripts/verify-template-package.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --output-dir <dir>`;
}

function cliFail(message) {
  throw new CliError(message);
}

function fail(message) {
  throw new ValidationError(message);
}

function parseArgs(argv) {
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
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

function toKebab(value) {
  return value.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
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

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
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
      const content = tarBuffer.subarray(contentStart, contentEnd);
      scanArchiveFileContent(content, entryPath);
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

function buildReport({
  contract,
  releaseContractInputDigest,
  deployTemplatePackage,
  deployTemplatePackageInputDigest,
  archiveSha256,
  archive
}) {
  return {
    scope: 'template_package_intake_only',
    readiness: false,
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    artifacts: {
      release_contract: {
        input_sha256: releaseContractInputDigest
      },
      deploy_template_package: {
        input_sha256: deployTemplatePackageInputDigest,
        package_uri: deployTemplatePackage.package_uri,
        package_sha256: deployTemplatePackage.package_sha256,
        manifest_sha256: deployTemplatePackage.manifest_sha256,
        artifact_sha256: deployTemplatePackage.artifact_provenance?.artifact_sha256,
        provenance: deployTemplatePackage.artifact_provenance
      },
      archive: {
        archive_sha256: archiveSha256,
        manifest_sha256: archive.manifestSha256,
        entry_count: archive.entries.length
      }
    },
    status: 'pass'
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(
    path.join(outputDir, 'template-package-report.json'),
    `${JSON.stringify(report, null, 2)}\n`
  );
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const deployTemplatePackageInput = await readJson(
    args.deployTemplatePackage,
    'deploy template package'
  );
  const archiveBuffer = await readArchive(args.archive);
  const archiveSha256 = digestBuffer(archiveBuffer);

  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const deployTemplatePackage = requireObject(
    deployTemplatePackageInput.value,
    'deploy_template_package'
  );

  assertNoUnsafePayload(
    [contract, 'release_contract'],
    [deployTemplatePackage, 'deploy_template_package']
  );
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

  await writeReport(
    args.outputDir,
    buildReport({
      contract,
      releaseContractInputDigest: releaseContractInput.inputDigest,
      deployTemplatePackage,
      deployTemplatePackageInputDigest: deployTemplatePackageInput.inputDigest,
      archiveSha256,
      archive
    })
  );
  console.log('PASS: deploy template package archive accepted');
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
