# 轻启·安装器

从 GitHub Releases 发现 HarmonyOS HAP，在手机上用自己的开发者签名安装。图标采用用户提供的星星角色图，见[原图](design/qingqi-installer-icon-source.png)和[1024 像素预览](design/qingqi-installer-icon.png)。

## 当前状态

- HarmonyOS 6.1 已安装并检查 `0.1.0+2026092736` 的连接、状态栏、发现页、悬浮安装按钮和图标。最新 `0.1.0+2026092737` 增加 HAP 实际应用名与管理页，已构建、签名并通过自动测试，尚未在手机上操作。7.0 设备按用户要求未操作。签名包见[轻启·安装器 0.1.0+2026092737](https://github.com/thx853068675-dev/starstore-harmonyos/releases/tag/v0.1.0-build2026092737)，SHA-256 `512a99dc20788ecdd68d0ec349097bbfb41f7fec54a7e89acde71508612131f7`。证书槽位处理见[恢复说明](docs/CERTIFICATE-RECOVERY.md)。
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
