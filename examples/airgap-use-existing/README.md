# Airgap Use Existing Example

This directory is a minimal operator input pack template for
`airgap/use_existing`: consume a bundle-local AgentSmith release with
operator-declared external substrates.

Release/material inputs are bundle-local. Operator tools such as `kubectl`,
`archive_probe`, and `image_loader` are package-local executables and may live
outside the bundle.

Secrets stay outside the package. Use `secretRef:` values only.

The bundle manifest and bundle-local operator inputs are already bound to
`airgap/use_existing`. Keep their path identity fields unchanged. Replace
bundle components, component checksums, namespace, secret refs, endpoint
values, and package-local tools.
The facade derives deployment identity from `deployment_path`; do not add
deployment identity fields to the bundle-local substrate truth or target
prerequisites.

## Build The Package

```bash
EXAMPLE_DIR="examples/airgap-use-existing"
PKG="out/operator-inputs/airgap-use-existing"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp -R "$EXAMPLE_DIR/airgap-bundle" "$PKG/airgap-bundle"
cp -R "$EXAMPLE_DIR/tools" "$PKG/tools"
```

Replace the files under `"$PKG/airgap-bundle/components"` with the real
bundle-local release contract, deploy template package, deploy template
archive, and image map. Update `airgap-bundle/airgap-bundle-manifest.json`
component sha256 values after replacement. Replace package-local tools before
`--run`.

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
