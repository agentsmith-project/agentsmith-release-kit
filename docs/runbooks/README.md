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

Current focused image-map runbook note: use `bash scripts/verify-release.sh
--image-map` to produce `image-map.json` from a release contract before online
or airgap registry work. Online can omit `--target-registry` to use source
digest refs directly. Airgap requires `--target-registry` with
`<registry-host[/namespace]>`; namespace components must be lowercase and must
start and end with alphanumeric characters. The output is a mirror plan only;
it is not evidence that images already exist in that registry.

Current focused airgap bundle check runbook note: use `bash
scripts/verify-release.sh --airgap-bundle-check` only for a local
manifest/digest check of an already assembled bundle directory. The bundle
manifest must use `schema_version:
agentsmith.airgap-bundle-manifest/v1`; `components` must name exactly one
`kind` each for `release_contract`, `deploy_template_package`,
`deploy_template_archive`, and `image_map`. The deploy template archive sha256
must match `deploy_template_package.package_sha256`,
`artifact_provenance.artifact_sha256`, and
`bundle_manifest.bindings.deploy_template_archive_sha256`; image artifact
declarations must match the airgap image-map mappings one-to-one by id. The
release contract must include the
`existing_kubernetes/external_declared/airgap` target profile with
`required: boolean`, and the bundle manifest must use only the documented
manifest fields. This check validates safe relative paths and sha256 values
only. It is not a packager, does not parse the `.tgz`, does not create an
airgap package, does
not call Docker, skopeo, oras, kubectl, pull, push, mirror, save, or load
images, does not prove registry presence, image load, offline install
readiness, deploy readiness, package readiness, or release readiness, and does
not support online or kind targets.

Current focused route smoke runbook note: use `bash scripts/verify-release.sh
--smoke` only after a passing focused `rollout-report.json`. Supply an HTTPS
URL by default; local HTTP is reserved for focused tests with explicit
`--allow-http --allow-localhost`. Do not add custom headers or tokens.

Current focused online deployment gate note: use `bash scripts/verify-release.sh
--online-deployment-gate` when an operator wants one KISS command to run the
online focused chain. Default mode is server-side dry-run and does not run
rollout or smoke. Confirmed apply requires exact confirm text and an operator
run id; smoke is optional and only runs after rollout. This is not airgap,
kind rehearsal, image mirroring, rollback, deploy readiness, or release
readiness.

Runbooks must avoid raw secrets. They should describe secret refs, redacted
fingerprints, prerequisites, and explicit operator inputs.
