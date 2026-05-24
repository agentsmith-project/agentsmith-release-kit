# Contracts

Status: bootstrap placeholder.

This directory is the future home for release-kit-owned contract documents and
schemas.

The release kit consumes AgentSmith release contract artifacts and AgentSmith
deploy template packages. It must not copy AgentSmith product contracts or
infer product truth from source paths.

The current `--inputs` validator is a focused contract intake diagnostic only.
Its reports keep `readiness: false` and prove contract/input digest readiness,
not deploy, package, or release readiness.

The current `--template-package` validator is a focused materialized archive
intake diagnostic only. It confirms that the deploy template package descriptor
matches the release contract and that the `.tgz` archive matches the declared
package and manifest digests. Its report keeps `readiness: false` and does not
claim render, deploy, package, or release readiness.

The current `--evidence` validator is a focused release-kit evidence envelope
intake diagnostic only. It requires `evidence.json` and
`evidence-subject.json`, binds them to the supplied release contract raw
sha256, release id, git sha, and explicit target profile, and writes
`evidence-validation-report.json` with `readiness: false` and
`scope: release_kit_evidence_intake_only`. The evidence `git_sha` is the
AgentSmith product release commit; `artifact_provenance.commit_sha` is the
release-kit producer commit and is not required to equal it. The subject file
entry for `evidence.json` must use the canonical evidence body without
`artifact_provenance` as its listed sha256. All other subject file entries use
their raw file sha256. This prevents `artifact_provenance.subject_sha256` from
self-referencing the evidence file that carries it. AgentSmith `product_flows`
and `product_flow_results` remain AgentSmith-produced evidence and are rejected
here.

Future contracts should cover:

- Release contract input validation.
- Deploy template package input validation.
- Substrate connection truth validation.
- Evidence subject and provenance validation.
- Image inventory and digest adoption validation.
- Airgap bundle manifest validation.

AFSCP and ASBCP can be cited as family-style governance references only. This
repo must not depend on their source trees, contract files, or gate scripts.
