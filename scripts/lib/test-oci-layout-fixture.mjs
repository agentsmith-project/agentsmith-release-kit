#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const TAR_BLOCK_SIZE = 512;
const VARIANTS = new Set(['valid', 'missing-layer', 'manifest-only']);

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function usage() {
  return `Usage:
  node scripts/lib/test-oci-layout-fixture.mjs --from-contract <json> --output-dir <dir>
  node scripts/lib/test-oci-layout-fixture.mjs --archive <tar> --image-id <id> --target-digest <sha256> [--variant valid|missing-layer|manifest-only]
  node scripts/lib/test-oci-layout-fixture.mjs --bundle-root <dir> --image-id <id> [--target-digest <sha256>] [--variant valid|missing-layer|manifest-only]`;
}

function readArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (!value || value.trim() === '' || value.startsWith('--')) {
    fail(`missing value for ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const args = { variant: 'valid' };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = () => {
      const value = readArgValue(argv, index, arg);
      index += 1;
      return value;
    };
    switch (arg) {
      case '--from-contract':
        args.fromContract = nextValue();
        break;
      case '--output-dir':
        args.outputDir = nextValue();
        break;
      case '--archive':
        args.archive = nextValue();
        break;
      case '--bundle-root':
        args.bundleRoot = nextValue();
        break;
      case '--image-id':
        args.imageId = nextValue();
        break;
      case '--target-digest':
        args.targetDigest = nextValue();
        break;
      case '--variant':
        args.variant = nextValue();
        break;
      case '--help':
      case '-h':
        args.help = true;
        break;
      default:
        fail(`unknown argument: ${arg}`);
    }
  }
  if (!VARIANTS.has(args.variant)) {
    fail(`--variant must be one of: ${[...VARIANTS].join(', ')}`);
  }
  return args;
}

function digestBuffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function writeOctal(buffer, offset, length, value) {
  const text = value.toString(8).padStart(length - 1, '0').slice(-(length - 1));
  buffer.write(text, offset, length - 1, 'ascii');
  buffer[offset + length - 1] = 0;
}

function tarHeader(name, contentLength) {
  if (Buffer.byteLength(name) > 100) {
    fail(`fixture tar entry name is too long: ${name}`);
  }
  const header = Buffer.alloc(TAR_BLOCK_SIZE, 0);
  header.write(name, 0, 100, 'utf8');
  writeOctal(header, 100, 8, 0o644);
  writeOctal(header, 108, 8, 0);
  writeOctal(header, 116, 8, 0);
  writeOctal(header, 124, 12, contentLength);
  writeOctal(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  header[156] = '0'.charCodeAt(0);
  header.write('ustar', 257, 5, 'ascii');
  header[262] = 0;
  header.write('00', 263, 2, 'ascii');

  let checksum = 0;
  for (const byte of header) {
    checksum += byte;
  }
  const checksumText = checksum.toString(8).padStart(6, '0').slice(-6);
  header.write(checksumText, 148, 6, 'ascii');
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

function tarEntry(name, content) {
  const body = Buffer.isBuffer(content) ? content : Buffer.from(content);
  const paddingLength = (TAR_BLOCK_SIZE - (body.length % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE;
  return Buffer.concat([tarHeader(name, body.length), body, Buffer.alloc(paddingLength, 0)]);
}

function blobPath(digest) {
  return `blobs/sha256/${digest.slice('sha256:'.length)}`;
}

function writeOciLayoutArchive({ archivePath, imageId, targetDigest, variant }) {
  if (!DIGEST_RE.test(targetDigest)) {
    fail(`invalid target digest for ${imageId}: ${targetDigest}`);
  }

  const layerContent = Buffer.from(`fixture layer for ${imageId}\n`);
  const layerDigest = digestBuffer(layerContent);
  const config = {
    architecture: 'amd64',
    os: 'linux',
    rootfs: {
      type: 'layers',
      diff_ids: [layerDigest]
    },
    config: {
      Labels: {
        'io.agentsmith.fixture.image_id': imageId
      }
    }
  };
  const configBuffer = Buffer.from(`${JSON.stringify(config)}\n`);
  const configDigest = digestBuffer(configBuffer);
  const layers =
    variant === 'manifest-only'
      ? []
      : [
          {
            mediaType: 'application/vnd.oci.image.layer.v1.tar',
            digest: layerDigest,
            size: layerContent.length
          }
        ];
  const manifest = {
    schemaVersion: 2,
    mediaType: 'application/vnd.oci.image.manifest.v1+json',
    config: {
      mediaType: 'application/vnd.oci.image.config.v1+json',
      digest: configDigest,
      size: configBuffer.length
    },
    layers
  };
  const manifestBuffer = Buffer.from(`${JSON.stringify(manifest)}\n`);
  const manifestDigest = digestBuffer(manifestBuffer);
  const index = {
    schemaVersion: 2,
    mediaType: 'application/vnd.oci.image.index.v1+json',
    manifests: [
      {
        mediaType: 'application/vnd.oci.image.manifest.v1+json',
        digest: manifestDigest,
        size: manifestBuffer.length,
        annotations: {
          'org.opencontainers.image.ref.name': imageId,
          'io.agentsmith.fixture.target_digest': targetDigest
        }
      }
    ]
  };
  const layout = {
    imageLayoutVersion: '1.0.0'
  };

  const entries = [
    tarEntry('oci-layout', `${JSON.stringify(layout)}\n`),
    tarEntry('index.json', `${JSON.stringify(index)}\n`),
    tarEntry(blobPath(manifestDigest), manifestBuffer),
    tarEntry(blobPath(configDigest), configBuffer)
  ];
  if (variant === 'valid') {
    entries.push(tarEntry(blobPath(layerDigest), layerContent));
  }

  fs.mkdirSync(path.dirname(archivePath), { recursive: true });
  fs.writeFileSync(archivePath, Buffer.concat([...entries, Buffer.alloc(TAR_BLOCK_SIZE * 2, 0)]));
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function writeFromContract(args) {
  if (!args.fromContract || !args.outputDir) {
    fail('--from-contract requires --output-dir');
  }
  const contract = readJson(args.fromContract);
  const inventory = Array.isArray(contract.deploy_image_inventory)
    ? contract.deploy_image_inventory
    : [];
  if (inventory.length === 0) {
    fail('contract deploy_image_inventory must not be empty');
  }
  for (const image of inventory) {
    if (!image?.id || !image?.digest) {
      fail('contract deploy_image_inventory entries must include id and digest');
    }
    writeOciLayoutArchive({
      archivePath: path.join(args.outputDir, `${image.id}.oci-layout.tar`),
      imageId: image.id,
      targetDigest: image.digest,
      variant: args.variant
    });
  }
}

function writeDirectArchive(args) {
  if (!args.archive || !args.imageId || !args.targetDigest) {
    fail('--archive requires --image-id and --target-digest');
  }
  writeOciLayoutArchive({
    archivePath: args.archive,
    imageId: args.imageId,
    targetDigest: args.targetDigest,
    variant: args.variant
  });
}

function writeBundleArchive(args) {
  if (!args.bundleRoot || !args.imageId) {
    fail('--bundle-root requires --image-id');
  }
  const manifestPath = path.join(args.bundleRoot, 'airgap-bundle-manifest.json');
  const manifest = readJson(manifestPath);
  const declaration = manifest.image_artifact_declarations?.find(
    (item) => item.id === args.imageId
  );
  if (!declaration) {
    fail(`missing image declaration: ${args.imageId}`);
  }
  const targetDigest = args.targetDigest || declaration.target_digest;
  const archivePath = path.join(args.bundleRoot, ...declaration.path.split('/'));
  writeOciLayoutArchive({
    archivePath,
    imageId: args.imageId,
    targetDigest,
    variant: args.variant
  });
  declaration.sha256 = digestBuffer(fs.readFileSync(archivePath));
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }
  if (args.fromContract) {
    writeFromContract(args);
    return;
  }
  if (args.bundleRoot) {
    writeBundleArchive(args);
    return;
  }
  writeDirectArchive(args);
}

main();
