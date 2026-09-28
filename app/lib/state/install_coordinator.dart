// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 安装编排 —— 把「商店发现 → 下载 → 预检 → 重签 → 安装」串成一条链。
//
// 这是整个 App 的核心流程。设计要点：
//
// 1) **先取得可用 Profile，再预检**。Profile 的自动重建发生在「预检之后」
//    是本模块最严重的历史缺陷：准备阶段只为商店自身包名申请过 Profile，
//    安装别的应用时预检会因为包名不符直接返回，重建逻辑根本没机会执行。
//    现在的顺序是「读包内真实信息 → 确保 Profile 可用（必要时自动重建）
//    → 对最终材料预检 → 签名 → 安装」。
// 2) **包名与权限来自包内**，不信服务端元数据：在线路径同样从下载到的
//    HAP 里读 `module.json`。服务端字段可能缺失，且 Profile 申请必须用
//    真实的权限声明（否则需要 ACL 的应用会 9568289）。
// 3) **每次安装独立工作目录**。多个应用同时安装时，不同仓库的 HAP 常常
//    同名，共用一个目录会互相删除/覆盖对方的中间产物。
// 4) **每一阶段都可取消**，且中间产物必清理（HAP 可能几十 MB）。
// 5) 全程向 UI 汇报阶段，让「安装」按钮能显示真实进度。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:signing_core/signing_core.dart';

import '../model/store_models.dart';
import '../net/downloader.dart';

/// 从 HAP 的 module.json 中读出的关键元数据。
///
/// 预检与 Profile 申请所需的 bundleName / minAPIVersion / 权限声明
/// 都必须来自**包本身** —— 服务端元数据可能缺失或过期。
class HapMetadata {
  HapMetadata({
    required this.bundleName,
    required this.minApi,
    required this.permissions,
    required this.versionCode,
    required this.versionName,
    required this.mainAbility,
    required this.moduleName,
  });

  final String bundleName;
  final int minApi;
  final List<String> permissions;
  final int versionCode;
  final String versionName;
  final String mainAbility;
  final String moduleName;
}

/// 读取 HAP 的元数据（module.json）。
///
/// 返回 null 表示包损坏或缺失 module.json —— 调用方应给出可读错误。
Future<HapMetadata?> readHapMetadata(File hap) async {
  HapReader? reader;
  try {
    reader = await HapReader.open(hap);
    final entry = reader.find('module.json');
    if (entry == null) return null;
    // module.json 是已知的小文件；给它一个明确的解压上限，
    // 避免被构造出来的异常条目拖垮内存。
    final json = jsonDecode(utf8
        .decode(await reader.readDecoded(entry, maxBytes: _metadataSizeLimit)));
    if (json is! Map<String, dynamic>) return null;

    final app = json['app'];
    final module = json['module'];
    final bundle = app is Map ? (app['bundleName'] ?? '') as String : '';
    final minApi = app is Map ? (app['minAPIVersion'] ?? 0) : 0;
    var code = app is Map ? (app['versionCode'] ?? 0) : 0;
    var name = app is Map ? (app['versionName'] ?? '') : '';
    final packEntry = reader.find('pack.info');
    if (packEntry != null) {
      try {
        final pack = jsonDecode(utf8.decode(
          await reader.readDecoded(packEntry, maxBytes: _metadataSizeLimit)));
        final summary = pack is Map ? pack['summary'] : null;
        final packApp = summary is Map ? summary['app'] : null;
        final version = packApp is Map ? packApp['version'] : null;
        if (version is Map) {
          code = version['code'] ?? code;
          name = version['name'] ?? name;
        }
      } catch (_) {}
    }
    return HapMetadata(
      bundleName: bundle,
      minApi: minApi is int ? minApi : int.tryParse('$minApi') ?? 0,
      permissions: extractRequestedPermissionsFrom(json),
      versionCode: code is int ? code : int.tryParse('$code') ?? 0,
      versionName: '$name',
      mainAbility: module is Map ? '${module['mainElement'] ?? ''}' : '',
      moduleName: module is Map ? '${module['name'] ?? ''}' : '',
    );
  } catch (_) {
    return null;
  } finally {
    await reader?.close();
  }
}

/// module.json 的合理上限（真实文件几 KB）。
const int _metadataSizeLimit = 8 * 1024 * 1024;

/// 安装链路的阶段。
enum InstallStage {
  idle,
  probing,
  downloading,
  verifying,
  preflight,
  provisioning,
  signing,
  installing,
  done,
  failed,
}

extension InstallStageText on InstallStage {
  String get label {
    switch (this) {
      case InstallStage.idle:
        return '';
      case InstallStage.probing:
        return '选择最快的下载线路…';
      case InstallStage.downloading:
        return '下载中';
      case InstallStage.verifying:
        return '校验文件完整性…';
      case InstallStage.preflight:
        return '检查签名材料…';
      case InstallStage.provisioning:
        return '更新设备授权…';
      case InstallStage.signing:
        return '重签中';
      case InstallStage.installing:
        return '安装中';
      case InstallStage.done:
        return '完成';
      case InstallStage.failed:
        return '失败';
    }
  }
}

/// 安装进度快照。
class InstallProgress {
  InstallProgress({
    required this.stage,
    this.stageDetail = '',
    this.received = 0,
    this.total = 0,
    this.error,
    this.issues = const [],
  });

  final InstallStage stage;
  final String stageDetail;
  final int received;
  final int total;

  /// 失败原因（人类可读）
  final String? error;

  /// 预检发现的问题（用于展示「为什么装不了」）
  final List<PreflightIssue> issues;

  double get ratio => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  /// Monotonic stage weighting for one circular progress indicator.
  double get overallRatio {
    switch (stage) {
      case InstallStage.idle: return 0;
      case InstallStage.probing: return stageDetail.contains('解析') ? 0.76 : 0.02;
      case InstallStage.downloading: return 0.03 + ratio * 0.70;
      case InstallStage.verifying: return 0.75;
      case InstallStage.provisioning: return 0.82;
      case InstallStage.preflight: return 0.88;
      case InstallStage.signing: return 0.93;
      case InstallStage.installing: return 0.98;
      case InstallStage.done: return 1;
      case InstallStage.failed: return 0;
    }
  }

  bool get isBusy =>
      stage != InstallStage.idle &&
      stage != InstallStage.done &&
      stage != InstallStage.failed;
}

/// 平台能力注入点。
///
/// 由 App 层实现（接 ohos_adapter / AGC），核心库只依赖契约。
class InstallPlatform {
  const InstallPlatform();

  /// Wait for a usable device channel at the point where signing needs it.
  Future<bool> ensureInstallConnection() async => true;

  /// 调用原生签名器（HarmonyOS 走 ohosAdapter.signCmd）。
  Future<void> sign(File input, File target, int minimumApi) {
    throw UnimplementedError('sign');
  }

  /// 调用 hdc 安装。
  Future<String?> install(String hapPath) {
    throw UnimplementedError('install');
  }

  /// 读取本机 UDID。
  Future<String?> deviceUdid() async => null;

  /// 获取可写的工作目录。
  Future<Directory> workDir() {
    throw UnimplementedError('workDir');
  }

  /// 设备授权（Profile）Provider；返回 null 表示不支持自动重建。
  ProfileProvider? profileProvider() => null;
}

/// 一次安装的结果。
class InstallOutcome {
  InstallOutcome({required this.ok, this.message, this.didRegenerate = false,
    this.bundleName = '', this.versionCode = 0, this.versionName = '',
    this.mainAbility = '', this.moduleName = ''});

  final bool ok;
  final String? message;

  /// 是否自动重建过设备授权（用于提示「已自动更新授权」）
  final bool didRegenerate;
  final String bundleName;
  final int versionCode;
  final String versionName;
  final String mainAbility;
  final String moduleName;
}

/// 安装编排器。
class InstallCoordinator {
  InstallCoordinator({
    required this.downloader,
    required this.platform,
    required this.onProgress,
  });

  final MirrorDownloader downloader;
  final InstallPlatform platform;
  final void Function(InstallProgress) onProgress;

  bool _cancelled = false;

  /// 工作目录名里的自增序号，保证同微秒内并发也不会撞名。
  static int _seq = 0;

  void cancel() => _cancelled = true;

  void _emit(InstallProgress p) {
    if (!_cancelled) onProgress(p);
  }

  /// 一键安装：下载 → 解析包 → 确保授权 → 预检 → 重签 → 安装。
  ///
  /// [asset] 可指定具体附件（详情页选版本时用）。
  Future<InstallOutcome> run({
    required StoreApp app,
    required HapAsset asset,
    required SignConfig signConfig,
  }) async {
    _cancelled = false;
    Directory? work;
    File? downloaded;
    try {
      work = await _newWorkDir();
      if (_cancelled) return InstallOutcome(ok: false, message: '已取消');

      // ── 1. 下载 ────────────────────────────────────────────────
      _emit(InstallProgress(stage: InstallStage.probing));
      final result = await downloader.download(
        asset: asset,
        destDir: work,
        onProgress: (dp) {
          _emit(InstallProgress(
            stage: _mapStage(dp.stage),
            received: dp.received,
            total: dp.total,
            stageDetail: dp.mirror.isEmpty ? '' : _shortUrl(dp.mirror),
          ));
        },
      );
      downloaded = result.file;
      if (_cancelled) return InstallOutcome(ok: false, message: '已取消');

      // ── 2..5 共用管线 ──────────────────────────────────────────
      return await _pipeline(
        hap: downloaded,
        work: work,
        signConfig: signConfig,
        // 服务端元数据只作为包内信息读不出来时的兜底
        fallbackBundleName: asset.bundleName.isNotEmpty
            ? asset.bundleName
            : app.repo.replaceAll('/', '.'),
        fallbackMinApi: asset.minApi,
      );
    } catch (e) {
      final msg = e is DownloadException ? e.message : '$e';
      _emit(InstallProgress(stage: InstallStage.failed, error: msg));
      return InstallOutcome(ok: false, message: msg);
    } finally {
      // 中间产物必清理：HAP 可能几十 MB，而这是手机沙箱。
      // 成功与失败都清，避免反复尝试把空间占满。
      if (downloaded != null) await _safeDelete(downloaded);
      if (work != null) await _safeDeleteDir(work);
    }
  }

  /// 离线安装一个本地 HAP：解析包 → 确保授权 → 预检 → 重签 → 安装。
  ///
  /// 与 [run] 的差异：没有下载阶段；**不删除用户选择的原文件**。
  Future<InstallOutcome> runLocal({
    required File hap,
    required SignConfig signConfig,
  }) async {
    _cancelled = false;
    Directory? work;
    try {
      work = await _newWorkDir();
      if (_cancelled) return InstallOutcome(ok: false, message: '已取消');
      return await _pipeline(
        hap: hap,
        work: work,
        signConfig: signConfig,
        fallbackBundleName: '',
        fallbackMinApi: 0,
      );
    } catch (e) {
      final msg = '$e';
      _emit(InstallProgress(stage: InstallStage.failed, error: msg));
      return InstallOutcome(ok: false, message: msg);
    } finally {
      // 只清理工作目录；用户选的原始文件留在原处。
      if (work != null) await _safeDeleteDir(work);
    }
  }

  /// 下载完成（或本地选中文件）之后的公共管线。
  ///
  /// 顺序有意如此：**先确保 Profile 可用，再预检**。
  /// 反过来会让「首次安装别的应用」必然失败 —— 那时的 Profile 还是为
  /// 商店自身包名申请的，预检一看包名不符就返回，重建根本没机会跑。
  Future<InstallOutcome> _pipeline({
    required File hap,
    required Directory work,
    required SignConfig signConfig,
    required String fallbackBundleName,
    required int fallbackMinApi,
  }) async {
    // ── 解析包：拿到真实的包名 / 权限 / minAPI ────────────────────
    _emit(InstallProgress(stage: InstallStage.probing, stageDetail: '解析安装包…'));
    final meta = await readHapMetadata(hap);
    final bundleName = meta != null && meta.bundleName.isNotEmpty
        ? meta.bundleName
        : fallbackBundleName;
    if (bundleName.isEmpty) {
      const msg = '无法读取安装包信息（缺失 module.json 或包已损坏）';
      _emit(InstallProgress(stage: InstallStage.failed, error: msg));
      return InstallOutcome(ok: false, message: msg);
    }
    final permissions = meta?.permissions ?? const <String>[];
    final minApi = (meta != null && meta.minApi > 0)
        ? meta.minApi
        : (fallbackMinApi > 0 ? fallbackMinApi : _defaultMinApi);
    if (_cancelled) return InstallOutcome(ok: false, message: '已取消');

    _emit(InstallProgress(stage: InstallStage.provisioning,
        stageDetail: '检查设备连接…'));
    if (!await platform.ensureInstallConnection()) {
      const msg = '未连接无线调试，安装已取消';
      _emit(InstallProgress(stage: InstallStage.failed, error: msg));
      return InstallOutcome(ok: false, message: msg);
    }
    var udid = await platform.deviceUdid();
    if ((udid == null || udid.isEmpty) &&
        await platform.ensureInstallConnection()) {
      udid = await platform.deviceUdid();
    }
    if (udid == null || udid.isEmpty) {
      const msg = '设备连接失效，请重新连接无线调试后重试';
      _emit(InstallProgress(stage: InstallStage.failed, error: msg));
      return InstallOutcome(ok: false, message: msg);
    }

    // ── 共享资源串行段 ───────────────────────────────────────────
    // Profile 路径、certId 都是**全局唯一**的：两个应用同时安装时，
    // 若各自并发地申请/写入 Profile，会互相覆盖，最终可能把 A 的包
    // 用 B 的 Profile 去签。这里把「确保授权 → 预检 → 签名 → 安装」串行化，
    // 下载（上面那段）仍然可以并行。
    return await _serialize(() async {
      // ── 确保 Profile 适用于**本机 + 本包**（必要时自动重建）──────
      final profileErr = await _ensureProfile(
        signConfig: signConfig,
        bundleName: bundleName,
        udid: udid,
        permissions: permissions,
      );
      if (profileErr != null) {
        _emit(InstallProgress(stage: InstallStage.failed, error: profileErr));
        return InstallOutcome(ok: false, message: profileErr);
      }
      if (_cancelled) return InstallOutcome(ok: false, message: '已取消');

      // ── 预检：对**最终**材料做签名前检查 ──────────────────────────
      _emit(InstallProgress(
          stage: InstallStage.preflight, stageDetail: '检查签名材料…'));
      final report = await preflightSigningMaterial(
        config: signConfig,
        targetBundleName: bundleName,
        deviceUdid: udid,
      );
      if (!report.canProceed) {
        final msg = _summarize(report);
        _emit(InstallProgress(
          stage: InstallStage.failed,
          error: msg,
          issues: report.issues,
        ));
        return InstallOutcome(ok: false, message: msg);
      }

      // ── 签名 ───────────────────────────────────────────────────
      _emit(InstallProgress(stage: InstallStage.signing, stageDetail: '重签中'));
      final signedFile =
          File('${work.path}/${_signedName(p.basename(hap.path))}');
      if (await signedFile.exists()) await signedFile.delete();

      final outcome = await _signWithFallback(
        input: hap,
        output: signedFile,
        signConfig: signConfig,
        bundleName: bundleName,
        udid: udid,
        permissions: permissions,
        minimumApi: minApi,
        skipProfileEnsure: true, // 上面已经确保过，避免重复调 AGC
      );
      if (!outcome.succeeded) {
        _emit(InstallProgress(
            stage: InstallStage.failed, error: outcome.message ?? '签名失败'));
        return InstallOutcome(ok: false, message: outcome.message);
      }

      // ── 安装 ───────────────────────────────────────────────────
      _emit(InstallProgress(stage: InstallStage.installing));
      final err = await platform.install(outcome.outputPath!);
      if (err != null) {
        _emit(InstallProgress(stage: InstallStage.failed, error: err));
        return InstallOutcome(ok: false, message: err);
      }

      _emit(InstallProgress(stage: InstallStage.done, stageDetail: '安装成功'));
      return InstallOutcome(
        ok: true,
        didRegenerate: outcome.didRegenerate || _regeneratedProfile,
        bundleName: bundleName,
        versionCode: meta?.versionCode ?? 0,
        versionName: meta?.versionName ?? '',
        mainAbility: meta?.mainAbility ?? '',
        moduleName: meta?.moduleName ?? '',
      );
    });
  }

  /// 串行化「共享签名材料」的关键段。
  ///
  /// Profile 文件路径与 AGC 证书 ID 都是全局共享的可变资源，多应用同时安装
  /// 时必须排队执行，否则会互相覆盖。下载等无共享状态的阶段不受影响，
  /// 仍然并行 —— 这样既保证正确性，又不牺牲最大的那段耗时（下载）。
  static Future<void> _mutationTail = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() action) async {
    final prev = _mutationTail;
    final gate = Completer<void>();
    _mutationTail = gate.future;
    try {
      await prev; // 等前一个结束；它的失败不应影响本次
    } catch (_) {
      // 忽略前序失败
    }
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  /// 本次安装是否重建过 Profile。
  bool _regeneratedProfile = false;

  /// 确保 Profile 可用于「本机 + [bundleName]」。
  ///
  /// 复用 signing_core 的判定与编排：材料可用时**不会**触发任何网络请求；
  /// 不适用时（缺失 / 包名不符 / 不含本机 UDID / 过期）才调 AGC 重建。
  ///
  /// 返回 null 表示可用；否则是给用户看的原因。
  /// 未接入 provider（未登录）时直接返回 null —— 交给预检给出可读提示。
  Future<String?> _ensureProfile({
    required SignConfig signConfig,
    required String bundleName,
    required String? udid,
    required List<String> permissions,
  }) async {
    final provider = platform.profileProvider();
    if (provider == null) {
      _regeneratedProfile = false;
      return null;
    }

    _emit(InstallProgress(
        stage: InstallStage.provisioning, stageDetail: '检查设备授权…'));
    try {
      final result = await ensureUsableProfile(
        request: ProfileRequest(
          packageName: bundleName,
          deviceUdid: udid ?? '',
          profilePath: signConfig.profilePath,
          certId: signConfig.certId,
          requestedPermissions: permissions,
          grantableAcls: provider.grantableAcls,
        ),
        provider: provider,
      );
      _regeneratedProfile = result.didRegenerate;
      if (result.ok) {
        if (result.didRegenerate) {
          _emit(InstallProgress(
              stage: InstallStage.provisioning, stageDetail: '已更新设备授权'));
        }
        return null;
      }
      final error = result.error ?? '未知原因';
      if (error.contains('aclPermissionList') &&
          error.contains('support scope')) {
        return '设备授权不可用：AGC 拒绝了本次 Profile 的 ACL 列表。'
            '请核对包内权限声明与提交的 ACL。原始错误：$error';
      }
      return '设备授权不可用：$error';
    } catch (e) {
      _regeneratedProfile = false;
      return '更新设备授权失败：$e';
    }
  }

  /// 签名并处理「非轻启包」回退：signHap 只处理轻启整包，
  /// 返回 handled=false 时改走普通单包签名（signPlain）。
  Future<SignResult> _signWithFallback({
    required File input,
    required File output,
    required SignConfig signConfig,
    required String bundleName,
    required String? udid,
    required List<String> permissions,
    required int minimumApi,
    bool skipProfileEnsure = false,
  }) async {
    final provider = skipProfileEnsure ? null : platform.profileProvider();
    var outcome = await signHap(
      input: input,
      output: output,
      profileBytes: await _readProfileBytes(signConfig),
      sign: platform.sign,
      progress: (msg) {
        _emit(InstallProgress(
          stage: msg.contains('设备授权')
              ? InstallStage.provisioning
              : InstallStage.signing,
          stageDetail: msg,
        ));
      },
      profileRequest: provider == null
          ? null
          : ProfileRequest(
              packageName: bundleName,
              deviceUdid: udid ?? '',
              profilePath: signConfig.profilePath,
              certId: signConfig.certId,
              requestedPermissions: permissions,
              grantableAcls: provider.grantableAcls,
            ),
      profileProvider: provider,
    );
    if (!outcome.handled) {
      _emit(
          InstallProgress(stage: InstallStage.signing, stageDetail: '普通包重签中'));
      outcome = await signPlain(
        input: input,
        output: output,
        minimumApi: minimumApi,
        sign: platform.sign,
      );
    }
    return outcome;
  }

  /// 每次安装一个独立的工作目录。
  ///
  /// 多个应用同时安装时，不同仓库的 HAP 常同名（`entry-default.hap`），
  /// 共用目录会互相删除/覆盖对方的下载与签名产物。
  Future<Directory> _newWorkDir() async {
    final base = await platform.workDir();
    final dir = Directory(p.join(
        base.path, 'job-${DateTime.now().microsecondsSinceEpoch}-${_seq++}'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    return dir;
  }

  /// 包内未声明 minAPIVersion 时的兜底值（不影响安装，只写进签名）。
  static const int _defaultMinApi = 5;

  Future<Uint8List> _readProfileBytes(SignConfig config) async {
    final f = File(config.profilePath);
    if (!await f.exists()) return Uint8List(0);
    return f.readAsBytes();
  }

  InstallStage _mapStage(DownloadStage s) {
    switch (s) {
      case DownloadStage.probing:
        return InstallStage.probing;
      case DownloadStage.downloading:
        return InstallStage.downloading;
      case DownloadStage.verifying:
        return InstallStage.verifying;
      case DownloadStage.done:
        return InstallStage.verifying;
      case DownloadStage.failed:
        return InstallStage.failed;
    }
  }

  static String _summarize(PreflightReport report) {
    if (report.errors.isEmpty) return '签名材料检查未通过';
    final first = report.errors.first;
    return first.hint != null
        ? '${first.message}\n${first.hint}'
        : first.message;
  }

  static String _shortUrl(String url) {
    if (url.length <= 40) return url;
    return '${url.substring(0, 20)}…${url.substring(url.length - 16)}';
  }

  static String _signedName(String name) {
    final base = p.basenameWithoutExtension(name);
    return '${base}_signed.hap';
  }

  static Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 清理失败不影响主流程
    }
  }

  static Future<void> _safeDeleteDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响主流程
    }
  }
}
