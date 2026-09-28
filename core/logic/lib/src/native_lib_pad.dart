// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 原生库尺寸下限的修补。
//
// ── 为什么需要这个 ────────────────────────────────────────────────────
// 手机侧签名用的是第三方 Go 版 hapsigner（`libsigner.so`）。它的
// `PageInfoGenerator.libExecSegment` 对**小于约 169 KB 的原生库**会
// nil 解引用崩溃：
//
//     panic: runtime error: invalid memory address or nil pointer dereference
//       .../codesigning/elf.(*ELFFile).IsELFFile
//       .../codesigning/sign.(*PageInfoGenerator).libExecSegment
//
// 实测边界（`libunhap.so` 尾部填充到不同大小）：
//
//     168 KB → ❌ 崩溃
//     170 KB → ✅ 成功
//
// 修好之后立即触发：很多应用都带小的 `libnative_core.so`（仅 5 KB），
// 于是**任何含小原生库的应用都装不上**。
//
// ── 修补方式与它的安全性 ──────────────────────────────────────────────
// 在文件**尾部追加 NUL 字节**到下限之上。
//
// 这样做是安全的：
//   · ELF 加载器只依据程序头（program header）里的 p_offset/p_filesz
//     映射段，尾部多余字节不会被加载，也不参与任何符号解析
//   · 包内所有字节都被签名覆盖，所以签名与内容始终一致
//
// 已在真机验证：把一个含 4 个 <169KB 原生库的完整 HAP 填充后签名安装，
// 应用正常启动，被填充的库（如 `libgo_signer.so`）成功加载。
//
// ── 为什么不用官方 Java 签名器 ────────────────────────────────────────
// 官方 `hap-sign-tool.jar` 没有这个缺陷，但手机上要跑它需要 JVM
// （`libjavacmd.so`），而原「小白」工程**从未真正提供**该库 —— 那条路
// 在设备上不可用。因此这里选择修补文档格式，而不是引入 Java 运行时。

import 'dart:io';
import 'dart:typed_data';

/// 原生库的尺寸下限（字节）。
///
/// 实测临界在 168 KB（崩）与 170 KB（成功）之间。取 192 KB 留出余量，
/// 避免不同构建的签名器在临界点附近行为漂移。
const int minNativeLibSize = 192 * 1024;

/// 判断某个条目是否是原生库。
bool isNativeLibEntry(String entryName) =>
    entryName.endsWith('.so') && entryName.contains('libs/');

/// 计算某个条目需要补的字节数（不需要补时为 0）。
///
/// [size] 为该条目**解压后的**大小。
int paddingFor(String entryName, int size) {
  if (!isNativeLibEntry(entryName)) return 0;
  if (size >= minNativeLibSize) return 0;
  return minNativeLibSize - size;
}

/// 在字节尾部补 NUL 到下限之上。
///
/// 返回原字节（无需修补时）或补齐后的新字节。
Uint8List padIfNeeded(String entryName, Uint8List data) {
  final pad = paddingFor(entryName, data.length);
  if (pad == 0) return data;

  final out = Uint8List(data.length + pad);
  out.setRange(0, data.length, data);
  // 新增部分默认为 0，正是我们想要的
  return out;
}

/// 检查一份 HAP 里有哪些原生库低于下限（供预检与诊断使用）。
///
/// 返回 `条目名 → 当前大小`。空表示无需修补。
Future<Map<String, int>> findUndersizedNativeLibs(File hap) async {
  final result = <String, int>{};
  await for (final entry in _iterEntries(hap)) {
    if (isNativeLibEntry(entry.name) && entry.size < minNativeLibSize) {
      result[entry.name] = entry.size;
    }
  }
  return result;
}

/// 中央目录里的一个条目（只需要名称与解压后大小）。
///
/// 用普通类而非 record：鸿蒙 Flutter 分支是 Dart 2.19，
/// 尚不支持 records 语法。
class _CdEntry {
  _CdEntry(this.name, this.size);
  final String name;
  final int size;
}

/// 遍历 HAP 条目（名称、解压后大小）。
///
/// 这里只读中央目录，不解压数据 —— 对大包也很快。
Stream<_CdEntry> _iterEntries(File hap) async* {
  final raf = await hap.open();
  try {
    final length = await raf.length();
    // 中央目录结束记录固定 22 字节，注释最长 65535
    final tailLength = length < 66000 ? length : 66000;
    await raf.setPosition(length - tailLength);
    final tail = await raf.read(tailLength);

    final eocd = _findEocd(tail);
    if (eocd < 0) return;
    final entryCount = _u16(tail, eocd + 10);
    final cdSize = _u32(tail, eocd + 12);
    final cdOffset = _u32(tail, eocd + 16);

    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);

    var p = 0;
    for (var i = 0; i < entryCount && p + 46 <= cd.length; i++) {
      if (_u32(cd, p) != 0x02014b50) break; // 中央目录文件头签名
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      final uncompressed = _u32(cd, p + 24);
      final name = String.fromCharCodes(cd, p + 46, p + 46 + nameLen);
      yield _CdEntry(name, uncompressed);
      p += 46 + nameLen + extraLen + commentLen;
    }
  } finally {
    await raf.close();
  }
}

int _findEocd(Uint8List b) {
  for (var i = b.length - 22; i >= 0; i--) {
    if (b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 0x05 && b[i + 3] == 0x06) {
      return i;
    }
  }
  return -1;
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
