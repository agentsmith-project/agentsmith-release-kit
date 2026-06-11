# Runbooks

Status: operator package flow first.

## Operator First Screen

### 1. Which path do I choose?

Pick exactly one deployment path per input package:

- `online/use_existing`
- `online/install_substrates`
- `airgap/use_existing`
- `airgap/install_substrates`

Use four packages when all four GA inputs are required. Do not combine the four
paths into one manifest. `use_existing` means the target
environment already provides the required substrates. `install_substrates`
means the path runs the namespace-scoped substrate installer with explicit
confirmation; it is not cloud provisioning for clusters, managed databases,
buckets, IAM, networks, or OIDC realms.

### 2. What do I prepare?

Prepare one directory or JSON manifest containing `operator-inputs.json` for
the selected deployment path. Keep secrets as references, not raw values. For
airgap packages, release/material inputs consumed from the bundle are
bundle-local. Package-local executable tools such as `kubectl`,
`archive_probe`, `image_loader`, and online `registry_probe` can live outside
the bundle while still being referenced by the operator package. Post-deploy
product smoke is produced after the runtime check; it is not an operator input
package field. You can scaffold the package first, then fill in the
package-local refs and confirmations.
For airgap packages, the bundle manifest must come from the assembled bundle and
travel with its payload/prerequisite closure; operators should not edit manifest
internals.
The package facade does not call `skopeo` directly. If a package-local
`archive_probe`, `image_loader`, or `registry_probe` wrapper uses `skopeo`
internally, the target environment must preinstall it or provide it with the
package, and the wrapper should return a clear missing-tool error.

### 3. What do I run?

Use the single operator facade:

```bash
bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <dir>
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --doctor
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --run
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

The init command writes a package skeleton for one deployment path and refuses
to overwrite an existing `operator-inputs.json`. The doctor command lists
missing package refs/fields plus static package blockers without executing the
selected path. A passing doctor only means static package checks passed; it
is not runnable readiness or the final GA result. Add `--run` only when the
package is ready to execute the selected path. A passing `--run` produces
package output for the final GA report; do not treat intermediate files as the
final release result. After all four package runs and product-side reports are
available, use `--ga-report` to write the final `ga-release-report.json`.
Replace scaffold scalar placeholders such as
`context: replace-with-kube-context` and
`smoke_url: https://agentsmith.example.com/healthz`; doctor reports them as
blockers until they are real target facts.
When doctor fails, its human output groups the blockers as release materials,
operator target facts, operator tools, and operator confirmations before the
raw field list.
The repository's manual `ga-release-aggregate` GitHub workflow can also
download already-produced artifacts and run this same final aggregate. That
workflow is aggregate-only; it does
not rerun package, product, deployment, or airgap producers. Use
`ga-release-report.json` for the final pass/fail result.

### 4. What is the final report?

Final release pass/fail is represented only by `ga-release-report.json`, which
`operator-release.sh --ga-report` writes from four package paths plus
AgentSmith product-side reports. The facade locates package output itself.
Pass post-deploy product smoke reports for at least one online target and one
airgap target; the final report records pass/fail and blockers.
The final report also verifies that each smoke report's substrate truth digest
matches the finalized deployment truth for the package it is bound to; smoke
evidence from a different deployed substrate is a blocker.
`site.env` is not an operator-inputs field; AgentSmith's post-deploy product
smoke report binds the deployed site facts for this final verifier.

## Operator Package Matrix

This table explains package contents for the four operator paths. It is not a
release result, package readiness, operator readiness, or GA signoff.

`online/install_substrates` needs namespace-scoped installer evidence,
required `kubectl` and `context` inputs, a package-local `routability_probe`,
substrate pack manifest, substrate install inputs, and an explicit installer
confirmation. It does not accept package-local `substrate_truth`; the online
deployment gate uses installer-generated truth. `airgap/install_substrates`
needs package-local `kubectl`, explicit `context`, the airgap bundle plus
manifest, package-local `archive_probe` and `image_loader` for apply,
substrate pack manifest, substrate install inputs, and explicit installer
confirmation. It uses installer-generated substrate truth for the airgap
deployment gate and does not require `routability_probe` or bundle/package
`substrate_truth`. `installed_by` stays a provenance marker, not installer
proof.
For install paths, the substrate pack is the manifest plus its referenced
`payload/`, `templates/`, `tools/`, and `checksums/` material tree; those
paths are relative to the manifest's directory. The first-party source lives
under `substrate-packs/minimal/`; materialize it with
`scripts/materialize-substrate-pack.mjs` for one deployment path before adding
it to an operator package or airgap bundle. Add `--verify-source-images` when
`skopeo` is available to check the public source refs against their declared
digests; only packages materialized with that flag have skopeo-verified source
refs. Otherwise install `skopeo` before doing source-ref verification.
Online materialization requires real target namespace, installation id, and
storage class facts. Airgap materialization also requires the target registry,
and the materialized substrate pack plus image archives must be bound into the
assembled bundle before bundle-create handoff. `.example.json` files and
placeholder pack trees are not runnable readiness.
Materialization only proves the package shape: initialization Jobs for DB
schema/users, object-storage bucket bootstrap, and OIDC realm/client bootstrap,
plus real target secrets, storage, registry access, rollout, and smoke checks
remain downstream blockers.
For both online paths, an apply package may also set `target_registry` and
provide a package-local `registry_probe`; the registry must already contain
digest refs for the release images.

| `deployment_path` | Package must include | Current run result |
| --- | --- | --- |
| `online/use_existing` | Release contract, deploy template package and archive, render values, target substrate truth, target prerequisites, namespace, required package-local `kubectl` and explicit `context`, optional target registry plus package-local `registry_probe`. | Validates the package. With `--run`, executes the online path and records output for `--ga-report`. |
| `online/install_substrates` | Release contract, deploy template package and archive, render values, target prerequisites, substrate pack manifest, substrate install inputs, required `kubectl` and `context`, package-local `routability_probe`, optional target registry plus package-local `registry_probe`, and explicit install confirmation. No package-local `substrate_truth`. | Validates installer inputs. With `--run`, runs substrate-install first, uses the installer output truth, and records output for `--ga-report`. |
| `airgap/use_existing` | Bundle-local release contract, deploy template package and archive, render values, substrate truth, and target prerequisites; `airgap_bundle`; explicit bundle-local `airgap_bundle_manifest`; required package-local `kubectl`; explicit `context`; package-local `archive_probe` and `image_loader`; smoke URL for runtime route-smoke evidence. | Validates the bundle reference. With `--run`, runs the airgap path and records output for `--ga-report`. |
| `airgap/install_substrates` | Bundle-local release contract, deploy template package and archive, render values, and target prerequisites; substrate pack manifest; substrate install inputs; `airgap_bundle`; explicit bundle-local `airgap_bundle_manifest`; required package-local `kubectl`; explicit `context`; package-local `archive_probe` and `image_loader`; smoke URL; explicit install confirmation. No bundle/package `substrate_truth`. | Validates installer and bundle references. With `--run`, runs substrate-install first, uses the installer output truth, and records output for `--ga-report`. |

## Operator Examples

Copy/pasteable package skeletons are available under `examples/`:

- `examples/online-use-existing/`: `online/use_existing`
- `examples/online-install-substrates/`: `online/install_substrates`
- `examples/airgap-use-existing/`: `airgap/use_existing`
- `examples/airgap-install-substrates/`: `airgap/install_substrates`

Each example stages one package for `bash scripts/operator-release.sh
--operator-inputs <pkg>`. Run `--doctor` on the staged package to list missing
refs before validation/execution. Install-substrate examples use
`confirm_current_install_parameters: true`; the package check computes and
prints `install_parameters_sha256` for audit, and `--run` uses it for
installer confirmation.

### Airgap Tool Contract

For package-driven airgap apply packages, `archive_probe` and `image_loader`
are package-relative executable refs. The resolver rejects PATH-only command
names, URIs, Windows paths, symlinks, non-files, non-executable files, and
paths that escape the package; the plan digest-binds the executable files.

`archive_probe` is called once per image archive as
`<archive_probe> <archive_path>` with `AGENTSMITH_IMAGE_ARCHIVE_PATH` and
`AGENTSMITH_IMAGE_ID` in the environment. It must exit zero within 5 seconds,
write no stderr, and print exactly one `sha256:<64-hex>` digest to stdout.
The archive probe executable basename must not be `docker`, `skopeo`, `oras`,
`kubectl`, `curl`, or `wget`.

`image_loader` is called once per image as
`<image_loader> <archive_path> <target_image> <target_digest>` with
`AGENTSMITH_IMAGE_ARCHIVE_PATH`, `AGENTSMITH_IMAGE_ID`,
`AGENTSMITH_TARGET_IMAGE`, and `AGENTSMITH_TARGET_DIGEST` in the environment.
It must exit zero within 30 seconds, write no stderr, and print exactly one
matching sha256 digest to stdout.

If either wrapper shells out to `skopeo`, the target environment must include
that binary or the package must provide it, and the wrapper should explain the
missing dependency clearly. The wrapper executable name and stdout digest
contract still remain the package-local contract.

These tools are the operator's package-local offline boundary. The release kit
does not download from the public internet, and an airgap package should treat
network access by these tools as out of contract; the current checks bind
local executable refs and digest output, not network isolation proof.

## Maintainer/Internal References

Maintainer/internal diagnostic details are outside this operator runbook. Use
`docs/maintainer-diagnostics.md` when changing release-kit internals or focused
producer diagnostics, and use `docs/RELEASE_GATES.md` for the full gate
contract. This page intentionally keeps the operator path limited to
`operator-inputs`, `scripts/operator-release.sh`, and the final
`ga-release-report.json`.

Archive attachments written next to the final report are maintainer/reference
artifacts, not operator results. The operator-facing result remains
`ga-release-report.json`.
