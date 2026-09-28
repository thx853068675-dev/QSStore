import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:signing_core/signing_core.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('rp-');
  final rnd = Random(42);
  final big = List<int>.generate(300000, (_) => rnd.nextInt(4));
  final arch = Archive();
  arch.addFile(ArchiveFile('module.json', 10, utf8.encode('{"a":1}'))..compress = true);
  arch.addFile(ArchiveFile('resources/large.bin', big.length, big)..compress = true);
  final src = File('${dir.path}/src.hap');
  src.writeAsBytesSync(ZipEncoder().encode(arch)!);

  final r = await HapReader.open(src);
  print('源条目:');
  for (final e in r.entries) {
    print('  ${e.name}: method=${e.compressionMethod} '
          'csize=${e.compressedSize} usize=${e.uncompressedSize} crc=${e.crc32}');
  }
  final target = File('${dir.path}/out.hap');
  await streamRepack(source: r, target: target, replacements: {
    'module.json': Uint8List.fromList(utf8.encode('{"b":2}')),
  });
  await r.close();

  print('产物条目:');
  final ro = await HapReader.open(target);
  for (final e in ro.entries) {
    print('  ${e.name}: method=${e.compressionMethod} '
          'csize=${e.compressedSize} usize=${e.uncompressedSize} crc=${e.crc32}');
  }
  print('读回全部条目...');
  for (final e in ro.entries) {
    try {
      final d = await ro.readDecoded(e);
      print('  ${e.name} -> ${d.length} 字节 OK');
    } catch (err) {
      print('  ${e.name} -> 失败: $err');
    }
  }
  await ro.close();
  dir.deleteSync(recursive: true);
}
