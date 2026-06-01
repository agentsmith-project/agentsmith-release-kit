import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import { validateSubstrateInstallReport } from './deployment-path-source-validation.mjs';

const INTERNAL_DIR = '.release-kit-internal';
const AIRGAP_INSTALL_OUTPUT_ROOT = 'airgap-install-substrates';
const INSTALL_OUTPUT_DIR = 'substrate-install';
const INSTALL_REPORT_FILE = 'substrate-install-report.json';
const INSTALL_TRUTH_FILE = 'substrate-truth.json';
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const WINDOWS_DRIVE_RE = /^[A-Za-z]:/;
const URI_SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i;
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_SCHEMA = 'agentsmith.deploy-template-package/v1';

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function requireString(value, label, fail) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function requireObject(value, label, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireDigest(value, label, fail) {
  const digest = requireString(value, label, fail);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function requireSchema(value, expected, label, fail) {
  const schema = value.schema ?? value.schema_version;
  if (schema !== expected) {
    fail(`${label}.schema must be ${expected}`);
  }
}

function rejectUriOrWindowsPath(value, label, fail) {
  const text = requireString(value, label, fail);
  if (text.trim() !== text) {
    fail(`${label} must not have leading or trailing whitespace`);
  }
  if (text.startsWith('//') || WINDOWS_DRIVE_RE.test(text) || text.includes('\\')) {
    fail(`${label} must be a local POSIX path`);
  }
  if (URI_SCHEME_RE.test(text)) {
    fail(`${label} must be a local POSIX path, not a URI`);
  }
  if (text.split('/').includes('..')) {
    fail(`${label} must not contain parent path segments`);
  }
  return text;
}

async function canonicalLocalFile(input, label, fail) {
  const value = rejectUriOrWindowsPath(input, label, fail);
  const requested = path.resolve(value);
  let stat;
  try {
    stat = await fs.lstat(requested);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  if (stat.isSymbolicLink()) {
    fail(`${label} must not be a symlink`);
  }
  if (!stat.isFile()) {
    fail(`${label} must point to a file`);
  }
  try {
    return await fs.realpath(requested);
  } catch (error) {
    fail(`cannot resolve ${label}: ${error.message}`);
  }
}

async function readJson(file, label, fail) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      value: JSON.parse(buffer.toString('utf8')),
      digest: digestBuffer(buffer)
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function digestFile(file, label, fail) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return digestBuffer(buffer);
}

function pathSegments(file) {
  return path.resolve(file).split(path.sep).filter(Boolean);
}

function pathFromSegments(segments) {
  return `${path.sep}${segments.join(path.sep)}`;
}

function airgapInstallRootFromPath(file) {
  const segments = pathSegments(file);
  for (let index = 0; index < segments.length; index += 1) {
    if (
      segments[index] === INTERNAL_DIR &&
      segments[index + 1] === AIRGAP_INSTALL_OUTPUT_ROOT
    ) {
      return {
        root: pathFromSegments(segments.slice(0, index + 2)),
        relative: segments.slice(index + 2)
      };
    }
  }
  return undefined;
}

function expectedReportPathFromConsumerOutput(outputDir) {
  if (!outputDir) {
    return undefined;
  }
  const outputRoot = airgapInstallRootFromPath(outputDir);
  if (!outputRoot) {
    return undefined;
  }
  return path.join(outputRoot.root, INSTALL_OUTPUT_DIR, INSTALL_REPORT_FILE);
}

function assertInstallerOutputLayout({
  substrateTruthPath,
  substrateInstallReportPath,
  consumerOutputDir,
  fail
}) {
  if (path.basename(substrateInstallReportPath) !== INSTALL_REPORT_FILE) {
    fail(`--substrate-install-report must be named ${INSTALL_REPORT_FILE}`);
  }
  if (path.basename(substrateTruthPath) !== INSTALL_TRUTH_FILE) {
    fail(`--substrate-truth must be named ${INSTALL_TRUTH_FILE} for installer-generated truth`);
  }
  if (path.basename(path.dirname(substrateInstallReportPath)) !== INSTALL_OUTPUT_DIR) {
    fail(`--substrate-install-report must live under ${INTERNAL_DIR}/.../${INSTALL_OUTPUT_DIR}`);
  }
  if (path.dirname(substrateTruthPath) !== path.dirname(substrateInstallReportPath)) {
    fail('--substrate-truth must be the sibling truth file from --substrate-install-report output');
  }
  const reportRoot = airgapInstallRootFromPath(substrateInstallReportPath);
  if (!reportRoot || reportRoot.relative.join('/') !== `${INSTALL_OUTPUT_DIR}/${INSTALL_REPORT_FILE}`) {
    fail(`--substrate-install-report must live under ${INTERNAL_DIR}/${AIRGAP_INSTALL_OUTPUT_ROOT}/${INSTALL_OUTPUT_DIR}`);
  }
  const expectedReportPath = expectedReportPathFromConsumerOutput(consumerOutputDir);
  if (expectedReportPath && path.resolve(substrateInstallReportPath) !== expectedReportPath) {
    fail(
      `--substrate-install-report must be the current ${INTERNAL_DIR}/${AIRGAP_INSTALL_OUTPUT_ROOT}/${INSTALL_OUTPUT_DIR}/${INSTALL_REPORT_FILE}`
    );
  }
}

function requireOutputTruthPath(report, fail) {
  const outputPath = requireString(
    report.output_substrate_truth_path,
    'substrate_install_report.output_substrate_truth_path',
    fail
  );
  if (
    outputPath !== INSTALL_TRUTH_FILE ||
    path.posix.isAbsolute(outputPath) ||
    path.isAbsolute(outputPath) ||
    WINDOWS_DRIVE_RE.test(outputPath) ||
    outputPath.includes('\\') ||
    URI_SCHEME_RE.test(outputPath) ||
    outputPath.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')
  ) {
    fail(`substrate_install_report.output_substrate_truth_path must be ${INSTALL_TRUTH_FILE}`);
  }
  return outputPath;
}

async function readReleaseBinding({ releaseContractPath, deployTemplatePackagePath, fail }) {
  const releaseContractRealPath = await canonicalLocalFile(
    releaseContractPath,
    'release contract',
    fail
  );
  const deployTemplateRealPath = await canonicalLocalFile(
    deployTemplatePackagePath,
    'deploy template package',
    fail
  );
  const releaseContractInput = await readJson(releaseContractRealPath, 'release contract', fail);
  const deployTemplateInput = await readJson(
    deployTemplateRealPath,
    'deploy template package',
    fail
  );
  const releaseContract = requireObject(releaseContractInput.value, 'release contract', fail);
  const deployTemplate = requireObject(deployTemplateInput.value, 'deploy template package', fail);
  requireSchema(releaseContract, RELEASE_CONTRACT_SCHEMA, 'release contract', fail);
  requireSchema(deployTemplate, DEPLOY_TEMPLATE_SCHEMA, 'deploy template package', fail);

  const releaseId = requireString(releaseContract.release_id, 'release_contract.release_id', fail);
  const gitSha = requireString(releaseContract.git_sha, 'release_contract.git_sha', fail);
  const contractTemplate = requireObject(
    releaseContract.deploy_template_package,
    'release_contract.deploy_template_package',
    fail
  );
  const packageSha = requireDigest(
    deployTemplate.package_sha256,
    'deploy_template_package.package_sha256',
    fail
  );
  if (
    packageSha !==
    requireDigest(
      contractTemplate.package_sha256,
      'release_contract.deploy_template_package.package_sha256',
      fail
    )
  ) {
    fail('deploy template package package_sha256 must match release contract');
  }
  const manifestSha = requireDigest(
    deployTemplate.manifest_sha256,
    'deploy_template_package.manifest_sha256',
    fail
  );
  if (
    manifestSha !==
    requireDigest(
      contractTemplate.manifest_sha256,
      'release_contract.deploy_template_package.manifest_sha256',
      fail
    )
  ) {
    fail('deploy template package manifest_sha256 must match release contract');
  }

  return {
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: releaseContractInput.digest,
    deploy_template_package_digest: deployTemplateInput.digest
  };
}

function validateReportShape(report, release, targetProfile, fail) {
  try {
    return validateSubstrateInstallReport(
      report,
      release,
      targetProfile.value
    );
  } catch (error) {
    fail(error.message);
  }
}

export async function validateInstalledSubstrateTruthProof({
  substrateTruthPath,
  substrateInstallReportPath,
  targetProfile,
  releaseContractPath,
  deployTemplatePackagePath,
  consumerOutputDir,
  fail
}) {
  const truthPath = await canonicalLocalFile(substrateTruthPath, 'substrate truth', fail);
  const reportPath = await canonicalLocalFile(
    substrateInstallReportPath,
    'substrate install report',
    fail
  );
  assertInstallerOutputLayout({
    substrateTruthPath: truthPath,
    substrateInstallReportPath: reportPath,
    consumerOutputDir,
    fail
  });

  const release = await readReleaseBinding({
    releaseContractPath,
    deployTemplatePackagePath,
    fail
  });
  const reportInput = await readJson(reportPath, 'substrate install report', fail);
  const report = requireObject(reportInput.value, 'substrate_install_report', fail);
  validateReportShape(report, release, targetProfile, fail);

  const outputTruthPath = requireOutputTruthPath(report, fail);
  const expectedTruthPath = path.resolve(path.dirname(reportPath), outputTruthPath);
  let expectedTruthRealPath;
  try {
    expectedTruthRealPath = await fs.realpath(expectedTruthPath);
  } catch (error) {
    fail(`cannot resolve substrate_install_report.output_substrate_truth_path: ${error.message}`);
  }
  if (expectedTruthRealPath !== truthPath) {
    fail('--substrate-truth must match substrate_install_report.output_substrate_truth_path');
  }

  const truthDigest = await digestFile(truthPath, 'substrate truth', fail);
  const outputTruthDigest = requireDigest(
    report.output_substrate_truth_digest,
    'substrate_install_report.output_substrate_truth_digest',
    fail
  );
  if (outputTruthDigest !== truthDigest) {
    fail('substrate_install_report.output_substrate_truth_digest must match --substrate-truth digest');
  }
  if (
    Object.hasOwn(report, 'substrate_truth_digest') &&
    requireDigest(
      report.substrate_truth_digest,
      'substrate_install_report.substrate_truth_digest',
      fail
    ) !== truthDigest
  ) {
    fail('substrate_install_report.substrate_truth_digest must match --substrate-truth digest');
  }

  return {
    substrateTruthPath: truthPath,
    substrateInstallReportPath: reportPath,
    substrateTruthDigest: truthDigest,
    substrateInstallReportDigest: reportInput.digest
  };
}
