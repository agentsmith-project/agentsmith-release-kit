# Runbooks

Status: operator package flow first; maintainer/internal diagnostics are in
the appendix.

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
airgap packages, every runtime file referenced by the path must live inside the
referenced `airgap_bundle`. Post-deploy product smoke is produced after the
runtime check; it is not an operator input package field.

### 3. What do I run?

Use the single operator facade:

```bash
bash scripts/operator-release.sh --operator-inputs <dir-or-json>
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --run
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <json> \
  --post-deploy-product-smoke-report <json> \
  --output-dir <dir>
```

The first command validates the package. Add `--run` only when the package is
ready to execute the selected apply path. A passing `--run` produces path-level
evidence for the release captain/finalizer to consume; do not treat
intermediate files as the formal release verdict. After all four package runs
and product-side reports are available, use `--ga-report` to write the final
`ga-release-report.json`.

### 4. What is the final report?

Formal release success or failure is represented only by the final
`ga-release-report.json` issued by the release finalizer/captain through
`operator-release.sh --ga-report`. The facade takes four package paths plus
AgentSmith product-side reports and locates internal path evidence itself.

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

## Maintainer/Internal Appendix

Everything below is for maintainers changing release-kit internals or for CI
diagnostic plumbing. It is not the operator main path.

### Release Captain/Finalizer Handoff Reference

Use one package for each deployment path. Do not combine the four paths into a
single manifest.

After all four package runs and product-side reports are available, the
operator/release captain runs the package facade:

```bash
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <agentsmith/product-readiness-report.json> \
  --post-deploy-product-smoke-report <agentsmith/post-deploy-product-smoke-report.json> \
  --output-dir <dir>
```

Maintainer diagnostics and internal verifier details live in
`docs/RELEASE_GATES.md`; this runbook intentionally keeps operators on
package inputs and the final `ga-release-report.json`.

The post-deploy product smoke input must be the AgentSmith canonical report:
`schema_version: agentsmith.post-deploy-product-smoke-report/v1`, `producer:
agentsmith-post-deploy-product-smoke`, and nested `release_contract: { path,
input_sha256, release_id, git_sha }`. Its `input_sha256`, `release_id`, and
`git_sha` must match the same `--release-contract` raw digest, id, and git sha.
Legacy surrogate top-level fields are rejected: `release_id`, `git_sha`,
`release_contract_digest`, `covered_flows`, and `artifact_provenance`.

Legacy `kit_provided` is a maintainer/internal alias for focused diagnostics.
It is not a GA operator `deployment_path`; operator packages use
`install_substrates`.

### Maintainer/Internal Diagnostics

Airgap bundle packaging commands are packaging-side helpers for the airgap
producer diagnostics, not standalone operator choices. The table names their
legacy diagnostic entries without copy-paste commands; operators should use
the package-driven `--operator-inputs` flow above.

| Packaging diagnostic | Machine profile mapping | Internal entry | Current result |
| --- | --- | --- | --- |
| `airgap-bundle/use_existing` | `existing_kubernetes/external_declared/airgap` | Legacy positional bundle packaging diagnostic, maintainer/internal only. | Runs the local bundle assembler and immediate self-check, then writes the operator surface summary. Follow-on consume diagnostics remain producer/focused commands. |
| `airgap-bundle/kit_provided` | `existing_kubernetes/kit_installed/airgap` | Legacy positional bundle packaging diagnostic, maintainer/internal only. | Runs the packaging-side local bundle assembler and immediate self-check, binds the substrate pack manifest as a bundle component, then writes the operator surface summary. It does not consume/deploy the bundle or install substrates. |

### Optional Rehearsal

| Path | Target profile | Internal diagnostic command entry | Current result |
| --- | --- | --- | --- |
| Kind rehearsal, kit-provided substrates, online | `kind_rehearsal/kit_installed/online` | `bash scripts/verify-release.sh --inputs ...` and `--target-preflight ... --substrate-truth ... --target-prerequisites ...` | Accepts rehearsal intake only. It is not a prerequisite for real Kubernetes. |

For airgap consume rehearsal, optional
`--rehearsal-label existing_kubernetes|kind_rehearsal` is
operator-provided label-only metadata for the supplied Kubernetes endpoint. It
does not change the target profile, create or manage kind, or prove the
endpoint is kind.

### Legacy Diagnostic Status

The following table is maintainer/internal compatibility status for focused
diagnostics. It is not the operator-facing package matrix.

| Path | Implemented now | Not yet |
| --- | --- | --- |
| `online/use_existing` | Inputs, target-preflight over substrate truth plus target prerequisites, template-package, optional image-map target-ref adoption, optional registry presence through an operator probe, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke through the online focused chain. | Cloud provisioning, substrate provisioning, registry mirroring, registry login, rollback, product-flow checks, deploy readiness, release readiness. |
| `online/kit_provided` | Contract declaration, target-preflight substrate/prerequisites intake, standalone image-map planning, substrate pack focused materiality, Pod-network substrate routability, template-package, render, render-check, apply dry-run or confirmed apply, rollout, optional route smoke, and optional confirmed-apply evidence envelope through the online focused chain. | Substrate installer, target-registry/registry-probe support, deploy readiness, package readiness, release readiness. |
| `airgap/use_existing` | Bundle consume/deployment-focused diagnostics for an already assembled existing-substrate airgap bundle: bundle check, image load, bundle render-check, apply, rollout, optional smoke, and operator surface summary. | Registry mirroring, offline install, full readiness, operator verdict, deploy readiness, package readiness, release readiness. |
| `airgap/kit_provided` | Bundle consume/deployment-focused diagnostics for an already assembled kit-provided airgap bundle: bundle check, substrate-pack-check, image load, bundle render-check, apply, rollout, optional smoke, and operator surface summary. | Substrate installer, full readiness, operator verdict, deploy readiness, package readiness, release readiness. |
| `airgap-bundle/use_existing` | Image-map mirror plan through the bundle-create producer, local bundle assembler plus self-check, and operator surface summary. Other airgap checks remain focused producer diagnostics. | Registry mirroring, offline install, deploy readiness, package readiness. |
| `airgap-bundle/kit_provided` | Packaging-side bundle assembly, substrate pack manifest component/digest binding, bundle self-check, and operator surface summary. | Bundle consume/deploy execution by this command; use `airgap/kit_provided` for the consume/deployment-focused path. Still no substrate installer, full readiness, operator verdict, deploy readiness, package readiness, or release readiness. |

### Command Roles

`scripts/test-*.sh` files are maintainer self-tests for this repository. They
exercise failure cases and fixture behavior while changing release-kit code.

The positional `bash scripts/operator-release.sh <surface>
<substrate_strategy> ...` facade is a maintainer/internal focused diagnostic,
not the operator main path. It rejects producer vocabulary such as
`--target-profile`, maps the operator choice internally, calls the existing
producer diagnostic, and writes
`operator-release-surface-report.json` with a minimal `readiness=false`
summary. That summary is not accepted by `--evidence`.
For confirmed apply, keep using the operator choice as the confirmation value,
for example `--confirm-apply online/use_existing`; raw machine profiles are
rejected at the facade.

`bash scripts/verify-release.sh --...` remains the producer catalog and
maintainer/focused diagnostic entry. Use it when changing release-kit internals
or running a specific downstream check, not as the first operator-facing
command.

Default PR/push CI follows the quick/core path only:
`verify-release.sh --quick`, `test-inputs.sh`, `test-template-package.sh`,
`test-render.sh`, `test-render-check.sh`, and
`test-operator-inputs.sh`, `test-operator-inputs-orchestration.sh`,
`test-operator-release-surface.sh`, `test-substrate-install.sh`,
`test-deployment-path-report.sh`, `test-ga-release.sh`, and
`test-package-driven-ga-smoke.sh`.
`test-substrate-install.sh` stays in this default path because it uses local
fixtures and fake kubectl, including online plus low-cost airgap producer
coverage. Maintainer diagnostics such as adoption aggregation, operator signoff
intake, airgap image load, substrate routability, and release-engineering intake
are manual `workflow_dispatch` checks. They are useful while changing those
producers, but they are not default operator quick-path evidence and still do
not issue deploy, package, or release readiness.

For a concrete real Kubernetes plus existing substrates online example, copy
and edit `examples/online-existing-kubernetes/`. It demonstrates the
package-driven `--operator-inputs` intake, confirmed apply, optional route
smoke, and finalized deployment-path evidence handoff without claiming GA
readiness.

For target-preflight and the online focused chain, keep substrate connection
truth and target prerequisites as separate files. Substrate truth stays neutral;
target prerequisites carry namespace, RBAC policy/proof, ingress TLS, registry
pull secret, storage policy, and substrate secret refs. The registry object is
limited to `pull_secret_ref`; do not add `preloaded`, `mirror_done`, `verdict`,
`token`, or other pseudo-proof fields.

For the online focused chain, confirmed apply can optionally add
`--evidence-root <dir> --evidence-provenance <json>` on
`existing_kubernetes/external_declared/online` or
`existing_kubernetes/kit_installed/online`. Use only remote release-kit
provenance such as CI artifact or signed operator-run metadata. The gate writes
a focused evidence envelope and revalidates it through `--evidence`; it is
still `readiness=false` and is not deploy or release signoff. Evidence intake
accepts only this confirmed-apply envelope; server dry-run reports,
empty-step online gate reports, missing kit substrate steps, and external/kit
profile mixes are rejected.
When this runs through `operator-release.sh`, the operator surface summary may
include a digest-only `online_handoff` block for the evidence root. It is a
handoff summary only, not release, deploy, or package readiness.
External-declared online `--target-registry <registry-host[/namespace]>` asks
the gate to generate an image-map and render target image references. In confirmed
`--mode apply`, it also requires `--registry-probe <executable>` and runs
`--registry-presence` immediately after image-map and before render, apply,
smoke, or evidence closure. Server dry-run target-registry does not require and
does not allow the probe.
Kit-provided online is source-registry only: it requires
`--substrate-pack-manifest <json>` plus `--routability-probe <executable>` and
rejects `--target-registry` and `--registry-probe`. Its evidence envelope keeps
the substrate-pack-check and substrate-routability steps but does not change
deploy/package/release readiness.

For standalone online target registry presence diagnostics, run
`--registry-presence` separately with the generated mirror-required
`image-map.json` and an operator-provided read-only probe. The probe is called as
`<executable> <target_image> <expected_digest>` and must print exactly one
matching sha256 digest. The resulting `registry-presence-report.json` has
`readiness=false`, omits raw probe output and probe path, is not
evidence-envelope input, and does not prove deploy/package/release readiness.
Neither path performs registry login, pull, push, or mirror.

After a confirmed online focused chain run, maintainers may run
`--operator-signoff-intake` with `operator-signoff-intake.json` and the
generated `online-deployment-gate-report.json` only for explicit GA or
compliance trigger work. This is machine intake and binding only: it checks
the signoff JSON allowlist, release identity, release contract digest, target
profile, operator run id, raw report sha256, and the canonical source-registry
or target-registry confirmed-apply producer order. It writes
`operator-signoff-intake-report.json` with `readiness=false`, does not verify
signatures or identity, is not registry presence proof, is not accepted by the
evidence envelope validator, and is not deploy/package/release readiness.

For maintainer-only repo-local candidate intake, run
`--release-engineering-gate-intake` with the generated online adoption report
and both airgap adoption reports. The command only verifies the candidate
boundary for explicit GA or compliance trigger work: all four operator choices
are present, release identity/digest/provenance bindings agree with the
release contract, focused producer reports are not used as adoption inputs, and
no input already contains readiness or verdict fields. It writes
`release-engineering-gate-intake-report.json` with `readiness=false` and
`formal_verdict=not_issued`, and lists future formal operator verdict plus
offline/package/release readiness as blocking gaps. It is not accepted by
evidence intake and is not deploy/package/release readiness.

### Current Notes

Pre-GA release contracts may declare the four existing-Kubernetes operator
choice mappings plus `kind_rehearsal/kit_installed/online` only as
rehearsal-only input, but none may be marked required. Keep every
`target_profiles[].required` value `false`; `required: true` fails fast because
release-kit does not yet have full deploy/package evidence for every path.

For image-map, online targets may omit `--target-registry` to use source
digest refs directly. Airgap targets require
`--target-registry <registry-host[/namespace]>`; namespace components must be
lowercase and start and end with alphanumeric characters.
Evidence intake rechecks the same adoption rule as render: source-use plans
cannot carry `target_registry`, and mirrored targets must match the
deterministic target registry ref.
The image id set comes from the AgentSmith release contract's embedded deploy
template package closure:
`release_contract.deploy_template_package.required_image_ids`,
`deploy_template_package.required_image_ids`, and `deploy_image_inventory` ids
must be exact-set aligned. Non-product image declarations such as provider
images, release-kit prerequisite images, or `managed_runner_image` are
optional release-kit intake details. If the closure includes one, it is carried
by ordinary image-map, render, and airgap archive mechanics rather than a
runner-specific runtime gate.

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
For `airgap-bundle/use_existing` and `airgap-bundle/kit_provided`,
optional
`--evidence-root <dir> --evidence-provenance <json>` writes an unsigned focused
evidence root only after bundle self-check passes, then revalidates it through
`--evidence`. The root contains `evidence.json`, `evidence-subject.json`,
`airgap-bundle-check-report.json`, `airgap-bundle-manifest.json`, and
`image-map.json`; kit-provided airgap also contains
`substrate-pack-manifest.json`. The envelope uses `release_kit_output:
airgap_bundle_check`, keeps `readiness=false`, and does not add signature,
operator identity, formal verdict, package readiness, deploy readiness, or
release readiness semantics. The operator surface summary carries only a
digest-only airgap evidence handoff; for kit-provided airgap it includes the
substrate pack manifest digest.
The evidence root must be absent, empty, or contain only those managed evidence
files from a previous run; any other direct entry fails fast and is left in
place.
Scoped runbook acceptance is checked separately with
`scripts/verify-operator-runbook-acceptance.mjs`. It binds only the operator
choice, existing-Kubernetes airgap machine profile, operator surface report
digest, evidence root digests, and the safe runbook path/digest from the bundle
manifest. It rejects kind/local-kind profiles, signed provenance, operator
identity/signature fields, and formal/readiness/verdict fields in the
acceptance inputs.
For `airgap-bundle/kit_provided`, also provide
`--substrate-pack-manifest <json>`; the generated bundle records it as
`components/substrate-pack-manifest.json`,
`components[].kind: substrate_pack_manifest`, and
`bindings.substrate_pack_manifest_sha256`.

For airgap bundle checks, the bundle manifest must use
`schema_version: agentsmith.airgap-bundle-manifest/v1`. The check validates
safe relative paths and sha256 bindings only. It now requires
`payload_artifacts` for runbook/script/profile-values schema/checksums payloads
and `operator_prerequisites` for operator-held substrate truth, registry proof,
and tool prerequisites. Bundled tool files are checked by path/sha under the
bundle root; operator prerequisite locations/proofs are strings and must not be
URLs, download instructions, or secret-looking content. The airgap image-map is
also rebound to `release_contract.deploy_image_inventory`. Stdout ends with
`readiness=false`. Evidence intake for `airgap_bundle_check` accepts
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap` real check report + manifest +
`image-map.json` inputs with bundle-check-compatible components, image
declarations, payload/tool counts, and digests; empty fake manifests are
rejected. Kit-provided airgap additionally requires
`substrate-pack-manifest.json`, a `components[].kind` entry set to
`substrate_pack_manifest`, and `bindings.substrate_pack_manifest_sha256`.

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

For airgap deployment gate diagnostics, use `--airgap-deployment-gate` with
`existing_kubernetes/external_declared/airgap` or
`existing_kubernetes/kit_installed/airgap`. Server dry-run runs
target-preflight, bundle render-check, and apply dry-run only; kit-provided
airgap also runs substrate-pack-check. Confirmed apply requires archive probe,
image loader, matching confirm profile, and operator run id, then runs
image-load, render-check, apply, rollout, and optional smoke; kit-provided
airgap adds substrate-pack-check. Its report is not evidence-envelope input or
deploy/release readiness.

For airgap consume rehearsal, use `--airgap-consume-rehearsal` when the bundle
is already assembled and the operator wants one offline consumption entry
instead of repeating component paths by hand. Provide `--bundle-root`,
bundle-local render values and substrate truth, target prerequisites,
namespace, and Kubernetes client options. The runner discovers component paths
from `airgap-bundle-manifest.json`, runs `--airgap-bundle-check`, then reuses
the existing airgap deployment gate. The optional `--rehearsal-label` value is
label-only metadata and does not change the bundle target profile.
The report has
`readiness=false`, stores only `rehearsal_label`, digests, and
output-relative paths, is not evidence-envelope input, and does not prove
registry mirror/login, offline install, package, deploy, operator signoff, or
release readiness.

For kit-provided substrate pack materiality, use `--substrate-pack-check`
with `existing_kubernetes/kit_installed/online` or
`existing_kubernetes/kit_installed/airgap`, an explicit
`agentsmith.substrate-pack-manifest/v1`, and matching substrate truth. The
manifest must use `installed_by: agentsmith-release-kit`, plain semver
`release_kit_version`, digest-pinned PostgreSQL/MongoDB/Redis/object-storage/OIDC
images, and only sha256 digests or safe relative pack paths for
payload/templates/tools/checksums. The command reuses substrate truth
validation for services, secret refs, TLS or sslmode, pgvector, reachability,
and kit-provided identity. Its report has `readiness=false`, is not
evidence-envelope input, and does not install substrates, create
databases/buckets/realms, log in to registries, call Kubernetes, deploy,
package, or prove release readiness.

For kit-provided online substrate routability, use `--substrate-routability`
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
