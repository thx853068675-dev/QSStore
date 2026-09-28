# 排查：登录后没有回执

> 状态：**根因已定位并修复，实测登录成功** · 待继续验证后续步骤

---

## 一、现象

第①步点「登录」→ 浏览器打开 → 完成华为账号登录 → **星仓毫无反应**。

真机日志（修复前的完整记录）：

```
[login] 已监听端口 8888
[login] 已监听端口 3633
[login] 将向授权页声明回调端口 8888
[login] 已打开授权页
（此后无任何「收到请求」）
```

**端口绑定成功、授权页已打开，但回调从未到达。**

---

## 二、回调机制（逆向授权页 JS 得到的事实）

抓取授权页（`/console/DevEcoIDE/apply`）后确认它是个 Vite SPA，
真正的逻辑在懒加载分块 `consent-3bf99b06.js`（即路由里的 `ideApply`）里：

```js
// 1) 从 URL 读参数
for (...) {
  if ("port"  === t[0]) S.value = t[1];
  if ("appid" === t[0]) P.value = t[1];
  if ("code"  === t[0]) X.value = t[1];
}

// 2) 用户点「允许」后，用浏览器导航把 tempToken 送回本机
let e = "http://localhost:" + S.value + "/callback?tempToken=" + G.value
        + "&siteId=" + _.value;
window.location.href = e;
```

另外还有两条分支：

```js
// 用户点「取消」
let e = "http://localhost:" + S.value + "/callback?quit=quit";

// 未点允许而端口未就绪时
else i.error(J("portError"))
```

**关键事实**：

| 事实 | 含义 |
|---|---|
| 回调是 `window.location.href` 导航 | 由**浏览器**发出，不是华为服务端 |
| 路径固定 `/callback` | 我实现的路径正确 |
| 参数名固定 `tempToken` | 我解析的参数名正确 |
| 端口来自 URL 的 `port` 参数 | 我们传什么它就用什么 |
| 只在点「允许」时触发 | **不点「允许」就没有回调** |
| 取消时带 `quit=quit` | 用来区分「用户取消」与「超时」 |

页面文案也印证了流程：

> 您已成功登录 HUAWEI DevEco Studio 客户端，请返回 DevEco Studio 进行下一步操作。

---

## 三、定位到的两个真实缺陷

### 缺陷 1：缺少 CORS 预检响应（本次现象的直接原因）

浏览器从 **HTTPS** 页面导航到 **http://localhost** 时，受
Private Network Access（私有网络访问）约束，可能先发一个
`OPTIONS` 预检请求。

我原来只处理 `/callback`，其余一律回 404 —— 预检拿不到
`Access-Control-Allow-Private-Network: true`，真正的回调就被浏览器拦下，
表现为**应用侧完全收不到任何请求**（正是日志中的样子）。

修法：

```dart
if (request.method == 'OPTIONS') {
  h.set('Access-Control-Allow-Origin', '*');
  h.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  h.set('Access-Control-Allow-Headers', '*');
  h.set('Access-Control-Allow-Private-Network', 'true');
  return;   // 204
}
```

顺带把回执页做成即时返回，减少浏览器等待。

### 缺陷 2：`path_provider` 在鸿蒙上没有实现

`GeneratedPluginRegistrant.ets` 里**只注册了 `ohos_adapter`**：

```ts
flutterEngine.getPlugins()?.add(new OhosAdapterPlugin());
```

所以 `getApplicationSupportDirectory()` 必然抛异常。我原来的写法回退到
`Directory.systemTemp`，导致：

- 生成的密钥、CSR、配置写进**临时目录**（重启即清）
- 表现为「登录成功了，但什么都没发生」

修法：优先用 adapter 的 `appDir()`（鸿蒙上是 `context.filesDir`，
沙箱内且持久），`path_provider` 仅作非鸿蒙环境的兜底：

```dart
Future<String> appDataDir() async {
  final d = await ohosAdapter.appDir();      // <sandbox>/haps/entry/files
  if (d != null && d.isNotEmpty) return d;
  ...
}
```

同时加了**旧路径迁移**：从 `appDir()` 推导同级 `cache/`、`temp/`，
把早期落在那里的 `agc_auth.json` 搬到新位置，免得用户重新登录。

### 顺带修的两处

| 项 | 原来 | 现在 |
|---|---|---|
| 多端口监听 | 只监听随机端口 | **同时监听 8888 与随机端口**，无论授权页打到哪个都能收到 |
| 取消识别 | `quit=quit` 被当失败 | 识别为「用户取消」，文案更准确 |

另外**整条登录/准备流程以前完全没有日志**（`print` 在鸿蒙上不保证进
hilog），排查时无从下手。现在统一走新增的 `ohosAdapter.log()`，
原生侧写 hilog、标签 `StarHub`：

```bash
hdc shell hilog -x | grep StarHub
```

---

## 四、修复后的实测结果

```
[login] 已监听端口 8888
[login] 已监听端口 3633
[login] 将向授权页声明回调端口 8888
[login] 已打开授权页
[login] 收到请求 POST /callback（来自 127.0.0.1）      ← 回调到达
[login] 回调内容长度 1081
[login] 登录结束：LoginOutcome.success                  ← 登录成功
```

登录态已正确持久化到 `filesDir/agc_auth.json`：

```
nickName    = 童大****
userId      = 2850086000439684142
teamId      = 2850086000439684142
accessToken 长度 = 136
jwtToken 长度    = 1567
```

---

## 五、还做了一处体验改进

原逻辑点「登录」一律先开浏览器。但用户可能只是想做后面的步骤，
这时不该重复走一遍授权。现在会**先校验已有登录态**，有效就直接
跳过浏览器继续生成身份：

```dart
if (materials.isSignedIn) {
  final stillValid = await materials.ensureAgc().checkSignedIn();
  if (stillValid) { await _afterLogin(); return; }
}
```

---

## 六、待继续验证

登录已通，但**后续三步尚未跑完**（此前被缺陷 2 挡住）：

| 步骤 | 状态 |
|---|---|
| ①-a 登录华为账号 | ✅ 实测成功 |
| ①-b 生成唯一密钥对（`signtool generate-keypair`） | ⏳ 待验证 |
| ①-c 申请调试证书 | ⏳ 待验证 |
| ①-d 申请设备授权 Profile | ⏳ 待验证 |
| ② 无线调试连接 | ⏳ 待验证 |
| ③ 从商店一键安装 | ⏳ 待验证 |

排查方式：

```bash
hdc shell hilog -x | grep StarHub
# 会看到 [setup] 身份生成：… / 证书申请：… / 设备授权申请：…
```


---

## 七、续查：密钥生成失败的真实原因（第二个缺陷）

登录通了之后，第①步卡在「无法生成密钥对（内置签名器不可用）」。

### 7.1 排查过程

给原生命令加上「原始返回」日志后看到：

```
[signer] generate-keypair ok=false out=签名成功
```

`out=签名成功` 是原生包装层 `GoSign` 的**硬编码返回**：

```ts
go_sign(cmd.replace("signtool", ""), async (out) => {
  if (out.indexOf("success") > -1) res("签名成功")   // 空输出也命中
  else res(out)                                      // 走这个分支才返回真实输出
})
```

`"".indexOf("success") === -1` 其实不成立，但**签名器的真实输出里确实没有
"success" 之外的线索**，于是 UI 只看到「成功」而目录里没有任何文件。

进一步在应用内枚举目录，确认路径本身有效：

```
[signer] keypair ok=false found=""
[signer]   dir=.../files 内容=[agc_auth.json(1821B)]     ← Dart 写进去了
[signer]   systemTemp=.../cache/ 内容=[...]
[signer]   rawOut="签名成功"
```

同目录里 Dart 能写文件，说明**不是权限或路径问题**。

### 7.2 桌面复现：同一份代码同样有问题

在 Mac 上跑同一个签名器：

```bash
$ signer generate-keypair -keyAlias t1 -keyAlg ECC -keySize NIST-P-256     -keystoreFile /tmp/a.jks -keystorePwd pw
退出码: 0
stdout: （空）
stderr: Start generate-keypair
stderr: generate-keypair success      ← 报告成功
$ ls /tmp/a.jks
ls: /tmp/a.jks: No such file or directory   ← 但文件不存在
```

**桌面版与手机版是同一份代码、行为完全一致。** `generate-csr` 同样如此。

> 顺带说明：原「小白」从不使用这两个子命令（它把 `key.pem` 与 `xiaobai.csr`
> 作为**随包资源**分发，见 [SIGNING-IDENTITY.md](SIGNING-IDENTITY.md)），
> 所以这个缺陷在它那里从未暴露。

对照：官方 `hap-sign-tool.jar` 的同一命令**工作正常**（实测生成 500 字节
keystore + 428 字节 CSR）。但手机上跑 Java 需要 JVM（`libjavacmd.so`），
而该库在原工程里**从未被提供**（全工程只有头文件）。设备上无 Java 可用。

### 7.3 解法：改为纯 Dart 生成（`identity_generator.dart`）

`pointycastle` 是纯 Dart 实现，自带 ASN.1 / PKCS#10 / X.501 / ECC / ECDSA /
SecureRandom，**不依赖任何原生库**。用它生成密钥与 CSR：

| 好处 | 说明 |
|---|---|
| **每台设备唯一** | 修掉了「所有用户共用一把私钥」的安全问题 |
| 私钥不出设备 | 只在本机内存与沙箱内产生 |
| 不依赖缺陷命令 | 也不依赖 OpenSSL |
| 离线可用 | 已缓存在 pub-cache，无需联网 |

私钥写成**未加密的 PKCS#8 PEM**，与原「小白」的 `key.pem` 同格式，
签名器按 PEM 解析、忽略口令。

### 7.4 排查中修掉的三处密码学细节

这三处都是 **OpenSSL 交叉验证**发现的 —— 只靠 pointycastle 自验会漏掉：

| 现象 | 原因 | 修法 |
|---|---|---|
| `explicit tag not constructed` in `EC_PRIVATEKEY.publicKey` | SEC1 的 `[1]` 是**显式**标签，内容是一整个 BIT STRING 编码 | 用 `ASN1Object(tag: 0xA1)` 包 BIT STRING |
| OpenSSL `Type=ECDSA_SIG` 解析失败 | 签名未归一化，`s` 可能是 high-s | `sig.normalize(curve)` 转 low-s |
| 自签名验证不过 | 签名器用 `ECDSASigner(null, ...)`（对原始字节签名），而 CSR 要求对 **SHA-256 摘要**签名 | 改用 `ECDSASigner(SHA256Digest(), ...)` |

**为什么必须用外部工具交叉验证**：上面每一条，pointycastle 自己的验证器
都会「通过」，只有 OpenSSL 会拒绝。

最终验证：

```
$ openssl req -in req.csr -noout -verify
verify OK                                    ← CSR 自签名有效

$ openssl x509 -req -in req.csr -signkey key.pem -out cert.pem
# 证书公钥 sha == 私钥公钥 sha  →  配对正确
```

### 7.5 设备实测（成功）

```
[setup] 复用已有登录态，跳过浏览器
[material] 纯 Dart 生成身份 → .../temp/identity.pem
[material] 身份生成成功：私钥 241 字符，CSR 424 字符
[setup] 身份生成：成功
[setup] 证书申请：成功              ← 已能从 AGC 拿到真实证书
```

设备沙箱中确认产物：

```
identity.pem           241 B   本机唯一私钥
identity.csr           424 B   证书请求
identity.cer          2914 B   从 AGC 申请到的**真实调试证书**
sign_material.json     310 B   材料配置
```

### 7.6 又发现一处死锁（已修）

材料配置里 `profilePath` 为空，导致后续卡住：

```
"profilePath": ""
```

原因是一个循环依赖：

```
_attachProvider()  在 profilePath 为空时不创建 AGC Provider
        ↓
_requestProfile()  需要 Provider 才能申请 Profile
        ↓
Profile 拿到后才会写入 profilePath  ← 永远到不了
```

修法：在生成身份时就把 `profilePath` 设为默认位置
（`<data>/identity.p7b`），打破循环。

---

## 八、当前状态

| 步骤 | 状态 |
|---|---|
| ①-a 登录华为账号 | ✅ **实测成功** |
| ①-b 生成唯一密钥对 | ✅ **实测成功**（纯 Dart，设备上已产出 241 字节私钥） |
| ①-c 申请调试证书 | ✅ **实测成功**（已产出 2914 字节真实证书） |
| ①-d 申请设备授权 Profile | ⏳ 死锁已修，待复测 |
| ② 无线调试连接 | ⏳ 待验证 |
| ③ 从商店一键安装 | ⏳ 待验证 |
