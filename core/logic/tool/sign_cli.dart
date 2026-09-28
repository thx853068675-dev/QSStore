// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// sign_cli —— 无 UI 的签名端到端验证入口。
//
// 用途：在真实 HAP 与真实设备上验证签名核心，不依赖 Flutter。
//
// 用法示例：
//   dart run tool/sign_cli.dart \
//     --input  /path/to/app.hap \
//     --output /path/to/app-signed.hap \
//     --cert   /path/to/chain.cer \
//     --profile /path/to/profile.p7b \
//     --key    /path/to/key.pem \
//     --signer /path/to/signer \
//     [--install --hdc /path/to/hdc --target <deviceId>] \
//     [--udid <设备UDID>]
//
// 退出码：0 成功；1 预检失败；2 签名失败；3 安装失败。

import 'dart:convert';
import 'dart:io';

import 'package:signing_core/signing_core.dart';

Future<int> main(List<String> argv) async {
  final args = _parseArgs(argv);
  if (args == null) {
    _usage();
    return 64;
  }

  final input = File(args['input']!);
  final output = File(args['output']!);
  final cert = args['cert']!;
  final profilePath = args['profile']!;
  final key = args['key']!;
  final signerPath = args['signer']!;

  if (!await input.exists()) {
    stderr.writeln('输入文件不存在：${input.path}');
    return 64;
  }
  for (final f in [cert, profilePath, key, signerPath]) {
    if (!await File(f).exists()) {
      stderr.writeln('材料文件不存在：$f');
      return 64;
    }
  }

  print('════════ 签名端到端验证 ════════');
  print('输入   : ${input.path} (${await _mb(input)} MB)');
  print('输出   : ${output.path}');
  print('');

  // ── 1. 结构检查 ──────────────────────────────────────────────────
  print('── 1/5 包结构检查 ──');
  PackageInfo? info;
  try {
    info = await PackageInfo.inspect(input);
  } on HapFormatException catch (e) {
    stderr.writeln('包结构无效：${e.message}');
    return 2;
  }

  String bundleName;
  bool isQuietStart;
  if (info != null) {
    bundleName = bundleNameOf(info.main);
    isQuietStart = true;
    print('  类型     : 轻启整包（含内嵌工作模块）');
    print('  bundle   : $bundleName');
    print('  版本号   : ${info.main['app']?['versionCode']}');
    print('  工作模块 : ${info.workerPayload.length} 字节 '
        '(上限 $workerPayloadLimit)');
  } else {
    // 非轻启包：从 module.json 读 bundleName
    final reader = await HapReader.open(input);
    try {
      final e = reader.find('module.json');
      if (e == null) {
        stderr.writeln('不是有效的 HAP：缺少 module.json');
        return 2;
      }
      bundleName = bundleNameOf(
          Map<String, dynamic>.from(
              _decodeJson(await reader.readDecoded(e))));
      isQuietStart = false;
      print('  类型     : 普通 HAP（单包直签）');
      print('  bundle   : $bundleName');
      print('  条目数   : ${reader.entries.length}');
    } finally {
      await reader.close();
    }
  }
  print('');

  // ── 2. 预检 ──────────────────────────────────────────────────────
  print('── 2/5 签名前预检 ──');
  final deviceUdid = args['udid'] ?? await _detectUdid(args);
  final report = await preflightSigningMaterial(
    config: SignConfig(
      certPath: cert,
      profilePath: profilePath,
      keystoreFile: key,
    ),
    targetBundleName: bundleName,
    deviceUdid: deviceUdid,
  );

  if (report.profile != null) {
    final pf = report.profile!;
    print('  Profile  : bundle=${pf.bundleName} 类型=${pf.type} '
        '设备数=${pf.deviceIds.length} 到期=${pf.notAfter}');
  }
  if (deviceUdid != null) {
    print('  本机 UDID: ${deviceUdid.substring(0, deviceUdid.length.clamp(0, 16))}…');
  }
  for (final i in report.issues) {
    print('  ${_icon(i.severity)} ${i.code}: ${i.message}');
    if (i.hint != null) print('      → ${i.hint}');
  }
  if (!report.canProceed) {
    stderr.writeln('\n预检未通过，已阻止签名（这正是为了避免设备侧报 9568423/9568322）。');
    return 1;
  }
  print('  预检通过');
  print('');

  // ── 3. 签名 ──────────────────────────────────────────────────────
  print('── 3/5 签名 ──');
  final profileBytes = await File(profilePath).readAsBytes();
  final minApi = isQuietStart
      ? info!.mainMinApi
      : 12; // 普通包用保守值；原生签名器会按包内实际值处理

  SignResult result;
  if (isQuietStart) {
    result = await signHap(
      input: input,
      output: output,
      profileBytes: profileBytes,
      sign: (i, t, m) => _runSigner(signerPath, i, t, m, cert, profilePath, key),
      progress: (s) => print('  $s'),
    );
  } else {
    print('  单包直签');
    result = await signPlain(
      input: input,
      output: output,
      minimumApi: minApi,
      sign: (i, t, m) => _runSigner(signerPath, i, t, m, cert, profilePath, key),
    );
  }

  if (!result.succeeded) {
    stderr.writeln('签名失败：${result.message}');
    return 2;
  }
  final outFile = File(result.outputPath!);
  print('  产物: ${outFile.path} (${await _mb(outFile)} MB)');
  print('');

  // ── 4. 验签 ──────────────────────────────────────────────────────
  print('── 4/5 产物校验 ──');
  try {
    final signedProfile = await signedProfileOf(outFile);
    final matches = bytesEqual(signedProfile, profileBytes);
    print('  签名块 Profile 与本次材料一致: ${matches ? "是" : "否"}');
    if (!matches) {
      stderr.writeln('产物中的 Profile 与配置不符，拒绝继续。');
      return 2;
    }
  } catch (e) {
    stderr.writeln('产物缺少有效签名块：$e');
    return 2;
  }
  print('');

  // ── 5. 安装（可选）──────────────────────────────────────────────
  if (args.containsKey('install')) {
    print('── 5/5 安装到设备 ──');
    final hdc = args['hdc'];
    final target = args['target'] ?? await _detectTarget(hdc);
    if (hdc == null || target == null) {
      stderr.writeln('缺少 --hdc 或无法确定设备目标');
      return 3;
    }
    print('  设备: $target');
    final installer = HdcInstaller(hdcPath: hdc, target: target);
    final failure = await installer.install(outFile.path);
    if (failure != null) {
      stderr.writeln('安装失败：$failure');
      return 3;
    }
    print('  安装成功');
  } else {
    print('── 5/5 安装（已跳过，加 --install 启用）──');
  }

  print('');
  print('════════ 完成 ════════');
  return 0;
}

String bundleNameOf(Map<String, dynamic> moduleJson) =>
    ((moduleJson['app'] as Map?)?['bundleName'] as String?) ?? '';

dynamic _decodeJson(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes));

/// 用传统 switch 而非 Dart 3 的 switch 表达式，
/// 以便与鸿蒙 Flutter 工具链（Dart 2.19.6）兼容。
String _icon(Severity s) {
  switch (s) {
    case Severity.error:
      return '✗';
    case Severity.warning:
      return '!';
    case Severity.info:
      return 'i';
  }
  // ignore: dead_code
  return '?';
}

Future<String> _mb(File f) async {
  final n = await f.length();
  return (n / 1048576).toStringAsFixed(1);
}

/// 调用原生签名器（文件到文件）。
Future<void> _runSigner(
  String signerPath,
  File input,
  File target,
  int minimumApi,
  String cert,
  String profile,
  String key,
) async {
  final r = await Process.run(signerPath, [
    'sign-app',
    '-mode', 'localSign',
    '-keyAlias', 'xiaobai',
    '-appCertFile', cert,
    '-profileFile', profile,
    '-keystoreFile', key,
    '-keystorePwd', 'unused-for-unencrypted-pem',
    '-keyPwd', 'unused-for-unencrypted-pem',
    '-signAlg', 'SHA256withECDSA',
    '-compatibleVersion', '$minimumApi',
    '-signCode', '1',
    '-inFile', input.path,
    '-outFile', target.path,
  ]);
  if (r.exitCode != 0) {
    throw StateError('签名器退出码 ${r.exitCode}\n${r.stdout}\n${r.stderr}');
  }
  if (!await target.exists() || await target.length() < 1024) {
    throw StateError('签名器未产出有效文件');
  }
}

Future<String?> _detectUdid(Map<String, String> args) async {
  final hdc = args['hdc'];
  if (hdc == null) return null;
  final target = args['target'] ?? await _detectTarget(hdc);
  if (target == null) return null;
  return HdcInstaller(hdcPath: hdc, target: target).deviceUdid();
}

Future<String?> _detectTarget(String? hdc) async {
  if (hdc == null) return null;
  final r = await Process.run(hdc, ['list', 'targets']);
  final lines = r.stdout
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('[Empty]'))
      .toList();
  return lines.isEmpty ? null : lines.first;
}

Map<String, String>? _parseArgs(List<String> argv) {
  final out = <String, String>{};
  const valued = {
    'input', 'output', 'cert', 'profile', 'key', 'signer', 'hdc', 'target', 'udid'
  };
  const flags = {'install', 'help'};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) return null;
    final name = a.substring(2);
    if (flags.contains(name)) {
      out[name] = 'true';
      continue;
    }
    if (!valued.contains(name)) return null;
    if (i + 1 >= argv.length) return null;
    out[name] = argv[++i];
  }
  if (out.containsKey('help')) return null;
  for (final req in ['input', 'output', 'cert', 'profile', 'key', 'signer']) {
    if (!out.containsKey(req)) {
      stderr.writeln('缺少必需参数：--$req');
      return null;
    }
  }
  return out;
}

void _usage() {
  print('''
sign_cli —— 签名端到端验证

必需参数：
  --input   <path>   待签 HAP
  --output  <path>   产物路径
  --cert    <path>   证书链 (.cer)
  --profile <path>   设备授权 Profile (.p7b)
  --key     <path>   未加密私钥 PEM
  --signer  <path>   原生签名器可执行文件

可选参数：
  --install          签名后安装到设备
  --hdc     <path>   hdc 可执行文件
  --target  <id>     hdc 设备标识（省略则自动取第一个）
  --udid    <udid>   设备 UDID（省略则尝试经 hdc 读取）

退出码：0 成功 / 1 预检失败 / 2 签名失败 / 3 安装失败 / 64 参数错误
''');
}
