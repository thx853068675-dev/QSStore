import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/state/install_coordinator.dart';

void main() {
  test('安装包主 Ability 和模块名从 HAP 内读取', () async {
    final dir = await Directory.systemTemp.createTemp('starstore-hap-meta-');
    try {
      final module = utf8.encode(jsonEncode({
        'app': {'bundleName': 'com.example.custom', 'versionCode': 3},
        'module': {'name': 'entry', 'mainElement': 'CustomMainAbility'},
      }));
      final archive = Archive()
        ..addFile(ArchiveFile('module.json', module.length, module));
      final hap = File('${dir.path}/custom.hap');
      await hap.writeAsBytes(ZipEncoder().encode(archive)!);

      final metadata = await readHapMetadata(hap);
      expect(metadata?.bundleName, 'com.example.custom');
      expect(metadata?.mainAbility, 'CustomMainAbility');
      expect(metadata?.moduleName, 'entry');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
