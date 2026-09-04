import assert from 'node:assert/strict';

import { validateMacReleaseManifest } from '../lib/mac-release-policy.mjs';

const commit = 'a'.repeat(40);
const valid = {
  schemaVersion: 2,
  available: true,
  verifiedFromCanonicalManifest: true,
  signedAndNotarized: true,
  cleanMacAccepted: true,
  acceptanceAttestation: 'operator-confirmed',
  version: '1.2.3',
  build: 7,
  teamID: 'AB12CD34EF',
  sha256: 'b'.repeat(64),
  artifactFileName: 'FoundersOffice-1.2.3-build-7-macOS.zip',
  artifactSizeBytes: 1024,
  releaseCommit: commit,
  sourceManifestSHA256: 'c'.repeat(64),
  acceptanceRecordSHA256: 'd'.repeat(64),
  canonicalManifestURL: `https://downloads.example.com/releases/macos/v1.2.3/build-7/${commit}/release.json`,
  acceptanceRecordURL: `https://downloads.example.com/releases/macos/v1.2.3/build-7/${commit}/clean-mac-acceptance.json`,
  downloadURL: `https://downloads.example.com/releases/macos/v1.2.3/build-7/${commit}/FoundersOffice-1.2.3-build-7-macOS.zip`,
};

assert.equal(validateMacReleaseManifest(valid, undefined), null);
assert.equal(
  validateMacReleaseManifest(valid, 'http://downloads.example.com'),
  null,
);
assert.equal(
  validateMacReleaseManifest(valid, 'https://downloads.example.com').version,
  '1.2.3',
);

for (const mutation of [
  { available: false },
  { verifiedFromCanonicalManifest: false },
  { signedAndNotarized: false },
  { cleanMacAccepted: false },
  { acceptanceAttestation: 'cryptographic' },
  { artifactFileName: 'latest.zip' },
  { sourceManifestSHA256: '' },
  { acceptanceRecordSHA256: '' },
  {
    canonicalManifestURL: 'https://downloads.example.com/releases/latest.json',
  },
  {
    acceptanceRecordURL: 'https://downloads.example.com/acceptance/latest.json',
  },
  { downloadURL: `${valid.downloadURL}?cache=latest` },
  { downloadURL: valid.downloadURL.replace(commit, 'latest') },
  {
    downloadURL: valid.downloadURL.replace(
      `/${commit}/`,
      `/ignored/../${commit}/`,
    ),
  },
  {
    downloadURL: valid.downloadURL.replace(
      'downloads.example.com',
      'evil.example',
    ),
  },
  { unexpected: true },
]) {
  assert.equal(
    validateMacReleaseManifest(
      { ...valid, ...mutation },
      'https://downloads.example.com',
    ),
    null,
  );
}

for (const origin of [
  'https://DOWNLOADS.example.com',
  'https://downloads.example.com:443',
  'https://downloads.example.com/',
  'https://downloads.example.com.',
]) {
  assert.equal(validateMacReleaseManifest(valid, origin), null);
}

console.log('Mac website release gate denied every unsafe fixture.');
