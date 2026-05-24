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
| Kubernetes apply-only diagnostic | Focused only | `apply-report.json` keeps `readiness: false`. |
| Kubernetes rollout/live digest diagnostic | Focused only | `rollout-report.json` keeps `readiness: false`. |
| Route/service smoke diagnostic | Focused only | `smoke-report.json` keeps `readiness: false`. |
| Online deployment gate runner | Focused only | `online-deployment-gate-report.json` keeps `readiness: false`. |
| Release-kit evidence envelope diagnostic | Focused only | `evidence-validation-report.json` keeps `readiness: false`. |
| Target preflight diagnostic | Focused only | `target-preflight-report.json` keeps `readiness: false`. |
| Online deploy evidence | Not implemented | Future release-kit authority. |
| Airgap package evidence | Not implemented | Future release-kit authority. |
| Full Kubernetes rollout evidence | Not implemented | Future release-kit authority beyond the focused live digest diagnostic. |
| Operator runbook signoff | Not implemented | Future release-kit authority. |

The quick gate is not release readiness and does not produce deploy, package,
or operator evidence.

Contract intake output proves contract/input digest readiness only. Its target
profile coverage report is limited to required profile support coverage for the
current focused set and never claims release readiness. It is not deploy,
package, release, rollout, or operator readiness evidence.

Template package archive output proves only that one materialized deploy
template package archive matches the declared descriptor and path-safety
constraints. It is not render, deploy, package, release, rollout, smoke, or
operator readiness evidence.

Materialized template render output proves only that one descriptor-bound
archive can render its declared Kubernetes templates from explicit render
values, release contract image inventory, target axes, and substrate connection
truth. Its `manifest-render-report.json` keeps `readiness: false`; it is not
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
image references for `existing_kubernetes/external_declared/online` or
`existing_kubernetes/external_declared/airgap`. Online without a target
registry uses source refs directly; a provided target registry, and every
airgap run, produces mirror-required target refs. It does not verify that
images exist in a target registry, does not pull or push images, does not build
an airgap bundle, and does not support local kind image import.
`image-map.json` keeps `readiness: false`; it is not deploy, package, release,
rollout, smoke, product-flow, or operator readiness evidence.

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

Online deployment gate output proves only that the repo-local runner invoked
the focused online chain in order for
`existing_kubernetes/external_declared/online`. Default mode stops after
server-side dry-run apply; confirmed apply additionally runs rollout and
optional route smoke. It does not provision cloud resources, mirror images,
build airgap bundles, import images into kind, roll back changes, or produce
product-flow evidence. `online-deployment-gate-report.json` keeps
`readiness: false`; it is not deploy, release, package, airgap, kind, product
readiness, or operator signoff evidence.

Release-kit evidence envelope output proves only that one pre-existing evidence
root has the expected release-kit-owned envelope, subject, provenance, target
profile, release-kit version, digest, and redaction/source-safety shape. The
raw envelope schema is `agentsmith.release-kit-evidence-envelope/v1`, distinct from AgentSmith's
adapter/canonical `agentsmith.release-kit-evidence/v1`. It is not render,
apply, deploy, package, release, rollout, smoke, or operator readiness
evidence. Raw envelopes explicitly name `release_kit_output`, use
`release-kit-evidence-subject` provenance subjects, list only `evidence.json`
plus the mapped output files in `evidence_subject.files`, including the
render+rollout and render+rollout+smoke report combinations, and include
inline neutral substrate connection truth for `external_declared`.

Target preflight output proves only that one explicit
`agentsmith.substrate-connection.truth/v1` document matches the requested
target axes and contains the required service, canonical endpoint, secret
reference, TLS or sslmode, `extensions.pgvector.status: installed`, object
storage, OIDC `issuer_url`, `kit_installed` release-kit version plain semver,
and reachability status `declared_reachable` or `verified_by_operator`. It
does not connect to Kubernetes and is not render, apply, deploy, package,
release, rollout, smoke, or operator readiness evidence.
