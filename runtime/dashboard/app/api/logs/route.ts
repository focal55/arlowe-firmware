import { NextRequest, NextResponse } from 'next/server';
import { readFile, readdir } from 'fs/promises';
import { existsSync } from 'fs';
import { execSync } from 'child_process';

// TODO(plan-08): repoint to /var/lib/arlowe/logs/ and drop SESSION_DIR/CRON_RUNS_DIR (workforce paths)
const VOICE_LOG_DIR = '/home/focal55/whisplay/logs';
const OPENCLAW_LOG_DIR = '/home/focal55/.openclaw/logs';
const SESSION_DIR = '/home/focal55/.openclaw/agents/main/sessions';
const CRON_RUNS_DIR = '/home/focal55/.openclaw/cron/runs';

export interface LogEntry {
  timestamp: string;
  type: 'voice' | 'command' | 'session' | 'subagent' | 'cron' | 'service';
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

// ─── Command logs ───
function parseCommandLogs(content: string): LogEntry[] {
  const logs: LogEntry[] = [];
  for (const line of content.split('\n').filter(l => l.trim())) {
    try {
      const e = JSON.parse(line);
      logs.push({
        timestamp: e.timestamp,
        type: 'command',
        content: `/${e.action} from ${e.source || 'unknown'}`,
        metadata: { action: e.action, sessionKey: e.sessionKey, source: e.source },
      });
    } catch { /* skip */ }
  }
  return logs;
}

// ─── OpenClaw session messages ───
async function parseSessionLogs(start: Date, end: Date): Promise<LogEntry[]> {
  const logs: LogEntry[] = [];
  if (!existsSync(SESSION_DIR)) return logs;

  const files = await readdir(SESSION_DIR);
  // Sort by modification time descending, take recent
  const sorted = files.filter(f => f.endsWith('.jsonl')).slice(-30);

  for (const file of sorted) {
    try {
      const content = await readFile(`${SESSION_DIR}/${file}`, 'utf-8');
      const lines = content.split('\n').filter(l => l.trim());

      // Check first line for session metadata
      let sessionLabel = '';
      let isSubagent = false;
      const firstLine = lines[0] ? JSON.parse(lines[0]) : null;
      if (firstLine?.type === 'session') {
        // Sub-agent sessions have 'subagent' in their id path typically
        const sessionId = firstLine.id || '';
        // Check for label in spawn metadata or session key pattern
        isSubagent = content.includes('"subagent"') || content.includes('agent:main:subagent');
      }

      // Track current model for this session
      let currentModel = '';
      let currentProvider = '';

      for (const line of lines) {
        try {
          const d = JSON.parse(line);
          const ts = d.timestamp ? new Date(d.timestamp) : null;
          
          // Track model changes even outside date range
          if (d.type === 'model_change') {
            currentProvider = d.provider || '';
            currentModel = d.modelId || '';
          }
          
          if (!ts || ts < start || ts > end) continue;

          if (d.type === 'message' && d.message) {
            const role = d.message.role;
            let msgContent = d.message.content;

            // Get model from message or tracked state
            const msgProvider = d.message.provider || currentProvider || '';
            const msgModel = d.message.model || currentModel || '';

            if (Array.isArray(msgContent)) {
              const textBlock = msgContent.find((c: Record<string, unknown>) => c.type === 'text');
              if (textBlock) msgContent = String(textBlock.text);
              else {
                const toolCall = msgContent.find((c: Record<string, unknown>) => c.type === 'toolCall');
                if (toolCall) msgContent = `🔧 ${toolCall.name}(${String(JSON.stringify(toolCall.arguments) || '').slice(0, 60)})`;
                else continue;
              }
            }

            if (typeof msgContent !== 'string') msgContent = String(msgContent || '');
            if (!msgContent.trim() || msgContent.length < 3) continue;
            if (role === 'user' && msgContent.startsWith('Read HEARTBEAT')) continue;

            if (role === 'user' || role === 'assistant') {
              const isAssistant = role === 'assistant';
              logs.push({
                timestamp: d.timestamp,
                type: isSubagent ? 'subagent' : 'session',
                content: msgContent.slice(0, 200),
                metadata: {
                  role,
                  sessionId: file.replace('.jsonl', ''),
                  provider: isAssistant ? msgProvider : undefined,
                  model: isAssistant ? msgModel : undefined,
                  label: sessionLabel || undefined,
                },
              });
            }
          } else if (d.type === 'model_change' && ts >= start && ts <= end) {
            logs.push({
              timestamp: d.timestamp,
              type: isSubagent ? 'subagent' : 'session',
              content: `Model → ${d.provider}/${d.modelId}`,
              metadata: { role: 'system', event: 'model_change', provider: d.provider, model: d.modelId },
            });
          }
        } catch { /* skip bad line */ }
      }
    } catch { /* skip bad file */ }
  }
  return logs;
}

// ─── Cron run logs ───
async function parseCronLogs(start: Date, end: Date): Promise<LogEntry[]> {
  const logs: LogEntry[] = [];
  if (!existsSync(CRON_RUNS_DIR)) return logs;

  const files = await readdir(CRON_RUNS_DIR);
  for (const file of files.filter(f => f.endsWith('.jsonl'))) {
    try {
      const content = await readFile(`${CRON_RUNS_DIR}/${file}`, 'utf-8');
      for (const line of content.split('\n').filter(l => l.trim())) {
        try {
          const d = JSON.parse(line);
          const ts = d.ts ? new Date(d.ts) : null;
          if (!ts || ts < start || ts > end) continue;

          logs.push({
            timestamp: ts.toISOString(),
            type: 'cron',
            content: `Cron ${d.action || 'run'}: ${d.status || 'unknown'}${d.error ? ' — ' + String(d.error).slice(0, 100) : ''}`,
            metadata: { jobId: d.jobId, action: d.action, status: d.status, error: d.error },
          });
        } catch { /* skip */ }
      }
    } catch { /* skip */ }
  }
  return logs;
}

// ─── Service events (systemd) ───
function parseServiceLogs(start: Date, end: Date): LogEntry[] {
  const logs: LogEntry[] = [];
  try {
    const since = start.toISOString();
    const until = end.toISOString();
    // TODO(plan-08): expand journalctl filters to product services (qwen-*, arlowe-*, whisper-stt)
    const output = execSync(
      `journalctl --user -u arlowe-voice -u arlowe-face -u arlowe-dashboard -u qwen-api -u qwen-openai -u whisper-stt --since "${since}" --until "${until}" --no-pager -o json 2>/dev/null | tail -200`,
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
    const types = logType === 'all' ? ['voice', 'command', 'session', 'cron', 'service'] : [logType];

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

    // Commands
    if (types.includes('command') && existsSync(`${OPENCLAW_LOG_DIR}/commands.log`)) {
      const content = await readFile(`${OPENCLAW_LOG_DIR}/commands.log`, 'utf-8');
      all.push(...parseCommandLogs(content).filter(l => {
        const d = new Date(l.timestamp);
        return d >= start && d <= end;
      }));
    }

    // Sessions
    if (types.includes('session')) {
      all.push(...await parseSessionLogs(start, end));
    }

    // Cron
    if (types.includes('cron')) {
      all.push(...await parseCronLogs(start, end));
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
