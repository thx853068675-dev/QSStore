import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('mn-');
  final rnd = Random(11);
  final data = List<int>.generate(256 * 1024, (_) => rnd.nextInt(6));

  // 源：只有这一个条目，避免任何其它条目的干扰
  final arch = Archive()..addFile(ArchiveFile('d.bin', data.length, data)..compress = true);
  final srcPath = '${dir.path}/s.zip';
  File(srcPath).writeAsBytesSync(ZipEncoder().encode(arch)!);

  // 用 ZipDecoder 拿 rawContent
  final f0 = ZipDecoder().decodeBytes(File(srcPath).readAsBytesSync()).files.first;
  final raw = f0.rawContent!.toUint8List();
  print('源 rawContent: ${raw.length} 字节, 前8=${raw.sublist(0,8)}');

  // 目标：单条目，InputStream 包裹 rawContent
  final outPath = '${dir.path}/o1.zip';
  final enc = ZipFileEncoder();
  enc.create(outPath);
  enc.addArchiveFile(ArchiveFile('d.bin', f0.size, InputStream(raw), ArchiveFile.DEFLATE)
    ..compress = true ..crc32 = f0.crc32);
  enc.close();
  final out1 = ZipDecoder().decodeBytes(File(outPath).readAsBytesSync()).files.first;
  final raw1 = out1.rawContent!.toUint8List();
  print('产物1 rawContent: ${raw1.length} 字节  与源相同=${_eq(raw, raw1)}');

  // 目标2：InputFileStream 定位（模拟我的代码）
  final outPath2 = '${dir.path}/o2.zip';
  final enc2 = ZipFileEncoder();
  enc2.create(outPath2);
  final fs = InputFileStream(srcPath);
  // d.bin 的数据区偏移 = 本地头30 + 名5 + extra0 = 35
  fs.position = 35;
  enc2.addArchiveFile(ArchiveFile('d.bin', f0.size, fs, ArchiveFile.DEFLATE)
    ..compress = true ..crc32 = f0.crc32);
  fs.close();
  enc2.close();
  final out2 = ZipDecoder().decodeBytes(File(outPath2).readAsBytesSync()).files.first;
  final raw2 = out2.rawContent!.toUint8List();
  print('产物2 rawContent: ${raw2.length} 字节  与源相同=${_eq(raw, raw2)}');
  if (!_eq(raw, raw2)) { print('  源前8=${raw.sublist(0,8)}  产物2前8=${raw2.sublist(0,8)}'); }

  dir.deleteSync(recursive: true);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
  return true;
}
