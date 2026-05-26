import {
  DISTRIBUTION_VALUES,
  SUBSTRATE_SOURCE_VALUES,
  TARGET_CLUSTER_VALUES,
  TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_SET,
  TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_VALUES,
  requirePlainSemver
} from './release-kit-version-policy.mjs';

export { DISTRIBUTION_VALUES, SUBSTRATE_SOURCE_VALUES, TARGET_CLUSTER_VALUES };

export const SUBSTRATE_CONNECTION_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
export const TARGET_PREREQUISITES_SCHEMA = 'agentsmith.target-prerequisites.truth/v1';

const REQUIRED_SERVICES = ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc'];
const SUBSTRATE_TRUTH_FIELDS = [
  'schema_version',
  'target_cluster',
  'substrate_source',
  'distribution',
  'declared_at',
  'declared_by',
  'installed_by',
  'release_kit_version',
  'installation_id',
  'services'
];
const TARGET_PREREQUISITES_FIELDS = [
  'schema_version',
  'target_profile',
  'namespace',
  'rbac',
  'ingress',
  'registry',
  'storage',
  'substrate_secret_refs'
];
const SECRET_REF_PREFIX = 'secretRef:';
const FINGERPRINT_RE = /^(?:redacted|fingerprint):sha256:[0-9a-f]{64}$/;
const KUBERNETES_NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
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

function assertAllowedObjectFields(value, label, allowedFields) {
  const allowed = new Set(allowedFields);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
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

function endpointHostnameCandidate(text) {
  const trimmed = text.trim();
  const bracketed = trimmed.match(/^\[([^\]]+)\](?::[^:/?#\s@]+)?$/);
  if (bracketed) {
    return bracketed[1];
  }

  const hostWithPort = trimmed.match(/^([^:/?#\s@]+):[^:/?#\s@]+$/);
  if (hostWithPort) {
    return hostWithPort[1];
  }

  return trimmed;
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

  if (!TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_SET.has(value)) {
    fail(
      `target_profile must be one of canonical target preflight profiles: ${TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_VALUES.join(
        ', '
      )}`
    );
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
    if (parsed.username || parsed.password) {
      fail(`${label} must not include userinfo`);
    }
    if (isLoopbackHost(parsed.hostname)) {
      fail(`${label} must not use a local or Docker-only endpoint`);
    }
  } else if (isLoopbackHost(endpointHostnameCandidate(text))) {
    fail(`${label} must not use a local or Docker-only host`);
  } else if (text.includes('@')) {
    fail(`${label} must not include userinfo`);
  }

  return text;
}

function assertKubernetesNamespace(value, label) {
  const namespace = requireString(value, label);
  if (
    namespace.length > 63 ||
    !KUBERNETES_NAMESPACE_RE.test(namespace)
  ) {
    fail(`${label} must be a Kubernetes namespace name`);
  }
  return namespace;
}

function assertIngressHost(value, label) {
  const host = requireString(value, label);
  const issues = [];
  scanUnsafeString(host, label, issues);
  if (issues.length > 0) {
    fail(issues[0]);
  }
  if (
    URI_SCHEME_RE.test(host) ||
    host.includes('@') ||
    host.includes('/') ||
    host.includes(':') ||
    /\s/.test(host)
  ) {
    fail(`${label} must be a host without scheme, path, port, or userinfo`);
  }
  if (isLoopbackHost(host)) {
    fail(`${label} must not use a local or Docker-only host`);
  }
  return host;
}

function assertNonDisabledString(value, label) {
  const text = requireString(value, label);
  if (['disable', 'disabled', 'none', 'not_required'].includes(text.toLowerCase())) {
    fail(`${label} must not disable the prerequisite`);
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

function collectSafeSecretReferences(value, refs = new Set()) {
  if (Array.isArray(value)) {
    for (const item of value) {
      collectSafeSecretReferences(item, refs);
    }
    return refs;
  }

  if (!value || typeof value !== 'object') {
    return refs;
  }

  for (const [key, nested] of Object.entries(value)) {
    if (
      SECRET_KEY_RE.test(key) &&
      typeof nested === 'string' &&
      isSafeSecretReference(nested)
    ) {
      refs.add(nested);
    }
    collectSafeSecretReferences(nested, refs);
  }
  return refs;
}

function assertTargetProfilePrerequisites(prerequisites, targetProfile, label) {
  assertSchemaVersion(
    prerequisites.schema_version,
    TARGET_PREREQUISITES_SCHEMA,
    `${label}.schema_version`
  );

  const targetProfileValue = requireString(
    prerequisites.target_profile,
    `${label}.target_profile`
  );
  if (targetProfileValue !== targetProfile.value) {
    fail(`${label}.target_profile must match CLI target_profile`);
  }
  return targetProfileValue;
}

function assertRbacPrerequisite(value, label) {
  const rbac = requireObject(value, label);
  const hasPolicy = Object.prototype.hasOwnProperty.call(rbac, 'policy');
  const hasProof = Object.prototype.hasOwnProperty.call(rbac, 'proof');
  if (!hasPolicy && !hasProof) {
    fail(`${label} must include policy or proof`);
  }
  if (hasPolicy) {
    assertNonDisabledString(rbac.policy, `${label}.policy`);
  }
  if (hasProof) {
    requireString(rbac.proof, `${label}.proof`);
  }
  return {
    policy: hasPolicy ? rbac.policy : undefined,
    proof: hasProof ? rbac.proof : undefined
  };
}

function assertTargetSecretRefs(value, label, expectedRefs) {
  const refs = requireArray(value, label).map((item, index) =>
    requireSecretReference(item, `${label}[${index}]`)
  );
  const actualRefs = new Set(refs);
  for (const expectedRef of expectedRefs) {
    if (!actualRefs.has(expectedRef)) {
      fail(`${label} missing substrate secret ref: ${expectedRef}`);
    }
  }
  for (const actualRef of actualRefs) {
    if (!expectedRefs.has(actualRef)) {
      fail(`${label} includes substrate secret ref not declared by substrate truth: ${actualRef}`);
    }
  }
  return {
    count: actualRefs.size,
    refs: [...actualRefs].sort()
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
  assertAllowedObjectFields(truth, label, SUBSTRATE_TRUTH_FIELDS);
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

export function validateTargetPrerequisitesTruth(
  value,
  targetProfile,
  substrateTruth,
  { label = 'target_prerequisites', expectedNamespace } = {}
) {
  const prerequisites = requireObject(value, label);
  assertAllowedObjectFields(prerequisites, label, TARGET_PREREQUISITES_FIELDS);
  const targetProfileValue = assertTargetProfilePrerequisites(
    prerequisites,
    targetProfile,
    label
  );

  const namespace = assertKubernetesNamespace(
    prerequisites.namespace,
    `${label}.namespace`
  );
  if (expectedNamespace && namespace !== expectedNamespace) {
    fail(`${label}.namespace must match --expected-namespace`);
  }

  assertRbacPrerequisite(prerequisites.rbac, `${label}.rbac`);

  const ingress = requireObject(prerequisites.ingress, `${label}.ingress`);
  const ingressHost = assertIngressHost(ingress.host, `${label}.ingress.host`);
  requireSecretReference(
    ingress.tls_secret_ref,
    `${label}.ingress.tls_secret_ref`
  );

  const registry = requireObject(prerequisites.registry, `${label}.registry`);
  assertAllowedObjectFields(registry, `${label}.registry`, ['pull_secret_ref']);
  requireSecretReference(
    registry.pull_secret_ref,
    `${label}.registry.pull_secret_ref`
  );

  const storage = requireObject(prerequisites.storage, `${label}.storage`);
  assertNonDisabledString(
    storage.storage_class,
    `${label}.storage.storage_class`
  );
  assertNonDisabledString(
    storage.persistent_volume_policy,
    `${label}.storage.persistent_volume_policy`
  );

  const expectedSubstrateRefs = collectSafeSecretReferences(
    requireObject(substrateTruth, 'substrate_truth')
  );
  const substrateRefsSummary = assertTargetSecretRefs(
    prerequisites.substrate_secret_refs,
    `${label}.substrate_secret_refs`,
    expectedSubstrateRefs
  );

  return {
    prerequisites,
    prerequisitesSummary: {
      schema_version: TARGET_PREREQUISITES_SCHEMA,
      target_profile: targetProfileValue,
      namespace,
      ingress_host: ingressHost,
      substrate_secret_refs_count: substrateRefsSummary.count
    }
  };
}
