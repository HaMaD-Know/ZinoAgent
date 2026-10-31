// Minimal, safe Markdown renderer (builds React elements; never injects HTML).
import { Fragment, type ReactNode } from 'react';

function inline(text: string, keyBase: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*\s][^*]*\*)|(\[[^\]]+\]\((https?:\/\/[^)\s]+)\))/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const t = m[0];
    const k = `${keyBase}-${i++}`;
    if (t.startsWith('`')) out.push(<code key={k}>{t.slice(1, -1)}</code>);
    else if (t.startsWith('**')) out.push(<strong key={k}>{t.slice(2, -2)}</strong>);
    else if (t.startsWith('*')) out.push(<em key={k}>{t.slice(1, -1)}</em>);
    else {
      const label = t.slice(1, t.indexOf(']'));
      out.push(<a key={k} href={m[5]} target="_blank" rel="noreferrer noopener">{label}</a>);
    }
    last = m.index + t.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text }: { text: string }) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const blocks: ReactNode[] = [];
  let i = 0;
  let key = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('```')) {
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) body.push(lines[i++]);
      i++;
      blocks.push(<pre key={key++} className="selectable"><code>{body.join('\n')}</code></pre>);
      continue;
    }
    const h = line.match(/^(#{1,3})\s+(.*)$/);
    if (h) { const T = (`h${h[1].length}`) as 'h1'; blocks.push(<T key={key++}>{inline(h[2], `h${key}`)}</T>); i++; continue; }
    if (/^\s*([-*•]|\d+[.)])\s+/.test(line)) {
      const ordered = /^\s*\d+[.)]/.test(line);
      const items: string[] = [];
      while (i < lines.length && /^\s*([-*•]|\d+[.)])\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*([-*•]|\d+[.)])\s+/, ''));
      const L = ordered ? 'ol' : 'ul';
      blocks.push(<L key={key++}>{items.map((it, j) => <li key={j}>{inline(it, `l${key}-${j}`)}</li>)}</L>);
      continue;
    }
    if (line.startsWith('>')) {
      const q: string[] = [];
      while (i < lines.length && lines[i].startsWith('>')) q.push(lines[i++].replace(/^>\s?/, ''));
      blocks.push(<blockquote key={key++}>{inline(q.join(' '), `q${key}`)}</blockquote>);
      continue;
    }
    if (!line.trim()) { i++; continue; }
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() && !/^(```|#{1,3}\s|>|\s*([-*•]|\d+[.)])\s+)/.test(lines[i])) para.push(lines[i++]);
    blocks.push(<p key={key++}>{para.map((p, j) => <Fragment key={j}>{j > 0 && <br />}{inline(p, `p${key}-${j}`)}</Fragment>)}</p>);
  }
  return <div className="md">{blocks}</div>;
}
