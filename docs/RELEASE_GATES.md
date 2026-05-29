# Release Gates

Status: bootstrap-only.

## Quick Gate

Run:

```bash
bash scripts/verify-release.sh --quick
```

The quick gate is not release readiness. It only checks repo identity and
boundary guardrails.

Current quick checks:

- Canonical repo identity is `github.com/agentsmith-project/agentsmith-release-kit`.
- Required bootstrap files exist.
- Owner/team metadata exists.
- Scope and non-goals are declared.
- Release gate entry exists and states that quick is not release readiness.
- No AgentSmith product source import or relative product source path is used.
- No AFSCP or ASBCP source, contract, or gate dependency is used.
- No raw secret placeholder is present.
- No mutable image or non-digest release claim is present.

Passing the quick gate means repo-local workstreams can proceed. It does not
approve deploy tooling, package output, evidence, publishing, or adoption.

## Operator Release Surface v0 Focused Guard

Run:

```bash
bash scripts/test-operator-release-surface.sh
```

This focused guard exercises `bash scripts/operator-release.sh`. The facade
accepts operator choices only, rejects producer vocabulary such as
`--target-profile`, maps the choice internally, and calls the existing producer
diagnostic:

- `online/use_existing` -> `--online-deployment-gate` with
  `existing_kubernetes/external_declared/online`.
- `online/install_substrates` -> `--online-deployment-gate` with
  `existing_kubernetes/kit_installed/online`.
- `airgap-bundle/use_existing` -> `--bundle-create` with
  `existing_kubernetes/external_declared/airgap`.
- `airgap-bundle/install_substrates` fails fast in v0.

For confirmed apply, the operator passes the same operator choice to
`--confirm-apply`, for example `--confirm-apply online/use_existing`; the facade
maps that value to the producer target profile internally. Raw producer machine
profiles are rejected before producer reports or summaries are written.

The generated `operator-release-surface-report.json` must keep `schema:
agentsmith.operator-release-surface-report/v1`, `scope:
operator_release_surface_v0`, `readiness: false`, and `status: pass`. It stores
only release identity, release contract digest, producer report digests, and
output-relative step paths, with a small airgap handoff digest/count summary
for bundle creation. Online confirmed apply with `--evidence-root` may also add
a digest/provenance-only `online_handoff` summary. It is not accepted by
`--evidence` and is not deploy, package, or release readiness.

## Contract Intake Focused Diagnostic

Run:

```bash
bash scripts/test-inputs.sh
```

This focused guard exercises `bash scripts/verify-release.sh --inputs`. It
checks release contract intake, deploy template package intake, target-profile
selection, target-profile coverage, release-kit version policy, provenance, and
digest-bound image inventory only.

Release contract inventory closure is exact-set:
`release_contract.required_image_ids`,
`deploy_template_package.required_image_ids`, and
`release_contract.deploy_image_inventory` ids must be non-empty exact-set
matches. The release kit consumes the dynamic image closure from the AgentSmith
release contract rather than a hardcoded six-image list. Current
fixtures/examples include `managed_runner`, a digest-bound inventory image
supplied by the release contract. This is still a focused diagnostic with
`readiness: false`, not release readiness.

Every `release_contract.target_profiles` entry must declare
`required: boolean`; `support_level` is not accepted as a replacement. Duplicate
`target_cluster/substrate_source/distribution` tuples are rejected. Every entry
must use one of the canonical declarable profiles:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`,
`existing_kubernetes/kit_installed/airgap`, or
`kind_rehearsal/kit_installed/online`. During pre-GA every canonical profile
is declarable/intake-supported only for contract purposes, and every entry must
use `required: false`; any `required: true` target fails fast.

The generated `intake-report.json`, `image-digest-plan.json`, and
`target-profile-coverage-report.json` must keep `readiness: false`. The
coverage report separates `declarable_profiles`,
`intake_supported_profiles`, `executable_profiles`, and
`evidence_supported_profiles`. `executable_profiles` means currently
executable focused deployment profiles:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`; it does not include
`existing_kubernetes/kit_installed/airgap`, kind rehearsal, or aliases.
Evidence-supported profiles include external-declared online/airgap plus
kit-installed online confirmed-apply envelopes in this slice. They prove
contract/input digest readiness only. They are not
deploy readiness, package readiness, release readiness, rollout evidence, or
operator signoff. The coverage report must not contain `verdict` or
`release_verdict`.

## Template Package Archive Focused Diagnostic

Run:

```bash
bash scripts/test-template-package.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--template-package`. It checks only the materialized deploy template package
archive against the release contract and deploy template package descriptor.

The check verifies descriptor equality, archive sha256, declared provenance
artifact sha256, archive `manifest.json` sha256, path safety for package
entries, and obvious local source or plaintext credential payloads. It rejects
absolute paths, `..` package-root escapes, symlinks, and hardlinks before any
future render/check code can consume the archive.
It also enforces the same dynamic `required_image_ids` exact-set closure
against `deploy_image_inventory` ids; the report remains `readiness: false`.

The generated `template-package-report.json` must keep `readiness: false` and
`scope: template_package_intake_only`. It is not release readiness, package
readiness, Kubernetes render evidence, deploy evidence, rollout evidence, smoke
evidence, or operator signoff.

## Materialized Template Render Focused Diagnostic

Run:

```bash
bash scripts/test-render.sh
```

This focused guard exercises `bash scripts/verify-release.sh --render`. It
checks only repo-local rendering from an already materialized deploy template
package archive. It does not call `kubectl`, apply or dry-run manifests, roll
out workloads, smoke product endpoints, mirror images, read a sibling
AgentSmith checkout, or migrate AgentSmith unified-deploy rendering.
When a sibling `../agentsmith` checkout exists next to release-kit, `--render`
rejects it as a default forbidden source root.

The check binds the release contract, deploy template package descriptor,
archive sha256, archive `manifest.json` sha256, explicit target profile,
explicit render values, and
`agentsmith.substrate-connection.truth/v1` substrate truth. It renders only
`kubernetes` template files declared by archive `manifest.json` into
`<output-dir>/rendered-manifests` and keeps the archive path rules from the
template package diagnostic: absolute paths, `..` package-root escapes,
symlinks, hardlinks, local/source payloads, plaintext credential payloads, and
missing declared template files fail fast.
Direct render also enforces the dynamic `required_image_ids` exact-set closure;
the report remains `readiness: false` and is not release readiness.
If `--image-map <json>` is supplied, render validates a passing
`agentsmith.image-map/v1` report with `scope: image_map_only`,
`readiness: false`, matching release identity, release contract digest, target
profile axes, and one mapping per `deploy_image_inventory` item. It adopts
`mapping.target_image` for template image refs while keeping the expected digest
bound to the release inventory. It does not log in to a registry, pull, push,
mirror, or check registry presence.

The template language is scalar placeholder replacement only. It has no
conditionals, loops, includes, Helm, Kustomize, or non-canonical pre-GA target
names. Supported placeholder roots are `values`, `images`, `target`,
`substrate`, and `release`;
examples are `${{ values.namespace }}`, `${{ images.agentsmith_app.image }}`,
`${{ target.distribution }}`, `${{ substrate.services.postgresql.host }}`, and
`${{ release.release_id }}`. Unknown, malformed, unresolved, object, or array
placeholders fail fast.

After rendering, workload images in Deployment, StatefulSet, DaemonSet,
ReplicaSet, Job, CronJob, Pod, and List manifests must be digest-pinned and
must match `release_contract.deploy_image_inventory` by exact image ref or
digest. Unknown images, tag-only image refs, digest drift, secret-looking
rendered payloads, local/source paths, non-canonical pre-GA target profile names
such as `local-kind`, and synonym axes such as `kind` or `cluster` are rejected.

The generated `manifest-render-report.json` must keep `readiness: false`,
`scope: manifest_render_only`, and `status: pass`. It must not contain
`verdict`, `release_verdict`, `deploy_readiness`, or AgentSmith product-flow
fields. It is not release readiness, package readiness, apply evidence,
rollout evidence, smoke evidence, deploy evidence, or operator signoff.

## Render/Check Image Inventory Focused Diagnostic

Run:

```bash
bash scripts/test-render-check.sh
```

This focused guard exercises `bash scripts/verify-release.sh --render-check`.
It checks only rendered Kubernetes manifest files supplied through
`--rendered-manifests`; it does not render templates or read a sibling
AgentSmith checkout.

The check scans yaml, yml, and json files for Deployment, StatefulSet,
DaemonSet, ReplicaSet, Job, CronJob, and Pod workload images under
`containers` and `initContainers`. Every discovered workload image must be
digest-pinned and must match `release_contract.deploy_image_inventory` by exact
image ref or digest. It rejects unknown images, tag-only image refs, digest
drift, non-canonical pre-GA target names such as `local-kind`, synonym axes,
manifest path escapes, external symlinks, and obvious plaintext credential or
kubeconfig payloads.

The generated `render-report.json` must keep `readiness: false`,
`scope: render_check_image_inventory_only`, and `status: pass`. It must not
contain `verdict` or `release_verdict`. It is not release readiness, package
readiness, render readiness, apply evidence, rollout evidence, smoke evidence,
deploy evidence, or operator signoff.

## Image-Map / Mirror-Plan Focused Diagnostic

Run:

```bash
bash scripts/test-image-map.sh
```

This focused guard exercises `bash scripts/verify-release.sh --image-map`. It
checks only the release contract `deploy_image_inventory` and writes a
digest-pinned source-to-target image reference map. It does not log in to a
registry, pull images, push images, create a mirror, build an airgap bundle,
call Kubernetes, or claim deploy, package, or release readiness.

`--image-map` accepts existing Kubernetes canonical profiles as CLI targets:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`.
`kind_rehearsal/kit_installed/online` is a canonical profile tuple but out of
scope for image-map CLI. Only canonical profile tuples are accepted in
`release_contract.target_profiles`; non-canonical pre-GA names and synonym
axes fail fast. The selected target profile must exist in the release
contract. Every inventory item must have unique `id`, `image`, and `digest`
values; each image must be digest-pinned and its `@sha256` suffix must match
the `digest` field.
Standalone image-map enforces the release contract's dynamic
`required_image_ids` exact-set closure against `deploy_image_inventory` ids;
this remains a focused `readiness: false` diagnostic, not release readiness.

For online targets without `--target-registry`, target image refs equal source
image refs and mappings use `action: use_source`. Airgap targets require
`--target-registry <registry-host[/namespace]>`. Whenever a target registry is
provided, mappings use `action: mirror_required`; target refs are derived by
stripping the source registry and tag, preserving the repository path, and
appending the original sha256 digest under the target registry. Target
registries must not include schemes, userinfo, whitespace, query, hash,
localhost, 127.x, `::1`, or `host.docker.internal`. Namespace components must
be lowercase and must start and end with alphanumeric characters.

The generated `image-map.json` must keep `schema: agentsmith.image-map/v1`,
`scope: image_map_only`, `readiness: false`, and `status: pass`. It must not
contain `verdict`, `release_verdict`, deploy readiness, AgentSmith
product-flow fields, raw credential payloads, or registry login material.

If the release contract closure includes `managed_runner`, image-map propagates
it as a normal digest-bound mapping. Render and airgap archive diagnostics carry
that id through their existing image placeholder adoption and image artifact
declaration rules. This is not a dedicated runner runtime gate and does not
cover AgentSmith runner runtime, backend-real validation, or release readiness.
During pre-GA, stale six-image required-id inputs, obsolete
`${{ values.MANAGED_RUNNER_IMAGE }}` template placeholders, and stale
runner-name aliases such as `agent-task-runner` or `agentsmith-codex-runner`
are not formal success or compatibility paths; they are limited to fail-fast
checks or negative diagnostics, and can be deleted once the formal fixtures and
runbooks stabilize.

## Registry Presence Focused Diagnostic

Run:

```bash
bash scripts/test-registry-presence.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--registry-presence`. It checks only that a passing, mirror-required online
image-map points at digest refs that an operator-provided read-only probe can
resolve in the target registry. It accepts only
`existing_kubernetes/external_declared/online`.

Required inputs are `--release-contract <json>`, `--image-map <json>`,
`--target-profile existing_kubernetes/external_declared/online`,
`--registry-probe <executable>`, and `--output-dir <dir>`. The image-map must
have schema `agentsmith.image-map/v1`, scope `image_map_only`,
`readiness: false`, `status: pass`, `mirror_required: true`, a
`target_registry`, matching release identity, matching release contract raw
sha256, and one-to-one
mappings for `release_contract.deploy_image_inventory`. The release contract
must keep `required_image_ids` as an exact-set match for
`deploy_image_inventory` ids. Target images must equal the deterministic mirror ref
computed from the release contract source image plus
`image_map.target_registry`, and every target digest must equal the source
digest.

The probe interface is `<executable> <target_image> <expected_digest>`. The
producer does not implement registry clients itself; it only checks the probe
exit code and requires stdout to contain exactly one `sha256:<64>` digest equal
to the expected target digest. Raw probe stdout, stderr, executable path,
credentials, kubeconfig content, and tokens must not be written to the report.

The generated `registry-presence-report.json` must keep `schema:
agentsmith.registry-presence/v1`, `scope: registry_presence_only`,
`readiness: false`, and `status: pass`. It may contain only release identity,
target profile, target registry, release contract and image-map input digests,
image count, and digest match summaries. It does not log in, pull, push,
mirror, call Docker, skopeo, oras, kubectl, curl, wget, or cloud APIs, apply
Kubernetes resources, or claim deploy/package/release readiness. It is not an
accepted release-kit evidence envelope output.

## Airgap Bundle Create Focused Diagnostic

Run:

```bash
bash scripts/test-bundle-create.sh
```

This focused guard exercises `bash scripts/verify-release.sh --bundle-create`.
It is a KISS local assembler plus self-check for
`existing_kubernetes/external_declared/airgap` only. It does not log in to a
registry, pull, push, mirror, save, load, call Docker, skopeo, oras, kubectl,
curl, or wget, inspect OCI tar contents, deploy workloads, or claim offline
install, package, deploy, or release readiness.

The guard requires explicit local inputs: release contract, deploy template
package descriptor, matching `.tgz` archive, target registry, repeated
`--image-archive <image_id=local-file>` entries matching the generated
image-map one-to-one, runbook, script, profile-values schema, optional
profile-values example, operator prerequisites JSON, an absent-or-empty bundle
root, and output directory. It rejects online, kind, `kit_installed/airgap`,
and synonym axes. Image archives, payloads, and bundled tools must be local
regular files, not URIs, directories, or symlinks; secret-looking payloads and
operator URL/download/secret proofs fail fast.

The generated bundle contains fixed local paths under `components/`, `images/`,
`payload/`, optional `tools/`, and root `airgap-bundle-manifest.json`. The
assembler immediately runs the existing airgap bundle check against that
manifest. Only after self-check passes does it write
`bundle-create-report.json` with `schema:
agentsmith.airgap-bundle-create-report/v1`, `scope:
airgap_bundle_create_only`, `readiness: false`, and non-sensitive count/digest
summaries. The report must not contain raw local paths, bundle root, operator
refs, locations, proofs, verdicts, registry presence, image-load claims, or
readiness claims. It is not an accepted release-kit evidence envelope output.

## Airgap Bundle Manifest/Digest Focused Diagnostic

Run:

```bash
bash scripts/test-airgap-bundle-check.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--airgap-bundle-check`. It checks only a local bundle manifest, safe bundle
paths, the deploy template archive sha256, and declared file sha256 values
under an explicit bundle root. It does not call Docker, skopeo, oras, kubectl,
pull images, push images, mirror images, save images, load images, create an
airgap package, parse the `.tgz`, inspect tar or OCI contents, verify registry
presence, or claim offline install, deploy, package, or release readiness.

`--airgap-bundle-check` accepts only
`existing_kubernetes/external_declared/airgap`. Online, kind rehearsal,
`kit_installed`, non-canonical pre-GA target names, and synonym axes fail fast.
The image-map
must be a passing airgap `agentsmith.image-map/v1` report with `scope:
image_map_only`, `readiness: false`, `mirror_required: true`, a target
registry, and `action: mirror_required` on every mapping. The bundle check
binds those mappings back to `release_contract.deploy_image_inventory`: ids
must exist, source image and digest must match inventory, target digest must
equal source digest, and target image must be under `image_map.target_registry`
with `@<target_digest>`.
The check also enforces the dynamic `required_image_ids` exact-set closure from
inputs/template-package and `deploy_image_inventory` ids; this does not make the
bundle check release readiness.

The release contract `target_profiles` value must be an array and must declare
`existing_kubernetes/external_declared/airgap`. Every target profile tuple must
be canonical, every entry must carry `required: false` during pre-GA, and
`support_level` is rejected. `existing_kubernetes/kit_installed/airgap` may be
declared in the contract, but this check does not deploy it.

The bundle manifest must use `schema_version:
agentsmith.airgap-bundle-manifest/v1`. Its `components` array must contain
exactly one component for each `kind`: `release_contract`,
`deploy_template_package`, `deploy_template_archive`, and `image_map`; each
component path must stay under the bundle root and its sha256 must match the
explicit input file. `bundle_manifest.bindings.deploy_template_archive_sha256`
must match the supplied archive sha256. The archive sha256 must also match
`deploy_template_package.package_sha256` and
`deploy_template_package.artifact_provenance.artifact_sha256`. Image artifact
declarations must match image-map mappings one-to-one by id and must use
`artifact_format: oci_layout_tar`. Bundle paths are POSIX-style relative paths
only; absolute paths, parent segments, empty segments, dot segments,
backslashes, URI paths, symlinks, missing files, unexpected manifest fields,
and sha mismatches fail fast.

The manifest also requires `payload_artifacts` and
`operator_prerequisites` at the top level. `payload_artifacts[]` allows only
`id`, `kind`, `path`, and `sha256`; allowed kinds are `runbook`, `script`,
`profile_values_schema`, `profile_values_example`, and `checksums`, with
`runbook`, `script`, `profile_values_schema`, and `checksums` required.
Payload paths reuse the safe bundle-root relative file check and sha256 must
match the file. Duplicate payload ids, unknown fields, unknown kinds, unsafe
paths, missing files, and sha mismatches fail fast. `operator_prerequisites`
allows only `substrate_connection_truth_ref`, `target_registry_proof_ref`, and
`tools`; refs are non-empty operator-held strings and are not read as bundle
files. Tools are source-discriminated: `source: "bundled"` allows only `name`,
`version`, `source`, `path`, and `sha256`, with path/sha checked under the
bundle root; `source: "operator_prerequisite"` allows only `name`, `version`,
`source`, `location`, and `proof`, and those strings are not read as files.
Missing source, unknown source, field mixing, missing required fields, URI
schemes, public-download semantics, and secret-looking content fail fast.

The generated `airgap-bundle-check-report.json` must keep `schema:
agentsmith.airgap-bundle-check-report/v1`, `scope:
airgap_bundle_manifest_check_only`, `readiness: false`, and `status: pass`. It
must not contain `verdict`, `release_verdict`, deploy readiness, offline
install readiness, registry presence verification, image load verification,
AgentSmith product-flow fields, raw credential payloads, or registry login
material. It may include only non-sensitive counts for payload artifacts and
tools, not raw paths, refs, locations, or proof strings.

## Airgap Image Archive Materiality Focused Diagnostic

Run:

```bash
bash scripts/test-airgap-image-archive-check.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--airgap-image-archive-check`. It consumes an already assembled airgap bundle
and first reuses the existing `--airgap-bundle-check` validator. It accepts
only `existing_kubernetes/external_declared/airgap`; online, kind rehearsal,
`kit_installed`, non-canonical pre-GA target names, and synonym axes fail fast.
It does not call Docker, skopeo, oras, kubectl, curl, or wget, does not log in
to a registry, pull, push, mirror, load/import images, apply manifests, deploy,
or smoke.

The diagnostic requires `--archive-probe <executable>`. The probe must be a
local executable and is invoked once per
`bundle_manifest.image_artifact_declarations[]` archive file under the bundle
root. The archive path is provided as argv and env. Probe stdout must be
exactly one `sha256:<64>` digest and stderr must be empty. The probe digest
must match the image-map `target_digest`; bundle-check has already aligned
that digest with `release_contract.deploy_image_inventory`. This proves only
local archive digest materiality through the chosen probe. `--archive-probe`
is an operator-owned trusted local executable; release-kit does not sandbox it
or prove the probe itself trustworthy, and only validates stdout digest
alignment with the release contract, image-map, and bundle manifest. It is not
a registry mirror, image import, image load, offline install, package, deploy,
or release readiness check.

The generated `airgap-image-archive-check-report.json` must keep `schema:
agentsmith.airgap-image-archive-check-report/v1`, `scope:
airgap_image_archive_content_check_only`, `readiness: false`, and `status:
pass`. It may contain only release identity, target profile, input/report
digest summary, archive counts, image ids, and digest summaries. It must not
include absolute paths, bundle root, probe path, raw probe output, target
registry topology, operator refs, locations, proofs, secrets, `verdict`,
`release_verdict`, image load/import/push success, registry execution,
offline install readiness, package readiness, deploy readiness, or release
readiness. It is not an accepted release-kit evidence envelope output.

## Airgap Image Load Focused Diagnostic

Run:

```bash
bash scripts/test-airgap-image-load.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--airgap-image-load`. It consumes an already assembled airgap bundle and first
reuses `--airgap-image-archive-check`, so the existing bundle-check and archive
materiality semantics must pass before any loader call. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind rehearsal,
`kit_installed`, non-canonical pre-GA target names, and synonym axes fail fast.

The diagnostic requires both `--archive-probe <executable>` and
`--image-loader <executable>`. The loader is operator-provided and is invoked
once per declared image archive as:

```text
<executable> <archive_path> <target_image> <target_digest>
```

Loader stdout must be exactly one `sha256:<64>` digest matching
`target_digest`; non-zero exit, digest mismatch, and extra stdout fail fast.
Release-kit does not choose or depend on Docker, skopeo, oras, kubectl, or
registry credentials. Those remain operator-owned behind the loader boundary.

The generated `airgap-image-load-report.json` must keep `schema:
agentsmith.airgap-image-load-report/v1`, `scope: airgap_image_load_only`,
`readiness: false`, and `status: pass`. It may contain only release identity,
target profile, image ids, digest summaries, and counts. It must not contain
loader path, archive absolute paths, raw loader stdout/stderr, operator refs,
proofs, locations, secrets, `verdict`, `release_verdict`, offline install
readiness, package readiness, deploy readiness, registry readiness, or release
readiness. It is not an accepted release-kit evidence envelope output.

## Airgap Bundle Load Plan Focused Diagnostic

Run:

```bash
bash scripts/test-bundle-load-plan.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--bundle-load-plan`. It consumes an already assembled airgap bundle and first
reuses the existing `--airgap-bundle-check` validator. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind rehearsal,
`kit_installed`, non-canonical pre-GA target names, and synonym axes fail fast
before self-check.

The load plan rechecks that the image-map is a passing airgap mirror plan with
`scope: image_map_only`, `readiness: false`, `mirror_required: true`, target
registry, and `action: mirror_required` on every mapping. Image artifact
declarations must match image-map mappings one-to-one by id, target digests
must match target image digest suffixes, and target images must be under
`image_map.target_registry`. Operator prerequisites must declare the target
registry proof ref and operator-prerequisite tool proofs, but those proof
strings are not registry presence, signed load, push, import, package
readiness, or release readiness proof.

The generated `airgap-bundle-load-plan-report.json` must keep `schema:
agentsmith.airgap-bundle-load-plan-report/v1`, `scope:
airgap_bundle_load_plan_only`, `readiness: false`, and `status: pass`. It may
contain only release identity, target profile, target registry, image count,
digest summary, count summary, and target-registry summary. It must not contain
raw local paths, operator refs, locations, proofs, secrets, `verdict`,
`release_verdict`, registry presence fields, image load/import/push success
fields, or deploy/package/release readiness fields. It does not call Docker,
skopeo, oras, kubectl, curl, or wget, does not read OCI tar contents, does not
log in to a registry, push, import, load images, deploy, or smoke. It is not an
accepted release-kit evidence envelope output.

## Airgap Bundle Render-Check Focused Diagnostic

Run:

```bash
bash scripts/test-airgap-bundle-render-check.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--airgap-bundle-render-check`. It consumes an already assembled airgap bundle
only. The release contract, deploy template package descriptor, archive,
image-map, bundle manifest, render values, and substrate truth must all be
local files inside the bundle root. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind rehearsal,
`kit_installed`, non-canonical pre-GA target names, and synonym axes fail fast.

The diagnostic first reuses `--airgap-bundle-check`, then reuses `--render`
with the bundle-local airgap image-map, then reuses `--render-check` against
the rendered manifests. After those pass, it verifies that the rendered image
inventory uses image-map `target_image` refs only; source-image refs in
rendered workloads fail even if they are digest-pinned and listed in the
release contract.

The generated `airgap-bundle-render-check-report.json` must keep `schema:
agentsmith.airgap-bundle-render-check-report/v1`, `scope:
airgap_bundle_render_check_only`, `readiness: false`, and `status: pass`. It
may contain only digest, count, and relative-path summaries, and must not
include `target_registry`. It must not contain operator refs, locations,
proofs, absolute paths, `verdict`, `release_verdict`, package/offline
install/deploy/release readiness, registry presence, image load/import/push
success, apply, rollout, or smoke claims. It does not call Docker, skopeo,
oras, kubectl, curl, or wget, does not log in to a registry, load or import
images, apply manifests, deploy, or smoke. It is not an accepted release-kit
evidence envelope output.

## Airgap Deployment Focused Chain

Run:

```bash
bash scripts/test-airgap-deployment-gate.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--airgap-deployment-gate` for `existing_kubernetes/external_declared/airgap`
only. `server-dry-run` runs target-preflight, airgap bundle render-check, and
apply server dry-run, and rejects archive/image loader, confirmed apply,
operator run, and smoke options.

Confirmed `--mode apply` requires `--archive-probe`, `--image-loader`,
matching `--confirm-apply existing_kubernetes/external_declared/airgap`, and
`--operator-run-id`; it then runs image-load, bundle render-check, apply,
rollout, and optional smoke only when `--smoke-url` is supplied.
`airgap-deployment-gate-report.json` has `schema:
agentsmith.airgap-deployment-gate/v1`, `scope:
airgap_deployment_gate_only`, `readiness: false`, and `status: pass`; it is
not evidence-envelope input and does not prove registry mirror/login,
offline install, package, deploy, operator signoff, or release readiness.

## Airgap Consume Rehearsal Focused Chain

Run:

```bash
bash scripts/test-airgap-consume-rehearsal.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--airgap-consume-rehearsal`. It is a KISS consumer-side entry for an already
assembled `existing_kubernetes/external_declared/airgap` bundle. It does not
create bundles, create or manage clusters, install substrates, mirror images,
choose registry tooling, run product flows, or claim offline install, package,
deploy, or release readiness.

The runner requires `--bundle-root`, bundle-local `--render-values` and
`--substrate-truth`, explicit `--target-prerequisites`, `--namespace`, and
`--output-dir`. `--bundle-manifest` defaults to
`<bundle-root>/airgap-bundle-manifest.json` and, when provided, must still be
inside the bundle root. The manifest is used only to discover the four fixed
component paths: release contract, deploy template package, deploy template
archive, and image-map. Those component paths must be safe bundle-local files
before any producer step runs. The selected target profile remains
`existing_kubernetes/external_declared/airgap`.

Default `server-dry-run` runs `--airgap-bundle-check`, then reuses
`--airgap-deployment-gate` server dry-run for target preflight, bundle
render-check, and Kubernetes apply dry-run. Confirmed `--mode apply` requires
`--archive-probe`, `--image-loader`, matching `--confirm-apply
existing_kubernetes/external_declared/airgap`, and `--operator-run-id`, then
reuses the existing image-load, render-check, apply, rollout, and optional
smoke steps inside the deployment gate. `--rehearsal-label
existing_kubernetes|kind_rehearsal` is operator-provided label-only metadata
for the Kubernetes endpoint. It does not alter target profile semantics,
create or manage kind, prove the endpoint is kind, or make kind-labeled
evidence a replacement for real Kubernetes evidence.

The generated `airgap-consume-rehearsal-report.json` must keep `schema:
agentsmith.airgap-consume-rehearsal/v1`, `scope:
airgap_consume_rehearsal_only`, `readiness: false`, and `status: pass`. It
stores release identity, target profile, `rehearsal_label`, input digest
summaries, producer report digests, and only the two main output-relative
report paths for `airgap-bundle-check` and `airgap-deployment-gate`. It must
not contain `verdict`, `release_verdict`, deploy readiness, raw local paths,
operator refs, registry login material, raw kubectl output, or product-flow
fields. It is not an evidence-envelope input.

## Kubernetes Apply-Only Focused Diagnostic

Run:

```bash
bash scripts/test-apply.sh
```

This focused guard exercises `bash scripts/verify-release.sh --apply`. It
validates already-rendered manifests against a real Kubernetes API by default
with server-side dry-run. It does not render templates, roll out workloads,
smoke routes, run product flows, provision cloud resources, build packages, or
claim deploy or release readiness.

`--apply` accepts only `existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`. `kind_rehearsal`,
`kit_installed/airgap`, aliases such as `offline`, non-canonical pre-GA names,
and synonym axes fail fast.
Required inputs are `--release-contract`, `--rendered-manifests`,
`--target-profile`, `--namespace`, and `--output-dir`. Optional inputs are
`--kubeconfig`, `--context`, `--kubectl`, and `--forbidden-source-root`.
If a sibling `../agentsmith` checkout exists next to release-kit, `--apply`
passes it as a default forbidden source root to render/check.

Before any `kubectl` call, the apply diagnostic must pass the render/check
image inventory guard. The default mode is `server-dry-run`, which runs
`kubectl apply --server-side --dry-run=server`. Real apply requires all of:
`--mode apply`, `--confirm-apply <matching-target-profile>`,
and `--operator-run-id <id>`.

The generated `apply-report.json` must keep `schema_version:
agentsmith.kubernetes-apply-report/v1`, `scope: kubernetes_apply_only`,
`readiness: false`, and `status: pass`. It records the release contract digest,
target axes, namespace, mode, resource refs, kubectl version, and
`operator_run_id` only for real apply mode. It must not contain `verdict`,
`release_verdict`, deploy readiness, product-flow fields, kubeconfig content,
or raw secret payloads.

## Kubernetes Rollout/Live Digest Focused Diagnostic

Run:

```bash
bash scripts/test-rollout.sh
```

This focused guard exercises `bash scripts/verify-release.sh --rollout`. It
checks only rollout status and live pod image digest adoption for
already-rendered manifests. It does not render templates, apply resources,
smoke routes, run product flows, provision cloud resources, build packages, or
claim deploy or release readiness.

`--rollout` accepts only `existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`. `kind_rehearsal`,
`kit_installed/airgap`, aliases such as `offline`, non-canonical pre-GA names,
and synonym axes fail fast.
Required inputs are `--release-contract`, `--rendered-manifests`,
`--target-profile`, `--namespace`, and `--output-dir`. Optional inputs are
`--timeout` (default `120s`), `--kubeconfig`, `--context`, `--kubectl`, and
`--forbidden-source-root`. If a sibling `../agentsmith` checkout exists next to
release-kit, `--rollout` passes it as a default forbidden source root to
render/check.

Before any `kubectl` call, the rollout diagnostic must pass the render/check
image inventory guard. The rendered workload set must contain only
Deployment, StatefulSet, and DaemonSet resources. List wrappers are flattened
by render/check and judged by their inner workloads; other workload kinds such
as Job, CronJob, Pod, or ReplicaSet fail fast before rollout commands. For
each rollout-capable resource, the diagnostic runs `kubectl rollout status
<kind>/<name> --namespace <ns> --timeout <duration>`, then reads
`kubectl get <kind>/<name> --namespace <ns> -o json`. The workload selector
must use non-empty `spec.selector.matchLabels` with safe non-empty string keys
and values; `matchExpressions` are not supported. The diagnostic then reads
`kubectl get pods --namespace <ns> --selector <selector> -o json` and verifies
that every expected render/check image digest for that workload appears in the
selected pods, using live `imageID` values first and `image` only as a
fallback. For ordinary source-registry rendered refs, this digest match is the
live image check. When render/check accepts a rendered ref through digest
adoption, as with target-registry image-map refs, digest-pinned live refs for
that digest must be only the rendered refs; mixed source and target refs fail.

The generated `rollout-report.json` must keep `schema:
agentsmith.kubernetes-rollout-report/v1`, `scope:
kubernetes_rollout_imageid_only`, `readiness: false`, and `status: pass`. It
records the release contract digest, target axes, namespace, timeout, rollout
resource refs, selectors, expected image digests, selector-scoped
`observed_live_image_digest_summary` with source counts, and render/check
summary. It must not contain `verdict`, `release_verdict`, deploy readiness,
product-flow fields, kubeconfig content, raw kubectl stdout/stderr, or raw
secret payloads.

## Route/Service Smoke Focused Diagnostic

Run:

```bash
bash scripts/test-smoke.sh
```

This focused guard exercises `bash scripts/verify-release.sh --smoke`. It
checks only one route status after a successful focused rollout report. It
does not call Kubernetes, render templates, apply resources, roll out
workloads, run product flows, provision cloud resources, build packages, or
claim deploy or release readiness.

`--smoke` accepts only `existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`.
Required inputs are `--release-contract`, `--rollout-report`,
`--target-profile`, `--url`, and `--output-dir`. Optional inputs are
`--expected-status` (default `200`), `--timeout-ms` (default `5000`),
`--allow-http`, and `--allow-localhost`. Custom headers and tokens are not
supported.

Before any network request, the smoke diagnostic removes stale
`smoke-report.json`, validates the target profile, URL, status, timeout,
release contract, and rollout report. The rollout report must have `status:
pass`, `readiness: false`, `scope: kubernetes_rollout_imageid_only`, and
matching release id, git sha, release contract digest, and target profile.
The URL must be HTTPS by default, must not include userinfo, query, or hash,
and must not target localhost, 127.x, `::1`, or `host.docker.internal`.
Focused tests may explicitly pass `--allow-http --allow-localhost`.

The diagnostic performs one GET using built-in Node `fetch` with
`redirect: manual`. Success requires the response status to equal the expected
status. The generated `smoke-report.json` must keep `schema:
agentsmith.route-smoke-report/v1`, `scope: route_smoke_only`, `readiness:
false`, and `status: pass`. It records release identity, release contract
digest, target axes, normalized route summary (`scheme`, `origin`, `host`,
`path`), expected/observed status, duration, and rollout report digest/summary.
It must not contain response body, raw headers, custom token payloads,
kubeconfig content, product-flow fields, `verdict`, `release_verdict`, or
deploy readiness fields.

## Online Focused Chain Orchestration

Run:

```bash
bash scripts/test-online-deployment-gate.sh
```

This focused runner exercises `bash scripts/verify-release.sh
--online-deployment-gate`. It is a KISS sequence runner for the online focused
chain on
`existing_kubernetes/external_declared/online` and
`existing_kubernetes/kit_installed/online`. It does not implement a release
platform, cloud resource provisioning, substrate installation, image
mirroring, airgap bundle creation, kind image import, rollback, product-flow
checks, or full release readiness.

The runner requires both `--substrate-truth <json>` and
`--target-prerequisites <json>`. The external-declared online order is inputs,
target-preflight, template-package, optional image-map when
`--target-registry <registry-host[/namespace]>` is provided, target-registry
apply registry-presence through `--registry-probe <executable>`, render,
render-check, apply, and, for confirmed `--mode apply` only, rollout plus
optional route smoke. The kit-installed online order is inputs,
target-preflight, substrate-pack-check, template-package,
substrate-routability, render, render-check, apply, and, for confirmed
`--mode apply` only, rollout plus optional route smoke. Kit-installed online
requires `--substrate-pack-manifest <json>` and
`--routability-probe <executable>`, rejects `--target-registry`, and does not
expand registry-presence. External-declared online rejects the kit-only
substrate args. Target-preflight runs before render, kubectl, or route network
checks, and invalid prerequisites remove stale managed reports. Default
`server-dry-run` stops after apply dry-run and rejects `--smoke-url` and
`--registry-probe`; server dry-run external target-registry does not require a
probe. Apply mode requires exact `--confirm-apply <matching-target-profile>`
and `--operator-run-id <id>` before Kubernetes calls. In confirmed apply
rollout, strict live ref checks apply only to digest-adopted target refs;
ordinary source-registry rollout remains digest-only. It is not mirror
execution or registry login; registry presence and routability remain focused
read-only probe prerequisites and are not standalone release evidence.

Confirmed apply mode can optionally add `--evidence-root <dir>` and
`--evidence-provenance <json>` for external-declared online or kit-installed
online. The provenance input must be explicit remote release-kit provenance;
local/file URIs, source paths, and secret-looking fields fail before
Kubernetes calls. The gate computes the fixed `release-kit-evidence-subject`
metadata, writes `evidence.json`, `evidence-subject.json`, and
`online-deployment-gate-report.json` under the evidence root, and validates
that root with the existing `--evidence` diagnostic. `server-dry-run` and
unsupported profiles fail fast and remove stale managed evidence files. The
capability map marks external online and kit-installed online evidence
envelope support as `optional`.

The generated `online-deployment-gate-report.json` must keep `schema:
agentsmith.online-deployment-gate/v1`, `scope:
online_deployment_gate_only`, `readiness: false`, and `status: pass`. It
records release identity, release contract digest, target axes, mode, and
step names with relative report paths. Confirmed apply reports must include
top-level `operator_run_id`; server dry-run reports must not. It also contains
a small capability map keyed only by the selected online target profile with
declared/intake/preflight/render/apply/rollout/smoke capabilities plus the
profile-specific evidence envelope capability. It must not contain raw command args, response bodies,
kubeconfig content, secret payloads, product-flow fields, `verdict`,
`release_verdict`, or deploy readiness fields.

## Operator Signoff Intake Focused Diagnostic

Run:

```bash
bash scripts/test-operator-signoff-intake.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--operator-signoff-intake`. It validates only an operator signoff intake JSON
against an already generated online deployment gate apply report. It is not a
signature verifier, identity system, registry presence proof, full online
adoption check, deploy readiness check, package readiness check, or release
readiness check.

The CLI accepts only `existing_kubernetes/external_declared/online`:

```bash
bash scripts/verify-release.sh --operator-signoff-intake \
  --release-contract release-contract.json \
  --online-deployment-gate-report online-deployment-gate-report.json \
  --operator-signoff-intake operator-signoff-intake.json \
  --target-profile existing_kubernetes/external_declared/online \
  --output-dir out
```

The intake JSON schema is `agentsmith.operator-signoff-intake/v1`, with
`scope: operator_signoff_intake_only`. It uses an allowlist only:
`schema_version`, `scope`, `decision`, `operator_run_id`,
`operator_identity`, `signed_off_at`, `target_profile`, `release_id`,
`git_sha`, `release_contract_digest`, and `subject`. The subject allows only
`kind: online_deployment_gate_report` and a raw file `sha256` for the online
gate report. Local/source paths, secret-looking values, signature fields,
registry presence claims, image push/pull/mirror/load/import claims,
product-flow fields, full online adoption fields, and deploy/package/release
readiness or verdict fields fail fast.

The validator binds release id, git sha, release contract raw sha256, target
profile, subject sha256, and `operator_run_id` across the release contract,
the signoff intake, and the online gate report. The online gate report must be
`schema: agentsmith.online-deployment-gate/v1`, `scope:
online_deployment_gate_only`, `readiness: false`, `status: pass`, `mode:
apply`, with top-level `operator_run_id` and non-empty steps including apply
and rollout. Only canonical confirmed-apply producer order is accepted:
source-registry apply is
`inputs,target-preflight,template-package,render,render-check,apply,rollout`
with optional trailing `smoke`; target-registry apply is
`inputs,target-preflight,template-package,image-map,registry-presence,render,render-check,apply,rollout`
with optional trailing `smoke`.

The generated `operator-signoff-intake-report.json` keeps `schema:
agentsmith.operator-signoff-intake-report/v1`, `scope:
operator_signoff_intake_only`, `readiness: false`, and `status: pass`. It
contains only summary bindings and must not contain raw command args,
kubeconfig content, secret payloads, product-flow fields, signature fields,
registry presence claims, verdict fields, or deploy/package/release readiness
claims. It is not an accepted `release_kit_output` for the release-kit
evidence envelope.

## Evidence Envelope Focused Diagnostic

Run:

```bash
bash scripts/test-evidence.sh
```

This focused guard exercises `bash scripts/verify-release.sh --evidence`. It
checks only the release-kit evidence envelope shape for an evidence root that
already exists. The root must contain `evidence.json` and
`evidence-subject.json`.

The repo-local raw intake schema is
`agentsmith.release-kit-evidence-envelope/v1`. AgentSmith's
`agentsmith.release-kit-evidence/v1` name is reserved for its adapter/canonical
evidence shape and must not be used for this raw envelope.

The check verifies the release contract raw sha256, release identity, exact
target profile axes, `passed`/`failed` status and failure-class pairing,
the explicit `release_kit_output` mapping, `evidence.release_kit_version`
plain semver check against `release_contract.min_release_kit_version`,
release-kit provenance, subject file digests, subject path safety,
output-specific semantics, and redaction/source scans for the envelope and
subject files. It rejects non-canonical pre-GA target names, synonym axes,
AgentSmith product-flow fields, local provenance URIs, absolute paths, `..`
escapes, symlinks, hardlinks, and obvious secret payloads.
Accepted `release_kit_output` values are `image-map.json`,
`online-deployment-gate-report.json`, and
`airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json`;
`AgentSmith product flow aggregate` is rejected. `deploy-result.json#substrate`
is future reserved and is rejected during pre-GA until there is a current
producer and schema to revalidate. The image-map output is rechecked for
`agentsmith.image-map/v1`, `scope: image_map_only`, `readiness: false`,
`status: pass`, release/target binding, and digest-pinned mappings against
`release_contract.deploy_image_inventory`; it also follows the render
image-map adoption rule, so `use_source` cannot carry `target_registry` or drift
from the source image, and mirrored targets must match the deterministic target
registry ref. The standalone image-map output is accepted only for
`existing_kubernetes/external_declared/online` or
`existing_kubernetes/external_declared/airgap`. The online gate output is
accepted only for `existing_kubernetes/external_declared/online` or
`existing_kubernetes/kit_installed/online` confirmed apply output:
`mode` must be `apply`, top-level `operator_run_id` must be present, steps
must be non-empty, and apply plus rollout steps must be present. Only the same
canonical source-registry, target-registry, or kit-installed confirmed-apply
producer order is accepted; kit-installed evidence must include
substrate-pack-check before template-package and substrate-routability before
render. Reports such as `image-map,registry-presence,inputs,...` or
external/kit profile mixes are rejected even if all required steps are
present. The airgap
bundle output is accepted only for
`existing_kubernetes/external_declared/airgap` and must bind
`airgap-bundle-check-report.json` to a bundle-check-compatible
`airgap-bundle-manifest.json` and a re-read `image-map.json`: required four
components, image artifact declarations, mandatory payload/tool categories and
counts, report counts, image-map mappings, and artifact/binding digests must
agree. The old two-file airgap output value is rejected. The provenance
`subject_name` must be `release-kit-evidence-subject`. The subject file list
must contain only `evidence.json` plus the mapped output files:
`image-map.json`, `online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json` plus `airgap-bundle-manifest.json` plus
`image-map.json`.
Render, rollout, and smoke reports remain individual focused diagnostic
outputs, but render+rollout combinations are not accepted release-kit evidence
envelope outputs. `airgap-bundle-load-plan-report.json` is also intentionally
not accepted because it is plan-only and does not prove registry execution,
package readiness, or release readiness.
`airgap-bundle-render-check-report.json` is intentionally not accepted because
it proves only offline bundle render plus rendered image inventory, not
registry execution, package readiness, offline install readiness, deploy
readiness, or release readiness.
`airgap-image-archive-check-report.json` is intentionally not accepted because
it proves only local archive probe digest alignment, not image load/import,
offline install, package, deploy, registry, or release readiness.
`airgap-image-load-report.json` is intentionally not accepted because it proves
only this focused operator-loader execution, not offline install, package,
deploy, registry, or release readiness.
`airgap-deployment-gate-report.json` is intentionally not accepted because it
proves only the focused airgap chain, not offline install, package, deploy,
registry, operator signoff, or release readiness.
`registry-presence-report.json` is intentionally not accepted because it proves
only focused target digest-ref presence through an operator probe, not deploy,
package, or release readiness.
`substrate-pack-check-report.json` is intentionally not accepted because it
proves only kit-installed substrate pack manifest and substrate truth
materiality, not substrate installation, package readiness, deploy readiness,
or release readiness.
`substrate-routability-report.json` is intentionally not accepted because it
proves only focused existing Kubernetes Pod-network substrate endpoint
routability for `existing_kubernetes/kit_installed/online`, not substrate
installation, package readiness, deploy readiness, or release readiness.
`evidence.git_sha` is the AgentSmith product release commit and must match the
release contract; `artifact_provenance.commit_sha` is the release-kit producer
commit and is validated as its own 40-character git sha.
For `evidence-subject.json`, the listed sha256 for `evidence.json` is the
canonical evidence body without `artifact_provenance`; every other subject file
uses its raw file sha256. This prevents `artifact_provenance.subject_sha256`
from self-referencing the evidence file that carries it.

The generated `evidence-validation-report.json` must keep `readiness: false`,
`scope: release_kit_evidence_intake_only`, and `status: pass`. It must not
contain `verdict` or `release_verdict`. It is not release readiness, package
readiness, Kubernetes render evidence, apply evidence, rollout evidence, smoke
evidence, or operator signoff.

## Substrate Pack Focused Diagnostic

Run:

```bash
bash scripts/test-substrate-pack-check.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--substrate-pack-check`. It checks only a minimal kit-installed substrate pack
manifest plus matching substrate truth for existing Kubernetes online or
airgap targets. It does not install substrates, create databases, buckets, OIDC
realms, or secrets, log in to registries, call Kubernetes, render, apply, roll
out workloads, smoke product endpoints, build packages, or claim deploy,
package, or release readiness.

The only accepted target profiles are
`existing_kubernetes/kit_installed/online` and
`existing_kubernetes/kit_installed/airgap`. `external_declared`,
`kind_rehearsal`, non-canonical pre-GA names such as `local-kind`,
`existing-cluster`, `real-k8s`, and synonym axes such as `cluster` or
`offline` fail fast.

The substrate pack manifest schema is
`agentsmith.substrate-pack-manifest/v1`. It must declare
`installed_by: agentsmith-release-kit`, a plain semver `release_kit_version`,
and a `target_profile` string that exactly matches the CLI target profile.
`images` must include `postgresql`, `mongodb`, `redis`, `object_storage`, and
`oidc`. Every image must be digest-pinned as `...@sha256:<64>` and must not use
`latest`, URI syntax, localhost, loopback, local/source paths, or empty/relative
repository path segments. `payload`, `templates`, `tools`, and `checksums`
must contain only sha256 digests or safe relative pack paths. Public-download
wording, `file://`, `local://`, `source://`, absolute paths, workspace source
paths, kubeconfig text, and credential/secret-looking values fail fast.

The substrate truth input is then validated through the shared
`validateSubstrateConnectionTruth` path with required substrate source
`kit_installed`; `assertNoUnsafeSubstratePayload` is applied before validation.
That keeps service presence, endpoint fields, secret refs, TLS or sslmode,
pgvector, reachability, target profile binding, `installed_by:
agentsmith-release-kit`, and plain release-kit semver consistent with target
preflight.

The generated `substrate-pack-check-report.json` must keep `schema:
agentsmith.substrate-pack-check-report/v1`, `scope:
substrate_pack_check_only`, `readiness: false`, and `status: pass`. It may
contain only target profile, input sha256 digests, and non-sensitive summary
counts/service names. It must not contain raw secrets, kubeconfig content,
release verdicts, deploy readiness, package readiness, product-flow fields, or
operator signoff fields. It is not an accepted release-kit evidence envelope
output.

## Substrate Routability Focused Diagnostic

Run:

```bash
bash scripts/test-substrate-routability.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--substrate-routability`. It accepts only
`existing_kubernetes/kit_installed/online` and checks a previously passing
`substrate-pack-check-report.json`, matching substrate truth, matching target
prerequisites, namespace, explicit kubectl input, and an operator-provided
Pod-network routability probe. It does not install substrates, create
databases, buckets, OIDC realms, or secrets, render, apply, roll out workloads,
smoke product endpoints, build packages, or claim deploy, package, or release
readiness.

The producer revalidates substrate truth through the shared
`validateSubstrateConnectionTruth` path with required substrate source
`kit_installed`, revalidates target prerequisites with the expected namespace,
and binds the substrate truth sha256 to the upstream substrate pack check
report. `external_declared`, `kind_rehearsal`, `airgap`, missing pack reports,
profile mismatches, and digest mismatches fail fast.

The probe interface is explicit and narrow: the release kit runs `kubectl
version --output=json`, then calls `--routability-probe` once per required
substrate service with kubectl, namespace, optional context/kubeconfig path,
service id, endpoint kind, raw endpoint value, optional port, expected endpoint
fingerprint, and timeout. The probe must verify routability from the target
Kubernetes Pod network and print exactly the expected sha256 fingerprint. The
report stores only kubectl version summary, input digests, service ids,
endpoint fingerprints, and probe fingerprints; it omits raw endpoints, raw
probe stdout/stderr, probe path, kubectl path, kubeconfig content, and
credentials.

The generated `substrate-routability-report.json` must keep `schema:
agentsmith.substrate-routability-report/v1`, `scope:
substrate_routability_probe_only`, `readiness: false`, and `status: pass`.
It must not contain raw secrets, kubeconfig content, release verdicts, deploy
readiness, package readiness, product-flow fields, or operator signoff fields.
It is not an accepted release-kit evidence envelope output.

## Target Preflight Focused Diagnostic

Run:

```bash
bash scripts/test-target-preflight.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--target-preflight`. It checks only repo-local intake of a neutral substrate
connection truth document and a separate target prerequisites truth document.
It does not open a Kubernetes client, render manifests, run checks, apply
resources, roll out workloads, smoke product endpoints, create cloud resources,
or build an airgap bundle.

The accepted truth schemas are
`agentsmith.substrate-connection.truth/v1` and
`agentsmith.target-prerequisites.truth/v1`. Docker substrate truth,
non-canonical pre-GA target names such as `local-kind`, `existing-cluster`,
`real-k8s`, and synonym axes such as `kind` or `cluster` are rejected. The
supported focused profiles for this diagnostic are the canonical
target-preflight intake profiles:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`,
`existing_kubernetes/kit_installed/airgap`, and
`kind_rehearsal/kit_installed/online`.

For `external_declared`, the operator provides the connection truth and target
prerequisites; the release kit only validates the documents. Raw evidence
envelopes for `external_declared` must include inline neutral connection truth
under `substrate_connection_truth`. For `kit_installed`, the same neutral truth
schema is used and the document must declare `installed_by` and
`release_kit_version` as plain `x.y.z` semver. Both paths must include the
required substrate services, canonical endpoint declarations (`host` for
PostgreSQL/MongoDB/Redis, `url` or `endpoint` plus `region` and `bucket` for
object storage, and `issuer_url` for OIDC), secret references, TLS or sslmode
declarations, `extensions.pgvector.status: installed`, and reachability status
`declared_reachable` or `verified_by_operator` with proof. Target prerequisites
must include target profile, namespace, RBAC policy or proof, ingress host plus
TLS secret ref, registry pull secret ref, storage class plus PV policy, and the
substrate secret refs declared in substrate truth. The prerequisites `registry`
object accepts only `pull_secret_ref`; pseudo-evidence or secret payload fields
such as `preloaded`, `mirror_done`, `verdict`, or `token` are rejected. Plaintext credentials,
connection strings, kubeconfig payloads, file or source URIs, localhost,
`host.docker.internal`, and hosts or URLs with userinfo are rejected.

The generated `target-preflight-report.json` must keep `readiness: false`,
`scope: target_preflight_prerequisite_only`, and `status: pass`. It must not contain
`verdict` or `release_verdict`. It is not release readiness, package readiness,
Kubernetes connectivity evidence, render/check evidence, apply evidence,
rollout evidence, smoke evidence, or operator signoff.

## Full Release Gate

The full release gate is the future repo-local authority for online deploy,
airgap package/deploy, operator runbooks, and deployment/package evidence.

It is not implemented during bootstrap. Running `bash scripts/verify-release.sh`
without `--quick` must fail fast until the full gate is designed and
implemented in this repository.

The future full release gate must not delegate release readiness to AgentSmith
product gates, AFSCP gates, ASBCP gates, or kind rehearsal alone. AgentSmith
product flows remain AgentSmith evidence; this repository owns only
deployment, distribution, package, and operator evidence.

Airgap release-kit work must use tools, templates, artifacts, and images already
available inside the target network. Operator-declared substrate endpoints may
be prerequisites in that network, but this repository must not create clusters,
databases, buckets, IAM, networks, OIDC realms, or other cloud resources.
