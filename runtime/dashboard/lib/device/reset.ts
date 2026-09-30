import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export const RESET_UNIT = 'arlowe-factory-reset@dashboard.service';

// Route modules may only export handlers, so the test seam lives here.
export const resetDeps = {
  execFile: async (file: string, args: string[]): Promise<void> => {
    await execFileAsync(file, args, { timeout: 10_000 });
  },
};

// --no-block: the reset stops this dashboard, so the start must return before the 202 is sent.
export function startReset(): Promise<void> {
  return resetDeps.execFile('systemctl', ['start', '--no-block', RESET_UNIT]);
}
