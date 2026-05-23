#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/verify-release.sh --quick
  bash scripts/verify-release.sh --help

Bootstrap status:
  --quick checks governance skeleton and boundary guardrails only.
  The full release gate is not implemented during bootstrap.
USAGE
}

case "${1:-}" in
  --quick)
    if [[ $# -ne 1 ]]; then
      echo "error: --quick does not accept extra arguments" >&2
      usage >&2
      exit 2
    fi
    bash "$ROOT_DIR/scripts/check-governance-guard.sh"
    echo "quick mode is not release readiness"
    ;;
  --help|-h)
    usage
    ;;
  "")
    usage
    echo
    echo "FAIL: full release gate is not implemented in bootstrap."
    echo "Run --quick only for bootstrap governance checks."
    exit 2
    ;;
  *)
    usage
    echo
    echo "FAIL: unknown argument: $1"
    exit 2
    ;;
esac
