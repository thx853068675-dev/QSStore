import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';

void main() {
  final rnd = Random(7);
  // 低熵大数组，确保 deflate 输出多块
  final data = Uint8List.fromList(
      List<int>.generate(8 * 1024 * 1024, (_) => rnd.nextInt(4)));
  final deflated = Uint8List.fromList(Deflate(data).getBytes());
  print('原始: ${data.length}  压缩后: ${deflated.length}');

  // 参考：整块解压
  final whole = Uint8List.fromList(Inflate(deflated).getBytes());
  print('整块解压长度: ${whole.length}  一致: ${_eq(whole, data)}');

  // 分块喂入
  final inf = Inflate.stream();
  final out = BytesBuilder();
  const chunk = 65536;
  var off = 0;
  while (off < deflated.length) {
    final end = (off + chunk) > deflated.length ? deflated.length : off + chunk;
    inf.streamInput(deflated.sublist(off, end));
    var calls = 0;
    while (true) {
      final part = inf.inflateNext();
      if (part == null) break;
      if (part.isNotEmpty) out.add(part);
      calls++;
      if (calls > 1000000) { print('!! inflateNext 未收敛'); break; }
    }
    off = end;
  }
  final tail = inf.getBytes();
  if (tail.isNotEmpty) out.add(tail);
  final chunked = out.takeBytes();
  print('分块解压长度: ${chunked.length}  一致: ${_eq(chunked, data)}');
  if (chunked.length != data.length) {
    print('  长度差: ${data.length - chunked.length}');
    for (var i = 0; i < data.length && i < chunked.length; i++) {
      if (data[i] != chunked[i]) { print('  首个差异位置: $i'); break; }
    }
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
  return true;
}
