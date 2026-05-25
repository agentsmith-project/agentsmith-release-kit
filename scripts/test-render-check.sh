#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
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

run_render_check() {
  local rendered_manifests="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"
  local release_contract="${4:-$VALID_CONTRACT}"
  local forbidden_source_root="${5:-}"

  local command=(
    bash "$ROOT_DIR/scripts/verify-release.sh" --render-check
    --release-contract "$release_contract" \
    --rendered-manifests "$rendered_manifests" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir"
  )
  if [[ -n "$forbidden_source_root" ]]; then
    command+=(--forbidden-source-root "$forbidden_source_root")
  fi

  "${command[@]}"
}

expect_fail() {
  local label="$1"
  local mutation="${2:-$label}"
  local rendered_manifests="$TMP_DIR/manifests-$label"
  local output_dir="$TMP_DIR/out-$label"

  write_manifests "$rendered_manifests" "$mutation"

  if run_render_check "$rendered_manifests" "$output_dir" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid render/check case to fail: $label"
  fi

  pass "invalid render/check rejected: $label"
}

expect_target_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local rendered_manifests="$TMP_DIR/manifests-target-$label"
  local output_dir="$TMP_DIR/out-target-$label"

  write_manifests "$rendered_manifests" valid

  if run_render_check "$rendered_manifests" "$output_dir" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  if ! grep -q "canonical profiles" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected canonical target profile message for: $label"
  fi

  pass "canonical profiles only; non-canonical pre-GA name or synonym axis rejected: $label"
}

expect_forbidden_root_cli_fail() {
  local label="$1"
  local rendered_manifests="$TMP_DIR/manifests-forbidden-root-$label"
  local output_dir="$TMP_DIR/out-forbidden-root-$label"
  local forbidden_source_root="$TMP_DIR/missing-forbidden-source-root-$label"

  write_manifests "$rendered_manifests" valid

  if run_render_check "$rendered_manifests" "$output_dir" "$TARGET_PROFILE" "$VALID_CONTRACT" "$forbidden_source_root" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected forbidden source root CLI case to fail: $label"
  fi

  if ! grep -Eq "forbidden source root.*exist|forbidden source root.*directory" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected forbidden source root CLI message for: $label"
  fi

  pass "forbidden source root CLI rejected: $label"
}

expect_source_path_fail() {
  local label="$1"
  local mode="$2"
  local rendered_manifests="$TMP_DIR/manifests-source-$label"
  local output_dir="$TMP_DIR/out-source-$label"
  local bad_contract="$VALID_CONTRACT"
  local forbidden_source_root="$TMP_DIR/forbidden-product-source-$label"

  write_manifests "$rendered_manifests" valid
  mkdir -p "$forbidden_source_root"

  if [[ "$mode" == "release_contract" ]]; then
    bad_contract="$forbidden_source_root/release-contract.json"
  elif [[ "$mode" == "rendered_root_canonical_alias" ]]; then
    local canonical_forbidden_source_root="$TMP_DIR/canonical-forbidden-product-source-$label"
    rendered_manifests="$canonical_forbidden_source_root/rendered-manifests"
    forbidden_source_root="$TMP_DIR/forbidden-product-source-link-$label"
    write_manifests "$rendered_manifests" valid
    ln -s "$canonical_forbidden_source_root" "$forbidden_source_root"
  elif [[ "$mode" == "rendered_root_symlink" ]]; then
    "$NODE_BIN" --input-type=module - "$forbidden_source_root" "$rendered_manifests" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const [forbiddenSourceRoot, renderedManifests] = process.argv.slice(2);
const target = path.join(forbiddenSourceRoot, 'rendered-manifests');
fs.mkdirSync(target, { recursive: true });
fs.rmSync(renderedManifests, { recursive: true, force: true });
fs.symlinkSync(target, renderedManifests, 'dir');
NODE
  else
    fail "unknown source path fail mode: $mode"
  fi

  if run_render_check "$rendered_manifests" "$output_dir" "$TARGET_PROFILE" "$bad_contract" "$forbidden_source_root" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected source path boundary case to fail: $label"
  fi

  if ! grep -Eq "forbidden product source|product source tree|forbidden source" "$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected source path boundary message for: $label"
  fi

  pass "source path boundary rejected: $label"
}

assert_pass_report() {
  local report_file="$1"
  "$NODE_BIN" --input-type=module - "$report_file" <<'NODE'
import fs from 'node:fs';

const [reportFile] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const serialized = JSON.stringify(report);

if (report.schema !== 'agentsmith.render-check-report/v1') {
  throw new Error(`unexpected schema: ${report.schema}`);
}
if (report.scope !== 'render_check_image_inventory_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('render/check report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if ('release_verdict' in report || 'verdict' in report || 'deploy_readiness' in report) {
  throw new Error('render/check report must not claim a verdict or deploy readiness');
}
if (/required_product_flows|product_flows|product_flow_results/.test(serialized)) {
  throw new Error('render/check report must not include AgentSmith product flow fields');
}
if (!Array.isArray(report.images) || report.images.length !== 5) {
  throw new Error('render/check report must list the five workload images used by the fixture');
}
if (!Array.isArray(report.manifests) || report.manifests.length !== 3) {
  throw new Error('render/check report must list the three workload manifests used by the fixture');
}
NODE
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
const image = (id) => {
  const value = inventory.get(id);
  if (!value) {
    throw new Error(`missing fixture image id: ${id}`);
  }
  return value;
};

fs.mkdirSync(renderedManifests, { recursive: true });

let webImage = image('web');
if (mutation === 'unknown_image') {
  webImage = `ghcr.io/agentsmith-project/not-in-contract:${contract.release_id}@sha256:${'9'.repeat(64)}`;
}
if (mutation === 'tag_only_image') {
  webImage = webImage.replace(/@sha256:[0-9a-f]{64}$/, '');
}
if (mutation === 'digest_mismatch') {
  webImage = webImage.replace(/@sha256:[0-9a-f]{64}$/, `@sha256:${'9'.repeat(64)}`);
}

const deployment = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentsmith-web
spec:
  template:
    spec:
      initContainers:
        - name: schema
          image: ${image('product_schema_bootstrap')}
      containers:
        - name: web
          image: ${webImage}
`;

const job = {
  apiVersion: 'batch/v1',
  kind: 'Job',
  metadata: {
    name: 'agentsmith-api-migration'
  },
  spec: {
    template: {
      spec: {
        containers: [
          {
            name: 'api',
            image: image('api')
          }
        ],
        initContainers: []
      }
    }
  }
};

const cronJob = `apiVersion: batch/v1
kind: CronJob
metadata:
  name: agentsmith-maintenance
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          initContainers:
            - name: ingress-check
              image: ${image('ingress_nginx_controller')}
          containers:
            - name: llmup
              image: ${image('llmup')}
`;

fs.writeFileSync(path.join(renderedManifests, 'deployment.yaml'), deployment);
fs.writeFileSync(path.join(renderedManifests, 'job.json'), `${JSON.stringify(job, null, 2)}\n`);
fs.writeFileSync(path.join(renderedManifests, 'cronjob.yml'), cronJob);

if (mutation === 'secret_payload') {
  fs.writeFileSync(
    path.join(renderedManifests, 'secret-looking-config.yaml'),
    `apiVersion: v1
kind: ConfigMap
metadata:
  name: unsafe-config
data:
  client_secret: not-real-credential-value
`
  );
}

if (mutation === 'safe_secret_refs') {
  fs.writeFileSync(
    path.join(renderedManifests, 'safe-secret-refs.yaml'),
    `apiVersion: v1
kind: ConfigMap
metadata:
  name: safe-config
data:
  client_secret: secretRef:oidc-client
  password: operator_secret_ref
  token: redacted
`
  );
}

if (mutation === 'yaml_list_unknown_image') {
  fs.writeFileSync(
    path.join(renderedManifests, 'list.yaml'),
    `apiVersion: v1
kind: List
items:
  - apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: hidden-list-workload
    spec:
      template:
        spec:
          containers:
            - name: hidden
              image: ghcr.io/agentsmith-project/hidden:${contract.release_id}@sha256:${'9'.repeat(64)}
`
  );
}

if (mutation === 'flow_style_object_unknown_image') {
  fs.writeFileSync(
    path.join(renderedManifests, 'flow-object.yaml'),
    `apiVersion: apps/v1
kind: Deployment
metadata:
  name: flow-object
spec:
  template:
    spec:
      initContainers:
        - name: schema
          image: ${image('product_schema_bootstrap')}
      containers:
        - { name: hidden, image: ghcr.io/agentsmith-project/hidden:${contract.release_id}@sha256:${'9'.repeat(64)} }
`
  );
}

if (mutation === 'flow_style_inline_list_unknown_image') {
  fs.writeFileSync(
    path.join(renderedManifests, 'flow-inline-list.yaml'),
    `apiVersion: apps/v1
kind: Deployment
metadata:
  name: flow-inline-list
spec:
  template:
    spec:
      initContainers:
        - name: schema
          image: ${image('product_schema_bootstrap')}
      containers: [{ name: hidden, image: ghcr.io/agentsmith-project/hidden:${contract.release_id}@sha256:${'9'.repeat(64)} }]
`
  );
}

if (mutation === 'commented_doc_separator_unknown_image') {
  fs.writeFileSync(
    path.join(renderedManifests, 'commented-doc-separator.yaml'),
    `apiVersion: v1
kind: ConfigMap
metadata:
  name: harmless-first-doc
data:
  mode: diagnostic
--- # rendered workload follows
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hidden-after-commented-separator
spec:
  template:
    spec:
      containers:
        - name: hidden
          image: ghcr.io/agentsmith-project/hidden:${contract.release_id}@sha256:${'9'.repeat(64)}
`
  );
}

if (mutation === 'symlink_escape') {
  const outside = path.join(path.dirname(renderedManifests), 'outside-workload.yaml');
  fs.writeFileSync(outside, deployment);
  fs.symlinkSync(outside, path.join(renderedManifests, 'escape.yaml'));
}
NODE
}

valid_manifests="$TMP_DIR/manifests-valid"
valid_output="$TMP_DIR/out-valid"
write_manifests "$valid_manifests" valid
run_render_check "$valid_manifests" "$valid_output"
assert_pass_report "$valid_output/render-report.json"
pass "valid Deployment, Job, and CronJob accepted with non-readiness report"

safe_secret_manifests="$TMP_DIR/manifests-safe-secret-refs"
safe_secret_output="$TMP_DIR/out-safe-secret-refs"
write_manifests "$safe_secret_manifests" safe_secret_refs
run_render_check "$safe_secret_manifests" "$safe_secret_output"
assert_pass_report "$safe_secret_output/render-report.json"
pass "safe secretRef and redacted manifest values accepted"

expect_fail unknown_image
expect_fail tag_only_image
expect_fail digest_mismatch
expect_fail yaml_list_unknown_image
expect_fail flow_style_object_unknown_image
expect_fail flow_style_inline_list_unknown_image
expect_fail commented_doc_separator_unknown_image
expect_target_profile_fail noncanonical_local_kind "local-kind/external_declared/online"
expect_target_profile_fail noncanonical_kind_external_declared "kind_rehearsal/external_declared/online"
expect_fail secret_payload
expect_fail symlink_escape
expect_forbidden_root_cli_fail missing_forbidden_root
expect_source_path_fail release_contract_source_path release_contract
expect_source_path_fail rendered_root_canonical_alias rendered_root_canonical_alias
expect_source_path_fail rendered_root_source_symlink rendered_root_symlink

pass "render/check focused diagnostic tests completed"
