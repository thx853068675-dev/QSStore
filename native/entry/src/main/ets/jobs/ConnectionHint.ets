/** Only explicit transport evidence is classified; a reachable port is not proof of occupation. */
export class ConnectionHint {
  static closed(detail: string): boolean {
    return /connection refused|econnrefused|os error (?:61|111)\b/i.test(detail);
  }

  static message(detail: string): string {
    if (ConnectionHint.closed(detail)) {
      return '此端口没有接受连接：无线调试可能未开启，或端口已变化。请打开无线调试，填入当前端口。';
    }
    if (/address.*in use|eaddrinuse|occupied|another (?:host|client)|port.*busy/i.test(detail)) {
      return '调试连接已被占用。请断开电脑或其他侧载工具的调试连接，再重新连接。';
    }
    if (/authentication rejected|permission denied|not authorized|untrusted/i.test(detail)) {
      return '设备尚未授权本机调试。请在系统弹窗中允许连接；若没有弹窗，可关闭再开启无线调试。';
    }
    if (/authentication timeout/i.test(detail)) {
      return '端口可以访问，但调试授权超时。请确认系统连接授权；若已被电脑或其他工具连接，请先断开。';
    }
    if (/timed out|timeout/i.test(detail)) {
      return '连接超时。请确认无线调试已开启且端口未变化，再重试。';
    }
    if (/connection reset|broken pipe|unexpected eof|channel closed|connection aborted/i.test(detail)) {
      return '端口可以访问，但调试链路已中断。请断开其他调试工具，并重新开启无线调试后连接。';
    }
    return '未能建立调试连接。请核对当前端口，在系统弹窗中允许连接，并断开电脑或其他侧载工具后重试。';
  }
}
