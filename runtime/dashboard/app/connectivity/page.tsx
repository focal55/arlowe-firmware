'use client';

import React, { useState } from 'react';
import ConnectionStatus from './components/ConnectionStatus';
import NetworkList from './components/NetworkList';
import SavedNetworksList from './components/SavedNetworksList';
import PasswordModal from './components/PasswordModal';

interface Network {
  ssid: string;
  signal: number;
  security: string;
}

export default function ConnectivityPage() {
  const [selectedNetwork, setSelectedNetwork] = useState<Network | null>(null);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSelectNetwork = (network: Network) => {
    setSelectedNetwork(network);
    setIsModalOpen(true);
  };

  const handleConnect = async (ssid: string, password: string) => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch('/api/connectivity/connect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ssid, password }),
      });
      if (!res.ok) {
        const errorData = await res.json();
        throw new Error(errorData.message || 'Connection failed');
      }
      setIsModalOpen(false);
      setSelectedNetwork(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setLoading(false);
    }
  };

  const handleCancel = () => {
    setIsModalOpen(false);
    setSelectedNetwork(null);
    setError(null);
  };

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-bold flex items-center gap-2">
          <span>📶</span> WiFi Connectivity
        </h1>
        <p className="text-[var(--muted)] text-sm mt-1">Manage and connect to wireless networks.</p>
      </header>
      
      <div className="space-y-6">
        <ConnectionStatus />
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <NetworkList onSelectNetwork={handleSelectNetwork} />
          <SavedNetworksList />
        </div>
      </div>

      {isModalOpen && (
        <PasswordModal
          network={selectedNetwork}
          onConnect={handleConnect}
          onCancel={handleCancel}
          loading={loading}
        />
      )}
      
      {error && (
        <div className="fixed bottom-4 right-4 bg-[var(--error)] text-white p-4 rounded-lg shadow-lg">
          <p className="font-bold">Connection Error</p>
          <p>{error}</p>
        </div>
      )}
    </>
  );
}
