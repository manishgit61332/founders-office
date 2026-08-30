import { ArrowDown, Check, LockKeyhole } from 'lucide-react';
import Link from 'next/link';

import { getVerifiedMacRelease } from '../lib/mac-release';

export default function Home() {
  const macRelease = getVerifiedMacRelease();

  return (
    <main>
      <nav className="site-nav" aria-label="Primary navigation">
        <a className="wordmark" href="#top" aria-label="Founder's Office home">
          Founder&apos;s Office
        </a>
        <div className="nav-links">
          <a href="#product">Product</a>
          <a href="#release">Mac beta</a>
          <a href="#principles">Principles</a>
        </div>
      </nav>

      <section className="hero" id="top">
        <div className="eyebrow">A focus surface for founders</div>
        <h1>
          Know the next move
          <br />
          in two seconds.
        </h1>
        <p className="hero-copy">
          Founder&apos;s Office turns the MacBook notch into a quiet check-in
          for your next move, calendar, and one finish line that matters.
        </p>
        <div className="hero-actions">
          {macRelease ? (
            <a className="download-button" href={macRelease.downloadURL}>
              Download for macOS <ArrowDown aria-hidden="true" />
            </a>
          ) : (
            <span className="download-button is-disabled" aria-disabled="true">
              Download opens after notarization
            </span>
          )}
          <span className="release-note">macOS 14 or later · private beta</span>
        </div>
      </section>

      <section
        className="product-stage"
        id="product"
        aria-label="Founder's Office product preview"
      >
        <div className="ambient ambient-one" />
        <div className="ambient ambient-two" />
        <div className="notch-preview">
          <div className="hardware-notch" aria-hidden="true" />
          <header className="preview-header">
            <div>
              <span className="preview-kicker">Founder&apos;s Office</span>
              <h2>Hi, Aanya.</h2>
            </div>
            <div className="preview-tabs" aria-label="Preview sections">
              <span className="active">Home</span>
              <span>Moves</span>
              <span>Calendar</span>
            </div>
          </header>

          <div className="preview-grid">
            <article className="next-move-card">
              <span className="card-label">Next move</span>
              <h3>Send the revised launch story</h3>
              <p>One clear action. No backlog theatre.</p>
              <div className="task-action">
                <Check aria-hidden="true" /> Mark complete
              </div>
            </article>

            <article className="signal-card">
              <span className="card-label">Up next</span>
              <h3>Design partner call</h3>
              <p>11:30 AM · Google Calendar</p>
            </article>

            <article className="goal-card">
              <span className="card-label">Primary goal</span>
              <div className="goal-values">
                <strong>$3k</strong>
                <span>of $10k MRR</span>
              </div>
              <div className="goal-track">
                <span />
              </div>
              <p>59 days left</p>
            </article>

            <article className="vision-card">
              <div className="vision-orbit orbit-one" />
              <div className="vision-orbit orbit-two" />
              <div className="vision-copy">
                <span>Your picture. Your reason.</span>
                <strong>Keep the why close.</strong>
              </div>
            </article>
          </div>
        </div>
      </section>

      <section className="principles" id="principles">
        <div className="section-heading">
          <span className="eyebrow">Deliberately small</span>
          <h2>A homepage you check like the time.</h2>
        </div>
        <div className="principle-grid">
          <article>
            <span>01</span>
            <h3>One move, not fifty cards</h3>
            <p>
              Deadline-aware Moves stay available without taking over the home
              view.
            </p>
          </article>
          <article>
            <span>02</span>
            <h3>Personal without becoming noisy</h3>
            <p>
              Your name, finish line, color, type, and one meaningful image
              shape the space.
            </p>
          </article>
          <article>
            <span>03</span>
            <h3>Calendar without another login loop</h3>
            <p>
              It reads the Apple and Google calendars already enabled on your
              Mac.
            </p>
          </article>
        </div>
      </section>

      <section className="release" id="release">
        <div>
          <span className="eyebrow">Private Mac beta</span>
          <h2>The download stays closed until the build is safe to trust.</h2>
          <p>
            The first public build must pass Developer ID signing, Apple
            notarization, clean-install onboarding, upgrade, recovery, and
            permission-retention tests.
          </p>
        </div>
        <div className="release-checks" aria-label="Release requirements">
          <div>
            <LockKeyhole aria-hidden="true" />
            <span>Signed and notarized</span>
          </div>
          <div>
            <LockKeyhole aria-hidden="true" />
            <span>Data recovery tested</span>
          </div>
          <div>
            <LockKeyhole aria-hidden="true" />
            <span>Privacy controls shipped</span>
          </div>
        </div>
      </section>

      <footer>
        <span>Founder&apos;s Office</span>
        <span className="footer-links">
          <Link href="/privacy">Privacy</Link>
          <Link href="/support">Support</Link>
          <Link href="/security">Security</Link>
          <Link href="/THIRD_PARTY_NOTICES.txt">Licenses</Link>
        </span>
      </footer>
    </main>
  );
}
