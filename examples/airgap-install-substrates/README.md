# Airgap Install Substrates Example

This directory is a minimal operator input pack template for
`airgap/install_substrates`: install namespace-scoped kit substrates, then
deploy AgentSmith from a bundle-local airgap release.

Release/material inputs are bundle-local. Operator tools such as `kubectl`,
`archive_probe`, and `image_loader` are package-local executables and may live
outside the bundle.

Secrets stay outside the package. Use `secretRef:` values only.

The bundle manifest and bundle-local install inputs are already bound to
`airgap/install_substrates`. Keep their path identity fields unchanged.
Replace bundle components, component checksums, namespace, service refs,
package-local tools, and confirmation fields.
The installer derives its deployment identity from `deployment_path`; do not
add deployment identity fields to the bundle-local target prerequisites or
install inputs.

## Build The Package

```bash
EXAMPLE_DIR="examples/airgap-install-substrates"
PKG="out/operator-inputs/airgap-install-substrates"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp -R "$EXAMPLE_DIR/airgap-bundle" "$PKG/airgap-bundle"
cp -R "$EXAMPLE_DIR/tools" "$PKG/tools"
```

Replace the files under `"$PKG/airgap-bundle/components"` with the real
bundle-local release contract, deploy template package, deploy template
archive, image map, and substrate pack manifest. Update
`airgap-bundle/airgap-bundle-manifest.json` component sha256 values after
replacement. Replace package-local tools before `--run`.

## Confirm Install Parameters

Keep `install_confirmation.confirm_current_install_parameters: true` after
editing the bundle-local install inputs and `namespace`. The operator-inputs
intake computes `install_parameters_sha256`, prints it for audit, and passes
it internally to the installer during `--run`.

## Doctor And Run

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

The package run writes path-level evidence for the final GA facade. It does
not issue `ga-release-report.json`.

## Final GA Report

After all four package runs and AgentSmith product-side reports are available,
use the final GA facade with the four package paths:

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

The formal result is `ga-release-report.json`.
