import { ArrowLeft } from 'lucide-react';
import Link from 'next/link';

export default function SecurityPage() {
  return (
    <main className="policy-shell">
      <Link className="policy-back" href="/">
        <ArrowLeft aria-hidden="true" /> Founder&apos;s Office
      </Link>
      <article className="policy-page">
        <span className="eyebrow">Security</span>
        <h1>Trust is a release requirement.</h1>
        <p className="policy-lede">
          The Mac download stays closed until signing, notarization, sandbox,
          entitlement, upgrade, recovery, and clean-install checks pass against
          one sealed artifact.
        </p>
        <section>
          <h2>Report responsibly</h2>
          <p>
            During the private beta, use the security contact supplied in the
            invitation. A dedicated public reporting address and disclosure
            policy will be published before general availability. Never include
            credentials or another person&apos;s data in a report.
          </p>
        </section>
        <section>
          <h2>Automatic repair boundary</h2>
          <p>
            The installed app may perform only deterministic, allowlisted
            recovery actions. AI-generated code changes belong in isolated,
            tested pull requests with human review; the customer app does not
            rewrite its own executable.
          </p>
        </section>
      </article>
    </main>
  );
}
