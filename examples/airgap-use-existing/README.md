# Airgap Use Existing Example

This directory is a minimal operator input pack template for
`airgap/use_existing`: consume a bundle-local AgentSmith release with
operator-declared external substrates.

Release/material inputs are bundle-local. Operator tools such as `kubectl`,
`archive_probe`, and `image_loader` are package-local executables and may live
outside the bundle.

Secrets stay outside the package. Use `secretRef:` values only.

This package requires an already assembled airgap bundle. The bundle manifest
must come from the assembled airgap bundle provided by the release package, and
must include the release identity, bindings, image archive declarations, payload
artifacts, and operator prerequisites. Do not update only `components` and
component sha256 values in the checked-in manifest.

Keep `deployment_path` set to `airgap/use_existing`. Replace the whole
`airgap-bundle/` directory from the assembled bundle, then provide or edit the
bundle-local operator input files, namespace, secret refs, endpoint values, and
package-local tools.
The facade chooses the path from `deployment_path`; do not add extra deployment
selection fields to the bundle-local substrate truth or target prerequisites.
Do not add `substrate_pack_manifest`, `substrate_install_inputs`, or
`install_confirmation`; this package uses only operator-declared existing
endpoint/secret facts.

## Build The Package

```bash
EXAMPLE_DIR="examples/airgap-use-existing"
PKG="out/operator-inputs/airgap-use-existing"
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
If this package started from init scaffold, replace
`context: replace-with-kube-context` and
`smoke_url: https://agentsmith.example.com/healthz`; doctor treats those
placeholder values as blockers.

## Doctor And Run

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

The package run records output for the final GA facade. It does not issue
`ga-release-report.json`.

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

The final result is `ga-release-report.json`.
`site.env` is supplied by the AgentSmith post-deploy product smoke report, not
by operator-inputs.
