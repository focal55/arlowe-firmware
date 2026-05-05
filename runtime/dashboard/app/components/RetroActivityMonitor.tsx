'use client';

import { useEffect, useState, useCallback, useRef } from 'react';

interface HealthData {
  cpu: number;
  memory: number;
  temp: number;
  disk: number;
  npuStatus: string;
}

interface HistoryPoint {
  cpu: number;
  memory: number;
  timestamp: number;
}

const HISTORY_LENGTH = 30; // 30 data points for the graph
const POLL_INTERVAL = 2000; // Poll every 2 seconds

// Pixel art characters for the bar graph
const BLOCK_FULL = '█';
const BLOCK_MEDIUM = '▓';
const BLOCK_LIGHT = '░';

export default function RetroActivityMonitor() {
  const [health, setHealth] = useState<HealthData | null>(null);
  const [history, setHistory] = useState<HistoryPoint[]>([]);
  const [blinkOn, setBlinkOn] = useState(true);
  const [scanlineOffset, setScanlineOffset] = useState(0);
  const terminalRef = useRef<HTMLDivElement>(null);

  const fetchHealth = useCallback(async () => {
    try {
      const res = await fetch('/api/health');
      if (res.ok) {
        const data = await res.json();
        setHealth(data);
        setHistory(prev => {
          const newHistory = [...prev, {
            cpu: data.cpu,
            memory: data.memory,
            timestamp: Date.now(),
          }];
          // Keep only the last HISTORY_LENGTH points
          return newHistory.slice(-HISTORY_LENGTH);
        });
      }
    } catch (err) {
      console.error('Failed to fetch health:', err);
    }
  }, []);

  useEffect(() => {
    fetchHealth();
    const interval = setInterval(fetchHealth, POLL_INTERVAL);
    return () => clearInterval(interval);
  }, [fetchHealth]);

  // Cursor blink effect
  useEffect(() => {
    const blinkInterval = setInterval(() => {
      setBlinkOn(prev => !prev);
    }, 530);
    return () => clearInterval(blinkInterval);
  }, []);

  // Subtle scanline animation
  useEffect(() => {
    const scanlineInterval = setInterval(() => {
      setScanlineOffset(prev => (prev + 1) % 4);
    }, 100);
    return () => clearInterval(scanlineInterval);
  }, []);

  // Generate ASCII bar for a percentage value
  const generateBar = (value: number, maxWidth: number = 20): string => {
    const filled = Math.round((value / 100) * maxWidth);
    const empty = maxWidth - filled;
    return BLOCK_FULL.repeat(filled) + BLOCK_LIGHT.repeat(empty);
  };

  // Generate mini sparkline from history
  const generateSparkline = (metric: 'cpu' | 'memory'): string => {
    if (history.length === 0) return '▁'.repeat(HISTORY_LENGTH);
    
    const chars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    const values = history.map(h => h[metric]);
    
    // Pad with empty values if not enough history
    while (values.length < HISTORY_LENGTH) {
      values.unshift(0);
    }
    
    return values.map(v => {
      const index = Math.min(Math.floor((v / 100) * chars.length), chars.length - 1);
      return chars[index];
    }).join('');
  };

  // Get status indicator
  const getStatusColor = (value: number, type: 'cpu' | 'mem' | 'temp'): string => {
    if (type === 'temp') {
      if (value > 70) return 'text-retro-red';
      if (value > 60) return 'text-retro-amber';
      return 'text-retro-green';
    }
    if (value > 80) return 'text-retro-red';
    if (value > 60) return 'text-retro-amber';
    return 'text-retro-green';
  };

  const currentTime = new Date().toLocaleTimeString('en-US', { 
    hour12: false, 
    hour: '2-digit', 
    minute: '2-digit', 
    second: '2-digit' 
  });

  return (
    <div className="retro-monitor">
      {/* CRT Frame */}
      <div className="retro-crt-frame">
        {/* Scanlines overlay */}
        <div 
          className="retro-scanlines" 
          style={{ backgroundPositionY: `${scanlineOffset}px` }}
        />
        
        {/* Screen glow */}
        <div className="retro-glow" />
        
        {/* Terminal content */}
        <div ref={terminalRef} className="retro-terminal">
          {/* Header */}
          <div className="retro-header">
            <span className="text-retro-amber">╔══════════════════════════════════════╗</span>
            <span className="text-retro-amber">║</span>
            <span className="text-retro-green"> ARLOWE-1 SYSTEM MONITOR </span>
            <span className="text-retro-amber">║</span>
            <span className="text-retro-amber">║</span>
            <span className="text-retro-green"> {currentTime} </span>
            <span className="text-retro-amber">║</span>
            <span className="text-retro-amber">╠══════════════════════════════════════╣</span>
          </div>

          {/* CPU Section */}
          <div className="retro-section">
            <div className="retro-row">
              <span className="text-retro-amber">CPU: </span>
              <span className={getStatusColor(health?.cpu || 0, 'cpu')}>
                [{generateBar(health?.cpu || 0, 16)}]
              </span>
              <span className="text-retro-green ml-1">
                {health?.cpu?.toFixed(1).padStart(5)}%
              </span>
            </div>
            <div className="retro-row text-retro-green-dim">
              <span className="text-retro-amber">     </span>
              {generateSparkline('cpu')}
            </div>
          </div>

          {/* Memory Section */}
          <div className="retro-section">
            <div className="retro-row">
              <span className="text-retro-amber">MEM: </span>
              <span className={getStatusColor(health?.memory || 0, 'mem')}>
                [{generateBar(health?.memory || 0, 16)}]
              </span>
              <span className="text-retro-green ml-1">
                {(health?.memory || 0).toString().padStart(5)}%
              </span>
            </div>
            <div className="retro-row text-retro-green-dim">
              <span className="text-retro-amber">     </span>
              {generateSparkline('memory')}
            </div>
          </div>

          {/* Disk Section */}
          <div className="retro-section">
            <div className="retro-row">
              <span className="text-retro-amber">DSK: </span>
              <span className={getStatusColor(health?.disk || 0, 'mem')}>
                [{generateBar(health?.disk || 0, 16)}]
              </span>
              <span className="text-retro-green ml-1">
                {(health?.disk || 0).toString().padStart(5)}%
              </span>
            </div>
          </div>

          {/* Temperature */}
          <div className="retro-section">
            <div className="retro-row">
              <span className="text-retro-amber">TMP: </span>
              <span className={getStatusColor(health?.temp || 0, 'temp')}>
                {health?.temp || 0}°C
              </span>
              <span className="text-retro-green-dim ml-2">
                {health?.temp && health.temp > 60 ? '⚠ WARM' : health?.temp && health.temp > 70 ? '🔥 HOT!' : '✓ OK'}
              </span>
            </div>
          </div>

          {/* NPU Status */}
          <div className="retro-section">
            <div className="retro-row">
              <span className="text-retro-amber">NPU: </span>
              <span className={health?.npuStatus === 'Online' ? 'text-retro-green' : 'text-retro-red'}>
                {health?.npuStatus === 'Online' ? '● ONLINE ' : '○ OFFLINE'}
              </span>
              <span className="text-retro-green-dim ml-2">
                {health?.npuStatus === 'Online' ? 'AX8850 READY' : 'DISCONNECTED'}
              </span>
            </div>
          </div>

          {/* Footer */}
          <div className="retro-footer">
            <span className="text-retro-amber">╚══════════════════════════════════════╝</span>
            <div className="retro-row mt-1">
              <span className="text-retro-green-dim">
                &gt; POLLING: {POLL_INTERVAL/1000}s
              </span>
              <span className={`retro-cursor ${blinkOn ? 'opacity-100' : 'opacity-0'}`}>█</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
