import { NextResponse } from 'next/server';

const NPU_API_URL = 'http://localhost:8000';

interface BenchmarkResult {
  name: string;
  prompt: string;
  response: string;
  ttftMs: number | null;
  totalMs: number;
  tokensPerSec: number;
  correct: boolean;
}

async function runSingleBenchmark(
  name: string,
  prompt: string,
  expectedContains?: string
): Promise<BenchmarkResult> {
  // Reset KV cache
  await fetch(`${NPU_API_URL}/api/reset`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  await new Promise((r) => setTimeout(r, 500));

  const startTime = Date.now();

  // Start generation
  await fetch(`${NPU_API_URL}/api/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt }),
  });

  // Poll for response
  let response = '';
  let firstTokenTime: number | null = null;
  let done = false;
  let iterations = 0;

  while (!done && iterations < 100) {
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
  const ttftMs = firstTokenTime ? firstTokenTime - startTime : null;
  const totalMs = endTime - startTime;
  const genTime = firstTokenTime ? endTime - firstTokenTime : totalMs;
  const wordCount = response.split(/\s+/).filter((w) => w.length > 0).length;
  const estimatedTokens = Math.round(wordCount * 1.3);
  const tokensPerSec =
    genTime > 0 ? Math.round((estimatedTokens / genTime) * 1000 * 10) / 10 : 0;

  const correct = expectedContains
    ? response.toLowerCase().includes(expectedContains.toLowerCase())
    : true;

  return {
    name,
    prompt,
    response,
    ttftMs,
    totalMs,
    tokensPerSec,
    correct,
  };
}

export async function POST() {
  try {
    // Check if NPU is running first
    const statusCheck = await fetch(`${NPU_API_URL}/api/reset`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    }).catch(() => null);

    if (!statusCheck || !statusCheck.ok) {
      return NextResponse.json(
        { error: 'NPU API not available. Is the service running?' },
        { status: 503 }
      );
    }

    const benchmarks = [
      { name: 'Simple Math', prompt: 'What is 25 + 37?', expected: '62' },
      { name: 'Multiplication', prompt: 'What is 15 times 7?', expected: '105' },
      { name: 'Capital City', prompt: 'What is the capital of France?', expected: 'paris' },
      { name: 'Basic Fact', prompt: 'What is the capital of Japan?', expected: 'tokyo' },
      {
        name: 'Short Explanation',
        prompt: 'Why is the sky blue? Answer in one sentence.',
        expected: 'scatter',
      },
    ];

    const results: BenchmarkResult[] = [];

    for (const bench of benchmarks) {
      const result = await runSingleBenchmark(bench.name, bench.prompt, bench.expected);
      results.push(result);
    }

    // Calculate averages
    const validTtft = results.filter((r) => r.ttftMs !== null);
    const avgTtft =
      validTtft.length > 0
        ? Math.round(validTtft.reduce((sum, r) => sum + (r.ttftMs || 0), 0) / validTtft.length)
        : null;
    const avgTotal = Math.round(results.reduce((sum, r) => sum + r.totalMs, 0) / results.length);
    const avgTps =
      Math.round(
        (results.reduce((sum, r) => sum + r.tokensPerSec, 0) / results.length) * 10
      ) / 10;
    const accuracy = Math.round((results.filter((r) => r.correct).length / results.length) * 100);

    return NextResponse.json({
      results,
      summary: {
        avgTtftMs: avgTtft,
        avgTotalMs: avgTotal,
        avgTokPerSec: avgTps,
        accuracy,
        testsRun: results.length,
        testsPassed: results.filter((r) => r.correct).length,
      },
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error('Benchmark error:', error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}

export async function GET() {
  return NextResponse.json({
    message: 'POST to this endpoint to run benchmarks',
    benchmarks: [
      'Simple Math',
      'Multiplication',
      'Capital City',
      'Basic Fact',
      'Short Explanation',
    ],
  });
}
