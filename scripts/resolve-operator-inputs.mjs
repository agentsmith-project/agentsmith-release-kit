#!/usr/bin/env node
import { resolveOperatorInputs } from './lib/operator-inputs-resolver.mjs';

function usage() {
  return `Usage:
  node scripts/resolve-operator-inputs.mjs --operator-inputs <dir-or-json> [--output-dir <dir>] [--stdout]

This is an internal/test helper for operator-inputs intake. It writes
.release-kit-internal/operator-inputs-plan.json by default. The plan is not a
GA verdict, release readiness report, or runtime evidence.`;
}

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    throw new Error(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {
    stdout: false
  };

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
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--stdout':
        parsed.stdout = true;
        break;
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (!parsed.help && !parsed.inputPath) {
    throw new Error('--operator-inputs is required');
  }
  return parsed;
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    process.exit(0);
  }
  const { plan, planPath } = await resolveOperatorInputs({
    inputPath: args.inputPath,
    outputDir: args.outputDir
  });
  if (args.stdout) {
    console.log(JSON.stringify(plan, null, 2));
  } else {
    console.log(`operator-inputs plan written: ${planPath}`);
    console.log('operator-inputs intake only; no GA verdict or release readiness was issued.');
  }
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  console.error(usage());
  process.exit(error.exitCode || 2);
}
