'use client';

import { useEffect, useState, useCallback } from 'react';
import StatusCard from './components/StatusCard';
import RetroActivityMonitor from './components/RetroActivityMonitor';

interface SystemHealth {
  cpu: number;
  memory: number;
  temp: number;
  disk: number;
  uptime: string;
  npuStatus: string;
}

interface VoiceStatus {
  active: boolean;
  uptime: string;
}

export default function Dashboard() {
  const [health, setHealth] = useState<SystemHealth | null>(null);
  const [voice, setVoice] = useState<VoiceStatus | null>(null);
  const [voiceLoading, setVoiceLoading] = useState(false);
  const [loading, setLoading] = useState(true);

  const fetchData = useCallback(async () => {
    try {
      // TODO(plan-08): expand fetches to include product-relevant health/voice payload
      const [healthRes, voiceRes] = await Promise.all([
        fetch('/api/health'),
        fetch('/api/voice'),
      ]);

      if (healthRes.ok) setHealth(await healthRes.json());
      if (voiceRes.ok) setVoice(await voiceRes.json());
    } catch (err) {
      console.error('Failed to fetch data:', err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 15000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const toggleVoice = async () => {
    setVoiceLoading(true);
    try {
      const res = await fetch('/api/voice', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'toggle' }),
      });
      if (res.ok) {
        const data = await res.json();
        setVoice({ active: data.active, uptime: data.uptime });
      }
    } catch (err) {
      console.error('Failed to toggle voice:', err);
    } finally {
      setVoiceLoading(false);
    }
  };

  return loading ? (
    <div className="flex items-center justify-center h-64">
      <div className="text-[var(--muted)]">Loading...</div>
    </div>
  ) : (
    <>
      {/* Voice Assistant Toggle */}
      <section className="mb-6">
        <div className="card p-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <span className="text-2xl">🎤</span>
              <div>
                <h2 className="text-base font-semibold">Voice Assistant</h2>
                <p className="text-[var(--muted)] text-xs">
                  {voice?.active
                    ? `Listening for wake word • up ${voice.uptime || '–'}`
                    : 'Paused — not listening'}
                </p>
              </div>
            </div>
            <button
              onClick={toggleVoice}
              disabled={voiceLoading}
              className={`relative w-14 h-8 rounded-full transition-all duration-300 ${
                voiceLoading ? 'opacity-50 cursor-wait' : 'cursor-pointer'
              } ${voice?.active ? 'bg-[var(--success)]' : 'bg-[var(--border)]'}`}
            >
              <div
                className={`absolute top-1 w-6 h-6 rounded-full bg-white shadow transition-transform duration-300 ${
                  voice?.active ? 'translate-x-7' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </div>
      </section>

      {/* System Health - Retro Activity Monitor */}
      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-3 flex items-center gap-2">
          <span>🖥️</span> System Activity
        </h2>
        <RetroActivityMonitor />
      </section>

      {/* System Health - Card View */}
      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-3 flex items-center gap-2">
          <span>💓</span> System Health
        </h2>
        <div className="grid grid-cols-2 gap-3">
          <StatusCard
            title="CPU"
            value={health ? `${health.cpu}%` : '--'}
            color={health && health.cpu > 80 ? 'warning' : 'default'}
          />
          <StatusCard
            title="Memory"
            value={health ? `${health.memory}%` : '--'}
            color={health && health.memory > 80 ? 'warning' : 'default'}
          />
          <StatusCard
            title="Temperature"
            value={health ? `${health.temp}°C` : '--'}
            color={health && health.temp > 70 ? 'error' : health && health.temp > 60 ? 'warning' : 'default'}
          />
          <StatusCard
            title="NPU"
            value={health?.npuStatus || '--'}
            color={health?.npuStatus === 'Online' ? 'success' : 'error'}
          />
        </div>
      </section>
    </>
  );
}
