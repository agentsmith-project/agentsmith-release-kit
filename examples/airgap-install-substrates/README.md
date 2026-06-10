# Airgap Install Substrates Example

This directory is a minimal operator input pack template for
`airgap/install_substrates`: install namespace-scoped kit substrates, then
deploy AgentSmith from a bundle-local airgap release.

Release/material inputs are bundle-local. Operator tools such as `kubectl`,
`archive_probe`, and `image_loader` are package-local executables and may live
outside the bundle.

Secrets stay outside the package. Use `secretRef:` values only.

This package requires an already assembled airgap bundle. The bundle manifest
must come from the assembled airgap bundle provided by the release package, and
must include the release identity, bindings, image archive declarations, payload
artifacts, and operator prerequisites. Do not update only `components` and
component sha256 values in the checked-in manifest.

Keep `deployment_path` set to `airgap/install_substrates`. Replace the whole
`airgap-bundle/` directory from the assembled bundle, then provide or edit the
bundle-local install inputs, namespace, service refs, package-local tools, and
confirmation fields. Provide the substrate pack manifest together with its
referenced `payload/`, `templates/`, and `tools/` material tree; paths are
relative to the manifest's directory.
The installer chooses the path from `deployment_path`; do not add extra
deployment selection fields to the bundle-local target prerequisites or install
inputs.

## Build The Package

```bash
EXAMPLE_DIR="examples/airgap-install-substrates"
PKG="out/operator-inputs/airgap-install-substrates"
BUNDLE_ROOT="<path-to-assembled-airgap-bundle>"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
rm -rf "$PKG/airgap-bundle"
mkdir -p "$PKG/airgap-bundle"
cp -R "$BUNDLE_ROOT"/. "$PKG/airgap-bundle"/
mkdir -p "$PKG/airgap-bundle/operator-inputs"
cp "$EXAMPLE_DIR/airgap-bundle/operator-inputs/"*.example.json \
  "$PKG/airgap-bundle/operator-inputs/"
cp -R "$EXAMPLE_DIR/tools" "$PKG/tools"
```

`BUNDLE_ROOT` is the assembled bundle directory containing
`airgap-bundle-manifest.json`. Keep that manifest from bundle assembly; it is
not a components-only manifest. Replace package-local tools before `--run`.
Because the airgap substrate pack manifest is under
`airgap-bundle/components/`, put its referenced material tree under that same
directory, or update the manifest paths to match.
If this package started from init scaffold, replace
`context: replace-with-kube-context` and
`smoke_url: https://agentsmith.example.com/healthz`; doctor treats those
placeholder values as blockers.

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
`site.env` is supplied by the AgentSmith post-deploy product smoke report, not
by operator-inputs.
