import { connection, http } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';

export class DownloadProxyProbe {
  static async latency(protocol: string, host: string, port: number): Promise<number> {
    if (protocol === 'socks5' && deviceInfo.sdkApiVersion < 26) {
      throw new Error('当前系统暂不支持 SOCKS5 测速');
    }
    const client = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.HEAD, expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000, readTimeout: 8000, maxLimit: 8192,
      usingProxy: protocol === 'http' ? { host: host, port: port, exclusionList: [] } : false
    };
    if (protocol === 'socks5') options.usingSocks5Proxy = {
      host: host.startsWith('[') ? host.slice(1, -1) : host, port: port,
      dnsStrategy: connection.Socks5DnsStrategy.PROXY_MODE
    };
    const start = Date.now();
    try {
      const response = await client.request('https://github.com/', options);
      if (response.responseCode < 200 || response.responseCode >= 400) throw new Error('代理请求失败：' + response.responseCode);
      return Math.max(1, Date.now() - start);
    } finally { client.destroy(); }
  }
}
