import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void main() {
  final content = utf8.encode('{"b":2}');
  final orig = utf8.encode('{"a":1}');

  // A: 纯 ZipEncoder + ArchiveFile（原工程 repack() 的写法）
  {
    final a = Archive();
    a.addFile(ArchiveFile('keep.txt', 5, utf8.encode('hello'))..compress = true);
    a.addFile(ArchiveFile('module.json', content.length, content)
      ..mode = 420 ..compress = true ..lastModTime = 1700000000);
    final bytes = ZipEncoder().encode(a)!;
    File('/tmp/rep_A.zip').writeAsBytesSync(bytes);
    try {
      final back = ZipDecoder().decodeBytes(bytes, verify: true);
      final m = back.files.firstWhere((f) => f.name == 'module.json');
      print('  [A ZipEncoder] module.json = ${String.fromCharCodes(m.content as List<int>)}');
    } catch (e) {
      print('  [A ZipEncoder] 失败: $e');
    }
  }

  // B: ZipEncoder + 显式 crc32
  {
    final a = Archive();
    a.addFile(ArchiveFile('module.json', content.length, content)
      ..compress = true ..crc32 = getCrc32(content));
    final bytes = ZipEncoder().encode(a)!;
    File('/tmp/rep_B.zip').writeAsBytesSync(bytes);
    try {
      final back = ZipDecoder().decodeBytes(bytes, verify: true);
      final m = back.files.firstWhere((f) => f.name == 'module.json');
      print('  [B 显式crc] module.json = ${String.fromCharCodes(m.content as List<int>)}');
    } catch (e) {
      print('  [B 显式crc] 失败: $e');
    }
  }

  // C: ZipFileEncoder.addArchiveFile（我用的写法）
  {
    final enc = ZipFileEncoder();
    enc.create('/tmp/rep_C.zip');
    enc.addArchiveFile(ArchiveFile('module.json', content.length, content)
      ..compress = true);
    enc.close();
    final bytes = File('/tmp/rep_C.zip').readAsBytesSync();
    try {
      final back = ZipDecoder().decodeBytes(bytes, verify: true);
      final m = back.files.firstWhere((f) => f.name == 'module.json');
      print('  [C ZipFileEncoder] module.json = ${String.fromCharCodes(m.content as List<int>)}');
    } catch (e) {
      print('  [C ZipFileEncoder] 失败: $e');
    }
  }
}
