# Release Gates

Status: bootstrap-only.

## Quick Gate

Run:

```bash
bash scripts/verify-release.sh --quick
```

The quick gate is not release readiness. It only checks that the bootstrap
governance skeleton and boundary guardrails are intact.

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

## Contract Intake Focused Diagnostic

Run:

```bash
bash scripts/test-inputs.sh
```

This focused guard exercises `bash scripts/verify-release.sh --inputs`. It
checks release contract intake, deploy template package intake, target-profile
selection, provenance, and digest-bound image inventory only.

The generated `intake-report.json` and `image-digest-plan.json` must keep
`readiness: false`. They prove contract/input digest readiness only. They are
not deploy readiness, package readiness, release readiness, rollout evidence,
or operator signoff.

## Template Package Archive Focused Diagnostic

Run:

```bash
bash scripts/test-template-package.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--template-package`. It checks only the materialized deploy template package
archive against the release contract and deploy template package descriptor.

The check verifies descriptor equality, archive sha256, provenance artifact
sha256 when present, archive `manifest.json` sha256, path safety for package
entries, and obvious local source or plaintext credential payloads. It rejects
absolute paths, `..` package-root escapes, symlinks, and hardlinks before any
future render/check code can consume the archive.

The generated `template-package-report.json` must keep `readiness: false` and
`scope: template_package_intake_only`. It is not release readiness, package
readiness, Kubernetes render evidence, deploy evidence, rollout evidence, smoke
evidence, or operator signoff.

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
drift, legacy or synonym target values such as `local-kind`, manifest path
escapes, external symlinks, and obvious plaintext credential or kubeconfig
payloads.

The generated `render-report.json` must keep `readiness: false`,
`scope: render_check_image_inventory_only`, and `status: pass`. It must not
contain `verdict` or `release_verdict`. It is not release readiness, package
readiness, render readiness, apply evidence, rollout evidence, smoke evidence,
deploy evidence, or operator signoff.

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
the explicit `release_kit_output` mapping, release-kit provenance, subject file digests, subject path safety, and
redaction/source scans for the envelope and subject files. It rejects legacy or
synonym target values, AgentSmith product-flow fields, local provenance URIs,
absolute paths, `..` escapes, symlinks, hardlinks, and obvious secret payloads.
Accepted `release_kit_output` values are `deploy-result.json#substrate`,
`image-map.json`, and `render-report.json+rollout-report.json`; `AgentSmith
product flow aggregate` is rejected. The provenance `subject_name` must be
`release-kit-evidence-subject`. The subject file list must include the mapped
output file: `deploy-result.json`, `image-map.json`, or both
`render-report.json` and `rollout-report.json`.
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

## Target Preflight Focused Diagnostic

Run:

```bash
bash scripts/test-target-preflight.sh
```

This focused guard exercises `bash scripts/verify-release.sh
--target-preflight`. It checks only repo-local intake of a substrate connection
truth document supplied by the operator or by a release-kit adjacent substrate
pack. It does not open a Kubernetes client, render manifests, run checks,
apply resources, roll out workloads, smoke product endpoints, create cloud
resources, or build an airgap bundle.

The accepted truth schema is
`agentsmith.substrate-connection.truth/v1`. Docker substrate truth, legacy
target names such as `local-kind`, `existing-cluster`, `real-k8s`, and synonym
axes such as `kind` or `cluster` are rejected. The supported focused profiles
are `existing_kubernetes/external_declared/online` and
`kind_rehearsal/kit_installed/online`.

For `external_declared`, the operator provides the connection truth and the
release kit only validates the document. Raw evidence envelopes for
`external_declared` must include inline neutral connection truth under
`substrate_connection_truth`. For `kit_installed`, the same neutral truth
schema is used and the document must declare `installed_by` and
`release_kit_version`. Both paths must include the required substrate services,
endpoint declarations, secret references, TLS or sslmode declarations,
PostgreSQL vector extension truth, object storage and OIDC fields, and
reachability status/proof fields. Plaintext credentials, connection strings,
kubeconfig payloads, file or source URIs, and AgentSmith source paths are
rejected.

The generated `target-preflight-report.json` must keep `readiness: false`,
`scope: target_preflight_intake_only`, and `status: pass`. It must not contain
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
