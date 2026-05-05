import { NextRequest, NextResponse } from 'next/server';
import { readFile, rename, writeFile } from 'fs/promises';
import { existsSync } from 'fs';
import yaml from 'js-yaml';

const CONFIG_PATH = '/etc/arlowe/config.yml';
const CONFIG_TMP_PATH = '/etc/arlowe/.config.yml.tmp';

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
    const body = await request.json();
    const raw = yaml.dump(body);

    await writeFile(CONFIG_TMP_PATH, raw, 'utf-8');
    await rename(CONFIG_TMP_PATH, CONFIG_PATH);

    // TODO(phase-4): validate against config/schema.yml before writing.
    return NextResponse.json({ ok: true, written: CONFIG_PATH });
  } catch (error) {
    console.error('Failed to write config:', error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
