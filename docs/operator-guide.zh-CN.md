# AgentSmith Operator 中文操作手册

本文面向安装和部署整套 AgentSmith 的 operator。目标是把操作路径压到
一个清晰入口：准备一个 `operator-inputs` 包，运行
`scripts/operator-release.sh`，最后读取 `ga-release-report.json`。

本文中的 `<...>` 是必须替换的占位值。命令使用空格分隔参数，不使用
`--flag=value` 形式。

## 0. 推荐入口

在 release-kit 仓库根目录执行：

```bash
cd /home/percy/works/mbos-v1/agentsmith-release-kit
```

面向 operator 的统一入口是：

```bash
bash scripts/operator-release.sh --init-operator-inputs <deployment_path> --output-dir <package-dir>
bash scripts/operator-release.sh --operator-inputs <package-dir-or-json> --doctor
bash scripts/operator-release.sh --operator-inputs <package-dir-or-json> --run
```

最终报告只由下面的命令生成：

```bash
bash scripts/operator-release.sh --ga-report \
  --operator-inputs <online-use-existing-pkg> \
  --operator-inputs <online-install-substrates-pkg> \
  --operator-inputs <airgap-use-existing-pkg> \
  --operator-inputs <airgap-install-substrates-pkg> \
  --product-readiness-report <product-readiness.json> \
  --post-deploy-product-smoke-report <online-smoke.json> \
  --post-deploy-product-smoke-report <airgap-smoke.json> \
  --output-dir <ga-output-dir>
```

最终结果看：

```bash
cat <ga-output-dir>/ga-release-report.json
```

`formal_verdict` 为 `issued` 表示最终报告签发；失败时同一个
`ga-release-report.json` 会写出 `formal_verdict: not_issued` 和
`blockers`。同目录下还会有 `ga-release-summary.md` 和
`ga-evidence-index.json`，便于快速定位。

## 1. 四种安装部署方式

每个 `operator-inputs` 包只能选择一种 `deployment_path`：

| 方式 | 适用场景 | substrate 语义 |
| --- | --- | --- |
| `online/use_existing` | 联网环境，operator 已提供 PostgreSQL、MongoDB、Redis、对象存储、OIDC | release-kit 只消费 operator 声明的连接事实和 Secret 引用 |
| `online/install_substrates` | 联网环境，由 release-kit 在目标 namespace 内安装最小 substrate pack | 只安装 namespace-scoped 最小包，不创建云资源、CRD、集群级平台能力 |
| `airgap/use_existing` | 离线环境，operator 已提供目标网络内的 PostgreSQL、MongoDB、Redis、对象存储、OIDC | release-kit 从离线 bundle 中消费声明事实和 Secret 引用 |
| `airgap/install_substrates` | 离线环境，由 release-kit 在目标 namespace 内安装最小 substrate pack | bundle 内带最小 substrate pack，只做 namespace-scoped 安装 |

`use_existing` 的含义是 operator 已经提供 substrates。它可以是真实外部云服务、
企业内部托管服务、或本地已安装服务。当前 release-kit 只验证 operator 提供的
目标事实和运行结果；本地已安装 substrates 可以作为 GA rehearsal evidence，
但不能声称已经验证了某个云厂商托管服务。实际实施时可以接外部云服务，只要
`substrate_truth`、Secret 和网络前提真实可用。

`install_substrates` 的含义是使用 release-kit 的 minimal substrate pack 在
指定 namespace 内安装最小依赖。它不会创建 Kubernetes 集群、云数据库、对象桶、
IAM、网络、OIDC 托管服务、CRD 或集群级平台能力。

## 2. 必须先准备的内容

### 2.1 目标 namespace 和 Kubernetes 访问

准备一个独立 namespace。不同路径建议使用不同 namespace 或不同集群；至少不要
把 online/airgap、use_existing/install_substrates 的输出和证据混在同一个包里。

```bash
NAMESPACE="<agentsmith-namespace>"
KUBE_CONTEXT="<kube-context>"

kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE"
kubectl --context "$KUBE_CONTEXT" auth can-i apply deployments -n "$NAMESPACE"
kubectl --context "$KUBE_CONTEXT" auth can-i get pods -n "$NAMESPACE"
```

准备 ingress/route、TLS Secret、镜像拉取 Secret、StorageClass、RBAC。把这些
写入 `target-prerequisites.json`，不要只写在人工记录里。

### 2.2 Secrets

operator-inputs 里只能写 `secretRef:<namespace>/<name>`，不要写明文密码、
token、kubeconfig 或私钥。Secret key 名需要和 truth 中引用的服务匹配。

常见 Secret 示例：

```bash
NAMESPACE="<agentsmith-namespace>"
KUBE_CONTEXT="<kube-context>"

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic postgresql-app \
  --from-literal=username='<postgres-app-user>' \
  --from-literal=password='<postgres-app-password>'

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic postgresql-admin \
  --from-literal=username='<postgres-admin-user>' \
  --from-literal=password='<postgres-admin-password>'

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic mongodb-app \
  --from-literal=username='<mongodb-user>' \
  --from-literal=password='<mongodb-password>'

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic redis-app \
  --from-literal=password='<redis-password>'

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic object-storage-app \
  --from-literal=access_key='<object-storage-access-key>' \
  --from-literal=secret_key='<object-storage-secret-key>'

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic oidc-client \
  --from-literal=client_secret='<oidc-client-secret>'
```

如果 truth 里声明了 CA Secret，key 使用 `ca.crt`：

```bash
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic postgresql-ca \
  --from-file=ca.crt=<postgresql-ca.crt>
```

如果 truth 里声明了服务端 TLS Secret，对应 key 必须匹配：

| 服务 | Secret key |
| --- | --- |
| PostgreSQL | `tls.crt`, `tls.key`, `ca.crt` |
| MongoDB | `tls.pem`, `ca.crt` |
| Redis | `tls.crt`, `tls.key`, `ca.crt` |
| object storage | `public.crt`, `private.key` |
| OIDC | `tls.crt`, `tls.key` |

### 2.3 operator-inputs 包

建议先生成骨架：

```bash
PKG_ROOT="out/operator-inputs"

bash scripts/operator-release.sh --init-operator-inputs online/use_existing \
  --output-dir "$PKG_ROOT/online-use-existing"

bash scripts/operator-release.sh --init-operator-inputs online/install_substrates \
  --output-dir "$PKG_ROOT/online-install-substrates"

bash scripts/operator-release.sh --init-operator-inputs airgap/use_existing \
  --output-dir "$PKG_ROOT/airgap-use-existing"

bash scripts/operator-release.sh --init-operator-inputs airgap/install_substrates \
  --output-dir "$PKG_ROOT/airgap-install-substrates"
```

也可以从 `examples/` 复制对应目录。无论哪种方式，一个包内都必须有
`operator-inputs.json`。

重要字段：

| 字段 | 说明 |
| --- | --- |
| `deployment_path` | 四选一：`online/use_existing`、`online/install_substrates`、`airgap/use_existing`、`airgap/install_substrates` |
| `release_contract` | AgentSmith release contract JSON；online 包通常放在包根，airgap 包通常来自 `airgap-bundle/components/` |
| `deploy_template_package` | deploy template package JSON |
| `deploy_template_archive` | deploy template package tgz |
| `render_values` | 渲染部署模板的目标值，例如 namespace、副本数、默认卷配置 |
| `substrate_truth` | 仅 `use_existing` 路径使用；描述 operator 已提供 substrates |
| `target_prerequisites` | namespace、RBAC、ingress、registry、storage、Secret 引用等目标前提 |
| `substrate_pack_manifest` | 仅 `install_substrates` 路径使用；minimal substrate pack manifest |
| `substrate_install_inputs` | 仅 `install_substrates` 路径使用；installer 输入 |
| `airgap_bundle` | 仅 airgap 路径使用；离线 bundle 目录 |
| `airgap_bundle_manifest` | 仅 airgap 路径使用；必须来自组装后的 bundle |
| `namespace` | 目标 namespace，必须与 `target_prerequisites.namespace` 一致 |
| `mode` | operator 执行整套部署时使用 `apply` |
| `context` | kube context 名；不要填 `replace-with-kube-context` |
| `kubectl` | 包内可执行 `kubectl` 包装器或二进制路径，例如 `tools/kubectl` |
| `routability_probe` | `online/install_substrates` 需要；包内可执行连通性探针 |
| `archive_probe` | airgap 需要；包内可执行镜像归档探针 |
| `image_loader` | airgap 需要；包内可执行镜像加载器 |
| `smoke_url` | 部署后 route smoke URL；不要填骨架默认占位 URL |
| `install_confirmation` | `install_substrates` 需要，确认安装 substrate pack |
| `deploy_confirmation` | `mode: apply` 需要，确认执行部署 |

`target_registry` 和 `registry_probe` 是 online apply 包的可选项。使用时，目标
registry 必须已经有 release images 的 digest refs；release-kit 不负责 mirror、
push、registry login。

### 2.4 substrate truth

`substrate_truth.json` 描述真实可连接的服务，不保存密钥。至少覆盖：

- `postgresql`: `host`, `port`, `database`, `credential_secret_ref`,
  `admin_secret_ref`, TLS/CA 信息，`pgvector` 安装状态。
- `mongodb`: `host`, `port`, `credential_secret_ref`, TLS/CA 信息。
- `redis`: `host`, `port`, `credential_secret_ref`, TLS/CA 信息。
- `object_storage`: `url`, `bucket`, `region`, `credential_secret_ref`,
  TLS/CA 信息。
- `oidc`: `issuer_url`, `client_id`, `client_secret_ref`, TLS/CA 信息。

`secretRef:` 必须指向目标 namespace 中真实存在的 Secret。`reachability.proof`
写 operator 做过的连通性确认，例如时间、方式和结果摘要。

### 2.5 target prerequisites

`target-prerequisites.json` 至少写清：

| 字段 | 说明 |
| --- | --- |
| `namespace` | 目标 namespace |
| `rbac.policy` / `rbac.proof` | operator 对 namespace 的权限说明和检查结果 |
| `ingress.host` | AgentSmith 对外访问域名 |
| `ingress.tls_secret_ref` | ingress TLS Secret |
| `registry.auth.mode` | 镜像拉取认证方式 |
| `registry.pull_secret_ref` | 镜像拉取 Secret |
| `storage.storage_class` | 使用的 StorageClass |
| `storage.persistent_volume_policy` | 动态或预置 PV 策略 |
| `substrate_secret_refs` | truth 中引用的 substrate Secret 清单 |

## 3. online/use_existing

这条路径适合联网目标，并且 PostgreSQL、MongoDB、Redis、对象存储、OIDC 已由
operator 提供。

```bash
PKG="out/operator-inputs/online-use-existing"

cp <release-contract.json> "$PKG/release-contract.json"
cp <deploy-template-package.json> "$PKG/deploy-template-package.json"
cp <agentsmith-deploy-template-package.tgz> "$PKG/deploy-template-package.tgz"
cp <render-values.json> "$PKG/render-values.json"
cp <substrate-truth.json> "$PKG/substrate-truth.json"
cp <target-prerequisites.json> "$PKG/target-prerequisites.json"
mkdir -p "$PKG/tools"
cp <operator-approved-kubectl> "$PKG/tools/kubectl"
chmod +x "$PKG/tools/kubectl"
```

编辑 `"$PKG/operator-inputs.json"`：

- `deployment_path` 保持 `online/use_existing`。
- `release_contract`、`deploy_template_package`、`deploy_template_archive`、
  `render_values`、`substrate_truth`、`target_prerequisites` 指向包内文件。
- `namespace`、`context`、`smoke_url` 改成目标真实值。
- `deploy_confirmation.confirmed` 设为 `true`。
- `deploy_confirmation.operator_run_id` 填本次操作编号，例如
  `operator-online-existing-20260615-001`。

检查并执行：

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

## 4. online/install_substrates

这条路径适合联网目标，并由 release-kit minimal substrate pack 在目标 namespace
中安装最小 substrates。不要在这个包里提供 package-local `substrate_truth`；
`--run` 会使用 installer 生成的 truth。

先 materialize minimal substrate pack：

```bash
PKG="out/operator-inputs/online-install-substrates"
NAMESPACE="<agentsmith-namespace>"

node scripts/materialize-substrate-pack.mjs \
  --deployment-path online/install_substrates \
  --output-dir "$PKG/substrate-pack" \
  --namespace "$NAMESPACE" \
  --installation-id <kit-install-id> \
  --storage-class <storage-class>
```

如果制包环境有 `skopeo`，可以加源镜像 digest 校验：

```bash
node scripts/materialize-substrate-pack.mjs \
  --deployment-path online/install_substrates \
  --output-dir "$PKG/substrate-pack" \
  --namespace "$NAMESPACE" \
  --installation-id <kit-install-id> \
  --storage-class <storage-class> \
  --verify-source-images \
  --skopeo <skopeo-path-or-command>
```

复制 release 物料和工具：

```bash
cp <release-contract.json> "$PKG/release-contract.json"
cp <deploy-template-package.json> "$PKG/deploy-template-package.json"
cp <agentsmith-deploy-template-package.tgz> "$PKG/deploy-template-package.tgz"
cp <render-values.json> "$PKG/render-values.json"
cp <target-prerequisites.json> "$PKG/target-prerequisites.json"
mkdir -p "$PKG/tools"
cp <operator-approved-kubectl> "$PKG/tools/kubectl"
cp <operator-approved-routability-probe> "$PKG/tools/routability-probe"
chmod +x "$PKG/tools/kubectl" "$PKG/tools/routability-probe"
```

编辑 `"$PKG/operator-inputs.json"`：

- `deployment_path` 保持 `online/install_substrates`。
- `substrate_pack_manifest` 指向
  `substrate-pack/substrate-pack-manifest.json`。
- `substrate_install_inputs` 指向
  `substrate-pack/substrate-install-inputs.json`。
- `namespace`、`context`、`smoke_url` 改成目标真实值。
- `install_confirmation.confirmed` 设为 `true`。
- `install_confirmation.confirm_current_install_parameters` 设为 `true`，让
  release-kit 按当前 install inputs 计算并使用
  `install_parameters_sha256`。
- `install_confirmation.operator_run_id` 和
  `deploy_confirmation.operator_run_id` 使用不同的本次操作编号。

检查并执行：

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

## 5. 生成离线安装包

离线包在联网制包机上生成，然后复制到离线目标网络。制包命令需要真实 release
物料、镜像归档、runbook/script/profile schema、operator prerequisites。

### 5.1 导出镜像归档

```bash
ARCHIVES="out/airgap-image-archives"

node scripts/export-airgap-image-archives.mjs \
  --release-contract <release-contract.json> \
  --output-dir "$ARCHIVES" \
  --skopeo <skopeo-path-or-command>
```

输出目录会包含 OCI archive 文件和
`airgap-image-archive-export.json`。后续 bundle-create 的
`--image-archive <image_id=local-file>` 必须来自这些归档。

### 5.2 airgap/use_existing bundle

`use_existing` 离线包不带 substrate pack，目标网络内必须已有 substrates。

```bash
BUNDLE_ROOT="out/airgap-bundle-use-existing"
BUNDLE_OUT="out/airgap-bundle-use-existing-check"

bash scripts/verify-release.sh --bundle-create \
  --release-contract <release-contract.json> \
  --deploy-template-package <deploy-template-package.json> \
  --archive <agentsmith-deploy-template-package.tgz> \
  --target-profile existing_kubernetes/external_declared/airgap \
  --target-registry <registry-host[/namespace]> \
  --image-archive <image_id>=<local-oci-archive-file> \
  --image-archive <image_id>=<local-oci-archive-file> \
  --runbook <operator-runbook-file> \
  --script <offline-install-script-file> \
  --profile-values-schema <profile-values-schema-file> \
  --profile-values-example <profile-values-example-file> \
  --operator-prerequisites <operator-prerequisites.json> \
  --bundle-root "$BUNDLE_ROOT" \
  --output-dir "$BUNDLE_OUT"
```

`--image-archive` 可重复多次，必须覆盖 release contract 中声明的镜像。

### 5.3 airgap/install_substrates bundle

先为 airgap materialize substrate pack 到一个独立目录；这里必须提供目标
registry，因为离线部署会使用目标 registry 地址。`--bundle-create` 的
`--bundle-root` 必须不存在或为空，所以不要把 substrate pack 先写进
`BUNDLE_ROOT`。

```bash
BUNDLE_ROOT="out/airgap-bundle-install-substrates"
SUBSTRATE_PACK_DIR="out/airgap-substrate-pack"
NAMESPACE="<agentsmith-namespace>"

node scripts/materialize-substrate-pack.mjs \
  --deployment-path airgap/install_substrates \
  --target-registry <registry-host[/namespace]> \
  --output-dir "$SUBSTRATE_PACK_DIR" \
  --namespace "$NAMESPACE" \
  --installation-id <kit-install-id> \
  --storage-class <storage-class>
```

如果制包环境有 `skopeo`，可以加：

```bash
node scripts/materialize-substrate-pack.mjs \
  --deployment-path airgap/install_substrates \
  --target-registry <registry-host[/namespace]> \
  --output-dir "$SUBSTRATE_PACK_DIR" \
  --namespace "$NAMESPACE" \
  --installation-id <kit-install-id> \
  --storage-class <storage-class> \
  --verify-source-images \
  --skopeo <skopeo-path-or-command>
```

然后创建 bundle：

```bash
BUNDLE_OUT="out/airgap-bundle-install-substrates-check"

bash scripts/verify-release.sh --bundle-create \
  --release-contract <release-contract.json> \
  --deploy-template-package <deploy-template-package.json> \
  --archive <agentsmith-deploy-template-package.tgz> \
  --target-profile existing_kubernetes/kit_installed/airgap \
  --target-registry <registry-host[/namespace]> \
  --image-archive <image_id>=<local-oci-archive-file> \
  --image-archive <image_id>=<local-oci-archive-file> \
  --runbook <operator-runbook-file> \
  --script <offline-install-script-file> \
  --profile-values-schema <profile-values-schema-file> \
  --profile-values-example <profile-values-example-file> \
  --substrate-pack-manifest "$SUBSTRATE_PACK_DIR/substrate-pack-manifest.json" \
  --substrate-install-inputs "$SUBSTRATE_PACK_DIR/substrate-install-inputs.json" \
  --operator-prerequisites <operator-prerequisites.json> \
  --bundle-root "$BUNDLE_ROOT" \
  --output-dir "$BUNDLE_OUT"
```

`--bundle-create` 会组装 `airgap-bundle-manifest.json` 并立即做 bundle 一致性
检查。它不是最终部署结果；最终结果仍来自 `operator-release.sh --ga-report`。

### 5.4 离线制包参数说明

| 参数 | 用在 | 说明 |
| --- | --- | --- |
| `--release-contract` | export / bundle-create / check / load | AgentSmith release contract JSON，镜像清单和 release 身份来自这里 |
| `--deploy-template-package` | bundle-create / check / load | deploy template package JSON |
| `--archive` | bundle-create / check / load | deploy template package tgz |
| `--output-dir` | 所有制包/检查命令 | 命令输出报告目录；不要和 `--bundle-root` 混用 |
| `--skopeo` | image export / source image verify | `skopeo` 命令或绝对路径；只在导出镜像或显式校验源镜像时需要 |
| `--target-profile` | bundle-create / check / load | `existing_kubernetes/external_declared/airgap` 对应 `airgap/use_existing`；`existing_kubernetes/kit_installed/airgap` 对应 `airgap/install_substrates` |
| `--target-registry` | bundle-create / airgap substrate pack | 离线目标 registry 地址，可带 namespace，例如 `registry.local/agentsmith` |
| `--image-archive` | bundle-create | 可重复；格式是 `<image_id>=<local-oci-archive-file>`，必须覆盖 release contract 中声明的镜像 |
| `--runbook` | bundle-create | 放入 bundle 的 operator runbook 文件 |
| `--script` | bundle-create | 放入 bundle 的离线安装脚本文件 |
| `--profile-values-schema` | bundle-create | 放入 bundle 的 values schema |
| `--profile-values-example` | bundle-create | 可选；放入 bundle 的 values 示例 |
| `--operator-prerequisites` | bundle-create | operator 工具、目标 registry 证明、substrate truth 引用等前提说明 JSON |
| `--bundle-root` | bundle-create / check / load | bundle 目录；创建时必须不存在或为空，检查/加载时指向已解压 bundle |
| `--bundle-manifest` | check / load | 已组装 bundle 内的 `airgap-bundle-manifest.json` |
| `--substrate-pack-manifest` | kit_installed bundle-create | `airgap/install_substrates` 必填；指向独立 substrate pack 目录里的 manifest |
| `--substrate-install-inputs` | kit_installed bundle-create | `airgap/install_substrates` 必填；指向独立 substrate pack 目录里的 install inputs |
| `--archive-probe` | image archive check / load | 包内可执行探针，读取本地 archive 并输出 digest |
| `--image-loader` | image load / airgap run | 包内可执行加载器，把 archive 导入目标 registry 或目标运行环境 |

## 6. 拷贝、校验、加载离线包

### 6.1 打包和校验传输文件

在联网制包机上：

```bash
BUNDLE_ROOT="<path-to-assembled-airgap-bundle>"
TRANSFER_DIR="out/transfer"

mkdir -p "$TRANSFER_DIR"
tar -C "$(dirname "$BUNDLE_ROOT")" -czf "$TRANSFER_DIR/airgap-bundle.tgz" "$(basename "$BUNDLE_ROOT")"
sha256sum "$TRANSFER_DIR/airgap-bundle.tgz" > "$TRANSFER_DIR/airgap-bundle.tgz.sha256"
```

把 `airgap-bundle.tgz` 和 `airgap-bundle.tgz.sha256` 拷贝到离线目标网络。

在离线目标网络上：

```bash
TRANSFER_DIR="<offline-transfer-dir>"
WORK_DIR="<offline-work-dir>"

cd "$TRANSFER_DIR"
sha256sum -c airgap-bundle.tgz.sha256
mkdir -p "$WORK_DIR"
tar -C "$WORK_DIR" -xzf "$TRANSFER_DIR/airgap-bundle.tgz"
```

### 6.2 校验 bundle

```bash
BUNDLE_ROOT="<offline-work-dir>/<airgap-bundle-dir>"

bash scripts/verify-release.sh --airgap-bundle-check \
  --release-contract "$BUNDLE_ROOT/components/release-contract.json" \
  --deploy-template-package "$BUNDLE_ROOT/components/deploy-template-package.json" \
  --archive "$BUNDLE_ROOT/components/agentsmith-deploy-template-package.tgz" \
  --image-map "$BUNDLE_ROOT/components/image-map.json" \
  --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap \
  --bundle-root "$BUNDLE_ROOT" \
  --bundle-manifest "$BUNDLE_ROOT/airgap-bundle-manifest.json" \
  --output-dir <bundle-check-output-dir>
```

`external_declared` 对应 `airgap/use_existing`；
`kit_installed` 对应 `airgap/install_substrates`。

### 6.3 加载镜像

正式 airgap `--run` 会通过包内 `image_loader` 加载镜像。如果需要在部署前单独
加载或验证加载器，可执行：

```bash
BUNDLE_ROOT="<offline-work-dir>/<airgap-bundle-dir>"

bash scripts/verify-release.sh --airgap-image-load \
  --release-contract "$BUNDLE_ROOT/components/release-contract.json" \
  --deploy-template-package "$BUNDLE_ROOT/components/deploy-template-package.json" \
  --archive "$BUNDLE_ROOT/components/agentsmith-deploy-template-package.tgz" \
  --image-map "$BUNDLE_ROOT/components/image-map.json" \
  --target-profile existing_kubernetes/<external_declared|kit_installed>/airgap \
  --bundle-root "$BUNDLE_ROOT" \
  --bundle-manifest "$BUNDLE_ROOT/airgap-bundle-manifest.json" \
  --archive-probe <package-local-archive-probe> \
  --image-loader <package-local-image-loader> \
  --output-dir <image-load-output-dir>
```

`archive_probe` 调用形式是 `<archive_probe> <archive_path>`，stdout 必须只输出
匹配的 `sha256:<64-hex>`。`image_loader` 调用形式是
`<image_loader> <archive_path> <target_image> <target_digest>`，stdout 也必须只输出
匹配 digest。它们可以内部调用 `skopeo`、`ctr`、`crictl`、`docker` 或企业自有
工具，但这些依赖必须已经在离线目标环境可用，或随包提供。

## 7. airgap/use_existing

这条路径使用离线 bundle，并连接目标网络内 operator 已提供的 substrates。

```bash
PKG="out/operator-inputs/airgap-use-existing"
BUNDLE_ROOT="<offline-work-dir>/<airgap-bundle-dir>"

rm -rf "$PKG/airgap-bundle"
mkdir -p "$PKG/airgap-bundle"
cp -R "$BUNDLE_ROOT"/. "$PKG/airgap-bundle"/
mkdir -p "$PKG/airgap-bundle/operator-inputs"
cp <render-values.json> "$PKG/airgap-bundle/operator-inputs/render-values.json"
cp <substrate-truth.json> "$PKG/airgap-bundle/operator-inputs/substrate-truth.json"
cp <target-prerequisites.json> "$PKG/airgap-bundle/operator-inputs/target-prerequisites.json"
mkdir -p "$PKG/tools"
cp <operator-approved-kubectl> "$PKG/tools/kubectl"
cp <operator-approved-archive-probe> "$PKG/tools/archive-probe"
cp <operator-approved-image-loader> "$PKG/tools/image-loader"
chmod +x "$PKG/tools/kubectl" "$PKG/tools/archive-probe" "$PKG/tools/image-loader"
```

编辑 `"$PKG/operator-inputs.json"`：

- `deployment_path` 保持 `airgap/use_existing`。
- release 物料路径指向 `airgap-bundle/components/...`。
- `render_values`、`substrate_truth`、`target_prerequisites` 指向
  `airgap-bundle/operator-inputs/...`。
- `airgap_bundle` 指向 `airgap-bundle`。
- `airgap_bundle_manifest` 指向 `airgap-bundle/airgap-bundle-manifest.json`。
- `namespace`、`context`、`smoke_url` 改成离线目标真实值。
- `deploy_confirmation.confirmed` 设为 `true`。

执行：

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

## 8. airgap/install_substrates

这条路径使用离线 bundle，并先安装 bundle 内的 minimal substrate pack。不要在
这个包里提供 package-local `substrate_truth`；`--run` 会使用 installer 生成的
truth。

```bash
PKG="out/operator-inputs/airgap-install-substrates"
BUNDLE_ROOT="<offline-work-dir>/<airgap-bundle-dir>"

rm -rf "$PKG/airgap-bundle"
mkdir -p "$PKG/airgap-bundle"
cp -R "$BUNDLE_ROOT"/. "$PKG/airgap-bundle"/
mkdir -p "$PKG/airgap-bundle/operator-inputs"
cp <render-values.json> "$PKG/airgap-bundle/operator-inputs/render-values.json"
cp <target-prerequisites.json> "$PKG/airgap-bundle/operator-inputs/target-prerequisites.json"
mkdir -p "$PKG/tools"
cp <operator-approved-kubectl> "$PKG/tools/kubectl"
cp <operator-approved-archive-probe> "$PKG/tools/archive-probe"
cp <operator-approved-image-loader> "$PKG/tools/image-loader"
chmod +x "$PKG/tools/kubectl" "$PKG/tools/archive-probe" "$PKG/tools/image-loader"
```

编辑 `"$PKG/operator-inputs.json"`：

- `deployment_path` 保持 `airgap/install_substrates`。
- `substrate_pack_manifest` 指向 bundle 内的
  `airgap-bundle/components/substrate-pack-manifest.json`，或 bundle manifest
  中声明的真实位置。
- `substrate_install_inputs` 指向 bundle 内的
  `airgap-bundle/components/substrate-install-inputs.json`，或 bundle manifest
  中声明的真实位置。
- `airgap_bundle` 和 `airgap_bundle_manifest` 指向包内 bundle。
- `namespace`、`context`、`smoke_url` 改成离线目标真实值。
- `install_confirmation.confirmed` 设为 `true`。
- `install_confirmation.confirm_current_install_parameters` 设为 `true`。
- `install_confirmation.operator_run_id` 和
  `deploy_confirmation.operator_run_id` 使用不同编号。

执行：

```bash
bash scripts/operator-release.sh --operator-inputs "$PKG" --doctor
bash scripts/operator-release.sh --operator-inputs "$PKG" --run
```

## 9. 生成最终 GA 报告

四个包都运行完成后，准备 AgentSmith 产品侧报告：

- `<product-readiness.json>`：产品侧 readiness 报告。
- `<online-smoke.json>`：至少一个 online 部署的 post-deploy product smoke 报告。
- `<airgap-smoke.json>`：至少一个 airgap 部署的 post-deploy product smoke 报告。

post-deploy product smoke report 是部署后的运行结果，不是
`operator-inputs.json` 字段；`site.env` 也不要放进 operator-inputs。

然后生成最终报告：

```bash
GA_OUT="out/ga-release"

bash scripts/operator-release.sh --ga-report \
  --operator-inputs out/operator-inputs/online-use-existing \
  --operator-inputs out/operator-inputs/online-install-substrates \
  --operator-inputs out/operator-inputs/airgap-use-existing \
  --operator-inputs out/operator-inputs/airgap-install-substrates \
  --product-readiness-report <product-readiness.json> \
  --post-deploy-product-smoke-report <online-smoke.json> \
  --post-deploy-product-smoke-report <airgap-smoke.json> \
  --output-dir "$GA_OUT"
```

查看结果：

```bash
cat "$GA_OUT/ga-release-report.json"
cat "$GA_OUT/ga-release-summary.md"
```

最终聚合会检查四个包是否都已经 `--run`，也会检查 smoke 报告和部署时的
substrate truth digest 是否匹配。拿另一个 namespace、另一个 bundle、另一次
install_substrates 的 smoke 报告来混用，会被视为 blocker。

## 10. 失败时看哪里

`--doctor` 失败时先看终端输出。它会按几类列出缺失项：

- release materials
- operator target facts
- operator tools
- operator confirmations

`--run` 失败时先看终端最后输出的报告路径。正常会写：

| 路径 | 用途 |
| --- | --- |
| `<pkg>/.release-kit-internal/operator-inputs-plan.json` | 本次包解析后的执行计划 |
| `<pkg>/.release-kit-internal/<path-slug>/substrate-install/substrate-install-report.json` | `install_substrates` 的安装报告 |
| `<pkg>/.release-kit-internal/<path-slug>/online-deployment-gate/online-deployment-gate-report.json` | online 部署路径报告 |
| `<pkg>/.release-kit-internal/<path-slug>/airgap-consume-rehearsal/airgap-consume-rehearsal-report.json` | `airgap/use_existing` 的离线部署路径报告 |
| `<pkg>/.release-kit-internal/<path-slug>/airgap-bundle-check/airgap-bundle-check-report.json` | `airgap/install_substrates` 的 bundle 检查报告 |
| `<pkg>/.release-kit-internal/<path-slug>/airgap-deployment-gate/airgap-deployment-gate-report.json` | `airgap/install_substrates` 的离线部署报告 |
| `<pkg>/.release-kit-internal/<path-slug>/deployment-path/deployment-path-report.json` | 最终 `--ga-report` 消费的该路径报告 |

`<path-slug>` 是把 `deployment_path` 中的 `/` 和 `_` 替换成 `-`，例如
`online/use_existing` 对应 `online-use-existing`。

`--ga-report` 失败时看：

```bash
cat <ga-output-dir>/ga-release-report.json
cat <ga-output-dir>/ga-release-summary.md
cat <ga-output-dir>/ga-evidence-index.json
```

## 11. 最佳实践

- 一个 package 只放一个 deployment path；不要做四路径大 manifest。
- online 和 airgap 的包、bundle、输出目录、报告不要混用。
- use_existing 和 install_substrates 的 substrate truth 不要混用。
- 每个 namespace 只承载一条当前要证明的路径；复用 namespace 前先清理旧资源和旧报告。
- `airgap-bundle-manifest.json` 必须来自 bundle-create 输出，不要手写或只改
  `components`。
- 所有工具引用使用包内路径，例如 `tools/kubectl`、`tools/archive-probe`；
  不要只写 PATH 上的命令名。
- 示例目录里的 `.example.json` 和 placeholder tools 不能直接用于真实 `--run`。
- `install_confirmation.operator_run_id` 和
  `deploy_confirmation.operator_run_id` 使用可追踪、唯一的编号。
- `skopeo` 只在导出镜像归档或显式 source image 校验时需要；operator facade
  本身不直接要求 `skopeo`。
- 离线环境不要从公网下载；所有 release 物料、工具、镜像归档和配置都应随 bundle
  或 operator package 进入目标网络。

## 12. 常见错误

| 现象 | 处理 |
| --- | --- |
| `operator facade does not accept equals form` | 使用 `--operator-inputs "$PKG"`，不要写 `--operator-inputs="$PKG"` |
| `--run is accepted only after --operator-inputs` | 使用 `bash scripts/operator-release.sh --operator-inputs "$PKG" --run` |
| doctor 报 `replace-with-kube-context` 或示例 smoke URL | 把骨架占位值替换成真实目标值 |
| doctor 报 placeholder executable | 替换 `tools/*` 为真实可执行文件，并 `chmod +x` |
| Secret key missing | 按本文 Secret key 表重新创建或修正 Secret |
| airgap bundle manifest invalid | 使用 bundle-create 产物，不要手工拼 manifest |
| `install_substrates` 报不接受 `substrate_truth` | 移除 package-local `substrate_truth`，使用 installer 输出 truth |
| final GA 报 missing path evidence | 对应包没有成功 `--run`，按提示重新运行该 package |
| final GA 报 smoke/substrate truth digest mismatch | smoke 报告来自不同部署或不同 substrate，重新跑匹配目标的 product smoke |
