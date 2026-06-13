# Minimal Substrate Pack

This is the first-party minimal substrate pack source for
`online/install_substrates` and `airgap/install_substrates`.

It is a materialization source, not a release verdict. Use
`scripts/materialize-substrate-pack.mjs` to write a concrete
`substrate-pack-manifest.json`, `substrate-install-inputs.json`,
`substrate-truth.json`, and JSON resource list for one target.

The pack installs only namespace-scoped resources accepted by the substrate
installer guard: `Service`, `ConfigMap`, `NetworkPolicy`, `StatefulSet`,
`Deployment`, `Job`, and `PersistentVolumeClaim`. It does not create
`Secret`, RBAC, `IngressClass`, `StorageClass`, or `PersistentVolume`
resources.

The substrate NetworkPolicy keeps substrate traffic namespace-local, with only
the default `kube-system` JuiceFS CSI node and mount pods allowed to reach
PostgreSQL `5432` and mount pods allowed to reach object-storage `9000`.
Use `--juicefs-csi-namespace` during materialization when the CSI mount
namespace is not `kube-system`.

Secrets are operator-provided target facts. Resource manifests reference only
secret names and keys, and substrate truth uses `secretRef:<namespace>/<name>`.
The operator must create every referenced credential, admin, client, server
TLS, and CA secret before confirmed apply. For private registries, image pull
access remains a target registry setup responsibility.

The generated resources are intended to pass pack validation and
server-dry-run. Full local-kind or production readiness still depends on the
operator-provided secrets, CA/TLS contents, storage class, registry access, and
post-apply substrate initialization checks. This minimal pack does not yet
create initialization Jobs for database schema/users, object-storage bucket
bootstrap, or OIDC realm/client bootstrap; those are follow-up runtime-ready
blockers, not evidence hidden inside server-dry-run.

To verify the public source image digests while materializing, run:

```bash
node scripts/materialize-substrate-pack.mjs \
  --deployment-path online/install_substrates \
  --output-dir out/substrate-pack \
  --namespace agentsmith \
  --installation-id kit-install-<id> \
  --storage-class <storage-class> \
  --verify-source-images
```

`--verify-source-images` requires `skopeo`; environments without `skopeo` can
omit that flag and treat `skopeo` as the focused preflight dependency for
source-ref verification.
