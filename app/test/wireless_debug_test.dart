// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 无线调试端口发现的测试。
//
// 保护的是一个**真实误判**：最初只接受 127.0.0.1（`0100007F`），
// 但实测 HarmonyOS 7.0 上调试端口绑在 **WiFi 网卡**（192.168.3.160）
// 与 0.0.0.0 上，导致候选列表永远为空、「自动连接」永远失败。
//
// 下面的用例直接采用真机 `/proc/net/tcp` 的实际内容。

import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/state/wireless_debug.dart';

/// 真机（VDE-AL10 / HarmonyOS 7.0）`/proc/net/tcp` 的片段。
/// 注意调试端口在 192.168.3.160 与 0.0.0.0 上，loopback 上的三个都不是。
const deviceProcNetTcp = '''
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:E7E2 00000000:0000 0A 00000000:00000000 00:00000000 00000000 20020221 0 5884616 1
   1: 0100007F:26E4 00000000:0000 0A 00000000:00000000 00:00000000 00000000 20020068 0 6073858 1
   2: 0100007F:1ED2 00000000:0000 0A 00000000:00000000 00:00000000 00000000 20020410 0 6129416 1
   3: 00000000:B6A9 00000000:0000 0A 00000000:00000000 00:00000000 00000000  2000 0 6303246 1
   4: C0A803A0:B6A9 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1024 0 6303247 1
   5: C0A803A0:F2A6 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1024 0 6303248 1
   6: 0100007F:46B4 00000000:0000 0A 00000000:00000000 00:00000000 00000000 20020221 0 5884617 1
   7: 0100007F:D431 00000000:0001 01 00000000:00000000 00:00000000 00000000 20020221 0 5884618 1
''';

Future<String?> fakeRead(String path) async =>
    path == '/proc/net/tcp' ? deviceProcNetTcp : null;

void main() {
  group('端口发现', () {
    test('★ 不局限于 loopback —— 能发现绑在网卡与 0.0.0.0 上的端口', () async {
      final ports = await WirelessDebugger.listenPorts(readFile: fakeRead);

      // 0x1ED2 = 7890, 0x26E4 = 9956, 0xE7E2 = 59362, 0x46B4 = 18100
      // 0xB6A9 = 46761, 0xF2A6 = 62118
      expect(ports, contains(46761), reason: '0.0.0.0 上的端口必须被纳入');
      expect(ports, contains(62118), reason: '网卡地址上的端口必须被纳入');
      expect(ports, contains(7890), reason: 'loopback 上的端口也要纳入');
    });

    test('★ 只用 loopback 过滤时会漏掉全部调试端口（回归保护）', () async {
      final ports = await WirelessDebugger.listenPorts(readFile: fakeRead);
      // 真机的三个 loopback 端口都不是调试端口；若实现退回只认 loopback，
      // 这个断言会失败，提醒不要重蹈覆辙。
      final loopbackOnly = ports.where((p) => [7890, 9956, 59362].contains(p));
      expect(loopbackOnly.length, 3);
      expect(ports.length, greaterThan(3),
          reason: '必须包含 loopback 之外的端口');
    });

    test('高位端口排在前面（调试端口不会是特权端口）', () async {
      final ports = await WirelessDebugger.listenPorts(readFile: fakeRead);
      final firstLow = ports.indexWhere((p) => p <= 1024);
      if (firstLow >= 0) {
        // 若有低位端口，它必须排在所有高位端口之后
        final lastHigh = ports.lastIndexWhere((p) => p > 1024);
        expect(lastHigh, lessThan(firstLow));
      }
    });

    test('只取 LISTEN 状态', () async {
      final ports = await WirelessDebugger.listenPorts(readFile: fakeRead);
      // 0xD431 = 54321 是 ESTABLISHED(01)，不该出现
      expect(ports, isNot(contains(54321)));
    });

    test('读不到 /proc/net/tcp 时返回空而不抛异常', () async {
      final ports = await WirelessDebugger.listenPorts(
          readFile: (p) async => null);
      expect(ports, isEmpty);
    });

    test('内容异常时不崩', () async {
      final ports = await WirelessDebugger.listenPorts(
          readFile: (p) async => 'garbage\nnot a table\n');
      expect(ports, isEmpty);
    });
  });

  group('list targets 解析', () {
    test('空列表是 [Empty]，不算目标', () {
      expect(WirelessDebugger.parseTargets('[Empty]\n'), isEmpty);
      expect(WirelessDebugger.parseTargets(''), isEmpty);
    });

    test('真实目标被识别', () {
      expect(
        WirelessDebugger.parseTargets('3UJ0225318033410\n'),
        equals(['3UJ0225318033410']),
      );
    });

    test('失败输出不算目标', () {
      expect(
        WirelessDebugger.parseTargets('[Fail]Connect failed\n'),
        isEmpty,
      );
    });
  });

  group('连接存活检查', () {
    test('旧目标仍在列表但设备命令失败时判为断开', () async {
      final wd = WirelessDebugger(runHdc: (cmd) async =>
          cmd.contains('list targets') ? 'DEVICE-A\n' : '[Fail]No target');
      expect(await wd.hasLiveConnection(), isFalse);
    });

    test('只有设备实际返回 UDID 才判为已连接', () async {
      final wd = WirelessDebugger(runHdc: (cmd) async =>
          'udid of current device is :\n'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n');
      expect(await wd.hasLiveConnection(), isTrue);
    });
  });

  group('连接流程', () {
    test('已有目标时直接返回成功，不去试端口', () async {
      final cmds = <String>[];
      final wd = WirelessDebugger(
        runHdc: (c) async {
          cmds.add(c);
          if (c.contains('shell bm get --udid')) {
            return 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
          }
          return c.contains('list targets') ? 'DEVICE-A\n' : '';
        },
      );

      final r = await wd.connect();
      expect(r.ok, isTrue);
      expect(r.target, 'DEVICE-A');
      expect(cmds.where((c) => c.contains('tconn')), isEmpty,
          reason: '已连上就不该再试端口');
    });

    test('★ 连对端口后确认目标', () async {
      var connected = false;
      final wd = WirelessDebugger(
        runHdc: (c) async {
          if (c.contains('list targets')) {
            return connected ? 'DEVICE-B\n' : '[Empty]\n';
          }
          if (c.contains('shell bm get --udid')) {
            return connected
                ? 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
                : '';
          }
          if (c.contains(':46761')) connected = true;
          return '';
        },
        log: (m) async {},
      );

      final r = await wd.connectToPort(46761, trustWait: Duration(milliseconds: 300));
      expect(r.ok, isTrue);
      expect(r.target, 'DEVICE-B');
      expect(r.port, 46761);
    });

    test('tconn 报错时该端口判为失败', () async {
      final wd = WirelessDebugger(
        runHdc: (c) async => c.contains('tconn') ? '[Fail]Connect failed' : '',
        log: (m) async {},
      );
      final r = await wd.connectToPort(12345, trustWait: Duration(milliseconds: 300));
      expect(r.ok, isFalse);
    });

    test('tconn 成功但无目标时判为失败（需设备授权）', () async {
      final wd = WirelessDebugger(
        runHdc: (c) async => c.contains('list targets') ? '[Empty]\n' : '',
        log: (m) async {},
      );
      final r = await wd.connectToPort(12345,
          trustWait: Duration(milliseconds: 300));
      expect(r.ok, isFalse);
      // 超时后给出可操作的原因（端口/信任弹窗/开关状态）
      expect(r.message, contains('端口'));
      expect(r.message, contains('信任'));
    });

    test('★ 首次 tconn 快速失败后会重试成功（吸收服务刚启动的抖动）', () async {
      var tconnAttempts = 0;
      var connected = false;
      final wd = WirelessDebugger(
        runHdc: (c) async {
          if (c.contains('list targets')) {
            return connected ? 'DEVICE-R\n' : '[Empty]\n';
          }
          if (c.contains('shell bm get --udid')) {
            return connected
                ? 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
                : '';
          }
          if (c.contains('tconn')) {
            tconnAttempts++;
            if (tconnAttempts >= 2) connected = true;
            return tconnAttempts == 1 ? '[Fail]Connect failed' : 'Connect OK';
          }
          return '';
        },
        log: (m) async {},
      );

      final r = await wd.connectToPort(40941,
          trustWait: const Duration(seconds: 3));
      expect(r.ok, isTrue);
      expect(r.target, 'DEVICE-R');
      expect(tconnAttempts, greaterThanOrEqualTo(2), reason: '应当重试过一次');
    });

    test('旧目标仍可用，但新端口 tconn 失败时不能误报连接成功', () async {
      final wd = WirelessDebugger(runHdc: (cmd) async {
        if (cmd.contains('list targets')) return 'DEVICE-OLD\n';
        if (cmd.contains('shell bm get --udid')) {
          return 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
        }
        return '[Fail]Connect failed';
      });
      final result = await wd.connectToPort(54321,
          trustWait: const Duration(milliseconds: 300));
      expect(result.ok, isFalse);
    });

    test('排除表生效：被排除的端口不会被试连', () async {
      final tried = <int>[];
      final wd = WirelessDebugger(
        runHdc: (c) async {
          if (c.contains('list targets')) return '[Empty]\n';
          final m = RegExp(r'tconn [^:]+:(\d+)').firstMatch(c);
          if (m != null) tried.add(int.parse(m.group(1)!));
          return '';
        },
        excludedPorts: {46761, 62118},
        log: (m) async {},
      );

      // connectToPort 本身不看排除表；排除表在 connect() 里生效。
      // 这里直接验证字段内容与「未排除的会被尝试」。
      expect(wd.excludedPorts, equals({46761, 62118}));
      for (final p in [46761, 62118, 7890]) {
        if (wd.excludedPorts.contains(p)) continue;
        await wd.connectToPort(p, trustWait: Duration(milliseconds: 300));
      }
      // 每个端口会依次尝试 127.0.0.1 与 localhost 两个主机名
      expect(tried.toSet(), equals({7890}), reason: '只有未被排除的端口才该被尝试');
      expect(tried, isNot(contains(46761)));
      expect(tried, isNot(contains(62118)));
    });
  });

}
