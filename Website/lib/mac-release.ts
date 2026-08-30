import releaseManifest from '../release/mac-release.json';
import { validateMacReleaseManifest } from './mac-release-policy.mjs';

export function getVerifiedMacRelease() {
  return validateMacReleaseManifest(
    releaseManifest,
    process.env.FOUNDER_OFFICE_APPROVED_DOWNLOAD_ORIGIN,
  );
}
