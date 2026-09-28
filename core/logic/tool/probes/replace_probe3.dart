import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void run(String label, List<ArchiveFile> Function() build) {
  final enc = ZipFileEncoder();
  final path = '/tmp/multi_$label.zip';
  enc.create(path);
  for (final f in build()) { enc.addArchiveFile(f); }
  enc.close();
  final bytes = File(path).readAsBytesSync();
  try {
    final back = ZipDecoder().decodeBytes(bytes, verify: true);
    final out = back.files.map((f) {
      final c = f.content as List<int>;
      return '${f.name}=${c.length}';
    }).join(', ');
    print('  [$label] OK  $out');
  } catch (e) {
    print('  [$label] 失败: $e');
  }
}

void main() {
  final content = utf8.encode('{"b":2}');
  final keep = utf8.encode('hello');

  run('keep-mod', () => [
    ArchiveFile('keep.txt', keep.length, keep)..compress = true,
    ArchiveFile('module.json', content.length, content)..compress = true,
  ]);
  run('mod-keep', () => [
    ArchiveFile('module.json', content.length, content)..compress = true,
    ArchiveFile('keep.txt', keep.length, keep)..compress = true,
  ]);
  run('keep-mod-crc', () => [
    ArchiveFile('keep.txt', keep.length, keep)..compress = true,
    ArchiveFile('module.json', content.length, content)
      ..compress = true ..crc32 = getCrc32(content),
  ]);
  run('explicit-type', () => [
    ArchiveFile('keep.txt', keep.length, keep, ArchiveFile.DEFLATE)..compress = true,
    ArchiveFile('module.json', content.length, content, ArchiveFile.DEFLATE)..compress = true,
  ]);
  run('three', () => [
    ArchiveFile('a.txt', keep.length, keep)..compress = true,
    ArchiveFile('b.txt', keep.length, keep)..compress = true,
    ArchiveFile('module.json', content.length, content)..compress = true,
  ]);
}
