# Online Install Substrates Example

This directory is a minimal operator input pack template for
`online/install_substrates`: install namespace-scoped kit substrates, then
deploy AgentSmith online using the installer-generated substrate truth.

Secrets stay outside the package. Use `secretRef:` values only.

The example pack, prerequisites, and install-input files are already bound to
`online/install_substrates`. Keep `deployment_path` set to
`online/install_substrates`. Replace namespace, storage values, service refs,
package-local tools, and confirmation fields.
The installer chooses the path from `deployment_path`; do not add extra
deployment selection fields to `target-prerequisites.example.json` or
`substrate-install-inputs.example.json`.

## Build The Package

```bash
RELEASE_CONTRACT="release-contract.json"
DEPLOY_TEMPLATE_PACKAGE="deploy-template-package.json"
DEPLOY_TEMPLATE_ARCHIVE="agentsmith-deploy-template-package.tgz"
EXAMPLE_DIR="examples/online-install-substrates"
PKG="out/operator-inputs/online-install-substrates"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp "$EXAMPLE_DIR/render-values.example.json" "$PKG/render-values.example.json"
cp "$EXAMPLE_DIR/target-prerequisites.example.json" "$PKG/target-prerequisites.example.json"
cp "$EXAMPLE_DIR/substrate-pack-manifest.example.json" "$PKG/substrate-pack-manifest.example.json"
cp "$EXAMPLE_DIR/substrate-install-inputs.example.json" "$PKG/substrate-install-inputs.example.json"
cp -R "$EXAMPLE_DIR/tools" "$PKG/tools"
cp "$RELEASE_CONTRACT" "$PKG/release-contract.json"
cp "$DEPLOY_TEMPLATE_PACKAGE" "$PKG/deploy-template-package.json"
cp "$DEPLOY_TEMPLATE_ARCHIVE" "$PKG/deploy-template-package.tgz"
```

For the target registry variant, run this after the block above to swap the
manifest and include the probe placeholder:

```bash
cp "$EXAMPLE_DIR/operator-inputs.target-registry.apply.example.json" "$PKG/operator-inputs.json"
mkdir -p "$PKG/tools"
cp "$EXAMPLE_DIR/tools/registry-probe" "$PKG/tools/registry-probe"
```

For package-driven `online/install_substrates`, the target registry variant is
supported when the registry already contains digest refs for the release
images. `registry_probe` is a package-local read-only executable invoked as
`tools/registry-probe <target-image> <expected-digest>`; stdout must be
exactly the matching `sha256:<64>` digest. The package run does not mirror
images, push images, or perform registry login.

Replace `tools/kubectl` and `tools/routability-probe` with operator-approved
package-local executables before `--run`. When using the target registry
variant, replace `tools/registry-probe` too; it intentionally exits non-zero
until replaced.

## Confirm Install Parameters

Keep `install_confirmation.confirm_current_install_parameters: true` after
editing `substrate-install-inputs.example.json` and `namespace`. The
operator-inputs intake computes `install_parameters_sha256`, prints it for
audit, and passes it internally to the installer during `--run`.

## Doctor And Run

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

The package run writes path-level evidence for the final GA facade. It does
not issue `ga-release-report.json`. When doctor fails, the human output groups
blockers as release materials, operator target facts, operator tools, and
operator confirmations.

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
