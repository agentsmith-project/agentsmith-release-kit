# Runbooks

Status: bootstrap placeholder.

This directory is the future home for operator runbooks.

Expected future runbook areas:

- Existing Kubernetes online deployment.
- Existing Kubernetes airgap deployment.
- Airgap bundle verification and load.
- Image mirror and digest adoption checks.
- Substrate connection truth validation.
- Rollout, route smoke, and evidence collection.
- Troubleshooting and rollback.
- `kind_rehearsal` for local or CI rehearsal only.

Current focused route smoke runbook note: use `bash scripts/verify-release.sh
--smoke` only after a passing focused `rollout-report.json`. Supply an HTTPS
URL by default; local HTTP is reserved for focused tests with explicit
`--allow-http --allow-localhost`. Do not add custom headers or tokens.

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
