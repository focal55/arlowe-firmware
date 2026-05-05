import { NextRequest, NextResponse } from 'next/server';
import { exec } from 'child_process';
import { promisify } from 'util';
// import { verifyAuth } from '../../middleware/auth';

const execAsync = promisify(exec);

export async function POST(request: NextRequest) {
  console.log('--- [arlowe-dashboard-backend] POST /api/connectivity/connect ---');
  
  // TODO: Re-enable auth after adding UI flow for authentication
  // const authError = verifyAuth(request);
  // if (authError) return authError;
  
  try {
    const body = await request.json();
    const { ssid, password } = body;

    if (!ssid) {
      return NextResponse.json({ error: 'SSID is required' }, { status: 400 });
    }

    let command: string;
    
    // Check if this is a saved network (has existing profile)
    let isSavedNetwork = false;
    try {
      const { stdout } = await execAsync(`nmcli -t -f NAME connection show | grep -x '${ssid}'`);
      isSavedNetwork = stdout.trim() === ssid;
    } catch {
      // Not a saved network
    }
    
    if (isSavedNetwork && !password) {
      // Use connection up for saved networks (credentials already stored)
      command = `nmcli connection up '${ssid}'`;
      console.log(`Connecting to saved network: ${ssid}`);
    } else if (password) {
      // New network with password - delete any broken profile first
      try {
        await execAsync(`nmcli connection delete '${ssid}' 2>/dev/null || true`);
      } catch {
        // Ignore
      }
      const escapedPassword = password.replace(/'/g, "'\\''");
      command = `nmcli device wifi connect '${ssid}' password '${escapedPassword}'`;
      console.log(`Connecting to new network: ${ssid}`);
    } else {
      // Open network
      command = `nmcli device wifi connect '${ssid}'`;
      console.log(`Connecting to open network: ${ssid}`);
    }
    
    console.log(`Executing connect command for SSID: ${ssid}`);
    const { stdout, stderr } = await execAsync(command, { timeout: 30000 });

    if (stderr) {
      console.error(`nmcli connect stderr for SSID "${ssid}":`, stderr);
      // Check for common connection errors
      if (stderr.includes('Error: No network with SSID')) {
        return NextResponse.json({ error: `Network not found: ${ssid}` }, { status: 404 });
      }
      if (stderr.includes('Error: Connection activation failed')) {
         return NextResponse.json({ error: 'Connection failed. Please check the password.' }, { status: 401 });
      }
      return NextResponse.json({ error: 'Failed to connect to the network.', details: stderr }, { status: 500 });
    }

    console.log(`Successfully connected to SSID: ${ssid}`);
    console.log('nmcli stdout:', stdout);
    return NextResponse.json({ message: `Successfully connected to ${ssid}` });

  } catch (error) {
    console.error('Failed to process connection request:', error);
    // Handle cases where the request body is malformed
    if (error instanceof SyntaxError) {
      return NextResponse.json({ error: 'Invalid JSON in request body' }, { status: 400 });
    }
    return NextResponse.json(
      { error: 'An unexpected error occurred.', details: error instanceof Error ? error.message : String(error) },
      { status: 500 }
    );
  }
}
