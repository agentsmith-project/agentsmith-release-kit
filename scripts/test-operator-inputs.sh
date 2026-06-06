#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
EXAMPLE_ONLINE_DIR="$ROOT_DIR/examples/online-existing-kubernetes"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

write_package_files() {
  local package_dir="$1"

  mkdir -p "$package_dir/tools" "$package_dir/bundle"
  cat >"$package_dir/release-contract.json" <<'JSON'
{
  "schema_version": "fixture.release-contract/v1",
  "release_id": "operator-inputs-test"
}
JSON
  cat >"$package_dir/deploy-template-package.json" <<'JSON'
{
  "schema_version": "fixture.deploy-template-package/v1"
}
JSON
  printf '%s\n' "deploy template archive fixture" >"$package_dir/deploy-template-package.tgz"
  cat >"$package_dir/image-map.json" <<'JSON'
{
  "schema_version": "fixture.image-map/v1"
}
JSON
  cat >"$package_dir/render-values.json" <<'JSON'
{
  "namespace": "agentsmith"
}
JSON
  cat >"$package_dir/substrate-truth.json" <<'JSON'
{
  "schema_version": "fixture.substrate-truth/v1"
}
JSON
  cat >"$package_dir/target-prerequisites.json" <<'JSON'
{
  "schema_version": "fixture.target-prerequisites/v1"
}
JSON
  cat >"$package_dir/substrate-pack-manifest.json" <<'JSON'
{
  "schema_version": "fixture.substrate-pack-manifest/v1"
}
JSON
  cat >"$package_dir/substrate-install-inputs.json" <<'JSON'
{
  "schema_version": "fixture.substrate-install-inputs/v1"
}
JSON
  cat >"$package_dir/bundle/airgap-bundle-manifest.json" <<'JSON'
{
  "schema_version": "agentsmith.airgap-bundle-manifest/v1",
  "target_profile": {
    "value": "existing_kubernetes/external_declared/airgap",
    "target_cluster": "existing_kubernetes",
    "substrate_source": "external_declared",
    "distribution": "airgap"
  },
  "substrate": {
    "mode": "external_declared",
    "bundled": false
  }
}
JSON
  for tool in kubectl archive-probe image-loader routability-probe registry-probe; do
    cat >"$package_dir/tools/$tool" <<'SH'
#!/usr/bin/env sh
exit 0
SH
    chmod +x "$package_dir/tools/$tool"
  done
}

write_manifest() {
  local package_dir="$1"
  local deployment_path="$2"
  local mode="${3:-}"

"$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" "$deployment_path" "$mode" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [output, deploymentPath, mode] = process.argv.slice(2);
const packageRoot = path.dirname(output);
const installsSubstrates = deploymentPath.endsWith('/install_substrates');

function targetProfileObject(value) {
  const [targetCluster, substrateSource, distribution] = value.split('/');
  return {
    value,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function copyPackageFileIntoBundle(sourceRelativePath, bundleRelativePath) {
  const source = path.join(packageRoot, sourceRelativePath);
  const destination = path.join(packageRoot, 'bundle', bundleRelativePath);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
  return `bundle/${bundleRelativePath}`;
}

function bundleComponent(kind, bundleRelativePath) {
  return {
    kind,
    path: bundleRelativePath,
    sha256: digestFile(path.join(packageRoot, 'bundle', bundleRelativePath))
  };
}

function writeAirgapBundleManifest(profileValue, components) {
  const profile = targetProfileObject(profileValue);
  const bundleManifest = {
    schema_version: 'agentsmith.airgap-bundle-manifest/v1',
    target_profile: profile,
    components,
    substrate: {
      mode: profile.substrate_source,
      bundled: profile.substrate_source === 'kit_installed'
    }
  };
  fs.writeFileSync(
    path.join(path.dirname(output), 'bundle/airgap-bundle-manifest.json'),
    `${JSON.stringify(bundleManifest, null, 2)}\n`
  );
}

function writeSubstrateInstallInputs(profileValue) {
  const profile = targetProfileObject(profileValue);
  const installationId = `operator-inputs-${profile.distribution}-install`;
  const serviceReachability = {
    status: 'declared_reachable',
    proof: 'operator-inputs fixture proof'
  };
  const substrateTruth = {
    schema_version: 'agentsmith.substrate-connection.truth/v1',
    target_cluster: profile.target_cluster,
    substrate_source: profile.substrate_source,
    distribution: profile.distribution,
    declared_at: '2026-05-23T12:00:00.000Z',
    declared_by: 'release-operator@example.com',
    installed_by: 'agentsmith-release-kit',
    release_kit_version: '0.1.0',
    installation_id: installationId,
    services: {
      postgresql: {
        host: 'postgresql.agentsmith.svc',
        port: 5432,
        database: 'agentsmith',
        credential_secret_ref: 'secretRef:agentsmith/postgresql-app',
        admin_secret_ref: 'secretRef:agentsmith/postgresql-admin',
        sslmode: 'verify-full',
        reachability: serviceReachability,
        extensions: {
          pgvector: {
            status: 'installed',
            version: '0.7.4'
          }
        }
      },
      mongodb: {
        host: 'mongodb.agentsmith.svc',
        port: 27017,
        credential_secret_ref: 'secretRef:agentsmith/mongodb-app',
        tls: { mode: 'verify-full' },
        reachability: serviceReachability
      },
      redis: {
        host: 'redis.agentsmith.svc',
        port: 6379,
        credential_secret_ref: 'secretRef:agentsmith/redis-app',
        tls: { mode: 'verify-full' },
        reachability: serviceReachability
      },
      object_storage: {
        url: 'https://objects.agentsmith.example.com',
        bucket: 'agentsmith-release-artifacts',
        region: 'us-west-2',
        credential_secret_ref: 'secretRef:agentsmith/object-storage-app',
        tls: { mode: 'https' },
        reachability: serviceReachability
      },
      oidc: {
        issuer_url: 'https://oidc.agentsmith.example.com/realms/agentsmith',
        client_id: 'agentsmith-web',
        client_secret_ref: 'secretRef:agentsmith/oidc-client',
        tls: { mode: 'https' },
        reachability: serviceReachability
      }
    }
  };
  const installInputs = {
    schema_version: 'agentsmith.substrate-install-inputs/v1',
    target_profile: profileValue,
    installation_id: installationId,
    substrate_truth: substrateTruth,
    resources: [
      {
        apiVersion: 'v1',
        kind: 'ConfigMap',
        metadata: {
          name: `agentsmith-${profile.distribution}-substrate-endpoints`,
          namespace: 'agentsmith',
          labels: {
            'app.kubernetes.io/managed-by': 'agentsmith-release-kit'
          },
          annotations: {
            'agentsmith.io/managed-by': 'agentsmith-release-kit',
            'agentsmith.io/installation-id': installationId
          }
        },
        data: {
          postgresql_host: 'postgresql.agentsmith.svc'
        }
      }
    ]
  };
  fs.writeFileSync(
    path.join(packageRoot, 'substrate-install-inputs.json'),
    `${JSON.stringify(installInputs, null, 2)}\n`
  );
}

const manifest = {
  schema_version: 'agentsmith.operator-inputs/v1',
  operator_inputs_version: 1,
  deployment_path: deploymentPath,
  release_contract: 'release-contract.json',
  deploy_template_package: 'deploy-template-package.json',
  deploy_template_archive: 'deploy-template-package.tgz',
  render_values: 'render-values.json',
  substrate_truth: 'substrate-truth.json',
  target_prerequisites: 'target-prerequisites.json',
  namespace: 'agentsmith',
  kubectl: 'tools/kubectl',
  context: 'operator-inputs-context'
};

if (mode) {
  manifest.mode = mode;
}

if (mode === 'apply') {
  manifest.deploy_confirmation = {
    confirmed: true,
    operator_run_id: 'operator-inputs-deploy-1001'
  };
  manifest.smoke_url = 'https://release.example/ok';
  manifest.expected_status = 200;
  manifest.timeout = '120s';
  manifest.timeout_ms = 5000;
}

if (installsSubstrates) {
  writeSubstrateInstallInputs(
    deploymentPath.startsWith('airgap/')
      ? 'existing_kubernetes/kit_installed/airgap'
      : 'existing_kubernetes/kit_installed/online'
  );
}

if (deploymentPath.startsWith('airgap/')) {
  manifest.airgap_bundle = 'bundle';
  manifest.airgap_bundle_manifest = 'bundle/airgap-bundle-manifest.json';
  manifest.release_contract = copyPackageFileIntoBundle(
    'release-contract.json',
    'components/release-contract.json'
  );
  manifest.deploy_template_package = copyPackageFileIntoBundle(
    'deploy-template-package.json',
    'components/deploy-template-package.json'
  );
  manifest.deploy_template_archive = copyPackageFileIntoBundle(
    'deploy-template-package.tgz',
    'components/deploy-template-package.tgz'
  );
  copyPackageFileIntoBundle('image-map.json', 'components/image-map.json');
  manifest.render_values = copyPackageFileIntoBundle(
    'render-values.json',
    'operator-inputs/render-values.json'
  );
  if (!installsSubstrates) {
    manifest.substrate_truth = copyPackageFileIntoBundle(
      'substrate-truth.json',
      'operator-inputs/substrate-truth.json'
    );
  }
  manifest.target_prerequisites = copyPackageFileIntoBundle(
    'target-prerequisites.json',
    'operator-inputs/target-prerequisites.json'
  );

  const components = [
    bundleComponent('release_contract', 'components/release-contract.json'),
    bundleComponent('deploy_template_package', 'components/deploy-template-package.json'),
    bundleComponent('deploy_template_archive', 'components/deploy-template-package.tgz'),
    bundleComponent('image_map', 'components/image-map.json')
  ];
  if (installsSubstrates) {
    manifest.substrate_pack_manifest = copyPackageFileIntoBundle(
      'substrate-pack-manifest.json',
      'components/substrate-pack-manifest.json'
    );
    manifest.substrate_install_inputs = copyPackageFileIntoBundle(
      'substrate-install-inputs.json',
      'operator-inputs/substrate-install-inputs.json'
    );
    components.push(
      bundleComponent('substrate_pack_manifest', 'components/substrate-pack-manifest.json')
    );
  }
  writeAirgapBundleManifest(
    installsSubstrates
      ? 'existing_kubernetes/kit_installed/airgap'
      : 'existing_kubernetes/external_declared/airgap',
    components
  );
  if (mode === 'apply') {
    manifest.archive_probe = 'tools/archive-probe';
    manifest.image_loader = 'tools/image-loader';
  }
}

if (installsSubstrates) {
  delete manifest.substrate_truth;
  if (!deploymentPath.startsWith('airgap/')) {
    manifest.substrate_pack_manifest = 'substrate-pack-manifest.json';
    manifest.substrate_install_inputs = 'substrate-install-inputs.json';
    manifest.routability_probe = 'tools/routability-probe';
  }
  manifest.install_confirmation = {
    confirmed: true,
    confirm_current_install_parameters: true,
    operator_run_id: 'operator-inputs-install-1001'
  };
}

fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

copy_valid_package() {
  local source_dir="$1"
  local output_dir="$2"

  cp -R "$source_dir" "$output_dir"
  rm -rf "$output_dir/.release-kit-internal"
}

mutate_manifest() {
  local package_dir="$1"
  local case_name="$2"

"$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" "$case_name" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [manifestPath, caseName] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

function targetProfileObject(value) {
  const [targetCluster, substrateSource, distribution] = value.split('/');
  return {
    value,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function writeAirgapBundleManifest(profileValue) {
  const profile = targetProfileObject(profileValue);
  const bundleManifest = {
    schema_version: 'agentsmith.airgap-bundle-manifest/v1',
    target_profile: profile,
    substrate: {
      mode: profile.substrate_source,
      bundled: profile.substrate_source === 'kit_installed'
    }
  };
  fs.writeFileSync(
    path.join(path.dirname(manifestPath), 'bundle/airgap-bundle-manifest.json'),
    `${JSON.stringify(bundleManifest, null, 2)}\n`
  );
}

switch (caseName) {
  case 'missing_schema_version':
    delete manifest.schema_version;
    break;
  case 'missing_operator_inputs_version':
    delete manifest.operator_inputs_version;
    break;
  case 'bad_operator_inputs_version':
    manifest.operator_inputs_version = 2;
    break;
  case 'unknown_field':
    manifest.extra_field = true;
    break;
  case 'path_escape':
    manifest.release_contract = '../release-contract.json';
    break;
  case 'reserved_output_tree_ref': {
    const packageRoot = path.dirname(manifestPath);
    const reservedRef = path.join(
      packageRoot,
      '.release-kit-internal/online-use-existing/deployment-path/source-evidence/release-contract-input.json'
    );
    fs.mkdirSync(path.dirname(reservedRef), { recursive: true });
    fs.copyFileSync(path.join(packageRoot, 'release-contract.json'), reservedRef);
    manifest.release_contract =
      '.release-kit-internal/online-use-existing/deployment-path/source-evidence/release-contract-input.json';
    break;
  }
  case 'candidate_paths': {
    const packageRoot = path.dirname(manifestPath);
    fs.mkdirSync(path.join(packageRoot, 'candidate'), { recursive: true });
    fs.copyFileSync(
      path.join(packageRoot, 'release-contract.json'),
      path.join(packageRoot, 'release-candidate-contract.json')
    );
    fs.copyFileSync(
      path.join(packageRoot, 'render-values.json'),
      path.join(packageRoot, 'candidate/render-values.json')
    );
    manifest.release_contract = 'release-candidate-contract.json';
    manifest.render_values = 'candidate/render-values.json';
    break;
  }
  case 'internal_operator_release_surface_report_field':
    manifest.operator_release_surface_report = 'operator-release-surface-report.json';
    break;
  case 'internal_adoption_report_value':
    fs.copyFileSync(
      path.join(path.dirname(manifestPath), 'release-contract.json'),
      path.join(path.dirname(manifestPath), 'adoption-report.json')
    );
    manifest.release_contract = 'adoption-report.json';
    break;
  case 'internal_operator_release_surface_report_value':
    fs.copyFileSync(
      path.join(path.dirname(manifestPath), 'release-contract.json'),
      path.join(path.dirname(manifestPath), 'operator-release-surface-report.json')
    );
    manifest.release_contract = 'operator-release-surface-report.json';
    break;
  case 'internal_release_engineering_gate_intake_report_value':
    fs.copyFileSync(
      path.join(path.dirname(manifestPath), 'release-contract.json'),
      path.join(path.dirname(manifestPath), 'release-engineering-gate-intake-report.json')
    );
    manifest.release_contract = 'release-engineering-gate-intake-report.json';
    break;
  case 'payload_case':
    manifest.smoke_url = 'https://release.example/ok?token=secretpayload123';
    break;
  case 'smoke_url_access_token':
    manifest.smoke_url = 'https://release.example/ok?access_token=secretpayload123';
    break;
  case 'feishu_webhook_url':
    manifest.smoke_url = 'https://open.feishu.cn/open-apis/bot/v2/hook/abcdef1234567890';
    break;
  case 'jira_webhook_url':
    manifest.smoke_url = 'https://agentsmith.atlassian.net/rest/webhooks/1.0/webhook/abcdef1234567890';
    break;
  case 'smoke_modifiers_without_url':
    manifest.expected_status = 200;
    manifest.timeout_ms = 5000;
    manifest.allow_http = true;
    manifest.allow_localhost = true;
    break;
  case 'smoke_url_server_dry_run':
    manifest.smoke_url = 'https://release.example/ok';
    manifest.expected_status = 200;
    break;
  case 'smoke_url_userinfo':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://user:pass@example.com/ok';
    break;
  case 'smoke_url_query':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://release.example/ok?debug=true';
    break;
  case 'smoke_url_hash':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://release.example/ok#ready';
    break;
  case 'smoke_url_http_without_allow':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'http://release.example/ok';
    break;
  case 'smoke_timeout_too_large':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://release.example/ok';
    manifest.timeout_ms = 300001;
    break;
  case 'timeout_without_unit':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://release.example/ok';
    manifest.timeout = '120';
    break;
  case 'timeout_leading_zero_duration':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://release.example/ok';
    manifest.timeout = '00s';
    break;
  case 'timeout_zero_duration':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.smoke_url = 'https://release.example/ok';
    manifest.timeout = '0s';
    break;
  case 'namespace_too_long':
    manifest.namespace = 'a'.repeat(64);
    break;
  case 'apply_smoke_modifier_without_url':
    manifest.mode = 'apply';
    manifest.deploy_confirmation = {
      confirmed: true,
      operator_run_id: 'operator-inputs-deploy-1002'
    };
    manifest.expected_status = 200;
    break;
  case 'product_readiness_report':
    manifest.product_readiness_report = 'product-readiness-report.json';
    break;
  case 'missing_install_confirmation':
    delete manifest.install_confirmation;
    break;
  case 'missing_current_install_confirmation':
    delete manifest.install_confirmation.confirm_current_install_parameters;
    delete manifest.install_confirmation.install_parameters_sha256;
    break;
  case 'missing_kubectl':
    delete manifest.kubectl;
    break;
  case 'missing_context':
    delete manifest.context;
    break;
  case 'missing_routability_probe':
    delete manifest.routability_probe;
    break;
  case 'missing_airgap_bundle':
    delete manifest.airgap_bundle;
    break;
  case 'missing_airgap_bundle_manifest':
    delete manifest.airgap_bundle_manifest;
    break;
  case 'airgap_bundle_manifest_outside_bundle':
    manifest.airgap_bundle_manifest = 'airgap-bundle-manifest-outside.json';
    fs.writeFileSync(
      path.join(path.dirname(manifestPath), 'airgap-bundle-manifest-outside.json'),
      `${JSON.stringify({ schema_version: 'fixture.airgap-bundle-manifest/v1' }, null, 2)}\n`
    );
    break;
  case 'airgap_bundle_manifest_missing_components': {
    const bundleManifestPath = path.join(
      path.dirname(manifestPath),
      manifest.airgap_bundle_manifest
    );
    const bundleManifest = JSON.parse(fs.readFileSync(bundleManifestPath, 'utf8'));
    delete bundleManifest.components;
    fs.writeFileSync(bundleManifestPath, `${JSON.stringify(bundleManifest, null, 2)}\n`);
    break;
  }
  case 'airgap_bundle_manifest_empty_components': {
    const bundleManifestPath = path.join(
      path.dirname(manifestPath),
      manifest.airgap_bundle_manifest
    );
    const bundleManifest = JSON.parse(fs.readFileSync(bundleManifestPath, 'utf8'));
    bundleManifest.components = [];
    fs.writeFileSync(bundleManifestPath, `${JSON.stringify(bundleManifest, null, 2)}\n`);
    break;
  }
  case 'airgap_bundle_manifest_component_sha_mismatch': {
    const bundleManifestPath = path.join(
      path.dirname(manifestPath),
      manifest.airgap_bundle_manifest
    );
    const bundleManifest = JSON.parse(fs.readFileSync(bundleManifestPath, 'utf8'));
    bundleManifest.components[0].sha256 = `sha256:${'a'.repeat(64)}`;
    fs.writeFileSync(bundleManifestPath, `${JSON.stringify(bundleManifest, null, 2)}\n`);
    break;
  }
  case 'airgap_release_contract_outside_bundle_same_digest': {
    const packageRoot = path.dirname(manifestPath);
    const copyPath = path.join(packageRoot, 'release-contract-copy.json');
    fs.copyFileSync(path.join(packageRoot, manifest.release_contract), copyPath);
    manifest.release_contract = 'release-contract-copy.json';
    break;
  }
  case 'airgap_deploy_template_package_outside_bundle_same_digest': {
    const packageRoot = path.dirname(manifestPath);
    const copyPath = path.join(packageRoot, 'deploy-template-package-copy.json');
    fs.copyFileSync(path.join(packageRoot, manifest.deploy_template_package), copyPath);
    manifest.deploy_template_package = 'deploy-template-package-copy.json';
    break;
  }
  case 'airgap_render_values_outside_bundle':
    manifest.render_values = 'render-values.json';
    break;
  case 'airgap_target_prerequisites_outside_bundle':
    manifest.target_prerequisites = 'target-prerequisites.json';
    break;
  case 'airgap_substrate_truth_outside_bundle':
    manifest.substrate_truth = 'substrate-truth.json';
    break;
  case 'airgap_install_substrate_install_inputs_outside_bundle':
    manifest.substrate_install_inputs = 'substrate-install-inputs.json';
    break;
  case 'operator_facing_substrate_install_inputs': {
    const packageRoot = path.dirname(manifestPath);
    const installInputsPath = path.join(packageRoot, manifest.substrate_install_inputs);
    const installInputs = JSON.parse(fs.readFileSync(installInputsPath, 'utf8'));
    delete installInputs.target_profile;
    delete installInputs.substrate_truth.target_cluster;
    delete installInputs.substrate_truth.substrate_source;
    delete installInputs.substrate_truth.distribution;
    fs.writeFileSync(installInputsPath, `${JSON.stringify(installInputs, null, 2)}\n`);
    break;
  }
  case 'airgap_bundle_manifest_existing_mismatch':
    writeAirgapBundleManifest('existing_kubernetes/kit_installed/airgap');
    break;
  case 'airgap_bundle_manifest_install_mismatch':
    writeAirgapBundleManifest('existing_kubernetes/external_declared/airgap');
    break;
  case 'missing_archive_probe':
    delete manifest.archive_probe;
    break;
  case 'missing_image_loader':
    delete manifest.image_loader;
    break;
  case 'slashless_kubectl':
    manifest.kubectl = 'true';
    break;
  case 'slashless_routability_probe':
    manifest.routability_probe = 'true';
    break;
  case 'slashless_image_loader':
    manifest.image_loader = 'true';
    break;
  case 'registry_probe':
    manifest.registry_probe = 'tools/registry-probe';
    break;
  case 'smoke_endpoint':
    manifest.smoke_endpoint = '/healthz';
    break;
  case 'missing_substrate_truth':
    delete manifest.substrate_truth;
    break;
  case 'install_substrate_truth':
    manifest.substrate_truth = manifest.deployment_path.startsWith('airgap/')
      ? 'bundle/operator-inputs/substrate-truth.json'
      : 'substrate-truth.json';
    break;
  case 'missing_target_prerequisites':
    manifest.target_prerequisites = 'missing-target-prerequisites.json';
    break;
  case 'post_deploy_smoke_report':
    manifest.post_deploy_smoke_report = 'smoke-report.json';
    break;
  default:
    throw new Error(`unknown mutate case: ${caseName}`);
}

fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

assert_plan() {
  local plan_path="$1"
  local deployment_path="$2"

"$NODE_BIN" --input-type=module - "$plan_path" "$deployment_path" "$ROOT_DIR" <<'NODE'
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [planPath, deploymentPath, rootDir] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
const serialized = JSON.stringify(plan);
const installsSubstrates = deploymentPath.endsWith('/install_substrates');
const existingArgPathFlags = new Set([
  '--operator-inputs',
  '--release-contract',
  '--deploy-template-package',
  '--archive',
  '--image-map',
  '--render-values',
  '--substrate-truth',
  '--target-prerequisites',
  '--substrate-pack-manifest',
  '--substrate-install-inputs',
  '--bundle-root',
  '--bundle-manifest',
  '--kubectl',
  '--routability-probe',
  '--archive-probe',
  '--image-loader'
]);
const absoluteArgPathFlags = new Set([...existingArgPathFlags, '--output-dir']);

function assertAbsolute(value, label) {
  if (!path.isAbsolute(value || '')) {
    throw new Error(`${label} must be an absolute path: ${value}`);
  }
}

function assertAccessibleFile(value, label) {
  assertAbsolute(value, label);
  fs.accessSync(value, fs.constants.R_OK);
  if (!fs.statSync(value).isFile()) {
    throw new Error(`${label} must point to a file`);
  }
}

function assertAccessiblePath(value, label) {
  assertAbsolute(value, label);
  fs.accessSync(value, fs.constants.R_OK);
}

function isInsidePath(rootDir, candidate) {
  const relative = path.relative(rootDir, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function assertArgvPaths(argv, label) {
  if (!Array.isArray(argv) || argv.length < 2) {
    throw new Error(`${label} argv must include bash and script path`);
  }
  if (argv[0] !== 'bash') {
    throw new Error(`${label} argv must start with bash`);
  }
  assertAccessibleFile(argv[1], `${label} script path`);
  for (let index = 2; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!absoluteArgPathFlags.has(flag)) {
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw new Error(`${label} missing value after ${flag}`);
    }
    assertAbsolute(value, `${label} ${flag}`);
    if (existingArgPathFlags.has(flag)) {
      if (
        flag === '--substrate-truth' &&
        (
          (deploymentPath === 'online/install_substrates' &&
            label === 'producer online-deployment-gate') ||
          (deploymentPath === 'airgap/install_substrates' &&
            label === 'producer airgap-deployment-gate')
        )
      ) {
        const generatedTruth = plan._internal?.expected?.generated_refs?.substrate_truth;
        if (!generatedTruth || !path.isAbsolute(generatedTruth)) {
          throw new Error('install producer plan must model generated installer substrate truth');
        }
        if (value !== generatedTruth) {
          throw new Error('install producer argv must use generated installer substrate truth');
        }
        continue;
      }
      assertAccessiblePath(value, `${label} ${flag}`);
    }
    index += 1;
  }
}

function argValue(argv, flag, label) {
  const index = argv.indexOf(flag);
  if (index === -1) {
    throw new Error(`${label} argv must include ${flag}`);
  }
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`${label} argv missing value after ${flag}`);
  }
  return value;
}

if (plan.schema_version !== 'agentsmith.operator-inputs-plan/v1') {
  throw new Error(`unexpected plan schema: ${plan.schema_version}`);
}
if (plan.scope !== 'operator_inputs_intake_only') {
  throw new Error(`unexpected plan scope: ${plan.scope}`);
}
if (plan.status !== 'pass') {
  throw new Error(`unexpected plan status: ${plan.status}`);
}
if (plan.deployment_path !== deploymentPath) {
  throw new Error(`unexpected deployment_path: ${plan.deployment_path}`);
}
if (fs.realpathSync(plan.repo_root || '') !== fs.realpathSync(rootDir)) {
  throw new Error(`unexpected repo_root: ${plan.repo_root}`);
}
if (plan.argv_path_mode !== 'absolute') {
  throw new Error(`unexpected argv path mode: ${plan.argv_path_mode}`);
}
assertAbsolute(plan.operator_inputs_root, 'operator_inputs_root');
if (!fs.statSync(plan.operator_inputs_root).isDirectory()) {
  throw new Error('operator_inputs_root must point to a directory');
}
if (Object.prototype.hasOwnProperty.call(plan, 'readiness')) {
  throw new Error('operator-inputs plan must not write readiness');
}
if (Object.prototype.hasOwnProperty.call(plan, 'formal_verdict')) {
  throw new Error('operator-inputs plan must not write formal_verdict');
}
if (!/^sha256:[0-9a-f]{64}$/.test(plan.package?.manifest_sha256 || '')) {
  throw new Error('manifest digest missing');
}
assertAccessibleFile(plan.package?.manifest_path, 'manifest path');
for (const key of [
  'release_contract',
  'deploy_template_package',
  'deploy_template_archive',
  'render_values',
  'target_prerequisites'
]) {
  const ref = plan.input_refs?.[key];
  if (!ref || ref.kind !== 'file' || !/^sha256:[0-9a-f]{64}$/.test(ref.sha256 || '')) {
    throw new Error(`missing file digest ref: ${key}`);
  }
  assertAccessibleFile(ref.absolute_path, `input ref ${key}`);
}
if (installsSubstrates) {
  if (plan.input_refs?.substrate_truth) {
    throw new Error('install path plan must not include package-local substrate truth ref');
  }
} else {
  const ref = plan.input_refs?.substrate_truth;
  if (!ref || ref.kind !== 'file' || !/^sha256:[0-9a-f]{64}$/.test(ref.sha256 || '')) {
    throw new Error('missing file digest ref: substrate_truth');
  }
  assertAccessibleFile(ref.absolute_path, 'input ref substrate_truth');
}
for (const key of [
  'kubectl',
  'routability_probe',
  'archive_probe',
  'image_loader'
]) {
  const ref = plan.input_refs?.[key];
  if (!ref) {
    continue;
  }
  if (ref.kind !== 'file' || !/^sha256:[0-9a-f]{64}$/.test(ref.sha256 || '')) {
    throw new Error(`command ref must be a digest-bound file: ${key}`);
  }
  assertAccessibleFile(ref.absolute_path, `command ref ${key}`);
}
if (deploymentPath.endsWith('/install_substrates')) {
  for (const key of ['substrate_pack_manifest', 'substrate_install_inputs']) {
    const ref = plan.input_refs?.[key];
    if (!ref || ref.kind !== 'file' || !/^sha256:[0-9a-f]{64}$/.test(ref.sha256 || '')) {
      throw new Error(`missing install input digest ref: ${key}`);
    }
    assertAccessibleFile(ref.absolute_path, `install input ref ${key}`);
  }
}
if (deploymentPath.startsWith('airgap/')) {
  const bundleRef = plan.input_refs?.airgap_bundle;
  const manifestRef = plan.input_refs?.airgap_bundle_manifest;
  if (!bundleRef || bundleRef.kind !== 'directory') {
    throw new Error('airgap plan must include airgap_bundle directory ref');
  }
  if (!manifestRef || manifestRef.kind !== 'file') {
    throw new Error('airgap plan must include airgap_bundle_manifest file ref');
  }
  assertAccessibleFile(manifestRef.absolute_path, 'airgap bundle manifest ref');
  if (!isInsidePath(bundleRef.absolute_path, manifestRef.absolute_path)) {
    throw new Error('airgap_bundle_manifest must be inside airgap_bundle');
  }
  const componentBoundKeys = ['release_contract', 'deploy_template_package', 'deploy_template_archive'];
  if (installsSubstrates) {
    componentBoundKeys.push('substrate_pack_manifest');
  }
  for (const key of componentBoundKeys) {
    const ref = plan.input_refs?.[key];
    if (!isInsidePath(bundleRef.absolute_path, ref?.absolute_path || '')) {
      throw new Error(`${key} must match a bundle-local component`);
    }
  }
  for (const key of ['render_values', 'target_prerequisites']) {
    const ref = plan.input_refs?.[key];
    if (!isInsidePath(bundleRef.absolute_path, ref?.absolute_path || '')) {
      throw new Error(`${key} must be inside airgap_bundle`);
    }
  }
  if (!installsSubstrates) {
    const ref = plan.input_refs?.substrate_truth;
    if (!isInsidePath(bundleRef.absolute_path, ref?.absolute_path || '')) {
      throw new Error('substrate_truth must be inside airgap_bundle');
    }
  }
  let sawBundleManifestArg = false;
  let sawBundleLocalRenderValuesArg = false;
  let sawBundleLocalSubstrateTruthArg = false;
  let sawInstallerGeneratedSubstrateTruthArg = false;
  for (const step of plan.producer_argv || []) {
    const argv = step.argv || [];
    for (let index = 0; index < argv.length - 1; index += 1) {
      if (argv[index] === '--bundle-manifest') {
        sawBundleManifestArg = true;
        if (argv[index + 1] !== manifestRef.absolute_path) {
          throw new Error('airgap producer argv must carry the absolute bundle manifest path');
        }
      }
      if (argv[index] === '--render-values') {
        sawBundleLocalRenderValuesArg = true;
        if (argv[index + 1] !== plan.input_refs.render_values.absolute_path) {
          throw new Error('airgap producer argv must carry absolute bundle-local render values');
        }
      }
      if (argv[index] === '--substrate-truth') {
        if (deploymentPath === 'airgap/install_substrates' && step.name === 'airgap-deployment-gate') {
          sawInstallerGeneratedSubstrateTruthArg = true;
          const generatedTruth = plan._internal?.expected?.generated_refs?.substrate_truth;
          if (argv[index + 1] !== generatedTruth) {
            throw new Error('airgap install gate must use installer output substrate truth');
          }
          if (plan.input_refs?.substrate_truth && argv[index + 1] === plan.input_refs.substrate_truth.absolute_path) {
            throw new Error('airgap install gate must not use bundle-local substrate truth');
          }
        } else {
          sawBundleLocalSubstrateTruthArg = true;
          if (argv[index + 1] !== plan.input_refs.substrate_truth.absolute_path) {
            throw new Error('airgap producer argv must carry absolute bundle-local substrate truth');
          }
        }
      }
    }
  }
  if (!sawBundleManifestArg) {
    throw new Error('airgap producer argv must include --bundle-manifest');
  }
  if (!sawBundleLocalRenderValuesArg) {
    throw new Error('airgap producer argv must include bundle-local render inputs');
  }
  if (deploymentPath === 'airgap/install_substrates') {
    const installInputsRef = plan.input_refs?.substrate_install_inputs;
    if (!isInsidePath(bundleRef.absolute_path, installInputsRef?.absolute_path || '')) {
      throw new Error('substrate_install_inputs must be inside airgap_bundle');
    }
    if (!sawInstallerGeneratedSubstrateTruthArg) {
      throw new Error('airgap install producer argv must include installer-generated substrate truth');
    }
  } else if (!sawBundleLocalSubstrateTruthArg) {
    throw new Error('airgap producer argv must include bundle-local substrate inputs');
  }
  if (deploymentPath === 'airgap/use_existing') {
    const kubectlRef = plan.input_refs?.kubectl;
    if (!kubectlRef || kubectlRef.kind !== 'file') {
      throw new Error('airgap use_existing plan must include package-local kubectl ref');
    }
    const consumeStep = (plan.producer_argv || []).find((step) => step.name === 'airgap-consume-rehearsal');
    if (!consumeStep) {
      throw new Error('airgap use_existing plan must include airgap-consume-rehearsal step');
    }
    if (argValue(consumeStep.argv, '--kubectl', 'airgap-consume-rehearsal') !== kubectlRef.absolute_path) {
      throw new Error('airgap consume plan must use package-local kubectl');
    }
    if (argValue(consumeStep.argv, '--context', 'airgap-consume-rehearsal') !== 'operator-inputs-context') {
      throw new Error('airgap consume plan must pass operator-inputs context');
    }
  }
  if (deploymentPath === 'airgap/install_substrates') {
    const generatedTruth = plan._internal?.expected?.generated_refs?.substrate_truth;
    if (!generatedTruth || !path.isAbsolute(generatedTruth)) {
      throw new Error('airgap install plan must model generated substrate truth as an absolute path');
    }
    if (generatedTruth !== path.join(
      plan._internal.expected.output_dirs.substrate_install,
      'substrate-truth.json'
    )) {
      throw new Error('airgap generated substrate truth must live under substrate-install output dir');
    }
    const gateStep = (plan.producer_argv || []).find((step) => step.name === 'airgap-deployment-gate');
    if (!gateStep) {
      throw new Error('airgap install plan must include airgap-deployment-gate step');
    }
    if (argValue(gateStep.argv, '--substrate-truth', 'airgap-deployment-gate') !== generatedTruth) {
      throw new Error('airgap install gate must use installer output substrate truth');
    }
    if (!gateStep.argv.includes('--allow-installed-substrate-truth')) {
      throw new Error('airgap install gate must opt into installer-generated substrate truth');
    }
    const generatedReport = path.join(
      plan._internal.expected.output_dirs.substrate_install,
      'substrate-install-report.json'
    );
    if (argValue(gateStep.argv, '--substrate-install-report', 'airgap-deployment-gate') !== generatedReport) {
      throw new Error('airgap install gate must bind installer output substrate-install report');
    }
    if (!((plan.producer_argv || []).some((step) => step.name === 'airgap-bundle-check'))) {
      throw new Error('airgap install plan must include airgap-bundle-check step');
    }
  }
}
if (!Array.isArray(plan.producer_argv) || plan.producer_argv.length < 1) {
  throw new Error('plan must include producer argv');
}
assertArgvPaths(plan.facade_argv, 'facade');
if (plan.facade_argv[2] !== '--operator-inputs') {
  throw new Error('facade argv must replay through --operator-inputs');
}
const replayInput = plan.facade_argv[3];
assertAccessiblePath(replayInput, 'facade replay input');
const replayInputStat = fs.lstatSync(replayInput);
if (replayInputStat.isSymbolicLink()) {
  throw new Error('facade replay input must not be a symlink');
}
if (replayInputStat.isDirectory()) {
  const replayManifest = path.join(replayInput, 'operator-inputs.json');
  assertAccessibleFile(replayManifest, 'facade replay directory manifest');
  if (fs.lstatSync(replayManifest).isSymbolicLink()) {
    throw new Error('facade replay directory manifest must not be a symlink');
  }
}
if (replayInputStat.isFile() && fs.lstatSync(replayInput).isSymbolicLink()) {
  throw new Error('facade replay manifest must not be a symlink');
}
const replay = spawnSync(plan.facade_argv[0], plan.facade_argv.slice(1), {
  cwd: rootDir,
  encoding: 'utf8'
});
if (replay.status !== 0) {
  throw new Error(`facade argv replay failed: ${replay.stderr || replay.stdout}`);
}
for (const step of plan.producer_argv) {
  assertArgvPaths(step.argv, `producer ${step.name}`);
  if (step.name === 'substrate-install') {
    const expectedInstallHash =
      plan._internal?.expected?.install?.install_parameters_sha256;
    if (!/^sha256:[0-9a-f]{64}$/.test(expectedInstallHash || '')) {
      throw new Error('install path plan must expose computed install_parameters_sha256');
    }
    if (
      argValue(step.argv, '--confirm-install-parameters', 'substrate-install') !==
      expectedInstallHash
    ) {
      throw new Error('substrate-install plan must use computed install_parameters_sha256');
    }
    if (step.argv.includes('--substrate-truth')) {
      throw new Error('substrate-install plan must not pass substrate_truth');
    }
    for (const flag of ['--substrate-pack-manifest', '--substrate-install-inputs']) {
      if (!step.argv.includes(flag)) {
        throw new Error(`substrate-install plan must include ${flag}`);
      }
    }
    if (argValue(step.argv, '--kubectl', 'substrate-install') !== plan.input_refs.kubectl.absolute_path) {
      throw new Error('substrate-install plan must use package-local kubectl');
    }
    if (argValue(step.argv, '--context', 'substrate-install') !== 'operator-inputs-context') {
      throw new Error('substrate-install plan must pass operator-inputs context');
    }
  }
  if (deploymentPath === 'online/install_substrates' && step.name === 'online-deployment-gate') {
    const generatedTruth = plan._internal?.expected?.generated_refs?.substrate_truth;
    if (!generatedTruth || !path.isAbsolute(generatedTruth)) {
      throw new Error('online install plan must model generated substrate truth as an absolute path');
    }
    if (generatedTruth !== path.join(
      plan._internal.expected.output_dirs.substrate_install,
      'substrate-truth.json'
    )) {
      throw new Error('generated substrate truth must live under substrate-install output dir');
    }
    if (argValue(step.argv, '--substrate-truth', 'online-deployment-gate') !== generatedTruth) {
      throw new Error('online install gate must use installer output substrate truth');
    }
    if (plan.input_refs?.substrate_truth) {
      throw new Error('online install plan must not include package-local substrate truth');
    }
    if (generatedTruth === plan.input_refs?.substrate_truth?.absolute_path) {
      throw new Error('online install gate must not use package-local substrate truth');
    }
  }
}
if (/post-deploy smoke report/i.test(serialized)) {
  throw new Error('plan must not carry post-deploy smoke report wording');
}
NODE
}

expect_fail() {
  local label="$1"
  shift

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected operator-inputs failure: $label"
  fi

  pass "operator-inputs rejected invalid case: $label"
}

expect_fail_matching() {
  local label="$1"
  local pattern="$2"
  shift 2

  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected operator-inputs failure: $label"
  fi
  if ! grep -Eq "$pattern" "$TMP_DIR/$label.out" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "operator-inputs failure message did not match $pattern for $label"
  fi

  pass "operator-inputs rejected invalid case with expected message: $label"
}

deployment_path_dir() {
  local package_dir="$1"
  local slug="${2:-online-use-existing}"
  printf '%s\n' "$package_dir/.release-kit-internal/$slug/deployment-path"
}

write_stale_path_evidence() {
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

remove_manifest_fields() {
  local package_dir="$1"
  shift

  "$NODE_BIN" --input-type=module - "$package_dir/operator-inputs.json" "$@" <<'NODE'
import fs from 'node:fs';

const [manifestFile, ...fields] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
for (const field of fields) {
  delete manifest[field];
}
fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

valid_paths=(
  online/use_existing
  online/install_substrates
  airgap/use_existing
  airgap/install_substrates
)

for deployment_path in "${valid_paths[@]}"; do
  package_dir="$TMP_DIR/package-${deployment_path//\//-}"
  mkdir -p "$package_dir"
  write_package_files "$package_dir"
  write_manifest "$package_dir" "$deployment_path"

  bash "$ROOT_DIR/scripts/operator-release.sh" --operator-inputs "$package_dir" \
    >"$TMP_DIR/${deployment_path//\//-}.out"
  assert_plan "$package_dir/.release-kit-internal/operator-inputs-plan.json" "$deployment_path"
  pass "operator-release --operator-inputs accepts $deployment_path"
done

for deployment_path in "${valid_paths[@]}"; do
  init_dir="$TMP_DIR/init-${deployment_path//\//-}"
  bash "$ROOT_DIR/scripts/operator-release.sh" \
    --init-operator-inputs "$deployment_path" \
    --output-dir "$init_dir" >"$TMP_DIR/init-${deployment_path//\//-}.out"
  grep -Fq "operator-inputs package README: $init_dir/README.md" "$TMP_DIR/init-${deployment_path//\//-}.out" ||
    fail "operator-inputs init output must point to generated README: $deployment_path"
  "$NODE_BIN" --input-type=module - "$init_dir/operator-inputs.json" "$init_dir/README.md" "$deployment_path" <<'NODE'
import fs from 'node:fs';

const [manifestFile, readmeFile, deploymentPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const readme = fs.readFileSync(readmeFile, 'utf8');
if (manifest.schema_version !== 'agentsmith.operator-inputs/v1') {
  throw new Error('init manifest schema mismatch');
}
if (manifest.operator_inputs_version !== 1) {
  throw new Error('init manifest version mismatch');
}
if (manifest.deployment_path !== deploymentPath) {
  throw new Error('init manifest deployment_path mismatch');
}
if (manifest.deploy_confirmation !== undefined || manifest.install_confirmation !== undefined) {
  throw new Error('init manifest must not prefill explicit confirmations');
}
if (deploymentPath.endsWith('/install_substrates') && manifest.substrate_truth !== undefined) {
  throw new Error('init install_substrates manifest must not include substrate_truth');
}
if (deploymentPath.startsWith('airgap/') && manifest.airgap_bundle !== 'airgap-bundle') {
  throw new Error('init airgap manifest must include airgap bundle refs');
}
if (!readme.includes(`Deployment path: \`${deploymentPath}\``)) {
  throw new Error('init package README must identify the selected deployment path');
}
if (!readme.includes('bash scripts/operator-release.sh --operator-inputs <this-package> --doctor')) {
  throw new Error('init package README must show the doctor command');
}
if (!readme.includes('bash scripts/operator-release.sh --ga-report')) {
  throw new Error('init package README must show the final GA report command');
}
if (!readme.includes('ga-release-report.json')) {
  throw new Error('init package README must point to ga-release-report.json');
}
if (!readme.includes('"deploy_confirmation": {') || !readme.includes('"operator_run_id": "replace-with-deploy-run-id"')) {
  throw new Error('init package README must include a deploy_confirmation JSON snippet');
}
if (deploymentPath.endsWith('/install_substrates') && !readme.includes('namespace-scoped installer')) {
  throw new Error('install_substrates README must explain the installer boundary');
}
if (deploymentPath.endsWith('/install_substrates')) {
  if (!readme.includes('"install_confirmation": {') || !readme.includes('"confirm_current_install_parameters": true')) {
    throw new Error('install_substrates README must include an install_confirmation JSON snippet');
  }
} else if (readme.includes('"install_confirmation": {')) {
  throw new Error('use_existing README must not include an install_confirmation snippet');
}
if (deploymentPath.startsWith('airgap/') && !readme.includes('airgap-bundle/')) {
  throw new Error('airgap README must explain bundle-local materials');
}
if (/[.]release-kit-internal|operator-inputs-plan|operator-release-surface-report|adoption report|candidate intake|release-engineering|operator-signoff|--target-profile|verify-release[.]sh|target_cluster|substrate_source|external_declared|kit_installed|existing_kubernetes|kind_rehearsal/u.test(readme)) {
  throw new Error('init package README must not expose internal release-kit vocabulary');
}
NODE
  if "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
    --operator-inputs "$init_dir" \
    --doctor \
    --stdout >"$TMP_DIR/init-doctor-${deployment_path//\//-}.json"; then
    fail "operator-inputs doctor should fail for scaffold-only init package: $deployment_path"
  fi
  "$NODE_BIN" --input-type=module - "$TMP_DIR/init-doctor-${deployment_path//\//-}.json" "$deployment_path" <<'NODE'
import fs from 'node:fs';

const [doctorFile, deploymentPath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(doctorFile, 'utf8'));
if (report.schema_version !== 'agentsmith.operator-inputs-doctor/v1') {
  throw new Error('init doctor schema mismatch');
}
if (report.status !== 'fail' || report.readiness !== false || report.formal_verdict !== 'not_issued') {
  throw new Error('init doctor must fail without readiness or formal verdict');
}
if (!report.missing.includes('deploy_confirmation')) {
  throw new Error('init doctor must require explicit deploy_confirmation');
}
if (deploymentPath.endsWith('/install_substrates') && !report.missing.includes('install_confirmation')) {
  throw new Error('init doctor must require explicit install_confirmation');
}
const missingRefFields = new Set(report.missing_refs.map((entry) => entry.field));
for (const field of ['release_contract', 'deploy_template_package', 'deploy_template_archive']) {
  if (!missingRefFields.has(field)) {
    throw new Error(`init doctor missing refs did not include ${field}`);
  }
}
NODE
  if bash "$ROOT_DIR/scripts/operator-release.sh" \
    --init-operator-inputs "$deployment_path" \
    --output-dir "$init_dir" >"$TMP_DIR/init-overwrite.out" 2>"$TMP_DIR/init-overwrite.err"; then
    fail "operator-inputs init should refuse to overwrite existing manifest: $deployment_path"
  fi
  grep -Fq 'refuses to overwrite existing operator-inputs.json' "$TMP_DIR/init-overwrite.err" ||
    fail "operator-inputs init overwrite failure did not explain blocker"
  pass "operator-release --init-operator-inputs scaffolds $deployment_path"
done

if bash "$ROOT_DIR/scripts/operator-release.sh" \
  --init-operator-inputs existing_kubernetes/kit_installed/online \
  --output-dir "$TMP_DIR/init-machine-profile" >"$TMP_DIR/init-machine-profile.out" 2>"$TMP_DIR/init-machine-profile.err"; then
  fail "operator-inputs init should reject machine target profile vocabulary"
fi
grep -Fq 'deployment_path must be one of online/use_existing' "$TMP_DIR/init-machine-profile.err" ||
  fail "operator-inputs init machine profile failure did not explain deployment_path choices"
pass "operator-release --init-operator-inputs rejects machine profile vocabulary"

direct_package="$TMP_DIR/direct-json"
mkdir -p "$direct_package"
write_package_files "$direct_package"
write_manifest "$direct_package" online/use_existing
"$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$direct_package/operator-inputs.json" \
  --stdout >"$TMP_DIR/direct-json-plan.out"
assert_plan "$direct_package/.release-kit-internal/operator-inputs-plan.json" online/use_existing
pass "resolve-operator-inputs accepts a direct JSON manifest"

example_online_package="$TMP_DIR/example-online-existing-kubernetes"
mkdir -p "$example_online_package"
write_package_files "$example_online_package"
cp "$EXAMPLE_ONLINE_DIR/operator-inputs.apply.example.json" \
  "$example_online_package/operator-inputs.json"
cp "$EXAMPLE_ONLINE_DIR/render-values.example.json" \
  "$example_online_package/render-values.example.json"
cp "$EXAMPLE_ONLINE_DIR/substrate-truth.example.json" \
  "$example_online_package/substrate-truth.example.json"
cp "$EXAMPLE_ONLINE_DIR/target-prerequisites.example.json" \
  "$example_online_package/target-prerequisites.example.json"
"$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$example_online_package" >/dev/null
assert_plan \
  "$example_online_package/.release-kit-internal/operator-inputs-plan.json" \
  online/use_existing
pass "resolve-operator-inputs accepts online existing Kubernetes example package"

base_online="$TMP_DIR/base-online"
mkdir -p "$base_online"
write_package_files "$base_online"
write_manifest "$base_online" online/use_existing

doctor_missing_dir="$TMP_DIR/doctor-missing-online"
copy_valid_package "$base_online" "$doctor_missing_dir"
remove_manifest_fields "$doctor_missing_dir" substrate_truth target_prerequisites
if "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$doctor_missing_dir" \
  --doctor \
  --stdout >"$TMP_DIR/doctor-missing.json"; then
  fail "operator-inputs doctor should fail when required inputs are missing"
fi
"$NODE_BIN" --input-type=module - "$TMP_DIR/doctor-missing.json" <<'NODE'
import fs from 'node:fs';

const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.schema_version !== 'agentsmith.operator-inputs-doctor/v1') {
  throw new Error('unexpected doctor schema');
}
if (report.status !== 'fail' || report.formal_verdict !== 'not_issued' || report.readiness !== false) {
  throw new Error('doctor must fail without issuing readiness or formal verdict');
}
for (const field of ['substrate_truth', 'target_prerequisites']) {
  if (!report.missing.includes(field)) {
    throw new Error(`doctor missing list did not include ${field}`);
  }
}
if (report.missing.length < 2) {
  throw new Error('doctor must list multiple missing inputs');
}
NODE
if bash "$ROOT_DIR/scripts/operator-release.sh" \
  --operator-inputs "$doctor_missing_dir" \
  --doctor >"$TMP_DIR/doctor-facade.out" 2>"$TMP_DIR/doctor-facade.err"; then
  fail "operator facade doctor should fail when required inputs are missing"
fi
grep -Fq -- '- substrate_truth' "$TMP_DIR/doctor-facade.out" ||
  fail "operator facade doctor did not list substrate_truth"
grep -Fq -- '- target_prerequisites' "$TMP_DIR/doctor-facade.out" ||
  fail "operator facade doctor did not list target_prerequisites"
[[ ! -e "$doctor_missing_dir/.release-kit-internal/operator-inputs-plan.json" ]] ||
  fail "operator-inputs doctor must not write an intake plan"
pass "operator-inputs doctor lists multiple missing package inputs without writing a plan"

missing_release_contract_run_dir="$TMP_DIR/run-missing-release-contract"
copy_valid_package "$base_online" "$missing_release_contract_run_dir"
write_stale_path_evidence "$missing_release_contract_run_dir"
rm "$missing_release_contract_run_dir/release-contract.json"
expect_fail_matching public_preclean_missing_release_contract 'cannot read release_contract' \
  bash "$ROOT_DIR/scripts/operator-release.sh" \
    --operator-inputs "$missing_release_contract_run_dir" \
    --run
assert_no_path_evidence "$missing_release_contract_run_dir"
pass "operator-inputs --run clears stale path evidence before missing release_contract validation"

candidate_paths_dir="$TMP_DIR/valid-candidate-paths"
copy_valid_package "$base_online" "$candidate_paths_dir"
mutate_manifest "$candidate_paths_dir" candidate_paths
"$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$candidate_paths_dir" >/dev/null
assert_plan "$candidate_paths_dir/.release-kit-internal/operator-inputs-plan.json" online/use_existing
pass "resolve-operator-inputs accepts package path refs containing candidate"

for case_name in \
  internal_operator_release_surface_report_field \
  internal_adoption_report_value \
  internal_operator_release_surface_report_value \
  internal_release_engineering_gate_intake_report_value; do
  invalid_dir="$TMP_DIR/invalid-$case_name"
  copy_valid_package "$base_online" "$invalid_dir"
  mutate_manifest "$invalid_dir" "$case_name"
  expect_fail_matching "$case_name" 'internal report reference' \
    "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$invalid_dir"
done

reserved_ref_dir="$TMP_DIR/invalid-reserved-output-tree-ref"
copy_valid_package "$base_online" "$reserved_ref_dir"
mutate_manifest "$reserved_ref_dir" reserved_output_tree_ref
expect_fail_matching reserved_output_tree_ref 'reserved operator-inputs output tree' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$reserved_ref_dir"
[[ -f "$reserved_ref_dir/.release-kit-internal/online-use-existing/deployment-path/source-evidence/release-contract-input.json" ]] ||
  fail "resolver must not delete operator package input in reserved output tree"

for case_name in \
  missing_schema_version \
  missing_operator_inputs_version \
  bad_operator_inputs_version \
  unknown_field \
  path_escape \
  payload_case \
  smoke_url_access_token \
  feishu_webhook_url \
  jira_webhook_url \
  smoke_modifiers_without_url \
  smoke_url_server_dry_run \
  smoke_url_userinfo \
  smoke_url_query \
  smoke_url_hash \
  smoke_url_http_without_allow \
  smoke_timeout_too_large \
  timeout_without_unit \
  timeout_leading_zero_duration \
  timeout_zero_duration \
  namespace_too_long \
  apply_smoke_modifier_without_url \
  product_readiness_report \
  slashless_kubectl \
  smoke_endpoint \
  missing_target_prerequisites \
  post_deploy_smoke_report; do
  invalid_dir="$TMP_DIR/invalid-$case_name"
  copy_valid_package "$base_online" "$invalid_dir"
  mutate_manifest "$invalid_dir" "$case_name"
  expect_fail "$case_name" \
    "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$invalid_dir"
done

missing_online_truth_dir="$TMP_DIR/invalid-online-use-existing-missing-substrate-truth"
copy_valid_package "$base_online" "$missing_online_truth_dir"
mutate_manifest "$missing_online_truth_dir" missing_substrate_truth
expect_fail_matching online_use_existing_missing_substrate_truth 'missing required operator-inputs field for online/use_existing: substrate_truth' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_online_truth_dir"

registry_probe_dir="$TMP_DIR/invalid-registry-probe"
copy_valid_package "$base_online" "$registry_probe_dir"
mutate_manifest "$registry_probe_dir" registry_probe
expect_fail_matching registry_probe 'registry_probe is not supported.*target_registry is not modeled' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$registry_probe_dir"

manifest_symlink_dir="$TMP_DIR/invalid-manifest-symlink"
copy_valid_package "$base_online" "$manifest_symlink_dir"
outside_manifest="$TMP_DIR/outside-operator-inputs.json"
cp "$base_online/operator-inputs.json" "$outside_manifest"
rm "$manifest_symlink_dir/operator-inputs.json"
ln -s "$outside_manifest" "$manifest_symlink_dir/operator-inputs.json"
expect_fail_matching manifest_symlink 'operator-inputs manifest must not be a symlink' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$manifest_symlink_dir"

plan_leaf_symlink_dir="$TMP_DIR/invalid-plan-leaf-symlink"
copy_valid_package "$base_online" "$plan_leaf_symlink_dir"
outside_plan="$TMP_DIR/outside-plan-leaf.json"
mkdir -p "$plan_leaf_symlink_dir/.release-kit-internal"
ln -s "$outside_plan" "$plan_leaf_symlink_dir/.release-kit-internal/operator-inputs-plan.json"
expect_fail_matching plan_leaf_symlink 'operator-inputs plan output must not be a symlink' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$plan_leaf_symlink_dir"
[[ ! -e "$outside_plan" ]] ||
  fail "operator-inputs intake must not write through operator-inputs-plan.json symlink"

base_install="$TMP_DIR/base-install"
mkdir -p "$base_install"
write_package_files "$base_install"
write_manifest "$base_install" online/install_substrates

operator_facing_install_dir="$TMP_DIR/operator-facing-online-install"
copy_valid_package "$base_install" "$operator_facing_install_dir"
mutate_manifest "$operator_facing_install_dir" operator_facing_substrate_install_inputs
"$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$operator_facing_install_dir" >/dev/null
assert_plan "$operator_facing_install_dir/.release-kit-internal/operator-inputs-plan.json" online/install_substrates
pass "resolve-operator-inputs derives online install substrate target profile axes from deployment_path"

legacy_install_truth_dir="$TMP_DIR/invalid-online-install-substrate-truth"
copy_valid_package "$base_install" "$legacy_install_truth_dir"
mutate_manifest "$legacy_install_truth_dir" install_substrate_truth
expect_fail_matching online_install_substrate_truth 'substrate_truth is accepted only for use_existing deployment_path' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$legacy_install_truth_dir"

missing_install_dir="$TMP_DIR/invalid-missing-install-confirmation"
copy_valid_package "$base_install" "$missing_install_dir"
mutate_manifest "$missing_install_dir" missing_install_confirmation
expect_fail missing_install_confirmation \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_install_dir"

missing_current_install_dir="$TMP_DIR/invalid-missing-current-install-confirmation"
copy_valid_package "$base_install" "$missing_current_install_dir"
mutate_manifest "$missing_current_install_dir" missing_current_install_confirmation
expect_fail_matching missing_current_install_confirmation 'install_confirmation.confirm_current_install_parameters must be true' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_current_install_dir"

missing_routability_dir="$TMP_DIR/invalid-missing-routability-probe"
copy_valid_package "$base_install" "$missing_routability_dir"
mutate_manifest "$missing_routability_dir" missing_routability_probe
expect_fail_matching missing_routability_probe 'missing required operator-inputs field for online/install_substrates: routability_probe' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_routability_dir"

missing_install_kubectl_dir="$TMP_DIR/invalid-online-install-missing-kubectl"
copy_valid_package "$base_install" "$missing_install_kubectl_dir"
mutate_manifest "$missing_install_kubectl_dir" missing_kubectl
expect_fail_matching online_install_missing_kubectl 'missing required operator-inputs field for online/install_substrates: kubectl' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_install_kubectl_dir"

missing_install_context_dir="$TMP_DIR/invalid-online-install-missing-context"
copy_valid_package "$base_install" "$missing_install_context_dir"
mutate_manifest "$missing_install_context_dir" missing_context
expect_fail_matching online_install_missing_context 'missing required operator-inputs field for online/install_substrates: context' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_install_context_dir"

slashless_routability_dir="$TMP_DIR/invalid-slashless-routability-probe"
copy_valid_package "$base_install" "$slashless_routability_dir"
mutate_manifest "$slashless_routability_dir" slashless_routability_probe
expect_fail_matching slashless_routability_probe 'routability_probe must be a package-relative executable path' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$slashless_routability_dir"

base_airgap="$TMP_DIR/base-airgap"
mkdir -p "$base_airgap"
write_package_files "$base_airgap"
write_manifest "$base_airgap" airgap/use_existing
missing_airgap_dir="$TMP_DIR/invalid-missing-airgap-bundle"
copy_valid_package "$base_airgap" "$missing_airgap_dir"
mutate_manifest "$missing_airgap_dir" missing_airgap_bundle
expect_fail missing_airgap_bundle \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_dir"

missing_airgap_manifest_dir="$TMP_DIR/invalid-missing-airgap-bundle-manifest"
copy_valid_package "$base_airgap" "$missing_airgap_manifest_dir"
mutate_manifest "$missing_airgap_manifest_dir" missing_airgap_bundle_manifest
expect_fail_matching missing_airgap_bundle_manifest 'missing required operator-inputs field for airgap/use_existing: airgap_bundle_manifest' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_manifest_dir"

missing_airgap_kubectl_dir="$TMP_DIR/invalid-airgap-missing-kubectl"
copy_valid_package "$base_airgap" "$missing_airgap_kubectl_dir"
mutate_manifest "$missing_airgap_kubectl_dir" missing_kubectl
expect_fail_matching airgap_missing_kubectl 'missing required operator-inputs field for airgap/use_existing: kubectl' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_kubectl_dir"

missing_airgap_context_dir="$TMP_DIR/invalid-airgap-missing-context"
copy_valid_package "$base_airgap" "$missing_airgap_context_dir"
mutate_manifest "$missing_airgap_context_dir" missing_context
expect_fail_matching airgap_missing_context 'missing required operator-inputs field for airgap/use_existing: context' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_context_dir"

missing_airgap_truth_dir="$TMP_DIR/invalid-airgap-use-existing-missing-substrate-truth"
copy_valid_package "$base_airgap" "$missing_airgap_truth_dir"
mutate_manifest "$missing_airgap_truth_dir" missing_substrate_truth
expect_fail_matching airgap_use_existing_missing_substrate_truth 'missing required operator-inputs field for airgap/use_existing: substrate_truth' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_truth_dir"

outside_airgap_manifest_dir="$TMP_DIR/invalid-airgap-bundle-manifest-outside-bundle"
copy_valid_package "$base_airgap" "$outside_airgap_manifest_dir"
mutate_manifest "$outside_airgap_manifest_dir" airgap_bundle_manifest_outside_bundle
expect_fail_matching airgap_bundle_manifest_outside_bundle 'airgap_bundle_manifest must resolve inside airgap_bundle' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_airgap_manifest_dir"

missing_airgap_components_dir="$TMP_DIR/invalid-airgap-bundle-missing-components"
copy_valid_package "$base_airgap" "$missing_airgap_components_dir"
mutate_manifest "$missing_airgap_components_dir" airgap_bundle_manifest_missing_components
expect_fail_matching airgap_bundle_manifest_missing_components 'airgap_bundle_manifest.components must be an array' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_components_dir"

empty_airgap_components_dir="$TMP_DIR/invalid-airgap-bundle-empty-components"
copy_valid_package "$base_airgap" "$empty_airgap_components_dir"
mutate_manifest "$empty_airgap_components_dir" airgap_bundle_manifest_empty_components
expect_fail_matching airgap_bundle_manifest_empty_components 'airgap_bundle_manifest.components must contain release_contract' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$empty_airgap_components_dir"

airgap_component_sha_mismatch_dir="$TMP_DIR/invalid-airgap-component-sha-mismatch"
copy_valid_package "$base_airgap" "$airgap_component_sha_mismatch_dir"
mutate_manifest "$airgap_component_sha_mismatch_dir" airgap_bundle_manifest_component_sha_mismatch
expect_fail_matching airgap_bundle_manifest_component_sha_mismatch 'airgap_bundle_manifest.components\[0\].sha256 must match component file sha256' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$airgap_component_sha_mismatch_dir"

outside_release_contract_dir="$TMP_DIR/invalid-airgap-release-contract-outside-bundle"
copy_valid_package "$base_airgap" "$outside_release_contract_dir"
mutate_manifest "$outside_release_contract_dir" airgap_release_contract_outside_bundle_same_digest
expect_fail_matching airgap_release_contract_outside_bundle 'release_contract must match airgap_bundle_manifest.components.release_contract.path' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_release_contract_dir"

outside_deploy_template_package_dir="$TMP_DIR/invalid-airgap-deploy-template-package-outside-bundle"
copy_valid_package "$base_airgap" "$outside_deploy_template_package_dir"
mutate_manifest "$outside_deploy_template_package_dir" airgap_deploy_template_package_outside_bundle_same_digest
expect_fail_matching airgap_deploy_template_package_outside_bundle 'deploy_template_package must match airgap_bundle_manifest.components.deploy_template_package.path' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_deploy_template_package_dir"

outside_render_values_dir="$TMP_DIR/invalid-airgap-render-values-outside-bundle"
copy_valid_package "$base_airgap" "$outside_render_values_dir"
mutate_manifest "$outside_render_values_dir" airgap_render_values_outside_bundle
expect_fail_matching airgap_render_values_outside_bundle 'render_values must resolve inside airgap_bundle' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_render_values_dir"

outside_target_prerequisites_dir="$TMP_DIR/invalid-airgap-target-prerequisites-outside-bundle"
copy_valid_package "$base_airgap" "$outside_target_prerequisites_dir"
mutate_manifest "$outside_target_prerequisites_dir" airgap_target_prerequisites_outside_bundle
expect_fail_matching airgap_target_prerequisites_outside_bundle 'target_prerequisites must resolve inside airgap_bundle' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_target_prerequisites_dir"

outside_substrate_truth_dir="$TMP_DIR/invalid-airgap-substrate-truth-outside-bundle"
copy_valid_package "$base_airgap" "$outside_substrate_truth_dir"
mutate_manifest "$outside_substrate_truth_dir" airgap_substrate_truth_outside_bundle
expect_fail_matching airgap_substrate_truth_outside_bundle 'substrate_truth must resolve inside airgap_bundle' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_substrate_truth_dir"

airgap_mismatch_dir="$TMP_DIR/invalid-airgap-bundle-profile-mismatch"
copy_valid_package "$base_airgap" "$airgap_mismatch_dir"
mutate_manifest "$airgap_mismatch_dir" airgap_bundle_manifest_existing_mismatch
expect_fail_matching airgap_bundle_manifest_existing_mismatch 'airgap_bundle_manifest.target_profile.value must match deployment_path target_profile' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$airgap_mismatch_dir"

base_airgap_install="$TMP_DIR/base-airgap-install"
mkdir -p "$base_airgap_install"
write_package_files "$base_airgap_install"
write_manifest "$base_airgap_install" airgap/install_substrates

operator_facing_airgap_install_dir="$TMP_DIR/operator-facing-airgap-install"
copy_valid_package "$base_airgap_install" "$operator_facing_airgap_install_dir"
mutate_manifest "$operator_facing_airgap_install_dir" operator_facing_substrate_install_inputs
"$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$operator_facing_airgap_install_dir" >/dev/null
assert_plan "$operator_facing_airgap_install_dir/.release-kit-internal/operator-inputs-plan.json" airgap/install_substrates
pass "resolve-operator-inputs derives airgap install substrate target profile axes from deployment_path"

legacy_airgap_install_truth_dir="$TMP_DIR/invalid-airgap-install-substrate-truth"
copy_valid_package "$base_airgap_install" "$legacy_airgap_install_truth_dir"
mutate_manifest "$legacy_airgap_install_truth_dir" install_substrate_truth
expect_fail_matching airgap_install_substrate_truth 'substrate_truth is accepted only for use_existing deployment_path' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$legacy_airgap_install_truth_dir"

airgap_install_mismatch_dir="$TMP_DIR/invalid-airgap-install-bundle-profile-mismatch"
copy_valid_package "$base_airgap_install" "$airgap_install_mismatch_dir"
mutate_manifest "$airgap_install_mismatch_dir" airgap_bundle_manifest_install_mismatch
expect_fail_matching airgap_bundle_manifest_install_mismatch 'airgap_bundle_manifest.target_profile.value must match deployment_path target_profile' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$airgap_install_mismatch_dir"

outside_airgap_install_inputs_dir="$TMP_DIR/invalid-airgap-install-inputs-outside-bundle"
copy_valid_package "$base_airgap_install" "$outside_airgap_install_inputs_dir"
mutate_manifest "$outside_airgap_install_inputs_dir" airgap_install_substrate_install_inputs_outside_bundle
expect_fail_matching airgap_install_substrate_install_inputs_outside_bundle 'substrate_install_inputs must resolve inside airgap_bundle' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$outside_airgap_install_inputs_dir"

missing_airgap_install_kubectl_dir="$TMP_DIR/invalid-airgap-install-missing-kubectl"
copy_valid_package "$base_airgap_install" "$missing_airgap_install_kubectl_dir"
mutate_manifest "$missing_airgap_install_kubectl_dir" missing_kubectl
expect_fail_matching airgap_install_missing_kubectl 'missing required operator-inputs field for airgap/install_substrates: kubectl' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_install_kubectl_dir"

missing_airgap_install_context_dir="$TMP_DIR/invalid-airgap-install-missing-context"
copy_valid_package "$base_airgap_install" "$missing_airgap_install_context_dir"
mutate_manifest "$missing_airgap_install_context_dir" missing_context
expect_fail_matching airgap_install_missing_context 'missing required operator-inputs field for airgap/install_substrates: context' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_airgap_install_context_dir"

base_airgap_apply="$TMP_DIR/base-airgap-apply"
mkdir -p "$base_airgap_apply"
write_package_files "$base_airgap_apply"
write_manifest "$base_airgap_apply" airgap/use_existing apply
"$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" \
  --operator-inputs "$base_airgap_apply" >/dev/null
assert_plan "$base_airgap_apply/.release-kit-internal/operator-inputs-plan.json" airgap/use_existing
pass "resolve-operator-inputs accepts airgap apply with loader probes"

missing_archive_dir="$TMP_DIR/invalid-missing-archive-probe"
copy_valid_package "$base_airgap_apply" "$missing_archive_dir"
mutate_manifest "$missing_archive_dir" missing_archive_probe
expect_fail_matching missing_archive_probe 'missing required operator-inputs field for airgap/use_existing: archive_probe' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_archive_dir"

missing_loader_dir="$TMP_DIR/invalid-missing-image-loader"
copy_valid_package "$base_airgap_apply" "$missing_loader_dir"
mutate_manifest "$missing_loader_dir" missing_image_loader
expect_fail_matching missing_image_loader 'missing required operator-inputs field for airgap/use_existing: image_loader' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$missing_loader_dir"

slashless_loader_dir="$TMP_DIR/invalid-slashless-image-loader"
copy_valid_package "$base_airgap_apply" "$slashless_loader_dir"
mutate_manifest "$slashless_loader_dir" slashless_image_loader
expect_fail_matching slashless_image_loader 'image_loader must be a package-relative executable path' \
  "$NODE_BIN" "$ROOT_DIR/scripts/resolve-operator-inputs.mjs" --operator-inputs "$slashless_loader_dir"

expect_fail raw_operator_inputs_equals \
  bash "$ROOT_DIR/scripts/operator-release.sh" "--operator-inputs=$base_online"

pass "operator-inputs focused tests completed"
