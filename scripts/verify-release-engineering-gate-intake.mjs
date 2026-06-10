#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const REPORT_FILE = 'release-engineering-gate-intake-report.json';

function replacementGuidance() {
  return `Use the package-driven GA path instead:
  bash scripts/operator-release.sh --operator-inputs <package-or-json> --run
  bash scripts/operator-release.sh --ga-report \\
    --operator-inputs <online-use-existing-pkg> \\
    --operator-inputs <online-install-substrates-pkg> \\
    --operator-inputs <airgap-use-existing-pkg> \\
    --operator-inputs <airgap-install-substrates-pkg> \\
    --product-readiness-report <agentsmith/product-readiness-report.json> \\
    --post-deploy-product-smoke-report <agentsmith/online-post-deploy-product-smoke-report.json> \\
    --post-deploy-product-smoke-report <agentsmith/airgap-post-deploy-product-smoke-report.json> \\
    --output-dir <dir>`;
}

function usage() {
  return `Usage:
  node scripts/verify-release-engineering-gate-intake.mjs --help

Retired compatibility guard:
  --release-engineering-gate-intake is retired and ordinary invocation fails fast.
  It no longer consumes online or airgap adoption reports and does not write
  ${REPORT_FILE}. It is not a GA input, release verdict, deployment verdict,
  package verdict, operator verdict, or report producer.

${replacementGuidance()}`;
}

function isHelp(argv) {
  return argv.includes('--help') || argv.includes('-h');
}

function extractOutputDir(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--output-dir') {
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.trim() === '' || value.startsWith('--')) {
      return { outputDir: undefined, error: 'missing value for --output-dir' };
    }
    return { outputDir: value, error: undefined };
  }
  return { outputDir: undefined, error: undefined };
}

function removeManagedReport(outputDir) {
  if (!outputDir) {
    return;
  }
  fs.rmSync(path.join(path.resolve(outputDir), REPORT_FILE), { force: true });
}

const argv = process.argv.slice(2);

if (isHelp(argv)) {
  console.log(usage());
  process.exit(0);
}

const outputDirResult = extractOutputDir(argv);
removeManagedReport(outputDirResult.outputDir);

console.error('error: --release-engineering-gate-intake is retired; this compatibility guard does not produce a report.');
if (outputDirResult.error) {
  console.error(`error: ${outputDirResult.error}`);
}
console.error(`error: ${REPORT_FILE} is no longer written by this command.`);
console.error(replacementGuidance());
process.exit(2);
