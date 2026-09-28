# 签名核心（signing_core）· 交接说明

> 位置：`core/logic/` · 纯 Dart，**不依赖 Flutter** · 2,069 行核心 + 655 行测试
> 状态：**已在真实 HAP、真实签名材料、真实设备上验证通过**

---

## 一、这是什么

从「小白·轻启」手机版（`orbit-admin/quietstart-mobile-installer/flutter/hap_installer`）
中**提取出来的签名与侧载端到端核心**，并修掉了原实现的关键缺陷。

原工程 `lib/` 有 9,708 行 Dart，其中签名相关核心约 **546 行**，其余 9,162 行
（94.4%）是 UI、freezed 生成代码、证书申请与华为登录等**与签名无关**的部分。

| 项 | 原工程 | 提取后 |
|---|---|---|
| 签名核心代码 | 散布在 3 个文件 + 502 行 CmdService | `core/logic/` 2,069 行（含注释与校验增强） |
| 代码生成依赖 | freezed + json_serializable（4,551 行生成码） | **无**（`SignConfig` 内联为 92 行普通类） |
| Flutter 依赖 | 有 | **无**（纯 Dart，可命令行测试） |
| 整包大小上限 | **64 MB**（9 处检查） | **无上限** |
| UDID 预检 | **无** | 有（签名前拦截） |

---

## 二、已验证的结论（不是推断）

本机装有 Dart SDK 3.12.2 与真实设备，因此以下都**实跑验证过**：

| 验证项 | 结果 |
|---|---|
| 静态分析 | `dart analyze` **零问题** |
| 单元测试 | **27/27 通过** |
| 解析真实 HAP（10.5 MB，84 条目） | ✅ 通过 |
| 72 MB 条目（**超过原 64 MB 上限**） | ✅ 通过 |
| 直通搬运字节级一致 | ✅ 106381 → **106381**，分毫不差 |
| 预检拦下真实错误 Profile | ✅ 见第四节 |
| 读取真机 UDID | ✅ `4D32998F6E81…`（HBN-AL00 / API 24） |

---

## 三、去掉 64 MB 上限是怎么做到的

### 3.1 原实现的内存问题

```dart
// 原 QuietStartAdapter.dart:16
final bytes = await input.readAsBytes();   // 整包进内存
```

Dart 的 `List<int>` **每个元素是 8 字节对象引用**，所以 64 MB 的包在这一行就是
512 MB，加上后续 `zipView()` 复制、`readHap()` 解包、重组中间态，峰值可达
**800 MB ~ 1.5 GB**。那 9 处 `maxBytes` 检查不是随手写的限制，而是**防 OOM 的护栏**——
直接删掉会让大包在签名中途崩溃，比报错更糟。

### 3.2 新方案：未改动条目「零解压零重压」直通

HAP 里绝大部分字节是 dex/so/资源，本来就是压缩态。新的 `zip_stream.dart` 只替换
少数条目，其余条目按其**原始压缩字节区间**搬运：

```
源文件 ──[随机访问中央目录]──> 定位每个条目的压缩数据区间
                                    │
                 ┌──────────────────┴──────────────────┐
                 │ 未改动条目                            │ 待替换条目
                 │ FileRangeStream 惰性读取               │ 新内容正常压缩
                 │ → ZipEncoder 直通分支（不解压不重压）    │
                 └──────────────────┬──────────────────┘
                                    ▼
                              产物（主包体全程不进内存）
```

### 3.3 三个必须知道的坑（都已实测并规避）

| # | 坑 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | **4 参构造的 `compressionType` 语义** | 它表示「传入内容**本身已是**这种压缩态」，不是「请压缩成这种格式」。误传给替换条目 → 产物报 `Invalid CRC for file in archive` | 替换用 **3 参构造** + `compress=true`；直通用 **4 参 + DEFLATE** |
| 2 | **`noCompress()` 会触发完全解压** | `ZipEncoder` 对 `compress=false` 会先 `file.decompress()`，反而把整条读进内存 | 直通一律用 `compress=true` + DEFLATE |
| 3 | **`InputFileStream` 定位读取有缺陷** | 定位到非零偏移后读取会**多出字节**（实测 106381 → 106454），静默产出损坏 ZIP | 自研 `FileRangeStream`（`range_stream.dart`），字节级一致 |
| 4 | **`Inflate.stream()` 是坏的** | archive 3.6.1 的流式解压在块边界丢比特：8.4 MB 只解出 **88 KB** | 不用流式解压；大条目走 CRC/尺寸判据 |

### 3.4 顺带发现并修复的真实兼容性问题

原解析器会**拒绝带数据描述符的条目**。但实测真实 HAP：

```
unsigned.hap: 84 个条目
  flags 分布: {0x800: 74, 0x808: 10}   ← 10 个条目带数据描述符(0x08)
```

若照搬原逻辑，**真实华为 HAP 会完全无法处理**。已修正：数据描述符只影响本地头，
而中央目录的 `csize`/`usize`/`crc` 始终权威，因此可安全处理。

---

## 四、预检：消灭「UUID 报错」的机制

### 4.1 你的问题是如何发生的

本机签名材料目录里放着两份 Profile：

| 文件 | 绑定 bundle | 本机 UDID 在列 | 有效期 |
|---|---|---|---|
| `xiaobai-debug.p7b` | `org.ohosdev.anime` ❌ | **❌ 否** | 已于 **2025-08-31 过期** |
| `com_tonghongxiang_quietstart.p7b` | `com.tonghongxiang.quietstart` ✅ | ✅ 是（7 台之一） | 到 2027-09-13 |

而 `signConfig.json` 指向的**恰恰是错的那份**。原实现全流程没有任何 UDID 预检
（唯一的 Profile 解析器只看 bundle-name 和 ACL，**完全跳过 device-ids**），于是：

```
签名"成功" → 推到设备 → 设备报 9568423 the device is unauthorized
→ 用户看不懂 → 去"重置证书"  ← 你描述的正是这个循环
```

### 4.2 现在的实际运行输出

```
── 2/5 签名前预检 ──
  Profile  : bundle=org.ohosdev.anime 类型=debug 设备数=10 到期=2025-08-31
  本机 UDID: 4D32998F6E8174CA…
  ✗ PROFILE_EXPIRED: Profile 已于 2025-08-31 22:10:10.000 过期
  ✗ DEVICE_UDID_NOT_AUTHORIZED: 本机 UDID（4D32998F6E81…）不在 Profile 授权列表内（列表含 10 台设备）
      → 这是设备报 9568423 的直接原因：需为该设备重新申请 Profile，而不是重置证书

预检未通过，已阻止签名
```

**签名之前就拦下**，并且直接告诉用户该做什么。

### 4.3 预检覆盖项

| 问题码 | 检查 | 严重度 |
|---|---|---|
| `MATERIAL_MISSING` | 证书/Profile/私钥是否存在 | error |
| `KEY_NOT_PEM` / `KEY_ENCRYPTED` | 私钥必须是未加密 PEM（口令不上命令行） | error |
| `PROFILE_NOT_DEBUG` | 发布 Profile 装不上设备（9568322） | error |
| `PROFILE_BUNDLE_MISMATCH` | Profile 绑定 bundle 与包是否一致 | error |
| `PROFILE_EXPIRED` / `PROFILE_EXPIRING` | 有效期（提前 7 天预警） | error / warning |
| `DEVICE_UDID_NOT_AUTHORIZED` | **本机 UDID 是否在授权列表**（9568423 根因） | error |
| `UDID_UNKNOWN` | 未提供 UDID 时降级提示 | warning |
| `CERT_EXPIRED` / `CERT_EXPIRING` | 证书有效期 | error / warning |

---

## 五、API

```dart
import 'package:signing_core/signing_core.dart';

// 1) 结构检查（返回 null 表示不是轻启包 → 走普通直签）
final info = await PackageInfo.inspect(File('app.hap'));

// 2) 预检（签名之前）
final report = await preflightSigningMaterial(
  config: SignConfig(certPath: ..., profilePath: ..., keystoreFile: ...),
  targetBundleName: 'com.example.app',
  deviceUdid: '4D32...',
);
if (!report.canProceed) { /* report.errors 给出可执行结论 */ }

// 3) 轻启整包分层重签
final r = await signHap(
  input: File('app.hap'),
  output: File('app-signed.hap'),
  profileBytes: await File('profile.p7b').readAsBytes(),
  sign: (i, t, minApi) async { /* 平台签名器 */ },
  progress: print,
);

// 3b) 普通 HAP 直签
final r2 = await signPlain(input: ..., output: ..., minimumApi: 12, sign: ...);

// 4) 安装（错误码 → 结构化结论）
final failure = await HdcInstaller(hdcPath: hdc, target: id).install('app-signed.hap');
```

---

## 六、如何自己验证

### 6.1 跑测试

```bash
cd "core/logic"
dart pub get
dart analyze lib/ test/ tool/     # 应输出 No issues found!
dart test                          # 应输出 All tests passed!（27 个）
```

### 6.2 端到端 CLI（真机）

```bash
dart run tool/sign_cli.dart \
  --input   ~/Documents/hap_installer/store/unsigned.hap \
  --output  /tmp/out.hap \
  --cert    ~/Documents/hap_installer/store/xiaobai-debug.cer \
  --profile ~/Documents/hap_installer/store/xiaobai-debug.p7b \
  --key     ~/Documents/hap_installer/store/key.pem \
  --signer  ~/Library/Caches/hap_installer/hdc_tools/signer \
  --hdc     ~/Library/Caches/hap_installer/hdc_tools/hdc \
  --install
```

退出码：`0` 成功 / `1` 预检失败 / `2` 签名失败 / `3` 安装失败 / `64` 参数错误。

> ⚠️ 用上面那份 `xiaobai-debug.p7b` 会**预期地**停在预检（它绑错 bundle 且已过期）。
> 要跑通完整签名，需要一份**匹配目标包 bundle 且含本机 UDID** 的 Profile。

---

## 七、尚未完成

| 项 | 状态 | 说明 |
|---|---|---|
| 真实轻启包的整包重签 | ⏳ **未验证** | 手上没有含内嵌工作模块的轻启 HAP。逻辑有测试覆盖，但**未在真机跑通** |
| 签名后安装到设备 | ⏳ 未验证 | 缺有效 Profile，卡在预检 |
| ArkTS / 手机端接线 | ⏳ 未开始 | 需把 `sign` 回调接到 `ohosAdapter.signCmd` |
| 商店 App 骨架与 UI | ⏳ 未开始 | 按方案 A：Flutter + 苹果商店风格 UI |
| 元数据服务端 | ⏳ 未开始 | M1 |
| 34 MB 迁移（原小白 app） | ⏳ 未开始 | 见下 |

### 关于「迁移到新商店 App」

原小白工程 34 MB（`entry-default-unsigned.hap`），含 Flutter 引擎 11 MB +
原生库 12.4 MB（`libsigner.so` 5.3M / `libhdc_z.so` 6.8M 等）+ UI 与资源。

迁移时**原生库必须随之携带**——它们是签名与设备通道的实际实现，且
`ohos_adapter` 插件包内含 `libgo_signer.so`。原生 C++ **无需重新编译**
（`cpp/CMakeLists.txt` 的 OHOS 分支本来就只编译 `unhap`）。

---

## 八、给后续开发的提醒

1. **不要用 `Inflate.stream()`**——archive 3.6.1 的实现有丢比特缺陷（§3.3 第 4 条）。
2. **替换条目用 3 参构造，直通条目用 4 参 + DEFLATE**——搞反会产出损坏 ZIP（§3.3 第 1 条）。
3. **不要用 `InputFileStream` 做定位读取**——会多出字节，用 `FileRangeStream`（§3.3 第 3 条）。
4. **大条目不要做整块解压比对**——那正是要消除的内存瓶颈；用尺寸 + CRC，小条目才做深度比对。
5. `workerPayloadLimit`（16 MB）是**工作模块**上限，与「整包无上限」不冲突，不要一起删。
