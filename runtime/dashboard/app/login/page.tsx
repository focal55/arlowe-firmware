'use client';

import React, { FormEvent, useState } from 'react';

// Only same-site paths: "//host" and absolute URLs would make ?next= an open redirect.
function safeNext(search: string): string {
  const next = new URLSearchParams(search).get('next');
  return next && next.startsWith('/') && !next.startsWith('//') && !next.startsWith('/\\') ? next : '/';
}

const MESSAGES: Record<number, string> = {
  401: 'Wrong password.',
  429: 'Too many attempts. Wait 30 seconds and try again.',
};

export default function LoginPage() {
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password }),
      });
      if (res.ok) {
        window.location.assign(safeNext(window.location.search));
        return;
      }
      setError(MESSAGES[res.status] ?? 'Login failed.');
    } catch {
      setError('Could not reach the device.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex items-center justify-center py-12">
      <div className="bg-gray-800 border border-gray-700 p-6 rounded-lg shadow-xl w-full max-w-md">
        <h1 className="text-xl font-bold mb-2">Log in</h1>
        <p className="text-gray-300 mb-6">Enter the dashboard password you set during pairing.</p>
        <form onSubmit={handleSubmit}>
          <label htmlFor="password" className="block text-sm font-medium text-gray-400 mb-1">
            Password
          </label>
          <input
            id="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
            autoFocus
          />
          {error && (
            <p role="alert" className="text-red-400 text-sm mt-3">
              {error}
            </p>
          )}
          <button
            type="submit"
            disabled={loading || !password}
            className="w-full mt-6 px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-md disabled:bg-gray-500 disabled:cursor-not-allowed transition-colors"
          >
            {loading ? 'Logging in...' : 'Log in'}
          </button>
        </form>
      </div>
    </div>
  );
}
