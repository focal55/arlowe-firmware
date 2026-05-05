import { NextRequest, NextResponse } from 'next/server';

const NPU_API_URL = 'http://localhost:8000';

export async function POST(request: NextRequest) {
  try {
    const { message, reset } = await request.json();

    // Optionally reset KV cache before new conversation
    if (reset) {
      await fetch(`${NPU_API_URL}/api/reset`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      });
      // Small delay after reset
      await new Promise((r) => setTimeout(r, 300));
    }

    const startTime = Date.now();

    // Start generation
    const genResponse = await fetch(`${NPU_API_URL}/api/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt: message }),
    });

    if (!genResponse.ok) {
      const error = await genResponse.text();
      return NextResponse.json({ error }, { status: 500 });
    }

    // Poll for response
    let response = '';
    let firstTokenTime: number | null = null;
    let done = false;
    let iterations = 0;
    const maxIterations = 200; // ~20 seconds max

    while (!done && iterations < maxIterations) {
      const pollResponse = await fetch(`${NPU_API_URL}/api/generate_provider`);
      const data = await pollResponse.json();

      if (data.response && data.response.length > 0) {
        if (firstTokenTime === null) {
          firstTokenTime = Date.now();
        }
        response += data.response;
      }

      done = data.done === true;
      if (!done) {
        await new Promise((r) => setTimeout(r, 100));
      }
      iterations++;
    }

    const endTime = Date.now();
    const ttft = firstTokenTime ? firstTokenTime - startTime : null;
    const totalTime = endTime - startTime;
    const wordCount = response.split(/\s+/).filter((w) => w.length > 0).length;
    const estimatedTokens = Math.round(wordCount * 1.3);
    const genTime = firstTokenTime ? endTime - firstTokenTime : totalTime;
    const tokensPerSec =
      genTime > 0 ? Math.round((estimatedTokens / genTime) * 1000 * 10) / 10 : 0;

    return NextResponse.json({
      response,
      metrics: {
        ttftMs: ttft,
        totalMs: totalTime,
        genTimeMs: genTime,
        wordCount,
        estimatedTokens,
        tokensPerSec,
      },
    });
  } catch (error) {
    console.error('NPU chat error:', error);
    return NextResponse.json(
      { error: String(error) },
      { status: 500 }
    );
  }
}
