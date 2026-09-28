import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/state/installed_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('删除一个 HAP 记录不影响同仓库另一个包，重启后仍正确', () async {
    final dir = await Directory.systemTemp.createTemp('starstore-installed-');
    const channel = MethodChannel('ohos_adapter');
    TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'appDir') return dir.path;
      return null;
    });
    InstalledRecord record(String bundle) => InstalledRecord(
          appId: 7,
          repo: 'owner/repo',
          displayName: bundle,
          summary: '',
          iconUrl: '',
          bundleName: bundle,
          installedVersionCode: 1,
          installedVersionName: '1.0',
          installedAt: 1,
          mainAbility: 'CustomMainAbility',
          moduleName: 'entry',
        );
    try {
      final store = await InstalledStore.load();
      await store.remember(record('com.example.main'));
      await store.remember(record('com.example.helper'));
      await store.forget(store.records.firstWhere(
          (r) => r.bundleName == 'com.example.main'));
      final restored = await InstalledStore.load();
      expect(restored.records.map((r) => r.bundleName),
          ['com.example.helper']);
      expect(restored.records.single.mainAbility, 'CustomMainAbility');
      expect(restored.records.single.moduleName, 'entry');
    } finally {
      TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    }
  });

  test('重复包名的旧记录只移除点中的一条', () async {
    final dir = await Directory.systemTemp.createTemp('starstore-installed-');
    const channel = MethodChannel('ohos_adapter');
    TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'appDir') return dir.path;
      return null;
    });
    try {
      await File('${dir.path}/installed.json').writeAsString('''[
        {"appId":7,"bundleName":"","installedAt":1},
        {"appId":7,"bundleName":"","installedAt":2}
      ]''');
      final store = await InstalledStore.load();
      await store.forget(store.records.first);
      final restored = await InstalledStore.load();
      expect(restored.records.length, 1);
      expect(restored.records.single.installedAt, 2);
    } finally {
      TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    }
  });
}
