'use client';

import React, { useState, useEffect } from 'react';
import AudioDevicePicker from './components/AudioDevicePicker';
import { AudioDevice, AudioDevicesResponse } from '../api/audio/devices/route';

interface ConfigResponse {
  paired: boolean;
  config: {
    audio?: {
      capture_device?: string;
      playback_device?: string;
    };
  } | null;
}

export default function AudioPage() {
  const [captureDevices, setCaptureDevices] = useState<AudioDevice[]>([]);
  const [playbackDevices, setPlaybackDevices] = useState<AudioDevice[]>([]);
  const [selectedCapture, setSelectedCapture] = useState('auto');
  const [selectedPlayback, setSelectedPlayback] = useState('auto');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  useEffect(() => {
    const load = async () => {
      setLoading(true);
      setError(null);

      try {
        const [devicesRes, configRes] = await Promise.all([
          fetch('/api/audio/devices'),
          fetch('/api/config'),
        ]);

        if (!devicesRes.ok) {
          throw new Error(`Failed to fetch audio devices: ${devicesRes.status}`);
        }
        const devices = (await devicesRes.json()) as AudioDevicesResponse;
        setCaptureDevices(devices.capture);
        setPlaybackDevices(devices.playback);

        // Pre-select from existing config if available; default to "auto".
        if (configRes.ok) {
          const configData = (await configRes.json()) as ConfigResponse;
          if (configData.config?.audio) {
            setSelectedCapture(configData.config.audio.capture_device ?? 'auto');
            setSelectedPlayback(configData.config.audio.playback_device ?? 'auto');
          }
        }
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : 'Unknown error');
      } finally {
        setLoading(false);
      }
    };

    load();
  }, []);

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    setSuccessMessage(null);

    try {
      const res = await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          audio: {
            capture_device: selectedCapture,
            playback_device: selectedPlayback,
          },
        }),
      });

      if (!res.ok) {
        const data = await res.json();
        const detail = data?.error ?? `HTTP ${res.status}`;
        throw new Error(detail);
      }

      setSuccessMessage('Saved — restarting voice service');
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Save failed');
    } finally {
      setSaving(false);
    }
  };

  const isEmpty = !loading && captureDevices.length === 0 && playbackDevices.length === 0;

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-bold">Audio Devices</h1>
        <p className="text-[var(--muted)] text-sm mt-1">
          Select capture and playback devices. Saving will restart the voice service.
        </p>
      </header>

      {loading && (
        <p className="text-gray-400">Loading audio devices...</p>
      )}

      {!loading && error && (
        <div className="bg-red-900/50 border border-red-500 text-red-300 p-4 rounded-lg mb-4">
          <p className="font-bold">Error</p>
          <p>{error}</p>
        </div>
      )}

      {isEmpty && (
        <div className="bg-gray-800 p-6 rounded-lg text-center">
          <p className="text-gray-300 font-medium">No audio devices detected</p>
          <p className="text-gray-400 text-sm mt-2">
            Plug in a USB microphone or speaker, then reload this page.
          </p>
        </div>
      )}

      {!loading && !isEmpty && (
        <>
          <AudioDevicePicker
            captureDevices={captureDevices}
            playbackDevices={playbackDevices}
            selectedCapture={selectedCapture}
            selectedPlayback={selectedPlayback}
            onCaptureChange={setSelectedCapture}
            onPlaybackChange={setSelectedPlayback}
            onSave={handleSave}
            saving={saving}
          />

          {successMessage && (
            <div className="mt-4 bg-green-900/50 border border-green-500 text-green-300 p-4 rounded-lg">
              {successMessage}
            </div>
          )}

          {error && (
            <div className="mt-4 bg-red-900/50 border border-red-500 text-red-300 p-4 rounded-lg">
              <p className="font-bold">Save failed</p>
              <p>{error}</p>
            </div>
          )}
        </>
      )}
    </>
  );
}
