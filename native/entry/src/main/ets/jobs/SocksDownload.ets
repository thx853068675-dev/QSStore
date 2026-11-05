import { connection, http } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { JobCancellation } from './JobCancellation';

/** Stream SOCKS5 traffic through NetStack without buffering the entire package. */
export class SocksDownload {
  static async run(url: string, path: string, address: string, jobId: string,
    progress?: (received: number, total: number) => void): Promise<void> {
    if (deviceInfo.sdkApiVersion < 26) throw new Error('当前系统版本暂不支持 SOCKS5 下载，请使用分流器 HTTP 混合端口');
    const match = /^socks5:\/\/(\[[0-9a-f:]+\]|[a-z0-9.-]+):(\d{1,5})$/i.exec(address);
    if (!match || Number(match[2]) < 1 || Number(match[2]) > 65535) throw new Error('SOCKS5 代理地址无效');
    const host = match[1].startsWith('[') ? match[1].slice(1, -1) : match[1];
    const client = http.createHttp();
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
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
        try { client.destroy(); } catch (_) {}
      }
    }, 500);
    try {
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
          try { client.destroy(); } catch (_) {}
        }
      });
      client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
        if (progress) progress(info.receiveSize, info.totalSize);
      });
      client.on('dataEnd', () => { dataEnded = true; finishData(); });
      const code = await client.requestInStream(url, {
        method: http.RequestMethod.GET, usingProxy: false,
        usingSocks5Proxy: { host: host, port: Number(match[2]), dnsStrategy: connection.Socks5DnsStrategy.PROXY_MODE },
        connectTimeout: 12000, readTimeout: 60000
      });
      if (!dataEnded) {
        await Promise.race([dataEnd, new Promise<void>((_resolve: () => void, reject: (error: Error) => void) => {
          endTimer = setTimeout(() => reject(new Error('代理下载未收到完整响应')), 5000);
        })]);
      }
      JobCancellation.assertActive(jobId);
      PrivacyConsent.assertBusinessAllowed();
      if (writeFailure) throw new Error(writeFailure);
      if (code !== 200 || written === 0) throw new Error('代理下载失败：HTTP ' + code);
      fileIo.fsyncSync(file.fd);
      complete = true;
    } finally {
      clearInterval(watcher);
      if (endTimer !== -1) clearTimeout(endTimer);
      try { client.destroy(); } catch (_) {}
      fileIo.closeSync(file);
      if (!complete) { try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_) {} }
    }
  }
}
