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
skeleton. Doctor mode prints missing refs plus static package blockers only.
None of these outputs is a GA verdict, release readiness report, or runtime
evidence.`;
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

const DOCTOR_BLOCKER_CATEGORIES = [
  {
    label: 'release materials',
    fields: new Set([
      'release_contract',
      'deploy_template_package',
      'deploy_template_archive',
      'airgap_bundle',
      'airgap_bundle_manifest'
    ])
  },
  {
    label: 'operator target facts',
    fields: new Set([
      'render_values',
      'substrate_truth',
      'target_prerequisites',
      'substrate_pack_manifest',
      'substrate_install_inputs',
      'target_registry',
      'namespace',
      'context'
    ])
  },
  {
    label: 'operator tools',
    fields: new Set([
      'kubectl',
      'registry_probe',
      'routability_probe',
      'archive_probe',
      'image_loader'
    ])
  },
  {
    label: 'operator confirmations',
    fields: new Set([
      'deploy_confirmation',
      'install_confirmation'
    ])
  },
  {
    label: 'other package fields',
    fields: new Set()
  }
];

function doctorCategoryForField(field) {
  const rootField = String(field || '').split('.')[0];
  return DOCTOR_BLOCKER_CATEGORIES.find((category) => category.fields.has(rootField)) ??
    DOCTOR_BLOCKER_CATEGORIES[DOCTOR_BLOCKER_CATEGORIES.length - 1];
}

function printDoctorBlockerCategories(report) {
  const grouped = new Map(
    DOCTOR_BLOCKER_CATEGORIES.map((category) => [category.label, new Set()])
  );
  const addField = (field) => {
    if (!field) {
      return;
    }
    grouped.get(doctorCategoryForField(field).label).add(field);
  };

  for (const field of report.missing || []) {
    addField(field);
  }
  for (const ref of report.missing_refs || []) {
    addField(ref.field);
  }
  for (const issue of report.static_issues || []) {
    addField(issue.field);
  }

  const visibleGroups = [...grouped.entries()].filter(([, fields]) => fields.size > 0);
  if (visibleGroups.length === 0) {
    return;
  }

  console.log('Missing or blocking inputs by category:');
  for (const [label, fields] of visibleGroups) {
    console.log(`- ${label}: ${[...fields].join(', ')}`);
  }
  console.log('Raw blockers:');
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
      console.log(`operator-inputs doctor found blockers for ${report.deployment_path}:`);
      printDoctorBlockerCategories(report);
      for (const field of report.missing) {
        console.log(`- ${field}`);
      }
      for (const ref of report.missing_refs) {
        console.log(`- ${ref.field}: ${ref.path ?? '<unset>'} (${ref.reason})`);
      }
      for (const issue of report.static_issues || []) {
        console.log(`- ${issue.field}: ${issue.reason}`);
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
