#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
FIXTURE_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
FIXTURE_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
KIT_ONLINE_TARGET_PROFILE="existing_kubernetes/kit_installed/online"

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

  "$NODE_BIN" --input-type=module - \
    "$FIXTURE_CONTRACT" \
    "$FIXTURE_DEPLOY_TEMPLATE_PACKAGE" \
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

  "$NODE_BIN" --input-type=module - "$package_dir" "$profile" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [packageDir, profile] = process.argv.slice(2);
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

writeJson(path.join(packageDir, 'substrate-pack-manifest.json'), {
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
      sha256: digest('6')
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
      sha256: digest('7')
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
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "get" ]]; then
      get_target="$arg"
    fi
    previous="$arg"
  done

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
    live_image="ghcr.io/agentsmith-project/agentsmith-app:2026.05.23-p0@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    live_image_id="docker-pullable://ghcr.io/agentsmith-project/agentsmith-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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
  kubectl: 'tools/kubectl'
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
  substrate_truth: 'substrate-truth.json',
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
    install_parameters_sha256: installParametersSha256,
    operator_run_id: 'operator-inputs-install-1001'
  }
};

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
  write_fake_routability_probe "$package_dir/tools/routability-probe"

  local install_parameters_sha256
  if [[ "$install_digest_mode" == "valid" ]]; then
    install_parameters_sha256="$(install_parameters_digest "$package_dir/substrate-install-inputs.json" agentsmith)"
  else
    install_parameters_sha256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fi
  write_online_install_operator_inputs "$package_dir" "$mode" "$install_parameters_sha256" "$smoke_path"
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
  ['deploy-template-package.tgz', 'bundle/components/deploy-template-package.tgz'],
  ['image-map.json', 'bundle/components/image-map.json'],
  ['substrate-pack-manifest.json', 'bundle/components/substrate-pack-manifest.json'],
  ['render-values.json', 'bundle/operator-inputs/render-values.json'],
  ['substrate-truth.json', 'bundle/operator-inputs/substrate-truth.json'],
  ['target-prerequisites.json', 'bundle/operator-inputs/target-prerequisites.json'],
  ['substrate-install-inputs.json', 'bundle/operator-inputs/substrate-install-inputs.json']
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
    component('deploy_template_archive', 'components/deploy-template-package.tgz'),
    component('image_map', 'components/image-map.json'),
    component('substrate_pack_manifest', 'components/substrate-pack-manifest.json')
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
  deploy_template_archive: 'bundle/components/deploy-template-package.tgz',
  render_values: 'bundle/operator-inputs/render-values.json',
  substrate_truth: 'bundle/operator-inputs/substrate-truth.json',
  target_prerequisites: 'bundle/operator-inputs/target-prerequisites.json',
  substrate_pack_manifest: 'bundle/components/substrate-pack-manifest.json',
  substrate_install_inputs: 'bundle/operator-inputs/substrate-install-inputs.json',
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
    install_parameters_sha256: `sha256:${'a'.repeat(64)}`,
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

run_operator_inputs() {
  local package_dir="$1"
  local label="$2"
  FAKE_KUBECTL_LOG="$TMP_DIR/$label-kubectl.log" \
    bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$package_dir" --run
}

start_server

positive_package="$TMP_DIR/positive-online"
prepare_online_package "$positive_package" apply /ok
run_operator_inputs "$positive_package" positive >"$TMP_DIR/positive.out" 2>"$TMP_DIR/positive.err"
assert_path_evidence "$positive_package"
pass "operator-inputs --run executes online/use_existing apply and finalizes path evidence"

positive_install_package="$TMP_DIR/positive-online-install"
prepare_online_install_package "$positive_install_package" apply /ok
run_operator_inputs "$positive_install_package" positive-install >"$TMP_DIR/positive-install.out" 2>"$TMP_DIR/positive-install.err"
assert_install_path_evidence "$positive_install_package"
pass "operator-inputs --run executes online/install_substrates apply and finalizes path evidence"

dry_run_package="$TMP_DIR/dry-run-online"
prepare_online_package "$dry_run_package" server-dry-run /ok
expect_fail_matching dry_run_run 'currently supports only online/use_existing or online/install_substrates with mode apply' \
  run_operator_inputs "$dry_run_package" dry-run
assert_no_path_evidence "$dry_run_package"
pass "operator-inputs --run rejects server-dry-run without path evidence"

dry_run_install_package="$TMP_DIR/dry-run-online-install"
prepare_online_install_package "$dry_run_install_package" server-dry-run /ok
expect_fail_matching dry_run_install_run 'currently supports only online/use_existing or online/install_substrates with mode apply' \
  run_operator_inputs "$dry_run_install_package" dry-run-install
assert_no_path_evidence "$dry_run_install_package" online-install-substrates
pass "operator-inputs --run rejects online/install_substrates server-dry-run"

airgap_install_package="$TMP_DIR/airgap-install"
mkdir -p "$airgap_install_package"
write_minimal_airgap_install_package "$airgap_install_package"
expect_fail_matching airgap_install_run 'currently supports only online/use_existing or online/install_substrates with mode apply' \
  bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$airgap_install_package" --run
if find "$airgap_install_package/.release-kit-internal" -name deployment-path-report.json -print -quit | grep -q .; then
  fail "unsupported airgap/install_substrates run must not write a deployment path report"
fi
pass "operator-inputs --run fail-fasts unsupported airgap/install_substrates"

wrong_install_digest_package="$TMP_DIR/wrong-install-digest"
prepare_online_install_package "$wrong_install_digest_package" apply /ok wrong
expect_fail_matching wrong_install_digest 'confirm-install-parameters must match the substrate install parameters sha256' \
  run_operator_inputs "$wrong_install_digest_package" wrong-install-digest
[[ ! -e "$wrong_install_digest_package/.release-kit-internal/online-install-substrates/online-deployment-gate/online-deployment-gate-report.json" ]] ||
  fail "wrong install confirmation digest must stop before online gate"
assert_no_path_evidence "$wrong_install_digest_package" online-install-substrates
pass "operator-inputs --run stops before gate/finalizer on wrong install confirmation digest"

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

tampered_plan_package="$TMP_DIR/tampered-plan-order"
prepare_online_install_package "$tampered_plan_package" apply /ok
bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$tampered_plan_package" >/dev/null
FAKE_KUBECTL_LOG="$TMP_DIR/tampered-plan-kubectl.log" \
  tamper_plan_swap_producers "$tampered_plan_package"
assert_no_path_evidence "$tampered_plan_package" online-install-substrates
pass "operator-inputs runner rejects tampered install producer order through direct library invocation"

pass "operator-inputs orchestration focused tests completed"
