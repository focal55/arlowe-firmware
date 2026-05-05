import { NextResponse } from 'next/server';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export async function GET() {
  try {
    // Get system stats
    const statsCmd = `
      cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1);
      mem=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}');
      temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.0f", $1/1000}' || echo "0");
      disk=$(df / | awk 'NR==2 {print $5}' | tr -d '%');
      uptime=$(uptime -p | sed 's/up //');
      echo "$cpu|$mem|$temp|$disk|$uptime"
    `;

    const { stdout: stats } = await execAsync(statsCmd);
    const [cpu, memory, temp, disk, uptime] = stats.trim().split('|');

    // Check NPU status
    let npuStatus = 'Offline';
    try {
      const { stdout: npuOut } = await execAsync('/usr/bin/axcl/axcl-smi 2>/dev/null | grep -q "AX8850" && echo "Online" || echo "Offline"');
      npuStatus = npuOut.trim();
    } catch {
      npuStatus = 'Offline';
    }

    return NextResponse.json({
      cpu: parseFloat(cpu) || 0,
      memory: parseInt(memory) || 0,
      temp: parseInt(temp) || 0,
      disk: parseInt(disk) || 0,
      uptime: uptime || 'unknown',
      npuStatus,
    });
  } catch (error) {
    console.error('Health check failed:', error);
    return NextResponse.json(
      { error: 'Failed to fetch health data' },
      { status: 500 }
    );
  }
}
