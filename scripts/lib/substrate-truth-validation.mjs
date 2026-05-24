import {
  SUPPORTED_FOCUSED_TARGET_PROFILE_SET,
  requirePlainSemver
} from './release-kit-version-policy.mjs';

export const SUBSTRATE_CONNECTION_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
export const TARGET_CLUSTER_VALUES = new Set(['existing_kubernetes', 'kind_rehearsal']);
export const SUBSTRATE_SOURCE_VALUES = new Set(['external_declared', 'kit_installed']);
export const DISTRIBUTION_VALUES = new Set(['online', 'airgap']);

const REQUIRED_SERVICES = ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc'];
const SECRET_REF_PREFIX = 'secretRef:';
const FINGERPRINT_RE = /^(?:redacted|fingerprint):sha256:[0-9a-f]{64}$/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_URI_RE = /\b(?:file|local|source|git\+file):\/\//i;
const LOCAL_SCHEME_RE = /^(?:file|local|source|git\+file):/i;
const LOCALHOST_URI_RE = /\bhttps?:\/\/(?:localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|0\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[?(?:::|::1)\]?|host\.docker\.internal)(?::\d+)?(?:[/?#]|$)/i;
const HOST_DOCKER_INTERNAL_RE = /(^|[^A-Za-z0-9.-])host\.docker\.internal(?=$|[^A-Za-z0-9.-])/i;
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
  'verified_by_operator'
]);
const VECTOR_STATUS_VALUES = new Set(['installed']);
const ENDPOINT_FIELD_NAMES = ['endpoint', 'host', 'url', 'issuer', 'issuer_url'];

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

function fail(message) {
  throw new ValidationError(message);
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

export function isSafeSecretReference(value) {
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
    HOST_DOCKER_INTERNAL_RE.test(value) ||
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

export function assertNoUnsafeSubstratePayload(value, label, raw) {
  const issues = [];
  if (typeof raw === 'string') {
    scanUnsafeString(raw, `${label} raw`, issues);
  }
  scanPayload(value, label, issues);
  if (issues.length > 0) {
    fail(issues[0]);
  }
}

export function parseTargetProfile(targetProfile) {
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

  if (!SUPPORTED_FOCUSED_TARGET_PROFILE_SET.has(value)) {
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

function formatAllowedFields(fields) {
  return fields.join(' or ');
}

function assertEndpoint(service, label, allowedFields = ['host']) {
  const allowed = new Set(allowedFields);
  for (const field of ENDPOINT_FIELD_NAMES) {
    if (!allowed.has(field) && Object.prototype.hasOwnProperty.call(service, field)) {
      fail(`${label}.${field} is not allowed; use ${formatAllowedFields(allowedFields)}`);
    }
  }

  const present = allowedFields.filter((field) =>
    Object.prototype.hasOwnProperty.call(service, field)
  );
  if (present.length === 0) {
    fail(`${label} must include ${formatAllowedFields(allowedFields)}`);
  }

  for (const field of present) {
    assertEndpointValue(service[field], `${label}.${field}`);
  }

  return service[present[0]];
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

function assertVectorExtension(postgresql, label) {
  const extensions = requireObject(postgresql.extensions, `${label}.extensions`);
  if (Object.prototype.hasOwnProperty.call(extensions, 'vector')) {
    fail(`${label}.extensions.vector is not allowed; use ${label}.extensions.pgvector`);
  }
  const pgvector = extensions.pgvector;
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

function assertServices(truth, label) {
  const services = requireObject(truth.services, `${label}.services`);
  const missing = REQUIRED_SERVICES.filter(
    (service) => !Object.prototype.hasOwnProperty.call(services, service)
  );
  if (missing.length > 0) {
    fail(`${label}.services missing required service: ${missing[0]}`);
  }

  const postgresql = assertBaseService(
    services.postgresql,
    `${label}.services.postgresql`,
    ['credential_secret_ref', 'admin_secret_ref'],
    ['host']
  );
  assertVectorExtension(postgresql, `${label}.services.postgresql`);

  assertBaseService(
    services.mongodb,
    `${label}.services.mongodb`,
    ['credential_secret_ref'],
    ['host']
  );
  assertBaseService(
    services.redis,
    `${label}.services.redis`,
    ['credential_secret_ref'],
    ['host']
  );

  const objectStorage = assertBaseService(
    services.object_storage,
    `${label}.services.object_storage`,
    ['credential_secret_ref'],
    ['url', 'endpoint']
  );
  requireString(objectStorage.bucket, `${label}.services.object_storage.bucket`);
  requireString(objectStorage.region, `${label}.services.object_storage.region`);

  const oidc = assertBaseService(
    services.oidc,
    `${label}.services.oidc`,
    ['client_secret_ref'],
    ['issuer_url']
  );
  requireString(oidc.client_id, `${label}.services.oidc.client_id`);

  return {
    services_count: REQUIRED_SERVICES.length,
    services: [...REQUIRED_SERVICES]
  };
}

function assertTruthIdentity(truth, targetProfile, label, requiredSubstrateSource) {
  assertSchemaVersion(
    truth.schema_version,
    SUBSTRATE_CONNECTION_SCHEMA,
    `${label}.schema_version`
  );

  const targetCluster = requireEnumString(
    truth.target_cluster,
    `${label}.target_cluster`,
    TARGET_CLUSTER_VALUES
  );
  const substrateSource = requireEnumString(
    truth.substrate_source,
    `${label}.substrate_source`,
    SUBSTRATE_SOURCE_VALUES
  );
  const distribution = requireEnumString(
    truth.distribution,
    `${label}.distribution`,
    DISTRIBUTION_VALUES
  );

  if (requiredSubstrateSource && substrateSource !== requiredSubstrateSource) {
    fail(`${label}.substrate_source must be ${requiredSubstrateSource}`);
  }

  const value = `${targetCluster}/${substrateSource}/${distribution}`;
  if (value !== targetProfile.value) {
    fail(`${label} target axes must match CLI target_profile`);
  }

  if (substrateSource === 'external_declared') {
    requireString(truth.declared_by, `${label}.declared_by`);
  }

  if (substrateSource === 'kit_installed') {
    const installedBy = requireString(truth.installed_by, `${label}.installed_by`);
    if (installedBy !== 'agentsmith-release-kit') {
      fail(`${label}.installed_by must be agentsmith-release-kit`);
    }
    requirePlainSemver(
      truth.release_kit_version,
      `${label}.release_kit_version`,
      fail
    );
  }

  return {
    value,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

export function validateSubstrateConnectionTruth(
  value,
  targetProfile,
  { label = 'substrate_truth', requiredSubstrateSource } = {}
) {
  const truth = requireObject(value, label);
  const truthProfile = assertTruthIdentity(
    truth,
    targetProfile,
    label,
    requiredSubstrateSource
  );
  const serviceSummary = assertServices(truth, label);
  return {
    truth,
    truthProfile,
    serviceSummary
  };
}
