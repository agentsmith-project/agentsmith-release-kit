# AgentSmith Release Kit

Status: bootstrap-only, docs-governance-first skeleton.

This repository is the future deploy and package execution home for
AgentSmith releases. It is intentionally small at bootstrap time: repo
identity, boundary documents, handoff guidance, and focused diagnostics. It
contains an apply-only focused diagnostic, but does not contain rollout,
smoke, or full deploy tooling yet.

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
- Operator inputs, including target cluster, registry, substrate connection
  truth, namespace, ingress, TLS, and secret references.

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

`kind_rehearsal` is only a local or CI rehearsal target. It is not a user deployment prerequisite.
It does not replace real Kubernetes evidence when a real Kubernetes target is in scope.

For `airgap`, operators must provide all required tools, templates, artifacts,
and images from inside the target network. Airgap flow must not download from
the public internet. An operator-declared substrate endpoint can be a target
network prerequisite, but this repository does not create cloud resources.

## Current Verification

Bootstrap quick gate:

```bash
bash scripts/verify-release.sh --quick
```

The quick gate checks only the governance skeleton and boundary guardrails. It
is not release readiness and must not be used as a deploy, package, or release
verdict.

Contract intake focused diagnostic:

```bash
bash scripts/test-inputs.sh
```

`--inputs` validates only the release contract, deploy template package, target
profile, provenance, release-kit version policy, and digest-bound image
inventory. Every declared `target_profiles` entry must carry
`required: boolean`; `support_level` is rejected, duplicate three-axis tuples
are rejected, and required profiles must fit the current focused support set:
`existing_kubernetes/external_declared/online` and
`kind_rehearsal/kit_installed/online`. The kind profile is supported only as a
focused rehearsal and must not be `required: true`. The airgap profile
`existing_kubernetes/external_declared/airgap` may be declared only with
`required: false` during this bootstrap slice. `intake-report.json`,
`image-digest-plan.json`, and `target-profile-coverage-report.json` are
written with `readiness: false`; they prove only contract/input digest
readiness, not deploy, package, or release readiness.

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

The template language is intentionally tiny: scalar placeholders only, no
conditionals and no loops. Supported placeholder roots are `values`, `images`,
`target`, `substrate`, and `release`, for example
`${{ values.namespace }}`, `${{ images.web.image }}`,
`${{ target.distribution }}`, `${{ substrate.services.postgresql.host }}`, and
`${{ release.release_id }}`. Unknown or non-scalar placeholders fail fast.
Rendered workload images must be digest-pinned and must come from
`release_contract.deploy_image_inventory`. Archive path escapes, symlinks,
hardlinks, local/source payloads, secret-looking rendered content, and legacy
target profile names are rejected. This diagnostic does not call `kubectl`,
apply or dry-run manifests, roll out workloads, smoke endpoints, mirror images,
read a sibling AgentSmith checkout, or claim render/deploy/release readiness.
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
`deploy_image_inventory` by exact image ref or digest. It rejects legacy target
profile names, unknown images, tag-only image refs, digest drift, manifest path
escapes, external symlinks, and obvious plaintext credential or kubeconfig
payloads. `render-report.json` is written with `readiness: false`,
`scope: render_check_image_inventory_only`, and `status: pass`; it is not
render readiness, deploy readiness, release readiness, apply evidence, rollout
evidence, smoke evidence, or operator signoff.

Kubernetes apply-only focused diagnostic:

```bash
bash scripts/test-apply.sh
```

`--apply` validates already-rendered manifests against a real Kubernetes API.
It accepts only `existing_kubernetes/external_declared/online` and rejects
`kind_rehearsal`, `airgap`, legacy names, and synonym axes. Required inputs are
`--release-contract`, `--rendered-manifests`, `--target-profile`,
`--namespace`, and `--output-dir`; optional inputs are `--kubeconfig`,
`--context`, `--kubectl`, and `--forbidden-source-root`. If a sibling
`../agentsmith` checkout exists next to release-kit, `--apply` treats it as a
default forbidden source root before running render/check.

Before any `kubectl` call, `--apply` runs the render/check image inventory
guard. The default `--mode server-dry-run` runs `kubectl apply --server-side
--dry-run=server` and writes `apply-report.json` only after success. Real
apply requires `--mode apply --confirm-apply
existing_kubernetes/external_declared/online --operator-run-id <id>`.
`apply-report.json` keeps `readiness: false`, `scope:
kubernetes_apply_only`, and `status: pass`; it is not deploy readiness,
release readiness, rollout evidence, route smoke evidence, product-flow
evidence, or operator signoff.

Release-kit evidence envelope focused diagnostic:

```bash
bash scripts/test-evidence.sh
```

`--evidence` validates only a future deployment/package evidence envelope
already present under an evidence root. The root must contain `evidence.json`
and `evidence-subject.json`; the check binds the envelope to the supplied
release contract digest, release identity, target profile, provenance, subject
files, release-kit version policy, and redaction/source-safety rules. The raw envelope schema is
`agentsmith.release-kit-evidence-envelope/v1`; AgentSmith owns the separate
adapter/canonical `agentsmith.release-kit-evidence/v1` shape.
The raw envelope must set `release_kit_output` to one mapped release-kit output:
`deploy-result.json#substrate`, `image-map.json`, or
`render-report.json+rollout-report.json`; release-kit must not emit
AgentSmith product-flow evidence. `evidence_subject.files` must contain only
`evidence.json` plus the mapped output files: `deploy-result.json`,
`image-map.json`, or both `render-report.json` and `rollout-report.json`. Its
provenance `subject_name` is `release-kit-evidence-subject`. For
`external_declared` targets, the envelope must include inline
`agentsmith.substrate-connection.truth/v1` connection truth.
`evidence-validation-report.json` is written with `readiness: false`,
`scope: release_kit_evidence_intake_only`, and `status: pass`; it is not
render, apply, smoke, package, deploy, or release readiness.

Target preflight focused diagnostic:

```bash
bash scripts/test-target-preflight.sh
```

`--target-preflight` validates only repo-local intake of
`agentsmith.substrate-connection.truth/v1` substrate connection truth for an
explicit target profile. It checks the three target axes, supported focused
profiles, required substrate services, canonical endpoint declarations
(`host` for PostgreSQL/MongoDB/Redis, `url` or `endpoint` plus `region` and
`bucket` for object storage, and `issuer_url` for OIDC), secret references, TLS
or sslmode declarations, `extensions.pgvector.status: installed`, reachability
statuses `declared_reachable` or `verified_by_operator`, `kit_installed`
release-kit versions as plain `x.y.z` semver, and obvious local source or
plaintext credential payloads. `target-preflight-report.json` is written with
`readiness: false`, `scope: target_preflight_intake_only`, and `status: pass`;
it is not Kubernetes connectivity evidence, render/check evidence, apply
evidence, smoke evidence, package readiness, deploy readiness, or release
readiness.

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
