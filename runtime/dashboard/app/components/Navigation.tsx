'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const navItems = [
  { href: '/', label: 'Overview', icon: '📊' },
  { href: '/npu', label: 'NPU Lab', icon: '🧠' },
  { href: '/logs', label: 'Logs', icon: '📋' },
  { href: '/connectivity', label: 'Connect', icon: '📶' },
];

export default function Navigation() {
  const pathname = usePathname();

  return (
    <nav className="glass fixed bottom-0 left-0 right-0 z-50 border-t border-[var(--border)] safe-area-pb md:relative md:bottom-auto md:border-t-0 md:border-r md:h-screen md:w-20">
      <div className="flex justify-around items-center h-16 md:flex-col md:h-full md:justify-start md:pt-6 md:gap-2 overflow-x-auto md:overflow-x-visible">
        {navItems.map((item) => {
          const isActive = pathname === item.href;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex flex-col items-center justify-center p-2 rounded-xl transition-smooth md:w-14 md:h-14 min-w-[3rem] ${
                isActive
                  ? 'bg-[var(--accent)] text-white'
                  : 'text-[var(--muted)] hover:text-[var(--foreground)] hover:bg-[var(--card)]'
              }`}
            >
              <span className="text-xl">{item.icon}</span>
              <span className="text-[10px] mt-0.5 font-medium">{item.label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
