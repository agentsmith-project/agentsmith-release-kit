# Airgap Install Substrates Example

This directory is a minimal operator input pack template for
`airgap/install_substrates`: install namespace-scoped kit substrates, then
deploy AgentSmith from a bundle-local airgap release.

Release/material inputs are bundle-local. Operator tools such as `kubectl`,
`archive_probe`, and `image_loader` are package-local executables and may live
outside the bundle.

Secrets stay outside the package. Use `secretRef:` values only.

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

## Validate And Run

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG"
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

The package run writes path-level evidence for the final GA facade. It does
not issue `ga-release-report.json`.
