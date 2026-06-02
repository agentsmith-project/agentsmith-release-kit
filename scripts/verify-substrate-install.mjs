#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  SUBSTRATE_PACK_MANIFEST_SCHEMA,
  validateSubstratePackManifest
} from './lib/substrate-pack-manifest-validation.mjs';
import {
  TARGET_PREREQUISITES_SCHEMA,
  assertNoUnsafeSubstratePayload,
  validateTargetPrerequisitesTruth
} from './lib/substrate-truth-validation.mjs';
import {
  SUBSTRATE_INSTALL_INPUTS_SCHEMA,
  validateSubstrateInstallInputs
} from './lib/substrate-install-input-validation.mjs';
import {
  digestBuffer,
  digestText,
  resolveSubstrateInstallParameters
} from './lib/substrate-install-parameters.mjs';
import {
  formatResourceRef,
  imageRefsFromSubstratePackManifest,
  isKitOwnedResource,
  resourceRefForKubectl,
  validateNamespaceScopedResources
} from './lib/kubernetes-namespace-scope-guard.mjs';
import {
  CURRENT_RELEASE_KIT_VERSION,
  parseCanonicalTargetProfile
} from './lib/release-kit-version-policy.mjs';

const REQUIRED_ARGS = [
  'releaseContract',
  'deployTemplatePackage',
  'targetProfile',
  'substratePackManifest',
  'substrateInstallInputs',
  'targetPrerequisites',
  'namespace',
  'outputDir'
];
const RELEASE_CONTRACT_SCHEMA = 'agentsmith.release-contract/v1';
const DEPLOY_TEMPLATE_SCHEMA = 'agentsmith.deploy-template-package/v1';
const REPORT_SCHEMA = 'agentsmith.substrate-install-report/v1';
const REPORT_SCOPE = 'substrate_install_only';
const PRODUCER = 'agentsmith-release-kit-substrate-installer';
const REPORT_FILE = 'substrate-install-report.json';
const TRUTH_FILE = 'substrate-truth.json';
const SUPPORTED_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
];
const SUPPORTED_TARGET_PROFILE_SET = new Set(SUPPORTED_TARGET_PROFILE_VALUES);
const SUPPORTED_MODES = new Set(['server-dry-run', 'apply']);
const NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const GIT_SHA_RE = /^[0-9a-f]{40}$/;
const OPERATOR_RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;

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
  node scripts/verify-substrate-install.mjs \\
    --release-contract <json> \\
    --deploy-template-package <json> \\
    --target-profile existing_kubernetes/kit_installed/<online|airgap> \\
    --substrate-pack-manifest <json> \\
    --substrate-install-inputs <json> \\
    --target-prerequisites <json> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--mode server-dry-run|apply] \\
    [--kubectl <path>] \\
    [--kubeconfig <path>] \\
    [--context <name>]

  Real substrate apply requires:
    --mode apply \\
    --confirm-substrate-install <matching-target-profile> \\
    --confirm-install-parameters <sha256:substrate-install-parameters> \\
    --operator-run-id <id>`;
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
    kubectl: 'kubectl',
    mode: 'server-dry-run'
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
    if (arg.startsWith('--confirm-substrate-install=')) {
      parsed.confirmSubstrateInstall = arg.slice('--confirm-substrate-install='.length);
      continue;
    }
    if (arg.startsWith('--confirm-install-parameters=')) {
      parsed.confirmInstallParameters = arg.slice('--confirm-install-parameters='.length);
      continue;
    }

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = nextValue();
        break;
      case '--deploy-template-package':
        parsed.deployTemplatePackage = nextValue();
        break;
      case '--target-profile':
        parsed.targetProfile = nextValue();
        break;
      case '--substrate-pack-manifest':
        parsed.substratePackManifest = nextValue();
        break;
      case '--substrate-install-inputs':
        parsed.substrateInstallInputs = nextValue();
        break;
      case '--target-prerequisites':
        parsed.targetPrerequisites = nextValue();
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
      case '--kubectl':
        parsed.kubectl = nextValue();
        break;
      case '--kubeconfig':
        parsed.kubeconfig = nextValue();
        break;
      case '--context':
        parsed.context = nextValue();
        break;
      case '--confirm-substrate-install':
        parsed.confirmSubstrateInstall = nextValue();
        break;
      case '--confirm-install-parameters':
        parsed.confirmInstallParameters = nextValue();
        break;
      case '--operator-run-id':
        parsed.operatorRunId = nextValue();
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

  validateArgs(parsed);
  return parsed;
}

function parseTargetProfile(value) {
  const targetProfile = parseCanonicalTargetProfile(value, fail, 'target_profile');
  if (!SUPPORTED_TARGET_PROFILE_SET.has(targetProfile.value)) {
    fail(`--substrate-install only accepts ${SUPPORTED_TARGET_PROFILE_VALUES.join(' or ')}`);
  }
  return targetProfile;
}

function validateNamespace(value) {
  if (typeof value !== 'string' || value.length > 63 || !NAMESPACE_RE.test(value)) {
    fail('namespace must be a Kubernetes DNS label');
  }
  return value;
}

function validateOperatorRunId(value, label) {
  if (typeof value !== 'string' || !OPERATOR_RUN_ID_RE.test(value)) {
    fail(`${label} must be a safe operator run id`);
  }
  return value;
}

function validateDigest(value, label) {
  if (typeof value !== 'string' || !DIGEST_RE.test(value)) {
    fail(`${label} must be a sha256 digest`);
  }
  return value;
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);
  args.namespace = validateNamespace(args.namespace);

  if (!SUPPORTED_MODES.has(args.mode)) {
    cliFail('--mode must be server-dry-run or apply');
  }

  if (args.mode === 'apply') {
    if (args.confirmSubstrateInstall !== args.targetProfile.value) {
      cliFail(`--mode apply requires --confirm-substrate-install ${args.targetProfile.value}`);
    }
    if (!args.confirmInstallParameters) {
      cliFail('--mode apply requires --confirm-install-parameters <sha256:...>');
    }
    validateDigest(args.confirmInstallParameters, '--confirm-install-parameters');
    if (!args.operatorRunId) {
      cliFail('--mode apply requires --operator-run-id <id>');
    }
    validateOperatorRunId(args.operatorRunId, '--operator-run-id');
    return;
  }

  if (args.confirmSubstrateInstall) {
    cliFail('--confirm-substrate-install is only accepted with --mode apply');
  }
  if (args.confirmInstallParameters) {
    cliFail('--confirm-install-parameters is only accepted with --mode apply');
  }
  if (args.operatorRunId) {
    cliFail('--operator-run-id is only accepted with --mode apply');
  }
}

async function readJson(file, label) {
  let buffer;
  try {
    buffer = await fs.readFile(file);
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      file,
      buffer,
      value: JSON.parse(buffer.toString('utf8')),
      raw: buffer.toString('utf8'),
      inputDigest: digestBuffer(buffer)
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function removeStaleOutputs(outputDir) {
  await fs.rm(path.join(outputDir, REPORT_FILE), { force: true });
  await fs.rm(path.join(outputDir, TRUTH_FILE), { force: true });
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

function requireDigest(value, label) {
  const digest = requireString(value, label);
  if (!DIGEST_RE.test(digest)) {
    fail(`${label} must be a sha256 digest`);
  }
  return digest;
}

function requireGitSha(value, label) {
  const gitSha = requireString(value, label);
  if (!GIT_SHA_RE.test(gitSha)) {
    fail(`${label} must be a 40-character git sha`);
  }
  return gitSha;
}

function requireSchema(value, expected, label) {
  const schema = value.schema ?? value.schema_version;
  if (schema !== expected) {
    fail(`${label}.schema must be ${expected}`);
  }
}

function sameArraySet(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) {
    return false;
  }
  const leftSet = new Set(left);
  const rightSet = new Set(right);
  if (leftSet.size !== left.length || rightSet.size !== right.length || leftSet.size !== rightSet.size) {
    return false;
  }
  return [...leftSet].every((item) => rightSet.has(item));
}

function validateDeployImageInventory(value) {
  const entries = Array.isArray(value) ? value : fail('release_contract.deploy_image_inventory must be an array');
  if (entries.length === 0) {
    fail('release_contract.deploy_image_inventory must not be empty');
  }
  const seen = new Set();
  const ids = [];
  for (const [index, rawEntry] of entries.entries()) {
    const entry = requireObject(rawEntry, `release_contract.deploy_image_inventory[${index}]`);
    const id = requireString(entry.id, `release_contract.deploy_image_inventory[${index}].id`);
    if (seen.has(id)) {
      fail(`release_contract.deploy_image_inventory contains duplicate image id: ${id}`);
    }
    requireString(entry.image, `release_contract.deploy_image_inventory[${index}].image`);
    requireDigest(entry.digest, `release_contract.deploy_image_inventory[${index}].digest`);
    seen.add(id);
    ids.push(id);
  }
  return ids;
}

function validateReleaseInputs(contractInput, deployTemplateInput) {
  const contract = requireObject(contractInput.value, 'release contract');
  const deployTemplate = requireObject(deployTemplateInput.value, 'deploy template package');
  requireSchema(contract, RELEASE_CONTRACT_SCHEMA, 'release contract');
  requireSchema(deployTemplate, DEPLOY_TEMPLATE_SCHEMA, 'deploy template package');

  const releaseId = requireString(contract.release_id, 'release_contract.release_id');
  const gitSha = requireGitSha(contract.git_sha, 'release_contract.git_sha');
  const contractTemplate = requireObject(
    contract.deploy_template_package,
    'release_contract.deploy_template_package'
  );
  const packageSha = requireDigest(deployTemplate.package_sha256, 'deploy_template_package.package_sha256');
  const contractPackageSha = requireDigest(
    contractTemplate.package_sha256,
    'release_contract.deploy_template_package.package_sha256'
  );
  if (packageSha !== contractPackageSha) {
    fail('deploy template package package_sha256 must match release contract');
  }
  const manifestSha = requireDigest(
    deployTemplate.manifest_sha256,
    'deploy_template_package.manifest_sha256'
  );
  const contractManifestSha = requireDigest(
    contractTemplate.manifest_sha256,
    'release_contract.deploy_template_package.manifest_sha256'
  );
  if (manifestSha !== contractManifestSha) {
    fail('deploy template package manifest_sha256 must match release contract');
  }

  const templateRequiredIds = Array.isArray(deployTemplate.required_image_ids)
    ? deployTemplate.required_image_ids.map((item, index) =>
        requireString(item, `deploy_template_package.required_image_ids[${index}]`)
      )
    : fail('deploy_template_package.required_image_ids must be an array');
  const contractRequiredIds = Array.isArray(contractTemplate.required_image_ids)
    ? contractTemplate.required_image_ids.map((item, index) =>
        requireString(item, `release_contract.deploy_template_package.required_image_ids[${index}]`)
      )
    : fail('release_contract.deploy_template_package.required_image_ids must be an array');
  const inventoryIds = validateDeployImageInventory(contract.deploy_image_inventory);
  if (!sameArraySet(contractRequiredIds, inventoryIds)) {
    fail('release_contract.deploy_template_package.required_image_ids must exactly match release_contract.deploy_image_inventory ids');
  }
  if (!sameArraySet(templateRequiredIds, contractRequiredIds)) {
    fail('deploy template package required_image_ids must match release contract');
  }

  return {
    release_id: releaseId,
    git_sha: gitSha,
    release_contract_digest: contractInput.inputDigest,
    deploy_template_package_digest: deployTemplateInput.inputDigest
  };
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

function summarizeOutput(output) {
  const text = output.trim();
  if (!text) {
    return '';
  }
  return `: ${text.split(/\r?\n/).slice(-6).join(' | ')}`;
}

function runCommand(command, commandArgs, label, options = {}) {
  const result = spawnSync(command, commandArgs, {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  });

  if (result.error) {
    fail(`${label} failed to start: ${result.error.message}`);
  }

  if (result.status !== 0) {
    const exitStatus = result.status === null ? `signal ${result.signal}` : `exit code ${result.status}`;
    const output = options.includeOutput
      ? summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`)
      : '';
    fail(`${label} failed with ${exitStatus}${output}`);
  }

  return {
    stdout: result.stdout || '',
    stderr: result.stderr || ''
  };
}

function versionFields(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const fields = {};
  for (const key of ['gitVersion', 'major', 'minor', 'platform']) {
    if (typeof value[key] === 'string' && value[key].trim() !== '') {
      fields[key] = value[key];
    }
  }
  return Object.keys(fields).length > 0 ? fields : undefined;
}

function normalizeKubectlVersion(stdout) {
  const trimmed = stdout.trim();
  if (trimmed === '') {
    return {
      output: 'empty',
      output_sha256: digestText(trimmed)
    };
  }

  try {
    const parsed = JSON.parse(trimmed);
    const normalized = {
      output_sha256: digestText(trimmed)
    };
    const client = versionFields(parsed.clientVersion);
    const server = versionFields(parsed.serverVersion);
    if (client) {
      normalized.client = client;
    }
    if (server) {
      normalized.server = server;
    }
    return normalized;
  } catch {
    return {
      parse_status: 'unparsed',
      output_sha256: digestText(trimmed)
    };
  }
}

function runKubectlVersion(args) {
  const result = runCommand(
    args.kubectl,
    [...kubectlPrefixArgs(args), 'version', '--output=json'],
    'kubectl version'
  );
  return normalizeKubectlVersion(result.stdout);
}

function isNotFound(result) {
  const output = `${result.stderr || ''}\n${result.stdout || ''}`;
  return /notfound|not found|not\s+found/i.test(output);
}

function runKubectlGet(args, ref) {
  return spawnSync(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'get',
      ref.resource,
      ref.name,
      '--namespace',
      ref.namespace,
      '-o',
      'json'
    ],
    {
      encoding: 'utf8',
      maxBuffer: 2 * 1024 * 1024
    }
  );
}

function assertNoNonKitCollision(args, resources, installationId) {
  const summary = {
    checked_resource_count: 0,
    kubectl_get_count: 0,
    not_found_count: 0,
    owned_resource_count: 0
  };
  for (const resource of resources) {
    const ref = resourceRefForKubectl(resource, args.namespace);
    summary.checked_resource_count += 1;
    summary.kubectl_get_count += 1;
    const result = runKubectlGet(args, ref);
    if (result.error) {
      fail(`kubectl get ${formatResourceRef(ref)} failed to start: ${result.error.message}`);
    }
    if (result.status !== 0) {
      if (isNotFound(result)) {
        summary.not_found_count += 1;
        continue;
      }
      const exitStatus = result.status === null ? `signal ${result.signal}` : `exit code ${result.status}`;
      fail(`kubectl get ${formatResourceRef(ref)} failed with ${exitStatus}${summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`)}`);
    }

    let existing;
    try {
      existing = JSON.parse(result.stdout);
    } catch (error) {
      fail(`kubectl get ${formatResourceRef(ref)} returned invalid JSON: ${error.message}`);
    }
    if (
      !isKitOwnedResource(resource, { installationId }) ||
      !isKitOwnedResource(existing, { installationId })
    ) {
      fail(`existing ${formatResourceRef(ref)} is not owned by agentsmith-release-kit`);
    }
    summary.owned_resource_count += 1;
  }
  return summary;
}

function kubectlResourceRefs(stdout) {
  return stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== '');
}

async function writeApplyResourceList(outputDir, applyResourceListBytes) {
  await fs.mkdir(outputDir, { recursive: true });
  const file = path.join(outputDir, `.substrate-install-resources.${process.pid}.json`);
  await fs.writeFile(file, applyResourceListBytes);
  return file;
}

async function runKubectlApply(args, applyResourceListBytes) {
  const resourceListFile = await writeApplyResourceList(args.outputDir, applyResourceListBytes);
  try {
    const applyArgs = [
      ...kubectlPrefixArgs(args),
      'apply',
      '--server-side',
      '--namespace',
      args.namespace,
      '-f',
      resourceListFile
    ];

    if (args.mode === 'server-dry-run') {
      applyArgs.push('--dry-run=server');
    }

    applyArgs.push('-o', 'name');
    return runCommand(args.kubectl, applyArgs, 'kubectl apply');
  } finally {
    await fs.rm(resourceListFile, { force: true });
  }
}

async function writeJsonWithDigest(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const tempFile = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  const buffer = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
  await fs.writeFile(tempFile, buffer);
  await fs.rename(tempFile, file);
  return digestBuffer(buffer);
}

function buildReport({
  args,
  release,
  packInputDigest,
  installInputDigest,
  resourceListBinding,
  prerequisitesInputDigest,
  substrateTruthDigest,
  serviceSummary,
  manifestSummary,
  prerequisitesSummary,
  resourceRefs,
  kubectlVersion,
  kubectlApplyOutput,
  collisionSummary
}) {
  const kubectlRefs = kubectlResourceRefs(kubectlApplyOutput.stdout);
  const kubectlApplyCommand =
    `kubectl apply --server-side --namespace ${args.namespace} -f <apply-resource-list>${
      args.mode === 'server-dry-run' ? ' --dry-run=server' : ''
    } -o name`;
  const report = {
    schema: REPORT_SCHEMA,
    scope: REPORT_SCOPE,
    producer: PRODUCER,
    readiness: false,
    status: 'pass',
    release_id: release.release_id,
    git_sha: release.git_sha,
    release_contract_digest: release.release_contract_digest,
    deploy_template_package_digest: release.deploy_template_package_digest,
    target_profile: args.targetProfile,
    namespace: args.namespace,
    mode: args.mode,
    inputs: {
      substrate_pack_manifest: {
        schema_version: SUBSTRATE_PACK_MANIFEST_SCHEMA,
        input_sha256: packInputDigest,
        target_profile: args.targetProfile.value,
        release_contract_digest: release.release_contract_digest,
        deploy_template_package_digest: release.deploy_template_package_digest
      },
      substrate_install_inputs: {
        schema_version: SUBSTRATE_INSTALL_INPUTS_SCHEMA,
        input_sha256: installInputDigest,
        resource_source: resourceListBinding.resourceSource,
        resource_list_sha256: resourceListBinding.resourceListDigest,
        apply_resource_list_sha256: resourceListBinding.applyResourceListDigest,
        effective_namespace: resourceListBinding.effectiveNamespace,
        install_parameters_sha256: resourceListBinding.installParametersDigest,
        ...(resourceListBinding.resourceListPath
          ? { resource_list_path: resourceListBinding.resourceListPath }
          : {})
      },
      target_prerequisites: {
        schema_version: TARGET_PREREQUISITES_SCHEMA,
        input_sha256: prerequisitesInputDigest,
        target_profile: args.targetProfile.value,
        namespace: prerequisitesSummary.namespace
      }
    },
    substrate_truth_digest: substrateTruthDigest,
    output_substrate_truth_path: TRUTH_FILE,
    output_substrate_truth_digest: substrateTruthDigest,
    installed_services: serviceSummary.services,
    resource_refs: resourceRefs,
    kubectl_resource_refs: kubectlRefs,
    kubectl_version: kubectlVersion,
    checks: {
      substrate_pack_manifest: 'pass',
      substrate_install_inputs: 'pass',
      target_prerequisites: 'pass',
      namespace_scope: {
        status: 'pass',
        namespace: args.namespace,
        resource_count: resourceRefs.length,
        allowed_resource_count: resourceRefs.length
      },
      collision_guard: {
        status: 'pass',
        ...collisionSummary
      },
      kubectl_apply: {
        status: 'pass',
        mode: args.mode,
        applied_resource_count: resourceRefs.length,
        kubectl_resource_count: kubectlRefs.length,
        command_summary: {
          command: kubectlApplyCommand,
          server_side: true,
          namespace: args.namespace,
          output: 'name',
          dry_run: args.mode === 'server-dry-run' ? 'server' : 'none'
        }
      }
    },
    summary: {
      release_kit_version: CURRENT_RELEASE_KIT_VERSION,
      substrate_pack_release_kit_version: manifestSummary.release_kit_version,
      installed_by: manifestSummary.installed_by,
      resources_count: resourceRefs.length,
      substrate_services_count: serviceSummary.services_count
    },
    generated_at: new Date().toISOString()
  };

  if (args.mode === 'apply') {
    report.operator_run_id = args.operatorRunId;
  }

  return report;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleOutputs(args.outputDir);
  const releaseContractInput = await readJson(args.releaseContract, 'release contract');
  const deployTemplateInput = await readJson(args.deployTemplatePackage, 'deploy template package');
  const packInput = await readJson(args.substratePackManifest, 'substrate pack manifest');
  const installInput = await readJson(args.substrateInstallInputs, 'substrate install inputs');
  const prerequisitesInput = await readJson(args.targetPrerequisites, 'target prerequisites');

  const release = validateReleaseInputs(releaseContractInput, deployTemplateInput);
  const { manifest, manifestSummary } = validateSubstratePackManifest(
    packInput.value,
    args.targetProfile,
    { fail }
  );
  const installSummary = validateSubstrateInstallInputs(
    installInput.value,
    args.targetProfile,
    {
      fail,
      raw: installInput.raw
    }
  );
  const resourceListBinding = await resolveSubstrateInstallParameters({
    installInput,
    installSummary,
    namespace: args.namespace,
    readJson,
    fail
  });
  const { applyResourceListBytes } = resourceListBinding;
  if (
    args.mode === 'apply' &&
    args.confirmInstallParameters !== resourceListBinding.installParametersDigest
  ) {
    fail('--confirm-install-parameters must match the substrate install parameters sha256');
  }

  assertNoUnsafeSubstratePayload(
    prerequisitesInput.value,
    'target_prerequisites',
    prerequisitesInput.raw
  );
  const { prerequisitesSummary } = validateTargetPrerequisitesTruth(
    prerequisitesInput.value,
    args.targetProfile,
    installSummary.substrateTruth,
    {
      label: 'target_prerequisites',
      expectedNamespace: args.namespace
    }
  );

  const resources = resourceListBinding.resources;
  const resourceRefs = validateNamespaceScopedResources(resources, args.namespace, {
    fail,
    label: 'substrate install resources',
    installationId: installSummary.installationId,
    allowedImages: imageRefsFromSubstratePackManifest(manifest, { fail }),
    storageClassName: prerequisitesSummary.storage_class
  });

  const kubectlVersion = runKubectlVersion(args);
  const collisionSummary = assertNoNonKitCollision(args, resources, installSummary.installationId);
  const kubectlApplyOutput = await runKubectlApply(args, applyResourceListBytes);

  const truthDigest = await writeJsonWithDigest(
    path.join(args.outputDir, TRUTH_FILE),
    installSummary.substrateTruth
  );
  const report = buildReport({
    args,
    release,
    packInputDigest: packInput.inputDigest,
    installInputDigest: installInput.inputDigest,
    prerequisitesInputDigest: prerequisitesInput.inputDigest,
    substrateTruthDigest: truthDigest,
    serviceSummary: installSummary.serviceSummary,
    manifestSummary,
    prerequisitesSummary,
    resourceListBinding,
    resourceRefs,
    kubectlVersion,
    kubectlApplyOutput,
    collisionSummary
  });
  assertNoUnsafeSubstratePayload(report, 'substrate_install_report', JSON.stringify(report));
  await writeJsonWithDigest(path.join(args.outputDir, REPORT_FILE), report);

  if (args.mode === 'server-dry-run') {
    console.log('PASS: substrate install server-side dry-run accepted namespace-scoped resources');
    return;
  }
  console.log('PASS: substrate install apply accepted namespace-scoped resources');
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
