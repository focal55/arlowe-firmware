interface StatusCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  icon?: string;
  trend?: 'up' | 'down' | 'neutral';
  color?: 'default' | 'success' | 'warning' | 'error' | 'local' | 'gemini' | 'claude';
}

const colorClasses = {
  default: 'text-[var(--foreground)]',
  success: 'text-[var(--success)]',
  warning: 'text-[var(--warning)]',
  error: 'text-[var(--error)]',
  local: 'text-[var(--local)]',
  gemini: 'text-[var(--gemini)]',
  claude: 'text-[var(--claude)]',
};

export default function StatusCard({ title, value, subtitle, icon, trend, color = 'default' }: StatusCardProps) {
  return (
    <div className="card p-4">
      <div className="flex items-start justify-between">
        <div className="flex-1">
          <p className="text-[var(--muted)] text-sm font-medium">{title}</p>
          <p className={`text-2xl font-semibold mt-1 ${colorClasses[color]}`}>
            {value}
            {trend && (
              <span className={`text-sm ml-2 ${trend === 'up' ? 'text-[var(--success)]' : trend === 'down' ? 'text-[var(--error)]' : 'text-[var(--muted)]'}`}>
                {trend === 'up' ? '↑' : trend === 'down' ? '↓' : '→'}
              </span>
            )}
          </p>
          {subtitle && <p className="text-[var(--muted)] text-xs mt-1">{subtitle}</p>}
        </div>
        {icon && <span className="text-2xl">{icon}</span>}
      </div>
    </div>
  );
}
