import { NextResponse } from 'next/server';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export async function GET() {
  try {
    // Check if NPU API is running
    const portCheck = await execAsync('ss -tlnp | grep 8000 || true');
    const isRunning = portCheck.stdout.includes('8000');

    // Get memory usage if running
    let memory = 0;
    if (isRunning) {
      try {
        const memCheck = await execAsync(
          "ps aux | grep main_api_axcl | grep -v grep | awk '{print $6}'"
        );
        memory = Math.round(parseInt(memCheck.stdout.trim()) / 1024);
      } catch {
        memory = 0;
      }
    }

    // Check tokenizer
    const tokenizerCheck = await execAsync('ss -tlnp | grep 12345 || true');
    const tokenizerRunning = tokenizerCheck.stdout.includes('12345');

    return NextResponse.json({
      status: isRunning ? 'online' : 'offline',
      apiPort: 8000,
      tokenizerPort: 12345,
      tokenizerStatus: tokenizerRunning ? 'online' : 'offline',
      memoryMB: memory,
      model: 'Qwen 2.5 7B INT4',
      contextWindow: 2048,
      estimatedTokPerSec: 5.0,
    });
  } catch (error) {
    console.error('NPU status error:', error);
    return NextResponse.json(
      { status: 'error', error: String(error) },
      { status: 500 }
    );
  }
}
