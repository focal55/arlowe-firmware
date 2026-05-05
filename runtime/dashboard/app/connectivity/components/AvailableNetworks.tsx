
import React from 'react';

interface Network {
  ssid: string;
  security: string; // e.g., WPA2, Open, WPA3
  signal: number; // in percentage or dBm
}

interface AvailableNetworksProps {
  onConnectClick: (network: Network) => void;
}

const AvailableNetworks: React.FC<AvailableNetworksProps> = ({ onConnectClick }) => {
  // Mock data for available networks
  const mockNetworks: Network[] = [
    { ssid: 'Home_WiFi', security: 'WPA2', signal: 90 },
    { ssid: 'Guest_Network', security: 'Open', signal: 75 },
    { ssid: 'Office_Network_Secure', security: 'WPA3', signal: 60 },
    { ssid: 'Public_WiFi', security: 'Open', signal: 50 },
  ];

  return (
    <div className="bg-gray-800 p-6 rounded-lg shadow-md mb-6">
      <h2 className="text-xl font-semibold text-white mb-4">Available Networks</h2>
      {
        mockNetworks.length > 0 ? (
          <ul className="space-y-4">
            {mockNetworks.map((network) => (
              <li key={network.ssid} className="flex justify-between items-center bg-gray-700 p-4 rounded-md">
                <div>
                  <p className="text-white text-lg font-medium">{network.ssid}</p>
                  <p className="text-gray-400 text-sm">Security: {network.security}</p>
                  <p className="text-gray-400 text-sm">Signal: {network.signal}%</p>
                </div>
                <button
                  onClick={() => onConnectClick(network)}
                  className="bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded transition duration-200"
                >
                  Connect
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-gray-300">No available networks found.</p>
        )
      }
    </div>
  );
};

export default AvailableNetworks;
