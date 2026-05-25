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
bash scripts/test-airgap-bundle-check.sh
bash scripts/test-apply.sh
bash scripts/test-rollout.sh
bash scripts/test-smoke.sh
bash scripts/test-online-deployment-gate.sh
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
- Operator registry and namespace inputs.

The release kit must not infer those inputs from a sibling checkout.

The current `--inputs` path is a focused diagnostic for contract intake only.
Its `intake-report.json`, `image-digest-plan.json`, and
`target-profile-coverage-report.json` outputs must keep `readiness: false`;
they prove contract/input digest readiness only and are not deploy, package, or
release readiness evidence. All target profiles must declare
`required: boolean`; `support_level` is rejected. Required profiles must be
covered by the current canonical focused set:
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
`readiness: false` and `scope: manifest_render_only`. The only template syntax
is scalar placeholder replacement with roots `values`, `images`, `target`,
`substrate`, and `release`, such as `${{ values.namespace }}` or
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
For online without a target registry, it maps each image to itself with
`action: use_source`; with a target registry, and always for airgap, it writes
digest-pinned target refs under that registry with `action: mirror_required`.
Registry namespace components must be lowercase and must start and end with
alphanumeric characters.
Its `image-map.json` must keep `readiness: false` and `scope:
image_map_only`; it does not log in to a registry, pull, push, mirror, build an
airgap bundle, import images into kind, call Kubernetes, or claim deploy,
package, or release readiness.

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
`image_artifact_declarations`, and `substrate` fields. Its `components` list
must contain exactly one component for each `kind`: `release_contract`,
`deploy_template_package`, `deploy_template_archive`, and `image_map`. The
image-map must be airgap, have `mirror_required: true`, and every mapping must
use `action: mirror_required`. Image artifact declarations must match image-map
mappings one-to-one by id. Bundle paths are relative to the bundle root only;
absolute paths, parent segments, dot segments, empty path segments, URI paths,
symlinks, and backslashes fail fast.
Its `airgap-bundle-check-report.json` must keep `readiness: false` and
`scope: airgap_bundle_manifest_check_only`; it checks only manifest bindings
and declared file sha256 values. It is not a packager, does not parse the
`.tgz`, does not create an airgap package, does not call Docker, skopeo, oras,
kubectl, pull, push, mirror, save, load, or inspect image contents, and does
not prove registry presence, image load, offline install readiness, deploy
readiness, package readiness, or release readiness. It does not support kind or
online targets.

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
It then checks live pod `imageID` or `image` digests only from
`kubectl get pods --selector <selector> -o json` for that workload. It accepts
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
in order: inputs, target-preflight, template-package, render, render-check,
apply, and, for confirmed `--mode apply` only, rollout plus optional smoke.
Default `server-dry-run` does not run rollout or smoke and rejects
`--smoke-url`. Confirmed apply requires exact `--confirm-apply
existing_kubernetes/external_declared/online` and `--operator-run-id <id>`
before Kubernetes calls. Its `online-deployment-gate-report.json` must keep
`readiness: false` and `scope: online_deployment_gate_only`; it records only
release identity, target profile, mode, step names, relative report paths, and
a small capability map for the current online profile.
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
or release readiness.

The current `--evidence` path is a focused diagnostic for release-kit evidence
envelope intake only. It consumes a release contract, an evidence root
containing `evidence.json` and `evidence-subject.json`, and an explicit target
profile. The raw envelope schema is
`agentsmith.release-kit-evidence-envelope/v1`; AgentSmith
`agentsmith.release-kit-evidence/v1` is the separate adapter/canonical shape.
The raw envelope must explicitly name `release_kit_output` as
`deploy-result.json#substrate`, `image-map.json`,
`online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json+airgap-bundle-manifest.json`; release-kit cannot
produce AgentSmith product-flow evidence. Render, rollout, and smoke reports
remain individual focused diagnostic files, but their combinations are not
accepted release-kit evidence envelope outputs. `evidence_subject.files` must
contain only `evidence.json` plus the mapped output files:
`deploy-result.json`, `image-map.json`, `online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json` plus `airgap-bundle-manifest.json`. Its
artifact provenance `subject_name` is `release-kit-evidence-subject`.
`external_declared` evidence must carry inline neutral substrate connection
truth.
Its `evidence-validation-report.json` must keep `readiness: false` and
`scope: release_kit_evidence_intake_only`; it does not claim deploy, package,
smoke, operator, or release readiness. `evidence.release_kit_version` must be
plain `x.y.z` semver and must be greater than or equal to
`release_contract.min_release_kit_version`.

The current `--target-preflight` path is a focused diagnostic for substrate
connection truth intake only. It consumes an explicit target profile and an
operator-provided `agentsmith.substrate-connection.truth/v1` document. Its
`target-preflight-report.json` must keep `readiness: false` and
`scope: target_preflight_intake_only`; it does not connect to Kubernetes,
render manifests, apply resources, smoke a cluster, package artifacts, or
claim deploy or release readiness.
Accepted connection truth uses `host` for PostgreSQL/MongoDB/Redis, `url` or
`endpoint` plus `region` and `bucket` for object storage, `issuer_url` for
OIDC, `extensions.pgvector.status: installed`, and reachability status
`declared_reachable` or `verified_by_operator`. For `kit_installed`,
`release_kit_version` must be plain `x.y.z` semver.

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
