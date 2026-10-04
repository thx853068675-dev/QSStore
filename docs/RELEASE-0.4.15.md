# 原生客户端 0.4.15 发布说明

对应提交 `608d120` 之后（分支 `codex/native-arkts-rebuild`）。滚动区域高度。

## 制品

| 项 | 值 |
|---|---|
| 文件 | `dist/qingqi-native-formal-0.4.15-device6.1-signed.hap` |
| SHA-256 | `8f46c5078186e5f0071e9847e966fad1ff862f1a2634814518a5b70f385183cb` |
| 包名 | `com.tonghongxiang.hapstore`（正式包名） |
| versionCode / versionName | `2026092912` / `0.4.15` |

**这是本机自用的候选包**：Profile 只绑定一台设备，装到别的设备会被系统拒绝。

## 0.4.15 新增

### 滚动区域高度

「管理」页的列表宽度是全宽，但高度只有中间一块：条目少的时候可视滚动区按内容
高度收缩，下方留一片空白。

原因是列表收尾只写了 `layoutWeight(1)`、漏了 `height('100%')`：

| 页面 | 收尾 |
|---|---|
| 发现 | `.padding(...).width('100%').height('100%')` |
| **管理** | `.padding(...).layoutWeight(1)` ← 缺 `height('100%')` |
| 我的 | `.layoutWeight(1).width('100%')` ← 同样缺 |

现在三处都补成 `.width('100%').height('100%').layoutWeight(1)`，「我的」页一并
对齐。本地页用的是 `Scroll`，本来就带 `height('100%')`，未改动。

## 验证

| 检查 | 结果 |
|---|---|
| ArkTS 四套（恢复 / 发现页 / 安装任务 / 本地目录） | 60 项通过 |
| C++ HAP 核心 | 17 项通过 |
| Python 服务端 | 36 项通过 |
| ArkTS + arm64 原生库 + HAP 构建 | 通过，官方 `hap-sign-tool` 验签 `verify-app success` |

**仍未验证**：`height('100%')` 与 `layoutWeight(1)` 并存在 ArkUI 里的实际布局效果
未在实机确认（设备当时不可用）。若「管理」「我的」两页出现新问题（例如列表高度
异常），回退这一处即可 —— 改动只有一行属性。
