#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  SUBSTRATE_CONNECTION_SCHEMA,
  TARGET_PREREQUISITES_SCHEMA,
  assertNoUnsafeSubstratePayload,
  validateSubstrateConnectionTruth,
  validateTargetPrerequisitesTruth
} from './lib/substrate-truth-validation.mjs';

const REQUIRED_ARGS = [
  'targetProfile',
  'substratePackCheckReport',
  'substrateTruth',
  'targetPrerequisites',
  'namespace',
  'kubectl',
  'routabilityProbe',
  'outputDir'
];
const SUPPORTED_TARGET_PROFILE = 'existing_kubernetes/kit_installed/online';
const PACK_REPORT_SCHEMA = 'agentsmith.substrate-pack-check-report/v1';
const PACK_REPORT_SCOPE = 'substrate_pack_check_only';
const REPORT_SCHEMA = 'agentsmith.substrate-routability-report/v1';
const REPORT_SCOPE = 'substrate_routability_probe_only';
const REPORT_FILE = 'substrate-routability-report.json';
const DEFAULT_TIMEOUT_MS = 5000;
const MAX_TIMEOUT_MS = 60000;
const NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const FORBIDDEN_REPORT_TEXT_RE =
  /(?:required_product_flows|product_flows|product_flow_results|deploy_readiness|release_verdict|\bverdict\b|\bkubeconfig\b)/i;
const SECRET_VALUE_RE = [
  /sk-[A-Za-z0-9]{12,}/,
  /AKIA[0-9A-Z]{16}/,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /\bAIza[0-9A-Za-z_-]{20,}/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\b(?:password|passwd|pwd|token|secret|client_secret)\s*[:=]\s*["']?[^"'\s]{8,}/i,
  /\bexecution[_ -]?ticket\b/i,
  /\bmanaged_credentials\b/i,
  /\bkubeconfig\b/i
];
const ARG_SECRET_VALUE_RE = SECRET_VALUE_RE.filter(
  (pattern) => pattern.source !== '\\bkubeconfig\\b'
);

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

let parsedArgs;

function usage() {
  return `Usage:
  node scripts/verify-substrate-routability.mjs \\
    --target-profile existing_kubernetes/kit_installed/online \\
    --substrate-pack-check-report <json> \\
    --substrate-truth <json> \\
    --target-prerequisites <json> \\
    --namespace <name> \\
    --kubectl <path-or-command> \\
    --routability-probe <executable> \\
    --output-dir <dir> \\
    [--context <name>] \\
    [--kubeconfig <path>] \\
    [--timeout-ms <ms>]

Probe interface:
  <executable> --kubectl <path-or-command> --namespace <name> \\
    [--context <name>] [--kubeconfig <path>] \\
    --service <id> --endpoint-kind <host|url|endpoint|issuer_url> \\
    --endpoint <value> [--port <port>] \\
    --expected-fingerprint <sha256> --timeout-ms <ms>

The probe must verify routability from the target Kubernetes Pod network and
print exactly the expected sha256 fingerprint on stdout.`;
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

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {
    timeoutMs: String(DEFAULT_TIMEOUT_MS)
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    if (arg.startsWith('--timeout-ms=')) {
      parsed.timeoutMs = arg.slice('--timeout-ms='.length);
      continue;
    }

    switch (arg) {
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--substrate-pack-check-report':
        parsed.substratePackCheckReport = nextValue();
        break;
      case '--substrate-truth':
        parsed.substrateTruth = nextValue();
        break;
      case '--target-prerequisites':
        parsed.targetPrerequisites = nextValue();
        break;
      case '--namespace':
        parsed.namespace = nextValue();
        break;
      case '--kubectl':
        parsed.kubectl = nextValue();
        break;
      case '--context':
        parsed.context = nextValue();
        break;
      case '--kubeconfig':
        parsed.kubeconfig = nextValue();
        break;
      case '--routability-probe':
        parsed.routabilityProbe = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--timeout-ms':
        parsed.timeoutMs = nextValue();
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

function findOutputDirArg(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (value && value.trim() !== '' && !value.startsWith('--')) {
      return value;
    }
  }
  return undefined;
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestText(text) {
  return digestBuffer(Buffer.from(text));
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

function digestObject(value) {
  return digestText(JSON.stringify(stableJson(value)));
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
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
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

function requireBooleanFalse(value, label) {
  if (value !== false) {
    fail(`${label} must be false`);
  }
}

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function assertStringEquals(value, expected, label) {
  const actual = requireString(value, label);
  if (actual !== expected) {
    fail(`${label} must be ${expected}`);
  }
  return actual;
}

function parseTargetProfile(value) {
  const targetProfile = requireString(value, 'target_profile');
  const tuple = targetProfile.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail('target_profile must be <target_cluster>/<substrate_source>/<distribution>');
  }
  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (normalized !== SUPPORTED_TARGET_PROFILE) {
    fail(`--substrate-routability only accepts ${SUPPORTED_TARGET_PROFILE}`);
  }
  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function assertTargetProfileObjectMatches(value, expected, label) {
  const object = requireObject(value, label);
  const declaredValue = requireString(object.value, `${label}.value`);
  const targetCluster = requireString(object.target_cluster, `${label}.target_cluster`);
  const substrateSource = requireString(object.substrate_source, `${label}.substrate_source`);
  const distribution = requireString(object.distribution, `${label}.distribution`);
  const computedValue = `${targetCluster}/${substrateSource}/${distribution}`;

  if (declaredValue !== computedValue) {
    fail(`${label}.value must match target profile axes`);
  }
  if (computedValue !== expected.value) {
    fail(`${label} must match CLI target_profile`);
  }
}

function assertNamespace(namespace) {
  const value = requireString(namespace, 'namespace');
  if (value.length > 63 || !NAMESPACE_RE.test(value)) {
    fail('namespace must be a Kubernetes DNS label');
  }
  return value;
}

function assertTimeoutMs(value) {
  if (!/^[1-9][0-9]*$/.test(String(value))) {
    fail('timeout-ms must be a positive integer');
  }
  const timeoutMs = Number(value);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs > MAX_TIMEOUT_MS) {
    fail(`timeout-ms must be <= ${MAX_TIMEOUT_MS}`);
  }
  return timeoutMs;
}

function assertNoSensitiveArg(value, label) {
  const text = requireString(value, label);
  if (/[\r\n]/.test(text)) {
    fail(`${label} must be a path, command, or name, not inline payload`);
  }
  if (/apiVersion:\s*v1|clusters:\s*|users:\s*|contexts:\s*/i.test(text)) {
    fail(`${label} must not contain kubeconfig payload`);
  }
  if (ARG_SECRET_VALUE_RE.some((pattern) => pattern.test(text))) {
    fail(`${label} contains a secret-looking value`);
  }
  return text;
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);
  args.namespace = assertNamespace(args.namespace);
  args.timeoutMs = assertTimeoutMs(args.timeoutMs);
  args.kubectl = assertNoSensitiveArg(args.kubectl, 'kubectl');
  args.routabilityProbe = assertNoSensitiveArg(args.routabilityProbe, 'routability_probe');
  if (args.context) {
    args.context = assertNoSensitiveArg(args.context, 'context');
  }
  if (args.kubeconfig) {
    args.kubeconfig = assertNoSensitiveArg(args.kubeconfig, 'kubeconfig');
  }
}

async function assertProbeExecutable(probe) {
  let stat;
  try {
    stat = await fs.stat(probe);
    await fs.access(probe, fsConstants.X_OK);
  } catch {
    fail('routability_probe must be an executable file');
  }
  if (!stat.isFile()) {
    fail('routability_probe must be an executable file');
  }
}

function assertPackReport(packReport, targetProfile, packReportInputDigest, substrateInputDigest) {
  const report = requireObject(packReport, 'substrate_pack_check_report');
  assertStringEquals(
    report.schema,
    PACK_REPORT_SCHEMA,
    'substrate_pack_check_report.schema'
  );
  assertStringEquals(
    report.scope,
    PACK_REPORT_SCOPE,
    'substrate_pack_check_report.scope'
  );
  requireBooleanFalse(report.readiness, 'substrate_pack_check_report.readiness');
  assertStringEquals(report.status, 'pass', 'substrate_pack_check_report.status');
  assertTargetProfileObjectMatches(
    report.target_profile,
    targetProfile,
    'substrate_pack_check_report.target_profile'
  );

  const inputs = requireObject(report.inputs, 'substrate_pack_check_report.inputs');
  const manifestInput = requireObject(
    inputs.substrate_pack_manifest,
    'substrate_pack_check_report.inputs.substrate_pack_manifest'
  );
  const substrateInput = requireObject(
    inputs.substrate_truth,
    'substrate_pack_check_report.inputs.substrate_truth'
  );
  const manifestInputDigest = requireDigest(
    manifestInput.input_sha256,
    'substrate_pack_check_report.inputs.substrate_pack_manifest.input_sha256'
  );
  assertStringEquals(
    substrateInput.schema_version,
    SUBSTRATE_CONNECTION_SCHEMA,
    'substrate_pack_check_report.inputs.substrate_truth.schema_version'
  );
  const boundSubstrateDigest = requireDigest(
    substrateInput.input_sha256,
    'substrate_pack_check_report.inputs.substrate_truth.input_sha256'
  );
  if (boundSubstrateDigest !== substrateInputDigest) {
    fail('substrate_pack_check_report substrate truth digest must match --substrate-truth');
  }

  const serialized = JSON.stringify(report);
  if (FORBIDDEN_REPORT_TEXT_RE.test(serialized)) {
    fail('substrate_pack_check_report contains out-of-scope verdict, product-flow, deploy readiness, or kubeconfig text');
  }

  return {
    input_sha256: packReportInputDigest,
    schema: PACK_REPORT_SCHEMA,
    scope: PACK_REPORT_SCOPE,
    substrate_pack_manifest_input_sha256: manifestInputDigest,
    substrate_truth_input_sha256: boundSubstrateDigest
  };
}

function assertPort(value, label) {
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    fail(`${label} must be a TCP port number`);
  }
  return value;
}

function endpointTarget(serviceName, endpointKind, endpoint, port) {
  const target = {
    service: serviceName,
    endpoint_kind: endpointKind,
    endpoint: requireString(endpoint, `substrate_truth.services.${serviceName}.${endpointKind}`)
  };
  if (port !== undefined) {
    target.port = assertPort(port, `substrate_truth.services.${serviceName}.port`);
  }
  target.endpoint_fingerprint = digestObject({
    endpoint: target.endpoint,
    endpoint_kind: target.endpoint_kind,
    port: target.port,
    service: target.service
  });
  return target;
}

function substrateEndpointTargets(substrateTruth) {
  const services = requireObject(substrateTruth.services, 'substrate_truth.services');
  const objectStorage = requireObject(
    services.object_storage,
    'substrate_truth.services.object_storage'
  );
  const objectStorageEndpointKind =
    typeof objectStorage.url === 'string' ? 'url' : 'endpoint';

  return [
    endpointTarget(
      'postgresql',
      'host',
      requireObject(services.postgresql, 'substrate_truth.services.postgresql').host,
      services.postgresql.port
    ),
    endpointTarget(
      'mongodb',
      'host',
      requireObject(services.mongodb, 'substrate_truth.services.mongodb').host,
      services.mongodb.port
    ),
    endpointTarget(
      'redis',
      'host',
      requireObject(services.redis, 'substrate_truth.services.redis').host,
      services.redis.port
    ),
    endpointTarget(
      'object_storage',
      objectStorageEndpointKind,
      objectStorage[objectStorageEndpointKind]
    ),
    endpointTarget(
      'oidc',
      'issuer_url',
      requireObject(services.oidc, 'substrate_truth.services.oidc').issuer_url
    )
  ];
}

function kubectlPrefixArgs(args) {
  const prefix = [];
  if (args.kubeconfig) {
    prefix.push('--kubeconfig', args.kubeconfig);
  }
  if (args.context) {
    prefix.push('--context', args.context);
  }
  return prefix;
}

function normalizeKubectlVersion(stdout) {
  const trimmed = stdout.trim();
  const outputSha256 = digestText(trimmed);
  if (trimmed === '') {
    return {
      output_sha256: outputSha256,
      parsed: false
    };
  }

  try {
    JSON.parse(trimmed);
    return {
      output_sha256: outputSha256,
      parsed: true
    };
  } catch {
    return {
      output_sha256: outputSha256,
      parsed: false
    };
  }
}

function runKubectlVersion(args) {
  const result = spawnSync(
    args.kubectl,
    [...kubectlPrefixArgs(args), 'version', '--output=json'],
    {
      encoding: 'utf8',
      maxBuffer: 512 * 1024,
      timeout: args.timeoutMs
    }
  );

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      fail('kubectl version timed out');
    }
    fail(`kubectl version failed to start: ${result.error.message}`);
  }
  if (result.signal) {
    fail('kubectl version was interrupted');
  }
  if (result.status !== 0) {
    fail('kubectl version returned non-zero status');
  }
  return normalizeKubectlVersion(result.stdout || '');
}

function probeArgs(args, target) {
  const commandArgs = [
    '--kubectl',
    args.kubectl,
    '--namespace',
    args.namespace
  ];
  if (args.context) {
    commandArgs.push('--context', args.context);
  }
  if (args.kubeconfig) {
    commandArgs.push('--kubeconfig', args.kubeconfig);
  }
  commandArgs.push(
    '--service',
    target.service,
    '--endpoint-kind',
    target.endpoint_kind,
    '--endpoint',
    target.endpoint
  );
  if (target.port !== undefined) {
    commandArgs.push('--port', String(target.port));
  }
  commandArgs.push(
    '--expected-fingerprint',
    target.endpoint_fingerprint,
    '--timeout-ms',
    String(args.timeoutMs)
  );
  return commandArgs;
}

function runRoutabilityProbe(args, target) {
  const result = spawnSync(args.routabilityProbe, probeArgs(args, target), {
    encoding: 'utf8',
    maxBuffer: 64 * 1024,
    timeout: args.timeoutMs
  });

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      fail(`routability probe timed out for service ${target.service}`);
    }
    fail(`routability probe could not be executed for service ${target.service}`);
  }
  if (result.signal) {
    fail(`routability probe was interrupted for service ${target.service}`);
  }
  if (result.status !== 0) {
    fail(`routability probe returned non-zero status for service ${target.service}`);
  }

  const stdout = typeof result.stdout === 'string' ? result.stdout : '';
  if (!/^\s*sha256:[0-9a-f]{64}\s*$/.test(stdout)) {
    fail(`routability probe stdout for service ${target.service} must be exactly one sha256 fingerprint`);
  }
  const probeDigest = stdout.trim();
  if (probeDigest !== target.endpoint_fingerprint) {
    fail(`routability probe fingerprint mismatch for service ${target.service}`);
  }

  return {
    service: target.service,
    endpoint_kind: target.endpoint_kind,
    endpoint_fingerprint: target.endpoint_fingerprint,
    probe_fingerprint: probeDigest,
    status: 'pass'
  };
}

function buildReport({
  args,
  packReportSummary,
  substrateInputDigest,
  prerequisitesInputDigest,
  prerequisitesSummary,
  kubectlVersion,
  results
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    target_profile: args.targetProfile,
    namespace: args.namespace,
    inputs: {
      substrate_pack_check_report: packReportSummary,
      substrate_truth: {
        schema_version: SUBSTRATE_CONNECTION_SCHEMA,
        input_sha256: substrateInputDigest
      },
      target_prerequisites: {
        schema_version: TARGET_PREREQUISITES_SCHEMA,
        input_sha256: prerequisitesInputDigest,
        namespace: prerequisitesSummary.namespace
      }
    },
    kubectl_version: kubectlVersion,
    probe: {
      mode: 'operator_pod_network_probe',
      services_count: results.length,
      timeout_ms: args.timeoutMs
    },
    results,
    generated_at: new Date().toISOString()
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, REPORT_FILE);
  const tempFile = path.join(outputDir, `.substrate-routability-report.${process.pid}.tmp`);
  assertNoUnsafeReportPayload(report);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

function assertNoUnsafeReportPayload(report) {
  const serialized = JSON.stringify(report);
  if (FORBIDDEN_REPORT_TEXT_RE.test(serialized)) {
    fail('substrate_routability_report contains out-of-scope verdict, product-flow, deploy readiness, or kubeconfig text');
  }
  if (SECRET_VALUE_RE.some((pattern) => pattern.test(serialized))) {
    fail('substrate_routability_report contains a secret-looking value');
  }
  assertNoUnsafeSubstratePayload(
    report,
    'substrate_routability_report',
    serialized
  );
}

async function main() {
  const argv = process.argv.slice(2);
  const startupOutputDir = findOutputDirArg(argv);
  if (startupOutputDir) {
    await removeStaleReport(startupOutputDir);
  }

  parsedArgs = parseArgs(argv);
  if (parsedArgs.help) {
    console.log(usage());
    return;
  }
  if (!startupOutputDir) {
    await removeStaleReport(parsedArgs.outputDir);
  }

  validateArgs(parsedArgs);
  await assertProbeExecutable(parsedArgs.routabilityProbe);

  const substrateInput = await readJson(parsedArgs.substrateTruth, 'substrate truth');
  const prerequisitesInput = await readJson(
    parsedArgs.targetPrerequisites,
    'target prerequisites'
  );
  const packReportInput = await readJson(
    parsedArgs.substratePackCheckReport,
    'substrate pack check report'
  );

  assertNoUnsafeSubstratePayload(
    substrateInput.value,
    'substrate_truth',
    substrateInput.raw
  );
  assertNoUnsafeSubstratePayload(
    prerequisitesInput.value,
    'target_prerequisites',
    prerequisitesInput.raw
  );
  assertNoUnsafeSubstratePayload(
    packReportInput.value,
    'substrate_pack_check_report',
    packReportInput.raw
  );

  const { truth } = validateSubstrateConnectionTruth(
    substrateInput.value,
    parsedArgs.targetProfile,
    {
      label: 'substrate_truth',
      requiredSubstrateSource: 'kit_installed'
    }
  );
  const { prerequisitesSummary } = validateTargetPrerequisitesTruth(
    prerequisitesInput.value,
    parsedArgs.targetProfile,
    substrateInput.value,
    {
      label: 'target_prerequisites',
      expectedNamespace: parsedArgs.namespace
    }
  );
  const packReportSummary = assertPackReport(
    packReportInput.value,
    parsedArgs.targetProfile,
    packReportInput.inputDigest,
    substrateInput.inputDigest
  );

  const endpointTargets = substrateEndpointTargets(truth);
  const kubectlVersion = runKubectlVersion(parsedArgs);
  const results = endpointTargets.map((target) => runRoutabilityProbe(parsedArgs, target));

  await writeReport(
    parsedArgs.outputDir,
    buildReport({
      args: parsedArgs,
      packReportSummary,
      substrateInputDigest: substrateInput.inputDigest,
      prerequisitesInputDigest: prerequisitesInput.inputDigest,
      prerequisitesSummary,
      kubectlVersion,
      results
    })
  );

  console.log('PASS: substrate routability accepted kit-installed online probe results');
}

main().catch(async (error) => {
  if (parsedArgs?.outputDir) {
    await removeStaleReport(parsedArgs.outputDir).catch(() => {});
  } else {
    const startupOutputDir = findOutputDirArg(process.argv.slice(2));
    if (startupOutputDir) {
      await removeStaleReport(startupOutputDir).catch(() => {});
    }
  }
  const exitCode = error.exitCode || 1;
  const prefix = exitCode === 2 ? 'error' : 'FAIL';
  console.error(`${prefix}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
});
