import { NextRequest, NextResponse } from 'next/server';
import { execSync } from 'child_process';

const FACE_API = 'http://localhost:8080';

function getStatus(): { active: boolean; uptime: string } {
  try {
    const output = execSync('systemctl --user is-active arlowe-voice 2>/dev/null', { encoding: 'utf-8' }).trim();
    const active = output === 'active';
    
    let uptime = '';
    if (active) {
      try {
        const statusOutput = execSync('systemctl --user show arlowe-voice --property=ActiveEnterTimestamp --no-pager 2>/dev/null', { encoding: 'utf-8' }).trim();
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

function setFace(state: string) {
  try {
    execSync(`curl -s -X POST ${FACE_API}/state -d '{"state":"${state}"}' -H 'Content-Type: application/json'`, { encoding: 'utf-8', timeout: 3000 });
  } catch { /* ignore if face service is down */ }
}

export async function GET() {
  return NextResponse.json(getStatus());
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const action = body.action; // 'start' | 'stop' | 'toggle'
    
    const current = getStatus();
    
    let cmd: string;
    if (action === 'toggle') {
      cmd = current.active ? 'stop' : 'start';
    } else {
      cmd = action;
    }
    
    execSync(`systemctl --user ${cmd} arlowe-voice 2>&1`, { encoding: 'utf-8', timeout: 10000 });
    
    // Set face state
    if (cmd === 'stop') {
      setFace('sleeping');
    } else {
      setFace('idle');
    }
    
    // Brief pause for service state to settle
    await new Promise(r => setTimeout(r, 1000));
    
    const newStatus = getStatus();
    return NextResponse.json({ ...newStatus, action: cmd });
  } catch (error) {
    console.error('Voice control failed:', error);
    return NextResponse.json({ error: 'Failed to control voice service', details: String(error) }, { status: 500 });
  }
}
