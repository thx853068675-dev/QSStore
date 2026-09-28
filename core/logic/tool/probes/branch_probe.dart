import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('br-');
  final rnd = Random(11);
  final data = List<int>.generate(256 * 1024, (_) => rnd.nextInt(6));
  final src = Archive()..addFile(ArchiveFile('d.bin', data.length, data)..compress = true);
  File('${dir.path}/s.zip').writeAsBytesSync(ZipEncoder().encode(src)!);

  // 用 ZipDecoder 拿一个真实的「已压缩内容」
  final dec = ZipDecoder().decodeBytes(File('${dir.path}/s.zip').readAsBytesSync());
  final f0 = dec.files.first;
  print('源: compress=${f0.compress} type=${f0.compressionType} '
        'isCompressed=${f0.isCompressed} rawType=${f0.rawContent.runtimeType}');

  // 模拟我的代码：InputFileStream 定位到数据区
  final stream = InputFileStream('${dir.path}/s.zip');
  stream.position = 0; // 位置不对也没关系，这里只看分支判定

  final af = ArchiveFile('d.bin', f0.size, stream, ArchiveFile.DEFLATE)
    ..compress = true
    ..crc32 = f0.crc32;

  print('构造后: compress=${af.compress} type=${af.compressionType} '
        'isCompressed=${af.isCompressed} rawNull=${af.rawContent == null} '
        'rawType=${af.rawContent.runtimeType}');
  print('  isFile=${af.isFile}');

  // 判定会走哪条分支
  final branch = !af.compress
      ? 'A(!compress → 解压+STORE)'
      : (af.isCompressed && af.compressionType == ArchiveFile.DEFLATE && af.rawContent != null)
          ? 'B(DEFLATE 直通)'
          : af.isFile
              ? 'C(isFile → 重新压缩)'
              : 'D(无分支命中 → compressedData=null)';
  print('  预期分支: $branch');
  dir.deleteSync(recursive: true);
}
