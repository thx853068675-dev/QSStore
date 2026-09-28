// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 文件区间流：把「文件的一段字节区间」当作 archive 库的 InputStreamBase。
//
// ── 为什么不直接用 InputFileStream ──────────────────────────────────────
// archive 库自带的 InputFileStream 在**定位到非零偏移**后读取会出错：
// 实测把一段 106381 字节的已压缩数据交给它，产物里变成了 106454 字节
// （多出 73 字节），而用内存 InputStream 包裹同样的字节则完全一致。
// 对未改动条目的「直通搬运」来说这是致命的 —— 会静默产出损坏的 ZIP。
//
// ── 为什么是同步实现 ────────────────────────────────────────────────────
// ZipEncoder.addFile 是**同步**消费内容的，InputStreamBase 的读取接口也都是
// 同步的。因此这里用 RandomAccessFile，避免为了迁就异步 API 而把整段
// 数据先读进内存（那正是我们要消除的内存瓶颈）。

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 按需读取文件中 `[start, start + length)` 区间的流。
///
/// 每次读取都直接走文件句柄，因此内存占用与区间大小无关。
class FileRangeStream extends InputStreamBase {
  FileRangeStream({
    required RandomAccessFile file,
    required int start,
    required int length,
    this.name = '',
    bool ownsFile = false,
  })  : _file = file,
        _start = start,
        _length = length,
        _ownsFile = ownsFile;

  final RandomAccessFile _file;
  final int _start;
  final int _length;
  final bool _ownsFile;

  /// 便于诊断的可读标识（条目名）。
  final String name;

  int _position = 0;
  bool _closed = false;

  int get start => _start;
  int get rangeLength => _length;

  @override
  int get position => _position;

  @override
  set position(int v) {
    if (v < 0 || v > _length) {
      throw RangeError.range(v, 0, _length, 'position',
          '区间流定位越界（$name）');
    }
    _position = v;
  }

  @override
  int get length => _length - _position;

  @override
  bool get isEOS => _position >= _length;

  @override
  void reset() => _position = 0;

  @override
  void rewind([int length = 1]) => position = _position - length;

  @override
  void skip(int length) => position = _position + length;

  @override
  int readByte() {
    if (isEOS) throw StateError('区间流已到末尾（$name）');
    final bytes = _read(_position, 1);
    _position += 1;
    return bytes[0];
  }

  @override
  InputStreamBase readBytes(int count) {
    if (count < 0) throw RangeError.value(count, 'count');
    final available = _length - _position;
    final n = count > available ? available : count;
    final bytes = _read(_position, n);
    _position += n;
    return InputStream(bytes);
  }

  @override
  InputStreamBase peekBytes(int count, [int offset = 0]) {
    final at = _position + offset;
    final available = _length - at;
    final n = count > available ? available : count;
    return InputStream(_read(at, n));
  }

  @override
  InputStreamBase subset([int? position, int? length]) {
    final at = (position ?? _position).clamp(0, _length);
    final n = ((length ?? _length - at)).clamp(0, _length - at);
    return FileRangeStream(
      file: _file,
      start: _start + at,
      length: n,
      name: name,
    );
  }

  @override
  Uint8List toUint8List([Uint8List? bytes]) => _read(0, _length);

  @override
  int readUint16() {
    final b = _read(_position, 2);
    _position += 2;
    return b[0] | (b[1] << 8);
  }

  @override
  int readUint24() {
    final b = _read(_position, 3);
    _position += 3;
    return b[0] | (b[1] << 8) | (b[2] << 16);
  }

  @override
  int readUint32() {
    final b = _read(_position, 4);
    _position += 4;
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }

  @override
  int readUint64() {
    final lo = readUint32();
    final hi = readUint32();
    return lo + (hi << 32);
  }

  @override
  String readString({int? size, bool utf8 = true}) {
    if (size != null) {
      final b = _read(_position, size);
      _position += size;
      return utf8
          ? String.fromCharCodes(b)
          : String.fromCharCodes(b);
    }
    // 读取到 NUL 结尾。
    final out = <int>[];
    while (!isEOS) {
      final c = readByte();
      if (c == 0) break;
      out.add(c);
    }
    return String.fromCharCodes(out);
  }

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() {
    if (_closed) return;
    _closed = true;
    // 默认不关闭共享的文件句柄：HapReader 仍需要它读取其它条目。
    if (_ownsFile) _file.closeSync();
  }

  Uint8List _read(int offsetInRange, int count) {
    if (count == 0) return Uint8List(0);
    _file.setPositionSync(_start + offsetInRange);
    final bytes = _file.readSync(count);
    if (bytes.length != count) {
      throw StateError(
          '文件区间读取不足（$name）：期望 $count 字节，实际 ${bytes.length}');
    }
    return bytes;
  }
}
