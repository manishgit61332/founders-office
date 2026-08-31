/**
 * @typedef {object} VerifiedMacRelease
 * @property {string} downloadURL
 * @property {string} version
 * @property {number} build
 * @property {string} sha256
 * @property {string} teamID
 * @property {number} sizeBytes
 */

const expectedKeys = new Set([
  'schemaVersion',
  'available',
  'verifiedFromCanonicalManifest',
  'signedAndNotarized',
  'cleanMacAccepted',
  'version',
  'build',
  'teamID',
  'sha256',
  'artifactFileName',
  'artifactSizeBytes',
  'releaseCommit',
  'sourceManifestSHA256',
  'acceptanceRecordSHA256',
  'acceptanceRecordURL',
  'downloadURL',
]);

/** @param {unknown} value */
function isRecord(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Keep the download fail-closed. This parser accepts only the exact output of
 * Scripts/prepare-website-mac-release.py and an independently configured origin.
 *
 * @param {unknown} candidate
 * @param {string | undefined} approvedOrigin
 * @returns {VerifiedMacRelease | null}
 */
export function validateMacReleaseManifest(candidate, approvedOrigin) {
  if (!isRecord(candidate) || typeof approvedOrigin !== 'string') {
    return null;
  }

  if (
    Object.keys(candidate).length !== expectedKeys.size ||
    Object.keys(candidate).some((key) => !expectedKeys.has(key)) ||
    candidate.schemaVersion !== 2 ||
    candidate.available !== true ||
    candidate.verifiedFromCanonicalManifest !== true ||
    candidate.signedAndNotarized !== true ||
    candidate.cleanMacAccepted !== true ||
    typeof candidate.version !== 'string' ||
    !/^\d+\.\d+\.\d+$/.test(candidate.version) ||
    !Number.isSafeInteger(candidate.build) ||
    candidate.build < 1 ||
    typeof candidate.teamID !== 'string' ||
    !/^[A-Z0-9]{10}$/.test(candidate.teamID) ||
    typeof candidate.sha256 !== 'string' ||
    !/^[a-f0-9]{64}$/.test(candidate.sha256) ||
    typeof candidate.sourceManifestSHA256 !== 'string' ||
    !/^[a-f0-9]{64}$/.test(candidate.sourceManifestSHA256) ||
    typeof candidate.acceptanceRecordSHA256 !== 'string' ||
    !/^[a-f0-9]{64}$/.test(candidate.acceptanceRecordSHA256) ||
    typeof candidate.acceptanceRecordURL !== 'string' ||
    typeof candidate.releaseCommit !== 'string' ||
    !/^[a-f0-9]{40}$/.test(candidate.releaseCommit) ||
    !Number.isSafeInteger(candidate.artifactSizeBytes) ||
    candidate.artifactSizeBytes < 1 ||
    typeof candidate.artifactFileName !== 'string' ||
    typeof candidate.downloadURL !== 'string'
  ) {
    return null;
  }

  const expectedFileName = `FoundersOffice-${candidate.version}-build-${candidate.build}-macOS.zip`;
  if (candidate.artifactFileName !== expectedFileName) {
    return null;
  }

  try {
    const downloadURL = new URL(candidate.downloadURL);
    const acceptanceRecordURL = new URL(candidate.acceptanceRecordURL);
    const origin = new URL(approvedOrigin);
    const expectedPath = `/releases/macos/v${candidate.version}/build-${candidate.build}/${candidate.releaseCommit}/${expectedFileName}`;
    const expectedAcceptancePath = `/releases/macos/v${candidate.version}/build-${candidate.build}/${candidate.releaseCommit}/clean-mac-acceptance.json`;

    if (
      downloadURL.protocol !== 'https:' ||
      origin.protocol !== 'https:' ||
      origin.username !== '' ||
      origin.password !== '' ||
      origin.pathname !== '/' ||
      origin.search !== '' ||
      origin.hash !== '' ||
      downloadURL.username !== '' ||
      downloadURL.password !== '' ||
      downloadURL.origin !== origin.origin ||
      downloadURL.pathname !== expectedPath ||
      downloadURL.search !== '' ||
      downloadURL.hash !== '' ||
      acceptanceRecordURL.protocol !== 'https:' ||
      acceptanceRecordURL.username !== '' ||
      acceptanceRecordURL.password !== '' ||
      acceptanceRecordURL.origin !== origin.origin ||
      acceptanceRecordURL.pathname !== expectedAcceptancePath ||
      acceptanceRecordURL.search !== '' ||
      acceptanceRecordURL.hash !== ''
    ) {
      return null;
    }

    return {
      downloadURL: downloadURL.toString(),
      version: candidate.version,
      build: candidate.build,
      sha256: candidate.sha256,
      teamID: candidate.teamID,
      sizeBytes: candidate.artifactSizeBytes,
    };
  } catch {
    return null;
  }
}
