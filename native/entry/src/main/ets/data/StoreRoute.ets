import { connection, http } from '@kit.NetworkKit';
import { StoreBuildConfig } from './StoreBuildConfig';
import { PrivacyConsent } from './PrivacyConsent';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StoreConnectivity } from './StoreConnectivity';

type StoreScope = 'ordinary' | 'overseas' | '';

interface StoreSelection {
  overseas: boolean;
  scope: StoreScope;
}

/** Select a pinned entry point before sending any business request. */
export class StoreRoute {
  private static watcher: connection.NetConnection | undefined;
  private static netId: number = -1;
  private static capabilities: string = '';
  private static invalidation: (() => void) | undefined;
  private static generation: number = 0;
  private static overseas: boolean = false;
  private static scope: StoreScope = '';
  private static expiresAt: number = 0;
  private static selection: Promise<void> | undefined;

  static onNetworkChange(callback: () => void): void { StoreRoute.invalidation = callback; }

  static revalidate(): void {
    StoreRoute.generation++;
    StoreRoute.expiresAt = 0;
    StoreRoute.selection = undefined;
    StoreConnectivity.reset();
  }

  private static reset(): void {
    StoreRoute.revalidate();
    StoreRoute.invalidation?.();
  }

  private static watch(): void {
    if (StoreRoute.watcher) return;
    try {
      const watcher = connection.createNetConnection(); StoreRoute.watcher = watcher;
      watcher.on('netAvailable', (net: connection.NetHandle) => {
        if (StoreRoute.netId >= 0 && StoreRoute.netId !== net.netId) StoreRoute.reset();
        StoreRoute.netId = net.netId;
      });
      watcher.on('netLost', (net: connection.NetHandle) => {
        if (StoreRoute.netId === net.netId) { StoreRoute.netId = -1; StoreRoute.reset(); }
      });
      watcher.on('netCapabilitiesChange', (event) => {
        const signature = event.netHandle.netId + ':' + event.netCap.bearerTypes.join(',');
        if (StoreRoute.capabilities && StoreRoute.capabilities !== signature) StoreRoute.reset();
        StoreRoute.capabilities = signature;
      });
      watcher.register((error) => { if (error) StoreRoute.watcher = undefined; });
    } catch (_) { StoreRoute.watcher = undefined; }
  }

  private static options(source: http.HttpRequestOptions, overseas: boolean): http.HttpRequestOptions {
    const options: http.HttpRequestOptions = {
      method: source.method,
      header: source.header,
      connectTimeout: Math.min(source.connectTimeout ?? 8000, overseas ? 6500 : 3500),
      readTimeout: source.readTimeout,
      usingCache: false,
      maxRedirects: 0,
      caData: overseas ? StoreBuildConfig.overseasCaData : StoreBuildConfig.caData,
      certificatePinning: {
        publicKeyHash: overseas ? StoreBuildConfig.overseasPublicKeySha256 : StoreBuildConfig.publicKeySha256,
        hashAlgorithm: 'SHA-256'
      },
      maxLimit: source.maxLimit
    };
    if (source.extraData !== undefined) options.extraData = source.extraData;
    if (source.usingProtocol !== undefined) options.usingProtocol = source.usingProtocol;
    if (source.expectDataType !== undefined) options.expectDataType = source.expectDataType;
    return options;
  }

  private static origin(overseas: boolean): string {
    return overseas ? StoreBuildConfig.overseasBaseUrl : StoreBuildConfig.baseUrl;
  }

  private static async probe(overseas: boolean, timeout: number): Promise<StoreScope> {
    let request: http.HttpRequest | undefined;
    let timer: number = -1;
    try {
      request = http.createHttp();
      const response = await Promise.race([
        request.request(StoreRoute.origin(overseas) + '/api/v1/distribution', StoreRoute.options({
          method: http.RequestMethod.GET,
          connectTimeout: timeout,
          readTimeout: timeout,
          maxLimit: 4096
        }, overseas)),
        new Promise<undefined>((resolve) => { timer = setTimeout(() => resolve(undefined), timeout); })
      ]);
      if (response?.responseCode !== 200 || typeof response.result !== 'string') return '';
      const envelope = JSON.parse(response.result) as Record<string, Object>;
      const data = envelope['data'] as Record<string, Object> | undefined;
      if (envelope['ok'] !== true) return '';
      if (data?.['network_scope'] === 'ordinary') return 'ordinary';
      return data?.['network_scope'] === 'overseas' ? 'overseas' : '';
    } catch (_) {
      return '';
    } finally {
      if (timer >= 0) clearTimeout(timer);
      request?.destroy();
    }
  }

  private static async select(generation: number): Promise<void> {
    const primary = StoreRoute.probe(false, 3500);
    const gateway = new Promise<StoreScope>((resolve) => {
      let timer = setTimeout(() => {
        timer = -1;
        StoreRoute.probeGateway(generation).then(resolve);
      }, 350);
      primary.then((scope) => {
        if (timer < 0) return;
        clearTimeout(timer);
        timer = -1;
        // A fast domestic response avoids a second connection altogether.
        if (scope === 'ordinary') resolve('');
        else StoreRoute.probeGateway(generation).then(resolve);
      });
    });
    const selection = await Promise.race<StoreSelection>([
      primary.then(async (scope): Promise<StoreSelection> => {
        if (scope !== 'ordinary' && await gateway === 'overseas') return { overseas: true, scope: 'overseas' };
        return { overseas: false, scope };
      }),
      gateway.then(async (scope): Promise<StoreSelection> => {
        if (scope === 'overseas') return { overseas: true, scope };
        return { overseas: false, scope: await primary };
      })
    ]);
    if (generation !== StoreRoute.generation) return;
    const selected = selection.overseas;
    const scope = selection.scope;
    const changed = StoreRoute.overseas !== selected || StoreRoute.scope !== scope;
    StoreRoute.overseas = selected;
    StoreRoute.scope = scope;
    StoreRoute.expiresAt = Date.now() + (scope === 'ordinary' || selected ? 60000 : scope ? 20000 : 5000);
    if (changed) StoreRoute.invalidation?.();
  }

  private static async probeGateway(generation: number): Promise<StoreScope> {
    if (generation !== StoreRoute.generation) return '';
    try { PrivacyConsent.assertBusinessAllowed(); }
    catch (_) { return ''; }
    return StoreRoute.probe(true, 6000);
  }

  static async prepare(): Promise<void> {
    PrivacyConsent.assertBusinessAllowed();
    StoreRoute.watch();
    if (!StoreBuildConfig.overseasBaseUrl) return;
    while (Date.now() >= StoreRoute.expiresAt) {
      if (!StoreRoute.selection) {
        const generation = StoreRoute.generation;
        StoreRoute.selection = StoreRoute.select(generation).finally(() => {
          if (generation === StoreRoute.generation) StoreRoute.selection = undefined;
        });
      }
      await StoreRoute.selection;
      PrivacyConsent.assertBusinessAllowed();
    }
  }

  static async request(request: http.HttpRequest, path: string,
    options: http.HttpRequestOptions): Promise<http.HttpResponse> {
    // The caller supplies API paths, never URL origins or protocol-relative URLs.
    if (!path.startsWith('/api/v1/') || path.includes('\\')) throw new Error('Invalid store API path');
    do { await StoreRoute.prepare(); } while (StoreBuildConfig.overseasBaseUrl &&
      Date.now() >= StoreRoute.expiresAt);
    PrivacyConsent.assertBusinessAllowed();
    const overseas = StoreRoute.overseas;
    const started = Date.now();
    try {
      // Exactly one business request, including uncertain write outcomes.
      const routed = StoreRoute.options(options, overseas);
      if (options.method === http.RequestMethod.GET) {
        routed.readTimeout = Math.min(routed.readTimeout ?? 20000, path.includes('/readme') ? 10000 : 6500);
      }
      return await request.request(StoreRoute.origin(overseas) + path, routed);
    } catch (error) {
      hilog.warn(0x5149, 'QingqiStoreRoute', 'Store transport failed code=%{public}d elapsedMs=%{public}d',
        Number((error as BusinessError).code ?? 0), Date.now() - started);
      throw await StoreConnectivity.explain(error);
    }
  }
}
