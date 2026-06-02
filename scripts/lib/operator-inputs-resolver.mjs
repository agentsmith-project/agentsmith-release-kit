import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { validateSubstrateInstallInputs } from './substrate-install-input-validation.mjs';
import { resolveSubstrateInstallParameters } from './substrate-install-parameters.mjs';

const MANIFEST_FILE = 'operator-inputs.json';
const PLAN_FILE = 'operator-inputs-plan.json';
const INTERNAL_DIR = '.release-kit-internal';
const MANIFEST_SCHEMA = 'agentsmith.operator-inputs/v1';
const MANIFEST_OPERATOR_INPUTS_VERSION = 1;
const AIRGAP_BUNDLE_MANIFEST_SCHEMA = 'agentsmith.airgap-bundle-manifest/v1';
const PLAN_SCHEMA = 'agentsmith.operator-inputs-plan/v1';
const PLAN_SCOPE = 'operator_inputs_intake_only';
const INTERNAL_EXPECTED_SCHEMA = 'agentsmith.operator-inputs-plan-internal/v1';
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const OPERATOR_RELEASE_SCRIPT = path.join(REPO_ROOT, 'scripts/operator-release.sh');
const VERIFY_RELEASE_SCRIPT = path.join(REPO_ROOT, 'scripts/verify-release.sh');
const DEPLOYMENT_PATH_REPORT_FILE = 'deployment-path-report.json';
const DEPLOYMENT_PATH_FINALIZER_MANIFEST = 'deployment-path-finalizer-manifest.json';
const DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR = 'source-evidence';
const DEFAULT_MODE = 'server-dry-run';
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const SUPPORTED_DEPLOYMENT_PATHS = new Set([
  'online/use_existing',
  'online/install_substrates',
  'airgap/use_existing',
  'airgap/install_substrates'
]);
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const NAMESPACE_RE = /^(?=.{1,63}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const SAFE_TIMEOUT_RE = /^(?:0|[1-9][0-9]*(?:ms|s|m|h))$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:[\\/]/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i;
const MAX_SMOKE_TIMEOUT_MS = 300000;

const TOP_LEVEL_FIELDS = new Set([
  'schema_version',
  'operator_inputs_version',
  'deployment_path',
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'substrate_truth',
  'target_prerequisites',
  'namespace',
  'airgap_bundle',
  'airgap_bundle_manifest',
  'substrate_pack_manifest',
  'substrate_install_inputs',
  'install_confirmation',
  'deploy_confirmation',
  'mode',
  'kubectl',
  'context',
  'registry_probe',
  'routability_probe',
  'archive_probe',
  'image_loader',
  'smoke_url',
  'expected_status',
  'timeout',
  'timeout_ms',
  'allow_http',
  'allow_localhost'
]);

const FILE_FIELDS = new Set([
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'substrate_truth',
  'target_prerequisites',
  'airgap_bundle_manifest',
  'substrate_pack_manifest',
  'substrate_install_inputs'
]);
const DIRECTORY_FIELDS = new Set(['airgap_bundle']);
const COMMAND_FIELDS = new Set([
  'kubectl',
  'registry_probe',
  'routability_probe',
  'archive_probe',
  'image_loader'
]);
const BOOLEAN_FIELDS = new Set(['allow_http', 'allow_localhost']);
const STRING_FIELDS = new Set([
  'schema_version',
  'deployment_path',
  'namespace',
  'mode',
  'context',
  'smoke_url',
  'timeout'
]);

const COMMON_REQUIRED_FILES = [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'target_prerequisites'
];
const USE_EXISTING_REQUIRED_FILES = [
  ...COMMON_REQUIRED_FILES,
  'substrate_truth'
];
const SMOKE_MODIFIER_FIELDS = [
  'expected_status',
  'timeout_ms',
  'allow_http',
  'allow_localhost'
];
const INSTALL_CONFIRMATION_FIELDS = new Set([
  'confirmed',
  'confirm_current_install_parameters',
  'install_parameters_sha256',
  'operator_run_id'
]);
const APPLY_RUNTIME_FIELDS = [
  'timeout',
  'smoke_url',
  ...SMOKE_MODIFIER_FIELDS
];
const AIRGAP_BASE_COMPONENT_KINDS = [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'image_map'
];
const AIRGAP_KIT_COMPONENT_KINDS = [
  ...AIRGAP_BASE_COMPONENT_KINDS,
  'substrate_pack_manifest'
];
const AIRGAP_COMPONENT_KEYS = new Set(['kind', 'path', 'sha256']);

const DEPLOYMENT_PATH_CONFIG = new Map([
  [
    'online/use_existing',
    {
      targetProfile: 'existing_kubernetes/external_declared/online',
      operatorChoice: ['online', 'use_existing'],
      requiredFiles: USE_EXISTING_REQUIRED_FILES,
      requiredDirs: [],
      requiredCommands: [],
      requiredScalars: [],
      installSubstrates: false,
      producer: 'online'
    }
  ],
  [
    'online/install_substrates',
    {
      targetProfile: 'existing_kubernetes/kit_installed/online',
      operatorChoice: ['online', 'install_substrates'],
      requiredFiles: [
        ...COMMON_REQUIRED_FILES,
        'substrate_pack_manifest',
        'substrate_install_inputs'
      ],
      requiredDirs: [],
      requiredCommands: ['kubectl', 'routability_probe'],
      requiredScalars: ['context'],
      installSubstrates: true,
      producer: 'online'
    }
  ],
  [
    'airgap/use_existing',
    {
      targetProfile: 'existing_kubernetes/external_declared/airgap',
      operatorChoice: ['airgap', 'use_existing'],
      requiredFiles: [
        ...USE_EXISTING_REQUIRED_FILES,
        'airgap_bundle_manifest'
      ],
      requiredDirs: ['airgap_bundle'],
      requiredCommands: ['kubectl'],
      requiredScalars: ['context'],
      installSubstrates: false,
      producer: 'airgap'
    }
  ],
  [
    'airgap/install_substrates',
    {
      targetProfile: 'existing_kubernetes/kit_installed/airgap',
      operatorChoice: ['airgap', 'install_substrates'],
      requiredFiles: [
        ...COMMON_REQUIRED_FILES,
        'substrate_pack_manifest',
        'substrate_install_inputs',
        'airgap_bundle_manifest'
      ],
      requiredDirs: ['airgap_bundle'],
      requiredCommands: ['kubectl'],
      requiredScalars: ['context'],
      installSubstrates: true,
      producer: 'airgap'
    }
  ]
]);

const INTERNAL_REPORT_KEY_RE = /(^|[_-])(?:operator[_-]release[_-]surface[_-]report|adoption[_-]report|candidate[_-]intake|deployment[_-]path[_-]report|release[_-]engineering[_-]gate[_-]intake[_-]report)([_-]|$)/i;
const INTERNAL_REPORT_BASENAME_RE = /(?:^|[-_. ])(?:operator[-_ ]release[-_ ]surface[-_ ]report|adoption[-_ ]report|candidate[-_ ]intake|deployment[-_ ]path[-_ ]report|release[-_ ]engineering[-_ ]gate[-_ ]intake[-_ ]report)(?:[-_. ]|$)/i;
const FORBIDDEN_ROUTE_TEXT_RE = /(?:required_product_flows|product_flows|product_flow_results|deploy_readiness|release_verdict|\bverdict\b|\bkubeconfig\b)/i;
const SECRET_KEY_RE = /(^|[_-])(access[_-]?key|api[_-]?key|client[_-]?secret|credential|kubeconfig|kube[_-]?config|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)([_-]|$)/i;
const SECRET_VALUE_RE = [
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /\b(?:token|password|secret|client_secret|api_key|access_key|access_token|refresh_token|session_token)\s*[:=]\s*[^"'\s&?]{6,}/i,
  /[?&](?:token|password|secret|client_secret|api_key|access_key|access_token|refresh_token|session_token)=/i,
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:postgres|mongodb|redis):\/\/[^:\s]+:[^@\s]+@/i,
  /\bhttps?:\/\/[^\s"'<>]*(?:feishu|larksuite)[^\s"'<>]*(?:\/open-apis\/bot\/v\d+\/hook|webhook|hook)[^\s"'<>]*/i,
  /\bhttps?:\/\/[^\s"'<>]*(?:atlassian\.net|atlassian\.com|jira)[^\s"'<>]*(?:webhook|hooks?|automation\/webhook)[^\s"'<>]*/i,
  /\bhttps?:\/\/[^\s"'<>]*(?:webhook|hooks?)[^\s"'<>]*(?:token|secret|signature|sig|key)=/i,
  /\bhttps?:\/\/[^\s"'<>]*\/(?:webhook|hooks?)\/[A-Za-z0-9._~%+-]{8,}/i,
  /\bkubeconfig\b/i,
  /\bmanaged[_ -]?credential/i
];

class OperatorInputsError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

function fail(message) {
  throw new OperatorInputsError(message);
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
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

function digestJson(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

async function readFileDigest(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return {
    buffer,
    sha256: digestBuffer(buffer)
  };
}

async function readJson(file, label) {
  const { buffer, sha256 } = await readFileDigest(file, label);
  try {
    return {
      file,
      buffer,
      value: JSON.parse(buffer.toString('utf8')),
      raw: buffer.toString('utf8'),
      sha256,
      inputDigest: sha256
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

function assertPlainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be a JSON object`);
  }
}

function requirePlainObject(value, label) {
  assertPlainObject(value, label);
  return value;
}

function assertAllowedKeys(value, allowedKeys, label) {
  const object = requirePlainObject(value, label);
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`unknown ${label} field: ${key}`);
    }
  }
  return object;
}

function assertString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`);
  }
  return value;
}

function assertDigest(value, label) {
  const digest = assertString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function assertStringEquals(value, expected, label) {
  const actual = assertString(value, label);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function assertTargetProfileFieldEquals(value, expected, label) {
  const actual = assertString(value, label);
  if (actual !== expected) {
    fail(`${label} must match deployment_path target_profile (${expected})`);
  }
  return actual;
}

function assertBooleanEquals(value, expected, label) {
  if (value !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return value;
}

function packageRelativePath(baseDir, absolutePath) {
  const relative = path.relative(baseDir, absolutePath).split(path.sep).join('/');
  if (relative === '' || relative.startsWith('../') || relative === '..' || path.isAbsolute(relative)) {
    fail(`resolved path escaped operator-inputs package: ${absolutePath}`);
  }
  return relative;
}

function isReservedOperatorOutputPath(relativePath) {
  const normalized = path.posix.normalize(relativePath.replace(/\\/g, '/'));
  return normalized === INTERNAL_DIR || normalized.startsWith(`${INTERNAL_DIR}/`);
}

function assertNotReservedOperatorOutputPath(relativePath, label) {
  if (isReservedOperatorOutputPath(relativePath)) {
    fail(`${label} must not point into reserved operator-inputs output tree: ${INTERNAL_DIR}`);
  }
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function assertPackageRelativeInput(value, label) {
  const raw = assertString(value, label);
  if (raw.includes('\0')) {
    fail(`${label} contains an invalid path byte`);
  }
  if (raw.startsWith('/') || WINDOWS_DRIVE_RE.test(raw) || URI_SCHEME_RE.test(raw)) {
    fail(`${label} must be a package-relative path`);
  }
  const normalized = path.posix.normalize(raw.replace(/\\/g, '/'));
  if (
    normalized === '.' ||
    normalized.startsWith('../') ||
    normalized === '..' ||
    normalized.split('/').includes('..')
  ) {
    fail(`${label} escapes the operator-inputs package`);
  }
  assertNotReservedOperatorOutputPath(normalized, label);
  return normalized;
}

async function resolvePackagePath({ baseDir, key, kind }) {
  const relativePath = assertPackageRelativeInput(key.value, key.label);
  const requested = path.resolve(baseDir, relativePath);
  let lstat;
  try {
    lstat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${key.label}: ${error.message}`);
  }
  if (lstat.isSymbolicLink()) {
    fail(`${key.label} must not be a symlink`);
  }
  if (kind === 'file' && !lstat.isFile()) {
    fail(`${key.label} must point to a file`);
  }
  if (kind === 'directory' && !lstat.isDirectory()) {
    fail(`${key.label} must point to a directory`);
  }

  let realPath;
  try {
    realPath = await fs.realpath(requested);
  } catch (error) {
    fail(`cannot resolve ${key.label}: ${error.message}`);
  }
  if (!isInsidePath(baseDir, realPath)) {
    fail(`${key.label} resolves outside the operator-inputs package`);
  }
  const canonicalRelativePath = packageRelativePath(baseDir, realPath);
  assertNotReservedOperatorOutputPath(canonicalRelativePath, key.label);

  return {
    absolutePath: realPath,
    path: canonicalRelativePath
  };
}

async function digestDirectory(rootDir) {
  const entries = [];

  async function walk(absoluteDir, relativeDir = '') {
    const dirents = await fs.readdir(absoluteDir, { withFileTypes: true });
    for (const dirent of dirents.sort((a, b) => a.name.localeCompare(b.name))) {
      const relativePath = relativeDir ? `${relativeDir}/${dirent.name}` : dirent.name;
      const absolutePath = path.join(absoluteDir, dirent.name);
      if (dirent.isSymbolicLink()) {
        fail(`directory input contains a symlink: ${relativePath}`);
      }
      if (dirent.isDirectory()) {
        entries.push({ path: relativePath, type: 'directory' });
        await walk(absolutePath, relativePath);
        continue;
      }
      if (!dirent.isFile()) {
        fail(`directory input contains a non-file entry: ${relativePath}`);
      }
      const { sha256 } = await readFileDigest(absolutePath, relativePath);
      entries.push({ path: relativePath, type: 'file', sha256 });
    }
  }

  await walk(rootDir);
  return {
    entry_count: entries.length,
    tree_sha256: digestJson(entries)
  };
}

async function resolveCommand({ baseDir, value, label }) {
  const raw = assertString(value, label);
  if (!raw.includes('/') && !raw.includes('\\')) {
    fail(`${label} must be a package-relative executable path, not a PATH command name`);
  }

  const resolved = await resolvePackagePath({
    baseDir,
    key: { value, label },
    kind: 'file'
  });
  try {
    await fs.access(resolved.absolutePath, fsConstants.X_OK);
  } catch {
    fail(`${label} must be executable`);
  }
  const { sha256 } = await readFileDigest(resolved.absolutePath, label);
  return {
    kind: 'file',
    path: resolved.path,
    absolute_path: resolved.absolutePath,
    sha256
  };
}

function scanManifestForForbiddenContent(value, label, pathParts = []) {
  if (Array.isArray(value)) {
    value.forEach((item, index) =>
      scanManifestForForbiddenContent(item, label, [...pathParts, String(index)])
    );
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      if (SECRET_KEY_RE.test(key)) {
        fail(`${label} must not contain secret-like field: ${[...pathParts, key].join('.')}`);
      }
      if (INTERNAL_REPORT_KEY_RE.test(key)) {
        fail(`${label} must not contain internal report reference field: ${[...pathParts, key].join('.')}`);
      }
      scanManifestForForbiddenContent(nested, label, [...pathParts, key]);
    }
    return;
  }
  if (typeof value === 'string') {
    const currentPath = pathParts.join('.') || '<root>';
    const basename = path.posix.basename(value.replace(/\\/g, '/'));
    if (INTERNAL_REPORT_BASENAME_RE.test(basename)) {
      fail(`${label} must not contain internal report reference at ${currentPath}`);
    }
    for (const pattern of SECRET_VALUE_RE) {
      if (pattern.test(value)) {
        fail(`${label} must not contain secret-like payload at ${currentPath}`);
      }
    }
  }
}

function parseIpv4Address(hostname) {
  const normalized = hostname.replace(/\.+$/, '');
  const parts = normalized.split('.');
  if (parts.length !== 4) {
    return undefined;
  }
  const numbers = parts.map((part) => {
    if (!/^(?:0|[1-9][0-9]{0,2})$/.test(part)) {
      return undefined;
    }
    const value = Number(part);
    return value >= 0 && value <= 255 ? value : undefined;
  });
  if (numbers.some((value) => value === undefined)) {
    return undefined;
  }
  return numbers;
}

function isIpv4MappedLoopback(hostname) {
  if (!hostname.startsWith('::ffff:')) {
    return false;
  }

  const mapped = hostname.slice('::ffff:'.length);
  if (/^127(?:\.\d{1,3}){3}$/.test(mapped)) {
    return true;
  }

  const [firstHextet] = mapped.split(':');
  if (!/^[0-9a-f]{1,4}$/.test(firstHextet)) {
    return false;
  }

  return (Number.parseInt(firstHextet, 16) & 0xff00) === 0x7f00;
}

function normalizedHostname(hostname) {
  return hostname
    .toLowerCase()
    .replace(/^\[(.*)\]$/, '$1')
    .replace(/\.+$/, '');
}

function isLocalhost(hostname) {
  const normalized = normalizedHostname(hostname);
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::' ||
    normalized === '::1' ||
    isIpv4MappedLoopback(normalized) ||
    /^127(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

function isPrivateNetworkHost(hostname) {
  const normalized = normalizedHostname(hostname);
  const ipv4 = parseIpv4Address(normalized);
  if (ipv4) {
    const [first, second] = ipv4;
    return (
      first === 0 ||
      first === 10 ||
      first === 127 ||
      (first === 100 && second >= 64 && second <= 127) ||
      (first === 169 && second === 254) ||
      (first === 172 && second >= 16 && second <= 31) ||
      (first === 192 && second === 168) ||
      (first === 198 && (second === 18 || second === 19))
    );
  }
  return (
    normalized === '::' ||
    normalized === '::1' ||
    normalized.startsWith('fc') ||
    normalized.startsWith('fd') ||
    normalized.startsWith('fe80:')
  );
}

function decodedPathname(pathname) {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return pathname;
  }
}

function assertSafeSmokePath(pathname) {
  for (const value of [pathname, decodedPathname(pathname)]) {
    if (FORBIDDEN_ROUTE_TEXT_RE.test(value)) {
      fail('smoke_url path contains report-forbidden text');
    }
    if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
      fail('smoke_url path contains a secret-looking payload');
    }
  }
}

function validateSmokeUrlField(manifest) {
  if (!Object.hasOwn(manifest, 'smoke_url')) {
    return;
  }

  const input = assertString(manifest.smoke_url, 'smoke_url');
  if (input !== input.trim() || /[\s\r\n]/.test(input)) {
    fail('smoke_url must not contain whitespace');
  }

  let parsed;
  try {
    parsed = new URL(input);
  } catch {
    fail('smoke_url must be an absolute URL');
  }

  if (parsed.username || parsed.password) {
    fail('smoke_url must not include userinfo');
  }
  if (parsed.search || parsed.hash || input.includes('?') || input.includes('#')) {
    fail('smoke_url must not include query or hash');
  }
  if (parsed.protocol !== 'https:' && !(manifest.allow_http === true && parsed.protocol === 'http:')) {
    fail('smoke_url must use https unless allow_http is true');
  }
  if (isLocalhost(parsed.hostname) && manifest.allow_localhost !== true) {
    fail('smoke_url must not target localhost unless allow_localhost is true');
  }
  if (
    parsed.protocol === 'http:' &&
    isPrivateNetworkHost(parsed.hostname) &&
    !isLocalhost(parsed.hostname)
  ) {
    fail('smoke_url must not use http for private network hosts');
  }

  assertSafeSmokePath(parsed.pathname || '/');
}

function validateTopLevelFields(manifest) {
  for (const key of Object.keys(manifest)) {
    if (key === 'smoke_endpoint') {
      fail('smoke_endpoint is not supported by operator-inputs intake; use smoke_url');
    }
    if (key === 'product_readiness_report') {
      fail('product_readiness_report is not accepted by operator-inputs intake');
    }
    if (INTERNAL_REPORT_KEY_RE.test(key)) {
      fail(`operator-inputs manifest must not contain internal report reference field: ${key}`);
    }
    if (!TOP_LEVEL_FIELDS.has(key)) {
      fail(`unknown operator-inputs field: ${key}`);
    }
  }
}

function validateScalarFields(manifest) {
  for (const key of STRING_FIELDS) {
    if (Object.hasOwn(manifest, key)) {
      assertString(manifest[key], key);
    }
  }
  for (const key of BOOLEAN_FIELDS) {
    if (Object.hasOwn(manifest, key) && typeof manifest[key] !== 'boolean') {
      fail(`${key} must be a boolean`);
    }
  }
  if (Object.hasOwn(manifest, 'expected_status')) {
    if (!Number.isInteger(manifest.expected_status) || manifest.expected_status < 100 || manifest.expected_status > 599) {
      fail('expected_status must be an HTTP status integer');
    }
  }
  if (Object.hasOwn(manifest, 'timeout_ms')) {
    if (
      !Number.isInteger(manifest.timeout_ms) ||
      manifest.timeout_ms <= 0 ||
      manifest.timeout_ms > MAX_SMOKE_TIMEOUT_MS
    ) {
      fail(`timeout_ms must be an integer between 1 and ${MAX_SMOKE_TIMEOUT_MS}`);
    }
  }
  if (Object.hasOwn(manifest, 'timeout') && !SAFE_TIMEOUT_RE.test(manifest.timeout)) {
    fail('timeout must be 0 or a Kubernetes duration like 120s, 2m, or 1h');
  }
}

function validateSchemaAndPath(manifest) {
  if (!Object.hasOwn(manifest, 'schema_version')) {
    fail('missing required operator-inputs field: schema_version');
  }
  if (manifest.schema_version !== MANIFEST_SCHEMA) {
    fail(`schema_version must be ${MANIFEST_SCHEMA}`);
  }
  if (!Object.hasOwn(manifest, 'operator_inputs_version')) {
    fail('missing required operator-inputs field: operator_inputs_version');
  }
  if (manifest.operator_inputs_version !== MANIFEST_OPERATOR_INPUTS_VERSION) {
    fail(`operator_inputs_version must be ${MANIFEST_OPERATOR_INPUTS_VERSION}`);
  }
  if (!SUPPORTED_DEPLOYMENT_PATHS.has(manifest.deployment_path)) {
    fail('deployment_path must be one of online/use_existing, online/install_substrates, airgap/use_existing, airgap/install_substrates');
  }
  if (!NAMESPACE_RE.test(manifest.namespace || '')) {
    fail('namespace must be a Kubernetes DNS label');
  }
  const mode = manifest.mode || DEFAULT_MODE;
  if (!SUPPORTED_MODES.has(mode)) {
    fail('mode must be server-dry-run or apply');
  }
  return mode;
}

function validateSmokeRuntimeFields(manifest, mode) {
  const hasSmokeUrl = Object.hasOwn(manifest, 'smoke_url');
  const smokeModifiers = SMOKE_MODIFIER_FIELDS.filter((key) => Object.hasOwn(manifest, key));
  if (!hasSmokeUrl && smokeModifiers.length > 0) {
    fail(`${smokeModifiers.join(', ')} require smoke_url`);
  }

  const runtimeFields = APPLY_RUNTIME_FIELDS.filter((key) => Object.hasOwn(manifest, key));
  if (mode !== 'apply' && runtimeFields.length > 0) {
    fail(`${runtimeFields.join(', ')} are accepted only with mode apply`);
  }
}

function validateUnsupportedInputs(manifest) {
  if (Object.hasOwn(manifest, 'registry_probe')) {
    fail('registry_probe is not supported by operator-inputs intake because target_registry is not modeled; omit registry_probe');
  }
}

function validatePathSpecificUnsupportedInputs({ manifest, config }) {
  if (config.installSubstrates && Object.hasOwn(manifest, 'substrate_truth')) {
    fail('substrate_truth is accepted only for use_existing deployment_path');
  }
}

function validateConfirmation(value, label, fields) {
  assertPlainObject(value, label);
  const allowed = new Set(fields.map((field) => field.name));
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      fail(`unknown ${label} field: ${key}`);
    }
  }
  for (const field of fields) {
    if (!Object.hasOwn(value, field.name)) {
      fail(`missing ${label}.${field.name}`);
    }
    const nestedValue = value[field.name];
    if (field.type === 'boolean' && nestedValue !== true) {
      fail(`${label}.${field.name} must be true`);
    }
    if (field.type === 'digest' && (typeof nestedValue !== 'string' || !DIGEST_RE.test(nestedValue))) {
      fail(`${label}.${field.name} must be a sha256 digest`);
    }
    if (field.type === 'run_id' && (typeof nestedValue !== 'string' || !OPERATOR_RUN_ID_RE.test(nestedValue))) {
      fail(`${label}.${field.name} must be a safe operator run id`);
    }
  }
}

function validateInstallConfirmation(value, label) {
  const confirmation = assertAllowedKeys(value, INSTALL_CONFIRMATION_FIELDS, label);
  if (!Object.hasOwn(confirmation, 'confirmed')) {
    fail(`missing ${label}.confirmed`);
  }
  if (confirmation.confirmed !== true) {
    fail(`${label}.confirmed must be true`);
  }
  if (!Object.hasOwn(confirmation, 'operator_run_id')) {
    fail(`missing ${label}.operator_run_id`);
  }
  if (
    typeof confirmation.operator_run_id !== 'string' ||
    !OPERATOR_RUN_ID_RE.test(confirmation.operator_run_id)
  ) {
    fail(`${label}.operator_run_id must be a safe operator run id`);
  }

  const hasCurrentConfirmation = Object.hasOwn(
    confirmation,
    'confirm_current_install_parameters'
  );
  if (
    hasCurrentConfirmation &&
    confirmation.confirm_current_install_parameters !== true
  ) {
    fail(`${label}.confirm_current_install_parameters must be true`);
  }
  if (
    Object.hasOwn(confirmation, 'install_parameters_sha256') &&
    (typeof confirmation.install_parameters_sha256 !== 'string' ||
      !DIGEST_RE.test(confirmation.install_parameters_sha256))
  ) {
    fail(`${label}.install_parameters_sha256 must be a sha256 digest`);
  }
  if (
    !hasCurrentConfirmation &&
    !Object.hasOwn(confirmation, 'install_parameters_sha256')
  ) {
    fail(`${label}.confirm_current_install_parameters must be true`);
  }
}

function validateConfirmations({ manifest, config, mode }) {
  if (config.installSubstrates) {
    if (!Object.hasOwn(manifest, 'install_confirmation')) {
      fail('install_substrates deployment_path requires install_confirmation');
    }
    validateInstallConfirmation(manifest.install_confirmation, 'install_confirmation');
  } else if (Object.hasOwn(manifest, 'install_confirmation')) {
    fail('install_confirmation is accepted only for install_substrates deployment_path');
  }

  if (mode === 'apply') {
    if (!Object.hasOwn(manifest, 'deploy_confirmation')) {
      fail('mode apply requires deploy_confirmation');
    }
    validateConfirmation(manifest.deploy_confirmation, 'deploy_confirmation', [
      { name: 'confirmed', type: 'boolean' },
      { name: 'operator_run_id', type: 'run_id' }
    ]);
  } else if (Object.hasOwn(manifest, 'deploy_confirmation')) {
    fail('deploy_confirmation is accepted only with mode apply');
  }
}

function requiredInputsFor({ config, mode }) {
  const requiredCommands = [...config.requiredCommands];
  if (config.producer === 'airgap' && mode === 'apply') {
    requiredCommands.push('archive_probe', 'image_loader');
  }
  return {
    files: config.requiredFiles,
    dirs: config.requiredDirs,
    commands: requiredCommands,
    scalars: config.requiredScalars
  };
}

function requireFields({ manifest, config, mode }) {
  const requiredInputs = requiredInputsFor({ config, mode });
  for (const key of [
    ...requiredInputs.files,
    ...requiredInputs.dirs,
    ...requiredInputs.commands,
    ...requiredInputs.scalars,
    'namespace'
  ]) {
    if (!Object.hasOwn(manifest, key)) {
      fail(`missing required operator-inputs field for ${manifest.deployment_path}: ${key}`);
    }
  }
  return requiredInputs;
}

async function resolveManifestInput(inputPath) {
  const requested = path.resolve(assertString(inputPath, '--operator-inputs'));
  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read --operator-inputs: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('--operator-inputs must not be a symlink');
  }

  let manifestPath;
  let packageRoot;
  if (stat.isDirectory()) {
    packageRoot = await fs.realpath(requested);
    manifestPath = await resolveManifestFile({
      requestedManifest: path.join(packageRoot, MANIFEST_FILE),
      packageRoot
    });
  } else if (stat.isFile()) {
    packageRoot = await fs.realpath(path.dirname(requested));
    manifestPath = await resolveManifestFile({
      requestedManifest: requested,
      packageRoot
    });
  } else {
    fail('--operator-inputs must be a directory or JSON manifest file');
  }

  return {
    packageRoot,
    manifestPath
  };
}

async function resolveManifestFile({ requestedManifest, packageRoot }) {
  let stat;
  try {
    stat = await fs.lstat(requestedManifest);
  } catch (error) {
    fail(`cannot read operator-inputs manifest: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail('operator-inputs manifest must not be a symlink');
  }
  if (!stat.isFile()) {
    fail('operator-inputs manifest must point to a JSON file');
  }

  let realPath;
  try {
    realPath = await fs.realpath(requestedManifest);
  } catch (error) {
    fail(`cannot resolve operator-inputs manifest: ${error.message}`);
  }
  if (!isInsidePath(packageRoot, realPath)) {
    fail('operator-inputs manifest must resolve inside operator-inputs package');
  }
  return realPath;
}

async function resolveRefs({ manifest, baseDir }) {
  const refs = {};

  for (const field of FILE_FIELDS) {
    if (!Object.hasOwn(manifest, field)) {
      continue;
    }
    const resolved = await resolvePackagePath({
      baseDir,
      key: { value: manifest[field], label: field },
      kind: 'file'
    });
    const { sha256 } = await readFileDigest(resolved.absolutePath, field);
    refs[field] = {
      kind: 'file',
      path: resolved.path,
      absolute_path: resolved.absolutePath,
      sha256
    };
  }

  for (const field of DIRECTORY_FIELDS) {
    if (!Object.hasOwn(manifest, field)) {
      continue;
    }
    const resolved = await resolvePackagePath({
      baseDir,
      key: { value: manifest[field], label: field },
      kind: 'directory'
    });
    refs[field] = {
      kind: 'directory',
      path: resolved.path,
      absolute_path: resolved.absolutePath,
      ...(await digestDirectory(resolved.absolutePath))
    };
  }

  for (const field of COMMAND_FIELDS) {
    if (!Object.hasOwn(manifest, field)) {
      continue;
    }
    refs[field] = await resolveCommand({
      baseDir,
      value: manifest[field],
      label: field
    });
  }

  return refs;
}

function collectRawRefsForCleanupSafety({ manifest, baseDir }) {
  const refs = {};
  for (const field of [...FILE_FIELDS, ...DIRECTORY_FIELDS, ...COMMAND_FIELDS]) {
    if (!Object.hasOwn(manifest, field)) {
      continue;
    }
    const relativePath = assertPackageRelativeInput(
      manifest[field],
      `operator-inputs manifest.${field}`
    );
    refs[field] = {
      kind: DIRECTORY_FIELDS.has(field) ? 'directory' : 'file',
      path: relativePath,
      absolute_path: path.resolve(baseDir, relativePath)
    };
  }
  return refs;
}

function targetProfileObject(value) {
  const text = assertString(value, 'deployment_path target_profile');
  const [targetCluster, substrateSource, distribution] = text.split('/');
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateAirgapBundleManifestTarget({ bundleManifest, expectedTargetProfile }) {
  assertStringEquals(
    bundleManifest.schema_version,
    AIRGAP_BUNDLE_MANIFEST_SCHEMA,
    'airgap_bundle_manifest.schema_version'
  );

  const profile = requirePlainObject(
    bundleManifest.target_profile,
    'airgap_bundle_manifest.target_profile'
  );
  assertTargetProfileFieldEquals(
    profile.value,
    expectedTargetProfile.value,
    'airgap_bundle_manifest.target_profile.value'
  );
  assertTargetProfileFieldEquals(
    profile.target_cluster,
    expectedTargetProfile.target_cluster,
    'airgap_bundle_manifest.target_profile.target_cluster'
  );
  assertTargetProfileFieldEquals(
    profile.substrate_source,
    expectedTargetProfile.substrate_source,
    'airgap_bundle_manifest.target_profile.substrate_source'
  );
  assertTargetProfileFieldEquals(
    profile.distribution,
    expectedTargetProfile.distribution,
    'airgap_bundle_manifest.target_profile.distribution'
  );

  const substrate = requirePlainObject(
    bundleManifest.substrate,
    'airgap_bundle_manifest.substrate'
  );
  assertTargetProfileFieldEquals(
    substrate.mode,
    expectedTargetProfile.substrate_source,
    'airgap_bundle_manifest.substrate.mode'
  );
  assertBooleanEquals(
    substrate.bundled,
    expectedTargetProfile.substrate_source === 'kit_installed',
    'airgap_bundle_manifest.substrate.bundled'
  );
}

function expectedAirgapComponentKinds(expectedTargetProfile) {
  return expectedTargetProfile.value === 'existing_kubernetes/kit_installed/airgap'
    ? AIRGAP_KIT_COMPONENT_KINDS
    : AIRGAP_BASE_COMPONENT_KINDS;
}

function assertAirgapBundleRelativePath(value, label) {
  const relativePath = assertString(value, label);
  if (
    relativePath.trim() !== relativePath ||
    path.posix.isAbsolute(relativePath) ||
    path.isAbsolute(relativePath) ||
    WINDOWS_DRIVE_RE.test(relativePath) ||
    relativePath.includes('\\') ||
    URI_SCHEME_RE.test(relativePath)
  ) {
    fail(`${label} must be a relative bundle path`);
  }
  if (relativePath.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) {
    fail(`${label} must not contain empty, dot, or parent segments`);
  }
  return relativePath;
}

async function resolveAirgapBundleComponent({ bundleRoot, component, label }) {
  const relativePath = assertAirgapBundleRelativePath(component.path, `${label}.path`);
  const requested = path.resolve(bundleRoot, relativePath);
  if (!isInsidePath(bundleRoot, requested)) {
    fail(`${label}.path must resolve inside airgap_bundle`);
  }

  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${label}.path: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label}.path must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label}.path must point to a file`);
  }

  let realPath;
  try {
    realPath = await fs.realpath(requested);
  } catch (error) {
    fail(`cannot resolve ${label}.path: ${error.message}`);
  }
  if (!isInsidePath(bundleRoot, realPath)) {
    fail(`${label}.path must resolve inside airgap_bundle`);
  }

  const { sha256 } = await readFileDigest(realPath, `${label}.path`);
  return {
    absolute_path: realPath,
    sha256
  };
}

async function validateAirgapBundleComponents({
  bundleRoot,
  bundleManifest,
  expectedTargetProfile,
  refs
}) {
  const components = bundleManifest.components;
  if (!Array.isArray(components)) {
    fail('airgap_bundle_manifest.components must be an array');
  }

  const expectedKinds = expectedAirgapComponentKinds(expectedTargetProfile);
  const expectedKindSet = new Set(expectedKinds);
  if (components.length !== expectedKinds.length) {
    fail(`airgap_bundle_manifest.components must contain ${expectedKinds.join(', ')}`);
  }

  const seen = new Set();
  const componentRefs = {};
  for (const [index, value] of components.entries()) {
    const label = `airgap_bundle_manifest.components[${index}]`;
    const component = assertAllowedKeys(value, AIRGAP_COMPONENT_KEYS, label);
    const kind = assertString(component.kind, `${label}.kind`);
    if (!expectedKindSet.has(kind)) {
      fail(`${label}.kind is invalid; expected ${expectedKinds.join(', ')}`);
    }
    if (seen.has(kind)) {
      fail(`airgap_bundle_manifest.components contains duplicate kind: ${kind}`);
    }
    seen.add(kind);

    const declaredSha256 = assertDigest(component.sha256, `${label}.sha256`);
    const componentFile = await resolveAirgapBundleComponent({
      bundleRoot,
      component,
      label
    });
    if (componentFile.sha256 !== declaredSha256) {
      fail(`${label}.sha256 must match component file sha256`);
    }
    if (refs[kind] && refs[kind].absolute_path !== componentFile.absolute_path) {
      fail(`${kind} must match airgap_bundle_manifest.components.${kind}.path for airgap deployment_path`);
    }
    if (refs[kind] && refs[kind].sha256 !== declaredSha256) {
      fail(`airgap_bundle_manifest.components.${kind}.sha256 must match ${kind}`);
    }
    componentRefs[kind] = componentFile;
  }

  for (const kind of expectedKinds) {
    if (!seen.has(kind)) {
      fail(`airgap_bundle_manifest.components is missing ${kind}`);
    }
  }

  return componentRefs;
}

function airgapRuntimeBundleInputKeys(deploymentPath) {
  const keys = ['render_values', 'target_prerequisites'];
  if (deploymentPath === 'airgap/use_existing') {
    keys.push('substrate_truth');
  }
  if (deploymentPath === 'airgap/install_substrates') {
    keys.push('substrate_install_inputs');
  }
  return keys;
}

function validateAirgapRuntimeInputRefs({ refs, bundle, deploymentPath }) {
  for (const key of airgapRuntimeBundleInputKeys(deploymentPath)) {
    const ref = refs[key];
    if (ref && !isInsidePath(bundle.absolute_path, ref.absolute_path)) {
      fail(`${key} must resolve inside airgap_bundle for ${deploymentPath}`);
    }
  }
}

async function validateAirgapBundleRefs({ manifest, refs, config }) {
  if (!manifest.deployment_path.startsWith('airgap/')) {
    return {};
  }
  const bundle = refs.airgap_bundle;
  const bundleManifest = refs.airgap_bundle_manifest;
  if (!bundle || !bundleManifest) {
    return {};
  }
  if (!isInsidePath(bundle.absolute_path, bundleManifest.absolute_path)) {
    fail('airgap_bundle_manifest must resolve inside airgap_bundle');
  }
  const { value: bundleManifestJson } = await readJson(
    bundleManifest.absolute_path,
    'airgap_bundle_manifest'
  );
  const bundleManifestObject = requirePlainObject(bundleManifestJson, 'airgap_bundle_manifest');
  const expectedTargetProfile = targetProfileObject(config.targetProfile);
  validateAirgapBundleManifestTarget({
    bundleManifest: bundleManifestObject,
    expectedTargetProfile
  });
  validateAirgapRuntimeInputRefs({
    refs,
    bundle,
    deploymentPath: manifest.deployment_path
  });
  return validateAirgapBundleComponents({
    bundleRoot: bundle.absolute_path,
    bundleManifest: bundleManifestObject,
    expectedTargetProfile,
    refs
  });
}

function refPath(refs, key) {
  const ref = refs[key];
  if (!ref) {
    return undefined;
  }
  if (ref.kind === 'command') {
    return ref.command;
  }
  return ref.absolute_path;
}

function addOptional(argv, flag, value) {
  if (value !== undefined && value !== null && value !== '') {
    argv.push(flag, String(value));
  }
}

function addOptionalBoolean(argv, flag, value) {
  if (value === true) {
    argv.push(flag);
  }
}

function deploymentPathOutputSlug(deploymentPath) {
  return deploymentPath.replace(/[/_]+/g, '-');
}

function internalRuntimeRoot(packageRoot) {
  return path.join(packageRoot, INTERNAL_DIR);
}

async function lstatIfExists(absolutePath, label) {
  try {
    return await fs.lstat(absolutePath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return undefined;
    }
    fail(`cannot read ${label}: ${error.message}`);
  }
}

async function realpathForExisting(absolutePath, label) {
  try {
    return await fs.realpath(absolutePath);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

async function ensureInternalRuntimeRoot(packageRoot) {
  const internalPath = internalRuntimeRoot(packageRoot);
  let stat = await lstatIfExists(internalPath, 'operator-inputs internal output root');
  if (!stat) {
    try {
      await fs.mkdir(internalPath);
    } catch (error) {
      if (error.code !== 'EEXIST') {
        fail(`cannot create operator-inputs internal output root: ${error.message}`);
      }
    }
    stat = await lstatIfExists(internalPath, 'operator-inputs internal output root');
  }
  if (!stat) {
    fail('cannot create operator-inputs internal output root');
  }
  if (stat.isSymbolicLink()) {
    fail('operator-inputs internal output root must not be a symlink');
  }
  if (!stat.isDirectory()) {
    fail('operator-inputs internal output root must be a directory');
  }

  const realPath = await realpathForExisting(
    internalPath,
    'operator-inputs internal output root'
  );
  if (!isInsidePath(packageRoot, realPath)) {
    fail('operator-inputs internal output root resolves outside the operator-inputs package');
  }
  return realPath;
}

async function ensureDirectoryInsideInternalRoot({ internalRoot, targetDir, label }) {
  const absoluteDir = path.resolve(targetDir);
  if (!isInsidePath(internalRoot, absoluteDir)) {
    fail(`${label} must be inside operator-inputs internal output root`);
  }

  const relativePath = path.relative(internalRoot, absoluteDir);
  const segments = relativePath === '' ? [] : relativePath.split(path.sep);
  let current = internalRoot;

  for (const segment of segments) {
    current = path.join(current, segment);
    let stat = await lstatIfExists(current, label);
    if (!stat) {
      try {
        await fs.mkdir(current);
      } catch (error) {
        if (error.code !== 'EEXIST') {
          fail(`cannot create ${label}: ${error.message}`);
        }
      }
      stat = await lstatIfExists(current, label);
    }
    if (!stat) {
      fail(`cannot create ${label}`);
    }
    if (stat.isSymbolicLink()) {
      fail(`${label} must not contain a symlink`);
    }
    if (!stat.isDirectory()) {
      fail(`${label} must be a directory`);
    }

    const realPath = await realpathForExisting(current, label);
    if (!isInsidePath(internalRoot, realPath)) {
      fail(`${label} resolves outside operator-inputs internal output root`);
    }
  }

  const realTarget = await realpathForExisting(absoluteDir, label);
  if (!isInsidePath(internalRoot, realTarget)) {
    fail(`${label} resolves outside operator-inputs internal output root`);
  }
  return realTarget;
}

async function requireExistingDirectoryInsideInternalRoot({ internalRoot, targetDir, label }) {
  const absoluteDir = path.resolve(targetDir);
  if (!isInsidePath(internalRoot, absoluteDir)) {
    fail(`${label} must be inside operator-inputs internal output root`);
  }

  const stat = await lstatIfExists(absoluteDir, label);
  if (!stat) {
    fail(`${label} must exist`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isDirectory()) {
    fail(`${label} must be a directory`);
  }

  const realTarget = await realpathForExisting(absoluteDir, label);
  if (!isInsidePath(internalRoot, realTarget)) {
    fail(`${label} resolves outside operator-inputs internal output root`);
  }
  return realTarget;
}

async function cleanupTempPlanFile(tempPath) {
  try {
    await fs.unlink(tempPath);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      fail(`cannot remove operator-inputs plan temp file: ${error.message}`);
    }
  }
}

async function writePlanFileNoSymlink({ planPath, internalRoot, body }) {
  const outputDir = path.dirname(planPath);
  const fileName = path.basename(planPath);
  const canonicalDir = await requireExistingDirectoryInsideInternalRoot({
    internalRoot,
    targetDir: outputDir,
    label: 'operator-inputs plan output dir'
  });
  const canonicalPlanPath = path.join(canonicalDir, fileName);
  const existingStat = await lstatIfExists(canonicalPlanPath, 'operator-inputs plan output');
  if (existingStat?.isSymbolicLink()) {
    fail('operator-inputs plan output must not be a symlink');
  }
  if (existingStat && !existingStat.isFile()) {
    fail('operator-inputs plan output must be a regular file');
  }

  const tempPath = path.join(
    canonicalDir,
    `.${fileName}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`
  );
  let handle;
  try {
    handle = await fs.open(tempPath, 'wx', 0o600);
    await handle.writeFile(body);
    await handle.sync();
  } catch (error) {
    await cleanupTempPlanFile(tempPath);
    fail(`cannot write operator-inputs plan temp file: ${error.message}`);
  } finally {
    if (handle) {
      await handle.close();
    }
  }

  const tempStat = await lstatIfExists(tempPath, 'operator-inputs plan temp file');
  if (!tempStat || tempStat.isSymbolicLink() || !tempStat.isFile()) {
    await cleanupTempPlanFile(tempPath);
    fail('operator-inputs plan temp file must be a regular file');
  }

  const commitDir = await requireExistingDirectoryInsideInternalRoot({
    internalRoot,
    targetDir: canonicalDir,
    label: 'operator-inputs plan output dir'
  });
  if (commitDir !== canonicalDir) {
    await cleanupTempPlanFile(tempPath);
    fail('operator-inputs plan output dir changed while writing');
  }

  const currentStat = await lstatIfExists(canonicalPlanPath, 'operator-inputs plan output');
  if (currentStat?.isSymbolicLink()) {
    await cleanupTempPlanFile(tempPath);
    fail('operator-inputs plan output must not be a symlink');
  }
  if (currentStat) {
    if (!currentStat.isFile()) {
      await cleanupTempPlanFile(tempPath);
      fail('operator-inputs plan output must be a regular file');
    }
    try {
      await fs.unlink(canonicalPlanPath);
    } catch (error) {
      await cleanupTempPlanFile(tempPath);
      fail(`cannot replace operator-inputs plan output: ${error.message}`);
    }
  }

  try {
    await fs.link(tempPath, canonicalPlanPath);
  } catch (error) {
    await cleanupTempPlanFile(tempPath);
    if (error.code === 'EEXIST') {
      fail('operator-inputs plan output changed while writing; refusing to overwrite');
    }
    fail(`cannot commit operator-inputs plan output: ${error.message}`);
  }
  await cleanupTempPlanFile(tempPath);

  const finalDir = await requireExistingDirectoryInsideInternalRoot({
    internalRoot,
    targetDir: canonicalDir,
    label: 'operator-inputs plan output dir'
  });
  if (finalDir !== canonicalDir) {
    fail('operator-inputs plan output dir changed after writing');
  }
  const finalStat = await lstatIfExists(canonicalPlanPath, 'operator-inputs plan output');
  if (!finalStat || finalStat.isSymbolicLink() || !finalStat.isFile()) {
    fail('operator-inputs plan output must be a regular file');
  }
}

function deploymentPathOutputBase(outputRoot, deploymentPath) {
  return path.join(outputRoot, deploymentPathOutputSlug(deploymentPath));
}

async function cleanupDeploymentPathOutputs(outputDir) {
  await fs.rm(path.join(outputDir, DEPLOYMENT_PATH_REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, DEPLOYMENT_PATH_FINALIZER_MANIFEST), { force: true });
  await fs.rm(path.join(outputDir, DEPLOYMENT_PATH_SOURCE_EVIDENCE_DIR), {
    recursive: true,
    force: true
  });
}

function assertRefsOutsideCleanupRange({ refs, cleanupDir }) {
  for (const [key, ref] of Object.entries(refs)) {
    const absolutePath = ref?.absolute_path;
    if (!absolutePath) {
      continue;
    }
    if (isInsidePath(cleanupDir, absolutePath)) {
      fail(`operator-inputs manifest.${key} must not overlap deployment-path cleanup output`);
    }
    if (ref.kind === 'directory' && isInsidePath(absolutePath, cleanupDir)) {
      fail(`operator-inputs manifest.${key} must not contain deployment-path cleanup output`);
    }
  }
}

export async function cleanupStaleOperatorInputsPathEvidence({ inputPath } = {}) {
  if (!inputPath) {
    fail('--operator-inputs is required');
  }

  const { packageRoot, manifestPath } = await resolveManifestInput(inputPath);
  const { value: manifest } = await readJson(manifestPath, MANIFEST_FILE);
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    return {
      cleaned: false,
      deploymentPath: null
    };
  }

  const deploymentPath =
    typeof manifest.deployment_path === 'string' ? manifest.deployment_path : null;
  if (!deploymentPath || !DEPLOYMENT_PATH_CONFIG.has(deploymentPath)) {
    return {
      cleaned: false,
      deploymentPath
    };
  }

  const refs = collectRawRefsForCleanupSafety({ manifest, baseDir: packageRoot });
  const runtimeOutputRoot = await ensureInternalRuntimeRoot(packageRoot);
  const deploymentOutputBase = deploymentPathOutputBase(runtimeOutputRoot, deploymentPath);
  await ensureDirectoryInsideInternalRoot({
    internalRoot: runtimeOutputRoot,
    targetDir: deploymentOutputBase,
    label: 'operator-inputs deployment output base'
  });
  const deploymentPathOutputDir = await ensureDirectoryInsideInternalRoot({
    internalRoot: runtimeOutputRoot,
    targetDir: path.join(deploymentOutputBase, 'deployment-path'),
    label: 'deployment-path output dir'
  });
  assertRefsOutsideCleanupRange({ refs, cleanupDir: deploymentPathOutputDir });
  await cleanupDeploymentPathOutputs(deploymentPathOutputDir);

  return {
    cleaned: true,
    deploymentPath,
    deploymentPathOutputDir
  };
}

function optionalPlanString(value) {
  return value === undefined ? null : String(value);
}

function installParametersSha256(installParameters) {
  return installParameters?.installParametersDigest ?? null;
}

async function resolveInstallParameters({ manifest, refs, config }) {
  if (!config.installSubstrates) {
    return null;
  }

  const installInput = await readJson(
    refs.substrate_install_inputs.absolute_path,
    'substrate_install_inputs'
  );
  const installSummary = validateSubstrateInstallInputs(
    installInput.value,
    targetProfileObject(config.targetProfile),
    {
      fail,
      raw: installInput.raw
    }
  );
  const installParameters = await resolveSubstrateInstallParameters({
    installInput,
    installSummary,
    namespace: manifest.namespace,
    readJson,
    fail
  });

  const legacyDigest = manifest.install_confirmation.install_parameters_sha256;
  if (
    legacyDigest !== undefined &&
    legacyDigest !== installParameters.installParametersDigest
  ) {
    fail('install_confirmation.install_parameters_sha256 must match computed install parameters sha256');
  }
  return installParameters;
}

function buildInternalExpected({ manifest, config, outputRoot, mode, installParameters }) {
  const outputBase = deploymentPathOutputBase(outputRoot, manifest.deployment_path);
  const substrateInstallOutputDir = config.installSubstrates
    ? path.join(outputBase, 'substrate-install')
    : null;
  const airgapConsumeRehearsalOutputDir =
    config.producer === 'airgap' && !config.installSubstrates
      ? path.join(outputBase, 'airgap-consume-rehearsal')
      : null;
  return {
    schema_version: INTERNAL_EXPECTED_SCHEMA,
    deployment_path: manifest.deployment_path,
    target_profile: config.targetProfile,
    namespace: manifest.namespace,
    context: Object.hasOwn(manifest, 'context') ? manifest.context : null,
    mode,
    operator_run_id: manifest.deploy_confirmation?.operator_run_id ?? null,
    install: config.installSubstrates
      ? {
          operator_run_id: manifest.install_confirmation.operator_run_id,
          install_parameters_sha256: installParametersSha256(installParameters)
        }
      : null,
    output_dirs: {
      substrate_install: substrateInstallOutputDir,
      online_deployment_gate:
        config.producer === 'online' ? path.join(outputBase, 'online-deployment-gate') : null,
      airgap_consume_rehearsal: airgapConsumeRehearsalOutputDir,
      airgap_bundle_check:
        config.producer === 'airgap'
          ? path.join(
              airgapConsumeRehearsalOutputDir ?? outputBase,
              'airgap-bundle-check'
            )
          : null,
      airgap_deployment_gate:
        config.producer === 'airgap'
          ? path.join(
              airgapConsumeRehearsalOutputDir ?? outputBase,
              'airgap-deployment-gate'
            )
          : null,
      deployment_path: path.join(outputBase, 'deployment-path')
    },
    generated_refs: {
      substrate_truth: substrateInstallOutputDir
        ? path.join(substrateInstallOutputDir, 'substrate-truth.json')
        : null,
      substrate_install_report: substrateInstallOutputDir
        ? path.join(substrateInstallOutputDir, 'substrate-install-report.json')
        : null
    },
    smoke: {
      timeout: optionalPlanString(manifest.timeout),
      smoke_url: optionalPlanString(manifest.smoke_url),
      expected_status: optionalPlanString(manifest.expected_status),
      timeout_ms: optionalPlanString(manifest.timeout_ms),
      allow_http: manifest.allow_http === true,
      allow_localhost: manifest.allow_localhost === true
    }
  };
}

function addApplyRuntimeArgs({ argv, refs, manifest, targetProfile, mode, includeAirgapLoaders = false }) {
  if (mode !== 'apply') {
    return;
  }
  if (includeAirgapLoaders) {
    argv.push(
      '--archive-probe',
      refPath(refs, 'archive_probe'),
      '--image-loader',
      refPath(refs, 'image_loader')
    );
  }
  addOptional(argv, '--timeout', manifest.timeout);
  addOptional(argv, '--smoke-url', manifest.smoke_url);
  addOptional(argv, '--expected-status', manifest.expected_status);
  addOptional(argv, '--timeout-ms', manifest.timeout_ms);
  addOptionalBoolean(argv, '--allow-http', manifest.allow_http);
  addOptionalBoolean(argv, '--allow-localhost', manifest.allow_localhost);
  argv.push('--confirm-apply', targetProfile, '--operator-run-id', manifest.deploy_confirmation.operator_run_id);
}

function addCommonDeploymentArgs({
  argv,
  refs,
  manifest,
  targetProfile,
  outputDir,
  mode,
  substrateTruthPath
}) {
  argv.push(
    '--release-contract',
    refPath(refs, 'release_contract'),
    '--deploy-template-package',
    refPath(refs, 'deploy_template_package'),
    '--archive',
    refPath(refs, 'deploy_template_archive'),
    '--target-profile',
    targetProfile,
    '--render-values',
    refPath(refs, 'render_values'),
    '--substrate-truth',
    substrateTruthPath ?? refPath(refs, 'substrate_truth'),
    '--target-prerequisites',
    refPath(refs, 'target_prerequisites'),
    '--namespace',
    manifest.namespace,
    '--output-dir',
    outputDir,
    '--mode',
    mode
  );
  addOptional(argv, '--context', manifest.context);
  addOptional(argv, '--kubectl', refPath(refs, 'kubectl'));
  addApplyRuntimeArgs({ argv, refs, manifest, targetProfile, mode });
}

function requireAirgapComponent(components, kind) {
  const component = components?.[kind];
  if (!component?.absolute_path) {
    fail(`airgap_bundle_manifest.components must include ${kind}`);
  }
  return component.absolute_path;
}

function addCommonAirgapArgs({
  argv,
  refs,
  manifest,
  targetProfile,
  outputDir,
  mode,
  airgapBundleComponents,
  substrateTruthPath,
  substrateInstallReportPath,
  allowInstalledSubstrateTruth = false
}) {
  argv.push(
    '--release-contract',
    requireAirgapComponent(airgapBundleComponents, 'release_contract'),
    '--deploy-template-package',
    requireAirgapComponent(airgapBundleComponents, 'deploy_template_package'),
    '--archive',
    requireAirgapComponent(airgapBundleComponents, 'deploy_template_archive'),
    '--image-map',
    requireAirgapComponent(airgapBundleComponents, 'image_map'),
    '--target-profile',
    targetProfile,
    '--bundle-root',
    refPath(refs, 'airgap_bundle'),
    '--bundle-manifest',
    refPath(refs, 'airgap_bundle_manifest'),
    '--render-values',
    refPath(refs, 'render_values'),
    '--substrate-truth',
    substrateTruthPath ?? refPath(refs, 'substrate_truth'),
    '--target-prerequisites',
    refPath(refs, 'target_prerequisites'),
    '--namespace',
    manifest.namespace,
    '--output-dir',
    outputDir,
    '--mode',
    mode
  );
  if (allowInstalledSubstrateTruth) {
    argv.push('--allow-installed-substrate-truth');
    argv.push('--substrate-install-report', substrateInstallReportPath);
  }
  argv.push(
    '--context',
    manifest.context,
    '--kubectl',
    refPath(refs, 'kubectl')
  );
  addApplyRuntimeArgs({
    argv,
    refs,
    manifest,
    targetProfile,
    mode,
    includeAirgapLoaders: true
  });
}

function buildProducerArgv({
  manifest,
  refs,
  config,
  outputRoot,
  mode,
  airgapBundleComponents,
  installParameters
}) {
  const outputBase = deploymentPathOutputBase(outputRoot, manifest.deployment_path);
  const substrateInstallOutputDir = path.join(outputBase, 'substrate-install');
  const generatedSubstrateTruth = path.join(substrateInstallOutputDir, 'substrate-truth.json');
  const steps = [];

  if (config.installSubstrates) {
    const argv = [
      'bash',
      VERIFY_RELEASE_SCRIPT,
      '--substrate-install',
      '--release-contract',
      refPath(refs, 'release_contract'),
      '--deploy-template-package',
      refPath(refs, 'deploy_template_package'),
      '--target-profile',
      config.targetProfile,
      '--substrate-pack-manifest',
      refPath(refs, 'substrate_pack_manifest'),
      '--substrate-install-inputs',
      refPath(refs, 'substrate_install_inputs'),
      '--target-prerequisites',
      refPath(refs, 'target_prerequisites'),
      '--namespace',
      manifest.namespace,
      '--output-dir',
      substrateInstallOutputDir,
      '--mode',
      'apply'
    ];
    argv.push(
      '--context',
      manifest.context,
      '--kubectl',
      refPath(refs, 'kubectl')
    );
    argv.push(
      '--confirm-substrate-install',
      config.targetProfile,
      '--confirm-install-parameters',
      installParametersSha256(installParameters),
      '--operator-run-id',
      manifest.install_confirmation.operator_run_id
    );
    steps.push({
      name: 'substrate-install',
      argv
    });
  }

  if (config.producer === 'online') {
    const argv = ['bash', VERIFY_RELEASE_SCRIPT, '--online-deployment-gate'];
    addCommonDeploymentArgs({
      argv,
      refs,
      manifest,
      targetProfile: config.targetProfile,
      outputDir: path.join(outputBase, 'online-deployment-gate'),
      mode,
      substrateTruthPath: config.installSubstrates ? generatedSubstrateTruth : undefined
    });
    if (config.installSubstrates) {
      argv.push('--substrate-pack-manifest', refPath(refs, 'substrate_pack_manifest'));
      argv.push('--routability-probe', refPath(refs, 'routability_probe'));
    }
    steps.push({
      name: 'online-deployment-gate',
      argv
    });
  } else if (!config.installSubstrates) {
    const argv = [
      'bash',
      VERIFY_RELEASE_SCRIPT,
      '--airgap-consume-rehearsal',
      '--bundle-root',
      refPath(refs, 'airgap_bundle'),
      '--bundle-manifest',
      refPath(refs, 'airgap_bundle_manifest'),
      '--render-values',
      refPath(refs, 'render_values'),
      '--substrate-truth',
      refPath(refs, 'substrate_truth'),
      '--target-prerequisites',
      refPath(refs, 'target_prerequisites'),
      '--namespace',
      manifest.namespace,
      '--output-dir',
      path.join(outputBase, 'airgap-consume-rehearsal'),
      '--mode',
      mode
    ];
    argv.push(
      '--context',
      manifest.context,
      '--kubectl',
      refPath(refs, 'kubectl')
    );
    addApplyRuntimeArgs({
      argv,
      refs,
      manifest,
      targetProfile: config.targetProfile,
      mode,
      includeAirgapLoaders: true
    });
    steps.push({
      name: 'airgap-consume-rehearsal',
      argv
    });
  } else {
    const bundleCheckArgv = [
      'bash',
      VERIFY_RELEASE_SCRIPT,
      '--airgap-bundle-check',
      '--release-contract',
      requireAirgapComponent(airgapBundleComponents, 'release_contract'),
      '--deploy-template-package',
      requireAirgapComponent(airgapBundleComponents, 'deploy_template_package'),
      '--archive',
      requireAirgapComponent(airgapBundleComponents, 'deploy_template_archive'),
      '--image-map',
      requireAirgapComponent(airgapBundleComponents, 'image_map'),
      '--target-profile',
      config.targetProfile,
      '--bundle-root',
      refPath(refs, 'airgap_bundle'),
      '--bundle-manifest',
      refPath(refs, 'airgap_bundle_manifest'),
      '--output-dir',
      path.join(outputBase, 'airgap-bundle-check')
    ];
    steps.push({
      name: 'airgap-bundle-check',
      argv: bundleCheckArgv
    });

    const gateArgv = ['bash', VERIFY_RELEASE_SCRIPT, '--airgap-deployment-gate'];
    addCommonAirgapArgs({
      argv: gateArgv,
      refs,
      manifest,
      targetProfile: config.targetProfile,
      outputDir: path.join(outputBase, 'airgap-deployment-gate'),
      mode,
      airgapBundleComponents,
      substrateTruthPath: generatedSubstrateTruth,
      substrateInstallReportPath: path.join(substrateInstallOutputDir, 'substrate-install-report.json'),
      allowInstalledSubstrateTruth: true
    });
    steps.push({
      name: 'airgap-deployment-gate',
      argv: gateArgv
    });
  }

  return steps;
}

function assertNoPostDeploySmokeReport(manifest) {
  for (const key of Object.keys(manifest)) {
    if (/post[-_]?deploy[-_]?smoke[-_]?report/i.test(key)) {
      fail('post-deploy smoke report is runtime evidence and must not be in operator-inputs');
    }
  }
}

export async function resolveOperatorInputs({ inputPath, outputDir } = {}) {
  if (!inputPath) {
    fail('--operator-inputs is required');
  }
  const { packageRoot, manifestPath } = await resolveManifestInput(inputPath);
  const manifestRelativePath = packageRelativePath(packageRoot, manifestPath);
  const { value: manifest, sha256: manifestSha256 } = await readJson(manifestPath, MANIFEST_FILE);
  assertPlainObject(manifest, MANIFEST_FILE);
  assertNoPostDeploySmokeReport(manifest);
  validateTopLevelFields(manifest);
  scanManifestForForbiddenContent(manifest, MANIFEST_FILE);
  validateScalarFields(manifest);
  const mode = validateSchemaAndPath(manifest);
  validateSmokeRuntimeFields(manifest, mode);
  validateSmokeUrlField(manifest);
  validateUnsupportedInputs(manifest);
  const config = DEPLOYMENT_PATH_CONFIG.get(manifest.deployment_path);
  validatePathSpecificUnsupportedInputs({ manifest, config });
  const requiredInputs = requireFields({ manifest, config, mode });
  validateConfirmations({ manifest, config, mode });

  const refs = await resolveRefs({ manifest, baseDir: packageRoot });
  const airgapBundleComponents = await validateAirgapBundleRefs({ manifest, refs, config });
  const missingRequiredRef = [
    ...requiredInputs.files,
    ...requiredInputs.dirs,
    ...requiredInputs.commands
  ]
    .find((key) => !refs[key]);
  if (missingRequiredRef) {
    fail(`missing resolved input ref: ${missingRequiredRef}`);
  }

  const runtimeOutputRoot = await ensureInternalRuntimeRoot(packageRoot);
  const planOutputDir = outputDir
    ? await ensureDirectoryInsideInternalRoot({
        internalRoot: runtimeOutputRoot,
        targetDir: outputDir,
        label: 'operator-inputs plan output dir'
      })
    : runtimeOutputRoot;
  const planPath = path.join(planOutputDir, PLAN_FILE);
  const installParameters = await resolveInstallParameters({ manifest, refs, config });
  const internalExpected = buildInternalExpected({
    manifest,
    config,
    outputRoot: runtimeOutputRoot,
    mode,
    installParameters
  });
  const producerArgv = buildProducerArgv({
    manifest,
    refs,
    config,
    outputRoot: runtimeOutputRoot,
    mode,
    airgapBundleComponents,
    installParameters
  });
  const plan = {
    schema_version: PLAN_SCHEMA,
    scope: PLAN_SCOPE,
    status: 'pass',
    repo_root: REPO_ROOT,
    operator_inputs_root: packageRoot,
    argv_path_mode: 'absolute',
    deployment_path: manifest.deployment_path,
    mode,
    package: {
      manifest_path: manifestPath,
      manifest_relative_path: manifestRelativePath,
      manifest_sha256: manifestSha256
    },
    input_refs: refs,
    _internal: {
      expected: internalExpected
    },
    facade_argv: [
      'bash',
      OPERATOR_RELEASE_SCRIPT,
      '--operator-inputs',
      path.basename(manifestPath) === MANIFEST_FILE ? packageRoot : manifestPath
    ],
    producer_argv: producerArgv,
    plan_sha256: null
  };
  plan.plan_sha256 = digestJson({ ...plan, plan_sha256: null });
  await writePlanFileNoSymlink({
    planPath,
    internalRoot: runtimeOutputRoot,
    body: `${JSON.stringify(plan, null, 2)}\n`
  });

  return {
    plan,
    planPath
  };
}

export { MANIFEST_FILE, PLAN_FILE };
