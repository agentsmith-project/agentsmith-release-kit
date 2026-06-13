#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
AIRGAP_TARGET_PROFILE="existing_kubernetes/external_declared/airgap"
KIT_ONLINE_TARGET_PROFILE="existing_kubernetes/kit_installed/online"
KIT_AIRGAP_TARGET_PROFILE="existing_kubernetes/kit_installed/airgap"
ALIAS_OFFLINE_TARGET_PROFILE="existing_kubernetes/external_declared/offline"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_manifests() {
  local rendered_manifests="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$rendered_manifests" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, renderedManifests, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const inventory = new Map(contract.deploy_image_inventory.map((item) => [item.id, item.image]));
const unknownDigest = `sha256:${'e'.repeat(64)}`;
let appImage = inventory.get('agentsmith_app');

if (!appImage) {
  throw new Error('missing fixture app image');
}

if (mutation === 'unknown_image') {
  appImage = `ghcr.io/agentsmith-project/not-in-contract:${contract.release_id}@${unknownDigest}`;
}

const manifestDir =
  mutation === 'nested' ? path.join(renderedManifests, 'templates', 'app') : renderedManifests;
fs.mkdirSync(manifestDir, { recursive: true });
fs.writeFileSync(
  path.join(manifestDir, 'deployment.yaml'),
  `apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${appImage}
`
);
NODE
}

write_job_manifests() {
  local rendered_manifests="$1"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$rendered_manifests" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, renderedManifests] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const inventory = new Map(contract.deploy_image_inventory.map((item) => [item.id, item.image]));
const appImage = inventory.get('agentsmith_app');

if (!appImage) {
  throw new Error('missing fixture app image');
}

fs.mkdirSync(renderedManifests, { recursive: true });
fs.writeFileSync(
  path.join(renderedManifests, 'job.yaml'),
  `apiVersion: batch/v1
kind: Job
metadata:
  name: agentsmith-bootstrap
  labels:
    app.kubernetes.io/name: agentsmith
    app.kubernetes.io/part-of: agentsmith-deploy
  annotations:
    rendered-by: agentsmith-unified-deploy
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: bootstrap
          image: ${appImage}
`
);
NODE
}

write_secret_ref_manifests() {
  local rendered_manifests="$1"
  local mutation="$2"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$rendered_manifests" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, renderedManifests, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const inventory = new Map(contract.deploy_image_inventory.map((item) => [item.id, item.image]));
const appImage = inventory.get('agentsmith_app');

if (!appImage) {
  throw new Error('missing fixture app image');
}

const secretBlocks = {
  required_env_from: `          envFrom:
            - secretRef:
                name: agentsmith-app
`,
  missing_key: `          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: agentsmith-app
                  key: DATABASE_URL
`,
  missing_volume_item_key: `      volumes:
        - name: app-ca
          secret:
            secretName: agentsmith-app
            items:
              - key: ca.crt
                path: ca.crt
`,
  missing_projected_item_key: `      volumes:
        - name: projected-app-ca
          projected:
            sources:
              - secret:
                  name: agentsmith-app
                  items:
                    - key: ca.crt
                      path: ca.crt
`,
  optional_refs: `          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: agentsmith-app
                  key: DATABASE_URL
                  optional: true
          envFrom:
            - secretRef:
                name: agentsmith-app
                optional: true
      volumes:
        - name: optional-secret
          secret:
            secretName: agentsmith-app
            optional: true
        - name: optional-projected
          projected:
            sources:
              - secret:
                  name: agentsmith-app
                  optional: true
`,
  flow_style_missing_key: `          env: [{name: DATABASE_URL, valueFrom: {secretKeyRef: {name: agentsmith-app, key: DATABASE_URL}}}]
`
};

if (!Object.hasOwn(secretBlocks, mutation)) {
  throw new Error(`unknown secret ref mutation: ${mutation}`);
}

fs.mkdirSync(renderedManifests, { recursive: true });
fs.writeFileSync(
  path.join(renderedManifests, 'deployment-secret-ref.yaml'),
  `apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-api
spec:
  template:
    spec:
      containers:
        - name: api
          image: ${appImage}
${secretBlocks[mutation]}`
);
NODE
}

write_afscp_static_volume_manifests() {
  local rendered_manifests="$1"
  local mutation="${2:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$rendered_manifests" "$mutation" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, renderedManifests, mutation] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const inventory = new Map(contract.deploy_image_inventory.map((item) => [item.id, item.image]));
const appImage = inventory.get('agentsmith_app');

if (!appImage) {
  throw new Error('missing fixture app image');
}

let pvReclaimPolicy = 'Retain';
let pvStorageClassName = '""';
let pvClaimNamespace = 'agentsmith';
let pvClaimName = 'afscp-default-volume';
let pvCsiDriver = 'csi.juicefs.com';
let pvCsiFsType = 'juicefs';
let pvVolumeHandle = 'agentsmith-afscp-default-volume';
let pvSecretNamespace = 'agentsmith';
let pvcStorageClassName = '""';
let pvcVolumeName = 'agentsmith-afscp-default-volume';
let includeAfscpWorkloads = true;

switch (mutation) {
  case 'valid':
    break;
  case 'missing_workload_allowlist':
    includeAfscpWorkloads = false;
    break;
  case 'unsafe_pv':
    pvReclaimPolicy = 'Delete';
    pvStorageClassName = 'fast';
    pvClaimNamespace = 'foreign';
    pvClaimName = 'foreign-pvc';
    pvCsiDriver = 'example.invalid/csi';
    pvCsiFsType = 'ext4';
    pvVolumeHandle = 'foreign-volume';
    pvSecretNamespace = 'kube-system';
    break;
  case 'unsafe_pvc':
    pvcStorageClassName = 'fast';
    pvcVolumeName = 'foreign-pv';
    break;
  default:
    throw new Error(`unknown AFSCP static volume mutation: ${mutation}`);
}

const afscpWorkloadManifests = includeAfscpWorkloads ? `---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: afscp-api
  namespace: agentsmith
  labels:
    app.kubernetes.io/name: agentsmith
    app.kubernetes.io/part-of: agentsmith-deploy
    app.kubernetes.io/component: afscp
  annotations:
    rendered-by: agentsmith-unified-deploy
spec:
  template:
    spec:
      volumes:
        - name: files
          persistentVolumeClaim:
            claimName: afscp-default-volume
      containers:
        - name: api
          image: ${appImage}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: afscp-bootstrap
  namespace: agentsmith
  labels:
    app.kubernetes.io/name: agentsmith
    app.kubernetes.io/part-of: agentsmith-deploy
    app.kubernetes.io/component: afscp
  annotations:
    rendered-by: agentsmith-unified-deploy
spec:
  template:
    spec:
      volumes:
        - name: files
          persistentVolumeClaim:
            claimName: afscp-default-volume
      containers:
        - name: bootstrap
          image: ${appImage}
` : '';

fs.mkdirSync(renderedManifests, { recursive: true });
fs.writeFileSync(
  path.join(renderedManifests, 'afscp-static-volume.yaml'),
  `apiVersion: v1
kind: PersistentVolume
metadata:
  name: agentsmith-afscp-default-volume
  labels:
    app.kubernetes.io/name: agentsmith
    app.kubernetes.io/part-of: agentsmith-deploy
  annotations:
    rendered-by: agentsmith-unified-deploy
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: ${pvReclaimPolicy}
  storageClassName: ${pvStorageClassName}
  claimRef:
    namespace: ${pvClaimNamespace}
    name: ${pvClaimName}
  csi:
    driver: ${pvCsiDriver}
    fsType: ${pvCsiFsType}
    volumeHandle: ${pvVolumeHandle}
    nodePublishSecretRef:
      name: afscp-default-volume-juicefs-1a24f776a1db
      namespace: ${pvSecretNamespace}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: afscp-default-volume
  namespace: agentsmith
  labels:
    app.kubernetes.io/name: agentsmith
    app.kubernetes.io/part-of: agentsmith-deploy
  annotations:
    rendered-by: agentsmith-unified-deploy
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${pvcStorageClassName}
  volumeName: ${pvcVolumeName}
  resources:
    requests:
      storage: 1Gi
${afscpWorkloadManifests}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: agentsmith
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${appImage}
`
);
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
command_index=-1
args=("$@")
for index in "\${!args[@]}"; do
  arg="\${args[$index]}"
  if [[ "$arg" == "version" || "$arg" == "create" || "$arg" == "apply" || "$arg" == "get" || "$arg" == "delete" || "$arg" == "exec" ]]; then
    command_name="$arg"
    command_index="$index"
    break
  fi
done

afscp_owned_labels='"app.kubernetes.io/name":"agentsmith","app.kubernetes.io/part-of":"agentsmith-deploy"'
afscp_owned_annotations='"rendered-by":"agentsmith-unified-deploy"'
afscp_live_secret_base="afscp-default-volume-juicefs"
afscp_rendered_secret="afscp-default-volume-juicefs-1a24f776a1db"
afscp_pv_name="agentsmith-afscp-default-volume"
afscp_pvc_name="afscp-default-volume"
afscp_pv_uid="pv-uid-afscp-default-volume"
afscp_pvc_uid="pvc-uid-afscp-default-volume"
afscp_unique_id="juicefs-afscp-unique-7c9d"
afscp_postgres_ca_dir="/etc/agentsmith/substrate-ca/postgresql"
afscp_object_storage_ca_dir="/etc/agentsmith/substrate-ca/object-storage"
afscp_postgres_ca_secret="postgresql-ca"
afscp_object_storage_ca_secret="object-storage-ca"
afscp_mount_namespace="\${FAKE_KUBECTL_AFSCP_MOUNT_NAMESPACE:-kube-system}"
afscp_node_namespace="\${FAKE_KUBECTL_AFSCP_NODE_NAMESPACE:-$afscp_mount_namespace}"

print_afscp_volume_secret_json() {
  local name="$1"
  local mode="\${FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE:-valid}"

  node --input-type=module - "$name" "$mode" "$afscp_postgres_ca_dir" "$afscp_object_storage_ca_dir" <<'SECRET_NODE'
const [name, mode, postgresCaDir, objectStorageCaDir] = process.argv.slice(2);

const fields = {
  name: 'agentsmith-afscp-default-volume',
  metaurl: 'postgres://postgresql.release.example.internal:5432/appdb?sslmode=verify-full&sslrootcert=' + postgresCaDir + '/ca.crt',
  storage: 's3',
  bucket: 'http://objects.release.example.internal/release-artifacts',
  configs: JSON.stringify({
    'postgresql-ca': postgresCaDir
  }),
  envs: JSON.stringify({})
};

switch (mode) {
  case 'valid':
    break;
  case 'postgres_config_missing':
    fields.configs = JSON.stringify({});
    break;
  case 'object_tls_missing':
    fields.bucket = 'https://objects.release.example.internal/release-artifacts';
    fields.configs = JSON.stringify({
      'postgresql-ca': postgresCaDir
    });
    fields.envs = JSON.stringify({
      SSL_CERT_DIR: '/etc/ssl/certs'
    });
    break;
  case 'object_tls_valid':
    fields.bucket = 'https://objects.release.example.internal/release-artifacts';
    fields.configs = JSON.stringify({
      'postgresql-ca': postgresCaDir,
      'object-storage-ca': objectStorageCaDir
    });
    fields.envs = JSON.stringify({
      SSL_CERT_DIR: objectStorageCaDir + ':/etc/ssl/certs'
    });
    break;
  default:
    process.stderr.write('unknown FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE: ' + mode + '\\n');
    process.exit(2);
}

const data = Object.fromEntries(
  Object.entries(fields).map(([key, value]) => {
    return [key, Buffer.from(String(value), 'utf8').toString('base64')];
  })
);
process.stdout.write(JSON.stringify({ kind: 'Secret', metadata: { name, namespace: 'agentsmith' }, data }) + '\\n');
SECRET_NODE
}

print_afscp_ca_secret_json() {
  local name="$1"

  node --input-type=module - "$name" <<'SECRET_NODE'
const [name] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  kind: 'Secret',
  metadata: { name },
  data: {
    'ca.crt': Buffer.from('fixture-ca', 'utf8').toString('base64')
  }
}) + '\\n');
SECRET_NODE
}

print_afscp_csi_node_daemonset_json() {
  cat <<JSON
{"apiVersion":"apps/v1","kind":"DaemonSet","metadata":{"name":"juicefs-csi-node","namespace":"$afscp_node_namespace"},"spec":{"template":{"spec":{"containers":[{"name":"juicefs-plugin","env":[{"name":"JUICEFS_MOUNT_NAMESPACE","value":"$afscp_mount_namespace"}]}]}}}}
JSON
}

print_afscp_pv_json() {
  local mode="$1"
  local name="$2"
  local secret_name="$afscp_live_secret_base"
  local reclaim_policy="Retain"
  local claim_namespace="agentsmith"
  local claim_name="$afscp_pvc_name"
  local labels="$afscp_owned_labels"
  local annotations="$afscp_owned_annotations"
  local metadata_extra=""

  case "$mode" in
    no_drift)
      secret_name="$afscp_rendered_secret"
      ;;
    deleting_pv)
      metadata_extra=',"deletionTimestamp":"2026-06-13T00:00:00Z"'
      ;;
    non_owned)
      labels='"app.kubernetes.io/name":"agentsmith"'
      annotations=''
      ;;
    reclaim_delete)
      reclaim_policy="Delete"
      ;;
    foreign_binding)
      claim_namespace="foreign"
      claim_name="foreign-pvc"
      ;;
  esac

  local annotations_json="{}"
  if [[ -n "$annotations" ]]; then
    annotations_json="{\${annotations}}"
  fi

  cat <<JSON
{"apiVersion":"v1","kind":"PersistentVolume","metadata":{"name":"$name","uid":"$afscp_pv_uid","labels":{\${labels}},"annotations":\${annotations_json}\${metadata_extra}},"spec":{"capacity":{"storage":"1Gi"},"accessModes":["ReadWriteMany"],"persistentVolumeReclaimPolicy":"$reclaim_policy","storageClassName":"","claimRef":{"namespace":"$claim_namespace","name":"$claim_name"},"csi":{"driver":"csi.juicefs.com","fsType":"juicefs","volumeHandle":"$name","nodePublishSecretRef":{"name":"$secret_name","namespace":"agentsmith"}}},"status":{"phase":"Bound"}}
JSON
}

print_afscp_pvc_json() {
  local mode="$1"
  local name="$2"
  local volume_name="$afscp_pv_name"
  local labels="$afscp_owned_labels"
  local annotations="$afscp_owned_annotations"
  local metadata_extra=""

  case "$mode" in
    deleting_pvc)
      metadata_extra=',"deletionTimestamp":"2026-06-13T00:00:00Z"'
      ;;
    non_owned)
      labels='"app.kubernetes.io/name":"agentsmith"'
      annotations=''
      ;;
    foreign_binding)
      volume_name="foreign-pv"
      ;;
  esac

  local annotations_json="{}"
  if [[ -n "$annotations" ]]; then
    annotations_json="{\${annotations}}"
  fi

  cat <<JSON
{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"$name","namespace":"agentsmith","uid":"$afscp_pvc_uid","labels":{\${labels}},"annotations":\${annotations_json}\${metadata_extra}},"spec":{"accessModes":["ReadWriteMany"],"storageClassName":"","volumeName":"$volume_name","resources":{"requests":{"storage":"1Gi"}}},"status":{"phase":"Bound"}}
JSON
}

print_afscp_workloads_json() {
  local mode="$1"

  if [[ "$mode" == "owned_replicaset_pod" ]]; then
    cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"afscp-api","namespace":"agentsmith","uid":"deployment-uid-afscp-api","labels":{\${afscp_owned_labels},"app.kubernetes.io/component":"afscp"},"annotations":{\${afscp_owned_annotations}}},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"api","image":"example.invalid/afscp:latest"}]}}}},{"apiVersion":"apps/v1","kind":"ReplicaSet","metadata":{"name":"afscp-api-7d88f879c9","namespace":"agentsmith","uid":"rs-uid-afscp-api","labels":{"app.kubernetes.io/name":"afscp-api","pod-template-hash":"7d88f879c9"},"annotations":{},"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"afscp-api","uid":"deployment-uid-afscp-api","controller":true}]},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"api","image":"example.invalid/afscp:latest"}]}}}},{"apiVersion":"v1","kind":"Pod","metadata":{"name":"afscp-api-7d88f879c9-x42qv","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"afscp-api","pod-template-hash":"7d88f879c9"},"annotations":{},"ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"afscp-api-7d88f879c9","uid":"rs-uid-afscp-api","controller":true}]},"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"api","image":"example.invalid/afscp:latest"}]}}]}
JSON
    return
  fi

  if [[ "$mode" == "foreign_owned_pod" ]]; then
    cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"foreign-owned-files-reader","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"foreign"},"annotations":{},"ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"foreign-files-reader-6d4f8","uid":"foreign-rs-uid"}]},"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"reader","image":"example.invalid/reader:latest"}]}}]}
JSON
    return
  fi

  if [[ "$mode" == "foreign_workload" ]]; then
    cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"foreign-files-reader","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"foreign"},"annotations":{}},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"reader","image":"example.invalid/reader:latest"}]}}}}]}
JSON
    return
  fi

  if [[ "$mode" == "with_non_pvc_afscp_named" ]]; then
    cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"afscp-api","namespace":"agentsmith","labels":{\${afscp_owned_labels},"app.kubernetes.io/component":"afscp"},"annotations":{\${afscp_owned_annotations}}},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"api","image":"example.invalid/afscp:latest"}]}}}},{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"afscp-bootstrap","namespace":"agentsmith","labels":{\${afscp_owned_labels},"app.kubernetes.io/component":"afscp"},"annotations":{\${afscp_owned_annotations}}},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"bootstrap","image":"example.invalid/afscp:latest"}]}}}},{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"afscp-metrics","namespace":"agentsmith","labels":{\${afscp_owned_labels},"app.kubernetes.io/component":"afscp"},"annotations":{\${afscp_owned_annotations}}},"spec":{"template":{"spec":{"containers":[{"name":"metrics","image":"example.invalid/afscp:latest"}]}}}}]}
JSON
    return
  fi

  cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"afscp-api","namespace":"agentsmith","labels":{\${afscp_owned_labels},"app.kubernetes.io/component":"afscp"},"annotations":{\${afscp_owned_annotations}}},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"api","image":"example.invalid/afscp:latest"}]}}}},{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"afscp-bootstrap","namespace":"agentsmith","labels":{\${afscp_owned_labels},"app.kubernetes.io/component":"afscp"},"annotations":{\${afscp_owned_annotations}}},"spec":{"template":{"spec":{"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"$afscp_pvc_name"}}],"containers":[{"name":"bootstrap","image":"example.invalid/afscp:latest"}]}}}},{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"agentsmith-web","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"agentsmith-web"},"annotations":{}},"spec":{"template":{"spec":{"containers":[{"name":"web","image":"example.invalid/web:latest"}]}}}}]}
JSON
}

print_afscp_cache_json() {
  local selector="\${1:-}"
  local cache_mode="\${FAKE_KUBECTL_AFSCP_CACHE_MODE:-default}"

  if [[ "$cache_mode" == "owner_scope" ]]; then
    case "$selector" in
      "app.kubernetes.io/name=juicefs-mount,volume-id=$afscp_unique_id")
        cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"juicefs-pvc-owner-pod","namespace":"kube-system","labels":{"app.kubernetes.io/name":"juicefs-mount"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolumeClaim","name":"$afscp_pvc_name","uid":"$afscp_pvc_uid"}]}},{"apiVersion":"v1","kind":"Pod","metadata":{"name":"juicefs-secret-owner-pod","namespace":"kube-system","labels":{"app.kubernetes.io/name":"juicefs-mount"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"Secret","name":"$afscp_live_secret_base","uid":"secret-owner-uid"}]}},{"apiVersion":"v1","kind":"Pod","metadata":{"name":"juicefs-strong-volume-id-pod","namespace":"kube-system","labels":{"app.kubernetes.io/name":"juicefs-mount","volume-id":"$afscp_unique_id"},"annotations":{"juicefs/cache":"true"}}}]}
JSON
        return
        ;;
      "volume-id=$afscp_unique_id")
        cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"juicefs-pv-uid-owner-pod","namespace":"kube-system","labels":{"app.kubernetes.io/name":"juicefs-mount"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"Secret","name":"not-the-pv","uid":"$afscp_pv_uid"}]}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-secret-name-owner-secret","namespace":"kube-system","labels":{"juicefs/secret":"true"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"Secret","name":"$afscp_live_secret_base","uid":"secret-owner-uid"}]},"data":{"token":"plain-secret-value"}}]}
JSON
        return
        ;;
    esac
  fi

  case "$selector" in
    "app.kubernetes.io/name=juicefs-mount,volume-id=$afscp_unique_id")
      cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"juicefs-agentsmith-afscp-default-volume","namespace":"kube-system","labels":{"app.kubernetes.io/name":"juicefs-mount","volume-id":"$afscp_unique_id"},"annotations":{"juicefs/pv-name":"$afscp_pv_name","juicefs/pvc":"agentsmith/$afscp_pvc_name"}}}]}
JSON
      return
      ;;
    "volume-id=$afscp_unique_id")
      cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"juicefs-agentsmith-afscp-default-volume","namespace":"kube-system","labels":{"app.kubernetes.io/name":"juicefs-mount","volume-id":"$afscp_unique_id"},"annotations":{"juicefs/pv-name":"$afscp_pv_name","juicefs/pvc":"agentsmith/$afscp_pvc_name"}}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-agentsmith-afscp-default-volume","namespace":"kube-system","labels":{"juicefs/secret":"true","volume-id":"$afscp_unique_id"},"annotations":{"juicefs/pv-name":"$afscp_pv_name","juicefs/pvc":"agentsmith/$afscp_pvc_name","juicefs/secret-name":"$afscp_rendered_secret"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolume","name":"$afscp_pv_name","uid":"$afscp_pv_uid"}]},"data":{"token":"plain-secret-value"}}]}
JSON
      return
      ;;
  esac

  cat <<JSON
{"apiVersion":"v1","kind":"List","items":[]}
JSON
}

print_afscp_generated_secrets_json() {
  local cache_mode="\${FAKE_KUBECTL_AFSCP_CACHE_MODE:-default}"

  if [[ "$cache_mode" == "owner_scope" ]]; then
    cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-pvc-uid-owner-secret","namespace":"kube-system","labels":{"juicefs/secret":"true"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolumeClaim","name":"$afscp_pvc_name","uid":"$afscp_pvc_uid"}]},"data":{"token":"plain-secret-value"}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-pvc-name-owner-secret","namespace":"kube-system","labels":{"juicefs/secret":"true"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolumeClaim","name":"$afscp_pvc_name","uid":"foreign-pvc-owner-uid"}]},"data":{"token":"plain-secret-value"}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-pv-name-owner-secret","namespace":"kube-system","labels":{"juicefs/secret":"true","volume-id":"$afscp_unique_id"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolume","name":"$afscp_pv_name","uid":"foreign-pv-owner-uid"}]},"data":{"token":"plain-secret-value"}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-pv-uid-owner-secret","namespace":"kube-system","labels":{"juicefs/secret":"true"},"annotations":{"juicefs/cache":"true"},"ownerReferences":[{"apiVersion":"v1","kind":"Secret","name":"not-the-pv","uid":"$afscp_pv_uid"}]},"data":{"token":"plain-secret-value"}}]}
JSON
    return
  fi

  cat <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-agentsmith-afscp-default-volume","namespace":"kube-system","labels":{"juicefs/secret":"true","volume-id":"$afscp_unique_id"},"annotations":{"juicefs/pv-name":"$afscp_pv_name","juicefs/pvc":"agentsmith/$afscp_pvc_name","juicefs/secret-name":"$afscp_rendered_secret"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolume","name":"$afscp_pv_name","uid":"$afscp_pv_uid"}]},"data":{"token":"plain-secret-value"}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"juicefs-other-volume","namespace":"kube-system","labels":{"juicefs/secret":"true","volume-id":"other-unique-id"},"annotations":{"juicefs/pv-name":"other-volume","juicefs/pvc":"foreign/$afscp_pvc_name"},"ownerReferences":[{"apiVersion":"v1","kind":"PersistentVolume","name":"other-volume","uid":"other-pv-uid"}]},"data":{"token":"other-secret-value"}}]}
JSON
}

label_selector_arg() {
  local previous=""
  local label_selector=""

  for arg in "$@"; do
    if [[ "$previous" == "-l" || "$previous" == "--selector" ]]; then
      label_selector="$arg"
    fi
    case "$arg" in
      -l=*)
        label_selector="\${arg#-l=}"
        ;;
      --selector=*)
        label_selector="\${arg#--selector=}"
        ;;
    esac
    previous="$arg"
  done

  printf '%s' "$label_selector"
}

namespace_arg() {
  local previous=""
  local namespace=""

  for arg in "$@"; do
    if [[ "$previous" == "--namespace" || "$previous" == "-n" ]]; then
      namespace="$arg"
    fi
    case "$arg" in
      --namespace=*)
        namespace="\${arg#--namespace=}"
        ;;
      -n=*)
        namespace="\${arg#-n=}"
        ;;
    esac
    previous="$arg"
  done

  printf '%s' "$namespace"
}

has_all_namespaces_arg() {
  for arg in "$@"; do
    if [[ "$arg" == "--all-namespaces" || "$arg" == "-A" ]]; then
      return 0
    fi
  done

  return 1
}

if [[ "$command_name" == "create" ]]; then
  manifest_sources=()
  expanded_sources=()
  output_format=""
  dry_run_client=0
  previous=""

  for arg in "$@"; do
    if [[ "$previous" == "-f" || "$previous" == "--filename" ]]; then
      manifest_sources+=("$arg")
    fi
    if [[ "$previous" == "-o" || "$previous" == "--output" ]]; then
      output_format="$arg"
    fi
    case "$arg" in
      -f=*)
        manifest_sources+=("\${arg#-f=}")
        ;;
      --filename=*)
        manifest_sources+=("\${arg#--filename=}")
        ;;
      -o=*)
        output_format="\${arg#-o=}"
        ;;
      --output=*)
        output_format="\${arg#--output=}"
        ;;
      --dry-run=client)
        dry_run_client=1
        ;;
    esac
    previous="$arg"
  done

  if [[ "\${#manifest_sources[@]}" == "0" || "$output_format" != "json" || "$dry_run_client" != "1" ]]; then
    echo "unexpected fake kubectl create args: $*" >&2
    exit 2
  fi

  for source in "\${manifest_sources[@]}"; do
    if [[ -d "$source" ]]; then
      for candidate in "$source"/*.json "$source"/*.yaml "$source"/*.yml; do
        [[ -f "$candidate" ]] && expanded_sources+=("$candidate")
      done
    elif [[ -f "$source" ]]; then
      expanded_sources+=("$source")
    else
      printf 'error: the path "%s" does not exist\\n' "$source" >&2
      exit 1
    fi
  done

  node --input-type=module - "\${expanded_sources[@]}" <<'DECODE_NODE'
import fs from 'node:fs';
import path from 'node:path';

const files = process.argv.slice(2);
const LF = String.fromCharCode(10);
const CR = String.fromCharCode(13);

function rawLines(raw) {
  return raw.split(LF).map((line) => line.endsWith(CR) ? line.slice(0, -1) : line);
}

function countIndent(line) {
  let count = 0;
  while (count < line.length && line[count] === ' ') {
    count += 1;
  }
  return count;
}

function stripQuotes(value) {
  const text = String(value ?? '').trim();
  if (text.length >= 2) {
    const first = text[0];
    const last = text[text.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return text.slice(1, -1);
    }
  }
  return text;
}

function scalarAfter(line, key) {
  const trimmed = line.trim();
  const prefix = key + ':';
  if (!trimmed.startsWith(prefix)) {
    return undefined;
  }
  return stripQuotes(trimmed.slice(prefix.length));
}

function firstValue(raw, key) {
  for (const line of rawLines(raw)) {
    const value = scalarAfter(line, key);
    if (value !== undefined) {
      return value;
    }
  }
  return undefined;
}

function topLevelValue(raw, key) {
  for (const line of rawLines(raw)) {
    if (countIndent(line) !== 0) {
      continue;
    }
    const value = scalarAfter(line, key);
    if (value !== undefined) {
      return value;
    }
  }
  return undefined;
}

function nestedValue(raw, parent, key) {
  const lines = rawLines(raw);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() !== parent + ':') {
      continue;
    }
    const parentIndent = countIndent(line);
    for (let child = index + 1; child < lines.length; child += 1) {
      const childLine = lines[child];
      if (childLine.trim() === '') {
        continue;
      }
      if (countIndent(childLine) <= parentIndent) {
        break;
      }
      const value = scalarAfter(childLine, key);
      if (value !== undefined) {
        return value;
      }
    }
  }
  return undefined;
}

function inlineFieldAfter(raw, marker, key) {
  const markerIndex = raw.indexOf(marker + ':');
  if (markerIndex === -1) {
    return undefined;
  }
  const keyMarker = key + ':';
  const keyIndex = raw.indexOf(keyMarker, markerIndex);
  if (keyIndex === -1) {
    return undefined;
  }
  let end = keyIndex + keyMarker.length;
  while (end < raw.length && raw[end] === ' ') {
    end += 1;
  }
  let cursor = end;
  while (cursor < raw.length && ![',', '}', ']', LF].includes(raw[cursor])) {
    cursor += 1;
  }
  return stripQuotes(raw.slice(end, cursor));
}

function metadataValue(raw, key) {
  return nestedValue(raw, 'metadata', key);
}

function labelsFor(raw) {
  const labels = {};
  if (raw.includes('app.kubernetes.io/name: agentsmith')) {
    labels['app.kubernetes.io/name'] = 'agentsmith';
  }
  if (raw.includes('app.kubernetes.io/part-of: agentsmith-deploy')) {
    labels['app.kubernetes.io/part-of'] = 'agentsmith-deploy';
  }
  if (raw.includes('app.kubernetes.io/component: afscp')) {
    labels['app.kubernetes.io/component'] = 'afscp';
  }
  return labels;
}

function annotationsFor(raw) {
  const annotations = {};
  if (raw.includes('rendered-by: agentsmith-unified-deploy')) {
    annotations['rendered-by'] = 'agentsmith-unified-deploy';
  }
  return annotations;
}

function buildMetadata(raw) {
  const metadata = {
    name: metadataValue(raw, 'name')
  };
  const namespace = metadataValue(raw, 'namespace');
  if (namespace) {
    metadata.namespace = namespace;
  }
  const labels = labelsFor(raw);
  if (Object.keys(labels).length > 0) {
    metadata.labels = labels;
  }
  const annotations = annotationsFor(raw);
  if (Object.keys(annotations).length > 0) {
    metadata.annotations = annotations;
  }
  return metadata;
}

function buildPodSpec(raw) {
  const podSpec = {};
  const container = {
    name: firstValue(raw, 'name') || 'app'
  };
  const image = firstValue(raw, 'image');
  if (image) {
    container.image = image;
  }

  const secretKeyRefName =
    nestedValue(raw, 'secretKeyRef', 'name') || inlineFieldAfter(raw, 'secretKeyRef', 'name');
  const secretKeyRefKey =
    nestedValue(raw, 'secretKeyRef', 'key') || inlineFieldAfter(raw, 'secretKeyRef', 'key');
  if (secretKeyRefName || secretKeyRefKey) {
    container.env = [{
      name: 'DATABASE_URL',
      valueFrom: {
        secretKeyRef: {
          name: secretKeyRefName,
          key: secretKeyRefKey
        }
      }
    }];
    if (raw.includes('optional: true')) {
      container.env[0].valueFrom.secretKeyRef.optional = true;
    }
  }

  const envFromSecretName =
    nestedValue(raw, 'secretRef', 'name') || inlineFieldAfter(raw, 'secretRef', 'name');
  if (envFromSecretName && !secretKeyRefName) {
    container.envFrom = [{ secretRef: { name: envFromSecretName } }];
    if (raw.includes('optional: true')) {
      container.envFrom[0].secretRef.optional = true;
    }
  }

  podSpec.containers = [container];

  const pvcClaimName =
    nestedValue(raw, 'persistentVolumeClaim', 'claimName') ||
    inlineFieldAfter(raw, 'persistentVolumeClaim', 'claimName');
  if (pvcClaimName) {
    podSpec.volumes = [{
      name: 'files',
      persistentVolumeClaim: {
        claimName: pvcClaimName
      }
    }];
  }

  const secretName =
    firstValue(raw, 'secretName') ||
    nestedValue(raw, 'secret', 'name') ||
    inlineFieldAfter(raw, 'secret', 'secretName') ||
    inlineFieldAfter(raw, 'secret', 'name');
  if (secretName) {
    const itemKey = firstValue(raw, 'key') || inlineFieldAfter(raw, 'items', 'key');
    if (raw.includes('projected:')) {
      podSpec.volumes = [{
        name: 'projected-app-ca',
        projected: {
          sources: [{
            secret: {
              name: secretName,
              items: itemKey ? [{ key: itemKey, path: 'ca.crt' }] : undefined
            }
          }]
        }
      }];
      if (raw.includes('optional: true')) {
        podSpec.volumes[0].projected.sources[0].secret.optional = true;
      }
    } else {
      podSpec.volumes = [{
        name: 'app-ca',
        secret: {
          secretName,
          items: itemKey ? [{ key: itemKey, path: 'ca.crt' }] : undefined
        }
      }];
      if (raw.includes('optional: true')) {
        podSpec.volumes[0].secret.optional = true;
      }
    }
  }

  return podSpec;
}

function parseResource(raw) {
  const trimmed = raw.trim();
  if (trimmed === '') {
    return undefined;
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return JSON.parse(trimmed);
  }

  const kind = topLevelValue(trimmed, 'kind');
  if (!kind) {
    return undefined;
  }

  const resource = {
    apiVersion: topLevelValue(trimmed, 'apiVersion'),
    kind,
    metadata: buildMetadata(trimmed)
  };

  if (kind === 'PersistentVolume') {
    resource.spec = {
      persistentVolumeReclaimPolicy: firstValue(trimmed, 'persistentVolumeReclaimPolicy'),
      storageClassName: firstValue(trimmed, 'storageClassName'),
      claimRef: {
        namespace: nestedValue(trimmed, 'claimRef', 'namespace'),
        name: nestedValue(trimmed, 'claimRef', 'name')
      },
      csi: {
        driver: nestedValue(trimmed, 'csi', 'driver'),
        fsType: nestedValue(trimmed, 'csi', 'fsType'),
        volumeHandle: nestedValue(trimmed, 'csi', 'volumeHandle'),
        nodePublishSecretRef: {
          name: nestedValue(trimmed, 'nodePublishSecretRef', 'name'),
          namespace: nestedValue(trimmed, 'nodePublishSecretRef', 'namespace')
        }
      }
    };
    return resource;
  }

  if (kind === 'PersistentVolumeClaim') {
    resource.spec = {
      storageClassName: firstValue(trimmed, 'storageClassName'),
      volumeName: firstValue(trimmed, 'volumeName')
    };
    return resource;
  }

  const podSpec = buildPodSpec(trimmed);
  if (kind === 'Pod') {
    resource.spec = podSpec;
  } else if (kind === 'CronJob') {
    resource.spec = { jobTemplate: { spec: { template: { spec: podSpec } } } };
  } else {
    resource.spec = { template: { spec: podSpec } };
  }
  return resource;
}

function splitDocuments(raw) {
  const documents = [];
  let current = [];
  for (const line of rawLines(raw)) {
    if (line.trim() === '---') {
      documents.push(current.join(LF));
      current = [];
      continue;
    }
    current.push(line);
  }
  documents.push(current.join(LF));
  return documents;
}

const resources = [];
for (const file of files) {
  const raw = fs.readFileSync(file, 'utf8');
  if (path.extname(file) === '.json') {
    resources.push(JSON.parse(raw));
    continue;
  }
  for (const document of splitDocuments(raw)) {
    const resource = parseResource(document);
    if (resource) {
      resources.push(resource);
    }
  }
}

process.stdout.write(JSON.stringify({
  apiVersion: 'v1',
  kind: 'List',
  items: resources
}) + LF);
DECODE_NODE
  exit 0
fi

if [[ "$command_name" == "version" ]]; then
  if [[ "\${FAKE_KUBECTL_VERSION_MODE:-json}" == "nonjson" ]]; then
    printf '%s\\n' "kubectl client output token=plain-secret-value client=v1.30.0"
    exit 0
  fi
  printf '%s\\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
  exit 0
fi

if [[ "$command_name" == "get" ]]; then
  resource="\${args[$((command_index + 1))]:-}"
  name="\${args[$((command_index + 2))]:-}"
  afscp_mode="\${FAKE_KUBECTL_AFSCP_MODE:-not_found}"
  label_selector="$(label_selector_arg "$@")"
  if [[ "$resource" == "pv" || "$resource" == "persistentvolume" || "$resource" == "persistentvolumes" ]]; then
    if [[ "$name" != "$afscp_pv_name" || "$afscp_mode" == "not_found" ]]; then
      printf 'Error from server (NotFound): persistentvolumes "%s" not found\\n' "$name" >&2
      exit 1
    fi
    print_afscp_pv_json "$afscp_mode" "$name"
    exit 0
  fi
  if [[ "$resource" == "pvc" || "$resource" == "persistentvolumeclaim" || "$resource" == "persistentvolumeclaims" ]]; then
    if [[ "$name" != "$afscp_pvc_name" || "$afscp_mode" == "not_found" ]]; then
      printf 'Error from server (NotFound): persistentvolumeclaims "%s" not found\\n' "$name" >&2
      exit 1
    fi
    print_afscp_pvc_json "$afscp_mode" "$name"
    exit 0
  fi
  if [[ "$resource" == "daemonset" || "$resource" == "daemonsets" || "$resource" == "ds" ]]; then
    namespace="$(namespace_arg "$@")"
    if has_all_namespaces_arg "$@"; then
      if [[ "\${FAKE_KUBECTL_AFSCP_NODE_WORKLOAD_MODE:-present}" == "missing" ]]; then
        printf '%s\\n' '{"apiVersion":"v1","kind":"List","items":[]}'
        exit 0
      fi
      printf '{"apiVersion":"v1","kind":"List","items":['
      print_afscp_csi_node_daemonset_json
      printf ']}\\n'
      exit 0
    fi
    if [[ "$name" != "juicefs-csi-node" ]]; then
      printf 'Error from server (NotFound): daemonsets.apps "%s" not found\\n' "$name" >&2
      exit 1
    fi
    if [[ "\${FAKE_KUBECTL_AFSCP_NODE_WORKLOAD_MODE:-present}" == "missing" || "$namespace" != "$afscp_node_namespace" ]]; then
      printf 'Error from server (NotFound): daemonsets.apps "%s" not found\\n' "$name" >&2
      exit 1
    fi
    print_afscp_csi_node_daemonset_json
    exit 0
  fi
  if [[ "$resource" == "deployment,statefulset,daemonset,job,cronjob,replicaset,pod" ]]; then
    print_afscp_workloads_json "$afscp_mode"
    exit 0
  fi
  if [[ "$resource" == "pod,secret" ]]; then
    print_afscp_cache_json "$label_selector"
    exit 0
  fi
  if [[ "$resource" == "secret" && "$label_selector" == "juicefs/secret=true" ]]; then
    print_afscp_generated_secrets_json
    exit 0
  fi
  if [[ "$resource" == "secret" ]]; then
    namespace=""
    output_format=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == "--namespace" ]]; then
        namespace="$arg"
      fi
      if [[ "$previous" == "-o" || "$previous" == "--output" ]]; then
        output_format="$arg"
      fi
      case "$arg" in
        --namespace=*)
          namespace="\${arg#--namespace=}"
          ;;
        --output=*)
          output_format="\${arg#--output=}"
          ;;
      esac
      previous="$arg"
    done
    if [[ -z "$name" || -z "$namespace" || "$output_format" != "json" ]]; then
      echo "unexpected fake kubectl get secret args: $*" >&2
      exit 2
    fi

    if [[ "$name" == "$afscp_rendered_secret" || "$name" == "$afscp_live_secret_base" ]]; then
      print_afscp_volume_secret_json "$name"
      exit 0
    fi

    if [[ "$name" == "$afscp_postgres_ca_secret" || "$name" == "$afscp_object_storage_ca_secret" ]]; then
      case "\${FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE:-present}" in
        present)
          print_afscp_ca_secret_json "$name"
          exit 0
          ;;
        missing_postgres_ca)
          if [[ "$name" == "$afscp_postgres_ca_secret" ]]; then
            printf 'Error from server (NotFound): secrets "%s" not found\\n' "$name" >&2
            exit 1
          fi
          print_afscp_ca_secret_json "$name"
          exit 0
          ;;
        missing_object_storage_ca)
          if [[ "$name" == "$afscp_object_storage_ca_secret" ]]; then
            printf 'Error from server (NotFound): secrets "%s" not found\\n' "$name" >&2
            exit 1
          fi
          print_afscp_ca_secret_json "$name"
          exit 0
          ;;
        missing_ca_crt)
          printf '%s\\n' "{\"kind\":\"Secret\",\"metadata\":{\"name\":\"$name\"},\"data\":{\"other\":\"dmFsdWU=\"}}"
          exit 0
          ;;
        *)
          echo "unknown FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE: \${FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE}" >&2
          exit 2
          ;;
      esac
    fi

    case "\${FAKE_KUBECTL_SECRET_MODE:-present}" in
      present)
        node --input-type=module - "$name" "\${FAKE_KUBECTL_SECRET_KEYS:-DATABASE_URL}" "\${FAKE_KUBECTL_SECRET_VALUE:-plain-secret-value}" <<'SECRET_NODE'
const [name, keysCsv, secretValue] = process.argv.slice(2);
const data = {};
for (const key of keysCsv.split(',')) {
  if (key.trim() !== '') {
    data[key.trim()] = secretValue;
  }
}
process.stdout.write(JSON.stringify({ kind: 'Secret', metadata: { name }, data }) + '\\n');
SECRET_NODE
        exit 0
        ;;
      missing)
        printf 'Error from server (NotFound): secrets "%s" not found token=tail-secret-value\\n' "$name" >&2
        exit 1
        ;;
      error)
        printf '%s\\n' "forbidden to read secret token=tail-secret-value client_secret=tail-client-secret-value" >&2
        exit 1
        ;;
      *)
        echo "unknown FAKE_KUBECTL_SECRET_MODE: \${FAKE_KUBECTL_SECRET_MODE}" >&2
        exit 2
        ;;
    esac
  fi
  if [[ "$resource" != "job" ]]; then
    echo "unexpected fake kubectl get resource: $*" >&2
    exit 2
  fi

  case "\${FAKE_KUBECTL_JOB_MODE:-not_found}" in
    not_found)
      printf 'Error from server (NotFound): jobs.batch "%s" not found\\n' "$name" >&2
      exit 1
      ;;
    completed)
      cat <<JSON
{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"$name","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"agentsmith","app.kubernetes.io/part-of":"agentsmith-deploy"},"annotations":{"rendered-by":"agentsmith-unified-deploy"}},"status":{"conditions":[{"type":"Complete","status":"True"}]}}
JSON
      exit 0
      ;;
    missing_ownership)
      cat <<JSON
{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"$name","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"agentsmith"},"annotations":{}},"status":{"conditions":[{"type":"Complete","status":"True"}]}}
JSON
      exit 0
      ;;
    active)
      cat <<JSON
{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"$name","namespace":"agentsmith","labels":{"app.kubernetes.io/name":"agentsmith","app.kubernetes.io/part-of":"agentsmith-deploy"},"annotations":{"rendered-by":"agentsmith-unified-deploy"}},"status":{"active":1,"conditions":[{"type":"Complete","status":"False"}]}}
JSON
      exit 0
      ;;
    invalid_json)
      printf '{not-json\\n'
      exit 0
      ;;
    error)
      echo "fake get failure" >&2
      exit 1
      ;;
    *)
      echo "unknown FAKE_KUBECTL_JOB_MODE: \${FAKE_KUBECTL_JOB_MODE}" >&2
      exit 2
      ;;
  esac
fi

if [[ "$command_name" == "exec" ]]; then
  resource="\${args[$((command_index + 1))]:-}"
  namespace=""
  container=""
  readable_path=""
  previous=""
  after_separator=0
  after_test=0
  for arg in "$@"; do
    if [[ "$previous" == "--namespace" || "$previous" == "-n" ]]; then
      namespace="$arg"
    fi
    if [[ "$previous" == "-c" || "$previous" == "--container" ]]; then
      container="$arg"
    fi
    case "$arg" in
      --namespace=*)
        namespace="\${arg#--namespace=}"
        ;;
      -n=*)
        namespace="\${arg#-n=}"
        ;;
      --container=*)
        container="\${arg#--container=}"
        ;;
    esac
    if [[ "$after_test" == "1" && "$previous" == "-r" ]]; then
      readable_path="$arg"
    fi
    if [[ "$after_separator" == "1" && "$arg" == "test" ]]; then
      after_test=1
    fi
    if [[ "$arg" == "--" ]]; then
      after_separator=1
    fi
    previous="$arg"
  done

  if [[ "$resource" != "ds/juicefs-csi-node" || "$container" != "juicefs-plugin" || -z "$readable_path" ]]; then
    echo "unexpected fake kubectl exec args: $*" >&2
    exit 2
  fi
  if [[ -z "$namespace" ]]; then
    namespace="$afscp_node_namespace"
  fi
  if [[ "$namespace" != "$afscp_node_namespace" ]]; then
    printf 'Error from server (NotFound): daemonsets.apps "juicefs-csi-node" not found\\n' >&2
    exit 1
  fi

  case "\${FAKE_KUBECTL_AFSCP_NODE_FILE_MODE:-readable}" in
    readable)
      exit 0
      ;;
    missing)
      printf 'test: %s: No such file or directory\\n' "$readable_path" >&2
      exit 1
      ;;
    *)
      echo "unknown FAKE_KUBECTL_AFSCP_NODE_FILE_MODE: \${FAKE_KUBECTL_AFSCP_NODE_FILE_MODE}" >&2
      exit 2
      ;;
  esac
fi

if [[ "$command_name" == "delete" ]]; then
  resource="\${args[$((command_index + 1))]:-}"
  name="\${args[$((command_index + 2))]:-}"
  case "$resource" in
    job|deployment|statefulset|daemonset|cronjob|pod|secret|pvc|pv) ;;
    *)
    echo "unexpected fake kubectl delete resource: $*" >&2
    exit 2
      ;;
  esac

  case "\${FAKE_KUBECTL_DELETE_MODE:-success}" in
    success)
      printf '%s "%s" deleted\\n' "$resource" "$name"
      exit 0
      ;;
    not_found)
      printf 'Error from server (NotFound): %s "%s" not found\\n' "$resource" "$name" >&2
      exit 1
      ;;
    error)
      echo "fake delete failure" >&2
      exit 1
      ;;
    *)
      echo "unknown FAKE_KUBECTL_DELETE_MODE: \${FAKE_KUBECTL_DELETE_MODE}" >&2
      exit 2
      ;;
  esac
fi

if [[ "$command_name" == "apply" ]]; then
  seen_manifest_source=0
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-f" || "$previous" == "--filename" ]]; then
      seen_manifest_source=1
      if [[ -d "$arg" ]]; then
        has_manifest=0
        for candidate in "$arg"/*.json "$arg"/*.yaml "$arg"/*.yml; do
          if [[ -f "$candidate" ]]; then
            has_manifest=1
            break
          fi
        done
        if [[ "$has_manifest" == "0" ]]; then
          printf 'error: error reading [%s]: recognized file extensions are [.json .yaml .yml]\\n' "$arg" >&2
          exit 1
        fi
      elif [[ -f "$arg" ]]; then
        case "$arg" in
          *.json|*.yaml|*.yml) ;;
          *)
            printf 'error: error reading [%s]: recognized file extensions are [.json .yaml .yml]\\n' "$arg" >&2
            exit 1
            ;;
        esac
      else
        printf 'error: the path "%s" does not exist\\n' "$arg" >&2
        exit 1
      fi
    fi
    previous="$arg"
  done
  if [[ "$seen_manifest_source" == "0" ]]; then
    echo "error: apply requires -f" >&2
    exit 1
  fi
  case "\${FAKE_KUBECTL_APPLY_MODE:-success}" in
    success)
      ;;
    fail)
      {
        printf '%s\\n' "kubectl apply failure detail line 1"
        printf '%s\\n' "kubectl apply failure detail line 2"
        printf '%s\\n' 'Error from server (Invalid): deployment.apps "agentsmith-web" is invalid'
        printf '%s\\n' "spec.template.spec.containers[0].image: Required value"
        printf '%s\\n' "metadata.managedFields: field manager conflict client_secret=tail-client-secret-value"
        printf '%s\\n' "hint: inspect rendered manifests for owner handoff access_key=tail-access-key-value"
      } >&2
      exit 1
      ;;
    *)
      echo "unknown FAKE_KUBECTL_APPLY_MODE: \${FAKE_KUBECTL_APPLY_MODE}" >&2
      exit 2
      ;;
  esac
  printf '%s\\n' "\${FAKE_KUBECTL_APPLY_OUTPUT:-deployment.apps/agentsmith-web}"
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

run_apply() {
  local rendered_manifests="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"
  if (($# >= 3)); then
    shift 3
  else
    shift 2
  fi

  run_apply_raw "$VALID_CONTRACT" "$rendered_manifests" "$output_dir" "$target_profile" "$@"
}

run_apply_raw() {
  local release_contract="$1"
  local rendered_manifests="$2"
  local output_dir="$3"
  local target_profile="$4"
  shift 4

  local command=(
    bash "$ROOT_DIR/scripts/verify-release.sh" --apply
    --release-contract "$release_contract"
    --rendered-manifests "$rendered_manifests"
    --target-profile "$target_profile"
    --namespace agentsmith
    --output-dir "$output_dir"
    --kubectl "$FAKE_KUBECTL"
  )
  command+=("$@")

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
    FAKE_KUBECTL_VERSION_MODE="${FAKE_KUBECTL_VERSION_MODE:-json}" \
    FAKE_KUBECTL_JOB_MODE="${FAKE_KUBECTL_JOB_MODE:-not_found}" \
    FAKE_KUBECTL_DELETE_MODE="${FAKE_KUBECTL_DELETE_MODE:-success}" \
    FAKE_KUBECTL_APPLY_MODE="${FAKE_KUBECTL_APPLY_MODE:-success}" \
    FAKE_KUBECTL_SECRET_MODE="${FAKE_KUBECTL_SECRET_MODE:-present}" \
    FAKE_KUBECTL_SECRET_KEYS="${FAKE_KUBECTL_SECRET_KEYS:-DATABASE_URL}" \
    FAKE_KUBECTL_SECRET_VALUE="${FAKE_KUBECTL_SECRET_VALUE:-plain-secret-value}" \
    FAKE_KUBECTL_APPLY_OUTPUT="${FAKE_KUBECTL_APPLY_OUTPUT:-deployment.apps/agentsmith-web}" \
    FAKE_KUBECTL_AFSCP_MODE="${FAKE_KUBECTL_AFSCP_MODE:-not_found}" \
    FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE="${FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE:-valid}" \
    FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE="${FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE:-present}" \
    FAKE_KUBECTL_AFSCP_NODE_FILE_MODE="${FAKE_KUBECTL_AFSCP_NODE_FILE_MODE:-readable}" \
    FAKE_KUBECTL_AFSCP_MOUNT_NAMESPACE="${FAKE_KUBECTL_AFSCP_MOUNT_NAMESPACE:-kube-system}" \
    FAKE_KUBECTL_AFSCP_CACHE_MODE="${FAKE_KUBECTL_AFSCP_CACHE_MODE:-default}" \
    "${command[@]}"
}

run_apply_from_release_kit() {
  local release_kit_root="$1"
  local release_contract="$2"
  local rendered_manifests="$3"
  local output_dir="$4"
  local target_profile="$5"
  shift 5

  local command=(
    bash "$release_kit_root/scripts/verify-release.sh" --apply
    --release-contract "$release_contract"
    --rendered-manifests "$rendered_manifests"
    --target-profile "$target_profile"
    --namespace agentsmith
    --output-dir "$output_dir"
    --kubectl "$FAKE_KUBECTL"
  )
  command+=("$@")

  FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
    FAKE_KUBECTL_VERSION_MODE="${FAKE_KUBECTL_VERSION_MODE:-json}" \
    FAKE_KUBECTL_JOB_MODE="${FAKE_KUBECTL_JOB_MODE:-not_found}" \
    FAKE_KUBECTL_DELETE_MODE="${FAKE_KUBECTL_DELETE_MODE:-success}" \
    FAKE_KUBECTL_APPLY_MODE="${FAKE_KUBECTL_APPLY_MODE:-success}" \
    FAKE_KUBECTL_SECRET_MODE="${FAKE_KUBECTL_SECRET_MODE:-present}" \
    FAKE_KUBECTL_SECRET_KEYS="${FAKE_KUBECTL_SECRET_KEYS:-DATABASE_URL}" \
    FAKE_KUBECTL_SECRET_VALUE="${FAKE_KUBECTL_SECRET_VALUE:-plain-secret-value}" \
    FAKE_KUBECTL_APPLY_OUTPUT="${FAKE_KUBECTL_APPLY_OUTPUT:-deployment.apps/agentsmith-web}" \
    FAKE_KUBECTL_AFSCP_MODE="${FAKE_KUBECTL_AFSCP_MODE:-not_found}" \
    FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE="${FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE:-valid}" \
    FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE="${FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE:-present}" \
    FAKE_KUBECTL_AFSCP_NODE_FILE_MODE="${FAKE_KUBECTL_AFSCP_NODE_FILE_MODE:-readable}" \
    FAKE_KUBECTL_AFSCP_MOUNT_NAMESPACE="${FAKE_KUBECTL_AFSCP_MOUNT_NAMESPACE:-kube-system}" \
    FAKE_KUBECTL_AFSCP_CACHE_MODE="${FAKE_KUBECTL_AFSCP_CACHE_MODE:-default}" \
    "${command[@]}"
}

assert_apply_report() {
  local report_file="$1"
  local expected_mode="$2"
  local expected_operator_run_id="${3:-}"
  local expected_profile="${4:-$TARGET_PROFILE}"
  local expected_resource_ref_count="${5:-1}"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_mode" "$expected_operator_run_id" "$expected_profile" "$expected_resource_ref_count" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedMode, expectedOperatorRunId, expectedProfile, expectedResourceRefCountRaw] = process.argv.slice(2);
const expectedResourceRefCount = Number(expectedResourceRefCountRaw);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema_version !== 'agentsmith.kubernetes-apply-report/v1') {
  throw new Error(`unexpected schema_version: ${report.schema_version}`);
}
if (report.scope !== 'kubernetes_apply_with_pre_apply_controls') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('apply report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.mode !== expectedMode) {
  throw new Error(`unexpected mode: ${report.mode}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if (report.namespace !== 'agentsmith') {
  throw new Error(`unexpected namespace: ${report.namespace}`);
}
if (!report.release_contract?.input_sha256?.startsWith('sha256:')) {
  throw new Error('release contract digest is missing');
}
if (!Array.isArray(report.resource_refs) || report.resource_refs.length !== expectedResourceRefCount) {
  throw new Error('apply report must include manifest resource refs');
}
if (!Array.isArray(report.kubectl_resource_refs) || report.kubectl_resource_refs[0] !== 'deployment.apps/agentsmith-web') {
  throw new Error('apply report must include kubectl resource refs');
}
if (!Array.isArray(report.pre_apply_job_replacements)) {
  throw new Error('apply report must include stable pre_apply_job_replacements array');
}
if (report.pre_apply_job_replacements.length !== 0) {
  throw new Error('non-Job apply report must not include pre-apply Job replacements');
}
if (!report.pre_apply_reconcile || typeof report.pre_apply_reconcile !== 'object' || Array.isArray(report.pre_apply_reconcile)) {
  throw new Error('apply report must retain legacy pre_apply_reconcile object');
}
const controls = report.pre_apply_controls;
if (!controls || typeof controls !== 'object' || Array.isArray(controls)) {
  throw new Error('apply report must include pre_apply_controls object');
}
for (const key of [
  'secret_preflight',
  'afscp_juicefs_csi_tls_readiness',
  'afscp_static_juicefs_pv_reconcile',
  'completed_job_replacements'
]) {
  if (!controls[key] || typeof controls[key] !== 'object' || Array.isArray(controls[key])) {
    throw new Error(`apply report pre_apply_controls missing ${key}`);
  }
  if (typeof controls[key].status !== 'string') {
    throw new Error(`apply report pre_apply_controls.${key}.status must be stable`);
  }
}
if (!Array.isArray(controls.completed_job_replacements.replacements)) {
  throw new Error('pre_apply_controls.completed_job_replacements must include replacements array');
}
if (!report.kubectl_version?.client?.gitVersion || !report.kubectl_version?.server?.gitVersion) {
  throw new Error('apply report must include kubectl client and server versions');
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('apply report must not claim a verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('apply report must not include AgentSmith product flow fields');
}
if (expectedMode === 'apply') {
  if (report.operator_run_id !== expectedOperatorRunId) {
    throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
  }
} else if ('operator_run_id' in report) {
  throw new Error('dry-run report must not include operator_run_id');
}
NODE
}

assert_unparsed_version_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.kubectl_version?.parse_status !== 'unparsed') {
  throw new Error('unparsed kubectl version output must be marked parse_status=unparsed');
}
if (!report.kubectl_version?.output_sha256?.startsWith('sha256:')) {
  throw new Error('unparsed kubectl version output must keep a sha256 digest');
}
if ('output' in report.kubectl_version) {
  throw new Error('unparsed kubectl version output must not store raw stdout');
}
if ('client' in report.kubectl_version || 'server' in report.kubectl_version) {
  throw new Error('unparsed kubectl version output must not claim parsed client/server fields');
}
if (/plain-secret-value|token=|kubectl client output/.test(serialized)) {
  throw new Error('apply report leaked raw kubectl version stdout');
}
NODE
}

assert_job_replacement_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const replacements = report.pre_apply_job_replacements;

if (report.mode !== 'apply') {
  throw new Error(`unexpected report mode: ${report.mode}`);
}
if (report.operator_run_id !== 'operator-run-job-1001') {
  throw new Error(`unexpected operator_run_id: ${report.operator_run_id}`);
}
if (!Array.isArray(report.kubectl_resource_refs) || report.kubectl_resource_refs[0] !== 'job.batch/agentsmith-bootstrap') {
  throw new Error('Job apply report must include kubectl Job resource ref');
}
if (!Array.isArray(replacements) || replacements.length !== 1) {
  throw new Error('apply report must record exactly one pre-apply Job replacement');
}

const replacement = replacements[0];
if (replacement.kind !== 'Job') {
  throw new Error(`unexpected replacement kind: ${replacement.kind}`);
}
if (replacement.name !== 'agentsmith-bootstrap') {
  throw new Error(`unexpected replacement name: ${replacement.name}`);
}
if (replacement.namespace !== 'agentsmith') {
  throw new Error(`unexpected replacement namespace: ${replacement.namespace}`);
}
if (replacement.reason !== 'completed_existing_job_replaced_before_apply') {
  throw new Error(`unexpected replacement reason: ${replacement.reason}`);
}
NODE
}

assert_no_pre_apply_job_replacements() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));

if (!Array.isArray(report.pre_apply_job_replacements)) {
  throw new Error('apply report must include stable pre_apply_job_replacements array');
}
if (report.pre_apply_job_replacements.length !== 0) {
  throw new Error('expected no pre-apply Job replacements');
}
NODE
}

assert_job_replacement_order() {
  local get_line
  local delete_line
  local apply_line

  get_line="$(grep -n '^get job agentsmith-bootstrap --namespace agentsmith -o json$' "$KUBECTL_LOG" | head -n 1 | cut -d: -f1 || true)"
  delete_line="$(grep -n '^delete job agentsmith-bootstrap --namespace agentsmith --wait=true$' "$KUBECTL_LOG" | head -n 1 | cut -d: -f1 || true)"
  apply_line="$(grep -n '^apply ' "$KUBECTL_LOG" | head -n 1 | cut -d: -f1 || true)"

  if [[ -z "$get_line" || -z "$delete_line" || -z "$apply_line" ]]; then
    cat "$KUBECTL_LOG" >&2
    fail "expected get, delete, and apply kubectl calls for Job replacement"
  fi
  if ((get_line >= delete_line || delete_line >= apply_line)); then
    cat "$KUBECTL_LOG" >&2
    fail "expected Job get before delete before apply"
  fi
}

assert_no_delete_or_apply_after_job_get() {
  grep -q '^get job agentsmith-bootstrap --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
    fail "expected kubectl get job before failing"
  if grep -Eq '^(delete job agentsmith-bootstrap|apply )' "$KUBECTL_LOG"; then
    cat "$KUBECTL_LOG" >&2
    fail "failed Job replacement preflight must not delete or apply"
  fi
}

line_number_for_log() {
  local pattern="$1"
  grep -n "$pattern" "$KUBECTL_LOG" | head -n 1 | cut -d: -f1 || true
}

assert_afscp_reconcile_order() {
  local delete_deployment_line
  local delete_job_line
  local delete_cache_pod_line
  local delete_cache_secret_line
  local delete_pvc_line
  local delete_pv_line
  local apply_line

  delete_deployment_line="$(line_number_for_log '^delete deployment afscp-api --namespace agentsmith --cascade=foreground --wait=true --timeout=120s$')"
  delete_job_line="$(line_number_for_log '^delete job afscp-bootstrap --namespace agentsmith --cascade=foreground --wait=true --timeout=120s$')"
  delete_cache_pod_line="$(line_number_for_log '^delete pod juicefs-agentsmith-afscp-default-volume --namespace kube-system --wait=true --timeout=120s$')"
  delete_cache_secret_line="$(line_number_for_log '^delete secret juicefs-agentsmith-afscp-default-volume --namespace kube-system --wait=true --timeout=120s$')"
  delete_pvc_line="$(line_number_for_log '^delete pvc afscp-default-volume --namespace agentsmith --wait=true --timeout=120s$')"
  delete_pv_line="$(line_number_for_log '^delete pv agentsmith-afscp-default-volume --wait=true --timeout=120s$')"
  apply_line="$(line_number_for_log '^apply ')"

  if [[ -z "$delete_deployment_line" || -z "$delete_job_line" || -z "$delete_cache_pod_line" || -z "$delete_cache_secret_line" || -z "$delete_pvc_line" || -z "$delete_pv_line" || -z "$apply_line" ]]; then
    cat "$KUBECTL_LOG" >&2
    fail "expected AFSCP workload/cache/PVC/PV deletes before apply"
  fi
  if ((delete_deployment_line >= delete_job_line || delete_job_line >= delete_cache_pod_line || delete_cache_pod_line >= delete_cache_secret_line || delete_cache_secret_line >= delete_pvc_line || delete_pvc_line >= delete_pv_line || delete_pv_line >= apply_line)); then
    cat "$KUBECTL_LOG" >&2
    fail "expected AFSCP reconcile deletes to happen in workload/job, cache, PVC, PV order before apply"
  fi
}

assert_afscp_reconcile_report() {
  local report_file="$1"

  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const legacySummary = report.pre_apply_reconcile?.afscp_static_juicefs_pv;
const summary = report.pre_apply_controls?.afscp_static_juicefs_pv_reconcile;

if (summary?.status !== 'reconciled') {
  throw new Error(`expected reconciled AFSCP summary, got ${summary?.status}`);
}
if (legacySummary?.status !== summary.status || legacySummary?.reason !== summary.reason) {
  throw new Error('legacy AFSCP reconcile summary must stay compatible with pre_apply_controls');
}
if (summary.reason !== 'node_publish_secret_ref_immutable_drift') {
  throw new Error(`unexpected AFSCP reconcile reason: ${summary.reason}`);
}
if (summary.pv?.name !== 'agentsmith-afscp-default-volume') {
  throw new Error('AFSCP reconcile report missing target PV');
}
if (summary.pvc?.namespace !== 'agentsmith' || summary.pvc?.name !== 'afscp-default-volume') {
  throw new Error('AFSCP reconcile report missing target PVC');
}
if (!Array.isArray(summary.operations) || summary.operations.length !== 6) {
  throw new Error('AFSCP reconcile report must record six delete operations');
}
const operationKeys = summary.operations.map((operation) => {
  return `${operation.kind}/${operation.namespace || ''}/${operation.name}/${operation.status}`;
});
for (const expected of [
  'Deployment/agentsmith/afscp-api/deleted',
  'Job/agentsmith/afscp-bootstrap/deleted',
  'Pod/kube-system/juicefs-agentsmith-afscp-default-volume/deleted',
  'Secret/kube-system/juicefs-agentsmith-afscp-default-volume/deleted',
  'PersistentVolumeClaim/agentsmith/afscp-default-volume/deleted',
  'PersistentVolume//agentsmith-afscp-default-volume/deleted'
]) {
  if (!operationKeys.includes(expected)) {
    throw new Error(`AFSCP reconcile report missing operation ${expected}`);
  }
}
if (/plain-secret-value|other-secret-value/.test(serialized)) {
  throw new Error('AFSCP reconcile report leaked Secret payload');
}
NODE
}

assert_afscp_tls_preflight_report() {
  local report_file="$1"
  local expected_node_namespace="${2:-kube-system}"
  local expected_mount_namespace="${3:-kube-system}"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_node_namespace" "$expected_mount_namespace" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedNodeNamespace, expectedMountNamespace] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);
const legacySummary = report.pre_apply_reconcile?.afscp_juicefs_csi_tls_readiness;
const summary = report.pre_apply_controls?.afscp_juicefs_csi_tls_readiness;

if (summary?.status !== 'pass') {
  throw new Error(`expected passing AFSCP CSI TLS preflight, got ${summary?.status}`);
}
if (legacySummary?.status !== summary.status || legacySummary?.reason !== summary.reason) {
  throw new Error('legacy AFSCP CSI TLS summary must stay compatible with pre_apply_controls');
}
if (summary.reason !== 'tls_projection_ready') {
  throw new Error(`unexpected AFSCP CSI TLS preflight reason: ${summary.reason}`);
}
if (summary.volume_secret_ref?.namespace !== 'agentsmith' || summary.volume_secret_ref?.name !== 'afscp-default-volume-juicefs-1a24f776a1db') {
  throw new Error('AFSCP CSI TLS preflight report missing rendered volume Secret ref');
}
if (summary.node_namespace !== expectedNodeNamespace) {
  throw new Error(`unexpected AFSCP CSI node namespace: ${summary.node_namespace}`);
}
if (summary.mount_namespace !== expectedMountNamespace) {
  throw new Error(`unexpected AFSCP CSI mount namespace: ${summary.mount_namespace}`);
}
if (!Array.isArray(summary.checks) || !summary.checks.includes('postgresql_sslrootcert_node_plugin_readable')) {
  throw new Error('AFSCP CSI TLS preflight report missing node plugin readability check');
}
if (/fixture-ca|metaurl|access-key|secret-key|plain-secret-value|other-secret-value/.test(serialized)) {
  throw new Error('AFSCP CSI TLS preflight report leaked Secret payload');
}
NODE
}

assert_afscp_reconcile_noop_report() {
  local report_file="$1"
  local expected_reason="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_reason" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedReason] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const legacySummary = report.pre_apply_reconcile?.afscp_static_juicefs_pv;
const summary = report.pre_apply_controls?.afscp_static_juicefs_pv_reconcile;

if (summary?.status !== 'noop') {
  throw new Error(`expected noop AFSCP summary, got ${summary?.status}`);
}
if (legacySummary?.status !== summary.status || legacySummary?.reason !== summary.reason) {
  throw new Error('legacy AFSCP noop summary must stay compatible with pre_apply_controls');
}
if (summary.reason !== expectedReason) {
  throw new Error(`unexpected AFSCP noop reason: ${summary.reason}`);
}
NODE
}

assert_afscp_reconcile_skipped_report() {
  local report_file="$1"
  local expected_reason="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$expected_reason" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedReason] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const legacySummary = report.pre_apply_reconcile?.afscp_static_juicefs_pv;
const summary = report.pre_apply_controls?.afscp_static_juicefs_pv_reconcile;

if (summary?.status !== 'skipped') {
  throw new Error(`expected skipped AFSCP summary, got ${summary?.status}`);
}
if (legacySummary?.status !== summary.status || legacySummary?.reason !== summary.reason) {
  throw new Error('legacy AFSCP skipped summary must stay compatible with pre_apply_controls');
}
if (summary.reason !== expectedReason) {
  throw new Error(`unexpected AFSCP skipped reason: ${summary.reason}`);
}
NODE
}

assert_no_afscp_delete_or_apply_after_pv_get() {
  grep -q '^get pv agentsmith-afscp-default-volume -o json$' "$KUBECTL_LOG" ||
    fail "expected kubectl get pv before failing"
  if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
    cat "$KUBECTL_LOG" >&2
    fail "failed AFSCP reconcile preflight must not delete or apply"
  fi
}

assert_boundary_failure() {
  local stdout_file="$1"
  local stderr_file="$2"
  local label="$3"

  if ! grep -Eiq 'forbidden|source|boundary|product source tree' "$stdout_file" "$stderr_file"; then
    cat "$stdout_file" >&2
    cat "$stderr_file" >&2
    fail "expected source-boundary failure message for: $label"
  fi
}

valid_manifests="$TMP_DIR/manifests-valid"
valid_output="$TMP_DIR/out-valid"
write_manifests "$valid_manifests" valid
reset_kubectl_log
run_apply "$valid_manifests" "$valid_output" "$TARGET_PROFILE" >/dev/null
grep -q 'version' "$KUBECTL_LOG" || fail "fake kubectl did not receive version call"
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "fake kubectl did not receive server dry-run apply call"
assert_apply_report "$valid_output/apply-report.json" server-dry-run
pass "server dry-run happy path calls kubectl dry-run and writes non-readiness report"

apply_failure_output="$TMP_DIR/out-apply-failure"
reset_kubectl_log
if FAKE_KUBECTL_APPLY_MODE=fail \
  run_apply "$valid_manifests" "$apply_failure_output" "$TARGET_PROFILE" >"$TMP_DIR/apply-failure.out" 2>"$TMP_DIR/apply-failure.err"; then
  cat "$TMP_DIR/apply-failure.out" >&2
  cat "$TMP_DIR/apply-failure.err" >&2
  fail "expected kubectl apply failure to fail"
fi
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "kubectl apply failure did not reach server dry-run apply"
if ! grep -Fq 'kubectl apply failed with exit code 1: kubectl apply failure detail line 1' "$TMP_DIR/apply-failure.err"; then
  cat "$TMP_DIR/apply-failure.err" >&2
  fail "kubectl apply failure did not include summarized stderr"
fi
if ! grep -Fq 'Error from server (Invalid): deployment.apps "agentsmith-web" is invalid' "$TMP_DIR/apply-failure.err"; then
  cat "$TMP_DIR/apply-failure.err" >&2
  fail "kubectl apply failure did not include server error detail"
fi
if grep -Eq 'tail-client-secret-value|tail-access-key-value' "$TMP_DIR/apply-failure.out" "$TMP_DIR/apply-failure.err"; then
  cat "$TMP_DIR/apply-failure.err" >&2
  fail "kubectl apply failure summary leaked tail secret-looking values"
fi
grep -Fq 'client_secret=[redacted]' "$TMP_DIR/apply-failure.err" || \
  fail "kubectl apply failure summary did not redact tail client_secret"
grep -Fq 'access_key=[redacted]' "$TMP_DIR/apply-failure.err" || \
  fail "kubectl apply failure summary did not redact tail access_key"
if [[ -e "$apply_failure_output/apply-report.json" ]]; then
  fail "failed kubectl apply must not leave apply-report.json"
fi
pass "kubectl apply failure includes summarized stderr in failure output"

nested_manifests="$TMP_DIR/manifests-nested"
nested_output="$TMP_DIR/out-nested"
write_manifests "$nested_manifests" nested
reset_kubectl_log
run_apply "$nested_manifests" "$nested_output" "$TARGET_PROFILE" >/dev/null
nested_manifest_file="$nested_manifests/templates/app/deployment.yaml"
grep -Fq -- "-f $nested_manifest_file" "$KUBECTL_LOG" || fail "nested rendered manifest file was not passed to kubectl apply"
if grep -Fq -- "-f $nested_manifests " "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "nested rendered manifests must not be applied by passing the root directory"
fi
assert_apply_report "$nested_output/apply-report.json" server-dry-run
pass "server dry-run applies nested rendered manifest files directly"

airgap_dry_run_output="$TMP_DIR/out-airgap-dry-run"
reset_kubectl_log
run_apply "$valid_manifests" "$airgap_dry_run_output" "$AIRGAP_TARGET_PROFILE" >/dev/null
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "airgap apply dry-run did not pass --dry-run=server"
assert_apply_report "$airgap_dry_run_output/apply-report.json" server-dry-run "" "$AIRGAP_TARGET_PROFILE"
pass "airgap server dry-run accepted without enabling kind or aliases"

kit_online_dry_run_output="$TMP_DIR/out-kit-online-dry-run"
reset_kubectl_log
run_apply "$valid_manifests" "$kit_online_dry_run_output" "$KIT_ONLINE_TARGET_PROFILE" >/dev/null
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "kit online apply dry-run did not pass --dry-run=server"
assert_apply_report "$kit_online_dry_run_output/apply-report.json" server-dry-run "" "$KIT_ONLINE_TARGET_PROFILE"
pass "kit-installed online server dry-run accepted without changing Kubernetes apply behavior"

kit_airgap_dry_run_output="$TMP_DIR/out-kit-airgap-dry-run"
reset_kubectl_log
run_apply "$valid_manifests" "$kit_airgap_dry_run_output" "$KIT_AIRGAP_TARGET_PROFILE" >/dev/null
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "kit airgap apply dry-run did not pass --dry-run=server"
assert_apply_report "$kit_airgap_dry_run_output/apply-report.json" server-dry-run "" "$KIT_AIRGAP_TARGET_PROFILE"
pass "kit-installed airgap server dry-run accepted without changing Kubernetes apply behavior"

unparsed_version_output="$TMP_DIR/out-unparsed-version"
reset_kubectl_log
FAKE_KUBECTL_VERSION_MODE=nonjson run_apply "$valid_manifests" "$unparsed_version_output" "$TARGET_PROFILE" >/dev/null
assert_unparsed_version_report "$unparsed_version_output/apply-report.json"
pass "non-JSON kubectl version output records only hash and unparsed marker"

apply_output="$TMP_DIR/out-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$apply_output" "$TARGET_PROFILE" \
  --mode=apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed apply must not pass --dry-run=server"
fi
assert_apply_report "$apply_output/apply-report.json" apply operator-run-1001
pass "confirmed apply requires operator run id and records it"

afscp_static_manifests="$TMP_DIR/manifests-afscp-static-volume"
write_afscp_static_volume_manifests "$afscp_static_manifests"

afscp_missing_workload_allowlist_manifests="$TMP_DIR/manifests-afscp-missing-workload-allowlist"
write_afscp_static_volume_manifests "$afscp_missing_workload_allowlist_manifests" missing_workload_allowlist

afscp_unsafe_pv_manifests="$TMP_DIR/manifests-afscp-unsafe-pv"
write_afscp_static_volume_manifests "$afscp_unsafe_pv_manifests" unsafe_pv
reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  run_apply "$afscp_unsafe_pv_manifests" "$TMP_DIR/out-afscp-unsafe-pv" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-unsafe-pv >"$TMP_DIR/afscp-unsafe-pv.out" 2>"$TMP_DIR/afscp-unsafe-pv.err"; then
  cat "$TMP_DIR/afscp-unsafe-pv.out" >&2
  cat "$TMP_DIR/afscp-unsafe-pv.err" >&2
  fail "expected unsafe rendered AFSCP PV to fail before live reconcile"
fi
if grep -Eq '^(get pv|get pvc|delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "unsafe rendered AFSCP PV must stop before live PV/PVC get, delete, or apply"
fi
grep -Fq 'rendered AFSCP static JuiceFS PV agentsmith-afscp-default-volume is not safe for live delete reconcile' "$TMP_DIR/afscp-unsafe-pv.err" ||
  fail "unsafe rendered AFSCP PV failure did not identify rendered PV safety"
pass "AFSCP reconcile fails closed on unsafe rendered PV before live delete"

afscp_unsafe_pvc_manifests="$TMP_DIR/manifests-afscp-unsafe-pvc"
write_afscp_static_volume_manifests "$afscp_unsafe_pvc_manifests" unsafe_pvc
reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  run_apply "$afscp_unsafe_pvc_manifests" "$TMP_DIR/out-afscp-unsafe-pvc" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-unsafe-pvc >"$TMP_DIR/afscp-unsafe-pvc.out" 2>"$TMP_DIR/afscp-unsafe-pvc.err"; then
  cat "$TMP_DIR/afscp-unsafe-pvc.out" >&2
  cat "$TMP_DIR/afscp-unsafe-pvc.err" >&2
  fail "expected unsafe rendered AFSCP PVC to fail before live reconcile"
fi
if grep -Eq '^(get pv|get pvc|delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "unsafe rendered AFSCP PVC must stop before live PV/PVC get, delete, or apply"
fi
grep -Fq 'rendered AFSCP static JuiceFS PVC agentsmith/afscp-default-volume is not safe for live delete reconcile' "$TMP_DIR/afscp-unsafe-pvc.err" ||
  fail "unsafe rendered AFSCP PVC failure did not identify rendered PVC safety"
pass "AFSCP reconcile fails closed on unsafe rendered PVC before live delete"

afscp_reconcile_output="$TMP_DIR/out-afscp-reconcile"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=drift \
run_apply "$afscp_static_manifests" "$afscp_reconcile_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-afscp-1001 >/dev/null
assert_afscp_reconcile_order
assert_afscp_reconcile_report "$afscp_reconcile_output/apply-report.json"
assert_afscp_tls_preflight_report "$afscp_reconcile_output/apply-report.json"
pass "apply mode reconciles AFSCP static JuiceFS PV immutable nodePublishSecretRef drift before apply"

afscp_non_pvc_named_output="$TMP_DIR/out-afscp-non-pvc-named"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=with_non_pvc_afscp_named \
run_apply "$afscp_static_manifests" "$afscp_non_pvc_named_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-afscp-non-pvc-named >/dev/null
if grep -q '^delete deployment afscp-metrics ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "AFSCP-named workload without the target PVC must not be deleted"
fi
grep -q '^delete deployment afscp-api --namespace agentsmith --cascade=foreground --wait=true --timeout=120s$' "$KUBECTL_LOG" ||
  fail "AFSCP non-PVC-name diagnostic test must still delete the eligible PVC-mounted Deployment"
pass "AFSCP marker in workload metadata is diagnostic only and does not authorize deletion"

grep -Fq 'get daemonset juicefs-csi-node --namespace kube-system -o json' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must inspect live JuiceFS CSI node DaemonSet"
grep -Fq 'get secret postgresql-ca --namespace kube-system -o json' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must check Postgres CA Secret in mount namespace"
grep -Fq 'exec ds/juicefs-csi-node --namespace kube-system -c juicefs-plugin -- test -r /etc/agentsmith/substrate-ca/postgresql/ca.crt' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must check node plugin readability for Postgres sslrootcert"
pass "AFSCP CSI TLS preflight passes with Postgres CA configs, mount namespace Secret, and readable node plugin file"

afscp_custom_csi_namespace_output="$TMP_DIR/out-afscp-custom-csi-namespace"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=drift \
FAKE_KUBECTL_AFSCP_NODE_NAMESPACE=juicefs-csi-system \
FAKE_KUBECTL_AFSCP_MOUNT_NAMESPACE=juicefs-mounts \
run_apply "$afscp_static_manifests" "$afscp_custom_csi_namespace_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-afscp-custom-csi-namespace >/dev/null
assert_afscp_tls_preflight_report \
  "$afscp_custom_csi_namespace_output/apply-report.json" \
  juicefs-csi-system \
  juicefs-mounts
grep -Fq 'get daemonset juicefs-csi-node --namespace kube-system -o json' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must preserve default kube-system DaemonSet discovery"
grep -Fq 'get daemonset --all-namespaces -o json' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must discover custom CSI node DaemonSet namespace"
grep -Fq 'get secret postgresql-ca --namespace juicefs-mounts -o json' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must check CA Secret in JuiceFS mount namespace"
grep -Fq 'exec ds/juicefs-csi-node --namespace juicefs-csi-system -c juicefs-plugin -- test -r /etc/agentsmith/substrate-ca/postgresql/ca.crt' "$KUBECTL_LOG" ||
  fail "AFSCP CSI TLS preflight must exec the CSI node DaemonSet in its workload namespace"
if grep -Fq 'exec ds/juicefs-csi-node --namespace juicefs-mounts ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "AFSCP CSI TLS preflight must not exec node plugin in the mount namespace"
fi
pass "AFSCP CSI TLS preflight separates custom CSI node and JuiceFS mount namespaces"

grep -Fq 'get secret --all-namespaces -l juicefs/secret=true -o json' "$KUBECTL_LOG" ||
  fail "AFSCP reconcile must discover JuiceFS generated Secrets with the upstream label"
grep -Fq 'get pod,secret --all-namespaces -l app.kubernetes.io/name=juicefs-mount,volume-id=juicefs-afscp-unique-7c9d -o json' "$KUBECTL_LOG" ||
  fail "AFSCP reconcile must discover JuiceFS mount pods with the upstream volume-id selector"
pass "AFSCP reconcile discovers upstream JuiceFS generated Secret and mount pod labels"

if grep -Eq '^delete (pod|secret) juicefs-other-volume ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "AFSCP reconcile must not delete JuiceFS CSI cache for another volume"
fi
pass "AFSCP reconcile keeps other JuiceFS CSI cache entries untouched"

afscp_cache_owner_scope_output="$TMP_DIR/out-afscp-cache-owner-scope"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=drift \
FAKE_KUBECTL_AFSCP_CACHE_MODE=owner_scope \
run_apply "$afscp_static_manifests" "$afscp_cache_owner_scope_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-afscp-cache-owner-scope >/dev/null
for weak_cache_name in \
  juicefs-pvc-uid-owner-secret \
  juicefs-pvc-name-owner-secret \
  juicefs-secret-name-owner-secret \
  juicefs-pvc-owner-pod \
  juicefs-secret-owner-pod; do
  if grep -Eq "^delete (pod|secret) $weak_cache_name " "$KUBECTL_LOG"; then
    cat "$KUBECTL_LOG" >&2
    fail "AFSCP reconcile must not delete JuiceFS cache from weak ownerRef scope: $weak_cache_name"
  fi
done
grep -q '^delete secret juicefs-pv-name-owner-secret --namespace kube-system --wait=true --timeout=120s$' "$KUBECTL_LOG" ||
  fail "AFSCP ownerRef scope test must still delete generated Secret with target PV ownerRef"
grep -q '^delete secret juicefs-pv-uid-owner-secret --namespace kube-system --wait=true --timeout=120s$' "$KUBECTL_LOG" ||
  fail "AFSCP ownerRef scope test must still delete generated Secret with live PV UID ownerRef"
grep -q '^delete pod juicefs-pv-uid-owner-pod --namespace kube-system --wait=true --timeout=120s$' "$KUBECTL_LOG" ||
  fail "AFSCP ownerRef scope test must still delete cache Pod with live PV UID ownerRef"
grep -q '^delete pod juicefs-strong-volume-id-pod --namespace kube-system --wait=true --timeout=120s$' "$KUBECTL_LOG" ||
  fail "AFSCP ownerRef scope test must still delete cache Pod with strong volume-id scope"
pass "AFSCP reconcile limits cache ownerRef scope to the target PV while preserving strong cache scope"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE=postgres_config_missing \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-postgres-config-missing" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-postgres-config-missing >"$TMP_DIR/afscp-postgres-config-missing.out" 2>"$TMP_DIR/afscp-postgres-config-missing.err"; then
  cat "$TMP_DIR/afscp-postgres-config-missing.out" >&2
  cat "$TMP_DIR/afscp-postgres-config-missing.err" >&2
  fail "expected missing Postgres CA configs to fail before apply"
fi
grep -Fq 'Postgres sslrootcert requires configs mapping a CA Secret to /etc/agentsmith/substrate-ca/postgresql' "$TMP_DIR/afscp-postgres-config-missing.err" ||
  fail "missing Postgres CA configs failure did not identify required configs mapping"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing Postgres CA configs must fail before delete or apply"
fi
pass "AFSCP CSI TLS preflight fails fast when Postgres CA configs are missing"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  FAKE_KUBECTL_AFSCP_MOUNT_SECRET_MODE=missing_postgres_ca \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-postgres-ca-missing" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-postgres-ca-missing >"$TMP_DIR/afscp-postgres-ca-missing.out" 2>"$TMP_DIR/afscp-postgres-ca-missing.err"; then
  cat "$TMP_DIR/afscp-postgres-ca-missing.out" >&2
  cat "$TMP_DIR/afscp-postgres-ca-missing.err" >&2
  fail "expected missing mount namespace Postgres CA Secret to fail before apply"
fi
grep -Fq 'Postgres sslrootcert Secret kube-system/postgresql-ca is missing' "$TMP_DIR/afscp-postgres-ca-missing.err" ||
  fail "missing mount namespace Postgres CA Secret failure did not identify the Secret"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing mount namespace Postgres CA Secret must fail before delete or apply"
fi
pass "AFSCP CSI TLS preflight fails fast when mount namespace Postgres CA Secret is missing"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  FAKE_KUBECTL_AFSCP_NODE_FILE_MODE=missing \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-node-sslrootcert-missing" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-node-sslrootcert-missing >"$TMP_DIR/afscp-node-sslrootcert-missing.out" 2>"$TMP_DIR/afscp-node-sslrootcert-missing.err"; then
  cat "$TMP_DIR/afscp-node-sslrootcert-missing.out" >&2
  cat "$TMP_DIR/afscp-node-sslrootcert-missing.err" >&2
  fail "expected missing node plugin sslrootcert to fail before apply"
fi
grep -Fq 'AFSCP JuiceFS CSI node plugin cannot read Postgres sslrootcert /etc/agentsmith/substrate-ca/postgresql/ca.crt' "$TMP_DIR/afscp-node-sslrootcert-missing.err" ||
  fail "missing node plugin sslrootcert failure did not identify node plugin readability"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing node plugin sslrootcert must fail before delete or apply"
fi
pass "AFSCP CSI TLS preflight fails fast when node plugin cannot read Postgres sslrootcert"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  FAKE_KUBECTL_AFSCP_VOLUME_SECRET_MODE=object_tls_missing \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-object-tls-missing" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-object-tls-missing >"$TMP_DIR/afscp-object-tls-missing.out" 2>"$TMP_DIR/afscp-object-tls-missing.err"; then
  cat "$TMP_DIR/afscp-object-tls-missing.out" >&2
  cat "$TMP_DIR/afscp-object-tls-missing.err" >&2
  fail "expected object-storage TLS missing configs/envs to fail before apply"
fi
grep -Fq 'object-storage TLS requires configs mapping a CA Secret to /etc/agentsmith/substrate-ca/object-storage' "$TMP_DIR/afscp-object-tls-missing.err" ||
  fail "object-storage TLS configs failure did not identify required object-storage CA mapping"
grep -Fq 'object-storage TLS requires envs.SSL_CERT_DIR to include /etc/agentsmith/substrate-ca/object-storage' "$TMP_DIR/afscp-object-tls-missing.err" ||
  fail "object-storage TLS envs failure did not identify SSL_CERT_DIR requirement"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "object-storage TLS missing configs/envs must fail before delete or apply"
fi
pass "AFSCP CSI TLS preflight fails fast when object-storage HTTPS lacks configs and SSL_CERT_DIR"

afscp_owned_replicaset_pod_output="$TMP_DIR/out-afscp-owned-replicaset-pod"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=owned_replicaset_pod \
run_apply "$afscp_static_manifests" "$afscp_owned_replicaset_pod_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-afscp-1001-rs-pod >/dev/null
grep -q '^delete deployment afscp-api --namespace agentsmith --cascade=foreground --wait=true --timeout=120s$' "$KUBECTL_LOG" ||
  fail "owned ReplicaSet Pod reconcile must delete the marked Deployment"
if grep -Eq '^delete pod afscp-api-7d88f879c9-x42qv ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "owned ReplicaSet Pod reconcile must not delete the Pod directly"
fi
if grep -Eq '^delete replicaset ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "owned ReplicaSet Pod reconcile must not delete ReplicaSets directly"
fi
"$NODE_BIN" --input-type=module - "$afscp_owned_replicaset_pod_output/apply-report.json" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const operations = report.pre_apply_controls?.afscp_static_juicefs_pv_reconcile?.operations;
if (!Array.isArray(operations)) {
  throw new Error('AFSCP owned ReplicaSet Pod reconcile report missing operations');
}
const operationKeys = operations.map((operation) => {
  return `${operation.kind}/${operation.namespace || ''}/${operation.name}/${operation.status}`;
});
if (!operationKeys.includes('Deployment/agentsmith/afscp-api/deleted')) {
  throw new Error('AFSCP owned ReplicaSet Pod reconcile report must delete the owning Deployment');
}
if (operationKeys.some((key) => key.startsWith('Pod/agentsmith/afscp-api-7d88f879c9-x42qv/'))) {
  throw new Error('AFSCP owned ReplicaSet Pod reconcile report must not delete the Pod directly');
}
if (operationKeys.some((key) => key.startsWith('ReplicaSet/agentsmith/afscp-api-7d88f879c9/'))) {
  throw new Error('AFSCP owned ReplicaSet Pod reconcile report must not delete ReplicaSets directly');
}
NODE
pass "AFSCP reconcile accepts legacy Pods owned through a marked Deployment ReplicaSet"

afscp_no_drift_output="$TMP_DIR/out-afscp-no-drift"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=no_drift \
run_apply "$afscp_static_manifests" "$afscp_no_drift_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-afscp-1002 >/dev/null
if grep -q '^delete ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "AFSCP no-drift path must not delete resources"
fi
grep -q '^apply ' "$KUBECTL_LOG" || fail "AFSCP no-drift path must continue to kubectl apply"
assert_apply_report "$afscp_no_drift_output/apply-report.json" apply operator-run-afscp-1002 "$TARGET_PROFILE" 3
assert_afscp_reconcile_noop_report \
  "$afscp_no_drift_output/apply-report.json" \
  node_publish_secret_ref_already_matches
pass "AFSCP static JuiceFS PV no-drift path is a no-op before apply"

afscp_dry_run_output="$TMP_DIR/out-afscp-dry-run"
reset_kubectl_log
FAKE_KUBECTL_AFSCP_MODE=drift \
run_apply "$afscp_static_manifests" "$afscp_dry_run_output" "$TARGET_PROFILE" >/dev/null
if grep -Eq '^(get pv|get pvc|delete )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "server dry-run must not query or mutate AFSCP live PV/PVC reconcile resources"
fi
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "AFSCP server dry-run must still run kubectl dry-run apply"
assert_afscp_reconcile_skipped_report \
  "$afscp_dry_run_output/apply-report.json" \
  server_dry_run_no_mutation
pass "server dry-run records skipped AFSCP reconcile without deletion"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=non_owned \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-non-owned" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-1003 >"$TMP_DIR/afscp-non-owned.out" 2>"$TMP_DIR/afscp-non-owned.err"; then
  cat "$TMP_DIR/afscp-non-owned.out" >&2
  cat "$TMP_DIR/afscp-non-owned.err" >&2
  fail "expected non-owned AFSCP static PV/PVC to fail before deletion"
fi
assert_no_afscp_delete_or_apply_after_pv_get
if [[ -e "$TMP_DIR/out-afscp-non-owned/apply-report.json" ]]; then
  fail "failed AFSCP non-owned reconcile must not leave apply-report.json"
fi
pass "AFSCP reconcile rejects live PV/PVC outside AgentSmith unified deploy ownership"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=deleting_pv \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-deleting-pv" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-deleting-pv >"$TMP_DIR/afscp-deleting-pv.out" 2>"$TMP_DIR/afscp-deleting-pv.err"; then
  cat "$TMP_DIR/afscp-deleting-pv.out" >&2
  cat "$TMP_DIR/afscp-deleting-pv.err" >&2
  fail "expected deleting AFSCP PV to fail before deletion"
fi
assert_no_afscp_delete_or_apply_after_pv_get
grep -Fq 'live PV metadata.deletionTimestamp is set' "$TMP_DIR/afscp-deleting-pv.err" ||
  fail "deleting PV failure did not identify deletionTimestamp"
pass "AFSCP reconcile fails closed when live PV is already deleting"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=deleting_pvc \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-deleting-pvc" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-deleting-pvc >"$TMP_DIR/afscp-deleting-pvc.out" 2>"$TMP_DIR/afscp-deleting-pvc.err"; then
  cat "$TMP_DIR/afscp-deleting-pvc.out" >&2
  cat "$TMP_DIR/afscp-deleting-pvc.err" >&2
  fail "expected deleting AFSCP PVC to fail before deletion"
fi
assert_no_afscp_delete_or_apply_after_pv_get
grep -Fq 'live PVC metadata.deletionTimestamp is set' "$TMP_DIR/afscp-deleting-pvc.err" ||
  fail "deleting PVC failure did not identify deletionTimestamp"
pass "AFSCP reconcile fails closed when live PVC is already deleting"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=reclaim_delete \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-reclaim-delete" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-1004 >"$TMP_DIR/afscp-reclaim-delete.out" 2>"$TMP_DIR/afscp-reclaim-delete.err"; then
  cat "$TMP_DIR/afscp-reclaim-delete.out" >&2
  cat "$TMP_DIR/afscp-reclaim-delete.err" >&2
  fail "expected AFSCP PV reclaimPolicy Delete to fail before deletion"
fi
assert_no_afscp_delete_or_apply_after_pv_get
pass "AFSCP reconcile rejects live PV when reclaimPolicy is not Retain"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=foreign_binding \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-foreign-binding" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-1005 >"$TMP_DIR/afscp-foreign-binding.out" 2>"$TMP_DIR/afscp-foreign-binding.err"; then
  cat "$TMP_DIR/afscp-foreign-binding.out" >&2
  cat "$TMP_DIR/afscp-foreign-binding.err" >&2
  fail "expected foreign AFSCP PV/PVC binding to fail before deletion"
fi
assert_no_afscp_delete_or_apply_after_pv_get
pass "AFSCP reconcile rejects foreign live PV claimRef and PVC volumeName"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=drift \
  run_apply "$afscp_missing_workload_allowlist_manifests" "$TMP_DIR/out-afscp-missing-workload-allowlist" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-missing-workload-allowlist >"$TMP_DIR/afscp-missing-workload-allowlist.out" 2>"$TMP_DIR/afscp-missing-workload-allowlist.err"; then
  cat "$TMP_DIR/afscp-missing-workload-allowlist.out" >&2
  cat "$TMP_DIR/afscp-missing-workload-allowlist.err" >&2
  fail "expected rendered allowlist miss for live AFSCP workload using target PVC to fail before deletion"
fi
assert_no_afscp_delete_or_apply_after_pv_get
grep -Fq 'rendered workload allowlist does not include the same kind/name/namespace mounting the target PVC' "$TMP_DIR/afscp-missing-workload-allowlist.err" ||
  fail "rendered allowlist miss failure did not identify the missing rendered workload"
grep -Fq 'metadata contains an AFSCP marker, but that marker is diagnostic only' "$TMP_DIR/afscp-missing-workload-allowlist.err" ||
  fail "rendered allowlist miss must clarify that AFSCP metadata is diagnostic only"
pass "AFSCP reconcile refuses live PVC-mounted workload when rendered allowlist is missing"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=foreign_workload \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-foreign-workload" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-1006 >"$TMP_DIR/afscp-foreign-workload.out" 2>"$TMP_DIR/afscp-foreign-workload.err"; then
  cat "$TMP_DIR/afscp-foreign-workload.out" >&2
  cat "$TMP_DIR/afscp-foreign-workload.err" >&2
  fail "expected foreign workload using AFSCP PVC to fail before deletion"
fi
grep -q '^get deployment,statefulset,daemonset,job,cronjob,replicaset,pod --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
  fail "AFSCP foreign workload test must inspect live workloads"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "foreign workload using AFSCP PVC must stop before delete or apply"
fi
pass "AFSCP reconcile rejects foreign workloads that mount the target PVC"

reset_kubectl_log
if FAKE_KUBECTL_AFSCP_MODE=foreign_owned_pod \
  run_apply "$afscp_static_manifests" "$TMP_DIR/out-afscp-foreign-owned-pod" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-afscp-1007 >"$TMP_DIR/afscp-foreign-owned-pod.out" 2>"$TMP_DIR/afscp-foreign-owned-pod.err"; then
  cat "$TMP_DIR/afscp-foreign-owned-pod.out" >&2
  cat "$TMP_DIR/afscp-foreign-owned-pod.err" >&2
  fail "expected owner-managed foreign Pod using AFSCP PVC to fail before deletion"
fi
grep -q '^get deployment,statefulset,daemonset,job,cronjob,replicaset,pod --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
  fail "AFSCP foreign owner-managed Pod test must inspect live workloads"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "owner-managed foreign Pod using AFSCP PVC must stop before delete or apply"
fi
grep -Fq 'workload Pod agentsmith/foreign-owned-files-reader mounts PVC agentsmith/afscp-default-volume but is not eligible for AFSCP pre-apply reconcile' "$TMP_DIR/afscp-foreign-owned-pod.err" ||
  fail "owner-managed foreign Pod failure did not identify the direct PVC mount"
pass "AFSCP reconcile rejects owner-managed foreign Pods that mount the target PVC"

required_secret_manifests="$TMP_DIR/manifests-required-secret"
required_secret_output="$TMP_DIR/out-required-secret"
write_secret_ref_manifests "$required_secret_manifests" required_env_from
mkdir -p "$required_secret_output"
printf '%s\n' '{"stale":true}' >"$required_secret_output/apply-report.json"
reset_kubectl_log
if FAKE_KUBECTL_SECRET_MODE=missing \
  run_apply "$required_secret_manifests" "$required_secret_output" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-secret-1001 >"$TMP_DIR/missing-secret.out" 2>"$TMP_DIR/missing-secret.err"; then
  cat "$TMP_DIR/missing-secret.out" >&2
  cat "$TMP_DIR/missing-secret.err" >&2
  fail "expected required rendered Secret ref to fail before apply"
fi
grep -q '^get secret agentsmith-app --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
  fail "required rendered Secret ref was not checked"
if grep -q '^apply ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing rendered Secret ref must fail before kubectl apply"
fi
grep -Fq 'rendered required Secret ref missing: Secret/agentsmith-app required by Deployment/agentsmith-api envFrom' "$TMP_DIR/missing-secret.err" ||
  fail "missing rendered Secret ref failure did not identify Secret, workload, and source"
if grep -Eq 'tail-secret-value|plain-secret-value' "$TMP_DIR/missing-secret.out" "$TMP_DIR/missing-secret.err"; then
  cat "$TMP_DIR/missing-secret.err" >&2
  fail "missing rendered Secret ref failure leaked secret-looking output"
fi
if [[ -e "$required_secret_output/apply-report.json" ]]; then
  fail "missing rendered Secret ref must remove stale apply-report.json"
fi
pass "apply mode fails before kubectl apply when rendered required Secret ref is missing"

missing_key_manifests="$TMP_DIR/manifests-missing-key"
write_secret_ref_manifests "$missing_key_manifests" missing_key
reset_kubectl_log
if FAKE_KUBECTL_SECRET_KEYS=OTHER_KEY \
  FAKE_KUBECTL_SECRET_VALUE=tail-secret-value \
  run_apply "$missing_key_manifests" "$TMP_DIR/out-missing-key" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-secret-1002 >"$TMP_DIR/missing-key.out" 2>"$TMP_DIR/missing-key.err"; then
  cat "$TMP_DIR/missing-key.out" >&2
  cat "$TMP_DIR/missing-key.err" >&2
  fail "expected required rendered Secret key to fail before apply"
fi
grep -q '^get secret agentsmith-app --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
  fail "required rendered Secret key Secret was not checked"
if grep -q '^apply ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing rendered Secret key must fail before kubectl apply"
fi
grep -Fq 'rendered required Secret key missing: Secret/agentsmith-app key DATABASE_URL required by Deployment/agentsmith-api env' "$TMP_DIR/missing-key.err" ||
  fail "missing rendered Secret key failure did not identify Secret, key, workload, and source"
if grep -Eq 'tail-secret-value|plain-secret-value' "$TMP_DIR/missing-key.out" "$TMP_DIR/missing-key.err"; then
  cat "$TMP_DIR/missing-key.err" >&2
  fail "missing rendered Secret key failure leaked Secret data"
fi
pass "apply mode fails before kubectl apply when rendered required Secret key is missing"

flow_style_secret_manifests="$TMP_DIR/manifests-flow-style-secret"
write_secret_ref_manifests "$flow_style_secret_manifests" flow_style_missing_key
reset_kubectl_log
if FAKE_KUBECTL_SECRET_KEYS=OTHER_KEY \
  run_apply "$flow_style_secret_manifests" "$TMP_DIR/out-flow-style-secret" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-secret-flow-style >"$TMP_DIR/flow-style-secret.out" 2>"$TMP_DIR/flow-style-secret.err"; then
  cat "$TMP_DIR/flow-style-secret.out" >&2
  cat "$TMP_DIR/flow-style-secret.err" >&2
  fail "expected flow-style secretKeyRef key preflight to fail before apply"
fi
grep -Fq 'rendered required Secret key missing: Secret/agentsmith-app key DATABASE_URL required by Deployment/agentsmith-api env' "$TMP_DIR/flow-style-secret.err" ||
  fail "flow-style secretKeyRef failure did not identify required key"
grep -q '^create --dry-run=client ' "$KUBECTL_LOG" ||
  fail "flow-style secretKeyRef test must use kubectl client dry-run decode"
if grep -Eq '^(delete |apply )' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "flow-style secretKeyRef failure must stop before delete or apply"
fi
pass "kubectl client dry-run decode preserves flow-style Secret refs for preflight"

missing_volume_item_key_manifests="$TMP_DIR/manifests-missing-volume-item-key"
write_secret_ref_manifests "$missing_volume_item_key_manifests" missing_volume_item_key
reset_kubectl_log
if FAKE_KUBECTL_SECRET_KEYS=OTHER_KEY \
  FAKE_KUBECTL_SECRET_VALUE=tail-secret-value \
  run_apply "$missing_volume_item_key_manifests" "$TMP_DIR/out-missing-volume-item-key" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-secret-volume-item >"$TMP_DIR/missing-volume-item-key.out" 2>"$TMP_DIR/missing-volume-item-key.err"; then
  cat "$TMP_DIR/missing-volume-item-key.out" >&2
  cat "$TMP_DIR/missing-volume-item-key.err" >&2
  fail "expected required rendered Secret volume item key to fail before apply"
fi
grep -q '^get secret agentsmith-app --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
  fail "required rendered Secret volume item Secret was not checked"
if grep -q '^apply ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing rendered Secret volume item key must fail before kubectl apply"
fi
grep -Fq 'rendered required Secret key missing: Secret/agentsmith-app key ca.crt required by Deployment/agentsmith-api volume item' "$TMP_DIR/missing-volume-item-key.err" ||
  fail "missing rendered Secret volume item key failure did not identify Secret, key, workload, and source"
if grep -Eq 'tail-secret-value|plain-secret-value' "$TMP_DIR/missing-volume-item-key.out" "$TMP_DIR/missing-volume-item-key.err"; then
  cat "$TMP_DIR/missing-volume-item-key.err" >&2
  fail "missing rendered Secret volume item key failure leaked Secret data"
fi
pass "apply mode fails before kubectl apply when rendered Secret volume item key is missing"

missing_projected_item_key_manifests="$TMP_DIR/manifests-missing-projected-item-key"
write_secret_ref_manifests "$missing_projected_item_key_manifests" missing_projected_item_key
reset_kubectl_log
if FAKE_KUBECTL_SECRET_KEYS=OTHER_KEY \
  FAKE_KUBECTL_SECRET_VALUE=tail-secret-value \
  run_apply "$missing_projected_item_key_manifests" "$TMP_DIR/out-missing-projected-item-key" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-secret-projected-item >"$TMP_DIR/missing-projected-item-key.out" 2>"$TMP_DIR/missing-projected-item-key.err"; then
  cat "$TMP_DIR/missing-projected-item-key.out" >&2
  cat "$TMP_DIR/missing-projected-item-key.err" >&2
  fail "expected required rendered projected Secret item key to fail before apply"
fi
grep -q '^get secret agentsmith-app --namespace agentsmith -o json$' "$KUBECTL_LOG" ||
  fail "required rendered projected Secret item Secret was not checked"
if grep -q '^apply ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "missing rendered projected Secret item key must fail before kubectl apply"
fi
grep -Fq 'rendered required Secret key missing: Secret/agentsmith-app key ca.crt required by Deployment/agentsmith-api projected volume item' "$TMP_DIR/missing-projected-item-key.err" ||
  fail "missing rendered projected Secret item key failure did not identify Secret, key, workload, and source"
if grep -Eq 'tail-secret-value|plain-secret-value' "$TMP_DIR/missing-projected-item-key.out" "$TMP_DIR/missing-projected-item-key.err"; then
  cat "$TMP_DIR/missing-projected-item-key.err" >&2
  fail "missing rendered projected Secret item key failure leaked Secret data"
fi
pass "apply mode fails before kubectl apply when rendered projected Secret item key is missing"

optional_secret_manifests="$TMP_DIR/manifests-optional-secret"
optional_secret_output="$TMP_DIR/out-optional-secret"
write_secret_ref_manifests "$optional_secret_manifests" optional_refs
reset_kubectl_log
FAKE_KUBECTL_SECRET_MODE=missing run_apply "$optional_secret_manifests" "$optional_secret_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-secret-1003 >/dev/null
if grep -q '^get secret agentsmith-app ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "optional rendered Secret refs must not be live checked"
fi
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "optional rendered Secret apply must still run confirmed apply"
fi
assert_apply_report "$optional_secret_output/apply-report.json" apply operator-run-secret-1003
pass "optional rendered Secret refs are skipped in apply mode"

dry_run_secret_output="$TMP_DIR/out-dry-run-secret"
reset_kubectl_log
FAKE_KUBECTL_SECRET_MODE=missing run_apply "$required_secret_manifests" "$dry_run_secret_output" "$TARGET_PROFILE" >/dev/null
if grep -q '^get secret ' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "server dry-run must not live check rendered Secret refs"
fi
grep -Eq 'apply .*--dry-run=server' "$KUBECTL_LOG" || fail "server dry-run with Secret refs did not call dry-run apply"
assert_apply_report "$dry_run_secret_output/apply-report.json" server-dry-run
pass "server dry-run does not require live rendered Secrets"

reset_kubectl_log
if FAKE_KUBECTL_SECRET_MODE=error \
  run_apply "$missing_key_manifests" "$TMP_DIR/out-secret-get-error" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-secret-1004 >"$TMP_DIR/secret-get-error.out" 2>"$TMP_DIR/secret-get-error.err"; then
  cat "$TMP_DIR/secret-get-error.out" >&2
  cat "$TMP_DIR/secret-get-error.err" >&2
  fail "expected rendered Secret preflight kubectl error to fail"
fi
grep -Fq 'kubectl get secret agentsmith-app failed with exit code 1: forbidden to read secret token=[redacted] client_secret=[redacted]' "$TMP_DIR/secret-get-error.err" ||
  fail "rendered Secret preflight kubectl error did not include redacted summary"
if grep -Eq 'tail-secret-value|tail-client-secret-value' "$TMP_DIR/secret-get-error.out" "$TMP_DIR/secret-get-error.err"; then
  cat "$TMP_DIR/secret-get-error.err" >&2
  fail "rendered Secret preflight kubectl error leaked secret-looking output"
fi
pass "rendered Secret preflight kubectl error output is redacted"

job_manifests="$TMP_DIR/manifests-job"
write_job_manifests "$job_manifests"

job_apply_output="$TMP_DIR/out-job-apply"
reset_kubectl_log
FAKE_KUBECTL_JOB_MODE=completed \
FAKE_KUBECTL_APPLY_OUTPUT=job.batch/agentsmith-bootstrap \
run_apply "$job_manifests" "$job_apply_output" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-job-1001 >/dev/null
assert_job_replacement_order
assert_job_replacement_report "$job_apply_output/apply-report.json"
pass "apply mode replaces completed adoptable rendered Jobs before kubectl apply"

job_dry_run_output="$TMP_DIR/out-job-dry-run"
reset_kubectl_log
FAKE_KUBECTL_JOB_MODE=completed \
FAKE_KUBECTL_APPLY_OUTPUT=job.batch/agentsmith-bootstrap \
run_apply "$job_manifests" "$job_dry_run_output" "$TARGET_PROFILE" >/dev/null
if grep -Eq '^(get job agentsmith-bootstrap|delete job agentsmith-bootstrap)' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "server dry-run must not run pre-apply Job replacement"
fi
assert_no_pre_apply_job_replacements "$job_dry_run_output/apply-report.json"
pass "server dry-run leaves rendered Jobs untouched"

reset_kubectl_log
if FAKE_KUBECTL_JOB_MODE=missing_ownership \
  run_apply "$job_manifests" "$TMP_DIR/out-job-missing-ownership" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-job-1002 >"$TMP_DIR/job-missing-ownership.out" 2>"$TMP_DIR/job-missing-ownership.err"; then
  cat "$TMP_DIR/job-missing-ownership.out" >&2
  cat "$TMP_DIR/job-missing-ownership.err" >&2
  fail "expected existing Job without AgentSmith ownership to fail before apply"
fi
assert_no_delete_or_apply_after_job_get
if [[ -e "$TMP_DIR/out-job-missing-ownership/apply-report.json" ]]; then
  fail "failed Job ownership preflight must not leave apply-report.json"
fi
pass "apply mode rejects completed Jobs outside the narrow AgentSmith ownership boundary"

reset_kubectl_log
if FAKE_KUBECTL_JOB_MODE=active \
  run_apply "$job_manifests" "$TMP_DIR/out-job-active" "$TARGET_PROFILE" \
    --mode apply \
    --confirm-apply "$TARGET_PROFILE" \
    --operator-run-id operator-run-job-1003 >"$TMP_DIR/job-active.out" 2>"$TMP_DIR/job-active.err"; then
  cat "$TMP_DIR/job-active.out" >&2
  cat "$TMP_DIR/job-active.err" >&2
  fail "expected active existing Job to fail before apply"
fi
assert_no_delete_or_apply_after_job_get
if [[ -e "$TMP_DIR/out-job-active/apply-report.json" ]]; then
  fail "failed active Job preflight must not leave apply-report.json"
fi
pass "apply mode rejects active rendered Jobs before delete or apply"

airgap_apply_output="$TMP_DIR/out-airgap-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$airgap_apply_output" "$AIRGAP_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$AIRGAP_TARGET_PROFILE" \
  --operator-run-id operator-run-airgap-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed airgap apply must not pass --dry-run=server"
fi
assert_apply_report "$airgap_apply_output/apply-report.json" apply operator-run-airgap-1001 "$AIRGAP_TARGET_PROFILE"
pass "confirmed airgap apply requires matching confirm target profile"

kit_online_apply_output="$TMP_DIR/out-kit-online-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$kit_online_apply_output" "$KIT_ONLINE_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$KIT_ONLINE_TARGET_PROFILE" \
  --operator-run-id operator-run-kit-online-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed kit online apply must not pass --dry-run=server"
fi
assert_apply_report "$kit_online_apply_output/apply-report.json" apply operator-run-kit-online-1001 "$KIT_ONLINE_TARGET_PROFILE"
pass "confirmed kit-installed online apply requires matching confirm target profile"

kit_airgap_apply_output="$TMP_DIR/out-kit-airgap-apply"
reset_kubectl_log
run_apply "$valid_manifests" "$kit_airgap_apply_output" "$KIT_AIRGAP_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$KIT_AIRGAP_TARGET_PROFILE" \
  --operator-run-id operator-run-kit-airgap-1001 >/dev/null
if grep -q -- '--dry-run=server' "$KUBECTL_LOG"; then
  cat "$KUBECTL_LOG" >&2
  fail "confirmed kit airgap apply must not pass --dry-run=server"
fi
assert_apply_report "$kit_airgap_apply_output/apply-report.json" apply operator-run-kit-airgap-1001 "$KIT_AIRGAP_TARGET_PROFILE"
pass "confirmed kit-installed airgap apply requires matching confirm target profile"

reset_kubectl_log
if run_apply "$valid_manifests" "$TMP_DIR/out-airgap-confirm-mismatch" "$AIRGAP_TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id operator-run-airgap-1002 >"$TMP_DIR/airgap-confirm-mismatch.out" 2>"$TMP_DIR/airgap-confirm-mismatch.err"; then
  fail "expected airgap apply with online confirm to fail"
fi
assert_kubectl_not_called
pass "airgap apply confirm must match the target profile exactly"

reset_kubectl_log
if run_apply "$valid_manifests" "$TMP_DIR/out-missing-confirm" "$TARGET_PROFILE" \
  --mode apply \
  --operator-run-id operator-run-1002 >"$TMP_DIR/missing-confirm.out" 2>"$TMP_DIR/missing-confirm.err"; then
  fail "expected apply without confirm to fail"
fi
assert_kubectl_not_called
pass "apply mode without confirm rejected"

reset_kubectl_log
if run_apply "$valid_manifests" "$TMP_DIR/out-missing-run-id" "$TARGET_PROFILE" \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" >"$TMP_DIR/missing-run-id.out" 2>"$TMP_DIR/missing-run-id.err"; then
  fail "expected apply without operator run id to fail"
fi
assert_kubectl_not_called
pass "apply mode without operator run id rejected"

expect_profile_fail() {
  local label="$1"
  local target_profile="$2"
  reset_kubectl_log
  if run_apply "$valid_manifests" "$TMP_DIR/out-profile-$label" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid apply target profile to fail: $label"
  fi
  assert_kubectl_not_called
  pass "invalid apply target profile rejected: $label"
}

expect_profile_fail kind-rehearsal "kind_rehearsal/kit_installed/online"
expect_profile_fail alias-offline "$ALIAS_OFFLINE_TARGET_PROFILE"
expect_profile_fail noncanonical-local-kind "local-kind/external_declared/online"
expect_profile_fail synonym-cluster "existing_kubernetes/cluster/online"

bad_manifests="$TMP_DIR/manifests-render-check-fail"
bad_output="$TMP_DIR/out-render-check-fail"
write_manifests "$bad_manifests" unknown_image
reset_kubectl_log
if run_apply "$bad_manifests" "$bad_output" "$TARGET_PROFILE" >"$TMP_DIR/render-check-fail.out" 2>"$TMP_DIR/render-check-fail.err"; then
  cat "$TMP_DIR/render-check-fail.out" >&2
  cat "$TMP_DIR/render-check-fail.err" >&2
  fail "expected apply to fail when render-check fails"
fi
assert_kubectl_not_called
if [[ -e "$bad_output/apply-report.json" ]]; then
  fail "failed apply must not leave apply-report.json"
fi
pass "render-check failure stops before kubectl apply"

explicit_forbidden_root="$TMP_DIR/explicit-forbidden-source"
explicit_forbidden_manifests="$explicit_forbidden_root/rendered-manifests"
write_manifests "$explicit_forbidden_manifests" valid
reset_kubectl_log
if run_apply_raw "$VALID_CONTRACT" "$explicit_forbidden_manifests" "$TMP_DIR/out-explicit-forbidden" "$TARGET_PROFILE" \
  --forbidden-source-root "$explicit_forbidden_root" >"$TMP_DIR/explicit-forbidden.out" 2>"$TMP_DIR/explicit-forbidden.err"; then
  cat "$TMP_DIR/explicit-forbidden.out" >&2
  cat "$TMP_DIR/explicit-forbidden.err" >&2
  fail "expected explicit forbidden source root to reject rendered manifests"
fi
assert_boundary_failure "$TMP_DIR/explicit-forbidden.out" "$TMP_DIR/explicit-forbidden.err" explicit-forbidden-rendered-manifests
assert_kubectl_not_called
pass "explicit forbidden source root rejects rendered manifests before kubectl"

default_boundary_parent="$TMP_DIR/default-boundary"
default_release_kit="$default_boundary_parent/release-kit"
default_agentsmith="$default_boundary_parent/agentsmith"
mkdir -p "$default_release_kit/scripts/lib" "$default_agentsmith"
cp "$ROOT_DIR/scripts/verify-release.sh" "$default_release_kit/scripts/verify-release.sh"
cp "$ROOT_DIR/scripts/verify-apply.mjs" "$default_release_kit/scripts/verify-apply.mjs"
cp "$ROOT_DIR/scripts/verify-render-check.mjs" "$default_release_kit/scripts/verify-render-check.mjs"
cp "$ROOT_DIR/scripts/lib/output-redaction.mjs" "$default_release_kit/scripts/lib/output-redaction.mjs"
chmod +x "$default_release_kit/scripts/verify-release.sh" "$default_release_kit/scripts/verify-apply.mjs" "$default_release_kit/scripts/verify-render-check.mjs"

default_forbidden_contract="$default_agentsmith/release-contract.json"
cp "$VALID_CONTRACT" "$default_forbidden_contract"
reset_kubectl_log
if run_apply_from_release_kit "$default_release_kit" "$default_forbidden_contract" "$valid_manifests" "$TMP_DIR/out-default-contract" "$TARGET_PROFILE" >"$TMP_DIR/default-contract.out" 2>"$TMP_DIR/default-contract.err"; then
  cat "$TMP_DIR/default-contract.out" >&2
  cat "$TMP_DIR/default-contract.err" >&2
  fail "expected default sibling forbidden source root to reject release contract"
fi
assert_boundary_failure "$TMP_DIR/default-contract.out" "$TMP_DIR/default-contract.err" default-sibling-release-contract
assert_kubectl_not_called
pass "default sibling forbidden source root rejects release contract before kubectl"

default_forbidden_manifests="$default_agentsmith/rendered-manifests"
write_manifests "$default_forbidden_manifests" valid
reset_kubectl_log
if run_apply_from_release_kit "$default_release_kit" "$VALID_CONTRACT" "$default_forbidden_manifests" "$TMP_DIR/out-default-manifests" "$TARGET_PROFILE" >"$TMP_DIR/default-manifests.out" 2>"$TMP_DIR/default-manifests.err"; then
  cat "$TMP_DIR/default-manifests.out" >&2
  cat "$TMP_DIR/default-manifests.err" >&2
  fail "expected default sibling forbidden source root to reject rendered manifests"
fi
assert_boundary_failure "$TMP_DIR/default-manifests.out" "$TMP_DIR/default-manifests.err" default-sibling-rendered-manifests
assert_kubectl_not_called
pass "default sibling forbidden source root rejects rendered manifests before kubectl"

pass "Kubernetes apply-only focused diagnostic tests completed"
