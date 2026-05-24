#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const AGENTSMITH_REPO = 'github.com/agentsmith-project/agentsmith';
const AGENTSMITH_PRODUCT = AGENTSMITH_REPO.slice(AGENTSMITH_REPO.lastIndexOf('/') + 1);
const CONTRACT_SUBJECT = 'agentsmith-release-contract';
const DEPLOY_TEMPLATE_PACKAGE_SUBJECT = 'agentsmith-deploy-template-package';
const PROVENANCE_KIND = 'ci_artifact';
const IMAGE_GROUPS = [
  'product_images',
  'adopted_provider_images',
  'release_kit_prerequisite_images'
];
const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'targetProfile',
  'outputDir'
];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_PACKAGE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const ARTIFACT_PROVENANCE_SCHEMA = 'agentsmith.artifact-provenance/v1';
const SUBSTRATE_CONNECTION_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
const TARGET_CLUSTER_VALUES = new Set(['existing_kubernetes', 'kind_rehearsal']);
const SUBSTRATE_SOURCE_VALUES = new Set(['external_declared', 'kit_installed']);
const DISTRIBUTION_VALUES = new Set(['online', 'airgap']);
const SUPPORT_LEVEL_VALUES = new Set(['primary', 'supported', 'diagnostic']);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCAL_SCHEME_RE = /^(?:file|local|source|git\+file):/i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?(?:[/?#]|$)/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const SOURCE_LIKE_LABEL_RE = /(?:^|\.)(?:source_uri|source_path|artifact_uri|package_uri|local_path|path|file|dir|kubeconfig)$/;
const WORKSPACE_SOURCE_RE = /\/home\/[^/]+\/works\/[^/]+\/agent(?:smith)?(?:\/|$)/i;
const SECRET_KEY_RE = /(^|[_-])(password|passwd|pwd|token|secret|client_secret|private_key|kubeconfig|access_key|api_key)([_-]|$)/i;
const SAFE_REDACTED_SECRET_RE = /^(redacted|\*+)$/i;
const SECRET_REF_PREFIX = 'secretRef:';
const TARGET_PULL_SECRET_REF_RE = /^release_contract\.target_profiles\[\d+\]\.prerequisites\.pull_secret_ref$/;
const CURRENT_LEGAL_PULL_SECRET_REFS = new Set(['operator_secret_ref', 'not_required']);
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
  node scripts/verify-inputs.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --target-profile <target_cluster>/<substrate_source>/<distribution> \\
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
      case '--target-profile':
        parsed.targetProfile = nextValue();
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
      inputDigest: `sha256:${crypto.createHash('sha256').update(raw).digest('hex')}`
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

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') {
    fail(`${label} must be a boolean`);
  }
  return value;
}

function requireEnumString(value, label, allowedValues) {
  const text = requireString(value, label);
  if (!allowedValues.has(text)) {
    fail(`${label} must be one of: ${[...allowedValues].join(', ')}`);
  }
  return text;
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

function canonicalSubjectDigest(payload) {
  const { artifact_provenance: _artifactProvenance, ...subject } = payload;
  const body = JSON.stringify(stableJson(subject));
  return `sha256:${crypto.createHash('sha256').update(body).digest('hex')}`;
}

function canonicalArtifactProjectionDigest(payload) {
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } = payload.artifact_provenance;
  const projection = { ...payload, artifact_provenance: artifactProvenance };
  const body = JSON.stringify(stableJson(projection));
  return `sha256:${crypto.createHash('sha256').update(body).digest('hex')}`;
}

function assertSameJson(left, right, label) {
  const leftStable = JSON.stringify(stableJson(left));
  const rightStable = JSON.stringify(stableJson(right));
  if (leftStable !== rightStable) {
    fail(`${label} mismatch`);
  }
}

function imageDigestSuffix(image, label) {
  const marker = '@sha256:';
  const index = image.lastIndexOf(marker);
  if (index < 0) {
    fail(`${label} must be pinned with @sha256`);
  }

  const digest = `sha256:${image.slice(index + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} has invalid sha256 suffix`);
  }
  return digest;
}

function normalizeImageItem(item, source, index) {
  const label = `${source}[${index}]`;
  const object = requireObject(item, label);
  const id = requireString(object.id, `${label}.id`);
  const image = requireString(object.image, `${label}.image`);
  const suffixDigest = imageDigestSuffix(image, `${label}.image`);
  const digest = requireDigest(object.digest, `${label}.digest`);

  if (digest !== suffixDigest) {
    fail(`${label}.digest must match image suffix`);
  }

  return {
    source,
    id,
    image,
    digest
  };
}

function normalizeInventoryItem(item, index) {
  const label = `deploy_image_inventory[${index}]`;
  const object = requireObject(item, label);
  const source = requireString(object.source, `${label}.source`);

  if (!IMAGE_GROUPS.includes(source)) {
    fail(`${label}.source is not a known image source`);
  }

  return normalizeImageItem(object, source, index);
}

function imageSortKey(item) {
  return `${item.source}\u0000${item.id}\u0000${item.image}\u0000${item.digest}`;
}

function sortedImages(images) {
  return [...images].sort((left, right) => imageSortKey(left).localeCompare(imageSortKey(right)));
}

function assertUniqueImageIds(images, label) {
  const ids = new Set();
  for (const image of images) {
    if (ids.has(image.id)) {
      fail(`${label} contains duplicate image id: ${image.id}`);
    }
    ids.add(image.id);
  }
}

function assertImageInventory(contract) {
  const expected = IMAGE_GROUPS.flatMap((source) => {
    const group = requireArray(contract[source], `release_contract.${source}`);
    if (group.length === 0) {
      fail(`release_contract.${source} must not be empty`);
    }
    return group.map((item, index) => normalizeImageItem(item, source, index));
  });
  const actual = requireArray(
    contract.deploy_image_inventory,
    'release_contract.deploy_image_inventory'
  ).map((item, index) => normalizeInventoryItem(item, index));

  assertUniqueImageIds(expected, 'release_contract image inventory');
  assertUniqueImageIds(actual, 'release_contract.deploy_image_inventory');

  assertSameJson(
    sortedImages(actual),
    sortedImages(expected),
    'release_contract.deploy_image_inventory'
  );

  return expected;
}

function assertProductFlowShape(contract) {
  const flows = requireArray(
    contract.required_product_flows,
    'release_contract.required_product_flows'
  );
  if (flows.length === 0) {
    fail('release_contract.required_product_flows must not be empty');
  }
  for (const [index, flow] of flows.entries()) {
    requireString(flow, `release_contract.required_product_flows[${index}]`);
  }
}

function parseTargetProfile(targetProfile) {
  requireString(targetProfile, 'target_profile');
  const tuple = targetProfile.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  return {
    targetCluster: requireEnumString(
      targetCluster,
      'target_profile.target_cluster',
      TARGET_CLUSTER_VALUES
    ),
    substrateSource: requireEnumString(
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

function isSecretRefValue(value) {
  if (typeof value !== 'string' || !value.startsWith(SECRET_REF_PREFIX)) {
    return false;
  }
  const ref = value.slice(SECRET_REF_PREFIX.length);
  return ref.trim() !== '' && !/[\r\n]/.test(ref) && !/^[\s:]+$/.test(ref);
}

function isAllowedPullSecretRef(value) {
  return CURRENT_LEGAL_PULL_SECRET_REFS.has(value) || isSecretRefValue(value);
}

function assertTargetProfile(contract, targetProfile) {
  const { targetCluster, substrateSource, distribution } = parseTargetProfile(targetProfile);

  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  let found;
  let foundIndex = -1;
  for (const [index, profile] of profiles.entries()) {
    const label = `release_contract.target_profiles[${index}]`;
    const object = requireObject(profile, label);
    const profileTargetCluster = requireEnumString(
      object.target_cluster,
      `${label}.target_cluster`,
      TARGET_CLUSTER_VALUES
    );
    const profileSubstrateSource = requireEnumString(
      object.substrate_source,
      `${label}.substrate_source`,
      SUBSTRATE_SOURCE_VALUES
    );
    const profileDistribution = requireEnumString(
      object.distribution,
      `${label}.distribution`,
      DISTRIBUTION_VALUES
    );
    const isMatch = (
      profileTargetCluster === targetCluster &&
      profileSubstrateSource === substrateSource &&
      profileDistribution === distribution
    );
    if (isMatch) {
      found = object;
      foundIndex = index;
    }
  }

  if (!found) {
    fail(`target_profile is not declared: ${targetProfile}`);
  }

  const label = `release_contract.target_profiles[${foundIndex}]`;
  const prerequisites = requireObject(found.prerequisites, `${label}.prerequisites`);
  const metadata = {};
  const hasRequired = Object.prototype.hasOwnProperty.call(found, 'required');
  if (hasRequired) {
    metadata.required = requireBoolean(found.required, `${label}.required`);
  }
  if (Object.prototype.hasOwnProperty.call(found, 'support_level')) {
    metadata.support_level = requireEnumString(
      found.support_level,
      `${label}.support_level`,
      SUPPORT_LEVEL_VALUES
    );
  }
  if (!hasRequired && !metadata.support_level) {
    fail(`${label}.required or ${label}.support_level is required`);
  }
  const prerequisiteFields = [
    'namespace',
    'rbac',
    'ingress',
    'tls',
    'storage_class',
    'registry',
    'pull_secret_ref'
  ];
  const normalizedPrerequisites = {};

  for (const field of prerequisiteFields) {
    if (!Object.prototype.hasOwnProperty.call(prerequisites, field)) {
      fail(`${label}.prerequisites.${field} is required`);
    }
    normalizedPrerequisites[field] = requireString(
      prerequisites[field],
      `${label}.prerequisites.${field}`
    );
  }

  if (!isAllowedPullSecretRef(normalizedPrerequisites.pull_secret_ref)) {
    fail(`${label}.prerequisites.pull_secret_ref is not allowed`);
  }

  return {
    value: targetProfile,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution,
    ...metadata,
    prerequisites: normalizedPrerequisites
  };
}

function isLoopbackHost(hostname) {
  const normalized = hostname.toLowerCase().replace(/^\[(.*)\]$/, '$1');
  return (
    normalized === 'localhost' ||
    normalized === '::' ||
    normalized === '::1' ||
    /^(?:127|0)(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

function isGithubSourceUri(parsed) {
  const host = parsed.hostname.toLowerCase();

  if (host === 'raw.githubusercontent.com' || host === 'codeload.github.com') {
    return true;
  }

  let pathname;
  try {
    pathname = decodeURIComponent(parsed.pathname).toLowerCase();
  } catch {
    return host === 'api.github.com' || host === 'github.com';
  }

  if (host === 'api.github.com') {
    return /^\/repos\/[^/]+\/[^/]+\/(?:contents|git|tarball|zipball|commits|branches|tags)(?:\/|$)/.test(
      pathname
    );
  }
  if (host !== 'github.com') {
    return false;
  }

  if (/^\/[^/]+\/[^/]+(?:\.git)?\/?$/.test(pathname)) {
    return true;
  }

  return /\/(?:archive|raw|blob|tree|tarball|zipball|commit|commits|branches|tags)(?:\/|$)/.test(
    pathname
  );
}

function requireRemoteArtifactUri(value, label) {
  const uri = requireString(value, label);

  if (
    uri !== uri.trim() ||
    LOCAL_URI_RE.test(uri) ||
    LOCALHOST_URI_RE.test(uri) ||
    ABSOLUTE_LOCAL_PATH_RE.test(uri) ||
    RELATIVE_URI_RE.test(uri) ||
    !URI_SCHEME_RE.test(uri)
  ) {
    fail(`${label} must be a remote CI artifact URI`);
  }

  let parsed;
  try {
    parsed = new URL(uri);
  } catch {
    fail(`${label} must be a remote CI artifact URI`);
  }

  const scheme = parsed.protocol.slice(0, -1).toLowerCase();
  if (!['gh-artifact', 'https'].includes(scheme)) {
    fail(`${label} must be a remote CI artifact URI`);
  }
  if (isLoopbackHost(parsed.hostname) || isGithubSourceUri(parsed)) {
    fail(`${label} must be a remote CI artifact URI`);
  }

  return uri;
}

function requireSubjectUri(value, label) {
  const uri = requireString(value, label);

  if (
    uri !== uri.trim() ||
    /[\r\n]/.test(uri) ||
    LOCAL_SCHEME_RE.test(uri) ||
    LOCAL_URI_RE.test(uri) ||
    LOCALHOST_URI_RE.test(uri) ||
    ABSOLUTE_LOCAL_PATH_RE.test(uri) ||
    RELATIVE_URI_RE.test(uri) ||
    WORKSPACE_SOURCE_RE.test(uri)
  ) {
    fail(`${label} must be an artifact subject URI`);
  }

  if (URI_SCHEME_RE.test(uri)) {
    let parsed;
    try {
      parsed = new URL(uri);
    } catch {
      fail(`${label} must be an artifact subject URI`);
    }
    if (isLoopbackHost(parsed.hostname) || isGithubSourceUri(parsed)) {
      fail(`${label} must be an artifact subject URI`);
    }
  }

  return uri;
}

function readAttestation(value, label) {
  if (value === 'none') {
    return 'none';
  }
  if (typeof value === 'undefined') {
    fail(`${label} must be "none" or an object`);
  }

  const attestation = requireObject(value, label);
  const allowedFields = new Set(['attestation_uri', 'attestation_sha256']);
  for (const field of Object.keys(attestation)) {
    if (!allowedFields.has(field)) {
      fail(`${label}.${field} is not allowed`);
    }
  }

  return {
    attestation_uri: requireRemoteArtifactUri(
      attestation.attestation_uri,
      `${label}.attestation_uri`
    ),
    attestation_sha256: requireDigest(
      attestation.attestation_sha256,
      `${label}.attestation_sha256`
    )
  };
}

function readProvenance(payload, label) {
  const provenance = requireObject(payload.artifact_provenance, `${label}.artifact_provenance`);
  assertSchemaVersion(
    provenance.schema_version,
    ARTIFACT_PROVENANCE_SCHEMA,
    `${label}.artifact_provenance.schema_version`
  );

  return {
    schema_version: ARTIFACT_PROVENANCE_SCHEMA,
    provenance_kind: requireString(
      provenance.provenance_kind,
      `${label}.artifact_provenance.provenance_kind`
    ),
    producer_repo: requireString(
      provenance.producer_repo,
      `${label}.artifact_provenance.producer_repo`
    ),
    normalized_remote: requireString(
      provenance.normalized_remote,
      `${label}.artifact_provenance.normalized_remote`
    ),
    commit_sha: requireGitSha(
      provenance.commit_sha,
      `${label}.artifact_provenance.commit_sha`
    ),
    subject_name: requireString(
      provenance.subject_name,
      `${label}.artifact_provenance.subject_name`
    ),
    subject_sha256: requireDigest(
      provenance.subject_sha256,
      `${label}.artifact_provenance.subject_sha256`
    ),
    subject_uri: requireSubjectUri(
      provenance.subject_uri,
      `${label}.artifact_provenance.subject_uri`
    ),
    workflow_name: requireString(
      provenance.workflow_name,
      `${label}.artifact_provenance.workflow_name`
    ),
    run_id: requireString(
      provenance.run_id,
      `${label}.artifact_provenance.run_id`
    ),
    run_attempt: requireString(
      provenance.run_attempt,
      `${label}.artifact_provenance.run_attempt`
    ),
    job: requireString(
      provenance.job,
      `${label}.artifact_provenance.job`
    ),
    artifact_uri: requireRemoteArtifactUri(
      provenance.artifact_uri,
      `${label}.artifact_provenance.artifact_uri`
    ),
    artifact_sha256: requireDigest(
      provenance.artifact_sha256,
      `${label}.artifact_provenance.artifact_sha256`
    ),
    generated_at: requireString(
      provenance.generated_at,
      `${label}.artifact_provenance.generated_at`
    ),
    generator_command: requireString(
      provenance.generator_command,
      `${label}.artifact_provenance.generator_command`
    ),
    generator_version: requireString(
      provenance.generator_version,
      `${label}.artifact_provenance.generator_version`
    ),
    attestation: readAttestation(
      provenance.attestation,
      `${label}.artifact_provenance.attestation`
    )
  };
}

function assertProvenance(contract, deployTemplatePackage, releaseGitSha) {
  const contractProvenance = readProvenance(contract, 'release_contract');
  const packageProvenance = readProvenance(deployTemplatePackage, 'deploy_template_package');

  if (contractProvenance.subject_sha256 !== canonicalSubjectDigest(contract)) {
    fail('release_contract.artifact_provenance.subject_sha256 must match release_contract canonical subject digest');
  }
  if (packageProvenance.subject_sha256 !== canonicalSubjectDigest(deployTemplatePackage)) {
    fail('deploy_template_package.artifact_provenance.subject_sha256 must match deploy_template_package canonical subject digest');
  }

  if (contractProvenance.commit_sha !== releaseGitSha) {
    fail('release_contract.artifact_provenance.commit_sha must match release_contract.git_sha');
  }
  if (packageProvenance.commit_sha !== releaseGitSha) {
    fail('deploy_template_package.artifact_provenance.commit_sha must match release_contract.git_sha');
  }

  for (const [provenance, label] of [
    [contractProvenance, 'release_contract.artifact_provenance'],
    [packageProvenance, 'deploy_template_package.artifact_provenance']
  ]) {
    if (provenance.provenance_kind !== PROVENANCE_KIND) {
      fail(`${label}.provenance_kind must be ${PROVENANCE_KIND}`);
    }
    if (provenance.producer_repo !== provenance.normalized_remote) {
      fail(`${label}.producer_repo must match normalized_remote`);
    }
    if (provenance.producer_repo !== AGENTSMITH_REPO) {
      fail(`${label}.producer_repo must be ${AGENTSMITH_REPO}`);
    }
  }

  if (contractProvenance.subject_name !== CONTRACT_SUBJECT) {
    fail(`release_contract.artifact_provenance.subject_name must be ${CONTRACT_SUBJECT}`);
  }
  if (packageProvenance.subject_name !== DEPLOY_TEMPLATE_PACKAGE_SUBJECT) {
    fail(
      `deploy_template_package.artifact_provenance.subject_name must be ${DEPLOY_TEMPLATE_PACKAGE_SUBJECT}`
    );
  }
  if (packageProvenance.artifact_uri !== deployTemplatePackage.package_uri) {
    fail('deploy_template_package.artifact_provenance.artifact_uri must match package_uri');
  }
  if (packageProvenance.artifact_sha256 !== deployTemplatePackage.package_sha256) {
    fail('deploy_template_package.artifact_provenance.artifact_sha256 must match package_sha256');
  }
  if (contractProvenance.artifact_sha256 !== canonicalArtifactProjectionDigest(contract)) {
    fail(
      'release_contract.artifact_provenance.artifact_sha256 must match release_contract canonical artifact projection digest'
    );
  }

  return {
    release_contract: contractProvenance,
    deploy_template_package: packageProvenance
  };
}

function assertTemplate(contract, deployTemplatePackage) {
  const contractPackage = requireObject(
    contract.deploy_template_package,
    'release_contract.deploy_template_package'
  );

  assertSameJson(
    contractPackage,
    deployTemplatePackage,
    'release_contract.deploy_template_package'
  );

  const contractDigest = requireDigest(
    contract.deploy_template_digest,
    'release_contract.deploy_template_digest'
  );
  const packageDigest = requireDigest(
    deployTemplatePackage.manifest_sha256,
    'deploy_template_package.manifest_sha256'
  );

  if (contractDigest !== packageDigest) {
    fail('release_contract.deploy_template_digest must match deploy_template_package.manifest_sha256');
  }

  for (const field of ['package_uri', 'package_sha256']) {
    if (contractPackage[field] !== deployTemplatePackage[field]) {
      fail(`release_contract.deploy_template_package.${field} must match deploy_template_package.${field}`);
    }
  }

  assertSameJson(
    requireObject(
      contractPackage.artifact_provenance,
      'release_contract.deploy_template_package.artifact_provenance'
    ),
    requireObject(
      deployTemplatePackage.artifact_provenance,
      'deploy_template_package.artifact_provenance'
    ),
    'deploy_template_package.artifact_provenance'
  );
}

function isAllowedSecretRef(label, value) {
  return (
    TARGET_PULL_SECRET_REF_RE.test(label) &&
    isAllowedPullSecretRef(value)
  );
}

function isSafeSecretReference(label, value) {
  return (
    SAFE_REDACTED_SECRET_RE.test(value) ||
    isSecretRefValue(value) ||
    isAllowedSecretRef(label, value)
  );
}

function assertSchemaVersion(value, expected, label) {
  const schemaVersion = requireString(value, label);
  if (schemaVersion !== expected) {
    fail(`${label} must be ${expected}`);
  }
}

function isRelativeSourcePath(value, label) {
  const trimmed = value.trim();
  return (
    SOURCE_LIKE_LABEL_RE.test(label) &&
    !URI_SCHEME_RE.test(trimmed) &&
    /^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)+$/.test(trimmed)
  );
}

function isGithubSourceLikeUri(value, label) {
  const trimmed = value.trim();
  if (!SOURCE_LIKE_LABEL_RE.test(label) || !URI_SCHEME_RE.test(trimmed)) {
    return false;
  }

  try {
    return isGithubSourceUri(new URL(trimmed));
  } catch {
    return false;
  }
}

function scanForUnsafePayload(value, label, issues = []) {
  if (typeof value === 'string') {
    if (
      LOCAL_URI_RE.test(value) ||
      LOCALHOST_URI_RE.test(value) ||
      ABSOLUTE_LOCAL_PATH_RE.test(value) ||
      RELATIVE_URI_RE.test(value) ||
      isRelativeSourcePath(value, label) ||
      isGithubSourceLikeUri(value, label) ||
      WORKSPACE_SOURCE_RE.test(value)
    ) {
      issues.push(`${label} contains a local or source URI`);
    }

    if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
      issues.push(`${label} contains a secret-looking value`);
    }
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
        !isSafeSecretReference(nestedLabel, nested)
      ) {
        issues.push(`${nestedLabel} contains a secret-looking payload`);
      }
      scanForUnsafePayload(nested, nestedLabel, issues);
    }
  }

  return issues;
}

function assertNoUnsafePayload(contract, deployTemplatePackage) {
  const issues = [
    ...scanForUnsafePayload(contract, 'release_contract'),
    ...scanForUnsafePayload(deployTemplatePackage, 'deploy_template_package')
  ];

  if (issues.length > 0) {
    fail(issues[0]);
  }
}

function assertReleaseIdentity(contract) {
  assertSchemaVersion(
    contract.schema_version,
    RELEASE_CONTRACT_SCHEMA,
    'release_contract.schema_version'
  );
  const product = requireString(contract.product, 'release_contract.product');
  if (product !== AGENTSMITH_PRODUCT) {
    fail('release_contract.product must be agentsmith');
  }
  requireString(contract.release_id, 'release_contract.release_id');
  requireDigest(contract.openapi_digest, 'release_contract.openapi_digest');
  requireDigest(contract.asyncapi_digest, 'release_contract.asyncapi_digest');
  assertSchemaVersion(
    contract.substrate_connection_schema,
    SUBSTRATE_CONNECTION_SCHEMA,
    'release_contract.substrate_connection_schema'
  );
  requireString(contract.min_release_kit_version, 'release_contract.min_release_kit_version');
  return requireGitSha(contract.git_sha, 'release_contract.git_sha');
}

function assertDeployTemplatePackageIdentity(deployTemplatePackage) {
  assertSchemaVersion(
    deployTemplatePackage.schema_version,
    DEPLOY_TEMPLATE_PACKAGE_SCHEMA,
    'deploy_template_package.schema_version'
  );
  requireRemoteArtifactUri(deployTemplatePackage.package_uri, 'deploy_template_package.package_uri');
  requireDigest(deployTemplatePackage.package_sha256, 'deploy_template_package.package_sha256');
  requireDigest(deployTemplatePackage.manifest_sha256, 'deploy_template_package.manifest_sha256');
  requireObject(
    deployTemplatePackage.artifact_provenance,
    'deploy_template_package.artifact_provenance'
  );
}

function buildEvidence({
  contract,
  deployTemplatePackage,
  targetProfile,
  images,
  inputDigests,
  provenance
}) {
  const digests = images.map((item) => ({
    source: item.source,
    id: item.id,
    digest: item.digest,
    status: 'planned'
  }));

  return {
    scope: 'contract_intake_only',
    readiness: false,
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    target_profile: targetProfile,
    artifacts: {
      release_contract: {
        input_sha256: inputDigests.releaseContract,
        artifact_uri: provenance.release_contract.artifact_uri,
        artifact_sha256: provenance.release_contract.artifact_sha256,
        provenance: provenance.release_contract
      },
      deploy_template_package: {
        input_sha256: inputDigests.deployTemplatePackage,
        package_uri: deployTemplatePackage.package_uri,
        package_sha256: deployTemplatePackage.package_sha256,
        manifest_sha256: deployTemplatePackage.manifest_sha256,
        artifact_uri: provenance.deploy_template_package.artifact_uri,
        artifact_sha256: provenance.deploy_template_package.artifact_sha256,
        provenance: provenance.deploy_template_package
      }
    },
    images,
    digests,
    status: 'pass'
  };
}

async function writeEvidence(outputDir, evidence) {
  await fs.mkdir(outputDir, { recursive: true });
  const body = `${JSON.stringify(evidence, null, 2)}\n`;

  await Promise.all([
    fs.writeFile(path.join(outputDir, 'intake-report.json'), body),
    fs.writeFile(path.join(outputDir, 'image-digest-plan.json'), body)
  ]);
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
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const deployTemplatePackage = requireObject(
    deployTemplatePackageInput.value,
    'deploy_template_package'
  );

  assertNoUnsafePayload(contract, deployTemplatePackage);
  const releaseGitSha = assertReleaseIdentity(contract);
  assertDeployTemplatePackageIdentity(deployTemplatePackage);
  assertTemplate(contract, deployTemplatePackage);
  const images = assertImageInventory(contract);
  assertProductFlowShape(contract);
  const targetProfile = assertTargetProfile(contract, args.targetProfile);
  const provenance = assertProvenance(contract, deployTemplatePackage, releaseGitSha);

  await writeEvidence(
    args.outputDir,
    buildEvidence({
      contract,
      deployTemplatePackage,
      targetProfile,
      images,
      inputDigests: {
        releaseContract: releaseContractInput.inputDigest,
        deployTemplatePackage: deployTemplatePackageInput.inputDigest
      },
      provenance
    })
  );
  console.log('PASS: release contract intake accepted');
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
