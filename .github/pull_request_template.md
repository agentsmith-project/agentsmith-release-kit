# Pull Request

## Workstream

- [ ] Docs
- [ ] Contracts
- [ ] Runbooks
- [ ] CI gate
- [ ] Implementation

## Boundary

- [ ] Changes stay inside `agentsmith-release-kit`.
- [ ] No AgentSmith product source, product flow, visual, or backend-real ownership is added.
- [ ] No cloud resource provisioning or release management UI is added.
- [ ] No AFSCP or ASBCP source, contract, or gate dependency is added.
- [ ] No raw secrets or mutable image release claims are added.

## Evidence

- [ ] I confirm the quick gate is bootstrap governance only; it is not release readiness and not a deployment or package verdict.

```bash
bash scripts/verify-release.sh --quick
```

Result:
