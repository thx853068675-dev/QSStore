# 轻启·安装器

一个 HarmonyOS 应用商店与侧载安装器：发现、下载 HAP，并在**本机用你自己的开发者证书重新签名**后安装到设备。签名、设备授权与上架记录都绑定在你自己的华为开发者账号下。

## 制品

**[轻启·安装器 0.4.7](https://github.com/thx853068675-dev/QSStore/releases/latest)** — `com.tonghongxiang.hapstore`，versionCode 2026092904，SHA-256 `70b8cc491a879903f4970ecfa61cbc840de6f1ef8eae2bb28add14e804538302`。ArkTS/ArkUI 原生实现，不含 Flutter 运行时。

Release 里的包已指向正式元数据服务，装上即可用。

> **装不上是正常的。** Release 里的包用开发者本人的 AGC 调试 Profile 签名，而调试 Profile **绑定设备**，直接安装会因签名 / 设备授权不匹配而失败。请 clone 本仓库，用 DevEco Studio 打开 `native/`，在你自己的华为开发者账号下配置调试证书与 Profile（把你的设备 UDID 加进去）后自行构建签名。

## 功能

商店列表与详情、历史版本下拉、账号登录、上架与下架、评论（分页）、可恢复下载、本地 HAP 导入、AGC 调试证书管理（列表 / 左滑删除 / 配对使用 / 证书重置）、深色模式、强制登录闸门、设备连接检测。

## 目录

| 路径 | 内容 |
|---|---|
| `native/` | **当前实现**：ArkTS/ArkUI 原生版。签名核心与 HDC TCP 主机以 Rust 源码静态链接进 `libhap_core.so` |
| `core/logic/` | HAP 校验、签名、设备授权逻辑 |
| `app/` | 早期 Flutter 实现，保留作参考 |
| `server/` | Python 元数据、上架、评论与签名身份服务 |
| `core/logic/` | HAP 校验、签名、设备授权逻辑 |
| `tools/` | 构建、部署与运维脚本 |
| `docs/` | API、签名、安全与实机记录 |
| `design/` | 图标源文件与预览 |

## 构建

ArkTS 版的构建与签名见 [native/README.md](native/README.md)。

早期 Flutter 版：

```bash
./tools/build-app.sh release
python3 -m unittest discover -s server/tests -v
cd app && flutter test
```

## 许可

MIT，见 [LICENSE](LICENSE)。
