// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// signing_core —— 轻启签名与侧载端到端核心。
//
// 纯 Dart 实现，**不依赖 Flutter**，因此可以：
//   · 直接在命令行跑测试（dart test）
//   · 被 Flutter 应用引用（手机端）
//   · 被纯 Dart 工具引用（桌面/CI）
//
// 核心能力：
//   inspectPackage  判断是否为轻启包并取出结构信息
//   signHap         端到端签名（分层重签 + 三重不变量）
//   checkPreflight  签名前材料预检（证书/Profile/UDID/链序）
//
// 关键特性：**没有整包大小上限**。
// 主包体全程以「文件区间」形式搬运，不进入内存。

library signing_core;

export 'src/hap_zip.dart'
    show
        HapReader,
        ZipEntry,
        HapFormatException,
        workerPayloadLimit,
        maxEntryCount,
        sha256FileHex;
export 'src/manifest.dart' show buildWorkerManifest, sha256Hex;
export 'src/models.dart' show SignConfig;
export 'src/package.dart'
    show
        PackageInfo,
        readDeclaredPermissions,
        extractRequestedPermissionsFrom,
        bundleName,
        workerPath,
        manifestPath,
        mainModuleName,
        workerModuleName;
export 'src/provision.dart'
    show
        ProfileRequest,
        ProfileProvider,
        RegenerateReason,
        RegenerateReasonText,
        EnsureProfileResult,
        EnsureProfileAttempt,
        ProvisioningException,
        provisioningDecision,
        ensureUsableProfile,
        requireUsableProfile,
        extractRequestedPermissions,
        buildProfileRequest;
export 'src/range_stream.dart' show FileRangeStream;
export 'src/installer.dart' show HdcInstaller, InstallFailure, classifyInstallError;
export 'src/preflight.dart'
    show
        PreflightReport,
        PreflightIssue,
        ProfileSummary,
        Severity,
        inspectProfile,
        preflightSigningMaterial;
export 'src/sign.dart'
    show SignResult, SignerRunner, SignProgress, signHap, signPlain;
export 'src/verify.dart'
    show signedProfileOf, checkPayloadUnchanged, bytesEqual, isSignerAddedEntry;
export 'src/zip_stream.dart' show streamRepack;

export 'src/native_lib_pad.dart'
    show
        minNativeLibSize,
        isNativeLibEntry,
        paddingFor,
        padIfNeeded,
        findUndersizedNativeLibs;
