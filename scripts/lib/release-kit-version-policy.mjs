export const CURRENT_RELEASE_KIT_VERSION = '0.1.0';

export const TARGET_CLUSTER_VALUES = new Set(['existing_kubernetes', 'kind_rehearsal']);
export const SUBSTRATE_SOURCE_VALUES = new Set(['external_declared', 'kit_installed']);
export const DISTRIBUTION_VALUES = new Set(['online', 'airgap']);

export const CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap',
  'kind_rehearsal/kit_installed/online'
];

export const CANONICAL_DECLARABLE_TARGET_PROFILE_SET = new Set(
  CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES
);

export const INTAKE_SUPPORTED_TARGET_PROFILE_VALUES =
  CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES;

export const INTAKE_SUPPORTED_TARGET_PROFILE_SET = new Set(
  INTAKE_SUPPORTED_TARGET_PROFILE_VALUES
);

export const EXECUTABLE_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online'
];

export const EXECUTABLE_TARGET_PROFILE_SET = new Set(EXECUTABLE_TARGET_PROFILE_VALUES);

export const EVIDENCE_SUPPORTED_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap'
];

export const EVIDENCE_SUPPORTED_TARGET_PROFILE_SET = new Set(
  EVIDENCE_SUPPORTED_TARGET_PROFILE_VALUES
);

// Pre-GA contracts may declare canonical targets, but no target is mandatory
// until the executable/evidence gates for that path exist.
export const REQUIRED_PROFILE_COVERAGE_TARGET_PROFILE_VALUES = [];

export const REQUIRED_PROFILE_COVERAGE_TARGET_PROFILE_SET = new Set(
  REQUIRED_PROFILE_COVERAGE_TARGET_PROFILE_VALUES
);

export const TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_VALUES =
  CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES;

export const TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_SET = new Set(
  TARGET_PREFLIGHT_INTAKE_TARGET_PROFILE_VALUES
);

export const IMAGE_MAP_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
];

export const IMAGE_MAP_TARGET_PROFILE_SET = new Set(IMAGE_MAP_TARGET_PROFILE_VALUES);

export const SUPPORTED_FOCUSED_TARGET_PROFILE_VALUES =
  EVIDENCE_SUPPORTED_TARGET_PROFILE_VALUES;

export const SUPPORTED_FOCUSED_TARGET_PROFILE_SET = new Set(
  SUPPORTED_FOCUSED_TARGET_PROFILE_VALUES
);

const STRICT_SEMVER_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

function requireProfileObject(value, label, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireProfileString(value, label, fail) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function requireProfileBoolean(value, label, fail) {
  if (typeof value !== 'boolean') {
    fail(`${label} must be a boolean`);
  }
  return value;
}

export function parseCanonicalTargetProfile(value, fail, label = 'target_profile') {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }

  const tuple = value.split('/');
  if (tuple.length !== 3 || tuple.some((part) => part.trim() === '')) {
    fail(`${label} must be <target_cluster>/<substrate_source>/<distribution>`);
  }

  const [targetCluster, substrateSource, distribution] = tuple;
  const normalized = `${targetCluster}/${substrateSource}/${distribution}`;
  if (!CANONICAL_DECLARABLE_TARGET_PROFILE_SET.has(normalized)) {
    fail(
      `${label} must be one of canonical profiles: ${CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES.join(
        ', '
      )}`
    );
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

export function validateContractTargetProfileEntry(value, fail, label) {
  const profile = requireProfileObject(value, label, fail);
  const targetCluster = requireProfileString(
    profile.target_cluster,
    `${label}.target_cluster`,
    fail
  );
  const substrateSource = requireProfileString(
    profile.substrate_source,
    `${label}.substrate_source`,
    fail
  );
  const distribution = requireProfileString(profile.distribution, `${label}.distribution`, fail);
  const profileTuple = `${targetCluster}/${substrateSource}/${distribution}`;

  if (!CANONICAL_DECLARABLE_TARGET_PROFILE_SET.has(profileTuple)) {
    fail(
      `${label} must be one of canonical profiles: ${CANONICAL_DECLARABLE_TARGET_PROFILE_VALUES.join(
        ', '
      )}`
    );
  }

  if (Object.prototype.hasOwnProperty.call(profile, 'support_level')) {
    fail(`${label}.support_level is not allowed; use ${label}.required`);
  }
  if (!Object.prototype.hasOwnProperty.call(profile, 'required')) {
    fail(`${label}.required is required`);
  }
  const required = requireProfileBoolean(profile.required, `${label}.required`, fail);
  if (required) {
    fail(`${label}.required must be false during pre-GA`);
  }

  return {
    value: profileTuple,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution,
    required
  };
}

export function parsePlainSemver(value) {
  if (typeof value !== 'string') {
    return null;
  }

  const match = STRICT_SEMVER_RE.exec(value);
  if (!match) {
    return null;
  }

  return {
    value,
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3])
  };
}

export function requirePlainSemver(value, label, fail) {
  const parsed = parsePlainSemver(value);
  if (!parsed) {
    fail(`${label} must be a plain semver version (x.y.z)`);
  }
  return parsed;
}

export function comparePlainSemver(left, right) {
  for (const part of ['major', 'minor', 'patch']) {
    if (left[part] > right[part]) {
      return 1;
    }
    if (left[part] < right[part]) {
      return -1;
    }
  }
  return 0;
}

export function assertPlainSemverAtLeast(value, minimum, valueLabel, minimumLabel, fail) {
  const parsedValue = requirePlainSemver(value, valueLabel, fail);
  const parsedMinimum = requirePlainSemver(minimum, minimumLabel, fail);
  if (comparePlainSemver(parsedValue, parsedMinimum) < 0) {
    fail(`${valueLabel} must be >= ${minimumLabel} (${minimum})`);
  }
  return parsedValue;
}
