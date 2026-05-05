import { NextRequest, NextResponse } from 'next/server';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

const FACE_API = 'http://localhost:8080';

// SYSTEMCTL_MODE: in Phase 1, units are --user (run as the device user on dev unit).
// Phase 3 introduces the dedicated arlowe system user; Phase 11 image build
// installs system-level units. Flipping ARLOWE_SYSTEMCTL_MODE=system at that
// point is sufficient. See research R7 for tech-debt rationale.
const SYSTEMCTL_MODE = process.env.ARLOWE_SYSTEMCTL_MODE || 'user';

function systemctlArgs(subcommand: string, unit: string): string[] {
  return SYSTEMCTL_MODE === 'system'
    ? ['systemctl', subcommand, unit]
    : ['systemctl', '--user', subcommand, unit];
}

async function getStatus(): Promise<{ active: boolean; uptime: string }> {
  try {
    const args = systemctlArgs('is-active', 'arlowe-voice');
    const { stdout } = await execFileAsync(args[0], args.slice(1), {
      timeout: 5000,
    }).catch(() => ({ stdout: '' }));

    const active = stdout.trim() === 'active';

    let uptime = '';
    if (active) {
      try {
        const showArgs = SYSTEMCTL_MODE === 'system'
          ? ['systemctl', 'show', 'arlowe-voice', '--property=ActiveEnterTimestamp', '--no-pager']
          : ['systemctl', '--user', 'show', 'arlowe-voice', '--property=ActiveEnterTimestamp', '--no-pager'];
        const { stdout: statusOutput } = await execFileAsync(showArgs[0], showArgs.slice(1), {
          timeout: 5000,
        });
        const match = statusOutput.match(/ActiveEnterTimestamp=(.+)/);
        if (match) {
          const startTime = new Date(match[1]);
          const diff = Date.now() - startTime.getTime();
          const mins = Math.floor(diff / 60000);
          const hours = Math.floor(mins / 60);
          if (hours > 0) uptime = `${hours}h ${mins % 60}m`;
          else uptime = `${mins}m`;
        }
      } catch { /* ignore */ }
    }

    return { active, uptime };
  } catch {
    return { active: false, uptime: '' };
  }
}

async function setFace(state: string): Promise<void> {
  try {
    await execFileAsync('curl', [
      '-s', '-X', 'POST', `${FACE_API}/state`,
      '-d', JSON.stringify({ state }),
      '-H', 'Content-Type: application/json',
    ], { timeout: 3000 });
  } catch { /* ignore if face service is down */ }
}

export async function GET() {
  return NextResponse.json(await getStatus());
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const action = body.action as string; // 'start' | 'stop' | 'toggle'

    const current = await getStatus();

    let cmd: string;
    if (action === 'toggle') {
      cmd = current.active ? 'stop' : 'start';
    } else {
      cmd = action;
    }

    const args = systemctlArgs(cmd, 'arlowe-voice');
    await execFileAsync(args[0], args.slice(1), { timeout: 10000 });

    if (cmd === 'stop') {
      await setFace('sleeping');
    } else {
      await setFace('idle');
    }

    // Brief pause for service state to settle
    await new Promise(r => setTimeout(r, 1000));

    const newStatus = await getStatus();
    return NextResponse.json({ ...newStatus, action: cmd });
  } catch (error) {
    console.error('Voice control failed:', error);
    return NextResponse.json(
      { error: 'Failed to control voice service', details: String(error) },
      { status: 500 }
    );
  }
}
