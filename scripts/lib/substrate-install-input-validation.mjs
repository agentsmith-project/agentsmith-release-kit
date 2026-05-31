import {
  assertNoUnsafeSubstratePayload,
  validateSubstrateConnectionTruth
} from './substrate-truth-validation.mjs';
import { flattenKubernetesResources } from './kubernetes-namespace-scope-guard.mjs';

export const SUBSTRATE_INSTALL_INPUTS_SCHEMA = 'agentsmith.substrate-install-inputs/v1';

const INPUT_FIELDS = new Set([
  'schema_version',
  'target_profile',
  'installation_id',
  'substrate_truth',
  'resources',
  'resource_list_path'
]);
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const INSTALLATION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;

function defaultFail(message) {
  throw new Error(message);
}

function requireObject(value, label, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireString(value, label, fail) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function assertAllowedFields(value, label, fail) {
  for (const key of Object.keys(value)) {
    if (!INPUT_FIELDS.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function requireTargetProfile(value, targetProfile, label, fail) {
  const text = requireString(value, label, fail);
  if (text !== targetProfile.value) {
    fail(`${label} must match CLI target_profile`);
  }
  return text;
}

function requireInstallationId(value, label, fail) {
  const text = requireString(value, label, fail);
  if (!INSTALLATION_ID_RE.test(text)) {
    fail(`${label} must be a safe installation id`);
  }
  return text;
}

function safeRelativePath(value, label, fail) {
  const text = requireString(value, label, fail);
  if (
    text !== text.trim() ||
    text.startsWith('/') ||
    /^[A-Za-z]:[\\/]/.test(text) ||
    text.includes('\\') ||
    text.includes('//') ||
    text.split('/').some((part) => part === '' || part === '.' || part === '..') ||
    !SAFE_RELATIVE_PATH_RE.test(text)
  ) {
    fail(`${label} must be a safe relative JSON resource list path`);
  }
  return text;
}

export function validateSubstrateInstallInputs(value, targetProfile, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'substrate_install_inputs';
  assertNoUnsafeSubstratePayload(value, label, options.raw);
  const inputs = requireObject(value, label, fail);
  assertAllowedFields(inputs, label, fail);

  const schemaVersion = requireString(inputs.schema_version, `${label}.schema_version`, fail);
  if (schemaVersion !== SUBSTRATE_INSTALL_INPUTS_SCHEMA) {
    fail(`${label}.schema_version must be ${SUBSTRATE_INSTALL_INPUTS_SCHEMA}`);
  }
  requireTargetProfile(inputs.target_profile, targetProfile, `${label}.target_profile`, fail);
  const installationId = requireInstallationId(
    inputs.installation_id,
    `${label}.installation_id`,
    fail
  );

  const hasInlineResources = Object.prototype.hasOwnProperty.call(inputs, 'resources');
  const hasResourceListPath = Object.prototype.hasOwnProperty.call(inputs, 'resource_list_path');
  if (hasInlineResources === hasResourceListPath) {
    fail(`${label} must include exactly one of resources or resource_list_path`);
  }

  const substrateTruth = requireObject(inputs.substrate_truth, `${label}.substrate_truth`, fail);
  const { truth, truthProfile, serviceSummary } = validateSubstrateConnectionTruth(
    substrateTruth,
    targetProfile,
    {
      label: `${label}.substrate_truth`,
      requiredSubstrateSource: 'kit_installed'
    }
  );

  return {
    inputs,
    installationId,
    substrateTruth: truth,
    truthProfile,
    serviceSummary,
    resources: hasInlineResources
      ? flattenKubernetesResources(inputs.resources, {
          fail,
          label: `${label}.resources`
        })
      : undefined,
    resourceListPath: hasResourceListPath
      ? safeRelativePath(inputs.resource_list_path, `${label}.resource_list_path`, fail)
      : undefined
  };
}

export function validateSubstrateResourceList(value, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'substrate_resource_list';
  assertNoUnsafeSubstratePayload(value, label, options.raw);
  return flattenKubernetesResources(value, { fail, label });
}
