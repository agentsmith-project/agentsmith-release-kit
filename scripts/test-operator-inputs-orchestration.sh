#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
KIT_ONLINE_TARGET_PROFILE="existing_kubernetes/kit_installed/online"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIT_AIRGAP_PROFILE="existing_kubernetes/kit_installed/airgap"
ONLINE_TARGET_REGISTRY="registry.release.example/agentsmith"
AIRGAP_REGISTRY="registry.example.internal/releases"
mapfile -t RELEASE_IMAGE_IDS < <(
  "$NODE_BIN" --input-type=module - "$FIXTURE_CONTRACT" <<'NODE'
import fs from 'node:fs';

const [fixtureContract] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(fixtureContract, 'utf8'));
for (const item of contract.deploy_image_inventory) {
  console.log(item.id);
}
NODE
)

TMP_DIR="$(mktemp -d)"
SERVER_PID=""
trap 'if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP_DIR"' EXIT

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

install_parameters_digest() {
  local install_inputs="$1"
  local namespace="${2:-agentsmith}"

  "$NODE_BIN" --input-type=module - "$install_inputs" "$namespace" <<'NODE'
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

create_archive() {
  local label="$1"
  local archive="$2"
  local package_dir="$TMP_DIR/archive-$label"

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
  cat >"$package_dir/templates/workloads.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
  namespace: ${{ values.namespace }}
spec:
  replicas: ${{ values.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: agentsmith-web
      app.kubernetes.io/part: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: agentsmith-web
        app.kubernetes.io/part: web
    spec:
      initContainers:
        - name: schema
          image: ${{ images.agentsmith_app.image }}
      containers:
        - name: web
          image: ${{ images.agentsmith_app.image }}
YAML

  tar -czf "$archive" -C "$package_dir" manifest.json templates/workloads.yaml
  sha256_file "$package_dir/manifest.json"
}

write_materials() {
  local manifest_sha="$1"
  local archive_sha="$2"
  local contract_output="$3"
  local deploy_template_package_output="$4"
  local target_profiles_required="${5:-false}"

  "$NODE_BIN" --input-type=module - \
    "$FIXTURE_CONTRACT" \
    "$FIXTURE_DEPLOY_TEMPLATE_PACKAGE" \
    "$manifest_sha" \
    "$archive_sha" \
    "$contract_output" \
    "$deploy_template_package_output" \
    "$target_profiles_required" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  contractInput,
  packageInput,
  manifestSha,
  archiveSha,
  contractOutput,
  packageOutput,
  targetProfilesRequired
] = process.argv.slice(2);

const contract = JSON.parse(fs.readFileSync(contractInput, 'utf8'));
const deployTemplatePackage = JSON.parse(fs.readFileSync(packageInput, 'utf8'));

if (targetProfilesRequired === 'true') {
  for (const profile of contract.target_profiles) {
    profile.required = true;
  }
}

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

write_render_values() {
  local output="$1"

  cat >"$output" <<'JSON'
{
  "namespace": "agentsmith",
  "replicas": 2
}
JSON
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
      proof: `operator ${name} check 2026-05-23T12:00:00Z`
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
        proof: 'operator bucket check 2026-05-23T12:00:00Z'
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
        proof: 'operator oidc check 2026-05-23T12:00:00Z'
      }
    }
  }
};

fs.writeFileSync(output, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

write_prerequisites() {
  local output="$1"
  local profile="${2:-$TARGET_PROFILE}"

  "$NODE_BIN" --input-type=module - "$output" "$profile" <<'NODE'
import fs from 'node:fs';

const [output, profile] = process.argv.slice(2);

const prerequisites = {
  schema_version: 'agentsmith.target-prerequisites.truth/v1',
  target_profile: profile,
  namespace: 'agentsmith',
  rbac: {
    policy: 'pre_provisioned',
    proof: 'operator kubectl auth can-i apply deployments in namespace agentsmith 2026-05-23T12:00:00Z'
  },
  ingress: {
    host: 'agentsmith.release.example.com',
    tls_secret_ref: 'secretRef:release/agentsmith-ingress-tls'
  },
  registry: {
    auth: {
      mode: 'secret'
    },
    pull_secret_ref: 'secretRef:release/registry-pull'
  },
  storage: {
    storage_class: 'gp3',
    persistent_volume_policy: 'dynamic'
  },
  substrate_secret_refs: [
    'secretRef:release/postgresql-credential',
    'secretRef:release/postgresql-admin',
    'secretRef:release/postgresql-ca',
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

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

write_substrate_install_materials() {
  local package_dir="$1"
  local profile="${2:-$KIT_ONLINE_TARGET_PROFILE}"
  local postgresql_digest
  local mongodb_digest
  local redis_digest
  local object_storage_digest
  local oidc_digest

  postgresql_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_postgresql)"
  mongodb_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_mongodb)"
  redis_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_redis)"
  object_storage_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_object_storage)"
  oidc_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_oidc)"

  "$NODE_BIN" --input-type=module - \
    "$package_dir" \
    "$profile" \
    "$postgresql_digest" \
    "$mongodb_digest" \
    "$redis_digest" \
    "$object_storage_digest" \
    "$oidc_digest" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  packageDir,
  profile,
  postgresqlDigest,
  mongodbDigest,
  redisDigest,
  objectStorageDigest,
  oidcDigest
] = process.argv.slice(2);
const [targetCluster, substrateSource, distribution] = profile.split('/');
const digest = (char) => `sha256:${char.repeat(64)}`;
const image = (name, tag, digestValue) =>
  `ghcr.io/agentsmith-project/substrates/${name}:${tag}@${digestValue}`;
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
  const file = path.join(packageDir, relativePath);
  const bytes = Buffer.from(content);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return digestBuffer(bytes);
}

function writePackJson(relativePath, value) {
  return writePackText(relativePath, `${JSON.stringify(value, null, 2)}\n`);
}

function service(name, host, port) {
  return {
    host,
    port,
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

const substrateTruth = {
  schema_version: 'agentsmith.substrate-connection.truth/v1',
  redacted_fingerprint: `sha256:${'a'.repeat(64)}`,
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
      ...service('postgresql', 'postgresql.release.example.internal', 5432),
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
    mongodb: service('mongodb', 'mongodb.release.example.internal', 27017),
    redis: service('redis', 'redis.release.example.internal', 6379),
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

const payloadDigest = writePackJson('payload/install-substrates.json', {
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
const toolsDigest = writePackText(
  'tools/substrate-checks.txt',
  'postgresql tls\nmongodb tls\nredis ping\nobject-storage head-bucket\noidc discovery\n'
);

writeJson(path.join(packageDir, 'substrate-pack-manifest.json'), {
  schema_version: 'agentsmith.substrate-pack-manifest/v1',
  release_kit_version: '0.1.0',
  installed_by: 'agentsmith-release-kit',
  target_profile: profile,
  images: {
    postgresql: image('postgresql', '16.3', postgresqlDigest),
    mongodb: image('mongodb', '7.0', mongodbDigest),
    redis: image('redis', '7.2', redisDigest),
    object_storage: image('object-storage', '2026.05', objectStorageDigest),
    oidc: image('keycloak', '25.0', oidcDigest)
  },
  payload: {
    install_plan: {
      path: 'payload/install-substrates.json',
      sha256: payloadDigest
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
      sha256: toolsDigest
    }
  },
  checksums: {
    manifest: digest('8')
  }
});

writeJson(path.join(packageDir, 'substrate-install-inputs.json'), {
  schema_version: 'agentsmith.substrate-install-inputs/v1',
  target_profile: profile,
  installation_id: 'kit-install-10001',
  substrate_truth: substrateTruth,
  resources: [
    {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: {
        name: 'agentsmith-substrate-config',
        namespace: 'agentsmith',
        labels: ownerLabels,
        annotations: ownerAnnotations
      },
      data: {
        installation_id: 'kit-install-10001',
        profile
      }
    }
  ]
});
NODE
}

write_target_prerequisites_from_install_inputs() {
  local install_inputs="$1"
  local output="$2"
  local target_profile="$3"

  "$NODE_BIN" --input-type=module - "$install_inputs" "$output" "$target_profile" <<'NODE'
import fs from 'node:fs';

const [installInputsFile, output, targetProfile] = process.argv.slice(2);
const installInputs = JSON.parse(fs.readFileSync(installInputsFile, 'utf8'));
const refs = new Set();

function collectSecretRefs(value) {
  if (typeof value === 'string' && value.startsWith('secretRef:')) {
    refs.add(value);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach(collectSecretRefs);
    return;
  }
  if (value && typeof value === 'object') {
    Object.values(value).forEach(collectSecretRefs);
  }
}

collectSecretRefs(installInputs.substrate_truth);

const prerequisites = {
  schema_version: 'agentsmith.target-prerequisites.truth/v1',
  target_profile: targetProfile,
  namespace: 'agentsmith',
  rbac: {
    policy: 'namespace_admin'
  },
  ingress: {
    host: 'agentsmith.release.example.com',
    tls_secret_ref: 'secretRef:agentsmith/agentsmith-ingress-tls'
  },
  registry: {
    auth: {
      mode: 'none'
    }
  },
  storage: {
    storage_class: 'gp3',
    persistent_volume_policy: 'dynamic'
  },
  substrate_secret_refs: [...refs].sort()
};

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

write_materialized_airgap_source_fixture() {
  local source_dir="$1"
  local postgresql_digest
  local mongodb_digest
  local redis_digest
  local object_storage_digest
  local oidc_digest

  postgresql_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_postgresql)"
  mongodb_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_mongodb)"
  redis_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_redis)"
  object_storage_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_object_storage)"
  oidc_digest="$("$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" --print-target-digest --image-id substrate_oidc)"

  mkdir -p "$source_dir"
  cp -R "$ROOT_DIR/substrate-packs/minimal/payload" "$source_dir/payload"
  cp -R "$ROOT_DIR/substrate-packs/minimal/templates" "$source_dir/templates"
  cp -R "$ROOT_DIR/substrate-packs/minimal/tools" "$source_dir/tools"
  "$NODE_BIN" --input-type=module - \
    "$ROOT_DIR/substrate-packs/minimal/pack-source.json" \
    "$source_dir/pack-source.json" \
    "$postgresql_digest" \
    "$mongodb_digest" \
    "$redis_digest" \
    "$object_storage_digest" \
    "$oidc_digest" <<'NODE'
import fs from 'node:fs';

const [
  input,
  output,
  postgresqlDigest,
  mongodbDigest,
  redisDigest,
  objectStorageDigest,
  oidcDigest
] = process.argv.slice(2);
const source = JSON.parse(fs.readFileSync(input, 'utf8'));
const digestByImageKey = {
  postgresql: postgresqlDigest,
  mongodb: mongodbDigest,
  redis: redisDigest,
  object_storage: objectStorageDigest,
  oidc: oidcDigest
};

for (const [key, digest] of Object.entries(digestByImageKey)) {
  source.images[key].source_ref = source.images[key].source_ref.replace(
    /@sha256:[0-9a-f]{64}$/,
    `@${digest}`
  );
}

fs.writeFileSync(output, `${JSON.stringify(source, null, 2)}\n`);
NODE
}

materialize_airgap_substrate_install_materials() {
  local output_dir="$1"
  local source_dir="$2"

  write_materialized_airgap_source_fixture "$source_dir"
  "$NODE_BIN" "$ROOT_DIR/scripts/materialize-substrate-pack.mjs" \
    --deployment-path airgap/install_substrates \
    --source-dir "$source_dir" \
    --target-registry "$AIRGAP_REGISTRY" \
    --output-dir "$output_dir" \
    --namespace agentsmith \
    --installation-id kit-install-minimal-airgap-1001 \
    --storage-class gp3 \
    --declared-at 2026-06-10T12:00:00.000Z >/dev/null
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
  if [[ "$arg" == "version" || "$arg" == "apply" || "$arg" == "rollout" || "$arg" == "get" ]]; then
    command_name="$arg"
    break
  fi
done

if [[ "$command_name" == "version" ]]; then
  printf '%s\\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
  exit 0
fi

if [[ "$command_name" == "apply" ]]; then
  if [[ "$*" == *".substrate-install-resources."* ]]; then
    printf '%s\\n' "configmap/agentsmith-substrate-config"
    exit 0
  fi
  printf '%s\\n' "deployment.apps/agentsmith-web"
  exit 0
fi

if [[ "$command_name" == "rollout" ]]; then
  printf '%s\\n' "deployment.apps/agentsmith-web rolled out"
  exit 0
fi

if [[ "$command_name" == "get" ]]; then
  get_target=""
  get_name=""
  get_namespace=""
  output_format=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "get" ]]; then
      get_target="$arg"
    fi
    if [[ "$get_target" == "secret" && "$previous" == "secret" && -z "$get_name" ]]; then
      get_name="$arg"
    fi
    if [[ "$previous" == "--namespace" ]]; then
      get_namespace="$arg"
    fi
    if [[ "$previous" == "-o" || "$previous" == "--output" ]]; then
      output_format="$arg"
    fi
    case "$arg" in
      --namespace=*)
        get_namespace="\${arg#--namespace=}"
        ;;
      --output=*)
        output_format="\${arg#--output=}"
        ;;
    esac
    previous="$arg"
  done
  if [[ "$get_target" == secret/* ]]; then
    get_name="\${get_target#secret/}"
    get_target="secret"
  fi

  if [[ "$get_target" == "secret" ]]; then
    if [[ -z "$get_name" || -z "$get_namespace" || "$output_format" != "json" ]]; then
      echo "unexpected fake kubectl get secret args: $*" >&2
      exit 2
    fi
    node --input-type=module - "$get_namespace" "$get_name" <<'SECRET_NODE'
const [namespace, name] = process.argv.slice(2);
const value = 'dg==';
const dataByName = new Map([
  ['postgresql-credential', { username: value, password: value }],
  ['postgresql-app', { username: value, password: value }],
  ['postgresql-admin', { username: value, password: value }],
  ['mongodb-credential', { username: value, password: value }],
  ['mongodb-app', { username: value, password: value }],
  ['redis-credential', { password: value }],
  ['redis-app', { password: value }],
  ['object-storage-credential', { access_key: value, secret_key: value }],
  ['object-storage-app', { access_key: value, secret_key: value }],
  ['oidc-admin', { username: value, password: value }],
  ['oidc-client', { client_secret: value }]
]);
const data = dataByName.get(name);
if (!data) {
  process.stderr.write('unexpected fake kubectl secret name: ' + name + '\\n');
  process.exit(2);
}
const emptyKey = process.env.FAKE_KUBECTL_EMPTY_SECRET_KEY || '';
for (const key of Object.keys(data)) {
  if (emptyKey === namespace + '/' + name + '/' + key || emptyKey === name + '/' + key) {
    data[key] = '';
  }
}
process.stdout.write(JSON.stringify({ data }) + '\\n');
SECRET_NODE
    exit 0
  fi

  if [[ "$get_target" == "Deployment/agentsmith-web" ]]; then
    cat <<'JSON'
{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"agentsmith-web","app.kubernetes.io/part":"web"}}}}
JSON
    exit 0
  fi

  if [[ "$get_target" == "configmaps" || "$get_target" == "configmap" ]]; then
    echo "Error from server (NotFound): resource not found" >&2
    exit 1
  fi

  if [[ "$get_target" == "pods" ]]; then
    live_image="\${FAKE_KUBECTL_LIVE_IMAGE:-ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111}"
    live_image_id="\${FAKE_KUBECTL_LIVE_IMAGE_ID:-docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111}"
    cat <<JSON
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"$live_image","imageID":"$live_image_id"}],"containerStatuses":[{"name":"web","image":"$live_image","imageID":"$live_image_id"}]}}]}
JSON
    exit 0
  fi
fi

echo "unexpected fake kubectl args: $*" >&2
exit 2
`
);
fs.chmodSync(fakeKubectl, 0o755);
NODE
}

write_fake_registry_probe() {
  local fake_probe="$1"

  "$NODE_BIN" --input-type=module - "$fake_probe" <<'NODE'
import fs from 'node:fs';

const [fakeProbe] = process.argv.slice(2);
fs.writeFileSync(
  fakeProbe,
  `#!/usr/bin/env bash
set -euo pipefail
target_digest="\${2:?target digest required}"
printf '%s\\n' "$target_digest"
`
);
fs.chmodSync(fakeProbe, 0o755);
NODE
}

write_fake_routability_probe() {
  local fake_probe="$1"

  "$NODE_BIN" --input-type=module - "$fake_probe" <<'NODE'
import fs from 'node:fs';

const [fakeProbe] = process.argv.slice(2);
fs.writeFileSync(
  fakeProbe,
  `#!/usr/bin/env bash
set -euo pipefail
expected=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --expected-fingerprint)
      expected="\${2:?expected fingerprint required}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$expected" ]] || exit 24
printf '%s\\n' "$expected"
`
);
fs.chmodSync(fakeProbe, 0o755);
NODE
}

start_server() {
  local ready_file="$TMP_DIR/server-ready"
  local log_file="$TMP_DIR/server-hits.log"
  local stdout_file="$TMP_DIR/server.out"
  local stderr_file="$TMP_DIR/server.err"

  "$NODE_BIN" --input-type=module - "$ready_file" "$log_file" >"$stdout_file" 2>"$stderr_file" <<'NODE' &
import fs from 'node:fs';
import http from 'node:http';

const [readyFile, logFile] = process.argv.slice(2);

const server = http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || '127.0.0.1'}`);
  fs.appendFileSync(logFile, `${request.method} ${url.pathname}\n`);
  response.statusCode = url.pathname === '/ok' ? 200 : 404;
  response.end(url.pathname === '/ok' ? 'route ok' : 'not found');
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(readyFile, String(server.address().port));
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
NODE
  SERVER_PID=$!

  for _ in {1..50}; do
    if [[ -s "$ready_file" ]]; then
      SERVER_PORT="$(<"$ready_file")"
      return
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$stdout_file" >&2 || true
      cat "$stderr_file" >&2 || true
      fail "operator-inputs orchestration smoke server exited before ready"
    fi
    sleep 0.1
  done

  cat "$stdout_file" >&2 || true
  cat "$stderr_file" >&2 || true
  fail "operator-inputs orchestration smoke server did not become ready"
}

write_online_operator_inputs() {
  local package_dir="$1"
  local mode="$2"
  local smoke_path="${3:-/ok}"
  local smoke_url="http://127.0.0.1:$SERVER_PORT$smoke_path"

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" "$mode" "$smoke_url" <<'NODE'
import fs from 'node:fs';

const [output, mode, smokeUrl] = process.argv.slice(2);
const manifest = {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: 'online/use_existing',
  release_contract: 'release-contract.json',
  deploy_template_package: 'deploy-template-package.json',
  deploy_template_archive: 'deploy-template-package.tgz',
  render_values: 'render-values.json',
  substrate_truth: 'substrate-truth.json',
  target_prerequisites: 'target-prerequisites.json',
  namespace: 'agentsmith',
  mode,
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context'
};

if (mode === 'apply') {
  Object.assign(manifest, {
    deploy_confirmation: {
      confirmed: true,
      operator_run_id: 'operator-inputs-online-apply-1001'
    },
    smoke_url: smokeUrl,
    expected_status: 200,
    timeout: '60s',
    timeout_ms: 5000,
    allow_http: true,
    allow_localhost: true
  });
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

write_online_install_operator_inputs() {
  local package_dir="$1"
  local mode="$2"
  local install_parameters_sha256="$3"
  local smoke_path="${4:-/ok}"
  local smoke_url="http://127.0.0.1:$SERVER_PORT$smoke_path"

  "$NODE_BIN" --input-type=module - \
    "$package_dir/operator-inputs.json" \
    "$mode" \
    "$smoke_url" \
    "$install_parameters_sha256" <<'NODE'
import fs from 'node:fs';

const [output, mode, smokeUrl, installParametersSha256] = process.argv.slice(2);
const manifest = {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: 'online/install_substrates',
  release_contract: 'release-contract.json',
  deploy_template_package: 'deploy-template-package.json',
  deploy_template_archive: 'deploy-template-package.tgz',
  render_values: 'render-values.json',
  target_prerequisites: 'target-prerequisites.json',
  substrate_pack_manifest: 'substrate-pack-manifest.json',
  substrate_install_inputs: 'substrate-install-inputs.json',
  namespace: 'agentsmith',
  mode,
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context',
  routability_probe: 'tools/routability-probe',
  install_confirmation: {
    confirmed: true,
    confirm_current_install_parameters: true,
    operator_run_id: 'operator-inputs-install-1001'
  }
};

if (installParametersSha256) {
  manifest.install_confirmation.install_parameters_sha256 = installParametersSha256;
}

if (mode === 'apply') {
  Object.assign(manifest, {
    deploy_confirmation: {
      confirmed: true,
      operator_run_id: 'operator-inputs-online-install-apply-1001'
    },
    smoke_url: smokeUrl,
    expected_status: 200,
    timeout: '60s',
    timeout_ms: 5000,
    allow_http: true,
    allow_localhost: true
  });
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

prepare_online_package() {
  local package_dir="$1"
  local mode="$2"
  local smoke_path="${3:-/ok}"

  mkdir -p "$package_dir/tools"
  local archive="$package_dir/deploy-template-package.tgz"
  local manifest_sha
  manifest_sha="$(create_archive "$(basename "$package_dir")" "$archive")"
  local archive_sha
  archive_sha="$(sha256_file "$archive")"
  write_materials "$manifest_sha" "$archive_sha" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json"
  write_render_values "$package_dir/render-values.json"
  write_truth "$package_dir/substrate-truth.json" "$TARGET_PROFILE"
  write_prerequisites "$package_dir/target-prerequisites.json" "$TARGET_PROFILE"
  write_fake_kubectl "$package_dir/tools/kubectl"
  write_fake_registry_probe "$package_dir/tools/registry-probe"
  write_online_operator_inputs "$package_dir" "$mode" "$smoke_path"
}

prepare_online_install_package() {
  local package_dir="$1"
  local mode="$2"
  local smoke_path="${3:-/ok}"
  local install_digest_mode="${4:-valid}"

  mkdir -p "$package_dir/tools"
  local archive="$package_dir/deploy-template-package.tgz"
  local manifest_sha
  manifest_sha="$(create_archive "$(basename "$package_dir")" "$archive")"
  local archive_sha
  archive_sha="$(sha256_file "$archive")"
  write_materials "$manifest_sha" "$archive_sha" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json"
  write_render_values "$package_dir/render-values.json"
  write_truth "$package_dir/substrate-truth.json" "$KIT_ONLINE_TARGET_PROFILE"
  write_prerequisites "$package_dir/target-prerequisites.json" "$KIT_ONLINE_TARGET_PROFILE"
  write_substrate_install_materials "$package_dir" "$KIT_ONLINE_TARGET_PROFILE"
  write_fake_kubectl "$package_dir/tools/kubectl"
  write_fake_registry_probe "$package_dir/tools/registry-probe"
  write_fake_routability_probe "$package_dir/tools/routability-probe"

  local install_parameters_sha256=""
  if [[ "$install_digest_mode" == "valid" ]]; then
    install_parameters_sha256=""
  else
    install_parameters_sha256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fi
  write_online_install_operator_inputs "$package_dir" "$mode" "$install_parameters_sha256" "$smoke_path"
}

create_airgap_payloads() {
  local package_dir="$1"
  local payload_dir="$package_dir/payload"

  mkdir -p "$payload_dir"
  cat >"$payload_dir/runbook.md" <<'EOF_RUNBOOK'
# AgentSmith airgap runbook

Use the approved operator-held substrate and registry records.
EOF_RUNBOOK
  cat >"$payload_dir/install.sh" <<'EOF_SCRIPT'
#!/usr/bin/env sh
set -eu
printf '%s\n' "operator-reviewed local install placeholder"
EOF_SCRIPT
  chmod +x "$payload_dir/install.sh"
  cat >"$payload_dir/profile-values.schema.json" <<'JSON'
{
  "type": "object",
  "additionalProperties": false
}
JSON
  printf '%s\n' 'namespace: agentsmith' >"$payload_dir/profile-values.example.yaml"
}

create_airgap_image_archives() {
  local package_dir="$1"
  local contract="$2"
  local image_dir="$package_dir/image-archives"

  retarget_release_contract_to_oci_fixture_digests "$contract"
  mkdir -p "$image_dir"
  "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
    --from-contract "$contract" \
    --output-dir "$image_dir"
}

retarget_release_contract_to_oci_fixture_digests() {
  local contract="$1"

  "$NODE_BIN" --input-type=module - "$contract" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [contractPath] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractPath, 'utf8'));

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

function digest(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function fixtureManifestDigest(imageId) {
  const layerContent = Buffer.from(`fixture layer for ${imageId}\n`);
  const layerDigest = digest(layerContent);
  const config = {
    architecture: 'amd64',
    os: 'linux',
    rootfs: {
      type: 'layers',
      diff_ids: [layerDigest]
    },
    config: {
      Labels: {
        'io.agentsmith.fixture.image_id': imageId
      }
    }
  };
  const configBuffer = Buffer.from(`${JSON.stringify(config)}\n`);
  const configDigest = digest(configBuffer);
  const manifest = {
    schemaVersion: 2,
    mediaType: 'application/vnd.oci.image.manifest.v1+json',
    config: {
      mediaType: 'application/vnd.oci.image.config.v1+json',
      digest: configDigest,
      size: configBuffer.length
    },
    layers: [
      {
        mediaType: 'application/vnd.oci.image.layer.v1.tar',
        digest: layerDigest,
        size: layerContent.length
      }
    ]
  };
  return digest(Buffer.from(`${JSON.stringify(manifest)}\n`));
}

function replaceImageDigest(image, nextDigest) {
  if (!/@sha256:[0-9a-f]{64}$/.test(image)) {
    throw new Error(`image must be digest-pinned: ${image}`);
  }
  return image.replace(/@sha256:[0-9a-f]{64}$/, `@${nextDigest}`);
}

function retargetImageItem(item, nextDigest) {
  item.digest = nextDigest;
  item.image = replaceImageDigest(item.image, nextDigest);
  if (item.source_provenance?.artifact_sha256) {
    item.source_provenance.artifact_sha256 = nextDigest;
  }
}

function subjectDigest(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return digest(JSON.stringify(stableJson(subject)));
}

function artifactProjectionDigest(value) {
  const { artifact_sha256: _artifactSha256, ...artifactProvenance } = value.artifact_provenance;
  const projection = { ...value, artifact_provenance: artifactProvenance };
  return digest(JSON.stringify(stableJson(projection)));
}

const digestByInventoryId = new Map();
for (const item of contract.deploy_image_inventory || []) {
  const nextDigest = fixtureManifestDigest(item.id);
  digestByInventoryId.set(item.id, nextDigest);
  retargetImageItem(item, nextDigest);
}

for (const sourceName of [
  'product_images',
  'adopted_provider_images',
  'release_kit_prerequisite_images'
]) {
  for (const item of contract[sourceName] || []) {
    const inventoryItem = (contract.deploy_image_inventory || []).find(
      (candidate) => candidate.source === sourceName && candidate.id === item.id
    );
    const nextDigest = digestByInventoryId.get(inventoryItem?.id || item.id);
    if (!nextDigest) {
      throw new Error(`missing fixture manifest digest for ${sourceName}.${item.id}`);
    }
    retargetImageItem(item, nextDigest);
  }
}

if (contract.managed_runner_image) {
  const nextDigest = digestByInventoryId.get('managed_runner');
  if (!nextDigest) {
    throw new Error('missing fixture manifest digest for managed_runner');
  }
  retargetImageItem(contract.managed_runner_image, nextDigest);
}

contract.artifact_provenance.subject_sha256 = subjectDigest(contract);
contract.artifact_provenance.artifact_sha256 = artifactProjectionDigest(contract);

fs.writeFileSync(contractPath, `${JSON.stringify(contract, null, 2)}\n`);
NODE
}

write_airgap_operator_prerequisites() {
  local package_dir="$1"
  local output="$2"
  local tool_file="$package_dir/payload/kubectl-local"

  printf '%s\n' 'bundled kubectl placeholder' >"$tool_file"
  "$NODE_BIN" --input-type=module - "$output" "$tool_file" <<'NODE'
import fs from 'node:fs';

const [output, toolFile] = process.argv.slice(2);
const prerequisites = {
  substrate_connection_truth_ref: 'operator held substrate truth record AS-123',
  target_registry_proof_ref: 'operator held target registry proof AS-123',
  tools: [
    {
      name: 'kubectl',
      version: '1.30.0',
      source: 'bundled',
      path: toolFile
    },
    {
      name: 'skopeo',
      version: '1.16.0',
      source: 'operator_prerequisite',
      location: 'operator workstation inventory skopeo',
      proof: 'signed operator prerequisite proof skopeo'
    }
  ]
};

fs.writeFileSync(output, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

run_airgap_bundle_create() {
  local package_dir="$1"
  local release_contract="$2"
  local deploy_template_package="$3"
  local archive="$4"
  local bundle_root="$5"
  local output_dir="$6"
  local target_profile="${7:-$AIRGAP_PROFILE}"
  local substrate_pack_manifest="${8:-}"
  local substrate_install_inputs="${9:-}"
  local payload_dir="$package_dir/payload"
  local image_archive_args=()
  local substrate_pack_args=()

  for id in "${RELEASE_IMAGE_IDS[@]}"; do
    image_archive_args+=(--image-archive "$id=$package_dir/image-archives/$id.oci-layout.tar")
  done
  if [[ -n "$substrate_pack_manifest" ]]; then
    substrate_pack_args+=(--substrate-pack-manifest "$substrate_pack_manifest")
    while IFS='=' read -r id digest; do
      "$NODE_BIN" "$ROOT_DIR/scripts/lib/test-oci-layout-fixture.mjs" \
        --archive "$package_dir/image-archives/$id.oci-layout.tar" \
        --image-id "$id" \
        --target-digest "$digest" >/dev/null
      image_archive_args+=(--image-archive "$id=$package_dir/image-archives/$id.oci-layout.tar")
    done < <("$NODE_BIN" --input-type=module - "$substrate_pack_manifest" <<'NODE'
import fs from 'node:fs';

const [substratePackManifest] = process.argv.slice(2);
const pack = JSON.parse(fs.readFileSync(substratePackManifest, 'utf8'));
for (const key of Object.keys(pack.images).sort()) {
  const image = pack.images[key];
  console.log(`substrate_${key}=${image.slice(image.lastIndexOf('@') + 1)}`);
}
NODE
)
  fi
  if [[ -n "$substrate_install_inputs" ]]; then
    substrate_pack_args+=(--substrate-install-inputs "$substrate_install_inputs")
  fi

  bash "$ROOT_DIR/scripts/verify-release.sh" --bundle-create \
    --release-contract "$release_contract" \
    --deploy-template-package "$deploy_template_package" \
    --archive "$archive" \
    --target-profile "$target_profile" \
    --target-registry "$AIRGAP_REGISTRY" \
    --bundle-root "$bundle_root" \
    --output-dir "$output_dir" \
    "${image_archive_args[@]}" \
    "${substrate_pack_args[@]}" \
    --runbook "$payload_dir/runbook.md" \
    --script "$payload_dir/install.sh" \
    --profile-values-schema "$payload_dir/profile-values.schema.json" \
    --profile-values-example "$payload_dir/profile-values.example.yaml" \
    --operator-prerequisites "$package_dir/operator-prerequisites.json"

  if [[ -n "$substrate_pack_manifest" ]]; then
    assert_bundled_substrate_pack_materials "$bundle_root"
  fi
}

assert_bundled_substrate_pack_materials() {
  local bundle_root="$1"

  "$NODE_BIN" --input-type=module - "$bundle_root" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [bundleRoot] = process.argv.slice(2);
const componentsRoot = path.join(bundleRoot, 'components');
const manifestPath = path.join(componentsRoot, 'substrate-pack-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const materialPaths = new Set();

function collectMaterialPaths(value, key = '') {
  if (typeof value === 'string') {
    if (key !== 'sha256' && !value.startsWith('sha256:')) {
      materialPaths.add(value);
    }
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  if (typeof value.path === 'string') {
    materialPaths.add(value.path);
  }
  for (const [nestedKey, nested] of Object.entries(value)) {
    if (nestedKey !== 'path' && nestedKey !== 'sha256') {
      collectMaterialPaths(nested, nestedKey);
    }
  }
}

collectMaterialPaths(manifest.payload);
collectMaterialPaths(manifest.templates);
collectMaterialPaths(manifest.tools);
collectMaterialPaths(manifest.checksums);

for (const material of [...materialPaths].sort()) {
  if (!fs.existsSync(path.join(componentsRoot, material))) {
    throw new Error(`bundle-create did not copy substrate pack material: ${material}`);
  }
}
NODE
  [[ ! -e "$bundle_root/components/tools/kubectl" ]] ||
    fail "bundle-create must not copy operator tools as substrate pack material"
}

write_bundle_operator_inputs() {
  local bundle_root="$1"
  local target_profile="${2:-$AIRGAP_PROFILE}"

  mkdir -p "$bundle_root/operator-inputs"
  write_render_values "$bundle_root/operator-inputs/render-values.json"
  write_truth "$bundle_root/operator-inputs/substrate-truth.json" "$target_profile"
  write_prerequisites "$bundle_root/operator-inputs/target-prerequisites.json" "$target_profile"
}

target_image_for_id() {
  local image_map="$1"
  local image_id="$2"

  "$NODE_BIN" --input-type=module - "$image_map" "$image_id" <<'NODE'
import fs from 'node:fs';

const [imageMapInput, imageId] = process.argv.slice(2);
const imageMap = JSON.parse(fs.readFileSync(imageMapInput, 'utf8'));
const mapping = imageMap.mappings.find((item) => item.id === imageId);
if (!mapping) {
  throw new Error(`missing image-map mapping: ${imageId}`);
}
console.log(mapping.target_image);
NODE
}

online_target_registry_app_image() {
  printf '%s\n' "$ONLINE_TARGET_REGISTRY/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"
}

write_fake_airgap_archive_probe() {
  local fake_probe="$1"

  cat >"$fake_probe" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const TAR_BLOCK_SIZE = 512;
const archivePath = process.argv[2] || process.env.AGENTSMITH_IMAGE_ARCHIVE_PATH;
if (!archivePath) {
  process.exit(2);
}

function readTarString(block, start, length) {
  const slice = block.subarray(start, start + length);
  const end = slice.indexOf(0);
  return slice.subarray(0, end === -1 ? slice.length : end).toString('utf8').trim();
}

function parseTarOctal(block, start, length) {
  const raw = readTarString(block, start, length).trim();
  return raw === '' ? 0 : Number.parseInt(raw, 8);
}

function readTarFile(buffer, wantedPath) {
  for (let offset = 0; offset + TAR_BLOCK_SIZE <= buffer.length; ) {
    const block = buffer.subarray(offset, offset + TAR_BLOCK_SIZE);
    if (block.every((byte) => byte === 0)) {
      break;
    }
    const name = readTarString(block, 0, 100);
    const prefix = readTarString(block, 345, 155);
    const entryPath = prefix ? `${prefix}/${name}` : name;
    const size = parseTarOctal(block, 124, 12);
    const contentStart = offset + TAR_BLOCK_SIZE;
    const contentEnd = contentStart + size;
    if (entryPath === wantedPath) {
      return buffer.subarray(contentStart, contentEnd);
    }
    offset = contentStart + Math.ceil(size / TAR_BLOCK_SIZE) * TAR_BLOCK_SIZE;
  }
  return undefined;
}

const body = fs.readFileSync(archivePath);
const indexContent = readTarFile(body, 'index.json');
if (!indexContent) {
  process.exit(3);
}
const index = JSON.parse(indexContent.toString('utf8'));
if (!Array.isArray(index.manifests) || index.manifests.length !== 1) {
  process.exit(4);
}
const digest = index.manifests[0]?.digest;
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) {
  process.exit(5);
}
console.log(digest);
NODE
  chmod +x "$fake_probe"
}

write_fake_airgap_image_loader() {
  local fake_loader="$1"

  cat >"$fake_loader" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';

const [archivePath, targetImage, targetDigest] = process.argv.slice(2);
if (!archivePath || !targetImage || !targetDigest) {
  process.exit(2);
}
const body = fs.readFileSync(archivePath, 'utf8');
const matches = [
  ...body.matchAll(/"io\.agentsmith\.fixture\.target_digest"\s*:\s*"(sha256:[0-9a-f]{64})"/g)
];
if (matches.length !== 1 || matches[0][1] !== targetDigest) {
  process.exit(3);
}
if (!targetImage.endsWith(`@${targetDigest}`)) {
  process.exit(4);
}
if (process.env.AGENTSMITH_LOAD_LOG) {
  fs.appendFileSync(process.env.AGENTSMITH_LOAD_LOG, `${targetDigest}\n`);
}
console.log(targetDigest);
NODE
  chmod +x "$fake_loader"
}

write_fake_airgap_kubectl() {
  local fake_kubectl="$1"

  cat >"$fake_kubectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_KUBECTL_LOG:?}"
printf '%s\n' "$*" >> "$FAKE_KUBECTL_LOG"

command_name=""
for arg in "$@"; do
  if [[ "$arg" == "version" || "$arg" == "apply" || "$arg" == "rollout" || "$arg" == "get" ]]; then
    command_name="$arg"
    break
  fi
done

case "$command_name" in
  version)
    printf '%s\n' '{"clientVersion":{"gitVersion":"v1.30.0","major":"1","minor":"30","platform":"linux/amd64"},"serverVersion":{"gitVersion":"v1.30.1","major":"1","minor":"30","platform":"linux/amd64"}}'
    ;;
  apply)
    if [[ "$*" == *".substrate-install-resources."* ]]; then
      resource_file=""
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "-f" ]]; then
          resource_file="$arg"
        fi
        previous="$arg"
      done
      node --input-type=module - "$resource_file" <<'APPLY_NODE'
import fs from 'node:fs';

const [resourceFile] = process.argv.slice(2);
const resourceNames = new Map([
  ['v1|ConfigMap', 'configmap'],
  ['v1|Service', 'service'],
  ['v1|PersistentVolumeClaim', 'persistentvolumeclaim'],
  ['networking.k8s.io/v1|NetworkPolicy', 'networkpolicy.networking.k8s.io'],
  ['apps/v1|Deployment', 'deployment.apps'],
  ['apps/v1|StatefulSet', 'statefulset.apps']
]);
const list = JSON.parse(fs.readFileSync(resourceFile, 'utf8'));
const refs = list.items.map((item) => {
  const resource = resourceNames.get(`${item.apiVersion}|${item.kind}`);
  if (!resource) {
    throw new Error(`unexpected substrate install resource ${item.apiVersion}/${item.kind}`);
  }
  return `${resource}/${item.metadata.name}`;
});
process.stdout.write(`${refs.join('\n')}\n`);
APPLY_NODE
      exit 0
    fi
    printf '%s\n' "deployment.apps/agentsmith-web"
    ;;
  rollout)
    printf '%s\n' "deployment.apps/agentsmith-web rolled out"
    ;;
  get)
    get_target=""
    get_name=""
    get_namespace=""
    output_format=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == "get" ]]; then
        get_target="$arg"
      fi
      if [[ "$get_target" == "secret" && "$previous" == "secret" && -z "$get_name" ]]; then
        get_name="$arg"
      fi
      if [[ "$previous" == "--namespace" ]]; then
        get_namespace="$arg"
      fi
      if [[ "$previous" == "-o" || "$previous" == "--output" ]]; then
        output_format="$arg"
      fi
      case "$arg" in
        --namespace=*)
          get_namespace="${arg#--namespace=}"
          ;;
        --output=*)
          output_format="${arg#--output=}"
          ;;
      esac
      previous="$arg"
    done
    if [[ "$get_target" == secret/* ]]; then
      get_name="${get_target#secret/}"
      get_target="secret"
    fi

    if [[ "$get_target" == "secret" ]]; then
      if [[ -z "$get_name" || -z "$get_namespace" || "$output_format" != "json" ]]; then
        echo "unexpected fake kubectl get secret args: $*" >&2
        exit 2
      fi
      node --input-type=module - "$get_namespace" "$get_name" <<'SECRET_NODE'
const [namespace, name] = process.argv.slice(2);
const value = 'dg==';
const dataByName = new Map([
  ['postgresql-credential', { username: value, password: value }],
  ['postgresql-app', { username: value, password: value }],
  ['postgresql-admin', { username: value, password: value }],
  ['mongodb-credential', { username: value, password: value }],
  ['mongodb-app', { username: value, password: value }],
  ['redis-credential', { password: value }],
  ['redis-app', { password: value }],
  ['object-storage-credential', { access_key: value, secret_key: value }],
  ['object-storage-app', { access_key: value, secret_key: value }],
  ['oidc-admin', { username: value, password: value }],
  ['oidc-client', { client_secret: value }]
]);
const data = dataByName.get(name);
if (!data) {
  process.stderr.write('unexpected fake kubectl secret name: ' + name + '\n');
  process.exit(2);
}
const emptyKey = process.env.FAKE_KUBECTL_EMPTY_SECRET_KEY || '';
for (const key of Object.keys(data)) {
  if (emptyKey === namespace + '/' + name + '/' + key || emptyKey === name + '/' + key) {
    data[key] = '';
  }
}
process.stdout.write(JSON.stringify({ data }) + '\n');
SECRET_NODE
      exit 0
    fi

    if [[ "$get_target" == "Deployment/agentsmith-web" ]]; then
      cat <<'JSON'
{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/part":"web","app.kubernetes.io/name":"agentsmith-web"}}}}
JSON
      exit 0
    fi

    if [[ "$get_target" == "configmaps" || "$get_target" == "configmap" ]]; then
      echo "Error from server (NotFound): resource not found" >&2
      exit 1
    fi

    case "$get_target" in
      configmaps/*|configmap/*|services|services/*|service|service/*|persistentvolumeclaims|persistentvolumeclaims/*|persistentvolumeclaim|persistentvolumeclaim/*|statefulsets.apps|statefulsets.apps/*|statefulset.apps|statefulset.apps/*|deployments.apps|deployments.apps/*|deployment.apps|deployment.apps/*|networkpolicies.networking.k8s.io|networkpolicies.networking.k8s.io/*|networkpolicy.networking.k8s.io|networkpolicy.networking.k8s.io/*)
        echo "Error from server (NotFound): resource not found" >&2
        exit 1
        ;;
    esac

    if [[ "$get_target" == "pods" ]]; then
      : "${FAKE_KUBECTL_TARGET_IMAGE:?}"
      cat <<JSON
{"items":[{"metadata":{"name":"agentsmith-web-abc"},"status":{"initContainerStatuses":[{"name":"schema","image":"$FAKE_KUBECTL_TARGET_IMAGE","imageID":"docker-pullable://$FAKE_KUBECTL_TARGET_IMAGE"}],"containerStatuses":[{"name":"web","image":"$FAKE_KUBECTL_TARGET_IMAGE","imageID":"docker-pullable://$FAKE_KUBECTL_TARGET_IMAGE"}]}}]}
JSON
      exit 0
    fi

    echo "unexpected fake kubectl get target: $get_target" >&2
    exit 2
    ;;
  *)
    echo "unexpected fake kubectl args: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fake_kubectl"
}

write_airgap_operator_inputs() {
  local package_dir="$1"
  local mode="$2"
  local smoke_path="${3:-/ok}"
  local smoke_url="http://127.0.0.1:$SERVER_PORT$smoke_path"

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" "$mode" "$smoke_url" <<'NODE'
import fs from 'node:fs';

const [output, mode, smokeUrl] = process.argv.slice(2);
const manifest = {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: 'airgap/use_existing',
  release_contract: 'bundle/components/release-contract.json',
  deploy_template_package: 'bundle/components/deploy-template-package.json',
  deploy_template_archive: 'bundle/components/agentsmith-deploy-template-package.tgz',
  render_values: 'bundle/operator-inputs/render-values.json',
  substrate_truth: 'bundle/operator-inputs/substrate-truth.json',
  target_prerequisites: 'bundle/operator-inputs/target-prerequisites.json',
  airgap_bundle: 'bundle',
  airgap_bundle_manifest: 'bundle/airgap-bundle-manifest.json',
  namespace: 'agentsmith',
  mode,
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context'
};

if (mode === 'apply') {
  Object.assign(manifest, {
    archive_probe: 'tools/archive-probe',
    image_loader: 'tools/image-loader',
    deploy_confirmation: {
      confirmed: true,
      operator_run_id: 'operator-inputs-airgap-apply-1001'
    },
    smoke_url: smokeUrl,
    expected_status: 200,
    timeout: '60s',
    timeout_ms: 5000,
    allow_http: true,
    allow_localhost: true
  });
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

write_airgap_install_operator_inputs() {
  local package_dir="$1"
  local mode="$2"
  local install_parameters_sha256="$3"
  local smoke_path="${4:-/ok}"
  local smoke_url="http://127.0.0.1:$SERVER_PORT$smoke_path"

  "$NODE_BIN" --input-type=module - \
    "$package_dir/operator-inputs.json" \
    "$mode" \
    "$smoke_url" \
    "$install_parameters_sha256" <<'NODE'
import fs from 'node:fs';

const [output, mode, smokeUrl, installParametersSha256] = process.argv.slice(2);
const manifest = {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: 'airgap/install_substrates',
  release_contract: 'bundle/components/release-contract.json',
  deploy_template_package: 'bundle/components/deploy-template-package.json',
  deploy_template_archive: 'bundle/components/agentsmith-deploy-template-package.tgz',
  render_values: 'bundle/operator-inputs/render-values.json',
  target_prerequisites: 'bundle/operator-inputs/target-prerequisites.json',
  substrate_pack_manifest: 'bundle/components/substrate-pack-manifest.json',
  substrate_install_inputs: 'bundle/components/substrate-install-inputs.json',
  airgap_bundle: 'bundle',
  airgap_bundle_manifest: 'bundle/airgap-bundle-manifest.json',
  namespace: 'agentsmith',
  mode,
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context',
  install_confirmation: {
    confirmed: true,
    confirm_current_install_parameters: true,
    operator_run_id: 'operator-inputs-install-1001'
  }
};

if (installParametersSha256) {
  manifest.install_confirmation.install_parameters_sha256 = installParametersSha256;
}

if (mode === 'apply') {
  Object.assign(manifest, {
    archive_probe: 'tools/archive-probe',
    image_loader: 'tools/image-loader',
    deploy_confirmation: {
      confirmed: true,
      operator_run_id: 'operator-inputs-airgap-install-apply-1001'
    },
    smoke_url: smokeUrl,
    expected_status: 200,
    timeout: '60s',
    timeout_ms: 5000,
    allow_http: true,
    allow_localhost: true
  });
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

prepare_airgap_package() {
  local package_dir="$1"
  local mode="$2"
  local smoke_path="${3:-/ok}"

  mkdir -p "$package_dir/tools" "$package_dir/bundle"
  local archive="$package_dir/deploy-template-package.tgz"
  local manifest_sha
  manifest_sha="$(create_archive "$(basename "$package_dir")" "$archive")"
  local archive_sha
  archive_sha="$(sha256_file "$archive")"
  write_materials "$manifest_sha" "$archive_sha" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json"
  create_airgap_payloads "$package_dir"
  create_airgap_image_archives "$package_dir" "$package_dir/release-contract.json"
  write_airgap_operator_prerequisites "$package_dir" "$package_dir/operator-prerequisites.json"
  run_airgap_bundle_create \
    "$package_dir" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json" \
    "$archive" \
    "$package_dir/bundle" \
    "$package_dir/bundle-create-output" >"$package_dir/bundle-create.out"
  write_bundle_operator_inputs "$package_dir/bundle"
  write_fake_airgap_kubectl "$package_dir/tools/kubectl"
  write_fake_airgap_archive_probe "$package_dir/tools/archive-probe"
  write_fake_airgap_image_loader "$package_dir/tools/image-loader"
  write_airgap_operator_inputs "$package_dir" "$mode" "$smoke_path"
}

prepare_airgap_install_package() {
  local package_dir="$1"
  local mode="$2"
  local smoke_path="${3:-/ok}"
  local install_digest_mode="${4:-valid}"

  mkdir -p "$package_dir/tools" "$package_dir/bundle"
  local archive="$package_dir/deploy-template-package.tgz"
  local manifest_sha
  manifest_sha="$(create_archive "$(basename "$package_dir")" "$archive")"
  local archive_sha
  archive_sha="$(sha256_file "$archive")"
  write_materials "$manifest_sha" "$archive_sha" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json"
  create_airgap_payloads "$package_dir"
  create_airgap_image_archives "$package_dir" "$package_dir/release-contract.json"
  write_airgap_operator_prerequisites "$package_dir" "$package_dir/operator-prerequisites.json"
  local substrate_pack_dir="$package_dir/materialized-substrate-pack"
  local substrate_pack_source_dir="$package_dir/materialized-substrate-pack-source"
  materialize_airgap_substrate_install_materials "$substrate_pack_dir" "$substrate_pack_source_dir"
  run_airgap_bundle_create \
    "$package_dir" \
    "$package_dir/release-contract.json" \
    "$package_dir/deploy-template-package.json" \
    "$archive" \
    "$package_dir/bundle" \
    "$package_dir/bundle-create-output" \
    "$KIT_AIRGAP_PROFILE" \
    "$substrate_pack_dir/substrate-pack-manifest.json" \
    "$substrate_pack_dir/substrate-install-inputs.json" >"$package_dir/bundle-create.out"
  write_bundle_operator_inputs "$package_dir/bundle" "$KIT_AIRGAP_PROFILE"
  write_target_prerequisites_from_install_inputs \
    "$package_dir/bundle/components/substrate-install-inputs.json" \
    "$package_dir/bundle/operator-inputs/target-prerequisites.json" \
    "$KIT_AIRGAP_PROFILE"
  write_fake_airgap_kubectl "$package_dir/tools/kubectl"
  write_fake_airgap_archive_probe "$package_dir/tools/archive-probe"
  write_fake_airgap_image_loader "$package_dir/tools/image-loader"

  local install_parameters_sha256=""
  if [[ "$install_digest_mode" == "valid" ]]; then
    install_parameters_sha256=""
  else
    install_parameters_sha256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fi
  write_airgap_install_operator_inputs "$package_dir" "$mode" "$install_parameters_sha256" "$smoke_path"
}

write_minimal_airgap_install_package() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [packageDir] = process.argv.slice(2);

function write(file, body, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
  if (mode) {
    fs.chmodSync(file, mode);
  }
}

function writeJson(file, value) {
  write(file, `${JSON.stringify(value, null, 2)}\n`);
}

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function component(kind, relativePath) {
  return {
    kind,
    path: relativePath,
    sha256: digestFile(path.join(packageDir, 'bundle', relativePath))
  };
}

writeJson(path.join(packageDir, 'release-contract.json'), { schema_version: 'fixture.release-contract/v1' });
writeJson(path.join(packageDir, 'deploy-template-package.json'), { schema_version: 'fixture.deploy-template-package/v1' });
write(path.join(packageDir, 'deploy-template-package.tgz'), 'archive fixture\n');
writeJson(path.join(packageDir, 'image-map.json'), { schema_version: 'fixture.image-map/v1' });
writeJson(path.join(packageDir, 'substrate-pack-manifest.json'), { schema_version: 'fixture.substrate-pack-manifest/v1' });
writeJson(path.join(packageDir, 'render-values.json'), { namespace: 'agentsmith' });
writeJson(path.join(packageDir, 'substrate-truth.json'), { schema_version: 'fixture.substrate-truth/v1' });
writeJson(path.join(packageDir, 'target-prerequisites.json'), { schema_version: 'fixture.target-prerequisites/v1' });
writeJson(path.join(packageDir, 'substrate-install-inputs.json'), { schema_version: 'fixture.substrate-install-inputs/v1' });

for (const [source, destination] of [
  ['release-contract.json', 'bundle/components/release-contract.json'],
  ['deploy-template-package.json', 'bundle/components/deploy-template-package.json'],
  ['deploy-template-package.tgz', 'bundle/components/agentsmith-deploy-template-package.tgz'],
  ['image-map.json', 'bundle/components/image-map.json'],
  ['substrate-pack-manifest.json', 'bundle/components/substrate-pack-manifest.json'],
  ['render-values.json', 'bundle/operator-inputs/render-values.json'],
  ['substrate-truth.json', 'bundle/operator-inputs/substrate-truth.json'],
  ['target-prerequisites.json', 'bundle/operator-inputs/target-prerequisites.json'],
  ['substrate-install-inputs.json', 'bundle/components/substrate-install-inputs.json']
]) {
  fs.mkdirSync(path.dirname(path.join(packageDir, destination)), { recursive: true });
  fs.copyFileSync(path.join(packageDir, source), path.join(packageDir, destination));
}

const profile = {
  value: 'existing_kubernetes/kit_installed/airgap',
  target_cluster: 'existing_kubernetes',
  substrate_source: 'kit_installed',
  distribution: 'airgap'
};
writeJson(path.join(packageDir, 'bundle/airgap-bundle-manifest.json'), {
  schema_version: 'agentsmith.airgap-bundle-manifest/v1',
  target_profile: profile,
  substrate: {
    mode: 'kit_installed',
    bundled: true
  },
  components: [
    component('release_contract', 'components/release-contract.json'),
    component('deploy_template_package', 'components/deploy-template-package.json'),
    component('deploy_template_archive', 'components/agentsmith-deploy-template-package.tgz'),
    component('image_map', 'components/image-map.json'),
    component('substrate_pack_manifest', 'components/substrate-pack-manifest.json'),
    component('substrate_install_inputs', 'components/substrate-install-inputs.json')
  ]
});

for (const tool of ['kubectl', 'archive-probe', 'image-loader']) {
  write(path.join(packageDir, 'tools', tool), '#!/usr/bin/env sh\nexit 0\n', 0o755);
}

writeJson(path.join(packageDir, 'operator-inputs.json'), {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: 'airgap/install_substrates',
  release_contract: 'bundle/components/release-contract.json',
  deploy_template_package: 'bundle/components/deploy-template-package.json',
  deploy_template_archive: 'bundle/components/agentsmith-deploy-template-package.tgz',
  render_values: 'bundle/operator-inputs/render-values.json',
  target_prerequisites: 'bundle/operator-inputs/target-prerequisites.json',
  substrate_pack_manifest: 'bundle/components/substrate-pack-manifest.json',
  substrate_install_inputs: 'bundle/components/substrate-install-inputs.json',
  airgap_bundle: 'bundle',
  airgap_bundle_manifest: 'bundle/airgap-bundle-manifest.json',
  namespace: 'agentsmith',
  mode: 'apply',
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context',
  archive_probe: 'tools/archive-probe',
  image_loader: 'tools/image-loader',
  install_confirmation: {
    confirmed: true,
    confirm_current_install_parameters: true,
    operator_run_id: 'operator-inputs-install-1001'
  },
  deploy_confirmation: {
    confirmed: true,
    operator_run_id: 'operator-inputs-airgap-apply-1001'
  },
  smoke_url: 'https://release.example/ok',
  expected_status: 200,
  timeout: '60s',
  timeout_ms: 5000
});
NODE
}

expect_fail_matching() {
  local label="$1"
  local pattern="$2"
  shift 2

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected failure: $label"
  fi
  if ! grep -Eq "$pattern" "$TMP_DIR/$label.out" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "failure message did not match $pattern for $label"
  fi
  pass "rejected expected orchestration case: $label"
}

deployment_path_dir() {
  local package_dir="$1"
  local slug="${2:-online-use-existing}"
  printf '%s\n' "$package_dir/.release-kit-internal/$slug/deployment-path"
}

write_stale_finalizer() {
  local package_dir="$1"
  local slug="${2:-online-use-existing}"
  local path_dir
  path_dir="$(deployment_path_dir "$package_dir" "$slug")"

  mkdir -p "$path_dir/source-evidence"
  printf '%s\n' '{"stale":true}' >"$path_dir/deployment-path-report.json"
  printf '%s\n' '{"stale":true}' >"$path_dir/deployment-path-finalizer-manifest.json"
  printf '%s\n' '{"stale":true}' >"$path_dir/source-evidence/stale-report.json"
}

assert_no_path_evidence() {
  local package_dir="$1"
  local slug="${2:-online-use-existing}"
  local path_dir
  path_dir="$(deployment_path_dir "$package_dir" "$slug")"

  [[ ! -e "$path_dir/deployment-path-report.json" ]] ||
    fail "unexpected deployment-path-report.json remained for $package_dir"
  [[ ! -e "$path_dir/deployment-path-finalizer-manifest.json" ]] ||
    fail "unexpected deployment-path-finalizer-manifest.json remained for $package_dir"
  [[ ! -e "$path_dir/source-evidence" ]] ||
    fail "unexpected source-evidence remained for $package_dir"
}

assert_no_ga_report() {
  local package_dir="$1"
  if find "$package_dir/.release-kit-internal" -name ga-release-report.json -print -quit | grep -q .; then
    fail "operator-inputs run must not write ga-release-report.json"
  fi
}

assert_path_evidence() {
  local package_dir="$1"
  local path_dir
  path_dir="$(deployment_path_dir "$package_dir")"

  for file in \
    "$package_dir/.release-kit-internal/operator-inputs-plan.json" \
    "$package_dir/.release-kit-internal/online-use-existing/online-deployment-gate/online-deployment-gate-report.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" \
    "$path_dir/source-evidence/deployment-gate-report.json" \
    "$path_dir/source-evidence/target-preflight-report.json" \
    "$path_dir/source-evidence/render-check-report.json" \
    "$path_dir/source-evidence/apply-report.json" \
    "$path_dir/source-evidence/rollout-report.json" \
    "$path_dir/source-evidence/route-smoke-report.json"; do
    [[ -f "$file" ]] || fail "missing expected path evidence file: $file"
  done
  [[ ! -e "$path_dir/source-evidence/stale-report.json" ]] ||
    fail "stale source evidence remained after successful online path run"

  "$NODE_BIN" --input-type=module - "$path_dir/deployment-path-report.json" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const stepNames = (report.steps || []).map((step) => step.name).join(',');

if (report.schema !== 'agentsmith.deployment-path-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'deployment_path_ga_evidence') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.status !== 'pass' || report.readiness !== false) {
  throw new Error('deployment path report must be pass with readiness=false');
}
if (report.formal_verdict !== undefined) {
  throw new Error('deployment path report must not issue formal_verdict');
}
if (report.operator_path !== 'online/use_existing') {
  throw new Error(`unexpected operator_path: ${report.operator_path}`);
}
if (stepNames !== 'target-preflight,render-check,apply,rollout,route-smoke') {
  throw new Error(`unexpected finalized steps: ${stepNames}`);
}
NODE
  assert_no_ga_report "$package_dir"
}

assert_install_path_evidence() {
  local package_dir="$1"
  local path_dir="$package_dir/.release-kit-internal/online-install-substrates/deployment-path"
  local install_dir="$package_dir/.release-kit-internal/online-install-substrates/substrate-install"
  local gate_dir="$package_dir/.release-kit-internal/online-install-substrates/online-deployment-gate"

  for file in \
    "$package_dir/.release-kit-internal/operator-inputs-plan.json" \
    "$install_dir/substrate-install-report.json" \
    "$install_dir/substrate-truth.json" \
    "$gate_dir/online-deployment-gate-report.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" \
    "$path_dir/source-evidence/deployment-gate-report.json" \
    "$path_dir/source-evidence/substrate-install-report.json" \
    "$path_dir/source-evidence/target-preflight-report.json" \
    "$path_dir/source-evidence/render-check-report.json" \
    "$path_dir/source-evidence/apply-report.json" \
    "$path_dir/source-evidence/rollout-report.json" \
    "$path_dir/source-evidence/route-smoke-report.json"; do
    [[ -f "$file" ]] || fail "missing expected install path evidence file: $file"
  done
  [[ ! -e "$path_dir/source-evidence/stale-report.json" ]] ||
    fail "stale source evidence remained after successful install path run"

  "$NODE_BIN" --input-type=module - \
    "$package_dir/substrate-truth.json" \
    "$install_dir/substrate-truth.json" \
    "$install_dir/substrate-install-report.json" \
    "$gate_dir/target-preflight/target-preflight-report.json" \
    "$path_dir/source-evidence/target-preflight-report.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';

const [
  packageTruthFile,
  generatedTruthFile,
  installReportFile,
  gateTargetPreflightFile,
  finalizedTargetPreflightFile,
  pathReportFile,
  finalizerManifestFile
] = process.argv.slice(2);

const digestFile = (file) =>
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
const packageTruthDigest = digestFile(packageTruthFile);
const generatedTruthDigest = digestFile(generatedTruthFile);
const installReport = JSON.parse(fs.readFileSync(installReportFile, 'utf8'));
const gateTargetPreflight = JSON.parse(fs.readFileSync(gateTargetPreflightFile, 'utf8'));
const finalizedTargetPreflight = JSON.parse(fs.readFileSync(finalizedTargetPreflightFile, 'utf8'));
const pathReport = JSON.parse(fs.readFileSync(pathReportFile, 'utf8'));
const finalizerManifest = JSON.parse(fs.readFileSync(finalizerManifestFile, 'utf8'));
const stepNames = (pathReport.steps || []).map((step) => step.name).join(',');

if (packageTruthDigest === generatedTruthDigest) {
  throw new Error('fixture must keep package-local substrate truth different from installer output truth');
}
if (installReport.output_substrate_truth_digest !== generatedTruthDigest) {
  throw new Error('installer report must bind generated substrate truth digest');
}
if (gateTargetPreflight.substrate_truth?.input_sha256 !== generatedTruthDigest) {
  throw new Error('online gate target-preflight must use installer output substrate truth digest');
}
if (finalizedTargetPreflight.substrate_truth?.input_sha256 !== generatedTruthDigest) {
  throw new Error('finalized target-preflight evidence must use installer output substrate truth digest');
}
if (gateTargetPreflight.substrate_truth.input_sha256 === packageTruthDigest) {
  throw new Error('online gate target-preflight must not use package-local substrate truth');
}
if (pathReport.operator_path !== 'online/install_substrates') {
  throw new Error(`unexpected operator_path: ${pathReport.operator_path}`);
}
if (stepNames !== 'substrate-install,target-preflight,render-check,apply,rollout,route-smoke') {
  throw new Error(`unexpected install finalized steps: ${stepNames}`);
}
if (
  pathReport.install_substrates_confirmation?.operator_run_id !==
  'operator-inputs-install-1001'
) {
  throw new Error('deployment path report must bind install confirmation operator_run_id');
}
if (
  pathReport.source_evidence?.substrate_install?.output_substrate_truth_digest !==
  generatedTruthDigest
) {
  throw new Error('deployment path report source evidence must bind installer truth digest');
}
const sourceEvidencePaths = new Set((finalizerManifest.source_evidence_files || []).map((entry) => entry.path));
if (!sourceEvidencePaths.has('source-evidence/substrate-install-report.json')) {
  throw new Error('finalizer manifest must include substrate install source evidence');
}
if ('formal_verdict' in pathReport) {
  throw new Error('deployment path report must not issue formal_verdict');
}
NODE
  assert_no_ga_report "$package_dir"
}

assert_airgap_path_evidence() {
  local package_dir="$1"
  local consume_dir="$package_dir/.release-kit-internal/airgap-use-existing/airgap-consume-rehearsal"
  local path_dir="$package_dir/.release-kit-internal/airgap-use-existing/deployment-path"

  for file in \
    "$package_dir/.release-kit-internal/operator-inputs-plan.json" \
    "$consume_dir/airgap-consume-rehearsal-report.json" \
    "$consume_dir/airgap-bundle-check/airgap-bundle-check-report.json" \
    "$consume_dir/airgap-deployment-gate/airgap-deployment-gate-report.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" \
    "$path_dir/source-evidence/deployment-gate-report.json" \
    "$path_dir/source-evidence/bundle-check-report.json" \
    "$path_dir/source-evidence/target-preflight-report.json" \
    "$path_dir/source-evidence/image-load-report.json" \
    "$path_dir/source-evidence/offline-render-check-report.json" \
    "$path_dir/source-evidence/apply-report.json" \
    "$path_dir/source-evidence/rollout-report.json" \
    "$path_dir/source-evidence/route-smoke-report.json" \
    "$path_dir/source-evidence/airgap-bundle-manifest.json" \
    "$path_dir/source-evidence/image-map.json"; do
    [[ -f "$file" ]] || fail "missing expected airgap path evidence file: $file"
  done
  [[ ! -e "$path_dir/source-evidence/stale-report.json" ]] ||
    fail "stale source evidence remained after successful airgap path run"

  "$NODE_BIN" --input-type=module - \
    "$consume_dir/airgap-consume-rehearsal-report.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" <<'NODE'
import fs from 'node:fs';

const [consumeReportFile, pathReportFile, finalizerManifestFile] = process.argv.slice(2);
const consumeReport = JSON.parse(fs.readFileSync(consumeReportFile, 'utf8'));
const pathReport = JSON.parse(fs.readFileSync(pathReportFile, 'utf8'));
const finalizerManifest = JSON.parse(fs.readFileSync(finalizerManifestFile, 'utf8'));
const consumeSteps = (consumeReport.steps || []).map((step) => `${step.name}:${step.report_path}`).join(',');
const pathSteps = (pathReport.steps || []).map((step) => step.name).join(',');
const sourceEvidencePaths = new Set((finalizerManifest.source_evidence_files || []).map((entry) => entry.path));

if (consumeReport.schema !== 'agentsmith.airgap-consume-rehearsal/v1') {
  throw new Error(`unexpected consume schema: ${consumeReport.schema}`);
}
if (consumeSteps !== 'airgap-bundle-check:airgap-bundle-check/airgap-bundle-check-report.json,airgap-deployment-gate:airgap-deployment-gate/airgap-deployment-gate-report.json') {
  throw new Error(`unexpected consume steps: ${consumeSteps}`);
}
if (pathReport.schema !== 'agentsmith.deployment-path-report/v1') {
  throw new Error(`unexpected path schema: ${pathReport.schema}`);
}
if (pathReport.operator_path !== 'airgap/use_existing') {
  throw new Error(`unexpected operator_path: ${pathReport.operator_path}`);
}
if (pathSteps !== 'target-preflight,bundle-check,image-load,offline-render-check,apply,rollout,route-smoke') {
  throw new Error(`unexpected airgap finalized steps: ${pathSteps}`);
}
if (pathReport.status !== 'pass' || pathReport.readiness !== false) {
  throw new Error('airgap path report must be pass with readiness=false');
}
if ('formal_verdict' in pathReport) {
  throw new Error('airgap path report must not issue formal_verdict');
}
if (!pathReport.airgap_offline || pathReport.airgap_offline.public_internet_downloads !== false) {
  throw new Error('airgap path report must include offline evidence summary');
}
if (sourceEvidencePaths.has('source-evidence/airgap-consume-rehearsal-report.json')) {
  throw new Error('finalizer must not ingest the consume rehearsal report as source evidence');
}
for (const required of [
  'source-evidence/bundle-check-report.json',
  'source-evidence/deployment-gate-report.json',
  'source-evidence/route-smoke-report.json',
  'source-evidence/airgap-bundle-manifest.json',
  'source-evidence/image-map.json'
]) {
  if (!sourceEvidencePaths.has(required)) {
    throw new Error(`missing source evidence entry: ${required}`);
  }
}
NODE
  assert_no_ga_report "$package_dir"
}

assert_airgap_install_path_evidence() {
  local package_dir="$1"
  local pack_source="${2:-fixture}"
  local output_base="$package_dir/.release-kit-internal/airgap-install-substrates"
  local install_dir="$output_base/substrate-install"
  local bundle_check_dir="$output_base/airgap-bundle-check"
  local gate_dir="$output_base/airgap-deployment-gate"
  local path_dir="$output_base/deployment-path"

  for file in \
    "$package_dir/.release-kit-internal/operator-inputs-plan.json" \
    "$install_dir/substrate-install-report.json" \
    "$install_dir/substrate-truth.json" \
    "$bundle_check_dir/airgap-bundle-check-report.json" \
    "$gate_dir/airgap-deployment-gate-report.json" \
    "$gate_dir/target-preflight/target-preflight-report.json" \
    "$gate_dir/substrate-pack-check/substrate-pack-check-report.json" \
    "$gate_dir/airgap-image-load/airgap-image-load-report.json" \
    "$gate_dir/airgap-bundle-render-check/airgap-bundle-render-check-report.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" \
    "$path_dir/source-evidence/deployment-gate-report.json" \
    "$path_dir/source-evidence/bundle-check-report.json" \
    "$path_dir/source-evidence/substrate-install-report.json" \
    "$path_dir/source-evidence/target-preflight-report.json" \
    "$path_dir/source-evidence/image-load-report.json" \
    "$path_dir/source-evidence/offline-render-check-report.json" \
    "$path_dir/source-evidence/apply-report.json" \
    "$path_dir/source-evidence/rollout-report.json" \
    "$path_dir/source-evidence/route-smoke-report.json" \
    "$path_dir/source-evidence/airgap-bundle-manifest.json" \
    "$path_dir/source-evidence/image-map.json"; do
    [[ -f "$file" ]] || fail "missing expected airgap install path evidence file: $file"
  done
  [[ ! -e "$output_base/airgap-consume-rehearsal/airgap-consume-rehearsal-report.json" ]] ||
    fail "airgap install path must not run airgap-consume-rehearsal"
  [[ ! -e "$path_dir/source-evidence/stale-report.json" ]] ||
    fail "stale source evidence remained after successful airgap install path run"

  "$NODE_BIN" --input-type=module - \
    "$package_dir/bundle/operator-inputs/substrate-truth.json" \
    "$install_dir/substrate-truth.json" \
    "$install_dir/substrate-install-report.json" \
    "$gate_dir/target-preflight/target-preflight-report.json" \
    "$gate_dir/airgap-bundle-render-check/airgap-bundle-render-check-report.json" \
    "$path_dir/source-evidence/target-preflight-report.json" \
    "$package_dir/bundle/components/substrate-pack-manifest.json" \
    "$package_dir/bundle/components/substrate-install-inputs.json" \
    "$path_dir/source-evidence/airgap-bundle-manifest.json" \
    "$path_dir/deployment-path-report.json" \
    "$path_dir/deployment-path-finalizer-manifest.json" \
    "$pack_source" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [
  bundleTruthFile,
  generatedTruthFile,
  installReportFile,
  gateTargetPreflightFile,
  offlineRenderCheckFile,
  finalizedTargetPreflightFile,
  packManifestFile,
  substrateInstallInputsFile,
  finalizedBundleManifestFile,
  pathReportFile,
  finalizerManifestFile,
  packSource
] = process.argv.slice(2);

const digestFile = (file) =>
  `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
const bundleTruthDigest = digestFile(bundleTruthFile);
const generatedTruthDigest = digestFile(generatedTruthFile);
const installReport = JSON.parse(fs.readFileSync(installReportFile, 'utf8'));
const gateTargetPreflight = JSON.parse(fs.readFileSync(gateTargetPreflightFile, 'utf8'));
const offlineRenderCheck = JSON.parse(fs.readFileSync(offlineRenderCheckFile, 'utf8'));
const finalizedTargetPreflight = JSON.parse(fs.readFileSync(finalizedTargetPreflightFile, 'utf8'));
const packManifest = JSON.parse(fs.readFileSync(packManifestFile, 'utf8'));
const finalizedBundleManifest = JSON.parse(fs.readFileSync(finalizedBundleManifestFile, 'utf8'));
const pathReport = JSON.parse(fs.readFileSync(pathReportFile, 'utf8'));
const finalizerManifest = JSON.parse(fs.readFileSync(finalizerManifestFile, 'utf8'));
const stepNames = (pathReport.steps || []).map((step) => step.name).join(',');

if (bundleTruthDigest === generatedTruthDigest) {
  throw new Error('fixture must keep bundle-local substrate truth different from installer output truth');
}
if (installReport.output_substrate_truth_digest !== generatedTruthDigest) {
  throw new Error('installer report must bind generated substrate truth digest');
}
if (gateTargetPreflight.substrate_truth?.input_sha256 !== generatedTruthDigest) {
  throw new Error('airgap gate target-preflight must use installer output substrate truth digest');
}
if (offlineRenderCheck.digest_summary?.substrate_truth_input_sha256 !== generatedTruthDigest) {
  throw new Error('airgap offline render-check must use installer output substrate truth digest');
}
if (finalizedTargetPreflight.substrate_truth?.input_sha256 !== generatedTruthDigest) {
  throw new Error('finalized target-preflight evidence must use installer output substrate truth digest');
}
if (gateTargetPreflight.substrate_truth.input_sha256 === bundleTruthDigest) {
  throw new Error('airgap gate target-preflight must not use bundle-local substrate truth');
}
if (pathReport.operator_path !== 'airgap/install_substrates') {
  throw new Error(`unexpected operator_path: ${pathReport.operator_path}`);
}
if (packSource === 'materialized') {
  if (packManifest.deployment_path !== 'airgap/install_substrates') {
    throw new Error('airgap install positive path must use materialized install_substrates substrate pack');
  }
  const materializedPaths = [
    packManifest.payload?.install_plan?.path,
    packManifest.templates?.resource_list?.path,
    packManifest.tools?.routability_probe?.path,
    packManifest.checksums?.materials?.path
  ];
  for (const materialPath of materializedPaths) {
    if (typeof materialPath !== 'string') {
      throw new Error('materialized substrate pack manifest must declare minimal material paths');
    }
    if (!fs.existsSync(path.join(path.dirname(packManifestFile), materialPath))) {
      throw new Error(`materialized substrate pack material missing from bundle: ${materialPath}`);
    }
  }
}
const bundleComponentByKind = new Map(
  (finalizedBundleManifest.components || []).map((component) => [component.kind, component])
);
if (
  bundleComponentByKind.get('substrate_pack_manifest')?.sha256 !==
  digestFile(packManifestFile)
) {
  throw new Error('finalized airgap bundle manifest must bind materialized substrate pack manifest digest');
}
if (
  bundleComponentByKind.get('substrate_install_inputs')?.sha256 !==
  digestFile(substrateInstallInputsFile)
) {
  throw new Error('finalized airgap bundle manifest must bind materialized substrate install inputs digest');
}
if (
  finalizedBundleManifest.bindings?.substrate_install_inputs_sha256 !==
  digestFile(substrateInstallInputsFile)
) {
  throw new Error('finalized airgap bundle manifest must bind substrate install inputs sha in bindings');
}
if (packSource !== 'fixture' && packSource !== 'materialized') {
  throw new Error(`unexpected airgap install pack assertion mode: ${packSource}`);
}
if (stepNames !== 'target-preflight,bundle-check,image-load,substrate-install,offline-render-check,apply,rollout,route-smoke') {
  throw new Error(`unexpected airgap install finalized steps: ${stepNames}`);
}
if (
  pathReport.install_substrates_confirmation?.operator_run_id !==
  'operator-inputs-install-1001'
) {
  throw new Error('deployment path report must bind install confirmation operator_run_id');
}
if (
  pathReport.source_evidence?.substrate_install?.output_substrate_truth_digest !==
  generatedTruthDigest
) {
  throw new Error('deployment path report source evidence must bind installer truth digest');
}
const sourceEvidencePaths = new Set((finalizerManifest.source_evidence_files || []).map((entry) => entry.path));
for (const required of [
  'source-evidence/substrate-install-report.json',
  'source-evidence/bundle-check-report.json',
  'source-evidence/deployment-gate-report.json',
  'source-evidence/route-smoke-report.json',
  'source-evidence/airgap-bundle-manifest.json',
  'source-evidence/image-map.json'
]) {
  if (!sourceEvidencePaths.has(required)) {
    throw new Error(`missing source evidence entry: ${required}`);
  }
}
if (sourceEvidencePaths.has('source-evidence/airgap-consume-rehearsal-report.json')) {
  throw new Error('airgap install finalizer must not ingest consume rehearsal evidence');
}
if ('formal_verdict' in pathReport) {
  throw new Error('deployment path report must not issue formal_verdict');
}
NODE
  assert_no_ga_report "$package_dir"
}

tamper_plan_swap_producers() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$ROOT_DIR" "$package_dir" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, packageDir] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestPlan(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

plan.producer_argv = [plan.producer_argv[1], plan.producer_argv[0]];
plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);

const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes('producer order must be substrate-install then online-deployment-gate')) {
    throw error;
  }
  process.exit(0);
}
throw new Error('tampered producer order should have failed');
NODE
}

tamper_plan_deployment_path() {
  local package_dir="$1"
  local replacement="$2"
  local expected_message="$3"

  "$NODE_BIN" --input-type=module - \
    "$ROOT_DIR" \
    "$package_dir" \
    "$replacement" \
    "$expected_message" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, packageDir, replacement, expectedMessage] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestPlan(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

plan.deployment_path = replacement;
plan._internal.expected.deployment_path = replacement;
plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);

const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes(expectedMessage)) {
    throw error;
  }
  process.exit(0);
}
throw new Error('tampered deployment_path should have failed');
NODE
}

tamper_plan_manifest_path() {
  local package_dir="$1"
  local replacement_manifest="$2"
  local expected_message="$3"

  "$NODE_BIN" --input-type=module - \
    "$ROOT_DIR" \
    "$package_dir" \
    "$replacement_manifest" \
    "$expected_message" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, packageDir, replacementManifest, expectedMessage] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestPlan(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

const canonicalManifestPath = fs.realpathSync(replacementManifest);
plan.package.manifest_path = canonicalManifestPath;
plan.package.manifest_sha256 = digestBuffer(fs.readFileSync(canonicalManifestPath));
plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);

const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes(expectedMessage)) {
    throw error;
  }
  process.exit(0);
}
throw new Error('tampered manifest_path should have failed');
NODE
}

tamper_airgap_plan_arg() {
  local package_dir="$1"
  local flag="$2"
  local replacement="$3"
  local expected_message="$4"

  "$NODE_BIN" --input-type=module - "$ROOT_DIR" "$package_dir" "$flag" "$replacement" "$expected_message" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, packageDir, flag, replacement, expectedMessage] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestPlan(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

const step = plan.producer_argv.find((candidate) => candidate.name === 'airgap-consume-rehearsal');
if (!step) {
  throw new Error('fixture plan must include airgap-consume-rehearsal');
}
const index = step.argv.indexOf(flag);
if (index === -1 || !step.argv[index + 1]) {
  throw new Error(`fixture plan step must include ${flag}`);
}
step.argv[index + 1] = replacement;
plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);

const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes(expectedMessage)) {
    throw error;
  }
  process.exit(0);
}
throw new Error(`tampered ${flag} should have failed`);
NODE
}

tamper_airgap_install_gate_substrate_truth_to_bundle() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$ROOT_DIR" "$package_dir" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, packageDir] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestPlan(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

const step = plan.producer_argv.find((candidate) => candidate.name === 'airgap-deployment-gate');
if (!step) {
  throw new Error('fixture plan must include airgap-deployment-gate');
}
const index = step.argv.indexOf('--substrate-truth');
if (index === -1 || !step.argv[index + 1]) {
  throw new Error('fixture airgap gate must include --substrate-truth');
}
step.argv[index + 1] = path.join(packageDir, 'bundle/operator-inputs/substrate-truth.json');
plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);

const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes('airgap-deployment-gate --substrate-truth must match plan expected value')) {
    throw error;
  }
  process.exit(0);
}
throw new Error('tampered airgap install gate substrate truth should have failed');
NODE
}

tamper_plan_ref_to_copy() {
  local package_dir="$1"
  local ref_key="$2"
  local copy_path="$3"
  local manifest_mode="$4"
  local expected_message="$5"
  local argv_flag="${6:-}"

  "$NODE_BIN" --input-type=module - \
    "$ROOT_DIR" \
    "$package_dir" \
    "$ref_key" \
    "$copy_path" \
    "$manifest_mode" \
    "$expected_message" \
    "$argv_flag" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [
  rootDir,
  packageDir,
  refKey,
  copyPath,
  manifestMode,
  expectedMessage,
  argvFlag
] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestFile(file) {
  return digestBuffer(fs.readFileSync(file));
}

function digestPlan(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

function packageRelativePath(absolutePath) {
  return path.relative(plan.operator_inputs_root, absolutePath).split(path.sep).join('/');
}

const ref = plan.input_refs?.[refKey];
if (!ref || ref.kind !== 'file') {
  throw new Error(`fixture plan must include file ref ${refKey}`);
}
fs.mkdirSync(path.dirname(copyPath), { recursive: true });
fs.copyFileSync(ref.absolute_path, copyPath);
const canonicalCopyPath = fs.realpathSync(copyPath);
ref.absolute_path = canonicalCopyPath;
ref.path = packageRelativePath(canonicalCopyPath);
ref.sha256 = digestFile(canonicalCopyPath);

if (manifestMode === 'update-manifest') {
  const manifestPath = plan.package.manifest_path;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  manifest[refKey] = packageRelativePath(canonicalCopyPath);
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  plan.package.manifest_sha256 = digestFile(manifestPath);
} else if (manifestMode !== 'keep-manifest') {
  throw new Error(`unknown manifest tamper mode: ${manifestMode}`);
}

if (argvFlag) {
  let updatedArgv = false;
  for (const step of plan.producer_argv || []) {
    if (!Array.isArray(step.argv)) {
      continue;
    }
    for (
      let index = step.argv.indexOf(argvFlag);
      index !== -1;
      index = step.argv.indexOf(argvFlag, index + 2)
    ) {
      if (!step.argv[index + 1]) {
        throw new Error(`fixture plan step must include value for ${argvFlag}`);
      }
      step.argv[index + 1] = canonicalCopyPath;
      updatedArgv = true;
    }
  }
  if (!updatedArgv) {
    throw new Error(`fixture plan producer_argv must include ${argvFlag}`);
  }
}

plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);

const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes(expectedMessage)) {
    throw error;
  }
  process.exit(0);
}
throw new Error(`tampered ${refKey} should have failed`);
NODE
}

run_direct_plan_expect_fail() {
  local package_dir="$1"
  local expected_message="$2"

  "$NODE_BIN" --input-type=module - "$ROOT_DIR" "$package_dir" "$expected_message" <<'NODE'
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [rootDir, packageDir, expectedMessage] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const runnerUrl = pathToFileURL(path.join(rootDir, 'scripts/lib/operator-inputs-runner.mjs')).href;
const { runOperatorInputsPlan } = await import(runnerUrl);

try {
  await runOperatorInputsPlan({ planPath });
} catch (error) {
  if (!String(error.message).includes(expectedMessage)) {
    throw error;
  }
  process.exit(0);
}
throw new Error('direct operator-inputs runner should have failed');
NODE
}

tamper_direct_plan_digest_without_update() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [packageDir] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
plan.producer_argv[0].name = 'tampered-online-deployment-gate';
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);
NODE
}

tamper_direct_plan_facade_argv() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [packageDir] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));

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

function digestPlan(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(stableJson(value))).digest('hex')}`;
}

plan.facade_argv[0] = 'sh';
plan.plan_sha256 = null;
plan.plan_sha256 = digestPlan({ ...plan, plan_sha256: null });
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);
NODE
}

run_operator_inputs() {
  local package_dir="$1"
  local label="$2"
  local live_image="${3:-}"

  if [[ -n "$live_image" ]]; then
    FAKE_KUBECTL_LOG="$TMP_DIR/$label-kubectl.log" \
      FAKE_KUBECTL_LIVE_IMAGE="$live_image" \
      FAKE_KUBECTL_LIVE_IMAGE_ID="docker-pullable://$live_image" \
      bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$package_dir" --run
  else
    FAKE_KUBECTL_LOG="$TMP_DIR/$label-kubectl.log" \
      bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$package_dir" --run
  fi
}

run_airgap_operator_inputs() {
  local package_dir="$1"
  local label="$2"
  local target_image
  target_image="$(target_image_for_id "$package_dir/bundle/components/image-map.json" agentsmith_app)"

  FAKE_KUBECTL_LOG="$TMP_DIR/$label-kubectl.log" \
    FAKE_KUBECTL_TARGET_IMAGE="$target_image" \
    AGENTSMITH_LOAD_LOG="$TMP_DIR/$label-image-load.log" \
    bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$package_dir" --run
}

make_operator_facing_substrate_truth() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [manifestPath] = process.argv.slice(2);
const packageRoot = path.dirname(manifestPath);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const truthPath = path.join(packageRoot, manifest.substrate_truth);
const truth = JSON.parse(fs.readFileSync(truthPath, 'utf8'));
delete truth.target_cluster;
delete truth.substrate_source;
delete truth.distribution;
fs.writeFileSync(truthPath, `${JSON.stringify(truth, null, 2)}\n`);
NODE
}

make_operator_facing_target_prerequisites() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [manifestPath] = process.argv.slice(2);
const packageRoot = path.dirname(manifestPath);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const prerequisitesPath = path.join(packageRoot, manifest.target_prerequisites);
const prerequisites = JSON.parse(fs.readFileSync(prerequisitesPath, 'utf8'));
delete prerequisites.target_profile;
fs.writeFileSync(prerequisitesPath, `${JSON.stringify(prerequisites, null, 2)}\n`);
NODE
}

make_operator_facing_install_inputs() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [manifestPath] = process.argv.slice(2);
const packageRoot = path.dirname(manifestPath);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}
const installInputsPath = path.join(packageRoot, manifest.substrate_install_inputs);
const installInputs = JSON.parse(fs.readFileSync(installInputsPath, 'utf8'));
delete installInputs.target_profile;
delete installInputs.substrate_truth.target_cluster;
delete installInputs.substrate_truth.substrate_source;
delete installInputs.substrate_truth.distribution;
fs.writeFileSync(installInputsPath, `${JSON.stringify(installInputs, null, 2)}\n`);
if (manifest.airgap_bundle_manifest) {
  const bundleManifestPath = path.join(packageRoot, manifest.airgap_bundle_manifest);
  const bundleManifest = JSON.parse(fs.readFileSync(bundleManifestPath, 'utf8'));
  const component = bundleManifest.components?.find((item) => (
    item.kind === 'substrate_install_inputs'
  ));
  if (component) {
    component.sha256 = digestFile(installInputsPath);
    if (bundleManifest.bindings) {
      bundleManifest.bindings.substrate_install_inputs_sha256 = component.sha256;
    }
    fs.writeFileSync(bundleManifestPath, `${JSON.stringify(bundleManifest, null, 2)}\n`);
  }
}
NODE
}

enable_online_target_registry() {
  local package_dir="$1"

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" "$ONLINE_TARGET_REGISTRY" <<'NODE'
import fs from 'node:fs';

const [manifestPath, targetRegistry] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
manifest.target_registry = targetRegistry;
manifest.registry_probe = 'tools/registry-probe';
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

assert_online_target_registry_orchestration() {
  local package_dir="$1"
  local slug="$2"
  local expected_gate_steps="$3"
  local expected_plan_steps="$4"

  "$NODE_BIN" --input-type=module - \
    "$package_dir/.release-kit-internal/operator-inputs-plan.json" \
    "$package_dir/.release-kit-internal/$slug/online-deployment-gate/online-deployment-gate-report.json" \
    "$package_dir/.release-kit-internal/$slug/deployment-path/deployment-path-report.json" \
    "$package_dir/.release-kit-internal/$slug/deployment-path/deployment-path-finalizer-manifest.json" \
    "$expected_gate_steps" \
    "$expected_plan_steps" \
    "$ONLINE_TARGET_REGISTRY" <<'NODE'
import fs from 'node:fs';

const [
  planFile,
  gateReportFile,
  pathReportFile,
  finalizerManifestFile,
  expectedGateSteps,
  expectedPlanSteps,
  targetRegistry
] = process.argv.slice(2);

const plan = JSON.parse(fs.readFileSync(planFile, 'utf8'));
const gateReport = JSON.parse(fs.readFileSync(gateReportFile, 'utf8'));
const pathReport = JSON.parse(fs.readFileSync(pathReportFile, 'utf8'));
const finalizerManifest = JSON.parse(fs.readFileSync(finalizerManifestFile, 'utf8'));
const planStepNames = (plan.producer_argv || []).map((step) => step.name).join(',');
const gateStepNames = (gateReport.steps || []).map((step) => step.name).join(',');
const pathStepNames = (pathReport.steps || []).map((step) => step.name).join(',');

if (planStepNames !== expectedPlanSteps) {
  throw new Error(`unexpected producer argv steps: ${planStepNames}`);
}
if (gateStepNames !== expectedGateSteps) {
  throw new Error(`unexpected online gate steps: ${gateStepNames}`);
}
if (pathStepNames.includes('image-map') || pathStepNames.includes('registry-presence')) {
  throw new Error('deployment path finalizer must not promote online registry diagnostics in this slice');
}
if (gateReport.formal_verdict !== undefined || pathReport.formal_verdict !== undefined) {
  throw new Error('target_registry orchestration must not issue a separate operator verdict');
}
if (plan._internal?.expected?.target_registry !== targetRegistry) {
  throw new Error('plan expected target_registry must bind operator-inputs target_registry');
}

const onlineStep = (plan.producer_argv || []).find((step) => step.name === 'online-deployment-gate');
if (!onlineStep) {
  throw new Error('plan must include online-deployment-gate producer');
}
const argv = onlineStep.argv || [];
const targetIndex = argv.indexOf('--target-registry');
if (targetIndex === -1 || argv[targetIndex + 1] !== targetRegistry) {
  throw new Error('online gate producer argv must include --target-registry');
}
const probeIndex = argv.indexOf('--registry-probe');
const probeRef = plan.input_refs?.registry_probe;
if (!probeRef || probeRef.kind !== 'file' || !/^sha256:[0-9a-f]{64}$/.test(probeRef.sha256 || '')) {
  throw new Error('plan must bind registry_probe as a digest-bound file ref');
}
if (probeIndex === -1 || argv[probeIndex + 1] !== probeRef.absolute_path) {
  throw new Error('online gate producer argv must include digest-bound --registry-probe');
}
const installStep = (plan.producer_argv || []).find((step) => step.name === 'substrate-install');
if (installStep && ((installStep.argv || []).includes('--target-registry') || (installStep.argv || []).includes('--registry-probe'))) {
  throw new Error('substrate-install producer must not receive registry target/probe args');
}
const sourceEvidencePaths = new Set((finalizerManifest.source_evidence_files || []).map((entry) => entry.path));
for (const forbidden of [
  'source-evidence/image-map-report.json',
  'source-evidence/registry-presence-report.json'
]) {
  if (sourceEvidencePaths.has(forbidden)) {
    throw new Error(`${forbidden} must remain inside online gate evidence for this slice`);
  }
}
NODE
}

if [[ "${AGENTSMITH_OPERATOR_INPUTS_ORCHESTRATION_LIB_ONLY:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

start_server

positive_package="$TMP_DIR/positive-online"
prepare_online_package "$positive_package" apply /ok
make_operator_facing_substrate_truth "$positive_package"
make_operator_facing_target_prerequisites "$positive_package"
write_stale_finalizer "$positive_package"
run_operator_inputs "$positive_package" positive >"$TMP_DIR/positive.out" 2>"$TMP_DIR/positive.err"
assert_path_evidence "$positive_package"
pass "operator-inputs --run executes online/use_existing apply with operator-facing substrate truth and prerequisites"

positive_target_registry_package="$TMP_DIR/positive-online-target-registry"
prepare_online_package "$positive_target_registry_package" apply /ok
make_operator_facing_substrate_truth "$positive_target_registry_package"
make_operator_facing_target_prerequisites "$positive_target_registry_package"
enable_online_target_registry "$positive_target_registry_package"
write_stale_finalizer "$positive_target_registry_package"
run_operator_inputs \
  "$positive_target_registry_package" \
  positive-target-registry \
  "$(online_target_registry_app_image)" >"$TMP_DIR/positive-target-registry.out" 2>"$TMP_DIR/positive-target-registry.err"
assert_path_evidence "$positive_target_registry_package"
assert_online_target_registry_orchestration \
  "$positive_target_registry_package" \
  online-use-existing \
  "inputs,target-preflight,template-package,image-map,registry-presence,render,render-check,apply,rollout,smoke" \
  "online-deployment-gate"
pass "operator-inputs --run forwards target_registry apply to online/use_existing gate without a separate registry verdict"

positive_install_package="$TMP_DIR/positive-online-install"
prepare_online_install_package "$positive_install_package" apply /ok
make_operator_facing_target_prerequisites "$positive_install_package"
make_operator_facing_install_inputs "$positive_install_package"
write_stale_finalizer "$positive_install_package" online-install-substrates
run_operator_inputs "$positive_install_package" positive-install >"$TMP_DIR/positive-install.out" 2>"$TMP_DIR/positive-install.err"
assert_install_path_evidence "$positive_install_package"
pass "operator-inputs --run executes online/install_substrates apply with operator-facing prerequisites and install inputs"

positive_install_target_registry_package="$TMP_DIR/positive-online-install-target-registry"
prepare_online_install_package "$positive_install_target_registry_package" apply /ok
make_operator_facing_target_prerequisites "$positive_install_target_registry_package"
make_operator_facing_install_inputs "$positive_install_target_registry_package"
enable_online_target_registry "$positive_install_target_registry_package"
write_stale_finalizer "$positive_install_target_registry_package" online-install-substrates
run_operator_inputs \
  "$positive_install_target_registry_package" \
  positive-install-target-registry \
  "$(online_target_registry_app_image)" >"$TMP_DIR/positive-install-target-registry.out" 2>"$TMP_DIR/positive-install-target-registry.err"
assert_install_path_evidence "$positive_install_target_registry_package"
assert_online_target_registry_orchestration \
  "$positive_install_target_registry_package" \
  online-install-substrates \
  "inputs,target-preflight,substrate-pack-check,template-package,substrate-routability,image-map,registry-presence,render,render-check,apply,rollout,smoke" \
  "substrate-install,online-deployment-gate"
pass "operator-inputs --run forwards target_registry apply to online/install_substrates gate without expanding substrate-install"

positive_airgap_package="$TMP_DIR/positive-airgap"
prepare_airgap_package "$positive_airgap_package" apply /ok
make_operator_facing_substrate_truth "$positive_airgap_package"
make_operator_facing_target_prerequisites "$positive_airgap_package"
write_stale_finalizer "$positive_airgap_package" airgap-use-existing
if ! run_airgap_operator_inputs "$positive_airgap_package" positive-airgap >"$TMP_DIR/positive-airgap.out" 2>"$TMP_DIR/positive-airgap.err"; then
  cat "$TMP_DIR/positive-airgap.out" >&2
  cat "$TMP_DIR/positive-airgap.err" >&2
  fail "airgap/use_existing positive run failed"
fi
assert_airgap_path_evidence "$positive_airgap_package"
pass "operator-inputs --run executes airgap/use_existing apply with operator-facing substrate truth and prerequisites"

missing_release_contract_package="$TMP_DIR/missing-release-contract"
prepare_online_package "$missing_release_contract_package" apply /ok
write_stale_finalizer "$missing_release_contract_package"
rm "$missing_release_contract_package/release-contract.json"
expect_fail_matching missing_release_contract_preclean 'cannot read release_contract' \
  run_operator_inputs "$missing_release_contract_package" missing-release-contract
assert_no_path_evidence "$missing_release_contract_package"
pass "operator-inputs --run clears stale path evidence before missing release_contract validation"

missing_online_truth_package="$TMP_DIR/missing-online-substrate-truth"
prepare_online_package "$missing_online_truth_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_online_truth_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.substrate_truth;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_online_truth_package"
expect_fail_matching missing_online_substrate_truth 'missing required operator-inputs field for online/use_existing: substrate_truth' \
  run_operator_inputs "$missing_online_truth_package" missing-online-substrate-truth
assert_no_path_evidence "$missing_online_truth_package"
pass "operator-inputs online/use_existing still requires target substrate truth"

missing_online_kubectl_package="$TMP_DIR/missing-online-kubectl"
prepare_online_package "$missing_online_kubectl_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_online_kubectl_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.kubectl;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_online_kubectl_package"
expect_fail_matching missing_online_kubectl 'missing required operator-inputs field for online/use_existing: kubectl' \
  run_operator_inputs "$missing_online_kubectl_package" missing-online-kubectl
assert_no_path_evidence "$missing_online_kubectl_package"
pass "operator-inputs online/use_existing apply requires package-local kubectl before orchestration"

missing_online_context_package="$TMP_DIR/missing-online-context"
prepare_online_package "$missing_online_context_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_online_context_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.context;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_online_context_package"
expect_fail_matching missing_online_context 'missing required operator-inputs field for online/use_existing: context' \
  run_operator_inputs "$missing_online_context_package" missing-online-context
assert_no_path_evidence "$missing_online_context_package"
pass "operator-inputs online/use_existing apply requires explicit context before orchestration"

reserved_ref_package="$TMP_DIR/reserved-output-tree-ref"
prepare_online_package "$reserved_ref_package" apply /ok
write_stale_finalizer "$reserved_ref_package"
reserved_ref_path="$(deployment_path_dir "$reserved_ref_package")/source-evidence/release-contract-input.json"
cp "$reserved_ref_package/release-contract.json" "$reserved_ref_path"
"$NODE_BIN" --input-type=module - "$reserved_ref_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
manifest.release_contract =
  '.release-kit-internal/online-use-existing/deployment-path/source-evidence/release-contract-input.json';
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
expect_fail_matching reserved_output_tree_ref 'reserved operator-inputs output tree' \
  run_operator_inputs "$reserved_ref_package" reserved-output-tree-ref
[[ -f "$reserved_ref_path" ]] ||
  fail "operator-inputs --run must not delete manifest input under reserved output tree"
[[ -f "$(deployment_path_dir "$reserved_ref_package")/source-evidence/stale-report.json" ]] ||
  fail "reserved-tree ref failure must fail before unsafe stale evidence cleanup"
pass "operator-inputs --run rejects reserved output tree refs before preclean"

missing_airgap_kubectl_package="$TMP_DIR/missing-airgap-kubectl"
prepare_airgap_package "$missing_airgap_kubectl_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_airgap_kubectl_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.kubectl;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_airgap_kubectl_package" airgap-use-existing
expect_fail_matching missing_airgap_kubectl 'missing required operator-inputs field for airgap/use_existing: kubectl' \
  run_airgap_operator_inputs "$missing_airgap_kubectl_package" missing-airgap-kubectl
assert_no_path_evidence "$missing_airgap_kubectl_package" airgap-use-existing
pass "operator-inputs airgap path requires package-local kubectl before orchestration"

missing_airgap_context_package="$TMP_DIR/missing-airgap-context"
prepare_airgap_package "$missing_airgap_context_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_airgap_context_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.context;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_airgap_context_package" airgap-use-existing
expect_fail_matching missing_airgap_context 'missing required operator-inputs field for airgap/use_existing: context' \
  run_airgap_operator_inputs "$missing_airgap_context_package" missing-airgap-context
assert_no_path_evidence "$missing_airgap_context_package" airgap-use-existing
pass "operator-inputs airgap path requires explicit context before orchestration"

missing_airgap_truth_package="$TMP_DIR/missing-airgap-substrate-truth"
prepare_airgap_package "$missing_airgap_truth_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_airgap_truth_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.substrate_truth;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_airgap_truth_package" airgap-use-existing
expect_fail_matching missing_airgap_substrate_truth 'missing required operator-inputs field for airgap/use_existing: substrate_truth' \
  run_airgap_operator_inputs "$missing_airgap_truth_package" missing-airgap-substrate-truth
assert_no_path_evidence "$missing_airgap_truth_package" airgap-use-existing
pass "operator-inputs airgap/use_existing still requires bundle-local substrate truth"

dry_run_package="$TMP_DIR/dry-run-online"
prepare_online_package "$dry_run_package" server-dry-run /ok
write_stale_finalizer "$dry_run_package"
expect_fail_matching dry_run_run 'currently supports only online/use_existing, online/install_substrates, airgap/use_existing, or airgap/install_substrates with mode apply' \
  run_operator_inputs "$dry_run_package" dry-run
assert_no_path_evidence "$dry_run_package"
pass "operator-inputs --run rejects server-dry-run and clears stale path evidence"

dry_run_install_package="$TMP_DIR/dry-run-online-install"
prepare_online_install_package "$dry_run_install_package" server-dry-run /ok
write_stale_finalizer "$dry_run_install_package" online-install-substrates
expect_fail_matching dry_run_install_run 'currently supports only online/use_existing, online/install_substrates, airgap/use_existing, or airgap/install_substrates with mode apply' \
  run_operator_inputs "$dry_run_install_package" dry-run-install
assert_no_path_evidence "$dry_run_install_package" online-install-substrates
pass "operator-inputs --run rejects online/install_substrates server-dry-run and clears stale path evidence"

dry_run_airgap_package="$TMP_DIR/dry-run-airgap"
prepare_airgap_package "$dry_run_airgap_package" server-dry-run /ok
write_stale_finalizer "$dry_run_airgap_package" airgap-use-existing
expect_fail_matching dry_run_airgap_run 'currently supports only online/use_existing, online/install_substrates, airgap/use_existing, or airgap/install_substrates with mode apply' \
  run_airgap_operator_inputs "$dry_run_airgap_package" dry-run-airgap
assert_no_path_evidence "$dry_run_airgap_package" airgap-use-existing
pass "operator-inputs --run rejects airgap/use_existing server-dry-run and clears stale path evidence"

dry_run_airgap_install_package="$TMP_DIR/dry-run-airgap-install"
prepare_airgap_install_package "$dry_run_airgap_install_package" server-dry-run /ok
write_stale_finalizer "$dry_run_airgap_install_package" airgap-install-substrates
expect_fail_matching dry_run_airgap_install_run 'currently supports only online/use_existing, online/install_substrates, airgap/use_existing, or airgap/install_substrates with mode apply' \
  run_airgap_operator_inputs "$dry_run_airgap_install_package" dry-run-airgap-install
assert_no_path_evidence "$dry_run_airgap_install_package" airgap-install-substrates
pass "operator-inputs --run rejects airgap/install_substrates server-dry-run and clears stale path evidence"

positive_airgap_install_package="$TMP_DIR/positive-airgap-install"
prepare_airgap_install_package "$positive_airgap_install_package" apply /ok
make_operator_facing_target_prerequisites "$positive_airgap_install_package"
make_operator_facing_install_inputs "$positive_airgap_install_package"
write_stale_finalizer "$positive_airgap_install_package" airgap-install-substrates
if ! run_airgap_operator_inputs "$positive_airgap_install_package" positive-airgap-install >"$TMP_DIR/positive-airgap-install.out" 2>"$TMP_DIR/positive-airgap-install.err"; then
  cat "$TMP_DIR/positive-airgap-install.out" >&2
  cat "$TMP_DIR/positive-airgap-install.err" >&2
  fail "airgap/install_substrates positive run failed"
fi
assert_airgap_install_path_evidence "$positive_airgap_install_package" materialized
pass "operator-inputs --run executes airgap/install_substrates apply with operator-facing prerequisites and install inputs"

missing_smoke_airgap_package="$TMP_DIR/missing-smoke-airgap"
prepare_airgap_package "$missing_smoke_airgap_package" apply /ok
"$NODE_BIN" --input-type=module - "$missing_smoke_airgap_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
delete manifest.smoke_url;
delete manifest.expected_status;
delete manifest.timeout_ms;
delete manifest.allow_http;
delete manifest.allow_localhost;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
write_stale_finalizer "$missing_smoke_airgap_package" airgap-use-existing
expect_fail_matching missing_smoke_airgap 'missing required operator-inputs field for airgap/use_existing: smoke_url' \
  run_airgap_operator_inputs "$missing_smoke_airgap_package" missing-smoke-airgap
assert_no_path_evidence "$missing_smoke_airgap_package" airgap-use-existing
pass "operator-inputs airgap path requires smoke_url at intake and clears stale finalizer evidence"

wrong_install_digest_package="$TMP_DIR/wrong-install-digest"
prepare_online_install_package "$wrong_install_digest_package" apply /ok wrong
expect_fail_matching wrong_install_digest 'install_confirmation.install_parameters_sha256 must match computed install parameters sha256' \
  run_operator_inputs "$wrong_install_digest_package" wrong-install-digest
[[ ! -e "$wrong_install_digest_package/.release-kit-internal/online-install-substrates/online-deployment-gate/online-deployment-gate-report.json" ]] ||
  fail "wrong install confirmation digest must stop before online gate"
assert_no_path_evidence "$wrong_install_digest_package" online-install-substrates
pass "operator-inputs --run stops before gate/finalizer on wrong install confirmation digest"

wrong_airgap_install_digest_package="$TMP_DIR/wrong-airgap-install-digest"
prepare_airgap_install_package "$wrong_airgap_install_digest_package" apply /ok wrong
expect_fail_matching wrong_airgap_install_digest 'install_confirmation.install_parameters_sha256 must match computed install parameters sha256' \
  run_airgap_operator_inputs "$wrong_airgap_install_digest_package" wrong-airgap-install-digest
[[ ! -e "$wrong_airgap_install_digest_package/.release-kit-internal/airgap-install-substrates/airgap-deployment-gate/airgap-deployment-gate-report.json" ]] ||
  fail "wrong airgap install confirmation digest must stop before airgap gate"
assert_no_path_evidence "$wrong_airgap_install_digest_package" airgap-install-substrates
pass "operator-inputs --run stops before airgap gate/finalizer on wrong install confirmation digest"

plan_bypass_package="$TMP_DIR/plan-bypass-online"
prepare_online_package "$plan_bypass_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$plan_bypass_package" >/dev/null
expect_fail_matching plan_bypass 'plan is not accepted' \
  "$NODE_BIN" "$ROOT_DIR/scripts/run-operator-inputs.mjs" \
    --plan "$plan_bypass_package/.release-kit-internal/operator-inputs-plan.json"
assert_no_path_evidence "$plan_bypass_package"
pass "operator-inputs run helper rejects external plan files"

internal_symlink_package="$TMP_DIR/internal-symlink-online"
prepare_online_package "$internal_symlink_package" apply /ok
outside_internal="$TMP_DIR/outside-internal-output"
mkdir -p "$outside_internal"
ln -s "$outside_internal" "$internal_symlink_package/.release-kit-internal"
expect_fail_matching internal_symlink_run 'internal output root must not be a symlink' \
  run_operator_inputs "$internal_symlink_package" internal-symlink
if find "$outside_internal" -mindepth 1 -print -quit | grep -q .; then
  fail "operator-inputs run must not write through .release-kit-internal symlink"
fi
pass "operator-inputs --run rejects .release-kit-internal symlink output escape"

plan_leaf_symlink_package="$TMP_DIR/plan-leaf-symlink-online"
prepare_online_package "$plan_leaf_symlink_package" apply /ok
outside_plan="$TMP_DIR/outside-run-plan-leaf.json"
printf '%s\n' '{"outside":true}' >"$outside_plan"
mkdir -p "$plan_leaf_symlink_package/.release-kit-internal"
ln -s "$outside_plan" "$plan_leaf_symlink_package/.release-kit-internal/operator-inputs-plan.json"
expect_fail_matching plan_leaf_symlink_run 'operator-inputs plan output must not be a symlink' \
  run_operator_inputs "$plan_leaf_symlink_package" plan-leaf-symlink
if [[ "$(cat "$outside_plan")" != '{"outside":true}' ]]; then
  fail "operator-inputs --run must not modify an outside operator-inputs-plan.json symlink target"
fi
assert_no_path_evidence "$plan_leaf_symlink_package"
pass "operator-inputs --run rejects operator-inputs-plan.json symlink output escape"

producer_fail_package="$TMP_DIR/producer-fail-online"
prepare_online_package "$producer_fail_package" apply /missing
write_stale_finalizer "$producer_fail_package"
expect_fail_matching producer_fail 'operator-inputs producer online-deployment-gate failed' \
  run_operator_inputs "$producer_fail_package" producer-fail
assert_no_path_evidence "$producer_fail_package"
pass "operator-inputs producer failure does not leave stale path finalizer evidence"

install_gate_fail_package="$TMP_DIR/install-gate-fail-online"
prepare_online_install_package "$install_gate_fail_package" apply /missing
write_stale_finalizer "$install_gate_fail_package" online-install-substrates
expect_fail_matching install_gate_fail 'operator-inputs producer online-deployment-gate failed' \
  run_operator_inputs "$install_gate_fail_package" install-gate-fail
[[ -f "$install_gate_fail_package/.release-kit-internal/online-install-substrates/substrate-install/substrate-install-report.json" ]] ||
  fail "install gate failure fixture should prove substrate install completed before gate failure"
assert_no_path_evidence "$install_gate_fail_package" online-install-substrates
pass "operator-inputs install path gate failure clears stale finalizer evidence"

airgap_smoke_fail_package="$TMP_DIR/airgap-smoke-fail"
prepare_airgap_package "$airgap_smoke_fail_package" apply /missing
write_stale_finalizer "$airgap_smoke_fail_package" airgap-use-existing
expect_fail_matching airgap_smoke_fail 'operator-inputs producer airgap-consume-rehearsal failed' \
  run_airgap_operator_inputs "$airgap_smoke_fail_package" airgap-smoke-fail
assert_no_path_evidence "$airgap_smoke_fail_package" airgap-use-existing
pass "operator-inputs airgap producer smoke failure clears stale finalizer evidence"

tampered_plan_package="$TMP_DIR/tampered-plan-order"
prepare_online_install_package "$tampered_plan_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_plan_package" >/dev/null
FAKE_KUBECTL_LOG="$TMP_DIR/tampered-plan-kubectl.log" \
  tamper_plan_swap_producers "$tampered_plan_package"
assert_no_path_evidence "$tampered_plan_package" online-install-substrates
pass "operator-inputs runner rejects tampered install producer order through direct library invocation"

tampered_airgap_truth_package="$TMP_DIR/tampered-airgap-install-truth"
prepare_airgap_install_package "$tampered_airgap_truth_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_truth_package" >/dev/null
tamper_airgap_install_gate_substrate_truth_to_bundle "$tampered_airgap_truth_package"
assert_no_path_evidence "$tampered_airgap_truth_package" airgap-install-substrates
pass "operator-inputs runner rejects airgap install gate bound to bundle-local substrate truth"

direct_plan_digest_mismatch_package="$TMP_DIR/direct-plan-digest-mismatch"
prepare_online_package "$direct_plan_digest_mismatch_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_plan_digest_mismatch_package" >/dev/null
write_stale_finalizer "$direct_plan_digest_mismatch_package"
tamper_direct_plan_digest_without_update "$direct_plan_digest_mismatch_package"
run_direct_plan_expect_fail \
  "$direct_plan_digest_mismatch_package" \
  'operator-inputs plan digest mismatch'
assert_no_path_evidence "$direct_plan_digest_mismatch_package"
pass "operator-inputs direct runner clears stale path evidence before plan digest validation"

direct_broken_facade_argv_package="$TMP_DIR/direct-broken-facade-argv"
prepare_online_package "$direct_broken_facade_argv_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_broken_facade_argv_package" >/dev/null
write_stale_finalizer "$direct_broken_facade_argv_package"
tamper_direct_plan_facade_argv "$direct_broken_facade_argv_package"
run_direct_plan_expect_fail \
  "$direct_broken_facade_argv_package" \
  'plan.facade_argv must replay through scripts/operator-release.sh --operator-inputs'
assert_no_path_evidence "$direct_broken_facade_argv_package"
pass "operator-inputs direct runner clears stale path evidence before facade argv validation"

direct_drift_ref_package="$TMP_DIR/direct-drift-ref"
prepare_online_package "$direct_drift_ref_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_drift_ref_package" >/dev/null
write_stale_finalizer "$direct_drift_ref_package"
printf '%s\n' '{"drift":true}' >"$direct_drift_ref_package/release-contract.json"
run_direct_plan_expect_fail \
  "$direct_drift_ref_package" \
  'input ref digest changed after plan generation: release_contract'
assert_no_path_evidence "$direct_drift_ref_package"
pass "operator-inputs direct runner clears stale path evidence before ref digest validation"

direct_missing_ref_package="$TMP_DIR/direct-missing-ref"
prepare_online_package "$direct_missing_ref_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_missing_ref_package" >/dev/null
write_stale_finalizer "$direct_missing_ref_package"
rm "$direct_missing_ref_package/release-contract.json"
run_direct_plan_expect_fail \
  "$direct_missing_ref_package" \
  'cannot read plan.input_refs.release_contract.absolute_path'
assert_no_path_evidence "$direct_missing_ref_package"
pass "operator-inputs direct runner clears stale path evidence before missing ref validation"

direct_mode_drift_package="$TMP_DIR/direct-mode-drift"
prepare_airgap_package "$direct_mode_drift_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_mode_drift_package" >/dev/null
write_stale_finalizer "$direct_mode_drift_package" airgap-use-existing
"$NODE_BIN" --input-type=module - "$direct_mode_drift_package" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [packageDir] = process.argv.slice(2);
const planPath = path.join(packageDir, '.release-kit-internal/operator-inputs-plan.json');
const manifestPath = path.join(packageDir, 'operator-inputs.json');
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

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

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

manifest.mode = 'server-dry-run';
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
plan.package.manifest_sha256 = digestBuffer(fs.readFileSync(manifestPath));
plan.plan_sha256 = null;
plan.plan_sha256 = digestBuffer(Buffer.from(JSON.stringify(stableJson(plan))));
fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);
NODE
run_direct_plan_expect_fail \
  "$direct_mode_drift_package" \
  'operator-inputs --run does not support input ref for airgap/use_existing: archive_probe'
assert_no_path_evidence "$direct_mode_drift_package" airgap-use-existing
pass "operator-inputs direct runner clears stale path evidence before mode drift allowed-set validation"

direct_manifest_extra_reserved_ref_package="$TMP_DIR/direct-manifest-extra-reserved-ref"
prepare_online_package "$direct_manifest_extra_reserved_ref_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_manifest_extra_reserved_ref_package" >/dev/null
write_stale_finalizer "$direct_manifest_extra_reserved_ref_package"
extra_reserved_ref_path="$(deployment_path_dir "$direct_manifest_extra_reserved_ref_package")/source-evidence/airgap-bundle-manifest.json"
cp "$direct_manifest_extra_reserved_ref_package/release-contract.json" "$extra_reserved_ref_path"
"$NODE_BIN" --input-type=module - "$direct_manifest_extra_reserved_ref_package/operator-inputs.json" <<'NODE'
import fs from 'node:fs';

const [manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
manifest.airgap_bundle_manifest =
  '.release-kit-internal/online-use-existing/deployment-path/source-evidence/airgap-bundle-manifest.json';
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
run_direct_plan_expect_fail \
  "$direct_manifest_extra_reserved_ref_package" \
  'reserved operator-inputs output tree'
[[ -f "$extra_reserved_ref_path" ]] ||
  fail "operator-inputs direct runner must not delete extra reserved-tree manifest ref before cleanup"
[[ -f "$(deployment_path_dir "$direct_manifest_extra_reserved_ref_package")/source-evidence/stale-report.json" ]] ||
  fail "extra manifest reserved-tree ref must fail before stale evidence cleanup"
pass "operator-inputs direct runner scans manifest refs absent from plan before stale cleanup"

direct_non_executable_command_package="$TMP_DIR/direct-non-executable-command"
prepare_online_package "$direct_non_executable_command_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$direct_non_executable_command_package" >/dev/null
write_stale_finalizer "$direct_non_executable_command_package"
chmod 0644 "$direct_non_executable_command_package/tools/kubectl"
run_direct_plan_expect_fail \
  "$direct_non_executable_command_package" \
  'plan.input_refs.kubectl.absolute_path must be executable'
assert_no_path_evidence "$direct_non_executable_command_package"
pass "operator-inputs direct runner clears stale path evidence before command executable validation"

tampered_manifest_path_package="$TMP_DIR/tampered-manifest-path"
prepare_online_package "$tampered_manifest_path_package" apply /ok
mkdir -p "$tampered_manifest_path_package/alternate"
write_truth "$tampered_manifest_path_package/alternate/substrate-truth.json" "$KIT_ONLINE_TARGET_PROFILE"
write_prerequisites "$tampered_manifest_path_package/alternate/target-prerequisites.json" "$KIT_ONLINE_TARGET_PROFILE"
write_substrate_install_materials "$tampered_manifest_path_package/alternate" "$KIT_ONLINE_TARGET_PROFILE"
write_fake_routability_probe "$tampered_manifest_path_package/tools/routability-probe"
"$NODE_BIN" --input-type=module - \
  "$tampered_manifest_path_package/alternate-operator-inputs.json" \
  "http://127.0.0.1:$SERVER_PORT/ok" <<'NODE'
import fs from 'node:fs';

const [output, smokeUrl] = process.argv.slice(2);
const manifest = {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: 'online/install_substrates',
  release_contract: 'release-contract.json',
  deploy_template_package: 'deploy-template-package.json',
  deploy_template_archive: 'deploy-template-package.tgz',
  render_values: 'render-values.json',
  target_prerequisites: 'alternate/target-prerequisites.json',
  substrate_pack_manifest: 'alternate/substrate-pack-manifest.json',
  substrate_install_inputs: 'alternate/substrate-install-inputs.json',
  namespace: 'agentsmith',
  mode: 'apply',
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context',
  routability_probe: 'tools/routability-probe',
  install_confirmation: {
    confirmed: true,
    confirm_current_install_parameters: true,
    operator_run_id: 'operator-inputs-alt-install-1001'
  },
  deploy_confirmation: {
    confirmed: true,
    operator_run_id: 'operator-inputs-alt-online-install-apply-1001'
  },
  smoke_url: smokeUrl,
  expected_status: 200,
  timeout: '60s',
  timeout_ms: 5000,
  allow_http: true,
  allow_localhost: true
};

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_manifest_path_package" >/dev/null
write_stale_finalizer "$tampered_manifest_path_package" online-use-existing
write_stale_finalizer "$tampered_manifest_path_package" online-install-substrates
tamper_plan_manifest_path \
  "$tampered_manifest_path_package" \
  "$tampered_manifest_path_package/alternate-operator-inputs.json" \
  'plan.package.manifest_relative_path must resolve to plan.package.manifest_path'
[[ -f "$(deployment_path_dir "$tampered_manifest_path_package" online-install-substrates)/source-evidence/stale-report.json" ]] ||
  fail "tampered plan manifest_path must not clean unrelated known path"
pass "operator-inputs direct runner binds manifest_path to manifest_relative_path before stale cleanup"

tampered_deployment_path_package="$TMP_DIR/tampered-deployment-path"
prepare_online_install_package "$tampered_deployment_path_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_deployment_path_package" >/dev/null
write_stale_finalizer "$tampered_deployment_path_package" online-install-substrates
write_stale_finalizer "$tampered_deployment_path_package" online-use-existing
tamper_plan_deployment_path \
  "$tampered_deployment_path_package" \
  online/use_existing \
  'plan.deployment_path must match operator-inputs manifest.deployment_path'
[[ -f "$(deployment_path_dir "$tampered_deployment_path_package" online-install-substrates)/source-evidence/stale-report.json" ]] ||
  fail "tampered plan deployment_path must fail before manifest path cleanup"
[[ -f "$(deployment_path_dir "$tampered_deployment_path_package" online-use-existing)/source-evidence/stale-report.json" ]] ||
  fail "tampered plan deployment_path must not clean unrelated known path"
pass "operator-inputs runner binds deployment_path before stale cleanup"

tampered_reserved_ref_package="$TMP_DIR/tampered-reserved-ref"
prepare_online_package "$tampered_reserved_ref_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_reserved_ref_package" >/dev/null
write_stale_finalizer "$tampered_reserved_ref_package"
tampered_reserved_ref_path="$(deployment_path_dir "$tampered_reserved_ref_package")/source-evidence/release-contract-input.json"
tamper_plan_ref_to_copy \
  "$tampered_reserved_ref_package" \
  release_contract \
  "$tampered_reserved_ref_path" \
  update-manifest \
  'reserved operator-inputs output tree'
[[ -f "$tampered_reserved_ref_path" ]] ||
  fail "operator-inputs direct runner must not delete reserved-tree input before ref validation"
[[ -f "$(deployment_path_dir "$tampered_reserved_ref_package")/source-evidence/stale-report.json" ]] ||
  fail "operator-inputs direct runner must fail before unsafe reserved-tree cleanup"
pass "operator-inputs direct runner rejects reserved output refs before stale cleanup"

tampered_outside_package_ref="$TMP_DIR/tampered-outside-package-ref"
prepare_online_package "$tampered_outside_package_ref" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_outside_package_ref" >/dev/null
write_stale_finalizer "$tampered_outside_package_ref"
tamper_plan_ref_to_copy \
  "$tampered_outside_package_ref" \
  release_contract \
  "$TMP_DIR/outside-package-release-contract-copy.json" \
  keep-manifest \
  'plan.input_refs.release_contract.absolute_path must resolve inside operator-inputs package'
[[ -f "$(deployment_path_dir "$tampered_outside_package_ref")/source-evidence/stale-report.json" ]] ||
  fail "operator-inputs direct runner must fail before cleanup when a plan ref escapes the package"
pass "operator-inputs runner rejects plan refs moved outside the package before stale cleanup"

tampered_airgap_release_contract_ref="$TMP_DIR/tampered-airgap-release-contract-ref"
prepare_airgap_package "$tampered_airgap_release_contract_ref" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_release_contract_ref" >/dev/null
write_stale_finalizer "$tampered_airgap_release_contract_ref" airgap-use-existing
tamper_plan_ref_to_copy \
  "$tampered_airgap_release_contract_ref" \
  release_contract \
  "$tampered_airgap_release_contract_ref/release-contract-copy.json" \
  update-manifest \
  'release_contract must match airgap_bundle_manifest.components.release_contract.path'
assert_no_path_evidence "$tampered_airgap_release_contract_ref" airgap-use-existing
pass "operator-inputs runner rejects airgap release_contract refs outside bundle components with unchanged digest"

tampered_airgap_deploy_template_ref="$TMP_DIR/tampered-airgap-deploy-template-ref"
prepare_airgap_package "$tampered_airgap_deploy_template_ref" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_deploy_template_ref" >/dev/null
write_stale_finalizer "$tampered_airgap_deploy_template_ref" airgap-use-existing
tamper_plan_ref_to_copy \
  "$tampered_airgap_deploy_template_ref" \
  deploy_template_package \
  "$tampered_airgap_deploy_template_ref/deploy-template-package-copy.json" \
  update-manifest \
  'deploy_template_package must match airgap_bundle_manifest.components.deploy_template_package.path'
assert_no_path_evidence "$tampered_airgap_deploy_template_ref" airgap-use-existing
pass "operator-inputs runner rejects airgap deploy_template_package refs outside bundle components with unchanged digest"

tampered_airgap_substrate_pack_manifest_ref="$TMP_DIR/tampered-airgap-substrate-pack-manifest-ref"
prepare_airgap_install_package "$tampered_airgap_substrate_pack_manifest_ref" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_substrate_pack_manifest_ref" >/dev/null
write_stale_finalizer "$tampered_airgap_substrate_pack_manifest_ref" airgap-install-substrates
tamper_plan_ref_to_copy \
  "$tampered_airgap_substrate_pack_manifest_ref" \
  substrate_pack_manifest \
  "$tampered_airgap_substrate_pack_manifest_ref/substrate-pack-manifest-copy.json" \
  update-manifest \
  'substrate_pack_manifest must match airgap_bundle_manifest.components.substrate_pack_manifest.path' \
  --substrate-pack-manifest
assert_no_path_evidence "$tampered_airgap_substrate_pack_manifest_ref" airgap-install-substrates
pass "operator-inputs runner rejects airgap install substrate_pack_manifest refs outside bundle components with updated argv"

tampered_airgap_target_prerequisites_ref="$TMP_DIR/tampered-airgap-target-prerequisites-ref"
prepare_airgap_package "$tampered_airgap_target_prerequisites_ref" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_target_prerequisites_ref" >/dev/null
write_stale_finalizer "$tampered_airgap_target_prerequisites_ref" airgap-use-existing
tamper_plan_ref_to_copy \
  "$tampered_airgap_target_prerequisites_ref" \
  target_prerequisites \
  "$tampered_airgap_target_prerequisites_ref/target-prerequisites-copy.json" \
  update-manifest \
  'plan.input_refs.target_prerequisites.absolute_path must resolve inside airgap_bundle'
assert_no_path_evidence "$tampered_airgap_target_prerequisites_ref" airgap-use-existing
pass "operator-inputs runner rejects airgap target_prerequisites refs outside bundle"

tampered_airgap_install_inputs_ref="$TMP_DIR/tampered-airgap-install-inputs-ref"
prepare_airgap_install_package "$tampered_airgap_install_inputs_ref" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_install_inputs_ref" >/dev/null
write_stale_finalizer "$tampered_airgap_install_inputs_ref" airgap-install-substrates
tamper_plan_ref_to_copy \
  "$tampered_airgap_install_inputs_ref" \
  substrate_install_inputs \
  "$tampered_airgap_install_inputs_ref/substrate-install-inputs-copy.json" \
  update-manifest \
  'substrate_install_inputs must match airgap_bundle_manifest.components.substrate_install_inputs.path'
assert_no_path_evidence "$tampered_airgap_install_inputs_ref" airgap-install-substrates
pass "operator-inputs runner rejects airgap install substrate_install_inputs refs outside bundle"

tampered_airgap_bundle_root_package="$TMP_DIR/tampered-airgap-bundle-root"
prepare_airgap_package "$tampered_airgap_bundle_root_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_bundle_root_package" >/dev/null
tamper_airgap_plan_arg \
  "$tampered_airgap_bundle_root_package" \
  --bundle-root \
  "$tampered_airgap_bundle_root_package" \
  'airgap-consume-rehearsal --bundle-root must match plan expected value'
assert_no_path_evidence "$tampered_airgap_bundle_root_package" airgap-use-existing
pass "operator-inputs runner rejects tampered airgap bundle root argv"

tampered_airgap_bundle_manifest_package="$TMP_DIR/tampered-airgap-bundle-manifest"
prepare_airgap_package "$tampered_airgap_bundle_manifest_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_bundle_manifest_package" >/dev/null
tamper_airgap_plan_arg \
  "$tampered_airgap_bundle_manifest_package" \
  --bundle-manifest \
  "$tampered_airgap_bundle_manifest_package/bundle/components/release-contract.json" \
  'airgap-consume-rehearsal --bundle-manifest must match plan expected value'
assert_no_path_evidence "$tampered_airgap_bundle_manifest_package" airgap-use-existing
pass "operator-inputs runner rejects tampered airgap bundle manifest argv"

tampered_airgap_kubectl_package="$TMP_DIR/tampered-airgap-kubectl"
prepare_airgap_package "$tampered_airgap_kubectl_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_kubectl_package" >/dev/null
tamper_airgap_plan_arg \
  "$tampered_airgap_kubectl_package" \
  --kubectl \
  "$tampered_airgap_kubectl_package/tools/archive-probe" \
  'airgap-consume-rehearsal --kubectl must match plan expected value'
assert_no_path_evidence "$tampered_airgap_kubectl_package" airgap-use-existing
pass "operator-inputs runner rejects tampered airgap kubectl argv"

tampered_airgap_context_package="$TMP_DIR/tampered-airgap-context"
prepare_airgap_package "$tampered_airgap_context_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_airgap_context_package" >/dev/null
tamper_airgap_plan_arg \
  "$tampered_airgap_context_package" \
  --context \
  other-context \
  'airgap-consume-rehearsal --context must match plan expected value'
assert_no_path_evidence "$tampered_airgap_context_package" airgap-use-existing
pass "operator-inputs runner rejects tampered airgap context argv"

pass "operator-inputs orchestration focused tests completed"
