#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/verify-release.sh --quick
  bash scripts/verify-release.sh --inputs --release-contract <json> --deploy-template-package <json> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir>
  bash scripts/verify-release.sh --template-package --release-contract <json> --deploy-template-package <json> --archive <tgz> --output-dir <dir>
  bash scripts/verify-release.sh --evidence --release-contract <json> --evidence-root <dir> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir>
  bash scripts/verify-release.sh --help

Bootstrap status:
  --quick checks governance skeleton and boundary guardrails only.
  --inputs checks release contract intake only; it is not release readiness.
  --template-package checks materialized deploy template package intake only; it is not release readiness.
  --evidence checks release-kit evidence envelope intake only; it is not release readiness.
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
  --inputs)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-inputs.mjs" "$@"
    echo "inputs mode is not release readiness"
    ;;
  --template-package)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-template-package.mjs" "$@"
    echo "template-package mode is not release readiness"
    ;;
  --evidence)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-evidence.mjs" "$@"
    echo "evidence mode is not release readiness"
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
