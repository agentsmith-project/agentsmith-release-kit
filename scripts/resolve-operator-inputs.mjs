#!/usr/bin/env node
import {
  diagnoseOperatorInputs,
  initOperatorInputs,
  resolveOperatorInputs
} from './lib/operator-inputs-resolver.mjs';

function usage() {
  return `Usage:
  node scripts/resolve-operator-inputs.mjs --operator-inputs <dir-or-json> [--output-dir <internal-dir>] [--stdout]
  node scripts/resolve-operator-inputs.mjs --operator-inputs <dir-or-json> --doctor [--stdout]
  node scripts/resolve-operator-inputs.mjs --init <deployment_path> --output-dir <package-dir> [--stdout]

This is an internal/test helper for operator-inputs intake. It writes
.release-kit-internal/operator-inputs-plan.json by default. Alternate output
dirs must stay inside .release-kit-internal. Init mode writes a package
skeleton. Doctor mode prints a missing input diagnostic only. None of these
outputs is a GA verdict, release readiness report, or runtime evidence.`;
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
    doctor: false,
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
      case '--init':
        parsed.initDeploymentPath = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--doctor':
        parsed.doctor = true;
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

  if (parsed.initDeploymentPath && parsed.inputPath) {
    throw new Error('--init cannot be combined with --operator-inputs');
  }
  if (!parsed.help && !parsed.inputPath && !parsed.initDeploymentPath) {
    throw new Error('--operator-inputs or --init is required');
  }
  if (parsed.doctor && parsed.outputDir) {
    throw new Error('--output-dir is not accepted with --doctor');
  }
  if (parsed.initDeploymentPath && !parsed.outputDir) {
    throw new Error('--output-dir is required with --init');
  }
  if (parsed.initDeploymentPath && parsed.doctor) {
    throw new Error('--doctor cannot be combined with --init');
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
  if (args.initDeploymentPath) {
    const report = await initOperatorInputs({
      deploymentPath: args.initDeploymentPath,
      outputDir: args.outputDir
    });
    if (args.stdout) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(`operator-inputs package initialized: ${report.manifest_path}`);
      console.log(`operator-inputs package README: ${report.readme_path}`);
      console.log(report.next_action);
      console.log('operator-inputs init only; no GA verdict or release readiness was issued.');
    }
    process.exit(0);
  }
  if (args.doctor) {
    const report = await diagnoseOperatorInputs({ inputPath: args.inputPath });
    if (args.stdout) {
      console.log(JSON.stringify(report, null, 2));
    } else if (report.status === 'pass') {
      console.log(`operator-inputs doctor passed for ${report.deployment_path}`);
      console.log(report.next_action);
    } else {
      console.log(`operator-inputs doctor found missing inputs for ${report.deployment_path}:`);
      for (const field of report.missing) {
        console.log(`- ${field}`);
      }
      for (const ref of report.missing_refs) {
        console.log(`- ${ref.field}: ${ref.path ?? '<unset>'} (${ref.reason})`);
      }
      console.log(report.next_action);
    }
    process.exit(report.status === 'pass' ? 0 : 1);
  }
  const { plan, planPath } = await resolveOperatorInputs({
    inputPath: args.inputPath,
    outputDir: args.outputDir
  });
  if (args.stdout) {
    console.log(JSON.stringify(plan, null, 2));
  } else {
    console.log(`operator-inputs plan written: ${planPath}`);
    printInstallParametersSha256(plan);
    console.log('operator-inputs intake only; no GA verdict or release readiness was issued.');
  }
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  console.error(usage());
  process.exit(error.exitCode || 2);
}
