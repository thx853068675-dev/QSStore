import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('pt-');
  final rnd = Random(1);
  final data = List<int>.generate(200000, (_) => rnd.nextInt(256));

  final src = Archive()
    ..addFile(ArchiveFile('big.bin', data.length, data)..compress = true);
  final srcBytes = ZipEncoder().encode(src)!;
  final srcPath = '${dir.path}/src.zip';
  File(srcPath).writeAsBytesSync(srcBytes);

  // 用我们自己的解析器拿原始区间（等价于 HapReader 的职责）
  final raf = File(srcPath).openSync();
  // 简化：用 ZipDecoder 拿 rawContent
  final arch = ZipDecoder().decodeBytes(srcBytes, verify: true);
  final f = arch.files.first;
  final rawContent = f.rawContent;
  print('源: compress=${f.compress} type=${f.compressionType} '
        'usize=${f.size} crc=${f.crc32} rawType=${rawContent.runtimeType}');

  // 直通：把 rawContent（仍压缩）作为流喂入，compressionType 显式 DEFLATE
  final outPath = '${dir.path}/out.zip';
  final enc = ZipFileEncoder();
  enc.create(outPath);

  final rc = rawContent!;
  final stream = InputStream(rc.toUint8List());
  final af = ArchiveFile('big.bin', f.size, stream, ArchiveFile.DEFLATE)
    ..compress = true
    ..crc32 = f.crc32;
  enc.addArchiveFile(af);
  enc.close();

  final outBytes = File(outPath).readAsBytesSync();
  print('输出大小: ${outBytes.length}  (源: ${srcBytes.length})');
  try {
    final back = ZipDecoder().decodeBytes(outBytes, verify: true);
    final b = back.files.first;
    final content = b.content as List<int>;
    var ok = content.length == data.length;
    if (ok) {
      for (var i = 0; i < data.length; i++) {
        if (content[i] != data[i]) { ok = false; print('首个差异: $i'); break; }
      }
    }
    print('内容一致: $ok   长度=${content.length}/${data.length}');
  } catch (err) {
    print('读回失败: $err');
  }
  raf.closeSync();
  dir.deleteSync(recursive: true);
}
