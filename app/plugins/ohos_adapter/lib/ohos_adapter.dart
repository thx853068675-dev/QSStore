import 'ohos_adapter_platform_interface.dart';

class OhosAdapter {
  Future<String?> getPlatformVersion() {
    return OhosAdapterPlatform.instance.getPlatformVersion();
  }

  bool get isOhos {
    return OhosAdapterPlatform.instance.isOhos;
  }

  /// 写系统日志（hilog）。排查问题时用，避免依赖 print。

  Future<void> log(String msg) {
    return OhosAdapterPlatform.instance.log(msg);
  }

  Future<Map<String, dynamic>?> getHuaweiProfile({bool force = false}) {
    return OhosAdapterPlatform.instance.getHuaweiProfile(force: force);
  }

  /// 通用 startAbility（系统设置页需要 bundle + ability + uri）
  Future<bool> startWant(String bundle, String ability, String uri) {
    return OhosAdapterPlatform.instance.startWant(bundle, ability, uri);
  }

  Future<bool> openInstalledApp(String bundleName,
      {String abilityName = '', String moduleName = ''}) {
    return OhosAdapterPlatform.instance.openInstalledApp(bundleName,
        abilityName: abilityName, moduleName: moduleName);
  }

  Future<void> openUrl(String url) {
    return OhosAdapterPlatform.instance.openUrl(url);
  }

  Future<String?> selectFile(List<String> filter) {
    return OhosAdapterPlatform.instance.selectFile(filter);
  }

  Future<String?> tempDir() {
    return OhosAdapterPlatform.instance.tempDir();
  }

  Future<String?> appDir() {
    return OhosAdapterPlatform.instance.appDir();
  }

  Future<String?> hdcCmd(String cmd) {
    return OhosAdapterPlatform.instance.hdcCmd(cmd);
  }

  Future<String?> signCmd(String cmd) {
    return OhosAdapterPlatform.instance.signCmd(cmd);
  }
  Future<String?> deviceType() {
    return OhosAdapterPlatform.instance.deviceType();
  }

  Future<bool?> hasJit(String cmd) {
    return OhosAdapterPlatform.instance.hasJit();
  }


  Future<void> startServer() {
    return OhosAdapterPlatform.instance.startServer();
  }

  Future<void> setLocalUrl(String url) {
    return OhosAdapterPlatform.instance.setLocalKey("url", url);
  }

  Future<bool> getFirstUse() async {
    return (await OhosAdapterPlatform.instance.getLocalKey("firstUse")) ==
        "ture";
  }

  Future<void> setFirstUse() {
    return OhosAdapterPlatform.instance.setLocalKey("firstUse", "ture");
  }

  Future<String?> getLocalUrl() {
    return OhosAdapterPlatform.instance.getLocalKey("url");
  }
}

final ohosAdapter = OhosAdapter();
