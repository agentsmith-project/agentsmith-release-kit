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
| Release-kit evidence envelope diagnostic | Focused only | `evidence-validation-report.json` keeps `readiness: false`. |
| Target preflight diagnostic | Focused only | `target-preflight-report.json` keeps `readiness: false`. |
| Online deploy evidence | Not implemented | Future release-kit authority. |
| Airgap package evidence | Not implemented | Future release-kit authority. |
| Kubernetes rollout evidence | Not implemented | Future release-kit authority. |
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

Release-kit evidence envelope output proves only that one pre-existing evidence
root has the expected release-kit-owned envelope, subject, provenance, target
profile, release-kit version, digest, and redaction/source-safety shape. The
raw envelope schema is `agentsmith.release-kit-evidence-envelope/v1`, distinct from AgentSmith's
adapter/canonical `agentsmith.release-kit-evidence/v1`. It is not render,
apply, deploy, package, release, rollout, smoke, or operator readiness
evidence. Raw envelopes explicitly name `release_kit_output`, use
`release-kit-evidence-subject` provenance subjects, list only `evidence.json`
plus the mapped output files in `evidence_subject.files`, and include inline
neutral substrate connection truth for `external_declared`.

Target preflight output proves only that one explicit
`agentsmith.substrate-connection.truth/v1` document matches the requested
target axes and contains the required service, canonical endpoint, secret
reference, TLS or sslmode, `extensions.pgvector.status: installed`, object
storage, OIDC `issuer_url`, `kit_installed` release-kit version plain semver,
and reachability status `declared_reachable` or `verified_by_operator`. It
does not connect to Kubernetes and is not render, apply, deploy, package,
release, rollout, smoke, or operator readiness evidence.
