/** Compact counts keep both repository metrics together on narrow cards. */
export function repositoryCount(value: number): string {
  if (!Number.isFinite(value) || value < 0) return '—';
  const count = Math.floor(value);
  if (count < 1000) return String(count);
  return (Math.floor(count / 100) / 10).toFixed(1).replace(/\.0$/, '') + 'K';
}
