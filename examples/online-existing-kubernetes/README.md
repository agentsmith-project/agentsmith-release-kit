# Online Existing Kubernetes Example

This directory is a minimal operator input pack for
`existing_kubernetes/external_declared/online`: use an existing Kubernetes
cluster plus existing PostgreSQL, MongoDB, Redis, object storage, and OIDC
endpoints.

The JSON files are examples to copy and edit. They intentionally contain only
operator-declared endpoints, secret references, target prerequisites, render
values, and optional CI artifact provenance for an evidence-root run. They are
not cloud provisioning, substrate installation, registry mirroring, rollback,
operator identity verification, signature verification, product-flow
validation, deploy readiness, or release readiness.

## Inputs

- `render-values.example.json`: namespace and replica values consumed by the
  deploy template package.
- `substrate-truth.example.json`: external substrate connection truth.
- `target-prerequisites.example.json`: namespace, RBAC, ingress, registry pull
  secret, storage, and matching substrate secret refs.
- `evidence-provenance.example.json`: optional remote CI artifact provenance
  for `--evidence-root`; it does not claim operator signature or identity.

Set these paths to the real release artifacts from the AgentSmith release:

```bash
TARGET_PROFILE="existing_kubernetes/external_declared/online"
RELEASE_CONTRACT="release-contract.json"
DEPLOY_TEMPLATE_PACKAGE="deploy-template-package.json"
DEPLOY_TEMPLATE_ARCHIVE="agentsmith-deploy-template-package.tgz"
EXAMPLE_DIR="examples/online-existing-kubernetes"
```

## 1. Server Dry-Run

```bash
bash scripts/verify-release.sh --online-deployment-gate \
  --release-contract "$RELEASE_CONTRACT" \
  --deploy-template-package "$DEPLOY_TEMPLATE_PACKAGE" \
  --archive "$DEPLOY_TEMPLATE_ARCHIVE" \
  --target-profile "$TARGET_PROFILE" \
  --render-values "$EXAMPLE_DIR/render-values.example.json" \
  --substrate-truth "$EXAMPLE_DIR/substrate-truth.example.json" \
  --target-prerequisites "$EXAMPLE_DIR/target-prerequisites.example.json" \
  --namespace agentsmith \
  --output-dir out/online-existing-kubernetes/server-dry-run \
  --mode server-dry-run
```

This renders, checks image inventory, and runs Kubernetes server-side dry-run
apply. It stops before rollout and smoke.

## 2. Confirmed Apply

```bash
OPERATOR_RUN_ID="operator-run-20260523-001"
SMOKE_URL="https://agentsmith.ops.example.com/ok"

bash scripts/verify-release.sh --online-deployment-gate \
  --release-contract "$RELEASE_CONTRACT" \
  --deploy-template-package "$DEPLOY_TEMPLATE_PACKAGE" \
  --archive "$DEPLOY_TEMPLATE_ARCHIVE" \
  --target-profile "$TARGET_PROFILE" \
  --render-values "$EXAMPLE_DIR/render-values.example.json" \
  --substrate-truth "$EXAMPLE_DIR/substrate-truth.example.json" \
  --target-prerequisites "$EXAMPLE_DIR/target-prerequisites.example.json" \
  --namespace agentsmith \
  --output-dir out/online-existing-kubernetes/apply \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id "$OPERATOR_RUN_ID" \
  --timeout 120s \
  --smoke-url "$SMOKE_URL"
```

Omit `--smoke-url "$SMOKE_URL"` when route smoke is not part of the focused
operator run.

## Optional Evidence Root

```bash
bash scripts/verify-release.sh --online-deployment-gate \
  --release-contract "$RELEASE_CONTRACT" \
  --deploy-template-package "$DEPLOY_TEMPLATE_PACKAGE" \
  --archive "$DEPLOY_TEMPLATE_ARCHIVE" \
  --target-profile "$TARGET_PROFILE" \
  --render-values "$EXAMPLE_DIR/render-values.example.json" \
  --substrate-truth "$EXAMPLE_DIR/substrate-truth.example.json" \
  --target-prerequisites "$EXAMPLE_DIR/target-prerequisites.example.json" \
  --namespace agentsmith \
  --output-dir out/online-existing-kubernetes/apply-with-evidence \
  --mode apply \
  --confirm-apply "$TARGET_PROFILE" \
  --operator-run-id "$OPERATOR_RUN_ID" \
  --timeout 120s \
  --smoke-url "$SMOKE_URL" \
  --evidence-root out/online-existing-kubernetes/evidence \
  --evidence-provenance "$EXAMPLE_DIR/evidence-provenance.example.json"
```

The generated `online-deployment-gate-report.json` and generated reports remain
focused evidence with `readiness: false`; the optional evidence root does not
claim readiness.
