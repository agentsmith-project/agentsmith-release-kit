#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"
VALID_DEPLOY_TEMPLATE_PACKAGE="$ROOT_DIR/tests/fixtures/deploy-template-package.valid.json"

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

  cat >"$output" <<'JSON'
{
  "namespace": "agentsmith",
  "replicas": 2,
  "release_channel": "stable",
  "unsafe_payload": "not-real-credential-value"
}
JSON
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
spec:
  replicas: ${{ values.replicas }}
  template:
    spec:
      initContainers:
        - name: schema
          image: ${{ images.product_schema_bootstrap.image }}
      containers:
        - name: web
          image: ${{ images.web.image }}
          env:
            - name: POSTGRES_HOST
              value: ${{ substrate.services.postgresql.host }}
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
          image: ${{ images.api.image }}
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
          image: ${{ images.web.image }}
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
          image: ghcr.io/agentsmith-project/not-in-contract:2026.05.23-p0@sha256:9999999999999999999999999999999999999999999999999999999999999999
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
          image: ghcr.io/agentsmith-project/agentsmith-web:2026.05.23-p0
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
spec:
  template:
    spec:
      containers:
        - name: web
          image: ${{ images.web.image }}
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
  case 'support-level-present':
    contract.target_profiles[0].support_level = 'primary';
    break;
  case 'kind-required':
    contract.target_profiles[2].required = true;
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
  local output_dir="$TMP_DIR/out-$label"

  if run_render \
    "$contract" \
    "$deploy_template_package" \
    "$archive" \
    "$render_values" \
    "$substrate_truth" \
    "$output_dir" \
    "$target_profile" \
    "$forbidden_source_root" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid render case to fail: $label"
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
if (!rendered.includes('postgresql.release.example.internal')) {
  throw new Error('rendered manifest must contain substrate truth values');
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
pass "valid render accepted with focused non-readiness report"

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

KIND_REQUIRED_CONTRACT="$TMP_DIR/release-contract.kind-required.json"
mutate_contract_target_profile kind-required \
  "$VALID_CONTRACT_MATERIAL" \
  "$KIND_REQUIRED_CONTRACT"
expect_fail_case kind-required-target-profile \
  "$KIND_REQUIRED_CONTRACT" \
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
