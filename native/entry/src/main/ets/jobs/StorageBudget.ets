import { ServiceFailure } from '../data/ServiceFailure';
import { FailureKind } from './InstallJob';
import { statfs } from '@kit.CoreFileKit';
import { I18n } from '../data/I18n';

export class StorageBudget {
  static async require(path: string, bytes: number): Promise<void> {
    if (!Number.isFinite(bytes) || bytes < 0 || bytes > 8 * 1024 * 1024 * 1024) {
      throw new Error(I18n.t('安装文件展开大小无效'));
    }
    const free = await statfs.getFreeSize(path);
    const needed = Math.ceil(bytes) + 64 * 1024 * 1024;
    if (free < needed) throw new ServiceFailure(FailureKind.TRANSIENT, I18n.t('可用存储不足，还需要约 ') +
      Math.ceil((needed - free) / 1024 / 1024) + I18n.t(' MB，请清理空间后重试'));
  }
}
