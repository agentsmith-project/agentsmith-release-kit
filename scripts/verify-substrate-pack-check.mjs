#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  SUBSTRATE_CONNECTION_SCHEMA,
  assertNoUnsafeSubstratePayload,
  validateSubstrateConnectionTruth
} from './lib/substrate-truth-validation.mjs';
import {
  SUBSTRATE_PACK_MANIFEST_SCHEMA,
  validateSubstratePackManifest
} from './lib/substrate-pack-manifest-validation.mjs';

const REQUIRED_ARGS = [
  'targetProfile',
  'substratePackManifest',
  'substrateTruth',
  'outputDir'
];
const REPORT_SCHEMA = 'agentsmith.substrate-pack-check-report/v1';
const REPORT_SCOPE = 'substrate_pack_check_only';
const REPORT_FILE = 'substrate-pack-check-report.json';
const SUPPORTED_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
];
const SUPPORTED_TARGET_PROFILE_SET = new Set(SUPPORTED_TARGET_PROFILE_VALUES);

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
  node scripts/verify-substrate-pack-check.mjs \\
    --target-profile existing_kubernetes/kit_installed/<online|airgap> \\
    --substrate-pack-manifest <json> \\
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

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    switch (arg) {
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--substrate-pack-manifest':
        parsed.substratePackManifest = nextValue();
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

async function removeStaleReport(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function parseTargetProfile(value) {
  const text = requireString(value, 'target_profile');
  if (!SUPPORTED_TARGET_PROFILE_SET.has(text)) {
    fail(`--substrate-pack-check only accepts ${SUPPORTED_TARGET_PROFILE_VALUES.join(' or ')}`);
  }
  const [targetCluster, substrateSource, distribution] = text.split('/');
  return {
    value: text,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function buildReport({
  targetProfile,
  manifestInputDigest,
  substrateInputDigest,
  manifestSummary,
  serviceSummary
}) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    target_profile: targetProfile,
    inputs: {
      substrate_pack_manifest: {
        schema_version: SUBSTRATE_PACK_MANIFEST_SCHEMA,
        input_sha256: manifestInputDigest
      },
      substrate_truth: {
        schema_version: SUBSTRATE_CONNECTION_SCHEMA,
        input_sha256: substrateInputDigest
      }
    },
    summary: {
      installed_by: manifestSummary.installed_by,
      release_kit_version: manifestSummary.release_kit_version,
      required_images_count: manifestSummary.required_images.length,
      image_count: manifestSummary.image_count,
      material_sections: manifestSummary.material_sections,
      substrate_services_count: serviceSummary.services_count,
      substrate_services: serviceSummary.services
    }
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(path.join(outputDir, REPORT_FILE), `${JSON.stringify(report, null, 2)}\n`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(args.outputDir);
  const targetProfile = parseTargetProfile(args.targetProfile);
  const manifestInput = await readJson(args.substratePackManifest, 'substrate pack manifest');
  const substrateInput = await readJson(args.substrateTruth, 'substrate truth');

  const { manifestSummary } = validateSubstratePackManifest(
    manifestInput.value,
    targetProfile,
    { fail }
  );
  assertNoUnsafeSubstratePayload(
    substrateInput.value,
    'substrate_truth',
    substrateInput.raw
  );
  const { serviceSummary } = validateSubstrateConnectionTruth(
    substrateInput.value,
    targetProfile,
    {
      label: 'substrate_truth',
      requiredSubstrateSource: 'kit_installed'
    }
  );

  await writeReport(
    args.outputDir,
    buildReport({
      targetProfile,
      manifestInputDigest: manifestInput.inputDigest,
      substrateInputDigest: substrateInput.inputDigest,
      manifestSummary,
      serviceSummary
    })
  );
  console.log('PASS: substrate pack manifest and truth accepted');
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
