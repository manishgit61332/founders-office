import { ArrowLeft } from 'lucide-react';
import Link from 'next/link';

export default function SupportPage() {
  return (
    <main className="policy-shell">
      <Link className="policy-back" href="/">
        <ArrowLeft aria-hidden="true" /> Founder&apos;s Office
      </Link>
      <article className="policy-page">
        <span className="eyebrow">Private beta support</span>
        <h1>Useful evidence, without handing over your life.</h1>
        <p className="policy-lede">
          Private beta testers should use the contact route in their invitation.
          A public support address and response policy will be posted before the
          download opens.
        </p>
        <section>
          <h2>If safe mode appears</h2>
          <p>
            Right-click the menu bar icon, copy the incident ID, and include it
            with the app version and a short description of what happened. Do
            not send workspace files, screenshots, calendar details, photos, or
            credentials unless support explicitly explains why they are needed.
          </p>
        </section>
        <section>
          <h2>If recovery is required</h2>
          <p>
            Keep the preserved files in place. Founder&apos;s Office stops edits
            and cloud startup rather than replacing unreadable data. Contact
            support before moving or deleting the canonical workspace files.
          </p>
        </section>
      </article>
    </main>
  );
}
