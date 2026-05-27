import type { Metadata, Viewport } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import Navigation from './components/Navigation';
import Header from './components/Header';

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Arlowe Dashboard",
  description: "Control panel for your Arlowe device",
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "Arlowe",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  themeColor: "#000000",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className={`${inter.className} flex flex-col md:flex-row min-h-screen antialiased bg-[var(--background)] text-[var(--foreground)]`}>
        <Navigation />
        <main className="flex-1 p-4 pb-24 md:pb-4 md:p-6 overflow-auto">
          <Header />
          {children}
        </main>
      </body>
    </html>
  );
}
