# AgentSmith Release Kit

Status: bootstrap-only, focused deploy/package diagnostics.

This repository is the future deploy and package execution home for
AgentSmith releases. It is intentionally small at bootstrap time: repo
identity, boundary documents, handoff guidance, and focused diagnostics. It
contains image-map, airgap bundle create, airgap bundle manifest/digest,
airgap image archive materiality, airgap image load, registry presence,
airgap bundle load-plan, airgap bundle render-check, airgap deployment focused
chain orchestration, airgap consume rehearsal, substrate pack check, apply-only,
rollout/live digest, route smoke, and online focused chain orchestration
diagnostics, plus operator signoff intake binding, but does not contain full
deploy tooling yet.

## Canonical Identity

| Field | Value |
| --- | --- |
| Repository | `github.com/agentsmith-project/agentsmith-release-kit` |
| Remote URL | `https://github.com/agentsmith-project/agentsmith-release-kit.git` |
| Default branch | `main` |
| Local bootstrap path | `/home/percy/works/mbos-v1/agentsmith-release-kit` |

The local bootstrap path is a workspace convention only. CI and future release
evidence must use the normalized GitHub repository identity.

## Scope

AgentSmith Release Kit consumes:

- AgentSmith release contract.
- AgentSmith deploy template package.
- Operator inputs, including target cluster, registry, neutral substrate
  connection truth, target prerequisites truth, namespace, ingress, TLS, and
  secret references.

AgentSmith Release Kit owns:

- Online deploy execution.
- Airgap package verification and deployment flow.
- Image bundle, mirror map, and digest adoption checks.
- Kubernetes render, apply, rollout, and smoke evidence.
- Operator runbooks for deployment, package handling, troubleshooting, and
  evidence collection.
- Deployment, distribution, and package evidence produced by this repository.

AgentSmith Release Kit does not own:

- AgentSmith product readiness.
- Visual, backend-real, story, e2e, or product flow validation.
- Product database schema, product bootstrap semantics, product authorization,
  or product UI truth.
- Cloud resource provisioning for clusters, databases, buckets, IAM, networks,
  or OIDC realms.
- A release management UI, dashboard, or DevOps product surface.
- AgentSmith product source, product contracts, product gates, or runner
  runtime implementation.

## Deployment Model

The intended future deployment model has three independent choices:

- `target_cluster`: `existing_kubernetes` or `kind_rehearsal`.
- `substrate_source`: `external_declared` or `kit_installed`.
- `distribution`: `online` or `airgap`.

The canonical declarable target profiles are
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`,
`existing_kubernetes/kit_installed/airgap`, and
`kind_rehearsal/kit_installed/online`. Removed old input names and synonym
axes such as `local-kind`, `existing-cluster`, `real-k8s`, `kind`, or
`cluster` fail fast.

`kind_rehearsal` is only a local or CI rehearsal target. It is not a user deployment prerequisite.
It does not replace real Kubernetes evidence when a real Kubernetes target is in scope.

For `airgap`, operators must provide all required tools, templates, artifacts,
and images from inside the target network. Airgap flow must not download from
the public internet. An operator-declared substrate endpoint can be a target
network prerequisite, but this repository does not create cloud resources.

## Current Verification

Operator release surface v0:

```bash
bash scripts/operator-release.sh online use_existing ...
bash scripts/operator-release.sh online install_substrates ...
bash scripts/operator-release.sh airgap-bundle use_existing ...
bash scripts/operator-release.sh airgap-bundle install_substrates ...
```

The first three commands map operator choices to the existing producer
diagnostics and write `operator-release-surface-report.json` with
`readiness: false`. `airgap-bundle/install_substrates` fails fast in v0.
`verify-release.sh` remains the producer catalog and maintainer/focused
diagnostic entry.

Bootstrap quick gate:

```bash
bash scripts/verify-release.sh --quick
```

The quick gate checks only repo identity and boundary guardrails. It is not
release readiness and must not be used as a deploy, package, or release
verdict.

Contract intake focused diagnostic:

```bash
bash scripts/test-inputs.sh
```

`--inputs` validates only the release contract, deploy template package, target
profile, provenance, release-kit version policy, and digest-bound image
inventory. During release contract intake, `release_contract.required_image_ids`,
`deploy_template_package.required_image_ids`, and the
`deploy_image_inventory` id set must be non-empty exact-set matches. The
release kit consumes the dynamic image closure from the AgentSmith release
contract instead of a hardcoded six-image list. Current fixtures/examples
include `managed_runner`, a digest-bound inventory image supplied by the
release contract. Every declared `target_profiles` entry
must carry `required: boolean`; `support_level` is rejected, duplicate
three-axis tuples are rejected, and every entry must use a canonical declarable
profile. Existing Kubernetes profiles can be declared for both
`external_declared` and `kit_installed` substrate choices across online and
airgap distributions.
During pre-GA every target profile must use `required: false`; `required:
true` fails fast because full deploy/package evidence is not implemented for
every path. `intake-report.json`, `image-digest-plan.json`, and
`target-profile-coverage-report.json` are written with `readiness: false`;
they prove only contract/input digest readiness, not deploy, package, or
release readiness. In that coverage report, `executable_profiles` means the
currently executable focused deployment profiles:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`; it does not include
`existing_kubernetes/kit_installed/airgap`, kind rehearsal, or aliases.
Evidence-supported profiles remain narrower and do not expand kit-installed
evidence.

Deploy template package archive focused diagnostic:

```bash
bash scripts/test-template-package.sh
```

`--template-package` validates only the materialized archive declared by the
release contract and deploy template package descriptor. It checks descriptor
equality, archive and manifest digests, unsafe archive paths, and obvious local
source or plaintext credential payloads. `template-package-report.json` is
written with `readiness: false`; it is not render, deploy, package, or release
readiness.

Materialized template render focused diagnostic:

```bash
bash scripts/test-render.sh
```

`--render` renders only Kubernetes template files declared in the materialized
archive `manifest.json`. It consumes the AgentSmith release contract, the
deploy template package descriptor, the matching `.tgz` archive, an explicit
target profile, explicit render values, and
`agentsmith.substrate-connection.truth/v1` substrate truth. Output goes to
`<output-dir>/rendered-manifests`, and `manifest-render-report.json` is written
with `readiness: false`, `scope: manifest_render_only`, and `status: pass`.
Direct render enforces the dynamic `required_image_ids` exact-set closure
across the release contract, deploy template package, and inventory ids.
When `--image-map <json>` is supplied, render first validates that it is a
passing `agentsmith.image-map/v1` report bound to the same release contract
digest and target profile, then uses `mapping.target_image` for
`${{ images.<id>.image }}` while keeping `${{ images.<id>.digest }}` digest
bound to the release inventory digest.

The template language is intentionally tiny: scalar placeholders only, no
conditionals and no loops. Supported placeholder roots are `values`, `images`,
`target`, `substrate`, and `release`, for example
`${{ values.namespace }}`, `${{ images.agentsmith_app.image }}`,
`${{ target.distribution }}`, `${{ substrate.services.postgresql.host }}`, and
`${{ release.release_id }}`. Unknown or non-scalar placeholders fail fast.
Rendered workload images must be digest-pinned and must come from
`release_contract.deploy_image_inventory`. Archive path escapes, symlinks,
hardlinks, local/source payloads, secret-looking rendered content, and
non-canonical pre-GA target profile names are rejected. This diagnostic does
not call `kubectl`, apply or dry-run manifests, roll out workloads, smoke
endpoints, mirror images, read a sibling AgentSmith checkout, or claim
render/deploy/release readiness.
If a sibling `../agentsmith` checkout exists next to release-kit, `--render`
rejects it as a default forbidden source root.

Render/check image inventory focused diagnostic:

```bash
bash scripts/test-render-check.sh
```

`--render-check` validates only rendered Kubernetes manifest files already
provided by an operator or earlier render step. It scans yaml, yml, and json
workload resources for Deployment, StatefulSet, DaemonSet, ReplicaSet, Job,
CronJob, and Pod `containers` and `initContainers` images. Every workload image
must be digest-pinned and must match the release contract
`deploy_image_inventory` by exact image ref or digest. It rejects
non-canonical pre-GA target profile names, unknown images, tag-only image refs,
digest drift, manifest path escapes, external symlinks, and obvious plaintext
credential or kubeconfig payloads. `render-report.json` is written with `readiness: false`,
`scope: render_check_image_inventory_only`, and `status: pass`; it is not
render readiness, deploy readiness, release readiness, apply evidence, rollout
evidence, smoke evidence, or operator signoff.

Image-map / mirror-plan focused diagnostic:

```bash
bash scripts/test-image-map.sh
```

`--image-map` validates only the release contract
`deploy_image_inventory` and writes a digest-pinned source-to-target image
reference plan. It accepts existing Kubernetes canonical profiles as CLI
targets:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`.
`kind_rehearsal/kit_installed/online` is a canonical profile tuple but out of
scope for image-map CLI. Only canonical profile tuples are accepted in
`release_contract.target_profiles`; non-canonical pre-GA names and synonym
axes fail fast. For online targets without
`--target-registry`, target refs equal source refs and the action is
`use_source`. When `--target-registry <registry-host[/namespace]>` is
provided, or for every airgap run where it is required, target refs are
derived by stripping the source registry and tag, keeping the repository path,
and appending the original sha256 digest under the target registry. Registry
namespace components must be lowercase and must start and end with
alphanumeric characters.
Standalone image-map enforces the release contract's dynamic
`required_image_ids` exact-set closure against `deploy_image_inventory` ids.
When the closure includes `managed_runner`, image-map treats it like any other
digest-bound inventory image. Render then adopts it through normal
`${{ images.<id>.image }}` and `${{ images.<id>.digest }}` placeholders when
templates reference it, and airgap archive flows carry it through the existing
image-map and image-artifact declaration mechanisms. This is not a dedicated
runner runtime, backend-real, or release readiness gate.

Pre-GA stale six-image required-id inputs, obsolete
`${{ values.MANAGED_RUNNER_IMAGE }}` template placeholders, and stale
runner-name aliases such as `agent-task-runner` or `agentsmith-codex-runner`
are not success or compatibility paths. Keep them only as fail-fast/negative
diagnostic evidence, and remove those cases once the formal fixtures and
runbooks stabilize.

This diagnostic does not log in to a registry, pull, push, mirror, build an
airgap bundle, import images into kind, call Kubernetes, or claim deploy,
package, or release readiness. `image-map.json` keeps `schema:
agentsmith.image-map/v1`, `scope: image_map_only`, `readiness: false`, and
`status: pass`; it contains only release identity, release contract digest,
target axes, optional target registry, image count, and mappings.

Registry presence focused diagnostic:

```bash
bash scripts/test-registry-presence.sh
```

`--registry-presence` validates only a mirror-required online image-map against
an operator-provided read-only probe. It accepts only
`existing_kubernetes/external_declared/online`; the image-map must be passing
`agentsmith.image-map/v1` with `scope: image_map_only`, `readiness: false`,
`mirror_required: true`, and `target_registry`. The probe interface is:
`<executable> <target_image> <expected_digest>`, and stdout must be exactly one
`sha256:<64>` digest matching the mapping target digest. It writes
`registry-presence-report.json` with `schema:
agentsmith.registry-presence/v1`, `scope: registry_presence_only`,
`readiness: false`, and non-sensitive digest summaries only. It does not log
in, pull, push, mirror, call Docker/skopeo/oras/kubectl/curl/wget/cloud APIs,
or claim deploy/package/release readiness; the report is not accepted by the
evidence envelope validator.

Airgap bundle create focused diagnostic:

```bash
bash scripts/test-bundle-create.sh
```

`--bundle-create` is a local airgap bundle assembler plus immediate
self-check. It accepts only `existing_kubernetes/external_declared/airgap`.
Inputs are the release contract, deploy template package descriptor, matching
`.tgz` archive, target registry, one local `--image-archive
<image_id=file>` per generated image-map mapping, runbook, install script,
profile-values schema, optional profile-values example, operator
prerequisites JSON, empty-or-absent bundle root, and output directory.

The assembler first reuses `--inputs`, `--template-package`, and `--image-map
--target-registry`; then it copies only local files into a fixed bundle shape:
`components/`, `images/`, `payload/`, optional `tools/`, and root
`airgap-bundle-manifest.json`. Image archive ids must match the generated
image-map one-to-one. Input image archives and bundled tools must be local
regular files, not URIs, directories, or symlinks. Payload files are lightly
scanned for obvious secret-looking content. Bundled tool inputs are copied
under `tools/<name>` and the manifest records the copied file sha.

After assembly, `--bundle-create` immediately runs `--airgap-bundle-check`
against the generated bundle. Only after that passes it writes
`bundle-create-report.json` with `schema:
agentsmith.airgap-bundle-create-report/v1`, `scope:
airgap_bundle_create_only`, `readiness: false`, and non-sensitive
count/digest summaries. It does not log in to a registry, pull, push, mirror,
save, load, parse OCI tar contents, prove registry presence, install offline,
deploy, package, or claim release readiness. `bundle-create-report.json` is
not an accepted release-kit evidence envelope output; evidence remains limited
to the existing airgap bundle check report plus manifest plus image-map set.

Airgap bundle manifest/digest focused diagnostic:

```bash
bash scripts/test-airgap-bundle-check.sh
```

`--airgap-bundle-check` validates only a local bundle manifest with
`schema_version: agentsmith.airgap-bundle-manifest/v1` against an explicit
bundle root, release contract, deploy template package descriptor, deploy
template archive `.tgz`, and airgap `image-map`. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind, and
non-canonical pre-GA target names fail fast. `kit_installed` airgap profiles
may be declared in the release contract but are not airgap bundle-check CLI
targets in this slice. The release contract
`target_profiles` value must be an array, must include
`existing_kubernetes/external_declared/airgap`, and every entry must use a
canonical profile tuple with `required: boolean`; `support_level` is rejected.
The airgap profile may remain `required: false`. The image-map must be a
passing `agentsmith.image-map/v1` report with `scope: image_map_only`,
`readiness: false`, `mirror_required: true`, a target registry, the exact
airgap target profile, and `action: mirror_required` for every mapping. Each
mapping id must exist in `release_contract.deploy_image_inventory`;
`source_image` and `source_digest` must match the inventory, `target_digest`
must equal `source_digest`, and `target_image` must sit under
`image_map.target_registry` with `@<target_digest>`.

This diagnostic checks only safe relative bundle paths and sha256 bindings for
the release contract, deploy template package descriptor, deploy template
archive, image-map, declared `oci_layout_tar` image artifact files, bundled
payload files, and bundled tool files. The deploy template archive sha256 must match
`deploy_template_package.package_sha256`,
`deploy_template_package.artifact_provenance.artifact_sha256`, and
`bundle_manifest.bindings.deploy_template_archive_sha256`. The bundle manifest
accepts only the documented top-level, `bindings`, `components`,
`image_artifact_declarations`, `payload_artifacts`,
`operator_prerequisites`, and `substrate` fields. `components` must contain
exactly one component of each `kind`:
`release_contract`, `deploy_template_package`, `deploy_template_archive`, and
`image_map`. `payload_artifacts[]` allows only `id`, `kind`, `path`, and
`sha256`; allowed kinds are `runbook`, `script`, `profile_values_schema`,
`profile_values_example`, and `checksums`, with `runbook`, `script`,
`profile_values_schema`, and `checksums` required. Duplicate payload ids,
unknown fields or kinds, unsafe paths, missing files, and sha mismatches fail
fast. `operator_prerequisites` allows only
`substrate_connection_truth_ref`, `target_registry_proof_ref`, and `tools`.
The two refs and `operator_prerequisite` tool `location`/`proof` values are
operator-held strings, not bundle files; URI schemes, public-download
semantics, and secret-looking content fail fast. Bundled tools use only
`name`, `version`, `source`, `path`, and `sha256`, with path/sha checked under
the bundle root. Operator prerequisite tools use only `name`, `version`,
`source`, `location`, and `proof`. It does not create an airgap package, parse the `.tgz`, inspect
tar or OCI contents, verify registry presence, load images, deploy to
Kubernetes, run kind, support online targets, or claim offline install,
deploy, package, or release readiness.
`airgap-bundle-check-report.json` keeps `schema:
agentsmith.airgap-bundle-check-report/v1`, `scope:
airgap_bundle_manifest_check_only`, `readiness: false`, and `status: pass`.
It may include only non-sensitive counts for payload artifacts and tools, not
raw paths, proof strings, locations, or refs.

Airgap image archive materiality focused diagnostic:

```bash
bash scripts/test-airgap-image-archive-check.sh
```

`--airgap-image-archive-check` consumes only an already assembled bundle plus
the same release contract, deploy template package descriptor, archive,
image-map, bundle root, and bundle manifest inputs as `--airgap-bundle-check`,
and an explicit `--archive-probe <executable>`. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind, `kit_installed`,
non-canonical pre-GA names, and synonym axes fail fast. It first reuses
`--airgap-bundle-check`; only after that passes it invokes the local read-only
probe once for each declared image archive file under the bundle root. The
probe receives the archive path as argv and env, and stdout must be exactly
one `sha256:<64>` digest. That probe digest must match the image-map
`target_digest`, which is already bound by bundle-check back to the release
contract inventory. `--archive-probe` is an operator-owned trusted local
executable; release-kit does not sandbox it or prove the probe itself
trustworthy, and only validates stdout digest alignment with the release
contract, image-map, and bundle manifest.

`airgap-image-archive-check-report.json` keeps `schema:
agentsmith.airgap-image-archive-check-report/v1`, `scope:
airgap_image_archive_content_check_only`, `readiness: false`, and `status:
pass`. It contains only release identity, target profile, input/report digest
summary, archive counts, image ids, and digest summaries. It omits absolute
paths, probe path, raw probe output, target registry topology, operator refs,
locations, proofs, and secrets. This is not package/deploy/offline install or
release readiness: it does not call Docker, skopeo, oras, kubectl, curl, or
wget, does not log in to a registry, does not pull, push, mirror, load, import,
or install images, does not apply manifests or smoke routes, and is not an
accepted evidence envelope output.

Airgap image load focused diagnostic:

```bash
bash scripts/test-airgap-image-load.sh
```

`--airgap-image-load` consumes the same already assembled bundle inputs as
`--airgap-image-archive-check`, plus `--archive-probe <executable>` and
`--image-loader <executable>`. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind, `kit_installed`,
non-canonical pre-GA names, and synonym axes fail fast. It first reuses
`--airgap-image-archive-check`, then invokes the operator-provided loader once
per image as `<executable> <archive_path> <target_image> <target_digest>`.
Loader stdout must be exactly one matching `sha256:<64>` digest. The report
omits loader path, archive paths, raw stdout/stderr, operator refs, proofs,
and secrets.

`airgap-image-load-report.json` keeps `schema:
agentsmith.airgap-image-load-report/v1`, `scope: airgap_image_load_only`,
`readiness: false`, and `status: pass`. It records only release identity,
target profile, image ids, counts, and digest summaries. The loader is
operator-owned; release-kit does not choose Docker, skopeo, oras, kubectl, or
registry credentials. This is not offline install, deploy, package, registry,
or release readiness, and it is not an accepted evidence envelope output.

Airgap bundle load-plan focused diagnostic:

```bash
bash scripts/test-bundle-load-plan.sh
```

`--bundle-load-plan` consumes only an already assembled bundle plus the same
release contract, deploy template package descriptor, archive, image-map,
bundle root, and bundle manifest inputs as `--airgap-bundle-check`. It accepts
only `existing_kubernetes/external_declared/airgap`; online, kind,
`kit_installed`, non-canonical pre-GA names, and synonym axes fail fast before
self-check. It first reuses `--airgap-bundle-check`; only after that passes it
writes `airgap-bundle-load-plan-report.json` with `schema:
agentsmith.airgap-bundle-load-plan-report/v1`, `scope:
airgap_bundle_load_plan_only`, `readiness: false`, and a digest/count/target
registry summary. It is a read-only plan: it does not call Docker, skopeo,
oras, kubectl, curl, or wget, does not log in to a registry, does not push,
import, load, or verify registry presence, and is not an accepted evidence
envelope output.

Airgap bundle render-check focused diagnostic:

```bash
bash scripts/test-airgap-bundle-render-check.sh
```

`--airgap-bundle-render-check` consumes only an already assembled bundle. All
release contract, deploy template package descriptor, archive, image-map,
bundle manifest, render-values, and substrate-truth inputs must be local files
inside the bundle root. It accepts only
`existing_kubernetes/external_declared/airgap`; online, kind, and
`kit_installed` airgap targets fail fast. It first reuses
`--airgap-bundle-check`, then renders the bundle-local deploy template package
with the bundle-local airgap image-map, and finally reuses `--render-check` on
the rendered manifests. The final report also verifies that every rendered
workload image is one of the image-map `target_image` refs, not a source ref.

`airgap-bundle-render-check-report.json` keeps `schema:
agentsmith.airgap-bundle-render-check-report/v1`, `scope:
airgap_bundle_render_check_only`, `readiness: false`, and `status: pass`. It
contains only digest/count/relative-path summaries and omits
`target_registry`. It does not call Docker, skopeo, oras, kubectl, curl, or
wget, does not log in to a registry, does not load/import images, apply
manifests, smoke routes, prove registry presence, or claim package, offline
install, deploy, registry, or release readiness. It is not an accepted evidence
envelope output.

Airgap deployment focused chain orchestration:

```bash
bash scripts/test-airgap-deployment-gate.sh
```

`--airgap-deployment-gate` is a small runner for
`existing_kubernetes/external_declared/airgap` only. Default
`server-dry-run` runs target-preflight, airgap bundle render-check, and
Kubernetes apply server dry-run; it does not run archive probing, image
loading, rollout, or smoke. `--mode apply` requires
`--archive-probe <executable>`, `--image-loader <executable>`,
`--confirm-apply existing_kubernetes/external_declared/airgap`, and
`--operator-run-id <id>`; it runs image-load, bundle render-check, apply, and
rollout, with route smoke only when `--smoke-url` is supplied.
`airgap-deployment-gate-report.json` keeps `schema:
agentsmith.airgap-deployment-gate/v1`, `scope:
airgap_deployment_gate_only`, `readiness: false`, and `status: pass`. It is
not accepted by evidence intake and does not perform registry mirror/login,
push/pull, substrate installation, operator signature/identity checks,
product-flow checks, package readiness, deploy readiness, or release
readiness.

Airgap consume rehearsal:

```bash
bash scripts/test-airgap-consume-rehearsal.sh
```

`--airgap-consume-rehearsal` is a thin offline consumption entry for an
already assembled `existing_kubernetes/external_declared/airgap` bundle. It
requires an explicit bundle root, bundle-local render values and substrate
truth, target prerequisites, namespace, output directory, and Kubernetes
client options. It discovers the release contract, deploy template package,
deploy template archive, and image-map component paths from
`airgap-bundle-manifest.json`, then reuses `--airgap-bundle-check` and the
existing `--airgap-deployment-gate` chain. Default `server-dry-run` runs
bundle check plus preflight/render-check/apply dry-run. `--mode apply`
requires archive probe, image loader, matching confirm text, and operator run
id, then reuses the existing image-load/apply/rollout path with optional
smoke through the deployment gate.

The optional `--rehearsal-label existing_kubernetes|kind_rehearsal` value is
operator-provided label-only metadata for the Kubernetes endpoint used by
`kubectl` settings. It does not change the
`existing_kubernetes/external_declared/airgap` target profile, create or
manage kind, or prove the endpoint is kind. Kind output remains optional
rehearsal evidence only and does not replace real Kubernetes evidence.
`airgap-consume-rehearsal-report.json`
keeps `schema: agentsmith.airgap-consume-rehearsal/v1`, `scope:
airgap_consume_rehearsal_only`, `readiness: false`, and `status: pass`. It
lists only `rehearsal_label`, digest summaries, producer report digests, and
the two main output-relative producer report paths. It is
not accepted by evidence intake and does not prove registry mirror/login,
offline install, package, deploy, operator signoff, or release readiness.

Substrate pack focused diagnostic:

```bash
bash scripts/test-substrate-pack-check.sh
```

`--substrate-pack-check` validates only a minimal kit-installed substrate pack
manifest plus matching `agentsmith.substrate-connection.truth/v1` substrate
truth. It accepts only `existing_kubernetes/kit_installed/online` and
`existing_kubernetes/kit_installed/airgap`; `external_declared`,
`kind_rehearsal`, old names such as `local-kind`, `existing-cluster`,
`real-k8s`, and synonym axes such as `cluster` or `offline` fail fast. The
manifest schema is `agentsmith.substrate-pack-manifest/v1`, `installed_by`
must be `agentsmith-release-kit`, `release_kit_version` must be plain semver,
and `target_profile` must match the CLI exactly. Required images are
`postgresql`, `mongodb`, `redis`, `object_storage`, and `oidc`; each image must
be digest-pinned with `@sha256:<64>` and must not use `latest`, localhost,
local/source paths, or URI syntax. Pack `payload`, `templates`, `tools`, and
`checksums` entries may contain only sha256 digests or safe relative pack
paths; public-download wording, file/local/source URIs, workspace source paths,
absolute paths, kubeconfig text, and secret-looking values fail fast.

The substrate truth is then checked by the shared substrate truth validator
with `requiredSubstrateSource: kit_installed`, so service presence, endpoint
shape, secret refs, TLS or sslmode, pgvector, reachability, target-profile
binding, `installed_by`, and release-kit version semantics stay consistent
with target preflight. `substrate-pack-check-report.json` keeps `schema:
agentsmith.substrate-pack-check-report/v1`, `scope:
substrate_pack_check_only`, `readiness: false`, and `status: pass`. It records
only input digests and non-sensitive counts/summaries. It does not install
substrates, create databases/buckets/realms, log in to registries, call
Kubernetes, roll out workloads, smoke routes, build packages, or claim
deploy/package/release readiness. It is not an accepted evidence envelope
output.

Kubernetes apply-only focused diagnostic:

```bash
bash scripts/test-apply.sh
```

`--apply` validates already-rendered manifests against a real Kubernetes API.
It accepts only `existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`; `kind_rehearsal`,
`kit_installed/airgap`, aliases such as `offline`, non-canonical pre-GA names,
and synonym axes fail fast. Required inputs are
`--release-contract`, `--rendered-manifests`, `--target-profile`,
`--namespace`, and `--output-dir`; optional inputs are `--kubeconfig`,
`--context`, `--kubectl`, and `--forbidden-source-root`. If a sibling
`../agentsmith` checkout exists next to release-kit, `--apply` treats it as a
default forbidden source root before running render/check.

Before any `kubectl` call, `--apply` runs the render/check image inventory
guard. The default `--mode server-dry-run` runs `kubectl apply --server-side
--dry-run=server` and writes `apply-report.json` only after success. Real
apply requires `--mode apply --confirm-apply <matching-target-profile>
--operator-run-id <id>`.
`apply-report.json` keeps `readiness: false`, `scope:
kubernetes_apply_only`, and `status: pass`; it is not deploy readiness,
release readiness, rollout evidence, route smoke evidence, product-flow
evidence, or operator signoff.

Kubernetes rollout/live digest focused diagnostic:

```bash
bash scripts/test-rollout.sh
```

`--rollout` validates only Kubernetes rollout status for already-rendered
rollout-capable workloads and checks that live pod image digests match the
render/check image inventory. It accepts only
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`; `kind_rehearsal`,
`kit_installed/airgap`, aliases such as `offline`, non-canonical pre-GA names,
and synonym axes fail fast. Required inputs are
`--release-contract`, `--rendered-manifests`, `--target-profile`,
`--namespace`, and `--output-dir`; optional inputs are `--timeout` (default
`120s`), `--kubeconfig`, `--context`, `--kubectl`, and
`--forbidden-source-root`. If a sibling `../agentsmith` checkout exists next to
release-kit, `--rollout` treats it as a default forbidden source root before
running render/check.

Before any `kubectl` call, `--rollout` runs the render/check image inventory
guard. It supports only Deployment, StatefulSet, and DaemonSet resources. List
wrappers are flattened by render/check and judged by their inner workloads;
Job, CronJob, Pod, ReplicaSet, and non-workload resources are not rollout
evidence in this diagnostic. It runs `kubectl rollout status` for each
rollout-capable resource, reads that workload's
`spec.selector.matchLabels`, then reads only matching pods with
`kubectl get pods --selector <selector> -o json`. Expected sha256 digests for
that workload must appear in those selected pods, using live `imageID` first
and falling back to `image` when needed. For ordinary source-registry rendered
refs, this digest match is the live image check. When render/check accepts a
rendered ref through digest adoption, as with target-registry image-map refs,
digest-pinned live refs for that digest must be only the rendered refs; mixed
source and target refs fail. `rollout-report.json` keeps
`readiness: false`, `scope: kubernetes_rollout_imageid_only`, and `status:
pass`; it is not deploy readiness, release readiness, route smoke evidence,
product-flow evidence, or operator signoff. The report stores
`observed_live_image_digest_summary` with source counts, and must not contain
raw kubectl stdout/stderr, kubeconfig content, verdict fields, deploy
readiness fields, or AgentSmith product-flow fields.

Route/service smoke focused diagnostic:

```bash
bash scripts/test-smoke.sh
```

`--smoke` validates only one already-deployed route status after a bound
rollout report. It accepts only
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`, and
`existing_kubernetes/kit_installed/online`. Required inputs are
`--release-contract`, `--rollout-report`, `--target-profile`, `--url`, and
`--output-dir`; optional inputs are `--expected-status` (default `200`),
`--timeout-ms` (default `5000`), `--allow-http`, and `--allow-localhost`.

Before any network request, `--smoke` removes stale `smoke-report.json`,
validates the target profile, URL, expected status, timeout, release contract,
and rollout report binding. The rollout report must be a passing
`kubernetes_rollout_imageid_only` report with `readiness: false`, and its
release id, git sha, release contract digest, and target profile must match
the supplied release contract and target profile. By default the URL must use
HTTPS, must not include userinfo, query, or hash, and must not target
localhost, 127.x, `::1`, or `host.docker.internal`. Local HTTP is accepted only
for focused tests with explicit `--allow-http --allow-localhost`.

The diagnostic performs one GET with built-in Node `fetch` and
`redirect: manual`. Success means only that the response status equals the
expected status. `smoke-report.json` keeps `schema:
agentsmith.route-smoke-report/v1`, `scope: route_smoke_only`, `readiness:
false`, and `status: pass`; it is not deploy readiness, release readiness,
product-flow evidence, or operator signoff. The report stores only a
normalized route summary, expected/observed status, duration, release contract
digest, and rollout report digest/summary. It must not contain response body,
raw headers, custom tokens, kubeconfig content, verdict fields, deploy
readiness fields, or AgentSmith product-flow fields.

Online focused chain orchestration:

```bash
bash scripts/test-online-deployment-gate.sh
```

A copy-pasteable `existing_kubernetes/external_declared/online` operator input
pack is available in `examples/online-existing-kubernetes/`. It is a minimal
use-existing-substrates example for the existing online gate and keeps every
generated report at `readiness: false`.

`--online-deployment-gate` is a KISS runner for the online focused chain on
`existing_kubernetes/external_declared/online` and
`existing_kubernetes/kit_installed/online`. External-declared online invokes
existing focused diagnostics in order: inputs, target-preflight,
template-package, optional image-map when
`--target-registry <registry-host[/namespace]>` is provided,
target-registry apply-only registry-presence through
`--registry-probe <executable>`, render, render-check, apply, and, in
`--mode apply` only, rollout plus optional route smoke.
Kit-installed online is source-registry only and requires
`--substrate-pack-manifest <json>` plus `--routability-probe <executable>`;
its order is inputs, target-preflight, substrate-pack-check, template-package,
substrate-routability, render, render-check, apply, then apply-mode rollout
and optional smoke. Kit-only substrate args are rejected on the external path,
and `--target-registry` is rejected on the kit path. Default `server-dry-run`
mode stops after apply dry-run and rejects `--smoke-url` and
`--registry-probe`; server dry-run target-registry does not require a probe.
Apply mode requires exact confirm text matching the selected target profile
and an operator run id before Kubernetes calls. The external target-registry
option adopts image-map target refs for rendering and, in confirmed apply
rollout, strict live ref checks for those digest-adopted target refs only;
ordinary source-registry rollout remains digest-only. It does not log in,
pull, push, or mirror; registry presence and routability are operator-probe
prerequisites.

Confirmed apply mode may also take `--evidence-root <dir>` and
`--evidence-provenance <json>`. The provenance input must be explicit remote
release-kit provenance without local/file URIs, source paths, or
secret-looking fields; the gate computes the evidence subject sha itself,
writes `evidence.json`, `evidence-subject.json`, and
`online-deployment-gate-report.json` under the evidence root, then reuses
`--evidence` to validate the root. `server-dry-run`, kit-installed online, and
unsupported profiles reject evidence output before Kubernetes or network calls
and remove stale managed evidence files. The capability map marks external
online evidence envelope support as `optional` and kit-installed online as
`unsupported`.

This runner does not provision cloud resources, install substrates, mirror
images, build airgap bundles, import images into kind, perform rollback, or
claim deploy/release readiness. `online-deployment-gate-report.json` keeps `schema:
agentsmith.online-deployment-gate/v1`, `scope:
online_deployment_gate_only`, `readiness: false`, and `status: pass`; it lists
only step names, relative report paths, and a small capability map for
the selected online target profile.

Release-kit evidence envelope focused diagnostic:

```bash
bash scripts/test-evidence.sh
```

`--evidence` validates only a focused release-kit evidence envelope already
present under an evidence root. The root must contain `evidence.json` and
`evidence-subject.json`; the check binds the envelope to the supplied release
contract digest, release identity, target profile, provenance, subject files,
release-kit version policy, output-specific semantics, and
redaction/source-safety rules. The raw envelope schema is
`agentsmith.release-kit-evidence-envelope/v1`; AgentSmith owns the separate
adapter/canonical `agentsmith.release-kit-evidence/v1` shape.
The raw envelope must set `release_kit_output` to one mapped release-kit output:
`image-map.json`, `online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json`;
release-kit must
not emit AgentSmith product-flow evidence. Each accepted output is re-read and
semantically checked. Image-map evidence follows the same image adoption rule as
render: `mirror_required: false` must omit `target_registry` and keep
`target_image === source_image`, while `mirror_required: true` must use the
deterministic target-registry mirror ref. Standalone image-map evidence is
accepted only for `existing_kubernetes/external_declared/online` or
`existing_kubernetes/external_declared/airgap`. Online gate evidence is
accepted only from confirmed apply output on
`existing_kubernetes/external_declared/online`:
`mode` must be `apply`, top-level `operator_run_id` must be present, producer
steps must be non-empty and include apply plus rollout, and `server-dry-run`
reports are rejected. Airgap bundle evidence must
be a real bundle-check triplet: the report, `airgap-bundle-manifest.json`, and
`image-map.json` must agree on required component, image artifact, payload/tool
count, and digest bindings; `components: []` is invalid. The old two-file
airgap output value is rejected. `deploy-result.json#substrate` is future
reserved and is not accepted during pre-GA. Render, rollout, and smoke reports
remain individual focused diagnostic files, but their combinations are not
accepted release-kit evidence envelope outputs. `evidence_subject.files` must
contain only `evidence.json` plus the mapped output files: `image-map.json`,
`online-deployment-gate-report.json`, or `airgap-bundle-check-report.json` plus
`airgap-bundle-manifest.json` plus `image-map.json`. Its provenance
`subject_name` is `release-kit-evidence-subject`. For
`external_declared` targets, the envelope must include inline
`agentsmith.substrate-connection.truth/v1` connection truth.
`evidence-validation-report.json` is written with `readiness: false`,
`scope: release_kit_evidence_intake_only`, and `status: pass`; it is not
render, apply, smoke, package, deploy, or release readiness.
`airgap-bundle-load-plan-report.json`,
`airgap-bundle-render-check-report.json`,
`airgap-image-archive-check-report.json`, and
`airgap-image-load-report.json`, `airgap-deployment-gate-report.json`, and
`substrate-pack-check-report.json` are
intentionally not accepted. Load-plan is plan-only, render-check proves only
offline render plus rendered manifest image inventory, archive-check proves
only local archive probe digest alignment, image-load proves only this focused
operator-loader execution, airgap deployment gate proves only the focused
airgap chain, and substrate-pack-check proves only pack manifest and truth
materiality, not offline install, package, deploy, registry, or release
readiness.
`registry-presence-report.json` is also intentionally not accepted; it is a
focused target digest-ref presence check only.

Operator signoff intake focused diagnostic:

```bash
bash scripts/test-operator-signoff-intake.sh
```

`--operator-signoff-intake` validates only one
`agentsmith.operator-signoff-intake/v1` JSON file against a generated
`online-deployment-gate-report.json` from confirmed apply mode. It accepts
only `existing_kubernetes/external_declared/online`, requires `decision:
signed_off`, binds `operator_run_id`, release id, git sha, the release contract
raw sha256, target profile, and `subject.sha256` to the raw online gate report
file. The online gate report must be `schema:
agentsmith.online-deployment-gate/v1`, `scope:
online_deployment_gate_only`, `readiness: false`, `status: pass`, `mode:
apply`, with top-level `operator_run_id` and non-empty steps including apply
and rollout. Accepted step order is canonical only: either
`inputs,target-preflight,template-package,render,render-check,apply,rollout`
with optional trailing `smoke`, or
`inputs,target-preflight,template-package,image-map,registry-presence,render,render-check,apply,rollout`
with optional trailing `smoke`.

The output `operator-signoff-intake-report.json` keeps `schema:
agentsmith.operator-signoff-intake-report/v1`, `scope:
operator_signoff_intake_only`, `readiness: false`, and `status: pass`. It is a
machine intake/binding report only: it does not verify signatures or identity,
does not prove registry presence, does not enter release-kit evidence envelope
accepted outputs, and is not deploy, package, or release readiness.

Target preflight focused diagnostic:

```bash
bash scripts/test-target-preflight.sh
```

`--target-preflight` validates repo-local intake of two explicit documents:
neutral substrate connection truth
`agentsmith.substrate-connection.truth/v1` and target prerequisites truth
`agentsmith.target-prerequisites.truth/v1`. Substrate truth stays limited to
service endpoints, secret refs or redacted fingerprints, TLS or sslmode,
pgvector, and reachability. Target prerequisites carry the real Kubernetes or
cloud deployment preconditions: target profile, namespace, RBAC policy/proof,
ingress host plus TLS secret ref, registry pull secret ref, storage class plus
PV policy, and the substrate secret refs declared by substrate truth.
The target prerequisites `registry` object is fail-fast allowlisted to
`pull_secret_ref` only; pseudo-proof or secret fields such as `preloaded`,
`mirror_done`, `verdict`, or `token` are rejected.
`target-preflight-report.json` is written with `readiness: false`,
`scope: target_preflight_prerequisite_only`, and `status: pass`; it is not
Kubernetes connectivity evidence, render/check evidence, apply evidence, smoke
evidence, package readiness, deploy readiness, or release readiness.

The full release gate is a future repo-local authority. It is intentionally not
implemented during bootstrap.

## Handoff

After entering this repository, team members must first claim non-overlapping
workstreams:

- Docs.
- Contracts.
- Runbooks.
- CI gate.
- Implementation.

All workstreams are constrained by this README, `AGENTS.md`, `DEVELOPMENT.md`,
and `docs/RELEASE_GATES.md`. Bootstrap approval only means the repo-local team
can begin those workstreams; it does not approve deploy tooling adoption,
release evidence, or publishing.
