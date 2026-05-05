interface ProviderBadgeProps {
  provider: string;
  size?: 'sm' | 'md';
}

const providerInfo: Record<string, { label: string; icon: string; className: string }> = {
  // Exact matches
  local: { label: 'Local', icon: '🏠', className: 'badge-local' },
  gemini: { label: 'Gemini', icon: '💎', className: 'badge-gemini' },
  claude: { label: 'Claude', icon: '🅰️', className: 'badge-claude' },
  // API provider names
  'qwen-local': { label: 'Qwen', icon: '🏠', className: 'badge-local' },
  'google-gemini': { label: 'Gemini', icon: '💎', className: 'badge-gemini' },
  anthropic: { label: 'Claude', icon: '🅰️', className: 'badge-claude' },
  // Fallbacks for partial matches
  qwen: { label: 'Qwen', icon: '🏠', className: 'badge-local' },
};

const fallback = { label: 'Unknown', icon: '❓', className: 'badge-local' };

function getProviderInfo(provider: string) {
  // Direct match
  if (providerInfo[provider]) return providerInfo[provider];
  // Partial match
  const lc = provider.toLowerCase();
  if (lc.includes('qwen') || lc.includes('local')) return providerInfo.local;
  if (lc.includes('gemini') || lc.includes('google')) return providerInfo.gemini;
  if (lc.includes('anthropic') || lc.includes('claude')) return providerInfo.anthropic;
  return fallback;
}

export default function ProviderBadge({ provider, size = 'sm' }: ProviderBadgeProps) {
  const info = getProviderInfo(provider);
  const sizeClasses = size === 'sm' ? 'text-xs px-2 py-1' : 'text-sm px-3 py-1.5';

  return (
    <span className={`inline-flex items-center gap-1 rounded-full font-medium flex-shrink-0 ${info.className} ${sizeClasses}`}>
      <span>{info.icon}</span>
      <span>{info.label}</span>
    </span>
  );
}
