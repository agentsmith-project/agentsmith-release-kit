#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"

usage() {
  cat <<'USAGE'
Usage:
  # Operator-facing v0 facade:
  #   bash scripts/operator-release.sh online use_existing ...
  #   bash scripts/operator-release.sh online install_substrates ...
  #   bash scripts/operator-release.sh airgap use_existing ...
  #   bash scripts/operator-release.sh airgap-bundle use_existing ...
  #   bash scripts/operator-release.sh airgap-bundle install_substrates ...
  # verify-release.sh remains the producer catalog and focused diagnostic entry.
  bash scripts/verify-release.sh --quick
  bash scripts/verify-release.sh --inputs --release-contract <json> --deploy-template-package <json> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir>
  bash scripts/verify-release.sh --template-package --release-contract <json> --deploy-template-package <json> --archive <tgz> --output-dir <dir>
  bash scripts/verify-release.sh --render --release-contract <json> --deploy-template-package <json> --archive <tgz> --target-profile <target_cluster>/<substrate_source>/<distribution> --render-values <json> --substrate-truth <json> --output-dir <dir> [--image-map <json>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --render-check --release-contract <json> --rendered-manifests <dir> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir> [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --image-map --release-contract <json> --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> --output-dir <dir> [--target-registry <registry-host[/namespace]>]
  bash scripts/verify-release.sh --registry-presence --release-contract <json> --image-map <json> --target-profile existing_kubernetes/external_declared/online --registry-probe <executable> --output-dir <dir>
  bash scripts/verify-release.sh --bundle-create --release-contract <json> --deploy-template-package <json> --archive <tgz> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --target-registry <registry-host[/namespace]> --image-archive <image_id=local-file> [--image-archive <image_id=local-file> ...] --runbook <file> --script <file> --profile-values-schema <file> [--profile-values-example <file>] [--substrate-pack-manifest <json> for kit_installed] --operator-prerequisites <json> --bundle-root <dir> --output-dir <dir>
  bash scripts/verify-release.sh --airgap-bundle-check --release-contract <json> --deploy-template-package <json> --archive <tgz> --image-map <json> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --bundle-root <dir> --bundle-manifest <json> --output-dir <dir>
  bash scripts/verify-release.sh --airgap-image-archive-check --release-contract <json> --deploy-template-package <json> --archive <tgz> --image-map <json> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --bundle-root <dir> --bundle-manifest <json> --archive-probe <executable> --output-dir <dir>
  bash scripts/verify-release.sh --airgap-image-load --release-contract <json> --deploy-template-package <json> --archive <tgz> --image-map <json> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --bundle-root <dir> --bundle-manifest <json> --archive-probe <executable> --image-loader <executable> --output-dir <dir>
  bash scripts/verify-release.sh --bundle-load-plan --release-contract <json> --deploy-template-package <json> --archive <tgz> --image-map <json> --target-profile existing_kubernetes/external_declared/airgap --bundle-root <dir> --bundle-manifest <json> --output-dir <dir>
  bash scripts/verify-release.sh --airgap-bundle-render-check --release-contract <bundle-local-json> --deploy-template-package <bundle-local-json> --archive <bundle-local-tgz> --image-map <bundle-local-json> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --bundle-root <dir> --bundle-manifest <bundle-local-json> --render-values <bundle-local-json> --substrate-truth <bundle-local-json> --output-dir <dir>
  bash scripts/verify-release.sh --airgap-deployment-gate --release-contract <bundle-local-json> --deploy-template-package <bundle-local-json> --archive <bundle-local-tgz> --image-map <bundle-local-json> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --bundle-root <dir> --bundle-manifest <bundle-local-json> --render-values <bundle-local-json> --substrate-truth <bundle-local-json> --target-prerequisites <json> --namespace <name> --output-dir <dir> --mode server-dry-run [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --airgap-deployment-gate --release-contract <bundle-local-json> --deploy-template-package <bundle-local-json> --archive <bundle-local-tgz> --image-map <bundle-local-json> --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap --bundle-root <dir> --bundle-manifest <bundle-local-json> --render-values <bundle-local-json> --substrate-truth <bundle-local-json> --target-prerequisites <json> --namespace <name> --output-dir <dir> --mode apply --archive-probe <executable> --image-loader <executable> --confirm-apply <matching-target-profile> --operator-run-id <id> [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--timeout <duration>] [--smoke-url <https-url>] [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --airgap-consume-rehearsal --bundle-root <dir> [--bundle-manifest <bundle-local-json>] --render-values <bundle-local-json> --substrate-truth <bundle-local-json> --target-prerequisites <json> --namespace <name> --output-dir <dir> [--rehearsal-label existing_kubernetes|kind_rehearsal] [--mode server-dry-run|apply] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--archive-probe <executable>] [--image-loader <executable>] [--confirm-apply <matching-bundle-target-profile>] [--operator-run-id <id>] [--timeout <duration>] [--smoke-url <https-url>] [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --airgap-adoption --release-contract <json> --bundle-surface-report <airgap-bundle/operator-release-surface-report.json> --consume-surface-report <airgap/operator-release-surface-report.json> --bundle-manifest <airgap-bundle-manifest.json> --output-dir <dir>
  bash scripts/verify-release.sh --substrate-pack-check --target-profile existing_kubernetes/kit_installed/<online|airgap> --substrate-pack-manifest <json> --substrate-truth <json> --output-dir <dir>
  bash scripts/verify-release.sh --substrate-routability --target-profile existing_kubernetes/kit_installed/online --substrate-pack-check-report <json> --substrate-truth <json> --target-prerequisites <json> --namespace <name> --kubectl <path-or-command> --routability-probe <executable> --output-dir <dir> [--context <name>] [--kubeconfig <path>] [--timeout-ms <ms>]
  bash scripts/verify-release.sh --apply --release-contract <json> --rendered-manifests <dir> --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> --namespace <name> --output-dir <dir> [--mode server-dry-run|apply] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --apply --release-contract <json> --rendered-manifests <dir> --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> --namespace <name> --output-dir <dir> --mode apply --confirm-apply <matching-target-profile> --operator-run-id <id> [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --rollout --release-contract <json> --rendered-manifests <dir> --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> --namespace <name> --output-dir <dir> [--timeout <duration>] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --smoke --release-contract <json> --rollout-report <json> --target-profile existing_kubernetes/<external_declared|kit_installed>/<online|airgap> --url <https-url> --output-dir <dir> [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost]
  bash scripts/verify-release.sh --online-deployment-gate --release-contract <json> --deploy-template-package <json> --archive <tgz> --target-profile existing_kubernetes/external_declared/online --render-values <json> --substrate-truth <json> --target-prerequisites <json> --namespace <name> --output-dir <dir> [--mode server-dry-run|apply] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--confirm-apply existing_kubernetes/external_declared/online] [--operator-run-id <id>] [--timeout <duration>] [--smoke-url <https-url>] [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost] [--target-registry <registry-host[/namespace]>] [--registry-probe <executable>] [--evidence-root <dir> --evidence-provenance <json>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --online-deployment-gate --release-contract <json> --deploy-template-package <json> --archive <tgz> --target-profile existing_kubernetes/kit_installed/online --render-values <json> --substrate-truth <json> --target-prerequisites <json> --substrate-pack-manifest <json> --routability-probe <executable> --namespace <name> --output-dir <dir> [--mode server-dry-run|apply] [--kubeconfig <path>] [--context <name>] [--kubectl <path>] [--confirm-apply existing_kubernetes/kit_installed/online] [--operator-run-id <id>] [--timeout <duration>] [--smoke-url <https-url>] [--expected-status <code>] [--timeout-ms <ms>] [--allow-http] [--allow-localhost] [--evidence-root <dir> --evidence-provenance <json>] [--forbidden-source-root <dir>]
  bash scripts/verify-release.sh --online-adoption --release-contract <json> --use-existing-report <online-deployment-gate-report.json> --use-existing-evidence-root <dir> --install-substrates-report <online-deployment-gate-report.json> --install-substrates-evidence-root <dir> --output-dir <dir>
  bash scripts/verify-release.sh --operator-signoff-intake --release-contract <json> --online-deployment-gate-report <json> --operator-signoff-intake <json> --target-profile existing_kubernetes/external_declared/online --output-dir <dir>
  bash scripts/verify-release.sh --evidence --release-contract <json> --evidence-root <dir> --target-profile <target_cluster>/<substrate_source>/<distribution> --output-dir <dir>
  bash scripts/verify-release.sh --target-preflight --target-profile <target_cluster>/<substrate_source>/<distribution> --substrate-truth <json> --target-prerequisites <json> --output-dir <dir> [--expected-namespace <name>]
  bash scripts/verify-release.sh --help

Bootstrap status:
  --quick checks repo identity and boundary guardrails only.
  --inputs checks release contract intake only; it is not release readiness.
  --template-package checks materialized deploy template package intake only; it is not release readiness.
  --render renders repo-local materialized deploy templates only; it is not release readiness.
  --render-check checks rendered manifest image inventory only; it is not release readiness.
  --image-map writes digest-pinned source/target image reference mapping only; it is not release readiness.
  --registry-presence checks target registry digest-ref presence through an operator probe only; it is not release readiness.
  --bundle-create assembles a local airgap bundle and immediately runs airgap-bundle-check only; it is not release readiness.
  --airgap-bundle-check checks an airgap bundle manifest, deploy template archive digest, payload/tool declarations, and declared file digests only; it is not release readiness.
  --airgap-image-archive-check checks already assembled airgap image archive file materiality through a local read-only probe only; it is not package, load/import, offline install, deploy, registry, or release readiness.
  --airgap-image-load runs existing airgap image archive materiality first, then calls an operator-provided image loader once per image archive only; it is not offline install, deploy, package, registry, or release readiness.
  --bundle-load-plan checks an already assembled airgap bundle through airgap-bundle-check and writes a read-only load plan summary only; it is not release readiness or registry execution.
  --airgap-bundle-render-check renders an already assembled airgap bundle offline and runs rendered manifest image inventory check only; it is not package, offline install, deploy, registry, apply, smoke, or release readiness.
  --airgap-deployment-gate runs the airgap focused chain for existing Kubernetes external-declared or kit-installed airgap targets only; kit-installed adds substrate-pack-check but not substrate installation. It is not package, offline install, registry mirror, operator signoff, or release readiness.
  --airgap-consume-rehearsal discovers bundle components from an already assembled bundle, then runs bundle-check plus the airgap focused chain; --rehearsal-label is operator-provided label-only metadata and does not change the target profile or prove kind; it is not package, offline install, registry mirror, operator signoff, deploy, or release readiness.
  --airgap-adoption aggregates already generated airgap-bundle/use_existing and confirmed-apply airgap/use_existing operator summaries for repo-local adoption preparation only; it is not deploy, package, operator signoff, full release gate, or release readiness.
  --substrate-pack-check checks only a kit-installed substrate pack manifest and matching substrate truth for existing Kubernetes online/airgap targets; it is not substrate installation, deploy, package, or release readiness.
  --substrate-routability checks only existing Kubernetes / kit-installed / online substrate endpoint routability through an operator pod-network probe; it is not substrate installation, deploy, package, or release readiness.
  --apply runs Kubernetes apply-only validation or confirmed apply only; it is not release readiness.
  --rollout checks Kubernetes rollout status and live image digests only; it is not release readiness.
  --smoke checks one route status after a bound rollout report only; it is not release readiness.
  --online-deployment-gate runs the online focused chain in order only for existing Kubernetes external-declared online and kit-installed online targets; kit-installed online requires --substrate-pack-manifest and --routability-probe. Optional evidence output is a validated focused envelope for external-declared online or kit-installed online, not release readiness.
  --online-deployment-gate evidence args are accepted only with --mode apply.
  --online-adoption aggregates already generated confirmed-apply online/use_existing and online/install_substrates focused reports/evidence roots for repo-local adoption preparation only; it is not deploy, package, operator signoff, full release gate, or release readiness.
  --operator-signoff-intake checks an operator signoff intake JSON against a generated online deployment gate apply report only; it is not signature, identity, registry, deploy, package, or release readiness.
  --evidence checks release-kit evidence envelope intake only; it is not release readiness.
  --target-preflight checks substrate truth plus target prerequisite truth intake only; it is not release readiness.
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
  --registry-presence)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-registry-presence.mjs" "$@"
    echo "registry-presence mode is not release readiness; readiness=false"
    ;;
  --bundle-create)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-bundle-create.mjs" "$@"
    echo "bundle create mode is not release readiness; readiness=false"
    ;;
  --airgap-bundle-check)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-bundle-check.mjs" "$@"
    echo "airgap bundle check mode is not release readiness; readiness=false"
    ;;
  --airgap-image-archive-check)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-image-archive-check.mjs" "$@"
    echo "airgap image archive check mode is not release readiness; readiness=false"
    ;;
  --airgap-image-load)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-image-load.mjs" "$@"
    echo "airgap image load mode is not release readiness; readiness=false"
    ;;
  --bundle-load-plan)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-bundle-load-plan.mjs" "$@"
    echo "bundle load plan mode is not release readiness; readiness=false"
    ;;
  --airgap-bundle-render-check)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-bundle-render-check.mjs" "$@"
    echo "airgap bundle render check mode is not release readiness; readiness=false"
    ;;
  --airgap-deployment-gate)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-deployment-gate.mjs" "$@"
    echo "airgap deployment focused chain mode is not release readiness; readiness=false"
    ;;
  --airgap-consume-rehearsal)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-consume-rehearsal.mjs" "$@"
    echo "airgap consume rehearsal mode is not release readiness; readiness=false"
    ;;
  --airgap-adoption)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-airgap-adoption.mjs" "$@"
    echo "airgap adoption aggregation mode is not release readiness; readiness=false"
    ;;
  --substrate-pack-check)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-substrate-pack-check.mjs" "$@"
    echo "substrate pack check mode is not release readiness; readiness=false"
    ;;
  --substrate-routability)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-substrate-routability.mjs" "$@"
    echo "substrate routability mode is not release readiness; readiness=false"
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
  --online-adoption)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-online-adoption.mjs" "$@"
    echo "online adoption aggregation mode is not release readiness; readiness=false"
    ;;
  --operator-signoff-intake)
    shift
    "$NODE_BIN" "$ROOT_DIR/scripts/verify-operator-signoff-intake.mjs" "$@"
    echo "operator signoff intake mode is not release readiness; readiness=false"
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
    echo "Run --quick only for bootstrap identity and boundary checks."
    exit 2
    ;;
  *)
    usage
    echo
    echo "FAIL: unknown argument: $1"
    exit 2
    ;;
esac
