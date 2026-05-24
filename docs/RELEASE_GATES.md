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

## Evidence Envelope Focused Diagnostic

Run:

```bash
bash scripts/test-evidence.sh
```

This focused guard exercises `bash scripts/verify-release.sh --evidence`. It
checks only the release-kit evidence envelope shape for an evidence root that
already exists. The root must contain `evidence.json` and
`evidence-subject.json`.

The check verifies the release contract raw sha256, release identity, exact
target profile axes, `passed`/`failed` status and failure-class pairing,
release-kit provenance, subject file digests, subject path safety, and
redaction/source scans for the envelope and subject files. It rejects legacy or
synonym target values, AgentSmith product-flow fields, local provenance URIs,
absolute paths, `..` escapes, symlinks, hardlinks, and obvious secret payloads.
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
