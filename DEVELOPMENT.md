# Development Guide

Status: bootstrap-only.

## Local Setup

No package manager setup is required for the bootstrap skeleton.

Use:

```bash
bash scripts/verify-release.sh --quick
bash scripts/test-inputs.sh
bash scripts/test-template-package.sh
bash scripts/test-render.sh
bash scripts/test-render-check.sh
bash scripts/test-image-map.sh
bash scripts/test-registry-presence.sh
bash scripts/test-bundle-create.sh
bash scripts/test-airgap-bundle-check.sh
bash scripts/test-airgap-image-archive-check.sh
bash scripts/test-bundle-load-plan.sh
bash scripts/test-airgap-bundle-render-check.sh
bash scripts/test-apply.sh
bash scripts/test-rollout.sh
bash scripts/test-smoke.sh
bash scripts/test-online-deployment-gate.sh
bash scripts/test-operator-signoff-intake.sh
bash scripts/test-evidence.sh
bash scripts/test-target-preflight.sh
```

There is intentionally no `package.json` in this repository.

## Development Principles

- Contract first, but do not copy AgentSmith product contracts into this repo.
- Keep deployment and package execution separate from AgentSmith product
  readiness.
- Fail fast when required inputs are missing, ambiguous, mutable, or not
  provenance-bound.
- Treat operator inputs as explicit truth. Do not guess local paths, Docker
  defaults, cloud resources, or product source locations.
- Keep secrets out of files, logs, and evidence. Use secret refs and redacted
  fingerprints.

## Inputs

Future implementation must consume only explicit inputs:

- AgentSmith release contract.
- AgentSmith deploy template package.
- Operator target inputs.
- Operator declared substrate connection truth.
- Operator declared target prerequisites truth.
- Operator registry and namespace inputs.

The release kit must not infer those inputs from a sibling checkout.

The current `--inputs` path is a focused diagnostic for contract intake only.
Its `intake-report.json`, `image-digest-plan.json`, and
`target-profile-coverage-report.json` outputs must keep `readiness: false`;
they prove contract/input digest readiness only and are not deploy, package, or
release readiness evidence. App-current inventory closure requires
`release_contract.required_image_ids` and
`deploy_template_package.required_image_ids` to be non-empty exact matches for
the current app image id set, and all required ids must exist in
`deploy_image_inventory`. The current required ids are `agentsmith_app`,
`llmup`, `afscp`, `asbcp`, `ingress_nginx_controller`, and
`ingress_nginx_certgen`. All target profiles must declare `required: boolean`;
`support_level` is rejected. Required profiles must be covered by the current
canonical focused set:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`,
`existing_kubernetes/kit_installed/airgap`, and
`kind_rehearsal/kit_installed/online`. `kind_rehearsal` is supported only as
focused rehearsal and must not be `required: true`. `min_release_kit_version`
must be plain `x.y.z` semver and cannot exceed the current release-kit
version.

The current `--template-package` path is a focused diagnostic for deploy
template package archive intake only. It consumes the release contract, the
deploy template package descriptor, and the materialized `.tgz` archive; it
does not render Kubernetes resources, apply manifests, smoke a cluster, or
claim release readiness.

The current `--render` path is a focused diagnostic for repo-local materialized
template rendering only. It consumes the release contract, deploy template
package descriptor, matching `.tgz` archive, explicit target profile, explicit
render values, and operator-provided substrate truth. It renders only
`kubernetes` templates declared by archive `manifest.json` into
`<output-dir>/rendered-manifests` and writes `manifest-render-report.json` with
`readiness: false` and `scope: manifest_render_only`.
Direct render enforces app-current `required_image_ids` exact-set closure
across the release contract, deploy template package, and inventory.
Optional `--image-map <json>` is accepted only as image reference adoption: it
must be a passing `agentsmith.image-map/v1` report bound to the same release
contract digest and target profile, and render uses `mapping.target_image` for
`${{ images.<id>.image }}` without registry login, pull, push, mirror, or
presence checks. The only template syntax is scalar placeholder replacement
with roots `values`, `images`, `target`, `substrate`, and `release`, such as
`${{ values.namespace }}` or
`${{ images.web.image }}`; unknown placeholders fail fast. It rejects archive
path escapes, symlinks, hardlinks, non-canonical target profile tuples,
pre-GA target profile names, secret-looking rendered payloads, local source
paths, and workload images that are not digest-pinned entries in
`deploy_image_inventory`. It does not call
`kubectl`, apply or dry-run manifests, roll out workloads, smoke a cluster,
mirror images, read sibling source checkouts, or claim render, deploy, or
release readiness.

The current `--render-check` path is a focused diagnostic for rendered
Kubernetes manifest image inventory only. It consumes a release contract, an
already-rendered manifests directory, and an explicit target profile. Its
`render-report.json` must keep `readiness: false` and
`scope: render_check_image_inventory_only`; it checks digest-pinned workload
images against `deploy_image_inventory` and rejects non-canonical target
profile tuples, pre-GA target profile names, path escapes, external symlinks,
and obvious plaintext credential or kubeconfig payloads. It does not render
templates, apply resources, roll out workloads, smoke a cluster, package
artifacts, or claim deploy or release readiness.

The current `--image-map` path is a focused diagnostic for image-map /
mirror-plan generation only. It consumes a release contract, explicit target
profile `existing_kubernetes/<external_declared|kit_installed>/<online|airgap>`,
an output directory, and an optional
`--target-registry <registry-host[/namespace]>`. It reads only
`release_contract.deploy_image_inventory`, requires every inventory image to
be digest-pinned with a matching `digest` field, rejects duplicate ids, images,
and digests, and accepts only the four existing Kubernetes canonical profiles
as CLI targets. `kind_rehearsal/kit_installed/online` is a canonical profile
tuple but out of scope for image-map CLI. Only canonical profile tuples are
accepted in `release_contract.target_profiles`; non-canonical pre-GA names and
synonym axes fail fast.
Standalone image-map enforces app-current `release_contract.required_image_ids`
exact-set closure against `deploy_image_inventory`.
For online without a target registry, it maps each image to itself with
`action: use_source`; with a target registry, and always for airgap, it writes
digest-pinned target refs under that registry with `action: mirror_required`.
Registry namespace components must be lowercase and must start and end with
alphanumeric characters.
Its `image-map.json` must keep `readiness: false` and `scope:
image_map_only`; it does not log in to a registry, pull, push, mirror, build an
airgap bundle, import images into kind, call Kubernetes, or claim deploy,
package, or release readiness.

The current `--registry-presence` path is a focused online target-registry
presence diagnostic only. It consumes a release contract, a passing
mirror-required `agentsmith.image-map/v1` report, explicit target profile
`existing_kubernetes/external_declared/online`, an operator-provided executable
probe, and an output directory. The probe is invoked as
`<executable> <target_image> <expected_digest>` and stdout must contain exactly
one matching `sha256:<64>` digest. `registry-presence-report.json` keeps
`readiness: false` and `scope: registry_presence_only`; it records release
identity, target registry, input digests, image count, and digest match
summaries only. It does not log in, pull, push, mirror, execute registry
tooling itself, call Kubernetes, or claim deploy/package/release readiness,
and it is not accepted by the evidence envelope validator.

The current `--bundle-create` path is a focused diagnostic for local airgap
bundle assembly plus immediate self-check only. It supports only
`existing_kubernetes/external_declared/airgap`. It consumes the release
contract, deploy template package descriptor, matching `.tgz` archive, target
registry, one local image archive per generated image-map mapping, required
payload files, operator prerequisites, an absent-or-empty bundle root, and an
output directory. It first reuses `--inputs`, `--template-package`, and
`--image-map --target-registry`; then it copies local files into `components/`,
`images/`, `payload/`, optional `tools/`, writes
`airgap-bundle-manifest.json`, and runs `--airgap-bundle-check` against that
bundle. `bundle-create-report.json` must keep `readiness: false` and `scope:
airgap_bundle_create_only`; it records only non-sensitive count/digest
summaries and is not an accepted evidence envelope output. It does not pull,
push, mirror, save, load, parse OCI tar contents, log in to registries, call
Docker, skopeo, oras, kubectl, curl, or wget, deploy, prove registry presence,
or claim package/release readiness.

The current `--airgap-bundle-check` path is a focused diagnostic for local
airgap bundle manifest/digest checking only. It consumes a release contract,
deploy template package descriptor, deploy template archive `.tgz`, airgap
`image-map`, explicit target profile
`existing_kubernetes/external_declared/airgap`, explicit bundle root, bundle
manifest, and output directory. The deploy template archive sha256 must match
`deploy_template_package.package_sha256`,
`deploy_template_package.artifact_provenance.artifact_sha256`, and
`bundle_manifest.bindings.deploy_template_archive_sha256`. The release
contract `target_profiles` value must be an array and must include
`existing_kubernetes/external_declared/airgap`; every declared profile must use
a canonical profile tuple with `required: boolean`, and `support_level` is
rejected. The airgap profile may remain `required: false`. The bundle manifest
must use `schema_version: agentsmith.airgap-bundle-manifest/v1` and accepts
only the documented top-level, `bindings`, `components`,
`image_artifact_declarations`, `payload_artifacts`,
`operator_prerequisites`, and `substrate` fields. Its `components` list must
contain exactly one component for each `kind`: `release_contract`,
`deploy_template_package`, `deploy_template_archive`, and `image_map`. The
image-map must be airgap, have `mirror_required: true`, and every mapping must
use `action: mirror_required`. Its mappings are rebound to
`release_contract.deploy_image_inventory`: ids must exist, source image and
digest must match inventory, target digest must equal source digest, and target
image must be under `image_map.target_registry` with `@<target_digest>`. Image
artifact declarations must match image-map mappings one-to-one by id. The
manifest also requires `payload_artifacts` and `operator_prerequisites`.
`payload_artifacts[]` only allows `id`, `kind`, `path`, and `sha256`; allowed
kinds are `runbook`, `script`, `profile_values_schema`,
`profile_values_example`, and `checksums`, and the check requires at least
`runbook`, `script`, `profile_values_schema`, and `checksums`. Operator
prerequisites require operator-held substrate and registry proof refs plus a
non-empty `tools` array. Bundled tools require `path`/`sha256` under the bundle
root; operator prerequisite tools require `location` and `proof` strings. URI
schemes, public-download wording, secret-looking content, field mixing, missing
fields, unsafe paths, missing files, duplicate payload ids, unknown payload
kinds, and sha mismatches fail fast. Bundle paths are relative to the bundle
root only; absolute paths, parent segments, dot segments, empty path segments,
URI paths, symlinks, and backslashes fail fast.
Its `airgap-bundle-check-report.json` must keep `readiness: false` and
`scope: airgap_bundle_manifest_check_only`; it checks only manifest bindings
and declared file sha256 values. The report may include only non-sensitive
payload/tool counts, not raw paths, refs, locations, or proof strings. It is not a packager, does not parse the
`.tgz`, does not create an airgap package, does not call Docker, skopeo, oras,
kubectl, pull, push, mirror, save, load, or inspect image contents, and does
not prove registry presence, image load, offline install readiness, deploy
readiness, package readiness, or release readiness. It does not support kind or
online targets.

The current `--airgap-image-archive-check` path is a focused read-only airgap
image archive materiality diagnostic only. It consumes an already assembled
bundle and the same explicit release contract, deploy template package
descriptor, archive, image-map, bundle root, and bundle manifest inputs as
`--airgap-bundle-check`, plus `--archive-probe <executable>`. It accepts only
`existing_kubernetes/external_declared/airgap`, first runs the existing airgap
bundle check, then invokes the local probe once per declared bundle image
archive. The probe receives the archive path as argv and env and stdout must
be exactly one `sha256:<64>` digest. Each probe digest must match the
image-map `target_digest`, which bundle-check already aligns to release
contract inventory. `--archive-probe` is an operator-owned trusted local
executable; release-kit does not sandbox it or prove the probe itself
trustworthy, and only validates stdout digest alignment with the release
contract, image-map, and bundle manifest.
Its `airgap-image-archive-check-report.json` keeps `readiness: false` and
`scope: airgap_image_archive_content_check_only`; it
records only non-sensitive release identity, target profile, input/report
digests, image ids, archive counts, and digest summaries, and is not accepted
by the evidence envelope validator. It does not call Docker, skopeo, oras,
kubectl, curl, or wget, does not log in, pull, push, mirror, load/import
images, perform offline install, apply manifests, smoke routes, or claim
package, deploy, registry, or release readiness.

The current `--bundle-load-plan` path is a focused read-only airgap bundle load
plan diagnostic only. It consumes an already assembled bundle and the same
explicit inputs as `--airgap-bundle-check`, accepts only
`existing_kubernetes/external_declared/airgap`, and runs the existing airgap
bundle check before writing its own report. It rechecks that the image-map is a
passing airgap mirror plan, image artifact declarations match mappings
one-to-one, target images are digest-pinned under `image_map.target_registry`,
and operator prerequisites declare registry proof and operator-prerequisite
tool proof. Its `airgap-bundle-load-plan-report.json` keeps
`readiness: false` and `scope: airgap_bundle_load_plan_only`; it contains only
digest/count/target-registry summaries and is not accepted by the evidence
envelope validator. It does not call Docker, skopeo, oras, kubectl, curl, or
wget, does not log in, push, import, load, verify registry presence, deploy, or
claim package/release readiness.

The current `--airgap-bundle-render-check` path is a focused read-only airgap
bundle render/check diagnostic only. It consumes an already assembled bundle,
requires the release contract, deploy template package descriptor, archive,
image-map, bundle manifest, render values, and substrate truth to be local
files inside that bundle root, and accepts only
`existing_kubernetes/external_declared/airgap`. It first runs
`--airgap-bundle-check`, then renders with the bundle-local airgap image-map,
then runs `--render-check` on the rendered manifests. Its extra assertion is
that every rendered workload image uses an image-map `target_image` ref, not a
source image ref. `airgap-bundle-render-check-report.json` must keep
`readiness: false` and `scope: airgap_bundle_render_check_only`; it contains
only digest/count/relative-path summaries, omits `target_registry`, and is not
accepted by the evidence envelope validator. It does not call Docker, skopeo,
oras, kubectl, curl, or wget, does not log in, load/import images, apply
manifests, smoke routes, verify registry presence, or claim package, offline
install, deploy, or release readiness.

The current `--apply` path is a focused diagnostic for Kubernetes apply-only
validation. It consumes a release contract, an already-rendered manifests
directory, explicit target profile `existing_kubernetes/external_declared/online`,
namespace, and output directory. It accepts canonical profiles only:
`kind_rehearsal`, `airgap`, non-canonical pre-GA names, and synonym axes fail
fast. It first runs the render/check image inventory
guard, then uses `kubectl` against the target API. Default mode is
`server-dry-run`, which runs server-side dry-run apply. True apply requires
`--mode apply`, `--confirm-apply existing_kubernetes/external_declared/online`,
and `--operator-run-id <id>`. It accepts `--forbidden-source-root` and treats
an existing sibling `../agentsmith` checkout as a default forbidden source
root for the render/check guard. Its `apply-report.json` must keep
`readiness: false` and `scope: kubernetes_apply_only`; it does not roll out
workloads, smoke routes, run product flows, provision cloud resources, or claim
deploy or release readiness.

The current `--rollout` path is a focused diagnostic for Kubernetes
rollout/live digest validation. It consumes a release contract,
already-rendered manifests, explicit target profile
`existing_kubernetes/external_declared/online`, namespace, output directory,
and optional Kubernetes client settings. It accepts canonical profiles only:
`kind_rehearsal`, `airgap`, non-canonical pre-GA names, and synonym axes fail
fast, and it rejects non-rollout workload kinds before rollout
commands. It first runs the render/check image inventory guard, then runs
`kubectl rollout status` for Deployment, StatefulSet, and DaemonSet resources
and reads each workload's selector through `kubectl get <kind>/<name> -o json`.
It then checks live pod `imageID` or `image` digests from
`kubectl get pods --selector <selector> -o json` for that workload. For
ordinary source-registry rendered refs, selected pods only need to show the
expected digest. When render/check accepts a rendered ref through digest
adoption, including target-registry image-map refs, digest-pinned live refs for
that digest must be only the rendered refs; mixed source and target refs fail.
It accepts
`--forbidden-source-root` and treats an existing sibling `../agentsmith`
checkout as a default forbidden source root for the render/check guard. Its
`rollout-report.json` must keep `readiness: false` and `scope:
kubernetes_rollout_imageid_only`; it records
`observed_live_image_digest_summary` rather than raw kubectl output, and does
not smoke routes, run product flows, provision cloud resources, or claim
deploy or release readiness.

The current `--smoke` path is a focused diagnostic for route/service smoke
only. It consumes a release contract, a prior `rollout-report.json`, explicit
target profile `existing_kubernetes/external_declared/online`, one URL, and an
output directory. It does not call Kubernetes, render, apply, roll out
workloads, run product flows, or claim deploy or release readiness. Before any
network request, it validates the target, URL, expected status, timeout,
release contract, and rollout binding. The rollout report must have
`status: pass`, `readiness: false`, `scope:
kubernetes_rollout_imageid_only`, and matching release id, git sha, release
contract digest, and target profile. URLs are HTTPS-only by default, must not
include userinfo, query, or hash, and must not target localhost, 127.x, `::1`,
or `host.docker.internal` unless focused tests explicitly pass
`--allow-http --allow-localhost`. Its `smoke-report.json` must keep
`readiness: false` and `scope: route_smoke_only`; it records only normalized
route/status/duration and release/rollout digests, not response bodies, raw
headers, custom tokens, kubeconfig content, product-flow fields, verdicts, or
deploy readiness.

The current `--online-deployment-gate` path is a KISS online focused
orchestration runner only. It supports
`existing_kubernetes/external_declared/online` and invokes existing diagnostics
in order after both `--substrate-truth <json>` and
`--target-prerequisites <json>` are provided: inputs, target-preflight,
template-package, optional image-map when
`--target-registry <registry-host[/namespace]>` is provided, target-registry
apply registry-presence through `--registry-probe <executable>`, render,
render-check, apply, and, for confirmed `--mode apply` only, rollout plus
optional smoke.
Default `server-dry-run` does not run rollout, smoke, or registry-presence and
rejects `--smoke-url` and `--registry-probe`. Confirmed apply requires exact `--confirm-apply
existing_kubernetes/external_declared/online` and `--operator-run-id <id>`
before Kubernetes calls. Confirmed apply with `--target-registry` also
requires `--registry-probe <executable>` and runs `--registry-presence` after
image-map and before render, apply, smoke, or evidence closure. Its
`online-deployment-gate-report.json` must keep
`readiness: false` and `scope: online_deployment_gate_only`; it records only
release identity, target profile, mode, step names, relative report paths, and
a small capability map for the current online profile. `server-dry-run`
reports must not include `operator_run_id`; confirmed apply reports include
top-level `operator_run_id` copied from `--operator-run-id`.
Confirmed apply may optionally write a focused evidence root with
`--evidence-root <dir> --evidence-provenance <json>`. The provenance JSON must
carry explicit remote release-kit provenance; local/file URIs, source paths,
and secret-looking fields fail before Kubernetes. The gate computes
`subject_name`, `subject_uri`, and `subject_sha256`, writes only
`evidence.json`, `evidence-subject.json`, and
`online-deployment-gate-report.json` as managed evidence files, and validates
the root through the existing `--evidence` diagnostic.
It does not provision cloud resources, mirror images, build airgap bundles,
import images into kind, roll back changes, run product flows, or claim deploy
or release readiness. `--target-registry` only makes the gate generate an
image-map, bind read-only registry-presence in apply mode, pass it into
render, and in confirmed apply rollout run strict live ref checks for those
digest-adopted target refs only. Ordinary source-registry rollout remains
digest-only. It is not mirror execution or registry readiness.

The current `--operator-signoff-intake` path is a focused intake/binding
diagnostic only. It consumes a release contract, a generated
`online-deployment-gate-report.json`, an
`agentsmith.operator-signoff-intake/v1` JSON file, and the explicit
`existing_kubernetes/external_declared/online` target profile. The intake JSON
uses allowlisted fields only and binds `decision: signed_off`,
`operator_run_id`, operator identity, signoff timestamp, release id, git sha,
release contract raw sha256, target profile, and
`subject.kind: online_deployment_gate_report` plus `subject.sha256` to the raw
online gate report file. The bound online gate report must be confirmed apply
output with `readiness: false`, `status: pass`, `mode: apply`, top-level
`operator_run_id`, and one canonical producer sequence: source-registry apply
`inputs,target-preflight,template-package,render,render-check,apply,rollout`
with optional trailing `smoke`, or target-registry apply
`inputs,target-preflight,template-package,image-map,registry-presence,render,render-check,apply,rollout`
with optional trailing `smoke`.
`operator-signoff-intake-report.json` must keep `readiness: false` and
`scope: operator_signoff_intake_only`; it does not verify signatures or
identity, does not prove registry presence, is not an accepted evidence
envelope output, and does not claim deploy, package, or release readiness.

The current `--evidence` path is a focused diagnostic for release-kit evidence
envelope intake only. It consumes a release contract, an evidence root
containing `evidence.json` and `evidence-subject.json`, and an explicit target
profile. The raw envelope schema is
`agentsmith.release-kit-evidence-envelope/v1`; AgentSmith
`agentsmith.release-kit-evidence/v1` is the separate adapter/canonical shape.
The raw envelope must explicitly name `release_kit_output` as
`image-map.json`, `online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json`;
release-kit cannot produce AgentSmith product-flow evidence. Intake accepts only
outputs that can be re-read and semantically checked against the envelope and
release contract:
`image-map.json` binds schema/scope/readiness/status, release identity, target
profile, and digest-pinned mappings to `deploy_image_inventory`, then rechecks
the render adoption rule (`use_source` has no `target_registry` and keeps
source refs; mirrored refs must be deterministic under `target_registry`) and
is accepted only for `existing_kubernetes/external_declared/online` or
`existing_kubernetes/external_declared/airgap`;
`online-deployment-gate-report.json` is accepted only when it is the confirmed
apply output for `existing_kubernetes/external_declared/online` with
`mode: apply`, top-level `operator_run_id`, and non-empty producer steps
including apply and rollout; when provenance is `signed_operator_run`, the
report `operator_run_id` must match the provenance `operator_run_id`; and
the airgap triplet must be a real bundle-check report, manifest, and image-map
set with required component kinds, image artifact declarations, payload/tool
kinds and counts, report counts, and digest bindings aligned. `components: []`,
dry-run online reports, old two-file airgap values, and hand-written empty
airgap sets are rejected.
`deploy-result.json#substrate` is future reserved and is not accepted during
pre-GA; do not preserve future/unimplemented output compatibility here. Render,
rollout, and smoke reports remain individual focused diagnostic files, but
their combinations are not accepted release-kit evidence envelope outputs.
`airgap-bundle-load-plan-report.json` and
`airgap-bundle-render-check-report.json` are also not accepted evidence
envelope outputs. `airgap-image-archive-check-report.json` is also not
accepted because it proves only local archive probe digest alignment, not
load/import, offline install, package, deploy, registry, or release readiness.
`evidence_subject.files` must contain only `evidence.json` plus the mapped
output files: `image-map.json`, `online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json` plus `airgap-bundle-manifest.json` plus
`image-map.json`. Its artifact provenance `subject_name` is
`release-kit-evidence-subject`.
`external_declared` evidence must carry inline neutral substrate connection
truth.
Its `evidence-validation-report.json` must keep `readiness: false` and
`scope: release_kit_evidence_intake_only`; it does not claim deploy, package,
smoke, operator, or release readiness. `evidence.release_kit_version` must be
plain `x.y.z` semver and must be greater than or equal to
`release_contract.min_release_kit_version`.

The current `--target-preflight` path is a focused diagnostic for substrate
truth plus target prerequisites truth intake. It consumes an explicit target
profile, an operator-provided `agentsmith.substrate-connection.truth/v1`
document, and an operator-provided
`agentsmith.target-prerequisites.truth/v1` document. Its
`target-preflight-report.json` must keep `readiness: false` and
`scope: target_preflight_prerequisite_only`; it does not connect to
Kubernetes, render manifests, apply resources, smoke a cluster, package
artifacts, or claim deploy or release readiness. The prerequisites document is
the only place for namespace, RBAC policy/proof, ingress host and TLS secret
ref, registry pull secret ref, storage class/PV policy, and substrate secret
refs needed before a real Kubernetes or cloud target deploy. Its `registry`
object accepts only `pull_secret_ref`; `preloaded`, `mirror_done`, `verdict`,
`token`, and other pseudo-proof or secret payload fields fail fast.

## Non-Goals

This repo does not implement or validate:

- AgentSmith product readiness.
- Visual review.
- Backend-real product validation.
- Product flows.
- Product database/bootstrap semantics.
- Cloud resource provisioning.
- Release management UI.
- Runner runtime.

## Deployment Profiles

`existing_kubernetes` is the real deployment target family.
`kind_rehearsal` is only local or CI rehearsal.

Future work must keep target cluster, substrate source, and distribution as
separate choices:

- `target_cluster`: `existing_kubernetes` or `kind_rehearsal`.
- `substrate_source`: `external_declared` or `kit_installed`.
- `distribution`: `online` or `airgap`.

For `airgap`, do not download public tools, templates, artifacts, or images at
execution time. Operators may declare a substrate endpoint that already exists
inside the target network, but release-kit code must not create cloud resources.

## Workflow

1. Claim a non-overlapping workstream: docs, contracts, runbooks, CI gate, or
   implementation.
2. Keep changes inside this repo.
3. Add focused checks before expanding behavior.
4. Run the matching focused check for the changed slice.
5. Run the quick gate for bootstrap boundary changes.
6. Do not claim release readiness until a future full release gate exists and
   passes.
