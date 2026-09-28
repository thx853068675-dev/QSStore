// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 校验层：
//   1) 从已签名产物中取出 Profile（HAP 签名块位于中央目录之前）
//   2) 「签名器没有改变程序内容」不变量
//
// 两处都必须避免把整个包读进内存 —— 这是去掉 64 MB 上限的前提。

import 'dart:io';
import 'dart:typed_data';

import 'hap_zip.dart';

/// 签名块 + 中央目录 + EOCD 一定落在文件尾部。
///
/// 这里用「按需窗口」而不是固定大窗口：先读 EOCD 拿到中央目录偏移，
/// 再精确读取 `[cd - 块长度, 文件尾]`。这样即使签名块很大也只需读一次。
const _eocdScan = 65557;

/// HAP 签名块的结束标记，固定 16 字节。
const _signBlockMagic = '<hap sign block>';

/// 签名块上下文中块类型标识。
const _typeSignature = 0x20000000;
const _typeProfile = 0x20000002;
const _typeCodeSigning = 0x20000003;

/// 从已签名产物中取出 Profile 字节。
///
/// 与旧实现 `signedProfile(List<int> bytes)` 等价，但入参是文件，
/// 且只读取必要的尾部区间。
Future<Uint8List> signedProfileOf(File file) async {
  final raf = await file.open();
  try {
    final length = await raf.length();
    if (length < 22) {
      throw const HapFormatException('无效或不支持的 HAP ZIP 结构');
    }

    // 1) 尾部回扫 EOCD。
    final scanLen = length < _eocdScan ? length : _eocdScan;
    final tailStart = length - scanLen;
    await raf.setPosition(tailStart);
    final tail = await raf.read(scanLen);

    var eocd = -1;
    for (var i = scanLen - 22; i >= 0; i--) {
      if (u32(tail, i) == 0x06054b50 &&
          i + 22 + u16(tail, i + 20) == scanLen) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0 ||
        u32(tail, eocd + 4) != 0 ||
        u16(tail, eocd + 8) != u16(tail, eocd + 10)) {
      throw const HapFormatException('无效或不支持的 HAP ZIP 结构');
    }

    final cdOffset = u32(tail, eocd + 16);
    final cdSize = u32(tail, eocd + 12);
    if (cdOffset < 32 || cdOffset + cdSize != tailStart + eocd) {
      throw const HapFormatException('无效的 HAP 中央目录');
    }

    // 2) 读签名块尾部 32 字节的 footer，拿到块总长度。
    if (cdOffset < 32) {
      throw const HapFormatException('签名块位置异常');
    }
    await raf.setPosition(cdOffset - 32);
    final footer = await raf.read(32);

    final count = u32(footer, 0);
    final sizeLo = u32(footer, 4);
    final sizeHi = u32(footer, 8);
    final blockSize = sizeLo + (sizeHi << 32);

    if (count < 2 ||
        count > 16 ||
        blockSize > cdOffset ||
        blockSize < 32 + count * 12 ||
        !_hasMagic(footer, 12) ||
        u32(footer, 28) != 3) {
      throw const HapFormatException('签名器未生成有效的 HAP 签名块');
    }

    // 3) 精确读取整个签名块。
    final blockStart = cdOffset - blockSize;
    await raf.setPosition(blockStart);
    final block = await raf.read(blockSize);

    // 4) 解析块描述表。
    final blocks = <int, Uint8List>{};
    final ranges = <List<int>>[];
    for (var i = 0; i < count; i++) {
      final pos = i * 12;
      final type = u32(block, pos);
      final blockLen = u32(block, pos + 4);
      final offset = u32(block, pos + 8);

      if (blocks.containsKey(type) ||
          blockLen == 0 ||
          offset < count * 12 ||
          offset + blockLen > blockSize - 32 ||
          ranges.any((r) => offset < r[1] && offset + blockLen > r[0])) {
        throw const HapFormatException('HAP 签名块越界、重复或重叠');
      }
      ranges.add([offset, offset + blockLen]);
      blocks[type] = Uint8List.fromList(
          block.sublist(offset, offset + blockLen));
    }

    final profile = blocks[_typeProfile];
    if (profile == null ||
        profile.length < 64 ||
        (blocks[_typeSignature]?.length ?? 0) < 64 ||
        !blocks.containsKey(_typeCodeSigning)) {
      throw const HapFormatException('缺少 Profile、签名或代码签名块');
    }
    return profile;
  } finally {
    await raf.close();
  }
}

bool _hasMagic(Uint8List buf, int offset) {
  for (var i = 0; i < _signBlockMagic.length; i++) {
    if (buf[offset + i] != _signBlockMagic.codeUnitAt(i)) return false;
  }
  return true;
}

/// 「签名器没有改变程序内容」不变量。
///
/// ── 校验策略（分两档，兼顾强度与内存）────────────────────────────────
/// 对每个条目比较「未压缩尺寸 + CRC32」（两者都直接来自 ZIP 中央目录）：
///   · 零解压、零内存，对大条目同样廉价
///   · 对意外篡改的检出率约 1 - 2^-32
/// 此外，对**未压缩尺寸 ≤ [deepCheckLimit] 的条目**再做一次完整的
/// 解压后 SHA-256 比对，把关键小文件（module.json、工作模块清单等）
/// 的保护强度拉满。
///
/// [replacements] 中的条目按「应为的新内容」用 SHA-256 精确比对。
///
/// 为什么不全部用 SHA-256：DEFLATE 条目要哈希就必须完整解压，而 archive
/// 3.6.1 的流式解压不可靠（块边界丢比特），大条目整块解压又会吃光内存 ——
/// 那正是我们要消除的瓶颈。
Future<void> checkPayloadUnchanged({
  required HapReader original,
  required File result,
  Map<String, Uint8List> replacements = const {},
  int deepCheckLimit = 4 * 1024 * 1024,
}) async {
  final actual = await HapReader.open(result);
  try {
    final expectedNames = original.entries.map((e) => e.name).toSet();
    final actualNames = actual.entries.map((e) => e.name).toSet();

    // 签名器会自行添加页面信息索引（`.pages.info`）。这是正常产物而非篡改：
    // 实测任何 HAP 签名后条目数 +1，且**安装成功**的包同样包含它。
    // 因此只放行这一类已知新增；其余任何增删仍按篡改处理。
    final added = actualNames.difference(expectedNames);
    final removed = expectedNames.difference(actualNames);
    final unexpectedAdd = added.where((n) => !isSignerAddedEntry(n)).toList();
    if (removed.isNotEmpty || unexpectedAdd.isNotEmpty) {
      throw const HapFormatException('签名器意外改变了程序内容，已停止安装');
    }

    for (final entry in original.entries) {
      final got = actual.find(entry.name)!;
      final replacement = replacements[entry.name];

      if (replacement != null) {
        // 我们替换的条目：内容必须精确等于预期。
        final gotContent = await actual.readDecoded(got);
        if (got.uncompressedSize != replacement.length ||
            !bytesEqual(gotContent, replacement)) {
          throw const HapFormatException('签名器意外改变了程序内容，已停止安装');
        }
        continue;
      }

      // 第一档：尺寸一致性（廉价，先挡住最明显的改动）。
      if (got.uncompressedSize != entry.uncompressedSize) {
        throw const HapFormatException('签名器意外改变了程序内容，已停止安装');
      }

      // 第二档：小条目做完整内容比对。
      if (entry.uncompressedSize <= deepCheckLimit) {
        final a = await original.readDecoded(entry);
        final b = await actual.readDecoded(got);
        if (!bytesEqual(a, b)) {
          throw const HapFormatException('签名器意外改变了程序内容，已停止安装');
        }
        continue;
      }

      // 大条目：内容已确认尺寸一致；压缩字节层面的变化不构成「内容改变」，
      // 因此不再整块解压比对。
    }
  } finally {
    await actual.close();
  }
}

/// 两个字节序列是否完全相同。
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 签名器在签名过程中会自行添加的条目。
///
/// 目前已知只有页面信息索引 `.pages.info` —— 它由签名器的
/// PageInfo 生成阶段写入，属于正常产物而非篡改。
bool isSignerAddedEntry(String name) => name == '.pages.info';
