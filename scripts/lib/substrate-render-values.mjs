const SECRET_REF_PREFIX = 'secretRef:';
const KUBERNETES_NAMESPACE_RE = /^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$/;
const KUBERNETES_DNS_LABEL_RE = /^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$/;
const KUBERNETES_SECRET_NAME_MAX_LENGTH = 253;
const TLS_DISABLED_VALUES = new Set([
  'disable',
  'disabled',
  'none',
  'false',
  'off',
  'http',
  'plain',
  'plaintext',
  '0',
  'no'
]);
const TLS_MODE_RE = /^[A-Za-z0-9_.-]+$/;
const SECRET_NAME_KEY_RE = /(^|_)SECRET_NAME$/i;
const AFSCP_VOLUME_REF_KEY = 'AFSCP_VOLUME_REF';
const AFSCP_VOLUME_REF_REVISION_KEY = 'AFSCP_VOLUME_REF_REVISION';
const AFSCP_RUNTIME_SECRETS_CHECKSUM_KEY = 'AFSCP_RUNTIME_SECRETS_CHECKSUM';
const SHA256_REVISION_RE = /^sha256:([0-9a-fA-F]{64})$/;

const SUBSTRATE_SERVICE_RENDER_BINDINGS = [
  {
    service: 'postgresql',
    label: 'postgresql',
    prefixes: ['SUBSTRATE_POSTGRES', 'SUBSTRATE_POSTGRESQL'],
    sslmodeKeys: ['SUBSTRATE_POSTGRES_SSLMODE', 'SUBSTRATE_POSTGRESQL_SSLMODE']
  },
  {
    service: 'mongodb',
    label: 'mongodb',
    prefixes: ['SUBSTRATE_MONGODB']
  },
  {
    service: 'redis',
    label: 'redis',
    prefixes: ['SUBSTRATE_REDIS']
  },
  {
    service: 'object_storage',
    label: 'object_storage',
    prefixes: ['SUBSTRATE_MINIO', 'SUBSTRATE_OBJECT_STORAGE']
  },
  {
    service: 'oidc',
    label: 'oidc',
    prefixes: ['SUBSTRATE_KEYCLOAK', 'SUBSTRATE_OIDC']
  }
];

const KNOWN_RENDER_VALUE_KEYS = new Set(
  SUBSTRATE_SERVICE_RENDER_BINDINGS.flatMap((binding) => [
    ...binding.prefixes.flatMap((prefix) => [
      `${prefix}_CA_SECRET_REF`,
      `${prefix}_CA_SECRET_NAME`,
      `${prefix}_TLS_MODE`,
      `${prefix}_USE_SSL`
    ]),
    ...(binding.sslmodeKeys || [])
  ])
);

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

function defaultFail(message) {
  throw new ValidationError(message);
}

function failWith(fail, message) {
  (fail || defaultFail)(message);
}

function requireObject(value, label, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    failWith(fail, `${label} must be an object`);
  }
  return value;
}

function optionalObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value
    : undefined;
}

function requireString(value, label, fail) {
  if (typeof value !== 'string' || value.trim() === '') {
    failWith(fail, `${label} must be a non-empty string`);
  }
  return value;
}

function optionalString(value) {
  return typeof value === 'string' && value.trim() !== ''
    ? value.trim()
    : undefined;
}

function assertKubernetesNamespace(value, label, fail) {
  const namespace = requireString(value, label, fail);
  if (namespace.length > 63 || !KUBERNETES_NAMESPACE_RE.test(namespace)) {
    failWith(fail, `${label} must be a Kubernetes namespace name`);
  }
  return namespace;
}

function assertKubernetesSecretName(value, label, fail) {
  const name = requireString(value, label, fail);
  if (name.length > 63 || !KUBERNETES_DNS_LABEL_RE.test(name)) {
    failWith(fail, `${label} must be a Kubernetes DNS label Secret name`);
  }
  return name;
}

function assertAfscpVolumeRefSecretName(
  value,
  label,
  fail,
  { allowOverlong = false } = {}
) {
  const name = requireString(value, label, fail);
  if (name !== name.trim()) {
    failWith(fail, `${label} must not include leading or trailing whitespace`);
  }
  if (
    (!allowOverlong && name.length > KUBERNETES_SECRET_NAME_MAX_LENGTH) ||
    !KUBERNETES_DNS_LABEL_RE.test(name)
  ) {
    failWith(fail, `${label} must be a Kubernetes DNS label Secret name`);
  }
  return name;
}

function parseSecretRef(value, label, fail) {
  const text = requireString(value, label, fail);
  if (!text.startsWith(SECRET_REF_PREFIX)) {
    failWith(fail, `${label} must be a secretRef:<namespace>/<name> reference`);
  }
  const ref = text.slice(SECRET_REF_PREFIX.length);
  const parts = ref.split('/');
  if (parts.length !== 2) {
    failWith(fail, `${label} must be a secretRef:<namespace>/<name> reference`);
  }
  const [namespace, name] = parts;
  return {
    namespace: assertKubernetesNamespace(namespace, `${label} namespace`, fail),
    name: assertKubernetesSecretName(name, `${label} name`, fail)
  };
}

function isTlsDisabledMode(value) {
  return TLS_DISABLED_VALUES.has(value.toLowerCase());
}

function normalizeTlsMode(value, label, fail, { allowDisabled = false } = {}) {
  const mode = requireString(value, label, fail).trim();
  if (mode !== value || !TLS_MODE_RE.test(mode)) {
    failWith(fail, `${label} must be a safe TLS mode token`);
  }
  if (!allowDisabled && isTlsDisabledMode(mode)) {
    failWith(fail, `${label} must not disable TLS`);
  }
  return mode;
}

function serviceTlsMode(service, serviceLabel, fail) {
  const tls = optionalObject(service.tls);
  const tlsMode = optionalString(tls?.mode);
  if (tlsMode) {
    return normalizeTlsMode(tlsMode, `${serviceLabel}.tls.mode`, fail, {
      allowDisabled: true
    });
  }
  const sslmode = optionalString(service.sslmode);
  if (sslmode) {
    return normalizeTlsMode(sslmode, `${serviceLabel}.sslmode`, fail, {
      allowDisabled: true
    });
  }
  return undefined;
}

function serviceUsesSsl(service, mode) {
  if (mode) {
    return !isTlsDisabledMode(mode);
  }
  for (const field of ['url', 'endpoint', 'issuer_url']) {
    const value = optionalString(service[field]);
    if (value?.toLowerCase().startsWith('https://')) {
      return true;
    }
  }
  return undefined;
}

function setDerivedValue(values, key, value) {
  if (value !== undefined) {
    values[key] = value;
  }
}

export function deriveSubstrateRenderValues(
  substrateTruth,
  { fail = defaultFail, label = 'substrate_truth' } = {}
) {
  const truth = requireObject(substrateTruth, label, fail);
  const services = requireObject(truth.services, `${label}.services`, fail);
  const values = {};

  for (const binding of SUBSTRATE_SERVICE_RENDER_BINDINGS) {
    const service = requireObject(
      services[binding.service],
      `${label}.services.${binding.label}`,
      fail
    );
    const serviceLabel = `${label}.services.${binding.label}`;
    const tls = optionalObject(service.tls);
    const mode = serviceTlsMode(service, serviceLabel, fail);
    const useSsl = serviceUsesSsl(service, mode);
    const caSecretRef = optionalString(tls?.ca_secret_ref);

    if (caSecretRef && useSsl !== false) {
      const parsed = parseSecretRef(caSecretRef, `${serviceLabel}.tls.ca_secret_ref`, fail);
      for (const prefix of binding.prefixes) {
        setDerivedValue(values, `${prefix}_CA_SECRET_REF`, caSecretRef);
        setDerivedValue(values, `${prefix}_CA_SECRET_NAME`, parsed.name);
      }
    }
    for (const prefix of binding.prefixes) {
      setDerivedValue(values, `${prefix}_TLS_MODE`, mode);
      setDerivedValue(values, `${prefix}_USE_SSL`, useSsl);
    }

    if (binding.sslmodeKeys) {
      const sslmode = optionalString(service.sslmode);
      if (sslmode) {
        const normalized = normalizeTlsMode(sslmode, `${serviceLabel}.sslmode`, fail, {
          allowDisabled: true
        });
        for (const key of binding.sslmodeKeys) {
          setDerivedValue(values, key, normalized);
        }
      }
    }
  }

  return values;
}

function normalizeComparable(value) {
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }
  return String(value);
}

function optionalRenderString(value, label, fail) {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== 'string') {
    failWith(fail, `${label} must be a string`);
  }
  if (value !== value.trim()) {
    failWith(fail, `${label} must not include leading or trailing whitespace`);
  }
  return value;
}

function parseAfscpVolumeRefRevision(value, label, fail) {
  const revision = optionalRenderString(value, label, fail);
  if (revision === undefined || revision === '' || revision.toLowerCase() === 'stable') {
    return {
      kind: 'stable',
      value: revision
    };
  }

  const match = SHA256_REVISION_RE.exec(revision);
  if (!match) {
    failWith(fail, `${label} must be empty, stable, or a sha256 digest`);
  }
  return {
    kind: 'sha256',
    value: `sha256:${match[1].toLowerCase()}`,
    suffix: match[1].slice(0, 12).toLowerCase()
  };
}

function appendAfscpVolumeRevisionSuffix(baseRef, suffix) {
  const revisionSuffix = `-${suffix}`;
  if (baseRef.endsWith(revisionSuffix)) {
    return baseRef;
  }
  const maxBaseLength = KUBERNETES_SECRET_NAME_MAX_LENGTH - revisionSuffix.length;
  return `${baseRef.slice(0, maxBaseLength)}${revisionSuffix}`;
}

export function normalizeAfscpVolumeRefRenderValues(
  renderValues,
  { fail = defaultFail, label = 'render_values' } = {}
) {
  const values = requireObject(renderValues, label, fail);
  const hasVolumeRef = Object.prototype.hasOwnProperty.call(values, AFSCP_VOLUME_REF_KEY);
  const hasRevision = Object.prototype.hasOwnProperty.call(
    values,
    AFSCP_VOLUME_REF_REVISION_KEY
  );
  const revision = parseAfscpVolumeRefRevision(
    hasRevision ? values[AFSCP_VOLUME_REF_REVISION_KEY] : undefined,
    `${label}.${AFSCP_VOLUME_REF_REVISION_KEY}`,
    fail
  );

  if (!hasVolumeRef) {
    if (revision.kind === 'sha256') {
      failWith(
        fail,
        `${label}.${AFSCP_VOLUME_REF_REVISION_KEY} requires ${label}.${AFSCP_VOLUME_REF_KEY}`
      );
    }
    return values;
  }

  const inputRef = assertAfscpVolumeRefSecretName(
    values[AFSCP_VOLUME_REF_KEY],
    `${label}.${AFSCP_VOLUME_REF_KEY}`,
    fail,
    { allowOverlong: revision.kind === 'sha256' }
  );
  if (revision.kind !== 'sha256') {
    return values;
  }

  const effectiveRef = appendAfscpVolumeRevisionSuffix(inputRef, revision.suffix);
  assertAfscpVolumeRefSecretName(
    effectiveRef,
    `${label}.${AFSCP_VOLUME_REF_KEY} effective value`,
    fail
  );

  const normalized = {
    ...values,
    [AFSCP_VOLUME_REF_KEY]: effectiveRef
  };
  const inputChecksum = optionalRenderString(
    values[AFSCP_RUNTIME_SECRETS_CHECKSUM_KEY],
    `${label}.${AFSCP_RUNTIME_SECRETS_CHECKSUM_KEY}`,
    fail
  );
  normalized[AFSCP_RUNTIME_SECRETS_CHECKSUM_KEY] = inputChecksum ?? revision.value;

  return normalized;
}

function valuesMatch(actual, expected) {
  return normalizeComparable(actual) === normalizeComparable(expected);
}

export function validateSubstrateRenderValues(
  renderValues,
  { fail = defaultFail, label = 'render_values' } = {}
) {
  const values = requireObject(renderValues, label, fail);
  normalizeAfscpVolumeRefRenderValues(values, { fail, label });

  for (const [key, value] of Object.entries(values)) {
    if (!KNOWN_RENDER_VALUE_KEYS.has(key)) {
      continue;
    }
    const valueLabel = `${label}.${key}`;
    if (key.endsWith('_CA_SECRET_REF')) {
      parseSecretRef(value, valueLabel, fail);
      continue;
    }
    if (key.endsWith('_CA_SECRET_NAME')) {
      assertKubernetesSecretName(value, valueLabel, fail);
      continue;
    }
    if (key.endsWith('_USE_SSL')) {
      if (
        typeof value !== 'boolean' &&
        !['true', 'false'].includes(String(value).toLowerCase())
      ) {
        failWith(fail, `${valueLabel} must be a boolean or true/false string`);
      }
      continue;
    }
    normalizeTlsMode(value, valueLabel, fail);
  }
}

export function mergeSubstrateRenderValues(
  renderValues,
  substrateTruth,
  {
    fail = defaultFail,
    label = 'render_values',
    truthLabel = 'substrate_truth'
  } = {}
) {
  const values = requireObject(renderValues, label, fail);
  validateSubstrateRenderValues(values, { fail, label });
  const derived = deriveSubstrateRenderValues(substrateTruth, {
    fail,
    label: truthLabel
  });

  for (const [key, expected] of Object.entries(derived)) {
    if (
      Object.prototype.hasOwnProperty.call(values, key) &&
      !valuesMatch(values[key], expected)
    ) {
      failWith(fail, `${label}.${key} must match ${truthLabel} derived value`);
    }
  }

  return {
    ...derived,
    ...normalizeAfscpVolumeRefRenderValues(values, { fail, label })
  };
}

export function isSafeRenderSecretLikeValue(key, value) {
  return (
    typeof value === 'string' &&
    SECRET_NAME_KEY_RE.test(key) &&
    value.length <= 63 &&
    KUBERNETES_DNS_LABEL_RE.test(value)
  );
}

export { ValidationError as SubstrateRenderValuesValidationError };
