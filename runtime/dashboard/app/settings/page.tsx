'use client';

import React, { FormEvent, useState } from 'react';

const MESSAGES: Record<number, string> = {
  401: 'Wrong password.',
  429: 'Too many attempts. Wait 30 seconds and try again.',
  500: 'The device could not start the reset.',
};

const ERASED = [
  'Saved Wi-Fi networks and their passwords',
  'The dashboard password and every signed-in session',
  'Conversations, wake-word recordings, logs and the system journal',
  'The device identity: its certificate is revoked and a new identity is created',
  'The device name, which returns to "arlowe"',
];

export default function SettingsPage() {
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const logout = async () => {
    await fetch('/api/auth/logout', { method: 'POST' }).catch(() => undefined);
    window.location.assign('/login');
  };

  const handleReset = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/device/reset', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password, confirm }),
      });
      if (res.status === 202) {
        setResetting(true);
        return;
      }
      setError(MESSAGES[res.status] ?? 'Reset failed.');
    } catch {
      setError('Could not reach the device.');
    } finally {
      setBusy(false);
    }
  };

  const card = 'bg-gray-800 border border-gray-700 p-6 rounded-lg shadow-xl w-full max-w-xl mb-6';
  const input =
    'w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500';

  return (
    <div className="py-6">
      <section className={card}>
        <h2 className="text-lg font-bold mb-2">Session</h2>
        <button onClick={logout} className="px-4 py-2 bg-gray-600 hover:bg-gray-500 rounded-md transition-colors">
          Log out
        </button>
      </section>

      <section className={`${card} border-red-800`}>
        <h2 className="text-lg font-bold mb-2 text-red-400">Factory reset</h2>
        {resetting ? (
          <p role="status" className="text-gray-300">
            Resetting. The unit will restart into setup mode; follow the instructions on its screen to pair it again.
          </p>
        ) : (
          <form onSubmit={handleReset}>
            <p className="text-gray-300 mb-2">This erases, and cannot be undone:</p>
            <ul className="list-disc list-inside text-gray-300 mb-4 text-sm">
              {ERASED.map((item) => (
                <li key={item}>{item}</li>
              ))}
            </ul>
            <label htmlFor="reset-password" className="block text-sm font-medium text-gray-400 mb-1">
              Dashboard password
            </label>
            <input
              id="reset-password"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={`${input} mb-3`}
            />
            <label htmlFor="reset-confirm" className="block text-sm font-medium text-gray-400 mb-1">
              Type RESET to confirm
            </label>
            <input
              id="reset-confirm"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              className={input}
            />
            {error && (
              <p role="alert" className="text-red-400 text-sm mt-3">
                {error}
              </p>
            )}
            <button
              type="submit"
              disabled={busy || !password || confirm !== 'RESET'}
              className="w-full mt-6 px-4 py-2 bg-red-700 hover:bg-red-800 rounded-md disabled:bg-gray-500 disabled:cursor-not-allowed transition-colors"
            >
              {busy ? 'Starting reset...' : 'Erase everything and reset'}
            </button>
          </form>
        )}
      </section>
    </div>
  );
}
