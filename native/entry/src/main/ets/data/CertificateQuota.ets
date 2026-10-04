import { FailureKind } from '../jobs/InstallJob';
import { ServiceFailure } from './ServiceFailure';

/** Only classify an explicit rejection of cert/add, never counts or Profile quotas. */
export function certificateQuotaFailure(error: Error): Error {
  if (!(error instanceof ServiceFailure) || error.status <= 0 ||
    /provision|profile|授权|HTTP|登录|权限/i.test(error.message)) return error;
  const message = error.message;
  if (!/(?:cert(?:ificate)?[\s\S]*(?:limit|quota|exceed|maximum)|(?:number|count|quantity)[\s\S]*(?:exceed|reached)[\s\S]*limit|证书[\s\S]*(?:上限|已满)|该证书类型的数量已达上限)/i.test(message)) return error;
  return new ServiceFailure(FailureKind.CERTIFICATE_LIMIT,
    'AGC 调试证书名额已满。请选择一张不再使用的证书删除，删除后会继续安装。', error.status);
}
