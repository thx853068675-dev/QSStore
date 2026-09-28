import { readModuleJson, readPackInfo } from 'libhap_core.so';

export class PackageInspectError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class PackageIdentity {
  bundleName: string = '';
  versionCode: number = 0;
  moduleName: string = '';
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
    const module = manifest['module'] as Record<string, Object> | undefined;
    identity.moduleName = String(module?.['name'] ?? '');
    identity.mainAbility = String(module?.['mainElement'] ?? '');
    const packText = readPackInfo(path);
    if (packText.length > 0) {
      const pack = JSON.parse(packText) as Record<string, Object>;
      const summary = pack['summary'] as Record<string, Object> | undefined;
      const packApp = summary?.['app'] as Record<string, Object> | undefined;
      const packName = String(packApp?.['bundleName'] ?? '');
      const version = packApp?.['version'] as Record<string, Object> | undefined;
      const packCode = Number(version?.['code'] ?? 0);
      if (packName !== identity.bundleName || !Number.isSafeInteger(packCode) || packCode <= 0) {
        throw new PackageInspectError('pack.info 与 HAP 清单的应用身份不一致');
      }
      identity.versionCode = packCode;
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

export function requestedPermissions(path: string): string[] {
  try {
    const manifest = JSON.parse(readModuleJson(path)) as Record<string, Object>;
    const module = manifest['module'] as Record<string, Object> | undefined;
    const rows = module?.['requestPermissions'] as Array<Record<string, Object>> | undefined;
    return (rows ?? []).map((row: Record<string, Object>) => String(row['name'] ?? ''))
      .filter((name: string, index: number, names: string[]) =>
        /^ohos\.permission\.[A-Za-z0-9_.]+$/.test(name) && names.indexOf(name) === index);
  } catch (_) {
    throw new PackageInspectError('无法读取 HAP 声明的权限');
  }
}
