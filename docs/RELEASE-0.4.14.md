# 原生客户端 0.4.14 发布说明

对应提交 `e0eaf2f` 之后（分支 `codex/native-arkts-rebuild`）。本地安装的版本号、
页面标题、侧载进度的留存。

## 制品

| 项 | 值 |
|---|---|
| 文件 | `dist/qingqi-native-formal-0.4.14-device6.1-signed.hap` |
| SHA-256 | `df66d9e8782933ad4bbe1404e33d2b988a7fbd3f0ece62ffe7e9baccd9867661` |
| 包名 | `com.tonghongxiang.hapstore`（正式包名） |
| versionCode / versionName | `2026092911` / `0.4.14` |

**这是本机自用的候选包**：Profile 只绑定一台设备，装到别的设备会被系统拒绝。

## 0.4.14 新增

### 本地安装的版本号不再显示成日期

界面上的版本号走 `versionLabel()`：先看记录里的 `versionName`，没有就从目录按
`versionCode` 反查版本名，再不行从包名解析，最后才回退到 `versionCode`。本地安装
这三步全都落空：

- 记录里没有 `versionName` —— `PackageIdentity` 只解析了 `versionCode`；
- `appId` 是 0，目录里查不到；
- 本地任务的 `assetName` 是 `<包名>.hap`，不含版本，解析不出。

于是显示 `2026092911` 这种看着像日期的数字。

现在 `PackageIdentity` 一并解析 `app.versionName`（`pack.info` 里有就以它为准，
和 `versionCode` 同样的优先级规则），并沿 `LocalImport.pickAndImport` →
`JobStore.enqueueLocal` 存进任务记录。

### 三个页面标题下的小字去掉

「本地安装 / 管理 / 我的」标题下的副标题（「为设备上的 HAP 安心签名安装」
「你的应用与本机已安装」「账号、证书与设备」）删掉。`heading()` 的副标题参数改为
可选，发现页那个自定义头部不受影响。

### 侧载进度不再跨页留存

本地页的侧载流程卡片是「这一次安装」的过程。装完切到别的页面再回来，它还挂在那里
（时间轴停在上一次的阶段），没有意义。

- 时间轴改为**只在显式选中时显示**：`LocalInstallTimeline.present()` 去掉了
  「没选中就挑最近一条 / 正在跑的那条」的回退，`selectedId` 为空即不显示。
- 离开「本地」页时清掉选中项与投影结果，回到「只有选择文件按钮」的初始状态。
- 只清界面状态，**不删安装记录** —— 装完的任务仍留在「管理 → 已安装」里。

## 验证

| 检查 | 结果 |
|---|---|
| ArkTS 安装任务状态 | 16 项通过（新增 1 项） |
| ArkTS 本地目录/更新 | 11 项通过 |
| ArkTS 发现页刷新/竞态 | 16 项通过 |
| ArkTS 恢复/并发/CAS 回归 | 17 项通过 |
| Python 服务端 | 36 项通过 |
| C++ HAP 核心 | 17 项通过 |
| ArkTS + arm64 原生库 + HAP 构建 | 通过，官方 `hap-sign-tool` 验签 `verify-app success` |

**未处理**：「管理页中间活动区域不是全屏」这一条没能定位 —— `managePage()` 的
`List` 已经是 `.layoutWeight(1)` 且全宽，`Column` 是 `width/height 100%`。需要更具体
的描述（哪一块区域、期望它延伸到哪里）才能继续。

本轮改动未在实机复验（设备当时不可用）。
