
import React from 'react';

interface SavedNetwork {
  ssid: string;
  security: string; // e.g., WPA2, Open, WPA3
}

interface SavedNetworksProps {
  onForgetClick: (network: SavedNetwork) => void;
}

const SavedNetworks: React.FC<SavedNetworksProps> = ({ onForgetClick }) => {
  // Mock data for saved networks
  const mockSavedNetworks: SavedNetwork[] = [
    { ssid: 'My_Home_Network', security: 'WPA2' },
    { ssid: 'Work_WiFi', security: 'WPA3' },
    { ssid: 'Coffee_Shop_Free', security: 'Open' },
  ];

  return (
    <div className="bg-gray-800 p-6 rounded-lg shadow-md mb-6">
      <h2 className="text-xl font-semibold text-white mb-4">Saved Networks</h2>
      {
        mockSavedNetworks.length > 0 ? (
          <ul className="space-y-4">
            {mockSavedNetworks.map((network) => (
              <li key={network.ssid} className="flex justify-between items-center bg-gray-700 p-4 rounded-md">
                <div>
                  <p className="text-white text-lg font-medium">{network.ssid}</p>
                  <p className="text-gray-400 text-sm">Security: {network.security}</p>
                </div>
                <button
                  onClick={() => onForgetClick(network)}
                  className="bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded transition duration-200"
                >
                  Forget
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-gray-300">No saved networks found.</p>
        )
      }
    </div>
  );
};

export default SavedNetworks;
