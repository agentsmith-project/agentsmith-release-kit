# Airgap Install Substrates Example

This directory is a minimal operator input pack template for
`airgap/install_substrates`: install namespace-scoped kit substrates, then
deploy AgentSmith from a bundle-local airgap release.

Release/material inputs are bundle-local. Operator tools such as `kubectl`,
`archive_probe`, and `image_loader` are package-local executables and may live
outside the bundle.

Secrets stay outside the package. Use `secretRef:` values only.

## Build The Package

```bash
EXAMPLE_DIR="examples/airgap-install-substrates"
PKG="out/operator-inputs/airgap-install-substrates"

mkdir -p "$PKG"
cp "$EXAMPLE_DIR/operator-inputs.apply.example.json" "$PKG/operator-inputs.json"
cp -R "$EXAMPLE_DIR/airgap-bundle" "$PKG/airgap-bundle"
cp -R "$EXAMPLE_DIR/tools" "$PKG/tools"
```

Replace the files under `"$PKG/airgap-bundle/components"` with the real
bundle-local release contract, deploy template package, deploy template
archive, image map, and substrate pack manifest. Update
`airgap-bundle/airgap-bundle-manifest.json` component sha256 values after
replacement. Replace package-local tools before `--run`.

## Compute Install Parameters

`install_confirmation.install_parameters_sha256` must match
`verify-substrate-install` exactly. Compute it after editing the bundle-local
install inputs and `namespace`:

```bash
NAMESPACE="agentsmith"
node --input-type=module -e "import crypto from 'node:crypto';import fs from 'node:fs';import path from 'node:path';import{flattenKubernetesResources as f}from'./scripts/lib/kubernetes-namespace-scope-guard.mjs';const[file,ns]=process.argv.slice(1);const b=fs.readFileSync(file);const j=JSON.parse(b);const d=x=>'sha256:'+crypto.createHash('sha256').update(x).digest('hex');const c=r=>Buffer.from(JSON.stringify({apiVersion:'v1',kind:'List',items:r},null,2)+'\n');let rb,r;if(j.resources){r=f(j.resources);rb=c(r)}else{rb=fs.readFileSync(path.join(path.dirname(file),j.resource_list_path));r=f(JSON.parse(rb.toString('utf8')))}process.stdout.write(d(Buffer.from(['agentsmith.substrate-install-parameters/v1','substrate_install_inputs='+d(b),'resource_list='+d(rb),'apply_resource_list='+d(c(r)),'effective_namespace='+ns].join('\n'))))" "$PKG/airgap-bundle/operator-inputs/substrate-install-inputs.example.json" "$NAMESPACE"
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

