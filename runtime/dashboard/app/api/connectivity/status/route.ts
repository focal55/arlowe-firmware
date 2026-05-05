import { NextResponse } from 'next/server';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export async function GET() {
  console.log('--- [arlowe-dashboard-backend] GET /api/connectivity/status ---');

  try {
    // Get active WiFi connection (TYPE is "802-11-wireless" in nmcli)
    const { stdout: activeConn } = await execAsync(
      "nmcli -t -f NAME,TYPE,DEVICE connection show --active | grep 802-11-wireless"
    ).catch(() => ({ stdout: '' }));

    if (!activeConn.trim()) {
      return NextResponse.json({
        connected: false,
        ssid: 'Not Connected',
        ipAddress: 'N/A',
        signalStrength: 'N/A',
        security: 'N/A',
      });
    }

    const [ssid, , device] = activeConn.trim().split(':');

    // Get IP address
    let ipAddress = 'N/A';
    try {
      const { stdout: ipOut } = await execAsync(
        `ip -4 addr show ${device} | grep inet | awk '{print $2}' | cut -d/ -f1`
      );
      ipAddress = ipOut.trim() || 'N/A';
    } catch {}

    // Get signal strength
    let signalStrength = 'N/A';
    try {
      const { stdout: signalOut } = await execAsync(
        `nmcli -t -f IN-USE,SIGNAL device wifi list | grep '\\*' | cut -d: -f2`
      );
      const signal = signalOut.trim();
      if (signal) signalStrength = `${signal}%`;
    } catch {}

    // Get security type
    let security = 'N/A';
    try {
      const { stdout: secOut } = await execAsync(
        `nmcli -t -f IN-USE,SECURITY device wifi list | grep '\\*' | cut -d: -f2`
      );
      security = secOut.trim() || 'N/A';
    } catch {}

    return NextResponse.json({
      connected: true,
      ssid: ssid || 'Unknown',
      ipAddress,
      signalStrength,
      security,
    });

  } catch (error) {
    console.error('Failed to get network status:', error);
    return NextResponse.json(
      { error: 'Failed to execute nmcli command', details: error instanceof Error ? error.message : String(error) },
      { status: 500 }
    );
  }
}
