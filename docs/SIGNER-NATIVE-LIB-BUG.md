# 排查：签名器对小型原生库崩溃

> 状态：**已定位、已修复、已真机验证** · 12 个新测试

---

## 一、结论

`libsigner.so`（第三方 Go 版 hapsigner）在遇到**小于约 169 KB 的原生库**时
nil 解引用崩溃：

```
panic: runtime error: invalid memory address or nil pointer dereference
  codesigning/elf.(*ELFFile).IsELFFile            ElfFile.go:136
  codesigning/sign.(*PageInfoGenerator).libExecSegment  PageInfoGenerator.go:88
  codesigning/sign.NewPageInfoGenerator           PageInfoGenerator.go:68
  hap/provider.(*BaseSignProvider).copyFileAndAlignment SignProvider.go:443
```

**这不是内存或包大小问题** —— 一个 5 KB 的空壳库就能触发。

修复方式：签名前把过小的原生库**尾部补 NUL**到 192 KB。
已在设备上验证：签名成功、安装成功、应用正常启动、被填充的库正常加载。

---

## 二、定位过程（含两次错误结论）

排查过程中我下过两个**错误结论**，记录在这里以免后人重走：

### 错误结论 1：「总量超 30 MB 触发」

早期用 `grep -qiE "panic" && echo "❌" || echo "✅"` 判断结果，而 panic 打在
stderr 上被 `tail -2` 截掉了，导致把「崩溃」误判成「成功」。用
**退出码 + 产物是否存在**双判据重测后，规律才显现。

### 错误结论 2：「是文件个数问题」

5 个库（1.6 MB）崩、3 个库（23.6 MB）成功，看起来像个数问题。
但隔离到单库后发现真正原因是**尺寸**：

| 库 | 大小 | 结果 |
|---|---|---|
| `libnative_core.so` | 5 KB | ❌ 崩溃 |
| `libgo_signer.so` | 112 KB | ❌ 崩溃 |
| `libunhap.so` | 158 KB | ❌ 崩溃 |
| `libflutter_accessibility.so` | 171 KB | ✅ 成功 |
| `libc++_shared.so` | 1.2 MB | ✅ 成功 |
| `libflutter.so` | 11 MB | ✅ 成功 |

之前的「个数规律」只是因为小库恰好集中在那几组测试里。

### 精确边界

把 `libunhap.so` 尾部填充到不同大小：

```
157 KB → ❌    164 KB → ❌    168 KB → ❌
170 KB → ✅    172 KB → ✅    176 KB → ✅
```

**临界在 168/170 KB 之间**。代码取值 192 KB 留出余量。

---

## 三、修复

### 3.1 实现

新增 `core/logic/lib/src/native_lib_pad.dart`：

```dart
const int minNativeLibSize = 192 * 1024;

bool isNativeLibEntry(String name) => name.endsWith('.so') && name.contains('libs/');

int paddingFor(String name, int size) { ... }        // 需要补多少
Uint8List padIfNeeded(String name, Uint8List data)   // 补 NUL 到下限
Future<Map<String,int>> findUndersizedNativeLibs(File hap)  // 诊断用
```

接入两条签名路径（`signPlain` 与 `signHap`）：把补齐后的字节作为
**replacements** 交给已有的 `streamRepack` —— 复用成熟的重打包机制，
不需要新的打包代码。

### 3.2 为什么补 NUL 是安全的

- ELF 加载器只依据程序头（program header）里的 `p_offset`/`p_filesz`
  映射段，尾部多余字节**不会被加载**，也不参与符号解析
- 包内所有字节都被签名覆盖，签名与内容始终一致
- 已在设备上确认：被填充的 `libgo_signer.so` 成功加载
  （日志 `Tail:default/go_signer` 走到加载流程）

### 3.3 为什么不用官方 Java 签名器

官方 `hap-sign-tool.jar` **没有这个缺陷**（实测签同一份包一次通过）。
但手机上要跑它需要 JVM（`libjavacmd.so`），而原「小白」工程
**从未真正提供该库** —— 全工程只有头文件，没有 `.so`。
那条路在设备上不可用，所以选择修补包格式而不是引入 Java 运行时。

---

## 四、连带修掉的一个校验器漏洞

修复过程中，签名流程报出：

```
签名失败：签名器意外改变了程序内容，已停止安装
```

排查后发现问题**不在填充**，而在校验器本身：

```
名称不符: orig=23 actual=24
  多=[.pages.info]
```

**签名器会自行添加 `.pages.info`（页面信息索引）**，这是正常产物 ——
实测任何 HAP 签名后条目数 +1，且此前**安装成功**的包同样包含它。

`checkPayloadUnchanged` 原来要求条目集合完全一致，于是把签名器的正常行为
当成篡改拦下。**这是预先存在的漏洞**，只是此前被「bundle 不匹配」的
预检错误掩盖（那道检查先一步拦下了签名）。

修法：只放行**已知**的签名器新增条目，其余增删仍按篡改处理。

```dart
bool isSignerAddedEntry(String name) => name == '.pages.info';

final added = actualNames.difference(expectedNames);
final removed = expectedNames.difference(oldNames);
final unexpectedAdd = added.where((n) => !isSignerAddedEntry(n)).toList();
if (removed.isNotEmpty || unexpectedAdd.isNotEmpty) { throw ... }
```

> 注意这里**没有**放宽成「允许多出条目」—— 只放行白名单里的那一个名字。
> 换签名器时需要重新评估这个白名单。

---

## 五、真机验证结果

```
输入: 31.5 MB HAP（9 个原生库，其中 4 个低于下限）
  libnative_core.so    5432 B → 196608 B  ← 已填充
  libgo_signer.so    111736 B → 196608 B  ← 已填充
  libunhap.so        160264 B → 196608 B  ← 已填充
  libflutter_accessibility.so 173872 B → 196608 B  ← 已填充

签名:    ✅ 成功（Go 签名器，未崩溃）
本地校验: ✅ 通过
安装:    ✅ install bundle successfully
启动:    ✅ 应用正常运行，无崩溃
原生库:  ✅ 被填充的库成功加载
```

---

## 六、测试

`core/logic/test/native_lib_pad_test.dart` —— **12 个测试**：

| 分组 | 覆盖 |
|---|---|
| 尺寸判定 | 5 KB / 160 KB 需补；达标不动；只有 `libs/` 下的 `.so` 参与 |
| 填充行为 | 补齐到下限且**原字节逐字节保留**；不需要时不复制；非原生库不补 |
| 签名器新增条目 | `.pages.info` 放行；其它任何多出的条目都不放行 |
| HAP 扫描 | 正确找出全部过小库；全部达标返回空；真实商店包 4 个库全识别 |

「原字节逐字节保留」这条最关键 —— 它保证填充不会破坏 ELF。

---

## 七、给后续维护者的提醒

1. **换签名器时重新评估**：若换成官方 Java 签名器（无此缺陷），
   填充逻辑可以去掉；但 `.pages.info` 的白名单仍需按新签名器的行为校准。
2. **不要用 `grep` 判断崩溃**：panic 走 stderr，容易被管道截断。
   用退出码 + 产物存在性双判据。
3. 这个缺陷影响**所有带小原生库的应用**（`libnative_core.so` 只有 5 KB，
   很常见）。若将来遇到「某些应用装不上、签名器崩溃」，先查原生库尺寸。
