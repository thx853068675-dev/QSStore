// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 流式重打包测试。
//
// 重点验证本方案赖以成立的核心假设：**未改动条目在搬运后字节完全一致**。
// 若不成立，说明 ZipEncoder 的「已压缩直通」分支没有被命中，或者 CRC/压缩
// 方式被改动 —— 那会让 HAP 体积异常膨胀，也会让「载荷未变」校验失去意义。

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:signing_core/signing_core.dart';
import 'package:test/test.dart';

/// 造一个包含 STORE 与 DEFLATE 条目的 ZIP。
///
/// [bigEntryBytes] 用于生成一个「压缩后仍很大」的条目，以覆盖大文件路径。
Future<File> makeSyntheticHap(
  Directory dir, {
  int bigEntryBytes = 0,
  int deflatableBytes = 0,
  Map<String, List<int>> extra = const {},
}) async {
  final archive = Archive();

  void add(String name, List<int> bytes, {bool compress = true}) {
    archive
        .addFile(ArchiveFile(name, bytes.length, bytes)..compress = compress);
  }

  add(
      'module.json',
      utf8.encode(jsonEncode({
        'app': {
          'bundleName': 'test.bundle',
          'versionCode': 1,
          'minAPIVersion': 12
        },
        'module': {'name': 'entry'},
      })));
  add('resources/rawfile/quietstart-worker.json',
      utf8.encode(jsonEncode({'versionCode': 1})));
  archive.addFile(
      ArchiveFile('signature-block.bin', 32, List<int>.filled(32, 7))
        ..compress = false);
  add('entries/classes.dex', List<int>.generate(4096, (i) => i & 0xff));

  if (bigEntryBytes > 0) {
    // 不可压缩的随机数据：保证包体本身真的很大，用于验证「超过 64 MB」。
    final rnd = Random(42);
    final big = List<int>.generate(bigEntryBytes, (_) => rnd.nextInt(256));
    add('resources/large.bin', big, compress: false);
  }
  if (deflatableBytes > 0) {
    // 低熵数据：会被真正 DEFLATE 压缩，用于验证「直通搬运」路径。
    final rnd = Random(11);
    final data = List<int>.generate(deflatableBytes, (_) => rnd.nextInt(6));
    add('resources/deflatable.bin', data);
  }
  extra.forEach((k, v) => add(k, v));

  final bytes = ZipEncoder().encode(archive)!;
  final f = File('${dir.path}/synthetic.hap');
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

/// 读出 ZIP 中所有条目的「解压后内容」。
Future<Map<String, List<int>>> decodeAll(File f) async {
  final reader = await HapReader.open(f);
  try {
    final out = <String, List<int>>{};
    for (final e in reader.entries) {
      out[e.name] = await reader.readDecoded(e);
    }
    return out;
  } finally {
    await reader.close();
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qs-repack-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('HapReader 解析', () {
    test('能读出中央目录全部条目', () async {
      final f = await makeSyntheticHap(tmp);
      final reader = await HapReader.open(f);
      try {
        final names = reader.entries.map((e) => e.name).toSet();
        expect(names, contains('module.json'));
        expect(names, contains('entries/classes.dex'));
        expect(names, contains('signature-block.bin'));
      } finally {
        await reader.close();
      }
    });

    test('STORE 与 DEFLATE 条目被正确区分', () async {
      final f = await makeSyntheticHap(tmp);
      final reader = await HapReader.open(f);
      try {
        expect(reader.find('signature-block.bin')!.isStored, isTrue);
        expect(reader.find('entries/classes.dex')!.isDeflate, isTrue);
      } finally {
        await reader.close();
      }
    });

    test('原始区间可精确读取', () async {
      final f = await makeSyntheticHap(tmp);
      final reader = await HapReader.open(f);
      try {
        final e = reader.find('entries/classes.dex')!;
        final raw = await reader.readRaw(e);
        expect(raw.length, e.compressedSize);
        final decoded = await reader.readDecoded(e);
        expect(decoded.length, e.uncompressedSize);
      } finally {
        await reader.close();
      }
    });

    test('伪造较小的中央目录长度也无法绕过解压上限', () async {
      final f = await makeSyntheticHap(tmp, deflatableBytes: 128 * 1024);
      final reader = await HapReader.open(f);
      try {
        final e = reader.find('resources/deflatable.bin')!;
        final forged = ZipEntry(
          name: e.name,
          compressionMethod: e.compressionMethod,
          flags: e.flags,
          crc32: e.crc32,
          compressedSize: e.compressedSize,
          uncompressedSize: 100,
          localHeaderOffset: e.localHeaderOffset,
          dosTime: e.dosTime,
          dosDate: e.dosDate,
          mode: e.mode,
        );
        await expectLater(reader.readDecoded(forged, maxBytes: 4096),
            throwsA(isA<HapFormatException>()));
      } finally {
        await reader.close();
      }
    });

    test('拒绝非 ZIP 文件', () async {
      final bad = File('${tmp.path}/bad.hap');
      await bad.writeAsBytes(List<int>.filled(100, 0));
      expect(() => HapReader.open(bad), throwsA(isA<HapFormatException>()));
    });

    test('拒绝长度不足的文件', () async {
      final bad = File('${tmp.path}/tiny.hap');
      await bad.writeAsBytes([1, 2, 3]);
      expect(() => HapReader.open(bad), throwsA(isA<HapFormatException>()));
    });
  });

  group('流式重打包 —— 核心假设：未改动条目字节完全一致', () {
    test('替换一个条目后，其余条目内容逐一相等', () async {
      final src = await makeSyntheticHap(tmp);
      final before = await decodeAll(src);

      final reader = await HapReader.open(src);
      final target = File('${tmp.path}/out.hap');
      try {
        final replacement = Uint8List.fromList(utf8.encode('REPLACED-CONTENT'));
        await streamRepack(
          source: reader,
          target: target,
          replacements: {'module.json': replacement},
        );
      } finally {
        await reader.close();
      }

      final after = await decodeAll(target);
      expect(after.keys.toSet(), before.keys.toSet(), reason: '条目集合不得变化');

      // 被替换的条目 = 新内容
      expect(utf8.decode(after['module.json']!), 'REPLACED-CONTENT');

      // 其余条目必须**逐字节**相同
      for (final name in before.keys) {
        if (name == 'module.json') continue;
        expect(after[name], equals(before[name]), reason: '条目「$name」内容被改变');
      }
    });

    test('未改动的 DEFLATE 条目被直通搬运（压缩字节不变）', () async {
      final src = await makeSyntheticHap(tmp, deflatableBytes: 256 * 1024);

      // 记录原条目的 (压缩后长度, crc)
      final srcReader = await HapReader.open(src);
      final origEntry = srcReader.find('resources/deflatable.bin')!;
      expect(origEntry.isDeflate, isTrue, reason: '样本必须真的是 DEFLATE，否则测不到直通路径');
      expect(origEntry.compressedSize, lessThan(origEntry.uncompressedSize),
          reason: '样本必须真的被压缩，否则无法区分「直通」与「重压」');
      final origCompressed = origEntry.compressedSize;
      final origCrc = origEntry.crc32;
      await srcReader.close();

      final reader = await HapReader.open(src);
      final target = File('${tmp.path}/out2.hap');
      try {
        await streamRepack(
          source: reader,
          target: target,
          replacements: {
            'module.json': Uint8List.fromList(utf8.encode('{}')),
          },
        );
      } finally {
        await reader.close();
      }

      final outReader = await HapReader.open(target);
      try {
        final outEntry = outReader.find('resources/deflatable.bin')!;
        // 压缩字节长度不变 ⇒ 确实走的直通，而不是「解压再压缩」
        expect(outEntry.compressedSize, origCompressed,
            reason: '压缩后长度变化说明走了重新压缩路径，未命中直通分支');
        expect(outEntry.crc32, origCrc);
        expect(outEntry.isDeflate, isTrue);
      } finally {
        await outReader.close();
      }
    });

    test('STORE 条目保持 STORE', () async {
      final src = await makeSyntheticHap(tmp);
      final reader = await HapReader.open(src);
      final target = File('${tmp.path}/out3.hap');
      try {
        await streamRepack(
          source: reader,
          target: target,
          replacements: {
            'module.json': Uint8List.fromList(utf8.encode('{}')),
          },
        );
      } finally {
        await reader.close();
      }

      final outReader = await HapReader.open(target);
      try {
        expect(outReader.find('signature-block.bin')!.isStored, isTrue);
      } finally {
        await outReader.close();
      }
    });

    test('替换不存在的条目会被拒绝', () async {
      final src = await makeSyntheticHap(tmp);
      final reader = await HapReader.open(src);
      try {
        expect(
          () => streamRepack(
            source: reader,
            target: File('${tmp.path}/x.hap'),
            replacements: {
              'not-there.txt': Uint8List.fromList([1, 2, 3]),
            },
          ),
          throwsA(isA<HapFormatException>()),
        );
      } finally {
        await reader.close();
      }
    });
  });

  group('大包路径 —— 证明 64 MB 上限确实消失', () {
    test('处理 72 MB 条目（超过原 64 MB 上限）', () async {
      // 低熵数据 → 压缩后仍很大，逼迫走大文件路径。
      final src = await makeSyntheticHap(tmp, bigEntryBytes: 72 * 1024 * 1024);
      final srcSize = await src.length();
      expect(srcSize, greaterThan(64 * 1024 * 1024),
          reason: '测试样本必须真的超过 64 MB 才有意义');

      final reader = await HapReader.open(src);
      final target = File('${tmp.path}/big-out.hap');
      try {
        await streamRepack(
          source: reader,
          target: target,
          replacements: {
            'module.json': Uint8List.fromList(utf8.encode('{"ok":1}')),
          },
        );
      } finally {
        await reader.close();
      }

      final outReader = await HapReader.open(target);
      try {
        final big = outReader.find('resources/large.bin')!;
        expect(big.uncompressedSize, 72 * 1024 * 1024);
      } finally {
        await outReader.close();
      }
      expect(await target.length(), greaterThan(64 * 1024 * 1024));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('checkPayloadUnchanged 能检出内容被改动', () async {
      final a = await makeSyntheticHap(tmp, bigEntryBytes: 1024 * 1024);
      final alt = await Directory.systemTemp.createTemp('qs-alt-');
      addTearDown(() async {
        if (await alt.exists()) await alt.delete(recursive: true);
      });
      final b = await makeSyntheticHap(
        alt,
        bigEntryBytes: 1024 * 1024,
        extra: {'tampered.txt': utf8.encode('injected')},
      );

      final ra = await HapReader.open(a);
      try {
        // b 多了一个条目 ⇒ 必须被判定为「内容被改变」
        await expectLater(
          checkPayloadUnchanged(original: ra, result: b),
          throwsA(isA<HapFormatException>()),
        );
      } finally {
        await ra.close();
      }
    });

    test('checkPayloadUnchanged 对相同包放行', () async {
      final a = await makeSyntheticHap(tmp, bigEntryBytes: 512 * 1024);
      final ra = await HapReader.open(a);
      try {
        await checkPayloadUnchanged(original: ra, result: a);
      } finally {
        await ra.close();
      }
    });
  });

  group('清单构建', () {
    test('格式与缩进稳定（回归保护）', () {
      final text = buildWorkerManifest(
        base: {'bundleName': 'x', 'versionCode': 1},
        workerSize: 123,
        workerSha256: 'abc',
      );
      expect(text, endsWith('\n'));
      expect(text, contains('  "bundleName"'), reason: '两空格缩进格式必须保持');
      expect(text, contains('"size": 123'));
      expect(text, contains('"sha256": "abc"'));
    });
  });
}
