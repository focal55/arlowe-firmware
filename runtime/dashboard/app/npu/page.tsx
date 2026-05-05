'use client';

import { useEffect, useState, useRef, useCallback } from 'react';
import Link from 'next/link';

interface NpuStatus {
  status: string;
  memoryMB: number;
  model: string;
  contextWindow: number;
  estimatedTokPerSec: number;
  tokenizerStatus: string;
}

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  metrics?: {
    ttftMs: number | null;
    totalMs: number;
    tokensPerSec: number;
  };
}

interface BenchmarkResult {
  name: string;
  prompt: string;
  response: string;
  ttftMs: number | null;
  totalMs: number;
  tokensPerSec: number;
  correct: boolean;
}

interface BenchmarkData {
  results: BenchmarkResult[];
  summary: {
    avgTtftMs: number | null;
    avgTotalMs: number;
    avgTokPerSec: number;
    accuracy: number;
    testsRun: number;
    testsPassed: number;
  };
  timestamp: string;
}

export default function NpuPage() {
  const [status, setStatus] = useState<NpuStatus | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [benchmark, setBenchmark] = useState<BenchmarkData | null>(null);
  const [benchmarkLoading, setBenchmarkLoading] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const fetchStatus = useCallback(async () => {
    try {
      const res = await fetch('/api/npu/status');
      if (res.ok) {
        setStatus(await res.json());
      }
    } catch (err) {
      console.error('Failed to fetch NPU status:', err);
    }
  }, []);

  useEffect(() => {
    fetchStatus();
    const interval = setInterval(fetchStatus, 10000);
    return () => clearInterval(interval);
  }, [fetchStatus]);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  const sendMessage = async () => {
    if (!input.trim() || loading) return;

    const userMessage = input.trim();
    setInput('');
    setMessages((prev) => [...prev, { role: 'user', content: userMessage }]);
    setLoading(true);

    try {
      const res = await fetch('/api/npu/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: userMessage }),
      });

      const data = await res.json();

      if (data.error) {
        setMessages((prev) => [
          ...prev,
          { role: 'assistant', content: `Error: ${data.error}` },
        ]);
      } else {
        setMessages((prev) => [
          ...prev,
          {
            role: 'assistant',
            content: data.response || '(no response)',
            metrics: data.metrics,
          },
        ]);
      }
    } catch (err) {
      setMessages((prev) => [
        ...prev,
        { role: 'assistant', content: `Error: ${err}` },
      ]);
    } finally {
      setLoading(false);
    }
  };

  const runBenchmark = async () => {
    setBenchmarkLoading(true);
    try {
      const res = await fetch('/api/npu/benchmark', { method: 'POST' });
      const data = await res.json();
      if (data.error) {
        alert(`Benchmark error: ${data.error}`);
      } else {
        setBenchmark(data);
      }
    } catch (err) {
      alert(`Benchmark failed: ${err}`);
    } finally {
      setBenchmarkLoading(false);
    }
  };

  const clearChat = async () => {
    setMessages([]);
    // Reset KV cache
    try {
      await fetch('/api/npu/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: '', reset: true }),
      });
    } catch {
      // Ignore reset errors
    }
  };

  return (
    <div className="min-h-screen bg-black text-white p-6">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-4">
          <Link href="/" className="text-gray-400 hover:text-white">
            ← Dashboard
          </Link>
          <h1 className="text-2xl font-bold">NPU Testing Lab</h1>
        </div>
        <div className="flex items-center gap-2">
          <span
            className={`w-3 h-3 rounded-full ${
              status?.status === 'online' ? 'bg-green-500' : 'bg-red-500'
            }`}
          />
          <span className="text-sm text-gray-400">
            {status?.status === 'online' ? 'NPU Online' : 'NPU Offline'}
          </span>
        </div>
      </div>

      {/* Status Cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
        <div className="bg-gray-900 rounded-lg p-4 border border-gray-800">
          <div className="text-gray-400 text-sm">Model</div>
          <div className="text-lg font-semibold">{status?.model || 'Unknown'}</div>
        </div>
        <div className="bg-gray-900 rounded-lg p-4 border border-gray-800">
          <div className="text-gray-400 text-sm">Memory</div>
          <div className="text-lg font-semibold">{status?.memoryMB || 0} MB</div>
        </div>
        <div className="bg-gray-900 rounded-lg p-4 border border-gray-800">
          <div className="text-gray-400 text-sm">Context Window</div>
          <div className="text-lg font-semibold">{status?.contextWindow || 0} tokens</div>
        </div>
        <div className="bg-gray-900 rounded-lg p-4 border border-gray-800">
          <div className="text-gray-400 text-sm">Est. Speed</div>
          <div className="text-lg font-semibold">~{status?.estimatedTokPerSec || 0} tok/s</div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Chat Interface */}
        <div className="bg-gray-900 rounded-lg border border-gray-800 flex flex-col h-[600px]">
          <div className="p-4 border-b border-gray-800 flex justify-between items-center">
            <h2 className="text-lg font-semibold">Chat with NPU</h2>
            <button
              onClick={clearChat}
              className="text-sm text-gray-400 hover:text-white"
            >
              Clear
            </button>
          </div>

          {/* Messages */}
          <div className="flex-1 overflow-y-auto p-4 space-y-4">
            {messages.length === 0 && (
              <div className="text-gray-500 text-center py-8">
                Send a message to test the local NPU
              </div>
            )}
            {messages.map((msg, idx) => (
              <div
                key={idx}
                className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
              >
                <div
                  className={`max-w-[80%] rounded-lg p-3 ${
                    msg.role === 'user'
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-800 text-gray-100'
                  }`}
                >
                  <div>{msg.content}</div>
                  {msg.metrics && (
                    <div className="text-xs text-gray-400 mt-2 border-t border-gray-700 pt-2">
                      TTFT: {msg.metrics.ttftMs}ms | Total: {msg.metrics.totalMs}ms |{' '}
                      {msg.metrics.tokensPerSec} tok/s
                    </div>
                  )}
                </div>
              </div>
            ))}
            {loading && (
              <div className="flex justify-start">
                <div className="bg-gray-800 rounded-lg p-3 text-gray-400">
                  <span className="animate-pulse">Thinking...</span>
                </div>
              </div>
            )}
            <div ref={messagesEndRef} />
          </div>

          {/* Input */}
          <div className="p-4 border-t border-gray-800">
            <div className="flex gap-2">
              <input
                type="text"
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && sendMessage()}
                placeholder="Type a message..."
                disabled={loading || status?.status !== 'online'}
                className="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-4 py-2 text-white placeholder-gray-500 focus:outline-none focus:border-blue-500 disabled:opacity-50"
              />
              <button
                onClick={sendMessage}
                disabled={loading || !input.trim() || status?.status !== 'online'}
                className="bg-blue-600 hover:bg-blue-700 disabled:bg-gray-700 disabled:opacity-50 px-4 py-2 rounded-lg font-semibold transition-colors"
              >
                Send
              </button>
            </div>
          </div>
        </div>

        {/* Benchmark Panel */}
        <div className="bg-gray-900 rounded-lg border border-gray-800 flex flex-col h-[600px]">
          <div className="p-4 border-b border-gray-800 flex justify-between items-center">
            <h2 className="text-lg font-semibold">Benchmarks</h2>
            <button
              onClick={runBenchmark}
              disabled={benchmarkLoading || status?.status !== 'online'}
              className="bg-green-600 hover:bg-green-700 disabled:bg-gray-700 disabled:opacity-50 px-4 py-2 rounded-lg text-sm font-semibold transition-colors"
            >
              {benchmarkLoading ? 'Running...' : 'Run Benchmarks'}
            </button>
          </div>

          <div className="flex-1 overflow-y-auto p-4">
            {!benchmark && !benchmarkLoading && (
              <div className="text-gray-500 text-center py-8">
                Click &quot;Run Benchmarks&quot; to test NPU performance
              </div>
            )}

            {benchmarkLoading && (
              <div className="text-center py-8">
                <div className="animate-spin w-8 h-8 border-2 border-blue-500 border-t-transparent rounded-full mx-auto mb-4" />
                <div className="text-gray-400">Running benchmarks...</div>
                <div className="text-gray-500 text-sm">This may take 30-60 seconds</div>
              </div>
            )}

            {benchmark && (
              <div className="space-y-4">
                {/* Summary */}
                <div className="grid grid-cols-2 gap-3">
                  <div className="bg-gray-800 rounded-lg p-3">
                    <div className="text-gray-400 text-xs">Avg TTFT</div>
                    <div className="text-xl font-bold text-blue-400">
                      {benchmark.summary.avgTtftMs || 'N/A'}ms
                    </div>
                  </div>
                  <div className="bg-gray-800 rounded-lg p-3">
                    <div className="text-gray-400 text-xs">Avg Total</div>
                    <div className="text-xl font-bold text-purple-400">
                      {benchmark.summary.avgTotalMs}ms
                    </div>
                  </div>
                  <div className="bg-gray-800 rounded-lg p-3">
                    <div className="text-gray-400 text-xs">Tok/s</div>
                    <div className="text-xl font-bold text-green-400">
                      {benchmark.summary.avgTokPerSec}
                    </div>
                  </div>
                  <div className="bg-gray-800 rounded-lg p-3">
                    <div className="text-gray-400 text-xs">Accuracy</div>
                    <div className="text-xl font-bold text-yellow-400">
                      {benchmark.summary.accuracy}%
                    </div>
                  </div>
                </div>

                {/* Individual Results */}
                <div className="space-y-2">
                  <h3 className="text-sm font-semibold text-gray-400">Test Results</h3>
                  {benchmark.results.map((result, idx) => (
                    <div
                      key={idx}
                      className="bg-gray-800 rounded-lg p-3 border border-gray-700"
                    >
                      <div className="flex justify-between items-start mb-2">
                        <span className="font-semibold">{result.name}</span>
                        <span
                          className={`text-xs px-2 py-1 rounded ${
                            result.correct
                              ? 'bg-green-900 text-green-300'
                              : 'bg-red-900 text-red-300'
                          }`}
                        >
                          {result.correct ? '✓ Pass' : '✗ Fail'}
                        </span>
                      </div>
                      <div className="text-sm text-gray-400 mb-1">
                        Q: {result.prompt}
                      </div>
                      <div className="text-sm mb-2">A: {result.response}</div>
                      <div className="text-xs text-gray-500">
                        TTFT: {result.ttftMs}ms | Total: {result.totalMs}ms |{' '}
                        {result.tokensPerSec} tok/s
                      </div>
                    </div>
                  ))}
                </div>

                <div className="text-xs text-gray-500 text-center">
                  Last run: {new Date(benchmark.timestamp).toLocaleString()}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
