# 华为登录与设备授权自动重建

> 状态：**已实现并通过 13 个单元测试** · 真机验证需华为账号（需你操作）

---

## 一、这一环解决什么

**「换个设备就要重置证书」的完整闭环。**

调试 Profile 里绑定了设备 UDID 列表。换设备后旧 Profile 不含新设备，
设备侧安装时报 `9568423 the device is unauthorized`，用户看不懂，
只能去「重置证书」。

原实现的根因（`EcoServices.dart:355`）：

```dart
if (!await File(config.profilePath).exists()) {   // ← 只看文件在不在
    ...调 AGC 创建含本机 UDID 的 Profile...
} else {
    print(" $profileName profile 存在");           // ← 存在就直接复用
}
```

它从不检查「这份 Profile 是否适用于**当前这台设备**」，所以换设备必然失败。

现在：

```
签名前预检
   ├─ 文件存在 ∧ bundle 匹配 ∧ 本机 UDID 在列 ∧ 未过期 ∧ ACL 覆盖
   │     → 直接复用
   └─ 任一不成立
         → 自动调 AGC 重建（登记设备 → 复用/新建证书 → 创建 Profile → 下载）
         → 复验新 Profile 确实含本机 UDID
         → 继续签名
```

**用户不需要做任何操作。**

---

## 二、新增模块（1,001 行）

```
app/lib/state/agc/
├── agc_models.dart          238 行  AuthInfo / EcoResult / CertInfo / DeviceInfo
│                                    + defaultAcl 白名单（照搬原实现，未增删）
├── agc_service.dart         322 行  AGC 云 API 客户端（端点契约保持不变）
├── huawei_login.dart        228 行  登录流程（本地回调服务 + 授权页）
└── agc_profile_provider.dart 213 行 接进 signing_core 的 ProfileProvider 契约
```

### 登录流程

```
1. 本机起临时 HTTP 服务，监听 127.0.0.1:<随机端口 3333~4332>
2. 系统浏览器打开 cn.devecostudio.huawei.com 授权页，回调指向该端口
3. 用户登录 → 华为带 tempToken 回调本机
4. tempToken → jwtToken → userInfo（accessToken / userId / teamId）
5. 关闭临时服务，回调页显示中文提示
```

**鉴权方式**：不依赖 AGC 的 client_id/secret，而是复用 **DevEco Studio 的登录态**。
之后所有 AGC 请求带三个头：`oauth2Token` / `teamId` / `uid`。

头像优先复用开发者登录态的 access token，调用华为开放资料接口 `GOpen.User.getInfo` 获取 `headPictureURL`；实机已成功显示。备用的 Account Kit `profile` 授权仍需要给应用配置 AGC Client ID。当前实机缺少该配置，备用路径返回 `1001502003`，但不影响优先路径显示头像。

与原实现的差异：

| 项 | 原实现 | 现在 |
|---|---|---|
| 超时 | 静默关服务，调用方无法区分 | 返回明确结果（成功/超时/取消/失败） |
| 主动取消 | 不支持 | 支持 |
| 回调页 | 一行纯文本 | 有样式的中文页面 |
| 监听范围 | loopback | loopback（不变，不对外开放端口） |

### 关于 CSR（一个容易误解的点）

重建 Profile **不需要**新建证书 —— Profile 绑定的是**已有的**证书 ID。

只有在完全没有调试证书时才需要 CSR，而 **CSR 与私钥配对，无法凭空生成**，
必须由生成签名材料时一并产出（小白就是这么做的）。

因此处理顺序是：

```
① 有 certId 且证书仍在列表 → 直接用
② 找同名调试证书           → 用它的（并补下证书文件）
③ 都没有                   → 才用 CSR 新建（CSR 缺失时给出可读错误）
```

AGC 对证书数量有限制，达上限时会自动清理最旧的一张（与原实现一致）。

### ACL 处理（对应错误码 9568289）

创建 Profile 时提交的是 **「包内 requestPermissions ∩ AGC 可授权白名单」**：

```dart
List<String> effectiveAcls(List<String> moduleRequestedPermissions) {
  final allowed = aclList.toSet();
  return moduleRequestedPermissions.where(allowed.contains).toList()..sort();
}
```

提交未知项会被 AGC 拒；**遗漏**某项则设备侧装不上（9568289）。
白名单照搬原实现，未作增删。

> ⚠️ **一个实测事实**：`ohos.permission.INTERNET` **不在**该白名单内。
> 这不是我们能决定的——普通权限本来就不需要 ACL 授权。

---

## 三、测试（13 个，全部通过）

真机验证需要华为账号，无法自动化。因此用一个假 `AgcService` 把**整条重建链路**
跑通 —— 测的是编排逻辑，不是网络层。

| 分组 | 覆盖 |
|---|---|
| **判据** | 文件不存在 / 缺本机 UDID / bundle 不匹配 / 已过期 → 触发重建；全部满足 → 不重建 |
| **完整链路** | ★ 缺 UDID → 登记设备 → 建 Profile → 下载 → **复验新 Profile 真的含本机 UDID** |
| | 设备已登记时不重复登记 |
| | ACL 取交集，白名单外的被过滤 |
| **证书** | 同名证书复用 / 无证书时用 CSR 新建 / CSR 读不到时给可读错误 / 达上限清理最旧 |
| **未登录** | 明确报错，且**不发起任何 AGC 调用** |

那个 ★ 测试是最关键的：它验证了「换设备」这个场景从头到尾能自动走通。

---

## 四、UI 接线

「我的」页新增「华为账号」分组：

```
┌─────────────────────────────────────────┐
│ 华为账号                                 │
│  [登录]  未登录                          │
│   登录后可自动为当前设备申请授权，         │
│   无需手动重置证书                        │
└─────────────────────────────────────────┘
```

登录后显示账号名与「退出」按钮。
登录态**会持久化**（`agc_auth.json`），下次启动自动恢复并校验有效性；
校验失败则清除，避免用户以为还登着。

### 接线路径

```
MinePage「登录」
  → main._login()
      → HuaweiLogin.login()          ← 本地回调 + 授权页
      → materials.saveAuth(authInfo) ← 持久化
      → materials._attachProvider()  ← 构造 AgcProfileProvider
  → 此后 signHap 的预检发现 Profile 不适用时会自动重建
```

---

## 五、真机验证步骤（需要你操作）

代码与测试都已就绪，但**登录需要你的华为账号**。

```bash
# 1. 构建
./tools/build-app.sh release

# 2. 签名（需要 hapstore 的 Profile —— 见 docs/APP-BUILD.md §六）
#    或用小白侧载一次生成
# 3. 安装
~/Library/Caches/hap_installer/hdc_tools/hdc -t <device> install <signed.hap>
```

然后在手机上：

1. 打开商店 → 「我的」→ 华为账号 → **登录**
2. 浏览器里完成华为账号登录
3. 回到商店，看到账号名即成功
4. 导入签名材料（证书 / Profile / 私钥）
5. **换一台设备**再装一次 —— 应自动重建 Profile，不再报 9568423

> 第 5 步是这一环的最终验收。

---

## 六、仍未做的部分

| 项 | 说明 |
|---|---|
| 真机登录验证 | 需要你的华为账号；代码与测试已完成 |
| 多团队切换 | AGC 支持一个账号多个团队（`TeamInfo`）。当前只用默认团队（teamId = userId），原实现也是 |
| 发布证书流程 | 当前只处理调试证书（`certType == 1`）。发布证书需要 AGC 侧额外权限，侧载场景用不到 |
