# Online Install Substrates Example

This directory is a minimal operator input pack template for
`online/install_substrates`: install namespace-scoped kit substrates, then
deploy AgentSmith online using the installer-generated substrate truth.

Secrets stay outside the package. Use `secretRef:` values only.

## Build The Package

```bash
RELEASE_CONTRACT="release-contract.json"
DEPLOY_TEMPLATE_PACKAGE="deploy-template-package.json"
DEPLOY_TEMPLATE_ARCHIVE="agentsmith-deploy-template-package.tgz"
EXAMPLE_DIR="examples/online-install-substrates"
PKG="out/operator-inputs/online-install-substrates"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp "$EXAMPLE_DIR/render-values.example.json" "$PKG/render-values.example.json"
cp "$EXAMPLE_DIR/target-prerequisites.example.json" "$PKG/target-prerequisites.example.json"
cp "$EXAMPLE_DIR/substrate-pack-manifest.example.json" "$PKG/substrate-pack-manifest.example.json"
cp "$EXAMPLE_DIR/substrate-install-inputs.example.json" "$PKG/substrate-install-inputs.example.json"
cp -R "$EXAMPLE_DIR/tools" "$PKG/tools"
cp "$RELEASE_CONTRACT" "$PKG/release-contract.json"
cp "$DEPLOY_TEMPLATE_PACKAGE" "$PKG/deploy-template-package.json"
cp "$DEPLOY_TEMPLATE_ARCHIVE" "$PKG/deploy-template-package.tgz"
```

Replace `tools/kubectl` and `tools/routability-probe` with operator-approved
package-local executables before `--run`.

## Compute Install Parameters

`install_confirmation.install_parameters_sha256` must match
`verify-substrate-install` exactly. Compute it after editing
`substrate-install-inputs.example.json` and `namespace`:

```bash
NAMESPACE="agentsmith"
node --input-type=module -e "import crypto from 'node:crypto';import fs from 'node:fs';import path from 'node:path';import{flattenKubernetesResources as f}from'./scripts/lib/kubernetes-namespace-scope-guard.mjs';const[file,ns]=process.argv.slice(1);const b=fs.readFileSync(file);const j=JSON.parse(b);const d=x=>'sha256:'+crypto.createHash('sha256').update(x).digest('hex');const c=r=>Buffer.from(JSON.stringify({apiVersion:'v1',kind:'List',items:r},null,2)+'\n');let rb,r;if(j.resources){r=f(j.resources);rb=c(r)}else{rb=fs.readFileSync(path.join(path.dirname(file),j.resource_list_path));r=f(JSON.parse(rb.toString('utf8')))}process.stdout.write(d(Buffer.from(['agentsmith.substrate-install-parameters/v1','substrate_install_inputs='+d(b),'resource_list='+d(rb),'apply_resource_list='+d(c(r)),'effective_namespace='+ns].join('\n'))))" "$PKG/substrate-install-inputs.example.json" "$NAMESPACE"
```

Paste the output into
`operator-inputs.json.install_confirmation.install_parameters_sha256`.

## Validate And Run

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG"
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

The package run writes path-level evidence for the final GA facade. It does
not issue `ga-release-report.json`.

