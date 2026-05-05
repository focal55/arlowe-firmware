'use client';

import React, { useState, FormEvent } from 'react';

interface Network {
  ssid: string;
  signal: number;
  security: string;
}

interface PasswordModalProps {
  network: Network | null;
  onConnect: (ssid: string, password: string) => void;
  onCancel: () => void;
  loading: boolean;
}

export default function PasswordModal({ network, onConnect, onCancel, loading }: PasswordModalProps) {
  const [password, setPassword] = useState('');

  if (!network) return null;

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    onConnect(network.ssid, password);
  };

  return (
    <div className="fixed inset-0 bg-black bg-opacity-60 backdrop-blur-sm flex items-center justify-center z-50">
      <div className="bg-gray-800 border border-gray-700 p-6 rounded-lg shadow-xl w-full max-w-md">
        <h2 className="text-xl font-bold mb-2">Connect to Network</h2>
        <p className="text-gray-300 mb-6">
          Enter the password for <span className="font-semibold text-blue-400">{network.ssid}</span>.
        </p>
        
        <form onSubmit={handleSubmit}>
          <div className="mb-4">
            <label htmlFor="password" className="block text-sm font-medium text-gray-400 mb-1">
              Password
            </label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
              autoFocus
            />
          </div>

          <div className="flex justify-end space-x-4 mt-8">
            <button
              type="button"
              onClick={onCancel}
              className="px-4 py-2 bg-gray-600 hover:bg-gray-700 rounded-md transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={loading || !password}
              className="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-md disabled:bg-gray-500 disabled:cursor-not-allowed transition-colors"
            >
              {loading ? 'Connecting...' : 'Connect'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
