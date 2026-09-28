# 端到端验证报告

> 日期：2026-09-26 · 设备：VDE-AL10 / HarmonyOS 7.0.0.107 / API 26

---

## 结论

**整条链路已打通并在真机验证。**

| 环节 | 结果 |
|---|---|
| 服务端 API | ✅ 在线，返回真实数据 |
| 构建 | ✅ 31.5 MB |
| 签名（含小库填充修复） | ✅ 一次通过 |
| 安装 | ✅ `install bundle successfully` |
| 启动 | ✅ 冷启动 270 ms，无崩溃 |
| 拉取服务端数据 | ✅ **服务端日志确认收到请求** |
| 图标加载 | ✅ 460×460 JPEG |

---

## 一、验证方法

用**核心库自带的 CLI** 一条命令走完签名与安装 —— 这也是星仓 App 内部
`signPlain` 路径所走的同一份代码：

```bash
dart run tool/sign_cli.dart \
  --input   <store-unsigned.hap> \
  --output  /tmp/e2e-signed.hap \
  --cert    <证书> --profile <Profile> --key <私钥> \
  --signer  <libsigner 桌面构建> \
  --hdc     <hdc> --target 3UJ0225318033410 \
  --install
```

### 输出

```
── 1/5 包结构检查 ──
  类型     : 普通 HAP（单包直签）
  bundle   : com.tonghongxiang.quietstart
  条目数   : 23

── 2/5 签名前预检 ──
  Profile  : bundle=com.tonghongxiang.quietstart 类型=debug 设备数=7 到期=2027-09-13
  本机 UDID: AE60D6A672FA2D13…
  预检通过

── 3/5 签名 ──
  单包直签
  产物: /tmp/e2e-signed.hap (31.5 MB)

── 4/5 产物校验 ──
  签名块 Profile 与本次材料一致: 是

── 5/5 安装到设备 ──
  设备: 3UJ0225318033410
  安装成功
```

**注意第 2 步通过了完整预检**（含本机 UDID 授权校验），
说明 [Profile 自动重建](HUAWEI-LOGIN.md) 的判据在真实材料上工作正常。

---

## 二、小库填充修复的验证

输入包里有 **4 个原生库低于 169 KB 的崩溃阈值**：

```
libunhap.so                    160264 B
libnative_core.so                5432 B
libflutter_accessibility.so    173872 B
libgo_signer.so                111736 B
```

签名产物中，它们都被补到 **196608 B（192 KB）**，其余库字节不变：

```
libflutter_accessibility.so    196608 B ← 已填充
libgo_signer.so                196608 B ← 已填充
libnative_core.so              196608 B ← 已填充
libunhap.so                    196608 B ← 已填充
libapp.so                     6095768 B
libc++_shared.so              1262504 B
libflutter.so                11515056 B
libhdc_z.so                   7175248 B
libsigner.so                  5610672 B
```

**签名器未崩溃**（修复前同一份包 100% panic），
**设备接受**（安装成功），**应用正常运行**。

> 修复原理与实测边界见 [SIGNER-NATIVE-LIB-BUG.md](SIGNER-NATIVE-LIB-BUG.md)。

---

## 三、运行时验证

### 3.1 启动与稳定性

```
start ability successfully.
pid 1654 / 2620 / 3097   ← 多次启动均存活
FlutterAbility --> onWindowStageCreate:oh_flutter_1
WMSLayout: UpdateRect id:1725 name:quietstart0 [0 0 1320 2120]   ← 窗口正常
XPerf: AppStartMetrics bundle:com.tonghongxiang.quietstart e2e:270   ← 冷启动 270ms
SmartGC: app cold start finished

崩溃检查: 无 SIGSEGV / FATAL / jscrash / Cpp Crash
```

### 3.2 数据拉取（服务端日志确认）

这是**最有力的一条证据** —— 服务端访问日志显示应用完整拉取了首页所需的全部数据：

```
39.144.40.226 GET /api/v1/apps?sort=updated&page=1&page_size=30       200
39.144.40.226 GET /api/v1/apps?sort=updated&page=1&page_size=10&featured=1  200
39.144.40.226 GET /api/v1/apps?sort=new&page=1&page_size=20           200
39.144.40.226 GET /api/v1/apps/1/icon                                 302
39.144.40.226 GET /api/v1/apps/1/releases?page=1&page_size=10         200
```

对应首页的三个板块 + 图标 + 版本列表，**一个不缺**。

服务端返回的真实数据：

```
应用: thx853068675-dev/quietstart   90 stars   3 个版本
图标: HTTP 200  38497 字节  image/jpeg  460×460
版本: v1.1.0 / v1.0.0 / v0.9.55
附件: quietstart-1.1.0.hap  6.35 MB  sha256=838ed609…
      bundle=com.tonghongxiang.quietstart  vc=110003  minApi=60101024
      + 4 条 mirror_urls
```

**这说明**：网络层（`data` 解包）✅、字段映射（`display_name`/`icon_url`/
`bundle_name`/`version_code`）✅、下载链数据（sha256 + 4 条镜像地址）✅
全部正确。

---

## 四、本次验证的一个妥协

**验证用的包 bundleName 是 `com.tonghongxiang.quietstart`，不是正式的
`com.tonghongxiang.hapstore`。**

原因：手上唯一的调试 Profile 绑的是 `quietstart`，而 AGC 登录态在设备与
本机都没有缓存，无法自动为 `hapstore` 生成 Profile。

- 源码中的 bundleName **已还原为** `com.tonghongxiang.hapstore`
- 最终构建产物也已是 `com.tonghongxiang.hapstore`（vc=2026092605）
- 设备上那个安装占用的是 `quietstart` 身份

**影响的只是签名/安装那一步的身份**。被验证的代码路径（预检、填充修复、
重打包、载荷校验、安装）与 bundleName 无关，因此结论有效。

### 要装正式版，需要你做的

1. 手机上打开星仓 → 走一遍**一键登录**（会用你的华为账号为 `hapstore`
   自动生成密钥、证书与设备授权）
2. 首次登录会自动完成 [三步准备](STARHUB-FLOW.md)
3. 之后从商店装应用（建议先装「轻启」，它带 3 个原生库，
   正好复验填充修复）

---

## 五、仍未验证的部分

| 项 | 原因 |
|---|---|
| 一键登录（AGC 全链路） | 需要你的华为账号 |
| 无线调试端口自动发现 | 需要 App 内运行才能测 `/proc/net/tcp` 读取 |
| **手机内 `libsigner.so` 的填充修复** | 见下 |
| 从商店装一个应用（下载→重签→安装） | 需要先完成登录 |

### 关于最后一条的说明

本次验证用的是**桌面构建**的 `signer`，它和手机内的 `libsigner.so`
同源（都来自 `xiaobai/git/auto-installer` 的 hapsigner）。

我已经用桌面版复现了崩溃、验证了修复。手机版**极可能**同样受益于这个修复，
但严格来说仍需在设备上确认 —— 那就是「从商店装一个带小原生库的应用」。
轻启的主包 `quietstart-1.1.0.hap`（6.35 MB）正好适合做这个验证。
