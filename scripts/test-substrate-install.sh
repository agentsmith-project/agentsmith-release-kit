#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
ONLINE_TARGET_PROFILE="existing_kubernetes/kit_installed/online"
AIRGAP_TARGET_PROFILE="existing_kubernetes/kit_installed/airgap"
TARGET_PROFILE="$ONLINE_TARGET_PROFILE"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_TEMPLATE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

install_parameters_digest() {
  local namespace="${2:-agentsmith}"
  "$NODE_BIN" --input-type=module - "$1" "$namespace" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [installInputsFile, namespace] = process.argv.slice(2);
const installInputBytes = fs.readFileSync(installInputsFile);
const installInputs = JSON.parse(installInputBytes.toString('utf8'));
const digest = (buffer) => `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
function flatten(value) {
  if (Array.isArray(value)) {
    return value.flatMap((item) => flatten(item));
  }
  if (value && typeof value === 'object' && (value.kind === 'List' || Array.isArray(value.items))) {
    return flatten(value.items);
  }
  return [value];
}
function canonicalApplyBytes(resources) {
  return Buffer.from(`${JSON.stringify({
    apiVersion: 'v1',
    kind: 'List',
    items: resources
  }, null, 2)}\n`);
}
let resourceListDigest;
let resources;
if (Object.prototype.hasOwnProperty.call(installInputs, 'resources')) {
  resources = flatten(installInputs.resources);
  resourceListDigest = digest(canonicalApplyBytes(resources));
} else if (typeof installInputs.resource_list_path === 'string') {
  const resourceListBytes = fs.readFileSync(path.join(
    path.dirname(installInputsFile),
    installInputs.resource_list_path
  ));
  resources = flatten(JSON.parse(resourceListBytes.toString('utf8')));
  resourceListDigest = digest(resourceListBytes);
} else {
  throw new Error('install inputs must include resources or resource_list_path');
}
const applyResourceListDigest = digest(canonicalApplyBytes(resources));
process.stdout.write(digest(Buffer.from([
  'agentsmith.substrate-install-parameters/v1',
  `substrate_install_inputs=${digest(installInputBytes)}`,
  `resource_list=${resourceListDigest}`,
  `apply_resource_list=${applyResourceListDigest}`,
  `effective_namespace=${namespace}`
].join('\n'))));
NODE
}

write_fixture_set() {
  local dir="$1"
  local mutation="${2:-valid}"
  local profile="${3:-$TARGET_PROFILE}"

  "$NODE_BIN" --input-type=module - "$dir" "$profile" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [outDir, profile, mutation] = process.argv.slice(2);
const [targetCluster, substrateSource, distribution] = profile.split('/');
const digest = (char) => `sha256:${char.repeat(64)}`;
const image = (name, tag, char) =>
  `ghcr.io/agentsmith-project/substrates/${name}:${tag}@${digest(char)}`;
const ownerLabels = {
  'app.kubernetes.io/managed-by': 'agentsmith-release-kit',
  'app.kubernetes.io/part-of': 'agentsmith-substrate'
};
const ownerAnnotations = {
  'agentsmith.io/managed-by': 'agentsmith-release-kit',
  'agentsmith.io/installation-id': 'kit-install-10001'
};

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function writePackText(relativePath, content) {
  const file = path.join(outDir, relativePath);
  const bytes = Buffer.from(content);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return digestBuffer(bytes);
}

function writePackJson(relativePath, value) {
  return writePackText(relativePath, `${JSON.stringify(value, null, 2)}\n`);
}

function service(name, host) {
  return {
    host,
    credential_secret_ref: `secretRef:release/${name}-credential`,
    tls: {
      mode: 'verify-full',
      ca_secret_ref: `secretRef:release/${name}-ca`
    },
    reachability: {
      status: 'declared_reachable',
      proof: `operator ${name} tcp/tls check 2026-05-31T12:00:00Z`
    }
  };
}

function serviceResource(serviceType, extraSpec = {}) {
  const spec = {
    selector: {
      'app.kubernetes.io/name': 'agentsmith-substrate'
    },
    ports: [
      {
        name: 'http',
        port: 80,
        targetPort: 80
      }
    ]
  };

  if (serviceType !== undefined) {
    spec.type = serviceType;
  }
  if (serviceType === 'ExternalName') {
    delete spec.selector;
    spec.externalName = 'substrate.release.example.internal';
  }
  Object.assign(spec, extraSpec);

  return {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name: 'agentsmith-substrate-service',
      namespace: 'agentsmith',
      labels: ownerLabels,
      annotations: ownerAnnotations
    },
    spec
  };
}

const substrateTruth = {
  schema_version: 'agentsmith.substrate-connection.truth/v1',
  target_cluster: targetCluster,
  substrate_source: substrateSource,
  distribution,
  declared_at: '2026-05-31T12:00:00.000Z',
  declared_by: 'release-operator@example.com',
  installed_by: 'agentsmith-release-kit',
  release_kit_version: '0.1.0',
  installation_id: 'kit-install-10001',
  services: {
    postgresql: {
      ...service('postgresql', 'postgresql.release.example.internal'),
      port: 5432,
      database: 'appdb',
      admin_secret_ref: 'secretRef:release/postgresql-admin',
      sslmode: 'verify-full',
      extensions: {
        pgvector: {
          status: 'installed',
          version: '0.7.4'
        }
      }
    },
    mongodb: {
      ...service('mongodb', 'mongodb.release.example.internal'),
      port: 27017
    },
    redis: {
      ...service('redis', 'redis.release.example.internal'),
      port: 6379
    },
    object_storage: {
      url: 'https://objects.release.example.internal',
      bucket: 'release-artifacts',
      region: 'us-west-2',
      credential_secret_ref: 'secretRef:release/object-storage-credential',
      tls: {
        mode: 'https',
        ca_secret_ref: 'secretRef:release/object-storage-ca'
      },
      reachability: {
        status: 'declared_reachable',
        proof: 'operator bucket head-object check 2026-05-31T12:00:00Z'
      }
    },
    oidc: {
      issuer_url: 'https://keycloak.release.example.com/realms/app',
      client_id: 'app-web',
      client_secret_ref: 'secretRef:release/oidc-client',
      tls: {
        mode: 'https',
        ca_secret_ref: 'secretRef:release/oidc-ca'
      },
      reachability: {
        status: 'declared_reachable',
        proof: 'operator oidc discovery check 2026-05-31T12:00:00Z'
      }
    }
  }
};
if (mutation === 'installation_id_mismatch') {
  substrateTruth.installation_id = 'other-installation';
}
if (mutation === 'operator_facing_install_inputs') {
  delete substrateTruth.target_cluster;
  delete substrateTruth.substrate_source;
  delete substrateTruth.distribution;
}

const installPlanDigest = writePackJson('payload/install-substrates.json', {
  schema_version: 'agentsmith.substrate-install-plan.fixture/v1',
  target_profile: profile,
  installation_id: 'kit-install-10001',
  resources: ['postgresql', 'mongodb', 'redis', 'object_storage', 'oidc']
});
writePackText('templates/postgresql.yaml', 'kind: StatefulSet\nmetadata:\n  name: postgresql\n');
writePackText('templates/mongodb.yaml', 'kind: StatefulSet\nmetadata:\n  name: mongodb\n');
writePackText('templates/redis.yaml', 'kind: Deployment\nmetadata:\n  name: redis\n');
writePackText('templates/object-storage.yaml', 'kind: Deployment\nmetadata:\n  name: object-storage\n');
writePackText('templates/oidc.yaml', 'kind: Deployment\nmetadata:\n  name: oidc\n');
const checksDigest = writePackText(
  'tools/substrate-checks.txt',
  'postgresql tls\nmongodb tls\nredis ping\nobject-storage head-bucket\noidc discovery\n'
);

const manifest = {
  schema_version: 'agentsmith.substrate-pack-manifest/v1',
  release_kit_version: '0.1.0',
  installed_by: 'agentsmith-release-kit',
  target_profile: profile,
  images: {
    postgresql: image('postgresql', '16.3', '1'),
    mongodb: image('mongodb', '7.0', '2'),
    redis: image('redis', '7.2', '3'),
    object_storage: image('object-storage', '2026.05', '4'),
    oidc: image('keycloak', '25.0', '5')
  },
  payload: {
    install_plan: {
      path: 'payload/install-substrates.json',
      sha256: installPlanDigest
    }
  },
  templates: {
    postgresql: 'templates/postgresql.yaml',
    mongodb: 'templates/mongodb.yaml',
    redis: 'templates/redis.yaml',
    object_storage: 'templates/object-storage.yaml',
    oidc: 'templates/oidc.yaml'
  },
  tools: {
    checks: {
      path: 'tools/substrate-checks.txt',
      sha256: checksDigest
    }
  },
  checksums: {
    manifest: digest('8')
  }
};
if (mutation === 'operator_facing_pack_manifest' || mutation === 'operator_facing_pack_manifest_mismatch') {
  const deploymentPath = profile.endsWith('/airgap')
    ? 'airgap/install_substrates'
    : 'online/install_substrates';
  manifest.deployment_path = mutation === 'operator_facing_pack_manifest_mismatch'
    ? (deploymentPath === 'online/install_substrates' ? 'airgap/install_substrates' : 'online/install_substrates')
    : deploymentPath;
  delete manifest.target_profile;
}
if (mutation === 'pack_missing_material') {
  fs.rmSync(path.join(outDir, 'payload/install-substrates.json'), { force: true });
}
if (mutation === 'pack_material_sha_mismatch') {
  manifest.payload.install_plan.sha256 = digest('9');
}

function kitMetadata(name) {
  return {
    name,
    namespace: 'agentsmith',
    labels: ownerLabels,
    annotations: ownerAnnotations
  };
}

function configMapResource() {
  return {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: kitMetadata('agentsmith-substrate-config'),
    data: {
      installation_id: 'kit-install-10001',
      profile
    }
  };
}

function networkPolicyResource() {
  return {
    apiVersion: 'networking.k8s.io/v1',
    kind: 'NetworkPolicy',
    metadata: kitMetadata('agentsmith-substrate-network'),
    spec: {
      podSelector: {},
      policyTypes: ['Ingress']
    }
  };
}

function workloadLabels(name) {
  return {
    'app.kubernetes.io/name': name,
    'app.kubernetes.io/part-of': 'agentsmith-substrate'
  };
}

function podTemplate(name, containerName, imageRef) {
  const labels = workloadLabels(name);
  return {
    metadata: {
      labels
    },
    spec: {
      containers: [
        {
          name: containerName,
          image: imageRef
        }
      ]
    }
  };
}

function deploymentResource(imageRef = manifest.images.postgresql) {
  const name = 'agentsmith-substrate-postgresql';
  const labels = workloadLabels(name);
  return {
    apiVersion: 'apps/v1',
    kind: 'Deployment',
    metadata: kitMetadata(name),
    spec: {
      replicas: 1,
      selector: {
        matchLabels: labels
      },
      template: podTemplate(name, 'postgresql', imageRef)
    }
  };
}

function statefulSetResource(imageRef = manifest.images.mongodb) {
  const name = 'agentsmith-substrate-mongodb';
  const labels = workloadLabels(name);
  return {
    apiVersion: 'apps/v1',
    kind: 'StatefulSet',
    metadata: kitMetadata(name),
    spec: {
      serviceName: 'agentsmith-substrate-service',
      replicas: 1,
      selector: {
        matchLabels: labels
      },
      template: podTemplate(name, 'mongodb', imageRef)
    }
  };
}

function jobResource(imageRef = manifest.images.redis) {
  return {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: kitMetadata('agentsmith-substrate-installer'),
    spec: {
      template: {
        ...podTemplate('agentsmith-substrate-installer', 'installer', imageRef),
        spec: {
          ...podTemplate('agentsmith-substrate-installer', 'installer', imageRef).spec,
          restartPolicy: 'Never'
        }
      }
    }
  };
}

function pvcResource(storageClassName = 'gp3') {
  return {
    apiVersion: 'v1',
    kind: 'PersistentVolumeClaim',
    metadata: kitMetadata('agentsmith-substrate-postgresql-data'),
    spec: {
      storageClassName,
      accessModes: ['ReadWriteOnce'],
      resources: {
        requests: {
          storage: '1Gi'
        }
      }
    }
  };
}

function setPodSpecField(resource, field, value) {
  resource.spec.template.spec[field] = value;
  return resource;
}

function mutateFirstContainer(resource, mutate) {
  mutate(resource.spec.template.spec.containers[0]);
  return resource;
}

function addInitContainer(resource, extraFields) {
  resource.spec.template.spec.initContainers = [
    {
      name: 'init-substrate',
      image: manifest.images.redis,
      ...extraFields
    }
  ];
  return resource;
}

let resources = [
  configMapResource(),
  serviceResource('ClusterIP'),
  networkPolicyResource(),
  deploymentResource(),
  statefulSetResource(),
  jobResource(),
  pvcResource()
];

if (mutation === 'cluster_scoped_manifest') {
  resources = [
    {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: {
        name: 'agentsmith'
      }
    }
  ];
}
if (mutation === 'deployment_manifest') {
  resources = [deploymentResource()];
}
if (mutation === 'statefulset_manifest') {
  resources = [statefulSetResource()];
}
if (mutation === 'unknown_deployment_api_version') {
  resources = [
    {
      apiVersion: 'evil.example/v1',
      kind: 'Deployment',
      metadata: {
        name: 'agentsmith-substrate-postgresql',
        namespace: 'agentsmith',
        labels: ownerLabels,
        annotations: ownerAnnotations
      }
    }
  ];
}
if (mutation === 'unknown_workload_image') {
  resources = [deploymentResource(image('postgresql-extra', '16.3', '9'))];
}
if (mutation === 'tag_only_workload_image') {
  resources = [deploymentResource('ghcr.io/agentsmith-project/substrates/postgresql:16.3')];
}
if (mutation === 'digest_drift_workload_image') {
  resources = [deploymentResource(image('postgresql', '16.3', '9'))];
}
if (mutation === 'workload_host_network') {
  resources = [setPodSpecField(deploymentResource(), 'hostNetwork', true)];
}
if (mutation === 'workload_host_pid') {
  resources = [setPodSpecField(statefulSetResource(), 'hostPID', true)];
}
if (mutation === 'workload_host_ipc') {
  resources = [setPodSpecField(jobResource(), 'hostIPC', true)];
}
if (mutation === 'workload_host_path_volume') {
  resources = [
    setPodSpecField(deploymentResource(), 'volumes', [
      {
        name: 'host-docker-sock',
        hostPath: {
          type: 'Directory'
        }
      }
    ])
  ];
}
if (mutation === 'workload_service_account_name') {
  resources = [setPodSpecField(jobResource(), 'serviceAccountName', 'substrate-installer')];
}
if (mutation === 'workload_service_account') {
  resources = [setPodSpecField(deploymentResource(), 'serviceAccount', 'substrate-installer')];
}
if (mutation === 'workload_pod_privileged') {
  resources = [
    setPodSpecField(deploymentResource(), 'securityContext', {
      privileged: true
    })
  ];
}
if (mutation === 'workload_container_privileged') {
  resources = [
    mutateFirstContainer(deploymentResource(), (container) => {
      container.securityContext = {
        privileged: true
      };
    })
  ];
}
if (mutation === 'workload_allow_privilege_escalation') {
  resources = [
    mutateFirstContainer(deploymentResource(), (container) => {
      container.securityContext = {
        allowPrivilegeEscalation: true
      };
    })
  ];
}
if (mutation === 'workload_capabilities_add') {
  resources = [
    mutateFirstContainer(deploymentResource(), (container) => {
      container.securityContext = {
        capabilities: {
          add: ['NET_ADMIN']
        }
      };
    })
  ];
}
if (mutation === 'workload_host_port') {
  resources = [
    mutateFirstContainer(deploymentResource(), (container) => {
      container.ports = [
        {
          name: 'postgresql',
          containerPort: 5432,
          hostPort: 5432
        }
      ];
    })
  ];
}
if (mutation === 'workload_init_container_privileged') {
  resources = [
    addInitContainer(deploymentResource(), {
      securityContext: {
        privileged: true
      }
    })
  ];
}
if (mutation === 'daemonset_manifest') {
  resources = [
    {
      apiVersion: 'apps/v1',
      kind: 'DaemonSet',
      metadata: kitMetadata('agentsmith-substrate-daemon')
    }
  ];
}
if (mutation === 'cronjob_manifest') {
  resources = [
    {
      apiVersion: 'batch/v1',
      kind: 'CronJob',
      metadata: kitMetadata('agentsmith-substrate-cron')
    }
  ];
}
if (mutation === 'pod_manifest') {
  resources = [
    {
      apiVersion: 'v1',
      kind: 'Pod',
      metadata: kitMetadata('agentsmith-substrate-pod')
    }
  ];
}
if (mutation === 'replicaset_manifest') {
  resources = [
    {
      apiVersion: 'apps/v1',
      kind: 'ReplicaSet',
      metadata: kitMetadata('agentsmith-substrate-replicaset')
    }
  ];
}
if (mutation === 'cluster_ip_service') {
  resources = [serviceResource('ClusterIP')];
}
if (mutation === 'service_node_port') {
  resources = [serviceResource('NodePort')];
}
if (mutation === 'service_load_balancer') {
  resources = [serviceResource('LoadBalancer')];
}
if (mutation === 'service_external_name') {
  resources = [serviceResource('ExternalName')];
}
if (mutation === 'service_external_ips') {
  resources = [serviceResource('ClusterIP', { externalIPs: ['203.0.113.10'] })];
}
if (mutation === 'service_load_balancer_ip') {
  resources = [serviceResource('ClusterIP', { loadBalancerIP: '203.0.113.11' })];
}
if (mutation === 'service_load_balancer_class') {
  resources = [serviceResource('ClusterIP', { loadBalancerClass: 'example.com/lb' })];
}
if (mutation === 'service_external_name_field') {
  resources = [serviceResource('ClusterIP', { externalName: 'substrate.release.example.internal' })];
}
if (mutation === 'service_health_check_node_port') {
  resources = [serviceResource('ClusterIP', { healthCheckNodePort: 32080 })];
}
if (mutation === 'pvc_manifest') {
  resources = [pvcResource()];
}
if (mutation === 'secret_manifest') {
  resources = [
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'agentsmith-substrate-secret-payload',
        namespace: 'agentsmith',
        labels: ownerLabels,
        annotations: ownerAnnotations
      },
      type: 'Opaque',
      data: {
        config: 'dmFsdWU='
      },
      stringData: {
        config_text: 'fixture-value'
      }
    }
  ];
}
if (mutation === 'job_manifest') {
  resources = [jobResource()];
}
if (mutation === 'service_account_manifest') {
  resources = [
    {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: {
        name: 'agentsmith-substrate-installer',
        namespace: 'agentsmith',
        labels: ownerLabels,
        annotations: ownerAnnotations
      }
    }
  ];
}
if (mutation === 'role_manifest') {
  resources = [
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'Role',
      metadata: {
        name: 'agentsmith-substrate-installer',
        namespace: 'agentsmith',
        labels: ownerLabels,
        annotations: ownerAnnotations
      },
      rules: [
        {
          apiGroups: [''],
          resources: ['secrets', 'persistentvolumeclaims'],
          verbs: ['create']
        }
      ]
    }
  ];
}
if (mutation === 'role_binding_manifest') {
  resources = [
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'RoleBinding',
      metadata: {
        name: 'agentsmith-substrate-installer',
        namespace: 'agentsmith',
        labels: ownerLabels,
        annotations: ownerAnnotations
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'Role',
        name: 'agentsmith-substrate-installer'
      },
      subjects: [
        {
          kind: 'ServiceAccount',
          name: 'agentsmith-substrate-installer',
          namespace: 'agentsmith'
        }
      ]
    }
  ];
}
if (mutation === 'flag_like_name') {
  resources[0].metadata.name = '--agentsmith-substrate-installer';
}

const prerequisites = {
  schema_version: 'agentsmith.target-prerequisites.truth/v1',
  target_profile: profile,
  namespace: 'agentsmith',
  rbac: {
    policy: 'namespace_admin'
  },
  ingress: {
    host: 'agentsmith.release.example.com',
    tls_secret_ref: 'secretRef:release/agentsmith-ingress-tls'
  },
  registry: {
    pull_secret_ref: 'secretRef:release/registry-pull'
  },
  storage: {
    storage_class: 'gp3',
    persistent_volume_policy: 'dynamic'
  },
  substrate_secret_refs: [
    'secretRef:release/postgresql-credential',
    'secretRef:release/postgresql-ca',
    'secretRef:release/postgresql-admin',
    'secretRef:release/mongodb-credential',
    'secretRef:release/mongodb-ca',
    'secretRef:release/redis-credential',
    'secretRef:release/redis-ca',
    'secretRef:release/object-storage-credential',
    'secretRef:release/object-storage-ca',
    'secretRef:release/oidc-client',
    'secretRef:release/oidc-ca'
  ]
};

if (mutation === 'missing_registry_proof') {
  delete prerequisites.registry.pull_secret_ref;
}
if (mutation === 'missing_storage_proof') {
  delete prerequisites.storage.storage_class;
}
if (mutation === 'operator_facing_install_inputs') {
  delete prerequisites.target_profile;
}

writeJson(path.join(outDir, 'substrate-pack-manifest.json'), manifest);
if (mutation === 'resource_list_path') {
  writeJson(path.join(outDir, 'resource-list.json'), resources);
  const installInputs = {
    schema_version: 'agentsmith.substrate-install-inputs/v1',
    target_profile: profile,
    installation_id: 'kit-install-10001',
    substrate_truth: substrateTruth,
    resource_list_path: 'resource-list.json'
  };
  if (mutation === 'operator_facing_install_inputs') {
    delete installInputs.target_profile;
  }
  writeJson(path.join(outDir, 'substrate-install-inputs.json'), installInputs);
} else {
  const installInputs = {
    schema_version: 'agentsmith.substrate-install-inputs/v1',
    target_profile: profile,
    installation_id: 'kit-install-10001',
    substrate_truth: substrateTruth,
    resources
  };
  if (mutation === 'operator_facing_install_inputs') {
    delete installInputs.target_profile;
  }
  writeJson(path.join(outDir, 'substrate-install-inputs.json'), installInputs);
}
writeJson(path.join(outDir, 'target-prerequisites.json'), prerequisites);
NODE
}

write_fake_kubectl() {
  local fake_kubectl="$1"

  "$NODE_BIN" --input-type=module - "$fake_kubectl" <<'NODE'
import fs from 'node:fs';

const [fakeKubectl] = process.argv.slice(2);
fs.writeFileSync(
  fakeKubectl,
  `#!/usr/bin/env bash
set -euo pipefail
: "\${FAKE_KUBECTL_LOG:?}"
printf '%s\\n' "$*" >> "$FAKE_KUBECTL_LOG"

command_name=""
for arg in "$@"; do
  if [[ "$arg" == "version" || "$arg" == "get" || "$arg" == "apply" ]]; then
    command_name="$arg"
    break
  fi
done

if [[ "$command_name" == "version" ]]; then
  printf '%s\\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
  exit 0
fi

if [[ "$command_name" == "get" ]]; then
  mode="\${FAKE_KUBECTL_GET_MODE:-not-found}"
  if [[ "$mode" == "not-found" ]]; then
    echo "Error from server (NotFound): resource not found" >&2
    exit 1
  fi
  if [[ "$mode" == "unowned" ]]; then
    printf '%s\\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"agentsmith-substrate-config","namespace":"agentsmith","labels":{"app.kubernetes.io/managed-by":"operator"}}}'
    exit 0
  fi
  if [[ "$mode" == "label-only" ]]; then
    printf '%s\\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"agentsmith-substrate-config","namespace":"agentsmith","labels":{"app.kubernetes.io/managed-by":"agentsmith-release-kit"}}}'
    exit 0
  fi
  if [[ "$mode" == "installation-mismatch" ]]; then
    printf '%s\\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"agentsmith-substrate-config","namespace":"agentsmith","labels":{"app.kubernetes.io/managed-by":"agentsmith-release-kit"},"annotations":{"agentsmith.io/managed-by":"agentsmith-release-kit","agentsmith.io/installation-id":"other-installation"}}}'
    exit 0
  fi
  if [[ "$mode" == "owned" ]]; then
    printf '%s\\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"agentsmith-substrate-config","namespace":"agentsmith","labels":{"app.kubernetes.io/managed-by":"agentsmith-release-kit"},"annotations":{"agentsmith.io/managed-by":"agentsmith-release-kit","agentsmith.io/installation-id":"kit-install-10001"}}}'
    exit 0
  fi
fi

if [[ "$command_name" == "apply" ]]; then
  resource_file=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-f" ]]; then
      resource_file="$arg"
    fi
    previous="$arg"
  done
  if [[ "$resource_file" == *".substrate-install-resources."* ]]; then
    node --input-type=module - "$resource_file" <<'APPLY_NODE'
import fs from 'node:fs';

const [resourceFile] = process.argv.slice(2);
const resourceNames = new Map([
  ['v1|ConfigMap', 'configmap'],
  ['v1|Service', 'service'],
  ['networking.k8s.io/v1|NetworkPolicy', 'networkpolicy.networking.k8s.io'],
  ['apps/v1|Deployment', 'deployment.apps'],
  ['apps/v1|StatefulSet', 'statefulset.apps'],
  ['batch/v1|Job', 'job.batch'],
  ['v1|PersistentVolumeClaim', 'persistentvolumeclaim']
]);
const list = JSON.parse(fs.readFileSync(resourceFile, 'utf8'));
const refs = list.items.map((item) => {
  const resource = resourceNames.get(item.apiVersion + '|' + item.kind);
  if (!resource) {
    throw new Error('unexpected substrate install resource ' + item.apiVersion + '/' + item.kind);
  }
  return resource + '/' + item.metadata.name;
});
process.stdout.write(refs.join('\\n') + '\\n');
APPLY_NODE
    exit 0
  fi
  printf '%s\\n' "configmap/agentsmith-substrate-config"
  exit 0
fi

echo "unexpected fake kubectl args: $*" >&2
exit 2
`
);
fs.chmodSync(fakeKubectl, 0o755);
NODE
}

KUBECTL_LOG="$TMP_DIR/kubectl.log"
FAKE_KUBECTL="$TMP_DIR/kubectl"
write_fake_kubectl "$FAKE_KUBECTL"

reset_kubectl_log() {
  : >"$KUBECTL_LOG"
}

assert_kubectl_not_called() {
  if [[ -s "$KUBECTL_LOG" ]]; then
    cat "$KUBECTL_LOG" >&2
    fail "kubectl should not have been called"
  fi
}

assert_kubectl_no_apply() {
  if grep -q '^apply ' "$KUBECTL_LOG"; then
    cat "$KUBECTL_LOG" >&2
    fail "kubectl apply should not have been called"
  fi
}

run_install() {
  local fixture_dir="$1"
  local output_dir="$2"
  local target_profile="${SUBSTRATE_INSTALL_TARGET_PROFILE:-$TARGET_PROFILE}"
  shift 2

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" FAKE_KUBECTL_GET_MODE="${FAKE_KUBECTL_GET_MODE:-not-found}" \
    bash "$ROOT_DIR/scripts/verify-release.sh" --substrate-install \
      --release-contract "$VALID_CONTRACT" \
      --deploy-template-package "$VALID_TEMPLATE" \
      --target-profile "$target_profile" \
      --substrate-pack-manifest "$fixture_dir/substrate-pack-manifest.json" \
      --substrate-install-inputs "$fixture_dir/substrate-install-inputs.json" \
      --target-prerequisites "$fixture_dir/target-prerequisites.json" \
      --namespace agentsmith \
      --output-dir "$output_dir" \
      --kubectl "$FAKE_KUBECTL" \
      "$@"
}

assert_install_rejected_before_kubectl() {
  local mutation="$1"
  local expected_message="$2"
  local description="$3"
  local fixture_dir="$TMP_DIR/$mutation"

  write_fixture_set "$fixture_dir" "$mutation"
  reset_kubectl_log
  if run_install "$fixture_dir" "$TMP_DIR/out-$mutation" >"$TMP_DIR/$mutation.out" 2>&1; then
    fail "$description should fail"
  fi
  grep -Fq "$expected_message" "$TMP_DIR/$mutation.out" || \
    fail "$description failure message did not explain blocker"
  assert_kubectl_not_called
  pass "$description rejected before kubectl"
}

assert_install_report() {
  local report_file="$1"
  local truth_file="$2"
  local expected_mode="$3"
  local expected_operator_run_id="${4:-}"
  local expected_target_profile="${5:-$TARGET_PROFILE}"

  "$NODE_BIN" --input-type=module - "$report_file" "$truth_file" "$expected_mode" "$expected_operator_run_id" "$expected_target_profile" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [reportFile, truthFile, expectedMode, expectedOperatorRunId, expectedTargetProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const truth = JSON.parse(fs.readFileSync(truthFile, 'utf8'));
const truthDigest = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(truthFile)).digest('hex')}`;
const serialized = JSON.stringify({ report, truth });

if (report.schema !== 'agentsmith.substrate-install-report/v1') {
  throw new Error('unexpected substrate install report schema');
}
if (report.scope !== 'substrate_install_only') {
  throw new Error('unexpected substrate install report scope');
}
if (report.producer !== 'agentsmith-release-kit-substrate-installer') {
  throw new Error('unexpected substrate install report producer');
}
if (report.readiness !== false || report.status !== 'pass') {
  throw new Error('substrate install report must be pass readiness=false');
}
if (report.mode !== expectedMode) {
  throw new Error(`unexpected substrate install mode: ${report.mode}`);
}
if (report.target_profile?.value !== expectedTargetProfile) {
  throw new Error('unexpected substrate install target profile');
}
if (!report.release_contract_digest?.startsWith('sha256:')) {
  throw new Error('missing release contract digest');
}
if (!report.deploy_template_package_digest?.startsWith('sha256:')) {
  throw new Error('missing deploy template package digest');
}
const installInputs = report.inputs?.substrate_install_inputs;
const packManifest = report.inputs?.substrate_pack_manifest;
const targetPrerequisites = report.inputs?.target_prerequisites;
if (packManifest?.schema_version !== 'agentsmith.substrate-pack-manifest/v1') {
  throw new Error('missing substrate pack manifest input schema binding');
}
for (const field of ['input_sha256', 'release_contract_digest', 'deploy_template_package_digest']) {
  if (!packManifest[field]?.startsWith('sha256:')) {
    throw new Error(`missing substrate pack manifest digest field: ${field}`);
  }
}
if (packManifest.target_profile !== expectedTargetProfile) {
  throw new Error('substrate pack manifest binding must include target profile');
}
if (installInputs?.schema_version !== 'agentsmith.substrate-install-inputs/v1') {
  throw new Error('missing substrate install input schema binding');
}
for (const field of ['input_sha256', 'resource_list_sha256', 'apply_resource_list_sha256', 'install_parameters_sha256']) {
  if (!installInputs[field]?.startsWith('sha256:')) {
    throw new Error(`missing substrate install input digest field: ${field}`);
  }
}
if (installInputs.effective_namespace !== 'agentsmith') {
  throw new Error('substrate install report must bind effective namespace');
}
if (!new Set(['inline', 'resource_list_path']).has(installInputs.resource_source)) {
  throw new Error('unexpected substrate install resource source');
}
if (targetPrerequisites?.schema_version !== 'agentsmith.target-prerequisites.truth/v1') {
  throw new Error('missing target prerequisites input schema binding');
}
if (!targetPrerequisites.input_sha256?.startsWith('sha256:')) {
  throw new Error('missing target prerequisites input digest field');
}
if (
  targetPrerequisites.target_profile !== expectedTargetProfile ||
  targetPrerequisites.namespace !== 'agentsmith'
) {
  throw new Error('target prerequisites binding must include target profile and namespace');
}
if (report.output_substrate_truth_digest !== truthDigest || report.substrate_truth_digest !== truthDigest) {
  throw new Error('substrate install report must bind written substrate truth digest');
}
if (report.output_substrate_truth_path !== 'substrate-truth.json') {
  throw new Error('substrate install report must bind written substrate truth path');
}
if (!Array.isArray(report.installed_services) || report.installed_services.length !== 5) {
  throw new Error('substrate install report must include installed services');
}
if (!Array.isArray(report.resource_refs) || report.resource_refs.length === 0) {
  throw new Error('substrate install report must include namespace-scoped resource refs');
}
if (
  !Array.isArray(report.kubectl_resource_refs) ||
  report.kubectl_resource_refs.length !== report.resource_refs.length
) {
  throw new Error('substrate install report must include kubectl resource refs');
}
if (report.checks?.namespace_scope?.status !== 'pass') {
  throw new Error('substrate install report must include namespace scope pass proof');
}
if (
  report.checks.namespace_scope.resource_count !== report.resource_refs.length ||
  report.checks.namespace_scope.allowed_resource_count !== report.resource_refs.length ||
  report.checks.namespace_scope.namespace !== 'agentsmith'
) {
  throw new Error('namespace scope proof must summarize allowed resource refs');
}
if (report.checks?.collision_guard?.status !== 'pass') {
  throw new Error('substrate install report must include collision guard pass proof');
}
if (
  report.checks.collision_guard.checked_resource_count !== report.resource_refs.length ||
  report.checks.collision_guard.kubectl_get_count !== report.resource_refs.length
) {
  throw new Error('collision guard proof must summarize checked resources');
}
if (report.checks?.kubectl_apply?.status !== 'pass') {
  throw new Error('substrate install report must include kubectl apply pass proof');
}
if (
  report.checks.kubectl_apply.mode !== expectedMode ||
  report.checks.kubectl_apply.applied_resource_count !== report.resource_refs.length ||
  report.checks.kubectl_apply.kubectl_resource_count !== report.kubectl_resource_refs.length ||
  report.checks.kubectl_apply.command_summary?.server_side !== true ||
  report.checks.kubectl_apply.command_summary?.namespace !== 'agentsmith'
) {
  throw new Error('kubectl apply proof must summarize mode, command, and applied resources');
}
if (expectedMode === 'apply') {
  if (report.operator_run_id !== expectedOperatorRunId) {
    throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
  }
} else if ('operator_run_id' in report) {
  throw new Error('server-dry-run substrate install report must not include operator_run_id');
}
if (truth.schema_version !== 'agentsmith.substrate-connection.truth/v1') {
  throw new Error('unexpected substrate truth schema');
}
if (`${truth.target_cluster}/${truth.substrate_source}/${truth.distribution}` !== expectedTargetProfile) {
  throw new Error('substrate truth target profile did not match expected profile');
}
if (truth.installed_by !== 'agentsmith-release-kit') {
  throw new Error('substrate truth must keep release-kit installed_by marker');
}
if (truth.installation_id !== 'kit-install-10001') {
  throw new Error('substrate truth must keep fixture installation_id');
}
if (/plain-credential|Bearer\s+|AKIA|PRIVATE KEY|kubeconfig/i.test(serialized)) {
  throw new Error('substrate install outputs leaked raw secret-looking material');
}
NODE
}

valid_dir="$TMP_DIR/valid"
write_fixture_set "$valid_dir" valid

operator_facing_pack_dir="$TMP_DIR/operator-facing-pack"
write_fixture_set "$operator_facing_pack_dir" operator_facing_pack_manifest
operator_facing_pack_output="$TMP_DIR/out-operator-facing-pack"
reset_kubectl_log
run_install "$operator_facing_pack_dir" "$operator_facing_pack_output" >/dev/null
assert_install_report "$operator_facing_pack_output/substrate-install-report.json" "$operator_facing_pack_output/substrate-truth.json" server-dry-run
pass "operator-facing substrate pack manifest deployment_path is accepted and normalized"

assert_install_rejected_before_kubectl \
  operator_facing_pack_manifest_mismatch \
  "substrate_pack_manifest.deployment_path must match the selected install_substrates target" \
  "operator-facing substrate pack manifest deployment_path mismatch"

assert_install_rejected_before_kubectl \
  pack_missing_material \
  "substrate_pack_manifest.payload.install_plan.path must reference an existing file in substrate pack" \
  "substrate pack manifest missing material"

assert_install_rejected_before_kubectl \
  pack_material_sha_mismatch \
  "substrate_pack_manifest.payload.install_plan.sha256 must match referenced file sha256" \
  "substrate pack manifest material sha mismatch"

reset_kubectl_log
if run_install "$valid_dir" "$TMP_DIR/out-missing-confirm" \
  --mode apply \
  --operator-run-id operator-run-substrate-1001 >"$TMP_DIR/missing-confirm.out" 2>"$TMP_DIR/missing-confirm.err"; then
  fail "expected apply without confirmations to fail"
fi
assert_kubectl_not_called
pass "apply mode without explicit substrate install confirmation rejected"

installation_id_mismatch_dir="$TMP_DIR/installation-id-mismatch"
write_fixture_set "$installation_id_mismatch_dir" installation_id_mismatch
reset_kubectl_log
if run_install "$installation_id_mismatch_dir" "$TMP_DIR/out-installation-id-mismatch" >"$TMP_DIR/installation-id-mismatch.out" 2>&1; then
  fail "substrate truth installation_id mismatch should fail"
fi
grep -Fq "substrate_install_inputs.substrate_truth.installation_id must match substrate_install_inputs.installation_id" "$TMP_DIR/installation-id-mismatch.out" || \
  fail "installation_id mismatch failure message did not explain structural binding"
assert_kubectl_not_called
pass "substrate truth installation_id mismatch rejected before kubectl"

cluster_scoped_dir="$TMP_DIR/cluster-scoped"
write_fixture_set "$cluster_scoped_dir" cluster_scoped_manifest
reset_kubectl_log
if run_install "$cluster_scoped_dir" "$TMP_DIR/out-cluster-scoped" >"$TMP_DIR/cluster-scoped.out" 2>&1; then
  fail "cluster-scoped substrate install manifest should fail"
fi
grep -Fq "cluster-scoped" "$TMP_DIR/cluster-scoped.out" || \
  fail "cluster-scoped manifest failure message did not explain blocker"
assert_kubectl_not_called
pass "cluster-scoped substrate install resources rejected before kubectl"

deployment_dir="$TMP_DIR/deployment-manifest"
write_fixture_set "$deployment_dir" deployment_manifest
deployment_output="$TMP_DIR/out-deployment"
reset_kubectl_log
run_install "$deployment_dir" "$deployment_output" >/dev/null
grep -q '^get deployments.apps ' "$KUBECTL_LOG" || fail "Deployment collision guard did not use canonical Deployment resource"
assert_install_report "$deployment_output/substrate-install-report.json" "$deployment_output/substrate-truth.json" server-dry-run
pass "Deployment substrate install resource accepted with pack image binding"

statefulset_dir="$TMP_DIR/statefulset-manifest"
write_fixture_set "$statefulset_dir" statefulset_manifest
statefulset_output="$TMP_DIR/out-statefulset"
reset_kubectl_log
run_install "$statefulset_dir" "$statefulset_output" >/dev/null
grep -q '^get statefulsets.apps ' "$KUBECTL_LOG" || fail "StatefulSet collision guard did not use canonical StatefulSet resource"
assert_install_report "$statefulset_output/substrate-install-report.json" "$statefulset_output/substrate-truth.json" server-dry-run
pass "StatefulSet substrate install resource accepted with pack image binding"

unknown_api_dir="$TMP_DIR/unknown-api-version"
write_fixture_set "$unknown_api_dir" unknown_deployment_api_version
reset_kubectl_log
if run_install "$unknown_api_dir" "$TMP_DIR/out-unknown-api-version" >"$TMP_DIR/unknown-api-version.out" 2>&1; then
  fail "Deployment with unknown apiVersion should fail"
fi
grep -Fq "apiVersion evil.example/v1 with kind Deployment" "$TMP_DIR/unknown-api-version.out" || \
  fail "unknown apiVersion failure message did not explain blocker"
assert_kubectl_not_called
pass "namespace-scope guard rejects known kind under unknown apiVersion"

unknown_image_dir="$TMP_DIR/unknown-workload-image"
write_fixture_set "$unknown_image_dir" unknown_workload_image
reset_kubectl_log
if run_install "$unknown_image_dir" "$TMP_DIR/out-unknown-workload-image" >"$TMP_DIR/unknown-workload-image.out" 2>&1; then
  fail "workload image outside substrate pack manifest should fail"
fi
grep -Fq "must match an image declared in substrate_pack_manifest.images" "$TMP_DIR/unknown-workload-image.out" || \
  fail "unknown workload image failure message did not explain pack image inventory blocker"
assert_kubectl_not_called
pass "workload image outside substrate pack manifest rejected before kubectl"

tag_only_image_dir="$TMP_DIR/tag-only-workload-image"
write_fixture_set "$tag_only_image_dir" tag_only_workload_image
reset_kubectl_log
if run_install "$tag_only_image_dir" "$TMP_DIR/out-tag-only-workload-image" >"$TMP_DIR/tag-only-workload-image.out" 2>&1; then
  fail "tag-only workload image should fail"
fi
grep -Fq "must be digest-pinned with @sha256" "$TMP_DIR/tag-only-workload-image.out" || \
  fail "tag-only workload image failure message did not explain digest pin blocker"
assert_kubectl_not_called
pass "tag-only workload image rejected before kubectl"

digest_drift_dir="$TMP_DIR/digest-drift-workload-image"
write_fixture_set "$digest_drift_dir" digest_drift_workload_image
reset_kubectl_log
if run_install "$digest_drift_dir" "$TMP_DIR/out-digest-drift-workload-image" >"$TMP_DIR/digest-drift-workload-image.out" 2>&1; then
  fail "workload image digest drift should fail"
fi
grep -Fq "must match an image declared in substrate_pack_manifest.images" "$TMP_DIR/digest-drift-workload-image.out" || \
  fail "digest drift workload image failure message did not explain pack image inventory blocker"
assert_kubectl_not_called
pass "workload image digest drift rejected before kubectl"

assert_install_rejected_before_kubectl \
  workload_host_network \
  "resources[0].spec.template.spec.hostNetwork true is not allowed for substrate install" \
  "workload hostNetwork"

assert_install_rejected_before_kubectl \
  workload_host_pid \
  "resources[0].spec.template.spec.hostPID true is not allowed for substrate install" \
  "workload hostPID"

assert_install_rejected_before_kubectl \
  workload_host_ipc \
  "resources[0].spec.template.spec.hostIPC true is not allowed for substrate install" \
  "workload hostIPC"

assert_install_rejected_before_kubectl \
  workload_host_path_volume \
  "resources[0].spec.template.spec.volumes[0].hostPath is not allowed for substrate install" \
  "workload hostPath volume"

assert_install_rejected_before_kubectl \
  workload_service_account_name \
  "resources[0].spec.template.spec.serviceAccountName is not allowed for substrate install" \
  "workload serviceAccountName"

assert_install_rejected_before_kubectl \
  workload_service_account \
  "resources[0].spec.template.spec.serviceAccount is not allowed for substrate install" \
  "workload serviceAccount"

assert_install_rejected_before_kubectl \
  workload_pod_privileged \
  "resources[0].spec.template.spec.securityContext.privileged true is not allowed for substrate install" \
  "workload pod securityContext privileged"

assert_install_rejected_before_kubectl \
  workload_container_privileged \
  "resources[0].spec.template.spec.containers[0].securityContext.privileged true is not allowed for substrate install" \
  "workload container securityContext privileged"

assert_install_rejected_before_kubectl \
  workload_allow_privilege_escalation \
  "resources[0].spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation true is not allowed for substrate install" \
  "workload container allowPrivilegeEscalation"

assert_install_rejected_before_kubectl \
  workload_capabilities_add \
  "resources[0].spec.template.spec.containers[0].securityContext.capabilities.add must be empty or omitted for substrate install" \
  "workload container added capabilities"

assert_install_rejected_before_kubectl \
  workload_host_port \
  "resources[0].spec.template.spec.containers[0].ports[0].hostPort is not allowed for substrate install" \
  "workload container hostPort"

assert_install_rejected_before_kubectl \
  workload_init_container_privileged \
  "resources[0].spec.template.spec.initContainers[0].securityContext.privileged true is not allowed for substrate install" \
  "workload initContainer securityContext privileged"

"$NODE_BIN" --input-type=module - "$ROOT_DIR" <<'NODE'
import { pathToFileURL } from 'node:url';

const [rootDir] = process.argv.slice(2);
const guardUrl = pathToFileURL(`${rootDir}/scripts/lib/kubernetes-namespace-scope-guard.mjs`).href;
const { resourceRefForKubectl, validateNamespaceScopedResources } = await import(guardUrl);

let rejectedUnknownIdentity = false;
try {
  resourceRefForKubectl({
    apiVersion: 'evil.example/v1',
    kind: 'ConfigMap',
    metadata: {
      name: 'agentsmith-substrate-config'
    }
  }, 'agentsmith');
} catch (error) {
  if (!String(error.message).includes('not in the namespace-scoped substrate install allowlist')) {
    throw error;
  }
  rejectedUnknownIdentity = true;
}

if (!rejectedUnknownIdentity) {
  throw new Error('resourceRefForKubectl must reject unknown validated identities');
}

const ownerMetadata = {
  namespace: 'agentsmith',
  labels: {
    'app.kubernetes.io/managed-by': 'agentsmith-release-kit'
  },
  annotations: {
    'agentsmith.io/managed-by': 'agentsmith-release-kit',
    'agentsmith.io/installation-id': 'kit-install-10001'
  }
};
const serviceResource = (name, spec) => ({
  apiVersion: 'v1',
  kind: 'Service',
  metadata: {
    ...ownerMetadata,
    name
  },
  spec
});
const baseServiceSpec = {
  ports: [
    {
      name: 'http',
      port: 80,
      targetPort: 80
    }
  ]
};
validateNamespaceScopedResources([
  serviceResource('agentsmith-substrate-service-default', baseServiceSpec),
  serviceResource('agentsmith-substrate-service-cluster-ip', {
    ...baseServiceSpec,
    type: 'ClusterIP'
  })
], 'agentsmith', {
  installationId: 'kit-install-10001'
});
NODE
pass "kubectl resource ref helper rejects unknown identities and Service guard accepts defaulted or ClusterIP Services"

cluster_ip_service_dir="$TMP_DIR/cluster-ip-service"
write_fixture_set "$cluster_ip_service_dir" cluster_ip_service
cluster_ip_service_output="$TMP_DIR/out-cluster-ip-service"
reset_kubectl_log
run_install "$cluster_ip_service_dir" "$cluster_ip_service_output" >/dev/null
grep -q '^get services ' "$KUBECTL_LOG" || fail "ClusterIP Service collision guard did not use canonical Service resource"
grep -Eq '^apply .*--dry-run=server' "$KUBECTL_LOG" || \
  fail "ClusterIP Service server-dry-run did not pass --dry-run=server"
assert_install_report "$cluster_ip_service_output/substrate-install-report.json" "$cluster_ip_service_output/substrate-truth.json" server-dry-run
pass "ClusterIP Service substrate install resource accepted"

for service_case in \
  "service_node_port NodePort" \
  "service_load_balancer LoadBalancer" \
  "service_external_name ExternalName"; do
  read -r service_mutation service_type <<<"$service_case"
  service_type_dir="$TMP_DIR/$service_mutation"
  write_fixture_set "$service_type_dir" "$service_mutation"
  reset_kubectl_log
  if run_install "$service_type_dir" "$TMP_DIR/out-$service_mutation" >"$TMP_DIR/$service_mutation.out" 2>&1; then
    fail "Service type $service_type substrate install manifest should fail"
  fi
  grep -Fq "Service type $service_type is not allowed" "$TMP_DIR/$service_mutation.out" || \
    fail "Service type $service_type failure message did not explain allowlist blocker"
  assert_kubectl_not_called
  pass "substrate installer rejects Service type $service_type before kubectl"
done

for service_case in \
  "service_external_ips externalIPs" \
  "service_load_balancer_ip loadBalancerIP" \
  "service_load_balancer_class loadBalancerClass" \
  "service_external_name_field externalName" \
  "service_health_check_node_port healthCheckNodePort"; do
  read -r service_mutation service_field <<<"$service_case"
  service_field_dir="$TMP_DIR/$service_mutation"
  write_fixture_set "$service_field_dir" "$service_mutation"
  reset_kubectl_log
  if run_install "$service_field_dir" "$TMP_DIR/out-$service_mutation" >"$TMP_DIR/$service_mutation.out" 2>&1; then
    fail "ClusterIP Service field $service_field substrate install manifest should fail"
  fi
  grep -Fq "spec.$service_field is not allowed for substrate install ClusterIP Service" "$TMP_DIR/$service_mutation.out" || \
    fail "ClusterIP Service field $service_field failure message did not explain exposure blocker"
  assert_kubectl_not_called
  pass "substrate installer rejects ClusterIP Service field $service_field before kubectl"
done

secret_dir="$TMP_DIR/secret-payload"
write_fixture_set "$secret_dir" secret_manifest
reset_kubectl_log
if run_install "$secret_dir" "$TMP_DIR/out-secret-payload" >"$TMP_DIR/secret-payload.out" 2>&1; then
  fail "Secret substrate install manifest should fail"
fi
grep -Fq "use secret refs only and do not include Secret payload resources" "$TMP_DIR/secret-payload.out" || \
  fail "Secret resource failure message did not explain secret refs only boundary"
assert_kubectl_not_called
pass "substrate installer rejects Secret payload resources before kubectl"

for workload_case in \
  "daemonset_manifest apps/v1 DaemonSet" \
  "cronjob_manifest batch/v1 CronJob" \
  "pod_manifest v1 Pod" \
  "replicaset_manifest apps/v1 ReplicaSet"; do
  read -r workload_mutation workload_api workload_kind <<<"$workload_case"
  workload_dir="$TMP_DIR/$workload_mutation"
  write_fixture_set "$workload_dir" "$workload_mutation"
  reset_kubectl_log
  if run_install "$workload_dir" "$TMP_DIR/out-$workload_mutation" >"$TMP_DIR/$workload_mutation.out" 2>&1; then
    fail "$workload_kind substrate install manifest should fail"
  fi
  grep -Fq "apiVersion $workload_api with kind $workload_kind is not in the namespace-scoped substrate install allowlist" "$TMP_DIR/$workload_mutation.out" || \
    fail "$workload_kind failure message did not explain allowlist blocker"
  assert_kubectl_not_called
  pass "substrate installer rejects $workload_kind resources before kubectl"
done

job_dir="$TMP_DIR/job-manifest"
write_fixture_set "$job_dir" job_manifest
job_output="$TMP_DIR/out-job"
reset_kubectl_log
run_install "$job_dir" "$job_output" >/dev/null
grep -q '^get jobs.batch ' "$KUBECTL_LOG" || fail "Job collision guard did not use canonical Job resource"
assert_install_report "$job_output/substrate-install-report.json" "$job_output/substrate-truth.json" server-dry-run
pass "Job substrate install resource accepted with pack image binding"

service_account_dir="$TMP_DIR/service-account-manifest"
write_fixture_set "$service_account_dir" service_account_manifest
reset_kubectl_log
if run_install "$service_account_dir" "$TMP_DIR/out-service-account" >"$TMP_DIR/service-account.out" 2>&1; then
  fail "ServiceAccount substrate install manifest should fail"
fi
grep -Fq "apiVersion v1 with kind ServiceAccount is not in the namespace-scoped substrate install allowlist" "$TMP_DIR/service-account.out" || \
  fail "ServiceAccount resource failure message did not explain allowlist blocker"
assert_kubectl_not_called
pass "substrate installer rejects ServiceAccount resources before kubectl"

role_dir="$TMP_DIR/role-manifest"
write_fixture_set "$role_dir" role_manifest
reset_kubectl_log
if run_install "$role_dir" "$TMP_DIR/out-role" >"$TMP_DIR/role.out" 2>&1; then
  fail "Role substrate install manifest should fail"
fi
grep -Fq "apiVersion rbac.authorization.k8s.io/v1 with kind Role is not in the namespace-scoped substrate install allowlist" "$TMP_DIR/role.out" || \
  fail "Role resource failure message did not explain allowlist blocker"
assert_kubectl_not_called
pass "substrate installer rejects Role resources before kubectl"

role_binding_dir="$TMP_DIR/role-binding-manifest"
write_fixture_set "$role_binding_dir" role_binding_manifest
reset_kubectl_log
if run_install "$role_binding_dir" "$TMP_DIR/out-role-binding" >"$TMP_DIR/role-binding.out" 2>&1; then
  fail "RoleBinding substrate install manifest should fail"
fi
grep -Fq "apiVersion rbac.authorization.k8s.io/v1 with kind RoleBinding is not in the namespace-scoped substrate install allowlist" "$TMP_DIR/role-binding.out" || \
  fail "RoleBinding resource failure message did not explain allowlist blocker"
assert_kubectl_not_called
pass "substrate installer rejects RoleBinding resources before kubectl"

pvc_dir="$TMP_DIR/pvc"
write_fixture_set "$pvc_dir" pvc_manifest
pvc_output="$TMP_DIR/out-pvc"
reset_kubectl_log
run_install "$pvc_dir" "$pvc_output" >/dev/null
grep -q '^get persistentvolumeclaims ' "$KUBECTL_LOG" || fail "PVC collision guard did not use canonical PersistentVolumeClaim resource"
assert_install_report "$pvc_output/substrate-install-report.json" "$pvc_output/substrate-truth.json" server-dry-run
pass "PVC substrate install resource accepted with target storage prerequisite binding"

flag_like_name_dir="$TMP_DIR/flag-like-name"
write_fixture_set "$flag_like_name_dir" flag_like_name
reset_kubectl_log
if run_install "$flag_like_name_dir" "$TMP_DIR/out-flag-like-name" >"$TMP_DIR/flag-like-name.out" 2>&1; then
  fail "flag-like metadata.name should fail"
fi
grep -Fq "metadata.name must be a Kubernetes resource name" "$TMP_DIR/flag-like-name.out" || \
  fail "flag-like metadata.name failure message did not explain blocker"
assert_kubectl_not_called
pass "substrate installer rejects flag-like Kubernetes resource names before kubectl"

reset_kubectl_log
if FAKE_KUBECTL_GET_MODE=unowned run_install "$valid_dir" "$TMP_DIR/out-collision" >"$TMP_DIR/collision.out" 2>&1; then
  fail "non-kit-owned existing resource collision should fail"
fi
grep -Fq "not owned by agentsmith-release-kit" "$TMP_DIR/collision.out" || \
  fail "collision failure message did not explain blocker"
grep -q '^version ' "$KUBECTL_LOG" || fail "collision guard did not check kubectl version"
grep -q '^get ' "$KUBECTL_LOG" || fail "collision guard did not call kubectl get"
assert_kubectl_no_apply
pass "non-kit-owned resource collision fails before apply"

reset_kubectl_log
if FAKE_KUBECTL_GET_MODE=label-only run_install "$valid_dir" "$TMP_DIR/out-collision-label-only" >"$TMP_DIR/collision-label-only.out" 2>&1; then
  fail "label-only existing resource collision should fail"
fi
grep -Fq "not owned by agentsmith-release-kit" "$TMP_DIR/collision-label-only.out" || \
  fail "label-only collision failure message did not explain blocker"
assert_kubectl_no_apply
pass "existing resource with only managed-by label is not overwrite-owned"

reset_kubectl_log
if FAKE_KUBECTL_GET_MODE=installation-mismatch run_install "$valid_dir" "$TMP_DIR/out-collision-installation-mismatch" >"$TMP_DIR/collision-installation-mismatch.out" 2>&1; then
  fail "installation id mismatch existing resource collision should fail"
fi
grep -Fq "not owned by agentsmith-release-kit" "$TMP_DIR/collision-installation-mismatch.out" || \
  fail "installation mismatch collision failure message did not explain blocker"
assert_kubectl_no_apply
pass "existing resource installation_id mismatch is not overwrite-owned"

missing_registry_dir="$TMP_DIR/missing-registry"
write_fixture_set "$missing_registry_dir" missing_registry_proof
reset_kubectl_log
if run_install "$missing_registry_dir" "$TMP_DIR/out-missing-registry" >"$TMP_DIR/missing-registry.out" 2>&1; then
  fail "missing registry proof should fail"
fi
grep -Fq "target_prerequisites.registry.pull_secret_ref is required" "$TMP_DIR/missing-registry.out" || \
  fail "missing registry proof failure message did not explain blocker"
assert_kubectl_not_called
pass "missing registry prerequisite proof rejected before kubectl"

missing_storage_dir="$TMP_DIR/missing-storage"
write_fixture_set "$missing_storage_dir" missing_storage_proof
reset_kubectl_log
if run_install "$missing_storage_dir" "$TMP_DIR/out-missing-storage" >"$TMP_DIR/missing-storage.out" 2>&1; then
  fail "missing storage proof should fail"
fi
grep -Fq "target_prerequisites.storage.storage_class is required" "$TMP_DIR/missing-storage.out" || \
  fail "missing storage proof failure message did not explain blocker"
assert_kubectl_not_called
pass "missing storage prerequisite proof rejected before kubectl"

dry_run_output="$TMP_DIR/out-dry-run"
reset_kubectl_log
run_install "$valid_dir" "$dry_run_output" >/dev/null
grep -q '^get configmaps ' "$KUBECTL_LOG" || fail "collision guard did not use canonical ConfigMap resource"
grep -Eq '^apply .*--dry-run=server' "$KUBECTL_LOG" || \
  fail "server-dry-run substrate install did not pass --dry-run=server"
assert_install_report "$dry_run_output/substrate-install-report.json" "$dry_run_output/substrate-truth.json" server-dry-run
pass "server-dry-run writes diagnostic substrate install report and truth"

operator_facing_dir="$TMP_DIR/operator-facing-inputs"
write_fixture_set "$operator_facing_dir" operator_facing_install_inputs
operator_facing_output="$TMP_DIR/out-operator-facing-inputs"
reset_kubectl_log
run_install "$operator_facing_dir" "$operator_facing_output" >/dev/null
assert_install_report "$operator_facing_output/substrate-install-report.json" "$operator_facing_output/substrate-truth.json" server-dry-run
pass "operator-facing substrate install inputs and prerequisites derive target profile from CLI"

airgap_dir="$TMP_DIR/airgap-valid"
write_fixture_set "$airgap_dir" valid "$AIRGAP_TARGET_PROFILE"
airgap_dry_run_output="$TMP_DIR/out-airgap-dry-run"
reset_kubectl_log
SUBSTRATE_INSTALL_TARGET_PROFILE="$AIRGAP_TARGET_PROFILE" run_install "$airgap_dir" "$airgap_dry_run_output" >/dev/null
grep -q '^get configmaps ' "$KUBECTL_LOG" || fail "airgap collision guard did not use canonical ConfigMap resource"
grep -Eq '^apply .*--dry-run=server' "$KUBECTL_LOG" || \
  fail "airgap server-dry-run substrate install did not pass --dry-run=server"
assert_install_report "$airgap_dry_run_output/substrate-install-report.json" "$airgap_dry_run_output/substrate-truth.json" server-dry-run "" "$AIRGAP_TARGET_PROFILE"
pass "airgap server-dry-run writes diagnostic substrate install report and truth"

apply_output="$TMP_DIR/out-apply"
install_digest="$(install_parameters_digest "$valid_dir/substrate-install-inputs.json")"
reset_kubectl_log
run_install "$valid_dir" "$apply_output" \
  --mode apply \
  --confirm-substrate-install "$TARGET_PROFILE" \
  --confirm-install-parameters "$install_digest" \
  --operator-run-id operator-run-substrate-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed substrate install apply must not use server dry-run"
fi
grep -q '^apply ' "$KUBECTL_LOG" || fail "confirmed substrate install did not call kubectl apply"
assert_install_report "$apply_output/substrate-install-report.json" "$apply_output/substrate-truth.json" apply operator-run-substrate-1001
pass "confirmed substrate install apply writes report and substrate truth"

namespace_changed_output="$TMP_DIR/out-namespace-changed"
namespace_bound_digest="$(install_parameters_digest "$valid_dir/substrate-install-inputs.json" agentsmith)"
reset_kubectl_log
if run_install "$valid_dir" "$namespace_changed_output" \
  --mode apply \
  --confirm-substrate-install "$TARGET_PROFILE" \
  --confirm-install-parameters "$namespace_bound_digest" \
  --operator-run-id operator-run-substrate-1004 \
  --namespace changed-ns >"$TMP_DIR/namespace-changed.out" 2>&1; then
  fail "namespace changed after confirmation should fail"
fi
grep -Fq "confirm-install-parameters must match the substrate install parameters sha256" "$TMP_DIR/namespace-changed.out" || \
  fail "namespace changed confirmation failure message did not explain blocker"
assert_kubectl_not_called
pass "changed effective namespace requires a new install parameter confirmation"

resource_list_dir="$TMP_DIR/resource-list-path"
write_fixture_set "$resource_list_dir" resource_list_path
resource_list_confirm_digest="$(install_parameters_digest "$resource_list_dir/substrate-install-inputs.json")"
resource_list_apply_output="$TMP_DIR/out-resource-list-apply"
reset_kubectl_log
run_install "$resource_list_dir" "$resource_list_apply_output" \
  --mode apply \
  --confirm-substrate-install "$TARGET_PROFILE" \
  --confirm-install-parameters "$resource_list_confirm_digest" \
  --operator-run-id operator-run-substrate-1002 >/dev/null
assert_install_report "$resource_list_apply_output/substrate-install-report.json" "$resource_list_apply_output/substrate-truth.json" apply operator-run-substrate-1002
"$NODE_BIN" --input-type=module - "$resource_list_apply_output/substrate-install-report.json" <<'NODE'
import fs from 'node:fs';

const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const installInputs = report.inputs.substrate_install_inputs;
if (installInputs.resource_source !== 'resource_list_path') {
  throw new Error('external resource list report did not record resource_list_path source');
}
if (installInputs.resource_list_path !== 'resource-list.json') {
  throw new Error('external resource list report did not record safe relative path');
}
NODE
pass "external resource_list_path apply is bound into producer report"

changed_resource_list_dir="$TMP_DIR/resource-list-path-changed"
write_fixture_set "$changed_resource_list_dir" resource_list_path
stale_resource_list_confirm_digest="$(install_parameters_digest "$changed_resource_list_dir/substrate-install-inputs.json")"
"$NODE_BIN" --input-type=module - "$changed_resource_list_dir/resource-list.json" <<'NODE'
import fs from 'node:fs';

const file = process.argv[2];
const resources = JSON.parse(fs.readFileSync(file, 'utf8'));
resources[0].data.profile = 'changed-after-confirmation';
fs.writeFileSync(file, `${JSON.stringify(resources, null, 2)}\n`);
NODE
reset_kubectl_log
if run_install "$changed_resource_list_dir" "$TMP_DIR/out-resource-list-changed" \
  --mode apply \
  --confirm-substrate-install "$TARGET_PROFILE" \
  --confirm-install-parameters "$stale_resource_list_confirm_digest" \
  --operator-run-id operator-run-substrate-1003 >"$TMP_DIR/resource-list-changed.out" 2>&1; then
  fail "changed resource_list_path file with stale confirm digest should fail"
fi
grep -Fq "confirm-install-parameters must match the substrate install parameters sha256" "$TMP_DIR/resource-list-changed.out" || \
  fail "changed resource list confirmation failure message did not explain blocker"
assert_kubectl_not_called
pass "changed external resource_list_path bytes require a new install parameter confirmation"

echo "PASS: substrate install producer focused tests completed"
