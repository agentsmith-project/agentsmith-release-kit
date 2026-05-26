#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  SUBSTRATE_CONNECTION_SCHEMA,
  TARGET_PREREQUISITES_SCHEMA,
  assertNoUnsafeSubstratePayload,
  parseTargetProfile,
  validateSubstrateConnectionTruth,
  validateTargetPrerequisitesTruth
} from './lib/substrate-truth-validation.mjs';

const REQUIRED_ARGS = ['targetProfile', 'substrateTruth', 'targetPrerequisites', 'outputDir'];

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
    --target-prerequisites <json> \\
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
      case '--target-prerequisites':
        parsed.targetPrerequisites = nextValue();
        break;
      case '--expected-namespace':
        parsed.expectedNamespace = nextValue();
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

function buildReport({
  targetProfile,
  truthProfile,
  substrateInputDigest,
  prerequisitesInputDigest,
  serviceSummary,
  prerequisitesSummary
}) {
  return {
    scope: 'target_preflight_prerequisite_only',
    readiness: false,
    target_profile: targetProfile,
    substrate_truth: {
      schema_version: SUBSTRATE_CONNECTION_SCHEMA,
      input_sha256: substrateInputDigest,
      target_profile: truthProfile,
      services_count: serviceSummary.services_count,
      services: serviceSummary.services
    },
    target_prerequisites: {
      schema_version: TARGET_PREREQUISITES_SCHEMA,
      input_sha256: prerequisitesInputDigest,
      target_profile: prerequisitesSummary.target_profile,
      namespace: prerequisitesSummary.namespace,
      ingress_host: prerequisitesSummary.ingress_host,
      substrate_secret_refs_count: prerequisitesSummary.substrate_secret_refs_count
    },
    checks: {
      schema: 'pass',
      target_axes: 'pass',
      service_contracts: 'pass',
      target_prerequisites: 'pass',
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
  const targetPrerequisitesInput = await readJson(
    args.targetPrerequisites,
    'target prerequisites'
  );
  assertNoUnsafeSubstratePayload(
    substrateTruthInput.value,
    'substrate_truth',
    substrateTruthInput.raw
  );
  assertNoUnsafeSubstratePayload(
    targetPrerequisitesInput.value,
    'target_prerequisites',
    targetPrerequisitesInput.raw
  );
  const { truthProfile, serviceSummary } = validateSubstrateConnectionTruth(
    substrateTruthInput.value,
    targetProfile,
    { label: 'substrate_truth' }
  );
  const { prerequisitesSummary } = validateTargetPrerequisitesTruth(
    targetPrerequisitesInput.value,
    targetProfile,
    substrateTruthInput.value,
    {
      label: 'target_prerequisites',
      expectedNamespace: args.expectedNamespace
    }
  );

  await writeReport(
    args.outputDir,
    buildReport({
      targetProfile,
      truthProfile,
      substrateInputDigest: substrateTruthInput.inputDigest,
      prerequisitesInputDigest: targetPrerequisitesInput.inputDigest,
      serviceSummary,
      prerequisitesSummary
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
