# Development Guide

Status: bootstrap-only.

## Local Setup

No package manager setup is required for the bootstrap skeleton.

Use:

```bash
bash scripts/verify-release.sh --quick
```

There is intentionally no `package.json` in this repository.

## Development Principles

- Contract first, but do not copy AgentSmith product contracts into this repo.
- Keep deployment and package execution separate from AgentSmith product
  readiness.
- Fail fast when required inputs are missing, ambiguous, mutable, or not
  provenance-bound.
- Treat operator inputs as explicit truth. Do not guess local paths, Docker
  defaults, cloud resources, or product source locations.
- Keep secrets out of files, logs, and evidence. Use secret refs and redacted
  fingerprints.

## Inputs

Future implementation must consume only explicit inputs:

- AgentSmith release contract.
- AgentSmith deploy template package.
- Operator target inputs.
- Operator declared substrate connection truth.
- Operator registry and namespace inputs.

The release kit must not infer those inputs from a sibling checkout.

## Non-Goals

This repo does not implement or validate:

- AgentSmith product readiness.
- Visual review.
- Backend-real product validation.
- Product flows.
- Product database/bootstrap semantics.
- Cloud resource provisioning.
- Release management UI.
- Runner runtime.

## Deployment Profiles

`existing_kubernetes` is the real deployment target family.
`kind_rehearsal` is only local or CI rehearsal.

Future work must keep target cluster, substrate source, and distribution as
separate choices:

- `target_cluster`: `existing_kubernetes` or `kind_rehearsal`.
- `substrate_source`: `external_declared` or `kit_installed`.
- `distribution`: `online` or `airgap`.

## Workflow

1. Claim a non-overlapping workstream: docs, contracts, runbooks, CI gate, or
   implementation.
2. Keep changes inside this repo.
3. Add focused checks before expanding behavior.
4. Run the quick gate for bootstrap boundary changes.
5. Do not claim release readiness until a future full release gate exists and
   passes.
