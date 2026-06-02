#!/usr/bin/env node
import {
  cleanupStaleOperatorInputsPathEvidence,
  resolveOperatorInputs
} from './lib/operator-inputs-resolver.mjs';
import { runOperatorInputsPlan } from './lib/operator-inputs-runner.mjs';

function usage() {
  return `Usage:
  node scripts/run-operator-inputs.mjs --operator-inputs <dir-or-json>

Runs the current minimal operator-inputs orchestration slice. Only
online/use_existing, online/install_substrates, airgap/use_existing, and
airgap/install_substrates with mode apply are executed; server-dry-run modes
fail fast. This writes path-level deployment evidence only, not
ga-release-report.json.`;
}

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    throw new Error(`missing value for ${arg}`);
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
      case '--operator-inputs':
        parsed.inputPath = nextValue();
        break;
      case '--plan':
        throw new Error('--plan is not accepted; use --operator-inputs to generate and run a fresh plan');
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (parsed.help) {
    return parsed;
  }
  if (!parsed.inputPath) {
    throw new Error('--operator-inputs is required');
  }
  return parsed;
}

function printInstallParametersSha256(plan) {
  const installParametersSha256 =
    plan._internal?.expected?.install?.install_parameters_sha256;
  if (installParametersSha256) {
    console.log(`operator-inputs install_parameters_sha256: ${installParametersSha256}`);
  }
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    process.exit(0);
  }

  await cleanupStaleOperatorInputsPathEvidence({ inputPath: args.inputPath });
  const resolved = await resolveOperatorInputs({ inputPath: args.inputPath });
  const planPath = resolved.planPath;
  console.log(`operator-inputs plan written: ${planPath}`);
  printInstallParametersSha256(resolved.plan);

  const result = await runOperatorInputsPlan({ planPath });
  if (result.substrateInstallReportPath) {
    console.log(`operator-inputs substrate install report: ${result.substrateInstallReportPath}`);
  }
  console.log(`operator-inputs producer report: ${result.producerReportPath}`);
  console.log(`operator-inputs deployment-path report: ${result.deploymentPathReport}`);
  console.log('operator-inputs run wrote path-level evidence only; no GA verdict was issued.');
} catch (error) {
  const exitCode = error.exitCode || 2;
  const prefix = exitCode === 2 ? 'error' : 'FAIL';
  console.error(`${prefix}: ${error.message}`);
  if (exitCode === 2) {
    console.error(usage());
  }
  process.exit(exitCode);
}
