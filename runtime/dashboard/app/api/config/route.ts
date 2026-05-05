import { NextRequest, NextResponse } from 'next/server';
import { readFile, writeFile } from 'fs/promises';
import { existsSync } from 'fs';
import path from 'path';

// TODO(plan-08): repoint to /etc/arlowe/config.yml and replace ALLOWED_FILES with product config schema
const WORKSPACE = '/home/focal55/.openclaw/workspace';

// Only allow editing specific files
const ALLOWED_FILES = [
  'SOUL.md',
  'AGENTS.md',
  'USER.md',
  'TOOLS.md',
  'MEMORY.md',
  'HEARTBEAT.md',
  'IDENTITY.md',
];

function isPathSafe(filePath: string): boolean {
  const normalized = path.normalize(filePath);
  // Prevent directory traversal
  if (normalized.includes('..') || normalized.startsWith('/')) {
    return false;
  }
  return ALLOWED_FILES.includes(normalized);
}

export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams;
  const filePath = searchParams.get('path');

  if (!filePath || !isPathSafe(filePath)) {
    return NextResponse.json({ error: 'Invalid path' }, { status: 400 });
  }

  const fullPath = path.join(WORKSPACE, filePath);

  if (!existsSync(fullPath)) {
    return NextResponse.json({ content: '' });
  }

  try {
    const content = await readFile(fullPath, 'utf-8');
    return NextResponse.json({ content });
  } catch (error) {
    console.error('Failed to read file:', error);
    return NextResponse.json({ error: 'Failed to read file' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const { path: filePath, content } = await request.json();

    if (!filePath || !isPathSafe(filePath)) {
      return NextResponse.json({ error: 'Invalid path' }, { status: 400 });
    }

    if (typeof content !== 'string') {
      return NextResponse.json({ error: 'Content must be a string' }, { status: 400 });
    }

    const fullPath = path.join(WORKSPACE, filePath);
    await writeFile(fullPath, content, 'utf-8');

    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Failed to write file:', error);
    return NextResponse.json({ error: 'Failed to write file' }, { status: 500 });
  }
}
