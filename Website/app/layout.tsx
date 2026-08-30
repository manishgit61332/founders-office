import type { Metadata } from 'next';
import { Instrument_Serif } from 'next/font/google';

import './globals.css';

const instrumentSerif = Instrument_Serif({
  variable: '--font-instrument-serif',
  subsets: ['latin'],
  weight: '400',
});

export const metadata: Metadata = {
  metadataBase: new URL('https://founders-office.sampatirao2.chatgpt.site'),
  title: "Founder's Office — Know the next move in two seconds",
  description:
    'A calm MacBook notch app for your next move, calendar, and primary goal.',
  icons: { icon: '/favicon.svg' },
  openGraph: {
    type: 'website',
    title: "Founder's Office — Know the next move in two seconds",
    description:
      'A calm MacBook notch app for your next move, calendar, and primary goal.',
    images: [{ url: '/og.png', width: 1200, height: 630 }],
  },
  twitter: {
    card: 'summary_large_image',
    title: "Founder's Office — Know the next move in two seconds",
    description:
      'A calm MacBook notch app for your next move, calendar, and primary goal.',
    images: ['/og.png'],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className={instrumentSerif.variable}>{children}</body>
    </html>
  );
}
