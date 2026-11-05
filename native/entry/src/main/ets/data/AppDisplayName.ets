import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { CatalogApp } from './CatalogApp';

/** Titles use the verified installed label when available; rendering performs no device queries. */
export class AppDisplayName {
  static forBundle(bundleName: string, fallback: string): string {
    return InstalledAppRegistry.displayName(bundleName).trim() || fallback.trim();
  }

  /** 应用市场正式包可能与第三方仓库撞包名，不能借它的名称给目录应用。 */
  static forCatalogBundle(bundleName: string, fallback: string): string {
    return InstalledAppRegistry.isAppGallery(bundleName) ? fallback.trim() :
      AppDisplayName.forBundle(bundleName, fallback);
  }

  static forCatalog(app: CatalogApp): string {
    if (app.latestAsset?.bundleName) return AppDisplayName.forCatalogBundle(app.latestAsset.bundleName, app.displayName);
    const bundles = new Set<string>();
    for (const asset of app.latestAssets.concat(app.knownAssets)) {
      if (asset.bundleName) bundles.add(asset.bundleName);
    }
    if (bundles.size === 1) return AppDisplayName.forCatalogBundle(Array.from(bundles)[0], app.displayName);
    // A multi-package listing without a selected package must not borrow an arbitrary variant's name.
    return app.displayName.trim();
  }
}
