# Runbooks

Status: operator decision index for the current bootstrap diagnostics.

Use this page to choose the target path before running repo-local checks. The
scripts here produce focused evidence with `readiness: false`; they do not
sign off deploy, package, offline install, or release readiness.

## Default Operator Paths

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Real or cloud Kubernetes, existing substrates, online | `existing_kubernetes/external_declared/online` | `bash scripts/verify-release.sh --online-deployment-gate ... [--target-registry ...]` | Runs the online focused chain for existing substrate endpoints; target registry only adopts rendered image refs through image-map. |
| Real or cloud Kubernetes, existing substrates, airgap | `existing_kubernetes/external_declared/airgap` | `bash scripts/verify-release.sh --bundle-create ...` or `--image-map ... --target-registry ...`, then `--airgap-bundle-check ...` and optional `--bundle-load-plan ...` | Assembles a local bundle and immediately self-checks it, checks an already assembled bundle manifest/digests, or writes a read-only load plan summary. |
| Real or cloud Kubernetes, kit-installed substrates, online or airgap | `existing_kubernetes/kit_installed/online` or `existing_kubernetes/kit_installed/airgap` | `bash scripts/verify-release.sh --inputs ...`, `--target-preflight ...`, and `--image-map ...` | Accepts the declaration, substrate truth intake, and image plan only. |

Optional rehearsal path:

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Kind rehearsal, kit-installed substrates, online | `kind_rehearsal/kit_installed/online` | `bash scripts/verify-release.sh --inputs ...` and `--target-preflight ...` | Accepts rehearsal intake only. It is not a prerequisite for real Kubernetes. |

## Implemented Now / Not Yet

| Path | Implemented now | Not yet |
| --- | --- | --- |
| Real or cloud Kubernetes + existing substrates + online | Inputs, target-preflight, template-package, optional image-map target-ref adoption, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke through the online focused chain. | Cloud provisioning, substrate provisioning, registry mirroring, registry login, rollback, product-flow checks, deploy readiness, release readiness. |
| Real or cloud Kubernetes + existing substrates + airgap | Image-map mirror plan, local bundle assembler plus self-check, airgap bundle manifest/digest check, and read-only load plan summary for `existing_kubernetes/external_declared/airgap`. | Registry mirroring, image load/import, offline install, airgap deploy gate, deploy readiness, package readiness. |
| Real or cloud Kubernetes + kit-installed substrates + online/airgap | Contract declaration, target-preflight substrate truth intake, and image-map planning for `existing_kubernetes/kit_installed/online` and `existing_kubernetes/kit_installed/airgap`. | Substrate installer, kit-installed apply/rollout/smoke chain, kit-installed airgap deploy, deploy readiness, package readiness. |
| Kind rehearsal + kit-installed substrates + online | Contract declaration and target-preflight truth intake for `kind_rehearsal/kit_installed/online`. | Real deployment evidence, release readiness, mandatory pre-deploy rehearsal. |

## Command Roles

`scripts/test-*.sh` files are maintainer self-tests for this repository. They
exercise failure cases and fixture behavior while changing release-kit code.

Operators should call `bash scripts/verify-release.sh --...` directly with the
release contract, deploy template package, explicit target profile, and output
directory for their chosen path.

For the online focused chain, confirmed apply can optionally add
`--evidence-root <dir> --evidence-provenance <json>`. Use only remote
release-kit provenance such as CI artifact or signed operator-run metadata.
The gate writes a focused evidence envelope and revalidates it through
`--evidence`; it is still `readiness=false` and is not deploy or release
signoff.
Online `--target-registry <registry-host[/namespace]>` only asks the gate to
generate an image-map and render target image references. It does not perform
registry login, pull, push, mirror, or registry presence checks.

## Current Notes

Pre-GA release contracts may declare the five canonical target profiles, but
none may be marked required. Keep every `target_profiles[].required` value
`false`; `required: true` fails fast because release-kit does not yet have full
deploy/package evidence for every path.

For image-map, online targets may omit `--target-registry` to use source
digest refs directly. Airgap targets require
`--target-registry <registry-host[/namespace]>`; namespace components must be
lowercase and start and end with alphanumeric characters.

For airgap bundle create, provide exactly one local
`--image-archive <image_id=file>` for each image-map mapping plus local
payload and operator prerequisite inputs. The bundle root must be absent or
empty. The command writes `bundle-create-report.json` with `readiness=false`
after the generated bundle passes `--airgap-bundle-check`; that report is not
accepted by the evidence envelope validator.

For airgap bundle checks, the bundle manifest must use
`schema_version: agentsmith.airgap-bundle-manifest/v1`. The check validates
safe relative paths and sha256 bindings only. It now requires
`payload_artifacts` for runbook/script/profile-values schema/checksums payloads
and `operator_prerequisites` for operator-held substrate truth, registry proof,
and tool prerequisites. Bundled tool files are checked by path/sha under the
bundle root; operator prerequisite locations/proofs are strings and must not be
URLs, download instructions, or secret-looking content. The airgap image-map is
also rebound to `release_contract.deploy_image_inventory`. Stdout ends with
`readiness=false`.

For airgap bundle load plans, use `--bundle-load-plan` only after a bundle has
already been assembled. The command reuses `--airgap-bundle-check`, accepts
only `existing_kubernetes/external_declared/airgap`, and writes
`airgap-bundle-load-plan-report.json` with `readiness=false`. The report is a
digest/count/target-registry summary only; it is not evidence-envelope input,
does not prove registry presence, and does not push, import, load, deploy, or
smoke.

For route smoke, use `bash scripts/verify-release.sh --smoke` only after a
passing focused `rollout-report.json`. Supply an HTTPS URL by default; local
HTTP is reserved for focused tests with explicit `--allow-http
--allow-localhost`.

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
