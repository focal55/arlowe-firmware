'use client';

import React, { useState, useEffect } from 'react';

interface SavedNetwork {
  ssid: string;
  security: string;
}

export default function SavedNetworksList() {
  const [networks, setNetworks] = useState<SavedNetwork[]>([]);
  const [connectedSsid, setConnectedSsid] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchSavedNetworks = async () => {
    try {
      setLoading(true);
      setError(null);
      
      // Fetch both saved networks and current status in parallel
      const [savedRes, statusRes] = await Promise.all([
        fetch('/api/connectivity/saved'),
        fetch('/api/connectivity/status'),
      ]);
      
      let currentSsid: string | null = null;
      
      if (statusRes.ok) {
        const status = await statusRes.json();
        if (status.connected && status.ssid) {
          currentSsid = status.ssid;
          setConnectedSsid(status.ssid);
        } else {
          setConnectedSsid(null);
        }
      }
      
      if (savedRes.ok) {
        const data = await savedRes.json();
        // Sort connected network to top
        const sorted = data.sort((a: SavedNetwork, b: SavedNetwork) => {
          if (a.ssid === currentSsid) return -1;
          if (b.ssid === currentSsid) return 1;
          return a.ssid.localeCompare(b.ssid);
        });
        setNetworks(sorted);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setLoading(false);
    }
  };

  const [connecting, setConnecting] = useState<string | null>(null);

  const handleConnect = async (ssid: string) => {
    try {
      setConnecting(ssid);
      setError(null);
      const res = await fetch('/api/connectivity/connect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ssid }), // No password needed for saved networks
      });
      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.error || `Error ${res.status}`);
      }
      // Refresh to show new connection status
      await fetchSavedNetworks();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to connect');
    } finally {
      setConnecting(null);
    }
  };

  const handleForget = async (ssid: string) => {
    try {
      const res = await fetch('/api/connectivity/saved', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ssid }),
      });
      if (!res.ok) {
        throw new Error(`Error ${res.status}: ${await res.text()}`);
      }
      // Remove from local state
      setNetworks(prev => prev.filter(n => n.ssid !== ssid));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to forget network');
    }
  };

  useEffect(() => {
    fetchSavedNetworks();
  }, []);

  return (
    <div className="bg-gray-800 p-4 rounded-lg shadow-md">
      <div className="flex justify-between items-center mb-4">
        <h2 className="text-xl font-semibold">Saved Networks</h2>
        <button
          onClick={fetchSavedNetworks}
          disabled={loading}
          className="px-4 py-2 bg-gray-600 hover:bg-gray-500 rounded-md disabled:bg-gray-700 disabled:cursor-not-allowed transition-colors text-sm"
        >
          {loading ? 'Refreshing...' : 'Refresh'}
        </button>
      </div>

      {error && <p className="text-red-400 mb-4">Error: {error}</p>}

      <ul className="space-y-2 max-h-64 overflow-y-auto pr-2">
        {!loading && networks.length === 0 && (
          <p className="text-gray-400 text-center pt-4">No saved networks found.</p>
        )}
        {networks.map((net, index) => {
          const isConnected = net.ssid === connectedSsid;
          return (
            <li
              key={index}
              className={`flex items-center justify-between p-3 rounded-md ${
                isConnected 
                  ? 'bg-green-900/50 border border-green-500' 
                  : 'bg-gray-700'
              }`}
            >
              <div className="flex items-center space-x-2">
                {isConnected && <span className="text-green-400">✓</span>}
                <span className={`font-medium ${isConnected ? 'text-green-300' : ''}`}>{net.ssid}</span>
                {isConnected && (
                  <span className="text-xs text-green-400 bg-green-900/50 px-2 py-0.5 rounded">Connected</span>
                )}
                <span className="text-xs text-gray-400">({net.security})</span>
              </div>
              <div className="flex space-x-2">
                {!isConnected && (
                  <button
                    onClick={() => handleConnect(net.ssid)}
                    disabled={connecting === net.ssid}
                    className="px-3 py-1 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-800 rounded-md text-sm transition-colors"
                  >
                    {connecting === net.ssid ? 'Connecting...' : 'Connect'}
                  </button>
                )}
                <button
                  onClick={() => handleForget(net.ssid)}
                  disabled={isConnected}
                  className="px-3 py-1 bg-red-600 hover:bg-red-700 disabled:bg-gray-600 disabled:cursor-not-allowed rounded-md text-sm transition-colors"
                  title={isConnected ? "Disconnect first" : "Forget this network"}
                >
                  Forget
                </button>
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
