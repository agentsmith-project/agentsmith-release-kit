export const CURRENT_RELEASE_KIT_VERSION = '0.1.0';

export const SUPPORTED_FOCUSED_TARGET_PROFILE_VALUES = [
  'existing_kubernetes/external_declared/online',
  'kind_rehearsal/kit_installed/online'
];

export const SUPPORTED_FOCUSED_TARGET_PROFILE_SET = new Set(
  SUPPORTED_FOCUSED_TARGET_PROFILE_VALUES
);

const STRICT_SEMVER_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

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
