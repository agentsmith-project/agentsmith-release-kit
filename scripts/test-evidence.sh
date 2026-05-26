#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE:-node}"
TARGET_PROFILE="existing_kubernetes/external_declared/online"
AIRGAP_PROFILE="existing_kubernetes/external_declared/airgap"
KIND_PROFILE="kind_rehearsal/kit_installed/online"
VALID_CONTRACT="$ROOT_DIR/tests/fixtures/release-contract.valid.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

run_evidence() {
  local evidence_root="$1"
  local output_dir="$2"
  local target_profile="${3:-$TARGET_PROFILE}"

  bash "$ROOT_DIR/scripts/verify-release.sh" --evidence \
    --release-contract "$VALID_CONTRACT" \
    --evidence-root "$evidence_root" \
    --target-profile "$target_profile" \
    --output-dir "$output_dir"
}

expect_fail() {
  local label="$1"
  local kind="${2:-ci_artifact}"
  local mutation="${3:-$label}"
  local target_profile="${4:-$TARGET_PROFILE}"
  local evidence_root="$TMP_DIR/evidence-$label"
  local output_dir="$TMP_DIR/out-$label"

  write_evidence "$evidence_root" "$kind" "$mutation"

  if run_evidence "$evidence_root" "$output_dir" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid evidence case to fail: $label"
  fi

  pass "invalid evidence rejected: $label"
}

expect_target_profile_fail() {
  local label="$1"
  local target_profile="$2"
  local evidence_root="$TMP_DIR/evidence-target-$label"
  local output_dir="$TMP_DIR/out-target-$label"

  write_evidence "$evidence_root" ci_artifact valid

  if run_evidence "$evidence_root" "$output_dir" "$target_profile" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    cat "$TMP_DIR/$label.out" >&2
    cat "$TMP_DIR/$label.err" >&2
    fail "expected invalid target profile to fail: $label"
  fi

  pass "canonical profiles only; non-canonical pre-GA name or synonym axis rejected: $label"
}

assert_pass_report() {
  local report_file="$1"
  local expected_release_kit_output="${2:-online-deployment-gate-report.json}"
  "$NODE_BIN" --input-type=module - "$report_file" "$expected_release_kit_output" <<'NODE'
import fs from 'node:fs';

const [reportFile, expectedReleaseKitOutput] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (report.scope !== 'release_kit_evidence_intake_only') {
  throw new Error(`unexpected scope: ${report.scope}`);
}
if (report.readiness !== false) {
  throw new Error('evidence validation report must keep readiness=false');
}
if (report.status !== 'pass') {
  throw new Error(`unexpected status: ${report.status}`);
}
if (report.release_kit_output !== expectedReleaseKitOutput) {
  throw new Error(`unexpected release_kit_output: ${report.release_kit_output}`);
}
if (!Array.isArray(report.artifacts?.evidence?.files)) {
  throw new Error('evidence validation report must list mapped evidence files');
}
if ('release_verdict' in report || 'verdict' in report) {
  throw new Error('evidence validation report must not claim a release verdict');
}
NODE
}

write_evidence() {
  local evidence_root="$1"
  local kind="${2:-ci_artifact}"
  local mutation="${3:-valid}"

  "$NODE_BIN" --input-type=module - "$VALID_CONTRACT" "$evidence_root" "$kind" "$mutation" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [contractInput, evidenceRoot, kind, mutation] = process.argv.slice(2);
const producerRepo = 'github.com/agentsmith-project/agentsmith-release-kit';
const releaseKitCommitSha = 'fedcba9876543210fedcba9876543210fedcba98';
const contractRaw = fs.readFileSync(contractInput);
const contract = JSON.parse(contractRaw.toString('utf8'));
const contractDigest = digestBuffer(contractRaw);
const ONLINE_PROFILE = 'existing_kubernetes/external_declared/online';
const AIRGAP_PROFILE = 'existing_kubernetes/external_declared/airgap';
const KIND_PROFILE = 'kind_rehearsal/kit_installed/online';
const AIRGAP_BUNDLE_EVIDENCE_OUTPUT =
  'airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json';
const OLD_AIRGAP_BUNDLE_EVIDENCE_OUTPUT =
  'airgap-bundle-check-report.json+airgap-bundle-manifest.json';
let releaseKitOutput = 'online-deployment-gate-report.json';

fs.mkdirSync(evidenceRoot, { recursive: true });

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function digestFile(file) {
  return digestBuffer(fs.readFileSync(file));
}

function stableJson(value) {
  if (Array.isArray(value)) {
    return value.map(stableJson);
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableJson(value[key])])
    );
  }
  return value;
}

function canonicalDigest(value) {
  return digestBuffer(Buffer.from(JSON.stringify(stableJson(value))));
}

function jsonDigest(value) {
  return digestBuffer(Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}

function fixtureDigest(char) {
  return `sha256:${char.repeat(64)}`;
}

function targetProfileObject(profile) {
  const [targetCluster, substrateSource, distribution] = profile.split('/');
  return {
    value: profile,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

function stripTag(imageWithoutDigest) {
  const lastSlash = imageWithoutDigest.lastIndexOf('/');
  const lastColon = imageWithoutDigest.lastIndexOf(':');
  if (lastColon > lastSlash) {
    return imageWithoutDigest.slice(0, lastColon);
  }
  return imageWithoutDigest;
}

function firstPathComponentLooksLikeRegistry(component) {
  return (
    component.includes('.') ||
    component.includes(':') ||
    component === 'localhost' ||
    component === 'host.docker.internal'
  );
}

function sourceRepositoryPath(imageWithoutDigest) {
  const withoutTag = stripTag(imageWithoutDigest);
  const parts = withoutTag.split('/');
  if (parts.length > 1 && firstPathComponentLooksLikeRegistry(parts[0])) {
    return parts.slice(1).join('/');
  }
  return withoutTag;
}

function targetImageFor(item, targetRegistry) {
  if (!targetRegistry) {
    return item.image;
  }
  const imageWithoutDigest = item.image.replace(/@sha256:[0-9a-f]{64}$/, '');
  const repositoryPath = sourceRepositoryPath(imageWithoutDigest);
  return `${targetRegistry}/${repositoryPath}@${item.digest}`;
}

function buildImageMap(profile = ONLINE_PROFILE, targetRegistry) {
  const mirrorRequired = Boolean(targetRegistry);
  const mappings = contract.deploy_image_inventory.map((item) => ({
    id: item.id,
    source: item.source,
    source_image: item.image,
    source_digest: item.digest,
    target_image: targetImageFor(item, targetRegistry),
    target_digest: item.digest,
    action: mirrorRequired ? 'mirror_required' : 'use_source'
  }));
  const report = {
    schema: 'agentsmith.image-map/v1',
    scope: 'image_map_only',
    readiness: false,
    status: 'pass',
    release_id: contract.release_id,
    git_sha: contract.git_sha,
    release_contract: {
      input_sha256: contractDigest,
      deploy_image_inventory_count: contract.deploy_image_inventory.length
    },
    target_profile: targetProfileObject(profile),
    mirror_required: mirrorRequired,
    image_count: mappings.length,
    mappings
  };
  if (targetRegistry) {
    report.target_registry = targetRegistry;
  }
  return report;
}

function buildGateSteps(includeSmoke = true) {
  const names = [
    'inputs',
    'target-preflight',
    'template-package',
    'render',
    'render-check',
    'apply',
    'rollout',
    ...(includeSmoke ? ['smoke'] : [])
  ];
  const reportByStep = {
    inputs: 'inputs/target-profile-coverage-report.json',
    'target-preflight': 'target-preflight/target-preflight-report.json',
    'template-package': 'template-package/template-package-report.json',
    render: 'render/manifest-render-report.json',
    'render-check': 'render-check/render-report.json',
    apply: 'apply/apply-report.json',
    rollout: 'rollout/rollout-report.json',
    smoke: 'smoke/smoke-report.json'
  };
  return names.map((name) => ({
    name,
    status: 'pass',
    report_paths: [reportByStep[name]]
  }));
}

function withoutArtifactProvenance(value) {
  const { artifact_provenance: _artifactProvenance, ...subject } = value;
  return subject;
}

function writeJson(relativePath, value) {
  const file = path.join(evidenceRoot, relativePath);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  return file;
}

const evidence = {
  schema_version: 'agentsmith.release-kit-evidence-envelope/v1',
  release_kit_output: releaseKitOutput,
  release_contract_digest: contractDigest,
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_kit_version: '0.1.0',
  target_cluster: 'existing_kubernetes',
  substrate_source: 'external_declared',
  distribution: 'online',
  target: {
    namespace: 'release-ns',
    base_url: 'https://app.example.com'
  },
  status: 'passed',
  failure_class: 'none',
  substrate_connection_truth: {
    schema_version: 'agentsmith.substrate-connection.truth/v1',
    target_cluster: 'existing_kubernetes',
    substrate_source: 'external_declared',
    distribution: 'online',
    declared_at: '2026-05-23T12:00:00.000Z',
    declared_by: 'release-operator@example.com',
    services: {
      postgresql: {
        host: 'postgresql.release.example.internal',
        port: 5432,
        database: 'appdb',
        credential_secret_ref: 'secretRef:release/postgresql-credential',
        admin_secret_ref: 'secretRef:release/postgresql-admin',
        sslmode: 'verify-full',
        tls: {
          mode: 'verify-full',
          ca_secret_ref: 'secretRef:release/postgresql-ca'
        },
        extensions: {
          pgvector: {
            status: 'installed',
            version: '0.7.4'
          }
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator postgresql tcp/tls check 2026-05-23T12:00:00Z'
        }
      },
      mongodb: {
        host: 'mongodb.release.example.internal',
        port: 27017,
        credential_secret_ref: 'secretRef:release/mongodb-credential',
        tls: {
          mode: 'verify-full',
          ca_secret_ref: 'secretRef:release/mongodb-ca'
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator mongodb tcp/tls check 2026-05-23T12:00:00Z'
        }
      },
      redis: {
        host: 'redis.release.example.internal',
        port: 6379,
        credential_secret_ref: 'secretRef:release/redis-credential',
        tls: {
          mode: 'verify-full',
          ca_secret_ref: 'secretRef:release/redis-ca'
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator redis tcp/tls check 2026-05-23T12:00:00Z'
        }
      },
      object_storage: {
        url: 'https://objects.release.example.internal',
        bucket: 'release-artifacts',
        region: 'us-west-2',
        credential_secret_ref: 'secretRef:release/object-storage-credential',
        tls: {
          mode: 'https',
          ca_secret_ref: 'secretRef:release/object-storage-ca'
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator bucket head-object check 2026-05-23T12:00:00Z'
        }
      },
      oidc: {
        issuer_url: 'https://keycloak.release.example.com/realms/app',
        client_id: 'app-web',
        client_secret_ref: 'secretRef:release/oidc-client',
        tls: {
          mode: 'https',
          ca_secret_ref: 'secretRef:release/oidc-ca'
        },
        reachability: {
          status: 'declared_reachable',
          proof: 'operator oidc discovery check 2026-05-23T12:00:00Z'
        }
      }
    }
  }
};

const deployResult = {
  status: 'passed',
  namespace: 'service-ns'
};
const imageMap = buildImageMap();
const renderReport = {
  scope: 'render_check_intake_only',
  readiness: false,
  status: 'pass'
};
const rolloutReport = {
  scope: 'rollout_intake_only',
  readiness: false,
  status: 'passed'
};
const operatorRunId = 'operator-run-10001';
const smokeReport = {
  schema: 'agentsmith.route-smoke-report/v1',
  scope: 'route_smoke_only',
  readiness: false,
  status: 'pass',
  route: {
    scheme: 'https',
    origin: 'https://app.example.com',
    host: 'app.example.com',
    path: '/healthz'
  },
  expected_status: 200,
  status_code: 200
};
const onlineDeploymentGateReport = {
  schema: 'agentsmith.online-deployment-gate/v1',
  scope: 'online_deployment_gate_only',
  readiness: false,
  status: 'pass',
  mode: 'apply',
  operator_run_id: operatorRunId,
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  release_contract: {
    input_sha256: contractDigest
  },
  target_profile: targetProfileObject(ONLINE_PROFILE),
  capability_map: {
    [ONLINE_PROFILE]: {
      declared: 'supported',
      intake: 'supported',
      preflight: 'supported',
      render: 'supported',
      apply: 'supported',
      rollout: 'supported',
      smoke: 'optional',
      evidence_envelope: 'optional'
    }
  },
  steps: buildGateSteps(),
  generated_at: '2026-05-23T12:00:00.000Z'
};
const airgapImageMap = buildImageMap(AIRGAP_PROFILE, 'registry.example.internal/releases');
const airgapImageMapDigest = jsonDigest(airgapImageMap);
const deployTemplatePackageInputDigest = fixtureDigest('a');
const deployTemplateArchiveDigest = fixtureDigest('b');
const deployTemplateManifestDigest = fixtureDigest('c');
const componentPaths = {
  release_contract: 'components/release-contract.json',
  deploy_template_package: 'components/deploy-template-package.json',
  deploy_template_archive: 'components/agentsmith-deploy-template-package.tgz',
  image_map: 'components/image-map.json'
};
const imageArtifactDeclarations = airgapImageMap.mappings.map((mapping, index) => ({
  id: mapping.id,
  source_image: mapping.source_image,
  source_digest: mapping.source_digest,
  target_image: mapping.target_image,
  target_digest: mapping.target_digest,
  artifact_format: 'oci_layout_tar',
  path: `images/${mapping.id}.oci-layout.tar`,
  sha256: fixtureDigest(String(index + 1))
}));
const airgapPayloadArtifacts = [
  {
    id: 'operator_runbook',
    kind: 'runbook',
    path: 'payload/runbook.md',
    sha256: fixtureDigest('d')
  },
  {
    id: 'install_script',
    kind: 'script',
    path: 'payload/install.sh',
    sha256: fixtureDigest('e')
  },
  {
    id: 'profile_values_schema',
    kind: 'profile_values_schema',
    path: 'payload/profile-values.schema.json',
    sha256: fixtureDigest('f')
  },
  {
    id: 'profile_values_example',
    kind: 'profile_values_example',
    path: 'payload/profile-values.example.yaml',
    sha256: fixtureDigest('0')
  },
  {
    id: 'bundle_checksums',
    kind: 'checksums',
    path: 'payload/checksums.txt',
    sha256: fixtureDigest('2')
  }
];
const airgapOperatorTools = [
  {
    name: 'kubectl',
    version: '1.30.0',
    source: 'bundled',
    path: 'tools/kubectl-placeholder.txt',
    sha256: fixtureDigest('3')
  },
  {
    name: 'skopeo',
    version: '1.16.0',
    source: 'operator_prerequisite',
    location: 'operator provided workstation inventory skopeo',
    proof: 'signed operator prerequisite proof skopeo'
  }
];
const airgapBundleManifest = {
  schema_version: 'agentsmith.airgap-bundle-manifest/v1',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  target_profile: targetProfileObject(AIRGAP_PROFILE),
  bindings: {
    release_contract_sha256: contractDigest,
    deploy_template_package_sha256: deployTemplatePackageInputDigest,
    deploy_template_archive_sha256: deployTemplateArchiveDigest,
    deploy_template_manifest_sha256: deployTemplateManifestDigest,
    image_map_sha256: airgapImageMapDigest
  },
  components: [
    {
      kind: 'release_contract',
      path: componentPaths.release_contract,
      sha256: contractDigest
    },
    {
      kind: 'deploy_template_package',
      path: componentPaths.deploy_template_package,
      sha256: deployTemplatePackageInputDigest
    },
    {
      kind: 'deploy_template_archive',
      path: componentPaths.deploy_template_archive,
      sha256: deployTemplateArchiveDigest
    },
    {
      kind: 'image_map',
      path: componentPaths.image_map,
      sha256: airgapImageMapDigest
    }
  ],
  image_artifact_declarations: imageArtifactDeclarations,
  payload_artifacts: airgapPayloadArtifacts,
  operator_prerequisites: {
    substrate_connection_truth_ref: 'operator-substrate-truth-evidence-ref',
    target_registry_proof_ref: 'operator-target-registry-proof-ref',
    tools: airgapOperatorTools
  },
  substrate: {
    mode: 'external_declared',
    bundled: false
  }
};
const airgapBundleCheckReport = {
  schema: 'agentsmith.airgap-bundle-check-report/v1',
  scope: 'airgap_bundle_manifest_check_only',
  readiness: false,
  status: 'pass',
  release_id: contract.release_id,
  git_sha: contract.git_sha,
  target_profile: targetProfileObject(AIRGAP_PROFILE),
  artifacts: {
    release_contract: {
      input_sha256: contractDigest
    },
    deploy_template_package: {
      input_sha256: deployTemplatePackageInputDigest,
      package_sha256: deployTemplateArchiveDigest,
      manifest_sha256: deployTemplateManifestDigest,
      artifact_sha256: deployTemplateArchiveDigest
    },
    deploy_template_archive: {
      input_sha256: deployTemplateArchiveDigest
    },
    image_map: {
      input_sha256: airgapImageMapDigest,
      image_count: imageArtifactDeclarations.length
    },
    bundle_manifest: {
      input_sha256: fixtureDigest('4'),
      image_artifact_declaration_count: imageArtifactDeclarations.length
    }
  },
  components_count: 4,
  image_artifact_declaration_count: imageArtifactDeclarations.length,
  payload_artifact_count: airgapPayloadArtifacts.length,
  tool_count: airgapOperatorTools.length,
  bundled_tool_count: 1,
  operator_prerequisite_tool_count: 1
};
let outputFiles = [
  {
    path: 'online-deployment-gate-report.json',
    value: onlineDeploymentGateReport
  }
];
let syncAirgapReportManifestDigest = true;
let syncAirgapImageMapDigest = true;
let provenanceArtifactUri =
  kind === 'signed_operator_run'
    ? `signed-operator-run://agentsmith-release-kit/evidence/${operatorRunId}/evidence-envelope.tgz`
    : 'gh-artifact://agentsmith-release-kit/evidence/10001/evidence-envelope.tgz';

function useSslmodeOnly() {
  for (const service of Object.values(evidence.substrate_connection_truth.services)) {
    delete service.tls;
    service.sslmode = 'verify-full';
  }
}

function useRedactedFingerprints() {
  const fingerprint = `redacted:sha256:${'b'.repeat(64)}`;
  const services = evidence.substrate_connection_truth.services;
  services.postgresql.credential_secret_ref = fingerprint;
  services.postgresql.admin_secret_ref = fingerprint;
  services.postgresql.tls.ca_secret_ref = fingerprint;
  services.mongodb.credential_secret_ref = fingerprint;
  services.mongodb.tls.ca_secret_ref = fingerprint;
  services.redis.credential_secret_ref = fingerprint;
  services.redis.tls.ca_secret_ref = fingerprint;
  services.object_storage.credential_secret_ref = fingerprint;
  services.object_storage.tls.ca_secret_ref = fingerprint;
  services.oidc.client_secret_ref = fingerprint;
  services.oidc.tls.ca_secret_ref = fingerprint;
}

function useTargetProfile(profile) {
  const [targetCluster, substrateSource, distribution] = profile.split('/');
  evidence.target_cluster = targetCluster;
  evidence.substrate_source = substrateSource;
  evidence.distribution = distribution;
  evidence.substrate_connection_truth.target_cluster = targetCluster;
  evidence.substrate_connection_truth.substrate_source = substrateSource;
  evidence.substrate_connection_truth.distribution = distribution;
}

function useOnlineGateOutput() {
  releaseKitOutput = 'online-deployment-gate-report.json';
  evidence.release_kit_output = releaseKitOutput;
  outputFiles = [
    {
      path: 'online-deployment-gate-report.json',
      value: onlineDeploymentGateReport
    }
  ];
}

function useImageMapOutput() {
  releaseKitOutput = 'image-map.json';
  evidence.release_kit_output = releaseKitOutput;
  outputFiles = [
    {
      path: 'image-map.json',
      value: imageMap
    }
  ];
}

function useAirgapBundleOutput() {
  useTargetProfile(AIRGAP_PROFILE);
  releaseKitOutput = AIRGAP_BUNDLE_EVIDENCE_OUTPUT;
  evidence.release_kit_output = releaseKitOutput;
  outputFiles = [
    {
      path: 'airgap-bundle-check-report.json',
      value: airgapBundleCheckReport
    },
    {
      path: 'airgap-bundle-manifest.json',
      value: airgapBundleManifest
    },
    {
      path: 'image-map.json',
      value: airgapImageMap
    }
  ];
}

switch (mutation) {
  case 'valid':
    break;
  case 'future_deploy_result_output':
    releaseKitOutput = 'deploy-result.json#substrate';
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = [
      {
        path: 'deploy-result.json',
        value: deployResult
      }
    ];
    break;
  case 'online_gate_wrong_schema':
    onlineDeploymentGateReport.schema = 'agentsmith.deploy-result/v1';
    break;
  case 'online_gate_wrong_scope':
    onlineDeploymentGateReport.scope = 'release_readiness';
    break;
  case 'online_gate_wrong_readiness':
    onlineDeploymentGateReport.readiness = true;
    break;
  case 'online_gate_wrong_status':
    onlineDeploymentGateReport.status = 'passed';
    break;
  case 'online_gate_release_digest_mismatch':
    onlineDeploymentGateReport.release_contract.input_sha256 = `sha256:${'e'.repeat(64)}`;
    break;
  case 'online_gate_report_target_profile_mismatch':
    onlineDeploymentGateReport.target_profile = targetProfileObject(AIRGAP_PROFILE);
    break;
  case 'online_gate_stale_release_id':
    onlineDeploymentGateReport.release_id = `${contract.release_id}-stale`;
    break;
  case 'online_gate_stale_git_sha':
    onlineDeploymentGateReport.git_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    break;
  case 'online_gate_missing_operator_run_id':
    delete onlineDeploymentGateReport.operator_run_id;
    break;
  case 'online_gate_operator_run_id_mismatch':
    onlineDeploymentGateReport.operator_run_id = 'operator-run-drift';
    break;
  case 'online_gate_dry_run':
    onlineDeploymentGateReport.mode = 'server-dry-run';
    onlineDeploymentGateReport.steps = buildGateSteps(false).filter((step) => step.name !== 'rollout');
    break;
  case 'online_gate_empty_steps':
    onlineDeploymentGateReport.steps = [];
    break;
  case 'valid_image_map_output':
    useImageMapOutput();
    break;
  case 'valid_airgap_image_map_output':
    useTargetProfile(AIRGAP_PROFILE);
    Object.assign(imageMap, buildImageMap(AIRGAP_PROFILE, 'registry.example.internal/releases'));
    useImageMapOutput();
    break;
  case 'image_map_kind_rehearsal_output':
    useTargetProfile(KIND_PROFILE);
    Object.assign(imageMap, buildImageMap(KIND_PROFILE));
    useImageMapOutput();
    break;
  case 'image_map_mapping_missing':
    useImageMapOutput();
    imageMap.mappings.pop();
    imageMap.image_count = imageMap.mappings.length;
    break;
  case 'image_map_digest_drift':
    useImageMapOutput();
    imageMap.mappings[0].source_digest = `sha256:${'9'.repeat(64)}`;
    break;
  case 'image_map_target_registry_with_use_source':
    useImageMapOutput();
    imageMap.target_registry = 'registry.example.internal/releases';
    break;
  case 'image_map_use_source_target_drift':
    useImageMapOutput();
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      'ghcr.io',
      'registry.example.internal'
    );
    break;
  case 'image_map_mirror_target_drift': {
    useImageMapOutput();
    const mirroredImageMap = buildImageMap(ONLINE_PROFILE, 'registry.example.internal/releases');
    Object.assign(imageMap, mirroredImageMap);
    imageMap.mappings[0].target_image = imageMap.mappings[0].target_image.replace(
      'registry.example.internal',
      'registry-drift.example.internal'
    );
    break;
  }
  case 'image_map_airgap_use_source':
    useTargetProfile(AIRGAP_PROFILE);
    Object.assign(imageMap, buildImageMap(AIRGAP_PROFILE));
    useImageMapOutput();
    break;
  case 'removed_render_rollout_output':
    releaseKitOutput = 'render-report.json+rollout-report.json';
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = [
      {
        path: 'render-report.json',
        value: renderReport
      },
      {
        path: 'rollout-report.json',
        value: rolloutReport
      }
    ];
    break;
  case 'removed_render_rollout_smoke_output':
    releaseKitOutput = 'render-report.json+rollout-report.json+smoke-report.json';
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = [
      {
        path: 'render-report.json',
        value: renderReport
      },
      {
        path: 'rollout-report.json',
        value: rolloutReport
      },
      {
        path: 'smoke-report.json',
        value: smokeReport
      }
    ];
    break;
  case 'valid_online_deployment_gate_output':
    useOnlineGateOutput();
    break;
  case 'valid_airgap_bundle_output':
    useAirgapBundleOutput();
    break;
  case 'airgap_old_two_file_pair':
    useAirgapBundleOutput();
    releaseKitOutput = OLD_AIRGAP_BUNDLE_EVIDENCE_OUTPUT;
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = outputFiles.filter((outputFile) => outputFile.path !== 'image-map.json');
    break;
  case 'airgap_image_map_missing':
    useAirgapBundleOutput();
    outputFiles = outputFiles.filter((outputFile) => outputFile.path !== 'image-map.json');
    break;
  case 'airgap_image_map_mirror_required_false':
    useAirgapBundleOutput();
    Object.assign(airgapImageMap, buildImageMap(AIRGAP_PROFILE));
    break;
  case 'airgap_manifest_target_image_drift':
    useAirgapBundleOutput();
    airgapBundleManifest.image_artifact_declarations[0].target_image =
      airgapBundleManifest.image_artifact_declarations[0].target_image.replace(
        'registry.example.internal',
        'registry-drift.example.internal'
      );
    break;
  case 'airgap_tools_empty':
    useAirgapBundleOutput();
    airgapBundleManifest.operator_prerequisites.tools = [];
    airgapBundleCheckReport.tool_count = 0;
    airgapBundleCheckReport.bundled_tool_count = 0;
    airgapBundleCheckReport.operator_prerequisite_tool_count = 0;
    break;
  case 'airgap_manifest_release_digest_mismatch':
    useAirgapBundleOutput();
    airgapBundleManifest.bindings.release_contract_sha256 = `sha256:${'8'.repeat(64)}`;
    break;
  case 'airgap_report_manifest_sha_mismatch':
    useAirgapBundleOutput();
    syncAirgapReportManifestDigest = false;
    airgapBundleCheckReport.artifacts.bundle_manifest.input_sha256 = `sha256:${'7'.repeat(64)}`;
    break;
  case 'airgap_manifest_target_profile_mismatch':
    useAirgapBundleOutput();
    airgapBundleManifest.target_profile = targetProfileObject(ONLINE_PROFILE);
    break;
  case 'airgap_manifest_components_empty':
    useAirgapBundleOutput();
    airgapBundleManifest.components = [];
    airgapBundleCheckReport.components_count = 0;
    break;
  case 'airgap_image_artifact_declaration_missing':
    useAirgapBundleOutput();
    airgapBundleManifest.image_artifact_declarations.pop();
    break;
  case 'airgap_missing_required_payload_kind':
    useAirgapBundleOutput();
    airgapBundleManifest.payload_artifacts = airgapBundleManifest.payload_artifacts.filter(
      (artifact) => artifact.kind !== 'checksums'
    );
    airgapBundleCheckReport.payload_artifact_count = airgapBundleManifest.payload_artifacts.length;
    break;
  case 'airgap_report_payload_count_mismatch':
    useAirgapBundleOutput();
    airgapBundleCheckReport.payload_artifact_count += 1;
    break;
  case 'airgap_missing_image_map_artifact_digest':
    useAirgapBundleOutput();
    delete airgapBundleCheckReport.artifacts.image_map.input_sha256;
    break;
  case 'airgap_component_sha_mismatch':
    useAirgapBundleOutput();
    syncAirgapImageMapDigest = false;
    airgapBundleManifest.components.find((component) => component.kind === 'image_map').sha256 =
      fixtureDigest('6');
    break;
  case 'airgap_operator_ref_wget':
    useAirgapBundleOutput();
    airgapBundleManifest.operator_prerequisites.target_registry_proof_ref =
      'operator evidence: wget example.invalid/proof';
    break;
  case 'airgap_operator_tool_proof_docker_pull':
    useAirgapBundleOutput();
    airgapBundleManifest.operator_prerequisites.tools[1].proof =
      'operator proof: docker pull registry.invalid/skopeo:1.16';
    break;
  case 'online_gate_output_wrong_profile':
    useTargetProfile('existing_kubernetes/kit_installed/online');
    delete evidence.substrate_connection_truth;
    useOnlineGateOutput();
    break;
  case 'release_kit_output_extra_subject_file':
    break;
  case 'image_map_extra_subject_file':
    useImageMapOutput();
    break;
  case 'render_rollout_extra_subject_file':
    releaseKitOutput = 'render-report.json+rollout-report.json';
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = [
      {
        path: 'render-report.json',
        value: renderReport
      },
      {
        path: 'rollout-report.json',
        value: rolloutReport
      }
    ];
    break;
  case 'render_rollout_smoke_extra_subject_file':
    releaseKitOutput = 'render-report.json+rollout-report.json+smoke-report.json';
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = [
      {
        path: 'render-report.json',
        value: renderReport
      },
      {
        path: 'rollout-report.json',
        value: rolloutReport
      },
      {
        path: 'smoke-report.json',
        value: smokeReport
      }
    ];
    break;
  case 'render_rollout_smoke_missing_subject_file':
    releaseKitOutput = 'render-report.json+rollout-report.json+smoke-report.json';
    evidence.release_kit_output = releaseKitOutput;
    outputFiles = [
      {
        path: 'render-report.json',
        value: renderReport
      },
      {
        path: 'rollout-report.json',
        value: rolloutReport
      }
    ];
    break;
  case 'release_kit_output_missing_subject_file':
    releaseKitOutput = 'image-map.json';
    evidence.release_kit_output = releaseKitOutput;
    break;
  case 'missing_release_contract_digest':
    delete evidence.release_contract_digest;
    break;
  case 'missing_release_kit_output':
    delete evidence.release_kit_output;
    break;
  case 'v_prefixed_release_kit_version':
    evidence.release_kit_version = 'v0.1.0';
    break;
  case 'short_release_kit_version':
    evidence.release_kit_version = '0.1';
    break;
  case 'leading_zero_release_kit_version':
    evidence.release_kit_version = '0.01.0';
    break;
  case 'below_contract_release_kit_version':
    evidence.release_kit_version = '0.0.9';
    break;
  case 'unknown_release_kit_output':
    evidence.release_kit_output = 'unknown-output.json';
    break;
  case 'bundle_create_report_release_kit_output':
    evidence.release_kit_output = 'bundle-create-report.json';
    break;
  case 'airgap_bundle_load_plan_report_release_kit_output':
    evidence.release_kit_output = 'airgap-bundle-load-plan-report.json';
    break;
  case 'airgap_bundle_render_check_report_release_kit_output':
    evidence.release_kit_output = 'airgap-bundle-render-check-report.json';
    break;
  case 'product_flow_release_kit_output':
    evidence.release_kit_output = 'AgentSmith product flow aggregate';
    break;
  case 'missing_substrate_connection_truth':
    delete evidence.substrate_connection_truth;
    break;
  case 'substrate_truth_localhost_endpoint':
    evidence.substrate_connection_truth.services.postgresql.host = 'localhost';
    break;
  case 'evidence_target_host_docker_internal':
    evidence.target.base_url = 'https://host.docker.internal:3000';
    break;
  case 'evidence_json_bare_host_docker_internal':
    evidence.operator_note = 'declared by host.docker.internal';
    break;
  case 'substrate_truth_sslmode_only':
    useSslmodeOnly();
    break;
  case 'substrate_truth_redacted_fingerprint':
    useRedactedFingerprints();
    break;
  case 'reserved_agentsmith_adapter_schema':
    evidence.schema_version = 'agentsmith.release-kit-evidence/v1';
    break;
  case 'release_identity_mismatch':
    evidence.release_id = `${contract.release_id}-drift`;
    break;
  case 'target_profile_mismatch':
    evidence.target_cluster = 'kind_rehearsal';
    break;
  case 'status_failure_class_passed_wrong':
    evidence.failure_class = 'rollout_failed';
    break;
  case 'status_failure_class_failed_wrong':
    evidence.status = 'failed';
    evidence.failure_class = 'none';
    break;
  case 'product_flows_present':
    evidence.product_flows = ['workspace_project'];
    break;
  case 'wrong_producer_repo':
    break;
  case 'local_provenance_uri':
    provenanceArtifactUri = 'file://' + path.join(evidenceRoot, 'evidence-envelope.tgz');
    break;
  case 'github_api_provenance_uri':
    provenanceArtifactUri =
      'https://api.github.com/repos/agentsmith-project/agentsmith-release-kit/actions/runs/10001/artifacts';
    break;
  case 'wrong_artifact_uri_host':
    provenanceArtifactUri =
      'https://example.com/agentsmith-release-kit/actions/runs/10001/artifacts/evidence.zip';
    break;
  case 'wrong_artifact_uri_repo':
    provenanceArtifactUri =
      'https://api.github.com/repos/example/not-release-kit/actions/runs/10001/artifacts/evidence.zip';
    break;
  case 'repo_level_artifact_uri':
    provenanceArtifactUri =
      'https://api.github.com/repos/agentsmith-project/agentsmith-release-kit/actions/artifacts';
    break;
  case 'artifact_uri_run_id_mismatch':
    provenanceArtifactUri = 'gh-artifact://agentsmith-release-kit/evidence/99999/evidence-envelope.tgz';
    break;
  case 'signed_unbound_operator_run_uri':
    provenanceArtifactUri =
      'gh-artifact://agentsmith-release-kit/evidence/10001/evidence-envelope.tgz';
    break;
  case 'valid_secret_ref':
    evidence.target.pull_secret_ref = 'secretRef:release/registry-pull';
    break;
  case 'subject_file_secret_payload':
    onlineDeploymentGateReport.database =
      'postgres' + '://user:' + 'password' + '@db.example.internal:5432/appdb';
    break;
  case 'subject_file_source_payload':
    onlineDeploymentGateReport.source_path =
      '/home/percy/works/mbos-v1/' + 'agent' + 'smith/' + 'sr' + 'c/' + 'ap' + 'p/page.tsx';
    break;
  case 'subject_file_host_docker_internal':
    onlineDeploymentGateReport.endpoint = 'https://host.docker.internal:20000/status';
    break;
  case 'subject_file_bare_host_docker_internal':
    onlineDeploymentGateReport.operator_note = 'declared by host.docker.internal';
    break;
  case 'evidence_json_secret_payload':
    evidence['client_' + 'secret'] = 'not-real-credential-value';
    break;
  case 'signed_missing_signature':
    break;
  case 'missing_provenance_schema_version':
  case 'missing_commit_sha':
  case 'bad_provenance_commit_sha':
  case 'missing_subject_uri':
  case 'bad_subject_name':
  case 'old_subject_name':
  case 'missing_generated_at':
  case 'missing_generator_command':
  case 'missing_generator_version':
  case 'bad_attestation_object':
  case 'provenance_extra_field':
  case 'raw_evidence_file_sha':
    break;
  case 'subject_sha_mismatch':
  case 'subject_contains_artifact_provenance':
  case 'subject_missing_file':
  case 'subject_sha_mismatch_file':
  case 'subject_parent_path':
  case 'subject_absolute_path':
  case 'subject_symlink':
  case 'subject_hardlink':
    break;
  default:
    throw new Error(`unknown mutation: ${mutation}`);
}

if (
  outputFiles.some((outputFile) => outputFile.path === 'image-map.json') &&
  syncAirgapImageMapDigest
) {
  const imageMapDigest = jsonDigest(airgapImageMap);
  if (
    airgapBundleCheckReport.artifacts?.image_map &&
    Object.prototype.hasOwnProperty.call(
      airgapBundleCheckReport.artifacts.image_map,
      'input_sha256'
    )
  ) {
    airgapBundleCheckReport.artifacts.image_map.input_sha256 = imageMapDigest;
  }
  if (airgapBundleManifest.bindings) {
    airgapBundleManifest.bindings.image_map_sha256 = imageMapDigest;
  }
  const imageMapComponent = airgapBundleManifest.components?.find(
    (component) => component.kind === 'image_map'
  );
  if (imageMapComponent) {
    imageMapComponent.sha256 = imageMapDigest;
  }
}

if (
  outputFiles.some((outputFile) => outputFile.path === 'airgap-bundle-check-report.json') &&
  syncAirgapReportManifestDigest
) {
  airgapBundleCheckReport.artifacts.bundle_manifest.input_sha256 =
    jsonDigest(airgapBundleManifest);
}

const outputFilePaths = new Map();
const subjectEntries = [];
for (const outputFile of outputFiles) {
  const file = writeJson(outputFile.path, outputFile.value);
  outputFilePaths.set(outputFile.path, file);
  subjectEntries.push({
    path: outputFile.path,
    sha256: digestFile(file)
  });
}
const firstSubjectFile = outputFilePaths.get(subjectEntries[0].path);
const deployResultFile = outputFilePaths.get('deploy-result.json') || firstSubjectFile;
const firstSubjectPath = subjectEntries[0].path;

if (mutation === 'subject_missing_file') {
  subjectEntries.push({
    path: 'missing-result.json',
    sha256: `sha256:${'b'.repeat(64)}`
  });
}
if (mutation === 'subject_sha_mismatch_file') {
  subjectEntries[0].sha256 = `sha256:${'c'.repeat(64)}`;
}
if (mutation === 'subject_parent_path') {
  subjectEntries.push({
    path: '../escape.json',
    sha256: digestFile(deployResultFile)
  });
}
if (mutation === 'subject_absolute_path') {
  subjectEntries.push({
    path: '/tmp/evidence-result.json',
    sha256: digestFile(deployResultFile)
  });
}
if (mutation === 'subject_symlink') {
  fs.symlinkSync(firstSubjectPath, path.join(evidenceRoot, 'output-link.json'));
  subjectEntries.push({
    path: 'output-link.json',
    sha256: digestFile(deployResultFile)
  });
}
if (mutation === 'subject_hardlink') {
  const targetFile = writeJson('hardlink-target.json', { status: 'passed' });
  const hardlinkFile = path.join(evidenceRoot, 'hardlink-result.json');
  fs.linkSync(targetFile, hardlinkFile);
  subjectEntries.push({
    path: 'hardlink-result.json',
    sha256: digestFile(hardlinkFile)
  });
}
if (
  [
    'release_kit_output_extra_subject_file',
    'image_map_extra_subject_file',
    'render_rollout_extra_subject_file',
    'render_rollout_smoke_extra_subject_file'
  ].includes(mutation)
) {
  const extraFile = writeJson('extra-output.json', { status: 'passed' });
  subjectEntries.push({
    path: 'extra-output.json',
    sha256: digestFile(extraFile)
  });
}

const evidenceSubjectProjectionSha = canonicalDigest(withoutArtifactProvenance(evidence));
const subject = {
  schema_version: 'agentsmith.release-kit-evidence-subject/v1',
  files: [
    {
      path: 'evidence.json',
      sha256: evidenceSubjectProjectionSha
    },
    ...subjectEntries
  ]
};

if (mutation === 'subject_contains_artifact_provenance') {
  subject.artifact_provenance = {
    producer_repo: producerRepo
  };
}

let subjectSha = canonicalDigest(subject);
if (mutation === 'subject_sha_mismatch') {
  subjectSha = `sha256:${'d'.repeat(64)}`;
}

const provenance = {
  schema_version: 'agentsmith.artifact-provenance/v1',
  provenance_kind: kind,
  producer_repo: producerRepo,
  normalized_remote: producerRepo,
  commit_sha: releaseKitCommitSha,
  subject_name: 'release-kit-evidence-subject',
  subject_uri: 'evidence-subject.json',
  subject_sha256: subjectSha,
  artifact_uri: provenanceArtifactUri,
  generated_at: '2026-05-23T12:00:00.000Z',
  generator_command: 'bash scripts/verify-release.sh --evidence',
  generator_version: '0.1.0',
  attestation: 'none'
};

if (kind === 'ci_artifact') {
  Object.assign(provenance, {
    workflow_name: 'release-kit-evidence',
    run_id: '10001',
    run_attempt: '1',
    job: 'evidence'
  });
} else if (kind === 'signed_operator_run') {
  Object.assign(provenance, {
    operator_run_id: operatorRunId,
    operator_identity: 'release-operator@example.com',
    signature_uri: `https://signatures.example.com/agentsmith-release-kit/${operatorRunId}.sig`,
    signature_sha256: `sha256:${'a'.repeat(64)}`
  });
} else {
  throw new Error(`unknown provenance kind: ${kind}`);
}

if (mutation === 'wrong_producer_repo') {
  provenance.producer_repo = 'github.com/example/not-release-kit';
  provenance.normalized_remote = 'github.com/example/not-release-kit';
}
if (mutation === 'signed_missing_signature') {
  delete provenance.signature_uri;
}
if (mutation === 'missing_provenance_schema_version') {
  delete provenance.schema_version;
}
if (mutation === 'missing_commit_sha') {
  delete provenance.commit_sha;
}
if (mutation === 'bad_provenance_commit_sha') {
  provenance.commit_sha = 'not-a-git-sha';
}
if (mutation === 'missing_subject_uri') {
  delete provenance.subject_uri;
}
if (mutation === 'bad_subject_name') {
  provenance.subject_name = 'agentsmith-release-kit-render-report';
}
if (mutation === 'old_subject_name') {
  provenance.subject_name = 'agentsmith-release-kit-evidence';
}
if (mutation === 'missing_generated_at') {
  delete provenance.generated_at;
}
if (mutation === 'missing_generator_command') {
  delete provenance.generator_command;
}
if (mutation === 'missing_generator_version') {
  delete provenance.generator_version;
}
if (mutation === 'bad_attestation_object') {
  provenance.attestation = {
    attestation_uri: 'https://attestations.example.com/agentsmith-release-kit/evidence.intoto.jsonl',
    attestation_sha256: 'not-a-sha256-digest'
  };
}
if (mutation === 'provenance_extra_field') {
  provenance.readiness = true;
  provenance.verdict = 'release-ready';
  provenance.scope = 'release_readiness';
  provenance.product_flow_results = ['workspace_project'];
  provenance.operator_signoff = { status: 'approved' };
}

evidence.artifact_provenance = provenance;
const evidenceFile = writeJson('evidence.json', evidence);
if (mutation === 'raw_evidence_file_sha') {
  subject.files[0].sha256 = digestFile(evidenceFile);
  provenance.subject_sha256 = canonicalDigest(subject);
  writeJson('evidence.json', evidence);
}
writeJson('evidence-subject.json', subject);
NODE
}

VALID_CI_ROOT="$TMP_DIR/evidence-valid-ci"
VALID_CI_OUT="$TMP_DIR/out-valid-ci"
write_evidence "$VALID_CI_ROOT" ci_artifact valid
run_evidence "$VALID_CI_ROOT" "$VALID_CI_OUT" >/dev/null
assert_pass_report "$VALID_CI_OUT/evidence-validation-report.json"
pass "valid ci_artifact evidence accepted with focused non-readiness report"

VALID_GITHUB_API_ROOT="$TMP_DIR/evidence-valid-github-api"
VALID_GITHUB_API_OUT="$TMP_DIR/out-valid-github-api"
write_evidence "$VALID_GITHUB_API_ROOT" ci_artifact github_api_provenance_uri
run_evidence "$VALID_GITHUB_API_ROOT" "$VALID_GITHUB_API_OUT" >/dev/null
assert_pass_report "$VALID_GITHUB_API_OUT/evidence-validation-report.json"
pass "valid GitHub Actions artifact API provenance URI accepted"

VALID_SIGNED_ROOT="$TMP_DIR/evidence-valid-signed"
VALID_SIGNED_OUT="$TMP_DIR/out-valid-signed"
write_evidence "$VALID_SIGNED_ROOT" signed_operator_run valid
run_evidence "$VALID_SIGNED_ROOT" "$VALID_SIGNED_OUT" >/dev/null
assert_pass_report "$VALID_SIGNED_OUT/evidence-validation-report.json"
pass "valid signed_operator_run evidence accepted"

VALID_IMAGE_MAP_ROOT="$TMP_DIR/evidence-valid-image-map"
VALID_IMAGE_MAP_OUT="$TMP_DIR/out-valid-image-map"
write_evidence "$VALID_IMAGE_MAP_ROOT" ci_artifact valid_image_map_output
run_evidence "$VALID_IMAGE_MAP_ROOT" "$VALID_IMAGE_MAP_OUT" >/dev/null
assert_pass_report "$VALID_IMAGE_MAP_OUT/evidence-validation-report.json" "image-map.json"
pass "valid image-map release_kit_output evidence accepted"

VALID_AIRGAP_IMAGE_MAP_ROOT="$TMP_DIR/evidence-valid-airgap-image-map"
VALID_AIRGAP_IMAGE_MAP_OUT="$TMP_DIR/out-valid-airgap-image-map"
write_evidence "$VALID_AIRGAP_IMAGE_MAP_ROOT" ci_artifact valid_airgap_image_map_output
run_evidence "$VALID_AIRGAP_IMAGE_MAP_ROOT" "$VALID_AIRGAP_IMAGE_MAP_OUT" "$AIRGAP_PROFILE" >/dev/null
assert_pass_report "$VALID_AIRGAP_IMAGE_MAP_OUT/evidence-validation-report.json" "image-map.json"
pass "valid airgap image-map release_kit_output evidence accepted"

VALID_ONLINE_GATE_ROOT="$TMP_DIR/evidence-valid-online-gate"
VALID_ONLINE_GATE_OUT="$TMP_DIR/out-valid-online-gate"
write_evidence "$VALID_ONLINE_GATE_ROOT" ci_artifact valid_online_deployment_gate_output
run_evidence "$VALID_ONLINE_GATE_ROOT" "$VALID_ONLINE_GATE_OUT" >/dev/null
assert_pass_report "$VALID_ONLINE_GATE_OUT/evidence-validation-report.json" "online-deployment-gate-report.json"
pass "valid online deployment gate release_kit_output evidence accepted"

VALID_AIRGAP_BUNDLE_ROOT="$TMP_DIR/evidence-valid-airgap-bundle"
VALID_AIRGAP_BUNDLE_OUT="$TMP_DIR/out-valid-airgap-bundle"
write_evidence "$VALID_AIRGAP_BUNDLE_ROOT" ci_artifact valid_airgap_bundle_output
run_evidence "$VALID_AIRGAP_BUNDLE_ROOT" "$VALID_AIRGAP_BUNDLE_OUT" "$AIRGAP_PROFILE" >/dev/null
assert_pass_report "$VALID_AIRGAP_BUNDLE_OUT/evidence-validation-report.json" "airgap-bundle-check-report.json+airgap-bundle-manifest.json+image-map.json"
pass "valid airgap bundle check release_kit_output evidence accepted"

VALID_SECRET_REF_ROOT="$TMP_DIR/evidence-valid-secret-ref"
VALID_SECRET_REF_OUT="$TMP_DIR/out-valid-secret-ref"
write_evidence "$VALID_SECRET_REF_ROOT" ci_artifact valid_secret_ref
run_evidence "$VALID_SECRET_REF_ROOT" "$VALID_SECRET_REF_OUT" >/dev/null
assert_pass_report "$VALID_SECRET_REF_OUT/evidence-validation-report.json"
pass "valid persisted secretRef evidence accepted"

VALID_SSLMODE_ONLY_ROOT="$TMP_DIR/evidence-valid-sslmode-only"
VALID_SSLMODE_ONLY_OUT="$TMP_DIR/out-valid-sslmode-only"
write_evidence "$VALID_SSLMODE_ONLY_ROOT" ci_artifact substrate_truth_sslmode_only
run_evidence "$VALID_SSLMODE_ONLY_ROOT" "$VALID_SSLMODE_ONLY_OUT" >/dev/null
assert_pass_report "$VALID_SSLMODE_ONLY_OUT/evidence-validation-report.json"
pass "valid sslmode-only substrate truth evidence accepted"

VALID_REDACTED_FINGERPRINT_ROOT="$TMP_DIR/evidence-valid-redacted-fingerprint"
VALID_REDACTED_FINGERPRINT_OUT="$TMP_DIR/out-valid-redacted-fingerprint"
write_evidence "$VALID_REDACTED_FINGERPRINT_ROOT" ci_artifact substrate_truth_redacted_fingerprint
run_evidence "$VALID_REDACTED_FINGERPRINT_ROOT" "$VALID_REDACTED_FINGERPRINT_OUT" >/dev/null
assert_pass_report "$VALID_REDACTED_FINGERPRINT_OUT/evidence-validation-report.json"
pass "valid redacted fingerprint substrate truth evidence accepted"

expect_fail missing-release-contract-digest ci_artifact missing_release_contract_digest
expect_fail missing-release-kit-output ci_artifact missing_release_kit_output
expect_fail v-prefixed-release-kit-version ci_artifact v_prefixed_release_kit_version
expect_fail short-release-kit-version ci_artifact short_release_kit_version
expect_fail leading-zero-release-kit-version ci_artifact leading_zero_release_kit_version
expect_fail below-contract-release-kit-version ci_artifact below_contract_release_kit_version
expect_fail unknown-release-kit-output ci_artifact unknown_release_kit_output
expect_fail future-deploy-result-output ci_artifact future_deploy_result_output
expect_fail bundle-create-report-release-kit-output ci_artifact bundle_create_report_release_kit_output
expect_fail airgap-bundle-load-plan-report-release-kit-output ci_artifact airgap_bundle_load_plan_report_release_kit_output
expect_fail airgap-bundle-render-check-report-release-kit-output ci_artifact airgap_bundle_render_check_report_release_kit_output
expect_fail product-flow-release-kit-output ci_artifact product_flow_release_kit_output
expect_fail online-gate-wrong-schema ci_artifact online_gate_wrong_schema
expect_fail online-gate-wrong-scope ci_artifact online_gate_wrong_scope
expect_fail online-gate-wrong-readiness ci_artifact online_gate_wrong_readiness
expect_fail online-gate-wrong-status ci_artifact online_gate_wrong_status
expect_fail online-gate-release-digest-mismatch ci_artifact online_gate_release_digest_mismatch
expect_fail online-gate-report-target-profile-mismatch ci_artifact online_gate_report_target_profile_mismatch
expect_fail online-gate-stale-release-id ci_artifact online_gate_stale_release_id
expect_fail online-gate-stale-git-sha ci_artifact online_gate_stale_git_sha
expect_fail online-gate-missing-operator-run-id ci_artifact online_gate_missing_operator_run_id
expect_fail online-gate-operator-run-id-mismatch signed_operator_run online_gate_operator_run_id_mismatch
expect_fail online-gate-dry-run ci_artifact online_gate_dry_run
expect_fail online-gate-empty-steps ci_artifact online_gate_empty_steps
expect_fail image-map-mapping-missing ci_artifact image_map_mapping_missing
expect_fail image-map-digest-drift ci_artifact image_map_digest_drift
expect_fail image-map-target-registry-with-use-source ci_artifact image_map_target_registry_with_use_source
expect_fail image-map-use-source-target-drift ci_artifact image_map_use_source_target_drift
expect_fail image-map-mirror-target-drift ci_artifact image_map_mirror_target_drift
expect_fail standalone-airgap-image-map-use-source ci_artifact image_map_airgap_use_source "$AIRGAP_PROFILE"
expect_fail standalone-kind-image-map-output ci_artifact image_map_kind_rehearsal_output "$KIND_PROFILE"
expect_fail airgap-old-two-file-pair ci_artifact airgap_old_two_file_pair "$AIRGAP_PROFILE"
expect_fail airgap-image-map-missing ci_artifact airgap_image_map_missing "$AIRGAP_PROFILE"
expect_fail airgap-image-map-mirror-required-false ci_artifact airgap_image_map_mirror_required_false "$AIRGAP_PROFILE"
expect_fail airgap-manifest-target-image-drift ci_artifact airgap_manifest_target_image_drift "$AIRGAP_PROFILE"
expect_fail airgap-tools-empty ci_artifact airgap_tools_empty "$AIRGAP_PROFILE"
expect_fail airgap-manifest-release-digest-mismatch ci_artifact airgap_manifest_release_digest_mismatch "$AIRGAP_PROFILE"
expect_fail airgap-report-manifest-sha-mismatch ci_artifact airgap_report_manifest_sha_mismatch "$AIRGAP_PROFILE"
expect_fail airgap-manifest-target-profile-mismatch ci_artifact airgap_manifest_target_profile_mismatch "$AIRGAP_PROFILE"
expect_fail airgap-manifest-components-empty ci_artifact airgap_manifest_components_empty "$AIRGAP_PROFILE"
expect_fail airgap-image-artifact-declaration-missing ci_artifact airgap_image_artifact_declaration_missing "$AIRGAP_PROFILE"
expect_fail airgap-missing-required-payload-kind ci_artifact airgap_missing_required_payload_kind "$AIRGAP_PROFILE"
expect_fail airgap-report-payload-count-mismatch ci_artifact airgap_report_payload_count_mismatch "$AIRGAP_PROFILE"
expect_fail airgap-missing-image-map-artifact-digest ci_artifact airgap_missing_image_map_artifact_digest "$AIRGAP_PROFILE"
expect_fail airgap-component-sha-mismatch ci_artifact airgap_component_sha_mismatch "$AIRGAP_PROFILE"
expect_fail airgap-operator-ref-wget ci_artifact airgap_operator_ref_wget "$AIRGAP_PROFILE"
expect_fail airgap-operator-tool-proof-docker-pull ci_artifact airgap_operator_tool_proof_docker_pull "$AIRGAP_PROFILE"
expect_fail removed-render-rollout-output ci_artifact removed_render_rollout_output
expect_fail removed-render-rollout-smoke-output ci_artifact removed_render_rollout_smoke_output
WRONG_ONLINE_GATE_PROFILE_ROOT="$TMP_DIR/evidence-online-gate-wrong-profile"
WRONG_ONLINE_GATE_PROFILE_OUT="$TMP_DIR/out-online-gate-wrong-profile"
write_evidence "$WRONG_ONLINE_GATE_PROFILE_ROOT" ci_artifact online_gate_output_wrong_profile
if run_evidence "$WRONG_ONLINE_GATE_PROFILE_ROOT" "$WRONG_ONLINE_GATE_PROFILE_OUT" "existing_kubernetes/kit_installed/online" >"$TMP_DIR/online-gate-wrong-profile.out" 2>"$TMP_DIR/online-gate-wrong-profile.err"; then
  cat "$TMP_DIR/online-gate-wrong-profile.out" >&2
  cat "$TMP_DIR/online-gate-wrong-profile.err" >&2
  fail "expected online gate output on kit-installed profile to fail"
fi
pass "online gate evidence output rejects kit-installed profile"
expect_fail missing-substrate-connection-truth ci_artifact missing_substrate_connection_truth
expect_fail release-kit-output-missing-subject-file ci_artifact release_kit_output_missing_subject_file
expect_fail release-kit-output-extra-subject-file ci_artifact release_kit_output_extra_subject_file
expect_fail image-map-extra-subject-file ci_artifact image_map_extra_subject_file
expect_fail render-rollout-extra-subject-file ci_artifact render_rollout_extra_subject_file
expect_fail render-rollout-smoke-extra-subject-file ci_artifact render_rollout_smoke_extra_subject_file
expect_fail render-rollout-smoke-missing-subject-file ci_artifact render_rollout_smoke_missing_subject_file
expect_fail substrate-truth-localhost-endpoint ci_artifact substrate_truth_localhost_endpoint
expect_fail evidence-target-host-docker-internal ci_artifact evidence_target_host_docker_internal
expect_fail evidence-json-bare-host-docker-internal ci_artifact evidence_json_bare_host_docker_internal
expect_fail reserved-agentsmith-adapter-schema ci_artifact reserved_agentsmith_adapter_schema
expect_fail release-identity-mismatch ci_artifact release_identity_mismatch
expect_fail target-profile-mismatch ci_artifact target_profile_mismatch

expect_target_profile_fail noncanonical-local-kind 'local-kind/external_declared/online'
expect_target_profile_fail noncanonical-existing-cluster 'existing-cluster/external_declared/online'
expect_target_profile_fail noncanonical-real-k8s 'real-k8s/external_declared/online'
expect_target_profile_fail synonym-kind 'kind/external_declared/online'
expect_target_profile_fail synonym-cluster 'existing_kubernetes/cluster/online'

expect_fail status-failure-class-passed-wrong ci_artifact status_failure_class_passed_wrong
expect_fail status-failure-class-failed-wrong ci_artifact status_failure_class_failed_wrong
expect_fail product-flows-present ci_artifact product_flows_present
expect_fail wrong-producer-repo ci_artifact wrong_producer_repo
expect_fail local-provenance-uri ci_artifact local_provenance_uri
expect_fail wrong-artifact-uri-host ci_artifact wrong_artifact_uri_host
expect_fail wrong-artifact-uri-repo ci_artifact wrong_artifact_uri_repo
expect_fail repo-level-artifact-uri ci_artifact repo_level_artifact_uri
expect_fail artifact-uri-run-id-mismatch ci_artifact artifact_uri_run_id_mismatch
expect_fail provenance-extra-field ci_artifact provenance_extra_field
expect_fail missing-provenance-schema-version ci_artifact missing_provenance_schema_version
expect_fail missing-commit-sha ci_artifact missing_commit_sha
expect_fail bad-provenance-commit-sha ci_artifact bad_provenance_commit_sha
expect_fail missing-subject-uri ci_artifact missing_subject_uri
expect_fail bad-subject-name ci_artifact bad_subject_name
expect_fail old-subject-name ci_artifact old_subject_name
expect_fail missing-generated-at ci_artifact missing_generated_at
expect_fail missing-generator-command ci_artifact missing_generator_command
expect_fail missing-generator-version ci_artifact missing_generator_version
expect_fail bad-attestation-object ci_artifact bad_attestation_object
expect_fail signed-missing-signature signed_operator_run signed_missing_signature
expect_fail signed-wrong-artifact-host signed_operator_run wrong_artifact_uri_host
expect_fail signed-unbound-operator-run-uri signed_operator_run signed_unbound_operator_run_uri
expect_fail subject-sha-mismatch ci_artifact subject_sha_mismatch
expect_fail subject-contains-artifact-provenance ci_artifact subject_contains_artifact_provenance
expect_fail raw-evidence-file-sha ci_artifact raw_evidence_file_sha
expect_fail subject-missing-file ci_artifact subject_missing_file
expect_fail subject-sha-mismatch-file ci_artifact subject_sha_mismatch_file
expect_fail subject-parent-path ci_artifact subject_parent_path
expect_fail subject-absolute-path ci_artifact subject_absolute_path
expect_fail subject-symlink ci_artifact subject_symlink
expect_fail subject-hardlink ci_artifact subject_hardlink
expect_fail subject-file-secret-payload ci_artifact subject_file_secret_payload
expect_fail subject-file-source-payload ci_artifact subject_file_source_payload
expect_fail subject-file-host-docker-internal ci_artifact subject_file_host_docker_internal
expect_fail subject-file-bare-host-docker-internal ci_artifact subject_file_bare_host_docker_internal
expect_fail evidence-json-secret-payload ci_artifact evidence_json_secret_payload

if bash "$ROOT_DIR/scripts/verify-release.sh" >"$TMP_DIR/full-gate.out" 2>"$TMP_DIR/full-gate.err"; then
  fail "full release gate must remain unavailable"
fi
if ! grep -q 'full release gate is not implemented' "$TMP_DIR/full-gate.out"; then
  cat "$TMP_DIR/full-gate.out" >&2
  cat "$TMP_DIR/full-gate.err" >&2
  fail "full release gate failure must remain explicit"
fi
pass "evidence diagnostic is not release readiness"
