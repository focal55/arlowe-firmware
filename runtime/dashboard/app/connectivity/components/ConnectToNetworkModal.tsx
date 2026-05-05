
'use client';

import React, { useState } from 'react';

interface Network {
  ssid: string;
  security: string; // e.g., WPA2, Open, WPA3
  signal: number; // in percentage or dBm
}

interface ConnectToNetworkModalProps {
  isOpen: boolean;
  network: Network | null;
  onClose: () => void;
  onConnect: (ssid: string, password?: string) => void;
}

const ConnectToNetworkModal: React.FC<ConnectToNetworkModalProps> = ({
  isOpen,
  network,
  onClose,
  onConnect,
}) => {
  const [password, setPassword] = useState('');

  if (!isOpen || !network) return null;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    onConnect(network.ssid, network.security !== 'Open' ? password : undefined);
    setPassword(''); // Clear password after attempt
  };

  return (
    <div className="fixed inset-0 bg-black bg-opacity-75 flex items-center justify-center z-50">
      <div className="bg-gray-800 p-8 rounded-lg shadow-xl w-full max-w-md mx-4">
        <h2 className="text-2xl font-bold text-white mb-6">Connect to {network.ssid}</h2>
        <form onSubmit={handleSubmit}>
          {network.security !== 'Open' && (
            <div className="mb-4">
              <label htmlFor="password" className="block text-gray-300 text-sm font-medium mb-2">
                Password
              </label>
              <input
                type="password"
                id="password"
                className="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:shadow-outline bg-gray-700 border-gray-600"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
              />
            </div>
          )}
          <div className="flex justify-end space-x-4">
            <button
              type="button"
              onClick={onClose}
              className="bg-gray-600 hover:bg-gray-700 text-white font-bold py-2 px-4 rounded transition duration-200"
            >
              Cancel
            </button>
            <button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded transition duration-200"
            >
              Connect
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default ConnectToNetworkModal;
