// /api/logs — reads /var/lib/arlowe/logs/ for file appenders and journalctl
// for the product service set. Founder paths removed in plan 08
// (Phase 1 runtime extraction).
//
// Service set: arlowe-voice, arlowe-face, arlowe-dashboard,
// qwen-{tokenizer,api,openai}, whisper-stt. See ROADMAP Phase 11 for the
// canonical service ordering that BOOT-03 codifies.

import { NextRequest, NextResponse } from 'next/server';
import { readFile, readdir } from 'fs/promises';
import { existsSync } from 'fs';
import { execSync } from 'child_process';

const VOICE_LOG_DIR = '/var/lib/arlowe/logs';

export interface LogEntry {
  timestamp: string;
  type: 'voice' | 'command' | 'service';
  content: string;
  metadata?: Record<string, unknown>;
}

// ─── Voice logs ───
function parseVoiceLogs(content: string, dateStr: string): LogEntry[] {
  const logs: LogEntry[] = [];
  const lines = content.split('\n');
  let currentEntry: Record<string, unknown> | null = null;
  let entryStartTime: Date | null = null;
  let collectingResponse = false;
  let responseLines: string[] = [];
  let responseProvider = '';
  let responseModel = '';

  const flush = (timestamp: string) => {
    if (!currentEntry || responseLines.length === 0) return;
    const fullResponse = responseLines.join('\n').trim();
    if (entryStartTime) currentEntry.latencyMs = new Date(timestamp).getTime() - entryStartTime.getTime();
    if (currentEntry.transcript && fullResponse) {
      logs.push({
        timestamp: String(currentEntry.timestamp) || timestamp,
        type: 'voice',
        content: `"${currentEntry.transcript}" → "${fullResponse.slice(0, 80)}..."`,
        metadata: {
          transcript: String(currentEntry.transcript),
          response: fullResponse.slice(0, 500),
          provider: responseProvider || 'local',
          model: responseModel || (responseProvider === 'cloud' ? 'claude' : 'qwen'),
          latencyMs: Number(currentEntry.latencyMs) || 0,
        },
      });
    }
    collectingResponse = false;
    responseLines = [];
    currentEntry = null;
    entryStartTime = null;
  };

  for (const line of lines) {
    const timeMatch = line.match(/^(\d{2}:\d{2}:\d{2})\s+(.+)/);
    if (timeMatch) {
      const [, time, rest] = timeMatch;
      const timestamp = `${dateStr}T${time}`;
      if (collectingResponse) flush(timestamp);

      if (rest.includes('🔔 Wake word')) {
        currentEntry = { timestamp };
        entryStartTime = new Date(timestamp);
      } else if (rest.includes('🎤 Heard:') && currentEntry) {
        const m = rest.match(/🎤 Heard:\s*(.+)/);
        if (m) currentEntry.transcript = m[1].trim();
      } else if (rest.includes('🔊 Response') && currentEntry) {
        const m = rest.match(/🔊 Response \(([^)|]+)(?:\|([^)]+))?\):\s*(.*)/);
        if (m) {
          responseProvider = m[1] === 'local' ? 'local' : 'claude';
          responseModel = m[2] || (m[1] === 'local' ? 'qwen2.5-1.5b' : 'claude-opus');
          responseLines = [m[3] || ''];
          collectingResponse = true;
        }
      }
    } else if (collectingResponse && line.trim()) {
      responseLines.push(line);
    }
  }
  if (collectingResponse && currentEntry) flush(`${dateStr}T23:59:59`);
  return logs;
}

// ─── Service events (systemd) ───
function parseServiceLogs(start: Date, end: Date): LogEntry[] {
  const logs: LogEntry[] = [];
  try {
    const since = start.toISOString();
    const until = end.toISOString();
    const services = [
      'arlowe-voice',
      'arlowe-face',
      'arlowe-dashboard',
      'qwen-tokenizer',
      'qwen-api',
      'qwen-openai',
      'whisper-stt',
    ];
    const unitArgs = services.map(s => `-u ${s}`).join(' ');
    // Phase 1: services run as --user units on the dev device.
    // Phase 11 (image build) converts to system units; update flag at that point.
    const output = execSync(
      `journalctl --user ${unitArgs} --since "${since}" --until "${until}" --no-pager -o json 2>/dev/null | tail -200`,
      { encoding: 'utf-8', timeout: 5000 }
    );
    for (const line of output.split('\n').filter(l => l.trim())) {
      try {
        const d = JSON.parse(line);
        const ts = d.__REALTIME_TIMESTAMP ? new Date(Number(d.__REALTIME_TIMESTAMP) / 1000) : null;
        if (!ts) continue;
        const unit = (d._SYSTEMD_USER_UNIT || '').replace('.service', '');
        const msg = d.MESSAGE || '';
        if (!msg || msg.includes('ALSA lib') || msg.includes('jack server')) continue;
        logs.push({
          timestamp: ts.toISOString(),
          type: 'service',
          content: `[${unit}] ${String(msg).slice(0, 200)}`,
          metadata: { unit, priority: d.PRIORITY },
        });
      } catch { /* skip */ }
    }
  } catch { /* journalctl might fail */ }
  return logs;
}

// ─── Main handler ───
export async function GET(request: NextRequest) {
  const sp = request.nextUrl.searchParams;
  const logType = sp.get('type') || 'all';
  const startDate = sp.get('start');
  const endDate = sp.get('end');
  const search = sp.get('q') || '';
  const limit = parseInt(sp.get('limit') || '200');

  const now = new Date();
  const start = startDate ? new Date(startDate) : new Date(now.getTime() - 7 * 86400000);
  const end = endDate ? new Date(endDate + 'T23:59:59') : now;
  const all: LogEntry[] = [];

  try {
    const types = logType === 'all' ? ['voice', 'service'] : [logType];

    // Voice
    if (types.includes('voice') && existsSync(VOICE_LOG_DIR)) {
      const files = await readdir(VOICE_LOG_DIR);
      for (const file of files.filter(f => /^voice_\d{4}-\d{2}-\d{2}\.log(\.\d+)?$/.test(f)).sort().reverse()) {
        const dm = file.match(/voice_(\d{4}-\d{2}-\d{2})\.log/);
        if (!dm) continue;
        const fd = new Date(dm[1]);
        if (fd < start || fd > end) continue;
        const content = await readFile(`${VOICE_LOG_DIR}/${file}`, 'utf-8');
        all.push(...parseVoiceLogs(content, dm[1]));
      }
    }

    // Services
    if (types.includes('service')) {
      all.push(...parseServiceLogs(start, end));
    }

    all.sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime());

    const filtered = search
      ? all.filter(l => {
          const q = search.toLowerCase();
          return l.content.toLowerCase().includes(q)
            || JSON.stringify(l.metadata || {}).toLowerCase().includes(q);
        })
      : all;

    return NextResponse.json({
      logs: filtered.slice(0, limit),
      meta: { total: filtered.length, start: start.toISOString(), end: end.toISOString(), type: logType, search: search || null },
    });
  } catch (error) {
    console.error('Log fetch error:', error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
