#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { statSync } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERIFY_RELEASE = path.join(ROOT_DIR, 'scripts', 'verify-release.sh');
const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'archive',
  'targetProfile',
  'renderValues',
  'substrateTruth',
  'namespace',
  'outputDir'
];
const SUPPORTED_TARGET_PROFILE = 'existing_kubernetes/external_declared/online';
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const REPORT_SCHEMA = 'agentsmith.online-deployment-gate/v1';
const REPORT_SCOPE = 'online_deployment_gate_only';
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const MANAGED_OUTPUT_ENTRIES = [
  'online-deployment-gate-report.json',
  'inputs',
  'target-preflight',
  'template-package',
  'render',
  'render-check',
  'apply',
  'rollout',
  'smoke'
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

class StepError extends Error {
  constructor(step, status, message) {
    super(message || `online focused chain step failed: ${step}`);
    this.exitCode = status || 1;
  }
}

function usage() {
  return `Usage:
  node scripts/verify-online-deployment-gate.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --archive <tgz> \\
    --target-profile existing_kubernetes/external_declared/online \\
    --render-values <json> \\
    --substrate-truth <json> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--mode server-dry-run|apply] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
    [--confirm-apply existing_kubernetes/external_declared/online] \\
    [--operator-run-id <id>] \\
    [--timeout <duration>] \\
    [--smoke-url <https-url>] \\
    [--expected-status <code>] \\
    [--timeout-ms <ms>] \\
    [--allow-http] \\
    [--allow-localhost] \\
    [--forbidden-source-root <dir>]`;
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
    mode: 'server-dry-run',
    kubectl: 'kubectl',
    forbiddenSourceRoots: [],
    allowHttp: false,
    allowLocalhost: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    if (arg.startsWith('--mode=')) {
      parsed.mode = arg.slice('--mode='.length);
      continue;
    }
    if (arg.startsWith('--confirm-apply=')) {
      parsed.confirmApply = arg.slice('--confirm-apply='.length);
      continue;
    }
    if (arg.startsWith('--timeout=')) {
      parsed.timeout = arg.slice('--timeout='.length);
      continue;
    }

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--deploy-template-package':
        parsed.deployTemplatePackage = nextValue();
        break;
      case '--archive':
        parsed.archive = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--render-values':
        parsed.renderValues = nextValue();
        break;
      case '--substrate-truth':
        parsed.substrateTruth = nextValue();
        break;
      case '--namespace':
        parsed.namespace = nextValue();
        break;
      case '--output-dir':
        parsed.outputDir = nextValue();
        break;
      case '--mode':
        parsed.mode = nextValue();
        break;
      case '--kubeconfig':
        parsed.kubeconfig = nextValue();
        break;
      case '--context':
        parsed.context = nextValue();
        break;
      case '--kubectl':
        parsed.kubectl = nextValue();
        break;
      case '--confirm-apply':
        parsed.confirmApply = nextValue();
        break;
      case '--operator-run-id':
        parsed.operatorRunId = nextValue();
        break;
      case '--timeout':
        parsed.timeout = nextValue();
        break;
      case '--smoke-url':
        parsed.smokeUrl = nextValue();
        break;
      case '--expected-status':
        parsed.expectedStatus = nextValue();
        break;
      case '--timeout-ms':
        parsed.timeoutMs = nextValue();
        break;
      case '--allow-http':
        parsed.allowHttp = true;
        break;
      case '--allow-localhost':
        parsed.allowLocalhost = true;
        break;
      case '--forbidden-source-root':
        parsed.forbiddenSourceRoots.push(nextValue());
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
  if (normalized !== SUPPORTED_TARGET_PROFILE) {
    fail(`--online-deployment-gate only accepts ${SUPPORTED_TARGET_PROFILE}`);
  }
  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateOperatorRunId(operatorRunId) {
  if (typeof operatorRunId !== 'string' || !OPERATOR_RUN_ID_RE.test(operatorRunId)) {
    fail('operator_run_id must be a non-empty run identifier without whitespace');
  }
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);

  if (!SUPPORTED_MODES.has(args.mode)) {
    cliFail('--mode must be server-dry-run or apply');
  }

  const hasSmokeOption =
    args.smokeUrl ||
    args.expectedStatus !== undefined ||
    args.timeoutMs !== undefined ||
    args.allowHttp ||
    args.allowLocalhost;
  if (args.mode === 'server-dry-run' && args.smokeUrl) {
    fail('--smoke-url requires --mode apply');
  }
  if (!args.smokeUrl && hasSmokeOption) {
    fail('smoke options require --smoke-url');
  }

  if (args.mode === 'apply') {
    if (args.confirmApply !== SUPPORTED_TARGET_PROFILE) {
      cliFail(`--mode apply requires --confirm-apply ${SUPPORTED_TARGET_PROFILE}`);
    }
    if (!args.operatorRunId) {
      cliFail('--mode apply requires --operator-run-id <id>');
    }
    validateOperatorRunId(args.operatorRunId);
  } else {
    if (args.confirmApply) {
      cliFail('--confirm-apply is only accepted with --mode apply');
    }
    if (args.operatorRunId) {
      cliFail('--operator-run-id is only accepted with --mode apply');
    }
    if (args.timeout) {
      cliFail('--timeout is only accepted with --mode apply');
    }
  }

  return args;
}

async function removeManagedOutputs(outputDir) {
  await Promise.all(
    MANAGED_OUTPUT_ENTRIES.map((entry) =>
      fs.rm(path.join(outputDir, entry), { recursive: true, force: true })
    )
  );
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function readReleaseIdentity(file) {
  const raw = await fs.readFile(file);
  const contract = JSON.parse(raw.toString('utf8'));
  return {
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    input_sha256: digestBuffer(raw)
  };
}

function outputSubdir(args, name) {
  return path.join(args.outputDir, name);
}

function renderedManifestsDir(args) {
  return path.join(outputSubdir(args, 'render'), 'rendered-manifests');
}

function rolloutReportPath(args) {
  return path.join(outputSubdir(args, 'rollout'), 'rollout-report.json');
}

function relativeOutputPath(outputDir, file) {
  return path.relative(outputDir, file).split(path.sep).join('/');
}

function pushIfValue(argv, flag, value) {
  if (value !== undefined) {
    argv.push(flag, value);
  }
}

function appendForbiddenRoots(argv, args) {
  for (const root of args.forbiddenSourceRoots) {
    argv.push('--forbidden-source-root', root);
  }
}

function runVerify(step, mode, argv) {
  const result = spawnSync('bash', [VERIFY_RELEASE, mode, ...argv], {
    cwd: ROOT_DIR,
    stdio: 'inherit',
    env: process.env
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new StepError(step, result.status);
  }
}

function runStep({ args, steps, name, mode, argv, reportPaths }) {
  runVerify(name, mode, argv);
  for (const reportPath of reportPaths) {
    let stat;
    try {
      stat = statSync(reportPath);
    } catch {
      throw new StepError(name, 1, `online focused chain step report missing: ${name}`);
    }
    if (!stat.isFile()) {
      throw new StepError(name, 1, `online focused chain step report is not a file: ${name}`);
    }
  }
  steps.push({
    name,
    status: 'pass',
    report_paths: reportPaths.map((reportPath) => relativeOutputPath(args.outputDir, reportPath))
  });
}

function kubeArgs(args) {
  const argv = [];
  pushIfValue(argv, '--kubeconfig', args.kubeconfig);
  pushIfValue(argv, '--context', args.context);
  pushIfValue(argv, '--kubectl', args.kubectl);
  return argv;
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'online-deployment-gate-report.json');
  const tempFile = path.join(outputDir, `.online-deployment-gate.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

function buildReport({ releaseIdentity, args, steps }) {
  return {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    readiness: false,
    status: 'pass',
    mode: args.mode,
    release_id: releaseIdentity.release_id,
    git_sha: releaseIdentity.git_sha,
    release_contract: {
      input_sha256: releaseIdentity.input_sha256
    },
    target_profile: args.targetProfile,
    steps,
    generated_at: new Date().toISOString()
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeManagedOutputs(args.outputDir);
  validateArgs(args);

  const steps = [];
  const targetProfile = args.targetProfile.value;

  runStep({
    args,
    steps,
    name: 'inputs',
    mode: '--inputs',
    argv: [
      '--release-contract',
      args.releaseContract,
      '--deploy-template-package',
      args.deployTemplatePackage,
      '--target-profile',
      targetProfile,
      '--output-dir',
      outputSubdir(args, 'inputs')
    ],
    reportPaths: [path.join(outputSubdir(args, 'inputs'), 'target-profile-coverage-report.json')]
  });

  runStep({
    args,
    steps,
    name: 'target-preflight',
    mode: '--target-preflight',
    argv: [
      '--target-profile',
      targetProfile,
      '--substrate-truth',
      args.substrateTruth,
      '--output-dir',
      outputSubdir(args, 'target-preflight')
    ],
    reportPaths: [
      path.join(outputSubdir(args, 'target-preflight'), 'target-preflight-report.json')
    ]
  });

  runStep({
    args,
    steps,
    name: 'template-package',
    mode: '--template-package',
    argv: [
      '--release-contract',
      args.releaseContract,
      '--deploy-template-package',
      args.deployTemplatePackage,
      '--archive',
      args.archive,
      '--output-dir',
      outputSubdir(args, 'template-package')
    ],
    reportPaths: [
      path.join(outputSubdir(args, 'template-package'), 'template-package-report.json')
    ]
  });

  const renderArgv = [
    '--release-contract',
    args.releaseContract,
    '--deploy-template-package',
    args.deployTemplatePackage,
    '--archive',
    args.archive,
    '--target-profile',
    targetProfile,
    '--render-values',
    args.renderValues,
    '--substrate-truth',
    args.substrateTruth,
    '--output-dir',
    outputSubdir(args, 'render')
  ];
  appendForbiddenRoots(renderArgv, args);
  runStep({
    args,
    steps,
    name: 'render',
    mode: '--render',
    argv: renderArgv,
    reportPaths: [path.join(outputSubdir(args, 'render'), 'manifest-render-report.json')]
  });

  const renderCheckArgv = [
    '--release-contract',
    args.releaseContract,
    '--rendered-manifests',
    renderedManifestsDir(args),
    '--target-profile',
    targetProfile,
    '--output-dir',
    outputSubdir(args, 'render-check')
  ];
  appendForbiddenRoots(renderCheckArgv, args);
  runStep({
    args,
    steps,
    name: 'render-check',
    mode: '--render-check',
    argv: renderCheckArgv,
    reportPaths: [path.join(outputSubdir(args, 'render-check'), 'render-report.json')]
  });

  const applyArgv = [
    '--release-contract',
    args.releaseContract,
    '--rendered-manifests',
    renderedManifestsDir(args),
    '--target-profile',
    targetProfile,
    '--namespace',
    args.namespace,
    '--output-dir',
    outputSubdir(args, 'apply'),
    '--mode',
    args.mode,
    ...kubeArgs(args)
  ];
  if (args.mode === 'apply') {
    applyArgv.push(
      '--confirm-apply',
      SUPPORTED_TARGET_PROFILE,
      '--operator-run-id',
      args.operatorRunId
    );
  }
  appendForbiddenRoots(applyArgv, args);
  runStep({
    args,
    steps,
    name: 'apply',
    mode: '--apply',
    argv: applyArgv,
    reportPaths: [path.join(outputSubdir(args, 'apply'), 'apply-report.json')]
  });

  if (args.mode === 'apply') {
    const rolloutArgv = [
      '--release-contract',
      args.releaseContract,
      '--rendered-manifests',
      renderedManifestsDir(args),
      '--target-profile',
      targetProfile,
      '--namespace',
      args.namespace,
      '--output-dir',
      outputSubdir(args, 'rollout'),
      ...kubeArgs(args)
    ];
    pushIfValue(rolloutArgv, '--timeout', args.timeout);
    appendForbiddenRoots(rolloutArgv, args);
    runStep({
      args,
      steps,
      name: 'rollout',
      mode: '--rollout',
      argv: rolloutArgv,
      reportPaths: [rolloutReportPath(args)]
    });

    if (args.smokeUrl) {
      const smokeArgv = [
        '--release-contract',
        args.releaseContract,
        '--rollout-report',
        rolloutReportPath(args),
        '--target-profile',
        targetProfile,
        '--url',
        args.smokeUrl,
        '--output-dir',
        outputSubdir(args, 'smoke')
      ];
      pushIfValue(smokeArgv, '--expected-status', args.expectedStatus);
      pushIfValue(smokeArgv, '--timeout-ms', args.timeoutMs);
      if (args.allowHttp) {
        smokeArgv.push('--allow-http');
      }
      if (args.allowLocalhost) {
        smokeArgv.push('--allow-localhost');
      }
      runStep({
        args,
        steps,
        name: 'smoke',
        mode: '--smoke',
        argv: smokeArgv,
        reportPaths: [path.join(outputSubdir(args, 'smoke'), 'smoke-report.json')]
      });
    }
  }

  const releaseIdentity = await readReleaseIdentity(args.releaseContract);
  await writeReport(
    args.outputDir,
    buildReport({
      releaseIdentity,
      args,
      steps
    })
  );

  console.log('PASS: online focused chain completed focused diagnostics');
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
