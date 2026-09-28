// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 原生库尺寸下限修补的测试。
//
// 这些测试保护的是一个**已实测的真实缺陷**：
// 手机侧 Go 版签名器（libsigner.so）对小于约 169KB 的原生库会
// nil 解引用崩溃。实测边界：168KB 崩 / 170KB 成功。
//
// 若将来换掉签名器，或换用官方 Java 签名器（无此缺陷），
// 这些测试仍应保留 —— 它们同时也在保护「填充不破坏 ELF 语义」这一点。

import 'dart:io';
import 'dart:typed_data';

import 'package:signing_core/signing_core.dart';
import 'package:test/test.dart';

/// 造一个最小的合法 ELF 头（仅用于测试尺寸判定，不要求可加载）。
Uint8List fakeElf(int size) {
  final b = Uint8List(size);
  b[0] = 0x7f;
  b[1] = 0x45; // E
  b[2] = 0x4c; // L
  b[3] = 0x46; // F
  b[4] = 2; // 64 位
  b[5] = 1; // 小端
  return b;
}

/// 构造一个含原生库的最小 HAP。
Future<File> makeHap(
  Directory dir,
  Map<String, Uint8List> libs, {
  Map<String, String> extra = const {},
}) async {
  final f = File('${dir.path}/test.hap');
  final raf = f.openSync(mode: FileMode.write);
  try {
    // 简化处理：直接用 dart:io 的 ZipEncoder 不方便，改用 archive 包
    // 这里通过 signing_core 已有的重打包能力间接完成：
    // 先用一个空包 + 替换条目生成
    final base = File('${dir.path}/base.hap');
    await _writeStoredZip(base, {'module.json': '{}', ...extra, ...{}});
    // 用 streamRepack 把 libs 作为替换写入 —— 但替换要求条目已存在，
    // 因此改为直接写一个包含全部条目的 ZIP。
    await _writeStoredZip(f, {
      'module.json': '{}',
      ...extra,
      for (final e in libs.entries) e.key: e.value,
    });
  } finally {
    raf.closeSync();
  }
  return f;
}

/// 写一个 STORE（不压缩）方式的 ZIP。
Future<void> _writeStoredZip(File target, Map<String, dynamic> entries) async {
  final out = target.openSync(mode: FileMode.write);
  final central = BytesBuilder();
  var offset = 0;

  for (final e in entries.entries) {
    final nameBytes = Uint8List.fromList(e.key.codeUnits);
    final data = e.value is String
        ? Uint8List.fromList((e.value as String).codeUnits)
        : e.value as Uint8List;
    final crc = _crc32(data);

    final local = BytesBuilder()
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(0)) // STORE
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0))
      ..add(nameBytes);
    out.writeFromSync(local.toBytes());
    out.writeFromSync(data);

    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(0)) // STORE
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(offset))
      ..add(nameBytes);

    offset += local.length + data.length;
  }

  final cd = central.toBytes();
  out.writeFromSync(cd);
  final eocd = BytesBuilder()
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(cd.length))
    ..add(_u32(offset))
    ..add(_u16(0));
  out.writeFromSync(eocd.toBytes());
  out.closeSync();
}

Uint8List _u16(int v) => Uint8List.fromList([v & 0xff, (v >> 8) & 0xff]);

Uint8List _u32(int v) => Uint8List.fromList(
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

int _crc32(Uint8List data) {
  var crc = 0xffffffff;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('pad-test-'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('尺寸判定', () {
    test('小原生库需要补到下限', () {
      // 5 KB 的 libnative_core.so —— 真实世界里就存在（实测 5432 B）
      expect(paddingFor('libs/arm64-v8a/libnative_core.so', 5432),
          minNativeLibSize - 5432);
    });

    test('刚低于下限的库需要补', () {
      // libunhap.so 实测 160264 B，是触发崩溃的典型
      expect(paddingFor('libs/arm64-v8a/libunhap.so', 160264),
          minNativeLibSize - 160264);
    });

    test('达到下限的库不动', () {
      expect(paddingFor('libs/arm64-v8a/libflutter.so', 11515056), 0);
      expect(paddingFor('libs/arm64-v8a/x.so', minNativeLibSize), 0);
    });

    test('libs/ 下的 .so 才算原生库', () {
      expect(isNativeLibEntry('libs/arm64-v8a/a.so'), isTrue);
      // 顶层或非 libs 下的 .so 不参与（避免动到不该动的东西）
      expect(isNativeLibEntry('resources/rawfile/other.so'), isFalse);
      expect(isNativeLibEntry('module.json'), isFalse);
      expect(isNativeLibEntry('libs/arm64-v8a/a.abc'), isFalse);
    });
  });

  group('填充行为', () {
    test('补齐到下限，且原字节原样保留', () {
      final orig = fakeElf(5432);
      final out = padIfNeeded('libs/arm64-v8a/libnative_core.so', orig);

      expect(out.length, minNativeLibSize);
      // 前缀必须逐字节相同 —— 否则 ELF 会被破坏
      expect(out.sublist(0, orig.length), equals(orig));
      // 新增部分全为 0
      expect(out.sublist(orig.length).every((b) => b == 0), isTrue);
    });

    test('不需要补时返回原对象（不做无谓复制）', () {
      final orig = fakeElf(minNativeLibSize + 100);
      final out = padIfNeeded('libs/arm64-v8a/libflutter.so', orig);
      expect(identical(out, orig), isTrue);
    });

    test('非原生库即使很小也不补', () {
      final small = Uint8List.fromList([1, 2, 3]);
      final out = padIfNeeded('module.json', small);
      expect(identical(out, small), isTrue);
    });
  });

  signerAddedEntryTests();

  group('HAP 扫描', () {
    test('找出全部低于下限的原生库', () async {
      final hap = await makeHap(tmp, {
        'libs/arm64-v8a/libnative_core.so': fakeElf(5432),
        'libs/arm64-v8a/libunhap.so': fakeElf(160264),
        'libs/arm64-v8a/libgo_signer.so': fakeElf(111736),
        // 这个够大，不该被列出
        'libs/arm64-v8a/libflutter.so': fakeElf(200000),
        // 非原生库，不该被列出
        'resources/rawfile/tiny.so': fakeElf(100),
      });

      final found = await findUndersizedNativeLibs(hap);

      expect(found.keys, contains('libs/arm64-v8a/libnative_core.so'));
      expect(found.keys, contains('libs/arm64-v8a/libunhap.so'));
      expect(found.keys, contains('libs/arm64-v8a/libgo_signer.so'));
      expect(found.keys, isNot(contains('libs/arm64-v8a/libflutter.so')));
      expect(found.keys, isNot(contains('resources/rawfile/tiny.so')));
      expect(found['libs/arm64-v8a/libnative_core.so'], 5432);
    });

    test('全部达标时返回空', () async {
      final hap = await makeHap(tmp, {
        'libs/arm64-v8a/libflutter.so': fakeElf(300000),
      });
      expect(await findUndersizedNativeLibs(hap), isEmpty);
    });

    test('真实商店包的四个小库都能被识别', () async {
      // 商店自身构建的 HAP 里有 4 个库低于下限：
      //   libnative_core.so 5432 / libgo_signer.so 111736
      //   libunhap.so 160264 / libflutter_accessibility.so 173872
      // 这是那 4 个的实测字节数。
      final hap = await makeHap(tmp, {
        'libs/arm64-v8a/libnative_core.so': fakeElf(5432),
        'libs/arm64-v8a/libgo_signer.so': fakeElf(111736),
        'libs/arm64-v8a/libunhap.so': fakeElf(160264),
        'libs/arm64-v8a/libflutter_accessibility.so': fakeElf(173872),
      });
      final found = await findUndersizedNativeLibs(hap);
      expect(found.length, 4);
    });
  });
}

/// 签名器会自行添加 `.pages.info`（页面信息索引）。
///
/// 这不是篡改 —— 实测任何 HAP 签名后条目数 +1，且**安装成功**的包同样包含它。
/// 曾因此让校验器误判「签名器意外改变了程序内容」，把正常签名全部拦下。
void signerAddedEntryTests() {
  group('签名器自行添加的条目', () {
    test('.pages.info 被识别为签名器产物', () {
      expect(isSignerAddedEntry('.pages.info'), isTrue);
    });

    test('其它任何多出的条目都不放行', () {
      expect(isSignerAddedEntry('libs/arm64-v8a/evil.so'), isFalse);
      expect(isSignerAddedEntry('module.json'), isFalse);
      expect(isSignerAddedEntry('.hidden'), isFalse);
      expect(isSignerAddedEntry('pages.info'), isFalse);
    });
  });
}
