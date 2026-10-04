import { connection } from '@kit.NetworkKit';

/** VPN 下 GitHub 直连优先；权限/网络服务不可用时保持原有顺序。 */
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

  static order(source: string, mirrors: string[], vpn: boolean): string[] {
    const urls = [source, ...mirrors].filter((url: string, index: number, all: string[]) =>
      /^https:\/\//.test(url) && all.indexOf(url) === index);
    if (!vpn) return urls;
    const official = (url: string): boolean =>
      /^https:\/\/(github\.com|release-assets\.githubusercontent\.com|objects\.githubusercontent\.com)(\/|$)/i.test(url);
    return [...urls.filter(official), ...urls.filter((url: string) => !official(url))];
  }
}
