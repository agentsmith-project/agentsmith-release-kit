#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
REPORT_FILE="release-engineering-gate-intake-report.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "missing text in $file: $text"
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "unexpected text in $file: $text"
  fi
}

assert_no_report() {
  local output_dir="$1"
  [[ ! -e "$output_dir/$REPORT_FILE" ]] || fail "retired intake wrote old report: $output_dir/$REPORT_FILE"
}

seed_stale_report() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '{"stale":true}\n' >"$output_dir/$REPORT_FILE"
  printf 'keep\n' >"$output_dir/keep.txt"
}

assert_keep_file() {
  local output_dir="$1"
  [[ -f "$output_dir/keep.txt" ]] || fail "retired intake removed unrelated file: $output_dir/keep.txt"
}

HELP_OUT="$TMP_DIR/help.out"
"$NODE_BIN" "$ROOT_DIR/scripts/verify-release-engineering-gate-intake.mjs" --help >"$HELP_OUT"
require_text "$HELP_OUT" "Retired compatibility guard"
require_text "$HELP_OUT" "--release-engineering-gate-intake is retired"
require_text "$HELP_OUT" "bash scripts/operator-release.sh --ga-report"
require_text "$HELP_OUT" "--operator-inputs <online-use-existing-pkg>"
require_text "$HELP_OUT" "--operator-inputs <online-install-substrates-pkg>"
require_text "$HELP_OUT" "--operator-inputs <airgap-use-existing-pkg>"
require_text "$HELP_OUT" "--operator-inputs <airgap-install-substrates-pkg>"
reject_text "$HELP_OUT" "--online-adoption-report"
reject_text "$HELP_OUT" "--airgap-adoption-report"
pass "retired intake help points to package-driven GA path"

DIRECT_OUTPUT="$TMP_DIR/direct-out"
seed_stale_report "$DIRECT_OUTPUT"
if "$NODE_BIN" "$ROOT_DIR/scripts/verify-release-engineering-gate-intake.mjs" \
  --release-contract "$TMP_DIR/missing-release-contract.json" \
  --online-adoption-report "$TMP_DIR/missing-online-adoption-report.json" \
  --airgap-adoption-report "$TMP_DIR/missing-airgap-adoption-report.json" \
  --output-dir "$DIRECT_OUTPUT" >"$TMP_DIR/direct.out" 2>"$TMP_DIR/direct.err"; then
  fail "retired intake direct invocation must fail"
fi
require_text "$TMP_DIR/direct.err" "--release-engineering-gate-intake is retired"
require_text "$TMP_DIR/direct.err" "$REPORT_FILE is no longer written"
require_text "$TMP_DIR/direct.err" "bash scripts/operator-release.sh --ga-report"
require_text "$TMP_DIR/direct.err" "--operator-inputs <online-use-existing-pkg>"
require_text "$TMP_DIR/direct.err" "--operator-inputs <online-install-substrates-pkg>"
require_text "$TMP_DIR/direct.err" "--operator-inputs <airgap-use-existing-pkg>"
require_text "$TMP_DIR/direct.err" "--operator-inputs <airgap-install-substrates-pkg>"
reject_text "$TMP_DIR/direct.err" "cannot read"
assert_no_report "$DIRECT_OUTPUT"
assert_keep_file "$DIRECT_OUTPUT"
pass "retired intake fails fast without consuming old adoption inputs"

WRAPPER_OUTPUT="$TMP_DIR/wrapper-out"
seed_stale_report "$WRAPPER_OUTPUT"
if bash "$ROOT_DIR/scripts/verify-release.sh" --release-engineering-gate-intake \
  --release-contract "$TMP_DIR/missing-release-contract.json" \
  --online-adoption-report "$TMP_DIR/missing-online-adoption-report.json" \
  --airgap-adoption-report "$TMP_DIR/missing-airgap-adoption-report.json" \
  --output-dir "$WRAPPER_OUTPUT" >"$TMP_DIR/wrapper.out" 2>"$TMP_DIR/wrapper.err"; then
  fail "verify-release retired intake mode must fail"
fi
require_text "$TMP_DIR/wrapper.err" "--release-engineering-gate-intake is retired"
require_text "$TMP_DIR/wrapper.err" "bash scripts/operator-release.sh --ga-report"
assert_no_report "$WRAPPER_OUTPUT"
assert_keep_file "$WRAPPER_OUTPUT"
pass "verify-release retired intake mode is compatibility guard only"

EMPTY_OUTPUT="$TMP_DIR/empty-wrapper-out"
mkdir -p "$EMPTY_OUTPUT"
if bash "$ROOT_DIR/scripts/verify-release.sh" --release-engineering-gate-intake \
  >"$TMP_DIR/empty-wrapper.out" 2>"$TMP_DIR/empty-wrapper.err"; then
  fail "verify-release retired intake mode without --help must fail"
fi
require_text "$TMP_DIR/empty-wrapper.err" "--release-engineering-gate-intake is retired"
assert_no_report "$EMPTY_OUTPUT"
pass "verify-release retired intake mode without args fails fast"

if ! bash "$ROOT_DIR/scripts/verify-release.sh" --release-engineering-gate-intake --help >"$TMP_DIR/wrapper-help.out"; then
  fail "verify-release retired intake help must succeed"
fi
require_text "$TMP_DIR/wrapper-help.out" "Retired compatibility guard"
require_text "$TMP_DIR/wrapper-help.out" "--operator-inputs <airgap-install-substrates-pkg>"
pass "verify-release retired intake help is available"

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/default.out" 2>"$TMP_DIR/default.err"; then
  fail "verify-release.sh without an explicit mode must fail"
fi
grep -q 'missing release verification mode' "$TMP_DIR/default.out" ||
  grep -q 'missing release verification mode' "$TMP_DIR/default.err" ||
  fail "default verify-release.sh must remain fail-closed"

pass "release engineering gate intake retirement guard completed"
