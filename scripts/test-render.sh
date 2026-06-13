#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
AFSCP_VOLUME_BASE_REF="afscp-default-volume-juicefs"
AFSCP_VOLUME_REVISION_HEX="$(printf '1a24f776a1db%052d' 0)"
AFSCP_VOLUME_REVISION="sha256:$AFSCP_VOLUME_REVISION_HEX"
AFSCP_VOLUME_REVISION_SUFFIX="${AFSCP_VOLUME_REVISION_HEX:0:12}"
AFSCP_EFFECTIVE_VOLUME_REF="$AFSCP_VOLUME_BASE_REF-$AFSCP_VOLUME_REVISION_SUFFIX"
AFSCP_STALE_SUFFIX_EFFECTIVE_VOLUME_REF="$AFSCP_VOLUME_BASE_REF-deadbeefdead-$AFSCP_VOLUME_REVISION_SUFFIX"
AFSCP_EXPLICIT_RUNTIME_SECRETS_CHECKSUM="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

sha256_file() {
  "$NODE_BIN" --input-type=module - "$1" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [file] = process.argv.slice(2);
const body = fs.readFileSync(file);
console.log(`sha256:${crypto.createHash('sha256').update(body).digest('hex')}`);
NODE
}

write_truth() {
  local output="$1"
  local profile="${2:-$TARGET_PROFILE}"

  "$NODE_BIN" --input-type=module - "$output" "$profile" <<'NODE'
import fs from 'node:fs';

const [output, profile] = process.argv.slice(2);
const [targetCluster, substrateSource, distribution] = profile.split('/');

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
      proof: `operator ${name} tcp/tls check 2026-05-23T12:00:00Z`
    }
  };
}

const truth = {
  schema_version: 'agentsmith.substrate-connection.truth/v1',
  redacted_fingerprint: `sha256:${'a'.repeat(64)}`,
  target_cluster: targetCluster,
  substrate_source: substrateSource,
  distribution,
  declared_at: '2026-05-23T12:00:00.000Z',
  declared_by: 'release-operator@example.com',
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
        proof: 'operator bucket head-object check 2026-05-23T12:00:00Z'
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
        proof: 'operator oidc discovery check 2026-05-23T12:00:00Z'
      }
    }
  }
};

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_render_values() {
  local output="$1"
  local mutation="${2:-valid}"

  cat >"$output" <<'JSON'
{
  "namespace": "agentsmith",
  "replicas": 2,
  "release_channel": "stable",
  "PUBLIC_BASE_URL": "https://agentsmith.release.example.com",
  "unsafe_payload": "not-real-credential-value",
  "AFSCP_DEFAULT_VOLUME_ID": "vol_agentsmith_default",
  "AFSCP_DEFAULT_VOLUME_BACKEND": "juicefs",
  "AFSCP_DEFAULT_VOLUME_ISOLATION_CLASS": "shared",
  "AFSCP_DEFAULT_VOLUME_STATUS": "active",
  "AFSCP_DEFAULT_VOLUME_CAPABILITIES_JSON": "{\"webdav_export\":true,\"workload_mount\":true,\"jvs_external_control_root\":true,\"directory_quota\":false,\"filtered_mount\":false,\"csi_driver\":\"csi.juicefs.com\",\"storage_class\":\"static-juicefs-rwx\",\"permission_model\":\"payload-root-only\"}"
}
JSON

  "$NODE_BIN" --input-type=module - "$output" "$mutation" <<'NODE'
import fs from 'node:fs';

const [output, mutation] = process.argv.slice(2);
const values = JSON.parse(fs.readFileSync(output, 'utf8'));
const afscpBaseRef = 'afscp-default-volume-juicefs';
const afscpRevision = `sha256:${'1a24f776a1db'.padEnd(64, '0')}`;

switch (mutation) {
  case 'valid':
    break;
  case 'single_label_endpointslice_fqdn':
    values.SUBSTRATE_POSTGRES_ADDRESS_TYPE = 'FQDN';
    values.SUBSTRATE_POSTGRES_HOST = 'mbos-postgres';
    break;
  case 'url_endpointslice_fqdn':
    values.SUBSTRATE_POSTGRES_ADDRESS_TYPE = 'FQDN';
    values.SUBSTRATE_POSTGRES_HOST = 'https://postgres.ops.example.com/path';
    break;
  case 'host_port_endpointslice_fqdn':
    values.SUBSTRATE_POSTGRES_ADDRESS_TYPE = 'FQDN';
    values.SUBSTRATE_POSTGRES_HOST = 'postgres.ops.example.com:5432';
    break;
  case 'host_port_endpointslice_ipv4':
    values.SUBSTRATE_POSTGRES_ADDRESS_TYPE = 'IPv4';
    values.SUBSTRATE_POSTGRES_HOST = '192.0.2.10:5432';
    break;
  case 'afscp_default_volume_id_default':
    values.AFSCP_DEFAULT_VOLUME_ID = 'default';
    break;
  case 'afscp_default_volume_ready_workspace':
    values.AFSCP_DEFAULT_VOLUME_STATUS = 'ready';
    values.AFSCP_DEFAULT_VOLUME_ISOLATION_CLASS = 'workspace';
    break;
  case 'afscp_default_volume_bad_capabilities':
    values.AFSCP_DEFAULT_VOLUME_CAPABILITIES_JSON = JSON.stringify({
      webdav_export: true,
      workload_mount: true,
      jvs_external_control_root: false,
      directory_quota: false,
      filtered_mount: false,
      csi_driver: 'csi.juicefs.com',
      storage_class: 'static-juicefs-rwx',
      permission_model: 'payload-root-only'
    });
    break;
  case 'profile_mismatch':
    values.PROFILE = 'local-kind-online-install-substrates';
    break;
  case 'ingress_host_mismatch':
    values.INGRESS_HOST = 'other.release.example.com';
    break;
  case 'afscp_default_volume_pv_name_mismatch':
    values.namespace = 'agentsmith-install-online';
    values.AFSCP_DEFAULT_VOLUME_PV_NAME = 'agentsmith-afscp-default-volume';
    break;
  case 'afscp_volume_ref_stable':
    values.AFSCP_VOLUME_REF = afscpBaseRef;
    values.AFSCP_VOLUME_REF_REVISION = 'stable';
    values.AFSCP_RUNTIME_SECRETS_CHECKSUM = 'stable';
    break;
  case 'afscp_volume_ref_sha':
    values.AFSCP_VOLUME_REF = afscpBaseRef;
    values.AFSCP_VOLUME_REF_REVISION = afscpRevision;
    break;
  case 'afscp_volume_ref_suffixed':
    values.AFSCP_VOLUME_REF = `${afscpBaseRef}-1a24f776a1db`;
    values.AFSCP_VOLUME_REF_REVISION = afscpRevision;
    values.AFSCP_RUNTIME_SECRETS_CHECKSUM = afscpRevision;
    break;
  case 'afscp_volume_ref_stale_suffix':
    values.AFSCP_VOLUME_REF = `${afscpBaseRef}-deadbeefdead`;
    values.AFSCP_VOLUME_REF_REVISION = afscpRevision;
    break;
  case 'afscp_volume_ref_stale_checksum':
    values.AFSCP_VOLUME_REF = afscpBaseRef;
    values.AFSCP_VOLUME_REF_REVISION = afscpRevision;
    values.AFSCP_RUNTIME_SECRETS_CHECKSUM = `sha256:${'f'.repeat(64)}`;
    break;
  default:
    throw new Error(`unknown render values mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(values, null, 2)}\n`);
NODE
}

create_render_archive() {
  local label="$1"
  local archive="$2"
  local mutation="${3:-valid}"
  local package_dir="$TMP_DIR/package-$label"

  mkdir -p "$package_dir/templates"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": [
    {
      "path": "templates/workloads.yaml",
      "kind": "kubernetes"
    }
  ]
}
JSON

  case "$mutation" in
    valid)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    release: ${{ release.release_id }}
    channel: ${{ values.release_channel }}
    distribution: ${{ target.distribution }}
    profile: ${{ values.PROFILE }}
    pv-name: ${{ values.AFSCP_DEFAULT_VOLUME_PV_NAME }}
spec:
  replicas: ${{ values.replicas }}
  template:
    spec:
      initContainers:
        - name: schema
          image: ${{ images.agentsmith_app.image }}
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
            - name: AGENTSMITH_CONFIG_PATH
              value: /etc/agentsmith/config.yaml
          volumes:
            - name: webhook-cert
              secret:
                secretName: agentsmith-webhook-cert
---
apiVersion: batch/v1
kind: Job
metadata:
  name: agentsmith-api-migration
  namespace: ${{ values.namespace }}
spec:
  template:
    spec:
      containers:
        - name: api
          image: ${{ images.agentsmith_app.image }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: agentsmith-maintenance
  namespace: ${{ values.namespace }}
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: llmup
              image: ${{ images.llmup.image }}
            - name: managed-runner
              image: ${{ images.managed_runner.image }}
YAML
      ;;
    substrate_tls_render_values)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: substrate-ca-bindings
  namespace: ${{ values.namespace }}
data:
  POSTGRES_HOST: ${{ substrate.services.postgresql.host }}
  SUBSTRATE_POSTGRES_CA_SECRET_REF: ${{ values.SUBSTRATE_POSTGRES_CA_SECRET_REF }}
  SUBSTRATE_POSTGRES_CA_SECRET_NAME: ${{ values.SUBSTRATE_POSTGRES_CA_SECRET_NAME }}
  SUBSTRATE_POSTGRES_TLS_MODE: ${{ values.SUBSTRATE_POSTGRES_TLS_MODE }}
  SUBSTRATE_POSTGRES_SSLMODE: ${{ values.SUBSTRATE_POSTGRES_SSLMODE }}
  SUBSTRATE_POSTGRESQL_CA_SECRET_REF: ${{ values.SUBSTRATE_POSTGRESQL_CA_SECRET_REF }}
  SUBSTRATE_POSTGRESQL_CA_SECRET_NAME: ${{ values.SUBSTRATE_POSTGRESQL_CA_SECRET_NAME }}
  SUBSTRATE_POSTGRESQL_TLS_MODE: ${{ values.SUBSTRATE_POSTGRESQL_TLS_MODE }}
  SUBSTRATE_POSTGRESQL_SSLMODE: ${{ values.SUBSTRATE_POSTGRESQL_SSLMODE }}
  SUBSTRATE_MINIO_CA_SECRET_REF: ${{ values.SUBSTRATE_MINIO_CA_SECRET_REF }}
  SUBSTRATE_MINIO_CA_SECRET_NAME: ${{ values.SUBSTRATE_MINIO_CA_SECRET_NAME }}
  SUBSTRATE_MINIO_TLS_MODE: ${{ values.SUBSTRATE_MINIO_TLS_MODE }}
  SUBSTRATE_MINIO_USE_SSL: "${{ values.SUBSTRATE_MINIO_USE_SSL }}"
  SUBSTRATE_OBJECT_STORAGE_CA_SECRET_REF: ${{ values.SUBSTRATE_OBJECT_STORAGE_CA_SECRET_REF }}
  SUBSTRATE_OBJECT_STORAGE_CA_SECRET_NAME: ${{ values.SUBSTRATE_OBJECT_STORAGE_CA_SECRET_NAME }}
  SUBSTRATE_OBJECT_STORAGE_TLS_MODE: ${{ values.SUBSTRATE_OBJECT_STORAGE_TLS_MODE }}
  SUBSTRATE_OBJECT_STORAGE_USE_SSL: "${{ values.SUBSTRATE_OBJECT_STORAGE_USE_SSL }}"
  SUBSTRATE_KEYCLOAK_CA_SECRET_REF: ${{ values.SUBSTRATE_KEYCLOAK_CA_SECRET_REF }}
  SUBSTRATE_KEYCLOAK_CA_SECRET_NAME: ${{ values.SUBSTRATE_KEYCLOAK_CA_SECRET_NAME }}
  SUBSTRATE_KEYCLOAK_TLS_MODE: ${{ values.SUBSTRATE_KEYCLOAK_TLS_MODE }}
  SUBSTRATE_KEYCLOAK_USE_SSL: "${{ values.SUBSTRATE_KEYCLOAK_USE_SSL }}"
  SUBSTRATE_OIDC_CA_SECRET_REF: ${{ values.SUBSTRATE_OIDC_CA_SECRET_REF }}
  SUBSTRATE_OIDC_CA_SECRET_NAME: ${{ values.SUBSTRATE_OIDC_CA_SECRET_NAME }}
  SUBSTRATE_OIDC_TLS_MODE: ${{ values.SUBSTRATE_OIDC_TLS_MODE }}
  SUBSTRATE_OIDC_USE_SSL: "${{ values.SUBSTRATE_OIDC_USE_SSL }}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    distribution: ${{ target.distribution }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_CA_SECRET_REF
              value: ${{ values.SUBSTRATE_POSTGRES_CA_SECRET_REF }}
      volumes:
        - name: postgres-ca
          secret:
            secretName: ${{ values.SUBSTRATE_POSTGRES_CA_SECRET_NAME }}
YAML
      ;;
    with_ingress)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    distribution: ${{ target.distribution }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: agentsmith
  namespace: ${{ values.namespace }}
spec:
  rules:
    - host: ${{ values.INGRESS_HOST }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: agentsmith-web
                port:
                  number: 3001
YAML
      ;;
    hostless_ingress)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    distribution: ${{ target.distribution }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: agentsmith
  namespace: ${{ values.namespace }}
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: agentsmith-web
                port:
                  number: 3001
YAML
      ;;
    unknown_variable)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: MISSING
              value: ${{ values.not_declared }}
YAML
      ;;
    unknown_image)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unknown-image
spec:
  template:
    spec:
      containers:
        - name: hidden
          image: ghcr.io/agentsmith-project/not-in-contract:2026.05.23-p0@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
YAML
      ;;
    tag_only_image)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tag-only
spec:
  template:
    spec:
      containers:
        - name: web
          image: ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0
YAML
      ;;
    secret_payload)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: unsafe-config
data:
  client_secret: ${{ values.unsafe_payload }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    distribution: ${{ target.distribution }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
YAML
      ;;
    afscp_workload_mount_secret_refs)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: afscp-config
data:
  AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: workspace=agentsmith/afscp-workload-mounts,task_cache=agentsmith/task-cache
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    distribution: ${{ target.distribution }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
YAML
      ;;
    afscp_volume_ref)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: afscp-default-volume
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: csi.juicefs.com
    volumeHandle: afscp-default-volume
    nodePublishSecretRef:
      name: ${{ values.AFSCP_VOLUME_REF }}
      namespace: ${{ values.namespace }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: afscp-mount-refs
  namespace: ${{ values.namespace }}
data:
  AFSCP_VOLUME_REF: ${{ values.AFSCP_VOLUME_REF }}
  AFSCP_RUNTIME_SECRETS_CHECKSUM: ${{ values.AFSCP_RUNTIME_SECRETS_CHECKSUM }}
  AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: workspace=${{ values.namespace }}/${{ values.AFSCP_VOLUME_REF }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
  labels:
    distribution: ${{ target.distribution }}
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
YAML
      ;;
    afscp_workload_mount_secret_refs_missing_name)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: afscp-config
data:
  AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: workspace=agentsmith
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
YAML
      ;;
    afscp_workload_mount_secret_refs_path_escape)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: afscp-config
data:
  AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: workspace=../secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
YAML
      ;;
    afscp_workload_mount_secret_refs_token_volume)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: afscp-config
data:
  AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: token=agentsmith/something
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
YAML
      ;;
    afscp_workload_mount_secret_refs_reserved_name)
      cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: afscp-config
data:
  AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: workspace=agentsmith/password-token-value
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
YAML
      ;;
    *)
      fail "unknown archive mutation: $mutation"
      ;;
  esac

  tar -czf "$archive" -C "$package_dir" manifest.json templates/workloads.yaml
  sha256_file "$package_dir/manifest.json"
}

create_traversal_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-traversal"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  printf 'escape\n' >"$package_dir/escape.yaml"
  tar -czf "$archive" -C "$package_dir" manifest.json --transform='s#^escape.yaml$#../escape.yaml#' escape.yaml
  sha256_file "$package_dir/manifest.json"
}

create_symlink_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-symlink"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  ln -s manifest.json "$package_dir/manifest-link.json"
  tar -czf "$archive" -C "$package_dir" manifest.json manifest-link.json
  sha256_file "$package_dir/manifest.json"
}

create_hardlink_archive() {
  local archive="$1"
  local package_dir="$TMP_DIR/package-hardlink"

  mkdir -p "$package_dir"
  cat >"$package_dir/manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.deploy-template-manifest/v1",
  "templates": []
}
JSON
  ln "$package_dir/manifest.json" "$package_dir/manifest-hardlink.json"
  tar -czf "$archive" -C "$package_dir" manifest.json manifest-hardlink.json
  sha256_file "$package_dir/manifest.json"
}

write_materials() {
  local manifest_sha="$1"
  local archive_sha="$2"
  local contract_output="$3"
  local deploy_template_package_output="$4"

  "$NODE_BIN" --input-type=module - \
    "$VALID_CONTRACT" \
    "$VALID_DEPLOY_TEMPLATE_PACKAGE" \
    "$manifest_sha" \
    "$archive_sha" \
    "$contract_output" \
    "$deploy_template_package_output" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  contractInput,
  packageInput,
  manifestSha,
  archiveSha,
  contractOutput,
  packageOutput
] = process.argv.slice(2);

const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));

function stableJson(value) {
  if (Array.isArray(value)) {
    return value.map(stableJson);
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableJson(value[key])])
    );
  }
  return value;
}

function subjectDigest(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(subject))).digest('hex')}`;
}

function artifactProjectionDigest(value) {
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } = value.artifact_provenance;
  const projection = { ...value, artifact_provenance: artifactProvenance };
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(projection))).digest('hex')}`;
}

deployTemplatePackage.package_sha256 = archiveSha;
deployTemplatePackage.manifest_sha256 = manifestSha;
deployTemplatePackage.artifact_provenance.artifact_sha256 = archiveSha;
deployTemplatePackage.artifact_provenance.subject_sha256 = subjectDigest(deployTemplatePackage);

contract.deploy_template_digest = manifestSha;
contract.deploy_template_package = deployTemplatePackage;
contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(packageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_required_image_ids() {
  local mutation="$1"
  local contract_input="$2"
  local deploy_template_package_input="$3"
  local contract_output="$4"
  local deploy_template_package_output="$5"

  "$NODE_BIN" --input-type=module - \
    "$mutation" \
    "$contract_input" \
    "$deploy_template_package_input" \
    "$contract_output" \
    "$deploy_template_package_output" <<'NODE'
import fs from 'node:fs';

const [
  mutation,
  contractInput,
  deployTemplatePackageInput,
  contractOutput,
  deployTemplatePackageOutput
] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(deployTemplatePackageInput, 'utf8'));
const staleSixImageIds = contract.deploy_template_package.required_image_ids.filter(
  (id) => id !== 'managed_runner'
);

function replaceRequiredImageId(oldId, newId) {
  contract.deploy_template_package.required_image_ids =
    contract.deploy_template_package.required_image_ids.map((id) =>
      id === oldId ? newId : id
    );
  deployTemplatePackage.required_image_ids = deployTemplatePackage.required_image_ids.map((id) =>
    id === oldId ? newId : id
  );
}

function driftInventoryId(oldId, newId) {
  const item = contract.deploy_image_inventory.find((entry) => entry.id === oldId);
  if (!item) {
    throw new Error(`missing inventory item: ${oldId}`);
  }
  item.id = newId;
  replaceRequiredImageId(oldId, newId);
}

switch (mutation) {
  case 'stale-six-image-required-image-ids':
    contract.deploy_template_package.required_image_ids = staleSixImageIds;
    deployTemplatePackage.required_image_ids = staleSixImageIds;
    break;
  case 'adopted-provider-image-inventory-id-drift':
    driftInventoryId('llmup', 'llmup_drift');
    break;
  case 'managed-runner-inventory-id-drift':
    driftInventoryId('managed_runner', 'agentsmith-runner');
    break;
  case 'required-current-id-absent-from-inventory':
    contract.deploy_image_inventory = contract.deploy_image_inventory.filter(
      (item) => item.id !== 'asbcp'
    );
    break;
  default:
    throw new Error(`unknown required_image_ids mutation: ${mutation}`);
}

fs.writeFileSync(deployTemplatePackageOutput, `${JSON.stringify(deployTemplatePackage, null, 2)}\n`);
fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

mutate_contract_target_profile() {
  local mutation="$1"
  local contract_input="$2"
  local contract_output="$3"

  "$NODE_BIN" --input-type=module - "$mutation" "$contract_input" "$contract_output" <<'NODE'
import fs from 'node:fs';

const [mutation, contractInput, contractOutput] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));

switch (mutation) {
  case 'missing-required':
    delete contract.target_profiles[0].required;
    break;
  case 'required-string':
    contract.target_profiles[0].required = 'true';
    break;
  case 'required-true':
    for (const profile of contract.target_profiles) {
      profile.required = true;
    }
    break;
  case 'support-level-present':
    contract.target_profiles[0].support_level = 'primary';
    break;
  case 'noncanonical-extra-kind-external-declared':
    contract.target_profiles.push({
      ...contract.target_profiles[2],
      target_cluster: 'kind_rehearsal',
      substrate_source: 'external_declared',
      required: false
    });
    break;
  default:
    throw new Error(`unknown target profile mutation: ${mutation}`);
}

fs.writeFileSync(contractOutput, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

run_render() {
  local contract="$1"
  local deploy_template_package="$2"
  local archive="$3"
  local render_values="$4"
  local substrate_truth="$5"
  local output_dir="$6"
  local target_profile="${7:-$TARGET_PROFILE}"
  local forbidden_source_root="${8:-}"
  local image_map="${9:-}"

  local command=(
    bash "$ROOT_DIR/scripts/verify-release.sh" --render
    --release-contract "$contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --target-profile "$target_profile" \
    --render-values "$render_values" \
    --substrate-truth "$substrate_truth" \
    --output-dir "$output_dir"
  )
  if [[ -n "$forbidden_source_root" ]]; then
    command+=(--forbidden-source-root "$forbidden_source_root")
  fi
  if [[ -n "$image_map" ]]; then
    command+=(--image-map "$image_map")
  fi

  "${command[@]}"
}

expect_fail_case() {
  local label="$1"
  local contract="$2"
  local deploy_template_package="$3"
  local archive="$4"
  local render_values="$5"
  local substrate_truth="$6"
  local target_profile="${7:-$TARGET_PROFILE}"
  local forbidden_source_root="${8:-}"
  local image_map="${9:-}"
  local expected_stderr="${10:-}"
  local output_dir="$TMP_DIR/out-$label"

  if run_render \
    "$contract" \
    "$deploy_template_package" \
    "$archive" \
    "$render_values" \
    "$substrate_truth" \
    "$output_dir" \
    "$target_profile" \
    "$forbidden_source_root" \
    "$image_map" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid render case to fail: $label"
  fi

  if [[ -n "$expected_stderr" ]] && ! grep -Fq "$expected_stderr" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected render stderr to contain '$expected_stderr': $label"
  fi

  pass "invalid render rejected: $label"
}

expect_target_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local output_dir="$TMP_DIR/out-target-$label"

  if run_render \
    "$VALID_CONTRACT_MATERIAL" \
    "$VALID_PACKAGE_MATERIAL" \
    "$VALID_ARCHIVE" \
    "$VALID_VALUES" \
    "$VALID_TRUTH" \
    "$output_dir" \
    "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  if ! grep -q "canonical profiles" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected canonical target profile message for: $label"
  fi

  pass "canonical profiles only; non-canonical target profile rejected: $label"
}

expect_contract_target_profile_fail() {
  local label="$1"
  local mutation="$2"
  local contract="$TMP_DIR/release-contract.$label.json"
  local output_dir="$TMP_DIR/out-contract-target-$label"

  mutate_contract_target_profile "$mutation" "$VALID_CONTRACT_MATERIAL" "$contract"

  if run_render \
    "$contract" \
    "$VALID_PACKAGE_MATERIAL" \
    "$VALID_ARCHIVE" \
    "$VALID_VALUES" \
    "$VALID_TRUTH" \
    "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid release contract target profile to fail: $label"
  fi

  if ! grep -q "canonical profiles" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected canonical release contract target profile message for: $label"
  fi

  pass "release contract canonical target profiles enforced: $label"
}

prepare_archive_case() {
  local label="$1"
  local create_function="$2"
  local contract_output="$3"
  local deploy_template_package_output="$4"
  local archive="$TMP_DIR/$label.tgz"

  local manifest_sha
  manifest_sha="$("$create_function" "$archive")"
  local archive_sha
  archive_sha="$(sha256_file "$archive")"
  write_materials "$manifest_sha" "$archive_sha" "$contract_output" "$deploy_template_package_output"
  printf '%s\n' "$archive"
}

assert_pass_report() {
  local report_file="$1"
  local rendered_root="$2"

  "$NODE_BIN" --input-type=module - "$report_file" "$rendered_root" "$TARGET_PROFILE" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [reportFile, renderedRoot, expectedProfile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.manifest-render-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'manifest_render_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('manifest render report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.target_profile?.value !== expectedProfile) {
  throw new Error(`unexpected target profile: ${report.target_profile?.value}`);
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('manifest render report must not claim a verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('manifest render report must not include AgentSmith product flow fields');
}
if (!Array.isArray(report.rendered_files) || report.rendered_files.length !== 1) {
  throw new Error('manifest render report must list exactly one rendered file for the fixture');
}
const rendered = fs.readFileSync(path.join(renderedRoot, 'templates/workloads.yaml'), 'utf8');
if (rendered.includes('${{')) {
  throw new Error('rendered manifest must not contain unresolved placeholders');
}
if (!rendered.includes('namespace: agentsmith')) {
  throw new Error('rendered manifest must contain explicit values');
}
if (!rendered.includes('distribution: online')) {
  throw new Error('rendered manifest must contain target profile values');
}
if (rendered.includes('channel: stable') && !rendered.includes(`profile: ${expectedProfile}`)) {
  throw new Error('rendered manifest must bind values.PROFILE to the target profile');
}
if (rendered.includes('channel: stable') && !rendered.includes('pv-name: agentsmith-afscp-default-volume')) {
  throw new Error('rendered manifest must bind AFSCP_DEFAULT_VOLUME_PV_NAME to the namespace-scoped default');
}
if (!rendered.includes('postgresql.release.example.internal')) {
  throw new Error('rendered manifest must contain substrate truth values');
}
NODE
}

assert_afscp_volume_ref_rendered() {
  local rendered_file="$1"
  local expected_ref="$2"
  local expected_checksum="$3"

  "$NODE_BIN" --input-type=module - \
    "$rendered_file" \
    "$expected_ref" \
    "$expected_checksum" \
    "$AFSCP_VOLUME_BASE_REF" <<'NODE'
import fs from 'node:fs';

const [renderedFile, expectedRef, expectedChecksum, baseRef] = process.argv.slice(2);
const rendered = fs.readFileSync(renderedFile, 'utf8');
const required = [
  `name: ${expectedRef}`,
  `AFSCP_VOLUME_REF: ${expectedRef}`,
  `AFSCP_API_WORKLOAD_MOUNT_SECRET_REFS: workspace=agentsmith/${expectedRef}`,
  `AFSCP_RUNTIME_SECRETS_CHECKSUM: ${expectedChecksum}`
];

for (const text of required) {
  if (!rendered.includes(text)) {
    throw new Error(`rendered AFSCP manifest missing: ${text}`);
  }
}
if (expectedRef !== baseRef && rendered.includes(`name: ${baseRef}\n`)) {
  throw new Error('rendered PV nodePublishSecretRef kept the base Secret ref');
}
NODE
}

write_image_map() {
  local contract="$1"
  local output_dir="$2"
  local target_registry="$3"

  bash "$ROOT_DIR/scripts/verify-release.sh" --image-map \
    --release-contract "$contract" \
    --target-profile "$TARGET_PROFILE" \
    --output-dir "$output_dir" \
    --target-registry "$target_registry" >/dev/null
}

mutate_image_map() {
  local mutation="$1"
  local input="$2"
  local output="$3"
  local detail="${4:-}"

  "$NODE_BIN" --input-type=module - "$mutation" "$input" "$output" "$detail" <<'NODE'
import fs from 'node:fs';

const [mutation, input, output, detail = ''] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(input, 'utf8'));
const digest = (char) => `sha256:${char.repeat(64)}`;

switch (mutation) {
  case 'release-digest':
    imageMap.release_contract.input_sha256 = digest('9');
    break;
  case 'target-profile':
    imageMap.target_profile = {
      value: 'existing_kubernetes/external_declared/airgap',
      target_cluster: 'existing_kubernetes',
      substrate_source: 'external_declared',
      distribution: 'airgap'
    };
    break;
  case 'digest-drift':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /@sha256:[0-9a-f]{64}$/,
      `@${digest('2')}`
    );
    break;
  case 'target-registry-mismatch':
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      /^registry\.release\.example\/agentsmith\//,
      'attacker.example/'
    );
    break;
  case 'mirror-required-source-ref':
    imageMap.mappings[0].target_image = imageMap.mappings[0].source_image;
    break;
  case 'target-registry':
    imageMap.target_registry = detail;
    break;
  case 'extra-mapping':
    imageMap.mappings.push({
      ...imageMap.mappings[0],
      id: 'extra_image',
      target_image: imageMap.mappings[0].target_image.replace(
        '/agentsmith-app@',
        '/extra-image@'
      )
    });
    imageMap.image_count = imageMap.mappings.length;
    break;
  case 'readiness':
    imageMap.readiness = true;
    break;
  case 'verdict':
    imageMap.verdict = 'release-ready';
    break;
  case 'product-flow':
    imageMap.product_flows = ['workspace_project'];
    imageMap['product-flow'] = 'workspace_project';
    break;
  default:
    throw new Error(`unknown image-map mutation: ${mutation}`);
}

fs.writeFileSync(output, `${JSON.stringify(imageMap, null, 2)}\n`);
NODE
}

assert_rendered_image_adoption() {
  local rendered_file="$1"
  local image_map="$2"
  local mode="$3"

  "$NODE_BIN" --input-type=module - "$rendered_file" "$image_map" "$VALID_CONTRACT_MATERIAL" "$mode" <<'NODE'
import fs from 'node:fs';

const [renderedFile, imageMapFile, contractFile, mode] = process.argv.slice(2);
const rendered = fs.readFileSync(renderedFile, 'utf8');
const imageMap = JSON.parse(fs.readFileSync(imageMapFile, 'utf8'));
const contract = JSON.parse(fs.readFileSync(contractFile, 'utf8'));
const expectedImageIds = ['agentsmith_app', 'managed_runner'];

for (const imageId of expectedImageIds) {
  const source = contract.deploy_image_inventory.find((item) => item.id === imageId)?.image;
  const target = imageMap.mappings.find((item) => item.id === imageId)?.target_image;
  if (!source || !target) {
    throw new Error(`fixture image is missing: ${imageId}`);
  }

  if (mode === 'target') {
    if (!rendered.includes(target)) {
      throw new Error(`rendered manifest did not adopt target image for ${imageId}: ${target}`);
    }
    if (rendered.includes(source)) {
      throw new Error(`rendered manifest should not keep source image for ${imageId} when image-map is provided`);
    }
  } else {
    if (!rendered.includes(source)) {
      throw new Error(`rendered manifest did not use source image for ${imageId}: ${source}`);
    }
  }
}

if (mode !== 'target') {
  if (rendered.includes('registry.release.example/agentsmith/')) {
    throw new Error('rendered manifest should not use target registry without image-map');
  }
}
NODE
}

VALID_VALUES="$TMP_DIR/render-values.valid.json"
VALID_TRUTH="$TMP_DIR/substrate-truth.valid.json"
write_render_values "$VALID_VALUES"
write_truth "$VALID_TRUTH"

VALID_ARCHIVE="$TMP_DIR/valid.tgz"
VALID_MANIFEST_SHA="$(create_render_archive valid "$VALID_ARCHIVE" valid)"
VALID_ARCHIVE_SHA="$(sha256_file "$VALID_ARCHIVE")"
VALID_CONTRACT_MATERIAL="$TMP_DIR/release-contract.material.json"
VALID_PACKAGE_MATERIAL="$TMP_DIR/deploy-template-package.material.json"
write_materials "$VALID_MANIFEST_SHA" "$VALID_ARCHIVE_SHA" "$VALID_CONTRACT_MATERIAL" "$VALID_PACKAGE_MATERIAL"

VALID_OUT="$TMP_DIR/out-valid"
run_render \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$VALID_OUT" >/dev/null
assert_pass_report "$VALID_OUT/manifest-render-report.json" "$VALID_OUT/rendered-manifests"
TARGET_REGISTRY="registry.release.example/agentsmith"
VALID_IMAGE_MAP_DIR="$TMP_DIR/image-map-valid"
VALID_IMAGE_MAP="$VALID_IMAGE_MAP_DIR/image-map.json"
write_image_map "$VALID_CONTRACT_MATERIAL" "$VALID_IMAGE_MAP_DIR" "$TARGET_REGISTRY"
assert_rendered_image_adoption \
  "$VALID_OUT/rendered-manifests/templates/workloads.yaml" \
  "$VALID_IMAGE_MAP" \
  source
pass "valid render accepted with focused non-readiness report"

SUBSTRATE_TLS_ARCHIVE="$TMP_DIR/substrate-tls-values.tgz"
SUBSTRATE_TLS_MANIFEST_SHA="$(create_render_archive substrate-tls-values "$SUBSTRATE_TLS_ARCHIVE" substrate_tls_render_values)"
SUBSTRATE_TLS_ARCHIVE_SHA="$(sha256_file "$SUBSTRATE_TLS_ARCHIVE")"
SUBSTRATE_TLS_CONTRACT="$TMP_DIR/release-contract.substrate-tls-values.json"
SUBSTRATE_TLS_PACKAGE="$TMP_DIR/deploy-template-package.substrate-tls-values.json"
SUBSTRATE_TLS_OUT="$TMP_DIR/out-substrate-tls-values"
write_materials \
  "$SUBSTRATE_TLS_MANIFEST_SHA" \
  "$SUBSTRATE_TLS_ARCHIVE_SHA" \
  "$SUBSTRATE_TLS_CONTRACT" \
  "$SUBSTRATE_TLS_PACKAGE"
run_render \
  "$SUBSTRATE_TLS_CONTRACT" \
  "$SUBSTRATE_TLS_PACKAGE" \
  "$SUBSTRATE_TLS_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$SUBSTRATE_TLS_OUT" >/dev/null
assert_pass_report "$SUBSTRATE_TLS_OUT/manifest-render-report.json" "$SUBSTRATE_TLS_OUT/rendered-manifests"
grep -Fq 'SUBSTRATE_POSTGRES_CA_SECRET_REF: secretRef:release/postgresql-ca' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive postgresql CA secretRef from substrate truth"
grep -Fq 'SUBSTRATE_POSTGRES_CA_SECRET_NAME: postgresql-ca' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive postgresql CA secret name from substrate truth"
grep -Fq 'SUBSTRATE_POSTGRES_SSLMODE: verify-full' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive postgresql sslmode from substrate truth"
grep -Fq 'SUBSTRATE_POSTGRESQL_SSLMODE: verify-full' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive postgresql accepted-name sslmode alias from substrate truth"
grep -Fq 'SUBSTRATE_MINIO_USE_SSL: "true"' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive MinIO TLS use_ssl from substrate truth"
grep -Fq 'SUBSTRATE_OBJECT_STORAGE_USE_SSL: "true"' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive object-storage accepted-name use_ssl alias from substrate truth"
grep -Fq 'SUBSTRATE_OIDC_CA_SECRET_REF: secretRef:release/oidc-ca' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not derive OIDC accepted-name CA secretRef alias from substrate truth"
grep -Fq 'secretName: postgresql-ca' \
  "$SUBSTRATE_TLS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "render did not expose safe CA secret name for manifest mounts"
pass "render derives substrate CA secret refs/names and TLS mode from substrate truth"

AFSCP_VOLUME_REF_ARCHIVE="$TMP_DIR/afscp-volume-ref.tgz"
AFSCP_VOLUME_REF_MANIFEST_SHA="$(create_render_archive afscp-volume-ref "$AFSCP_VOLUME_REF_ARCHIVE" afscp_volume_ref)"
AFSCP_VOLUME_REF_ARCHIVE_SHA="$(sha256_file "$AFSCP_VOLUME_REF_ARCHIVE")"
AFSCP_VOLUME_REF_CONTRACT="$TMP_DIR/release-contract.afscp-volume-ref.json"
AFSCP_VOLUME_REF_PACKAGE="$TMP_DIR/deploy-template-package.afscp-volume-ref.json"
write_materials \
  "$AFSCP_VOLUME_REF_MANIFEST_SHA" \
  "$AFSCP_VOLUME_REF_ARCHIVE_SHA" \
  "$AFSCP_VOLUME_REF_CONTRACT" \
  "$AFSCP_VOLUME_REF_PACKAGE"

AFSCP_VOLUME_REF_STABLE_VALUES="$TMP_DIR/render-values.afscp-volume-ref-stable.json"
AFSCP_VOLUME_REF_STABLE_OUT="$TMP_DIR/out-afscp-volume-ref-stable"
write_render_values "$AFSCP_VOLUME_REF_STABLE_VALUES" afscp_volume_ref_stable
run_render \
  "$AFSCP_VOLUME_REF_CONTRACT" \
  "$AFSCP_VOLUME_REF_PACKAGE" \
  "$AFSCP_VOLUME_REF_ARCHIVE" \
  "$AFSCP_VOLUME_REF_STABLE_VALUES" \
  "$VALID_TRUTH" \
  "$AFSCP_VOLUME_REF_STABLE_OUT" >/dev/null
assert_pass_report "$AFSCP_VOLUME_REF_STABLE_OUT/manifest-render-report.json" "$AFSCP_VOLUME_REF_STABLE_OUT/rendered-manifests"
assert_afscp_volume_ref_rendered \
  "$AFSCP_VOLUME_REF_STABLE_OUT/rendered-manifests/templates/workloads.yaml" \
  "$AFSCP_VOLUME_BASE_REF" \
  stable
pass "render keeps stable AFSCP volume ref literal"

AFSCP_VOLUME_REF_SHA_VALUES="$TMP_DIR/render-values.afscp-volume-ref-sha.json"
AFSCP_VOLUME_REF_SHA_OUT="$TMP_DIR/out-afscp-volume-ref-sha"
write_render_values "$AFSCP_VOLUME_REF_SHA_VALUES" afscp_volume_ref_sha
run_render \
  "$AFSCP_VOLUME_REF_CONTRACT" \
  "$AFSCP_VOLUME_REF_PACKAGE" \
  "$AFSCP_VOLUME_REF_ARCHIVE" \
  "$AFSCP_VOLUME_REF_SHA_VALUES" \
  "$VALID_TRUTH" \
  "$AFSCP_VOLUME_REF_SHA_OUT" >/dev/null
assert_pass_report "$AFSCP_VOLUME_REF_SHA_OUT/manifest-render-report.json" "$AFSCP_VOLUME_REF_SHA_OUT/rendered-manifests"
assert_afscp_volume_ref_rendered \
  "$AFSCP_VOLUME_REF_SHA_OUT/rendered-manifests/templates/workloads.yaml" \
  "$AFSCP_EFFECTIVE_VOLUME_REF" \
  "$AFSCP_VOLUME_REVISION"
pass "render derives revisioned AFSCP volume ref from sha256 revision"

AFSCP_VOLUME_REF_SUFFIXED_VALUES="$TMP_DIR/render-values.afscp-volume-ref-suffixed.json"
AFSCP_VOLUME_REF_SUFFIXED_OUT="$TMP_DIR/out-afscp-volume-ref-suffixed"
write_render_values "$AFSCP_VOLUME_REF_SUFFIXED_VALUES" afscp_volume_ref_suffixed
run_render \
  "$AFSCP_VOLUME_REF_CONTRACT" \
  "$AFSCP_VOLUME_REF_PACKAGE" \
  "$AFSCP_VOLUME_REF_ARCHIVE" \
  "$AFSCP_VOLUME_REF_SUFFIXED_VALUES" \
  "$VALID_TRUTH" \
  "$AFSCP_VOLUME_REF_SUFFIXED_OUT" >/dev/null
assert_pass_report "$AFSCP_VOLUME_REF_SUFFIXED_OUT/manifest-render-report.json" "$AFSCP_VOLUME_REF_SUFFIXED_OUT/rendered-manifests"
assert_afscp_volume_ref_rendered \
  "$AFSCP_VOLUME_REF_SUFFIXED_OUT/rendered-manifests/templates/workloads.yaml" \
  "$AFSCP_EFFECTIVE_VOLUME_REF" \
  "$AFSCP_VOLUME_REVISION"
pass "render keeps already suffixed AFSCP volume ref idempotent"

AFSCP_VOLUME_REF_STALE_SUFFIX_VALUES="$TMP_DIR/render-values.afscp-volume-ref-stale-suffix.json"
AFSCP_VOLUME_REF_STALE_SUFFIX_OUT="$TMP_DIR/out-afscp-volume-ref-stale-suffix"
write_render_values "$AFSCP_VOLUME_REF_STALE_SUFFIX_VALUES" afscp_volume_ref_stale_suffix
run_render \
  "$AFSCP_VOLUME_REF_CONTRACT" \
  "$AFSCP_VOLUME_REF_PACKAGE" \
  "$AFSCP_VOLUME_REF_ARCHIVE" \
  "$AFSCP_VOLUME_REF_STALE_SUFFIX_VALUES" \
  "$VALID_TRUTH" \
  "$AFSCP_VOLUME_REF_STALE_SUFFIX_OUT" >/dev/null
assert_pass_report "$AFSCP_VOLUME_REF_STALE_SUFFIX_OUT/manifest-render-report.json" "$AFSCP_VOLUME_REF_STALE_SUFFIX_OUT/rendered-manifests"
assert_afscp_volume_ref_rendered \
  "$AFSCP_VOLUME_REF_STALE_SUFFIX_OUT/rendered-manifests/templates/workloads.yaml" \
  "$AFSCP_STALE_SUFFIX_EFFECTIVE_VOLUME_REF" \
  "$AFSCP_VOLUME_REVISION"
pass "render appends current AFSCP volume ref suffix after a different 12hex suffix"

AFSCP_VOLUME_REF_STALE_CHECKSUM_VALUES="$TMP_DIR/render-values.afscp-volume-ref-stale-checksum.json"
AFSCP_VOLUME_REF_STALE_CHECKSUM_OUT="$TMP_DIR/out-afscp-volume-ref-stale-checksum"
write_render_values "$AFSCP_VOLUME_REF_STALE_CHECKSUM_VALUES" afscp_volume_ref_stale_checksum
run_render \
  "$AFSCP_VOLUME_REF_CONTRACT" \
  "$AFSCP_VOLUME_REF_PACKAGE" \
  "$AFSCP_VOLUME_REF_ARCHIVE" \
  "$AFSCP_VOLUME_REF_STALE_CHECKSUM_VALUES" \
  "$VALID_TRUTH" \
  "$AFSCP_VOLUME_REF_STALE_CHECKSUM_OUT" >/dev/null
assert_pass_report "$AFSCP_VOLUME_REF_STALE_CHECKSUM_OUT/manifest-render-report.json" "$AFSCP_VOLUME_REF_STALE_CHECKSUM_OUT/rendered-manifests"
assert_afscp_volume_ref_rendered \
  "$AFSCP_VOLUME_REF_STALE_CHECKSUM_OUT/rendered-manifests/templates/workloads.yaml" \
  "$AFSCP_EFFECTIVE_VOLUME_REF" \
  "$AFSCP_EXPLICIT_RUNTIME_SECRETS_CHECKSUM"
pass "render preserves explicit AFSCP runtime secrets checksum"

"$NODE_BIN" --input-type=module - "$ROOT_DIR" "$AFSCP_VOLUME_REVISION" "$AFSCP_VOLUME_REVISION_SUFFIX" <<'NODE'
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, revision, suffix] = process.argv.slice(2);
const { normalizeAfscpVolumeRefRenderValues } = await import(
  pathToFileURL(path.join(rootDir, 'scripts/lib/substrate-render-values.mjs'))
);
const longBase = 'a'.repeat(300);
const normalized = normalizeAfscpVolumeRefRenderValues({
  AFSCP_VOLUME_REF: longBase,
  AFSCP_VOLUME_REF_REVISION: revision
});
const expected = `${'a'.repeat(253 - suffix.length - 1)}-${suffix}`;
if (normalized.AFSCP_VOLUME_REF !== expected) {
  throw new Error(`expected truncated AFSCP ref ${expected}, got ${normalized.AFSCP_VOLUME_REF}`);
}
if (normalized.AFSCP_VOLUME_REF.length > 253) {
  throw new Error('normalized AFSCP ref must not exceed Kubernetes Secret name length');
}
for (const badRef of ['afscp.volume', '-afscp-volume', 'afscp-volume-']) {
  let rejected = false;
  try {
    normalizeAfscpVolumeRefRenderValues({
      AFSCP_VOLUME_REF: badRef,
      AFSCP_VOLUME_REF_REVISION: revision
    });
  } catch {
    rejected = true;
  }
  if (!rejected) {
    throw new Error(`expected invalid AFSCP ref to be rejected: ${badRef}`);
  }
}
NODE
pass "render validates AFSCP volume refs as dotless DNS-label-shaped Secret names"

"$NODE_BIN" --input-type=module - "$ROOT_DIR" "$VALID_TRUTH" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, truthPath] = process.argv.slice(2);
const { deriveSubstrateRenderValues, mergeSubstrateRenderValues } = await import(
  pathToFileURL(path.join(rootDir, 'scripts/lib/substrate-render-values.mjs'))
);
const truth = JSON.parse(fs.readFileSync(truthPath, 'utf8'));

truth.services.postgresql.tls.mode = 'plaintext';
truth.services.postgresql.sslmode = 'plaintext';
truth.services.object_storage.tls.mode = 'http';
truth.services.object_storage.url = 'http://objects.release.example.internal';

const values = deriveSubstrateRenderValues(truth);
const absentKeys = [
  'SUBSTRATE_POSTGRES_CA_SECRET_REF',
  'SUBSTRATE_POSTGRES_CA_SECRET_NAME',
  'SUBSTRATE_POSTGRESQL_CA_SECRET_REF',
  'SUBSTRATE_POSTGRESQL_CA_SECRET_NAME',
  'SUBSTRATE_MINIO_CA_SECRET_REF',
  'SUBSTRATE_MINIO_CA_SECRET_NAME',
  'SUBSTRATE_OBJECT_STORAGE_CA_SECRET_REF',
  'SUBSTRATE_OBJECT_STORAGE_CA_SECRET_NAME'
];
for (const key of absentKeys) {
  if (Object.prototype.hasOwnProperty.call(values, key)) {
    throw new Error(`disabled TLS mode must not derive CA render value: ${key}`);
  }
}

const expected = {
  SUBSTRATE_POSTGRES_TLS_MODE: 'plaintext',
  SUBSTRATE_POSTGRES_SSLMODE: 'plaintext',
  SUBSTRATE_POSTGRES_USE_SSL: false,
  SUBSTRATE_POSTGRESQL_TLS_MODE: 'plaintext',
  SUBSTRATE_POSTGRESQL_SSLMODE: 'plaintext',
  SUBSTRATE_POSTGRESQL_USE_SSL: false,
  SUBSTRATE_MINIO_TLS_MODE: 'http',
  SUBSTRATE_MINIO_USE_SSL: false,
  SUBSTRATE_OBJECT_STORAGE_TLS_MODE: 'http',
  SUBSTRATE_OBJECT_STORAGE_USE_SSL: false
};
for (const [key, expectedValue] of Object.entries(expected)) {
  if (values[key] !== expectedValue) {
    throw new Error(`expected ${key}=${expectedValue}, got ${values[key]}`);
  }
}

mergeSubstrateRenderValues(
  {
    SUBSTRATE_POSTGRES_USE_SSL: false,
    SUBSTRATE_POSTGRESQL_USE_SSL: 'false',
    SUBSTRATE_MINIO_USE_SSL: false,
    SUBSTRATE_OBJECT_STORAGE_USE_SSL: 'false'
  },
  truth
);
NODE
pass "render treats plaintext/http substrate TLS modes as disabled without CA or USE_SSL conflicts"

DOTTED_CA_TRUTH="$TMP_DIR/substrate-truth.dotted-ca-secret.json"
"$NODE_BIN" --input-type=module - "$VALID_TRUTH" "$DOTTED_CA_TRUTH" <<'NODE'
import fs from 'node:fs';

const [input, output] = process.argv.slice(2);
const truth = JSON.parse(fs.readFileSync(input, 'utf8'));
truth.services.postgresql.tls.ca_secret_ref = 'secretRef:release/postgresql.ca';
fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
expect_fail_case \
  dotted-ca-secret-name \
  "$SUBSTRATE_TLS_CONTRACT" \
  "$SUBSTRATE_TLS_PACKAGE" \
  "$SUBSTRATE_TLS_ARCHIVE" \
  "$VALID_VALUES" \
  "$DOTTED_CA_TRUTH"
grep -Fq 'must be a Kubernetes DNS label Secret name' "$TMP_DIR/dotted-ca-secret-name.err" ||
  fail "render should reject substrate CA Secret names containing dots"
pass "render rejects substrate CA Secret names that are not AgentSmith DNS labels"

INGRESS_ARCHIVE="$TMP_DIR/with-ingress.tgz"
INGRESS_MANIFEST_SHA="$(create_render_archive with-ingress "$INGRESS_ARCHIVE" with_ingress)"
INGRESS_ARCHIVE_SHA="$(sha256_file "$INGRESS_ARCHIVE")"
INGRESS_CONTRACT="$TMP_DIR/release-contract.with-ingress.json"
INGRESS_PACKAGE="$TMP_DIR/deploy-template-package.with-ingress.json"
INGRESS_OUT="$TMP_DIR/out-with-ingress"
write_materials \
  "$INGRESS_MANIFEST_SHA" \
  "$INGRESS_ARCHIVE_SHA" \
  "$INGRESS_CONTRACT" \
  "$INGRESS_PACKAGE"
run_render \
  "$INGRESS_CONTRACT" \
  "$INGRESS_PACKAGE" \
  "$INGRESS_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$INGRESS_OUT" >/dev/null
assert_pass_report "$INGRESS_OUT/manifest-render-report.json" "$INGRESS_OUT/rendered-manifests"
grep -Fq 'host: agentsmith.release.example.com' "$INGRESS_OUT/rendered-manifests/templates/workloads.yaml" ||
  fail "rendered ingress did not derive host from PUBLIC_BASE_URL"
pass "render derives ingress host from PUBLIC_BASE_URL"

HOSTLESS_INGRESS_ARCHIVE="$TMP_DIR/hostless-ingress.tgz"
HOSTLESS_INGRESS_MANIFEST_SHA="$(create_render_archive hostless-ingress "$HOSTLESS_INGRESS_ARCHIVE" hostless_ingress)"
HOSTLESS_INGRESS_ARCHIVE_SHA="$(sha256_file "$HOSTLESS_INGRESS_ARCHIVE")"
HOSTLESS_INGRESS_CONTRACT="$TMP_DIR/release-contract.hostless-ingress.json"
HOSTLESS_INGRESS_PACKAGE="$TMP_DIR/deploy-template-package.hostless-ingress.json"
write_materials \
  "$HOSTLESS_INGRESS_MANIFEST_SHA" \
  "$HOSTLESS_INGRESS_ARCHIVE_SHA" \
  "$HOSTLESS_INGRESS_CONTRACT" \
  "$HOSTLESS_INGRESS_PACKAGE"
expect_fail_case \
  hostless-ingress \
  "$HOSTLESS_INGRESS_CONTRACT" \
  "$HOSTLESS_INGRESS_PACKAGE" \
  "$HOSTLESS_INGRESS_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "must declare spec.rules[].host"

SINGLE_LABEL_ENDPOINTSLICE_VALUES="$TMP_DIR/render-values.single-label-endpointslice-fqdn.json"
write_render_values "$SINGLE_LABEL_ENDPOINTSLICE_VALUES" single_label_endpointslice_fqdn
expect_fail_case \
  single-label-endpointslice-fqdn \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$SINGLE_LABEL_ENDPOINTSLICE_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.SUBSTRATE_POSTGRES_HOST must be an IPv4/IPv6 address or an EndpointSlice FQDN with at least two DNS labels"

URL_ENDPOINTSLICE_VALUES="$TMP_DIR/render-values.url-endpointslice-fqdn.json"
write_render_values "$URL_ENDPOINTSLICE_VALUES" url_endpointslice_fqdn
expect_fail_case \
  url-endpointslice-fqdn \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$URL_ENDPOINTSLICE_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.SUBSTRATE_POSTGRES_HOST must be an EndpointSlice address literal without scheme, path, port, or userinfo"

HOST_PORT_ENDPOINTSLICE_FQDN_VALUES="$TMP_DIR/render-values.host-port-endpointslice-fqdn.json"
write_render_values "$HOST_PORT_ENDPOINTSLICE_FQDN_VALUES" host_port_endpointslice_fqdn
expect_fail_case \
  host-port-endpointslice-fqdn \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$HOST_PORT_ENDPOINTSLICE_FQDN_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.SUBSTRATE_POSTGRES_HOST must be an EndpointSlice address literal without scheme, path, port, or userinfo"

HOST_PORT_ENDPOINTSLICE_IPV4_VALUES="$TMP_DIR/render-values.host-port-endpointslice-ipv4.json"
write_render_values "$HOST_PORT_ENDPOINTSLICE_IPV4_VALUES" host_port_endpointslice_ipv4
expect_fail_case \
  host-port-endpointslice-ipv4 \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$HOST_PORT_ENDPOINTSLICE_IPV4_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.SUBSTRATE_POSTGRES_HOST must be an EndpointSlice address literal without scheme, path, port, or userinfo"

AFSCP_DEFAULT_VOLUME_ID_DEFAULT_VALUES="$TMP_DIR/render-values.afscp-default-volume-id-default.json"
write_render_values "$AFSCP_DEFAULT_VOLUME_ID_DEFAULT_VALUES" afscp_default_volume_id_default
expect_fail_case \
  afscp-default-volume-id-default \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$AFSCP_DEFAULT_VOLUME_ID_DEFAULT_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.AFSCP_DEFAULT_VOLUME_ID must match AFSCP volume id pattern vol_<suffix>"

AFSCP_DEFAULT_VOLUME_READY_WORKSPACE_VALUES="$TMP_DIR/render-values.afscp-default-volume-ready-workspace.json"
write_render_values "$AFSCP_DEFAULT_VOLUME_READY_WORKSPACE_VALUES" afscp_default_volume_ready_workspace
expect_fail_case \
  afscp-default-volume-ready-workspace \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$AFSCP_DEFAULT_VOLUME_READY_WORKSPACE_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.AFSCP_DEFAULT_VOLUME_ISOLATION_CLASS must be shared"

AFSCP_DEFAULT_VOLUME_BAD_CAPABILITIES_VALUES="$TMP_DIR/render-values.afscp-default-volume-bad-capabilities.json"
write_render_values "$AFSCP_DEFAULT_VOLUME_BAD_CAPABILITIES_VALUES" afscp_default_volume_bad_capabilities
expect_fail_case \
  afscp-default-volume-bad-capabilities \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$AFSCP_DEFAULT_VOLUME_BAD_CAPABILITIES_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.AFSCP_DEFAULT_VOLUME_CAPABILITIES_JSON.jvs_external_control_root must be true"

PROFILE_MISMATCH_VALUES="$TMP_DIR/render-values.profile-mismatch.json"
write_render_values "$PROFILE_MISMATCH_VALUES" profile_mismatch
expect_fail_case \
  profile-mismatch \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$PROFILE_MISMATCH_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.PROFILE must match --target-profile"

INGRESS_HOST_MISMATCH_VALUES="$TMP_DIR/render-values.ingress-host-mismatch.json"
write_render_values "$INGRESS_HOST_MISMATCH_VALUES" ingress_host_mismatch
expect_fail_case \
  ingress-host-mismatch \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$INGRESS_HOST_MISMATCH_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.INGRESS_HOST must match render_values.PUBLIC_BASE_URL host"

AFSCP_DEFAULT_VOLUME_PV_NAME_MISMATCH_VALUES="$TMP_DIR/render-values.afscp-default-volume-pv-name-mismatch.json"
write_render_values "$AFSCP_DEFAULT_VOLUME_PV_NAME_MISMATCH_VALUES" afscp_default_volume_pv_name_mismatch
expect_fail_case \
  afscp-default-volume-pv-name-mismatch \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$AFSCP_DEFAULT_VOLUME_PV_NAME_MISMATCH_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "render_values.AFSCP_DEFAULT_VOLUME_PV_NAME must match the namespace-scoped default"

STALE_REQUIRED_IDS_CONTRACT="$TMP_DIR/release-contract.stale-six-image-required-image-ids.json"
STALE_REQUIRED_IDS_PACKAGE="$TMP_DIR/deploy-template-package.stale-six-image-required-image-ids.json"
mutate_required_image_ids \
  stale-six-image-required-image-ids \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$STALE_REQUIRED_IDS_CONTRACT" \
  "$STALE_REQUIRED_IDS_PACKAGE"
expect_fail_case \
  stale-six-image-required-image-ids \
  "$STALE_REQUIRED_IDS_CONTRACT" \
  "$STALE_REQUIRED_IDS_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "release_contract.deploy_template_package.required_image_ids must match release_contract.deploy_image_inventory ids"

MISSING_REQUIRED_ID_CONTRACT="$TMP_DIR/release-contract.required-current-id-absent-from-inventory.json"
MISSING_REQUIRED_ID_PACKAGE="$TMP_DIR/deploy-template-package.required-current-id-absent-from-inventory.json"
mutate_required_image_ids \
  required-current-id-absent-from-inventory \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$MISSING_REQUIRED_ID_CONTRACT" \
  "$MISSING_REQUIRED_ID_PACKAGE"
expect_fail_case \
  required-current-id-absent-from-inventory \
  "$MISSING_REQUIRED_ID_CONTRACT" \
  "$MISSING_REQUIRED_ID_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "release_contract.deploy_image_inventory must match declared image sources"

ADOPTED_ID_DRIFT_CONTRACT="$TMP_DIR/release-contract.adopted-provider-image-inventory-id-drift.json"
ADOPTED_ID_DRIFT_PACKAGE="$TMP_DIR/deploy-template-package.adopted-provider-image-inventory-id-drift.json"
mutate_required_image_ids \
  adopted-provider-image-inventory-id-drift \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$ADOPTED_ID_DRIFT_CONTRACT" \
  "$ADOPTED_ID_DRIFT_PACKAGE"
expect_fail_case \
  adopted-provider-image-inventory-id-drift \
  "$ADOPTED_ID_DRIFT_CONTRACT" \
  "$ADOPTED_ID_DRIFT_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "release_contract.deploy_image_inventory must match declared image sources"

MANAGED_RUNNER_ID_DRIFT_CONTRACT="$TMP_DIR/release-contract.managed-runner-inventory-id-drift.json"
MANAGED_RUNNER_ID_DRIFT_PACKAGE="$TMP_DIR/deploy-template-package.managed-runner-inventory-id-drift.json"
mutate_required_image_ids \
  managed-runner-inventory-id-drift \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$MANAGED_RUNNER_ID_DRIFT_CONTRACT" \
  "$MANAGED_RUNNER_ID_DRIFT_PACKAGE"
expect_fail_case \
  managed-runner-inventory-id-drift \
  "$MANAGED_RUNNER_ID_DRIFT_CONTRACT" \
  "$MANAGED_RUNNER_ID_DRIFT_PACKAGE" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "" \
  "" \
  "release_contract.deploy_image_inventory must match declared image sources"

IMAGE_MAP_OUT="$TMP_DIR/out-valid-image-map"
run_render \
  "$VALID_CONTRACT_MATERIAL" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$IMAGE_MAP_OUT" \
  "$TARGET_PROFILE" \
  "" \
  "$VALID_IMAGE_MAP" >/dev/null
assert_pass_report "$IMAGE_MAP_OUT/manifest-render-report.json" "$IMAGE_MAP_OUT/rendered-manifests"
assert_rendered_image_adoption \
  "$IMAGE_MAP_OUT/rendered-manifests/templates/workloads.yaml" \
  "$VALID_IMAGE_MAP" \
  target
pass "valid render with image-map adopts target registry image refs"

for mutation in release-digest target-profile digest-drift extra-mapping readiness verdict product-flow; do
  bad_image_map="$TMP_DIR/image-map.$mutation.json"
  mutate_image_map "$mutation" "$VALID_IMAGE_MAP" "$bad_image_map"
  expect_fail_case "bad-image-map-$mutation" \
    "$VALID_CONTRACT_MATERIAL" \
    "$VALID_PACKAGE_MATERIAL" \
    "$VALID_ARCHIVE" \
    "$VALID_VALUES" \
    "$VALID_TRUTH" \
    "$TARGET_PROFILE" \
    "" \
    "$bad_image_map"
done

for mutation in target-registry-mismatch mirror-required-source-ref; do
  bad_image_map="$TMP_DIR/image-map.$mutation.json"
  mutate_image_map "$mutation" "$VALID_IMAGE_MAP" "$bad_image_map"
  expect_fail_case "bad-image-map-$mutation" \
    "$VALID_CONTRACT_MATERIAL" \
    "$VALID_PACKAGE_MATERIAL" \
    "$VALID_ARCHIVE" \
    "$VALID_VALUES" \
    "$VALID_TRUTH" \
    "$TARGET_PROFILE" \
    "" \
    "$bad_image_map"
done

while IFS='|' read -r label target_registry; do
  bad_image_map="$TMP_DIR/image-map.invalid-target-registry-$label.json"
  mutate_image_map target-registry "$VALID_IMAGE_MAP" "$bad_image_map" "$target_registry"
  expect_fail_case "bad-image-map-invalid-target-registry-$label" \
    "$VALID_CONTRACT_MATERIAL" \
    "$VALID_PACKAGE_MATERIAL" \
    "$VALID_ARCHIVE" \
    "$VALID_VALUES" \
    "$VALID_TRUTH" \
    "$TARGET_PROFILE" \
    "" \
    "$bad_image_map"
done <<'CASES'
scheme|https://registry.release.example/agentsmith
userinfo|user@registry.release.example/agentsmith
localhost|localhost:5000/agentsmith
query|registry.release.example/agentsmith?pull=true
uppercase-namespace|registry.release.example/Agentsmith
CASES

if bash "$ROOT_DIR/scripts/verify-release.sh" --render \
  --release-contract "$VALID_CONTRACT_MATERIAL" \
  --deploy-template-package "$VALID_PACKAGE_MATERIAL" \
  --archive "$VALID_ARCHIVE" \
  --target-profile "$TARGET_PROFILE" \
  --render-values "$VALID_VALUES" \
  --output-dir "$TMP_DIR/out-missing-substrate" >"$TMP_DIR/missing-arg.out" 2>"$TMP_DIR/missing-arg.err"; then
  fail "expected missing required render arg to fail"
fi
pass "missing required render argument rejected"

UNKNOWN_VARIABLE_ARCHIVE="$TMP_DIR/unknown-variable.tgz"
UNKNOWN_VARIABLE_MANIFEST_SHA="$(create_render_archive unknown-variable "$UNKNOWN_VARIABLE_ARCHIVE" unknown_variable)"
UNKNOWN_VARIABLE_ARCHIVE_SHA="$(sha256_file "$UNKNOWN_VARIABLE_ARCHIVE")"
UNKNOWN_VARIABLE_CONTRACT="$TMP_DIR/release-contract.unknown-variable.json"
UNKNOWN_VARIABLE_PACKAGE="$TMP_DIR/deploy-template-package.unknown-variable.json"
write_materials \
  "$UNKNOWN_VARIABLE_MANIFEST_SHA" \
  "$UNKNOWN_VARIABLE_ARCHIVE_SHA" \
  "$UNKNOWN_VARIABLE_CONTRACT" \
  "$UNKNOWN_VARIABLE_PACKAGE"
expect_fail_case unknown-variable \
  "$UNKNOWN_VARIABLE_CONTRACT" \
  "$UNKNOWN_VARIABLE_PACKAGE" \
  "$UNKNOWN_VARIABLE_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

expect_target_profile_fail noncanonical-local-kind "local-kind/external_declared/online"
expect_target_profile_fail noncanonical-kind-external-declared "kind_rehearsal/external_declared/online"
expect_contract_target_profile_fail \
  contract-noncanonical-extra-kind-external-declared \
  noncanonical-extra-kind-external-declared

MISSING_REQUIRED_CONTRACT="$TMP_DIR/release-contract.missing-target-required.json"
mutate_contract_target_profile missing-required \
  "$VALID_CONTRACT_MATERIAL" \
  "$MISSING_REQUIRED_CONTRACT"
expect_fail_case missing-target-profile-required \
  "$MISSING_REQUIRED_CONTRACT" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

REQUIRED_STRING_CONTRACT="$TMP_DIR/release-contract.target-required-string.json"
mutate_contract_target_profile required-string \
  "$VALID_CONTRACT_MATERIAL" \
  "$REQUIRED_STRING_CONTRACT"
expect_fail_case target-profile-required-string \
  "$REQUIRED_STRING_CONTRACT" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

REQUIRED_TRUE_CONTRACT="$TMP_DIR/release-contract.target-required-true.json"
REQUIRED_TRUE_OUT="$TMP_DIR/out-target-required-true"
mutate_contract_target_profile required-true \
  "$VALID_CONTRACT_MATERIAL" \
  "$REQUIRED_TRUE_CONTRACT"
run_render \
  "$REQUIRED_TRUE_CONTRACT" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$REQUIRED_TRUE_OUT" >"$TMP_DIR/target-required-true.out"
assert_pass_report "$REQUIRED_TRUE_OUT/manifest-render-report.json" "$REQUIRED_TRUE_OUT/rendered-manifests"
pass "render consumes final GA required target profiles without claiming readiness"

SUPPORT_LEVEL_CONTRACT="$TMP_DIR/release-contract.support-level-present.json"
mutate_contract_target_profile support-level-present \
  "$VALID_CONTRACT_MATERIAL" \
  "$SUPPORT_LEVEL_CONTRACT"
expect_fail_case target-profile-support-level-present \
  "$SUPPORT_LEVEL_CONTRACT" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

TRAVERSAL_CONTRACT="$TMP_DIR/release-contract.traversal.json"
TRAVERSAL_PACKAGE="$TMP_DIR/deploy-template-package.traversal.json"
TRAVERSAL_ARCHIVE="$(prepare_archive_case traversal create_traversal_archive "$TRAVERSAL_CONTRACT" "$TRAVERSAL_PACKAGE")"
expect_fail_case path-traversal "$TRAVERSAL_CONTRACT" "$TRAVERSAL_PACKAGE" "$TRAVERSAL_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH"

SYMLINK_CONTRACT="$TMP_DIR/release-contract.symlink.json"
SYMLINK_PACKAGE="$TMP_DIR/deploy-template-package.symlink.json"
SYMLINK_ARCHIVE="$(prepare_archive_case symlink create_symlink_archive "$SYMLINK_CONTRACT" "$SYMLINK_PACKAGE")"
expect_fail_case symlink "$SYMLINK_CONTRACT" "$SYMLINK_PACKAGE" "$SYMLINK_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH"

HARDLINK_CONTRACT="$TMP_DIR/release-contract.hardlink.json"
HARDLINK_PACKAGE="$TMP_DIR/deploy-template-package.hardlink.json"
HARDLINK_ARCHIVE="$(prepare_archive_case hardlink create_hardlink_archive "$HARDLINK_CONTRACT" "$HARDLINK_PACKAGE")"
expect_fail_case hardlink "$HARDLINK_CONTRACT" "$HARDLINK_PACKAGE" "$HARDLINK_ARCHIVE" "$VALID_VALUES" "$VALID_TRUTH"

UNKNOWN_IMAGE_ARCHIVE="$TMP_DIR/unknown-image.tgz"
UNKNOWN_IMAGE_MANIFEST_SHA="$(create_render_archive unknown-image "$UNKNOWN_IMAGE_ARCHIVE" unknown_image)"
UNKNOWN_IMAGE_ARCHIVE_SHA="$(sha256_file "$UNKNOWN_IMAGE_ARCHIVE")"
UNKNOWN_IMAGE_CONTRACT="$TMP_DIR/release-contract.unknown-image.json"
UNKNOWN_IMAGE_PACKAGE="$TMP_DIR/deploy-template-package.unknown-image.json"
write_materials \
  "$UNKNOWN_IMAGE_MANIFEST_SHA" \
  "$UNKNOWN_IMAGE_ARCHIVE_SHA" \
  "$UNKNOWN_IMAGE_CONTRACT" \
  "$UNKNOWN_IMAGE_PACKAGE"
expect_fail_case unknown-image \
  "$UNKNOWN_IMAGE_CONTRACT" \
  "$UNKNOWN_IMAGE_PACKAGE" \
  "$UNKNOWN_IMAGE_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

TAG_ONLY_ARCHIVE="$TMP_DIR/tag-only-image.tgz"
TAG_ONLY_MANIFEST_SHA="$(create_render_archive tag-only-image "$TAG_ONLY_ARCHIVE" tag_only_image)"
TAG_ONLY_ARCHIVE_SHA="$(sha256_file "$TAG_ONLY_ARCHIVE")"
TAG_ONLY_CONTRACT="$TMP_DIR/release-contract.tag-only-image.json"
TAG_ONLY_PACKAGE="$TMP_DIR/deploy-template-package.tag-only-image.json"
write_materials \
  "$TAG_ONLY_MANIFEST_SHA" \
  "$TAG_ONLY_ARCHIVE_SHA" \
  "$TAG_ONLY_CONTRACT" \
  "$TAG_ONLY_PACKAGE"
expect_fail_case tag-only-image \
  "$TAG_ONLY_CONTRACT" \
  "$TAG_ONLY_PACKAGE" \
  "$TAG_ONLY_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

SECRET_ARCHIVE="$TMP_DIR/secret-payload.tgz"
SECRET_MANIFEST_SHA="$(create_render_archive secret-payload "$SECRET_ARCHIVE" secret_payload)"
SECRET_ARCHIVE_SHA="$(sha256_file "$SECRET_ARCHIVE")"
SECRET_CONTRACT="$TMP_DIR/release-contract.secret-payload.json"
SECRET_PACKAGE="$TMP_DIR/deploy-template-package.secret-payload.json"
write_materials \
  "$SECRET_MANIFEST_SHA" \
  "$SECRET_ARCHIVE_SHA" \
  "$SECRET_CONTRACT" \
  "$SECRET_PACKAGE"
expect_fail_case secret-payload \
  "$SECRET_CONTRACT" \
  "$SECRET_PACKAGE" \
  "$SECRET_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH"

AFSCP_SECRET_REFS_ARCHIVE="$TMP_DIR/afscp-workload-mount-secret-refs.tgz"
AFSCP_SECRET_REFS_MANIFEST_SHA="$(create_render_archive afscp-workload-mount-secret-refs "$AFSCP_SECRET_REFS_ARCHIVE" afscp_workload_mount_secret_refs)"
AFSCP_SECRET_REFS_ARCHIVE_SHA="$(sha256_file "$AFSCP_SECRET_REFS_ARCHIVE")"
AFSCP_SECRET_REFS_CONTRACT="$TMP_DIR/release-contract.afscp-workload-mount-secret-refs.json"
AFSCP_SECRET_REFS_PACKAGE="$TMP_DIR/deploy-template-package.afscp-workload-mount-secret-refs.json"
AFSCP_SECRET_REFS_OUT="$TMP_DIR/out-afscp-workload-mount-secret-refs"
write_materials \
  "$AFSCP_SECRET_REFS_MANIFEST_SHA" \
  "$AFSCP_SECRET_REFS_ARCHIVE_SHA" \
  "$AFSCP_SECRET_REFS_CONTRACT" \
  "$AFSCP_SECRET_REFS_PACKAGE"
run_render \
  "$AFSCP_SECRET_REFS_CONTRACT" \
  "$AFSCP_SECRET_REFS_PACKAGE" \
  "$AFSCP_SECRET_REFS_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$AFSCP_SECRET_REFS_OUT" >/dev/null
assert_pass_report "$AFSCP_SECRET_REFS_OUT/manifest-render-report.json" "$AFSCP_SECRET_REFS_OUT/rendered-manifests"
pass "AFSCP workload mount secret refs accepted"

for mutation in \
  afscp_workload_mount_secret_refs_missing_name \
  afscp_workload_mount_secret_refs_path_escape \
  afscp_workload_mount_secret_refs_token_volume \
  afscp_workload_mount_secret_refs_reserved_name; do
  bad_archive="$TMP_DIR/$mutation.tgz"
  bad_manifest_sha="$(create_render_archive "$mutation" "$bad_archive" "$mutation")"
  bad_archive_sha="$(sha256_file "$bad_archive")"
  bad_contract="$TMP_DIR/release-contract.$mutation.json"
  bad_package="$TMP_DIR/deploy-template-package.$mutation.json"
  write_materials "$bad_manifest_sha" "$bad_archive_sha" "$bad_contract" "$bad_package"
  expect_fail_case "$mutation" \
    "$bad_contract" \
    "$bad_package" \
    "$bad_archive" \
    "$VALID_VALUES" \
    "$VALID_TRUTH"
done

FORBIDDEN_ROOT="$TMP_DIR/forbidden-product-source"
mkdir -p "$FORBIDDEN_ROOT"
FORBIDDEN_CONTRACT="$FORBIDDEN_ROOT/release-contract.json"
cp "$VALID_CONTRACT_MATERIAL" "$FORBIDDEN_CONTRACT"
expect_fail_case forbidden-source-root \
  "$FORBIDDEN_CONTRACT" \
  "$VALID_PACKAGE_MATERIAL" \
  "$VALID_ARCHIVE" \
  "$VALID_VALUES" \
  "$VALID_TRUTH" \
  "$TARGET_PROFILE" \
  "$FORBIDDEN_ROOT"

DEFAULT_SIBLING_AGENTSMITH="$ROOT_DIR/../agentsmith"
if [[ -d "$DEFAULT_SIBLING_AGENTSMITH" ]]; then
  DEFAULT_SIBLING_OUT="$TMP_DIR/out-default-sibling-agent-smith"
  DEFAULT_SIBLING_INPUT="$DEFAULT_SIBLING_AGENTSMITH/package.json"

  if run_render \
    "$DEFAULT_SIBLING_INPUT" \
    "$VALID_PACKAGE_MATERIAL" \
    "$VALID_ARCHIVE" \
    "$VALID_VALUES" \
    "$VALID_TRUTH" \
    "$DEFAULT_SIBLING_OUT" >"$TMP_DIR/default-sibling-agent-smith.out" 2>"$TMP_DIR/default-sibling-agent-smith.err"; then
    cat "$TMP_DIR/default-sibling-agent-smith.out" >&2
    cat "$TMP_DIR/default-sibling-agent-smith.err" >&2
    fail "expected default sibling AgentSmith source input to fail"
  fi

  if ! grep -q "forbidden product source tree" "$TMP_DIR/default-sibling-agent-smith.err"; then
    cat "$TMP_DIR/default-sibling-agent-smith.out" >&2
    cat "$TMP_DIR/default-sibling-agent-smith.err" >&2
    fail "expected default sibling AgentSmith source input to fail before reading it"
  fi

  pass "default sibling AgentSmith source input rejected"
fi

pass "render focused diagnostic tests completed"
