import { readModuleJson, readPackInfo, readHapIcon, readInstallPermissions } from 'libhap_core.so';

export class PackageInspectError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class PackageIdentity {
  bundleName: string = '';
  versionCode: number = 0;
  /** 清单里的 `app.versionName`，如 0.4.13；缺省时为空。 */
  versionName: string = '';
  moduleName: string = '';
  moduleType: string = '';
  mainAbility: string = '';
}

// The HAP is authoritative; catalog fields are never package identity.
// On some real HAPs pack.info and module.json disagree about versionCode.
// Package Manager uses pack.info, so prefer it while rejecting mismatched names.
export function inspectPackage(path: string): PackageIdentity {
  try {
    const manifest = JSON.parse(readModuleJson(path)) as Record<string, Object>;
    const app = manifest['app'] as Record<string, Object> | undefined;
    const identity = new PackageIdentity();
    identity.bundleName = String(app?.['bundleName'] ?? '');
    identity.versionCode = Number(app?.['versionCode'] ?? 0);
    // 版本名要一起取出来。界面上显示 versionCode 会得到 2026092910 这种
    // 看着像日期的数字；本地安装没有目录可比对，只能从包里读。
    identity.versionName = String(app?.['versionName'] ?? '');
    const module = manifest['module'] as Record<string, Object> | undefined;
    identity.moduleName = String(module?.['name'] ?? '');
    identity.moduleType = String(module?.['type'] ?? '');
    identity.mainAbility = String(module?.['mainElement'] ?? '');
    const packText = readPackInfo(path);
    if (packText.length > 0) {
      const pack = JSON.parse(packText) as Record<string, Object>;
      const summary = pack['summary'] as Record<string, Object> | undefined;
      const packApp = summary?.['app'] as Record<string, Object> | undefined;
      const packName = String(packApp?.['bundleName'] ?? '');
      const version = packApp?.['version'] as Record<string, Object> | undefined;
      const packCode = Number(version?.['code'] ?? 0);
      const packNameText = String(version?.['name'] ?? '');
      if (packName !== identity.bundleName || !Number.isSafeInteger(packCode) || packCode <= 0) {
        throw new PackageInspectError('pack.info 与 HAP 清单的应用身份不一致');
      }
      identity.versionCode = packCode;
      // 两边都有版本名时以 pack.info 为准（Package Manager 用它）；只有一边有就用那边。
      if (packNameText.length > 0) identity.versionName = packNameText;
    }
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(identity.bundleName) ||
      !Number.isSafeInteger(identity.versionCode) || identity.versionCode <= 0) {
      throw new PackageInspectError('HAP 包名或版本号无效');
    }
    return identity;
  } catch (error) {
    if (error instanceof PackageInspectError) throw error;
    throw new PackageInspectError('无法解析 HAP 清单：' + String(error));
  }
}

/** 放宽目录 SHA-256 后，仍拒绝与用户所选应用或版本不符的附件。 */
export function checkCatalogIdentity(bundleName: string, versionCode: number,
  actual: PackageIdentity): void {
  if (bundleName.length > 0 && actual.bundleName !== bundleName) {
    throw new PackageInspectError('下载的 HAP 包名与所选应用不一致');
  }
  if (versionCode > 0 && actual.versionCode !== versionCode) {
    throw new PackageInspectError('下载的 HAP 版本与所选版本不一致');
  }
}

export function requestedPermissions(path: string): string[] {
  try {
    const rows = JSON.parse(readInstallPermissions(path)) as string[];
    return rows
      .filter((name: string, index: number, names: string[]) =>
        /^ohos\.permission\.[A-Za-z0-9_.]+$/.test(name) && names.indexOf(name) === index);
  } catch (_) {
    throw new PackageInspectError('无法读取 HAP 及内包声明的权限');
  }
}

/**
 * 应用图标在 HAP 清单里的引用。
 *
 * 既可能是 `$media:app_icon` 字符串，也可能是 `{ "name": "app_icon" }`；
 * 取不到就返回空串，交给调用方按「没有图标」处理。
 */
export function iconReference(path: string): string {
  try {
    const manifest = JSON.parse(readModuleJson(path)) as Record<string, Object>;
    const app = manifest['app'] as Record<string, Object> | undefined;
    const raw = app?.['icon'];
    if (typeof raw === 'string') return raw;
    if (raw !== null && raw !== undefined) {
      const row = raw as Record<string, Object>;
      return String(row['name'] ?? '');
    }
    return '';
  } catch (_) {
    return '';
  }
}

/**
 * 从本机 HAP 里取出应用图标字节。读不到返回 undefined —— 缺图标是正常情况，
 * 不该让整个安装流程失败。
 */
export function readIconBytes(path: string, reference: string): ArrayBuffer | undefined {
  if (reference.length === 0) return undefined;
  try {
    const bytes = readHapIcon(path, reference);
    if (bytes === undefined || bytes === null || bytes.byteLength === 0) return undefined;
    // NAPI 返回的是 Uint8Array 视图，ImageSource 要的是底层 ArrayBuffer
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  } catch (_) {
    return undefined;
  }
}
