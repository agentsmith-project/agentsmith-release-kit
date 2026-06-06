# Online Existing Kubernetes Example

This directory is a minimal operator input pack template for
`online/use_existing`: deploy to an existing Kubernetes cluster and use
operator-declared PostgreSQL, MongoDB, Redis, object storage, and OIDC
endpoints.

The operator path is package-driven:

```bash
bash scripts/operator-release.sh --operator-inputs <operator-inputs-json-or-dir> --doctor
bash scripts/operator-release.sh --operator-inputs <operator-inputs-json-or-dir> --run
```

## Files

- `operator-inputs.apply.example.json`: package manifest for
  `online/use_existing` apply.
- `render-values.example.json`: namespace and replica values consumed by the
  deploy template package.
- `substrate-truth.example.json`: external substrate connection truth.
- `target-prerequisites.example.json`: namespace, RBAC, ingress, registry pull
  secret, storage, and matching substrate secret refs.

The example truth and prerequisite files are already bound to
`online/use_existing`. Keep their path identity fields unchanged. Replace
service endpoints, namespace, secret refs, storage values, and proof text with
values from the target environment.
The facade derives deployment identity from `deployment_path`; do not add
deployment identity fields to `substrate-truth.example.json` or
`target-prerequisites.example.json`.

## Build The Package

Set these paths to the real AgentSmith release artifacts, then stage one small
operator package:

```bash
RELEASE_CONTRACT="release-contract.json"
DEPLOY_TEMPLATE_PACKAGE="deploy-template-package.json"
DEPLOY_TEMPLATE_ARCHIVE="agentsmith-deploy-template-package.tgz"
EXAMPLE_DIR="examples/online-existing-kubernetes"
PKG="out/operator-inputs/online-existing-kubernetes"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp "$EXAMPLE_DIR/render-values.example.json" "$PKG/render-values.example.json"
cp "$EXAMPLE_DIR/substrate-truth.example.json" "$PKG/substrate-truth.example.json"
cp "$EXAMPLE_DIR/target-prerequisites.example.json" "$PKG/target-prerequisites.example.json"
cp "$RELEASE_CONTRACT" "$PKG/release-contract.json"
cp "$DEPLOY_TEMPLATE_PACKAGE" "$PKG/deploy-template-package.json"
cp "$DEPLOY_TEMPLATE_ARCHIVE" "$PKG/deploy-template-package.tgz"
```

`operator-inputs.json` uses package-relative refs. Real release artifacts must
be copied into the package, or the manifest refs must point to files inside the
same package.

Edit `"$PKG/operator-inputs.json"` before apply:

- Keep `deployment_path` as `online/use_existing`.
- Set `deploy_confirmation.operator_run_id` to the real operator run id.
- Optional route smoke can add `smoke_url`, `expected_status`, `timeout`, and
  `timeout_ms`; keep them omitted when route smoke is not in scope.

## Doctor

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
```

This lists missing package inputs without executing the selected path. It is
not runtime evidence and does not issue a GA verdict.

## Apply

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

For an apply manifest, a successful package run writes path-level evidence to
the package internal output for the later GA aggregate. A package run does not
write `ga-release-report.json`, does not issue `formal_verdict`, and does not
replace AgentSmith product readiness or post-deploy product smoke evidence.

## Final GA Report

After all four package runs and product-side reports are available, use the
final GA facade:

```bash
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <json> \
  --post-deploy-product-smoke-report <online-json> \
  --post-deploy-product-smoke-report <airgap-json> \
  --output-dir <dir>
```
