# 签名身份：自动化与一个必须修正的安全问题

> 状态：已实现，`flutter analyze` 零问题，58 个测试全通

---

## 一、为什么之前还要手动导入？—— 那是个设计缺陷

你问得对：**手动导入不是技术必需，是我照搬了「小白」的旧做法。**

### 1.1 「小白」是怎么做的

它在 `EcoViewModel.dart:566-568` 把签名材料作为**随包资源**拷贝出来：

```dart
await copyAssert("store", "xiaobai.csr", storeDir);
await copyAssert("store", "xiaobai.p12", storeDir);
await copyAssert("store", "key.pem", storeDir);
```

而 `pubspec.yaml` 明确把它们打进包：

```yaml
flutter:
  assets:
    - assets/store/key.pem
    - assets/store/xiaobai.csr
```

**实测确认**（用本机已构建的 HAP 验证）：

```
entry-default-unsigned.hap:
  resources/rawfile/flutter_assets/assets/store/key.pem   292 B
  resources/rawfile/flutter_assets/assets/store/xiaobai.csr 497 B
```

且工程内 `assets/store/key.pem` 与用户目录下的私钥
**SHA-256 前 16 位完全相同**（`615e57b759b49848`）—— 说明它是同一份固定文件。

### 1.2 这为什么是严重安全问题

| 问题 | 后果 |
|---|---|
| **私钥随 HAP 公开分发** | 任何人反编译 HAP 即可取得该私钥 |
| **所有用户共用同一把私钥** | 用户用它从 AGC 换到的证书，其对应私钥是**公开的** |
| 因此 | 任何人都能用该私钥签出「属于该用户证书」的包 |

也就是说：**签名链的信任基础被破坏了。** 设备看到的是用户的证书，
但签名用的私钥全世界都有。

（唯一还起保护作用的是 Profile 里的 UDID 绑定 —— 但那是另一层，
不该用来兜底一个已经泄露的私钥。）

### 1.3 正确做法（已实现）

**每台设备生成唯一的密钥对。** 商店现在这样做：

```
首次登录
  → 原生签名器 signtool generate-keypair  生成唯一密钥对（PKCS12）
  → 原生签名器 signtool generate-csr      用该密钥对生成 CSR
  → CSR 提交 AGC → 换回绑定本机的调试证书
  → 申请设备授权 Profile（含本机 UDID）
```

**全程不需要 OpenSSL**（手机上也没有），也不需要用户准备任何文件。

关键点：`generate-keypair` 与 `generate-csr` 都是**内置原生签名器**的子命令，
实测在本机可用：

```bash
$ signer generate-keypair -keyAlias testkey -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile /tmp/test-gen.p12 -keystorePwd testpwd
generate-keypair success

$ signer generate-csr -keyAlias testkey -keyPwd testpwd \
    -subject "C=CN,O=HapStore,OU=Dev,CN=test" -signAlg SHA256withECDSA \
    -keystoreFile /tmp/test-gen.p12 -keystorePwd testpwd -outFile /tmp/test-gen.csr
generate-csr success
```

私钥保存在**应用沙箱**内（`identity.p12`），其他应用无法读取，
也不上传、不进服务端。

---

## 二、现在的流程（对比）

| 环节 | 之前 | 现在 |
|---|---|---|
| 密钥对 | 随包分发的固定私钥 ❌ | **本机唯一生成** ✅ |
| CSR | 随包分发的固定文件 | 由本机私钥生成 |
| 证书 | 手动导入 | **自动向 AGC 申请** |
| Profile | 手动导入 | **自动申请（含本机 UDID）** |
| 换设备 | 手动重置证书 | **自动重建授权** |
| 用户操作 | 准备并导入 3 个文件 | **点一次「一键登录并准备」** |

界面上保留了「我已有一份签名材料，手动导入」作为**备选路径** ——
迁移过来的老用户或想复用既有材料的场景仍可用。

---

## 三、实现要点

### 3.1 密钥库格式的差异

自动生成的密钥对是 **PKCS12**（签名器要求 P12/JKS，不接受裸 PEM）。
而用户手动导入的可能是未加密 PEM。

因此签名调用按情况传口令：

```dart
final pwd = cfg.keystorePwd.isNotEmpty
    ? cfg.keystorePwd                  // 自动生成 → 真实口令
    : 'unused-for-unencrypted-pem';    // 手动导入的 PEM → 占位口令
```

### 3.2 CSR 路径的推导

`AgcProfileProvider` 只在「需要新建证书」时才用 CSR。
路径优先取配置里记录的（自动生成流程会写），否则按密钥库同名推导：

```dart
final csrPath = _config.csrPath.isNotEmpty
    ? _config.csrPath
    : p.setExtension(_config.keystoreFile, '.csr');
```

### 3.3 密钥对重建时 CSR 必须跟着重建

两者是配对的。若只重建密钥对而沿用旧 CSR，AGC 会签出一张与**当前私钥不匹配**
的证书 —— 那种包签出来装不上（9568322）。代码里已处理：

```dart
if (!keyOk) {
  ...generateKeyPair...;
  if (await csrFile.exists()) await csrFile.delete();  // 强制重建 CSR
}
```

---

## 四、仍需真机验证的部分

| 项 | 状态 |
|---|---|
| `generate-keypair` / `generate-csr` 可在本机运行 | ✅ 实测通过 |
| 上述命令在**手机内**（`libsigner.so`）可用 | ⏳ **待验证** |
| 登录 → 自动生成身份 → 自动申请授权 全链路 | ⏳ **待验证**（需你的华为账号） |

> ⚠️ **一个已知风险**：桌面版 `signer` 在签名含大量原生库（`.so`）的 HAP 时
> 会 **Go panic**（ELF 解析崩溃，实测）。
> 手机内的 `libsigner.so` 是否也有同样问题**尚未验证** ——
> 若有，则「用商店安装含原生库的应用」会失败。
> 验证方式：在商店里装一个带 `.so` 的应用（例如轻启自己）。
>
> 附带影响：构建机上给商店签名也必须改用官方 `hap-sign-tool.jar`，
> 详见 [APP-BUILD.md](APP-BUILD.md) §三。

---

## 五、给后续维护者的提醒

1. **不要把任何私钥放进 `assets/`。** 那等于公开发布。
2. 若接入新的签名工具，先确认它用的是**本机生成**的密钥，而不是内置密钥。
3. 迁移老用户时：他们手里那份「小白」材料对应的私钥是**已泄露的**，
   建议引导重新生成（登录一次即可），而不是继续沿用。
