'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { fileURLToPath } = require('node:url');
const { syncBuiltinESMExports } = require('node:module');

const LARGE_FILE_LIMIT = 2 * 1024 * 1024 * 1024;
const streamSource = process.env.RELEASE_KIT_TEST_LARGE_STREAM_SOURCE;

function pathFor(file) {
  if (file instanceof URL) {
    return fileURLToPath(file);
  }
  if (Buffer.isBuffer(file)) {
    return file.toString('utf8');
  }
  if (typeof file === 'string') {
    return file;
  }
  return undefined;
}

function isLargeFixture(file) {
  const filePath = pathFor(file);
  if (!filePath) {
    return false;
  }
  try {
    const stat = fs.statSync(filePath);
    return stat.isFile() && stat.size > LARGE_FILE_LIMIT;
  } catch {
    return false;
  }
}

function readFileError(file) {
  return new Error(`fs.readFile called on >2GiB test fixture: ${pathFor(file)}`);
}

const originalReadFile = fsp.readFile.bind(fsp);
fsp.readFile = async function guardedReadFile(file, ...args) {
  if (isLargeFixture(file)) {
    throw readFileError(file);
  }
  return originalReadFile(file, ...args);
};
fs.promises.readFile = fsp.readFile;

const originalReadFileSync = fs.readFileSync.bind(fs);
fs.readFileSync = function guardedReadFileSync(file, ...args) {
  if (isLargeFixture(file)) {
    throw readFileError(file);
  }
  return originalReadFileSync(file, ...args);
};

const originalCreateReadStream = fs.createReadStream.bind(fs);
fs.createReadStream = function guardedCreateReadStream(file, ...args) {
  if (isLargeFixture(file)) {
    if (!streamSource) {
      throw new Error('RELEASE_KIT_TEST_LARGE_STREAM_SOURCE is required for large fixture streams');
    }
    return originalCreateReadStream(streamSource, ...args);
  }
  return originalCreateReadStream(file, ...args);
};

const originalCopyFile = fsp.copyFile.bind(fsp);
fsp.copyFile = async function guardedCopyFile(source, destination, mode) {
  if (!isLargeFixture(source)) {
    return originalCopyFile(source, destination, mode);
  }

  const sourcePath = pathFor(source);
  const destinationPath = pathFor(destination);
  if (!sourcePath || !destinationPath) {
    return originalCopyFile(source, destination, mode);
  }

  const stat = fs.statSync(sourcePath);
  await fsp.mkdir(path.dirname(destinationPath), { recursive: true });
  const handle = await fsp.open(destinationPath, 'w');
  try {
    await handle.truncate(stat.size);
  } finally {
    await handle.close();
  }
};
fs.promises.copyFile = fsp.copyFile;

syncBuiltinESMExports();
