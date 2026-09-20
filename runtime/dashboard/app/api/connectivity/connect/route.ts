import { NextRequest, NextResponse } from 'next/server';
import { execFile } from 'child_process';
import { promisify } from 'util';
// import { verifyAuth } from '../../middleware/auth';

// execFile, never exec: an SSID is whatever a nearby access point broadcasts, so it
// is attacker-supplied data that must never reach a shell. Arguments go as an array.
const execFileAsync = promisify(execFile);

const nmcli = (args: string[], timeout = 10000) =>
  execFileAsync('nmcli', args, { timeout });

export async function POST(request: NextRequest) {
  console.log('--- [arlowe-dashboard-backend] POST /api/connectivity/connect ---');

  // TODO: Re-enable auth after adding UI flow for authentication
  // const authError = verifyAuth(request);
  // if (authError) return authError;

  try {
    const body = await request.json();
    const { ssid, password } = body;

    if (typeof ssid !== 'string' || !ssid) {
      return NextResponse.json({ error: 'SSID is required' }, { status: 400 });
    }
    if (password !== undefined && typeof password !== 'string') {
      return NextResponse.json({ error: 'Password must be a string' }, { status: 400 });
    }

    // Saved-network check: list profile names and compare in JS rather than piping
    // the SSID into grep, which would reinterpret it as a pattern even without a shell.
    let isSavedNetwork = false;
    try {
      const { stdout } = await nmcli(['-t', '-f', 'NAME', 'connection', 'show']);
      isSavedNetwork = stdout.split('\n').some((name) => name === ssid);
    } catch {
      // nmcli unavailable or no profiles; treat as not saved.
    }

    let args: string[];
    if (isSavedNetwork && !password) {
      args = ['connection', 'up', ssid];
      console.log('Connecting to saved network');
    } else if (password) {
      // Drop a stale profile so a changed password cannot be masked by an old one.
      try {
        await nmcli(['connection', 'delete', ssid]);
      } catch {
        // No such profile — nothing to clear.
      }
      args = ['device', 'wifi', 'connect', ssid, 'password', password];
      console.log('Connecting to new network');
    } else {
      args = ['device', 'wifi', 'connect', ssid];
      console.log('Connecting to open network');
    }

    const { stdout, stderr } = await nmcli(args, 30000);

    if (stderr) {
      console.error('nmcli connect stderr:', stderr);
      if (stderr.includes('Error: No network with SSID')) {
        return NextResponse.json({ error: 'Network not found' }, { status: 404 });
      }
      if (stderr.includes('Error: Connection activation failed')) {
        return NextResponse.json({ error: 'Connection failed. Please check the password.' }, { status: 401 });
      }
      return NextResponse.json({ error: 'Failed to connect to the network.', details: stderr }, { status: 500 });
    }

    console.log('nmcli stdout:', stdout);
    return NextResponse.json({ message: `Successfully connected to ${ssid}` });

  } catch (error) {
    console.error('Failed to process connection request:', error);
    if (error instanceof SyntaxError) {
      return NextResponse.json({ error: 'Invalid JSON in request body' }, { status: 400 });
    }
    return NextResponse.json(
      { error: 'An unexpected error occurred.', details: error instanceof Error ? error.message : String(error) },
      { status: 500 }
    );
  }
}
