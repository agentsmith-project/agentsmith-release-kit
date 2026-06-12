#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_FORBIDDEN_SOURCE_ROOTS = [path.resolve(ROOT_DIR, '..', 'agentsmith')];
const REQUIRED_ARGS = [
  'releaseContract',
  'renderedManifests',
  'targetProfile',
  'namespace',
  'outputDir'
];
const REPORT_SCHEMA = 'agentsmith.kubernetes-rollout-report/v1';
const ROLLOUT_SCOPE = 'kubernetes_rollout_imageid_only';
const SUPPORTED_TARGET_PROFILES = new Set([
  'existing_kubernetes/external_declared/online',
  'existing_kubernetes/external_declared/airgap',
  'existing_kubernetes/kit_installed/online',
  'existing_kubernetes/kit_installed/airgap'
]);
const ROLLOUT_STATUS_WORKLOAD_KINDS = new Set(['Deployment', 'StatefulSet', 'DaemonSet']);
const ROLLOUT_WORKLOAD_KINDS = new Set([...ROLLOUT_STATUS_WORKLOAD_KINDS, 'Job']);
const NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const TIMEOUT_RE = /^(?:0|[1-9][0-9]*(?:ms|s|m|h))$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const DIGEST_IN_TEXT_RE = /(?:@|^)(sha256:[0-9a-f]{64})(?:$|[^0-9a-f])/i;
const LABEL_SELECTOR_KEY_RE = /^[A-Za-z0-9_.\-/]+$/;
const LABEL_SELECTOR_VALUE_RE = /^[A-Za-z0-9_.-]+$/;

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
  node scripts/verify-rollout.mjs \\
    --release-contract <json> \\
    --rendered-manifests <dir> \\
    --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> \\
    --namespace <name> \\
    --output-dir <dir> \\
    [--timeout <duration>] \\
    [--kubeconfig <path>] \\
    [--context <name>] \\
    [--kubectl <path>] \\
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

function nextValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const parsed = {
    timeout: '120s',
    kubectl: 'kubectl'
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const readValue = () => {
      const value = nextValue(argv, index, arg);
      index += 1;
      return value;
    };

    if (arg.startsWith('--timeout=')) {
      parsed.timeout = arg.slice('--timeout='.length);
      continue;
    }

    switch (arg) {
      case '--release-contract':
        parsed.releaseContract = readValue();
        break;
      case '--rendered-manifests':
        parsed.renderedManifests = readValue();
        break;
      case '--target-profile':
        parsed.targetProfile = readValue();
        break;
      case '--namespace':
        parsed.namespace = readValue();
        break;
      case '--output-dir':
        parsed.outputDir = readValue();
        break;
      case '--timeout':
        parsed.timeout = readValue();
        break;
      case '--kubeconfig':
        parsed.kubeconfig = readValue();
        break;
      case '--context':
        parsed.context = readValue();
        break;
      case '--kubectl':
        parsed.kubectl = readValue();
        break;
      case '--forbidden-source-root':
        if (!parsed.forbiddenSourceRoots) {
          parsed.forbiddenSourceRoots = [];
        }
        parsed.forbiddenSourceRoots.push(readValue());
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
  if (!SUPPORTED_TARGET_PROFILES.has(normalized)) {
    fail(`--rollout only accepts ${[...SUPPORTED_TARGET_PROFILES].join(', ')}`);
  }

  return {
    value: normalized,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function validateNamespace(namespace) {
  if (
    typeof namespace !== 'string' ||
    namespace.length > 63 ||
    !NAMESPACE_RE.test(namespace)
  ) {
    fail('namespace must be a Kubernetes DNS label');
  }
}

function validateTimeout(timeout) {
  if (typeof timeout !== 'string' || !TIMEOUT_RE.test(timeout)) {
    fail('timeout must be 0 or a Kubernetes duration like 120s, 2m, or 1h');
  }
}

function validateArgs(args) {
  args.targetProfile = parseTargetProfile(args.targetProfile);
  validateNamespace(args.namespace);
  validateTimeout(args.timeout);
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
    const output = options.includeOutput ? summarizeOutput(`${result.stderr || ''}\n${result.stdout || ''}`) : '';
    fail(`${label} failed with ${exitStatus}${output}`);
  }

  return {
    stdout: result.stdout || '',
    stderr: result.stderr || ''
  };
}

function summarizeOutput(output) {
  const text = output.trim();
  if (!text) {
    return '';
  }
  return `: ${text.split(/\r?\n/).slice(-6).join(' | ')}`;
}

async function readJson(file, label) {
  let raw;
  try {
    raw = await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return {
      value: JSON.parse(raw),
      raw
    };
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

async function removeStaleReport(outputDir) {
  await fs.rm(path.join(outputDir, 'rollout-report.json'), { force: true });
}

async function existingDefaultForbiddenSourceRoots() {
  const roots = [];

  for (const root of DEFAULT_FORBIDDEN_SOURCE_ROOTS) {
    let stat;
    try {
      stat = await fs.stat(root);
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') {
        continue;
      }
      cliFail(`cannot inspect default forbidden source root: ${error.message}`);
    }

    if (stat.isDirectory()) {
      roots.push(root);
    }
  }

  return roots;
}

async function renderCheckForbiddenRootArgs(args) {
  const roots = [
    ...(await existingDefaultForbiddenSourceRoots()),
    ...(args.forbiddenSourceRoots || [])
  ];
  return roots.flatMap((root) => ['--forbidden-source-root', root]);
}

async function runRenderCheckGuard(args) {
  const tempOutputDir = await fs.mkdtemp(
    path.join(os.tmpdir(), 'agentsmith-rollout-render-check-')
  );
  const forbiddenRootArgs = await renderCheckForbiddenRootArgs(args);

  try {
    runCommand(
      process.execPath,
      [
        path.join(ROOT_DIR, 'scripts/verify-render-check.mjs'),
        '--release-contract',
        args.releaseContract,
        '--rendered-manifests',
        args.renderedManifests,
        '--target-profile',
        args.targetProfile.value,
        '--output-dir',
        tempOutputDir,
        ...forbiddenRootArgs
      ],
      'render-check guard',
      { includeOutput: true }
    );

    return await readJson(path.join(tempOutputDir, 'render-report.json'), 'render-check report');
  } finally {
    await fs.rm(tempOutputDir, { recursive: true, force: true });
  }
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

function requireRenderCheckPass(renderReport) {
  if (renderReport.readiness !== false) {
    fail('render-check guard report must keep readiness=false');
  }
  if (renderReport.status !== 'pass') {
    fail('render-check guard report must pass before rollout');
  }
  if (renderReport.scope !== 'render_check_image_inventory_only') {
    fail('render-check guard report has unexpected scope');
  }
}

function requirePlainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be a plain object`);
  }
  return value;
}

function expectedDigestsFromImages(images, label) {
  if (!Array.isArray(images) || images.length === 0) {
    fail(`${label} must include expected images`);
  }

  const byDigest = new Map();
  for (const image of images) {
    const digest = image?.digest;
    if (typeof digest !== 'string' || !DIGEST_RE.test(digest)) {
      fail(`${label} image digest is invalid`);
    }

    if (!byDigest.has(digest)) {
      byDigest.set(digest, {
        digest,
        inventory_ids: new Set(),
        images_count: 0
      });
    }
    const entry = byDigest.get(digest);
    entry.images_count += 1;
    if (typeof image.inventory_id === 'string' && image.inventory_id.trim() !== '') {
      entry.inventory_ids.add(image.inventory_id);
    }
  }

  return [...byDigest.values()]
    .map((entry) => ({
      digest: entry.digest,
      inventory_ids: [...entry.inventory_ids].sort(),
      images_count: entry.images_count
    }))
    .sort((left, right) => left.digest.localeCompare(right.digest));
}

function rolloutWorkloads(renderReport, namespace) {
  const manifests = Array.isArray(renderReport.manifests) ? renderReport.manifests : [];
  if (manifests.length === 0) {
    fail('render-check guard report must include workload manifests');
  }

  return manifests.map((manifest, index) => {
    const kind = manifest?.kind;
    const name = manifest?.name;

    if (!ROLLOUT_WORKLOAD_KINDS.has(kind)) {
      fail(`rollout supports only Deployment, StatefulSet, DaemonSet, and Job workloads; found ${kind || 'unknown'} at render-check manifest ${index + 1}`);
    }
    if (typeof name !== 'string' || name.trim() === '') {
      fail(`render-check manifest ${index + 1} must include metadata.name for rollout`);
    }

    const ref = {
      kind,
      name,
      namespace,
      path: manifest.path,
      document_index: manifest.document_index
    };

    return {
      resource_ref: Object.fromEntries(
        Object.entries(ref).filter(([, value]) => value !== undefined && value !== null)
      ),
      expected_image_digests: expectedDigestsFromImages(
        manifest.images,
        `render-check manifest ${index + 1}`
      ),
      expected_image_refs: expectedImageRefsFromImages(
        manifest.images,
        `render-check manifest ${index + 1}`
      )
    };
  });
}

function aggregateExpectedDigests(workloads) {
  const byDigest = new Map();

  for (const workload of workloads) {
    for (const expected of workload.expected_image_digests) {
      if (!byDigest.has(expected.digest)) {
        byDigest.set(expected.digest, {
          digest: expected.digest,
          inventory_ids: new Set(),
          images_count: 0
        });
      }
      const entry = byDigest.get(expected.digest);
      entry.images_count += expected.images_count;
      for (const inventoryId of expected.inventory_ids) {
        entry.inventory_ids.add(inventoryId);
      }
    }
  }

  return [...byDigest.values()]
    .map((entry) => ({
      digest: entry.digest,
      inventory_ids: [...entry.inventory_ids].sort(),
      images_count: entry.images_count
    }))
    .sort((left, right) => left.digest.localeCompare(right.digest));
}

function runRolloutStatus(args, resource) {
  runCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'rollout',
      'status',
      `${resource.kind}/${resource.name}`,
      '--namespace',
      args.namespace,
      '--timeout',
      args.timeout
    ],
    `kubectl rollout status ${resource.kind}/${resource.name}`
  );
}

function runJobWaitComplete(args, resource) {
  runCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'wait',
      '--for=condition=complete',
      `${resource.kind}/${resource.name}`,
      '--namespace',
      args.namespace,
      '--timeout',
      args.timeout
    ],
    `kubectl wait ${resource.kind}/${resource.name}`
  );
}

function waitForResourceReadiness(args, resource) {
  if (ROLLOUT_STATUS_WORKLOAD_KINDS.has(resource.kind)) {
    runRolloutStatus(args, resource);
    return;
  }

  if (resource.kind === 'Job') {
    runJobWaitComplete(args, resource);
    return;
  }

  fail(`rollout supports only Deployment, StatefulSet, DaemonSet, and Job workloads; found ${resource.kind || 'unknown'}`);
}

function parseKubectlJson(stdout, label) {
  try {
    return JSON.parse(stdout);
  } catch (error) {
    fail(`${label} returned invalid JSON: ${error.message}`);
  }
}

function runKubectlGetResource(args, resource) {
  const result = runCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'get',
      `${resource.kind}/${resource.name}`,
      '--namespace',
      args.namespace,
      '-o',
      'json'
    ],
    `kubectl get ${resource.kind}/${resource.name}`
  );

  return parseKubectlJson(result.stdout, `kubectl get ${resource.kind}/${resource.name}`);
}

function validateSelectorPart(value, label, pattern) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`);
  }
  if (value !== value.trim() || !pattern.test(value)) {
    fail(`${label} contains unsupported selector characters`);
  }
  return value;
}

function selectorFromResource(resourceJson, resource) {
  const selector = requirePlainObject(
    resourceJson?.spec?.selector,
    `${resource.kind}/${resource.name}.spec.selector`
  );
  if (Object.prototype.hasOwnProperty.call(selector, 'matchExpressions')) {
    fail(`${resource.kind}/${resource.name}.spec.selector.matchExpressions is not supported`);
  }

  const matchLabels = requirePlainObject(
    selector.matchLabels,
    `${resource.kind}/${resource.name}.spec.selector.matchLabels`
  );
  const entries = Object.entries(matchLabels).sort(([left], [right]) => {
    return left.localeCompare(right);
  });
  if (entries.length === 0) {
    fail(`${resource.kind}/${resource.name}.spec.selector.matchLabels must not be empty`);
  }

  return entries.map(([key, value]) => {
    const safeKey = validateSelectorPart(
      key,
      `${resource.kind}/${resource.name}.spec.selector.matchLabels key`,
      LABEL_SELECTOR_KEY_RE
    );
    const safeValue = validateSelectorPart(
      value,
      `${resource.kind}/${resource.name}.spec.selector.matchLabels.${key}`,
      LABEL_SELECTOR_VALUE_RE
    );
    return `${safeKey}=${safeValue}`;
  }).join(',');
}

function resourceRefWithSelector(resource, selector) {
  return Object.fromEntries(
    Object.entries({
      ...resource,
      selector
    }).filter(([, value]) => value !== undefined && value !== null)
  );
}

function runKubectlGetPods(args, selector) {
  const result = runCommand(
    args.kubectl,
    [
      ...kubectlPrefixArgs(args),
      'get',
      'pods',
      '--namespace',
      args.namespace,
      '--selector',
      selector,
      '-o',
      'json'
    ],
    'kubectl get pods'
  );

  return parseKubectlJson(result.stdout, 'kubectl get pods');
}

function extractDigest(value) {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim().toLowerCase();
  if (DIGEST_RE.test(trimmed)) {
    return trimmed;
  }
  const match = trimmed.match(DIGEST_IN_TEXT_RE);
  return match ? match[1].toLowerCase() : undefined;
}

function stripTag(imageWithoutDigest) {
  const lastSlash = imageWithoutDigest.lastIndexOf('/');
  const lastColon = imageWithoutDigest.lastIndexOf(':');
  if (lastColon > lastSlash) {
    return imageWithoutDigest.slice(0, lastColon);
  }
  return imageWithoutDigest;
}

function normalizeImageDigestRef(value) {
  if (typeof value !== 'string') {
    return undefined;
  }

  const withoutScheme = value.trim().replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
  const lower = withoutScheme.toLowerCase();
  const marker = '@sha256:';
  const markerIndex = lower.lastIndexOf(marker);
  if (markerIndex < 0) {
    return undefined;
  }

  const imageWithoutDigest = withoutScheme.slice(0, markerIndex);
  if (!imageWithoutDigest || imageWithoutDigest.includes('@')) {
    return undefined;
  }

  const digest = `sha256:${lower.slice(markerIndex + marker.length)}`;
  if (!DIGEST_RE.test(digest)) {
    return undefined;
  }

  const repository = stripTag(imageWithoutDigest).toLowerCase();
  if (!repository) {
    return undefined;
  }

  return {
    digest,
    ref: `${repository}@${digest}`
  };
}

function expectedImageRefsFromImages(images, label) {
  if (!Array.isArray(images) || images.length === 0) {
    fail(`${label} must include expected images`);
  }

  const byDigest = new Map();
  for (const image of images) {
    const normalized = normalizeImageDigestRef(image?.image);
    if (!normalized) {
      fail(`${label} image ref is invalid`);
    }

    if (!byDigest.has(normalized.digest)) {
      byDigest.set(normalized.digest, {
        digest: normalized.digest,
        image_refs: new Set()
      });
    }
    const entry = byDigest.get(normalized.digest);
    entry.image_refs.add(normalized.ref);
  }

  return [...byDigest.values()]
    .map((entry) => ({
      digest: entry.digest,
      image_refs: [...entry.image_refs].sort()
    }))
    .sort((left, right) => left.digest.localeCompare(right.digest));
}

function collectLiveStatusDigests(podsJson) {
  if (!podsJson || typeof podsJson !== 'object' || !Array.isArray(podsJson.items)) {
    fail('kubectl get pods JSON must include items array');
  }

  const observedDigests = new Set();
  const observedRefsByDigest = new Map();
  let statusEntriesCount = 0;
  let imageIdCount = 0;
  let imageFieldFallbackCount = 0;
  let missingDigestCount = 0;

  podsJson.items.forEach((pod) => {
    const status = pod && typeof pod === 'object' ? pod.status : undefined;
    if (!status || typeof status !== 'object' || Array.isArray(status)) {
      return;
    }

    for (const field of ['initContainerStatuses', 'containerStatuses']) {
      const statuses = Array.isArray(status[field]) ? status[field] : [];
      statuses.forEach((containerStatus) => {
        statusEntriesCount += 1;
        const imageIdDigest = extractDigest(containerStatus?.imageID);
        const imageDigest = extractDigest(containerStatus?.image);
        const selectedDigest = imageIdDigest || imageDigest;
        const selectedRef =
          normalizeImageDigestRef(containerStatus?.imageID) ||
          normalizeImageDigestRef(containerStatus?.image);
        if (selectedDigest) {
          observedDigests.add(selectedDigest);
        }
        if (selectedRef && selectedRef.digest === selectedDigest) {
          if (!observedRefsByDigest.has(selectedRef.digest)) {
            observedRefsByDigest.set(selectedRef.digest, new Set());
          }
          observedRefsByDigest.get(selectedRef.digest).add(selectedRef.ref);
        }
        if (imageIdDigest) {
          imageIdCount += 1;
        } else if (imageDigest) {
          imageFieldFallbackCount += 1;
        } else {
          missingDigestCount += 1;
        }
      });
    }
  });

  return {
    pods_count: podsJson.items.length,
    status_entries_count: statusEntriesCount,
    image_id_count: imageIdCount,
    image_field_fallback_count: imageFieldFallbackCount,
    missing_digest_count: missingDigestCount,
    observed_digests: [...observedDigests].sort(),
    observed_image_refs_by_digest: observedRefsByDigest
  };
}

function matchedExpectedDigests(expectedDigests, liveSummary) {
  return expectedDigests
    .map((entry) => entry.digest)
    .filter((digest) => liveSummary.observed_digests.includes(digest));
}

function assertExpectedDigestsObserved(expectedDigests, liveSummary, resource) {
  const observed = new Set(liveSummary.observed_digests);
  const missing = expectedDigests
    .map((entry) => entry.digest)
    .filter((digest) => !observed.has(digest));

  if (missing.length > 0) {
    fail(`${resource.kind}/${resource.name} selected pods are missing expected release image digest(s): ${missing.join(', ')}`);
  }
}

function liveDigestSummaryForExpected(expectedDigests, liveSummary) {
  return {
    pods_count: liveSummary.pods_count,
    status_entries_count: liveSummary.status_entries_count,
    image_id_count: liveSummary.image_id_count,
    image_field_fallback_count: liveSummary.image_field_fallback_count,
    missing_digest_count: liveSummary.missing_digest_count,
    observed_digest_count: liveSummary.observed_digests.length,
    observed_digests: liveSummary.observed_digests,
    matched_expected_digests: matchedExpectedDigests(expectedDigests, liveSummary)
  };
}

function imageRefDriftDigestSummary(digest, renderedImageRefs, observedLiveImageRefs) {
  const renderedRefs = [...new Set(renderedImageRefs)].sort();
  const observedRefs = [...new Set(observedLiveImageRefs)].sort();
  const renderedSet = new Set(renderedRefs);
  const observedSet = new Set(observedRefs);
  const missingRenderedRefCount = renderedRefs.filter((ref) => !observedSet.has(ref)).length;
  const unexpectedLiveRefCount = observedRefs.filter((ref) => !renderedSet.has(ref)).length;
  const drift = missingRenderedRefCount > 0 || unexpectedLiveRefCount > 0;

  return {
    digest,
    rendered_image_refs: renderedRefs,
    observed_live_image_refs: observedRefs,
    drift,
    missing_rendered_ref_count: missingRenderedRefCount,
    unexpected_live_ref_count: unexpectedLiveRefCount
  };
}

function imageRefDriftSummaryFromDigests(digests) {
  const normalizedDigests = digests.sort((left, right) => left.digest.localeCompare(right.digest));
  const driftedDigestsCount = normalizedDigests.filter((entry) => entry.drift).length;

  return {
    drift: driftedDigestsCount > 0,
    digests_count: normalizedDigests.length,
    drifted_digests_count: driftedDigestsCount,
    rendered_refs_count: normalizedDigests.reduce(
      (count, entry) => count + entry.rendered_image_refs.length,
      0
    ),
    observed_refs_count: normalizedDigests.reduce(
      (count, entry) => count + entry.observed_live_image_refs.length,
      0
    ),
    digests: normalizedDigests
  };
}

function liveImageRefDriftSummaryForExpected(expectedImageRefs, liveSummary) {
  const digests = expectedImageRefs.map((expected) => {
    const observedRefs = liveSummary.observed_image_refs_by_digest.get(expected.digest);
    return imageRefDriftDigestSummary(
      expected.digest,
      expected.image_refs,
      observedRefs ? [...observedRefs] : []
    );
  });

  return imageRefDriftSummaryFromDigests(digests);
}

function aggregateLiveDigestSummary(workloadResults, expectedDigests) {
  const observedDigests = new Set();
  const aggregate = {
    pods_count: 0,
    status_entries_count: 0,
    image_id_count: 0,
    image_field_fallback_count: 0,
    missing_digest_count: 0,
    observed_digests: []
  };

  for (const result of workloadResults) {
    const summary = result.observed_live_image_digest_summary;
    aggregate.pods_count += summary.pods_count;
    aggregate.status_entries_count += summary.status_entries_count;
    aggregate.image_id_count += summary.image_id_count;
    aggregate.image_field_fallback_count += summary.image_field_fallback_count;
    aggregate.missing_digest_count += summary.missing_digest_count;
    for (const digest of summary.observed_digests) {
      observedDigests.add(digest);
    }
  }

  aggregate.observed_digests = [...observedDigests].sort();
  return liveDigestSummaryForExpected(expectedDigests, aggregate);
}

function aggregateLiveImageRefDriftSummary(workloadResults) {
  const byDigest = new Map();

  for (const result of workloadResults) {
    const entries = result.observed_live_image_ref_drift_summary?.digests;
    if (!Array.isArray(entries)) {
      continue;
    }

    for (const entry of entries) {
      if (!byDigest.has(entry.digest)) {
        byDigest.set(entry.digest, {
          rendered_image_refs: new Set(),
          observed_live_image_refs: new Set()
        });
      }
      const aggregate = byDigest.get(entry.digest);
      for (const ref of entry.rendered_image_refs || []) {
        aggregate.rendered_image_refs.add(ref);
      }
      for (const ref of entry.observed_live_image_refs || []) {
        aggregate.observed_live_image_refs.add(ref);
      }
    }
  }

  const digests = [...byDigest.entries()].map(([digest, entry]) => {
    return imageRefDriftDigestSummary(
      digest,
      [...entry.rendered_image_refs],
      [...entry.observed_live_image_refs]
    );
  });

  return imageRefDriftSummaryFromDigests(digests);
}

function buildReport({ args, renderReport, workloadResults, expectedDigests }) {
  const resourceRefs = workloadResults.map((result) => result.resource_ref);

  return {
    schema: REPORT_SCHEMA,
    scope: ROLLOUT_SCOPE,
    readiness: false,
    status: 'pass',
    release_id: renderReport.release_id,
    git_sha: renderReport.git_sha,
    release_contract: {
      input_sha256: renderReport.release_contract?.input_sha256,
      deploy_image_inventory_count: renderReport.release_contract?.deploy_image_inventory_count
    },
    target_profile: args.targetProfile,
    namespace: args.namespace,
    timeout: args.timeout,
    rollout_resource_refs: resourceRefs,
    expected_image_digests: expectedDigests,
    observed_live_image_digest_summary: aggregateLiveDigestSummary(
      workloadResults,
      expectedDigests
    ),
    observed_live_image_ref_drift_summary: aggregateLiveImageRefDriftSummary(
      workloadResults
    ),
    workload_summaries: workloadResults,
    render_check: {
      schema: renderReport.schema,
      scope: renderReport.scope,
      status: renderReport.status,
      images_count: Array.isArray(renderReport.images) ? renderReport.images.length : 0,
      workload_count: Array.isArray(renderReport.manifests) ? renderReport.manifests.length : 0
    },
    generated_at: new Date().toISOString()
  };
}

async function writeReport(outputDir, report) {
  await fs.mkdir(outputDir, { recursive: true });
  const reportFile = path.join(outputDir, 'rollout-report.json');
  const tempFile = path.join(outputDir, `.rollout-report.${process.pid}.tmp`);
  await fs.writeFile(tempFile, `${JSON.stringify(report, null, 2)}\n`);
  await fs.rename(tempFile, reportFile);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  await removeStaleReport(args.outputDir);
  validateArgs(args);

  const renderCheckReport = await runRenderCheckGuard(args);
  requireRenderCheckPass(renderCheckReport.value);

  const workloads = rolloutWorkloads(renderCheckReport.value, args.namespace);
  const expectedDigests = aggregateExpectedDigests(workloads);
  const workloadResults = [];

  for (const workload of workloads) {
    const resource = workload.resource_ref;
    waitForResourceReadiness(args, resource);
    const liveResource = runKubectlGetResource(args, resource);
    const selector = selectorFromResource(liveResource, resource);
    const livePodsJson = runKubectlGetPods(args, selector);
    const liveSummary = collectLiveStatusDigests(livePodsJson);
    assertExpectedDigestsObserved(workload.expected_image_digests, liveSummary, resource);
    workloadResults.push({
      resource_ref: resourceRefWithSelector(resource, selector),
      expected_image_digests: workload.expected_image_digests,
      observed_live_image_digest_summary: liveDigestSummaryForExpected(
        workload.expected_image_digests,
        liveSummary
      ),
      observed_live_image_ref_drift_summary: liveImageRefDriftSummaryForExpected(
        workload.expected_image_refs,
        liveSummary
      )
    });
  }

  await writeReport(
    args.outputDir,
    buildReport({
      args,
      renderReport: renderCheckReport.value,
      workloadResults,
      expectedDigests
    })
  );

  console.log('PASS: Kubernetes rollout status/Job completion and live image digests accepted rendered manifests');
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
