import { getVerifiedMacRelease } from '../lib/mac-release';
import { FoundersOfficeExperience } from './founders-office-experience';

export default function Home() {
  const macRelease = getVerifiedMacRelease();

  return (
    <FoundersOfficeExperience
      downloadURL={macRelease ? macRelease.downloadURL : null}
    />
  );
}
