'use client';

import React, { useState, useEffect } from 'react';

interface Network {
  ssid: string;
  signal: number;
  security: string;
  inUse?: boolean;
}

interface SignalIconProps {
  strength: number;
}

interface NetworkListProps {
  onSelectNetwork: (network: Network) => void;
}

// Another simple icon for signal strength
const SignalIcon = ({ strength }: SignalIconProps) => {
  const bars = Math.ceil(strength / 25); // 4 bars total
  return (
    <div className="flex items-end space-x-0.5 h-5">
      <div className={`w-1 ${bars >= 1 ? 'bg-white' : 'bg-gray-600'}`} style={{ height: '25%' }}></div>
      <div className={`w-1 ${bars >= 2 ? 'bg-white' : 'bg-gray-600'}`} style={{ height: '50%' }}></div>
      <div className={`w-1 ${bars >= 3 ? 'bg-white' : 'bg-gray-600'}`} style={{ height: '75%' }}></div>
      <div className={`w-1 ${bars >= 4 ? 'bg-white' : 'bg-gray-600'}`} style={{ height: '100%' }}></div>
    </div>
  );
};

export default function NetworkList({ onSelectNetwork }: NetworkListProps) {
  const [networks, setNetworks] = useState<Network[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchNetworks = async () => {
    try {
      setLoading(true);
      setError(null);
      setNetworks([]); // Clear previous results
      const res = await fetch('/api/connectivity/networks');
      if (!res.ok) {
        throw new Error(`Error ${res.status}: ${await res.text()}`);
      }
      const data = await res.json();
      setNetworks(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setLoading(false);
    }
  };
  
  // Fetch networks on component mount
  useEffect(() => {
    fetchNetworks();
  }, []);

  return (
    <div className="bg-gray-800 p-4 rounded-lg shadow-md">
      <div className="flex justify-between items-center mb-4">
        <h2 className="text-xl font-semibold">Available Networks</h2>
        <button
          onClick={fetchNetworks}
          disabled={loading}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-md disabled:bg-gray-500 disabled:cursor-not-allowed transition-colors"
        >
          {loading ? 'Scanning...' : 'Rescan'}
        </button>
      </div>

      {error && <p className="text-red-400 mb-4">Error: {error}</p>}
      
      <ul className="space-y-2 h-64 overflow-y-auto pr-2">
        {!loading && networks.length === 0 && (
           <p className="text-gray-400 text-center pt-8">No networks found. Try rescanning.</p>
        )}
        {networks.map((net, index) => (
          <li
            key={index}
            onClick={() => onSelectNetwork(net)}
            className={`flex items-center justify-between p-3 rounded-md cursor-pointer transition-colors ${
              net.inUse 
                ? 'bg-green-900/50 border border-green-500 hover:bg-green-800/50' 
                : 'bg-gray-700 hover:bg-gray-600'
            }`}
          >
            <div className="flex items-center space-x-2">
              {net.inUse && <span className="text-green-400 text-sm">✓</span>}
              <span className={`font-medium ${net.inUse ? 'text-green-300' : ''}`}>{net.ssid}</span>
              {net.inUse && <span className="text-xs text-green-400 bg-green-900/50 px-2 py-0.5 rounded">Connected</span>}
            </div>
            <div className="flex items-center space-x-2">
              <span className="text-xs text-gray-400">{net.security}</span>
              <SignalIcon strength={net.signal} />
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
