// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 流式重打包：把主 HAP 里少数条目替换掉，其余条目「直通搬运」。
//
// ── 为什么不能简单地重新压缩每个条目 ──────────────────────────────────
// 一个 HAP 里绝大部分字节是 dex / so / 资源，本来就已经是压缩态。若把它们
// 解压再压缩一遍：CPU 白烧，而且**内容会变**（不同 zlib 实现的压缩字节流不
// 完全相同）。虽然解压后的内容一致，但那样会让「载荷未变」的校验失去意义，
// 也白白增加失败面。
//
// ── 直通搬运是怎么做到的 ──────────────────────────────────────────────
// archive 库的 ZipEncoder.addFile 有两个分支值得注意（3.6.1 实测）：
//
//   1) `file.compress == true && file.compressionType == DEFLATE`
//      → 直接透传 `file.rawContent`，不解压也不重压。
//   2) `file.compress == false`（即 noCompress 构造）
//      → **先 file.decompress()**，反而会把整个条目解压进内存。这是个陷阱。
//
// 另外 `ArchiveFile.stream()` 会把 compressionType 强制设为 STORE，同样走不到
// 分支 1 的直通路径（STORE 不做解压，但也不会帮我们保留原压缩方式）。
//
// 因此这里用**主构造函数**显式指定 DEFLATE，并把「原始压缩字节流」作为内容
// 传入，从而稳定命中分支 1。
//
// ── CRC 的坑 ──────────────────────────────────────────────────────────
// 若不显式设置 `crc32`，ZipEncoder 会调用 getFileCrc32(file)，而对流式内容来说
// 那会**触发一次完整解压**来算 CRC —— 内存与 CPU 优化全部作废。
// 原始条目的 CRC 可以直接从中央目录拿到，替换条目的 CRC 由我们自己算，所以
// 两条路径都能避免这次多余解压。

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'hap_zip.dart';

/// 把 [source] 复制为 [target]，并替换其中若干条目。
///
/// 未出现在 [replacements] 中的条目按其原始压缩字节流式搬运。
/// [replacements] 的 key 必须已存在于 [source] 中（不新增、不删除条目）。
Future<void> streamRepack({
  required HapReader source,
  required File target,
  required Map<String, Uint8List> replacements,
}) async {
  for (final name in replacements.keys) {
    if (source.find(name) == null) {
      throw HapFormatException('待替换的条目不存在：$name');
    }
  }

  final encoder = ZipFileEncoder();
  encoder.create(target.path);
  try {
    for (final entry in source.entries) {
      final replacement = replacements[entry.name];

      if (replacement != null) {
        // 替换条目：内容是新数据，需要**让库压缩**。
        //
        // 这里必须用 3 参构造（不带 compressionType）。4 参构造的
        // compressionType 语义是「传入的内容本身已是这种压缩态」，而不是
        // 「请压缩成这种格式」—— 若误传 DEFLATE，库会把明文当作已压缩数据
        // 直接写出，产物解压时报 "Invalid CRC for file in archive"（已实测）。
        final file = ArchiveFile(entry.name, replacement.length, replacement)
          ..compress = true
          ..mode = entry.mode
          ..lastModTime = _dosToEpochSeconds(entry.dosDate, entry.dosTime)
          ..crc32 = getCrc32(replacement);
        encoder.addArchiveFile(file);
        continue;
      }

      if (entry.isStored) {
        // STORE 条目：原始字节即内容。这类条目在 HAP 里通常是签名块等
        // 小数据，以内存块搬运不会造成压力。
        final raw = await source.readRaw(entry);
        final file = ArchiveFile.noCompress(entry.name, raw.length, raw)
          ..mode = entry.mode
          ..lastModTime = _dosToEpochSeconds(entry.dosDate, entry.dosTime)
          ..crc32 = entry.crc32;
        encoder.addArchiveFile(file);
        continue;
      }

      // DEFLATE 条目「直通搬运」：把**原始压缩字节**当作内容流喂进去。
      //
      // 这里**必须**用 4 参构造并显式传 DEFLATE —— 正是这个语义
      // （「内容已是 DEFLATE 压缩态」）让 ZipEncoder 命中
      // `isCompressed && compressionType == DEFLATE` 分支，
      // 直接把 rawContent 透传出去：既不解压也不重压。
      //
      // 流是惰性读取的，编码器消费时才从磁盘取数据，因此包体不驻留内存。
      final stream = source.openRangeStream(entry);

      final file = ArchiveFile(
        entry.name,
        entry.uncompressedSize,
        stream,
        ArchiveFile.DEFLATE,
      )
        ..compress = true
        ..mode = entry.mode
        ..lastModTime = _dosToEpochSeconds(entry.dosDate, entry.dosTime)
        ..crc32 = entry.crc32; // 显式给出，避免库解压一遍算 CRC

      encoder.addArchiveFile(file);
      // ZipEncoder.addFile 同步消费完内容后才返回，因此这里可以安全关闭。
      stream.closeSync();
    }
  } finally {
    encoder.close();
  }
}

/// DOS 日期/时间 → epoch 秒。非法值时回退到当前时间。
int _dosToEpochSeconds(int dosDate, int dosTime) {
  final year = 1980 + ((dosDate >> 9) & 0x7f);
  final month = (dosDate >> 5) & 0x0f;
  final day = dosDate & 0x1f;
  final hour = (dosTime >> 11) & 0x1f;
  final minute = (dosTime >> 5) & 0x3f;
  final second = (dosTime & 0x1f) * 2;
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }
  return DateTime.utc(year, month, day, hour, minute, second)
          .millisecondsSinceEpoch ~/
      1000;
}
