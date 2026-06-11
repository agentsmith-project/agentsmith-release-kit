# AgentSmith Release Kit

Status: package-driven operator facade plus final GA aggregate report.

This repository is the deploy/package evidence home for AgentSmith releases.
It keeps the operator path small: prepare `operator-inputs`, run the
`operator-release.sh` facade, and finish with `ga-release-report.json`.

## Canonical Identity

| Field | Value |
| --- | --- |
| Repository | `github.com/agentsmith-project/agentsmith-release-kit` |
| Remote URL | `https://github.com/agentsmith-project/agentsmith-release-kit.git` |
| Default branch | `main` |
| Workspace path | `$WORKSPACE/agentsmith-release-kit` |

The workspace path is a local checkout convention only; use this repository
root when working outside that layout. CI and release evidence must use the
normalized GitHub repository identity.

## Scope

AgentSmith Release Kit consumes:

- AgentSmith release contract.
- AgentSmith deploy template package.
- Operator inputs through `operator-inputs` packages that reference release
  contract, deploy template, render values, use-existing substrate truth,
  target prerequisites, optional online target registry facts, bundle,
  installer, and probe/loader materials without inlining business truth or
  secrets.

AgentSmith Release Kit owns:

- Online deploy execution.
- Airgap package verification and deployment flow.
- Image bundle, mirror map, and digest binding checks.
- Kubernetes render, apply, rollout, and smoke evidence.
- Operator runbooks for deployment, package handling, troubleshooting, and
  evidence collection.
- Deployment and package evidence produced by this repository.

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
  --post-deploy-product-smoke-report <online-json> \
  --post-deploy-product-smoke-report <airgap-json> \
  --output-dir <dir>
```

Run `--init-operator-inputs` when you want a scaffolded input package for one
deployment path. Run `--doctor` when you want missing package refs/fields plus
static package blockers checked without executing the selected path. A passing
doctor only means static package checks passed; it is not runnable readiness
or the final GA result. Add `--run` when the package is ready to execute the
selected path.
When doctor fails, the human output groups blockers as release materials,
operator target facts, operator tools, and operator confirmations before the
raw field list.

The package contains one `operator-inputs.json` for one selected deployment
path. It is not a four-path manifest. The four accepted `deployment_path`
values are:

- `online/use_existing`
- `online/install_substrates`
- `airgap/use_existing`
- `airgap/install_substrates`

The GA operator substrate choices are `use_existing` and
`install_substrates`.
For `online/use_existing` and `online/install_substrates` apply packages, an
operator may set `target_registry` and provide a package-local `registry_probe`
executable. The target registry must already contain digest refs for the
release images; release-kit does not mirror images, push images, or perform
registry login.

Post-deploy smoke reports are runtime evidence and are not operator-inputs.
`site.env` is not an operator-inputs field; the AgentSmith post-deploy product
smoke report binds the deployed site facts for the final GA verifier.

With `--doctor`, the facade reports missing package refs/fields plus static
package blockers for the selected deployment path and exits without executing
the selected path.

With `--init-operator-inputs <deployment_path> --output-dir <dir>`, the facade
creates a skeleton package for one of the four GA deployment paths and refuses
to overwrite an existing `operator-inputs.json`. The scaffold intentionally
does not prefill explicit deploy/install confirmations. Scaffold scalar
placeholders such as `context: replace-with-kube-context` and
`smoke_url: https://agentsmith.example.com/healthz` must be replaced; doctor
treats them as blockers.

With `--run`, the current orchestration slice supports `online/use_existing`,
`online/install_substrates`, `airgap/use_existing`, and
`airgap/install_substrates`.
`online/use_existing` executes the selected online path.
`online/install_substrates` first runs substrate-install, then deploys with the
installer output substrate truth. Airgap paths use bundle-local release
materials plus package-local `kubectl`, archive/image tooling, and smoke
inputs. Each package run records the output later consumed by `--ga-report`.
Final release pass/fail is represented only by `ga-release-report.json`, which
`--ga-report` writes after the required package outputs and AgentSmith
product-side reports are available.

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
AgentSmith product readiness and post-deploy product smoke reports. Provide at
least one online and one airgap post-deploy product smoke report. The facade
locates the package output itself and writes the final
`ga-release-report.json`; operators pass package paths, not internal report
paths.
The final aggregate also checks that each smoke report's substrate truth
digest matches the finalized deployment truth for the package it is bound to;
smoke evidence from a different deployed substrate blocks GA.
When blocked, the final report records the failed result and blockers.
The repository also provides a manual `ga-release-aggregate` GitHub workflow
for final aggregation. It is `workflow_dispatch` only, downloads the seven
already-produced operator/product artifact groups by repository, artifact
name, the operator package run id, and separate AgentSmith Product Readiness /
online smoke / airgap smoke run ids. It runs the
same `operator-release.sh --ga-report` facade, and uploads the final
operator report plus archive attachments. It does not rerun product,
deployment, airgap, or operator package producers.
These paths are still release-kit installer and package evidence flows;
they are not cloud provisioning for clusters, databases, buckets, IAM,
networks, or OIDC realms.

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
  --post-deploy-product-smoke-report <online-json> \
  --post-deploy-product-smoke-report <airgap-json> \
  --output-dir <dir>
```

Use `--init-operator-inputs` for a scaffolded package, use `--doctor` for
missing package refs/fields plus static package blockers, and add `--run` when
the package is ready to execute.
The package-driven `--run` path records package output for the final GA report.
It does not write the final GA result. Final release pass/fail is written only
by `--ga-report` in `ga-release-report.json`.

### Maintainer/Internal Diagnostics

Maintainer/internal producer diagnostics remain available for evidence plumbing
and troubleshooting, but they are not the operator copy-paste path.

The focused producer catalog is no longer duplicated in this root README.
Maintainers changing release-kit internals should use
`docs/maintainer-diagnostics.md` for compatibility aliases, command roles, and
manual diagnostics, and `docs/RELEASE_GATES.md` for the full gate contract.
Those references are not the operator copy-paste path, not package readiness,
not operator readiness, and not a separate GA signoff surface.
Legacy compatibility aliases are maintainer/internal only; removal target: release-kit v1.0.0 GA cut.

Archive attachments written next to the final report are maintainer/reference
artifacts, not operator results. The operator-facing result remains
`ga-release-report.json`.

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
