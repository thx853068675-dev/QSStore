import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { DownloadProxySetting } from '../data/DownloadProxyPreferences';
import { proxyHttpError, proxyRequestOptions } from '../data/DownloadProxyProbe';
import { I18n } from '../data/I18n';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { JobCancellation } from './JobCancellation';

/** NetStack streams packages for SOCKS5 and HTTP proxies that require credentials. */
export class ProxyDownload {
  static async run(url: string, path: string, proxy: DownloadProxySetting, jobId: string,
    progress?: (received: number, total: number) => void): Promise<void> {
    const match = /^(http|socks5):\/\/(\[[0-9a-f:]+\]|[a-z0-9.-]+):(\d{1,5})$/i.exec(proxy.address);
    if (!match || Number(match[3]) < 1 || Number(match[3]) > 65535) throw new Error(I18n.t('代理地址无效'));
    const options = proxyRequestOptions(match[1], match[2], Number(match[3]), proxy.username, proxy.password);
    options.method = http.RequestMethod.GET;
    options.connectTimeout = 12000;
    options.readTimeout = 60000;
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
    let client: http.HttpRequest | undefined;
    let complete = false;
    let written = 0;
    let writeFailure = '';
    let cancelled = false;
    let dataEnded = false;
    let finishData: () => void = () => {};
    const dataEnd = new Promise<void>((resolve: () => void) => { finishData = resolve; });
    let endTimer = -1;
    const watcher = setInterval(() => {
      if (JobCancellation.isCancelled(jobId) || !PrivacyConsent.isBusinessAllowed()) {
        cancelled = true;
        try { client?.destroy(); } catch (_) {}
      }
    }, 500);
    try {
      client = http.createHttp();
      client.on('dataReceive', (buffer: ArrayBuffer) => {
        if (writeFailure || cancelled) return;
        try {
          const bytes = new Uint8Array(buffer);
          let offset = 0;
          while (offset < bytes.length) {
            const count = fileIo.writeSync(file.fd, bytes.slice(offset).buffer);
            if (count <= 0) throw new Error('文件写入失败');
            offset += count;
          }
          written += bytes.length;
        } catch (error) {
          writeFailure = String(error);
          try { client?.destroy(); } catch (_) {}
        }
      });
      client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
        if (progress) progress(info.receiveSize, info.totalSize);
      });
      client.on('dataEnd', () => { dataEnded = true; finishData(); });
      const code = await client.requestInStream(url, options).catch(() => {
        JobCancellation.assertActive(jobId);
        PrivacyConsent.assertBusinessAllowed();
        if (writeFailure) throw new Error(writeFailure);
        throw new Error(I18n.t('代理连接失败，请检查地址和认证信息'));
      });
      if (code !== 200) throw proxyHttpError(code);
      if (!dataEnded) {
        await Promise.race([dataEnd, new Promise<void>((_resolve: () => void, reject: (error: Error) => void) => {
          endTimer = setTimeout(() => reject(new Error(I18n.t('代理下载未收到完整响应'))), 5000);
        })]);
      }
      JobCancellation.assertActive(jobId);
      PrivacyConsent.assertBusinessAllowed();
      if (writeFailure) throw new Error(writeFailure);
      if (written === 0) throw new Error(I18n.t('代理下载未收到完整响应'));
      fileIo.fsyncSync(file.fd);
      complete = true;
    } finally {
      clearInterval(watcher);
      if (endTimer !== -1) clearTimeout(endTimer);
      try { client?.destroy(); } catch (_) {}
      fileIo.closeSync(file);
      if (!complete) { try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_) {} }
    }
  }
}
