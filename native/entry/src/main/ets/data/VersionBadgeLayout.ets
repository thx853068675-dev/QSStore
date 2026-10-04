export interface VersionBadgeLayout {
  text: string;
  width: number;
}

/** Fit the displayed string first, then size its background to those glyphs. */
export function fitVersionBadge(value: string, maxWidth: number,
  measure: (text: string) => number): VersionBadgeLayout {
  const padding = 8;
  if (value.length === 0 || !Number.isFinite(maxWidth) || maxWidth <= padding) {
    return { text: '', width: 0 };
  }
  const widthOf = (text: string): number => Math.ceil(measure(text) + padding);
  if (widthOf(value) <= maxWidth) return { text: value, width: widthOf(value) };
  const ellipsis = '…';
  if (widthOf(ellipsis) > maxWidth) return { text: '', width: 0 };
  // Iterate code points so a tag containing an emoji is never split in half.
  const chars: string[] = [];
  for (const char of value) chars.push(char);
  let low = 0;
  let high = chars.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (widthOf(chars.slice(0, middle).join('') + ellipsis) <= maxWidth) low = middle;
    else high = middle - 1;
  }
  const text = chars.slice(0, low).join('') + ellipsis;
  return { text: text, width: widthOf(text) };
}
