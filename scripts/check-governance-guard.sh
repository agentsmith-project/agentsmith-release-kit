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
  case "$remote" in
    http://*)
      fail "origin must use https:// or git@github.com:, not http://"
      ;;
    https://github.com/*)
      remote="${remote#https://}"
      ;;
    git@github.com:*)
      remote="${remote#git@}"
      remote="${remote/:/\/}"
      ;;
    *)
      fail "origin must use https://github.com/ or git@github.com: form"
      ;;
  esac
  remote="${remote%.git}"
  echo "$remote"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing required file: $file"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fqi -- "$text" "$file" || fail "missing required text in $file: $text"
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

reject_operator_substrate_surface() {
  local paths=("$@")
  local label="install_substrates exposed as successful operator substrate surface"
  local hard_pattern='operator-release[.]sh[[:space:]]+(online|airgap|airgap-bundle)[[:space:]]+install_substrates|`(online|airgap|airgap-bundle)/install_substrates`[[:space:]]*(->|backed|requires|repo-local)|install_substrates[[:space:]]+maps|--substrate-strategy[[:space:]]+use_existing[|]install_substrates'
  local package_pair_pattern='`(online|airgap|airgap-bundle)/install_substrates`[[:space:]]+and'
  local allowed_context='operator-release[.]sh[[:space:]]+--operator-inputs[[:space:]]+<[^>]+>[[:space:]]+--run'
  local matches
  local file
  local line
  local text
  local start
  local end
  local context
  local found=0

  if ((${#paths[@]} == 0)); then
    return
  fi

  matches="$(grep -IInE -- "$hard_pattern" "${paths[@]}" || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches"
    found=1
  fi

  while IFS=: read -r file line text; do
    [[ -n "$file" && -n "$line" ]] || continue
    start=$((line > 3 ? line - 3 : 1))
    end=$((line + 3))
    context="$(sed -n "${start},${end}p" "$file")"
    if ! grep -Eqi -- "$allowed_context" <<<"$context"; then
      printf '%s:%s:%s\n' "$file" "$line" "$text"
      found=1
    fi
  done < <(grep -IInE -- "$package_pair_pattern" "${paths[@]}" || true)

  if ((found)); then
    fail "$label"
  fi
}

assert_development_default_commands_are_slim() {
  local default_block
  local forbidden

  default_block="$(
    awk '
      /^```bash$/ {
        if (!seen) {
          seen=1
          capture=1
          next
        }
      }
      /^```$/ && capture {
        exit
      }
      capture {
        print
      }
    ' DEVELOPMENT.md
  )"

  [[ -n "$default_block" ]] || fail "DEVELOPMENT.md must keep a default command block"

  for required in \
    'bash scripts/verify-release.sh --quick' \
    'bash scripts/test-operator-inputs.sh' \
    'bash scripts/test-operator-inputs-orchestration.sh' \
    'bash scripts/test-operator-release-surface.sh' \
    'bash scripts/test-substrate-install.sh' \
    'bash scripts/test-deployment-path-report.sh' \
    'bash scripts/test-ga-release.sh' \
    'bash scripts/test-package-driven-ga-smoke.sh'; do
    grep -Fq -- "$required" <<<"$default_block" || \
      fail "DEVELOPMENT.md default command block missing core command: $required"
  done

  forbidden='test-(image-map|registry-presence|bundle-create|airgap-bundle-check|airgap-image-archive-check|airgap-image-load|bundle-load-plan|airgap-bundle-render-check|airgap-deployment-gate|airgap-consume-rehearsal|airgap-adoption|substrate-pack-check|apply|rollout|smoke|online-deployment-gate|online-adoption|release-engineering-gate-intake|operator-runbook-acceptance|operator-signoff-intake|evidence|target-preflight)[.]sh'
  if grep -Eq -- "$forbidden" <<<"$default_block"; then
    printf '%s\n' "$default_block" | grep -En -- "$forbidden" >&2
    fail "DEVELOPMENT.md default command block must not include maintainer-only diagnostics"
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
  OWNERS.md
  DEVELOPMENT.md
  docs/RELEASE_GATES.md
  docs/contracts/README.md
  docs/runbooks/README.md
  docs/adr/0001-bootstrap-boundary.md
  .github/pull_request_template.md
  .github/workflows/ci.yml
  scripts/verify-release.sh
  scripts/verify-ga-release.mjs
  scripts/verify-deployment-path-report.mjs
  scripts/test-ga-release.sh
  scripts/test-deployment-path-report.sh
  scripts/check-governance-guard.sh
)

for file in "${required_files[@]}"; do
  require_file "$file"
done
pass "required bootstrap files"

require_text OWNERS.md "AgentSmith release-kit team"
pass "owner metadata"

assert_development_default_commands_are_slim
pass "development default command surface"

doc_policy_paths=(
  README.md
  DEVELOPMENT.md
  docs/RELEASE_GATES.md
  docs/contracts/README.md
  docs/runbooks/README.md
  scripts/verify-release.sh
  scripts/verify-release-engineering-gate-intake.mjs
)

operator_substrate_surface_paths=(
  README.md
  DEVELOPMENT.md
  docs/RELEASE_GATES.md
  docs/runbooks/README.md
  docs/contracts/README.md
  scripts/operator-release.sh
  scripts/verify-operator-release-surface.mjs
  scripts/verify-online-adoption.mjs
  scripts/verify-airgap-adoption.mjs
  scripts/verify-release-engineering-gate-intake.mjs
)

reject_scan \
  "formal operator release taxonomy wording found" \
  'formal operator release quadrants?|Formal Operator Quadrants|formal operator release profiles|operator-facing release quadrants?|operator release quadrants?|formal release quadrants?' \
  "${doc_policy_paths[@]}"

reject_scan \
  "formal-gate candidate wording found" \
  'formal[- ]gate candidate|repo-local formal[- ]gate|the only repo-local formal[- ]gate candidate boundary' \
  "${doc_policy_paths[@]}"

reject_scan \
  "stale formal operator verdict gap wording found" \
  'future formal operator verdict|formal_operator_verdict|does not yet have full deploy/package evidence' \
  "${doc_policy_paths[@]}" scripts/verify-release-engineering-gate-intake.mjs

reject_scan \
  "operator release choice wording found" \
  'operator release choices?' \
  "${doc_policy_paths[@]}"

reject_operator_substrate_surface "${operator_substrate_surface_paths[@]}"

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
require_text README.md "operator-facing path is a single package-driven facade"
require_text README.md 'bash scripts/operator-release.sh --operator-inputs <dir-or-json>'
require_text README.md "Formal release success"
require_text README.md 'final `ga-release-report.json` issued by'
require_text README.md 'release finalizer/captain'
require_text README.md '`online/use_existing`'
require_text README.md '`online/install_substrates`'
require_text README.md '`online/kit_provided`'
require_text README.md '`airgap/use_existing`'
require_text README.md '`airgap/install_substrates`'
require_text README.md '`airgap/kit_provided`'
require_text README.md 'removal target: release-kit v1.0.0 GA cut'
require_text README.md '`install_substrates` requires an explicit report from the separate'
require_text README.md 'kit-provided pack/truth identity marker / provenance marker'
require_text README.md 'not installer proof'
require_text README.md '`kind_rehearsal/kit_installed/online` remains rehearsal-only accepted input'
require_text README.md "is not a release profile, user deployment prerequisite, package-driven release"
require_text README.md "target, or replacement for real Kubernetes evidence"
require_text docs/runbooks/README.md "Use the single operator facade"
require_text docs/runbooks/README.md "Formal release success or failure is represented only by the final"
require_text docs/runbooks/README.md '`ga-release-report.json` issued by the release finalizer/captain'
require_text docs/runbooks/README.md "## Operator Package Matrix"
require_text docs/runbooks/README.md "Airgap bundle packaging commands are packaging-side helpers"
require_text docs/runbooks/README.md "not standalone operator choices"
require_text docs/runbooks/README.md 'use `airgap/kit_provided` for the consume/deployment-focused path'
require_text docs/runbooks/README.md 'removal target: release-kit v1.0.0 GA cut'
require_text docs/runbooks/README.md "provenance marker, not installer"
require_text docs/RELEASE_GATES.md "map to the operator choice surface"
require_text docs/RELEASE_GATES.md 'kit-provided pack/truth identity marker / provenance marker'
require_text docs/RELEASE_GATES.md 'removal target: release-kit v1.0.0 GA cut'
require_text docs/RELEASE_GATES.md "rehearsal-only accepted input"
require_text docs/contracts/README.md "Only accepted pre-GA profile tuples are accepted"
require_text docs/contracts/README.md "not an operator choice"
require_text docs/contracts/README.md '`installed_by` stays a provenance'
require_text DEVELOPMENT.md "There is intentionally no"
require_text DEVELOPMENT.md "package.json"
require_text DEVELOPMENT.md "four existing-Kubernetes operator choice mappings"
require_text DEVELOPMENT.md '`installed_by` is not'
require_text DEVELOPMENT.md '`kind_rehearsal/kit_installed/online` remains'
require_text DEVELOPMENT.md "rehearsal-only accepted input"
require_text DEVELOPMENT.md "profile, release target, or user deployment prerequisite"
require_text AGENTS.md "Quick gate success is never release readiness"
pass "scope and non-goals"

require_text docs/RELEASE_GATES.md "The quick gate is not release readiness"
require_text docs/RELEASE_GATES.md "Deployment Path Report Finalization Focused Diagnostic"
require_text docs/RELEASE_GATES.md "The GA release aggregate gate is the repo-local final verdict authority"
require_text docs/RELEASE_GATES.md "consumes finalized deployment path reports"
require_text scripts/verify-release.sh "--ga-release is the release-kit final GA aggregate"
require_text scripts/verify-release.sh "formal_verdict=issued"
require_text scripts/verify-release.sh "does not rerun producers"
require_text scripts/verify-release.sh "--operator-signoff-intake is maintainer-only for explicit GA or compliance trigger work"
if bash scripts/verify-release.sh >/dev/null 2>&1; then
  fail "verify-release.sh without an explicit mode must fail"
fi
pass "release gate authority boundary"

mapfile -d '' scan_paths < <(find . -path ./.git -prune -o -type f -print0)

afscp_mount_plan_contract="afscp-mount-plan"
afscp_mount_plan_contract+="-contract"

agentsmith_repo="agent"
agentsmith_repo+="smith"
fs_repo="${agentsmith_repo}-fs-control"
fs_repo+="-plane"
sandbox_repo="mbos-sandbox"
sandbox_repo+="-v1"
forbidden_runner_repo="${agentsmith_repo}-codex"
forbidden_runner_repo+="-runner"
forbidden_remote_repo_names="(${agentsmith_repo}|${fs_repo}|${sandbox_repo}|${forbidden_runner_repo})"
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
old_llmup_image="ghcr[.]io/agentsmith-project/llm"
old_llmup_image+="up"

reject_scan \
  "AgentSmith product source import or relative source path found" \
  '(^|[^[:alnum:]_])\.\./agentsmith(/|$)|/home/[^/[:space:]]+/works/[^/[:space:]]+/agentsmith(/|$)|from[[:space:]]+["'\''][^"'\'']*agentsmith|require\(["'\''][^"'\'']*agentsmith|packages/(api-entry-node|agent-task-runner|agent-runner|web|app)|src/(app)/|e2e/(stories)/|check-product-flows\.ts' \
  "${scan_paths[@]}"

reject_scan \
  "AFSCP or ASBCP source, contract, or gate dependency found" \
  "(^|[^[:alnum:]_])\\.\\./(agentsmith-fs-control-plane|mbos-sandbox-v1)(/|$)|/home/[^/[:space:]]+/works/[^/[:space:]]+/(agentsmith-fs-control-plane|mbos-sandbox-v1)(/|$)|agentsmith-fs-control-plane/(src|cmd|internal|pkg|deploy|migrations|scripts|docs)|mbos-sandbox-v1/(manager-service|k8s|scripts|docs)|verify-ga-release\\.sh|${afscp_mount_plan_contract}" \
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

reject_scan \
  "removed old input provider image name found" \
  "$old_llmup_image" \
  "${scan_paths[@]}"

reject_scan \
  "kind rehearsal prerequisite claim found" \
  '(^|[^[:alnum:]_])kind(_rehearsal)?[[:space:]]+(is|as)[[:space:]]+(a[[:space:]]+)?(required|mandatory|prerequisite)|(^|[^[:alnum:]_])kind(_rehearsal)?[[:space:]]+(must|shall)[[:space:]]+|(^|[^[:alnum:]_])(required|mandatory)[[:space:]]+kind(_rehearsal)?([[:space:]]+cluster|[[:space:]]+target)?' \
  "${scan_paths[@]}"

reject_scan \
  "kind rehearsal documented as canonical release profile" \
  'The canonical declarable target profiles are|canonical declarable (target |release )?profiles|canonical profile tuple(s)?|Only canonical profile tuples are accepted|five canonical target profiles|`kind_rehearsal/kit_installed/online` is a canonical|kind_rehearsal/kit_installed/online.*canonical.*(declarable|release|profile)' \
  "${doc_policy_paths[@]}"

reject_scan \
  "airgap-bundle/install_substrates documented as deploy execution" \
  'kit-installed airgap deploy' \
  "${doc_policy_paths[@]}"

require_text docs/RELEASE_GATES.md "No mutable image or non-digest release claim is present"
pass "boundary scans"

echo "PASS: quick identity and boundary guard"
