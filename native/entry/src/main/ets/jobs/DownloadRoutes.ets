import { connection } from '@kit.NetworkKit';

/** 用户选择的 GitHub 镜像优先；未配置时保持 VPN 直连及原有备用顺序。 */
export class DownloadRoutes {
  static async vpnEnabled(): Promise<boolean> {
    return new Promise<boolean>((resolve: (enabled: boolean) => void) => {
      const timer = setTimeout(() => resolve(false), 600);
      DownloadRoutes.readVpn().then((enabled: boolean) => {
        clearTimeout(timer);
        resolve(enabled);
      });
    });
  }

  private static async readVpn(): Promise<boolean> {
    try {
      const networks = await connection.getAllNets();
      const flags = await Promise.all(networks.slice(0, 16).map(async (network: connection.NetHandle): Promise<boolean> => {
        try {
          const capabilities = await connection.getNetCapabilities(network);
          return capabilities.bearerTypes.includes(connection.NetBearType.BEARER_VPN);
        } catch (_) { return false; }
      }));
      return flags.some((enabled: boolean) => enabled);
    } catch (_) { return false; }
  }

  private static githubRelease(url: string): string {
    // A query can hold an access token or another URL credential. Only plain
    // public release URLs are forwarded to a newly selected third-party mirror.
    const release = /^https:\/\/github\.com\/[^/?#]+\/[^/?#]+\/releases\/download\/[^/?#]+\/[^?#]+(?:#.*)?$/i;
    if (release.test(url)) return url;
    // A proxy may be the only URL saved by an older journal. Recover only an
    // absolute GitHub release URL at the start of its path, never a query value
    // or a lookalike host. The custom prefix is applied to this original URL.
    const nested = /^https:\/\/(?:[a-z0-9.-]+|\[[0-9a-f:.]+\])(?::\d+)?\/(https:\/\/github\.com\/.*)$/i.exec(url);
    return nested && release.test(nested[1]) ? nested[1] : '';
  }

  private static mirrorPrefix(value: string): string {
    const prefix = value.trim();
    if (!/^https:\/\/(?:[a-z0-9.-]+|\[[0-9a-f:.]+\])(?::\d{1,5})?(?:\/[^?#\\\s{}]*)?$/i.test(prefix)) return '';
    return prefix.endsWith('/') ? prefix : prefix + '/';
  }

  static order(source: string, mirrors: string[], vpn: boolean, custom: string = '',
    previousCustomPrefix: string = ''): string[] {
    let urls = [source, ...mirrors].filter((url: string, index: number, all: string[]) =>
      /^https:\/\//.test(url) && all.indexOf(url) === index);
    const previous = DownloadRoutes.mirrorPrefix(previousCustomPrefix);
    if (previous.length > 0) {
      const oldOriginal = (url: string): string => {
        const original = url.startsWith(previous) ? url.substring(previous.length) : '';
        return original.length > 0 && DownloadRoutes.githubRelease(original) === original ? original : '';
      };
      // Only recorded custom routes can be removed after a settings change.
      // Recover their exact original first, so even a proxy-only journal keeps
      // a usable source. Unrelated URLs are never guessed to be custom routes.
      const recovered = urls.map(oldOriginal).filter((url: string) => url.length > 0);
      urls = [...urls.filter((url: string) => oldOriginal(url).length === 0), ...recovered]
        .filter((url: string, index: number, all: string[]) => all.indexOf(url) === index);
    }
    const official = (url: string): boolean =>
      /^https:\/\/(github\.com|release-assets\.githubusercontent\.com|objects\.githubusercontent\.com)(\/|$)/i.test(url);
    const defaults = vpn ? [...urls.filter(official), ...urls.filter((url: string) => !official(url))] : urls;
    const prefix = DownloadRoutes.mirrorPrefix(custom);
    if (prefix.length === 0) return defaults;
    const originals = urls.map((url: string) => DownloadRoutes.githubRelease(url))
      .filter((url: string, index: number, all: string[]) => url.length > 0 && all.indexOf(url) === index);
    if (originals.length === 0) return defaults;
    // Keep the server/default routes and a direct fallback. A selected mirror
    // takes precedence even with a VPN; an existing agent never calls this path.
    return [...originals.map((url: string) => prefix + url), ...defaults, ...originals]
      .filter((url: string, index: number, all: string[]) => all.indexOf(url) === index);
  }
}
