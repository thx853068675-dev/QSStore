// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 签名材料模型。
//
// 原工程用 `freezed` 生成 386 行代码只为得到一个不可变数据类。这里内联成
// 普通类，从而去掉 build_runner / freezed / json_serializable 三条代码生成
// 依赖 —— 这是「裁减冗余」收益最大的一处。

/// 一次签名所需的全部材料。字段与小白原生的 `signApp` 参数一一对应。
class SignConfig {
  const SignConfig({
    this.packageName = '',
    this.udids = const [],
    this.csrPath = '',
    this.certPath = '',
    this.certId = '',
    this.profilePath = '',
    this.keystoreFile = '',
    this.keystorePwd = '',
    this.keyAlias = 'xiaobai',
  });

  final String packageName;
  final List<String> udids;
  final String csrPath;

  /// 证书链文件（.cer，PEM 或 DER，可含多级）。
  final String certPath;
  final String certId;

  /// 设备授权 Profile（.p7b）。
  final String profilePath;

  /// 私钥文件。小白生成的是**未加密 PEM**；加密私钥会被拒绝，
  /// 因为本项目不允许把口令放到进程命令行上。
  final String keystoreFile;
  final String keystorePwd;
  final String keyAlias;

  factory SignConfig.fromJson(Map<String, dynamic> json) => SignConfig(
        packageName: json['packageName'] as String? ?? '',
        udids: (json['udids'] as List?)?.cast<String>() ?? const [],
        csrPath: json['csrPath'] as String? ?? '',
        certPath: json['certPath'] as String? ?? '',
        certId: json['certId'] as String? ?? '',
        profilePath: json['profilePath'] as String? ?? '',
        keystoreFile: json['keystoreFile'] as String? ?? '',
        keystorePwd: json['keystorePwd'] as String? ?? '',
        keyAlias: json['keyAlias'] as String? ?? 'xiaobai',
      );

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'udids': udids,
        'csrPath': csrPath,
        'certPath': certPath,
        'certId': certId,
        'profilePath': profilePath,
        'keystoreFile': keystoreFile,
        'keystorePwd': keystorePwd,
        'keyAlias': keyAlias,
      };

  SignConfig copyWith({
    String? packageName,
    List<String>? udids,
    String? csrPath,
    String? certPath,
    String? certId,
    String? profilePath,
    String? keystoreFile,
    String? keystorePwd,
    String? keyAlias,
  }) =>
      SignConfig(
        packageName: packageName ?? this.packageName,
        udids: udids ?? this.udids,
        csrPath: csrPath ?? this.csrPath,
        certPath: certPath ?? this.certPath,
        certId: certId ?? this.certId,
        profilePath: profilePath ?? this.profilePath,
        keystoreFile: keystoreFile ?? this.keystoreFile,
        keystorePwd: keystorePwd ?? this.keystorePwd,
        keyAlias: keyAlias ?? this.keyAlias,
      );

  /// 材料是否齐全（只做存在性判断，内容校验见预检）。
  bool get isComplete =>
      certPath.isNotEmpty &&
      profilePath.isNotEmpty &&
      keystoreFile.isNotEmpty;
}
