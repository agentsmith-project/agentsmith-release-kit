# Operator Input Examples

Copy one directory per GA operator path, replace placeholder release artifacts
and environment values, then run the package-driven facade.

```bash
bash scripts/operator-release.sh --operator-inputs <staged-example-package> --run
```

Run the same command without `--run` only when you want package validation
before execution.

Available examples:

- `online-existing-kubernetes/`: `online/use_existing`
- `online-install-substrates/`: `online/install_substrates`
- `airgap-use-existing/`: `airgap/use_existing`
- `airgap-install-substrates/`: `airgap/install_substrates`

After all four packages have been run with `--run` and AgentSmith
product-side reports are available, use the final GA facade with the four
package paths. Operators do not pass internal deployment path report files.

```bash
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <json> \
  --post-deploy-product-smoke-report <json> \
  --output-dir <dir>
```

The final operator-facing artifact is `ga-release-report.json`.
