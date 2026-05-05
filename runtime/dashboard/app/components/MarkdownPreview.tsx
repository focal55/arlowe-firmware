'use client';

import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

interface MarkdownPreviewProps {
  content: string;
}

export default function MarkdownPreview({ content }: MarkdownPreviewProps) {
  return (
    <div className="prose prose-invert prose-sm max-w-none p-4 overflow-auto h-full
      prose-headings:text-[var(--foreground)] prose-headings:font-semibold prose-headings:border-b prose-headings:border-[var(--border)] prose-headings:pb-2
      prose-h1:text-2xl prose-h2:text-xl prose-h3:text-lg
      prose-p:text-[var(--foreground)] prose-p:leading-relaxed
      prose-a:text-[var(--accent)] prose-a:no-underline hover:prose-a:underline
      prose-strong:text-[var(--foreground)] prose-strong:font-semibold
      prose-em:text-[var(--foreground)]
      prose-code:text-[var(--accent)] prose-code:bg-[var(--card)] prose-code:px-1.5 prose-code:py-0.5 prose-code:rounded prose-code:text-sm prose-code:before:content-none prose-code:after:content-none
      prose-pre:bg-[var(--card)] prose-pre:border prose-pre:border-[var(--border)] prose-pre:rounded-lg
      prose-ul:text-[var(--foreground)] prose-ol:text-[var(--foreground)]
      prose-li:text-[var(--foreground)] prose-li:marker:text-[var(--muted)]
      prose-blockquote:border-l-[var(--accent)] prose-blockquote:text-[var(--muted)] prose-blockquote:bg-[var(--card)] prose-blockquote:py-1 prose-blockquote:px-4 prose-blockquote:rounded-r-lg
      prose-hr:border-[var(--border)]
      prose-table:border-collapse
      prose-th:border prose-th:border-[var(--border)] prose-th:bg-[var(--card)] prose-th:px-3 prose-th:py-2 prose-th:text-left
      prose-td:border prose-td:border-[var(--border)] prose-td:px-3 prose-td:py-2
    ">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>
        {content}
      </ReactMarkdown>
    </div>
  );
}
