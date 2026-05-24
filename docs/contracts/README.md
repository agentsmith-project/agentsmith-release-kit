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

The current `--render-check` validator is a focused rendered manifest image
inventory diagnostic only. It consumes the release contract and an explicit
rendered manifest directory; it does not consume AgentSmith source paths or
declare release readiness. It binds Deployment, StatefulSet, DaemonSet,
ReplicaSet, Job, CronJob, and Pod `containers` and `initContainers` images to
`deploy_image_inventory` by exact image ref or digest, rejects legacy target
profile values, and writes `render-report.json` with `readiness: false` and
`scope: render_check_image_inventory_only`. The report must not include
AgentSmith product-flow fields, `verdict`, or `release_verdict`.

The current `--evidence` validator is a focused release-kit evidence envelope
intake diagnostic only. It requires `evidence.json` and
`evidence-subject.json`, binds them to the supplied release contract raw
sha256, release id, git sha, and explicit target profile, and writes
`evidence-validation-report.json` with `readiness: false` and
`scope: release_kit_evidence_intake_only`. The raw envelope uses
`agentsmith.release-kit-evidence-envelope/v1`; AgentSmith
`agentsmith.release-kit-evidence/v1` remains its adapter/canonical evidence
shape. The evidence `git_sha` is the AgentSmith product release commit;
`artifact_provenance.commit_sha` is the release-kit producer commit and is not
required to equal it. The subject file entry for `evidence.json` must use the
canonical evidence body without `artifact_provenance` as its listed sha256. All
other subject file entries use their raw file sha256. This prevents
`artifact_provenance.subject_sha256` from self-referencing the evidence file
that carries it. AgentSmith `product_flows` and `product_flow_results` remain
AgentSmith-produced evidence and are rejected here.

The current `--target-preflight` validator is a focused substrate connection
truth intake diagnostic only. It accepts only
`agentsmith.substrate-connection.truth/v1`, rejects Docker substrate truth and
legacy target names, and binds the truth document to the supplied
`target_cluster/substrate_source/distribution` tuple. It writes
`target-preflight-report.json` with `readiness: false` and
`scope: target_preflight_intake_only`. It validates declarations for required
substrate services, endpoints, secret refs or redacted fingerprints, TLS or
sslmode, PostgreSQL vector extension truth, OIDC, object storage, and
reachability fields. It does not connect to Kubernetes, render, apply, smoke,
package, deploy, or claim release readiness.

Future contracts should cover:

- Release contract input validation.
- Deploy template package input validation.
- Substrate connection truth validation.
- Evidence subject and provenance validation.
- Image inventory and digest adoption validation.
- Airgap bundle manifest validation.

AFSCP and ASBCP can be cited as family-style governance references only. This
repo must not depend on their source trees, contract files, or gate scripts.
