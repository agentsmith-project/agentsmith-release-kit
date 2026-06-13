const REDACTED_VALUE = '[redacted]';

const SECRET_KEY_PATTERN = [
  '(?:[A-Za-z0-9]+[_-])*access[_-]?key',
  '(?:[A-Za-z0-9]+[_-])*api[_-]?key',
  '(?:[A-Za-z0-9]+[_-])*aws[_-]?secret[_-]?access[_-]?key',
  '(?:[A-Za-z0-9]+[_-])*client[_-]?key[_-]?data',
  '(?:[A-Za-z0-9]+[_-])*client[_-]?secret',
  '(?:[A-Za-z0-9]+[_-])*kube[_-]?config',
  '(?:[A-Za-z0-9]+[_-])*kubeconfig',
  '(?:[A-Za-z0-9]+[_-])*password',
  '(?:[A-Za-z0-9]+[_-])*passwd',
  '(?:[A-Za-z0-9]+[_-])*private[_-]?key',
  '(?:[A-Za-z0-9]+[_-])*refresh[_-]?token',
  '(?:[A-Za-z0-9]+[_-])*secret[_-]?access[_-]?key',
  '(?:[A-Za-z0-9]+[_-])*secret[_-]?key',
  '(?:[A-Za-z0-9]+[_-])*session[_-]?token',
  '(?:[A-Za-z0-9]+[_-])*token',
  'accessKey',
  'apiKey',
  'clientKeyData',
  'clientSecret',
  'kubeConfig',
  'kubeconfig',
  'password',
  'privateKey',
  'secret',
  'token'
].join('|');

const SECRET_KEY_VALUE_DOUBLE_QUOTED_RE = new RegExp(
  `(^|[^A-Za-z0-9_])((?:["'])?(?:${SECRET_KEY_PATTERN})(?:["'])?\\s*[:=]\\s*)"[^"\\r\\n]*"`,
  'gi'
);
const SECRET_KEY_VALUE_SINGLE_QUOTED_RE = new RegExp(
  `(^|[^A-Za-z0-9_])((?:["'])?(?:${SECRET_KEY_PATTERN})(?:["'])?\\s*[:=]\\s*)'[^'\\r\\n]*'`,
  'gi'
);
const SECRET_KEY_VALUE_UNQUOTED_RE = new RegExp(
  `(^|[^A-Za-z0-9_])((?:["'])?(?:${SECRET_KEY_PATTERN})(?:["'])?\\s*[:=]\\s*)[^"'\\s,;}\\]]+`,
  'gi'
);
const SECRET_PHRASE_VALUE_RE =
  /(^|[^A-Za-z0-9_])((?:access|api|client|private|secret|session|refresh|id|kube)\s+(?:key|secret|token|config)\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}]+)/gi;

export function redactSecretLikeOutput(value) {
  return String(value ?? '')
    .replace(
      /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/gi,
      '[redacted-private-key]'
    )
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, `Bearer ${REDACTED_VALUE}`)
    .replace(SECRET_KEY_VALUE_DOUBLE_QUOTED_RE, `$1$2"${REDACTED_VALUE}"`)
    .replace(SECRET_KEY_VALUE_SINGLE_QUOTED_RE, `$1$2'${REDACTED_VALUE}'`)
    .replace(SECRET_KEY_VALUE_UNQUOTED_RE, `$1$2${REDACTED_VALUE}`)
    .replace(SECRET_PHRASE_VALUE_RE, `$1$2${REDACTED_VALUE}`);
}
