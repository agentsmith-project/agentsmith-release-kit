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
  bash scripts/verify-release.sh --render --release-contract <json> --deploy-template-package <json> --archive <tgz> --target-profile <target_cluster>/<substrate_source>/<distribution> --render-values <json> --substrate-truth <json> --output-dir <dir> [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --render-check --release-contract <json> --rendered-manifests <dir> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir> [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --image-map --release-contract <json> --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> --output-dir <dir> [--target-registry <registry-host[/namespace]>]
  bash scripts/verify-release.sh --airgap-bundle-check --release-contract <json> --deploy-template-package <json> --archive <tgz> --image-map <json> --target-profile existing_kubernetes/external_declared/airgap --bundle-root <dir> --bundle-manifest <json> --output-dir <dir>
  bash scripts/verify-release.sh --apply --release-contract <json> --rendered-manifests <dir> --target-profile existing_kubernetes/external_declared/online --namespace <name> --output-dir <dir> [--mode server-dry-run|apply] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --apply --release-contract <json> --rendered-manifests <dir> --target-profile existing_kubernetes/external_declared/online --namespace <name> --output-dir <dir> --mode apply --confirm-apply existing_kubernetes/external_declared/online --operator-run-id <id> [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --rollout --release-contract <json> --rendered-manifests <dir> --target-profile existing_kubernetes/external_declared/online --namespace <name> --output-dir <dir> [--timeout <duration>] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --smoke --release-contract <json> --rollout-report <json> --target-profile existing_kubernetes/external_declared/online --url <https-url> --output-dir <dir> [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost]
  bash scripts/verify-release.sh --online-deployment-gate --release-contract <json> --deploy-template-package <json> --archive <tgz> --target-profile existing_kubernetes/external_declared/online --render-values <json> --substrate-truth <json> --namespace <name> --output-dir <dir> [--mode server-dry-run|apply] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--confirm-apply existing_kubernetes/external_declared/online] [--operator-run-id <id>] [--timeout <duration>] [--smoke-url <https-url>] [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --evidence --release-contract <json> --evidence-root <dir> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir>
  bash scripts/verify-release.sh --target-preflight --target-profile <target_cluster>/<substrate_source>/<distribution> --substrate-truth <json> --output-dir <dir>
  bash scripts/verify-release.sh --help

Bootstrap status:
  --quick checks governance skeleton and boundary guardrails only.
  --inputs checks release contract intake only; it is not release readiness.
  --template-package checks materialized deploy template package intake only; it is not release readiness.
  --render renders repo-local materialized deploy templates only; it is not release readiness.
  --render-check checks rendered manifest image inventory only; it is not release readiness.
  --image-map writes digest-pinned source/target image reference mapping only; it is not release readiness.
  --airgap-bundle-check checks an airgap bundle manifest, deploy template archive digest, and declared file digests only; it is not release readiness.
  --apply runs Kubernetes apply-only validation or confirmed apply only; it is not release readiness.
  --rollout checks Kubernetes rollout status and live image digests only; it is not release readiness.
  --smoke checks one route status after a bound rollout report only; it is not release readiness.
  --online-deployment-gate runs the online focused chain in order only; it is not release readiness.
  --evidence checks release-kit evidence envelope intake only; it is not release readiness.
  --target-preflight checks substrate connection truth intake only; it is not release readiness.
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
  --render)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-render.mjs" "$@"
    echo "render mode is not release readiness"
    ;;
  --render-check)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-render-check.mjs" "$@"
    echo "render-check mode is not release readiness"
    ;;
  --image-map)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-image-map.mjs" "$@"
    echo "image-map mode is not release readiness"
    ;;
  --airgap-bundle-check)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-bundle-check.mjs" "$@"
    echo "airgap bundle check mode is not release readiness; readiness=false"
    ;;
  --apply)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-apply.mjs" "$@"
    echo "apply mode is not release readiness"
    ;;
  --rollout)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-rollout.mjs" "$@"
    echo "rollout mode is not release readiness"
    ;;
  --smoke)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-smoke.mjs" "$@"
    echo "smoke mode is not release readiness"
    ;;
  --online-deployment-gate)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-online-deployment-gate.mjs" "$@"
    echo "online focused chain mode is not release readiness"
    ;;
  --evidence)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-evidence.mjs" "$@"
    echo "evidence mode is not release readiness"
    ;;
  --target-preflight)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-target-preflight.mjs" "$@"
    echo "target-preflight mode is not release readiness"
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
