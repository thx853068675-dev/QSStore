# 轻启·安装器

一个 HarmonyOS 应用商店与侧载安装器：发现、下载 HAP，并在**本机用你自己的开发者证书重新签名**后安装到设备。签名、设备授权与上架记录都绑定在你自己的华为开发者账号下。

## 制品

**[最新版本](https://github.com/thx853068675-dev/QSStore/releases/latest)** — `com.tonghongxiang.hapstore`。ArkTS/ArkUI 原生实现，不含 Flutter 运行时。

Release 里的包已指向正式元数据服务，装上即可用。

从 0.4.47 起，Release 提供**无签名 HAP**，不绑定作者设备。请使用支持 HarmonyOS 的侧载工具，用自己的开发者身份为本机签名后安装；也可 clone 本仓库，用 DevEco Studio 打开 `native/` 配置自己的签名材料后构建。

0.4.47 修复轻启内嵌工作模块的授权及签名匹配，手机端两层重签和安装已通过 6.1 实机验证。已经安装同版本轻启但工作模块导入失败时，可在 47 中本地重新导入轻启 HAP 触发修复。详见 [验证记录](docs/RELEASE-47-INNER-SIGNING-20260930.md)。

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
