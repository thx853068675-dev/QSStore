# 商店 App · 构建与真机验证报告

> 更新：2026-09-26 · 状态：**HAP 构建成功 + 真机安装成功**

---

## 一、结论先行

| 环节 | 状态 |
|---|---|
| Flutter 工具链（鸿蒙分支） | ✅ 复用 `orbit-admin/.toolchains/flutter-ohos-3.7.12-retry` |
| 商店 App 代码 | ✅ 4,676 行，`flutter analyze` 零问题 |
| HAP 构建（release） | ✅ **31.3 MB**，含全部原生库 |
| 签名 | ✅ 用官方 `hap-sign-tool.jar` |
| **真机安装** | ✅ **成功**（VDE-AL10 / API 26） |
| **应用运行** | ✅ **正常运行**（前台 + Flutter 首帧就绪，见 §五） |

---

## 二、构建环境的三个关键坑（都已解决）

### 坑 1：`compatibleSdkVersion` 的格式随 API 版本变化

这是最隐蔽的一个——**报错信息只在日志文件里，命令行看不到**。

```
API 10~25  →  "5.0.0(12)"   形式
API 26+    →  "26.0.0"      形式
```

写错的报错序列（每一步都不同，很容易误判方向）：

| 写法 | 报错 |
|---|---|
| `"5.0.0(12)"`（API 26 SDK 下） | `00306042 Specification Limit Violation`（先转成别的错） |
| `26`（数字） | `00303038 Configuration Error` — `Schema validate failed: must be string` |
| `"6.0.0(26)"` | `api version parameter is illegal! Expected format: <major>[.<minor>][.<patch>]` |
| `"26"` | `00306042` — 提示 API≥26 必须用 `'26.0.0'` |
| **`"26.0.0"`** | ✅ **通过** |

完整报错只在 `app/ohos/.hvigor/outputs/build-logs/build.log`。

### 坑 2：`versionCode` 来自 `pubspec.yaml`，不是 `app.json5`

实测：改 `AppScope/app.json5` 的 `versionCode` **完全无效**，产物仍是旧值。
真正的来源是 `pubspec.yaml` 的 build number：

```yaml
version: 0.1.0+2026092601   # ← 加号后的数字成为 HAP 的 versionCode
```

`versionName` 则来自加号前的部分。

### 坑 3：Flutter 只认 `-signed.hap`，而 hvigor 不签名

`flutter_tools/lib/src/project.dart:1002` 明确查找：

```
entry/build/{flavor}/outputs/{flavor}/entry-{flavor}-signed.hap
```

但 hvigor 只产出 `entry-default-unsigned.hap`，于是 `flutter build hap` 虽然在
日志里显示 `assembleHap` 成功，却报：

```
Hvigor build failed to produce an hap file.
```

**这是"假失败"**——HAP 其实已经生成在
`app/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`。

**所以流程是：`flutter build hap` 产出 unsigned → 我们自己签名。**

---

## 三、签名：桌面 signer 有缺陷，改用官方工具

### 3.1 桌面 `signer` 会崩溃

用 `~/Library/Caches/hap_installer/hdc_tools/signer` 签这个包时 **Go 运行时 panic**：

```
panic in ELFFile.IsELFFile
  → PageInfoGenerator.libExecSegment
  → BaseSignProvider.copyFileAndAlignment
```

崩在**解析原生库（ELF）**的阶段。这个包里有 8 个 `.so`
（`libflutter.so` 57.6 MB、`libhdc_z.so` 6.8 MB、`libsigner.so` 5.4 MB…），
桌面 signer 处理不了。

### 3.2 官方工具可用（推荐）

```bash
SDK=/Applications/DevEco-Studio.app/Contents/sdk
JAVA=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java
JAR="$SDK/default/openharmony/toolchains/lib/hap-sign-tool.jar"

# 官方工具不接受 PEM 私钥，需先转 PKCS12
openssl pkey -in ~/Documents/hap_installer/store/key.pem -out /tmp/clean-key.pem
openssl pkcs12 -export -inkey /tmp/clean-key.pem \
  -in ~/Documents/hap_installer/store/xiaobai-debug.cer \
  -name xiaobai -out /tmp/xiaobai.p12 -passout pass:xiaobai123

"$JAVA" -jar "$JAR" sign-app -mode localSign -keyAlias xiaobai \
  -appCertFile ~/Documents/hap_installer/store/xiaobai-debug.cer \
  -profileFile ~/Documents/hap_installer/store/com_tonghongxiang_quietstart.p7b \
  -keystoreFile /tmp/xiaobai.p12 -keystorePwd xiaobai123 -keyPwd xiaobai123 \
  -signAlg SHA256withECDSA -compatibleVersion 12 -signCode 1 \
  -inFile <unsigned.hap> -outFile <signed.hap>
```

产物用签名核心校验通过：

```
✅ 签名块有效，Profile 长度 4490 字节
   bundleName : com.tonghongxiang.quietstart
   授权设备数 : 7
   到期       : 2027-09-13
```

---

## 四、真机验证结果

设备：**VDE-AL10 · HarmonyOS 7.0.0.107 · API 26**（UDID `AE60D6A6…`）

```
[Info]App install path:/tmp/hapstore-signed.hap
      msg:install bundle successfully.
```

安装后从设备读回：

```
versionCode = 2026092601     ✅ 与构建一致
versionName = 0.1.0          ✅
vendor      = tonghongxiang  ✅
uid         = 20020411
```

### 中途遇到并解决的两个安装错误

| 错误 | 原因 | 解法 |
|---|---|---|
| `9568263 降级` | 设备上已装 versionCode **110011**，而我们的包是 **1** | 把 `pubspec.yaml` 的 build number 提到 `2026092601` |
| 安装包与设备上应用的 bundleName 冲突 | 设备上已有 `com.tonghongxiang.quietstart` | 属正常覆盖升级（同签名可覆盖） |

### ⚠️ 关于本次验证用的 bundleName

为了让安装能走通，本次**临时**把 App 的 bundleName 设成了
`com.tonghongxiang.quietstart`（因为手上唯一含本机 UDID 的 Profile 绑的是它）。

**该临时改动已还原**，源码现在是正式的 `com.tonghongxiang.hapstore`。

因此：

- 设备上那个"商店"应用，实际占用的是 `com.tonghongxiang.quietstart` 这个身份，
  **会与真正的轻启互相覆盖**
- 要装正式版（bundleName 为 `com.tonghongxiang.hapstore`），需要：
  1. 一份绑定 `com.tonghongxiang.hapstore` 的调试 Profile（用小白生成，或走 AGC）
  2. 先卸载设备上那个临时安装（避免身份混淆）

---

## 五、应用运行状态：已成功运行

### 5.1 结论

应用在 **VDE-AL10（HarmonyOS 7.0 · API 26）** 上**正常运行**。

```
Mission ID #1719  com.tonghongxiang.quietstart:entry:EntryAbility
  state      #FOREGROUND        ← 在前台
  app state  #FOREGROUND
  ready #1                      ← Flutter 首帧已就绪
```

Flutter 引擎完整起来了：

```
FlutterAbility --> onWindowStageCreate:oh_flutter_1
XComponent[oh_flutter_1] triggers onLoad / OnSurfaceCreated
RSSurfaceRenderNodeDrawable::OnDraw name:oh_flutter_1Surface   ← 正在渲染
SmartGC: app cold start just finished
```

无崩溃、无异常。

### 5.2 修正一个我先前的误判

我一度根据 `aa start` 的返回信息判断"设备未开启开发者模式"：

```
error: failed to start ability.
  Check in the settings whether the current device is in developer mode
```

**这个判断是错的。** 实际抓取设备日志后发现：

- 应用**当时就启动成功了**（`start ability successfully`，进程 39201）
- 已进入前台、Flutter 引擎已渲染
- 那条提示是 `aa` 命令返回的**通用模板文案**，与真实状态不符

**教训**：`aa start` 的返回文本不可作为启动是否成功的判据，
**应抓 `hilog` 或查 `aa dump -a` 的 `state` 字段**。

### 5.3 两条启动期警告（不致命）

```
E XComFlutterEngine: No sksl asset found.
E XComFlutterOHOS_Native: Could not make main_skia_context
```

这是 Flutter 鸿蒙分支的着色器缓存提示。应用照常渲染
（日志可见 `OnDraw ... oh_flutter_1Surface`）。若后续出现首帧偏慢或
特定视觉效果异常，可从这里查起。

---

## 六、关于 hapstore 的 Profile

**不需要我另行申请。** 直接用小白调试工具侧载即可 ——
它登录华为账号后会自动注册本机设备并签发对应 bundleName 的调试 Profile
（这正是 `EcoServices.autoCreateProfile` 在做的事，见 `SIGNING-CORE.md` §四）。

因此这条不构成阻塞：

1. 用小白把 `com.tonghongxiang.hapstore` 的 HAP 侧载一次
2. 它会生成该 bundleName 的 Profile（含本机 UDID）
3. 之后本项目的 `sign_cli` / App 内签名都能直接用这份材料

> 本次真机验证时，为了能立刻走通安装，临时把 bundleName 对齐到了
> 手上已有的 `com.tonghongxiang.quietstart` Profile。**该临时改动已还原**，
> 源码现在是正式的 `com.tonghongxiang.hapstore`。
> 设备上那个临时安装占用的也是 `com.tonghongxiang.quietstart` 身份。

---

## 七、一键构建脚本

```bash
./tools/build-app.sh release    # 或 debug
```

脚本已封装全部环境变量，并会**预先校验 `compatibleSdkVersion` 格式**
（避免踩坑 1）。它会：

1. 检查鸿蒙 Flutter / DevEco SDK / JBR
2. 校验 `compatibleSdkVersion` 与 API 版本是否匹配
3. `pub get` → `flutter analyze` → `flutter build hap`
4. 定位并报告产物路径 + 打印签名命令

---

## 八、待办

| 项 | 说明 |
|---|---|
| 生成 `com.tonghongxiang.hapstore` 的 Profile | **用小白调试工具侧载即可**（见 §六），不构成阻塞 |
| 卸载设备上那个临时安装 | 它占用 `com.tonghongxiang.quietstart` 身份，会与真正的轻启互相覆盖 |
| 华为登录 → AGC 自动重建 Profile | 见 `SIGNING-CORE.md` §四；这是让「换设备无需手动操作」闭环的最后一环 |

### 一个值得注意的架构事实

商店 App **包内已经带了 `libsigner.so` / `libhdc_z.so` / `libgo_signer.so`**
（见 §二产物清单），说明"在手机里给别人重签"的能力已经随包分发。
而**构建机上的签名**是另一条独立路径（给商店自己签）。
两者互不依赖，这点在设计上是正确的：
用户装别人的应用时，用的是**用户自己的**证书与 Profile，不需要构建机的任何东西。
