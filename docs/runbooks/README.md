# Runbooks

Status: operator decision index for the current bootstrap diagnostics.

Use this page to choose the target path before running repo-local checks. The
scripts here produce focused evidence with `readiness: false`; they do not
sign off deploy, package, offline install, or release readiness.

## Default Operator Paths

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Real or cloud Kubernetes, existing substrates, online | `existing_kubernetes/external_declared/online` | `bash scripts/verify-release.sh --online-deployment-gate ... --substrate-truth ... --target-prerequisites ... [--target-registry ... --registry-probe ...]`; optional standalone `--registry-presence ... --image-map ... --registry-probe ...` | Runs the online focused chain for existing substrate endpoints and explicit target prerequisites; target-registry confirmed apply binds registry presence through the operator probe before render/apply. |
| Real or cloud Kubernetes, existing substrates, airgap | `existing_kubernetes/external_declared/airgap` | `bash scripts/verify-release.sh --bundle-create ...` or `--image-map ... --target-registry ...`, then `--airgap-bundle-check ...`, optional `--airgap-image-load ... --archive-probe ... --image-loader ...`, optional `--bundle-load-plan ...`, optional `--airgap-bundle-render-check ...`, and optional `--airgap-deployment-gate ...` | Assembles a local bundle and immediately self-checks it, checks an already assembled bundle manifest/digests, can run a focused operator-loader image import diagnostic, writes a read-only load plan summary, renders/checks bundle-local manifests offline, or runs the focused airgap apply/rollout chain. |
| Real or cloud Kubernetes, kit-installed substrates, online | `existing_kubernetes/kit_installed/online` | `bash scripts/verify-release.sh --online-deployment-gate ... --substrate-truth ... --target-prerequisites ... --substrate-pack-manifest ... --routability-probe ...` | Runs the online focused chain for kit-installed substrate declarations: substrate pack materiality, Pod-network routability, render, render-check, apply, rollout, and optional route smoke. It is source-registry only and rejects `--target-registry`, `--registry-probe`, and `--evidence-root`; it is not a substrate installer or release readiness. |

Advanced intake-only paths:

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Real or cloud Kubernetes, kit-installed substrates, airgap | `existing_kubernetes/kit_installed/airgap` | `bash scripts/verify-release.sh --inputs ...`, `--target-preflight ... --substrate-truth ... --target-prerequisites ...`, `--image-map ... --target-registry ...`, and optional `--substrate-pack-check ... --substrate-pack-manifest ... --substrate-truth ...` | Advanced/focused intake only. Accepts the declaration, substrate truth, target prerequisites, image plan, and focused substrate pack materiality; it is not an airgap deploy path, substrate installer, or release readiness. |

Optional rehearsal path:

| Path | Target profile | Operator command entry | Current result |
| --- | --- | --- | --- |
| Kind rehearsal, kit-installed substrates, online | `kind_rehearsal/kit_installed/online` | `bash scripts/verify-release.sh --inputs ...` and `--target-preflight ... --substrate-truth ... --target-prerequisites ...` | Accepts rehearsal intake only. It is not a prerequisite for real Kubernetes. |

## Implemented Now / Not Yet

| Path | Implemented now | Not yet |
| --- | --- | --- |
| Real or cloud Kubernetes + existing substrates + online | Inputs, target-preflight over substrate truth plus target prerequisites, template-package, optional image-map target-ref adoption, optional registry presence through an operator probe, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke through the online focused chain. | Cloud provisioning, substrate provisioning, registry mirroring, registry login, rollback, product-flow checks, deploy readiness, release readiness. |
| Real or cloud Kubernetes + existing substrates + airgap | Image-map mirror plan, local bundle assembler plus self-check, airgap bundle manifest/digest check, focused operator-loader image load/import diagnostic, read-only load plan summary, offline bundle render-check, and focused airgap deployment gate for `existing_kubernetes/external_declared/airgap`. | Registry mirroring, offline install, deploy readiness, package readiness. |
| Real or cloud Kubernetes + kit-installed substrates + online | Contract declaration, target-preflight substrate/prerequisites intake, standalone image-map planning, substrate pack focused materiality, Pod-network substrate routability, template-package, render, render-check, apply dry-run or confirmed apply, rollout, and optional route smoke through the online focused chain. | Substrate installer, target-registry/registry-probe/evidence-root support, deploy readiness, package readiness, release readiness. |
| Real or cloud Kubernetes + kit-installed substrates + airgap | Advanced contract declaration, target-preflight substrate/prerequisites intake, image-map planning, and substrate pack focused materiality check for `existing_kubernetes/kit_installed/airgap`. | Substrate installer, kit-installed airgap deploy, deploy readiness, package readiness, release readiness. |
| Kind rehearsal + kit-installed substrates + online | Contract declaration and target-preflight truth/prerequisites intake for `kind_rehearsal/kit_installed/online`. | Real deployment evidence and release readiness; kind remains optional rehearsal only, not a real deployment prerequisite. |

## Command Roles

`scripts/test-*.sh` files are maintainer self-tests for this repository. They
exercise failure cases and fixture behavior while changing release-kit code.

Operators should call `bash scripts/verify-release.sh --...` directly with the
release contract, deploy template package, explicit target profile, and output
directory for their chosen path.

For a concrete real Kubernetes plus existing substrates online example, copy
and edit `examples/online-existing-kubernetes/`. It demonstrates the
server-dry-run command, confirmed apply command, optional route smoke, and
optional evidence-root input without claiming deploy or release readiness.

For target-preflight and the online focused chain, keep substrate connection
truth and target prerequisites as separate files. Substrate truth stays neutral;
target prerequisites carry namespace, RBAC policy/proof, ingress TLS, registry
pull secret, storage policy, and substrate secret refs. The registry object is
limited to `pull_secret_ref`; do not add `preloaded`, `mirror_done`, `verdict`,
`token`, or other pseudo-proof fields.

For the external-declared online focused chain, confirmed apply can optionally add
`--evidence-root <dir> --evidence-provenance <json>`. Use only remote
release-kit provenance such as CI artifact or signed operator-run metadata.
The gate writes a focused evidence envelope and revalidates it through
`--evidence`; it is still `readiness=false` and is not deploy or release
signoff. Evidence intake accepts only this confirmed-apply envelope; server
dry-run reports and empty-step online gate reports are rejected.
External-declared online `--target-registry <registry-host[/namespace]>` asks
the gate to generate an image-map and render target image references. In confirmed
`--mode apply`, it also requires `--registry-probe <executable>` and runs
`--registry-presence` immediately after image-map and before render, apply,
smoke, or evidence closure. Server dry-run target-registry does not require and
does not allow the probe.
Kit-installed online is source-registry only: it requires
`--substrate-pack-manifest <json>` plus `--routability-probe <executable>` and
rejects `--target-registry`, `--registry-probe`, and `--evidence-root`.

For standalone online target registry presence diagnostics, run
`--registry-presence` separately with the generated mirror-required
`image-map.json` and an operator-provided read-only probe. The probe is called as
`<executable> <target_image> <expected_digest>` and must print exactly one
matching sha256 digest. The resulting `registry-presence-report.json` has
`readiness=false`, omits raw probe output and probe path, is not
evidence-envelope input, and does not prove deploy/package/release readiness.
Neither path performs registry login, pull, push, or mirror.

After a confirmed online focused chain run, operators may run
`--operator-signoff-intake` with `operator-signoff-intake.json` and the
generated `online-deployment-gate-report.json`. This is machine intake and
binding only: it checks the signoff JSON allowlist, release identity, release
contract digest, target profile, operator run id, raw report sha256, and the
canonical source-registry or target-registry confirmed-apply producer order. It
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
The image id set comes from the AgentSmith release contract's dynamic closure:
`release_contract.required_image_ids`,
`deploy_template_package.required_image_ids`, and `deploy_image_inventory` ids
must be exact-set aligned. Current fixtures/examples include `managed_runner`,
which is carried by ordinary image-map, render, and airgap archive mechanics
rather than a runner-specific runtime gate.

During pre-GA, stale six-image required-id inputs, obsolete
`${{ values.MANAGED_RUNNER_IMAGE }}` template placeholders, and stale
runner-name aliases such as `agent-task-runner` or `agentsmith-codex-runner`
are not operator success or compatibility paths. Treat them only as
fail-fast cases or negative diagnostics, and delete those cases once the formal
fixtures and runbooks stabilize.

For registry presence, use only `existing_kubernetes/external_declared/online`
and only a passing mirror-required image-map. This diagnostic does not log in,
pull, push, mirror, or choose registry tooling; the operator owns the
read-only probe implementation and credentials outside the report.

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

For airgap image load/import diagnostics, use `--airgap-image-load` only after
a bundle has already been assembled. Pass the same inputs as
`--airgap-image-archive-check`, including `--archive-probe <executable>`, plus
`--image-loader <executable>`. The command first reruns archive materiality,
then calls the loader once per image as
`<executable> <archive_path> <target_image> <target_digest>`. Loader stdout
must be exactly one matching sha256 digest. The report has `readiness=false`,
omits loader/archive paths and raw stdout/stderr, is not evidence-envelope
input, and does not prove offline install, deploy, package, registry, or
release readiness.

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

For airgap deployment gate diagnostics, use `--airgap-deployment-gate` only
with `existing_kubernetes/external_declared/airgap`. Server dry-run runs
target-preflight, bundle render-check, and apply dry-run only. Confirmed apply
requires archive probe, image loader, matching confirm profile, and operator
run id, then runs image-load, render-check, apply, rollout, and optional smoke;
its report is not evidence-envelope input or deploy/release readiness.

For kit-installed substrate pack materiality, use `--substrate-pack-check`
with `existing_kubernetes/kit_installed/online` or
`existing_kubernetes/kit_installed/airgap`, an explicit
`agentsmith.substrate-pack-manifest/v1`, and matching substrate truth. The
manifest must use `installed_by: agentsmith-release-kit`, plain semver
`release_kit_version`, digest-pinned PostgreSQL/MongoDB/Redis/object-storage/OIDC
images, and only sha256 digests or safe relative pack paths for
payload/templates/tools/checksums. The command reuses substrate truth
validation for services, secret refs, TLS or sslmode, pgvector, reachability,
and kit-installed identity. Its report has `readiness=false`, is not
evidence-envelope input, and does not install substrates, create
databases/buckets/realms, log in to registries, call Kubernetes, deploy,
package, or prove release readiness.

For kit-installed online substrate routability, use `--substrate-routability`
only after a passing `--substrate-pack-check` for
`existing_kubernetes/kit_installed/online`. Pass the matching substrate truth,
target prerequisites, namespace, explicit kubectl input, and an
operator-provided `--routability-probe`. The producer runs `kubectl version`
and calls the probe once per PostgreSQL, MongoDB, Redis, object storage, and
OIDC endpoint. The probe must perform the actual target Kubernetes Pod-network
check and echo the expected sha256 endpoint fingerprint. The report has
`readiness=false`, stores only input digests, kubectl version summary, service
ids, and fingerprints, is not evidence-envelope input, and does not install
substrates, create databases/buckets/realms, deploy, package, or prove release
readiness.

For route smoke, use `bash scripts/verify-release.sh --smoke` only after a
passing focused `rollout-report.json`. Supply an HTTPS URL by default; local
HTTP is reserved for focused tests with explicit `--allow-http
--allow-localhost`.

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
