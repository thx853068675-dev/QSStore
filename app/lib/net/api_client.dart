// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 元数据 API 客户端。
//
// 服务端地址按设计文档 §7.6 固定为 IP 直连（不申请域名）。
// 所有响应统一包装：{"ok":bool,"data":{...},"error":{...}}
//
// ── 关于 HTTPS 与证书 pinning ─────────────────────────────────────────
// 元数据决定了「从哪个镜像下载、用什么哈希校验」。若走明文 HTTP，中间人
// 可以同时替换镜像地址与哈希，客户端的完整性校验就形同虚设。因此支持：
//   · 服务端用自签证书提供 HTTPS（见 tools/deploy-tls.sh）
//   · 客户端把该证书的 SHA-256 指纹**内置**进来做 pinning
// 两者通过编译期参数注入；默认值对应当前已部署的 HTTPS 服务：
//   --dart-define=HAPSTORE_API_BASE=https://47.98.250.230
//   --dart-define=HAPSTORE_API_PIN=<证书 DER 的 SHA-256 小写十六进制>

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../model/store_models.dart';

/// API 错误（带服务端返回的结构化 code/message/hint）。
class ApiException implements Exception {
  ApiException(this.code, this.message, {this.hint, this.status = 0});

  final String code;
  final String message;
  final String? hint;
  final int status;

  @override
  String toString() =>
      'ApiException($status $code): $message${hint != null ? ' — $hint' : ''}';
}

class ApiClient {
  ApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? defaultBaseUrl,
        _http = client ?? _makeClient();

  /// 生产地址。改 HTTPS 只需在构建时传 `HAPSTORE_API_BASE`，不必改代码。
  static const String defaultBaseUrl = String.fromEnvironment(
    'HAPSTORE_API_BASE',
    defaultValue: 'https://47.98.250.230',
  );

  /// 服务端证书 DER 的 SHA-256 指纹（小写十六进制）。
  ///
  /// 由 `--dart-define=HAPSTORE_API_PIN=...` 提供；为空表示不做 pinning
  /// （仅当服务端是受信任 CA 签发的证书时才可接受）。
  static const String pinnedCertSha256 = String.fromEnvironment(
    'HAPSTORE_API_PIN',
    defaultValue:
        '9a75775bef85e2ddca908529a708b426a0aa174525f9c133fd55ea615adb9b4f',
  );

  final String baseUrl;
  final http.Client _http;

  /// Current DevEco JWT, read at request time after login/refresh.
  String? Function()? authTokenProvider;
  String? Function()? authAccessTokenProvider;

  static const Duration _timeout = Duration(seconds: 20);

  /// 构造底层客户端：设置指纹后只信任**这一张**证书。
  static http.Client _makeClient() {
    final pin = pinnedCertSha256.trim().toLowerCase();
    // 有 pin 时不信任系统 CA：所有 TLS 握手都必须先进入回调并核对 pin，
    // 然后才允许发送请求体（其中可能包含签名私钥）。响应后的核对作为二次防线。
    final inner = pin.isEmpty
        ? HttpClient()
        : HttpClient(context: SecurityContext(withTrustedRoots: false));
    inner.badCertificateCallback = (cert, host, port) =>
        pin.isNotEmpty && sha256.convert(cert.der).toString() == pin;
    return _PinnedClient(inner, pin);
  }

  /// 把相对路径补全为绝对地址（图标等）。
  String resolve(String pathOrUrl) {
    if (pathOrUrl.isEmpty) return '';
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }
    return '$baseUrl$pathOrUrl';
  }

  Future<dynamic> _get(String path,
      [Map<String, String>? query, bool authenticated = false]) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    http.Response resp;
    try {
      final headers = <String, String>{};
      if (authenticated) {
        final token = authTokenProvider?.call();
        if (token == null || token.isEmpty) {
          throw ApiException('SIGN_IN_REQUIRED', '请先登录华为开发者账号');
        }
        headers['Authorization'] = 'Bearer $token';
        final accessToken = authAccessTokenProvider?.call();
        if (accessToken != null && accessToken.isNotEmpty) {
          headers['X-Huawei-Access-Token'] = accessToken;
        }
      }
      resp = await _http.get(uri, headers: headers).timeout(_timeout);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('NETWORK', '无法连接商店服务：$e');
    }
    return _decode(resp);
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body,
      {bool authenticated = false}) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response resp;
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (authenticated) {
        final token = authTokenProvider?.call();
        if (token == null || token.isEmpty) {
          throw ApiException('SIGN_IN_REQUIRED', '请先登录华为开发者账号');
        }
        headers['Authorization'] = 'Bearer $token';
        final accessToken = authAccessTokenProvider?.call();
        if (accessToken != null && accessToken.isNotEmpty) {
          headers['X-Huawei-Access-Token'] = accessToken;
        }
      }
      resp = await _http
          .post(uri,
              headers: headers,
              body: jsonEncode(body))
          .timeout(_timeout);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('NETWORK', '无法连接商店服务：$e');
    }
    return _decode(resp);
  }

  Future<dynamic> _deleteAuthenticated(String path) async {
    final token = authTokenProvider?.call();
    if (token == null || token.isEmpty) {
      throw ApiException('SIGN_IN_REQUIRED', '请先登录华为开发者账号');
    }
    final headers = <String, String>{'Authorization': 'Bearer $token'};
    final accessToken = authAccessTokenProvider?.call();
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['X-Huawei-Access-Token'] = accessToken;
    }
    try {
      final resp = await _http.delete(Uri.parse('$baseUrl$path'), headers: headers)
          .timeout(_timeout);
      return _decode(resp);
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException('NETWORK', '无法连接商店服务：$e');
    }
  }

  dynamic _decode(http.Response resp) {
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      throw ApiException('BAD_RESPONSE', '服务返回格式异常（HTTP ${resp.statusCode}）',
          status: resp.statusCode);
    }
    if (parsed['ok'] == true) return parsed['data'];
    final err = parsed['error'];
    if (err is Map) {
      throw ApiException(
        (err['code'] ?? 'UNKNOWN') as String,
        (err['message'] ?? '未知错误') as String,
        hint: err['hint'] as String?,
        status: resp.statusCode,
      );
    }
    throw ApiException('UNKNOWN', '未知错误（HTTP ${resp.statusCode}）',
        status: resp.statusCode);
  }

  // ────────────────────────── 业务接口 ──────────────────────────

  /// 应用列表。
  Future<Paged<StoreApp>> listApps({
    String query = '',
    String category = '',
    String sort = 'updated',
    bool? featured,
    int page = 1,
    int pageSize = 30,
  }) async {
    final q = <String, String>{
      'sort': sort,
      'page': '$page',
      'page_size': '$pageSize',
    };
    if (query.isNotEmpty) q['q'] = query;
    if (category.isNotEmpty) q['category'] = category;
    if (featured != null) q['featured'] = featured ? '1' : '0';

    final data = await _get('/api/v1/apps', q) as Map<String, dynamic>;
    return Paged<StoreApp>(
      items: ((data['items'] ?? []) as List)
          .map((e) => StoreApp.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (data['total'] ?? 0) as int,
      page: (data['page'] ?? 1) as int,
      pageSize: (data['page_size'] ?? pageSize) as int,
    );
  }

  /// 应用详情。
  Future<StoreApp> appDetail(int id) async {
    final data = await _get('/api/v1/apps/$id') as Map<String, dynamic>;
    return StoreApp.fromJson(data);
  }

  Future<List<StoreApp>> myPublishedApps() async {
    final data = await _get('/api/v1/me/apps', null, true) as Map<String, dynamic>;
    return ((data['items'] ?? []) as List)
        .map((e) => StoreApp.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> removeMyPublishedApp(int appId) async {
    await _deleteAuthenticated('/api/v1/me/apps/$appId');
  }

  /// 版本列表。
  Future<Paged<AppRelease>> listReleases(int appId,
      {int page = 1, int pageSize = 20}) async {
    final data = await _get('/api/v1/apps/$appId/releases', {
      'page': '$page',
      'page_size': '$pageSize',
    }) as Map<String, dynamic>;
    return Paged<AppRelease>(
      items: ((data['items'] ?? []) as List)
          .map((e) => AppRelease.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (data['total'] ?? 0) as int,
      page: (data['page'] ?? 1) as int,
      pageSize: (data['page_size'] ?? pageSize) as int,
    );
  }

  /// 分类统计。
  Future<List<Map<String, dynamic>>> categories() async {
    final data = await _get('/api/v1/categories') as Map<String, dynamic>;
    return ((data['items'] ?? []) as List).cast<Map<String, dynamic>>();
  }

  /// 服务端预处理仓库与最新 Release，返回可上架的 HAP 清单。
  Future<Map<String, dynamic>> prepareSubmit(String repoUrl) async {
    final data = await _post('/api/v1/submit/prepare', {'repo_url': repoUrl}, authenticated: true)
        as Map<String, dynamic>;
    return data;
  }

  /// 用户确认 HAP 和分类后再公开上架。
  Future<Map<String, dynamic>> confirmSubmit(
      String draftToken, String assetName, String category) async {
    final data = await _post('/api/v1/submit/confirm', {
      'draft_token': draftToken,
      'asset_name': assetName,
      'category': category,
    }, authenticated: true)
        as Map<String, dynamic>;
    return data;
  }

  Future<List<AppReview>> listReviews(int appId) async {
    final data = await _get('/api/v1/apps/$appId/reviews') as Map<String, dynamic>;
    return ((data['items'] ?? []) as List)
        .map((e) => AppReview.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> putReview(int appId, int stars, String body) async {
    await _post('/api/v1/apps/$appId/reviews',
        {'stars': stars, 'body': body}, authenticated: true);
  }

  /// 仅当前已核验的华为账号可取回其签名身份；服务端用独立随机密钥加密落盘。
  Future<Map<String, dynamic>> signingIdentity() async {
    final data = await _get('/api/v1/signing-identity', null, true)
        as Map<String, dynamic>;
    return data;
  }

  /// 首台设备发布签名身份；已有身份不会被后续设备覆盖。
  Future<Map<String, dynamic>> publishSigningIdentity(
      String certId, String privateKeyPem) async {
    return await _post('/api/v1/signing-identity', {
      'cert_id': certId,
      'private_key_pem': privateKeyPem,
    }, authenticated: true) as Map<String, dynamic>;
  }

  /// 匿名下载计数（失败不影响主流程）。
  Future<void> recordDownload(int appId, int assetId,
      {String device = ''}) async {
    try {
      await _post('/api/v1/apps/$appId/download-event',
          {'asset_id': assetId, 'device': device});
    } catch (_) {
      // 计数是尽力而为，不应影响安装
    }
  }

  void dispose() => _http.close();
}

/// 核对最终响应的证书；badCertificateCallback 只会收到系统不信任的证书。
class _PinnedClient extends http.BaseClient {
  _PinnedClient(this._inner, this._pin);

  final HttpClient _inner;
  final String _pin;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.scheme != 'https') {
      throw http.ClientException('元数据 API 必须使用 HTTPS', request.url);
    }
    final ioRequest = await _inner.openUrl(request.method, request.url);
    ioRequest.followRedirects = request.followRedirects;
    ioRequest.maxRedirects = request.maxRedirects;
    ioRequest.contentLength = request.contentLength ?? -1;
    ioRequest.persistentConnection = request.persistentConnection;
    request.headers.forEach(ioRequest.headers.set);
    final response =
        await request.finalize().pipe(ioRequest) as HttpClientResponse;
    final cert = response.certificate;
    if (response.redirects.any((r) => r.location.scheme != 'https') ||
        cert == null ||
        (_pin.isNotEmpty && sha256.convert(cert.der).toString() != _pin)) {
      await response.drain<void>();
      throw http.ClientException('元数据 API 证书校验失败', request.url);
    }
    final headers = <String, String>{};
    response.headers.forEach((key, values) => headers[key] = values.join(','));
    return http.StreamedResponse(response, response.statusCode,
        contentLength:
            response.contentLength < 0 ? null : response.contentLength,
        request: request,
        headers: headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase);
  }

  @override
  void close() => _inner.close(force: true);
}
