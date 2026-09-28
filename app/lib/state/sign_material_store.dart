// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 签名材料管理。
//
// ── 设计取舍 ──────────────────────────────────────────────────────────
// 签名材料是三个小文件：证书链（.cer）、设备授权 Profile（.p7b）、私钥（key.pem）。
// 它们是**每个用户自己的**，不随应用分发。首次使用在本机生成密钥；
// 若账号证书满额，可通过加密备份恢复与现有证书配对的私钥。
// 鸿蒙应用沙箱隔离，星仓不能直接读取其他应用保存的密钥。
//
// ── 关于 Profile 的自动重建 ────────────────────────────────────────────
// 核心库已具备「判定 Profile 是否适用于本机 → 需要则重建」的完整编排
// （signing_core/provision.dart）。但**重建动作要调华为 AGC 云服务**，
// 需要 DevEco 登录态换来的 oauth2Token。本文件通过 [AgcProfileProvider]
// 留出接点；未注入 provider 时，预检会明确告知用户「Profile 不含本机 UDID」，
// 而不是让设备侧报 9568423 后再去猜。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:ohos_adapter/ohos_adapter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:signing_core/signing_core.dart';

import 'agc/agc_models.dart';
import 'identity_generator.dart';
import 'agc/agc_profile_provider.dart';
import 'agc/agc_service.dart';

/// 材料的持久化与选择。
class SignMaterialStore {
  SignMaterialStore._(this._file, this._config, this._provider);

  File _file;
  SignConfig _config;
  ProfileProvider? _provider;

  SignConfig get config => _config;

  /// 是否已经选好材料
  bool get hasCertificate =>
      _config.certPath.isNotEmpty &&
      _config.keystoreFile.isNotEmpty &&
      File(_config.certPath).existsSync() &&
      File(_config.keystoreFile).existsSync();

  bool get isComplete => hasCertificate &&
      _config.profilePath.isNotEmpty &&
      File(_config.profilePath).existsSync();

  /// 设备授权重建能力；未登录或未接入 AGC 时为 null。
  ProfileProvider? get provider => _provider;

  /// AGC 服务实例（材料就绪后创建）。
  AgcService? agc;

  /// AGC 侧的证书 ID（登录并选定证书后写入）。
  ///
  /// 直接代理 [_config.certId]：只有一份真相，且随配置一起落盘。
  /// 独立字段会与持久化配置失步（重启后丢失），进而让 Provider 退化成
  /// 「按名字猜证书」而可能复用不配对的那张。
  String get certId => _config.certId;
  set certId(String value) => _config = _config.copyWith(certId: value);

  /// 本次会话是否重建过签名身份（密钥对换过）。
  ///
  /// 换过密钥后，任何旧证书都不再与当前私钥配对，必须新建证书。
  bool _identityRegenerated = false;

  /// 本次会话是否重建过签名身份（供 [ensureCertificate] 判断能否复用旧证书）。
  bool get identityRegenerated => _identityRegenerated;

  Future<void> _log(String msg) async {
    try {
      await ohosAdapter.log('[material] $msg');
    } catch (_) {}
  }

  static Future<SignMaterialStore> load() async {
    final file = File(p.join(await appDataDir(), 'sign_material.json'));

    var cfg = const SignConfig();
    try {
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, dynamic>) {
          cfg = SignConfig.fromJson(raw);
        }
      }
    } catch (_) {
      // 配置损坏不应导致启动失败
    }
    final store = SignMaterialStore._(file, cfg, null);
    await store._restoreSession();
    await store._removeDuplicateRestoreBackup();
    return store;
  }

  /// 恢复同一把密钥时无需在沙箱里留第二份明文；旧版本留下的副本也清理。
  Future<void> _removeDuplicateRestoreBackup() async {
    if (_config.keystoreFile.isEmpty) return;
    final current = File(_config.keystoreFile);
    final previous = File('${_config.keystoreFile}.before-restore');
    try {
      if (!await current.exists() || !await previous.exists()) return;
      final currentHash = sha256.convert(await current.readAsBytes());
      final previousHash = sha256.convert(await previous.readAsBytes());
      if (currentHash != previousHash) return;
      await previous.delete();
      if (_config.csrPath.isNotEmpty) {
        final oldCsr = File('${_config.csrPath}.before-restore');
        if (await oldCsr.exists()) await oldCsr.delete();
      }
    } catch (_) {
      // 清理失败不影响现有签名材料。
    }
  }

  /// 恢复上次的登录态（若有）。失败不阻断启动。
  Future<void> _restoreSession() async {
    final raw = await _readAuth();
    if (raw == null) return;

    final auth = AuthInfo.fromJson(raw);
    final service = AgcService()..initUserInfo(auth);
    agc = service;

    // 校验登录态是否仍有效；无效则清掉，避免用户以为还登着
    try {
      final ok = await service.checkSignedIn();
      if (!ok) {
        await _clearAuth();
        agc = null;
        return;
      }
    } catch (_) {
      // 网络不可达时保留本地登录态，允许离线查看
    }
    _attachProvider();
  }

  /// 注入/替换 AGC Profile 重建能力。
  void attachProfileProvider(ProfileProvider? provider) {
    _provider = provider;
  }

  /// 根据当前材料与登录态，构造并附加 AGC Provider。
  ///
  /// 这是「换设备自动重建授权」的实际接线点：只要材料齐全且已登录，
  /// Provider 就会就位，`signHap` 便会在预检发现 Profile 不适用时自动重建。
  void _attachProvider() {
    final service = agc;
    if (service == null || !service.isSignedIn) {
      _provider = null;
      return;
    }
    if (_config.profilePath.isEmpty) {
      _provider = null;
      return;
    }
    // CSR 与私钥配对，只在需要新建证书时才用得到。
    // 优先用配置里已记录的（自动生成流程会写），否则按密钥库同名推导。
    final csrPath = _config.csrPath.isNotEmpty
        ? _config.csrPath
        : p.setExtension(_config.keystoreFile, '.csr');

    _provider = AgcProfileProvider(
      agc: service,
      csrPath: csrPath,
      keyPath: _config.keystoreFile,
      certPath: _config.certPath,
      // Profile 名称按 bundle 生成（provider 内部会补上包名）
      profileName: 'hapstore-debug',
      // 用**配置里**的 certId（已落盘），而不是某个运行时副本：
      // 进程重启后仍能精确命中当初与私钥配对的那张证书。
      certId: _config.certId,
      certName: _certNameForCurrentKey(),
      // Provider 解析/新建出 certId 后立刻落盘。否则重启后退回
      // 「按名字猜证书」，可能复用一张与当前私钥**不配对**的同名证书。
      onCertIdResolved: (id) => update(certId: id),
    );
  }

  /// 是否已登录华为账号。
  bool get isSignedIn => agc?.isSignedIn ?? false;

  /// 账号展示名。
  String get accountLabel {
    final info = agc?.authInfo;
    if (info == null) return '未登录';
    final nick = info.nickName;
    if (nick != null && nick.isNotEmpty && !nick.contains('*') &&
        !nick.contains('＊')) return nick;
    return info.userId ?? '已登录';
  }

  String get accountAvatarUrl {
    final url = agc?.authInfo?.avatarUrl ?? '';
    return Uri.tryParse(url)?.scheme == 'https' ? url : '';
  }
  /// 优先用开发者登录态从华为开放资料接口读取头像；失败时再请求
  /// Account Kit 的 profile 授权。
  Future<String?> fetchAccountAvatar() async {
    final info = agc?.authInfo;
    if (info == null) return '请先登录华为开发者账号';
    if (await refreshDeveloperAvatar()) return null;
    try {
      final profile = await ohosAdapter.getHuaweiProfile(force: true);
      final avatar = profile?['avatarUrl'] as String? ?? '';
      final nick = profile?['nickName'] as String? ?? '';
      if (nick.isNotEmpty && !nick.contains('*') && !nick.contains('＊')) {
        info.nickName = nick;
      }
      if (Uri.tryParse(avatar)?.scheme != 'https') {
        await _writeAuth(info);
        return '华为帐号未返回可用头像，请检查帐号是否设置了头像';
      }
      info.avatarUrl = avatar;
      await _writeAuth(info);
      return null;
    } on PlatformException catch (e) {
      if (e.message?.contains('1001502003') == true) {
        return '请先在 AGC 为本应用配置 Client ID，再获取华为帐号头像';
      }
      return '获取华为帐号头像失败：${e.message ?? e.code}';
    } catch (e) {
      return '获取头像失败：$e';
    }
  }

  /// 后台静默获取头像，不弹出 Account Kit 授权页。
  Future<bool> refreshDeveloperAvatar() async {
    final info = agc?.authInfo;
    if (info == null) return false;
    final hadAvatar = Uri.tryParse(info.avatarUrl ?? '')?.scheme == 'https';
    final hadName = info.nickName?.isNotEmpty == true &&
        !info.nickName!.contains('*') && !info.nickName!.contains('＊');
    if (hadAvatar && hadName) return true;
    // DevEco OAuth 的 accessToken 也可调用华为开放帐号资料接口。
    // HoKit 使用同一接口；优先复用现有登录态，无须额外 AGC Client ID。
    try {
      final profile = await _openUserProfile(
          info.accessToken ?? '', info.userId ?? '');
      final avatar = profile['avatarUrl'] ?? '';
      final nick = profile['displayName'] ?? '';
      if (nick.isNotEmpty && !nick.contains('*') && !nick.contains('＊')) {
        info.nickName = nick;
        await _writeAuth(info);
      }
      if (Uri.tryParse(avatar)?.scheme == 'https') {
        info.avatarUrl = avatar;
        await _writeAuth(info);
        return true;
      }
    } catch (_) {
      // 某些账号未给开放资料权限；静默路径保留默认头像。
    }
    return hadAvatar;
  }

  Future<Map<String, String>> _openUserProfile(
      String accessToken, String expectedUserId) async {
    if (accessToken.isEmpty || expectedUserId.isEmpty) return const {};
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.https('account.cloud.huawei.com', '/rest.php',
          {'nsp_svc': 'GOpen.User.getInfo'});
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 12));
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded',
          charset: 'utf-8');
      request.write(Uri(queryParameters: {
        'access_token': accessToken,
        'getNickName': '1',
      }).query);
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) return const {};
      final body = await response.transform(utf8.decoder).join()
          .timeout(const Duration(seconds: 12));
      final data = jsonDecode(body);
      if (data is! Map) return const {};
      if ((data['userID'] ?? '').toString() != expectedUserId) return const {};
      return {
        'avatarUrl': (data['headPictureURL'] ?? data['headPicUrl'] ?? '').toString(),
        'displayName': (data['displayName'] ?? '').toString(),
      };
    } finally {
      client.close(force: true);
    }
  }

  /// 确保本机拥有一套**唯一**的签名身份（密钥对 + CSR）。
  ///
  /// ── 为什么不沿用「小白」的做法 ────────────────────────────────────
  /// 原「小白」把 key.pem 与 xiaobai.csr 作为随包资源分发，**所有用户共用
  /// 同一把私钥**。这有两个问题：
  ///   1. 私钥随 HAP 公开分发，任何人反编译即可取得
  ///   2. 用户用它从 AGC 换到的证书，也就等于人人可用
  /// 正确做法是每台设备生成唯一密钥对 —— 本方法就是做这件事。
  ///
  /// 生成依赖内置的原生签名器（`signtool generate-keypair`），
  /// 因此手机上不需要 OpenSSL。
  ///
  /// 已存在则直接返回，不重复生成。
  /// 生成/复用本机唯一的签名身份。
  ///
  /// [generateKeyPair] / [generateCsr] 保留为可选注入点（便于测试），
  /// 但**默认路径是纯 Dart 生成** —— 因为设备内签名器的这两个子命令
  /// 报告成功却不产出文件（见 identity_generator.dart 顶部说明）。
  Future<String?> ensureIdentity({
    Future<bool> Function({
      required String keystorePath,
      required String keyAlias,
      required String password,
    })?
        generateKeyPair,
    Future<String?> Function({
      required String keystorePath,
      required String outPath,
      required String keyAlias,
      required String password,
      required String subject,
    })?
        generateCsr,
  }) async {
    // 密钥库放在**持久私有目录**（沙箱 filesDir），不放临时目录。
    //
    // 历史上这里用 tempDir：早期发现「向 filesDir 写时签名器不产出文件」，
    // 于是整条身份链都落在临时目录。但那个问题只影响**原生签名器的
    // generate-keypair**（已弃用，现改为纯 Dart 生成），而把长期身份放在
    // 临时目录的代价很大 —— 系统清理临时目录后私钥与 CSR 直接消失，
    // 下次启动会生成新密钥，于是与已签发的证书、已下载的 Profile 全部失配。
    //
    // 文件名固定为 identity：便于旧版本遗留文件被复用（见 _migrateIdentity）。
    final keyDir = await _identityDir();
    // 未加密 PKCS#8 PEM —— 与「小白」的 key.pem 同格式，
    // 签名器按 PEM 解析、忽略口令。
    final keyPath = p.join(keyDir, 'identity.pem');
    final csrPath = p.join(keyDir, 'identity.csr');
    const alias = 'hapstore';

    // 已有完整的密钥对 + CSR → 复用
    final keyFile = File(keyPath);
    final csrFile = File(csrPath);
    // P-256 PKCS#8 PEM 通常只有约 241 字符。旧阈值 >256 会把每次生成的
    // 合法私钥判为损坏，下一次登录便覆盖密钥，导致 AGC 证书全部失配。
    var keyOk = false;
    if (await keyFile.exists()) {
      try {
        keyOk = isUsableIdentityKey(await keyFile.readAsString());
      } catch (_) {
        keyOk = false;
      }
    }
    var csrOk = false;
    if (keyOk && await csrFile.exists()) {
      try {
        csrOk = isCsrKeyPaired(
          privateKeyPem: await keyFile.readAsString(),
          csrPem: await csrFile.readAsString(),
        );
      } catch (_) {}
    }

    // 私钥还在时只补建 CSR；重建私钥会让已占用的 AGC 证书无法复用。
    if (keyOk && !csrOk) {
      try {
        final csr = generateCsrForPrivateKey(await keyFile.readAsString(),
            subject: 'C=CN,O=HapStore,OU=Device,CN=$alias');
        await csrFile.writeAsString(csr, flush: true);
        await _log('已用原私钥补建 CSR，保留现有证书身份');
      } catch (e) {
        return '证书请求损坏且无法从现有私钥恢复：$e';
      }
    }
    if (!keyOk) {
      await _log('纯 Dart 生成身份 → $keyPath');
      try {
        final gen = generateIdentity(
          subject: 'C=CN,O=HapStore,OU=Device,CN=$alias',
        );
        await keyFile.parent.create(recursive: true);
        await keyFile.writeAsString(gen.privateKeyPem, flush: true);
        await csrFile.writeAsString(gen.csrPem, flush: true);
        await _log('身份生成成功：私钥 ${gen.privateKeyPem.length} 字符，'
            'CSR ${gen.csrPem.length} 字符');
      } catch (e) {
        await _log('身份生成失败：$e');
        return '无法生成签名密钥：$e';
      }
      // 换了密钥 ⇒ 旧的证书/Profile 都不再配对，必须一并作废，
      // 否则后续流程会「复用同名证书」，得到一个装不上的签名。
      _identityRegenerated = true;
      await _invalidateIdentityArtifacts();
    }

    // 校验收尾：产物必须真的可读且足够长
    if (!await keyFile.exists() || await keyFile.length() < 100) {
      return '签名密钥写入失败（$keyPath）';
    }
    if (!await csrFile.exists() || await csrFile.length() < 100) {
      return '证书请求写入失败（$csrPath）';
    }

    // 写入配置：后续签名与 AGC 都用这一套。
    //
    // profilePath 必须在这里就给出默认位置：`_attachProvider()` 在它为空的
    // 时候不会创建 AGC Provider，而 Profile 又只能由 Provider 申请 ——
    // 两者互相等待会形成死锁（profilePath 永远为空）。
    await update(
      keystoreFile: keyPath,
      csrPath: csrPath,
      certPath: _config.certPath.isEmpty
          ? p.join(keyDir, 'identity.cer')
          : _config.certPath,
      profilePath: _config.profilePath.isEmpty
          ? p.join(keyDir, 'identity.p7b')
          : _config.profilePath,
      keyAlias: alias,
    );
    // 未加密 PEM 私钥不需要口令：签名器按 PEM 解析时用占位值。
    _config = _config.copyWith(keystorePwd: '');
    await _flush();
    return null;
  }

  /// 作废与旧密钥绑定的证书与 Profile。
  ///
  /// 密钥换过之后，这两样东西在密码学上已经不匹配当前私钥：
  ///   · 留着证书 → `ensureCertificate` 会「复用同名证书」，签出来的包装不上
  ///   · 留着 Profile → 预检以为材料齐全，实际绑的是旧证书
  /// 因此必须同时清掉「本地文件」与「配置里的 certId」。
  Future<void> _invalidateIdentityArtifacts() async {
    _config = _config.copyWith(certId: '');
    for (final path in [_config.certPath, _config.profilePath]) {
      if (path.isEmpty) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 删不掉不影响主流程：certId 已清空，会走新建路径
      }
    }
    await _flush();
    await _log('已作废旧证书与 Profile（密钥已更换）');
  }

  /// 存放签名身份的目录。
  ///
  /// 用**应用私有持久目录**（沙箱 filesDir）。临时目录会被系统清理，
  /// 放在那里的私钥丢失后会重新生成密钥，导致证书/Profile 全部失配。
  Future<String> _identityDir() async {
    final base = await appDataDir();
    final dir = Directory(p.join(base, 'identity'));
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {
      // 建目录失败时退回数据目录本身，至少不是临时目录
      return base;
    }
    await _migrateIdentity(dir);
    return dir.path;
  }

  /// 把旧版本留在临时目录里的身份搬到持久目录。
  ///
  /// 迁移而非重新生成，是为了保住已签发的证书与已下载的 Profile ——
  /// 重新生成会让它们全部作废，用户需要重新走一遍 AGC 流程。
  Future<void> _migrateIdentity(Directory target) async {
    final pem = File(p.join(target.path, 'identity.pem'));
    final csr = File(p.join(target.path, 'identity.csr'));
    try {
      if (await pem.exists() && await csr.exists()) return; // 已是完整身份
    } catch (_) {
      return;
    }
    try {
      final t = await ohosAdapter.tempDir();
      if (t == null || t.isEmpty) return;
      for (final name in ['identity.pem', 'identity.csr']) {
        final src = File(p.join(t, name));
        if (!await src.exists()) continue;
        final dst = File(p.join(target.path, name));
        if (await dst.exists()) continue;
        await src.copy(dst.path);
        await _log('已把身份文件从临时目录迁出：$name');
      }
    } catch (_) {
      // 迁移失败就当作没有旧身份，走重新生成
    }
  }

  /// 用已生成的 CSR 向 AGC 申请调试证书并下载到本地。
  ///
  /// 这是「身份准备」的最后一步：密钥对 → CSR → **证书** → Profile。
  /// 之后签名所需的三个文件（密钥库 / 证书 / Profile）就齐了，
  /// 用户全程不需要接触任何文件。
  ///
  /// 返回 null 表示成功，否则是给用户看的原因。
  Future<String?> ensureCertificate({bool allowLastSlot = false}) async {
    final service = agc;
    if (service == null || !service.isSignedIn) {
      return '请先登录华为账号';
    }
    final csrFile = File(_config.csrPath);
    if (!await csrFile.exists()) {
      return '缺少证书请求文件（CSR），请重新登录以生成';
    }

    try {
      final certs = await service.getCertList();
      final currentCertName = _certNameForCurrentKey();
      final debug = certs.where((c) => c.isDebug).toList();
      await _log('AGC 证书：调试 ${debug.length} 张，其他 ${certs.length - debug.length} 张；'
          '本次重建身份=$_identityRegenerated');

      final certFile = File(_config.certPath.isEmpty
          ? p.join(_file.parent.path, 'identity.cer')
          : _config.certPath);

      // 先复用记录的 ID、同名证书，再核验账号下其他调试证书。
      // 历史版本改过命名规则；只按名字查会错误地认为槽位已满。
      CertInfo? chosen;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final valid = debug.where((c) =>
          c.expireTime == 0 || c.expireEpochSeconds > now);
      final candidates = <CertInfo>[
        ...valid.where((c) => c.id == _config.certId),
        ...valid.where((c) => c.certName == currentCertName && c.id != _config.certId),
        ...valid.where((c) => c.id != _config.certId && c.certName != currentCertName),
      ];
      for (final candidate in candidates) {
        // 精确记录过 ID 时，本地证书与私钥配对即可复用，不再下载一次。
        if (candidate.id == _config.certId && !_identityRegenerated) {
          final local = await _readIfPresent(certFile);
          if (local != null &&
              isKeyCertPaired(
                    privateKeyPem: await File(_config.keystoreFile).readAsString(),
                    certificate: local,
                  ) ==
                  true) {
            chosen = candidate;
            break;
          }
        }
        final paired = await _certPairsWithKey(candidate, certFile, service);
        if (paired == null) return '无法下载或校验 AGC 证书，请检查网络后重试';
        if (paired) {
          chosen = candidate;
          break;
        }
      }

      late String id;
      CertInfo? createdCert;
      if (chosen != null) {
        id = chosen.id;
      } else {
        // AGC 是团队资源，不能凭同名或过期时间自动删除他人的证书。
        if (debug.length >= 3) {
          return '3 个调试证书槽位已满，且都不与本机私钥配对。请在证书管理中核对后删除一张不用的证书，或恢复该证书原私钥';
        }
        if (debug.length == 2 && !allowLastSlot) {
          return 'AGC 仅剩最后一个调试证书槽位。请先核对已有证书；确认需要为本机新建时，再点「占用最后槽位」';
        }
        final csr = await csrFile.readAsString();
        final created = await service.createCert(currentCertName, 1, csr);
        createdCert = created;
        id = created.id;
      }

      if (createdCert != null &&
          await _certPairsWithKey(createdCert, certFile, service) != true) {
        return '新建的证书下载失败或与当前私钥不配对';
      }

      // 更换证书后旧 Profile 仍可能在本机，但它绑定的是旧证书。
      // 清掉入口文件；按证书 ID 分开的本地缓存会自动避开旧缓存。
      if (_config.certId != id && _config.profilePath.isNotEmpty) {
        try {
          final oldProfile = File(_config.profilePath);
          if (await oldProfile.exists()) await oldProfile.delete();
        } catch (_) {
          return '证书已更换，但旧设备授权无法清理，请检查本机文件权限';
        }
      }
      certId = id;

      // 证书已与证书 ID 对齐，这一轮的身份-证书配对关系就此确立。
      _identityRegenerated = false;
      await update(certPath: certFile.path, certId: id);
      _attachProvider();
      return null;
    } on AgcException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// 恢复同一开发者账号已签发的签名身份。只接受与 AGC 现有调试证书
  /// **密码学配对**的私钥，并且不覆盖正在使用的本机证书。
  ///
  /// 账号证书槽位已满时，复用原私钥比删除别的设备的证书安全。入参应是
  /// 从加密备份解出的明文，不应经公共目录传递。
  Future<String?> restoreExistingIdentity(String pem) async {
    final service = agc;
    if (service == null || !service.isSignedIn) return '请先登录华为开发者账号';
    if (hasCertificate) return '本机已有可用证书，无需替换签名身份';

    if (!isUsableIdentityKey(pem)) return '备份中的私钥不是可用的 P-256 密钥';

    final dir = Directory(await _identityDir());
    CertInfo? matched;
    List<int>? matchedCert;
    try {
      final certs = await service.getCertList();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final cert in certs.where((c) => c.isDebug &&
          (c.expireTime == 0 || c.expireEpochSeconds > now))) {
        if (cert.certObjectId.isEmpty) continue;
        final urls = await service.downloadObj(cert.certObjectId);
        if (urls.isEmpty) continue;
        final candidate = File(p.join(dir.path, '.restore-candidate.cer'));
        try {
          if (!await service.downloadFile(urls.first.newUrl, candidate.path)) {
            continue;
          }
          final bytes = await _readIfPresent(candidate);
          if (bytes != null &&
              isKeyCertPaired(privateKeyPem: pem, certificate: bytes) == true) {
            matched = cert;
            matchedCert = bytes;
            break;
          }
        } finally {
          if (await candidate.exists()) await candidate.delete();
        }
      }
    } on AgcException catch (e) {
      return '核对 AGC 证书失败：${e.message}';
    } catch (e) {
      return '核对 AGC 证书失败：$e';
    }
    if (matched == null || matchedCert == null) {
      return '该私钥与当前账号的有效调试证书均不匹配；本机身份没有改动';
    }

    final key = File(p.join(dir.path, 'identity.pem'));
    final csr = File(p.join(dir.path, 'identity.csr'));
    final cert = File(p.join(dir.path, 'identity.cer'));
    final newKey = File('${key.path}.restore');
    final newCsr = File('${csr.path}.restore');
    final newCert = File('${cert.path}.restore');
    final oldKey = File('${key.path}.before-restore');
    final oldCsr = File('${csr.path}.before-restore');
    try {
      final csrPem = generateCsrForPrivateKey(pem,
          subject: 'C=CN,O=HapStore,OU=Device,CN=hapstore');
      await newKey.writeAsString(pem, flush: true);
      await newCsr.writeAsString(csrPem, flush: true);
      await newCert.writeAsBytes(matchedCert, flush: true);
      if (await oldKey.exists()) await oldKey.delete();
      if (await oldCsr.exists()) await oldCsr.delete();
      if (await key.exists()) await key.rename(oldKey.path);
      if (await csr.exists()) await csr.rename(oldCsr.path);
      await newKey.rename(key.path);
      await newCsr.rename(csr.path);
      await newCert.rename(cert.path);
      if (_config.profilePath.isNotEmpty) {
        final profile = File(_config.profilePath);
        if (await profile.exists()) await profile.delete();
      }
      _identityRegenerated = false;
      await update(
        keystoreFile: key.path,
        csrPath: csr.path,
        certPath: cert.path,
        profilePath: p.join(dir.path, 'identity.p7b'),
        certId: matched.id,
        keyAlias: 'hapstore',
        keystorePwd: '',
      );
      _attachProvider();
      await _removeDuplicateRestoreBackup();
      await _log('已恢复现有签名身份，复用 AGC 调试证书 ${matched.id}');
      return null;
    } catch (e) {
      // 文件提交失败时保留原有私钥；下一次登录仍能走原流程。
      try {
        if (await oldKey.exists()) {
          if (await key.exists()) await key.delete();
          await oldKey.rename(key.path);
        }
        if (await oldCsr.exists()) {
          if (await csr.exists()) await csr.delete();
          await oldCsr.rename(csr.path);
        }
      } catch (_) {}
      return '恢复签名身份失败：$e';
    } finally {
      for (final f in [newKey, newCsr, newCert]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// 判断 [cert] 是否与当前私钥配对。
  ///
  /// 每次从 AGC 按选中的 ID 下载，验证配对后才替换本地文件。
  Future<bool?> _certPairsWithKey(
      CertInfo cert, File certFile, AgcService service) async {
    try {
      final keyPem = await File(_config.keystoreFile).readAsString();

      if (cert.certObjectId.isEmpty) return null;
      final urls = await service.downloadObj(cert.certObjectId);
      if (urls.isEmpty) return null;
      await certFile.parent.create(recursive: true);
      final temp = File('${certFile.path}.download');
      try {
        if (!await service.downloadFile(urls.first.newUrl, temp.path))
          return null;
        final bytes = await _readIfPresent(temp);
        if (bytes == null) return null;
        final paired =
            isKeyCertPaired(privateKeyPem: keyPem, certificate: bytes);
        if (paired == null) return null;
        if (!paired) return false;
        await temp.rename(certFile.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      return true;
    } catch (e) {
      await _log('证书配对校验异常：$e');
      return null;
    }
  }

  /// 读取文件中已有内容；不存在或过短（明显不是证书）时返回 null。
  Future<List<int>?> _readIfPresent(File f) async {
    try {
      if (!await f.exists() || await f.length() < 256) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// AGC 的证书名必须唯一。把公钥指纹放进名称，重建身份时不会与
  /// 旧身份的证书重名，同时也能在下次登录时准确找到本机证书。
  String _certNameForCurrentKey() {
    try {
      final pem = File(_config.keystoreFile).readAsStringSync();
      final point = publicKeyPointOfPrivateKey(pem);
      return '$kDebugCertName-${sha256.convert(point).toString().substring(0, 10)}';
    } catch (_) {
      return kDebugCertName;
    }
  }

  /// 取得（必要时创建）AGC 服务实例。
  ///
  /// 登录前也要能拿到实例：`getAuthInfoBytempToken` 是它的方法。
  AgcService ensureAgc() => agc ??= AgcService();

  /// 保存登录态并附加 Provider。
  Future<void> saveAuth(AuthInfo info) async {
    ensureAgc().initUserInfo(info);
    await _writeAuth(info);
    _attachProvider();
  }

  /// 退出登录。
  Future<void> signOut() async {
    agc = null;
    _provider = null;
    await _clearAuth();
  }

  File get _authFile => File(p.join(_file.parent.path, 'agc_auth.json'));

  Future<Map<String, dynamic>?> _readAuth() async {
    // 先看当前路径
    final cur = await _tryRead(_authFile);
    if (cur != null) return cur;

    // 回退到旧路径：早期版本用 path_provider，它在鸿蒙上没有实现，
    // 于是配置落到了 systemTemp（可达目录）。已有登录态的用户从旧路径迁移，
    // 免去重新登录。
    for (final legacy in _legacyAuthPaths()) {
      final d = await _tryRead(File(legacy));
      if (d != null) {
        try {
          await _authFile.parent.create(recursive: true);
          await _authFile.writeAsString(jsonEncode(d), flush: true);
        } catch (_) {}
        return d;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _tryRead(File f) async {
    try {
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      return raw is Map<String, dynamic> ? raw : null;
    } catch (_) {
      return null;
    }
  }

  /// 可能的旧存放位置。
  ///
  /// 不硬编码绝对路径：从 `appDir()`（鸿蒙上是 `<sandbox>/haps/entry/files`）
  /// 推导同级的 cache 与 temp 目录，这样换应用/换设备都成立。
  List<String> _legacyAuthPaths() {
    final out = <String>[];

    // 早期版本回退到 systemTemp，即 <entry>/temp
    try {
      out.add(p.join(Directory.systemTemp.path, 'agc_auth.json'));
    } catch (_) {}

    // 从当前数据目录推导同级目录
    try {
      final entry = p.dirname(_file.parent.path); // <entry>
      out.add(p.join(entry, 'cache', 'agc_auth.json'));
      out.add(p.join(entry, 'temp', 'agc_auth.json'));
    } catch (_) {}

    return out;
  }

  Future<void> _writeAuth(AuthInfo info) async {
    try {
      await _authFile.writeAsString(jsonEncode(info.toJson()), flush: true);
    } catch (_) {
      // 持久化失败不影响本次会话
    }
  }

  Future<void> _clearAuth() async {
    try {
      if (await _authFile.exists()) await _authFile.delete();
    } catch (_) {
      // 忽略
    }
  }

  /// 用文件选择器导入三类材料。
  ///
  /// 返回 null 表示全部成功；否则返回人类可读的错误。
  Future<String?> pickAll() async {
    try {
      final cert = await ohosAdapter.selectFile(['cer', 'pem']);
      if (cert == null || cert.isEmpty) return '未选择证书';

      final profile = await ohosAdapter.selectFile(['p7b']);
      if (profile == null || profile.isEmpty) return '未选择 Profile';

      final key = await ohosAdapter.selectFile(['pem', 'key']);
      if (key == null || key.isEmpty) return '未选择私钥';

      await update(certPath: cert, profilePath: profile, keystoreFile: key);
      return null;
    } catch (e) {
      return '选择材料失败：$e';
    }
  }

  Future<void> update({
    String? certPath,
    String? profilePath,
    String? keystoreFile,
    String? csrPath,
    String? keystorePwd,
    String? keyAlias,
    String? certId,
  }) async {
    _config = _config.copyWith(
      certPath: certPath,
      profilePath: profilePath,
      keystoreFile: keystoreFile,
      csrPath: csrPath,
      keystorePwd: keystorePwd,
      keyAlias: keyAlias,
      // certId 必须进 _config 才能落盘 —— 只写运行时字段的话，
      // 重启后 config.certId 为空，Provider 会退化成「按名字找证书」，
      // 于是可能复用一张与当前私钥**不配对**的同名证书。
      certId: certId,
    );
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _file.writeAsString(jsonEncode(_config.toJson()), flush: true);
    } catch (_) {
      // 持久化失败不影响本次会话使用
    }
  }

  /// 一次性读取 Profile 字节（很小）。
  Future<List<int>> readProfile() async {
    final f = File(_config.profilePath);
    if (!await f.exists()) return <int>[];
    return f.readAsBytes();
  }

  /// 材料健康度摘要，用于「我的」页展示。
  Future<String> describe() async {
    if (!hasCertificate) return '签名证书尚未就绪';
    final parts = <String>[];

    // 先区分「文件不存在」与「解析失败」——两者给用户的动作完全不同：
    // 前者等登录后自动申请，后者才需要排查。
    final profileFile = File(_config.profilePath);
    if (!await profileFile.exists()) {
      return '证书已就绪 · 首次安装时自动申请设备授权';
    }
    try {
      final profile = await inspectProfile(await profileFile.readAsBytes());
      parts.add('当前设备授权已就绪');
      parts.add('${profile.deviceIds.length} 台设备');
      if (profile.notAfter != null) {
        parts.add('到期 ${profile.notAfter!.toIso8601String().substring(0, 10)}');
      }
    } catch (e) {
      parts.add('Profile 解析失败：$e');
    }
    return parts.join(' · ');
  }
}

/// AGC Profile 重建能力的契约。
///
/// 具体实现在 `agc/agc_profile_provider.dart`（`AgcProfileProvider`）：
/// 它调 AGC 完成「登记设备 → 复用/新建证书 → 创建 Profile → 下载」，
/// 让「换设备无需手动重置证书」真正闭环。
///
/// 前置条件是 DevEco 登录态（oauth2Token），登录流程见
/// `agc/huawei_login.dart`。
abstract class AgcProviderContract implements ProfileProvider {
  /// 是否已登录。未登录时不应尝试重建，而是给出可读提示。
  bool get isSignedIn;

  /// 账号展示名，用于「我的」页。
  String get accountLabel;
}

/// 应用私有数据目录。
///
/// 优先用 ohos_adapter 的 `appDir()`（鸿蒙上是 `context.filesDir`，
/// 沙箱内、重启后仍在）。**不要依赖 path_provider** —— 它没有鸿蒙
/// 实现（GeneratedPluginRegistrant 里只注册了 ohos_adapter），
/// `getApplicationSupportDirectory()` 会抛异常。
///
/// 曾因回退到 `Directory.systemTemp` 导致生成的密钥与配置写到临时目录，
/// 重启即丢，表现为「登录后什么都没发生」。
Future<String> appDataDir() async {
  try {
    final d = await ohosAdapter.appDir();
    if (d != null && d.isNotEmpty) return d;
  } catch (_) {
    // 非鸿蒙环境（测试/桌面）
  }
  try {
    final d = await getApplicationSupportDirectory();
    return d.path;
  } catch (_) {
    return Directory.systemTemp.path;
  }
}
