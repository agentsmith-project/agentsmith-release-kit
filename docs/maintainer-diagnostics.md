# Maintainer Diagnostics

Status: maintainer/internal reference only. This document is for release-kit
owners changing focused producers, compatibility aliases, and CI diagnostics.
It is not the operator main path, not package readiness, not operator readiness,
and not a separate GA signoff surface.

Operators should start with `docs/runbooks/README.md`, prepare
`operator-inputs`, run `scripts/operator-release.sh`, and read the final
`ga-release-report.json`.

## Finalizer Handoff

Use one operator-inputs package for each deployment path. Do not combine the
four paths into a single manifest.

After all four package runs and product-side reports are available, the
release captain runs the package facade:

```bash
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <agentsmith/product-readiness-report.json> \
  --post-deploy-product-smoke-report <agentsmith/online-post-deploy-product-smoke-report.json> \
  --post-deploy-product-smoke-report <agentsmith/airgap-post-deploy-product-smoke-report.json> \
  --output-dir <dir>
```

The post-deploy product smoke inputs must be AgentSmith canonical reports, with
at least one online target and one airgap target:
`schema_version: agentsmith.post-deploy-product-smoke-report/v1`, `producer:
agentsmith-post-deploy-product-smoke`, and nested `release_contract: { path,
input_sha256, release_id, git_sha }`. Its `input_sha256`, `release_id`, and
`git_sha` must match the same release contract raw digest, id, and git sha.
Its `source.product_flows_path` and `source.product_flows_sha256` must bind the
AgentSmith product-flow aggregate consumed by the smoke run. Its
`deployment_target` must bind the deployed target profile, public/API base
URLs, and portable relative `site_env` plus `substrate_truth` path/digest pairs
used for that smoke run. The
`deployment_target.substrate_truth.sha256` must match the finalized deployment
path substrate truth digest, and the GA report archives that digest under
`deployment_path_binding.deployment_path_substrate_truth_digest`.

Legacy surrogate top-level fields are rejected: `release_id`, `git_sha`,
`release_contract_digest`, `covered_flows`, and `artifact_provenance`.

## Legacy Aliases

Legacy `kit_provided` is a maintainer/internal alias for focused diagnostics.
It is not a GA operator `deployment_path`; operator packages use
`install_substrates`. removal target: release-kit v1.0.0 GA cut.

`installed_by: agentsmith-release-kit` is a kit-provided pack/truth identity
marker / provenance marker only. It is not installer proof and does not mean
release-kit created databases, buckets, OIDC realms, or other substrate
resources.

`kind_rehearsal/kit_installed/online` remains rehearsal-only accepted input. It
is not a release profile, user deployment prerequisite, package-driven release
target, or replacement for real Kubernetes evidence.

## Airgap Bundle Packaging Diagnostics

Airgap bundle packaging commands are packaging-side helpers for the airgap
producer diagnostics, not standalone operator choices. The table names their
legacy diagnostic entries without copy-paste commands; operators should use
the package-driven `--operator-inputs` flow in the operator runbook.

| Packaging diagnostic | Machine profile mapping | Internal entry | Current result |
| --- | --- | --- | --- |
| `airgap-bundle/use_existing` | `existing_kubernetes/external_declared/airgap` | Legacy positional bundle packaging diagnostic, maintainer/internal only. | Runs the local bundle assembler and immediate self-check, then writes the operator surface summary. Follow-on consume diagnostics remain producer/focused commands. |
| `airgap-bundle/kit_provided` | `existing_kubernetes/kit_installed/airgap` | Legacy positional bundle packaging diagnostic, maintainer/internal only. | Runs the packaging-side local bundle assembler and immediate self-check, binds the substrate pack manifest as a bundle component, then writes the operator surface summary. It does not consume/deploy the bundle or install substrates. |

For `airgap-bundle/kit_provided`, also provide
`--substrate-pack-manifest <json>`; the generated bundle records it as
`components/substrate-pack-manifest.json`,
`components[].kind: substrate_pack_manifest`, and
`bindings.substrate_pack_manifest_sha256`.

## Optional Rehearsal

| Path | Target profile | Internal diagnostic command entry | Current result |
| --- | --- | --- | --- |
| Kind rehearsal, kit-provided substrates, online | `kind_rehearsal/kit_installed/online` | `bash scripts/verify-release.sh --inputs ...` and `--target-preflight ... --substrate-truth ... --target-prerequisites ...` | Accepts rehearsal intake only. It is not a prerequisite for real Kubernetes. |

For airgap consume rehearsal, optional
`--rehearsal-label existing_kubernetes|kind_rehearsal` is operator-provided
label-only metadata for the supplied Kubernetes endpoint. It does not change
the target profile, create or manage kind, or prove the endpoint is kind.

## Legacy Diagnostic Status

The following table is maintainer/internal compatibility status for focused
diagnostics. It is not the operator-facing package matrix.

| Path | Implemented now | Not yet |
| --- | --- | --- |
| `online/use_existing` | Inputs, target-preflight over substrate truth plus target prerequisites, template-package, optional image-map target-ref adoption, optional registry presence through an operator probe, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke through the online focused chain. | Cloud provisioning, substrate provisioning, registry mirroring, registry login, rollback, product-flow checks, deploy readiness, release readiness. |
| `online/kit_provided` | Contract declaration, target-preflight substrate/prerequisites intake, standalone image-map planning, substrate pack focused materiality, Pod-network substrate routability, template-package, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke, and optional confirmed-apply evidence envelope through the online focused chain. | This legacy positional diagnostic does not run substrate-install; package-driven `online/install_substrates` covers the GA installer path. Still no target-registry/registry-probe support, deploy readiness, package readiness, or release readiness. |
| `airgap/use_existing` | Bundle consume/deployment-focused diagnostics for an already assembled existing-substrate airgap bundle: bundle check, image load, bundle render-check, apply, rollout, optional smoke, and operator surface summary. | Registry mirroring, offline install, full readiness, operator verdict, deploy readiness, package readiness, release readiness. |
| `airgap/kit_provided` | Bundle consume/deployment-focused diagnostics for an already assembled kit-provided airgap bundle: bundle check, substrate-pack-check, image load, bundle render-check, apply, rollout, optional smoke, and operator surface summary. | This legacy positional diagnostic does not run substrate-install; package-driven `airgap/install_substrates` covers the GA installer path. Still no full readiness, operator verdict, deploy readiness, package readiness, or release readiness. |
| `airgap-bundle/use_existing` | Image-map mirror plan through the bundle-create producer, local bundle assembler plus self-check, and operator surface summary. Other airgap checks remain focused producer diagnostics. | Registry mirroring, offline install, deploy readiness, package readiness. |
| `airgap-bundle/kit_provided` | Packaging-side bundle assembly, substrate pack manifest component/digest binding, bundle self-check, and operator surface summary. | Bundle consume/deploy execution by this command; package-driven `airgap/install_substrates` covers the GA consume/deploy path. Still no standalone operator choice, full readiness, operator verdict, deploy readiness, package readiness, or release readiness. |

## Command Roles

`scripts/test-*.sh` files are maintainer self-tests for this repository. They
exercise failure cases and fixture behavior while changing release-kit code.

The positional `bash scripts/operator-release.sh <surface>
<substrate_strategy> ...` facade is a maintainer/internal focused diagnostic,
not the operator main path. It only runs when the maintainer explicitly sets
`AGENTSMITH_ALLOW_LEGACY_OPERATOR_RELEASE_DIAGNOSTIC=1`; without that opt-in,
the facade points back to the package-driven `--operator-inputs` command. It
rejects producer vocabulary such as
`--target-profile`, maps the operator choice internally, calls the existing
producer diagnostic, and writes `operator-release-surface-report.json` with a
minimal `readiness=false` summary. That summary is not accepted by
`--evidence`.

`bash scripts/verify-release.sh --...` remains the producer catalog and
maintainer/focused diagnostic entry. Use it when changing release-kit internals
or running a specific downstream check, not as the first operator-facing
command.

Default PR/push CI follows the quick/core path only:
`verify-release.sh --quick`, `test-inputs.sh`, `test-template-package.sh`,
`test-render.sh`, `test-render-check.sh`, `test-operator-inputs.sh`,
`test-operator-inputs-orchestration.sh`, `test-operator-release-surface.sh`,
`test-substrate-install.sh`, `test-deployment-path-report.sh`,
`test-ga-release.sh`, `test-package-driven-ga-smoke.sh`, and
`test-ga-release-workflow.sh`.

Maintainer diagnostics such as adoption aggregation, operator signoff intake,
airgap image load, and substrate routability are manual checks. They are useful
while changing those producers, but they are not default operator quick-path
evidence and still do not issue deploy, package, or release readiness.
Release-engineering gate intake is retired and remains only as a compatibility
guard that points maintainers to package-driven `operator-inputs` runs followed
by `operator-release.sh --ga-report`.

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
