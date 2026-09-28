import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

/// 返回 'OK' 或错误描述
String tryCombo(String label, ArchiveFile Function() make, {String? expect}) {
  final enc = ZipFileEncoder();
  final path = '/tmp/combo_$label.zip';
  enc.create(path);
  // 加一个对照条目，确保多条目场景
  enc.addArchiveFile(ArchiveFile('ctrl.txt', 5, utf8.encode('hello'))..compress = true);
  enc.addArchiveFile(make());
  enc.close();
  try {
    final back = ZipDecoder().decodeBytes(File(path).readAsBytesSync(), verify: true);
    final f = back.files.firstWhere((x) => x.name == 'target.bin');
    final c = f.content as List<int>;
    if (expect != null && String.fromCharCodes(c) != expect) {
      return '内容错: ${String.fromCharCodes(c)}';
    }
    return 'OK (len=${c.length})';
  } catch (e) {
    return '失败: $e';
  }
}

void main() {
  final content = utf8.encode('{"b":2}');
  print('替换路径候选：');
  print('  [3参+compress]        ${tryCombo("a", () => ArchiveFile('target.bin', content.length, content)..compress = true, expect: '{"b":2}')}');
  print('  [4参DEFLATE+compress] ${tryCombo("b", () => ArchiveFile('target.bin', content.length, content, ArchiveFile.DEFLATE)..compress = true, expect: '{"b":2}')}');
  print('  [3参+noCompress]      ${tryCombo("c", () => ArchiveFile.noCompress('target.bin', content.length, content), expect: '{"b":2}')}');

  // 直通路径：把已压缩字节以流喂入
  print('');
  print('直通路径候选（内容为已 DEFLATE 的字节）：');
  final rnd = Random(3);
  final big = List<int>.generate(200000, (_) => rnd.nextInt(256));
  final srcArch = Archive()..addFile(ArchiveFile('x.bin', big.length, big)..compress = true);
  final srcBytes = ZipEncoder().encode(srcArch)!;
  File('/tmp/ps_src.zip').writeAsBytesSync(srcBytes);
  final dec = ZipDecoder().decodeBytes(srcBytes, verify: true).files.first;
  final rawList = dec.rawContent!.toUint8List();
  final isDeflate = dec.compressionType == ArchiveFile.DEFLATE;
  print('  源条目 compress=${dec.compress} type=${dec.compressionType} usize=${dec.size}');
  if (!isDeflate) {
    print('  (随机数据被降级为 STORE，直通 DEFLATE 路径不适用)');
  } else {
    print('  [4参DEFLATE+stream]   ${tryCombo("d", () => ArchiveFile('target.bin', dec.size, InputStream(rawList), ArchiveFile.DEFLATE)..compress = true ..crc32 = dec.crc32)}');
  }
}
