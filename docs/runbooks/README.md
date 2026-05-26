# Runbooks

Status: operator decision index for the current bootstrap diagnostics.

Use this page to choose the target path before running repo-local checks. The
scripts here produce focused evidence with `readiness: false`; they do not
sign off deploy, package, offline install, or release readiness.

## Default Operator Paths

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Real or cloud Kubernetes, existing substrates, online | `existing_kubernetes/external_declared/online` | `bash scripts/verify-release.sh --online-deployment-gate ... --substrate-truth ... --target-prerequisites ... [--target-registry ...]` | Runs the online focused chain for existing substrate endpoints and explicit target prerequisites; target registry only adopts rendered image refs through image-map. |
| Real or cloud Kubernetes, existing substrates, airgap | `existing_kubernetes/external_declared/airgap` | `bash scripts/verify-release.sh --bundle-create ...` or `--image-map ... --target-registry ...`, then `--airgap-bundle-check ...`, optional `--bundle-load-plan ...`, and optional `--airgap-bundle-render-check ...` | Assembles a local bundle and immediately self-checks it, checks an already assembled bundle manifest/digests, writes a read-only load plan summary, or renders/checks bundle-local manifests offline. |

Advanced intake-only paths:

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Real or cloud Kubernetes, kit-installed substrates, online or airgap | `existing_kubernetes/kit_installed/online` or `existing_kubernetes/kit_installed/airgap` | `bash scripts/verify-release.sh --inputs ...`, `--target-preflight ... --substrate-truth ... --target-prerequisites ...`, and `--image-map ...` | Advanced/intake-only. Accepts the declaration, substrate truth, target prerequisites, and image plan only; it is not a default operator deployment path. |

Optional rehearsal path:

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Kind rehearsal, kit-installed substrates, online | `kind_rehearsal/kit_installed/online` | `bash scripts/verify-release.sh --inputs ...` and `--target-preflight ... --substrate-truth ... --target-prerequisites ...` | Accepts rehearsal intake only. It is not a prerequisite for real Kubernetes. |

## Implemented Now / Not Yet

| Path | Implemented now | Not yet |
| --- | --- | --- |
| Real or cloud Kubernetes + existing substrates + online | Inputs, target-preflight over substrate truth plus target prerequisites, template-package, optional image-map target-ref adoption, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke through the online focused chain. | Cloud provisioning, substrate provisioning, registry mirroring, registry login, rollback, product-flow checks, deploy readiness, release readiness. |
| Real or cloud Kubernetes + existing substrates + airgap | Image-map mirror plan, local bundle assembler plus self-check, airgap bundle manifest/digest check, read-only load plan summary, and offline bundle render-check for `existing_kubernetes/external_declared/airgap`. | Registry mirroring, image load/import, offline install, airgap deploy gate, deploy readiness, package readiness. |
| Real or cloud Kubernetes + kit-installed substrates + online/airgap | Advanced contract declaration, target-preflight substrate/prerequisites intake, and image-map planning for `existing_kubernetes/kit_installed/online` and `existing_kubernetes/kit_installed/airgap`. | Default operator deployment path, substrate installer, kit-installed apply/rollout/smoke chain, kit-installed airgap deploy, deploy readiness, package readiness. |
| Kind rehearsal + kit-installed substrates + online | Contract declaration and target-preflight truth/prerequisites intake for `kind_rehearsal/kit_installed/online`. | Real deployment evidence, release readiness, mandatory pre-deploy rehearsal. |

## Command Roles

`scripts/test-*.sh` files are maintainer self-tests for this repository. They
exercise failure cases and fixture behavior while changing release-kit code.

Operators should call `bash scripts/verify-release.sh --...` directly with the
release contract, deploy template package, explicit target profile, and output
directory for their chosen path.

For target-preflight and the online focused chain, keep substrate connection
truth and target prerequisites as separate files. Substrate truth stays neutral;
target prerequisites carry namespace, RBAC policy/proof, ingress TLS, registry
pull secret, storage policy, and substrate secret refs.

For the online focused chain, confirmed apply can optionally add
`--evidence-root <dir> --evidence-provenance <json>`. Use only remote
release-kit provenance such as CI artifact or signed operator-run metadata.
The gate writes a focused evidence envelope and revalidates it through
`--evidence`; it is still `readiness=false` and is not deploy or release
signoff. Evidence intake accepts only this confirmed-apply envelope; server
dry-run reports and empty-step online gate reports are rejected.
Online `--target-registry <registry-host[/namespace]>` only asks the gate to
generate an image-map and render target image references. It does not perform
registry login, pull, push, mirror, or registry presence checks.

After a confirmed online focused chain run, operators may run
`--operator-signoff-intake` with `operator-signoff-intake.json` and the
generated `online-deployment-gate-report.json`. This is machine intake and
binding only: it checks the signoff JSON allowlist, release identity, release
contract digest, target profile, operator run id, and raw report sha256. It
writes `operator-signoff-intake-report.json` with `readiness=false`, does not
verify signatures or identity, is not registry presence proof, is not accepted
by the evidence envelope validator, and is not deploy/package/release
readiness.

## Current Notes

Pre-GA release contracts may declare the five canonical target profiles, but
none may be marked required. Keep every `target_profiles[].required` value
`false`; `required: true` fails fast because release-kit does not yet have full
deploy/package evidence for every path.

For image-map, online targets may omit `--target-registry` to use source
digest refs directly. Airgap targets require
`--target-registry <registry-host[/namespace]>`; namespace components must be
lowercase and start and end with alphanumeric characters.
Evidence intake rechecks the same adoption rule as render: source-use plans
cannot carry `target_registry`, and mirrored targets must match the
deterministic target registry ref.

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
`readiness=false`. Evidence intake accepts only a real check report +
manifest + `image-map.json` triplet with bundle-check-compatible components,
image declarations, payload/tool counts, and digests; empty fake manifests are
rejected.

For airgap bundle load plans, use `--bundle-load-plan` only after a bundle has
already been assembled. The command reuses `--airgap-bundle-check`, accepts
only `existing_kubernetes/external_declared/airgap`, and writes
`airgap-bundle-load-plan-report.json` with `readiness=false`. The report is a
digest/count/target-registry summary only; it is not evidence-envelope input,
does not prove registry presence, and does not push, import, load, deploy, or
smoke.

For airgap bundle render-check, use `--airgap-bundle-render-check` only after a
bundle has already been assembled. Pass the bundle-local components plus
bundle-local render values and substrate truth. The command reuses
`--airgap-bundle-check`, renders with the bundle-local airgap image-map, runs
`--render-check`, and verifies rendered workload images use target refs. Its
report has `readiness=false`, omits `target_registry`, is not
evidence-envelope input, and does not prove registry presence, image
load/import, offline install, deploy, package, or release readiness.

For route smoke, use `bash scripts/verify-release.sh --smoke` only after a
passing focused `rollout-report.json`. Supply an HTTPS URL by default; local
HTTP is reserved for focused tests with explicit `--allow-http
--allow-localhost`.

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
