// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 全局安装状态。
//
// 商店的列表页与详情页都能触发安装，因此安装状态需要集中管理：
//   · 同一应用正在安装时，列表按钮与详情按钮显示同一份进度
//   · 已安装的应用，按钮变为「打开」
//
// 安装目标的选择规则：取该 release 里**第一个 .hap 附件**。
// 若同一个 release 挂了多个 HAP（例如轻启同时挂主包与助手包），
// 详情页会提供选择；列表页直接装第一个，并在详情页可改选后重装。

import 'package:flutter/foundation.dart';
import 'package:ohos_adapter/ohos_adapter.dart';
import 'package:signing_core/signing_core.dart';

import '../model/store_models.dart';
import '../net/api_client.dart';
import '../net/downloader.dart';
import 'install_coordinator.dart';
import 'installed_store.dart';

/// 单个应用的安装态。
class AppInstallState {
  AppInstallState({
    required this.stage,
    this.ratio = 0,
    this.detail = '',
    this.error,
    this.issues = const [],
  });

  final InstallStage stage;
  final double ratio;
  final String detail;
  final String? error;
  final List<PreflightIssue> issues;

  bool get busy =>
      stage != InstallStage.idle &&
      stage != InstallStage.done &&
      stage != InstallStage.failed;

  static AppInstallState idle() => AppInstallState(stage: InstallStage.idle);
}

/// 安装编排的全局控制器。
class InstallCenter extends ChangeNotifier {
  InstallCenter({
    required this.api,
    required this.downloader,
    required this.installed,
    required this.makeCoordinator,
    required this.signConfig,
  });

  final ApiClient api;
  final MirrorDownloader downloader;
  final InstalledStore installed;

  /// 构造协调器（注入平台能力）
  final InstallCoordinator Function(void Function(InstallProgress) onProgress)
      makeCoordinator;
  final SignConfig Function() signConfig;

  final Map<int, AppInstallState> _states = {};
  final Map<int, bool> _running = {};

  /// 累计「安装成功」次数（单调递增）。
  ///
  /// 供「更新」页等监听者感知「有应用装完了」并重查版本差：
  /// done 状态本身会一直留在 [_states] 里（详情页要靠它显示结果），
  /// 因此不能靠「出现过 done」判断，只能靠计数器的增量。
  int doneCounter = 0;

  AppInstallState stateOf(int appId) =>
      _states[appId] ?? AppInstallState.idle();

  bool isInstalled(int appId) => installed.find(appId) != null;

  Future<bool> openApp(int appId) async {
    final record = installed.find(appId);
    final bundle = record?.bundleName ?? '';
    if (bundle.isEmpty) return false;
    try {
      return await OhosAdapter().openInstalledApp(bundle,
          abilityName: record?.mainAbility ?? '',
          moduleName: record?.moduleName ?? '');
    } catch (_) {
      return false;
    }
  }

  bool isBusy(int appId) => stateOf(appId).busy;

  /// 一键安装某个应用。
  ///
  /// 会自动：拉取该应用最新版本 → 选中第一个 HAP → 下载 → 预检 → 重签 → 安装。
  /// [asset] 可指定具体附件（详情页选版本时用）。
  Future<void> installApp(StoreApp app, {HapAsset? asset}) async {
    if (_running[app.id] == true) return;
    _running[app.id] = true;

    try {
      final target = asset ?? await _pickAsset(app);
      if (target == null) {
        _set(
            app.id,
            AppInstallState(
              stage: InstallStage.failed,
              error: '该应用没有可安装的 HAP 附件',
            ));
        return;
      }

      // 从待装包里读出权限声明 —— 建 Profile 时要用（每个应用不同）
      final coordinator = makeCoordinator((p) {
        _set(
            app.id,
            AppInstallState(
              stage: p.stage,
              ratio: p.overallRatio,
              detail: p.stageDetail.isNotEmpty ? p.stageDetail : p.stage.label,
              error: p.error,
              issues: p.issues,
            ));
      });

      final outcome = await coordinator.run(
        app: app,
        asset: target,
        signConfig: signConfig(),
      );

      if (outcome.ok) {
        await installed.remember(InstalledRecord(
          appId: app.id,
          repo: app.repo,
          displayName: app.displayName,
          summary: app.summary,
          iconUrl: app.iconUrl,
          bundleName: outcome.bundleName.isNotEmpty ? outcome.bundleName : target.bundleName,
          installedVersionCode: outcome.versionCode > 0 ? outcome.versionCode : target.versionCode,
          installedVersionName: outcome.versionName.isNotEmpty ? outcome.versionName : target.versionName,
          installedAt: DateTime.now().millisecondsSinceEpoch,
          mainAbility: outcome.mainAbility,
          moduleName: outcome.moduleName,
        ));
        // 先递增再 _set：_set 会触发监听者，监听者要靠新值感知完成。
        doneCounter++;
        _set(
            app.id,
            AppInstallState(
              stage: InstallStage.done,
              detail: outcome.didRegenerate ? '安装成功（已自动更新设备授权）' : '安装成功',
            ));
      } else {
        _set(
            app.id,
            AppInstallState(
              stage: InstallStage.failed,
              error: outcome.message ?? '安装失败',
              issues: stateOf(app.id).issues,
            ));
      }
    } catch (e) {
      _set(
          app.id,
          AppInstallState(
            stage: InstallStage.failed,
            error: '安装流程异常：$e',
          ));
    } finally {
      _running[app.id] = false;
      notifyListeners();
    }
  }

  /// 拉取该应用的 HAP 并选中一个。
  Future<HapAsset?> _pickAsset(StoreApp app) async {
    final releases = await api.listReleases(app.id, pageSize: 10);
    for (final r in releases.items) {
      if (!r.hasHap) continue;
      return r.installableAssets.first;
    }
    return null;
  }

  void clear(int appId) {
    _states.remove(appId);
    notifyListeners();
  }

  void _set(int appId, AppInstallState s) {
    _states[appId] = s;
    notifyListeners();
  }
}
