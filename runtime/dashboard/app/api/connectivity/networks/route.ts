import { NextResponse } from 'next/server';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export async function GET() {
  console.log('--- [arlowe-dashboard-backend] GET /api/connectivity/networks ---');
  console.log('Model: google-gemini/gemini-2.5-flash');

  try {
    // Rescan for Wi-Fi networks
    await execAsync('nmcli device wifi rescan');

    // List available Wi-Fi networks
    const command = "nmcli --terse --fields SSID,SIGNAL,SECURITY,IN-USE device wifi list";
    const { stdout, stderr } = await execAsync(command);

    if (stderr) {
      console.error('nmcli stderr:', stderr);
    }

    const networks = stdout
      .trim()
      .split('\n')
      .map(line => {
        const [ssid, signal, security, inUse] = line.split(':');
        return {
          ssid: ssid,
          signal: parseInt(signal, 10),
          security: security || 'Open',
          inUse: inUse === '*'
        };
      })
      .filter(network => network.ssid) // Filter out empty SSIDs
      .sort((a, b) => {
        // Connected network first, then by signal strength
        if (a.inUse && !b.inUse) return -1;
        if (!a.inUse && b.inUse) return 1;
        return b.signal - a.signal;
      });

    return NextResponse.json(networks);

  } catch (error: unknown) {
    console.error('Failed to get network list:', error);
    const message = error instanceof Error ? error.message : String(error);
    return NextResponse.json(
      { error: 'Failed to execute nmcli command', details: message },
      { status: 500 }
    );
  }
}
