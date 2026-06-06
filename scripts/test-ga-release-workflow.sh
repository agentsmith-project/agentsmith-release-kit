#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/ga-release.yml"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
DEVELOPMENT="$ROOT_DIR/DEVELOPMENT.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing required file: ${file#$ROOT_DIR/}"
}

require_text() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "${file#$ROOT_DIR/} missing: $needle"
}

reject_text() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "${file#$ROOT_DIR/} must not contain: $needle"
  fi
}

reject_regex() {
  local file="$1"
  local pattern="$2"
  if grep -Eq -- "$pattern" "$file"; then
    grep -En -- "$pattern" "$file" >&2
    fail "${file#$ROOT_DIR/} contains forbidden pattern: $pattern"
  fi
}

require_file "$WORKFLOW"
require_file "$CI_WORKFLOW"
require_file "$DEVELOPMENT"

require_text "$WORKFLOW" "workflow_dispatch:"
reject_regex "$WORKFLOW" "^[[:space:]]+pull_request:"
reject_regex "$WORKFLOW" "^[[:space:]]+push:"

for input in \
  operator_packages_repository \
  operator_packages_run_id \
  product_reports_repository \
  product_reports_run_id \
  online_use_existing_artifact \
  online_install_substrates_artifact \
  airgap_use_existing_artifact \
  airgap_install_substrates_artifact \
  product_readiness_artifact \
  online_post_deploy_product_smoke_artifact \
  airgap_post_deploy_product_smoke_artifact \
  output_artifact_name; do
  require_text "$WORKFLOW" "$input:"
done

download_count="$(grep -Fc "uses: actions/download-artifact@v4" "$WORKFLOW")"
[[ "$download_count" -eq 7 ]] || fail "ga-release workflow must download exactly 7 required input artifacts"

require_text "$WORKFLOW" "secrets.AGENTSMITH_ARTIFACT_READ_TOKEN || github.token"
require_text "$WORKFLOW" "find_one_file"
require_text "$WORKFLOW" "find_package_dir"
require_text "$WORKFLOW" "write_workflow_failure_outputs"
require_text "$WORKFLOW" "AgentSmith GA release aggregate blocked before final report upload."
require_text "$WORKFLOW" "expected exactly one %s named %s"
require_text "$WORKFLOW" "operator-release.sh --ga-report failed before writing ga-release-report.json"
require_text "$WORKFLOW" "operator-inputs.json"
require_text "$WORKFLOW" "product-readiness-report.json"
require_text "$WORKFLOW" "default: agentsmith-product-readiness"
require_text "$WORKFLOW" "post-deploy-product-smoke-report.json"
require_text "$WORKFLOW" "AgentSmith online post-deploy product smoke report"
require_text "$WORKFLOW" "AgentSmith airgap post-deploy product smoke report"
require_text "$WORKFLOW" "bash scripts/operator-release.sh --ga-report"
require_text "$WORKFLOW" '--operator-inputs "$ONLINE_USE_EXISTING_PACKAGE"'
require_text "$WORKFLOW" '--operator-inputs "$ONLINE_INSTALL_SUBSTRATES_PACKAGE"'
require_text "$WORKFLOW" '--operator-inputs "$AIRGAP_USE_EXISTING_PACKAGE"'
require_text "$WORKFLOW" '--operator-inputs "$AIRGAP_INSTALL_SUBSTRATES_PACKAGE"'
require_text "$WORKFLOW" '--product-readiness-report "$PRODUCT_READINESS_REPORT"'
require_text "$WORKFLOW" '--post-deploy-product-smoke-report "$ONLINE_POST_DEPLOY_PRODUCT_SMOKE_REPORT"'
require_text "$WORKFLOW" '--post-deploy-product-smoke-report "$AIRGAP_POST_DEPLOY_PRODUCT_SMOKE_REPORT"'
require_text "$WORKFLOW" "uses: actions/upload-artifact@v4"
require_text "$WORKFLOW" "if: always()"
require_text "$WORKFLOW" "Verify final GA report files"
require_text "$WORKFLOW" "missing final GA output"
require_text "$WORKFLOW" "ga-release-report.json"
require_text "$WORKFLOW" "ga-release-summary.md"
require_text "$WORKFLOW" "ga-evidence-index.json"
require_text "$WORKFLOW" "if-no-files-found: error"
require_text "$ROOT_DIR/docs/RELEASE_GATES.md" "seven required input artifact names"

reject_text "$WORKFLOW" "bash scripts/verify-release.sh --ga-release"
reject_text "$WORKFLOW" "operator-release.sh --operator-inputs"
reject_text "$WORKFLOW" "agentsmith-product-readiness-report"
reject_text "$WORKFLOW" "--run"
reject_text "$WORKFLOW" "if-no-files-found: warn"
reject_text "$ROOT_DIR/docs/RELEASE_GATES.md" "the six artifact names"
reject_regex "$WORKFLOW" '\b(target_cluster|substrate_source|external_declared|kit_installed|existing_kubernetes|kind_rehearsal|target_profile)\b|operator-release-surface-report|operator-inputs-plan|adoption report|candidate intake|release-engineering|operator-signoff|--deployment-path-report'

require_text "$CI_WORKFLOW" "bash scripts/test-ga-release-workflow.sh"
require_text "$DEVELOPMENT" "bash scripts/test-ga-release-workflow.sh"

pass "manual GA workflow guard"
