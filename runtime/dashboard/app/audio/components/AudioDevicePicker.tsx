'use client';

import React from 'react';
import { AudioDevice } from '../../api/audio/devices/route';

interface AudioDevicePickerProps {
  captureDevices: AudioDevice[];
  playbackDevices: AudioDevice[];
  selectedCapture: string;
  selectedPlayback: string;
  onCaptureChange: (id: string) => void;
  onPlaybackChange: (id: string) => void;
  onSave: () => void;
  saving: boolean;
}

export default function AudioDevicePicker({
  captureDevices,
  playbackDevices,
  selectedCapture,
  selectedPlayback,
  onCaptureChange,
  onPlaybackChange,
  onSave,
  saving,
}: AudioDevicePickerProps) {
  return (
    <div className="bg-gray-800 p-4 rounded-lg shadow-md space-y-4">
      <div>
        <label
          htmlFor="capture-device"
          className="block text-sm font-medium text-gray-300 mb-1"
        >
          Capture device (microphone)
        </label>
        <select
          id="capture-device"
          value={selectedCapture}
          onChange={e => onCaptureChange(e.target.value)}
          className="w-full bg-gray-700 border border-gray-600 text-white rounded-md px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
        >
          <option value="auto">Auto (recommended)</option>
          {captureDevices.map(device => (
            <option key={device.id} value={device.id}>
              {device.name}
            </option>
          ))}
        </select>
      </div>

      <div>
        <label
          htmlFor="playback-device"
          className="block text-sm font-medium text-gray-300 mb-1"
        >
          Playback device (speaker)
        </label>
        <select
          id="playback-device"
          value={selectedPlayback}
          onChange={e => onPlaybackChange(e.target.value)}
          className="w-full bg-gray-700 border border-gray-600 text-white rounded-md px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
        >
          <option value="auto">Auto (recommended)</option>
          {playbackDevices.map(device => (
            <option key={device.id} value={device.id}>
              {device.name}
            </option>
          ))}
        </select>
      </div>

      <button
        onClick={onSave}
        disabled={saving}
        className="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-md disabled:bg-gray-500 disabled:cursor-not-allowed transition-colors"
      >
        {saving ? 'Saving...' : 'Save'}
      </button>
    </div>
  );
}
