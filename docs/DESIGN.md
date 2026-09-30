# HAP 商店 · 设计文档与项目计划

> 版本 v0.1（待评审） · 2026-09-26
> 目标读者：项目所有者、后续接手的开发者
> 状态：**预览稿，评审通过后开工**

---

## 0. 文档导读

| 章节 | 内容 | 谁需要看 |
|---|---|---|
| 1 | 需求还原与边界确认 | 你（确认我没理解偏） |
| 2 | 现状审计：为什么小白版不好用 | 你 + 开发 |
| 3 | 总体架构 | 开发 |
| 4 | 签名与侧载底座设计（核心） | 开发 |
| 5 | 错误自愈引擎（错误码 → 自动修复） | 开发 |
| 6 | HAP 商店产品与 UI 设计 | 你 + 设计 |
| 7 | 服务端设计（API / 数据 / 安全） | 开发 + 运维 |
| 8 | GitHub 数据通道设计 | 开发 + 运维 |
| 9 | 工程结构 | 开发 |
| 10 | 项目计划（里程碑与验收） | 你 |
| 11 | 风险与未决问题 | 你 |

---

## 1. 需求还原与边界确认

### 1.1 你的原始诉求（逐条还原）

| # | 你的原话要点 | 我的理解 |
|---|---|---|
| 1 | 签名和侧载底座沿用「小白·轻启 小白特制版」 | 复用其签名器与 HDC 通道，**不重写签名算法本身** |
| 2 | 但需大幅优化，**自动解决报错，不让用户手动操作** | 核心诉求：消灭「清缓存 / 重置证书」这类手动兜底 |
| 3 | 全新的 HAP 商店，风格模仿苹果商店 | 独立 App，UI 对齐 App Store 信息架构与视觉规范 |
| 4 | 应用来源是 GitHub | 无自建应用库，一切内容源自 GitHub 仓库 |
| 5 | 用户上架只需填一个 GitHub 地址 | 上架成本 = 一个 URL，零表单、零审核材料 |
| 6 | 从最新 release 取所有 HAP 版本列表供用户选择 | 解析 release 附件，筛出 `.hap`，含历史版本 |
| 7 | 应用本地不存服务器，只存关键信息 | 服务器只做元数据/索引，**不做文件中转站** |
| 8 | 服务器 47.98.250.230 重置 + 加固 | 见《附录 A 服务器加固报告》 |

### 1.2 边界确认（这些我**不做**，请确认）

- ❌ **不做应用分发托管**：服务器不长期保存 HAP 文件（1.6G 内存 / 40G 盘的机器扛不住，也有法律风险）。
- ❌ **不做账号体系**：商店不要求注册；上架者身份用「仓库归属权」证明（见 7.4）。
- ❌ **不做越狱/绕过授权**：不绕过华为签名校验。所有安装仍使用**用户自己开发者账号**签发的合法调试证书与 Profile。
- ❌ **不做应用内购/支付**。

> ⚠️ **一个必须你确认的产品事实**：HarmonyOS 的 `.hap` 要装进真机，签名必须包含**目标设备 UDID** 的调试 Profile。这意味着「从 GitHub 下载别人的 HAP 直接装」在系统层面是**不可能的**——下载到的 HAP 必须在本地用**你自己的证书**重签。所以本商店的定位是：
>
> **「GitHub 上有什么 HAP」的发现与聚合平台 + 本地一键重签侧载器。**
>
> 商店里没有「安装」按钮，只有**「获取」**按钮，点下去走的是「下载 → 本地重签 → 安装」链路。这是与 App Store 最大的产品差异，也是本设计所有技术复杂度的根源。

### 1.3 关于「服务器直采 GitHub」的现状说明

你选择的是「服务器直采 GitHub」。实测当前服务器**出站 80/443 的应用层数据被阿里云侧丢弃**（诊断详见 [SERVER-HARDENING.md](SERVER-HARDENING.md) §5），因此：

- **架构上不引入任何第三方节点**。运行期只有两端：**手机上的 HAP 商店** 与 **云服务器**。
- 出站放行是**一次性的一次性控制台操作**（阿里云安全组/云防火墙），放行后服务器即可直连 GitHub 采集，**代码无需任何改动**。
- 在放行之前，M1 开发**不受影响**：商店端与 API 端可以先用固定样例数据把全链路跑通；采集器一旦放行即可启用。
- **客户端下载**始终走多镜像链（§8.4），不依赖服务器出站——即使服务器完全不能出网，商店的浏览与下载也能正常工作。

---

## 2. 现状审计：为什么小白版不好用

我通读了 [quietstart-private-110-reference](../../quietstart-private-110-reference)（主工程）、[quietstart-installer](../../quietstart-installer)（签名模块）、[quietstart-supervision-fix](../../quietstart-supervision-fix)（含构建产物）。结论：**「小白·轻启」自身不含签名代码**，签名链路分布在三处——桌面端「小白」(likuai2010/auto-installer，Flutter)、其内置原生 `signer`、以及工程里的 Python 重签脚本。

### 2.1 八个根因（这是「不好用」的全部原因）

| # | 根因 | 证据位置 | 用户看到的现象 |
|---|---|---|---|
| **R1** | `local-hdc-identity.json`（RSA-3072 设备身份）**写入后永不失效、永不轮换**。全工程 grep 不到任何 `unlinkSync`。设备侧 hdcd 一旦撤销该密钥（重装助手、hdc 升级、系统"不信任"），认证返回 `emgmsg E000002`，而代码只打印一句「请在系统弹窗中选择"始终信任"」，**不做密钥轮换** | `LocalActivation.ets:317-328`（写）、`:406-408`（只提示不修复） | 侧载反复失败，只能清应用数据 |
| **R2** | **全流程没有 UDID 预检**。唯一的 Profile 解析器只看 `bundle-name` 和 ACL，**完全跳过 `device-ids` 列表** | `scripts/build-task-keeping-acl.py:30-41` | 装到一半报 `code:9568423 the device is unauthorized` |
| **R3** | **没有证书 ↔ Profile ↔ 私钥三元组预检**（只有一个脚本做了，且只在那一条路径上） | `resign-hap.py` 全程不验；`resign-xiaobai-macos.py:128-129` 仅此一处 | 签名"成功"了但装不上，报 9568322 |
| **R4** | 输出产物缓存是**扁平**的（文档声称按设备分目录），跨设备复用 → 拿到为别人设备签名的包 | 文档 `docs/RESIGN.md:66` vs 实际 `~/Library/Caches/hap_installer/entry-default-signed_signed.hap` | 时好时坏，换设备就不行 |
| **R5** | 签名器 `verify-app` **对非法输入也返回成功**，等于没有校验 | `quietstart-installer/README.md:35`、`QuietStartAdapter.dart:72-74` | 假成功，问题延后到安装阶段爆发 |
| **R6** | **两套签名实现并存**（Java jar vs 原生 signer），keystore 语义不同（PKCS12 vs 裸 PEM）、参数集不同、行为不一致 | `tools/resign-hap.py:98-103` vs `QuietStartAdapter.dart:46-54` | 桌面端能签、手机端签不了，反之亦然 |
| **R7** | **没有机器可读的错误分类**。设备原始报错被塞进一句中文自由文本，下游无法据此决策 | `LocalActivation.ets:454` | 所有错误长一个样，无法针对性修复 |
| **R8** | **签名材料管理混乱**：`signConfig.json` 里 **明文存密码**；同目录下 `xiaobai-debug.p7b` 的 bundle 是 `org.ohosdev.anime`（**错的**），和正确的 `com_tonghongxiang_quietstart.p7b` 躺在一起；`.cer` 链序两种写法并存 | `~/Documents/hap_installer/signConfig.json`、`resign-work/chain/` | 选错 Profile 就静默签错包 |

### 2.2 已知设备错误码对照表（新版必须全部覆盖）

| 错误码 | 含义 | 真实根因 | 新版处置 |
|---|---|---|---|
| `9568423` | device is unauthorized, UDID not in signing profile | Profile 里没有本机 UDID | 触发 **HEAL-02** 自动补签 Profile |
| `9568322` | signature verification failed due to not trusted app source | 用了 AGC 发布证书而非调试证书 | **PRE-03** 预检拦截 |
| `9568320` | no signature file | 包未签名 | **PRE-01** 预检拦截 |
| `9568289` | grant request permissions failed: KEEP_BACKGROUND_RUNNING_SYSTEM | `hdc install -g` 无法替代 Profile ACL 授权 | 提示需在 Profile 中声明 ACL |
| `E000002` | hdc 认证被拒 | 设备侧撤销了本机 RSA 密钥 | 触发 **HEAL-01** 自动轮换密钥 |
| Unauthorized | 无线调试未授权 | 用户未在手机弹窗允许 | 触发 **HEAL-04** 重试+引导 |

---

## 3. 总体架构

### 3.1 四层结构

```
┌─────────────────────────────────────────────────────────────┐
│  L1  HAP 商店 App（HarmonyOS / ArkTS）                       │
│      苹果商店风格 UI · 发现 · 搜索 · 版本选择 · 更新          │
└───────────────┬─────────────────────────┬───────────────────┘
                │ 元数据 API (HTTPS)       │ 下载 HAP (HTTPS)
                ▼                          ▼
┌───────────────────────────────┐  ┌──────────────────────────┐
│  L2  元数据服务（阿里云）      │  │  L3  GitHub 源站 / 镜像   │
│      只存索引，不存包          │  │      release 附件本体     │
│  nginx + Fastify + SQLite     │  └──────────────────────────┘
│         ▲                     │
│         │ 采集器（服务器内）    │
│         └──── 出站放行后直连 GitHub
└───────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│  L4  签名与侧载底座（App 内，独立模块）                        │
│  预检 → 重签（主包+工作模块）→ 验签 → HDC → 安装 → 自愈        │
└───────────────────────────────────────────────────────────────┘
```

> **运行期只有两端**：手机（商店 + 签名底座）与云服务器（元数据 API + 采集器）。不存在任何中间节点或第三方中转。

### 3.2 一图看懂「获取」按钮的完整链路

```
用户点「获取」
   │
   ├─ 1. 从元数据服务拿 release 详情（含 asset 列表、sha256、大小）
   │
   ├─ 2. 下载 .hap 到沙箱（多镜像竞速，见 §8.4）
   │
   ├─ 3. ▓▓ PRE-FLIGHT 预检（7 项，全过才继续）▓▓
   │      证书有效期 / Profile 有效期 / bundle 匹配 / UDID 命中 /
   │      私钥配对 / 证书链序 / 签名材料完整性
   │      └─ 任一失败 → 进自愈引擎（§5），不打扰用户
   │
   ├─ 4. 重签：主 HAP + 内部工作模块（若含）分层重签
   │      每一步后做「载荷未变」校验 + 真实密码学校验
   │
   ├─ 5. 验签（真校验，不信任 signer 的退出码）
   │
   ├─ 6. 通过本地 HDC 通道推到设备并 bm install
   │      └─ 失败 → 错误分类 → 自愈 → 重试（最多 3 轮）
   │
   └─ 7. 成功：清除本次临时产物；失败：输出可分享诊断包
```

---

## 4. 签名与侧载底座设计

> **定位（已确认）**：**沿用现有的「小白·轻启」签名与侧载模块，在其上做优化**，不是重写。
> 本节只描述**改什么、为什么改、怎么改**。

### 4.0 现有底座盘点

签名链路分布在三处，**代码都在本机，可直接改**：

| 位置 | 内容 | 语言 |
|---|---|---|
| `quietstart-installer/core/lib/quietstart_signing.dart` | HAP ZIP 解析、工作模块分离/重组、Profile 一致性校验 | Dart（300 行） |
| `quietstart-installer/QuietStartAdapter.dart` | 调用原生 `signer`，证书/Profile/私钥临时隔离 | Dart（80 行） |
| `quietstart-private-110-reference/entry/.../core/` | HDC 协议、工作模块安装、身份管理 | ArkTS |
| 内置原生 `signer` | 实际签名执行体（`sign-app`） | 原生二进制 |
| `tools/resign-hap.py` | 另一套 Java jar 重签实现（桌面脚本用） | Python |

**结论**：底座是现成的、能跑的。优化点集中在 **① 大小上限 ② 预检缺失 ③ 缓存/身份永不失效** 三类。

### 4.1 优化点一：HAP 大小上限（**你要的重点**）

#### 现状：9 处硬编码上限

| # | 位置 | 内容 | 作用 |
|---|---|---|---|
| 1 | `quietstart_signing.dart:12` | `const maxBytes = 64 * 1024 * 1024` | 上限常量（64 MB） |
| 2 | `quietstart_signing.dart:22` | `bytes.length > maxBytes` | ZIP 视图入口校验 |
| 3 | `quietstart_signing.dart:58` | `total > maxBytes` | 中央目录累计解压尺寸 |
| 4 | `quietstart_signing.dart:81` | `bytes.length > maxBytes` | `readHap` 入口校验 |
| 5 | `quietstart_signing.dart:88` | `total > maxBytes` | 逐文件累计尺寸 |
| 6 | `QuietStartAdapter.dart:12` | `input.length() > maxBytes` | 待签文件预检 |
| 7 | `prepare.py:103` | `file.lengthSync() > quietstart.maxBytes` | 构建期校验 |
| 8 | `fetch_hap.py:10-11` | `read(64MB + 1)` | 下载期校验 |
| 9 | `quietstart_signing.dart:124` | `payload.length > 16777216` | **独立限制**：工作模块 16 MB |

#### 关键发现：这不是可以简单删掉的常量

```dart
// QuietStartAdapter.dart:15-16 —— 整包读进内存
final bytes = await input.readAsBytes();
if (QuietStartPackage.inspect(bytes) == null) return false;
// 之后 bytes 一路传给 resignQuietStart(input: bytes, ...)
```

**实测内存模型**：

| 环节 | 内存行为 |
|---|---|
| `readAsBytes()` | 整个 HAP 变成 `List<int>`。**Dart 的 `List<int>` 每元素是 8 字节对象引用**，64 MB 的包在此处 ≥ 512 MB |
| `zipView()` | 构造 `Uint8List.fromList(bytes)` **再复制一份** |
| `readHap()` | 解析出全部文件内容，**又一份**（`List<int>.from`） |
| `resignQuietStart()` | 组织新包、写临时文件，**再一份** |

→ **一个 64 MB 的包，峰值内存可达 800 MB ~ 1.5 GB。**

**所以：那 9 处检查是防止 OOM 的护栏，不是随手加的限制。** 若只把常量改大而不动架构，结果是大包在签名中途把小白的宿主进程打崩——**比"报大小超限"更糟**，因为崩在签名中途，可能产出损坏的中间文件。

#### 正确做法：改内存模型 + 放宽上限

| 改造 | 说明 |
|---|---|
| **流式解包** | 不再整体 `readAsBytes()`。改为基于 `RandomAccessFile` 按中央目录随机读取条目，逐个处理 |
| **磁盘中转替内存** | 工作模块解出后落盘到临时目录，用路径传递而非字节数组 |
| **签名器已支持文件输入** | 原生 `signer` 参数是 `-inFile / -outFile`，**本来就是文件到文件**，无需经过内存 |
| **分块哈希** | `unchanged_payload` 一致性校验改用流式 SHA-256，避免为比对再读两份 |
| **上限策略** | 不再硬编码，改为**基于可用内存的动态阈值**（如取 `可用内存 × 0.25`）＋ 一个**极高**的兜底阈值（如 2 GB）防恶意包 |

**收益**：上限从 64 MB 提到「受磁盘与内存共同决定的实际能力」，且峰值内存从「包大小 × 数倍」降到「常数级」。

#### 关于工作模块的 16 MB 上限（`16777216`）

这是**另一条独立限制**，不要和整包上限混淆：

- 它约束的是「嵌入在主 HAP 里、由轻启 App 自行安装的工作模块」
- 该模块走 **HDC + base64 分块传输**，而 base64 会膨胀 33%
- 它由 `module.json` 的 `manifest.size / sha256` 双重绑定，改动需同步更新摘要

**待确认**：你说的「去掉大小上限」若特指这一条，改造范围会小很多（只动 ArkTS 侧 `WorkerInstaller` 与传输分块），但需要同时处理 base64 膨胀与传输超时。

### 4.2 优化点二：预检缺失（**UUID 报错的根源**）

现状：**全流程没有 UDID 预检**。唯一的 Profile 解析器只看 `bundle-name` 和 ACL，**完全跳过 `device-ids` 列表**（`scripts/build-task-keeping-acl.py:30-41`）。

→ 结果：包签好了、推到设备了，才弹 `code:9568423 the device is unauthorized`。用户看到的就是「UUID 错误」，然后就只能去重置证书。

**优化：在签名前插入预检**（复用现有解析能力，不新建子系统）

| 检查 | 判定 | 失败时的自动动作 |
|---|---|---|
| 证书有效期 | `notAfter > now + 7d` | 提前提醒续期 |
| Profile 有效期 | `notAfter > now + 7d` | 提前提醒 |
| **Profile ↔ 包 bundle 匹配** | 逐模块比对 `bundle-info.bundle-name` | **自动从材料库选正确的 Profile**（现状：同目录下躺着 bundle 为 `org.ohosdev.anime` 的错 Profile，会被静默选中） |
| **UDID 命中** | 本机 UDID ∈ `debug-info.device-ids` | 明确告知缺哪个设备，而不是等设备报错 |
| 私钥 ↔ 证书配对 | 私钥签名挑战串、证书公钥验回 | 明确告知材料不匹配 |
| 证书链完整性 | 能否重建 leaf→root | 拦截，不再让设备报 `9568322` |

> **收益**：把「装到一半失败、用户去重置证书」变成「签名前就说清缺什么」。

### 4.3 优化点三：缓存与身份永不失效（**必须清缓存的根源**）

| 问题 | 证据 | 优化 |
|---|---|---|
| 设备身份密钥**写入后永不轮换** | `LocalActivation.ets:317-328` 写入；全工程 grep 不到 `unlinkSync`；`:406-408` 遇到 `E000002` 只提示不修复 | 加生命周期：识别到认证被拒 → **自动轮换密钥对** → 重新认证 |
| 输出产物缓存跨设备复用 | 文档称按设备分目录（`docs/RESIGN.md:66`），实际是扁平缓存 `entry-default-signed_signed.hap` | 产物目录按「设备 UDID + Profile 摘要」隔离，用完即焚 |
| 签名器「假成功」 | 原生 `verify-app` 对非法输入也返回成功（`quietstart-installer/README.md:35`） | 保留现有做法（不信退出码），补一次真实校验 |
| 错误不可分类 | 设备原始报错塞进一句自由文本（`LocalActivation.ets:454`） | 加错误码解析层，把 `9568423/9568322/9568320/E000002` 映射为可执行动作 |

---

## 5. 错误自愈引擎（本项目的灵魂）

### 5.1 状态机

```
        ┌──────────┐
        │  IDLE    │
        └────┬─────┘
             ▼
        ┌──────────┐   预检失败    ┌──────────────┐
        │PREFLIGHT ├──────────────►│ SELF_HEAL(n) │
        └────┬─────┘               └──────┬───────┘
             │ 通过                        │ 修复动作
             ▼                             │
        ┌──────────┐   签名失败            │
        │  SIGN    ├──────────────────────►┤
        └────┬─────┘                       │
             │ 成功                         │
             ▼                             │
        ┌──────────┐   安装失败            │
        │ INSTALL  ├──────────────────────►┤
        └────┬─────┘                       │
             │ 成功                         │ n < 3 且动作有进展
             ▼                             ▼
        ┌──────────┐              回到失败所在阶段重试
        │ SUCCESS  │
        └──────────┘
        任一阶段：n ≥ 3 或动作无进展 → 输出诊断包 + 人类可读建议
```

**关键约束**：自愈必须**有进展才重试**。同一动作重复无效即终止，避免死循环（这是现状 R1 的病根）。

### 5.2 自愈动作表

| 编号 | 触发条件 | 自动动作 | 是否需用户介入 |
|---|---|---|---|
| **HEAL-01** | `E000002` / 认证被拒（**设备身份问题，与签名无关**） | **自动轮换设备身份密钥对** → 重新认证 → 重试 | 仅需在系统弹窗点「始终信任」 |
| **HEAL-02** | Profile 缺本机 UDID / Profile 过期 | **在签名前预检发现**，明确告知「本机 UDID `xxxx` 不在授权列表内，列表含 N 台设备」→ 触发一次材料刷新（沿用现有小白的 Profile 获取机制）→ 自动重签。**不引入新的凭证体系** | 若需重新登录华为账号，仅此一次 |
| **HEAL-03** | Profile 与包 bundle 不匹配 | 从材料库中按 bundleName 索引自动选正确 Profile | 全自动 |
| **HEAL-04** | 安装返回 Unauthorized | 重连 HDC、重置端口缓存、重试；仍失败则引导授权 | 需在手机确认 |
| **HEAL-05** | 端口变更 / 连接断开 | 重新发现无线调试端口（读系统状态而非让用户手抄） | 全自动 |
| **HEAL-06** | 签名器产物非法 | 清理本次产物 → 隔离重试（禁用并行） | 全自动 |
| **HEAL-07** | 磁盘/临时目录异常 | 清理过期临时目录与历史产物后重试 | 全自动 |

### 5.3 用户可感知的差异（验收标准）

| 场景 | 现状（小白版） | 新版 |
|---|---|---|
| 设备撤销了调试密钥 | 反复失败，**要手动清应用数据** | 自动轮换身份，弹窗点一次「信任」 |
| Profile 缺本机 UDID | 装到一半报 `9568423`，**要重置证书** | 预检发现 → **自动补签** → 继续 |
| 换了一台手机 | 时好时坏（缓存串设备） | 设备指纹隔离，自动重新预检 |
| 线序/材料不匹配 | 静默签错包 | PRE 阶段拦截并说明原因 |
| 任意失败 | 一句中文报错，看不懂 | 错误码 + 原因 + 建议 + 一键导出诊断包 |

---

## 6. HAP 商店产品与 UI 设计

### 6.1 信息架构（对齐 App Store）

底部五个 Tab：

| Tab | 内容 |
|---|---|
| **今日** | 编辑精选流：大卡片、专题、新上架、限时推荐 |
| **应用** | 分类浏览（工具/效率/媒体/开发/游戏…）、排行榜 |
| **搜索** | 搜索框 + 热门搜索词 + 最近搜索（本地） |
| **更新** | 已安装应用的可用更新（对比本地版本与本机已装版本） |
| **我的** | 已获取、我的上架、签名材料状态、设备管理、设置 |

Apple 风格的核心页面范式：

- **App 详情页**：图标 1024 → 名称/副标题/开发者 → **「获取」圆角药丸按钮** → 截图横滑 → 「新功能」+ 版本历史 → 评分与评论 → 信息表（开发者/大小/分类/兼容性/语言）→ 隐私摘要
- **版本选择**：详情页「版本历史」可展开，每个 release 一张卡，列出该 release 下**全部 `.hap` 附件**，用户可选装任意历史版本（自动标注「最新」/「测试版」）
- **上架页**：**只有一个输入框** —— 粘贴 GitHub 仓库地址，点「检查」→ 展示解析结果（图标/名称/版本数/README 摘要）→ 点「发布」

### 6.2 视觉规范（设计 token）

> **本节已于 2026-09-27 与实现对齐。** 之前这里的色值和圆角是一份「iOS 命名 + Tailwind 色值」
> 的草稿，与 `app/lib/theme/tokens.dart` 已经漂移（分隔线、卡片圆角、主色都对不上），
> 审查结论见 [DESIGN-REVIEW-UI.md](DESIGN-REVIEW-UI.md)。现在**以 `tokens.dart` 为唯一真源**，
> 本节只做索引；改令牌必须同步改这里。

```dart
// app/lib/theme/tokens.dart —— 唯一真源
Space  { xs 4, sm 8, md 12, lg 16, pageGutter 20, xl 24, xxl 32, huge 44, touch 44 }
Radii  { field 12, card 20, button 22, sheet 28, iconCornerPercent 22.5 }
Sizes  { buttonMd 44, buttonLg 52, rowIcon 60, detailIcon 72 }
Font   { largeTitle 34, title1 28, title2 22, title3 20, headline 17, body 17,
         callout 16, subhead 15, footnote 13, caption 12 }
```

**颜色**

| 语义 | 浅色 | 深色 | 说明 |
|---|---|---|---|
| `background` | `#FFFFFF` | `#000000` | canvas |
| `backgroundGrouped` | `#F6F7FB` | `#101722` | 页面底 |
| `card` | `#FFFFFF` | `#1A2431` | 卡片/行 |
| `text` | `#142033` | `#FFFFFF` | |
| `textSecondary` | `#667085` | `#A8B4C5` | 副标题 |
| `textTertiary` | `#828C9E` | `#8494A9` | 仅图标/箭头，≥3:1 |
| `separator` | `#D0D7E2` | `#334154` | hairline |
| `accent` | `#1769E0` | `#78ACFF` | |
| `onAccent` | `#FFFFFF` | `#08111F` | 压在主色实底上的前景 |
| `fillAction` | `#F0F3F8` | `#28313F` | 「获取」药丸底（中性，不淡染主色） |
| `fillSelected` | `#EDF1F7` | `#28313F` | 导航/分段选中底 |
| `fillDisabled` | `#EDF1F7` | `#28313F` | 禁用底 |
| `fillPlaceholder` | `#EDF1F7` | `#28313F` | 头像/图标占位底 |
| `fillSecondary` | `#F1F4F9` | `#253143` | 卡片内次级底 |
| `green` / `greenText` | `#34C759` / `#11763A` | `#30D158` / `#4CD964` | 图标 / 文字 |
| `red` / `redText` | `#FF3B30` / `#C0271C` | `#FF453A` / `#FF6B61` | 图标 / 文字 |
| `orange` / `star` | `#FF9500` | `#FF9F0A` | |

**硬约束（有回归测试守住，见 `app/test/design_tokens_test.dart`）**

1. 主题必须显式 `useMaterial3: false`，且 `colorScheme` 跟随 `accent`。
   只设 `primaryColor` 不够——Material 控件的默认色取自 `colorScheme`。
2. 文字色在 `card` 与 `backgroundGrouped` 上均 ≥ 4.5:1；`textTertiary`（图标）≥ 3:1；
   `separator` 在卡片上 ≥ 1.4:1。
3. 页面级水平内边距只有 `Space.pageGutter` 一条；卡片内部才是 `Space.lg`。
4. 填充按钮只有 `AppButton` 一个实现，尺寸只有 `Sizes.buttonMd` / `buttonLg` 两档，
   圆角只有 `Radii.button`。视觉高度可以小于 44，命中区必须包到 `Space.touch`。
5. `AppText` 每个样式都必须带 `height`；调用点不要再 `copyWith(height:)`。
6. 固定高度一律用 `minHeight`，保证系统字号放大时不被裁切。

### 6.3 组件清单

| 组件 | 说明 |
|---|---|
| `AppIconTile` | 圆角 22.5% 图标，带占位与渐进加载；`fetchBytes` 是全局唯一的取图路径（证书固定 + 体积上限 + 失败兜底） |
| `NetworkAvatar` | 圆形头像，复用 `AppIconTile.fetchBytes`，不要直接用 `CircleAvatar(foregroundImage: NetworkImage(...))` |
| `AppButton` | 全站唯一的填充按钮：`primary / secondary / destructive` × `buttonMd / buttonLg`，圆角统一 |
| `GetButton` | 「获取 / 打开 / 更新 / 下载中(环形进度)」四态药丸按钮；已安装态是纯文字，可安装态是有底药丸 |
| `AppRowCard` | 列表行：图标 + 名称 + 副标题 + 获取按钮 |
| `FeatureCard` | 今日页大卡：大图 + 标题 + 副标题 + 「了解更多」 |
| `SectionHeader` | 分组标题 + 右侧「全部」 |
| `RatingStars` | 五星（支持半星） |
| `SegmentedControl` | iOS 风格分段控件 |
| `InstallProgressSheet` | 半屏浮层：下载/重签/安装三阶段进度 + 实时日志（可折叠） |
| `VersionHistoryList` | 版本历史 + HAP 资产选择 |
| `DiagnosticSheet` | 失败诊断：错误码、原因、已尝试的自愈动作、导出按钮 |
| `MaterialStatusCard` | 签名材料健康度：证书/Profile 有效期、UDID 覆盖数、到期提醒 |

**动效**：页面转场用系统 `Navigation` 默认转场；获取按钮按下时缩放 0.96；安装成功时图标一次「弹入」；列表用 `LazyForEach` 保证长列表 60fps。

**行与分隔线**：通栏列表行（`AppRowCard`、版本历史行）之间必须有 hairline，
缩进到文字列（`Space.pageGutter + Sizes.rowIcon + Space.md`）。没有分隔线时相邻行会连成一块白板。

### 6.4 深浅色与无障碍

- 全量深浅色自适应（`@ohos.app.ability.Configuration` 监听）
- 所有可点区域 ≥ `Space.touch`（44vp）。视觉尺寸可以更小，命中区不行——
  唯一例外是分段控件：轨道高沿用 iOS 原生的 32pt（平台约定）。
- 文本支持系统字号缩放：固定高度一律改 `minHeight`，见 6.2 的硬约束 6
- 文字对比度 ≥ 4.5:1，图标 ≥ 3:1（`textTertiary`、`greenText`、`redText` 就是为此拆出来的）
- 图标按钮全部带 `accessibilityText`

---

## 7. 服务端设计

### 7.1 定位

**只存关键信息**：应用身份、仓库绑定、release 索引、HAP 资产清单、下载计数、校验值。**不存 HAP 文件本体。**

### 7.2 技术选型

| 层 | 选型 | 理由 |
|---|---|---|
| Web 服务器 | nginx（已装） | 复用现有，加限流与反代 |
| 应用服务 | **Node.js 20 + Fastify** | 内存占用低（~80MB），生态成熟 |
| 数据库 | **SQLite (WAL)** | 单机零运维，数据量级（万级应用）绰绰有余 |
| 进程管理 | systemd 单元 + `Restart=always` | 与现有运维方式一致 |
| 传输 | **HTTP（80 端口，IP 直连）** | 不申请域名与证书，见 §7.6 |

> 内存预算：加固后可用内存约 **1.0~1.1 GB**（LobeChat 已停）。Fastify + SQLite + nginx 合计预计 < 200 MB。

### 7.3 API 契约（v1）

```
GET  /api/v1/apps?q=&category=&sort=&page=&page_size=
        → { items: AppSummary[], total, page }
GET  /api/v1/apps/:id
        → AppDetail { id, repo, owner, name, summary, icon_url, category,
                      tags, stars, license, latest_release, releases_count }
GET  /api/v1/apps/:id/releases?page=
        → Release[] { tag, name, published_at, prerelease, body_excerpt,
                      assets: HapAsset[] }
             HapAsset { name, size, sha256, min_api, module_type, url, mirror_urls[] }
GET  /api/v1/apps/:id/releases/:tag
        → Release 详情（含完整 body、全部 assets）
GET  /api/v1/apps/:id/icon
        → 302 → 图标真实地址（走镜像链）
POST /api/v1/submit            { repo_url }
        → 202 { task_id }  （异步解析校验）
GET  /api/v1/submit/:task_id
        → { status, app?, errors[] }
POST /api/v1/apps/:id/report   { reason, detail }   # 举报
POST /api/v1/apps/:id/download-event { asset, device }  # 匿名计数
```

**统一响应包装**

```json
{ "ok": true,  "data": {}, "server_time": "2026-09-26T12:00:00Z", "api_version": 1 }
{ "ok": false, "error": { "code": "REPO_NOT_FOUND", "message": "…", "hint": "…" } }
```

**限流**：普通接口按 IP 限制 120 req/min；`POST /api/v1/submit/prepare` 按已验证账号限制 3 req/min。无效地址不占次数，同一账号、同一仓库五分钟内复用预处理结果。超限返回 `429`，`Retry-After` 为实际剩余等待秒数。

### 7.4 上架与身份

**上架流程**（对应你「只需填一个 GitHub 地址」）：

```
1. 用户粘贴 https://github.com/<owner>/<repo>
2. 服务端规范化 + 校验仓库存在、公开、非 fork 黑名单
3. 拉取 releases → 筛 *.hap 附件 → 至少 1 个才允许上架
4. 拉取仓库元信息（描述/话题/star/license/README）作为商店条目
5. 写入 DB，状态 = published
```

**归属权证明**（防他人冒名上架你的仓库）：

- 商店生成一次性 `nonce`，展示为 `hapstore-verify=<nonce>`
- 上架者把该字符串写入仓库的 `.hapstore/verify.txt`（或任一 release 说明）
- 服务端读取校验 → 标记 `verified=true`
- **未验证**的应用照常展示，但带「未验证来源」标识；已存在他人先占时，验证者优先

> 这样零账号、零表单，符合你「只填一个地址」的设计。

### 7.5 安全设计（配合附录 A 的加固）

| 面 | 措施 |
|---|---|
| 传输 | 全站 HTTPS（HSTS），HTTP 301 跳转 |
| 输入 | 仓库 URL 严格白名单正则（仅 `github.com`），拒绝 SSRF（禁止内网 IP、禁止重定向到非 GitHub 域名） |
| 输出 | 全站安全响应头：CSP、`X-Content-Type-Options`、`Referrer-Policy`、`Permissions-Policy` |
| 限流 | nginx `limit_req` + 应用层二级限流 |
| 注入 | SQLite 全参数化查询；JSON body 大小上限 32KB |
| 依赖 | 锁定版本 + `npm audit` 纳入 CI |
| 审计 | 上架/举报/管理操作写审计日志（保留 90 天） |
| 管理接口 | 仅 localhost 监听，通过 SSH 隧道访问，不暴露公网 |
| 备份 | SQLite 每日 `VACUUM INTO` 快照，保留 7 份 |

### 7.6 接入方式：直接使用 IP，不申请域名（**已定**）

| 项 | 方案 |
|---|---|
| API 地址 | `http://47.98.250.230/api/v1/*` |
| 协议 | **HTTP 明文**（80 端口已放行并受 UFW 管控） |
| 证书 | 不申请，不做 TLS |
| 域名 | 不申请，不需要 ICP 备案 |

**取舍说明**：

- ✅ **零成本、零等待**：不需要域名、不需要备案（通常 1~3 工作日）、不需要证书续期运维
- ✅ **HarmonyOS 侧无障碍**：ArkTS `@kit.NetworkKit` 直接支持 HTTP，无需处理自签证书信任
- ⚠️ **已知代价**：明文流量可被运营商/中间网络观测。但本项目传输的是**公开的 GitHub release 元数据**与下载地址，**不含任何用户隐私、账号或密钥**，代价可接受
- 🔒 **防护边界**：签名私钥、AGC 令牌等敏感材料**只存在手机本地**，永不经过服务器；服务器不要求任何登录凭证

> 升级路径（暂不做）：IP 地址同样可签发证书（Let's Encrypt 支持 IP 证书），届时客户端加证书指纹 pinning 即可切换到 HTTPS。

---

## 8. GitHub 数据通道设计

> **原则：只有两端。** 采集器是**元数据服务的一个内部模块**，随服务一起跑在云服务器上，不引入任何外部节点。

### 8.1 实测约束

| 事实 | 证据 |
|---|---|
| 服务器**入站** 22/80/443 已放行且受 UFW 管控 | `ufw status` + 外网实测 `/` 返回 200 |
| 服务器**出站 80/443 应用层被丢弃** | TCP 握手 OK，但 HTTP 0 字节超时；已排除本机防火墙/MTU/DNS/offload |
| 判定为阿里云侧拦截 | 详见 [SERVER-HARDENING.md](SERVER-HARDENING.md) §5 |
| 镜像站 `gh-proxy.com` 可用 | 实测取到轻启 v1.1.0 / v1.0.0 真实 release 及全部附件 |

### 8.2 采集器（服务器内部模块，非独立节点）

```
元数据服务进程
 ├── API 路由（对手机提供 /api/v1/*）
 ├── 采集器 worker（Node 内定时任务，无独立进程/容器）
 │     ├── 出站探测：每 5 分钟探测一次 GitHub 可达性
 │     ├── 通 → 直连 api.github.com 采集
 │     └── 不通 → 走镜像链采集（gh-proxy.com 等）
 └── SQLite（WAL）
```

**设计要点**：
- 采集器**没有任何独立部署形态**，就是 API 服务里的一个定时任务 —— 部署面最小化
- **出站不通时不是「瘫痪」，而是「降级」**：自动切到镜像链继续采集（`gh-proxy.com` 已实测可用）
- 采集失败时 API 仍正常返回**上次成功的数据**，并在响应里带 `stale: true` 与 `data_age_seconds`，商店端据此显示「数据更新于 X 小时前」
- 因此**出站放行是「优化项」而非「阻塞项」**：即使永远不放行，只要有一个镜像可用，商店就能持续更新

### 8.3 采集策略

| 项 | 策略 |
|---|---|
| 触发 | 定时（已上架应用每 6 小时）+ 上架时立即 + 手动刷新（限频） |
| 增量 | 用 `ETag` / `If-None-Match`，304 不重复写库 |
| 限流 | GitHub 匿名 60 req/h；配置 PAT 后 5000 req/h（**PAT 只存服务器环境变量**） |
| 镜像链 | 直连 → `gh-proxy.com` → `cdn.jsdelivr.net`，逐个降级，全部失败才标记 `stale` |
| 退避 | 403/429 时指数退避，最长 6 小时 |
| 解析 | 只取 `*.hap` 附件；解析 HAP 内 `module.json` 提取 bundleName/versionCode/minAPI（用于兼容性提示） |
| 校验值 | 若 release 提供 `SHA256SUMS.txt` 则直接取用；否则服务器流式下载计算（**仅计算，不落盘留存**） |

### 8.4 客户端下载链（手机直连，不经服务器）

```
候选链（手机端并行竞速，取最先响应者）：
  1. gh-proxy.com/<原始 URL>          ← 国内实测可用，首选
  2. ghfast.top / ghproxy.net 等镜像
  3. cdn.jsdelivr.net/gh/<owner>/<repo>@<tag>/<path>   （仅仓库内文件）
  4. 直连 github.com                   （境外网络或手机自带代理时最快）
策略：并行首字节探测 → 取最快 → 分片续传 → sha256 校验通过才进入签名流程
```

**关键**：HAP 文件**不经过服务器中转**，手机直接从 GitHub/镜像下载。这既符合你「应用本地不存服务器」的要求，也让 1.6 GB 内存的小机器完全没有带宽压力。

> ⚠️ 服务器**只提供「哪个地址、多大、什么 sha256」这类元信息**，实际字节流走手机 → CDN。这也是本项目能在小机器上跑起来的前提。

---

## 9. 工程结构

```
Tong Store/
├── app/                                  # L1 HarmonyOS 应用（独立工程）
│   ├── AppScope/                         # bundleName: com.tonghongxiang.hapstore
│   ├── entry/src/main/ets/
│   │   ├── entryability/
│   │   ├── pages/                        # Index(今日) Apps Search Updates Mine
│   │   ├── view/app/                     # 详情页、版本历史、上架页
│   │   ├── view/component/               # §6.3 组件
│   │   ├── theme/                        # Tokens.ets
│   │   ├── model/                        # 数据模型与 ViewModel
│   │   ├── net/                          # API 客户端、镜像竞速下载器
│   │   ├── signer/                       # §4 签名底座
│   │   ├── hdc/                          # 设备通道（复用轻启实现）
│   │   ├── store/                        # 本地持久化（已获取/设置/材料索引）
│   │   └── util/
│   └── entry/src/ohosTest/
├── server/                               # L2 元数据服务（含采集器，单进程）
│   ├── src/{app,routes,db,collector,verify}/
│   ├── migrations/
│   ├── deploy/{nginx,hapstore-api.service,install.sh}
│   └── package.json
├── tools/                                # sshx.exp / scpx.exp / 运维脚本
└── docs/                                 # 本设计文档、加固报告、API 文档
```

**数据库表（草案）**

```sql
app(id, repo_full_name UNIQUE, owner, name, summary, description, icon_url,
    category, tags_json, stars, license, verified, status, created_at, updated_at)
release(id, app_id, tag UNIQUE(app_id,tag), name, published_at, prerelease,
        body, html_url, etag, fetched_at)
asset(id, release_id, name, size, sha256, content_type,
      bundle_name, version_code, min_api, module_type, download_url)
submit_task(id, repo_url, status, result_json, ip_hash, created_at)
report(id, app_id, reason, detail, ip_hash, created_at)
event_download(id, app_id, asset_id, device_hash, created_at)  -- 匿名
audit_log(id, actor, action, target, detail_json, created_at)
```

---

## 10. 项目计划

### 10.1 里程碑

| 阶段 | 名称 | 交付物 | 预估 |
|---|---|---|---|
| **M0** | 服务器重置与加固 | 加固报告、可回退备份、密钥登录 | ✅ **已完成**（见附录 A） |
| **M1** | 骨架与通道打通 | 独立工程可编译运行；元数据服务上线；采集通道双模可用 | 3~5 天 |
| **M2** | 商店 UI（无签名） | 五 Tab + 详情页 + 搜索 + 版本历史；接真实 GitHub 数据 | 5~8 天 |
| **M3** | 签名底座 + 预检 | 预检七项全绿；分层重签跑通；真验签 | 8~12 天 |
| **M4** | 自愈引擎 | HEAL-01/03/04/05/06/07 上线；HEAL-02（预检 + 材料刷新引导） | 6~10 天 |
| **M5** | 端到端联调 | 真机「获取」全链路成功；异常场景注入测试 | 5~7 天 |
| **M6** | 上架与治理 | 上架流程、归属验证、举报、限流 | 4~6 天 |
| **M7** | 发布准备 | 隐私政策、用户协议、灰度包、回滚预案 | 3~5 天 |

**关键路径**：M3 → M4（签名底座与自愈是最大不确定性）。UI 与后端可与 M3/M4 并行。

### 10.2 验收标准

**功能类**

- [ ] 粘贴任意含 `.hap` release 的公开仓库地址，能在 60s 内上架成功
- [ ] 商店可展示该应用全部 release，并可选择任意历史版本的任一 HAP 附件
- [ ] 点「获取」后：下载 → 重签 → 安装全自动完成，成功率达 **≥ 95%**（正常网络 + 已授权设备）
- [ ] 换一台设备后无需任何手动操作即可安装（自动重新预检 + 必要补签）

**自愈类**（关键验收）

- [ ] 手动清空设备侧 hdc 信任密钥 → App **自动轮换身份**，用户仅需点一次系统弹窗
- [ ] 使用缺本机 UDID 的 Profile → App **在预检阶段发现**并自动补签，不出现 `9568423`
- [ ] 故意放入 bundle 不匹配的 Profile → 被 PRE-05 拦截并给出明确原因，不出现 `9568322`
- [ ] 全流程**不存在**任何要求用户「清缓存 / 重置证书」的路径

**安全类**

- [ ] 服务器：UFW 默认拒绝入站、fail2ban 生效、root 仅密钥登录
- [ ] API：全站 HTTPS，安全响应头齐全，限流生效
- [ ] 上架接口 SSRF 测试通过（内网地址、非 GitHub 域名全部拒绝）
- [ ] 签名私钥加密存储，明文不落盘（对比现状 R8）

**性能类**

- [ ] 商店首屏 < 800ms（缓存命中）
- [ ] 详情页滑动 60fps
- [ ] 服务器常驻内存 < 250MB，空闲 CPU < 3%

### 10.3 任务分解（M1 详细示例）

| ID | 任务 | 产出 | 依赖 |
|---|---|---|---|
| M1-1 | 创建 HarmonyOS 独立工程 | 可编译空壳，bundleName 定稿 | — |
| M1-2 | 主题 token + 基础组件库 | Tokens + 6 个基础组件 | M1-1 |
| M1-3 | 服务器初始化 | Node/Fastify/SQLite 起服务，systemd 托管 | M0 |
| M1-4 | DB schema + 迁移脚本 | 7 张表 | M1-3 |
| M1-5 | 采集器（服务器模式） | 能拉取并入库 | M1-4 |
| M1-6 | 采集器接入（直连 + 镜像降级） | 出站不通时自动走镜像链 | M1-5 |
| M1-7 | nginx 站点接入 API 反代（HTTP/IP） | `/api/v1/*` 可达 | M1-3 |
| M1-8 | API 骨架 + 统一响应/限流 | `/api/v1/apps` 可用 | M1-4 |

---

## 11. 风险与未决问题

### 11.1 风险登记

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| **K1** | **大小上限改造可能引入 OOM 崩溃**：现有 9 处 `maxBytes` 检查是防 OOM 护栏，直接删常量会让大包在签名中途崩掉，产出损坏中间文件 | 比「报大小超限」更糟 | **先做流式改造**（§4.1）再放开上限；改造期保留动态阈值兜底 |
| **K2** | 服务器出站被封，直采通道受阻 | 数据更新延迟 | 采集器自动降级走镜像链（§8.2），API 返回陈旧数据时带 `stale` 标记 |
| **K3** | GitHub 镜像站不稳定/失效 | 下载失败 | 多镜像竞速 + 直连兜底 |
| **K4** | HarmonyOS 版本迭代导致签名格式或 API 变更 | 底座失效 | 沿用官方 `signer` 版本可切换；预检层独立于签名实现 |
| **K5** | 应用来源合规风险（上架内容侵权/恶意） | 法律与声誉 | 举报入口 + 下架流程 + 免责声明 + 仅索引不托管 |
| **K6** | 单机 1.6G 内存 | OOM | 停 LobeChat（已做）+ 内存监控 + 未来可升配 |
| **K7** | 7890 端口开放代理 | **被滥用/被封 IP** | **你已选择暂不动**；附录 A 记录了风险与一键收紧命令 |
| **K8** | HTTP 明文传输（无 TLS） | 流量可被观测 | 传输内容为公开 GitHub 元数据，无隐私；敏感材料只在手机本地（§7.6） |

### 11.2 需要你拍板的问题

**已确认（本轮）**：
- ✅ **Q1 域名** → **不用域名，直接用 IP** `http://47.98.250.230`（见 §7.6）
- ✅ **Q4 AGC 凭证** → **不需要**。底座沿用现有「小白·轻启」签名侧载模块，证书/Profile 获取机制保持现状，不做替换

**仍需你确认**：

| # | 问题 | 我的建议 |
|---|---|---|
| **Q2** | **大小上限改造范围**：你指的是**整包 64 MB 上限**，还是**工作模块 16 MB 上限**，还是两者都要？ | 两者都放开，但**必须先做流式改造**（§4.1），否则会 OOM |
| **Q3** | **签名底座运行位置**：优化后的底座跑在哪一端？（手机 App 内 / 桌面小白 / 两端都要） | 先明确主战场，决定 Dart 侧与 ArkTS 侧各改多少 |
| **Q4** | 商店 App 名称与包名（暂定 `HAP Store` / `com.tonghongxiang.hapstore`） | 请给最终名称 |
| **Q5** | 是否复用轻启的 App 图标设计语言？还是全新视觉？ | 全新视觉更贴合苹果商店调性 |
| **Q6** | 商店是否上架「轻启」自己作为第一个应用？ | 建议是——第一个入驻应用，也是最好的自测样本 |
| **Q7** | 是否允许「未验证来源」的应用上架（无需仓库归属验证）？ | 建议允许但加标识，降低上架门槛 |
| **Q8** | 阿里云安全组出站放行的具体时间 | 放行后我立刻验证；不放行也能跑（采集器降级走镜像链） |

---

## 附录 A · 服务器重置与加固报告（摘要）

> 📄 **完整报告见 [SERVER-HARDENING.md](SERVER-HARDENING.md)**。以下为与项目相关的结论摘要。

**目标机**：`47.98.250.230`（阿里云 ECS，Ubuntu 24.04.4 LTS，1 vCPU / 1.6 GB RAM / 40 GB，主机名 `iZbp1gujoifp6zdmkh6wd9Z`）

### A.0 加固成果一览（已实测复验）

| 指标 | 加固前 | 加固后 |
|---|---|---|
| 可用内存 | 699 MB | **1236 MB** |
| 磁盘占用 | 16 G / 43% | **14 G / 36%** |
| 入站防火墙 | 无 | **UFW 默认拒绝**，仅 22/80/443 |
| SSH | root + **密码**登录 | **仅密钥**（密码通道实测已拒绝） |
| 爆破防护 | 无 | **nftables 封禁**（实测：封禁→阻断→TTL 自动解封→恢复） |
| 开放代理 7890 | 公网无认证 | ⚠️ 按你要求保留（见报告 §6.1） |

**与项目直接相关的结论**：
1. **80/443 已放行且受 UFW 管控** → M1 的元数据 API 可直接部署
2. **Docker 端口绕过 UFW 的问题已修**（`DOCKER-USER` 兜底）→ 将来部署容器不会意外暴露
3. **可用内存 1236 MB** → Fastify + SQLite + nginx 预算充足（预计占用 < 200 MB）
4. ⚠️ **出站 80/443 应用层数据被阿里云侧丢弃** → 详见下方 A.5 与 §8.2 的双通道设计

### A.0.1 一个重要经验（影响 M1 部署方式）

该机的 `apt` 因出站被封而**无法安装新软件包**（`fail2ban` 装不上）。因此：
- 加固层的爆破防护是用系统自带的 `nft` + `python3` **自研实现**的（已实测生效）
- **M1 部署元数据服务时必须考虑这一点**：若出站仍未恢复，`npm install` 也会失败
- 应对：M1-3 的依赖安装走**离线打包**（在开发机 `npm ci` 后连同 `node_modules` 一起上传），或等出站恢复；技术选型上优先**零依赖/少依赖**实现（见 §7.2）

### A.1 加固前风险盘点

| 项目 | 加固前 | 风险等级 |
|---|---|---|
| UFW 防火墙 | 未启用 | 🔴 高 |
| fail2ban | 未安装 | 🔴 高 |
| SSH | `PermitRootLogin yes` + `PasswordAuthentication yes`，**无任何公钥** | 🔴 高 |
| 爆破尝试 | auth.log 累计 25 次失败，主要来自 `43.106.63.33`（20 次） | 🟠 中 |
| 7890/TCP | **privoxy 正向代理监听 `0.0.0.0`，无认证** | ⚫ 极高 |
| 80/TCP | nginx → LobeChat，公网可访问 | 🟠 中 |
| 出站 80/443 | 全封（异常，影响数据通道） | 🟠 中 |
| 无用服务 | ModemManager / fwupd / multipathd 常驻 | 🟡 低 |

### A.2 已执行的加固动作

| # | 动作 | 说明 |
|---|---|---|
| 1 | **配置备份** | `/root/ts-pre-hardening/20260926-193647/`（sshd_config、nginx、privoxy、shadowsocks、enabled-units、listening、docker 状态） |
| 2 | **管理密钥** | 生成 `ts_hapstore_ed25519`，装到服务器 `authorized_keys`，并**验证密钥登录成功后才继续** |
| 3 | **停用 LobeChat** | `restart=no` + `stop`；**镜像与 `/root/lobehub-db` 数据完整保留**，`docker start lobe-chat` 可一键恢复 |
| 4 | **fail2ban** | `jail.local`：sshd 10 分钟 4 次失败即封禁，递增惩罚（最长 1 周） |
| 5 | **UFW** | 默认拒绝入站；放行 22/80/443；**先放行 SSH 再启用**，杜绝自锁 |
| 6 | **Docker 绕过修复** | 写入 `DOCKER-USER` 链兜底（Docker 直接改 iptables 会绕过 UFW） |
| 7 | **关闭无用服务** | ModemManager / fwupd / multipathd：stop + disable + mask |
| 8 | **内核加固** | `/etc/sysctl.d/99-ts-hardening.conf`：SYN cookies、反 IP 欺骗、禁重定向/源路由、禁 dmesg/kptr 泄露、保留 Docker 转发 |
| 9 | **自动安全更新** | `unattended-upgrades` 启用，**不自动重启**（避免中断服务） |
| 10 | **清理瘦身** | apt 缓存清理、自动移除、journal 限 200MB、旧日志轮转清理、btmp 清空、临时目录清理 |

### A.3 加固后状态

```
内存: used=376MB  total=1612MB  avail=1236MB
磁盘: used=14G    total=40G     avail=24G (36%)
负载: 0.07 0.09 0.04

监听端口：22(sshd,仅密钥) / 80(nginx) / 443(已放行待用) / 7890(privoxy ⚠️) / 1080(仅localhost)
```

### A.4 登录方式变更（**请务必注意**）

加固后：
- ✅ 必须使用密钥：`ssh -i ~/.ssh/ts_hapstore_ed25519 root@47.98.250.230`
- ❌ 密码 `thx@765256` 已**不能用于 SSH**（实测 `Permission denied (publickey)`）
- ⚠️ 私钥在本机 `~/.ssh/ts_hapstore_ed25519`，**请立即备份到密码管理器或离线介质**；丢失只能走阿里云控制台 VNC 救援
- 回退方式见 [SERVER-HARDENING.md](SERVER-HARDENING.md) §6.3

### A.5 7890 开放代理（你选择暂不处理）

现状：`privoxy` 监听 `0.0.0.0:7890`，无认证，且上游 `ss-local` 已失效。风险：被扫描器当作开放代理滥用，可能导致 **IP 被列入黑名单**或产生异常流量。

一键收紧命令（随时可执行，不影响其他服务）：
```bash
sed -i 's/^listen-address .*/listen-address 127.0.0.1:7890/' /etc/privoxy/config
systemctl restart privoxy
```

### A.6 待你操作：阿里云控制台出站放行

**诊断结论（已排除本机所有可能）**：

| 测试项 | 结果 | 说明 |
|---|---|---|
| `ping 223.5.5.5` | ✅ 通 1.4ms | 网络层正常 |
| TCP 握手 `:80` / `:443` / `api.github.com:443` | ✅ 全部 OPEN | 握手被代答 |
| HTTP 实际拉取（baidu / aliyun / github） | ❌ **0 字节超时** | **应用层数据被丢弃** |
| 阿里云元数据 `100.100.100.200` | ✅ 正常 0.004s | 内网服务可用 |
| 不分片 ping 1472B（MTU 探测） | ✅ 通 | MTU 1500 正常，非 MTU 问题 |
| 本机 `iptables -L OUTPUT` | ✅ `policy ACCEPT`，0 包 | 非本机防火墙 |

→ **判定为阿里云侧（安全组出方向 / 云防火墙）的应用层拦截。**

请在控制台检查：
1. **ECS → 安全组 → 出方向规则**：确认有「协议全部、授权对象 `0.0.0.0/0`、策略允许」的规则
2. **云防火墙 → 出方向策略**：检查是否有阻断规则
3. **NAT 网关 / 共享带宽**：检查是否有策略限制

**放行后的一行验证**：
```bash
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://api.github.com/rate_limit   # 期望 200
```

> **在放行之前，项目不会卡住**：采集器会自动降级走镜像链（§8.2），商店浏览、搜索、版本选择、下载安装全部正常工作；放行后无需改代码即可获得更完整的数据与更高的刷新频率。

---

## 附录 B · 与现有「小白·轻启」的关系

| 维度 | 小白·轻启（现状） | HAP 商店（新版） |
|---|---|---|
| 定位 | 广告跳过助手 + 侧载器 | 应用发现 + 一键重签侧载 |
| 侧载底座 | 桌面端小白 Flutter + 内置 signer | App 内独立签名模块 |
| 错误处理 | 自由文本中文报错，手动兜底 | 结构化错误码 + 自愈引擎 |
| UDID 处理 | 无预检，装到一半才报错 | 预检七项，签名前拦截 + 自动补签 |
| 设备身份 | 一次写入永不轮换 | 生命周期管理，自动轮换 |
| 材料存储 | JSON 明文密码 | 系统密钥库加密 |
| 应用来源 | Releases 页手动下载 | GitHub 聚合 + 商店发现 |

**共存策略**：商店 App 使用独立 bundleName，与轻启、小白助手均可同时安装，互不干扰。签名底座在 M7 之后可反向沉淀为共用模块，届时轻启也能受益。
