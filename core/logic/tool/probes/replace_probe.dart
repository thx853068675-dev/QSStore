import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void main() {
  final content = utf8.encode('{"b":2}');
  print('content=$content len=${content.length}');

  for (final variant in ['plain', 'withMeta', 'noCrc']) {
    final path = '/tmp/replace_$variant.zip';
    final enc = ZipFileEncoder();
    enc.create(path);
    // 一个已知良好的对照条目
    enc.addArchiveFile(ArchiveFile('keep.txt', 5, utf8.encode('hello'))
      ..compress = true);

    final af = ArchiveFile('module.json', content.length, content, ArchiveFile.DEFLATE)
      ..compress = true;
    if (variant != 'noCrc') af.crc32 = getCrc32(content);
    if (variant == 'withMeta') {
      af.mode = 420;
      af.lastModTime = 1700000000;
    }
    enc.addArchiveFile(af);
    enc.close();

    final bytes = File(path).readAsBytesSync();
    try {
      final a = ZipDecoder().decodeBytes(bytes, verify: true);
      for (final f in a.files) {
        final c = f.content as List<int>;
        print('  [$variant] ${f.name}: len=${c.length} '
              '${f.name == 'module.json' ? (String.fromCharCodes(c) == '{"b":2}' ? "内容OK" : "内容错: ${String.fromCharCodes(c)}") : ""}');
      }
    } catch (e) {
      print('  [$variant] 解码失败: $e');
    }
  }
}
