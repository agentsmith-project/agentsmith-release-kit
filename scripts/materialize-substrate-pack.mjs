#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { validateSubstrateInstallInputs, validateSubstrateResourceList } from './lib/substrate-install-input-validation.mjs';
import {
  SUBSTRATE_PACK_INSTALLED_BY,
  validateSubstratePackManifest,
  validateSubstratePackManifestMateriality
} from './lib/substrate-pack-manifest-validation.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_SOURCE_DIR = path.join(ROOT_DIR, 'substrate-packs/minimal');
const SOURCE_FILE = 'pack-source.json';
const SOURCE_SCHEMA = 'agentsmith.substrate-pack-source/minimal/v1';
const SUBSTRATE_TRUTH_SCHEMA = 'agentsmith.substrate-connection.truth/v1';
const SUBSTRATE_INSTALL_INPUTS_SCHEMA = 'agentsmith.substrate-install-inputs/v1';
const TARGET_PROFILES = new Map([
  ['online/install_substrates', 'existing_kubernetes/kit_installed/online'],
  ['airgap/install_substrates', 'existing_kubernetes/kit_installed/airgap']
]);
const REQUIRED_IMAGE_KEYS = [
  'postgresql',
  'mongodb',
  'redis',
  'object_storage',
  'oidc'
];
const SAFE_RELATIVE_PATH_RE = /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/;
const SAFE_TARGET_REGISTRY_RE =
  /^[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)*$/;
const SAFE_REPOSITORY_RE = /^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:\/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$/;
const KUBERNETES_NAMESPACE_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const INSTALLATION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const DIGEST_PINNED_IMAGE_RE = /^[^\s@]+@sha256:[0-9a-f]{64}$/;
const MATERIALIZED_FILES = {
  manifest: 'substrate-pack-manifest.json',
  installInputs: 'substrate-install-inputs.json',
  substrateTruth: 'substrate-truth.json',
  resourceList: 'templates/substrate-resources.json',
  installPlan: 'payload/install-substrates.json',
  routabilityProbe: 'tools/substrate-routability-probe.txt',
  checksums: 'checksums/materials.sha256'
};

class CliError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 2;
  }
}

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.exitCode = 1;
  }
}

function usage() {
  return `Usage:
  node scripts/materialize-substrate-pack.mjs \\
    --deployment-path <online/install_substrates|airgap/install_substrates> \\
    --output-dir <dir> \\
    --namespace <namespace> \\
    --installation-id <id> \\
    --storage-class <storage-class> \\
    [--source-dir substrate-packs/minimal] \\
    [--target-registry <registry-host[/namespace]> for airgap/install_substrates] \\
    [--verify-source-images [--skopeo <path-or-command>]] \\
    [--declared-by <operator-email>] \\
    [--declared-at <iso8601>]`;
}

function cliFail(message) {
  throw new CliError(message);
}

function fail(message) {
  throw new ValidationError(message);
}

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    cliFail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const args = {
    sourceDir: DEFAULT_SOURCE_DIR,
    declaredBy: 'release-operator@example.com',
    skopeo: 'skopeo',
    verifySourceImages: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };

    switch (arg) {
      case '--deployment-path':
        args.deploymentPath = nextValue();
        break;
      case '--output-dir':
        args.outputDir = nextValue();
        break;
      case '--namespace':
        args.namespace = nextValue();
        break;
      case '--installation-id':
        args.installationId = nextValue();
        break;
      case '--storage-class':
        args.storageClass = nextValue();
        break;
      case '--source-dir':
        args.sourceDir = nextValue();
        break;
      case '--target-registry':
        args.targetRegistry = nextValue();
        break;
      case '--verify-source-images':
        args.verifySourceImages = true;
        break;
      case '--skopeo':
        args.skopeo = nextValue();
        break;
      case '--declared-by':
        args.declaredBy = nextValue();
        break;
      case '--declared-at':
        args.declaredAt = nextValue();
        break;
      case '--help':
      case '-h':
        args.help = true;
        break;
      default:
        cliFail(`unknown argument: ${arg}`);
    }
  }

  return args;
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} is required`);
  }
  return value;
}

function assertAllowedKeys(object, allowedKeys, label) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.has(key)) {
      fail(`${label}.${key} is not allowed`);
    }
  }
}

function requireObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function assertSafeRelativePath(value, label) {
  const text = requireString(value, label);
  if (
    text !== text.trim() ||
    text.startsWith('/') ||
    /^[A-Za-z]:[\\/]/.test(text) ||
    text.includes('\\') ||
    text.includes('//') ||
    text.split('/').some((part) => part === '' || part === '.' || part === '..') ||
    !SAFE_RELATIVE_PATH_RE.test(text)
  ) {
    fail(`${label} must be a safe relative pack path`);
  }
  return text;
}

function assertDeploymentPath(value) {
  const deploymentPath = requireString(value, 'deployment_path');
  const targetProfile = TARGET_PROFILES.get(deploymentPath);
  if (!targetProfile) {
    fail('deployment_path must be online/install_substrates or airgap/install_substrates');
  }
  return {
    deploymentPath,
    targetProfile
  };
}

function assertNamespace(value) {
  const namespace = requireString(value, 'namespace');
  if (namespace.length > 63 || !KUBERNETES_NAMESPACE_RE.test(namespace)) {
    fail('namespace must be a Kubernetes namespace name');
  }
  return namespace;
}

function assertInstallationId(value) {
  const installationId = requireString(value, 'installation_id');
  if (!INSTALLATION_ID_RE.test(installationId)) {
    fail('installation_id must be a safe installation id');
  }
  return installationId;
}

function assertStorageClass(value) {
  const storageClass = requireString(value, 'storage_class');
  if (
    storageClass !== storageClass.trim() ||
    storageClass.startsWith('--') ||
    storageClass.length > 253 ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(storageClass)
  ) {
    fail('storage_class must be a safe storage class name');
  }
  return storageClass;
}

function assertDeclaredAt(value) {
  const declaredAt = value ?? new Date().toISOString();
  if (Number.isNaN(Date.parse(declaredAt))) {
    fail('declared_at must be an ISO-8601 timestamp');
  }
  return declaredAt;
}

function assertDeclaredBy(value) {
  const declaredBy = requireString(value, 'declared_by');
  if (/\s/.test(declaredBy) || declaredBy.includes('/') || declaredBy.includes('\\')) {
    fail('declared_by must be a public-safe operator identifier');
  }
  return declaredBy;
}

function assertTargetRegistry(value, deploymentPath) {
  if (deploymentPath === 'airgap/install_substrates') {
    const registry = requireString(value, 'target_registry');
    if (
      registry !== registry.trim() ||
      registry.includes('://') ||
      registry.includes('@') ||
      registry.includes('\\') ||
      registry.includes('//') ||
      registry.split('/').some((part) => part === '' || part === '.' || part === '..') ||
      !SAFE_TARGET_REGISTRY_RE.test(registry)
    ) {
      fail('target_registry must be a registry host[/namespace] without scheme, path escapes, or credentials');
    }
    return registry;
  }

  if (value !== undefined) {
    fail('target_registry is only accepted for airgap/install_substrates');
  }
  return undefined;
}

function splitTargetProfile(targetProfile) {
  const [targetCluster, substrateSource, distribution] = targetProfile.split('/');
  return {
    value: targetProfile,
    target_cluster: targetCluster,
    substrate_source: substrateSource,
    distribution
  };
}

async function readJson(file, label) {
  let raw;
  try {
    raw = await fs.readFile(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }

  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`invalid JSON in ${label}: ${error.message}`);
  }
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

async function digestFile(file) {
  return digestBuffer(await fs.readFile(file));
}

function stableJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

async function writeText(root, relativePath, content) {
  const file = path.join(root, relativePath);
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, content);
  return digestBuffer(Buffer.from(content));
}

async function writeJson(root, relativePath, value) {
  return writeText(root, relativePath, stableJson(value));
}

async function copyMaterialFile(sourceRoot, outputRoot, sourceRelativePath, outputRelativePath) {
  const sourceFile = path.join(sourceRoot, assertSafeRelativePath(sourceRelativePath, 'source material path'));
  const outputFile = path.join(outputRoot, outputRelativePath);
  await fs.mkdir(path.dirname(outputFile), { recursive: true });
  await fs.copyFile(sourceFile, outputFile);
  return digestFile(outputFile);
}

async function assertEmptyOrMissingDir(dir) {
  try {
    const entries = await fs.readdir(dir);
    if (entries.length > 0) {
      fail('output_dir must be empty or not exist');
    }
  } catch (error) {
    if (error.code !== 'ENOENT') {
      fail(`cannot inspect output_dir: ${error.message}`);
    }
  }
  await fs.mkdir(dir, { recursive: true });
}

function readTagAndDigest(imageRef, label) {
  if (!DIGEST_PINNED_IMAGE_RE.test(imageRef)) {
    fail(`${label} must be digest-pinned with @sha256`);
  }
  const [withoutDigest, digestHex] = imageRef.split('@sha256:');
  const lastSlash = withoutDigest.lastIndexOf('/');
  const lastColon = withoutDigest.lastIndexOf(':');
  if (lastColon <= lastSlash) {
    fail(`${label} must include a non-latest tag before @sha256`);
  }
  const tag = withoutDigest.slice(lastColon + 1);
  if (tag.toLowerCase() === 'latest') {
    fail(`${label} must not use latest`);
  }
  return {
    imageWithoutDigest: withoutDigest,
    tag,
    digest: `sha256:${digestHex}`
  };
}

function targetImageRef(sourceImage, targetRegistry, targetRepository, label) {
  const { tag, digest } = readTagAndDigest(sourceImage, label);
  if (!targetRegistry) {
    return sourceImage;
  }
  if (!SAFE_REPOSITORY_RE.test(targetRepository)) {
    fail(`${label}.target_repository must be a safe lowercase image repository`);
  }
  return `${targetRegistry}/${targetRepository}:${tag}@${digest}`;
}

function verifySourceImageDigest(imageRef, label, skopeo) {
  const { imageWithoutDigest, digest } = readTagAndDigest(imageRef, label);
  const result = spawnSync(
    skopeo,
    [
      'inspect',
      '--override-os',
      'linux',
      '--override-arch',
      'amd64',
      '--format',
      '{{.Digest}}',
      `docker://${imageWithoutDigest}`
    ],
    {
      encoding: 'utf8'
    }
  );

  if (result.error) {
    if (result.error.code === 'ENOENT') {
      fail('skopeo is required for --verify-source-images; install skopeo or omit --verify-source-images in environments that only materialize from pre-reviewed refs');
    }
    fail(`skopeo source image check failed for ${label}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || `exit ${result.status}`).trim();
    fail(`skopeo source image check failed for ${label}: ${detail}`);
  }

  const actualDigest = result.stdout.trim();
  if (actualDigest !== digest) {
    fail(`${label} digest mismatch: skopeo inspect returned ${actualDigest}, source ref declares ${digest}`);
  }
}

function verifySourceImages(source, skopeo) {
  for (const key of REQUIRED_IMAGE_KEYS) {
    verifySourceImageDigest(
      source.images[key].source_ref,
      `substrate_pack_source.images.${key}.source_ref`,
      skopeo
    );
  }
}

function loadSource(source) {
  const object = requireObject(source, 'substrate_pack_source');
  assertAllowedKeys(
    object,
    new Set([
      'schema_version',
      'release_kit_version',
      'name',
      'images',
      'install_plan_template',
      'resource_list_template',
      'routability_probe'
    ]),
    'substrate_pack_source'
  );
  if (object.schema_version !== SOURCE_SCHEMA) {
    fail(`substrate_pack_source.schema_version must be ${SOURCE_SCHEMA}`);
  }
  requireString(object.release_kit_version, 'substrate_pack_source.release_kit_version');
  if (object.name !== 'minimal') {
    fail('substrate_pack_source.name must be minimal');
  }
  assertSafeRelativePath(object.install_plan_template, 'substrate_pack_source.install_plan_template');
  assertSafeRelativePath(object.resource_list_template, 'substrate_pack_source.resource_list_template');
  assertSafeRelativePath(object.routability_probe, 'substrate_pack_source.routability_probe');

  const images = requireObject(object.images, 'substrate_pack_source.images');
  for (const key of REQUIRED_IMAGE_KEYS) {
    if (!Object.hasOwn(images, key)) {
      fail(`substrate_pack_source.images missing required image: ${key}`);
    }
    const image = requireObject(images[key], `substrate_pack_source.images.${key}`);
    assertAllowedKeys(
      image,
      new Set(['source_ref', 'target_repository']),
      `substrate_pack_source.images.${key}`
    );
    readTagAndDigest(
      requireString(image.source_ref, `substrate_pack_source.images.${key}.source_ref`),
      `substrate_pack_source.images.${key}.source_ref`
    );
    if (!SAFE_REPOSITORY_RE.test(requireString(
      image.target_repository,
      `substrate_pack_source.images.${key}.target_repository`
    ))) {
      fail(`substrate_pack_source.images.${key}.target_repository must be a safe lowercase image repository`);
    }
  }

  return object;
}

function renderTemplate(value, replacements, label) {
  if (typeof value === 'string') {
    return value.replace(/\{\{([A-Z0-9_]+)\}\}/g, (match, key) => {
      if (!Object.hasOwn(replacements, key)) {
        fail(`${label} contains unknown placeholder ${match}`);
      }
      return replacements[key];
    });
  }
  if (Array.isArray(value)) {
    return value.map((item, index) => renderTemplate(item, replacements, `${label}[${index}]`));
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [
        key,
        renderTemplate(nested, replacements, `${label}.${key}`)
      ])
    );
  }
  return value;
}

function secretRef(namespace, name) {
  return `secretRef:${namespace}/${name}`;
}

function reachabilityProof(serviceName) {
  return `kit materialized ${serviceName} cluster Service; operator readiness verification required after apply`;
}

function buildSubstrateTruth({
  declaredAt,
  declaredBy,
  installationId,
  namespace,
  releaseKitVersion,
  targetProfile
}) {
  const profile = splitTargetProfile(targetProfile);
  return {
    schema_version: SUBSTRATE_TRUTH_SCHEMA,
    target_cluster: profile.target_cluster,
    substrate_source: profile.substrate_source,
    distribution: profile.distribution,
    declared_at: declaredAt,
    declared_by: declaredBy,
    installed_by: SUBSTRATE_PACK_INSTALLED_BY,
    release_kit_version: releaseKitVersion,
    installation_id: installationId,
    services: {
      postgresql: {
        host: `postgresql.${namespace}.svc`,
        port: 5432,
        database: 'agentsmith',
        credential_secret_ref: secretRef(namespace, 'postgresql-app'),
        admin_secret_ref: secretRef(namespace, 'postgresql-admin'),
        sslmode: 'verify-full',
        tls: {
          mode: 'verify-full',
          ca_secret_ref: secretRef(namespace, 'postgresql-ca'),
          server_secret_ref: secretRef(namespace, 'postgresql-server-tls')
        },
        extensions: {
          pgvector: {
            status: 'installed',
            version: '0.7.4'
          }
        },
        reachability: {
          status: 'declared_reachable',
          proof: reachabilityProof('postgresql')
        }
      },
      mongodb: {
        host: `mongodb.${namespace}.svc`,
        port: 27017,
        credential_secret_ref: secretRef(namespace, 'mongodb-app'),
        tls: {
          mode: 'verify-full',
          ca_secret_ref: secretRef(namespace, 'mongodb-ca'),
          server_secret_ref: secretRef(namespace, 'mongodb-server-tls')
        },
        reachability: {
          status: 'declared_reachable',
          proof: reachabilityProof('mongodb')
        }
      },
      redis: {
        host: `redis.${namespace}.svc`,
        port: 6379,
        credential_secret_ref: secretRef(namespace, 'redis-app'),
        tls: {
          mode: 'verify-full',
          ca_secret_ref: secretRef(namespace, 'redis-ca'),
          server_secret_ref: secretRef(namespace, 'redis-server-tls')
        },
        reachability: {
          status: 'declared_reachable',
          proof: reachabilityProof('redis')
        }
      },
      object_storage: {
        url: `https://object-storage.${namespace}.svc:9000`,
        bucket: 'agentsmith',
        region: 'local',
        credential_secret_ref: secretRef(namespace, 'object-storage-app'),
        tls: {
          mode: 'https',
          ca_secret_ref: secretRef(namespace, 'object-storage-ca'),
          server_secret_ref: secretRef(namespace, 'object-storage-server-tls')
        },
        reachability: {
          status: 'declared_reachable',
          proof: reachabilityProof('object-storage')
        }
      },
      oidc: {
        issuer_url: `https://oidc.${namespace}.svc:8443/realms/agentsmith`,
        client_id: 'agentsmith',
        admin_secret_ref: secretRef(namespace, 'oidc-admin'),
        client_secret_ref: secretRef(namespace, 'oidc-client'),
        tls: {
          mode: 'https',
          ca_secret_ref: secretRef(namespace, 'oidc-ca'),
          server_secret_ref: secretRef(namespace, 'oidc-server-tls')
        },
        reachability: {
          status: 'declared_reachable',
          proof: reachabilityProof('oidc')
        }
      }
    }
  };
}

function imageReplacements(images) {
  return {
    IMAGE_POSTGRESQL: images.postgresql,
    IMAGE_MONGODB: images.mongodb,
    IMAGE_REDIS: images.redis,
    IMAGE_OBJECT_STORAGE: images.object_storage,
    IMAGE_OIDC: images.oidc
  };
}

async function writeChecksumsFile(outputDir, files) {
  const lines = [];
  for (const relativePath of files) {
    lines.push(`${await digestFile(path.join(outputDir, relativePath))}  ${relativePath}`);
  }
  lines.sort();
  return writeText(outputDir, MATERIALIZED_FILES.checksums, `${lines.join('\n')}\n`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  const { deploymentPath, targetProfile } = assertDeploymentPath(args.deploymentPath);
  const namespace = assertNamespace(args.namespace);
  const installationId = assertInstallationId(args.installationId);
  const storageClass = assertStorageClass(args.storageClass);
  const declaredAt = assertDeclaredAt(args.declaredAt);
  const declaredBy = assertDeclaredBy(args.declaredBy);
  const targetRegistry = assertTargetRegistry(args.targetRegistry, deploymentPath);
  const sourceDir = path.resolve(requireString(args.sourceDir, 'source_dir'));
  const outputDir = path.resolve(requireString(args.outputDir, 'output_dir'));

  await assertEmptyOrMissingDir(outputDir);

  const source = loadSource(await readJson(path.join(sourceDir, SOURCE_FILE), 'substrate pack source'));
  if (args.verifySourceImages) {
    verifySourceImages(source, requireString(args.skopeo, 'skopeo'));
  }
  const images = Object.fromEntries(REQUIRED_IMAGE_KEYS.map((key) => [
    key,
    targetImageRef(
      source.images[key].source_ref,
      targetRegistry,
      source.images[key].target_repository,
      `substrate_pack_source.images.${key}`
    )
  ]));

  const replacements = {
    DEPLOYMENT_PATH: deploymentPath,
    TARGET_PROFILE: targetProfile,
    INSTALLATION_ID: installationId,
    NAMESPACE: namespace,
    STORAGE_CLASS: storageClass,
    ...imageReplacements(images)
  };

  const installPlanTemplate = await readJson(
    path.join(sourceDir, source.install_plan_template),
    'substrate install plan template'
  );
  const resourceListTemplate = await readJson(
    path.join(sourceDir, source.resource_list_template),
    'substrate resource list template'
  );

  const installPlan = renderTemplate(installPlanTemplate, replacements, 'install_plan_template');
  const resourceList = renderTemplate(resourceListTemplate, replacements, 'resource_list_template');
  const substrateTruth = buildSubstrateTruth({
    declaredAt,
    declaredBy,
    installationId,
    namespace,
    releaseKitVersion: source.release_kit_version,
    targetProfile
  });
  const installInputs = {
    schema_version: SUBSTRATE_INSTALL_INPUTS_SCHEMA,
    target_profile: targetProfile,
    installation_id: installationId,
    substrate_truth: substrateTruth,
    resource_list_path: MATERIALIZED_FILES.resourceList
  };

  const installPlanSha = await writeJson(outputDir, MATERIALIZED_FILES.installPlan, installPlan);
  const resourceListSha = await writeJson(outputDir, MATERIALIZED_FILES.resourceList, resourceList);
  await writeJson(outputDir, MATERIALIZED_FILES.substrateTruth, substrateTruth);
  await writeJson(outputDir, MATERIALIZED_FILES.installInputs, installInputs);
  const probeSha = await copyMaterialFile(
    sourceDir,
    outputDir,
    source.routability_probe,
    MATERIALIZED_FILES.routabilityProbe
  );
  const checksumsSha = await writeChecksumsFile(outputDir, [
    MATERIALIZED_FILES.installPlan,
    MATERIALIZED_FILES.resourceList,
    MATERIALIZED_FILES.substrateTruth,
    MATERIALIZED_FILES.installInputs,
    MATERIALIZED_FILES.routabilityProbe
  ]);

  const manifest = {
    schema_version: 'agentsmith.substrate-pack-manifest/v1',
    release_kit_version: source.release_kit_version,
    installed_by: SUBSTRATE_PACK_INSTALLED_BY,
    deployment_path: deploymentPath,
    images,
    payload: {
      install_plan: {
        path: MATERIALIZED_FILES.installPlan,
        sha256: installPlanSha
      }
    },
    templates: {
      resource_list: {
        path: MATERIALIZED_FILES.resourceList,
        sha256: resourceListSha
      }
    },
    tools: {
      routability_probe: {
        path: MATERIALIZED_FILES.routabilityProbe,
        sha256: probeSha
      }
    },
    checksums: {
      materials: {
        path: MATERIALIZED_FILES.checksums,
        sha256: checksumsSha
      }
    }
  };

  await writeJson(outputDir, MATERIALIZED_FILES.manifest, manifest);

  const targetProfileObject = splitTargetProfile(targetProfile);
  validateSubstratePackManifest(manifest, targetProfileObject, { fail });
  await validateSubstratePackManifestMateriality(manifest, {
    fail,
    packRoot: outputDir
  });
  validateSubstrateInstallInputs(installInputs, targetProfileObject, { fail });
  validateSubstrateResourceList(resourceList, { fail });

  console.log(stableJson({
    status: 'pass',
    deployment_path: deploymentPath,
    target_profile: targetProfile,
    output_dir: outputDir,
    files: Object.values(MATERIALIZED_FILES)
  }).trimEnd());
}

main().catch((error) => {
  const exitCode = error.exitCode || 1;
  console.error(error.message);
  process.exit(exitCode);
});
