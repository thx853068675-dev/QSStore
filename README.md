# 轻启·安装器

一个 HarmonyOS 应用商店与侧载安装器。发现、下载 HAP，并在**本机用你自己的开发者证书重新签名**后安装到设备——签名、设备授权与上架记录都绑定在你自己的华为开发者账号下。

图标见[原图](design/qingqi-installer-icon-source.png)与[1024 像素预览](design/qingqi-installer-icon.png)。

## 当前实现：ArkTS 原生版

`native/` 是当前主力实现，用 ArkTS/ArkUI 重写，**不含 Flutter 运行时**。签名核心与 HDC TCP 主机以 Rust 源码静态链接进 `libhap_core.so`。

最新制品：**[轻启·安装器 0.4.4](https://github.com/thx853068675-dev/QSStore/releases/latest)**（`com.tonghongxiang.hapstore`，versionCode 2026092901）

功能：商店列表与详情、历史版本下拉、账号登录、上架与下架、评论（分页）、可恢复下载、本地 HAP 导入、AGC 调试证书管理（列表 / 左滑删除 / 配对使用 / 证书重置）、深色模式、强制登录闸门、设备连接检测。

> **安装前请注意**：Release 里的包用开发者本人的 AGC 调试 Profile 签名，而调试 Profile **绑定设备**。直接装到你的设备上会因签名 / 设备授权不匹配而失败，这是预期行为。请 clone 本仓库，用 DevEco Studio 打开 `native/`，在你自己的华为开发者账号下配置调试证书与 Profile（把你的设备 UDID 加进去）后自行构建签名。

构建与签名说明见 [native/README.md](native/README.md)，实机验证记录见 [docs/NATIVE-DEVICE-VERIFICATION-20260928.md](docs/NATIVE-DEVICE-VERIFICATION-20260928.md)。

## 早期实现：Flutter 版

`app/` 是重构前的 Flutter 实现，保留作参考，不再是主力。以下为它当时的状态记录。


- HarmonyOS 6.1 已安装并检查 `0.1.0+2026092736` 的连接、状态栏、发现页、悬浮安装按钮和图标。最新 `0.1.0+2026092737` 增加 HAP 实际应用名与管理页，已构建、签名并通过自动测试，尚未在手机上操作。7.0 设备按用户要求未操作。签名包见 0.1.0 系列构建（已不再提供下载）。证书槽位处理见[恢复说明](docs/CERTIFICATE-RECOVERY.md)。
- 浏览、搜索、应用图标、分类、版本历史与下载安装使用正式元数据服务 `https://store.example.com`。
- 发现页右上角可提交 GitHub 仓库：服务端先检查 Release 并从各 HAP 读取实际应用名，用户再选择具体 HAP 和分类上架。管理页列出可更新的应用、已获取应用和本人上架的应用；上架者可删除自己的公开上架记录。应用显示提交者的华为开发者账号昵称。详情页可选历史版本，悬浮安装按钮显示百分比进度；同一账号可多次打星和评论，评论显示该账号的华为头像。
- 正式服务器已修复错误的系统代理继承。手机直连正式服务的华为账号核验、GitHub 上架和 4 星评论均已实机验证；详情见[实机验证记录](docs/DEVICE-VERIFICATION-20260927.md)和[功能依赖](docs/FEATURE-DEPENDENCIES.md)。
- 华为开发者头像优先用现有登录态调用华为开放资料接口，实机已成功显示并在升级后保留；Account Kit `profile` 是备用路径。已安装应用在发现页、详情页、管理页和我的页面可直接打开。

## 目录

| 路径 | 内容 |
|---|---|
| `app/` | Flutter HarmonyOS 商店客户端 |
| `server/` | Python 元数据、上架、评论与加密签名身份服务 |
| `core/logic/` | HAP 校验、签名、设备授权逻辑 |
| `design/` | 轻启·安装器图标源文件与预览 |
| `tools/` | 构建、部署与运维脚本 |
| `docs/` | API、签名、安全和实机报告 |

## 构建与验证

```bash
./tools/build-app.sh release
python3 -m unittest discover -s server/tests -v
cd app && flutter test
```

鸿蒙 Flutter 工具链、DevEco SDK 与签名材料的配置见 [APP-BUILD.md](docs/APP-BUILD.md)。应用签名工具见 `core/logic/tool/sign_cli.dart`。服务端签名身份库另依赖 Python `cryptography`。

当前 Flutter 84 项测试与服务端 17 项测试通过；TLS 回归测试覆盖“系统信任错误证书时仍须在发送签名私钥前拒绝”。

## 主要文档

- [实机验证记录](docs/DEVICE-VERIFICATION-20260927.md)
- [功能与服务器依赖](docs/FEATURE-DEPENDENCIES.md)
- [服务端 API](docs/SERVER-API.md)
- [商店构建](docs/APP-BUILD.md)
- [华为登录与设备授权](docs/HUAWEI-LOGIN.md)
- [签名核心](docs/SIGNING-CORE.md)
- [签名身份自动化](docs/SIGNING-IDENTITY.md)
- [服务端加固](docs/SERVER-HARDENING.md)
