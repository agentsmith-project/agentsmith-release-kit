# AGENTS.md

Guidance for coding agents working in `agentsmith-release-kit`.

## Repository Boundary

This repository is the AgentSmith release kit. Work here only inside
`/home/percy/works/mbos-v1/agentsmith-release-kit`.

Do not modify sibling repositories while working from this repo. In particular,
do not edit `agentsmith`, `agentsmith-fs-control-plane`, `mbos-sandbox-v1`, or
any other sibling repo unless the user explicitly gives a separate task for
that repository.

## Bootstrap Status

Current status is bootstrap-only, docs-governance-first. The repository has
identity, boundary docs, a quick guard, and placeholder documentation entries.
It does not yet have deploy, package, airgap, render, apply, smoke, mirror, or
release-readiness implementation.

## Scope

This repository consumes AgentSmith release contract artifacts, deploy template
packages, and operator inputs. It is responsible for online deployment,
airgap package/deploy flows, Kubernetes render/apply/smoke execution,
operator runbooks, and deployment/package evidence.

This repository does not own AgentSmith product readiness, visual validation,
backend-real validation, product flows, product database/bootstrap semantics,
cloud resource provisioning, release management UI, product contracts, or
AgentSmith source code.

`kind_rehearsal` is a rehearsal target only. Treat real Kubernetes evidence and
kind rehearsal evidence as different evidence lines.

## Governance Rules

- Keep implementation KISS and fail fast.
- Prefer bash, grep, and find for bootstrap guards.
- Do not add npm, Python, Go, or other package ecosystems until a future
  implementation workstream has a concrete need.
- Do not import or read AgentSmith product source at runtime.
- Do not depend on AFSCP or ASBCP source, contracts, or release gates.
- Do not persist raw secrets. Store only secret references, redacted
  fingerprints, and minimum diagnostic fields.
- Formal image and artifact claims must be digest-bound and provenance-bound.
- Quick gate success is never release readiness.

## Workstream Handoff

Repo-local team members must first claim one non-overlapping workstream:

- Docs.
- Contracts.
- Runbooks.
- CI gate.
- Implementation.

Each workstream must stay inside the boundary defined by `README.md`,
`DEVELOPMENT.md`, and `docs/RELEASE_GATES.md`. Cross-workstream changes need a
clear handoff note in the pull request.

## Verification

Bootstrap verification:

```bash
bash scripts/verify-release.sh --quick
```

The full release gate is intentionally unavailable during bootstrap. If a task
needs release readiness, stop and define the future repo-local release gate
before claiming readiness.
