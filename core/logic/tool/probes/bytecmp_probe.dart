import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:signing_core/signing_core.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('bc-');
  final rnd = Random(11);
  final data = List<int>.generate(256 * 1024, (_) => rnd.nextInt(6));
  final arch = Archive();
  arch.addFile(ArchiveFile('module.json', 10, utf8.encode('{"a":1}'))..compress = true);
  arch.addFile(ArchiveFile('res/deflatable.bin', data.length, data)..compress = true);
  final src = File('${dir.path}/src.hap');
  src.writeAsBytesSync(ZipEncoder().encode(arch)!);

  final r = await HapReader.open(src);
  final e = r.find('res/deflatable.bin')!;
  final srcRange = r.dataRangeSync(e);
  final srcRaw = await r.readRaw(e);
  print('源: method=${e.compressionMethod} csize=${e.compressedSize} usize=${e.uncompressedSize}');
  print('  前 16 字节: ${srcRaw.sublist(0, 16)}');

  final target = File('${dir.path}/out.hap');
  await streamRepack(source: r, target: target, replacements: {
    'module.json': Uint8List.fromList(utf8.encode('{"b":2}')),
  });
  await r.close();

  final ro = await HapReader.open(target);
  final eo = ro.find('res/deflatable.bin')!;
  final outRaw = await ro.readRaw(eo);
  print('产物: method=${eo.compressionMethod} csize=${eo.compressedSize} usize=${eo.uncompressedSize}');
  print('  前 16 字节: ${outRaw.sublist(0, 16)}');

  var same = srcRaw.length == outRaw.length;
  if (same) {
    for (var i = 0; i < srcRaw.length; i++) {
      if (srcRaw[i] != outRaw[i]) { same = false; print('  首个差异位置: $i'); break; }
    }
  }
  print('原始压缩字节完全相同: $same');
  print('  srcRange=${srcRange}');
  await ro.close();
  dir.deleteSync(recursive: true);
}
