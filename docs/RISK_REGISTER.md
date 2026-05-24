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
