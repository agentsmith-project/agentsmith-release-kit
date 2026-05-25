# Risk Register

Status: bootstrap ledger.

| ID | Risk | Status | Mitigation |
| --- | --- | --- | --- |
| R-001 | Quick gate could be mistaken for release readiness. | Open | `docs/RELEASE_GATES.md` and `scripts/verify-release.sh` state that full readiness is not implemented. |
| R-002 | Release kit could drift into AgentSmith product ownership. | Open | README, AGENTS, and DEVELOPMENT define product readiness, visual, backend-real, and product flows as non-goals. |
| R-003 | Future implementation could infer inputs from sibling source paths. | Open | Quick guard blocks AgentSmith product source imports and sibling source paths. |
| R-004 | Future evidence could leak raw secrets. | Open | Quick guard blocks common raw secret placeholders; future evidence checks must expand this. |
| R-005 | Kind rehearsal could be treated as real deployment evidence. | Open | Docs state that kind is rehearsal only and does not replace real Kubernetes evidence. |
| R-006 | Apply-only diagnostics could be mistaken for deploy or release readiness. | Open | `--apply` writes `readiness: false`, uses `scope: kubernetes_apply_only`, and docs state it excludes rollout, smoke, and product flows. |
| R-007 | A real apply could be run accidentally when an operator expected dry-run. | Open | Default mode is server-side dry-run; real apply requires `--mode apply`, exact `--confirm-apply` target text, and `--operator-run-id`. |
| R-008 | Rollout/live digest diagnostics could be mistaken for full deploy or release readiness. | Open | `--rollout` writes `readiness: false`, uses `scope: kubernetes_rollout_imageid_only`, accepts only `existing_kubernetes/external_declared/online`, and docs state it excludes smoke, product flows, and operator signoff. |
| R-009 | Route smoke diagnostics could leak endpoint secrets or be mistaken for product readiness. | Open | `--smoke` supports no custom headers or tokens, records no response body or raw headers, writes `readiness: false` with `scope: route_smoke_only`, binds a passing rollout report first, and docs state it excludes product flows and release readiness. |
| R-010 | Image-map diagnostics could be mistaken for completed registry mirroring or airgap package readiness. | Open | `--image-map` writes `readiness: false`, uses `scope: image_map_only`, never logs in to a registry or pulls/pushes images, and docs state that it is only a digest-pinned mirror plan. |
| R-011 | Online deployment gate runner could be mistaken for full deploy or release readiness. | Open | `--online-deployment-gate` writes `readiness: false`, uses `scope: online_deployment_gate_only`, only sequences focused diagnostics, and docs state it excludes cloud provisioning, image mirroring, airgap, kind, rollback, product flows, and release readiness. |
| R-012 | Airgap bundle manifest/digest diagnostics could be mistaken for package creation or offline install readiness. | Open | `--airgap-bundle-check` writes `readiness: false`, uses `scope: airgap_bundle_manifest_check_only`, accepts only `existing_kubernetes/external_declared/airgap`, requires the deploy template artifact sha256 to match the archive, checks only documented manifest fields, local manifest paths, and declared file sha256 values, and docs state it does not parse the `.tgz`, create a package, call Docker, skopeo, oras, kubectl, pull, push, mirror, save, or load images. |
