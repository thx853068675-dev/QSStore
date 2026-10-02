# 轻启·安装器

HarmonyOS 原生侧载安装器，当前版本 **0.4.50**。

[正式版](https://github.com/thx853068675-dev/QSStore/releases/tag/v0.4.50) · [预览版](https://github.com/thx853068675-dev/QSStore/releases/tag/v0.4.49-preview.1)

- 从 GitHub 上架、下载和更新应用。
- 支持 HAP、APP、ZIP，预览后加入安装队列。
- 使用自己的华为开发者账号签名，通过无线调试安装。

## 构建

准备 DevEco、OHPM、Rust 和 Python 依赖后，在仓库根目录执行：

```sh
python3 tools/check_local.py --offline --build --output /tmp/qingqi-check
```

生成无签名 HAP，由侧载工具签名安装。

[原生工程](native/README.md) · [服务器](docs/SERVER-API.md) · [发行记录](docs/RELEASE-0.4.50.md)
