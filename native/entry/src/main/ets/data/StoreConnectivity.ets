import { connection, http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrivacyConsent } from './PrivacyConsent';
import { I18n } from './I18n';

export class StoreConnectionFailure extends Error {
  code: number;
  userMessage: string;
  constructor(message: string, code: number) {
    super(message); this.code = code; this.userMessage = message;
  }
}

class NetworkSnapshot {
  connected: number = -1;
  validated: boolean = false;
  checking: boolean = false;
  portal: boolean = false;
  vpn: boolean = false;
  reachable: boolean = false;
  copy(): NetworkSnapshot {
    const value = new NetworkSnapshot();
    value.connected = this.connected; value.validated = this.validated;
    value.checking = this.checking; value.portal = this.portal;
    value.vpn = this.vpn; value.reachable = this.reachable;
    return value;
  }
}

/** Failure-only, anonymous diagnosis. No polling, business replay or route selection. */
export class StoreConnectivity {
  private static epoch: number = 0;
  private static checkedAt: number = 0;
  private static snapshot: NetworkSnapshot | undefined;
  private static flight: Promise<NetworkSnapshot> | undefined;

  static reset(): void {
    StoreConnectivity.epoch++; StoreConnectivity.checkedAt = 0;
    StoreConnectivity.snapshot = undefined; StoreConnectivity.flight = undefined;
  }

  private static async state(): Promise<NetworkSnapshot> {
    const value = new NetworkSnapshot();
    return new Promise<NetworkSnapshot>((resolve) => {
      let settled = false;
      const finish = (): void => {
        if (settled) return;
        settled = true; clearTimeout(timer); resolve(value.copy());
      };
      const timer = setTimeout(finish, 500);
      const physical = (async (): Promise<void> => {
        try {
          value.connected = await connection.hasDefaultNet() ? 1 : 0;
          if (value.connected === 0) return;
          const network = await connection.getDefaultNet();
          const capabilities = await connection.getNetCapabilities(network);
          const flags = capabilities.networkCap ?? [];
          value.validated = flags.includes(connection.NetCap.NET_CAPABILITY_VALIDATED);
          value.checking = flags.includes(connection.NetCap.NET_CAPABILITY_CHECKING_CONNECTIVITY);
          value.portal = flags.includes(connection.NetCap.NET_CAPABILITY_PORTAL);
        } catch (_) {}
      })();
      const vpn = (async (): Promise<void> => {
        try {
          const networks = await connection.getAllNets();
          const flags = await Promise.all(networks.slice(0, 16).map(async (network: connection.NetHandle): Promise<boolean> => {
            try { return (await connection.getNetCapabilities(network)).bearerTypes.includes(connection.NetBearType.BEARER_VPN); }
            catch (_) { return false; }
          }));
          value.vpn = flags.some((enabled: boolean) => enabled);
        } catch (_) {}
      })();
      Promise.all([physical, vpn]).then(finish, finish);
    });
  }

  private static async publicReachable(): Promise<boolean> {
    PrivacyConsent.assertBusinessAllowed();
    const request = http.createHttp();
    let timer = -1;
    try {
      return await new Promise<boolean>((resolve) => {
        let settled = false;
        const finish = (reachable: boolean): void => {
          if (settled) return;
          settled = true; resolve(reachable);
        };
        timer = setTimeout(() => finish(false), 900);
        // HEAD uses the application's normal network path and public TLS trust.
        // Never attach store credentials, pins, cookies, queries or request data.
        request.request('https://www.huawei.com/', {
          method: http.RequestMethod.HEAD, usingCache: false,
          header: { 'Connection': 'close' }, connectTimeout: 800, readTimeout: 800,
          maxLimit: 16 * 1024
        }).then((response: http.HttpResponse) => finish(response.responseCode >= 200 && response.responseCode < 600),
          () => finish(false));
      });
    } finally {
      if (timer !== -1) clearTimeout(timer);
      request.destroy();
    }
  }

  private static async inspect(): Promise<NetworkSnapshot> {
    if (StoreConnectivity.snapshot && Date.now() - StoreConnectivity.checkedAt < 10000) return StoreConnectivity.snapshot;
    if (StoreConnectivity.flight) return StoreConnectivity.flight;
    const epoch = StoreConnectivity.epoch;
    const read = (async (): Promise<NetworkSnapshot> => {
      const value = await StoreConnectivity.state();
      if (epoch !== StoreConnectivity.epoch) return value;
      if (value.connected !== 0 && !value.portal) value.reachable = await StoreConnectivity.publicReachable();
      if (epoch === StoreConnectivity.epoch) {
        StoreConnectivity.snapshot = value; StoreConnectivity.checkedAt = Date.now();
      }
      return value;
    })();
    StoreConnectivity.flight = read;
    try { return await read; } finally { if (StoreConnectivity.flight === read) StoreConnectivity.flight = undefined; }
  }

  static async explain(error: Object): Promise<Error> {
    if (error instanceof StoreConnectionFailure) return error;
    const code = Number((error as BusinessError)?.code ?? 0);
    const status = Number((error as HttpFailure)?.status ?? 0);
    if (status > 0) return new StoreConnectionFailure(status === 429 ?
      I18n.t('请求过于频繁，请稍后重试') : I18n.t('商店服务响应异常，请稍后重试'), code);
    if ([2300058, 2300059, 2300060, 2300077, 2300083, 2300090, 2300091].includes(code)) {
      return new StoreConnectionFailure(I18n.t('商店安全连接校验失败，请更新安装器或检查代理设置'), code);
    }
    if (![2300005, 2300006, 2300007, 2300016, 2300018, 2300028, 2300035,
      2300052, 2300055, 2300056, 2300092, 2300999].includes(code)) return error as Error;
    PrivacyConsent.assertBusinessAllowed();
    const epoch = StoreConnectivity.epoch;
    const state = await StoreConnectivity.inspect();
    PrivacyConsent.assertBusinessAllowed();
    if (epoch !== StoreConnectivity.epoch) return new StoreConnectionFailure(I18n.t('网络已切换，请重新刷新'), code);
    let message = I18n.t('暂时无法连接商店，请检查网络；如使用代理，请尝试更换节点');
    if (state.connected === 0) message = I18n.t('网络未连接，请检查 Wi-Fi 或移动网络后重试');
    else if (state.portal) message = I18n.t('当前 Wi-Fi 需要认证，请完成网络登录后重试');
    else if (state.reachable) message = state.vpn ?
      I18n.t('网络正常，但无法连接商店，请更换代理节点后重试') :
      I18n.t('网络正常，但无法连接商店，请稍后重试；如使用代理，请尝试更换节点');
    else if (state.vpn) message = I18n.t('暂时无法连接商店，请尝试更换代理节点后重试');
    else if (state.connected === 1 && !state.checking && !state.validated) {
      message = I18n.t('网络连接异常，请检查 Wi-Fi、移动网络或代理连接后重试');
    }
    return new StoreConnectionFailure(message, code);
  }
}

interface HttpFailure { status?: number; }
