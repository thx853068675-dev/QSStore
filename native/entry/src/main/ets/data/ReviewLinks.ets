import { url } from '@kit.ArkTS';

export interface ReviewTextRun {
  offset: number;
  text: string;
  uri: string;
}

function trimLinkEnd(candidate: string): string {
  const openers = '([{';
  const closers = ')]}';
  const balances: number[] = [0, 0, 0];
  for (const character of candidate) {
    const open = openers.indexOf(character);
    const close = closers.indexOf(character);
    if (open >= 0) balances[open]++;
    if (close >= 0) balances[close]--;
  }
  let end = candidate.length;
  while (end > 0) {
    const last = candidate.charAt(end - 1);
    const close = closers.indexOf(last);
    if ('.,!?;:'.includes(last)) {
      end--;
    } else if (close >= 0 && balances[close] < 0) {
      balances[close]++;
      end--;
    } else {
      break;
    }
  }
  return candidate.substring(0, end);
}

function browserUri(value: string): string {
  const candidate = /^www\./i.test(value) ? 'https://' + value : value;
  const authority = /^https?:\/\/([^/?#]+)/i.exec(candidate)?.[1] ?? '';
  if (!authority || /[@%\\]/.test(authority)) return '';
  try {
    const parsed = new url.URL(candidate);
    if ((parsed.protocol === 'https:' || parsed.protocol === 'http:') &&
      parsed.hostname && !parsed.username && !parsed.password) {
      return parsed.href;
    }
  } catch (_) { /* An invalid candidate remains selectable plain text. */ }
  return '';
}

export function reviewTextRuns(body: string): ReviewTextRun[] {
  const parts: ReviewTextRun[] = [];
  const pattern = /(?:https?:\/\/|www\.)[^\s\u0000-\u001F\u007F\u200B-\u200F\u202A-\u202E\u2060-\u206F<>"'\\，。！？；：、（）【】《》〈〉「」『』“”‘’…]+/gi;
  let start = 0;
  let match = pattern.exec(body);
  while (match !== null) {
    const offset = match.index;
    const text = trimLinkEnd(match[0]);
    // Avoid turning parts of a different URI, email address or identifier into links.
    const previous = body.charAt(offset - 1);
    const embedded = /[a-z0-9_@./%+-]/i.test(previous) ||
      (previous === ':' && /(?:javascript|data|file|mailto|intent):$/i.test(body.substring(0, offset)));
    const uri = embedded ? '' : browserUri(text);
    if (uri) {
      if (offset > start) parts.push({ offset: start, text: body.substring(start, offset), uri: '' });
      parts.push({ offset: offset, text: text, uri: uri });
      start = offset + text.length;
    }
    match = pattern.exec(body);
  }
  if (start < body.length) parts.push({ offset: start, text: body.substring(start), uri: '' });
  return parts;
}
