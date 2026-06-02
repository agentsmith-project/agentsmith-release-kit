import crypto from 'node:crypto';
import path from 'node:path';

import { validateSubstrateResourceList } from './substrate-install-input-validation.mjs';

export function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

export function digestText(value) {
  return digestBuffer(Buffer.from(value));
}

export function canonicalApplyResourceListBytes(resources) {
  return Buffer.from(`${JSON.stringify(
    {
      apiVersion: 'v1',
      kind: 'List',
      items: resources
    },
    null,
    2
  )}\n`);
}

export function installParametersDigest({
  installInputDigest,
  resourceListDigest,
  applyResourceListDigest,
  effectiveNamespace
}) {
  return digestText(
    [
      'agentsmith.substrate-install-parameters/v1',
      `substrate_install_inputs=${installInputDigest}`,
      `resource_list=${resourceListDigest}`,
      `apply_resource_list=${applyResourceListDigest}`,
      `effective_namespace=${effectiveNamespace}`
    ].join('\n')
  );
}

function readInputDigest(input, label, fail) {
  const digest = input.inputDigest ?? input.sha256;
  if (typeof digest !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(digest)) {
    fail(`${label} input digest is required`);
  }
  return digest;
}

async function loadInstallResources({ installInput, installSummary, readJson, fail }) {
  if (installSummary.resources) {
    const applyResourceListBytes = canonicalApplyResourceListBytes(installSummary.resources);
    return {
      resources: installSummary.resources,
      resourceListDigest: digestBuffer(applyResourceListBytes),
      resourceSource: 'inline'
    };
  }

  const resourceListFile = path.join(
    path.dirname(installInput.file),
    installSummary.resourceListPath
  );
  const resourceListInput = await readJson(resourceListFile, 'substrate install resource list');
  return {
    resources: validateSubstrateResourceList(resourceListInput.value, {
      fail,
      label: 'substrate_resource_list',
      raw: resourceListInput.raw
    }),
    resourceListDigest: readInputDigest(resourceListInput, 'substrate install resource list', fail),
    resourceSource: 'resource_list_path',
    resourceListPath: installSummary.resourceListPath
  };
}

export async function resolveSubstrateInstallParameters({
  installInput,
  installSummary,
  namespace,
  readJson,
  fail
}) {
  const resourceListBinding = await loadInstallResources({
    installInput,
    installSummary,
    readJson,
    fail
  });
  const applyResourceListBytes = canonicalApplyResourceListBytes(resourceListBinding.resources);
  const applyResourceListDigest = digestBuffer(applyResourceListBytes);
  const effectiveNamespace = namespace;
  const installInputDigest = readInputDigest(installInput, 'substrate_install_inputs', fail);
  return {
    ...resourceListBinding,
    applyResourceListBytes,
    applyResourceListDigest,
    effectiveNamespace,
    installParametersDigest: installParametersDigest({
      installInputDigest,
      resourceListDigest: resourceListBinding.resourceListDigest,
      applyResourceListDigest,
      effectiveNamespace
    })
  };
}
