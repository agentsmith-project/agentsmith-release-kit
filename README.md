# AgentSmith Release Kit

Status: package-driven operator facade plus focused producers and GA aggregate
report.

This repository is the deploy/package evidence home for AgentSmith releases.
It keeps the operator path small: prepare `operator-inputs`, run the
`operator-release.sh` facade, and finish with `ga-release-report.json`.
Maintainer/internal producer diagnostics remain available for evidence
plumbing and troubleshooting, but they are not the operator copy-paste path.

## Canonical Identity

| Field | Value |
| --- | --- |
| Repository | `github.com/agentsmith-project/agentsmith-release-kit` |
| Remote URL | `https://github.com/agentsmith-project/agentsmith-release-kit.git` |
| Default branch | `main` |
| Local bootstrap path | `$WORKSPACE/agentsmith-release-kit` |

The local bootstrap path is a workspace convention only; use this repository
root when working outside that layout. CI and future release evidence must use
the normalized GitHub repository identity.

## Scope

AgentSmith Release Kit consumes:

- AgentSmith release contract.
- AgentSmith deploy template package.
- Operator inputs through `operator-inputs` packages that reference release
  contract, deploy template, render values, use-existing substrate truth,
  target prerequisites, bundle, installer, and probe/loader materials without
  inlining business truth or secrets.

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

The operator-facing path is a single package-driven facade:

1. Prepare one `operator-inputs` package for the selected deployment path.
2. Execute the package with the operator facade.
3. Repeat for each required path.
4. Generate the final GA report from the four package paths plus AgentSmith
   product-side reports.

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
  --post-deploy-product-smoke-report <json> \
  --output-dir <dir>
```

Run `--init-operator-inputs` when you want a scaffolded input package for one
deployment path. Run `--doctor` when you want a missing-input checklist
without executing or writing an intake plan. Run the same `--operator-inputs
<dir-or-json>` command without `--run` only when you want package validation
before execution.

The package contains one `operator-inputs.json` for one selected deployment
path. It is not a four-path manifest. The four accepted `deployment_path`
values are:

- `online/use_existing`
- `online/install_substrates`
- `airgap/use_existing`
- `airgap/install_substrates`

The GA operator substrate choices are `use_existing` and
`install_substrates`.

Without `--run`, this slice validates the package, rejects internal producer
vocabulary, secret-looking payloads, missing path-specific inputs, and path
escapes, then writes `.release-kit-internal/operator-inputs-plan.json`. The
plan is internal only: it is not GA evidence, not release readiness, and does
not write `formal_verdict`. Post-deploy smoke reports are runtime evidence and
are not operator-inputs.

With `--doctor`, the facade reports all currently missing package fields for
the selected deployment path and exits without executing producers, issuing a
verdict, or writing the internal plan.

With `--init-operator-inputs <deployment_path> --output-dir <dir>`, the facade
creates a skeleton package for one of the four GA deployment paths and refuses
to overwrite an existing `operator-inputs.json`. The scaffold intentionally
does not prefill explicit deploy/install confirmations.

With `--run`, the current orchestration slice supports `online/use_existing`,
`online/install_substrates`, `airgap/use_existing`, and
`airgap/install_substrates` with `mode: apply`.
`online/use_existing` runs the existing online focused producer chain.
`online/install_substrates` first runs substrate-install, then runs the online
gate bound to the installer output substrate truth. `airgap/use_existing` runs
the existing airgap consume rehearsal, extracts only its nested bundle-check
and airgap deployment-gate reports, then calls the deployment-path finalizer
with bundle-local release contract/deploy package components. It requires
package-local `kubectl`, explicit `context`, package-local archive/image load
tools, and apply smoke inputs. The airgap install path runs substrate-install,
then runs bundle-check plus airgap deployment-gate using bundle-local release
materials and the installer output substrate truth. These paths write
path-level evidence under `.release-kit-internal/` for the release
captain/finalizer. Server-dry-run modes also fail fast. Formal release success
or failure is represented only by the final `ga-release-report.json` issued by
the release finalizer/captain after required path evidence and AgentSmith
product-side reports are available.

For `online/install_substrates`, the package must provide namespace-scoped
installer inputs, `kubectl` and `context` inputs, a package-local routability
probe, and an explicit install confirmation; it must not provide package-local
`substrate_truth` because the online gate uses installer-generated truth. For
`airgap/install_substrates`, the package must provide package-local
`kubectl`, `context`, the airgap bundle plus manifest, package-local
archive/image loader probes for apply, and explicit install confirmation; it
uses the installer-generated substrate truth under `.release-kit-internal` and
does not require `routability_probe` or bundle/package `substrate_truth`.

After the four packages have been run, the operator-facing final step is
`operator-release.sh --ga-report` with those four package paths plus the
AgentSmith product readiness and post-deploy product smoke reports. The facade
locates finalized path evidence inside each package and writes the final
`ga-release-report.json`; operators do not pass `.release-kit-internal` path
report files.
A blocked final aggregate overwrites stale pass outputs with `status=fail`,
`formal_verdict=not_issued`, and blockers in that same report.
The repository also provides a manual `ga-release-aggregate` GitHub workflow
for release captains. It is `workflow_dispatch` only, downloads the six
already-produced artifacts by repository, run id, and artifact name, runs the
same `operator-release.sh --ga-report` facade, and uploads the final
`ga-release-report.json` plus `ga-release-summary.md`. It does not rerun
product, deployment, airgap, or operator package producers.
These paths are still release-kit installer producer/finalizer evidence flows;
they are not cloud provisioning for clusters, databases, buckets, IAM,
networks, or OIDC realms.

Maintainer/internal references, including legacy positional surfaces,
adoption aggregation, operator signoff intake, release-engineering intake, and
deployment-path finalization, are documented under Maintainer/Internal
Diagnostics. They are not the operator main path, not package readiness, not
operator readiness, and not a separate GA signoff surface.

For `airgap`, operators must provide all required tools, templates, artifacts,
and images from inside the target network. Airgap flow must not download from
the public internet. An operator-declared substrate endpoint can be a target
network prerequisite, but this repository does not create cloud resources.
For airgap apply packages, see `docs/runbooks/README.md` "Airgap Tool
Contract": `archive_probe` and `image_loader` are package-local executable
refs with argv, timeout, and sha256 digest stdout checks. This is a local
tool/digest contract, not proof of network isolation.

## Current Verification

Operator package runbook:

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
  --post-deploy-product-smoke-report <json> \
  --output-dir <dir>
```

Use `--init-operator-inputs` for a scaffolded package, use `--doctor` for a
missing-input checklist, and use `--operator-inputs <dir-or-json>` without
`--run` only for package validation. The package-driven `--run` path writes
finalized deployment-path handoff evidence for the release captain/finalizer
when it executes an apply manifest. It does not issue a formal GA verdict.
Formal release success or failure is issued only by `--ga-report`, which
writes the final `ga-release-report.json`.

### Maintainer/Internal Diagnostics

Maintainer/internal focused diagnostics still exist for compatibility around
the legacy positional surfaces `online use_existing`, `online kit_provided`,
`airgap use_existing`, `airgap kit_provided`, `airgap-bundle use_existing`, and
`airgap-bundle kit_provided`. They are not the operator copy-paste path. All of
them map to existing producer diagnostics and write
`operator-release-surface-report.json` with `readiness: false`. The repo-local
focused surface supports airgap-bundle and airgap `use_existing` plus
`kit_provided`: kit airgap bundle packaging requires
`--substrate-pack-manifest`, validates the substrate pack manifest, binds it
into `airgap-bundle-manifest.json`, and the kit airgap consume/deployment chain
runs the focused substrate-pack-check, image load, bundle render-check, apply,
rollout, and smoke steps. Profile mismatches fail before producer output, and
duplicate singleton/control facade arguments fail fast before producer side
effects.
Airgap-bundle evidence handoff in the surface summary is digest-only. Scoped
operator runbook acceptance is a separate focused check that binds the
legacy positional path, existing-Kubernetes airgap machine profile, surface report,
evidence root, and safe runbook path/digest without adding identity,
signature, verdict, or readiness semantics.
Legacy `kit_provided` is an internal compatibility alias for focused
diagnostics; it is not a GA operator `deployment_path`. removal target: release-kit v1.0.0 GA cut.
`online/kit_provided` and `airgap/kit_provided` map to the kit-supplied
producer diagnostics only.
`install_substrates` requires an explicit report from the separate
`--substrate-install` producer only when maintainers run focused diagnostics
directly. The package-driven
`operator-release.sh --operator-inputs <pkg> --run` path creates that
namespace-scoped installer report internally for the online install package
path plus the matching airgap install package path, binds the installer output
truth into the deployment gate, and finalizes path-level evidence.
`installed_by: agentsmith-release-kit` is a kit-provided pack/truth identity marker / provenance marker only.
It is not installer proof and does not mean release-kit created databases,
buckets, OIDC realms, or other substrate resources.
`kind_rehearsal/kit_installed/online` remains rehearsal-only accepted input. It
is not a release profile, user deployment prerequisite, package-driven release
target, or replacement for real Kubernetes evidence.
`--airgap-adoption` aggregates matching generated airgap-bundle and
confirmed-apply airgap surfaces for `use_existing` or `kit_provided`
repo-local adoption preparation only. For kit airgap it binds the bundle
report, consume report, deployment report, substrate pack manifest digest, and
substrate-pack-check report truth. It writes `airgap-adoption-report.json`
with `readiness: false`; this is not a formal release gate, operator verdict,
deploy/package readiness, or release readiness.

Release engineering gate candidate intake:

```bash
bash scripts/verify-release.sh --release-engineering-gate-intake \
  --release-contract <json> \
  --online-adoption-report <online-adoption-report.json> \
  --airgap-adoption-report <airgap/use_existing airgap-adoption-report.json> \
  --airgap-adoption-report <airgap/kit_provided airgap-adoption-report.json> \
  --output-dir <dir>
```

This is a maintainer-only candidate intake boundary for explicit GA or
compliance trigger work. It consumes existing focused adoption outputs only,
requires the four legacy positional diagnostics (`online/use_existing`,
`online/kit_provided`, `airgap/use_existing`, `airgap/kit_provided`), binds
release identity and release contract digest/provenance, and writes
`release-engineering-gate-intake-report.json` with `readiness: false`,
`scope: release_engineering_gate_candidate_intake_only`, `status: pass`, and
`formal_verdict: not_issued`. The report lists the missing inputs that still
belong to the final `--ga-release` aggregate, including package-driven path
evidence, airgap offline path evidence, and AgentSmith product-side reports; it
is not an evidence envelope output, operator verdict, package readiness, or
release readiness.
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
inventory. During release contract intake,
`release_contract.deploy_template_package.required_image_ids`,
`deploy_template_package.required_image_ids`, and the
`deploy_image_inventory` id set must be non-empty exact-set matches. The
release kit consumes the dynamic deploy image closure from the AgentSmith
release contract instead of a hardcoded image list. Only `product_images` is a
required release-contract image source for intake. `adopted_provider_images`,
`release_kit_prerequisite_images`, and `managed_runner_image` are optional
non-product declarations: when present, their structure and matching inventory
entries are checked; when absent, intake does not fail. `--inputs` does not
require OpenAPI/AsyncAPI digests or product-flow declarations. Every declared
`target_profiles` entry must carry
`required: boolean`; `support_level` is rejected, duplicate three-axis tuples
are rejected, and every entry must use an accepted pre-GA tuple. Only the four
existing-Kubernetes tuples map to package-driven deployment paths. Existing
Kubernetes profiles can be declared for both `external_declared` and
`kit_installed` substrate choices across online and airgap distributions;
`kind_rehearsal/kit_installed/online` remains local/CI rehearsal-only input.
During pre-GA every target profile must use `required: false`; `required:
true` fails fast because full deploy/package evidence is not implemented for
every path. `intake-report.json`, `image-digest-plan.json`, and
`target-profile-coverage-report.json` are written with `readiness: false`;
they prove only contract/input digest readiness, not deploy, package, or
release readiness. In that coverage report, `executable_profiles` means the
currently executable focused deployment profiles:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`; it does not include kind
rehearsal or aliases.
Evidence-supported profiles include external-declared online/airgap plus
kit-installed online confirmed-apply envelopes. Kit airgap adoption remains a
repo-local focused aggregate, not an evidence envelope, operator verdict,
deploy/package readiness, or release readiness.

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
across the release contract's embedded deploy template package, deploy template
package input, and inventory ids.
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
`kind_rehearsal/kit_installed/online` is rehearsal-only accepted input and out
of scope for image-map CLI. Only accepted pre-GA profile tuples are accepted in
`release_contract.target_profiles`; non-canonical pre-GA names and synonym
axes fail fast. For online targets without
`--target-registry`, target refs equal source refs and the action is
`use_source`. When `--target-registry <registry-host[/namespace]>` is
provided, or for every airgap run where it is required, target refs are
derived by stripping the source registry and tag, keeping the repository path,
and appending the original sha256 digest under the target registry. Registry
namespace components must be lowercase and must start and end with
alphanumeric characters.
Standalone image-map enforces the release contract's embedded deploy template
package `required_image_ids` exact-set closure against `deploy_image_inventory`
ids.
Non-product image declarations such as provider images, release-kit
prerequisite images, or `managed_runner_image` are optional release-kit intake
details. When the closure includes one, image-map treats it like any other
digest-bound inventory image. Render then adopts it through normal
`${{ images.<id>.image }}` and `${{ images.<id>.digest }}` placeholders when
templates reference it, and airgap archive flows carry it through the existing
image-map and image-artifact declaration mechanisms. This is not a dedicated
runner runtime, backend-real, or release readiness gate.

Pre-GA stale six-image required-id inputs, obsolete
`${{ values.MANAGED_RUNNER_IMAGE }}` template placeholders, and stale
runner-name aliases such as `agent-task-runner` or `agentsmith-codex-runner`
are not success or compatibility paths. Keep them only as fail-fast/negative
diagnostic evidence, and remove those cases once the current fixtures and
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
self-check. It accepts `existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`. The kit-installed airgap target
requires `--substrate-pack-manifest <json>`.
Inputs are the release contract, deploy template package descriptor, matching
`.tgz` archive, target registry, one local `--image-archive
<image_id=file>` per generated image-map mapping, runbook, install script,
profile-values schema, optional profile-values example, operator
prerequisites JSON, empty-or-absent bundle root, and output directory.

The assembler first reuses `--inputs`, `--template-package`, and `--image-map
--target-registry`; then it copies only local files into a fixed bundle shape:
`components/`, `images/`, `payload/`, optional `tools/`, and root
`airgap-bundle-manifest.json`. Image archive ids must match the generated
image-map one-to-one. For kit-installed airgap bundles, the substrate pack
manifest is copied to `components/substrate-pack-manifest.json`; the bundle
manifest records a `substrate_pack_manifest` component and
`bindings.substrate_pack_manifest_sha256`, with `substrate.mode:
kit_installed` and `substrate.bundled: true`. Input image archives and
bundled tools must be local regular files, not URIs, directories, or symlinks.
Payload files are lightly scanned for obvious secret-looking content. Bundled
tool inputs are copied under `tools/<name>` and the manifest records the copied
file sha.

After assembly, `--bundle-create` immediately runs `--airgap-bundle-check`
against the generated bundle. Only after that passes it writes
`bundle-create-report.json` with `schema:
agentsmith.airgap-bundle-create-report/v1`, `scope:
airgap_bundle_create_only`, `readiness: false`, and non-sensitive
count/digest summaries. It does not log in to a registry, pull, push, mirror,
save, load, parse OCI tar contents, prove registry presence, install offline,
deploy, package, or claim release readiness. `bundle-create-report.json` is
not an accepted release-kit evidence envelope output. The `--evidence` airgap
bundle output is the scoped `airgap_bundle_check` value for
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`.

For either airgap bundle profile, `--bundle-create` can also take
`--evidence-root <dir> --evidence-provenance <json>`. This writes an unsigned
focused evidence root containing `evidence.json`, `evidence-subject.json`,
`airgap-bundle-check-report.json`, `airgap-bundle-manifest.json`,
`image-map.json`, and, for kit-installed airgap,
`substrate-pack-manifest.json`, then immediately revalidates that root with
`--evidence`. The provenance input is `ci_artifact` only; signed operator-run
fields such as signature URI or operator identity are not produced. This
remains `readiness: false` focused evidence, not package, operator signoff,
deploy, or release readiness.
The evidence root must be absent, empty, or contain only those managed evidence
files from a previous run; any other direct entry fails fast and is left in
place.

Airgap bundle manifest/digest focused diagnostic:

```bash
bash scripts/test-airgap-bundle-check.sh
```

`--airgap-bundle-check` validates only a local bundle manifest with
`schema_version: agentsmith.airgap-bundle-manifest/v1` against an explicit
bundle root, release contract, deploy template package descriptor, deploy
template archive `.tgz`, and airgap `image-map`. It accepts
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`; online, kind, and non-canonical
pre-GA target names fail fast. The release contract `target_profiles` value
must be an array, must include the selected airgap target profile, and every
entry must use an accepted pre-GA profile tuple with `required: boolean`;
`support_level` is rejected. The airgap profile may remain `required: false`.
The image-map must be a
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
`image_map`; kit-installed airgap bundles must also include
`substrate_pack_manifest`, with a matching binding digest. `payload_artifacts[]`
allows only `id`, `kind`, `path`, and
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
and an explicit `--archive-probe <executable>`. It accepts
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`; online, kind, non-canonical pre-GA
names, and synonym axes fail fast. It first reuses
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
`--image-loader <executable>`. It accepts
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`; online, kind, non-canonical pre-GA
names, and synonym axes fail fast. It first reuses
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
inside the bundle root. It accepts
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`; online, kind, and non-canonical
pre-GA targets fail fast. It first reuses
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
`existing_kubernetes/external_declared/airgap` and
`existing_kubernetes/kit_installed/airgap`. Default `server-dry-run` runs
target-preflight, bundle render-check, and Kubernetes apply server dry-run;
kit-installed airgap also runs substrate-pack-check. It does not run archive
probing, image loading, rollout, or smoke. `--mode apply` requires
`--archive-probe <executable>`, `--image-loader <executable>`,
`--confirm-apply <matching-target-profile>`, and `--operator-run-id <id>`; it
runs image-load, bundle render-check, apply, and rollout, with route smoke only
when `--smoke-url` is supplied. Kit-installed airgap adds substrate-pack-check
to that chain.
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
already assembled `existing_kubernetes/external_declared/airgap` or
`existing_kubernetes/kit_installed/airgap` bundle. It
requires an explicit bundle root, bundle-local render values and substrate
truth, target prerequisites, namespace, output directory, and Kubernetes
client options. It discovers the release contract, deploy template package,
deploy template archive, and image-map component paths from
`airgap-bundle-manifest.json`; kit-installed airgap bundles also carry the
substrate pack manifest component path. It then reuses
`--airgap-bundle-check` and the existing `--airgap-deployment-gate` chain.
Default `server-dry-run` runs bundle check plus preflight/render-check/apply
dry-run. `--mode apply`
requires archive probe, image loader, matching confirm text, and operator run
id, then reuses the existing image-load/apply/rollout path with optional
smoke through the deployment gate.

The optional `--rehearsal-label existing_kubernetes|kind_rehearsal` value is
operator-provided label-only metadata for the Kubernetes endpoint used by
`kubectl` settings. It does not change the bundle target profile, create or
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
Here, `installed_by` marks kit-provided pack/truth identity and provenance; it
is not installer proof.

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

Substrate install focused diagnostic:

```bash
bash scripts/test-substrate-install.sh
```

`--substrate-install` is a narrow producer for namespace-scoped kit substrate
resources. Confirmed apply requires `--confirm-install-parameters` to match a
digest over the substrate install inputs, `resource_list_sha256`,
`apply_resource_list_sha256`, and effective namespace; reports record
`input_sha256`, `resource_list_sha256`,
`apply_resource_list_sha256`, and `install_parameters_sha256` under
`inputs.substrate_install_inputs`.
Resources are allowed only by explicit apiVersion+kind pairs for static
namespace-scoped resources: core `v1` ConfigMap, `networking.k8s.io/v1`
NetworkPolicy, and core `v1` Service only when `spec.type` is omitted or
`ClusterIP`. The installer does not run workloads or create Pods, PVCs,
Secrets, or RBAC resources. Secret material stays in secret refs only, and
storage proof belongs in target prerequisites rather than installer-created
PVCs.

Kubernetes apply-only focused diagnostic:

```bash
bash scripts/test-apply.sh
```

`--apply` validates already-rendered manifests against a real Kubernetes API.
It accepts only `existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`; `kind_rehearsal`, aliases such as
`offline`, non-canonical pre-GA names, and synonym axes fail fast. Required
inputs are
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
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`; `kind_rehearsal`, aliases such as
`offline`, non-canonical pre-GA names, and synonym axes fail fast. Required
inputs are
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
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`. Required inputs are
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

Copy-pasteable package-driven operator input templates are available in
`examples/`:

- `examples/online-existing-kubernetes/`: `online/use_existing`
- `examples/online-install-substrates/`: `online/install_substrates`
- `examples/airgap-use-existing/`: `airgap/use_existing`
- `examples/airgap-install-substrates/`: `airgap/install_substrates`

They are minimal package skeletons for
`operator-release.sh --operator-inputs`. Install-substrate examples include
`confirm_current_install_parameters: true`; intake prints the computed
`install_parameters_sha256` for audit. Airgap examples keep
release/material inputs bundle-local while package-local executables such as
`kubectl`, `archive_probe`, and `image_loader` live outside the bundle.

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
`--evidence` to validate the root. `server-dry-run` and unsupported profiles
reject evidence output before Kubernetes or network calls and remove stale
managed evidence files. The capability map marks both external online and
kit-installed online evidence envelope support as `optional`.

This runner does not provision cloud resources, install substrates, mirror
images, build airgap bundles, import images into kind, perform rollback, or
claim deploy/release readiness. `online-deployment-gate-report.json` keeps `schema:
agentsmith.online-deployment-gate/v1`, `scope:
online_deployment_gate_only`, `readiness: false`, and `status: pass`; it lists
only step names, relative report paths, and a small capability map for
the selected online target profile.

Online adoption aggregation focused diagnostic:

```bash
bash scripts/test-online-adoption.sh
```

`--online-adoption` reads two already generated confirmed-apply online focused
paths: `online/use_existing` backed by
`existing_kubernetes/external_declared/online`, and
`online/kit_provided` backed by
`existing_kubernetes/kit_installed/online`. Each input must provide its
`online-deployment-gate-report.json` plus the matching evidence root. The check
reuses `--evidence`, requires both paths to bind the same release id, git sha,
release contract raw digest, and release contract subject digest, and writes
only `online-adoption-report.json` with digest/provenance/coverage summaries.
The report keeps `readiness: false`; this is not deploy, package, operator
signoff, AgentSmith product-flow, final GA aggregate, or release readiness.

Release engineering gate intake focused diagnostic:

```bash
bash scripts/test-release-engineering-gate-intake.sh
```

`--release-engineering-gate-intake` is maintainer-only for explicit GA or
compliance trigger work. It consumes only the focused online adoption report
and the two focused airgap adoption reports. It rejects focused producer
reports such as `online-deployment-gate-report.json`,
`operator-release-surface-report.json`, and
`airgap-deployment-gate-report.json`, and it fails closed on readiness/verdict
fields in any input. The generated
`release-engineering-gate-intake-report.json` is a candidate intake report
only: `readiness: false`, `status: pass`, and `formal_verdict: not_issued`.
It is not accepted by `--evidence` and is not deploy, package, offline, or
release readiness.

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
`airgap_bundle_check`; release-kit must
not emit AgentSmith product-flow evidence. Each accepted output is re-read and
semantically checked. Image-map evidence follows the same image adoption rule as
render: `mirror_required: false` must omit `target_registry` and keep
`target_image === source_image`, while `mirror_required: true` must use the
deterministic target-registry mirror ref. Standalone image-map evidence is
accepted only for `existing_kubernetes/external_declared/online` or
`existing_kubernetes/external_declared/airgap`. Online gate evidence is
accepted only from confirmed apply output on
`existing_kubernetes/external_declared/online` or
`existing_kubernetes/kit_installed/online`:
`mode` must be `apply`, top-level `operator_run_id` must be present, producer
steps must be non-empty and include apply plus rollout, and `server-dry-run`
reports are rejected. Kit-installed online evidence must also include the
canonical substrate-pack-check and substrate-routability steps. Airgap bundle
evidence is accepted for external-declared and kit-installed airgap. The
kit-installed profile must include `substrate-pack-manifest.json` in the
subject file list and must bind the bundle manifest
`substrate_pack_manifest` component plus
`bindings.substrate_pack_manifest_sha256`. The bundle-check report,
`airgap-bundle-manifest.json`, and `image-map.json` must agree on required
component, image artifact, payload/tool count, and digest bindings;
`components: []` is invalid. The old two-file and old three-file airgap output
values are rejected. `deploy-result.json#substrate` is future reserved and is
not accepted during pre-GA. Render, rollout, and smoke reports remain
individual focused diagnostic files, but their combinations are not accepted
release-kit evidence envelope outputs. `evidence_subject.files` must contain
only `evidence.json` plus the mapped output files: `image-map.json`,
`online-deployment-gate-report.json`, or the airgap bundle check files
(`airgap-bundle-check-report.json`, `airgap-bundle-manifest.json`,
`image-map.json`, and, for kit-installed airgap,
`substrate-pack-manifest.json`). Its provenance
`subject_name` is `release-kit-evidence-subject`. For online evidence, the
envelope must include matching inline
`agentsmith.substrate-connection.truth/v1` connection truth; kit-installed
truth keeps the kit installation identity fields. Airgap bundle triplet
evidence must not include inline substrate connection truth. This parity is
still focused evidence with `readiness: false`, not deploy/package/release
readiness.
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

`--operator-signoff-intake` is maintainer-only for explicit GA or compliance
trigger work. It validates only one `agentsmith.operator-signoff-intake/v1`
JSON file against a generated `online-deployment-gate-report.json` from
confirmed apply mode. It accepts only
`existing_kubernetes/external_declared/online`, requires `decision:
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
PV policy proof, and the substrate secret refs declared by substrate truth.
The substrate installer does not create PVCs; storage readiness is proven
through these prerequisites.
The target prerequisites `registry` object is fail-fast allowlisted to
`pull_secret_ref` only; pseudo-proof or secret fields such as `preloaded`,
`mirror_done`, `verdict`, or `token` are rejected.
`target-preflight-report.json` is written with `schema:
agentsmith.target-preflight-report/v1`, `readiness: false`,
`scope: target_preflight_prerequisite_only`, and `status: pass`; it is not
Kubernetes connectivity evidence, render/check evidence, apply evidence, smoke
evidence, package readiness, deploy readiness, or release readiness.

The GA release aggregate gate is the repo-local final verdict authority. It
consumes finalized deployment path reports, AgentSmith product readiness, and
post-deploy product smoke reports through the operator-facing
`bash scripts/operator-release.sh --ga-report` facade. The maintainer/internal
`bash scripts/verify-release.sh --ga-release` entry remains available for
diagnostics. The aggregate writes `ga-release-report.json` with
`formal_verdict=issued` on pass; blocked aggregates replace stale pass outputs
with `status=fail`, `formal_verdict=not_issued`, and blockers. It does not
rerun producers.
The post-deploy product smoke input must be the AgentSmith canonical report:
`schema_version: agentsmith.post-deploy-product-smoke-report/v1`, `producer:
agentsmith-post-deploy-product-smoke`, and nested `release_contract: { path,
input_sha256, release_id, git_sha }`. Its `input_sha256`, `release_id`, and
`git_sha` must match the same `--release-contract` raw digest, id, and git sha.
Its `source.product_flows_path` and `source.product_flows_sha256` must bind the
AgentSmith product-flow aggregate consumed by that smoke report.
Its `deployment_target` must bind the deployed target profile, public/API base
URLs, and portable relative `site_env` plus `substrate_truth` path/digest pairs
used for the smoke run.
Legacy surrogate top-level fields are rejected: `release_id`, `git_sha`,
`release_contract_digest`, `covered_flows`, and `artifact_provenance`.
Deployment path report finalization is internal evidence plumbing for
maintainers/CI; it writes a sibling finalizer manifest plus copied
`source-evidence/` JSON files for GA materiality checks and is not a new
operator command or runbook step. Both install-substrate package paths run
`substrate-install` internally through the operator-inputs `--run` slice,
consume its report plus explicit confirmation, and finalize path-level
evidence. This is path orchestration only, not GA verdict, package readiness,
or deploy readiness.
`bash scripts/test-package-driven-ga-smoke.sh` is the lightweight default CI
guard proving the four package-driven finalized path reports can be handed
to the `--ga-report` facade.
`bash scripts/test-ga-release-workflow.sh` is the lightweight default CI guard
proving the manual GA workflow remains dispatch-only and aggregate-only.

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
