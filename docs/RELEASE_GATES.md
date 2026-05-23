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
- Scope and non-goals are declared.
- Release gate entry exists and states that quick is not release readiness.
- No AgentSmith product source import or relative product source path is used.
- No AFSCP or ASBCP source, contract, or gate dependency is used.
- No raw secret placeholder is present.
- No mutable image or non-digest release claim is present.

Passing the quick gate means repo-local workstreams can proceed. It does not
approve deploy tooling, package output, evidence, publishing, or adoption.

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
