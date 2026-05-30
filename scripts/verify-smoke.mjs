#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const REQUIRED_ARGS = [
  'releaseContract',
  'rolloutReport',
  'targetProfile',
  'url',
  'outputDir'
];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const ROLLOUT_REPORT_SCHEMA = 'agentsmith.kubernetes-rollout-report/v1';
const REPORT_SCHEMA = 'agentsmith.route-smoke-report/v1';
const SMOKE_SCOPE = 'route_smoke_only';
const ROLLOUT_SCOPE = 'kubernetes_rollout_imageid_only';
const SUPPORTED_TARGET_PROFILES = new Set([
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
]);
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const FORBIDDEN_ROUTE_TEXT_RE = /(?:required_product_flows|product_flows|product_flow_results|deploy_readiness|release_verdict|\bverdict\b|\bkubeconfig\b)/i;
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:password|passwd|pwd|token|secret|client_secret|private_key|access_key|api_key)\s*[:=]\s*[^/\s]{8,}/i
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
  node scripts/verify-smoke.mjs \\
    --release-contract <json> \\
    --rollout-report <json> \\
    --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> \\
    --url <https-url> \\
    --output-dir <dir> \\
    [--expected-status <code>] \\
    [--timeout-ms <ms>] \\
    [--allow-http] \\
    [--allow-localhost]`;
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

function nextValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {
    expectedStatus: '200',
    timeoutMs: '5000',
    allowHttp: false,
    allowLocalhost: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const readValue = () => {
      const value = nextValue(argv, index, arg);
      index += 1;
      return value;
    };

    if (arg.startsWith('--expected-status=')) {
      parsed.expectedStatus = arg.slice('--expected-status='.length);
      continue;
    }
    if (arg.startsWith('--timeout-ms=')) {
      parsed.timeoutMs = arg.slice('--timeout-ms='.length);
      continue;
    }

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = readValue();
        break;
      case '--rollout-report':
        parsed.rolloutReport = readValue();
        break;
      case '--target-profile':
        parsed.targetProfile = readValue();
        break;
      case '--url':
        parsed.url = readValue();
        break;
      case '--output-dir':
        parsed.outputDir = readValue();
        break;
      case '--expected-status':
        parsed.expectedStatus = readValue();
        break;
      case '--timeout-ms':
        parsed.timeoutMs = readValue();
        break;
      case '--allow-http':
        parsed.allowHttp = true;
        break;
      case '--allow-localhost':
        parsed.allowLocalhost = true;
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

async function removeStaleReport(outputDir) {
  await fs.rm(path.join(outputDir, 'smoke-report.json'), { force: true });
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

function requireGitSha(value, label) {
  const gitSha = requireString(value, label).toLowerCase();
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function parseTargetProfile(value) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail('target_profile is required');
  }

  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!SUPPORTED_TARGET_PROFILES.has(normalized)) {
    fail(`--smoke only accepts ${[...SUPPORTED_TARGET_PROFILES].join(', ')}`);
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function parseInteger(value, label, min, max) {
  const text = requireString(value, label);
  if (!/^(?:0|[1-9][0-9]*)$/.test(text)) {
    fail(`${label} must be an integer`);
  }
  const parsed = Number(text);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    fail(`${label} must be between ${min} and ${max}`);
  }
  return parsed;
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

function isLocalhost(hostname) {
  const normalized = hostname
    .toLowerCase()
    .replace(/^\[(.*)\]$/, '$1')
    .replace(/\.+$/, '');
  return (
    normalized === 'localhost' ||
    normalized === 'host.docker.internal' ||
    normalized === '::' ||
    normalized === '::1' ||
    isIpv4MappedLoopback(normalized) ||
    /^127(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

function decodedPath(pathname) {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return pathname;
  }
}

function assertSafeRoutePath(pathname) {
  const values = [pathname, decodedPath(pathname)];
  for (const value of values) {
    if (FORBIDDEN_ROUTE_TEXT_RE.test(value)) {
      fail('url path contains report-forbidden text');
    }
    if (SECRET_VALUE_RE.some((pattern) => pattern.test(value))) {
      fail('url path contains a secret-looking payload');
    }
  }
}

function parseSmokeUrl(value, args) {
  const input = requireString(value, 'url');
  if (input !== input.trim() || /[\s\r\n]/.test(input)) {
    fail('url must not contain whitespace');
  }

  let parsed;
  try {
    parsed = new URL(input);
  } catch {
    fail('url must be an absolute URL');
  }

  if (parsed.username || parsed.password) {
    fail('url must not include userinfo');
  }
  if (parsed.search || parsed.hash || input.includes('?') || input.includes('#')) {
    fail('url must not include query or hash');
  }
  if (parsed.protocol !== 'https:' && !(args.allowHttp && parsed.protocol === 'http:')) {
    fail('url must use https unless --allow-http is explicit');
  }
  if (!args.allowLocalhost && isLocalhost(parsed.hostname)) {
    fail('url must not target localhost unless --allow-localhost is explicit');
  }
  assertSafeRoutePath(parsed.pathname || '/');

  return {
    parsed,
    summary: {
      scheme: parsed.protocol.slice(0, -1),
      origin: parsed.origin,
      host: parsed.host,
      path: parsed.pathname || '/'
    }
  };
}

function assertContractTargetProfile(contract, targetProfile) {
  const profiles = requireArray(contract.target_profiles, 'release_contract.target_profiles');
  const matched = profiles.some((profileValue, index) => {
    const profile = requireObject(profileValue, `release_contract.target_profiles[${index}]`);
    return (
      profile.target_cluster === targetProfile.target_cluster &&
      profile.substrate_source === targetProfile.substrate_source &&
      profile.distribution === targetProfile.distribution
    );
  });

  if (!matched) {
    fail(`release_contract.target_profiles must include ${targetProfile.value}`);
  }
}

function validateReleaseContract(releaseContractInput, targetProfile) {
  const contract = requireObject(releaseContractInput.value, 'release_contract');
  const schemaVersion = requireString(
    contract.schema_version,
    'release_contract.schema_version'
  );
  if (schemaVersion !== RELEASE_CONTRACT_SCHEMA) {
    fail(`release_contract.schema_version must be ${RELEASE_CONTRACT_SCHEMA}`);
  }

  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  assertContractTargetProfile(contract, targetProfile);

  return {
    release_id: releaseId,
    git_sha: gitSha,
    input_sha256: releaseContractInput.inputDigest
  };
}

function requireReportTargetProfile(report, targetProfile) {
  const profile = requireObject(report.target_profile, 'rollout_report.target_profile');
  const value = requireString(profile.value, 'rollout_report.target_profile.value');
  if (
    value !== targetProfile.value ||
    profile.target_cluster !== targetProfile.target_cluster ||
    profile.substrate_source !== targetProfile.substrate_source ||
    profile.distribution !== targetProfile.distribution
  ) {
    fail('rollout_report.target_profile must match CLI target_profile');
  }
}

function validateRolloutReport(rolloutReportInput, releaseIdentity, targetProfile) {
  const report = requireObject(rolloutReportInput.value, 'rollout_report');
  const schema = requireString(report.schema, 'rollout_report.schema');
  if (schema !== ROLLOUT_REPORT_SCHEMA) {
    fail(`rollout_report.schema must be ${ROLLOUT_REPORT_SCHEMA}`);
  }
  if (report.readiness !== false) {
    fail('rollout_report.readiness must be false');
  }
  if (report.status !== 'pass') {
    fail('rollout_report.status must be pass');
  }
  if (report.scope !== ROLLOUT_SCOPE) {
    fail(`rollout_report.scope must be ${ROLLOUT_SCOPE}`);
  }

  const releaseId = requireString(report.release_id, 'rollout_report.release_id');
  if (releaseId !== releaseIdentity.release_id) {
    fail('rollout_report.release_id must match release contract');
  }

  const gitSha = requireGitSha(report.git_sha, 'rollout_report.git_sha');
  if (gitSha !== releaseIdentity.git_sha) {
    fail('rollout_report.git_sha must match release contract');
  }

  const releaseContract = requireObject(
    report.release_contract,
    'rollout_report.release_contract'
  );
  const rolloutContractDigest = requireDigest(
    releaseContract.input_sha256,
    'rollout_report.release_contract.input_sha256'
  );
  if (rolloutContractDigest !== releaseIdentity.input_sha256) {
    fail('rollout_report.release_contract.input_sha256 must match release contract');
  }

  requireReportTargetProfile(report, targetProfile);

  return {
    input_sha256: rolloutReportInput.inputDigest,
    schema,
    scope: report.scope,
    status: report.status,
    generated_at: typeof report.generated_at === 'string' ? report.generated_at : undefined
  };
}

async function runSmokeGet(url, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();

  try {
    const response = await fetch(url.href, {
      method: 'GET',
      redirect: 'manual',
      signal: controller.signal
    });
    const durationMs = Math.max(0, Date.now() - startedAt);
    if (response.body) {
      await response.body.cancel().catch(() => {});
    }
    return {
      status_code: response.status,
      duration_ms: durationMs
    };
  } catch (error) {
    if (error?.name === 'AbortError') {
      fail(`route smoke GET timed out after ${timeoutMs}ms`);
    }
    fail(`route smoke GET failed: ${error.message}`);
  } finally {
    clearTimeout(timeout);
  }
}

function buildReport({
  releaseIdentity,
  targetProfile,
  route,
  expectedStatus,
  smokeResult,
  rolloutSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: SMOKE_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: releaseIdentity.release_id,
    git_sha: releaseIdentity.git_sha,
    release_contract: {
      input_sha256: releaseIdentity.input_sha256
    },
    target_profile: targetProfile,
    route,
    expected_status: expectedStatus,
    status_code: smokeResult.status_code,
    duration_ms: smokeResult.duration_ms,
    rollout_report: rolloutSummary,
    generated_at: new Date().toISOString()
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'smoke-report.json');
  const tempFile = path.join(outputDir, `.smoke-report.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(args.outputDir);

  const targetProfile = parseTargetProfile(args.targetProfile);
  const expectedStatus = parseInteger(args.expectedStatus, 'expected_status', 100, 599);
  const timeoutMs = parseInteger(args.timeoutMs, 'timeout_ms', 1, 300000);
  const route = parseSmokeUrl(args.url, args);
  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const releaseIdentity = validateReleaseContract(releaseContractInput, targetProfile);
  const rolloutReportInput = await readJson(args.rolloutReport, 'rollout report');
  const rolloutSummary = validateRolloutReport(
    rolloutReportInput,
    releaseIdentity,
    targetProfile
  );

  const smokeResult = await runSmokeGet(route.parsed, timeoutMs);
  if (smokeResult.status_code !== expectedStatus) {
    fail(`route smoke status ${smokeResult.status_code} did not match expected ${expectedStatus}`);
  }

  await writeReport(
    args.outputDir,
    buildReport({
      releaseIdentity,
      targetProfile,
      route: route.summary,
      expectedStatus,
      smokeResult,
      rolloutSummary
    })
  );

  console.log('PASS: route smoke accepted expected status');
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
