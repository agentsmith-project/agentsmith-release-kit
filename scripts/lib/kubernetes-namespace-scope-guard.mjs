export const K8S_KIT_OWNER_LABEL = 'app.kubernetes.io/managed-by';
export const K8S_KIT_OWNER_ANNOTATION = 'agentsmith.io/managed-by';
export const K8S_KIT_INSTALLATION_ID_ANNOTATION = 'agentsmith.io/installation-id';
export const K8S_KIT_OWNER_VALUE = 'agentsmith-release-kit';

const NAMESPACE_SCOPED_RESOURCE_DEFINITIONS = [
  {
    apiVersion: 'v1',
    group: '',
    kind: 'Service',
    resource: 'services',
    kubectlResources: new Set(['service', 'services'])
  },
  {
    apiVersion: 'v1',
    group: '',
    kind: 'ConfigMap',
    resource: 'configmaps',
    kubectlResources: new Set(['configmap', 'configmaps'])
  },
  {
    apiVersion: 'networking.k8s.io/v1',
    group: 'networking.k8s.io',
    kind: 'NetworkPolicy',
    resource: 'networkpolicies.networking.k8s.io',
    kubectlResources: new Set([
      'networkpolicy',
      'networkpolicies',
      'networkpolicy.networking.k8s.io',
      'networkpolicies.networking.k8s.io'
    ])
  },
  {
    apiVersion: 'apps/v1',
    group: 'apps',
    kind: 'StatefulSet',
    resource: 'statefulsets.apps',
    kubectlResources: new Set(['statefulset', 'statefulsets', 'statefulset.apps', 'statefulsets.apps'])
  },
  {
    apiVersion: 'apps/v1',
    group: 'apps',
    kind: 'Deployment',
    resource: 'deployments.apps',
    kubectlResources: new Set(['deployment', 'deployments', 'deployment.apps', 'deployments.apps'])
  },
  {
    apiVersion: 'batch/v1',
    group: 'batch',
    kind: 'Job',
    resource: 'jobs.batch',
    kubectlResources: new Set(['job', 'jobs', 'job.batch', 'jobs.batch'])
  },
  {
    apiVersion: 'v1',
    group: '',
    kind: 'PersistentVolumeClaim',
    resource: 'persistentvolumeclaims',
    kubectlResources: new Set([
      'persistentvolumeclaim',
      'persistentvolumeclaims',
      'pvc',
      'pvcs'
    ])
  }
];

function allowlistKey(apiVersion, kind) {
  return `${apiVersion}|${kind}`;
}

export const NAMESPACE_SCOPED_RESOURCE_ALLOWLIST = new Map(
  NAMESPACE_SCOPED_RESOURCE_DEFINITIONS.map((identity) => [
    allowlistKey(identity.apiVersion, identity.kind),
    identity
  ])
);

export const SUBSTRATE_INSTALL_RESOURCE_ALLOWLIST_BY_KIND = new Map(
  NAMESPACE_SCOPED_RESOURCE_DEFINITIONS.map((identity) => [identity.kind, identity])
);

export function substrateInstallAllowedKindList() {
  return NAMESPACE_SCOPED_RESOURCE_DEFINITIONS.map((identity) => identity.kind).join(', ');
}

export function substrateInstallAllowedKubectlResourceList() {
  return NAMESPACE_SCOPED_RESOURCE_DEFINITIONS.flatMap((identity) => [
    ...identity.kubectlResources
  ]).join(', ');
}

export function imageRefsFromSubstratePackManifest(manifest, options = {}) {
  const fail = options.fail || defaultFail;
  const label = options.label || 'substrate_pack_manifest';
  const images = requireObject(manifest?.images, `${label}.images`, fail);
  return new Set(Object.values(images).map((image, index) =>
    requireString(image, `${label}.images[${index}]`, fail)
  ));
}

const WORKLOAD_IMAGE_KINDS = new Set(['Deployment', 'StatefulSet', 'Job']);
const IMAGE_DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const ALLOWED_SERVICE_TYPES = new Set(['ClusterIP']);
const FORBIDDEN_POD_SPEC_TRUE_FIELDS = ['hostNetwork', 'hostPID', 'hostIPC'];
const FORBIDDEN_POD_SPEC_FIELDS = ['serviceAccountName', 'serviceAccount'];
const FORBIDDEN_CLUSTER_IP_SERVICE_FIELDS = [
  'externalIPs',
  'loadBalancerIP',
  'loadBalancerClass',
  'externalName',
  'healthCheckNodePort'
];

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

function imageDigestSuffix(image, label, fail) {
  const value = requireString(image, label, fail);
  const marker = '@sha256:';
  const index = value.lastIndexOf(marker);
  if (index < 0) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const digest = `sha256:${value.slice(index + marker.length)}`;
  if (!IMAGE_DIGEST_RE.test(digest)) {
    fail(`${label} must include a sha256 digest`);
  }
  return digest;
}

function normalizeAllowedImages(value, label, fail) {
  if (value instanceof Set) {
    return value;
  }
  if (Array.isArray(value)) {
    return new Set(value.map((image, index) => requireString(image, `${label}[${index}]`, fail)));
  }
  return undefined;
}

function requireNonEmptyArray(value, label, fail) {
  const array = requireArray(value, label, fail);
  if (array.length === 0) {
    fail(`${label} must not be empty`);
  }
  return array;
}

function hasOwnField(object, field) {
  return Object.prototype.hasOwnProperty.call(object, field);
}

function assertContainerImages(containers, label, allowedImages, fail) {
  for (const [index, container] of containers.entries()) {
    const itemLabel = `${label}[${index}]`;
    const object = requireObject(container, itemLabel, fail);
    const image = requireString(object.image, `${itemLabel}.image`, fail);
    imageDigestSuffix(image, `${itemLabel}.image`, fail);
    if (!allowedImages.has(image)) {
      fail(`${itemLabel}.image must match an image declared in substrate_pack_manifest.images`);
    }
  }
}

function assertPodSpecDenylist(podSpec, label, fail) {
  for (const field of FORBIDDEN_POD_SPEC_TRUE_FIELDS) {
    if (podSpec[field] === true) {
      fail(`${label}.${field} true is not allowed for substrate install`);
    }
  }

  for (const field of FORBIDDEN_POD_SPEC_FIELDS) {
    if (hasOwnField(podSpec, field)) {
      fail(`${label}.${field} is not allowed for substrate install`);
    }
  }

  if (hasOwnField(podSpec, 'securityContext')) {
    const securityContext = requireObject(
      podSpec.securityContext,
      `${label}.securityContext`,
      fail
    );
    if (securityContext.privileged === true) {
      fail(`${label}.securityContext.privileged true is not allowed for substrate install`);
    }
  }

  if (hasOwnField(podSpec, 'volumes')) {
    for (const [index, volume] of requireArray(podSpec.volumes, `${label}.volumes`, fail).entries()) {
      const volumeLabel = `${label}.volumes[${index}]`;
      const object = requireObject(volume, volumeLabel, fail);
      if (hasOwnField(object, 'hostPath')) {
        fail(`${volumeLabel}.hostPath is not allowed for substrate install`);
      }
    }
  }
}

function assertContainerDenylist(containers, label, fail) {
  for (const [index, container] of containers.entries()) {
    const itemLabel = `${label}[${index}]`;
    const object = requireObject(container, itemLabel, fail);

    if (hasOwnField(object, 'securityContext')) {
      const securityContext = requireObject(
        object.securityContext,
        `${itemLabel}.securityContext`,
        fail
      );
      if (securityContext.privileged === true) {
        fail(`${itemLabel}.securityContext.privileged true is not allowed for substrate install`);
      }
      if (securityContext.allowPrivilegeEscalation === true) {
        fail(`${itemLabel}.securityContext.allowPrivilegeEscalation true is not allowed for substrate install`);
      }
      if (hasOwnField(securityContext, 'capabilities')) {
        const capabilities = requireObject(
          securityContext.capabilities,
          `${itemLabel}.securityContext.capabilities`,
          fail
        );
        if (
          hasOwnField(capabilities, 'add') &&
          requireArray(
            capabilities.add,
            `${itemLabel}.securityContext.capabilities.add`,
            fail
          ).length > 0
        ) {
          fail(`${itemLabel}.securityContext.capabilities.add must be empty or omitted for substrate install`);
        }
      }
    }

    if (hasOwnField(object, 'ports')) {
      for (const [portIndex, port] of requireArray(object.ports, `${itemLabel}.ports`, fail).entries()) {
        const portLabel = `${itemLabel}.ports[${portIndex}]`;
        const portObject = requireObject(port, portLabel, fail);
        if (hasOwnField(portObject, 'hostPort')) {
          fail(`${portLabel}.hostPort is not allowed for substrate install`);
        }
      }
    }
  }
}

function assertWorkloadImages(resource, label, options, fail) {
  if (!WORKLOAD_IMAGE_KINDS.has(resource.kind)) {
    return;
  }

  const allowedImages = normalizeAllowedImages(
    options.allowedImages,
    'substrate_pack_manifest.images',
    fail
  );
  if (!allowedImages || allowedImages.size === 0) {
    fail(`${label} requires substrate_pack_manifest.images to validate workload images`);
  }

  const spec = requireObject(resource.spec, `${label}.spec`, fail);
  const template = requireObject(spec.template, `${label}.spec.template`, fail);
  const podSpec = requireObject(template.spec, `${label}.spec.template.spec`, fail);
  assertPodSpecDenylist(podSpec, `${label}.spec.template.spec`, fail);
  const containers = requireNonEmptyArray(
    podSpec.containers,
    `${label}.spec.template.spec.containers`,
    fail
  );
  assertContainerImages(
    containers,
    `${label}.spec.template.spec.containers`,
    allowedImages,
    fail
  );
  assertContainerDenylist(
    containers,
    `${label}.spec.template.spec.containers`,
    fail
  );
  if (Object.prototype.hasOwnProperty.call(podSpec, 'initContainers')) {
    const initContainers = requireArray(
      podSpec.initContainers,
      `${label}.spec.template.spec.initContainers`,
      fail
    );
    assertContainerImages(
      initContainers,
      `${label}.spec.template.spec.initContainers`,
      allowedImages,
      fail
    );
    assertContainerDenylist(
      initContainers,
      `${label}.spec.template.spec.initContainers`,
      fail
    );
  }
}

function assertPersistentVolumeClaim(resource, label, options, fail) {
  if (resource.apiVersion !== 'v1' || resource.kind !== 'PersistentVolumeClaim') {
    return;
  }
  const spec = requireObject(resource.spec, `${label}.spec`, fail);
  if (!Object.prototype.hasOwnProperty.call(spec, 'storageClassName')) {
    return;
  }
  const storageClassName = requireString(spec.storageClassName, `${label}.spec.storageClassName`, fail);
  if (
    options.storageClassName !== undefined &&
    storageClassName !== options.storageClassName
  ) {
    fail(`${label}.spec.storageClassName must match target_prerequisites.storage.storage_class`);
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
    assertWorkloadImages(resource, itemLabel, options, fail);
    assertPersistentVolumeClaim(resource, itemLabel, options, fail);

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
