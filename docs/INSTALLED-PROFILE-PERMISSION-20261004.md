# 已安装应用 Profile 权限实测（2026-10-04）

## 结果

尚未取得 `ohos.permission.GET_BUNDLE_INFO_PRIVILEGED`。已经用手机上的轻启·安装器完成真实签装测试，确认两个独立条件：华为必须签发包含该 ACL 的授权，调用 Profile 系统接口的应用还必须具有受认可的系统应用身份。

设备：`3UJ0225318033410`，HarmonyOS 7.0，API 26。客户端正式包名 `com.tonghongxiang.hapstore`；测试包使用独立包名 `com.tonghongxiang.hapstore.expiryprobe`，没有覆盖或卸载用户业务应用。

## 1. 实际通过安装器签装

构建无签名测试 HAP，声明普通 `GET_BUNDLE_INFO` 和待验证的 `GET_BUNDLE_INFO_PRIVILEGED`。通过浏览器下载到手机，使用安装器「本地 → 从本地签装」选择、预览、点击安装；桌面没有替代客户端执行签名或安装。

客户端完成设备授权、本机证书签名、签名校验、设备提交，系统返回：

```text
code:9568289
install failed due to grant request permissions failed.
PermissionName: ohos.permission.GET_BUNDLE_INFO_PRIVILEGED
```

读取这次客户端真实使用的 CMS Profile 并验证内容：`allowed-acls=[]`、`apl=normal`、`app-feature=hos_normal_app`。当前安装器的 ACL 支持列表会过滤该权限，所以此结果仅证明缺少授权时设备拒装，不能把这次客户端签装解释为 AGC 已审核并拒绝权限。

## 2. 向 AGC 实际申请该 ACL

随后使用上述客户端任务的同一账号、同一已配对证书、同一已登记设备、同一测试包名，向官方 `ide/test/provision/add` 发送一次明确包含该 ACL 的请求。不创建新证书，不重复登记设备。

```text
HTTP 200
ret.code = 205389941
ret.msg = check aclPermissionList failed, exist permission not in support scope.
```

这次账号可以正常签发普通 Profile，返回明确的 ACL 支持范围错误，区别于之前另一个账号被 `205389938` 申请额度拦住的结果。没有返回带特权的 Profile，也没有新增可用的特权授权记录。

这是自动签名接口的结果，不能据此断言所有官方审核渠道都拒绝该权限。

## 3. 系统 API 对照测试

同一测试包去掉特权声明，递增为 `1.0.1 / 2`，再次通过轻启·安装器本地签装，实际成功。该包只读取权限状态和 Profile 元数据，不上传已安装应用信息，不修改其他应用。

`verifyAccessTokenSync(GET_BUNDLE_INFO_PRIVILEGED)` 返回 `-1`。`getAppProvisionInfoSync(bundleName, 100)` 在三个目标上均返回：

```text
202: Permission denied. Non-system APP calling system API
```

目标为测试包自身、`com.hokit.app`、`com.tonghongxiang.quietstart`。系统包信息也确认测试包 `applicationInfo.isSystemApp=false`、`appProvisionType=debug`。

系统接口确实存在；失败不是函数未导出、包名错误或未安装。自查也返回 202，说明「获取自身不需要权限」不等于普通应用可以调用系统 API。

官方接口说明将该 API 标为系统接口，并列出特权权限及错误码 202：[OpenHarmony 官方文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ability-kit/js-apis-bundleManager-sys.md#bundlemanagergetappprovisioninfosync10)。参考服务源码 `GetAppProvisionInfo` 也先检查系统应用身份，再检查权限；设备的实际 202 与这一顺序一致。

没有给普通应用伪造系统身份，没有修改已签名 Profile，没有关闭设备安全保护，也没有使用安装日期加一年或当前账号证书日期冒充旧应用实际 Profile 到期时间。

## 独立审核仍待完成

AGC 独立 ACL 申请入口需要官方网页登录。此次能够打开 AGC 未登录首页，但登录操作后页面读取持续超时，未进入权限目录或可提交申请页。因此没有提交权限审核，没有取得审核编号，也没有确认个人应用是否具备该权限的申请资格。

下一步需要同时确认权限申请资格与系统接口调用资格。仅批准 ACL 而保持 `hos_normal_app`，不能据此宣布 Profile 读取已解决。

### 可用于官方咨询或申请的材料

**应用**：轻启·安装器，`com.tonghongxiang.hapstore`。

**能力用途**：在用户主动管理本机侧载应用时，读取当前用户的应用签名授权真实到期时间，展示到期提醒并在用户确认后续签。已有安装器签装记录可以从保留的 Profile 核验期限；其他工具安装的应用没有本安装器的原始 Profile，普通 BundleInfo 不提供该期限。

**所需最小信息**：当前用户下应用的包名、已安装版本、Profile 有效期及证书有效期。处理在本机完成，不上传应用清单、Profile 内容或私钥。无需跨用户读取、修改其他应用权限或静默卸载。

**希望官方确认**：

1. 第三方个人开发者应用能否申请 `GET_BUNDLE_INFO_PRIVILEGED`，具体资格、审核入口和材料是什么？
2. 获批该 ACL 后，如何合法满足 `getAppProvisionInfoSync` 的系统应用身份要求；是否有第三方可申请的对应能力？
3. 若第三方不能取得该身份，是否存在面向普通应用或经用户授权的官方 API，读取本机侧载应用实际 Profile 期限？

**复现证据**：自动 ACL 申请返回 `205389941`；缺 ACL 的 HAP 安装返回 `9568289`；普通对照包成功安装后，实际系统 API 返回 `202`。这三种错误发生在不同环节，不能归为同一类签名失败。

## 证据保存

原始构建记录、测试包、CMS Profile、客户端任务数据库和屏幕截图保存在本机 `/tmp/qingqi-expiry-paths-20261004/`。账号材料和数据库只保存在工作区外，不提交凭据、私钥、设备 UDID 或完整 Profile。

本轮没有向正式客户端清单加入这项尚未取得的权限，没有修改签装运行时代码，没有推送或发布新制品。
