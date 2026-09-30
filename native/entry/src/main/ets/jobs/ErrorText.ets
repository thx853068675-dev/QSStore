import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 把 catch 到的任意值转成能读的文案。
 *
 * ArkTS 只允许抛 Error 实例，但底层库（http、fileIo、bundleManager）抛的是
 * BusinessError，直接 `String(e)` 得到的是 `[object Object]` —— 用户看到的
 * 报错成了噪音，排查时也不知道是哪一步、什么错码失败的。
 *
 *   普通 Error          → 它的 message
 *   BusinessError       → message（错误码 N）
 *   其它                → String(value)，空则「未知错误」
 */
export function errorText(error: Object): string {
  const business = error as BusinessError;
  if (business !== undefined && business.code !== undefined) {
    const detail = business.message !== undefined ? business.message : '';
    return detail.length > 0 ? detail + '（错误码 ' + business.code + '）' :
      '错误码 ' + business.code;
  }
  const text = String(error);
  return text.length > 0 ? text : '未知错误';
}
