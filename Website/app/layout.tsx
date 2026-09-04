import type { Metadata } from 'next';
import { Instrument_Serif, Manrope } from 'next/font/google';

import './globals.css';

const instrumentSerif = Instrument_Serif({
  variable: '--font-instrument-serif',
  subsets: ['latin'],
  weight: '400',
});

const manrope = Manrope({
  variable: '--font-manrope',
  subsets: ['latin'],
  weight: ['400', '600', '700'],
});

export const metadata: Metadata = {
  metadataBase: new URL('https://founders-office.sampatirao2.chatgpt.site'),
  title: "Founder's Office — Use the app inside a MacBook",
  description:
    'Scroll through an interactive MacBook demo of Founder’s Office for macOS.',
  icons: { icon: '/favicon.svg' },
  openGraph: {
    type: 'website',
    title: "Founder's Office — Use the app inside a MacBook",
    description:
      'Scroll through an interactive MacBook demo of Founder’s Office for macOS.',
    images: [{ url: '/og.png', width: 1200, height: 630 }],
  },
  twitter: {
    card: 'summary_large_image',
    title: "Founder's Office — Use the app inside a MacBook",
    description:
      'Scroll through an interactive MacBook demo of Founder’s Office for macOS.',
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
      <body className={`${instrumentSerif.variable} ${manrope.variable}`}>
        {children}
      </body>
    </html>
  );
}
