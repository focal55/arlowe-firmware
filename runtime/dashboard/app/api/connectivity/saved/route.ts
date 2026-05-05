import { NextRequest, NextResponse } from 'next/server';
import { exec } from 'child_process';
import { promisify } from 'util';
import { verifyAuth } from '../../middleware/auth';

const execAsync = promisify(exec);

export async function GET() {
  console.log('--- [arlowe-dashboard-backend] GET /api/connectivity/saved ---');

  try {
    // List all saved Wi-Fi connections
    const command = "nmcli --terse --fields NAME,TYPE connection show | grep 802-11-wireless";
    const { stdout, stderr } = await execAsync(command);

    if (stderr) {
      console.error('nmcli stderr:', stderr);
    }

    const networks = stdout
      .trim()
      .split('\n')
      .filter(line => line.trim())
      .map(line => {
        const [name] = line.split(':');
        return {
          ssid: name,
          security: 'WPA2', // nmcli doesn't easily expose security type for saved networks
        };
      })
      .filter(network => network.ssid);

    return NextResponse.json(networks);

  } catch (error: unknown) {
    console.error('Failed to get saved networks:', error);
    const message = error instanceof Error ? error.message : String(error);
    // Return empty array if grep finds nothing
    if (message.includes('Command failed')) {
      return NextResponse.json([]);
    }
    return NextResponse.json(
      { error: 'Failed to execute nmcli command', details: message },
      { status: 500 }
    );
  }
}

export async function DELETE(request: NextRequest) {
  console.log('--- [arlowe-dashboard-backend] DELETE /api/connectivity/saved ---');
  
  // Auth check for destructive operation
  const authError = verifyAuth(request);
  if (authError) return authError;
  
  try {
    const body = await request.json();
    const { ssid } = body;

    if (!ssid) {
      return NextResponse.json({ error: 'SSID is required' }, { status: 400 });
    }

    const command = `nmcli connection delete "${ssid}"`;
    console.log(`Executing delete command for SSID: ${ssid}`);
    const { stdout, stderr } = await execAsync(command);

    if (stderr && !stderr.includes('successfully deleted')) {
      console.error(`nmcli delete stderr for SSID "${ssid}":`, stderr);
      return NextResponse.json({ error: 'Failed to delete the network.', details: stderr }, { status: 500 });
    }

    console.log(`Successfully deleted saved network: ${ssid}`);
    console.log('nmcli stdout:', stdout);
    return NextResponse.json({ message: `Successfully deleted ${ssid}` });

  } catch (error) {
    console.error('Failed to process delete request:', error);
    if (error instanceof SyntaxError) {
      return NextResponse.json({ error: 'Invalid JSON in request body' }, { status: 400 });
    }
    return NextResponse.json(
      { error: 'An unexpected error occurred.', details: error instanceof Error ? error.message : String(error) },
      { status: 500 }
    );
  }
}
