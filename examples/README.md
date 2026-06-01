# Operator Input Examples

Copy one directory per GA operator path, replace placeholder release artifacts
and environment values, then run the package-driven facade.

```bash
bash scripts/operator-release.sh --operator-inputs <staged-example-package>
```

Available examples:

- `online-existing-kubernetes/`: `online/use_existing`
- `online-install-substrates/`: `online/install_substrates`
- `airgap-use-existing/`: `airgap/use_existing`
- `airgap-install-substrates/`: `airgap/install_substrates`

After all four packages have been run with `--run` and AgentSmith
product-side reports are available, use the final GA facade with the four
package paths. Operators do not pass internal deployment path report files.

