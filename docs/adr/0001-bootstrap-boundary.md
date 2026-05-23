# ADR 0001: Bootstrap Boundary

Status: Accepted
Date: 2026-05-23

## Context

AgentSmith is splitting release execution into a separate release-kit
repository without expanding AgentSmith product scope. The first step should
create a local sibling repository with governance documents and a quick guard
only.

The release kit should eventually own online deployment, airgap package/deploy
flows, operator runbooks, and deployment/package evidence. AgentSmith remains
the owner of product readiness, product contracts, product flows, visual
validation, backend-real validation, and product bootstrap semantics.

## Decision

Create a bootstrap-only, docs-governance-first skeleton for
`github.com/agentsmith-project/agentsmith-release-kit`.

The skeleton includes:

- Canonical identity.
- Scope and non-goals.
- Contracts, runbooks, and ADR entry points.
- Readiness evidence and risk register entry points.
- A quick governance guard.
- A release gate entry that fails fast for full release readiness while
  allowing bootstrap quick checks.

The quick gate is not release readiness. The full release gate will be a future
repo-local authority.

## Consequences

Repo-local team members can begin non-overlapping workstreams after bootstrap:
docs, contracts, runbooks, CI gate, and implementation.

No AgentSmith source, AgentSmith deploy tooling, AFSCP source, ASBCP source, or
external gate implementation is copied into this repository during bootstrap.
