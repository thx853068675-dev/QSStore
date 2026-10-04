/** Rewrite references to this application only, preserving foreign identities. */
export class BundleReferences {
  static text(value: string, previous: string, next: string): string {
    if (value === previous || value.startsWith(previous + '.') || value.startsWith(previous + '/')) {
      return next + value.substring(previous.length);
    }
    for (const prefix of ['@bundle:', '@app:']) {
      if (value.startsWith(prefix + previous + '/')) return prefix + next + value.substring(prefix.length + previous.length);
    }
    return value;
  }
  static object(value: Object, previous: string, next: string): void {
    if (value === null || typeof value !== 'object') return;
    const fields = value as Record<string, Object>;
    for (const key of Object.keys(fields)) {
      const child = fields[key];
      if (typeof child === 'string') fields[key] = BundleReferences.text(child, previous, next);
      else if (child !== null && typeof child === 'object') BundleReferences.object(child, previous, next);
    }
  }
}
