import { common } from '@kit.AbilityKit';
import { http, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { DeveloperAccount } from './DeveloperAccount';

/**
 * 账号服务的临时故障标记。
 *
 * 网络不通或服务端 5xx 时用它包住错误信息：这类失败**不代表登录态失效**，
 * 调用方应当沿用本地已保存的账号，而不是把用户踢回登录页。
 */
const TRANSIENT = 'TRANSIENT|';

/** 已确认登录态失效（4xx）。与 TRANSIENT 相对，调用方必须重新登录。 */
const AUTH_FAILED = 'AUTHFAILED|';

export function isTransientAuthError(error: Object): boolean {
  const text = String(error);
  // 已判定失效的错误即使被别的层包过，也不算临时故障
  return text.includes(TRANSIENT) && !text.includes(AUTH_FAILED);
}

/** 去掉内部标记后、可直接展示给用户的文案。 */
export function authErrorText(error: Object): string {
  return String(error).split(TRANSIENT).join('').split(AUTH_FAILED).join('');
}

const AUTH_API = 'https://cn.devecostudio.huawei.com/authrouter/auth/api';
const PROFILE_API = 'https://account.cloud.huawei.com/rest.php?nsp_svc=GOpen.User.getInfo';
const AUTH_PAGE = 'https://cn.devecostudio.huawei.com/console/DevEcoIDE/apply' +
  '?port=8888&appid=1007&code=20698961dd4f420c8b44f49010c6f0cc';

class PlainTokenRet {
  msg: string = '';
}

class PlainTokenResponse {
  ret: PlainTokenRet = new PlainTokenRet();
}

// Login only exchanges an existing DevEco browser session. It never calls
// AGC certificate/profile creation, so it cannot consume a certificate slot.
export class DevEcoLogin {
  private static async requestJson(url: string, method: http.RequestMethod,
    headers: Record<string, string> = {}, body: string = '',
    allowPlainToken: boolean = false): Promise<Record<string, Object>> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: 12000,
        readTimeout: 12000,
        maxLimit: 1024 * 1024
      };
      if (body.length > 0) options.extraData = body;
      const response = await request.request(url, options);
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        const code = response.responseCode;
        // 5xx / 0 是服务端或网络问题，4xx 才可能是登录态本身有问题
        const head = (code === 0 || code === 408 || code === 429 || code >= 500) ? TRANSIENT : AUTH_FAILED;
        throw new Error(head + '华为账号服务暂不可用（HTTP ' + code + '）');
      }
      try {
        const parsed = JSON.parse(response.result) as Object;
        if (allowPlainToken && typeof parsed === 'string') {
          const token = new PlainTokenResponse();
          token.ret.msg = parsed;
          return JSON.parse(JSON.stringify(token)) as Record<string, Object>;
        }
        return parsed as Record<string, Object>;
      } catch (_) {
        // DevEco's tempToken exchange may return the JWT as plain text.
        // Other endpoints must still return JSON.
        if (allowPlainToken && response.result.trim().length > 0) {
          const token = new PlainTokenResponse();
          token.ret.msg = response.result.trim();
          return JSON.parse(JSON.stringify(token)) as Record<string, Object>;
        }
        throw new Error('华为账号服务返回的数据格式无效');
      }
    } catch (error) {
      const text = String(error);
      // 已经分过类的原样上抛。之前这里无条件加 TRANSIENT，会把内层刚判定
      // 的 401/403 重新盖成「临时故障」，于是拿着失效登录态继续跑，后续
      // 上架、评论、授权全部失败。
      if (text.includes(TRANSIENT) || text.includes(AUTH_FAILED)) {
        throw new Error(text);
      }
      // 其余是连接超时 / 断网：属于临时故障，不能据此判定登录态失效
      throw new Error(TRANSIENT + text);
    } finally {
      request.destroy();
    }
  }

  private static fromUserInfo(info: Record<string, Object>, jwt: string): DeveloperAccount {
    const account = new DeveloperAccount();
    account.accessToken = String(info['accessToken'] ?? '');
    account.jwtToken = jwt;
    account.userId = String(info['userId'] ?? '');
    account.teamId = String(info['teamId'] ?? account.userId);
    account.displayName = String(info['nickName'] ?? '');
    if (typeof info['realName'] === 'boolean') account.realNameVerified = info['realName'] as boolean;
    if (account.accessToken.length === 0 || account.userId.length === 0) {
      throw new Error('华为账号返回的信息不完整');
    }
    return account;
  }

  private static async userInfo(jwt: string, refresh: boolean): Promise<DeveloperAccount> {
    const data = await DevEcoLogin.requestJson(AUTH_API + '/jwToken/check',
      http.RequestMethod.GET, { 'jwtToken': jwt, 'refresh': refresh ? 'true' : 'false' });
    const info = data['userInfo'] as Record<string, Object> | undefined;
    if (!info) throw new Error('华为登录态已失效，请重新登录');
    const account = DevEcoLogin.fromUserInfo(info, jwt);
    await DevEcoLogin.fillPublicProfile(account);
    return account;
  }

  private static async fillPublicProfile(account: DeveloperAccount): Promise<void> {
    try {
      const form = 'access_token=' + encodeURIComponent(account.accessToken) + '&getNickName=1';
      const profile = await DevEcoLogin.requestJson(PROFILE_API,
        http.RequestMethod.POST,
        { 'Content-Type': 'application/x-www-form-urlencoded' }, form);
      if (String(profile['userID'] ?? '') !== account.userId) return;
      const name = String(profile['displayName'] ?? '');
      if (name.length > 0 && !name.includes('*') && !name.includes('＊')) {
        account.displayName = name;
      }
      const avatar = String(profile['headPictureURL'] ?? profile['headPicUrl'] ?? '');
      if (/^https:\/\//.test(avatar)) account.avatarUrl = avatar;
    } catch (_) {
      // The verified account still works when Huawei's public profile is down.
    }
  }

  static async refresh(saved: DeveloperAccount): Promise<DeveloperAccount> {
    const refreshed = await DevEcoLogin.userInfo(saved.jwtToken, true);
    if (refreshed.userId !== saved.userId) throw new Error('账号身份发生变化，请重新登录');
    if (refreshed.avatarUrl.length === 0) refreshed.avatarUrl = saved.avatarUrl;
    if (refreshed.realNameVerified === undefined) refreshed.realNameVerified = saved.realNameVerified;
    if (refreshed.label === refreshed.userId && saved.label !== saved.userId) {
      refreshed.displayName = saved.displayName;
    }
    return refreshed;
  }

  private static async exchange(tempToken: string): Promise<DeveloperAccount> {
    const url = AUTH_API + '/temptoken/check?site=CN&tempToken=' +
      encodeURIComponent(tempToken) + '&appid=1007&version=0.0.0';
    const data = await DevEcoLogin.requestJson(url, http.RequestMethod.GET, {}, '', true);
    const ret = data['ret'] as Record<string, Object> | undefined;
    const jwt = String(ret?.['msg'] ?? '');
    if (jwt.length === 0) throw new Error('华为授权回执无效');
    return DevEcoLogin.userInfo(jwt, false);
  }

  static async login(context: common.UIAbilityContext): Promise<DeveloperAccount> {
    const server = socket.constructTCPSocketServerInstance();
    let port = 0;
    for (const candidate of [8888, 3333 + Math.floor(Math.random() * 1000)]) {
      try {
        await server.listen({ address: '127.0.0.1', family: 1, port: candidate });
        port = candidate;
        break;
      } catch (_) {}
    }
    if (port === 0) throw new Error('无法启动本机登录回调，请稍后重试');

    let done = false;
    let timer = 0;
    let resolveLogin: (account: DeveloperAccount) => void = () => {};
    let rejectLogin: (error: Error) => void = () => {};
    const result = new Promise<DeveloperAccount>((resolve, reject) => {
      resolveLogin = resolve;
      rejectLogin = reject;
    });
    const finish = async (account?: DeveloperAccount, error?: Error): Promise<void> => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { await server.close(); } catch (_) {}
      if (account) resolveLogin(account);
      else rejectLogin(error ?? new Error('登录已取消'));
    };

    server.on('connect', (connection: socket.TCPSocketConnection) => {
      let received = '';
      let handled = false;
      connection.on('message', async (message: socket.SocketMessageInfo) => {
        if (handled) return;
        received += new util.TextDecoder('utf-8').decodeToString(new Uint8Array(message.message));
        if (received.length > 16384) {
          handled = true;
          await connection.close();
          return;
        }
        const divider = received.indexOf('\r\n\r\n');
        if (divider < 0) return;
        const header = received.substring(0, divider);
        const lengthMatch = /content-length:\s*(\d+)/i.exec(header);
        const contentLength = lengthMatch ? Number(lengthMatch[1]) : 0;
        if (contentLength > 8192 || received.length - divider - 4 < contentLength) return;
        handled = true;
        const body = received.substring(divider + 4, divider + 4 + contentLength);
        const first = header.split('\r\n')[0];
        let messageText = '登录失败，请返回应用重试';
        try {
          if (first.startsWith('OPTIONS ')) {
            await connection.send({ data: 'HTTP/1.1 204 No Content\r\n' +
              'Access-Control-Allow-Origin: *\r\n' +
              'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n' +
              'Access-Control-Allow-Headers: *\r\n' +
              'Access-Control-Allow-Private-Network: true\r\n' +
              'Content-Length: 0\r\nConnection: close\r\n\r\n' });
            await connection.close();
            return;
          }
        const target = first.split(' ')[1] ?? '';
        const query = target.includes('?') ? target.substring(target.indexOf('?') + 1) : '';
        const form = body.length > 0 ? body : query;
        const tokenMatch = /(?:^|&)tempToken=([^&]+)/.exec(form);
        if (/(?:^|&)quit=/.test(form)) {
          messageText = '已取消登录';
          await finish(undefined, new Error('已取消登录'));
        } else if (tokenMatch) {
          const account = await DevEcoLogin.exchange(decodeURIComponent(tokenMatch[1]));
          messageText = '登录成功，请返回轻启·安装器';
          resolveLogin(account);
          done = true;
          clearTimeout(timer);
        } else {
          messageText = '无效的登录回调';
        }
        } catch (error) {
          await finish(undefined, new Error(String(error)));
        }
        const html = '<!doctype html><meta charset="utf-8"><title>华为账号登录</title>' +
          '<p style="font:18px sans-serif;padding:32px">' + messageText + '</p>';
        try {
          await connection.send({ data: 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n' +
            'Content-Length: ' + new util.TextEncoder().encodeInto(html).length +
            '\r\nConnection: close\r\n\r\n' + html });
        } catch (_) {}
        try { await connection.close(); } catch (_) {}
        if (done) { try { await server.close(); } catch (_) {} }
      });
    });

    timer = setTimeout(() => {
      finish(undefined, new Error('等待华为账号登录超时'));
    }, 600000);
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: AUTH_PAGE.replace('port=8888', 'port=' + port)
      });
    } catch (error) {
      await finish(undefined, new Error('无法打开华为授权页：' + String(error)));
    }
    return result;
  }
}
