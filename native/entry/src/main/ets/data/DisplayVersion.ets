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

function withoutReleaseBuild(version: string): string {
  return version.replace(/[-+]\d+$/, '');
}

/** 标题的构建号必须同时匹配当前包编号和同一语义版本。 */
export function verifiedReleaseBuildVersion(releaseName: string, releaseTag: string,
  packageVersion: string, appName: string, packageVersionCode: number): string {
  const title = displayVersion(releaseName, appName);
  const tag = displayVersion(releaseTag, appName);
  const bracket = /[（(]\s*(?:(?:build|versioncode|构建(?:编号)?|内部编号)\s*[:：]?\s*)?(\d+)\s*[）)]\s*$/i.exec(releaseName);
  const inline = /[-+](\d+)$/.exec(title);
  const build = bracket?.[1] ?? inline?.[1] ?? '';
  const titleBase = withoutReleaseBuild(title).toLowerCase();
  const packageBase = withoutReleaseBuild(displayVersion(packageVersion, appName)).toLowerCase();
  // 不能用标题里的发布日期或另一个附件的编号覆盖语义版本。
  if (Number.isInteger(packageVersionCode) && packageVersionCode > 0 && Number(build) === packageVersionCode &&
    /^\d+(?:\.\d+){1,5}(?:-[a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)?$/.test(title) &&
    titleBase === packageBase && (!/^\d/.test(tag) || withoutReleaseBuild(tag).toLowerCase() === titleBase)) {
    return bracket !== null ? withoutReleaseBuild(title) + '-' + String(packageVersionCode) : title;
  }
  return '';
}

/** 固定 tag 下换包时，以包内编号证实标题的新构建号；其余仍优先发行标签。 */
export function releaseDisplayVersion(releaseName: string, releaseTag: string,
  packageVersion: string, appName: string = '', packageVersionCode: number = 0): string {
  const verified = verifiedReleaseBuildVersion(releaseName, releaseTag, packageVersion, appName, packageVersionCode);
  if (verified) return verified;
  for (const raw of [releaseTag, releaseName]) {
    const version = displayVersion(raw, appName);
    if (/^\d+(?:\.\d+){0,5}(?:-[a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)?(?:\+[a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*)?$/.test(version)) {
      return version;
    }
  }
  return displayVersion(packageVersion, appName);
}
