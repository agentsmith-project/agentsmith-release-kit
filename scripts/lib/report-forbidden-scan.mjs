const FORBIDDEN_REPORT_KEYS = new Set([
  'access_key',
  'access_token',
  'api_key',
  'aws_secret_access_key',
  'client_secret',
  'id_token',
  'kubeconfig',
  'kube_config',
  'kubeconfig_path',
  'kube_config_path',
  'operator_token',
  'private_key',
  'secret_access_key',
  'secret',
  'secrets',
  'session_token',
  'token',
  'password',
  'refresh_token',
  'raw_env',
  'operator_identity',
  'signature_uri'
]);

const FORBIDDEN_REPORT_KEY_VALUE_PATTERN = [
  'access[_-]?key',
  'access[_-]?token',
  'api[_-]?key',
  'aws[_-]?secret[_-]?access[_-]?key',
  'client[_-]?secret',
  'id[_-]?token',
  'kube[_-]?config',
  'kubeconfig',
  'kubeconfig[_-]?path',
  'operator[_-]?identity',
  'operator[_-]?token',
  'password',
  'private[_-]?key',
  'raw[_-]?env',
  'refresh[_-]?token',
  'secret',
  'secret[_-]?access[_-]?key',
  'secrets',
  'session[_-]?token',
  'signature[_-]?uri',
  'token'
].join('|');

const FORBIDDEN_REPORT_TEXT_RE = new RegExp(
  [
    String.raw`(?:^|["'\s])(?:\/home\/|\/Users\/|\/tmp\/|\/var\/|\/private\/|\/etc\/kubernetes\/admin\.conf\b|[A-Za-z]:[\\/]|file:\/\/)`,
    String.raw`(?:^|[\\/"'\s])\.kube[\\/]config\b`,
    String.raw`Bearer\s+[A-Za-z0-9._~+/=-]+`,
    String.raw`(?:^|[{"'\s,])["']?(?:${FORBIDDEN_REPORT_KEY_VALUE_PATTERN})["']?\s*[:=]\s*["']?[^"'\s,}]{3,}`,
    String.raw`sk-[A-Za-z0-9]{12,}`,
    String.raw`AKIA[0-9A-Z]{16}`,
    String.raw`-----BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY-----`,
    String.raw`\bkubeconfig\b`,
    String.raw`\bapiVersion:\s*v1\b[\s\S]{0,400}\bclusters:\b`
  ].join('|'),
  'i'
);
const FORBIDDEN_URI_MATERIAL_RE = new RegExp(
  [
    String.raw`(?:^|[#?&=:/\\])(?:\/(?:home|Users|tmp|var|private)(?:[\/\\#?&=:]|$)|\/etc\/kubernetes\/admin\.conf\b|[A-Za-z]:[\\/]|file:\/\/)`,
    String.raw`(?:^|[#?&=:/\\])\.kube[\\/]config\b`,
    String.raw`(?:^|[\\/])admin\.conf\b`,
    String.raw`Bearer\s+[A-Za-z0-9._~+/=-]+`,
    String.raw`(?:^|[#?&=:/\\])(?:access[_-]?token|api[_-]?key|client[_-]?secret|id[_-]?token|operator[_-]?token|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)\s*[:=]\s*[^#?&/\\\s]{3,}`,
    String.raw`sk-[A-Za-z0-9]{12,}`,
    String.raw`AKIA[0-9A-Z]{16}`,
    String.raw`-----BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY-----`
  ].join('|'),
  'i'
);
const PERCENT_ENCODED_OCTET_RE = /%[0-9A-Fa-f]{2}/;
const MAX_PERCENT_DECODE_DEPTH = 8;

function normalizeReportKey(key) {
  return key
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/[-\s]+/g, '_')
    .toLowerCase()
    .replace(/_+/g, '_')
    .replace(/^_|_$/g, '');
}

function forbiddenTextMatch(value) {
  return FORBIDDEN_REPORT_TEXT_RE.test(value) || FORBIDDEN_URI_MATERIAL_RE.test(value);
}

function percentDecodedCandidates(value, label, options = {}) {
  const candidates = [];
  let current = value;

  for (let depth = 0; depth < MAX_PERCENT_DECODE_DEPTH; depth += 1) {
    if (!current.includes('%')) {
      return candidates;
    }

    if (!PERCENT_ENCODED_OCTET_RE.test(current)) {
      if (options.strict) {
        try {
          decodeURIComponent(current);
        } catch {
          throw new Error(`${label} contains malformed percent encoding`);
        }
      }
      return candidates;
    }

    let decoded;
    try {
      decoded = decodeURIComponent(current);
    } catch {
      if (options.strict) {
        throw new Error(`${label} contains malformed percent encoding`);
      }
      return candidates;
    }

    if (decoded === current) {
      return candidates;
    }

    candidates.push(decoded);
    current = decoded;
  }

  if (PERCENT_ENCODED_OCTET_RE.test(current)) {
    throw new Error(`${label} exceeds maximum percent decoding depth`);
  }
  return candidates;
}

export function assertReportUriHasNoForbiddenContent(value, label) {
  const text = String(value ?? '');
  for (const candidate of [text, ...percentDecodedCandidates(text, label, { strict: true })]) {
    if (forbiddenTextMatch(candidate)) {
      throw new Error(`${label} contains forbidden local path or secret-like text`);
    }
  }
}

export function scanForForbiddenReportContent(value, label, pathParts = []) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => scanForForbiddenReportContent(item, label, [...pathParts, String(index)]));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      if (FORBIDDEN_REPORT_KEYS.has(normalizeReportKey(key))) {
        throw new Error(`${label} must not contain secret/local field: ${[...pathParts, key].join('.')}`);
      }
      scanForForbiddenReportContent(nested, label, [...pathParts, key]);
    }
    return;
  }
  if (typeof value === 'string') {
    for (const candidate of [value, ...percentDecodedCandidates(value, label)]) {
      if (forbiddenTextMatch(candidate)) {
        throw new Error(`${label} contains forbidden local path or secret-like text at ${pathParts.join('.') || '<root>'}`);
      }
    }
  }
}

export function scanReportForForbiddenContent({ value, buffer, label }) {
  if (buffer !== undefined && forbiddenTextMatch(buffer.toString('utf8'))) {
    throw new Error(`${label} contains forbidden local path or secret-like text in raw bytes`);
  }
  scanForForbiddenReportContent(value, label);
}
