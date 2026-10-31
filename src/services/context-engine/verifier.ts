// Deterministic summary verification: checks that names, numbers, file names, user instructions
// and open tasks from the original messages survive in the summary, and that the summary does not
// introduce numbers that never appeared. Pure functions — unit tested.
import type { VerificationReport } from '@/types';

const STOP = new Set(('a an the and or but if then else of to in on at by for with from as is are was were be been being this that these those it its ' +
  'i you he she we they me my your our their them his her us do does did done have has had not no yes ok okay so just also very can could would ' +
  'should will shall may might must about into over under than too more most some any all each every which who whom what when where why how ' +
  'please thanks thank sure here there let lets get got make made use used using want need like').split(' '));

const CAP_STOP = new Set(['I', 'The', 'This', 'That', 'These', 'Those', 'It', 'Its', 'You', 'Your', 'We', 'Our', 'They', 'He', 'She', 'Yes', 'No',
  'Okay', 'Ok', 'Sure', 'Here', 'There', 'Let', 'Lets', 'What', 'How', 'Why', 'When', 'Where', 'Which', 'Who', 'Please', 'Thanks', 'Thank',
  'Hi', 'Hello', 'Great', 'Also', 'And', 'But', 'Or', 'So', 'If', 'Then', 'Now', 'First', 'Second', 'Next', 'Finally', 'Note', 'However',
  'Summary', 'User', 'Assistant', 'Facts', 'Decisions', 'Open', 'Files', 'Memory', 'Instructions', 'Do', 'Don', 'Can', 'Could', 'Would', 'Should',
  'Will', 'Is', 'Are', 'A', 'An', 'In', 'On', 'At', 'For', 'With', 'To', 'Of', 'My', 'Me', 'Not', 'All', 'Some', 'Any', 'Each', 'Every', 'One']);

export const NUMBER_RE = /(?<![\w.])(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:\s?(?:%|gb|mb|kb|tb|ms|fps|px|k|m|x|tokens?|s|sec|min|h|hrs?|days?|usd|\$|€|£))?(?![\w])/gi;
export const FILE_RE = /[\w\-. ]*?[\w-]+\.(?:glb|gltf|obj|fbx|usdz|stl|png|jpe?g|webp|heic|gif|pdf|txt|md|json|ya?ml|csv|tsv|xlsx?|docx?|pptx?|ts|tsx|js|jsx|swift|py|java|kt|rs|go|cpp|c|h|mp4|mov|m4v|zip|gguf|mlmodelc|mlpackage|safetensors|html|css)\b/gi;
const URL_RE = /https?:\/\/[^\s)\]>"']+/gi;
const INSTRUCTION_RE = /\b(always|never|must|don't|do not|make sure|remember|from now on|prefer|use only|only use|avoid|keep|should|need to|i want|i'd like)\b/i;
const TASK_RE = /\b(todo|to-do|to do|next step|later|still need|remaining|pending|follow[- ]up|not (?:yet )?done|unfinished|we will|i will|let's|tomorrow|next time)\b/i;

export const normalizeNumber = (raw: string) => raw.toLowerCase().replace(/,/g, '').replace(/\s+/g, '').replace(/^\$/, '');
const bareNumber = (raw: string) => normalizeNumber(raw).replace(/[^\d.]/g, '');
const words = (s: string) => s.toLowerCase().match(/[a-z0-9][a-z0-9'_-]*/g) ?? [];
const keyWords = (s: string) => [...new Set(words(s).filter((w) => w.length >= 4 && !STOP.has(w)))];

function sentences(text: string): string[] {
  return text.split(/(?<=[.!?])\s+|\n+/).map((s) => s.trim()).filter((s) => s.length > 3);
}

/** A number is "significant" if it is not a list marker or a lone small integer in prose. */
function significantNumbers(text: string): string[] {
  const out: string[] = [];
  for (const line of text.split('\n')) {
    const stripped = line.replace(/^\s*(?:\d+[.)]|[-*•])\s+/, '');
    for (const m of stripped.matchAll(NUMBER_RE)) {
      const raw = m[0];
      const bare = bareNumber(raw);
      const hasUnit = /[a-z%$€£]/i.test(raw.replace(/\d|[.,]/g, ''));
      if (bare.length >= 2 || hasUnit || raw.includes('.')) out.push(normalizeNumber(raw));
    }
  }
  return out;
}

export function extractFacts(originals: { role: string; content: string }[]) {
  const all = originals.map((m) => m.content).join('\n');
  const user = originals.filter((m) => m.role === 'user').map((m) => m.content).join('\n');

  const numbers = [...new Set(significantNumbers(all))];
  const files = [...new Set([...(all.match(FILE_RE) ?? []).map((f) => f.trim().split(/\s+/).pop()!.toLowerCase()), ...(all.match(URL_RE) ?? []).map((u) => u.toLowerCase())])];

  const nameCounts = new Map<string, number>();
  const addName = (n: string, weight: number) => nameCounts.set(n, (nameCounts.get(n) ?? 0) + weight);
  for (const m of originals) {
    for (const s of sentences(m.content)) {
      const caps = s.match(/\b[A-Z][a-zA-Z0-9]+(?:\s+[A-Z][a-zA-Z0-9]+)*/g) ?? [];
      for (const c of caps) {
        const parts = c.split(/\s+/).filter((p) => !CAP_STOP.has(p));
        if (!parts.length) continue;
        const name = parts.join(' ');
        if (name.length < 3) continue;
        // Single capitalised words at the very start of a sentence are often just grammar.
        const atStart = s.startsWith(c) && parts.length === 1;
        addName(name, (m.role === 'user' ? 2 : 1) * (atStart ? 0.5 : 1));
      }
      for (const id of s.match(/\b[a-z]+[A-Z][A-Za-z0-9]+\b|\b\w+_\w+\b/g) ?? []) addName(id, 2);
    }
  }
  const names = [...nameCounts.entries()].filter(([, c]) => c >= 2).map(([n]) => n);

  const instructions = sentences(user).filter((s) => INSTRUCTION_RE.test(s));
  const tasks = originals.flatMap((m) => sentences(m.content)).filter((s) => TASK_RE.test(s));
  return { numbers, files, names, instructions, tasks };
}

function covers(summaryLower: string, summaryWords: Set<string>, sentence: string, threshold: number): boolean {
  const kw = keyWords(sentence);
  if (!kw.length) return true;
  const hit = kw.filter((w) => summaryWords.has(w) || summaryLower.includes(w)).length;
  return hit / kw.length >= threshold;
}

export function verifySummary(originals: { role: string; content: string }[], summary: string, attempts = 1): VerificationReport {
  const facts = extractFacts(originals);
  const lower = summary.toLowerCase();
  const summaryNums = new Set(significantNumbers(summary).map(bareNumber));
  const originalNums = new Set(significantNumbers(originals.map((m) => m.content).join('\n')).map(bareNumber));
  const summaryWords = new Set(words(summary));

  const missingNumbers = facts.numbers.filter((n) => !summaryNums.has(bareNumber(n)) && !lower.includes(n));
  const missingFiles = facts.files.filter((f) => !lower.includes(f));
  const missingNames = facts.names.filter((n) => !lower.includes(n.toLowerCase()));
  const missingInstructions = facts.instructions.filter((s) => !covers(lower, summaryWords, s, 0.5));
  const missingTasks = facts.tasks.filter((s) => !covers(lower, summaryWords, s, 0.4));
  const unsupportedNumbers = [...summaryNums].filter((n) => !originalNums.has(n));

  const total = facts.numbers.length + facts.files.length + facts.names.length + facts.instructions.length + facts.tasks.length;
  const missing = missingNumbers.length + missingFiles.length + missingNames.length + missingInstructions.length + missingTasks.length;
  const coverage = total === 0 ? 1 : (total - missing) / total;
  const nameTolerance = Math.floor(facts.names.length * 0.2);
  const passed = missingNumbers.length === 0 && missingFiles.length === 0 && missingInstructions.length === 0 &&
    missingTasks.length === 0 && unsupportedNumbers.length === 0 && missingNames.length <= nameTolerance;

  return { passed, attempts, missingNumbers, missingNames, missingFiles, missingInstructions, missingTasks, unsupportedNumbers, coverage };
}

/** Human-readable feedback for a retry prompt. */
export function verificationFeedback(r: VerificationReport): string[] {
  const out: string[] = [];
  if (r.missingNumbers.length) out.push(`Include these exact numbers: ${r.missingNumbers.join(', ')}`);
  if (r.missingFiles.length) out.push(`Include these file names / links exactly: ${r.missingFiles.join(', ')}`);
  if (r.missingNames.length) out.push(`Include these names exactly: ${r.missingNames.join(', ')}`);
  for (const s of r.missingInstructions) out.push(`Keep this user instruction: "${s}"`);
  for (const s of r.missingTasks) out.push(`Keep this unfinished task: "${s}"`);
  if (r.unsupportedNumbers.length) out.push(`Remove or correct numbers that are not in the conversation: ${r.unsupportedNumbers.join(', ')}`);
  return out;
}

/** Original sentences that contain the missing items, used to preserve them verbatim. */
export function sentencesForMissing(originals: { role: string; content: string }[], r: VerificationReport): string[] {
  const needles = [...r.missingNumbers, ...r.missingFiles, ...r.missingNames.map((n) => n.toLowerCase())];
  const keep = new Set<string>([...r.missingInstructions, ...r.missingTasks]);
  for (const m of originals) {
    for (const s of sentences(m.content)) {
      const l = s.toLowerCase();
      if (needles.some((n) => l.includes(n))) keep.add(`${m.role === 'user' ? 'User' : 'Assistant'}: ${s}`);
    }
  }
  return [...keep];
}

/** Remove summary sentences containing numbers that never appeared in the originals. */
export function stripUnsupportedNumbers(summary: string, unsupported: string[]): string {
  if (!unsupported.length) return summary;
  return summary.split('\n').filter((line) => !significantNumbers(line).some((n) => unsupported.includes(bareNumber(n)))).join('\n');
}
