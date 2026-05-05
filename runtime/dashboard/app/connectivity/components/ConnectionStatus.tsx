'use client';

import React, { useState, useEffect } from 'react';

// A simple icon component for demonstration
const WifiIcon = ({ connected }: { connected: boolean }) => (
  <svg className={`w-6 h-6 ${connected ? 'text-green-400' : 'text-red-400'}`} fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M8.111 16.556A5.5 5.5 0 0115.889 16.556M11.111 13.111A2.5 2.5 0 0112.889 13.111M15 10a1 1 0 11-2 0 1 1 0 012 0zM5 19a1 1 0 11-2 0 1 1 0 012 0zM19 19a1 1 0 11-2 0 1 1 0 012 0z"></path>
    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M4.121 12.121A10.002 10.002 0 0119.879 12.121"></path>
  </svg>
);


interface ConnectionStatusData {
  connected: boolean;
  ssid?: string;
  ip_address?: string;
}

export default function ConnectionStatus() {
  const [status, setStatus] = useState<ConnectionStatusData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchStatus = async () => {
      try {
        setLoading(true);
        const res = await fetch('/api/connectivity/status');
        if (!res.ok) {
          throw new Error('Failed to fetch status');
        }
        const data = await res.json();
        setStatus(data);
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : 'Unknown error';
        setError(message);
        setStatus({ connected: false, ssid: 'Unknown' }); // Set a default error state
      } finally {
        setLoading(false);
      }
    };

    fetchStatus();
    // Optional: Poll for status changes every 10 seconds
    const interval = setInterval(fetchStatus, 10000);
    return () => clearInterval(interval);
  }, []);

  const renderStatus = () => {
    if (loading) {
      return <p className="text-gray-400">Loading connection details...</p>;
    }
    if (error) {
      return <p className="text-red-400">Error: {error}</p>;
    }
    if (status && status.connected) {
      return (
        <div className="flex items-center space-x-4">
          <WifiIcon connected={true} />
          <div>
            <p className="font-semibold text-green-400">Connected</p>
            <p className="text-sm text-gray-300">SSID: {status.ssid}</p>
            <p className="text-sm text-gray-400">IP Address: {status.ip_address || 'N/A'}</p>
          </div>
        </div>
      );
    }
    return (
      <div className="flex items-center space-x-4">
        <WifiIcon connected={false} />
        <div>
          <p className="font-semibold text-red-400">Disconnected</p>
          <p className="text-sm text-gray-400">Not connected to any network.</p>
        </div>
      </div>
    );
  };

  return (
    <div className="bg-gray-800 p-4 rounded-lg shadow-md">
      <h2 className="text-xl font-semibold mb-4">Current Status</h2>
      {renderStatus()}
    </div>
  );
}
