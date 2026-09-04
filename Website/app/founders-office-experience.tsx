'use client';

import {
  ArrowDown,
  ArrowRight,
  CalendarDays,
  Check,
  Circle,
  MousePointer2,
  Palette,
} from 'lucide-react';
import Link from 'next/link';
import {
  type CSSProperties,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

type ViewName = 'home' | 'moves' | 'calendar' | 'personalize';

type Move = {
  id: number;
  title: string;
  meta: string;
  priority: 'P0' | 'P1';
};

const views: Array<{ id: ViewName; label: string }> = [
  { id: 'home', label: 'Home' },
  { id: 'moves', label: 'Moves' },
  { id: 'calendar', label: 'Calendar' },
  { id: 'personalize', label: 'Personalize' },
];

const story: Array<{
  view: ViewName;
  index: string;
  eyebrow: string;
  title: string;
  body: string;
}> = [
  {
    view: 'home',
    index: '01',
    eyebrow: 'Open the notch',
    title: 'One glance. One move.',
    body: 'Home keeps the next action, the next meeting, and the finish line in one small surface.',
  },
  {
    view: 'moves',
    index: '02',
    eyebrow: 'Clear the queue',
    title: 'Finish work without managing work.',
    body: 'Moves stay ordered by urgency. Complete one here. The rest keep their place.',
  },
  {
    view: 'calendar',
    index: '03',
    eyebrow: 'See the day',
    title: 'Calendar is context, not another inbox.',
    body: 'Pick a day inside the MacBook. Founder’s Office shows the events that shape the work.',
  },
  {
    view: 'personalize',
    index: '04',
    eyebrow: 'Make it yours',
    title: 'Change the signal, not the system.',
    body: 'Try an accent. The hierarchy stays quiet while the surface feels like your own.',
  },
];

const initialMoves: Move[] = [
  {
    id: 1,
    title: 'Send the revised launch story',
    meta: 'Today · 10:30 AM',
    priority: 'P0',
  },
  {
    id: 2,
    title: 'Confirm the beta onboarding flow',
    meta: 'Today · 2:00 PM',
    priority: 'P0',
  },
  {
    id: 3,
    title: 'Reply to the design partner notes',
    meta: 'Tomorrow',
    priority: 'P1',
  },
  {
    id: 4,
    title: 'Review the release checklist',
    meta: 'Friday',
    priority: 'P1',
  },
];

const calendarDays = [
  { day: 'Mon', date: 7 },
  { day: 'Tue', date: 8 },
  { day: 'Wed', date: 9 },
  { day: 'Thu', date: 10 },
  { day: 'Fri', date: 11 },
];

const eventsByDay: Record<number, Array<{ time: string; title: string }>> = {
  7: [
    { time: '10:00', title: 'Weekly planning' },
    { time: '15:30', title: 'Product review' },
  ],
  8: [
    { time: '11:30', title: 'Design partner call' },
    { time: '16:00', title: 'Deep work block' },
  ],
  9: [
    { time: '09:30', title: 'Launch review' },
    { time: '14:00', title: 'Onboarding test' },
  ],
  10: [
    { time: '10:45', title: 'Growth check-in' },
    { time: '13:30', title: 'Build window' },
  ],
  11: [
    { time: '10:00', title: 'Release gate' },
    { time: '17:00', title: 'Weekly close' },
  ],
};

const accents = [
  { name: 'Signal', value: '#ff5c35' },
  { name: 'Cobalt', value: '#5777ff' },
  { name: 'Acid', value: '#b7eb54' },
  { name: 'Lilac', value: '#b89cff' },
];

export function FoundersOfficeExperience({
  downloadURL,
}: {
  downloadURL: string | null;
}) {
  const [activeView, setActiveView] = useState<ViewName>('home');
  const [accent, setAccent] = useState(accents[0].value);
  const [completedMoves, setCompletedMoves] = useState<number[]>([]);
  const [selectedDay, setSelectedDay] = useState(8);
  const [scrollProgress, setScrollProgress] = useState(0);
  const demoRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const steps = Array.from(
      document.querySelectorAll<HTMLElement>('[data-story-view]'),
    );

    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];

        if (visible) {
          setActiveView(
            visible.target.getAttribute('data-story-view') as ViewName,
          );
        }
      },
      { rootMargin: '-34% 0px -46% 0px', threshold: [0.1, 0.35, 0.6] },
    );

    steps.forEach((step) => observer.observe(step));
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const updateProgress = () => {
      const demo = demoRef.current;
      if (!demo) return;

      const rect = demo.getBoundingClientRect();
      const total = demo.offsetHeight - window.innerHeight;
      const travelled = Math.min(Math.max(-rect.top, 0), Math.max(total, 1));
      setScrollProgress(travelled / Math.max(total, 1));
    };

    updateProgress();
    window.addEventListener('scroll', updateProgress, { passive: true });
    window.addEventListener('resize', updateProgress);
    return () => {
      window.removeEventListener('scroll', updateProgress);
      window.removeEventListener('resize', updateProgress);
    };
  }, []);

  const toggleMove = (id: number) => {
    setCompletedMoves((current) =>
      current.includes(id)
        ? current.filter((moveId) => moveId !== id)
        : [...current, id],
    );
  };

  const activeMove = useMemo(
    () => initialMoves.find((move) => !completedMoves.includes(move.id)),
    [completedMoves],
  );

  const pageStyle = {
    '--app-accent': accent,
    '--story-progress': `${scrollProgress * 100}%`,
  } as CSSProperties;

  return (
    <main className="experience" style={pageStyle}>
      <nav className="demo-nav" aria-label="Primary navigation">
        <a className="demo-wordmark" href="#top">
          <span aria-hidden="true">F/O</span>
          Founder&apos;s Office
        </a>
        <a className="nav-demo-link" href="#demo">
          Use the app <ArrowDown aria-hidden="true" />
        </a>
      </nav>

      <section className="intro" id="top">
        <p className="intro-kicker">Founder&apos;s Office for macOS</p>
        <h1>
          See the work.
          <br />
          <em>Pick the move.</em>
          <br />
          Get back to it.
        </h1>
        <div className="intro-bottom">
          <p>
            A focused surface that lives under your MacBook notch. Scroll to
            open it. Click to use it.
          </p>
          <a href="#demo">
            <MousePointer2 aria-hidden="true" /> Scroll to start
          </a>
        </div>
      </section>

      <section className="scroll-demo" id="demo" ref={demoRef}>
        <div className="story-progress" aria-hidden="true">
          <span />
        </div>

        <div className="mac-sticky">
          <MacBook
            activeView={activeView}
            setActiveView={setActiveView}
            activeMove={activeMove}
            completedMoves={completedMoves}
            toggleMove={toggleMove}
            selectedDay={selectedDay}
            setSelectedDay={setSelectedDay}
            accent={accent}
            setAccent={setAccent}
          />
          <div className="interaction-hint">
            <span className="live-dot" /> The MacBook is live. Try the tabs and
            controls.
          </div>
        </div>

        <div className="story-steps">
          {story.map((step) => (
            <article
              className={`story-step ${activeView === step.view ? 'is-active' : ''}`}
              data-story-view={step.view}
              key={step.view}
            >
              <span className="story-index">{step.index}</span>
              <p className="story-kicker">{step.eyebrow}</p>
              <h2>{step.title}</h2>
              <p>{step.body}</p>
              <button type="button" onClick={() => setActiveView(step.view)}>
                Open {views.find((view) => view.id === step.view)?.label}
                <ArrowRight aria-hidden="true" />
              </button>
            </article>
          ))}
        </div>
      </section>

      <section className="release-panel" id="release">
        <p>Private Mac beta</p>
        <h2>The demo is open. The download opens after notarization.</h2>
        <div>
          {downloadURL ? (
            <a href={downloadURL}>
              Download for macOS <ArrowDown aria-hidden="true" />
            </a>
          ) : (
            <span aria-disabled="true">Release checks in progress</span>
          )}
          <small>macOS 14 or later</small>
        </div>
      </section>

      <footer className="demo-footer">
        <span>Founder&apos;s Office</span>
        <div>
          <Link href="/privacy">Privacy</Link>
          <Link href="/support">Support</Link>
          <Link href="/security">Security</Link>
        </div>
        <span>Built in India</span>
      </footer>
    </main>
  );
}

function MacBook({
  activeView,
  setActiveView,
  activeMove,
  completedMoves,
  toggleMove,
  selectedDay,
  setSelectedDay,
  accent,
  setAccent,
}: {
  activeView: ViewName;
  setActiveView: (view: ViewName) => void;
  activeMove: Move | undefined;
  completedMoves: number[];
  toggleMove: (id: number) => void;
  selectedDay: number;
  setSelectedDay: (day: number) => void;
  accent: string;
  setAccent: (accent: string) => void;
}) {
  return (
    <div className="macbook" aria-label="Interactive Founder's Office demo">
      <div className="macbook-lid">
        <div className="macbook-camera" aria-hidden="true" />
        <div className="macbook-display">
          <div className="mac-menu-bar" aria-hidden="true">
            <span>Founder&apos;s Office</span>
            <span>9:41 AM</span>
          </div>

          <section className={`notch-app view-${activeView}`}>
            <div className="physical-notch" aria-hidden="true">
              <i />
            </div>

            <header className="app-header">
              <div>
                <span>Founder&apos;s Office</span>
                <strong>Good morning, Aanya.</strong>
              </div>
              <nav aria-label="App demo views">
                {views.map((view) => (
                  <button
                    aria-pressed={activeView === view.id}
                    className={activeView === view.id ? 'is-active' : ''}
                    key={view.id}
                    onClick={() => setActiveView(view.id)}
                    type="button"
                  >
                    {view.label}
                  </button>
                ))}
              </nav>
            </header>

            <div className="app-content">
              {activeView === 'home' && (
                <HomeView activeMove={activeMove} toggleMove={toggleMove} />
              )}
              {activeView === 'moves' && (
                <MovesView
                  completedMoves={completedMoves}
                  toggleMove={toggleMove}
                />
              )}
              {activeView === 'calendar' && (
                <CalendarView
                  selectedDay={selectedDay}
                  setSelectedDay={setSelectedDay}
                />
              )}
              {activeView === 'personalize' && (
                <PersonalizeView accent={accent} setAccent={setAccent} />
              )}
            </div>
          </section>

          <div className="desktop-dock" aria-hidden="true">
            <i />
            <i />
            <i />
            <i />
            <i />
          </div>
        </div>
      </div>
      <div className="macbook-base" aria-hidden="true">
        <span />
      </div>
    </div>
  );
}

function HomeView({
  activeMove,
  toggleMove,
}: {
  activeMove: Move | undefined;
  toggleMove: (id: number) => void;
}) {
  return (
    <div className="home-view app-view">
      <article className="next-move-panel">
        <span className="app-label">Next move</span>
        {activeMove ? (
          <>
            <h3>{activeMove.title}</h3>
            <p>{activeMove.meta}</p>
            <button type="button" onClick={() => toggleMove(activeMove.id)}>
              <Check aria-hidden="true" /> Mark complete
            </button>
          </>
        ) : (
          <div className="all-clear">
            <Check aria-hidden="true" />
            <h3>All clear.</h3>
            <p>You finished every Move in this demo.</p>
          </div>
        )}
      </article>

      <article className="meeting-panel">
        <CalendarDays aria-hidden="true" />
        <span className="app-label">Up next</span>
        <h3>Design partner call</h3>
        <p>11:30 AM · 28 minutes</p>
      </article>

      <article className="goal-panel">
        <span className="app-label">Primary goal</span>
        <div>
          <strong>$3k</strong>
          <span>of $10k MRR</span>
        </div>
        <div className="goal-meter">
          <i />
        </div>
        <p>59 days left</p>
      </article>
    </div>
  );
}

function MovesView({
  completedMoves,
  toggleMove,
}: {
  completedMoves: number[];
  toggleMove: (id: number) => void;
}) {
  return (
    <div className="moves-view app-view">
      <div className="view-heading">
        <div>
          <span className="app-label">Priority order</span>
          <h3>Moves</h3>
        </div>
        <span>{initialMoves.length - completedMoves.length} open</span>
      </div>

      <div className="move-list">
        {initialMoves.map((move) => {
          const complete = completedMoves.includes(move.id);
          return (
            <button
              className={complete ? 'is-complete' : ''}
              key={move.id}
              onClick={() => toggleMove(move.id)}
              type="button"
            >
              <span className="move-check">
                {complete ? (
                  <Check aria-hidden="true" />
                ) : (
                  <Circle aria-hidden="true" />
                )}
              </span>
              <span>
                <strong>{move.title}</strong>
                <small>{move.meta}</small>
              </span>
              <b>{move.priority}</b>
            </button>
          );
        })}
      </div>
    </div>
  );
}

function CalendarView({
  selectedDay,
  setSelectedDay,
}: {
  selectedDay: number;
  setSelectedDay: (day: number) => void;
}) {
  const events = eventsByDay[selectedDay] ?? [];

  return (
    <div className="calendar-view app-view">
      <div className="view-heading">
        <div>
          <span className="app-label">September</span>
          <h3>Your day</h3>
        </div>
        <span>2 calendars</span>
      </div>

      <div className="day-picker" aria-label="Choose a calendar day">
        {calendarDays.map((item) => (
          <button
            aria-pressed={selectedDay === item.date}
            className={selectedDay === item.date ? 'is-active' : ''}
            key={item.date}
            onClick={() => setSelectedDay(item.date)}
            type="button"
          >
            <span>{item.day}</span>
            <strong>{item.date}</strong>
          </button>
        ))}
      </div>

      <div className="event-list">
        {events.map((event) => (
          <article key={event.time}>
            <time>{event.time}</time>
            <div>
              <strong>{event.title}</strong>
              <span>Google Calendar</span>
            </div>
            <i />
          </article>
        ))}
      </div>
    </div>
  );
}

function PersonalizeView({
  accent,
  setAccent,
}: {
  accent: string;
  setAccent: (accent: string) => void;
}) {
  return (
    <div className="personalize-view app-view">
      <div className="view-heading">
        <div>
          <span className="app-label">Appearance</span>
          <h3>Make it yours</h3>
        </div>
        <Palette aria-hidden="true" />
      </div>

      <div className="personalize-grid">
        <section>
          <span className="app-label">Accent</span>
          <div className="swatches">
            {accents.map((item) => (
              <button
                aria-label={`Use ${item.name} accent`}
                aria-pressed={accent === item.value}
                className={accent === item.value ? 'is-active' : ''}
                key={item.value}
                onClick={() => setAccent(item.value)}
                style={{ '--swatch': item.value } as CSSProperties}
                type="button"
              >
                <i />
                <span>{item.name}</span>
              </button>
            ))}
          </div>
        </section>

        <section className="preview-tile">
          <span className="app-label">Preview</span>
          <div>
            <i />
            <span>Next move</span>
            <strong>Ship the work that matters.</strong>
            <button type="button">
              Done <Check aria-hidden="true" />
            </button>
          </div>
        </section>
      </div>
    </div>
  );
}
