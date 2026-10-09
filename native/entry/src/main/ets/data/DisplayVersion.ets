/** Presentation only: never rewrite release identities, manifests or upgrade comparisons. */
export function displayVersion(raw: string, appName: string = ''): string {
  const original = raw.trim();
  if (!original) return '';
  // Ignore separator differences only while matching the known application name.
  // This also avoids mistaking digits in names such as "工具 2.0" for the version.
  const separator = /[\s._\-–—·•:：/\\]/;
  let start = 0;
  let nameAt = 0;
  const name = appName.trim().toLowerCase();
  const lower = original.toLowerCase();
  while (nameAt < name.length && start < lower.length) {
    if (separator.test(name[nameAt])) { nameAt++; continue; }
    if (separator.test(lower[start])) { start++; continue; }
    if (name[nameAt] !== lower[start]) break;
    nameAt++; start++;
  }
  while (nameAt < name.length && separator.test(name[nameAt])) nameAt++;
  const value = name.length > 0 && nameAt === name.length ? original.substring(start).trim() : original;
  // Prefer dotted versions over standalone numbers (e.g. the "2" in OHcode2).
  // A boundary prevents extracting a numeric fragment from an identifier/hash.
  const dotted = /(?:^|[^a-zA-Z0-9.])(?:v\s*)?(\d+(?:\.\d+){1,5})(?![a-zA-Z0-9]|\.\d)/i.exec(value);
  const explicit = /(?:^|[^a-zA-Z0-9])(?:v|version\s*[:：]?|版本\s*[:：]?)\s*(\d+)(?![a-zA-Z0-9.])/i.exec(value);
  const numeric = /^[\s_\-:：]*([0-9]+)$/.exec(value);
  const match = dotted ?? explicit ?? numeric;
  if (!match) return original;
  const core = match[1];
  const tail = value.substring(match.index + match[0].length);
  // Preserve semantic prerelease/build identifiers. Filename extensions are not versions.
  const suffix = /^[-_]([a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)/.exec(tail);
  const channel = /^[\s_\-]*(alpha|beta|rc|pre|preview|dev|nightly|canary|snapshot|test)(?:[\s._\-]*(\d+(?:\.\d+)*))?/i.exec(tail);
  let result = core;
  let consumed = 0;
  if (channel && (!suffix || channel[0].length > suffix[0].length) &&
      !/^[a-zA-Z]/.test(tail.substring(channel[0].length))) {
    result += '-' + channel[1].toLowerCase() + (channel[2] ? '.' + channel[2] : '');
    consumed = channel[0].length;
  } else if (suffix && !/^(hap|app|zip|ohos|arm64|aarch64|release)$/i.test(suffix[1])) {
    result += '-' + suffix[1];
    consumed = suffix[0].length;
  }
  const build = /^\+([a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)/.exec(tail.substring(consumed));
  if (build) result += '+' + build[1];
  return result;
}

/** 展示优先级：发行标签、发行标题、包内版本；内部编号仍用于签装和设备校验。 */
export function releaseDisplayVersion(releaseName: string, releaseTag: string,
  packageVersion: string, appName: string = ''): string {
  for (const raw of [releaseTag, releaseName]) {
    const version = displayVersion(raw, appName);
    if (/^\d+(?:\.\d+){0,5}(?:-[a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)?(?:\+[a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)?$/.test(version)) {
      return version;
    }
  }
  return displayVersion(packageVersion, appName);
}
