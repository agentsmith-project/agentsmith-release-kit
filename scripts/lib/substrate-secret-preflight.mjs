import { spawnSync } from 'node:child_process';

import { requiredSubstrateSecretKeyRefs } from './substrate-truth-validation.mjs';

const SECRET_REF_PREFIX = 'secretRef:';
const ASBCP_SERVICE_ACCOUNT = 'agentsmith-sandbox-control-plane';
const ASBCP_REQUIRED_PV_VERBS = [
  'get',
  'list',
  'watch',
  'create',
  'update',
  'patch',
  'delete'
];
const KUBERNETES_NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const KUBERNETES_SECRET_NAME_RE = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;
const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function failWith(fail, message) {
  if (fail) {
    fail(message);
  }
  throw new Error(message);
}

function formatMissing(ref, key) {
  return `required substrate Secret key missing: ${ref} key ${key} decoded_length=missing`;
}

function formatEmpty(ref, key) {
  return `required substrate Secret key empty: ${ref} key ${key} decoded_length=empty`;
}

function parseSecretRef(ref) {
  if (typeof ref !== 'string' || !ref.startsWith(SECRET_REF_PREFIX)) {
    return undefined;
  }
  const body = ref.slice(SECRET_REF_PREFIX.length);
  const parts = body.split('/');
  if (parts.length !== 2) {
    return undefined;
  }
  const [namespace, name] = parts;
  if (!KUBERNETES_NAMESPACE_RE.test(namespace) || !KUBERNETES_SECRET_NAME_RE.test(name)) {
    return undefined;
  }
  return { namespace, name };
}

function kubectlPrefixArgs({ kubeconfig, context }) {
  const prefix = [];
  if (kubeconfig) {
    prefix.push('--kubeconfig', kubeconfig);
  }
  if (context) {
    prefix.push('--context', context);
  }
  return prefix;
}

function decodedLength(encoded) {
  if (typeof encoded !== 'string' || encoded.trim() !== encoded || !BASE64_RE.test(encoded)) {
    return undefined;
  }
  return Buffer.from(encoded, 'base64').length;
}

function runKubectlGetSecret({ kubectl, kubeconfig, context, parsedRef }) {
  return spawnSync(
    kubectl,
    [
      ...kubectlPrefixArgs({ kubeconfig, context }),
      'get',
      'secret',
      parsedRef.name,
      '--namespace',
      parsedRef.namespace,
      '-o',
      'json'
    ],
    {
      encoding: 'utf8',
      maxBuffer: 1024 * 1024,
      env: process.env
    }
  );
}

function runKubectlAuthCanI({ kubectl, kubeconfig, context, namespace, verb }) {
  return spawnSync(
    kubectl,
    [
      ...kubectlPrefixArgs({ kubeconfig, context }),
      'auth',
      'can-i',
      verb,
      'persistentvolumes',
      '--as',
      `system:serviceaccount:${namespace}:${ASBCP_SERVICE_ACCOUNT}`
    ],
    {
      encoding: 'utf8',
      maxBuffer: 1024 * 1024,
      env: process.env
    }
  );
}

function parseSecretJson(stdout) {
  const value = JSON.parse(stdout);
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const data = value.data;
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return undefined;
  }
  return data;
}

export function assertLiveRequiredSubstrateSecrets({
  substrateTruth,
  kubectl = 'kubectl',
  kubeconfig,
  context,
  fail
}) {
  const byRef = new Map();
  for (const requirement of requiredSubstrateSecretKeyRefs(substrateTruth)) {
    if (!byRef.has(requirement.ref)) {
      byRef.set(requirement.ref, []);
    }
    byRef.get(requirement.ref).push(requirement.key);
  }

  for (const [ref, keys] of byRef.entries()) {
    const parsedRef = parseSecretRef(ref);
    if (!parsedRef) {
      failWith(fail, formatMissing(ref, keys[0]));
    }

    const result = runKubectlGetSecret({ kubectl, kubeconfig, context, parsedRef });
    if (result.error || result.status !== 0) {
      failWith(fail, formatMissing(ref, keys[0]));
    }

    let data;
    try {
      data = parseSecretJson(result.stdout || '');
    } catch {
      failWith(fail, formatMissing(ref, keys[0]));
    }
    if (!data) {
      failWith(fail, formatMissing(ref, keys[0]));
    }

    for (const key of keys) {
      if (!Object.hasOwn(data, key)) {
        failWith(fail, formatMissing(ref, key));
      }
      const length = decodedLength(data[key]);
      if (length === undefined) {
        failWith(fail, formatMissing(ref, key));
      }
      if (length === 0) {
        failWith(fail, formatEmpty(ref, key));
      }
    }
  }
}

export function assertLiveAsbcpPersistentVolumeRbac({
  namespace,
  kubectl = 'kubectl',
  kubeconfig,
  context,
  fail
}) {
  if (typeof namespace !== 'string' || !KUBERNETES_NAMESPACE_RE.test(namespace)) {
    failWith(fail, 'namespace must be a Kubernetes namespace name before ASBCP PV RBAC preflight');
  }

  const serviceAccount = `system:serviceaccount:${namespace}:${ASBCP_SERVICE_ACCOUNT}`;
  for (const verb of ASBCP_REQUIRED_PV_VERBS) {
    const result = runKubectlAuthCanI({
      kubectl,
      kubeconfig,
      context,
      namespace,
      verb
    });
    const allowed = !result.error && result.status === 0 && (result.stdout || '').trim().toLowerCase() === 'yes';
    if (!allowed) {
      failWith(
        fail,
        `${serviceAccount} must be able to ${verb} persistentvolumes before product smoke`
      );
    }
  }
}
