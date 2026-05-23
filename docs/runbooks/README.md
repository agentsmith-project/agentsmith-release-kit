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

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
