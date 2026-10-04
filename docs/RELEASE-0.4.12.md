# 原生客户端 0.4.12 发布说明

对应提交 `a4873a4` 之后（分支 `codex/native-arkts-rebuild`）。两个实机反馈的问题。

## 制品

| 项 | 值 |
|---|---|
| 文件 | `dist/qingqi-native-formal-0.4.12-device6.1-signed.hap` |
| SHA-256 | `bd518607bf7fe84c86cf850779ae2eebdfd3bf0ef7c97ba84dbe2d32fe64a43c` |
| 包名 | `com.tonghongxiang.hapstore`（正式包名） |
| versionCode / versionName | `2026092909` / `0.4.12` |

**这是本机自用的候选包**：Profile 只绑定一台设备，装到别的设备会被系统拒绝。

## 0.4.12 新增

### 「更新」判定改用设备上的真实版本

卡片是否显示「更新」看的是 `installedVersionOf`，而它**先取安装记录里的版本号**：

```ts
const fromJob = job !== undefined ? job.versionCode : 0;
return Math.max(fromJob, this.installedVersions.get(appId) ?? 0);
```

记录里存的是「当时装的那个版本」。用户之后用别的途径装了新版本、或记录本身落后，
卡片就会一直显示「更新」，**刷新也没用** —— 因为刷新只更新了 `installedVersions`
那一路，而较大值来自记录。

现在对账时把设备上的**真实版本号**写进 `installedVersions`（取较大值，设备版本更高
时自然胜出），并在写入后重算「是否有更新」。装完刷新即可收敛。

批量查询也顺带拿到了版本号：`bm dump -a` 的输出里每个包都带 `versionCode`，
所以这次**没有增加设备往返次数**。

### 装完后不再立刻重装

原来的安装收尾逻辑是**立刻查一次**版本：

```ts
if (await installedVersion(bundle) !== job.versionCode) {
  await install(job);                       // 再装一遍
  if (await installedVersion(bundle) !== job.versionCode) throw '设备尚未确认安装结果';
}
```

`hdc install` 返回「成功」之后，设备的包管理器仍可能短暂返回旧版本号 —— 安装是
异步落盘的；**自己更新自己时**（安装器更新安装器）旧进程还在跑，窗口更长。于是：
第一次查到旧版本 → 再装一遍 → 还是旧版本 → 抛 `DEVICE` 失败 → 状态回到「等待设备」，
用户看到的就是「卡在 95%，轻启·安装器关闭，重开还要再点一次」。

现在改为**轮询等待**：每 1.5 秒查一次，最多等 15 秒；中途查询抛错（设备断开）立即
放弃——那不是「还没落盘」，继续等没有意义。

## 验证

| 检查 | 结果 |
|---|---|
| ArkTS 发现页刷新/竞态 | 16 项通过（新增 2 项） |
| ArkTS 恢复/并发/CAS 回归 | 17 项通过 |
| ArkTS 安装任务状态 | 9 项通过 |
| Python 服务端 | 36 项通过 |
| C++ HAP 核心 | 17 项通过 |
| Rust | 2 项通过 |
| ArkTS + arm64 原生库 + HAP 构建 | 通过，官方 `hap-sign-tool` 验签 `verify-app success` |

**仍需单独验收**：

- 「装完不再重装」的轮询逻辑**没有单元测试**。它依赖真实 `hdc install` 后的设备
  时序，模拟不出可信场景；下一轮把 `JobRunner` 的运行时适配器接进测试脚手架后补。
- 两处修复都未在实机复验（设备当时不可用）。
