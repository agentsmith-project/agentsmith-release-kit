#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

EXPECTED_IDENTITY="github.com/agentsmith-project/agentsmith-release-kit"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

normalize_remote() {
  local remote="$1"
  remote="${remote%.git}"
  remote="${remote#https://}"
  remote="${remote#http://}"
  remote="${remote#git@}"
  remote="${remote/:/\/}"
  echo "$remote"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing required file: $file"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fqi "$text" "$file" || fail "missing required text in $file: $text"
}

reject_ecosystem_bootstrap_files() {
  local found

  found="$(
    find . -path ./.git -prune -o \( \
      -name package.json -o \
      -name package-lock.json -o \
      -name npm-shrinkwrap.json -o \
      -name pnpm-lock.yaml -o \
      -name yarn.lock -o \
      -name bun.lock -o \
      -name bun.lockb -o \
      -name go.mod -o \
      -name go.sum -o \
      -name 'requirements*.txt' -o \
      -name uv.lock -o \
      -name pyproject.toml -o \
      -name poetry.lock -o \
      -name Pipfile -o \
      -name Pipfile.lock -o \
      -name Cargo.toml -o \
      -name Cargo.lock -o \
      -name composer.json -o \
      -name composer.lock -o \
      -name Gemfile -o \
      -name Gemfile.lock -o \
      -name '*.lock' \
    \) -print -quit
  )"

  [[ -z "$found" ]] || fail "ecosystem bootstrap file is not allowed during bootstrap: $found"
}

reject_scan() {
  local label="$1"
  local pattern="$2"
  shift 2
  local paths=("$@")

  if ((${#paths[@]} == 0)); then
    return
  fi

  if grep -IInE -- "$pattern" "${paths[@]}"; then
    fail "$label"
  fi
}

reject_ecosystem_bootstrap_files

remote_url="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$remote_url" ]] || fail "origin remote is missing"

normalized_remote="$(normalize_remote "$remote_url")"
[[ "$normalized_remote" == "$EXPECTED_IDENTITY" ]] || \
  fail "expected canonical identity mismatch"
pass "canonical repo identity"

required_files=(
  README.md
  AGENTS.md
  DEVELOPMENT.md
  docs/RELEASE_GATES.md
  docs/contracts/README.md
  docs/runbooks/README.md
  docs/adr/0001-bootstrap-boundary.md
  docs/READINESS_EVIDENCE.md
  docs/RISK_REGISTER.md
  .github/pull_request_template.md
  .github/workflows/ci.yml
  scripts/verify-release.sh
  scripts/check-governance-guard.sh
)

for file in "${required_files[@]}"; do
  require_file "$file"
done
pass "required bootstrap files"

require_text README.md "$EXPECTED_IDENTITY"
require_text README.md "AgentSmith release contract"
require_text README.md "deploy template package"
require_text README.md "operator inputs"
require_text README.md "Online deploy"
require_text README.md "Airgap"
require_text README.md "deployment"
require_text README.md "AgentSmith product readiness"
require_text README.md "Visual"
require_text README.md "backend-real"
require_text README.md "product flow"
require_text README.md "Cloud resource provisioning"
require_text README.md "release management UI"
require_text README.md "kind_rehearsal"
require_text DEVELOPMENT.md "There is intentionally no"
require_text DEVELOPMENT.md "package.json"
require_text AGENTS.md "Quick gate success is never release readiness"
pass "scope and non-goals"

require_text docs/RELEASE_GATES.md "The quick gate is not release readiness"
require_text docs/RELEASE_GATES.md "The full release gate is the future repo-local authority"
require_text docs/RELEASE_GATES.md "not implemented during bootstrap"
require_text scripts/verify-release.sh "full release gate is not implemented in bootstrap"
if bash scripts/verify-release.sh >/dev/null 2>&1; then
  fail "full release mode must fail during bootstrap"
fi
pass "release gate bootstrap boundary"

mapfile -d '' scan_paths < <(find . -path ./.git -prune -o -type f -print0)

afscp_mount_plan_contract="afscp-mount-plan"
afscp_mount_plan_contract+="-contract"

agentsmith_repo="agent"
agentsmith_repo+="smith"
fs_repo="${agentsmith_repo}-fs-control"
fs_repo+="-plane"
sandbox_repo="mbos-sandbox"
sandbox_repo+="-v1"
legacy_runner_repo="${agentsmith_repo}-codex"
legacy_runner_repo+="-runner"
forbidden_remote_repo_names="(${agentsmith_repo}|${fs_repo}|${sandbox_repo}|${legacy_runner_repo})"
forbidden_remote_repo_path="([^[:space:]\"'/:]+/)?${forbidden_remote_repo_names}"
remote_repo_boundary="([.]git)?([/#?[:space:]\"']|$)"
checkout_remote_dependency_pattern="repository:[[:space:]]*[\"']?${forbidden_remote_repo_path}${remote_repo_boundary}"
github_remote_dependency_pattern="(https?://github[.]com/|git@github[.]com:)${forbidden_remote_repo_path}${remote_repo_boundary}"
git_remote_dependency_pattern="git[[:space:]]+(clone|fetch|submodule)[^[:cntrl:]]*${github_remote_dependency_pattern}"
raw_remote_dependency_pattern="https?://raw[.]githubusercontent[.]com/${forbidden_remote_repo_path}/"
raw_contract_gate_dependency_pattern="https?://raw[.]githubusercontent[.]com/[^[:space:]\"']+/[^[:space:]\"']+/[^[:space:]\"']+/(docs/contracts/|contracts/|[^[:space:]\"']*(gate|verify-[^/[:space:]\"']*release)[^[:space:]\"']*)"
remote_dependency_pattern="(${checkout_remote_dependency_pattern}|${git_remote_dependency_pattern}|${raw_remote_dependency_pattern}|${raw_contract_gate_dependency_pattern})"

latest_tag=":late"
latest_tag+="st"
mutable_tag_claim="mutable tag"
mutable_tag_claim+="(s)? (are )?(allowed|accepted|release-ready)"
image_refs_without_digest_claim="image refs without"
image_refs_without_digest_claim+=" digest (are )?(allowed|accepted|release-ready)"
non_digest_image_claim="non-digest image"
non_digest_image_claim+="(s)? (are )?(allowed|accepted|release-ready)"
mutable_image_claim_pattern="(${latest_tag}([^[:alnum:]_.-]|$)|${mutable_tag_claim}|${image_refs_without_digest_claim}|${non_digest_image_claim})"

reject_scan \
  "AgentSmith product source import or relative source path found" \
  '(^|[^[:alnum:]_])\.\./agentsmith(/|$)|/home/percy/works/mbos-v1/agentsmith(/|$)|from[[:space:]]+["'\''][^"'\'']*agentsmith|require\(["'\''][^"'\'']*agentsmith|packages/(api-entry-node|agent-task-runner|agent-runner|web|app)|src/(app)/|e2e/(stories)/|check-product-flows\.ts' \
  "${scan_paths[@]}"

reject_scan \
  "AFSCP or ASBCP source, contract, or gate dependency found" \
  "(^|[^[:alnum:]_])\\.\\./(agentsmith-fs-control-plane|mbos-sandbox-v1)(/|$)|/home/percy/works/mbos-v1/(agentsmith-fs-control-plane|mbos-sandbox-v1)(/|$)|agentsmith-fs-control-plane/(src|cmd|internal|pkg|deploy|migrations|scripts|docs)|mbos-sandbox-v1/(manager-service|k8s|scripts|docs)|verify-ga-release\\.sh|${afscp_mount_plan_contract}" \
  "${scan_paths[@]}"

reject_scan \
  "remote source, contract, or gate dependency found" \
  "$remote_dependency_pattern" \
  "${scan_paths[@]}"

reject_scan \
  "raw secret placeholder found" \
  '(PASSWORD|TOKEN|SECRET|CLIENT_SECRET|KUBECONFIG|AWS_SECRET_ACCESS_KEY|ACCESS_KEY_ID)[[:space:]]*[:=][[:space:]]*["'\'']?(changeme|change-me|example|dummy|password|secret|token|[A-Za-z0-9_./+=-]{8,})|sk-[A-Za-z0-9]{12,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY-----|(postgres|mongodb|redis)://[^[:space:]]+:[^@[:space:]]+@' \
  "${scan_paths[@]}"

reject_scan \
  "mutable image or non-digest release claim found" \
  "$mutable_image_claim_pattern" \
  "${scan_paths[@]}"

require_text docs/RELEASE_GATES.md "No mutable image or non-digest release claim is present"
pass "boundary scans"

echo "PASS: bootstrap quick governance guard"
