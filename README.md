# AgentSmith Release Kit

Status: package-driven operator facade plus focused producers and GA aggregate
report.

This repository is the deploy/package evidence home for AgentSmith releases.
It keeps the operator path small: prepare `operator-inputs`, run the
`operator-release.sh` facade, and finish with `ga-release-report.json`.
Maintainer/internal producer diagnostics remain available for evidence
plumbing and troubleshooting, but they are not the operator copy-paste path.

## Canonical Identity

| Field | Value |
| --- | --- |
| Repository | `github.com/agentsmith-project/agentsmith-release-kit` |
| Remote URL | `https://github.com/agentsmith-project/agentsmith-release-kit.git` |
| Default branch | `main` |
| Local bootstrap path | `$WORKSPACE/agentsmith-release-kit` |

The local bootstrap path is a workspace convention only; use this repository
root when working outside that layout. CI and future release evidence must use
the normalized GitHub repository identity.

## Scope

AgentSmith Release Kit consumes:

- AgentSmith release contract.
- AgentSmith deploy template package.
- Operator inputs through `operator-inputs` packages that reference release
  contract, deploy template, render values, use-existing substrate truth,
  target prerequisites, bundle, installer, and probe/loader materials without
  inlining business truth or secrets.

AgentSmith Release Kit owns:

- Online deploy execution.
- Airgap package verification and deployment flow.
- Image bundle, mirror map, and digest adoption checks.
- Kubernetes render, apply, rollout, and smoke evidence.
- Operator runbooks for deployment, package handling, troubleshooting, and
  evidence collection.
- Deployment, distribution, and package evidence produced by this repository.

AgentSmith Release Kit does not own:

- AgentSmith product readiness.
- Visual, backend-real, story, e2e, or product flow validation.
- Product database schema, product bootstrap semantics, product authorization,
  or product UI truth.
- Cloud resource provisioning for clusters, databases, buckets, IAM, networks,
  or OIDC realms.
- A release management UI, dashboard, or DevOps product surface.
- AgentSmith product source, product contracts, product gates, or runner
  runtime implementation.

## Deployment Model

The operator-facing path is a single package-driven facade:

1. Prepare one `operator-inputs` package for the selected deployment path.
2. Execute the package with the operator facade.
3. Repeat for each required path.
4. Generate the final GA report from the four package paths plus AgentSmith
   product-side reports.

```bash
bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <dir>
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --doctor
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --run
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <json> \
  --post-deploy-product-smoke-report <json> \
  --output-dir <dir>
```

Run `--init-operator-inputs` when you want a scaffolded input package for one
deployment path. Run `--doctor` when you want a missing-input checklist
without executing or writing an intake plan. Run the same `--operator-inputs
<dir-or-json>` command without `--run` only when you want package validation
before execution.

The package contains one `operator-inputs.json` for one selected deployment
path. It is not a four-path manifest. The four accepted `deployment_path`
values are:

- `online/use_existing`
- `online/install_substrates`
- `airgap/use_existing`
- `airgap/install_substrates`

The GA operator substrate choices are `use_existing` and
`install_substrates`.

Without `--run`, this slice validates the package, rejects internal producer
vocabulary, secret-looking payloads, missing path-specific inputs, and path
escapes, then prepares an internal execution plan for `--run`. That validation
is not GA evidence, not release readiness, and does not write
`formal_verdict`. Post-deploy smoke reports are runtime evidence and are not
operator-inputs.

With `--doctor`, the facade reports all currently missing package fields for
the selected deployment path and exits without executing producers, issuing a
verdict, or writing the internal plan.

With `--init-operator-inputs <deployment_path> --output-dir <dir>`, the facade
creates a skeleton package for one of the four GA deployment paths and refuses
to overwrite an existing `operator-inputs.json`. The scaffold intentionally
does not prefill explicit deploy/install confirmations.

With `--run`, the current orchestration slice supports `online/use_existing`,
`online/install_substrates`, `airgap/use_existing`, and
`airgap/install_substrates` with `mode: apply`.
`online/use_existing` runs the existing online focused producer chain.
`online/install_substrates` first runs substrate-install, then runs the online
gate bound to the installer output substrate truth. `airgap/use_existing` runs
the existing airgap consume rehearsal, extracts only its nested bundle-check
and airgap deployment-gate reports, then calls the deployment-path finalizer
with bundle-local release contract/deploy package components. It requires
package-local `kubectl`, explicit `context`, package-local archive/image load
tools, and apply smoke inputs. The airgap install path runs substrate-install,
then runs bundle-check plus airgap deployment-gate using bundle-local release
materials and the installer output substrate truth. These paths record
path-level evidence for the release captain/finalizer. Server-dry-run modes
also fail fast. Formal release success or failure is represented only by the
final `ga-release-report.json` issued by the release finalizer/captain after
required path evidence and AgentSmith product-side reports are available.

For `online/install_substrates`, the package must provide namespace-scoped
installer inputs, `kubectl` and `context` inputs, a package-local routability
probe, and an explicit install confirmation; it must not provide package-local
`substrate_truth` because the online gate uses installer-generated truth. For
`airgap/install_substrates`, the package must provide package-local
`kubectl`, `context`, the airgap bundle plus manifest, package-local
archive/image loader probes for apply, and explicit install confirmation; it
uses the installer-generated substrate truth created during the package run
and does not require `routability_probe` or bundle/package `substrate_truth`.

After the four packages have been run, the operator-facing final step is
`operator-release.sh --ga-report` with those four package paths plus the
AgentSmith product readiness and post-deploy product smoke reports. The facade
locates finalized path evidence inside each package and writes the final
`ga-release-report.json`; operators pass package paths, not internal evidence
paths.
A blocked final aggregate overwrites stale pass outputs with `status=fail`,
`formal_verdict=not_issued`, and blockers in that same report.
It also writes `ga-evidence-index.json`, a derived archive index that binds
the final report digest to the path evidence, product readiness, post-deploy
smoke, and blockers without issuing another verdict. The index mirrors the
Product Readiness `runtime_readiness` block, including the runtime
pending/readiness convergence policy for Files, Agent Task sandbox, AFSCP
workspace binding, and read export, and exposes post-deploy product smoke
coverage for archive lookup.
The repository also provides a manual `ga-release-aggregate` GitHub workflow
for release captains. It is `workflow_dispatch` only, downloads the six
already-produced artifacts by repository, run id, and artifact name, runs the
same `operator-release.sh --ga-report` facade, and uploads the final
`ga-release-report.json`, `ga-release-summary.md`, and
`ga-evidence-index.json`. It does not rerun product, deployment, airgap, or
operator package producers.
These paths are still release-kit installer producer/finalizer evidence flows;
they are not cloud provisioning for clusters, databases, buckets, IAM,
networks, or OIDC realms.

Maintainer/internal diagnostics are documented in
`docs/maintainer-diagnostics.md` and `docs/RELEASE_GATES.md`. They are not the
operator main path, not package readiness, not operator readiness, and not a
separate GA signoff surface.

For `airgap`, operators must provide all required tools, templates, artifacts,
and images from inside the target network. Airgap flow must not download from
the public internet. An operator-declared substrate endpoint can be a target
network prerequisite, but this repository does not create cloud resources.
For airgap apply packages, see `docs/runbooks/README.md` "Airgap Tool
Contract": `archive_probe` and `image_loader` are package-local executable
refs with argv, timeout, and sha256 digest stdout checks. This is a local
tool/digest contract, not proof of network isolation.

## Current Verification

Operator package runbook:

```bash
bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <dir>
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --doctor
bash scripts/operator-release.sh --operator-inputs <dir-or-json> --run
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <json> \
  --post-deploy-product-smoke-report <json> \
  --output-dir <dir>
```

Use `--init-operator-inputs` for a scaffolded package, use `--doctor` for a
missing-input checklist, and use `--operator-inputs <dir-or-json>` without
`--run` only for package validation. The package-driven `--run` path writes
finalized deployment-path handoff evidence for the release captain/finalizer
when it executes an apply manifest. It does not issue a formal GA verdict.
Formal release success or failure is issued only by `--ga-report`, which
writes the final `ga-release-report.json`.

### Maintainer/Internal Diagnostics

The focused producer catalog is no longer duplicated in this root README.
Maintainers changing release-kit internals should use
`docs/maintainer-diagnostics.md` for compatibility aliases, command roles, and
manual diagnostics, and `docs/RELEASE_GATES.md` for the full gate contract.
Those references are not the operator copy-paste path, not package readiness,
not operator readiness, and not a separate GA signoff surface.
Legacy compatibility aliases are maintainer/internal only; removal target: release-kit v1.0.0 GA cut.

The root README intentionally keeps the default path to `operator-inputs`,
`scripts/operator-release.sh`, `ga-release-report.json`, and the concise
operator runbook.

## Handoff

After entering this repository, team members must first claim non-overlapping
workstreams:

- Docs.
- Contracts.
- Runbooks.
- CI gate.
- Implementation.

All workstreams are constrained by this README, `AGENTS.md`, `DEVELOPMENT.md`,
and `docs/RELEASE_GATES.md`. GA implementation approval only means the
repo-local team can begin those workstreams; it does not approve deploy
tooling adoption, release evidence, or publishing.
