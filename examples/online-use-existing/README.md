# Online Use Existing Example

This directory is a minimal operator input pack template for
`online/use_existing`: deploy to an operator-provided Kubernetes target and use
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
- `operator-inputs.target-registry.apply.example.json`: apply manifest variant
  that enables the target registry check.
- `render-values.example.json`: namespace and replica values consumed by the
  deploy template package.
- `substrate-truth.example.json`: external substrate connection truth.
- `target-prerequisites.example.json`: namespace, RBAC, ingress, registry auth
  mode, storage, and matching substrate secret refs.
- `tools/kubectl`: placeholder package-local kubectl wrapper/binary for apply.
- `tools/registry-probe`: placeholder package-local read-only probe for the
  target registry variant.

The example truth and prerequisite files are already bound to
`online/use_existing`. Keep `deployment_path` set to `online/use_existing`.
Replace service endpoints, namespace, secret refs, storage values, and proof
text with values from the target environment.
The facade chooses the path from `deployment_path`; do not add extra deployment
selection fields to `substrate-truth.example.json` or
`target-prerequisites.example.json`.

## Build The Package

Set these paths to the real AgentSmith release artifacts, then stage one small
operator package:

```bash
RELEASE_CONTRACT="release-contract.json"
DEPLOY_TEMPLATE_PACKAGE="deploy-template-package.json"
DEPLOY_TEMPLATE_ARCHIVE="agentsmith-deploy-template-package.tgz"
EXAMPLE_DIR="examples/online-use-existing"
PKG="out/operator-inputs/online-use-existing"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp "$EXAMPLE_DIR/render-values.example.json" "$PKG/render-values.example.json"
cp "$EXAMPLE_DIR/substrate-truth.example.json" "$PKG/substrate-truth.example.json"
cp "$EXAMPLE_DIR/target-prerequisites.example.json" "$PKG/target-prerequisites.example.json"
cp "$RELEASE_CONTRACT" "$PKG/release-contract.json"
cp "$DEPLOY_TEMPLATE_PACKAGE" "$PKG/deploy-template-package.json"
cp "$DEPLOY_TEMPLATE_ARCHIVE" "$PKG/deploy-template-package.tgz"
mkdir -p "$PKG/tools"
cp "$EXAMPLE_DIR/tools/kubectl" "$PKG/tools/kubectl"
```

For the target registry variant, run this after the block above to swap the
manifest and include the probe placeholder:

```bash
cp "$EXAMPLE_DIR/operator-inputs.target-registry.apply.example.json" "$PKG/operator-inputs.json"
cp "$EXAMPLE_DIR/tools/registry-probe" "$PKG/tools/registry-probe"
```

For package-driven `online/use_existing`, the target registry variant is
supported when the registry already contains digest refs for the release
images. `registry_probe` is a package-local read-only executable invoked as
`tools/registry-probe <target-image> <expected-digest>`; stdout must be
exactly the matching `sha256:<64>` digest. The package run does not mirror
images, push images, or perform registry login.

`operator-inputs.json` uses package-relative refs. Real release artifacts must
be copied into the package, or the manifest refs must point to files inside the
same package.

Edit `"$PKG/operator-inputs.json"` before apply:

- Keep `deployment_path` as `online/use_existing`.
- Replace `tools/kubectl` and set `context` to the target Kubernetes context.
- Set `smoke_url` to the HTTPS route smoke endpoint for this target.
- Set `deploy_confirmation.operator_run_id` to the real operator run id.
- When using the target registry variant, replace the placeholder
  `tools/registry-probe` before `--run`; it intentionally exits non-zero until
  replaced.
- Use `expected_status`, `timeout`, and `timeout_ms` only when the route smoke
  needs non-default checks.

## Doctor

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
```

This lists missing package refs/fields plus static package blockers without
executing the selected path. A passing doctor only means static package checks
passed; it is not runnable readiness or the final GA result. When doctor
fails, the human output groups blockers as release materials, operator target
facts, operator tools, and operator confirmations.

## Apply

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

A successful package run records package output for the later `--ga-report`.
It does not write `ga-release-report.json` and does not replace AgentSmith
product readiness or post-deploy product smoke reports.

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
