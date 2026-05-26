# Readiness Evidence

Status: bootstrap ledger.

This file records release-kit-owned evidence once a future full release gate
exists. During bootstrap there is no release readiness evidence.

| Evidence | Current status | Notes |
| --- | --- | --- |
| Governance skeleton | Present | Checked by quick gate. |
| Canonical repo identity | Present | Remote normalizes to `github.com/agentsmith-project/agentsmith-release-kit`. |
| Required bootstrap files | Present | Checked by quick gate. |
| Contract intake diagnostic | Focused only | `intake-report.json`, `image-digest-plan.json`, and `target-profile-coverage-report.json` keep `readiness: false`. |
| Template package archive diagnostic | Focused only | `template-package-report.json` keeps `readiness: false`. |
| Materialized template render diagnostic | Focused only | `manifest-render-report.json` keeps `readiness: false`. |
| Render/check image inventory diagnostic | Focused only | `render-report.json` keeps `readiness: false`. |
| Image-map / mirror-plan diagnostic | Focused only | `image-map.json` keeps `readiness: false`. |
| Airgap bundle create diagnostic | Focused only | `bundle-create-report.json` keeps `readiness: false` and is not evidence-envelope supported. |
| Airgap bundle manifest/digest diagnostic | Focused only | `airgap-bundle-check-report.json` keeps `readiness: false`. |
| Airgap bundle load-plan diagnostic | Focused only | `airgap-bundle-load-plan-report.json` keeps `readiness: false` and is not evidence-envelope supported. |
| Airgap bundle render-check diagnostic | Focused only | `airgap-bundle-render-check-report.json` keeps `readiness: false` and is not evidence-envelope supported. |
| Kubernetes apply-only diagnostic | Focused only | `apply-report.json` keeps `readiness: false`. |
| Kubernetes rollout/live digest diagnostic | Focused only | `rollout-report.json` keeps `readiness: false`. |
| Route/service smoke diagnostic | Focused only | `smoke-report.json` keeps `readiness: false`. |
| Online focused chain runner | Focused only | `online-deployment-gate-report.json` keeps `readiness: false`. |
| Operator runbook signoff | Focused intake only / not readiness | `operator-signoff-intake-report.json` keeps `readiness: false` and is not evidence-envelope supported. |
| Release-kit evidence envelope diagnostic | Focused only | `evidence-validation-report.json` keeps `readiness: false`. |
| Target preflight diagnostic | Focused only | `target-preflight-report.json` keeps `readiness: false`. |
| Online deploy evidence | Not implemented | Future release-kit authority. |
| Airgap package evidence | Not implemented | Future release-kit authority. |
| Full Kubernetes rollout evidence | Not implemented | Future release-kit authority beyond the focused live digest diagnostic. |

The quick gate is not release readiness and does not produce deploy, package,
or operator evidence.

Contract intake output proves contract/input digest readiness only. Its target
profile coverage report separates canonical declarable profiles,
intake-supported profiles, executable profiles, and evidence-supported focused
profiles. During pre-GA all `target_profiles.required` values must be `false`;
`required: true` fails fast instead of implying support. It never claims
release readiness. It is not deploy, package, release, rollout, or operator
readiness evidence.

Template package archive output proves only that one materialized deploy
template package archive matches the declared descriptor and path-safety
constraints. It is not render, deploy, package, release, rollout, smoke, or
operator readiness evidence.

Materialized template render output proves only that one descriptor-bound
archive can render its declared Kubernetes templates from explicit render
values, release contract image inventory, target axes, and substrate connection
truth. Direct render also enforces app-current `required_image_ids` exact-set
closure across the release contract, deploy template package descriptor, and
`deploy_image_inventory`. Its `manifest-render-report.json` keeps
`readiness: false`; it is not
apply, deploy, package, release, rollout, smoke, or operator readiness
evidence.

Render/check output proves only that already-rendered workload manifests use
digest-pinned images from the supplied release contract
`deploy_image_inventory`, and that manifest paths and obvious plaintext
credential payloads pass focused safety checks. It does not render templates,
apply resources, deploy, package, release, roll out workloads, smoke endpoints,
or produce operator readiness evidence.

Image-map output proves only that the release contract
`deploy_image_inventory` can be projected into digest-pinned source/target
image references for existing Kubernetes canonical profiles:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`. Online without a target
registry uses source refs directly; a provided target registry, and every
airgap run, produces mirror-required target refs. It does not verify that
images exist in a target registry, does not pull or push images, does not build
an airgap bundle, and does not support local kind image import. Because
`image-map.json` is an accepted release-kit evidence output, standalone
image-map generation also enforces the app-current
`release_contract.required_image_ids` exact-set closure and requires every
required id to exist in `deploy_image_inventory`.
`image-map.json` keeps `readiness: false`; it is not deploy, package, release,
rollout, smoke, product-flow, or operator readiness evidence.

Airgap bundle create output proves only that one local bundle root was
assembled from explicit local inputs and immediately accepted by the existing
airgap bundle manifest/digest diagnostic. It accepts only
`existing_kubernetes/external_declared/airgap`, rejects online, kind,
`kit_installed/airgap`, and synonym axes, and requires repeated local
`--image-archive <image_id=file>` inputs to match the generated image-map
mappings one-to-one. It copies local files into a fixed bundle shape, writes
`airgap-bundle-manifest.json`, generates `payload/checksums.txt`, and can copy
bundled tool inputs under `tools/<name>`. It does not pull, push, mirror,
save, load, log in to registries, call Docker, skopeo, oras, kubectl, curl, or
wget, parse OCI tar contents, verify registry presence, load images, install
offline, deploy, or prove package/release readiness.
`bundle-create-report.json` keeps `readiness: false`; it contains only
non-sensitive count/digest summaries and is not accepted by the release-kit
evidence envelope validator.

Airgap bundle manifest/digest output proves only that one local bundle manifest
with `schema_version: agentsmith.airgap-bundle-manifest/v1` binds the supplied
release contract, deploy template package descriptor, deploy template archive,
image-map, and declared image artifact files by safe relative paths and sha256
values. Components must be exactly one each by `kind`: `release_contract`,
`deploy_template_package`, `deploy_template_archive`, and `image_map`.
`bundle_manifest.bindings.deploy_template_archive_sha256` must match the
archive sha256, and the archive sha256 must match
`deploy_template_package.package_sha256` and
`deploy_template_package.artifact_provenance.artifact_sha256`. Image artifact
declarations must match airgap image-map mappings one-to-one by id. The release
contract must declare `existing_kubernetes/external_declared/airgap` in
`target_profiles`, each profile entry must carry `required: false` during
pre-GA, and `support_level` is rejected.
`existing_kubernetes/kit_installed/airgap` may be declared in the contract, but
this diagnostic does not deploy it. The bundle manifest accepts only the
documented top-level, `bindings`, `components`,
`image_artifact_declarations`, `payload_artifacts`,
`operator_prerequisites`, and `substrate` fields. The image-map must have
`mirror_required: true` and every mapping must use `action: mirror_required`;
mapping ids and source refs must match `release_contract.deploy_image_inventory`,
target digests must equal source digests, and target images must be under
`image_map.target_registry` with `@<target_digest>`. Payload artifacts must
declare only id/kind/path/sha, include runbook, script, profile-values schema,
and checksums kinds, and pass safe path plus sha256 checks. Operator
prerequisite refs, locations, and proofs are operator-held strings; they are
not bundle files and must not contain URI schemes, public-download semantics,
or secret-looking content. This diagnostic is manifest/digest check only: it
is not a packager, does not parse the `.tgz`, does not create an
airgap package, does not call Docker, skopeo, oras, kubectl, pull, push,
mirror, save, or load images, does not inspect image artifact contents, does
not verify registry presence or image load, does not support online or kind
targets, and does not prove offline install readiness.
`airgap-bundle-check-report.json` keeps `readiness: false`; it is not deploy,
package, release, rollout, smoke, product-flow, or operator readiness evidence.
It may include only non-sensitive payload/tool counts, not raw paths, refs,
locations, or proof strings.

Airgap bundle load-plan output proves only that one already assembled bundle
passed the existing airgap bundle check and can be summarized as a read-only
target-registry load plan. It accepts only
`existing_kubernetes/external_declared/airgap`, rechecks the airgap image-map
mirror plan and image artifact declarations, and confirms operator
prerequisites declare a target registry proof ref and operator-prerequisite
tool proof. It does not treat those proof strings as registry presence, signed
load evidence, image push/import/load success, package readiness, or release
readiness. It does not call Docker, skopeo, oras, kubectl, curl, or wget, does
not log in to a registry, does not read OCI tar contents, and does not deploy
or smoke. `airgap-bundle-load-plan-report.json` keeps `readiness: false`; it
contains only digest/count/target-registry summaries and is not accepted by the
release-kit evidence envelope validator.

Airgap bundle render-check output proves only that one already assembled
bundle can be checked, rendered offline from bundle-local render values and
substrate truth, and passed through rendered manifest image inventory checking.
It accepts only `existing_kubernetes/external_declared/airgap`; every
contract/package/archive/image-map/bundle-manifest/render-values/substrate-truth
input must be a local file inside the bundle root. It reuses
`--airgap-bundle-check`, `--render`, and `--render-check`, then asserts that
every rendered workload image is an image-map `target_image` ref. It does not
call Docker, skopeo, oras, kubectl, curl, or wget, does not log in, load/import
images, apply manifests, smoke routes, verify registry presence, deploy, or
prove package/offline install readiness.
`airgap-bundle-render-check-report.json` keeps `readiness: false`; it contains
only digest/count/relative-path summaries, omits `target_registry`, and is not
accepted by the release-kit evidence envelope validator.

Kubernetes apply-only output proves only that already-rendered manifests passed
the render/check image inventory guard and were accepted by `kubectl apply`
against `existing_kubernetes/external_declared/online`. The default path is
server-side dry-run; real apply is allowed only with explicit confirm text and
an operator run id. `apply-report.json` keeps `readiness: false`; it is not
deploy, release, rollout, route smoke, product-flow, package, or operator
readiness evidence.

Kubernetes rollout/live digest output proves only that already-rendered
Deployment, StatefulSet, and DaemonSet resources passed the render/check image
inventory guard, reached `kubectl rollout status`, and had every expected
render/check image digest visible in selector-scoped live pod `imageID` values
or, when needed, live `image` fields. It accepts only
`existing_kubernetes/external_declared/online`, rejects kind rehearsal,
airgap, non-canonical pre-GA target names, and synonym axes, and writes only
normalized digest summaries. `rollout-report.json` keeps `readiness: false`;
it is not deploy, release, route smoke, product-flow, package, full rollout,
or operator readiness evidence.

Route/service smoke output proves only that one explicit route returned the
expected status after the supplied rollout report was bound to the same release
contract and target profile. It accepts only
`existing_kubernetes/external_declared/online`, uses HTTPS by default, rejects
userinfo/query/hash and localhost-style URLs unless focused tests explicitly
allow them, and records only normalized route and status summaries.
`smoke-report.json` keeps `readiness: false`; it is not deploy, release,
product-flow, package, full smoke, or operator readiness evidence.

Online focused chain output proves only that the repo-local runner invoked the
focused online chain in order for
`existing_kubernetes/external_declared/online`. Default mode stops after
server-side dry-run apply; confirmed apply additionally runs rollout and
optional route smoke. It does not provision cloud resources, install
substrates, mirror images, build airgap bundles, import images into kind, roll
back changes, or produce product-flow evidence.
`online-deployment-gate-report.json` keeps
`readiness: false`; it is not deploy, release, package, airgap, kind, product
readiness, or operator signoff evidence.
When explicitly requested in confirmed apply mode, the online focused chain can
also write a release-kit evidence envelope root and validate it through
`--evidence`. That envelope is still focused diagnostic evidence with
`release_kit_output: online-deployment-gate-report.json`; it is not online
deploy readiness evidence or operator signoff.

Operator signoff intake proves only that one
`agentsmith.operator-signoff-intake/v1` JSON document is syntactically
allowlisted and bound to one generated online deployment gate apply report.
The binding checks release id, git sha, release contract raw sha256, target
profile, operator run id, and the raw sha256 of
`online-deployment-gate-report.json`; the gate report must be confirmed apply
output with `readiness: false`, `status: pass`, `mode: apply`, top-level
`operator_run_id`, and apply plus rollout steps. The resulting
`operator-signoff-intake-report.json` keeps `readiness: false`; it is not
signature verification, identity verification, registry presence proof, full
online adoption proof, evidence-envelope input, deploy readiness, package
readiness, or release readiness.

Release-kit evidence envelope output proves only that one pre-existing evidence
root has the expected release-kit-owned envelope, subject, provenance, target
profile, release-kit version, digest, and redaction/source-safety shape. The
raw envelope schema is `agentsmith.release-kit-evidence-envelope/v1`, distinct from AgentSmith's
adapter/canonical `agentsmith.release-kit-evidence/v1`. It is not render,
apply, deploy, package, release, rollout, smoke, or operator readiness
evidence. Raw envelopes explicitly name `release_kit_output`, use
`release-kit-evidence-subject` provenance subjects, and list only
`evidence.json` plus the mapped output files in `evidence_subject.files`.
Accepted `release_kit_output` values are `image-map.json`,
`online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json`.
The mapped files are `image-map.json`, `online-deployment-gate-report.json`, or
the airgap three-file set: `airgap-bundle-check-report.json`,
`airgap-bundle-manifest.json`, and `image-map.json`. Each accepted output is
re-read and semantically checked against the envelope, release contract digest,
release id, git sha, and target profile. `image-map` evidence must keep
`schema: agentsmith.image-map/v1`, `scope: image_map_only`, `readiness: false`,
`status: pass`, and digest-pinned mappings matching `deploy_image_inventory`;
it also reuses the render adoption semantics for `target_registry`,
`use_source`, and deterministic mirrored target refs. Standalone image-map
evidence is accepted only for `existing_kubernetes/external_declared/online` or
`existing_kubernetes/external_declared/airgap`.
Online gate evidence must keep
`schema: agentsmith.online-deployment-gate/v1`,
`scope: online_deployment_gate_only`, `readiness: false`, `status: pass`, and
is accepted only for confirmed apply output on
`existing_kubernetes/external_declared/online`; `mode: server-dry-run`, missing
top-level `operator_run_id`, empty steps, or missing apply/rollout steps are
rejected. Airgap bundle evidence must
bind a passing check report to a real
`agentsmith.airgap-bundle-manifest/v1` manifest for
`existing_kubernetes/external_declared/airgap`, including the required four
components, image artifact declarations, mandatory payload/tool categories and
counts, report counts, and artifact/binding digests, with image declarations
matching the re-read image-map mappings. `components: []`, fake empty
manifest/report sets, and the old two-file airgap output value are rejected.
`deploy-result.json#substrate` is future reserved and is not accepted during
pre-GA. Render, rollout, and smoke reports remain individual focused diagnostic
files, but their combinations are not accepted release-kit evidence envelope
outputs. `bundle-create-report.json` is also intentionally not accepted; use the
generated airgap bundle check report plus manifest plus image-map set for
focused airgap evidence intake. `airgap-bundle-load-plan-report.json` is intentionally not
accepted because it is plan-only and does not prove registry execution or
package readiness.
`airgap-bundle-render-check-report.json` is intentionally not accepted because
it proves only offline bundle rendering and rendered image inventory, not
registry execution, package readiness, offline install readiness, deploy
readiness, or release readiness.
Online gate evidence is accepted only for
`existing_kubernetes/external_declared/online`; airgap bundle check evidence is
accepted only for `existing_kubernetes/external_declared/airgap`. Raw
envelopes include inline neutral substrate connection truth for
`external_declared`.

Target preflight output proves only that one explicit
`agentsmith.substrate-connection.truth/v1` document and one explicit
`agentsmith.target-prerequisites.truth/v1` document match the requested target
axes. The substrate document covers required services, canonical endpoints,
secret refs, TLS or sslmode, pgvector, and reachability. The prerequisites
document covers namespace, RBAC policy/proof, ingress host plus TLS secret ref,
registry pull secret ref, storage class plus PV policy, and the substrate
secret refs declared by substrate truth. It does not connect to Kubernetes and
is not render, apply, deploy, package, release, rollout, smoke, or operator
readiness evidence.
