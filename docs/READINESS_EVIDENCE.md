# Readiness Evidence

Status: bootstrap ledger.

This file records release-kit-owned evidence once a future full release gate
exists. During bootstrap there is no release readiness evidence.

| Evidence | Current status | Notes |
| --- | --- | --- |
| Governance skeleton | Present | Checked by quick gate. |
| Canonical repo identity | Present | Remote normalizes to `github.com/agentsmith-project/agentsmith-release-kit`. |
| Required bootstrap files | Present | Checked by quick gate. |
| Contract intake diagnostic | Focused only | `intake-report.json` and `image-digest-plan.json` keep `readiness: false`. |
| Template package archive diagnostic | Focused only | `template-package-report.json` keeps `readiness: false`. |
| Release-kit evidence envelope diagnostic | Focused only | `evidence-validation-report.json` keeps `readiness: false`. |
| Online deploy evidence | Not implemented | Future release-kit authority. |
| Airgap package evidence | Not implemented | Future release-kit authority. |
| Kubernetes rollout evidence | Not implemented | Future release-kit authority. |
| Operator runbook signoff | Not implemented | Future release-kit authority. |

The quick gate is not release readiness and does not produce deploy, package,
or operator evidence.

Contract intake output proves contract/input digest readiness only. It is not
deploy, package, release, rollout, or operator readiness evidence.

Template package archive output proves only that one materialized deploy
template package archive matches the declared descriptor and path-safety
constraints. It is not render, deploy, package, release, rollout, smoke, or
operator readiness evidence.

Release-kit evidence envelope output proves only that one pre-existing evidence
root has the expected release-kit-owned envelope, subject, provenance, target
profile, digest, and redaction/source-safety shape. It is not render, apply,
deploy, package, release, rollout, smoke, or operator readiness evidence.
