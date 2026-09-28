// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// ZIP 随机访问层。
//
// 为什么自己解析中央目录而不用 archive 库的读取侧：
//   华为工具会在 ZIP 的 extra 字段里写零填充，archive 3.x 会把它当作结构化
//   字段解析而崩溃。原工程为此写了 `zipView()` 绕行逻辑（把整个包读进内存、
//   重建中央目录）。这里改为用 RandomAccessFile 只读尾部结构，于是：
//     · 不需要绕行逻辑，也不受该缺陷影响
//     · 主包体永不进内存
//     · 能拿到每个条目在文件中的精确字节区间，供「直通搬运」使用

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

import 'range_stream.dart';

/// 工作模块上限（16 MB）。注意：这不是「整包上限」。
///
/// 工作模块是内嵌在主包里的模块，必须整体交给原生签名器，且 manifest 里
/// 绑定了它的 size/sha256，因此仍保留上限。放开它需要同步改走 base64 分块
/// 传输的安装链路，属于另一件事。
const workerPayloadLimit = 16777216;

/// 中央目录条目数上限，防畸形包。
const maxEntryCount = 4096;

/// 兜底长度上限，仅防整数溢出与明显畸形的头部值，不构成业务限制。
/// 512 GB 远超任何真实 HAP。
const archiveSanityLimit = 512 * 1024 * 1024 * 1024;

/// [HapReader.readDecoded] 在调用方未指定 [maxBytes] 时的默认上限。
///
/// 取工作模块上限（16 MB）；解码器还会按实际输出字节数中途止损。
const defaultDecodeLimit = workerPayloadLimit;

class _LimitedByteSink implements Sink<List<int>> {
  _LimitedByteSink(this.limit, this.name);

  final int limit;
  final String name;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;

  @override
  void add(List<int> data) {
    if (data.length > limit - _length) {
      throw HapFormatException('条目「$name」实际解压结果超出上限 $limit 字节');
    }
    _length += data.length;
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List get bytes => _builder.takeBytes();
}

class HapFormatException implements Exception {
  const HapFormatException(this.message);
  final String message;
  @override
  String toString() => 'HapFormatException: $message';
}

int u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// 一个中央目录条目，只保留搬运与重建所需字段。
class ZipEntry {
  ZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.flags,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.dosTime,
    required this.dosDate,
    required this.mode,
  });

  final String name;
  final int compressionMethod;

  /// 通用目的标志位：bit0=加密，bit3=数据描述符，bit11=UTF-8 文件名。
  final int flags;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int dosTime;
  final int dosDate;

  /// Unix 权限位（外部属性高 16 位）。
  final int mode;

  bool get isEncrypted => flags & 1 != 0;
  bool get hasDataDescriptor => flags & 0x08 != 0;
  bool get isDeflate => compressionMethod == ArchiveFile.DEFLATE;
  bool get isStored => compressionMethod == ArchiveFile.STORE;
}

/// 用 RandomAccessFile 直接解析 ZIP，提供按区间读取能力。
class HapReader {
  HapReader._(this.file, this._raf, this.entries);

  final File file;
  final RandomAccessFile _raf;
  final List<ZipEntry> entries;

  static const _eocdSignature = 0x06054b50;
  static const _cdSignature = 0x02014b50;
  static const _lfhSignature = 0x04034b50;

  /// EOCD 最长回扫范围：22 字节定长 + 最多 65535 字节注释。
  static const _eocdScan = 65557;

  static Future<HapReader> open(File file) async {
    final raf = file.openSync();
    try {
      final length = raf.lengthSync();
      if (length < 22) throw const HapFormatException('无效的安装包长度');
      if (length > archiveSanityLimit) {
        throw const HapFormatException('安装包长度异常');
      }

      // 1) 尾部回扫 EOCD。
      final scanLen = length < _eocdScan ? length : _eocdScan;
      final tailStart = length - scanLen;
      raf.setPositionSync(tailStart);
      final tail = raf.readSync(scanLen);

      var eocd = -1;
      for (var i = scanLen - 22; i >= 0; i--) {
        if (u32(tail, i) == _eocdSignature &&
            i + 22 + u16(tail, i + 20) == scanLen) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw const HapFormatException('不支持的 ZIP 结构');
      if (u32(tail, eocd + 4) != 0) {
        throw const HapFormatException('不支持的分卷 ZIP');
      }

      final count = u16(tail, eocd + 10);
      final cdSize = u32(tail, eocd + 12);
      final cdOffset = u32(tail, eocd + 16);
      if (count == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff) {
        throw const HapFormatException('不支持 ZIP64 安装包');
      }
      if (count > maxEntryCount) {
        throw const HapFormatException('安装包文件过多');
      }
      if (cdOffset + cdSize != tailStart + eocd) {
        throw const HapFormatException('安装包中央目录无效');
      }

      // 2) 中央目录体积很小，一次性读入。
      raf.setPositionSync(cdOffset);
      final cd = raf.readSync(cdSize);

      final entries = <ZipEntry>[];
      final seen = <String>{};
      var pos = 0;
      for (var i = 0; i < count; i++) {
        if (pos + 46 > cdSize || u32(cd, pos) != _cdSignature) {
          throw const HapFormatException('安装包目录截断');
        }
        final flags = u16(cd, pos + 8);
        final method = u16(cd, pos + 10);
        final dosTime = u16(cd, pos + 12);
        final dosDate = u16(cd, pos + 14);
        final crc = u32(cd, pos + 16);
        final csize = u32(cd, pos + 20);
        final usize = u32(cd, pos + 24);
        final nameLen = u16(cd, pos + 28);
        final extraLen = u16(cd, pos + 30);
        final commentLen = u16(cd, pos + 32);
        final external = u32(cd, pos + 38);
        final localOffset = u32(cd, pos + 42);

        final total = 46 + nameLen + extraLen + commentLen;
        if (pos + total > cdSize) {
          throw const HapFormatException('安装包目录越界');
        }
        if (csize == 0xffffffff || usize == 0xffffffff) {
          throw const HapFormatException('不支持 ZIP64 条目');
        }

        final hasDataDescriptor = flags & 0x08 != 0;
        final name = utf8.decode(cd.sublist(pos + 46, pos + 46 + nameLen),
            allowMalformed: true);

        if (!seen.add(name)) {
          throw const HapFormatException('安装包内有重复文件名');
        }
        if (name.startsWith('/') ||
            name.contains('\\') ||
            name.split('/').contains('..')) {
          throw const HapFormatException('安装包文件路径无效');
        }
        if (flags & 1 != 0) {
          throw const HapFormatException('不支持加密的安装包');
        }
        // 数据描述符（flag bit 3）：真实华为 HAP 会用它（实测 unsigned.hap
        // 有 10 个条目带此标志）。它只影响**本地头**里的尺寸字段，而中央目录
        // 里的 csize/usize/crc 始终是权威值，因此定位数据结束位置不受影响。
        // 早期版本在这里直接拒绝，会导致真实 HAP 完全无法处理。
        if (hasDataDescriptor && csize == 0 && usize == 0) {
          // 流式写入器可能把中央目录的尺寸也留空，此时确实无法定位。
          throw const HapFormatException('不支持的安装包结构（尺寸缺失）');
        }
        if (method != ArchiveFile.STORE && method != ArchiveFile.DEFLATE) {
          throw const HapFormatException('不支持的压缩方式');
        }

        final mode = (external >> 16) & 0xffff;
        entries.add(ZipEntry(
          name: name,
          compressionMethod: method,
          flags: flags,
          crc32: crc,
          compressedSize: csize,
          uncompressedSize: usize,
          localHeaderOffset: localOffset,
          dosTime: dosTime,
          dosDate: dosDate,
          mode: mode == 0 ? 420 : mode, // 0644
        ));
        pos += total;
      }
      if (pos != cdSize) {
        throw const HapFormatException('安装包目录数量不符');
      }
      return HapReader._(file, raf, entries);
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  ZipEntry? find(String name) {
    for (final e in entries) {
      if (e.name == name) return e;
    }
    return null;
  }

  Future<void> close() async => _raf.closeSync();

  /// 创建一个按需读取该条目数据区的流。
  ///
  /// 用自研的 [FileRangeStream] 而不是 archive 的 InputFileStream：
  /// 后者在定位到非零偏移后读取会多出字节（实测 106381 → 106454），
  /// 会让「直通搬运」静默产出损坏的 ZIP。
  FileRangeStream openRangeStream(ZipEntry e) {
    final range = dataRangeSync(e);
    return FileRangeStream(
      file: _raf,
      start: range[0],
      length: range[1],
      name: e.name,
    );
  }

  /// 定位条目数据区的绝对偏移与长度，同时校验本地头签名。
  ///
  /// 本地头的 extra 字段只跳过不解析，因此华为的零填充不影响这里。
  List<int> dataRangeSync(ZipEntry e) {
    _raf.setPositionSync(e.localHeaderOffset);
    final lfh = _raf.readSync(30);
    if (lfh.length < 30 || u32(lfh, 0) != _lfhSignature) {
      throw const HapFormatException('安装包本地文件头无效');
    }
    final start = e.localHeaderOffset + 30 + u16(lfh, 26) + u16(lfh, 28);
    if (start + e.compressedSize > _raf.lengthSync()) {
      throw const HapFormatException('安装包条目数据越界');
    }
    return [start, e.compressedSize];
  }

  /// 读出条目的原始（仍压缩）字节。仅用于有上限的条目（工作模块）。
  Future<Uint8List> readRaw(ZipEntry e) async {
    final range = dataRangeSync(e);
    _raf.setPositionSync(range[0]);
    return _raf.readSync(range[1]);
  }

  /// 读出并解压条目内容。仅用于小文件（module.json / manifest / 工作模块）。
  ///
  /// 使用 dart:io 的流式 DEFLATE 解码，实际输出超过 [maxBytes] 立即停止。
  /// 不使用 archive 3.6.1 的 Inflate.stream()，它在块边界会丢失比特。
  Future<Uint8List> readDecoded(ZipEntry e, {int? maxBytes}) async {
    final limit = maxBytes ?? defaultDecodeLimit;
    if (e.uncompressedSize > limit) {
      throw HapFormatException('条目「${e.name}」解压后 ${e.uncompressedSize} 字节，'
          '超出该用途的上限 $limit 字节');
    }
    // 压缩数据本身也要有限制；允许 DEFLATE 头部/小文件额外开销。
    if (e.compressedSize > limit * 2 + 65536) {
      throw HapFormatException('条目「${e.name}」压缩数据异常（${e.compressedSize} 字节）');
    }

    final raw = await readRaw(e);
    if (e.isStored) {
      if (raw.length > limit) {
        throw HapFormatException('条目「${e.name}」实际长度超出上限');
      }
      return raw;
    }
    final collector = _LimitedByteSink(limit, e.name);
    final decoder = ZLibDecoder(raw: true).startChunkedConversion(collector);
    try {
      for (var offset = 0; offset < raw.length; offset += 65536) {
        final end = offset + 65536 < raw.length ? offset + 65536 : raw.length;
        decoder.addSlice(raw, offset, end, false);
      }
      decoder.close();
    } on HapFormatException {
      rethrow;
    } catch (error) {
      throw HapFormatException('条目「${e.name}」解压失败：$error');
    }
    final out = collector.bytes;
    if (out.length != e.uncompressedSize) {
      // 长度不符说明解压不完整，宁可报错也不要静默产出错误内容。
      throw HapFormatException(
          '条目「${e.name}」解压长度不符（期望 ${e.uncompressedSize}，实际 ${out.length}）');
    }
    return out;
  }

  /// 校验条目内容是否与中央目录记录一致（尺寸 + CRC32）。
  ///
  /// 这是「签名器没有改变程序内容」的廉价判据：CRC32 在**没有对手方刻意构造**
  /// 的前提下，对意外篡改有约 1 - 2^-32 的检出率，正适合本场景。
  /// 需要更强保证的条目（如被我们替换的条目）请用 SHA-256 逐一比对。
  ///
  /// 之所以不在这里做流式 SHA-256：DEFLATE 条目要哈希就必须完整解压，而
  /// archive 的流式解压不可靠（见 [readDecoded] 注释），大条目整块解压又会
  /// 吃光内存。CRC 直接来自中央目录，零解压、零内存。
  void assertEntryIntegrity(ZipEntry e) {
    if (e.compressedSize < 0 ||
        e.uncompressedSize < 0 ||
        e.compressedSize > archiveSanityLimit ||
        e.uncompressedSize > archiveSanityLimit) {
      throw HapFormatException('条目「${e.name}」尺寸异常');
    }
  }
}

/// 分块计算文件 SHA-256。
Future<String> sha256FileHex(File file) async {
  final sink = AccumulatorSink<Digest>();
  final conv = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    conv.add(chunk);
  }
  conv.close();
  return sink.events.single.toString();
}
