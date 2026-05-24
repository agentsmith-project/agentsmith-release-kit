# AgentSmith Release Kit

Status: bootstrap-only, docs-governance-first skeleton.

This repository is the future deploy and package execution home for
AgentSmith releases. It is intentionally small at bootstrap time: repo
identity, boundary documents, handoff guidance, and a quick governance guard.
It does not contain deploy tooling yet.

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
profile, provenance, and digest-bound image inventory. `intake-report.json` and
`image-digest-plan.json` are written with `readiness: false`; they prove only
contract/input digest readiness, not deploy, package, or release readiness.

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

Release-kit evidence envelope focused diagnostic:

```bash
bash scripts/test-evidence.sh
```

`--evidence` validates only a future deployment/package evidence envelope
already present under an evidence root. The root must contain `evidence.json`
and `evidence-subject.json`; the check binds the envelope to the supplied
release contract digest, release identity, target profile, provenance, subject
files, and redaction/source-safety rules. `evidence-validation-report.json` is
written with `readiness: false`, `scope: release_kit_evidence_intake_only`,
and `status: pass`; it is not render, apply, smoke, package, deploy, or
release readiness.

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
