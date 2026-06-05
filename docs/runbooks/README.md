# Runbooks

Status: operator package flow first; maintainer/internal diagnostics are outside
this operator runbook.

## Operator First Screen

### 1. Which path do I choose?

Pick exactly one deployment path per input package:

- `online/use_existing`
- `online/install_substrates`
- `airgap/use_existing`
- `airgap/install_substrates`

Use four packages when the release captain asks for all four GA inputs. Do not
combine the four paths into one manifest. `use_existing` means the target
environment already provides the required substrates. `install_substrates`
means the path runs the namespace-scoped substrate installer with explicit
confirmation; it is not cloud provisioning for clusters, managed databases,
buckets, IAM, networks, or OIDC realms.

### 2. What do I prepare?

Prepare one directory or JSON manifest containing `operator-inputs.json` for
the selected deployment path. Keep secrets as references, not raw values. For
airgap packages, release/material inputs consumed from the bundle are
bundle-local. Package-local executable tools such as `kubectl`,
`archive_probe`, and `image_loader` can live outside the bundle while still
being referenced by the operator package. Post-deploy product smoke is
produced after the runtime check; it is not an operator input package field.
You can scaffold the package first, then fill in the package-local refs and
confirmations.

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
missing package inputs without executing the selected path. Add `--run` only
when the package is ready to execute the selected apply path. A passing `--run`
produces path-level evidence for the release captain/finalizer to consume; do
not treat intermediate files as the formal release verdict. After all four
package runs and product-side reports are available, use `--ga-report` to write
the final `ga-release-report.json`.
Release captains can also use the repository's manual
`ga-release-aggregate` GitHub workflow to download already-produced artifacts
and run this same final aggregate. That workflow is aggregate-only; it does
not rerun package, product, deployment, or airgap producers. Both paths also
write `ga-evidence-index.json` for release archive lookup; it is derived from
the final report and does not issue another verdict. On pass the index mirrors
the Product Readiness runtime convergence policy and Files restore continuation
evidence, plus post-deploy product smoke coverage.
The sibling `ga-release-summary.md` is the human-readable view. It includes
Product runtime readiness classification, the Files restore continuation
runtime evidence path, and adaptive wait intervals; use it for quick review,
then use `ga-release-report.json` for the formal pass/fail result.

### 4. What is the final report?

Formal release success or failure is represented only by the final
`ga-release-report.json` issued by the release finalizer/captain through
`operator-release.sh --ga-report`. The facade takes four package paths plus
AgentSmith product-side reports and locates internal path evidence itself. Pass
post-deploy product smoke reports for at least one online target and one airgap
target; the final report records that coverage under
`post_deploy_product_smoke_coverage`.
On pass the report has `formal_verdict=issued`; when blocked it replaces stale
pass outputs with `status=fail`, `formal_verdict=not_issued`, and blockers.
The sibling `ga-evidence-index.json` binds that source report digest to the
archived path and product evidence for release captain review. Its
`product_runtime_readiness` and `post_deploy_product_smoke_coverage` entries
are archive lookup fields, not separate release verdicts.
The sibling `ga-release-summary.md` repeats the Product runtime readiness
classification, runtime evidence path, and adaptive wait intervals for quick
review. It is derived from the same final report and is not a separate release
verdict.

## Operator Package Matrix

This table explains package contents for the four operator paths. It is not a
formal release verdict, package readiness, operator readiness, or GA signoff.

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

| `deployment_path` | Package must include | Current run result |
| --- | --- | --- |
| `online/use_existing` | Release contract, deploy template package and archive, render values, target substrate truth, target prerequisites, namespace, optional package-local `kubectl`. | Validates the package. With `--run` and `mode: apply`, executes the online path and writes path-level evidence for finalization. |
| `online/install_substrates` | Release contract, deploy template package and archive, render values, target prerequisites, substrate pack manifest, substrate install inputs, required `kubectl` and `context`, package-local `routability_probe`, and explicit install confirmation. No package-local `substrate_truth`. | Validates installer inputs. With `--run` and `mode: apply`, runs substrate-install first, uses the installer output truth for the online gate, and writes path-level evidence for finalization. |
| `airgap/use_existing` | Bundle-local release contract, deploy template package and archive, render values, substrate truth, and target prerequisites; `airgap_bundle`; explicit bundle-local `airgap_bundle_manifest`; required package-local `kubectl`; explicit `context`; package-local `archive_probe` and `image_loader` for apply; smoke URL for runtime route-smoke evidence. | Validates the bundle reference. With `--run` and `mode: apply`, runs airgap consume/deployment checks and writes path-level evidence for finalization. |
| `airgap/install_substrates` | Bundle-local release contract, deploy template package and archive, render values, and target prerequisites; substrate pack manifest; substrate install inputs; `airgap_bundle`; explicit bundle-local `airgap_bundle_manifest`; required package-local `kubectl`; explicit `context`; package-local `archive_probe` and `image_loader` for apply; smoke URL; explicit install confirmation. No bundle/package `substrate_truth`. | Validates installer and bundle references. With `--run` and `mode: apply`, runs substrate-install first, uses the installer output truth for airgap deployment, and writes path-level evidence for finalization. |

## Operator Examples

Copy/pasteable package skeletons are available under `examples/`:

- `examples/online-existing-kubernetes/`: `online/use_existing`
- `examples/online-install-substrates/`: `online/install_substrates`
- `examples/airgap-use-existing/`: `airgap/use_existing`
- `examples/airgap-install-substrates/`: `airgap/install_substrates`

Each example stages one package for `bash scripts/operator-release.sh
--operator-inputs <pkg>`. Run `--doctor` on the staged package to list missing
refs before validation/execution. Install-substrate examples use
`confirm_current_install_parameters: true`; intake computes and prints
`install_parameters_sha256` for audit, then `--run` passes it internally to
`verify-substrate-install`.

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
