# ADR 0001: Bootstrap Boundary

Status: Bootstrap reference; superseded for GA release verdict by
`operator-release.sh --ga-report` / `verify-release.sh --ga-release`
Date: 2026-05-23

## Context

AgentSmith is splitting release execution into a separate release-kit
repository without expanding AgentSmith product scope. The first step should
create a local sibling repository with governance documents and a quick guard
only.

This ADR records the bootstrap boundary only. The current GA boundary is now
defined by the root `README.md`, `docs/runbooks/README.md`,
`docs/RELEASE_GATES.md`, and `docs/contracts/README.md`: release-kit owns
online/airgap deployment execution, path-level evidence, operator runbooks, and
the final GA aggregate report. AgentSmith remains the owner of product
readiness, product contracts, product smoke producer output, visual validation,
backend-real validation, and product bootstrap semantics.

## Decision

Create a bootstrap-only, docs-governance-first skeleton for
`github.com/agentsmith-project/agentsmith-release-kit`.

The skeleton includes:

- Canonical identity.
- Scope and non-goals.
- Contracts, runbooks, and ADR entry points.
- Release gate, runbook, and contract entry points.
- A quick governance guard.
- A release gate entry that fails fast for full release readiness while
  allowing bootstrap quick checks.

The bootstrap quick gate was not release readiness. In the current GA flow,
formal release success or failure is issued only by the final
`ga-release-report.json` from `operator-release.sh --ga-report` /
`verify-release.sh --ga-release`.

## Consequences

Repo-local team members can begin non-overlapping workstreams after bootstrap:
docs, contracts, runbooks, CI gate, and implementation.

No AgentSmith source, AgentSmith deploy tooling, AFSCP source, ASBCP source, or
external gate implementation is copied into this repository during bootstrap.
