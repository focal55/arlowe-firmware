'use client';

import React, { useState, useEffect } from 'react';

interface NetworkStatus {
  ssid: string;
  ipAddress: string;
  signalStrength: string;
  security: string;
  connected: boolean;
}

const CurrentStatus: React.FC = () => {
  const [status, setStatus] = useState<NetworkStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchStatus = async () => {
      try {
        const res = await fetch('/api/connectivity/status');
        if (!res.ok) throw new Error(`Failed to fetch: ${res.status}`);
        const data: NetworkStatus = await res.json();
        setStatus(data);
        setError(null);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load status');
      } finally {
        setLoading(false);
      }
    };

    fetchStatus();
    const interval = setInterval(fetchStatus, 10000); // Refresh every 10 seconds
    return () => clearInterval(interval);
  }, []);

  // Fixed height container to prevent layout jumps
  return (
    <div className="bg-gray-800 p-6 rounded-lg shadow-md mb-6 min-h-[180px]">
      <h2 className="text-xl font-semibold text-white mb-4">Current Status</h2>
      
      {loading ? (
        <div className="space-y-2 animate-pulse">
          <div className="h-4 bg-gray-700 rounded w-3/4"></div>
          <div className="h-4 bg-gray-700 rounded w-1/2"></div>
          <div className="h-4 bg-gray-700 rounded w-2/3"></div>
          <div className="h-4 bg-gray-700 rounded w-1/2"></div>
        </div>
      ) : error ? (
        <p className="text-red-400">Error: {error}</p>
      ) : status?.connected ? (
        <div className="grid grid-cols-2 gap-2 text-sm">
          <div className="text-gray-400">Status</div>
          <div className="text-green-400 font-medium">✓ Connected</div>
          
          <div className="text-gray-400">Network</div>
          <div className="text-white font-medium">{status.ssid}</div>
          
          <div className="text-gray-400">IP Address</div>
          <div className="text-white">{status.ipAddress}</div>
          
          <div className="text-gray-400">Signal</div>
          <div className="text-white">{status.signalStrength}</div>
          
          <div className="text-gray-400">Security</div>
          <div className="text-white">{status.security}</div>
        </div>
      ) : (
        <div className="text-center py-4">
          <p className="text-gray-400">Not Connected</p>
          <p className="text-sm text-gray-500 mt-1">Select a network below to connect</p>
        </div>
      )}
    </div>
  );
};

export default CurrentStatus;
