#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = ['targetProfile', 'substrateTruth', 'outputDir'];
const SUBSTRATE_CONNECTION_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
const TARGET_CLUSTER_VALUES = new Set(['existing_kubernetes', 'kind_rehearsal']);
const SUBSTRATE_SOURCE_VALUES = new Set(['external_declared', 'kit_installed']);
const DISTRIBUTION_VALUES = new Set(['online', 'airgap']);
const SUPPORTED_TARGET_PROFILES = new Set([
  'existing_kubernetes/external_declared/online',
  'kind_rehearsal/kit_installed/online'
]);
const REQUIRED_SERVICES = ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc'];
const SECRET_REF_PREFIX = 'secretRef:';
const FINGERPRINT_RE = /^(?:redacted|fingerprint):sha256:[0-9a-f]{64}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCAL_SCHEME_RE = /^(?:file|local|source|git\+file):/i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|0\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[?(?:::|::1)\]?|host\.docker\.internal)(?::\d+)?(?:[/?#]|$)/i;
const RELATIVE_URI_RE = /(^|[\s"'(=])\.\.?\//;
const ABSOLUTE_LOCAL_PATH_RE = /(^|[\s"'(=])(?:~\/|\/(?:Users|home|tmp|var|private|workspace|workspaces|mnt|opt|etc)\/|[A-Za-z]:[\\/])/;
const AGENTSMITH_SOURCE_PATH_RE = /\/home\/[^/]+\/works\/[^/]+\/agentsmith(?:\/|$)/i;
const SOURCE_LIKE_LABEL_RE = /(?:^|\.)(?:source_uri|source_path|local_path|path|file|dir|kubeconfig)$/;
const SECRET_KEY_RE = /(^|[_-])(password|passwd|pwd|token|secret|client_secret|private_key|kubeconfig|access_key|api_key)([_-]|$)/i;
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
const REACHABILITY_STATUS_VALUES = new Set([
  'declared_reachable',
  'verified_by_operator',
  'reachable',
  'passed'
]);
const VECTOR_STATUS_VALUES = new Set(['installed', 'enabled', 'available']);

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
  node scripts/verify-target-preflight.mjs \\
    --target-profile <target_cluster>/<substrate_source>/<distribution> \\
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
      case '--target-profile':
        parsed.targetProfile = nextValue();
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

function isLoopbackHost(hostname) {
  const normalized = hostname.toLowerCase().replace(/^\[(.*)\]$/, '$1');
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::' ||
    normalized === '::1' ||
    /^(?:127|0)(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

function isSecretRefValue(value) {
  if (typeof value !== 'string' || !value.startsWith(SECRET_REF_PREFIX)) {
    return false;
  }
  const ref = value.slice(SECRET_REF_PREFIX.length);
  return ref.trim() !== '' && !/[\r\n]/.test(ref) && !/^[\s:]+$/.test(ref);
}

function isRedactedFingerprint(value) {
  return typeof value === 'string' && FINGERPRINT_RE.test(value);
}

function isSafeSecretReference(value) {
  return isSecretRefValue(value) || isRedactedFingerprint(value);
}

function isRelativeSourcePath(value, label) {
  const trimmed = value.trim();
  return (
    SOURCE_LIKE_LABEL_RE.test(label) &&
    !URI_SCHEME_RE.test(trimmed) &&
    /^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)+$/.test(trimmed)
  );
}

function scanUnsafeString(value, label, issues) {
  if (
    LOCAL_SCHEME_RE.test(value) ||
    LOCAL_URI_RE.test(value) ||
    LOCALHOST_URI_RE.test(value) ||
    ABSOLUTE_LOCAL_PATH_RE.test(value) ||
    RELATIVE_URI_RE.test(value) ||
    AGENTSMITH_SOURCE_PATH_RE.test(value) ||
    isRelativeSourcePath(value, label)
  ) {
    issues.push(`${label} contains a local or source URI`);
  }

  if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
    issues.push(`${label} contains a secret-looking value`);
  }
}

function scanPayload(value, label, issues = []) {
  if (typeof value === 'string') {
    scanUnsafeString(value, label, issues);
    return issues;
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      scanPayload(item, `${label}[${index}]`, issues);
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
      scanPayload(nested, nestedLabel, issues);
    }
  }

  return issues;
}

function assertNoUnsafePayload(value, label, raw) {
  const issues = [];
  scanUnsafeString(raw, `${label} raw`, issues);
  scanPayload(value, label, issues);
  if (issues.length > 0) {
    fail(issues[0]);
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
  const parsed = {
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

  if (!SUPPORTED_TARGET_PROFILES.has(value)) {
    fail(`target_profile is not supported by target preflight: ${value}`);
  }

  return parsed;
}

function requireSecretReference(value, label) {
  const text = requireString(value, label);
  if (!isSafeSecretReference(text)) {
    fail(`${label} must be a secretRef or redacted fingerprint`);
  }
  return text;
}

function assertEndpointValue(value, label) {
  const text = requireString(value, label);
  const issues = [];
  scanUnsafeString(text, label, issues);
  if (issues.length > 0) {
    fail(issues[0]);
  }

  if (URI_SCHEME_RE.test(text)) {
    let parsed;
    try {
      parsed = new URL(text);
    } catch {
      fail(`${label} must be a valid endpoint URI`);
    }
    if (isLoopbackHost(parsed.hostname)) {
      fail(`${label} must not use a local or Docker-only endpoint`);
    }
  } else if (isLoopbackHost(text)) {
    fail(`${label} must not use a local or Docker-only host`);
  }

  return text;
}

function assertEndpoint(service, label, fields = ['endpoint', 'host', 'url']) {
  for (const field of fields) {
    if (Object.prototype.hasOwnProperty.call(service, field)) {
      return assertEndpointValue(service[field], `${label}.${field}`);
    }
  }
  fail(`${label} must include endpoint, host, or url`);
}

function assertTlsInfo(service, label) {
  const hasSslmode = Object.prototype.hasOwnProperty.call(service, 'sslmode');
  const hasTls = Object.prototype.hasOwnProperty.call(service, 'tls');
  if (!hasSslmode && !hasTls) {
    fail(`${label} must include tls or sslmode`);
  }

  if (hasSslmode) {
    const sslmode = requireString(service.sslmode, `${label}.sslmode`).toLowerCase();
    if (['disable', 'disabled', 'none'].includes(sslmode)) {
      fail(`${label}.sslmode must not disable TLS`);
    }
  }

  if (hasTls) {
    const tls = requireObject(service.tls, `${label}.tls`);
    if (Object.keys(tls).length === 0) {
      fail(`${label}.tls must not be empty`);
    }
    if (tls.enabled === false) {
      fail(`${label}.tls.enabled must not be false`);
    }
    if (Object.prototype.hasOwnProperty.call(tls, 'mode')) {
      const mode = requireString(tls.mode, `${label}.tls.mode`).toLowerCase();
      if (['disable', 'disabled', 'none'].includes(mode)) {
        fail(`${label}.tls.mode must not disable TLS`);
      }
    }
    for (const [key, nested] of Object.entries(tls)) {
      if (SECRET_KEY_RE.test(key) && typeof nested === 'string') {
        requireSecretReference(nested, `${label}.tls.${key}`);
      }
    }
  }
}

function assertReachability(service, label) {
  const reachability = requireObject(service.reachability, `${label}.reachability`);
  const status = requireEnumString(
    reachability.status,
    `${label}.reachability.status`,
    REACHABILITY_STATUS_VALUES
  );
  const proof = requireString(reachability.proof, `${label}.reachability.proof`);
  return { status, proof };
}

function assertSecretFields(service, label, fields) {
  for (const field of fields) {
    requireSecretReference(service[field], `${label}.${field}`);
  }
}

function assertVectorExtension(postgresql) {
  const label = 'substrate_truth.services.postgresql';
  const extensions = requireObject(postgresql.extensions, `${label}.extensions`);
  const pgvector = extensions.pgvector || extensions.vector;
  const vector = requireObject(pgvector, `${label}.extensions.pgvector`);
  const status = requireEnumString(
    vector.status,
    `${label}.extensions.pgvector.status`,
    VECTOR_STATUS_VALUES
  );
  return {
    status,
    version: typeof vector.version === 'string' ? vector.version : undefined
  };
}

function assertBaseService(service, label, secretFields, endpointFields) {
  const object = requireObject(service, label);
  assertEndpoint(object, label, endpointFields);
  assertSecretFields(object, label, secretFields);
  assertTlsInfo(object, label);
  assertReachability(object, label);
  return object;
}

function assertServices(truth) {
  const services = requireObject(truth.services, 'substrate_truth.services');
  const missing = REQUIRED_SERVICES.filter(
    (service) => !Object.prototype.hasOwnProperty.call(services, service)
  );
  if (missing.length > 0) {
    fail(`substrate_truth.services missing required service: ${missing[0]}`);
  }

  const postgresql = assertBaseService(
    services.postgresql,
    'substrate_truth.services.postgresql',
    ['credential_secret_ref', 'admin_secret_ref']
  );
  assertVectorExtension(postgresql);

  assertBaseService(
    services.mongodb,
    'substrate_truth.services.mongodb',
    ['credential_secret_ref']
  );
  assertBaseService(
    services.redis,
    'substrate_truth.services.redis',
    ['credential_secret_ref']
  );

  const objectStorage = assertBaseService(
    services.object_storage,
    'substrate_truth.services.object_storage',
    ['credential_secret_ref']
  );
  requireString(objectStorage.bucket, 'substrate_truth.services.object_storage.bucket');
  if (
    !Object.prototype.hasOwnProperty.call(objectStorage, 'region') &&
    !Object.prototype.hasOwnProperty.call(objectStorage, 'endpoint') &&
    !Object.prototype.hasOwnProperty.call(objectStorage, 'url')
  ) {
    fail('substrate_truth.services.object_storage must include region or endpoint');
  }

  const oidc = assertBaseService(
    services.oidc,
    'substrate_truth.services.oidc',
    ['client_secret_ref'],
    ['issuer_url', 'issuer', 'endpoint', 'url', 'host']
  );
  requireString(oidc.client_id, 'substrate_truth.services.oidc.client_id');
  const issuer = oidc.issuer_url || oidc.issuer;
  assertEndpointValue(issuer, 'substrate_truth.services.oidc.issuer_url');

  return {
    services_count: REQUIRED_SERVICES.length,
    services: [...REQUIRED_SERVICES]
  };
}

function assertTruthIdentity(truth, targetProfile) {
  assertSchemaVersion(
    truth.schema_version,
    SUBSTRATE_CONNECTION_SCHEMA,
    'substrate_truth.schema_version'
  );

  const targetCluster = requireEnumString(
    truth.target_cluster,
    'substrate_truth.target_cluster',
    TARGET_CLUSTER_VALUES
  );
  const substrateSource = requireEnumString(
    truth.substrate_source,
    'substrate_truth.substrate_source',
    SUBSTRATE_SOURCE_VALUES
  );
  const distribution = requireEnumString(
    truth.distribution,
    'substrate_truth.distribution',
    DISTRIBUTION_VALUES
  );

  const value = `${targetCluster}/${substrateSource}/${distribution}`;
  if (value !== targetProfile.value) {
    fail('substrate_truth target axes must match CLI target_profile');
  }

  if (substrateSource === 'external_declared') {
    requireString(truth.declared_by, 'substrate_truth.declared_by');
  }

  if (substrateSource === 'kit_installed') {
    const installedBy = requireString(truth.installed_by, 'substrate_truth.installed_by');
    if (installedBy !== 'agentsmith-release-kit') {
      fail('substrate_truth.installed_by must be agentsmith-release-kit');
    }
    requireString(truth.release_kit_version, 'substrate_truth.release_kit_version');
  }

  return {
    value,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function buildReport({ targetProfile, truthProfile, inputDigest, serviceSummary }) {
  return {
    scope: 'target_preflight_intake_only',
    readiness: false,
    target_profile: targetProfile,
    substrate_truth: {
      schema_version: SUBSTRATE_CONNECTION_SCHEMA,
      input_sha256: inputDigest,
      target_profile: truthProfile,
      services_count: serviceSummary.services_count,
      services: serviceSummary.services
    },
    checks: {
      schema: 'pass',
      target_axes: 'pass',
      service_contracts: 'pass',
      secret_references: 'pass',
      tls_or_sslmode: 'pass',
      reachability: 'pass'
    },
    status: 'pass'
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(
    path.join(outputDir, 'target-preflight-report.json'),
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
  const substrateTruthInput = await readJson(args.substrateTruth, 'substrate truth');
  const truth = requireObject(substrateTruthInput.value, 'substrate_truth');
  assertNoUnsafePayload(truth, 'substrate_truth', substrateTruthInput.raw);
  const truthProfile = assertTruthIdentity(truth, targetProfile);
  const serviceSummary = assertServices(truth);

  await writeReport(
    args.outputDir,
    buildReport({
      targetProfile,
      truthProfile,
      inputDigest: substrateTruthInput.inputDigest,
      serviceSummary
    })
  );
  console.log('PASS: target preflight truth accepted');
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
