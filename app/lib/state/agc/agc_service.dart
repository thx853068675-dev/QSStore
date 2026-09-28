// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 华为 AGC（AppGallery Connect）云服务客户端。
//
// ── 这是什么 ──────────────────────────────────────────────────────────
// 这是「换设备时自动重建设备授权 Profile」所依赖的云侧能力。移植自
// 小白（auto-installer）的 EcoServices，API 契约与端点保持不变 ——
// 那些端点是华为 DevEco 体系的一部分，不应擅自更动。
//
// ── 鉴权方式 ──────────────────────────────────────────────────────────
// 不依赖 AGC 的 client_id/secret，而是复用 **DevEco Studio 的登录态**：
//   1. 打开 cn.devecostudio.huawei.com 授权页，用户登录后回调带 tempToken
//   2. tempToken → jwtToken
//   3. jwtToken → userInfo（accessToken / userId / teamId）
// 之后所有请求带三个头：oauth2Token / teamId / uid
//
// ── 为什么这件事必须自动 ──────────────────────────────────────────────
// 调试 Profile 里绑定了设备 UDID 列表。换一台设备后旧 Profile 不含新设备，
// 设备侧会报 9568423。原实现只在「Profile 文件不存在」时才创建，
// 导致换设备必然失败、用户只能去「重置证书」。
// 本服务提供重建能力，由 signing_core 的 provision 编排决定何时调用。

import 'dart:convert';
import 'dart:io';

import 'agc_models.dart';

/// AGC 接口基址。
const String _authRouter = 'https://cn.devecostudio.huawei.com/authrouter/auth/api';
const String _connectApi = 'https://connect-api.cloud.huawei.com/api';

class AgcException implements Exception {
  AgcException(this.message, {this.code = 0});

  final String message;
  final int code;

  @override
  String toString() => 'AgcException($code): $message';
}

/// 设备授权重建过程对外汇报的进度（供 UI 展示）。
typedef AgcProgress = void Function(String message);

class AgcService {
  AgcService({this.aclList = defaultAcl});

  /// 可授权的 ACL 白名单（创建 Profile 时取交集用）
  final List<String> aclList;

  AuthInfo? authInfo;

  bool get isSignedIn => authInfo?.isComplete ?? false;

  void initUserInfo(AuthInfo? info) => authInfo = info;

  // ────────────────────── 底层请求 ──────────────────────

  /// 统一的 AGC 请求。鉴权头由 [authInfo] 提供。
  Future<EcoResult?> _request(
    String url,
    Map<String, dynamic> data,
    Map<String, String>? headers, [
    String method = 'POST',
  ]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      request.headers.contentType = ContentType.json;
      request.headers.set('oauth2Token', authInfo?.accessToken ?? '');
      request.headers.set('teamId', authInfo?.teamId ?? authInfo?.userId ?? '');
      request.headers.set('uid', authInfo?.userId ?? '');
      headers?.forEach((k, v) => request.headers.set(k, v));

      if (data.isNotEmpty) {
        final body = utf8.encode(jsonEncode(data));
        request.contentLength = body.length;
        request.add(body);
      }

      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) return EcoResult.fromJson(decoded);
          return EcoResult(ret: Ret(code: 0, msg: text));
        } catch (_) {
          return EcoResult(ret: Ret(code: 0, msg: text));
        }
      }
      if (response.statusCode == 401) {
        return EcoResult(ret: Ret(code: 401, msg: '登录信息过期'));
      }
      return EcoResult(ret: Ret(code: response.statusCode, msg: text));
    } on SocketException catch (e) {
      return EcoResult(ret: Ret(code: -1, msg: '网络不可达：${e.message}'));
    } catch (e) {
      return EcoResult(ret: Ret(code: -1, msg: '$e'));
    } finally {
      client.close(force: true);
    }
  }

  /// 下载二进制文件（证书 / Profile）。
  Future<bool> downloadFile(String url, String savePath) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('GET', Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        await response.pipe(sink);
        await sink.close();
        return true;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AgcException('登录信息失效', code: response.statusCode);
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ────────────────────── 登录 ──────────────────────

  /// 用 DevEco 授权页回调带来的 tempToken 换取用户信息。
  Future<AuthInfo?> getAuthInfoBytempToken(String tokenUrl) async {
    final params = Uri.splitQueryString(tokenUrl);
    final tempToken = params['tempToken'];
    if (tempToken == null || tempToken.isEmpty) {
      throw AgcException('回调中没有 tempToken');
    }

    // 第一步：tempToken → jwtToken
    final jwt = await _request(
      '$_authRouter/temptoken/check?site=CN&tempToken=$tempToken'
      '&appid=1007&version=0.0.0',
      const {},
      const {},
      'GET',
    );
    if (jwt?.ret == null || jwt!.ret!.msg.isEmpty) {
      throw AgcException('tempToken 无效');
    }

    // 第二步：jwtToken → userInfo
    final result = await _request(
      '$_authRouter/jwToken/check',
      const {},
      {'refresh': 'false', 'jwtToken': jwt.ret!.msg},
      'GET',
    );
    if (result?.userInfo == null) {
      throw AgcException('登录失败');
    }
    result!.userInfo!.setJwtToken(jwt.ret!.msg);
    authInfo = result.userInfo;
    return result.userInfo;
  }

  /// 刷新登录态。返回 null 表示刷新失败（需重新登录）。
  Future<AuthInfo?> refreshToken(AuthInfo? info) async {
    if (info?.jwtToken == null || info!.jwtToken!.isEmpty) return null;
    final result = await _request(
      '$_authRouter/jwToken/check',
      const {},
      {'refresh': 'true', 'jwtToken': info.jwtToken!},
      'GET',
    );
    if (result?.userInfo == null) return null;
    result!.userInfo!.setJwtToken(info.jwtToken!);
    // The refresh endpoint omits public profile fields. Keep the Huawei
    // nickname/avatar already fetched with this same verified account.
    if (result.userInfo!.userId == info.userId) {
      if (result.userInfo!.avatarUrl?.isEmpty ?? true) {
        result.userInfo!.avatarUrl = info.avatarUrl;
      }
      final refreshedName = result.userInfo!.nickName ?? '';
      if (refreshedName.isEmpty || refreshedName.contains('*') ||
          refreshedName.contains('＊')) {
        result.userInfo!.nickName = info.nickName;
      }
    }
    authInfo = result.userInfo;
    return result.userInfo;
  }

  /// 探测登录态是否仍有效。
  ///
  /// accessToken 过期时**先尝试静默刷新**（用 jwtToken 换新的 accessToken），
  /// 刷新成功则更新 [authInfo] 并返回 true —— 否则用户每次过期都要重走浏览器。
  Future<bool> checkSignedIn() async {
    if (!isSignedIn) return false;
    try {
      final teams = await getUserTeamList();
      if (teams != null) return true;
    } on AgcException catch (e) {
      // 401 = accessToken 过期（jwtToken 通常还有效，可以刷新）
      if (e.code != 401) rethrow;
    }
    // 401/403/空结果都视为需要刷新
    final refreshed = await refreshToken(authInfo);
    return refreshed != null;
  }

  Future<List<TeamInfo>?> getUserTeamList() async {
    final r = await _request(
      '$_connectApi/ups/user-permission-service/v1/user-team-list',
      const {},
      const {},
      'GET',
    );
    if (r?.ret?.code == 403) return null;
    if (r?.ret?.code == 401) throw AgcException(r!.ret!.msg, code: 401);
    return r?.teams ?? const [];
  }

  // ────────────────────── 证书 ──────────────────────

  Future<List<CertInfo>> getCertList() async {
    final r = await _request(
      '$_connectApi/cps/harmony-cert-manage/v1/cert/list',
      const {},
      const {},
      'GET',
    );
    if (r == null || (r.ret != null && r.ret!.code != 0)) {
      throw AgcException('读取证书列表失败：${r?.ret?.msg ?? "无响应"}',
          code: r?.ret?.code ?? -1);
    }
    return r.certList ?? const [];
  }

  Future<void> deleteCertList(List<String> certIds) async {
    final r = await _request(
      '$_connectApi/cps/harmony-cert-manage/v1/cert/delete',
      {'certIds': certIds},
      const {},
      'DELETE',
    );
    if (r == null || (r.ret != null && r.ret!.code != 0)) {
      throw AgcException('删除证书失败：${r?.ret?.msg ?? "无响应"}',
          code: r?.ret?.code ?? -1);
    }
  }

  /// 创建证书。[type] 1=调试 2=发布。
  Future<CertInfo> createCert(String name, int type, String csr) async {
    final r = await _request(
      '$_connectApi/cps/harmony-cert-manage/v1/cert/add',
      {'csr': csr, 'certName': name, 'certType': type},
      const {},
    );
    if (r?.harmonyCert == null) {
      var msg = r?.ret?.msg ?? '';
      if (msg.contains('certList')) {
        msg = '当前证书失效，需要重置证书';
      }
      throw AgcException('证书创建失败：$msg');
    }
    return r!.harmonyCert!;
  }

  /// 用对象 ID 换取可下载的临时地址。
  Future<List<UrlInfo>> downloadObj(String objId) async {
    final r = await _request(
      '$_connectApi/amis/app-manage/v1/objects/url/reapply',
      {'sourceUrls': objId},
      const {},
    );
    return r?.urlsInfo ?? const [];
  }

  // ────────────────────── 设备 ──────────────────────

  Future<List<DeviceInfo>> deviceList() async {
    final r = await _request(
      '$_connectApi/cps/device-manage/v1/device/list'
      '?start=1&pageSize=100&encodeFlag=0',
      const {},
      const {},
      'GET',
    );
    return r?.list ?? const [];
  }

  Future<void> createDevice(String deviceName, String uuid) async {
    await _request(
      '$_connectApi/cps/device-manage/v1/device/add',
      {'deviceName': deviceName, 'udid': uuid, 'deviceType': 4},
      const {},
    );
  }

  // ────────────────────── Profile ──────────────────────

  /// 创建调试 Profile，返回可下载地址。
  ///
  /// [moduleRequestedPermissions] 是包内 `module.json` 声明的权限，
  /// 会与 [aclList] 取交集后作为 `aclPermissionList` 提交。
  Future<String> createProfile({
    required String name,
    required String certId,
    required List<String> deviceIds,
    required List<String> moduleRequestedPermissions,
    required String packageName,
  }) async {
    final acls = effectiveAcls(moduleRequestedPermissions);
    final r = await _request(
      '$_connectApi/cps/provision-manage/v1/ide/test/provision/add',
      {
        'provisionName': name,
        'aclPermissionList': acls,
        'deviceList': deviceIds,
        'certList': [certId],
        'packageName': packageName,
      },
      const {},
    );
    if (r?.provisionFileUrl == null) {
      throw AgcException('Profile 创建失败：${r?.ret?.msg ?? "未知原因"}');
    }
    return r!.provisionFileUrl!;
  }

  /// 计算实际提交的 ACL：包内声明 ∩ 可授权白名单。
  List<String> effectiveAcls(List<String> moduleRequestedPermissions) {
    final allowed = aclList.toSet();
    final out = <String>{};
    for (final p in moduleRequestedPermissions) {
      if (allowed.contains(p)) out.add(p);
    }
    final list = out.toList()..sort();
    return list;
  }

  /// 读取 CSR 文本。
  Future<String?> readCsr(String csrPath) async {
    try {
      return await File(csrPath).readAsString();
    } catch (_) {
      return null;
    }
  }
}
