// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// hdc 设备安装通道。
//
// 与原 CmdService.installHap 的差异：
//   · 错误码 → 结构化结论（而不是一句中文自由文本）
//   · 每个错误码给出**可执行的下一步**，而不是让用户去「重置证书」
//
// 9568423 / 9568322 这两个码用户见得最多，也正是本项目预检要提前消灭的。

import 'dart:io';

/// 安装失败的结构化结果。
class InstallFailure {
  const InstallFailure({
    required this.code,
    required this.message,
    this.hint,
    this.rawOutput,
  });

  /// 设备错误码（如 `9568423`），无法识别时为 `UNKNOWN`。
  final String code;
  final String message;
  final String? hint;
  final String? rawOutput;

  @override
  String toString() => '[$code] $message${hint != null ? '\n  → $hint' : ''}';
}

/// 设备安装器：通过 hdc 把 HAP 推到设备并安装。
class HdcInstaller {
  HdcInstaller({required this.hdcPath, required this.target});

  final String hdcPath;

  /// 设备标识（`hdc list targets` 的输出）。
  final String target;

  /// 读取设备 UDID（供预检使用）。
  Future<String?> deviceUdid() async {
    final r = await _run(['shell', 'bm', 'get', '--udid']);
    if (r.exitCode != 0) return null;
    // 输出形如 "udid of current device is :\n<64位hex>"
    final m = RegExp(r'\b([0-9A-Fa-f]{40,})\b').firstMatch(r.stdout);
    return m?.group(1);
  }

  /// 安装 HAP。成功返回 null，失败返回 [InstallFailure]。
  Future<InstallFailure?> install(String hapPath) async {
    if (!await File(hapPath).exists()) {
      return InstallFailure(code: 'FILE_MISSING', message: '文件不存在：$hapPath');
    }
    final r = await _run(['install', hapPath]);
    final out = '${r.stdout}${r.stderr}';

    if (out.contains('install bundle successfully') && !out.contains('[Fail]')) {
      return null;
    }
    return classifyInstallError(out);
  }

  Future<ProcessOutput> _run(List<String> args) async {
    final r = await Process.run(
      hdcPath,
      ['-t', target, ...args],
      stdoutEncoding: SystemEncoding(),
      stderrEncoding: SystemEncoding(),
    );
    return ProcessOutput(
      exitCode: r.exitCode,
      stdout: r.stdout.toString(),
      stderr: r.stderr.toString(),
    );
  }
}

/// 命令执行结果。
///
/// 用普通类而非 Dart 3 的记录类型，以便与鸿蒙 Flutter 工具链
/// （3.7.12-ohos / Dart 2.19.6）兼容。
class ProcessOutput {
  ProcessOutput({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combined => '$stdout$stderr';
}

/// 把设备原始输出归类为结构化失败原因。
///
/// 错误码含义依据华为包管理器的实际返回。
InstallFailure classifyInstallError(String output) {
  String? pick(List<String> codes) {
    for (final c in codes) {
      if (output.contains(c)) return c;
    }
    return null;
  }

  final code = pick([
    '9568423', '9568322', '9568289', '9568297', '9568332',
    '9568329', '9568320', '9568263', '9568304', '9568407', 'E001005',
  ]);

  switch (code) {
    case '9568423':
      return InstallFailure(
        code: code!,
        message: '设备未授权：Profile 中没有本机 UDID',
        hint: '这正是预检应当提前拦下的情况。'
            '请为该设备重新申请 Profile，而不是重置证书。',
        rawOutput: output,
      );
    case '9568322':
      return InstallFailure(
        code: code!,
        message: '签名校验失败：不可信的签名来源',
        hint: '常见原因：Profile 与包的 bundleName 不一致，'
            '或使用了发布证书而非调试证书。',
        rawOutput: output,
      );
    case '9568329':
      return InstallFailure(
        code: code!,
        message: '签名信息中的包名与应用 bundleName 不一致',
        hint: '检查是否混入了第三方 HSP，或 Profile 绑定了别的 bundle。',
        rawOutput: output,
      );
    case '9568332':
      return InstallFailure(
        code: code!,
        message: '签名不一致：设备上已有应用与本次签名不同',
        hint: '同一应用的所有 HAP/HSP 必须使用同一套签名。',
        rawOutput: output,
      );
    case '9568320':
      return InstallFailure(
        code: code!,
        message: '不能安装未签名的 HAP',
        hint: '请先完成签名。',
        rawOutput: output,
      );
    case '9568289':
      return InstallFailure(
        code: code!,
        message: '权限授予失败',
        hint: '若使用了 system_basic/system_core 级权限，'
            '需要在 Profile 中声明对应 ACL，命令行 -g 无法替代。',
        rawOutput: output,
      );
    case '9568297':
      return InstallFailure(
        code: code!,
        message: '设备 SDK 版本过低',
        hint: '编译使用的 SDK 版本与设备镜像不匹配。',
        rawOutput: output,
      );
    case '9568263':
      return InstallFailure(
        code: code!,
        message: '不支持降级安装',
        hint: '设备上已有更高版本；先卸载或提升版本号。',
        rawOutput: output,
      );
    case '9568304':
      return InstallFailure(
        code: code!,
        message: '该 HAP 不支持当前设备安装',
        hint: '可能是设备类型或 API 版本不匹配。',
        rawOutput: output,
      );
    case '9568407':
      return InstallFailure(
        code: code!,
        message: 'HNP 包安装失败',
        hint: 'HNP 签名失败；检查 hnpcli 的签名配置。',
        rawOutput: output,
      );
    case 'E001005':
      return InstallFailure(
        code: code!,
        message: '设备未连接',
        hint: '重新连接设备或检查 hdc 目标是否有效。',
        rawOutput: output,
      );
  }

  return InstallFailure(
    code: 'UNKNOWN',
    message: '安装失败（未能识别的设备返回）',
    hint: output.trim().isEmpty ? '设备没有返回任何信息。' : null,
    rawOutput: output,
  );
}
