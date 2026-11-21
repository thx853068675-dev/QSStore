import { connection, http } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { I18n } from './I18n';

export function proxyRequestOptions(protocol: string, host: string, port: number,
  username: string = '', password: string = ''): http.HttpRequestOptions {
  if (protocol === 'socks5') {
    if (deviceInfo.sdkApiVersion < 26) {
      throw new Error(I18n.t('当前系统暂不支持 SOCKS5 下载，请使用 HTTP 代理'));
    }
    return {
      usingProxy: false,
      usingSocks5Proxy: {
        host: host.startsWith('[') ? host.slice(1, -1) : host, port: port,
        username: username || undefined, password: password || undefined,
        dnsStrategy: connection.Socks5DnsStrategy.PROXY_MODE
      }
    };
  }
  return {
    usingProxy: { host: host, port: port, exclusionList: [],
      username: username || undefined, password: password || undefined }
  };
}

export function proxyHttpError(code: number): Error {
  return new Error(code === 407 ? I18n.t('代理认证失败，请检查用户名和密码') :
    I18n.t('代理请求失败，HTTP ') + code);
}

export class DownloadProxyProbe {
  static async latency(protocol: string, host: string, port: number,
    username: string = '', password: string = ''): Promise<number> {
    const options = proxyRequestOptions(protocol, host, port, username, password);
    options.method = http.RequestMethod.HEAD;
    options.expectDataType = http.HttpDataType.STRING;
    options.connectTimeout = 8000;
    options.readTimeout = 8000;
    options.maxLimit = 8192;
    const client = http.createHttp();
    const start = Date.now();
    try {
      const response = await client.request('https://github.com/', options).catch(() => {
        throw new Error(I18n.t('代理连接失败，请检查地址和认证信息'));
      });
      if (response.responseCode < 200 || response.responseCode >= 400) throw proxyHttpError(response.responseCode);
      return Math.max(1, Date.now() - start);
    } finally { client.destroy(); }
  }
}
