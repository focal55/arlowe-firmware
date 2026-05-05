'use client';

import { usePathname } from 'next/navigation';
import React from 'react';

export default function Header() {
  const pathname = usePathname();

  const getTitle = () => {
    switch (pathname) {
      case '/':
        return 'Arlowe Dashboard';
      case '/config':
        return 'Configuration';
      case '/cron':
        return 'Scheduled Tasks';
      case '/logs':
        return 'System Logs';
      case '/stats':
        return 'Usage Statistics';
      case '/connectivity':
        return 'Connectivity Management';
      case '/testing':
        return 'E2E Testing';
      default:
        return 'Dashboard';
    }
  };

  const getSubtitle = () => {
    switch (pathname) {
      case '/':
        return 'System overview and controls';
      case '/config':
        return 'Manage OpenClaw settings';
      case '/cron':
        return 'Automated jobs and reminders';
      case '/logs':
        return 'Review system events and messages';
      case '/stats':
        return 'Monitor model usage and costs';
      case '/connectivity':
        return 'Manage network connections';
      case '/testing':
        return 'View and run Playwright E2E tests';
      default:
        return 'Welcome back!';
    }
  };

  return (
    <div className="mb-6">
      <h1 className="text-2xl font-bold">{getTitle()}</h1>
      <p className="text-[var(--muted)] text-sm mt-1">{getSubtitle()}</p>
    </div>
  );
}
