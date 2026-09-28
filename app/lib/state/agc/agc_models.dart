// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 华为 AGC 相关数据模型。
//
// 原工程用 freezed 生成这些类（连同 AuthInfo 一起产生数百行生成代码）。
// 这里手写 fromJson/toJson —— 字段不多，而生成链在鸿蒙工具链
// （Dart 2.19.6）下会带来额外的版本约束麻烦。

/// 调试证书的统一名称。
///
/// `SignMaterialStore`（创建/复用证书）与 `AgcProfileProvider`（按 ID/名字
/// 找证书）必须用同一个名字，否则会出现「创建时叫 A、查找时找 B」——
/// 结果是每次都新建一张证书，或复用到与私钥不配对的那张。
const String kDebugCertName = 'hapstore-debug';

/// 登录后的身份信息。
///
/// 三个字段直接决定 AGC 请求的鉴权头：
///   oauth2Token ← accessToken
///   teamId      ← teamId（默认等于 userId，可切换到其它团队）
///   uid         ← userId
class AuthInfo {
  AuthInfo({
    required this.accessToken,
    required this.userId,
    this.nickName,
    this.avatarUrl,
    this.jwtToken,
    String? teamId,
  }) : teamId = teamId ?? userId;

  String? accessToken;
  String? userId;
  String? teamId;
  String? nickName;
  String? avatarUrl;
  String? jwtToken;

  void changeTeamId(TeamInfo team) => teamId = team.id;

  void setJwtToken(String jwt) => jwtToken = jwt;

  bool get isComplete =>
      (accessToken ?? '').isNotEmpty &&
      (userId ?? '').isNotEmpty &&
      (teamId ?? '').isNotEmpty;

  factory AuthInfo.fromJson(Map<String, dynamic> j) => AuthInfo(
        accessToken: j['accessToken'] as String?,
        userId: j['userId'] as String?,
        teamId: j['teamId'] as String?,
        nickName: j['nickName'] as String?,
        avatarUrl: (j['avatarUrl'] ?? j['headUrl'] ?? j['headPicUrl']) as String?,
        jwtToken: j['jwtToken'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'userId': userId,
        'teamId': teamId,
        'nickName': nickName,
        'avatarUrl': avatarUrl,
        'jwtToken': jwtToken,
      };
}

class Ret {
  Ret({this.code = 0, this.msg = ''});
  final int code;
  final String msg;
}

class TeamInfo {
  TeamInfo(
      {this.id = '',
      this.name = '',
      this.countryCode = '',
      this.lastLoginTime = ''});
  final String id;
  final String name;
  final String countryCode;
  final String lastLoginTime;
}

class DeviceInfo {
  DeviceInfo({
    this.id = '',
    this.deviceName = '',
    this.udid = '',
    this.deviceType = 0,
    this.createTime = '',
    this.status = 0,
  });
  final String id;
  final String deviceName;
  final String udid;
  final int deviceType;
  final String createTime;
  final int status;
}

class CertInfo {
  CertInfo({
    this.id = '',
    this.certName = '',
    this.certObjectId = '',
    this.publicKeySha256 = '',
    this.certType = 0,
    this.expireTime = 0,
    this.createTime = 0,
    this.status = 0,
  });
  final String id;
  final String certName;
  final String certObjectId;
  final String publicKeySha256;

  /// 1 = 调试证书，2 = 发布证书
  final int certType;
  final int expireTime;
  final int createTime;
  final int status;

  bool get isDebug => certType == 1;

  /// AGC 不同接口/版本可能以秒或毫秒返回时间戳。
  int get expireEpochSeconds =>
      expireTime > 100000000000 ? expireTime ~/ 1000 : expireTime;
}

class UrlInfo {
  UrlInfo({this.newUrl = ''});
  final String newUrl;
}

/// AGC 统一响应。
class EcoResult {
  EcoResult({
    this.ret,
    this.userInfo,
    this.teams,
    this.list,
    this.certList,
    this.harmonyCert,
    this.urlsInfo,
    this.provisionFileUrl,
  });

  final Ret? ret;
  final AuthInfo? userInfo;
  final List<TeamInfo>? teams;
  final List<DeviceInfo>? list;
  final List<CertInfo>? certList;
  final CertInfo? harmonyCert;
  final List<UrlInfo>? urlsInfo;
  final String? provisionFileUrl;

  factory EcoResult.fromJson(Map<String, dynamic> j) => EcoResult(
        ret: j['ret'] is Map
            ? Ret(
                code: ((j['ret'] as Map)['code'] ?? 0) as int,
                msg: ((j['ret'] as Map)['msg'] ?? '') as String,
              )
            : null,
        userInfo: j['userInfo'] is Map
            ? AuthInfo.fromJson(Map<String, dynamic>.from(j['userInfo'] as Map))
            : null,
        teams: (j['teams'] as List?)
            ?.whereType<Map>()
            .map((e) => TeamInfo(
                  id: (e['id'] ?? '') as String,
                  name: (e['name'] ?? '') as String,
                  countryCode: (e['countryCode'] ?? '') as String,
                  lastLoginTime: (e['lastLoginTime'] ?? '') as String,
                ))
            .toList(),
        list: (j['list'] as List?)
            ?.whereType<Map>()
            .map((e) => DeviceInfo(
                  id: (e['id'] ?? '') as String,
                  deviceName: (e['deviceName'] ?? '') as String,
                  udid: (e['udid'] ?? '') as String,
                  deviceType: (e['deviceType'] ?? 0) as int,
                  createTime: (e['createTime'] ?? '') as String,
                  status: (e['status'] ?? 0) as int,
                ))
            .toList(),
        certList: (j['certList'] as List?)
            ?.whereType<Map>()
            .map((e) => CertInfo(
                  id: (e['id'] ?? '') as String,
                  certName: (e['certName'] ?? '') as String,
                  certObjectId: (e['certObjectId'] ?? '') as String,
                  publicKeySha256: (e['publicKeySha256'] ?? '') as String,
                  certType: (e['certType'] ?? 0) as int,
                  expireTime: (e['expireTime'] ?? 0) as int,
                  createTime: (e['createTime'] ?? 0) as int,
                  status: (e['status'] ?? 0) as int,
                ))
            .toList(),
        harmonyCert: j['harmonyCert'] is Map
            ? CertInfo(
                id: ((j['harmonyCert'] as Map)['id'] ?? '') as String,
                certName:
                    ((j['harmonyCert'] as Map)['certName'] ?? '') as String,
                certObjectId:
                    ((j['harmonyCert'] as Map)['certObjectId'] ?? '') as String,
                certType: ((j['harmonyCert'] as Map)['certType'] ?? 1) as int,
              )
            : null,
        urlsInfo: (j['urlsInfo'] as List?)
            ?.whereType<Map>()
            .map((e) => UrlInfo(newUrl: (e['newUrl'] ?? '') as String))
            .toList(),
        provisionFileUrl: j['provisionFileUrl'] as String?,
      );
}

/// AGC 可授权的 ACL 白名单。
///
/// 创建 Profile 时提交「包内 requestPermissions ∩ 本表」。
/// 之所以要取交集：AGC 只接受它认可的高级权限，提交未知项会被拒；
/// 而**遗漏**某项会导致设备侧装不上（9568289）。
///
/// 这份表照搬自原实现（`EcoServices.defaultAcl`），未作增删 ——
/// 擅自改动可能让某些应用的权限授权失败。
const List<String> defaultAcl = [
  'ohos.permission.SYSTEM_FLOAT_WINDOW',
  'ohos.permission.READ_CONTACTS',
  'ohos.permission.WRITE_CONTACTS',
  'ohos.permission.READ_AUDIO',
  'ohos.permission.WRITE_AUDIO',
  'ohos.permission.READ_IMAGEVIDEO',
  'ohos.permission.WRITE_IMAGEVIDEO',
  'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY',
  'ohos.permission.ACCESS_DDK_USB',
  'ohos.permission.ACCESS_DDK_HID',
  'ohos.permission.READ_PASTEBOARD',
  'ohos.permission.FILE_ACCESS_PERSIST',
  'ohos.permission.INTERCEPT_INPUT_EVENT',
  'ohos.permission.INPUT_MONITORING',
  'ohos.permission.SHORT_TERM_WRITE_IMAGEVIDEO',
  'ohos.permission.READ_WRITE_USER_FILE',
  'ohos.permission.READ_WRITE_USB_DEV',
  'ohos.permission.GET_WIFI_PEERS_MAC',
  'ohos.permission.SET_TELEPHONY_ESIM_STATE_OPEN',
  'ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION',
  'ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY',
  'ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY',
  'ohos.permission.MANAGE_PASTEBOARD_APP_SHARE_OPTION',
  'ohos.permission.MANAGE_UDMF_APP_SHARE_OPTION',
  'ohos.permission.ACCESS_DISK_PHY_INFO',
  'ohos.permission.PRELOAD_FILE',
  'ohos.permission.SET_PAC_URL',
  'ohos.permission.PERSONAL_MANAGE_RESTRICTIONS',
  'ohos.permission.START_PROVISIONING_MESSAGE',
  'ohos.permission.USE_FRAUD_CALL_LOG_PICKER',
  'ohos.permission.USE_FRAUD_MESSAGES_PICKER',
  'ohos.permission.PERSISTENT_BLUETOOTH_PEERS_MAC',
  'ohos.permission.ACCESS_VIRTUAL_SCREEN',
  'ohos.permission.MANAGE_APN_SETTING',
  'ohos.permission.GET_WIFI_LOCAL_MAC',
  'ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE',
  'ohos.permission.GET_ETHERNET_LOCAL_MAC',
  'ohos.permission.kernel.DISABLE_GOTPLT_RO_PROTECTION',
  'ohos.permission.USE_FRAUD_APP_PICKER',
  'ohos.permission.ACCESS_DDK_DRIVERS',
  'ohos.permission.ACCESS_DDK_SCSI_PERIPHERAL',
  'ohos.permission.kernel.SUPPORT_PLUGIN',
  'ohos.permission.CUSTOM_SANDBOX',
  'ohos.permission.MANAGE_SCREEN_TIME_GUARD',
  'ohos.permission.CUSTOMIZE_SAVE_BUTTON',
  'ohos.permission.GET_ABILITY_INFO',
  'ohos.permission.ACCESS_FIDO2_ONLINEAUTH',
  'ohos.permission.USE_FLOAT_BALL',
  'ohos.permission.DLP_GET_HIDE_STATUS',
  'ohos.permission.READ_LOCAL_DEVICE_NAME',
  'ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM',
  'ohos.permission.LINKTURBO',
  'ohos.permission.ACCESS_NET_TRACE_INFO',
  'ohos.permission.READ_WHOLE_CALENDAR',
  'ohos.permission.WRITE_WHOLE_CALENDAR',
  'ohos.permission.SET_SYSTEMSHARE_APPLAUNCHTRUSTLIST',
  'ohos.permission.HOOK_KEY_EVENT',
  'ohos.permission.WEB_NATIVE_MESSAGING',
  'ohos.permission.SUBSCRIBE_NOTIFICATION',
  'ohos.permission.CUSTOM_SCREEN_RECORDING',
  'ohos.permission.GET_IP_MAC_INFO',
  'ohos.permission.ACCESS_USER_FULL_DISK',
  'ohos.permission.kernel.LOAD_INDEPENDENT_LIBRARY',
  'ohos.permission.CRYPTO_EXTENSION_REGISTER',
];
