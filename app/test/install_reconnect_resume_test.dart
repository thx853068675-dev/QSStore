import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/net/downloader.dart';
import 'package:hapstore/state/install_coordinator.dart';
import 'package:signing_core/signing_core.dart';

class _WaitingPlatform extends InstallPlatform {
  _WaitingPlatform(this.directory);

  final Directory directory;
  final Completer<bool> reconnect = Completer<bool>();
  bool askedForUdid = false;

  @override
  Future<Directory> workDir() async => directory;

  @override
  Future<bool> ensureInstallConnection() => reconnect.future;

  @override
  Future<String?> deviceUdid() async {
    askedForUdid = true;
    return null;
  }
}

void main() {
  test('本地 HAP 在需要设备通道时等待，连接后从原进度继续', () async {
    final dir = await Directory.systemTemp.createTemp('qingqi-reconnect-');
    final downloader = MirrorDownloader();
    try {
      final module = utf8.encode(jsonEncode({
        'app': {'bundleName': 'com.example.local', 'minAPIVersion': 12},
        'module': {'name': 'entry'},
      }));
      final archive = Archive()
        ..addFile(ArchiveFile('module.json', module.length, module));
      final hap = File('${dir.path}/local.hap');
      await hap.writeAsBytes(ZipEncoder().encode(archive)!);

      final platform = _WaitingPlatform(dir);
      InstallProgress? progress;
      final coordinator = InstallCoordinator(
        downloader: downloader,
        platform: platform,
        onProgress: (p) => progress = p,
      );
      final outcome = coordinator.runLocal(
        hap: hap,
        signConfig: const SignConfig(),
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(progress?.stage, InstallStage.provisioning);
      expect(progress?.stageDetail, '检查设备连接…');
      expect(platform.askedForUdid, isFalse);
      expect(await hap.exists(), isTrue);

      platform.reconnect.complete(true);
      await outcome;
      expect(platform.askedForUdid, isTrue,
          reason: '重新连接后应从等待处继续执行，而不是重新选择 HAP');
      expect(await hap.exists(), isTrue,
          reason: '用户选中的本地文件不能在等待或失败时删除');
    } finally {
      downloader.dispose();
      await dir.delete(recursive: true);
    }
  });
}
