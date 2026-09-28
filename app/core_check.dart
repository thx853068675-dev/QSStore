import 'dart:io';
import 'dart:convert';
import 'package:signing_core/signing_core.dart';

Future<void> main(List<String> args) async {
  final f = File(args[0]);
  print('  文件: ${f.path.split('/').last}');
  print('  大小: ${(await f.length() / 1048576).toStringAsFixed(1)} MB');
  try {
    final profile = await signedProfileOf(f);
    print('  ✅ 签名块有效，Profile 长度 ${profile.length} 字节');
    // 解析 Profile 关键字段
    final report = await inspectProfile(profile);
    print('     bundleName : ${report.bundleName}');
    print('     类型       : ${report.type}');
    print('     授权设备数 : ${report.deviceIds.length}');
    print('     到期       : ${report.notAfter}');
  } on HapFormatException catch (e) {
    print('  ✗ 无有效签名块: ${e.message}');
  }
}
