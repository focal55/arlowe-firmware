import { NextResponse } from 'next/server';
import { readFile, readdir } from 'fs/promises';

export interface AudioDevice {
  id: string;
  name: string;
  index: number;
}

export interface AudioDevicesResponse {
  capture: AudioDevice[];
  playback: AudioDevice[];
}

// Parse /proc/asound/cards into a list of { index, shortId, longname } entries.
// Example line format:
//  0 [Headphones    ]: bcm2835_headpho - bcm2835 Headphones
//                      bcm2835 Headphones
async function parseCards(procRoot: string): Promise<Array<{ index: number; shortId: string; longname: string }>> {
  const cardsPath = `${procRoot}/asound/cards`;
  const raw = await readFile(cardsPath, 'utf-8');

  const result: Array<{ index: number; shortId: string; longname: string }> = [];

  // Each card occupies two lines. The first line has the card index and names.
  // Format: " N [short_id     ]: driver_name - longname"
  for (const line of raw.split('\n')) {
    const match = line.match(/^\s*(\d+)\s+\[(\S+)\s*\]:\s*\S+\s+-\s+(.+)$/);
    if (match) {
      result.push({
        index: parseInt(match[1], 10),
        shortId: match[2].trim(),
        longname: match[3].trim(),
      });
    }
  }

  return result;
}

// Read the canonical card-id token from /proc/asound/card{N}/id.
// Falls back to the shortId parsed from /proc/asound/cards on any error.
async function readCardId(procRoot: string, index: number, fallback: string): Promise<string> {
  try {
    const raw = await readFile(`${procRoot}/asound/card${index}/id`, 'utf-8');
    return raw.trim();
  } catch {
    return fallback;
  }
}

// Returns { hasCapture, hasPlayback } by examining pcm* entries in
// /proc/asound/card{N}/.  A "c" suffix indicates a capture PCM,
// a "p" suffix indicates a playback PCM.
async function classifyCard(procRoot: string, index: number): Promise<{ hasCapture: boolean; hasPlayback: boolean }> {
  try {
    const entries = await readdir(`${procRoot}/asound/card${index}`);
    const hasCapture = entries.some(e => /^pcm\d+c$/.test(e));
    const hasPlayback = entries.some(e => /^pcm\d+p$/.test(e));
    return { hasCapture, hasPlayback };
  } catch {
    return { hasCapture: false, hasPlayback: false };
  }
}

// Build a human-readable label from a card's long name.
// Rules (in order of priority):
//   wm8960 -> "Whisplay Speaker/Mic (WM8960)"
//   usb    -> "USB Audio Device (<longname>)"
//   vc4-hdmi / hdmi -> "HDMI <n>" where n comes from "HDMI <n>" in the longname
//   fallback -> raw longname
function friendlyName(longname: string, index: number): string {
  const lower = longname.toLowerCase();
  if (lower.includes('wm8960')) {
    return `Whisplay Speaker/Mic (WM8960)`;
  }
  if (lower.includes('usb')) {
    return `USB Audio Device (${longname})`;
  }
  if (lower.includes('hdmi')) {
    // Extract "HDMI N" or fall back to index-based label
    const hdmiMatch = longname.match(/hdmi\s*(\d*)/i);
    const suffix = hdmiMatch?.[1] ? ` ${hdmiMatch[1]}` : ` ${index}`;
    return `HDMI${suffix}`;
  }
  return longname;
}

// Exposed for testing. Defaults to /proc in production.
const PROC_ROOT = process.env.ARLOWE_PROC_ROOT ?? '/proc';

export async function GET(): Promise<NextResponse> {
  console.log('--- [arlowe-dashboard-backend] GET /api/audio/devices ---');

  const capture: AudioDevice[] = [];
  const playback: AudioDevice[] = [];

  try {
    const cards = await parseCards(PROC_ROOT);

    for (const card of cards) {
      const cardId = await readCardId(PROC_ROOT, card.index, card.shortId);
      const { hasCapture, hasPlayback } = await classifyCard(PROC_ROOT, card.index);
      const name = friendlyName(card.longname, card.index);
      const device: AudioDevice = { id: cardId, name, index: card.index };

      if (hasCapture) {
        capture.push(device);
      }
      if (hasPlayback) {
        playback.push(device);
      }
    }
  } catch (error: unknown) {
    // /proc/asound absent in a non-Pi dev container — return empty arrays, not 500.
    console.error('[arlowe-dashboard-backend] /proc/asound not available:', error);
  }

  const body: AudioDevicesResponse = { capture, playback };
  return NextResponse.json(body);
}
