'use client';

import { useEffect, useState, useCallback } from 'react';
import ProviderBadge from '../components/ProviderBadge';

interface LogEntry {
  timestamp: string;
  type: 'voice' | 'command' | 'session' | 'subagent' | 'cron' | 'service';
  content: string;
  metadata?: Record<string, unknown>;
}

interface LogMeta {
  total: number;
  type: string;
  search: string | null;
}

type LogType = 'all' | 'voice' | 'command' | 'session' | 'subagent' | 'cron' | 'service';

export default function LogsPage() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [meta, setMeta] = useState<LogMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [logType, setLogType] = useState<LogType>('all');
  const [search, setSearch] = useState('');
  const [searchInput, setSearchInput] = useState('');
  const [startDate, setStartDate] = useState(() => {
    const d = new Date(); d.setDate(d.getDate() - 7);
    return d.toISOString().split('T')[0];
  });
  const [endDate, setEndDate] = useState(() => new Date().toISOString().split('T')[0]);
  const [expandedIdx, setExpandedIdx] = useState<number | null>(null);

  const fetchLogs = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams({ type: logType, start: startDate, end: endDate, limit: '200' });
      if (search) params.set('q', search);
      const res = await fetch(`/api/logs?${params}`);
      if (res.ok) {
        const data = await res.json();
        setLogs(data.logs || []);
        setMeta(data.meta || null);
      }
    } catch (err) {
      console.error('Failed to fetch logs:', err);
    } finally {
      setLoading(false);
    }
  }, [logType, startDate, endDate, search]);

  useEffect(() => { fetchLogs(); }, [fetchLogs]);

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setSearch(searchInput);
  };

  const setQuickRange = (days: number) => {
    const end = new Date();
    const start = new Date();
    start.setDate(start.getDate() - days);
    setStartDate(start.toISOString().split('T')[0]);
    setEndDate(end.toISOString().split('T')[0]);
  };

  const toggleExpand = (idx: number) => {
    setExpandedIdx(prev => prev === idx ? null : idx);
  };

  const typeIcon: Record<string, string> = { voice: '🎤', command: '⚡', session: '💬', subagent: '🤖', cron: '⏰', service: '⚙️' };

  return (
    <>
      <h1 className="text-2xl font-bold mb-4">Logs</h1>

        {/* Filters — stacked layout */}
        <div className="card p-3 mb-4 space-y-2">
          {/* Row 1: Search */}
          <form onSubmit={handleSearch}>
            <div className="relative">
              <input
                type="text"
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
                placeholder="Search transcripts, responses, models..."
                className="w-full px-3 py-2 pl-8 rounded-lg bg-[var(--background)] border border-[var(--border)] text-sm"
              />
              <span className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[var(--muted)] text-sm">🔍</span>
              {search && (
                <button
                  type="button"
                  onClick={() => { setSearch(''); setSearchInput(''); }}
                  className="absolute right-2.5 top-1/2 -translate-y-1/2 text-[var(--muted)] text-xs hover:text-[var(--foreground)]"
                >
                  ✕
                </button>
              )}
            </div>
          </form>

          {/* Row 2: Log type pills */}
          <div className="flex gap-1.5">
            {(['all', 'voice', 'session', 'subagent', 'command', 'cron', 'service'] as const).map((t) => (
              <button
                key={t}
                onClick={() => setLogType(t)}
                className={`px-3 py-1 rounded-full text-xs font-medium transition-smooth ${
                  logType === t
                    ? 'bg-[var(--accent)] text-white'
                    : 'bg-[var(--background)] text-[var(--muted)] hover:text-[var(--foreground)]'
                }`}
              >
                {t === 'all' ? 'All' : `${typeIcon[t] || '📝'} ${t.charAt(0).toUpperCase() + t.slice(1)}`}
              </button>
            ))}
          </div>

          {/* Row 3: Date range + quick picks */}
          <div className="flex items-center gap-2 flex-wrap">
            <input
              type="date"
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              className="px-2 py-1 rounded-lg bg-[var(--background)] border border-[var(--border)] text-xs"
            />
            <span className="text-[var(--muted)] text-xs">–</span>
            <input
              type="date"
              value={endDate}
              onChange={(e) => setEndDate(e.target.value)}
              className="px-2 py-1 rounded-lg bg-[var(--background)] border border-[var(--border)] text-xs"
            />
            <span className="text-[var(--border)]">|</span>
            {[
              { label: 'Today', days: 0 },
              { label: '7d', days: 7 },
              { label: '30d', days: 30 },
            ].map(({ label, days }) => (
              <button
                key={label}
                onClick={() => setQuickRange(days)}
                className="px-2 py-1 rounded-full text-xs bg-[var(--background)] text-[var(--muted)] hover:text-[var(--foreground)] transition-smooth"
              >
                {label}
              </button>
            ))}
          </div>
        </div>

        {/* Results count */}
        {meta && !loading && (
          <div className="text-[var(--muted)] text-xs mb-3">
            {meta.total} result{meta.total !== 1 ? 's' : ''}
            {meta.search && <span> for &ldquo;{meta.search}&rdquo;</span>}
          </div>
        )}

        {/* Log entries */}
        {loading ? (
          <div className="flex items-center justify-center h-48 text-[var(--muted)]">Loading...</div>
        ) : logs.length === 0 ? (
          <div className="card p-8 text-center text-[var(--muted)]">
            <p>No logs found</p>
            <p className="text-xs mt-1">Adjust filters or date range</p>
          </div>
        ) : (
          <div className="space-y-1">
            {logs.map((log, idx) => {
              const isExpanded = expandedIdx === idx;
              return (
                <div
                  key={idx}
                  className={`card px-3 py-2 transition-smooth ${isExpanded ? 'bg-[var(--card-hover)]' : ''}`}
                >
                  {/* Compact row — always visible */}
                  <div
                    className="flex items-center gap-2 cursor-pointer"
                    onClick={() => toggleExpand(idx)}
                  >
                    <span className="text-xs flex-shrink-0">{typeIcon[log.type] || '📝'}</span>

                    {log.metadata?.provider ? (
                      <ProviderBadge provider={String(log.metadata.provider)} size="sm" />
                    ) : null}

                    {log.metadata?.model ? (
                      <span className="text-[10px] px-1.5 py-0.5 rounded bg-[var(--background)] text-[var(--muted)] font-mono flex-shrink-0">
                        {String(log.metadata.model)}
                      </span>
                    ) : null}

                    {log.metadata?.role && log.type === 'session' ? (
                      <span className={`text-[10px] px-1.5 py-0.5 rounded flex-shrink-0 ${
                        log.metadata.role === 'user' ? 'bg-[var(--accent)]/20 text-[var(--accent)]' : 'bg-[var(--local)]/20 text-[var(--local)]'
                      }`}>
                        {String(log.metadata.role)}
                      </span>
                    ) : null}

                    <span className="truncate flex-1 text-xs">
                      {log.type === 'voice' ? String(log.metadata?.transcript || '') : log.content}
                    </span>

                    {log.metadata?.latencyMs != null && Number(log.metadata.latencyMs) > 0 ? (
                      <span className="text-[var(--muted)] text-[10px] flex-shrink-0">
                        {String(log.metadata.latencyMs)}ms
                      </span>
                    ) : null}

                    <span className="text-[var(--muted)] text-[10px] flex-shrink-0 whitespace-nowrap">
                      {new Date(log.timestamp).toLocaleString('en-US', {
                        month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
                      })}
                    </span>

                    <span className={`text-[10px] text-[var(--muted)] transition-transform flex-shrink-0 ${isExpanded ? 'rotate-90' : ''}`}>
                      ▶
                    </span>
                  </div>

                  {/* Expanded detail */}
                  {isExpanded && (
                    <div className="mt-2 pt-2 border-t border-[var(--border)] text-xs space-y-2">
                      {log.type === 'voice' && log.metadata && (
                        <>
                          <div>
                            <span className="text-[var(--muted)] font-medium">You: </span>
                            <span>{String(log.metadata.transcript || '')}</span>
                          </div>
                          <div>
                            <span className="text-[var(--muted)] font-medium">Arlowe: </span>
                            <span className="whitespace-pre-wrap">{String(log.metadata.response || '')}</span>
                          </div>
                          <div className="flex flex-wrap gap-3 text-[var(--muted)] pt-1">
                            {log.metadata.provider ? (
                              <span>Provider: <span className="text-[var(--foreground)]">{String(log.metadata.provider)}</span></span>
                            ) : null}
                            {log.metadata.model ? (
                              <span>Model: <span className="font-mono text-[var(--foreground)]">{String(log.metadata.model)}</span></span>
                            ) : null}
                            {log.metadata.latencyMs != null ? (
                              <span>Latency: <span className="text-[var(--foreground)]">{String(log.metadata.latencyMs)}ms</span></span>
                            ) : null}
                          </div>
                        </>
                      )}
                      {log.type === 'command' && log.metadata && (
                        <div className="text-[var(--muted)]">
                          <div>Action: <span className="text-[var(--accent)]">/{String(log.metadata.action)}</span></div>
                          {log.metadata.source ? <div>Source: {String(log.metadata.source)}</div> : null}
                          {log.metadata.sessionKey ? <div className="truncate">Session: {String(log.metadata.sessionKey)}</div> : null}
                        </div>
                      )}
                      {log.type === 'session' && (
                        <div className="whitespace-pre-wrap">
                          {log.content}
                          {log.metadata?.role ? <div className="text-[var(--muted)] mt-1">Role: {String(log.metadata.role)}</div> : null}
                        </div>
                      )}
                      {log.type === 'cron' && (
                        <div className="text-[var(--muted)]">
                          {log.content}
                          {log.metadata?.jobId ? <div className="truncate mt-1">Job: {String(log.metadata.jobId)}</div> : null}
                        </div>
                      )}
                      {log.type === 'service' && (
                        <div className="text-[var(--muted)] font-mono text-[11px]">{log.content}</div>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
    </>
  );
}
