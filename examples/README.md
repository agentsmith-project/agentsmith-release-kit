# Operator Input Examples

Copy one directory per GA operator path, replace placeholder release artifacts
and environment values, then run the package-driven facade.

Each example directory is already bound to one deployment path. Keep
`deployment_path` set to the example value; choose a different example
directory when you need a different deployment path. Replace release artifacts,
endpoint values, namespace, secret refs, package-local tool paths, and explicit
confirmations. Do not add extra deployment selection fields to the truth or
install-input files.

```bash
bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <staged-example-package>
bash scripts/operator-release.sh --operator-inputs <staged-example-package> --doctor
bash scripts/operator-release.sh --operator-inputs <staged-example-package> --run
```

Run `--init-operator-inputs` to create a fresh package skeleton, then copy or
replace the example materials. Run `--doctor` to list missing package
refs/fields plus static package blockers before execution. A passing doctor
only means package static intake is clean; it is not runnable readiness or a GA
verdict. When doctor fails, the human output groups blockers as release
materials, operator target facts, operator tools, and operator confirmations.
Run `--run` only when the package is ready to execute.
Replace scaffold scalar placeholders such as
`context: replace-with-kube-context` and
`smoke_url: https://agentsmith.example.com/healthz`; doctor keeps them as
blockers until replaced.

Available examples:

- `online-use-existing/`: `online/use_existing`
- `online-install-substrates/`: `online/install_substrates`
- `airgap-use-existing/`: `airgap/use_existing`
- `airgap-install-substrates/`: `airgap/install_substrates`

Both online examples also include optional
`operator-inputs.target-registry.apply.example.json` variants for package-local
read-only registry probes. The target registry must already contain digest refs
for the release images.

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
  --post-deploy-product-smoke-report <online-json> \
  --post-deploy-product-smoke-report <airgap-json> \
  --output-dir <dir>
```

The final operator-facing artifact is `ga-release-report.json`.
`site.env` is not an operator-inputs field; it is bound through the
AgentSmith post-deploy product smoke report used by the final GA verifier.
