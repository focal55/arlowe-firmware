import { NextRequest, NextResponse } from 'next/server';
import { readFile, rename, writeFile } from 'fs/promises';
import { existsSync } from 'fs';
import { execFile } from 'child_process';
import { promisify } from 'util';
import yaml from 'js-yaml';
import Ajv2020 from 'ajv/dist/2020';
import { unitsForChange } from './restart-map';

const execFileAsync = promisify(execFile);

const CONFIG_PATH = '/etc/arlowe/config.yml';
const CONFIG_TMP_PATH = '/etc/arlowe/.config.yml.tmp';
const SCHEMA_PATH = process.env.ARLOWE_SCHEMA_PATH ?? '/opt/arlowe/config/schema.yml';

// Mirrors the ARLOWE_SYSTEMCTL_MODE seam from api/voice/route.ts.
// system = polkit-authorized system units (Phase 3+); user = dev fallback.
const SYSTEMCTL_MODE = process.env.ARLOWE_SYSTEMCTL_MODE ?? 'user';

function systemctlArgs(subcommand: string, unit: string): string[] {
  return SYSTEMCTL_MODE === 'system'
    ? ['systemctl', subcommand, unit]
    : ['systemctl', '--user', subcommand, unit];
}

function changedTopLevelKeys(
  body: Record<string, unknown>,
  previous: Record<string, unknown> | null
): string[] {
  if (previous === null) {
    // No prior overlay on disk — treat all body keys as changed.
    return Object.keys(body);
  }
  return Object.keys(body).filter(
    k => JSON.stringify(body[k]) !== JSON.stringify(previous[k])
  );
}

export async function GET(_request: NextRequest) {
  if (!existsSync(CONFIG_PATH)) {
    return NextResponse.json({ paired: false, config: null, message: 'Device is not paired.' });
  }

  try {
    const raw = await readFile(CONFIG_PATH, 'utf-8');
    const config = yaml.load(raw);
    return NextResponse.json({ paired: true, config });
  } catch (error) {
    console.error('Failed to parse config:', error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json() as Record<string, unknown>;

    // Validate against config/schema.yml (JSON Schema draft 2020-12) before writing.
    // An invalid body is rejected with 422; nothing is written to disk.
    const schemaRaw = await readFile(SCHEMA_PATH, 'utf-8');
    const schema = yaml.load(schemaRaw) as object;
    const ajv = new Ajv2020({ allErrors: true });
    const validate = ajv.compile(schema);
    if (!validate(body)) {
      return NextResponse.json(
        { error: 'schema violation', details: validate.errors },
        { status: 422 }
      );
    }

    // Read the current on-disk overlay (if present) to diff for restart targeting.
    let previous: Record<string, unknown> | null = null;
    if (existsSync(CONFIG_PATH)) {
      try {
        const prevRaw = await readFile(CONFIG_PATH, 'utf-8');
        const parsed = yaml.load(prevRaw);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          previous = parsed as Record<string, unknown>;
        }
      } catch {
        // Unreadable overlay: treat all body keys as changed (conservative).
      }
    }

    // Atomic write: temp file + rename so a crash mid-write cannot leave a partial overlay.
    const raw = yaml.dump(body);
    await writeFile(CONFIG_TMP_PATH, raw, 'utf-8');
    await rename(CONFIG_TMP_PATH, CONFIG_PATH);

    // Restart affected units for changed knobs. A restart failure is non-fatal:
    // the config is already written; log the error and include it in the response.
    const changed = changedTopLevelKeys(body, previous);
    const units = unitsForChange(changed);
    const restarted: string[] = [];
    const restartErrors: string[] = [];

    for (const unit of units) {
      try {
        const args = systemctlArgs('restart', unit);
        await execFileAsync(args[0], args.slice(1), { timeout: 10000 });
        restarted.push(unit);
      } catch (err) {
        const msg = `${unit}: ${String(err)}`;
        console.error('Restart failed (non-fatal):', msg);
        restartErrors.push(msg);
      }
    }

    return NextResponse.json({ ok: true, written: CONFIG_PATH, restarted, restartErrors });
  } catch (error) {
    console.error('Failed to write config:', error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
