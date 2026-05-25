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

The current `--render` validator is a focused materialized template render
diagnostic only. Optional `--image-map <json>` must be a passing
`agentsmith.image-map/v1` report with `scope: image_map_only`,
`readiness: false`, matching release contract digest and target profile axes,
and one valid mapping per `deploy_image_inventory` item. Render adopts
`mapping.target_image` for image placeholders only; it does not mirror images,
handle registry credentials, or prove registry presence.

The current `--render-check` validator is a focused rendered manifest image
inventory diagnostic only. It consumes the release contract and an explicit
rendered manifest directory; it does not consume AgentSmith source paths or
declare release readiness. It binds Deployment, StatefulSet, DaemonSet,
ReplicaSet, Job, CronJob, and Pod `containers` and `initContainers` images to
`deploy_image_inventory` by exact image ref or digest, rejects non-canonical
pre-GA target profile names, and writes `render-report.json` with
`readiness: false` and `scope: render_check_image_inventory_only`. The report
must not include AgentSmith product-flow fields, `verdict`, or
`release_verdict`.

The current `--image-map` validator is a focused image-map / mirror-plan
diagnostic only. It consumes only `release_contract.deploy_image_inventory`
from the supplied release contract and an explicit target profile. It accepts
existing Kubernetes canonical profiles as CLI targets:
`existing_kubernetes/external_declared/online`,
`existing_kubernetes/external_declared/airgap`,
`existing_kubernetes/kit_installed/online`, and
`existing_kubernetes/kit_installed/airgap`.
`kind_rehearsal/kit_installed/online` is a canonical profile tuple but out of
scope for image-map CLI. Only canonical profile tuples are accepted in
`release_contract.target_profiles`; non-canonical pre-GA target names and
synonym axes fail fast. It requires airgap runs to provide
`--target-registry <registry-host[/namespace]>`. Every inventory image must be
digest-pinned with a matching `digest` field, and duplicate ids, images, or
digests fail fast. It writes `image-map.json` with `schema:
agentsmith.image-map/v1`, `readiness: false`, and `scope: image_map_only`.
The report is a plan for source/target digest references only; it must not
claim registry presence, deploy readiness, package readiness, release
readiness, product-flow evidence, or registry credential handling.

The current `--bundle-create` validator is a focused local airgap assembler
and self-check only. It accepts only
`existing_kubernetes/external_declared/airgap`, reuses the existing inputs,
template-package, image-map, and airgap bundle-check validators, and writes a
bundle manifest matching `agentsmith.airgap-bundle-manifest/v1`. It creates a
fixed local structure under `components/`, `images/`, `payload/`, optional
`tools/`, and root `airgap-bundle-manifest.json`; image archive ids must match
the generated image-map mappings one-to-one. Its
`bundle-create-report.json` uses `schema:
agentsmith.airgap-bundle-create-report/v1`, `readiness: false`, and `scope:
airgap_bundle_create_only`, and contains only count/digest summaries. It is
not a release-kit evidence envelope output and must not claim registry
presence, image load, offline install, deploy, package, or release readiness.

The current `--airgap-bundle-check` validator is a focused local bundle
manifest/digest diagnostic only. It consumes an explicit release contract,
deploy template package descriptor, deploy template archive `.tgz`, airgap
image-map, bundle root, and bundle manifest, and accepts only
`existing_kubernetes/external_declared/airgap`. `kit_installed` airgap profiles
may be declared in the release contract but are not bundle-check CLI targets in
this slice. The deploy template archive
sha256 must match `deploy_template_package.package_sha256` and
`deploy_template_package.artifact_provenance.artifact_sha256`. The bundle
manifest must use `schema_version:
agentsmith.airgap-bundle-manifest/v1`; its `components` array must contain
exactly one component of each `kind`: `release_contract`,
`deploy_template_package`, `deploy_template_archive`, and `image_map`.
`bundle_manifest.bindings.deploy_template_archive_sha256` must match the
archive sha256. Component paths and image artifact paths must be POSIX-style
relative paths under the bundle root, and sha256 values must match the
referenced files. The release contract must declare
`existing_kubernetes/external_declared/airgap` in `target_profiles`, each
target profile entry must carry `required: false` during pre-GA, and
`support_level` is rejected. The bundle manifest accepts only the documented
top-level, `bindings`, `components`, `image_artifact_declarations`,
`payload_artifacts`, `operator_prerequisites`, and `substrate` fields. Image
artifact declarations must match image-map mappings one-to-one by id. The
image-map must be airgap, `mirror_required: true`, and every mapping must use
`action: mirror_required`; mapping ids, source images, and source digests must
match `release_contract.deploy_image_inventory`, target digests must equal
source digests, and target images must be under `image_map.target_registry`
with `@<target_digest>`.

`payload_artifacts[]` allows only `id`, `kind`, `path`, and `sha256`. Allowed
kinds are `runbook`, `script`, `profile_values_schema`,
`profile_values_example`, and `checksums`; `runbook`, `script`,
`profile_values_schema`, and `checksums` are required. Payload paths use the
same safe bundle-root relative file and sha256 checks. `operator_prerequisites`
allows only `substrate_connection_truth_ref`, `target_registry_proof_ref`, and
`tools`. Bundled tools allow only `name`, `version`, `source`, `path`, and
`sha256`; operator prerequisite tools allow only `name`, `version`, `source`,
`location`, and `proof`. Operator refs, locations, and proofs are strings, not
bundle files, and URI schemes, public-download semantics, and secret-looking
content are rejected. It writes
`airgap-bundle-check-report.json` with `schema:
agentsmith.airgap-bundle-check-report/v1`, `readiness: false`, and `scope:
airgap_bundle_manifest_check_only`. The report may include only non-sensitive
payload/tool counts, not raw paths, refs, locations, or proofs. This is
manifest/digest check only; it is
not a packager, does not parse the `.tgz`, does not create an airgap package,
does not call Docker, skopeo, oras, kubectl, pull, push, mirror, save, or load
images, and does not prove registry presence, image load, offline install
readiness, deploy readiness, package readiness, or release readiness.

The current `--rollout` validator is a focused Kubernetes rollout/live digest
diagnostic only. It consumes the release contract, an already-rendered manifest
directory, explicit target profile `existing_kubernetes/external_declared/online`,
namespace, and Kubernetes client options. It first runs the render/check guard,
then accepts only Deployment, StatefulSet, and DaemonSet workloads, runs
`kubectl rollout status`, reads `spec.selector.matchLabels` through
`kubectl get <kind>/<name> -o json`, and checks live pod `imageID` or `image`
digests only from `kubectl get pods --selector <selector> -o json` for that
workload. It writes `rollout-report.json` with `schema:
agentsmith.kubernetes-rollout-report/v1`, `readiness: false`, and `scope:
kubernetes_rollout_imageid_only`. The report uses
`observed_live_image_digest_summary` and must not include AgentSmith
product-flow fields, raw kubectl stdout/stderr, kubeconfig content, `verdict`,
`release_verdict`, or deploy readiness fields.

The current `--smoke` validator is a focused route/service smoke diagnostic
only. It consumes the release contract, a prior rollout report, explicit target
profile `existing_kubernetes/external_declared/online`, one URL, and an output
directory. It does not call Kubernetes, render, apply, roll out workloads, or
run product flows. It requires the rollout report to have `status: pass`,
`readiness: false`, `scope: kubernetes_rollout_imageid_only`, and matching
release id, git sha, release contract digest, and target profile. URLs are
HTTPS-only by default and must not include userinfo, query, hash, localhost,
127.x, `::1`, or `host.docker.internal`. It writes `smoke-report.json` with
`schema: agentsmith.route-smoke-report/v1`, `readiness: false`, and `scope:
route_smoke_only`. The report records only normalized route/status/duration
and release/rollout digests; it must not include response bodies, raw headers,
custom token payloads, product-flow fields, `verdict`, `release_verdict`, or
deploy readiness fields.

The current `--online-deployment-gate` validator is a focused online
orchestration runner only. It accepts only
`existing_kubernetes/external_declared/online`, calls existing validators in
order, and writes `online-deployment-gate-report.json` with `schema:
agentsmith.online-deployment-gate/v1`, `readiness: false`, and `scope:
online_deployment_gate_only`. Default mode stops after server-side dry-run
apply; confirmed apply runs rollout and optional smoke. When
`--target-registry <registry-host[/namespace]>` is supplied, it first generates
an image-map and passes it to render for image reference adoption only. The
report lists only step names, relative report paths, and a capability map keyed
only by `existing_kubernetes/external_declared/online`. Confirmed apply may
optionally write a release-kit evidence root from explicit remote provenance
and then validate it through `--evidence`; this emits exactly three managed
evidence-root files: `evidence.json`, `evidence-subject.json`, and
`online-deployment-gate-report.json`. For this output,
`evidence_subject.files` contains exactly two subject entries:
`evidence.json` and `online-deployment-gate-report.json`; it does not list
`evidence-subject.json`. It must not claim deploy readiness, release
readiness, product-flow evidence, rollback, image mirroring, airgap packaging,
or registry credential handling.

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
required to equal it. The raw envelope must include `release_kit_output` as
`deploy-result.json#substrate`, `image-map.json`,
`online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json+airgap-bundle-manifest.json`; release-kit must
not output AgentSmith product-flow evidence. Render, rollout, and smoke reports
remain individual focused diagnostic files, but their combinations are not
accepted release-kit evidence envelope outputs. `evidence_subject.files` must
contain only subject entries for `evidence.json` plus the mapped output files:
`deploy-result.json`, `image-map.json`, `online-deployment-gate-report.json`, or
`airgap-bundle-check-report.json` plus `airgap-bundle-manifest.json`.
Artifact provenance uses `subject_name: release-kit-evidence-subject`.
`external_declared` envelopes must include inline neutral
`substrate_connection_truth`. The subject file
entry for `evidence.json` must use the
canonical evidence body without `artifact_provenance` as its listed sha256. All
other subject file entries use their raw file sha256. This prevents
`artifact_provenance.subject_sha256` from self-referencing the evidence file
that carries it. AgentSmith `product_flows` and `product_flow_results` remain
AgentSmith-produced evidence and are rejected here.

The current `--target-preflight` validator is a focused substrate connection
truth intake diagnostic only. It accepts only
`agentsmith.substrate-connection.truth/v1`, rejects Docker substrate truth and
non-canonical pre-GA target names, and binds the truth document to the supplied
`target_cluster/substrate_source/distribution` tuple. It writes
`target-preflight-report.json` with `readiness: false` and
`scope: target_preflight_intake_only`. It validates declarations for required
substrate services, canonical endpoints (`host` for
PostgreSQL/MongoDB/Redis, `url` or `endpoint` plus `region` and `bucket` for
object storage, and `issuer_url` for OIDC), secret refs or redacted
fingerprints, TLS or sslmode, `extensions.pgvector.status: installed`, and
reachability status `declared_reachable` or `verified_by_operator`. It does
not connect to Kubernetes, render, apply, smoke, package, deploy, or claim
release readiness.

Future contracts should cover:

- Release contract input validation.
- Deploy template package input validation.
- Substrate connection truth validation.
- Evidence subject and provenance validation.
- Image inventory and digest adoption validation.
- Airgap bundle manifest validation.

AFSCP and ASBCP can be cited as family-style governance references only. This
repo must not depend on their source trees, contract files, or gate scripts.
