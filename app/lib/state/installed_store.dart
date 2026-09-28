// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 已安装记录 —— 「更新」页与「我的」页的数据源。
//
// 只登记**通过本商店安装成功**的应用，而不是扫描设备上全部应用：
//   · 扫描需要额外权限，且拿不到可靠的 versionCode
//   · 用户真正关心的是「我从这里装的东西有没有新版」
//
// 记录里保存 versionCode（用于与商店版本比较）和 bundleName（用于排除
// 同一个 release 里其他 bundle 的附件 —— 轻启的 release 就同时挂着两个包）。

import 'dart:convert';
import 'dart:io';

import '../model/store_models.dart';
import 'sign_material_store.dart' show appDataDir;

class InstalledRecord {
  InstalledRecord({
    required this.appId,
    required this.repo,
    required this.displayName,
    required this.summary,
    required this.iconUrl,
    required this.bundleName,
    required this.installedVersionCode,
    required this.installedVersionName,
    required this.installedAt,
    this.mainAbility = '',
    this.moduleName = '',
  });

  final int appId;
  final String repo;
  final String displayName;
  final String summary;
  final String iconUrl;

  /// 已安装包的 bundleName（用于筛选正确的附件）
  final String bundleName;
  final int installedVersionCode;
  final String installedVersionName;
  final int installedAt;
  final String mainAbility;
  final String moduleName;

  /// 转为 StoreApp 以便复用列表组件。
  StoreApp asStoreApp() => StoreApp(
        id: appId,
        repo: repo,
        owner: repo.contains('/') ? repo.split('/').first : '',
        name: repo.contains('/') ? repo.split('/').last : repo,
        displayName: displayName,
        summary: summary,
        description: '',
        iconUrl: iconUrl,
        category: '',
        tags: const [],
        stars: 0,
        verified: false,
        featured: false,
        releasesCount: 0,
      );

  Map<String, dynamic> toJson() => {
        'appId': appId,
        'repo': repo,
        'displayName': displayName,
        'summary': summary,
        'iconUrl': iconUrl,
        'bundleName': bundleName,
        'installedVersionCode': installedVersionCode,
        'installedVersionName': installedVersionName,
        'installedAt': installedAt,
        'mainAbility': mainAbility,
        'moduleName': moduleName,
      };

  factory InstalledRecord.fromJson(Map<String, dynamic> j) => InstalledRecord(
        appId: (j['appId'] ?? 0) as int,
        repo: (j['repo'] ?? '') as String,
        displayName: (j['displayName'] ?? '') as String,
        summary: (j['summary'] ?? '') as String,
        iconUrl: (j['iconUrl'] ?? '') as String,
        bundleName: (j['bundleName'] ?? '') as String,
        installedVersionCode: (j['installedVersionCode'] ?? 0) as int,
        installedVersionName: (j['installedVersionName'] ?? '') as String,
        installedAt: (j['installedAt'] ?? 0) as int,
        mainAbility: (j['mainAbility'] ?? '') as String,
        moduleName: (j['moduleName'] ?? '') as String,
      );
}

/// 已安装记录的本地存储（JSON 文件，原子写）。
class InstalledStore {
  InstalledStore._(this._file, this._records);

  final File _file;
  final List<InstalledRecord> _records;

  List<InstalledRecord> get records => List.unmodifiable(_records);

  bool get isEmpty => _records.isEmpty;

  static Future<InstalledStore> load() async {
    final file = File('${await appDataDir()}/installed.json');

    final records = <InstalledRecord>[];
    try {
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is List) {
          for (final e in raw) {
            if (e is Map<String, dynamic>) {
              records.add(InstalledRecord.fromJson(e));
            }
          }
        }
      }
    } catch (_) {
      // 记录文件损坏不应导致启动失败
    }
    return InstalledStore._(file, records);
  }

  InstalledRecord? find(int appId) {
    for (final r in _records) {
      if (r.appId == appId) return r;
    }
    return null;
  }

  InstalledRecord? findBundle(int appId, String bundleName) {
    for (final r in _records) {
      if (r.appId == appId && r.bundleName == bundleName) return r;
    }
    return null;
  }

  /// 登记一次成功安装（按 bundleName 去重，同一应用多 bundle 时各记一条）。
  Future<void> remember(InstalledRecord record) async {
    _records.removeWhere((r) =>
        r.appId == record.appId && r.bundleName == record.bundleName);
    _records.insert(0, record);
    await _flush();
  }

  Future<void> forget(InstalledRecord record) async {
    // The row shown by Management is the stored object. Delete exactly that
    // row, even if legacy data contains duplicate or empty bundle names.
    final index = _records.indexWhere((r) => identical(r, record));
    if (index < 0) return;
    _records.removeAt(index);
    await _flush();
  }

  /// 原子写：先写 .tmp 再 rename，避免写入中断留下半个文件。
  Future<void> _flush() async {
    try {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(_records.map((e) => e.toJson()).toList()),
        flush: true,
      );
      if (await _file.exists()) await _file.delete();
      await tmp.rename(_file.path);
    } catch (_) {
      // 记录失败不影响安装本身
    }
  }
}
