import { ArrowLeft } from 'lucide-react';
import Link from 'next/link';

export default function PrivacyPage() {
  return (
    <main className="policy-shell">
      <Link className="policy-back" href="/">
        <ArrowLeft aria-hidden="true" /> Founder&apos;s Office
      </Link>
      <article className="policy-page">
        <span className="eyebrow">Privacy before launch</span>
        <h1>Your workspace is not advertising inventory.</h1>
        <p className="policy-lede">
          Founder&apos;s Office is designed around explicit access, local-first
          storage, and small diagnostic records. The public download remains
          closed while the final account, export, and deletion controls are
          being completed.
        </p>

        <section>
          <h2>Workspace data</h2>
          <p>
            On first run, you choose local-only storage or iCloud. Local-only
            data stays in this Mac&apos;s Application Support folder. If you
            choose iCloud, supported workspace data is synced through the
            private CloudKit container associated with your Apple account.
          </p>
        </section>
        <section>
          <h2>Calendar</h2>
          <p>
            Calendar access is optional. With permission, the app reads upcoming
            titles and times from the calendars already enabled on the Mac,
            including Apple or Google accounts managed by Calendar.
            Founder&apos;s Office does not edit calendar events.
          </p>
        </section>
        <section>
          <h2>Diagnostics and assistants</h2>
          <p>
            Current health diagnostics are bounded, local records without task
            text, calendar text, photo paths, or credentials. Assistant
            execution is a development feature and will not be enabled in a
            customer build until its consent, sandboxing, and data-handling
            controls pass release review.
          </p>
        </section>
        <section>
          <h2>Control</h2>
          <p>
            Recovery preserves unreadable source data and pauses writes. A
            customer-facing export and verified deletion flow is a launch gate,
            not a promise deferred until after release.
          </p>
        </section>
      </article>
    </main>
  );
}
