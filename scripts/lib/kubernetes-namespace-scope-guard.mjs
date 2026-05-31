export const K8S_KIT_OWNER_LABEL = 'app.kubernetes.io/managed-by';
export const K8S_KIT_OWNER_ANNOTATION = 'agentsmith.io/managed-by';
export const K8S_KIT_INSTALLATION_ID_ANNOTATION = 'agentsmith.io/installation-id';
export const K8S_KIT_OWNER_VALUE = 'agentsmith-release-kit';

export const NAMESPACE_SCOPED_RESOURCE_ALLOWLIST = new Map([
  ['v1|Service', {
    apiVersion: 'v1',
    group: '',
    kind: 'Service',
    resource: 'services'
  }],
  ['v1|ConfigMap', {
    apiVersion: 'v1',
    group: '',
    kind: 'ConfigMap',
    resource: 'configmaps'
  }],
  ['networking.k8s.io/v1|NetworkPolicy', {
    apiVersion: 'networking.k8s.io/v1',
    group: 'networking.k8s.io',
    kind: 'NetworkPolicy',
    resource: 'networkpolicies.networking.k8s.io'
  }]
]);

const CLUSTER_SCOPED_KIND_DENYLIST = new Set([
  'APIService',
  'ClusterRole',
  'ClusterRoleBinding',
  'CustomResourceDefinition',
  'IngressClass',
  'MutatingWebhookConfiguration',
  'Namespace',
  'PersistentVolume',
  'PriorityClass',
  'RuntimeClass',
  'StorageClass',
  'ValidatingWebhookConfiguration',
  'VolumeSnapshotClass'
]);
const KUBERNETES_OBJECT_NAME_RE =
  /^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$/;
const ALLOWED_SERVICE_TYPES = new Set(['ClusterIP']);
const FORBIDDEN_CLUSTER_IP_SERVICE_FIELDS = [
  'externalIPs',
  'loadBalancerIP',
  'loadBalancerClass',
  'externalName',
  'healthCheckNodePort'
];

function defaultFail(message) {
  throw new Error(message);
}

function requireObject(value, label, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireArray(value, label, fail) {
  if (!Array.isArray(value)) {
    fail(`${label} must be an array`);
  }
  return value;
}

function requireString(value, label, fail) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function metadataFor(resource, label, fail) {
  return requireObject(resource.metadata, `${label}.metadata`, fail);
}

function assertKubernetesObjectName(value, label, fail) {
  const name = requireString(value, label, fail);
  if (
    name !== name.trim() ||
    name.startsWith('--') ||
    name.length > 253 ||
    !KUBERNETES_OBJECT_NAME_RE.test(name)
  ) {
    fail(`${label} must be a Kubernetes resource name`);
  }
  return name;
}

function resourceListItems(value, label, fail) {
  if (Array.isArray(value)) {
    return value;
  }

  const object = requireObject(value, label, fail);
  if (object.kind === 'List' || Array.isArray(object.items)) {
    return requireArray(object.items, `${label}.items`, fail);
  }

  return [object];
}

export function flattenKubernetesResources(value, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'resources';
  const resources = [];

  for (const [index, resource] of resourceListItems(value, label, fail).entries()) {
    const itemLabel = `${label}[${index}]`;
    const object = requireObject(resource, itemLabel, fail);
    if (object.kind === 'List' || Array.isArray(object.items)) {
      resources.push(
        ...flattenKubernetesResources(object, {
          fail,
          label: itemLabel
        })
      );
      continue;
    }
    resources.push(object);
  }

  if (resources.length === 0) {
    fail(`${label} must not be empty`);
  }
  return resources;
}

function allowlistKey(apiVersion, kind) {
  return `${apiVersion}|${kind}`;
}

function assertAllowedResource(apiVersion, kind, label, fail) {
  if (kind === 'Secret') {
    fail(`${label}.kind Secret is not allowed for substrate install; use secret refs only and do not include Secret payload resources`);
  }
  if (CLUSTER_SCOPED_KIND_DENYLIST.has(kind)) {
    fail(`${label}.kind ${kind} is cluster-scoped and not allowed for substrate install`);
  }
  const identity = NAMESPACE_SCOPED_RESOURCE_ALLOWLIST.get(allowlistKey(apiVersion, kind));
  if (!identity) {
    fail(`${label}.apiVersion ${apiVersion} with kind ${kind} is not in the namespace-scoped substrate install allowlist`);
  }
  return identity;
}

function assertAllowedServiceType(resource, label, fail) {
  if (resource.apiVersion !== 'v1' || resource.kind !== 'Service') {
    return;
  }

  const spec = resource.spec;
  if (spec === undefined || spec === null) {
    return;
  }
  if (typeof spec !== 'object' || Array.isArray(spec)) {
    fail(`${label}.spec must be an object when provided`);
  }
  if (Object.prototype.hasOwnProperty.call(spec, 'type')) {
    const serviceType = spec.type;
    if (!ALLOWED_SERVICE_TYPES.has(serviceType)) {
      fail(`${label}.spec.type must be omitted or ClusterIP for substrate install; Service type ${String(serviceType)} is not allowed`);
    }
  }
  for (const field of FORBIDDEN_CLUSTER_IP_SERVICE_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(spec, field)) {
      fail(`${label}.spec.${field} is not allowed for substrate install ClusterIP Service`);
    }
  }
}

export function validateNamespaceScopedResources(resources, namespace, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'resources';
  const expectedInstallationId = options.installationId;
  const refs = [];

  for (const [index, resource] of resources.entries()) {
    const itemLabel = `${label}[${index}]`;
    const apiVersion = requireString(resource.apiVersion, `${itemLabel}.apiVersion`, fail);
    const kind = requireString(resource.kind, `${itemLabel}.kind`, fail);
    const identity = assertAllowedResource(apiVersion, kind, itemLabel, fail);
    assertAllowedServiceType(resource, itemLabel, fail);

    const metadata = metadataFor(resource, itemLabel, fail);
    const name = assertKubernetesObjectName(
      metadata.name,
      `${itemLabel}.metadata.name`,
      fail
    );
    if (Object.prototype.hasOwnProperty.call(metadata, 'generateName')) {
      fail(`${itemLabel}.metadata.generateName is not allowed; use stable metadata.name`);
    }

    const resourceNamespace = metadata.namespace;
    if (
      resourceNamespace !== undefined &&
      resourceNamespace !== null &&
      resourceNamespace !== '' &&
      resourceNamespace !== namespace
    ) {
      fail(`${itemLabel}.metadata.namespace must be empty or ${namespace}`);
    }
    if (!isKitOwnedResource(resource)) {
      fail(`${itemLabel} must include agentsmith-release-kit ownership label, ownership annotation, and matching installation id annotation`);
    }
    if (!isKitOwnedResource(resource, { installationId: expectedInstallationId })) {
      fail(`${itemLabel} ownership installation id must match substrate install inputs`);
    }

    refs.push({
      apiVersion,
      group: identity.group,
      kind,
      resource: identity.resource,
      name,
      namespace,
      document_index: index + 1
    });
  }

  return refs;
}

export function resourceRefForKubectl(resource, namespace) {
  const apiVersion = requireString(resource?.apiVersion, 'resource.apiVersion', defaultFail);
  const kind = requireString(resource?.kind, 'resource.kind', defaultFail);
  const identity = assertAllowedResource(apiVersion, kind, 'resource', defaultFail);
  assertAllowedServiceType(resource, 'resource', defaultFail);
  const metadata = metadataFor(resource, 'resource', defaultFail);
  const name = assertKubernetesObjectName(
    metadata.name,
    'resource.metadata.name',
    defaultFail
  );
  return {
    apiVersion,
    group: identity.group,
    kind,
    resource: identity.resource,
    name,
    namespace
  };
}

export function formatResourceRef(ref) {
  return `${ref.resource}/${ref.name} apiVersion=${ref.apiVersion} namespace=${ref.namespace}`;
}

export function isKitOwnedResource(resource, options = {}) {
  const metadata = resource?.metadata;
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return false;
  }
  const labels = metadata.labels;
  const annotations = metadata.annotations;
  if (!labels || typeof labels !== 'object' || Array.isArray(labels)) {
    return false;
  }
  if (!annotations || typeof annotations !== 'object' || Array.isArray(annotations)) {
    return false;
  }
  if (labels[K8S_KIT_OWNER_LABEL] !== K8S_KIT_OWNER_VALUE) {
    return false;
  }
  if (annotations[K8S_KIT_OWNER_ANNOTATION] !== K8S_KIT_OWNER_VALUE) {
    return false;
  }
  const installationId = annotations[K8S_KIT_INSTALLATION_ID_ANNOTATION];
  if (options.installationId !== undefined) {
    return installationId === options.installationId;
  }
  return typeof installationId === 'string' && installationId.trim() !== '';
}
