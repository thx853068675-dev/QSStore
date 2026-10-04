# AGC 自动签名次数限制与管理弹窗验证

## 原因与修复

用户提供的[华为官方 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-tools-faq/faqs-app-debugging-4)明确说明：同一开发者账号最近 30 天内使用自动化签名不能超过 150 次，按最近 30 天滚动计算。`Sign ide test provision number exceeds limit`（AGC 205389938）应按自动签名使用次数限制处理。此前把它归因为遗留 Profile 占满可回收槽位不准确，现已纠正。删除 Profile 不能作为重置使用次数的方案。

旧客户端没有保存创建响应 ID，也没有下载后清理临时记录，属于独立的资源回收缺陷；修复回收生命周期不等于恢复自动签名额度。

- 创建结果保留真实记录 ID，兼容顶层及嵌套响应。19 位数字 ID 必须以字符串保留，不接受已被 JavaScript 舍入的数字。
- 有明确、有效的云端创建编号时，下载前原子保存回收凭据；成功、下载失败、授权验证失败、期限未延长均在 finally 中回收该记录。2026-10-04 修正：基础 IDE 签发可只返回文件地址，没有可删除的持久记录；无编号不得阻断签装，也不得捏造编号删除其他记录。
- 删除失败保留凭据，下次申请前恢复回收；按账号和团队隔离，只删除本安装器持有创建凭据的记录。
- 同账号申请串行化。优先复用包名、完整 UDID、证书、ACL 和期限均已核验的本地授权；续签请求保留独立副本，不覆盖历史安装证据。
- 次数上限错误停止 IDE 临时授权申请，清理成功也不重试 IDE 签发。自动尝试普通调试 Profile；按账号和团队保存 10 分钟的限额记录，避免连续任务反复撞限额，也避免把可能已滚动恢复的额度锁住一天。普通 Profile 不进入临时授权回收账本。

参考实现为 [dsh-deveco-cli 的 generate-profile.ts](https://github.com/fz-lyle/dsh-deveco-cli/blob/main/src/signature/generate-profile.ts)：保留创建响应的 `id`，下载后删除临时 Profile；HoKit 1.9.0 的已提取 ABC 也有下载后删除临时授权的路径。此参考不等于已验证当前满额账号的成功签发。

## 云端查询、清理与次数限制的区别

旧版没有保存记录 ID。本次登录 AGC 官方控制台后，Profile 页面只显示两条普通授权；调用页面自带的 `queryProvisionList`，分别不设类型限制和覆盖其全部公开类型枚举，均返回成功且仅有这两条记录，没有返回 IDE 临时授权。

继续检查本机官方 DevEco Studio 26.0.0.821：`AutoSigningConfigsService.getProvisionList` 使用 `/provision/list`，请求头名为 `appId`，参数为 `encodeFlag=0&start=1&pageSize=100`。此前探测错误使用 `app-id`；按官方写法和真实注册 App ID 重试后，HTTP 200 / ret 0，返回该应用一条普通发布 Profile（`tempFlag=0`）。调试类型及临时标记筛选均为空。使用实际 IDE Profile 的 `app-identifier` 作为请求头则返回 HTTP 403。HoKit 和 DevEco 的临时删除接口都使用具体创建 ID，没有找到 `all` 删除契约；未发送猜测的批量删除请求。

以上查询没有恢复额度；官方 FAQ 已说明恢复依据是滚动时间窗口。此次未删除用户证书或普通 Profile。发现可回收记录仍可清理资源，但不能把清理结果当成恢复 150 次额度的证据。

## 手动签名边界

官方 FAQ 明确推荐次数用满时采用手动签名。[申请调试 Profile](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)要求已经创建 HarmonyOS 应用、具有调试证书、注册设备，并将已获批准的 ACL 加入 Profile。每个应用最多 100 个 Profile；这与 IDE 自动化签名的滚动次数规则不同。

已接入 `AgcManagedProfile` 自动执行官方手动流程：先查询账号已有的同包名应用；没有时复用或创建「轻启本地签名」项目并登记 HarmonyOS 应用。登记接口按本机官方 DevEco 的表单编码调用；Profile 创建仍用 JSON，并带真实注册 `appId` 请求头。JSON 编码的登记请求实际返回 HTTP 403，改为表单后 ret 0。

再查询普通调试 Profile，验证其签名 CMS 中的包名、完整 UDID、证书、ACL 和期限后复用。无匹配授权时才创建稳定命名的普通 Profile；创建响应超时后的下一次尝试先查询，避免盲目重复 POST。云端普通 Profile 保留供恢复和多设备复用，不作为 IDE 临时授权删除。

本地缓存仍排在所有 AGC 网络请求之前。正常更新与重复安装不按版本号申请授权；进程重启也读取实际缓存。续签只有需要延长期限、旧材料不能满足目标时才取新授权。

ACL 是独立边界：本账号对 `KEEP_BACKGROUND_RUNNING_SYSTEM` 的普通 Profile 请求实际返回 205389941，说明未获得该应用的 ACL 批准。客户端会明确列出缺少的 ACL，不删除权限、不伪造已授权、不声称任意应用均能绕过限制。普通 Profile 使用新登记 app-identifier 时，也保留既有的签名兼容核对与丢失数据确认。

## GET_BUNDLE_INFO_PRIVILEGED 实际申请

用户要求尝试权限申请后，使用已有登录态、配对证书和已登记的 7.0 设备，向正常 IDE 授权创建接口提交一次仅包含 `ohos.permission.GET_BUNDLE_INFO_PRIVILEGED` 的 ACL 请求，目标包名为安装器自身。HTTP 200，AGC 返回 205389938 / `Sign ide test provision number exceeds limit.`，没有签发新 Profile。

这个结果说明当前申请被名额限制阻断，不能据此判断此权限被允许或被拒绝。没有把旧 Profile 改写为“已授权”，没有安装缺少对应 ACL 的候选包，也没有改动生产权限白名单。带此权限的安装器自更新和跨应用授权读取尚未验证。请求返回的非敏感错误证据保存在 `/tmp/qingqi-expiry-20261003/privileged-acl-result.json`，认证材料仍位于仓库外。

## 到期时间边界

本安装器已有可核对安装证据的应用，期限由实际签名 Profile 的 `validity.not-after` 和签包证书 NotAfter 中的较早值确定，并绑定包名、版本、安装更新时间和指纹。

7.0 上轻启、鸿米家等实际显示 2027-10-03。其他工具侧载的 HoKit 仍然显示“签名到期未知”：本次设备查询没有返回其可核验的 Profile；跨应用 SDK 查询受权限限制，已安装 HAP 路径也拒绝读取。证书到期日不能代替设备授权到期日，因此没有填写推测日期。这部分尚未完成普遍获取。

本次轻启样本中，授权文件有效期为 365 天，系统安装时间比授权起始时间晚 15082 秒（约 4.19 小时）。按安装时间加 365 天会比实际 Profile 期限多报约 4.19 小时。重复安装、更换证书以及其他工具复用旧授权时，偏差可能更大。因此安装时间推算只能作为明确标注的估计，不能作为真实到期证据。

## 验证结果

- 原生宿主回归 516 项全部通过，包括申请串行、失败回收、恢复隔离、损坏凭据、响应 ID 精度、卸载失败与取消、弹窗返回优先级。
- 官方 FAQ 纠正后，授权缓存和回收相关 22 项回归通过；新增验证“即使成功清理记录也不重试次数受限的签发”及“用满额度后仍可使用有效的本地授权”。上述 516 项为此前完整运行记录。
- ArkTS 编译通过；官方 SDK 签名及 `verify-app` 通过。
- HarmonyOS 7.0 设备已安装本地测试候选 `0.4.51-preview.1` / `2026100310`。
- 续签中央弹窗实际显示轻启图标；取消系统选包后弹窗仍在，未选文件时不能开始续签。
- 无子仓时配置只显示“新增子仓”；点击后展开输入与检查；系统返回关闭配置、保留管理页，本次没有保存或变更仓库配置。
- 已安装 HoKit 长按显示卸载菜单，点击后显示数据删除确认，取消后应用保持安装；没有为了验证删除真实用户应用。

以上为此前 7.0 验证；本轮新增 6.1 的普通 Profile 成功签发、安装及复用证据见下。任意外部侧载应用的真实授权期限仍未普遍获取。代码与测试候选只保留本地，未提交、推送、发布或部署服务器。

测试日志：`/tmp/qingqi-expiry-20261003/native-tests.log`；构建日志：`/tmp/qingqi-expiry-20261003/build.log`。图标截图：`/tmp/qingqi-expiry-20261003/renewal-icon-verified.png`；配置返回、子仓和卸载菜单的 UITest 快照位于 `/tmp/qingqi-cross-tool-renew-20261003/`。账号凭据、私钥及认证响应未写入此文档。


## 6.1 自动手动签名验证（2026-10-03 至 10-04）

设备 `3BH0224320005595`，HarmonyOS 6.1.1.120 / API 24。使用设备自身已经登录的账号和已配对证书；该账号与 IDE 自动签名次数满额的账号一致。没有新建或删除调试证书。

验证方式：本地候选临时加入 Want 参数触发的探针，直接调用真实的 `AccountSession`、`SigningIdentityRecovery`、`AgcProfile` 和原生 `signHap` / `verifyHap`。使用独立测试包名 `com.tonghongxiang.hapstore.manualcheck`，避免覆盖用户应用。系统提交安装使用主机 HDC；本轮未声称已通过常规续签弹窗完成带 ACL 应用的无线调试端到端续签。

| 验证 | 结果 |
| --- | --- |
| 普通 Profile 签发 | 同一个满额账号实际获得普通调试 Profile，云端 `provisionType=1` / `tempFlag=0` |
| 6.1 首次签装准备 | 自动登记应用、获取 Profile、本机重签和本机验签通过；约 2922 毫秒 |
| 重启复用本地授权 | 两次独立进程签装准备通过，约 1026 / 868 毫秒；授权文件路径和期限一致 |
| 缺失测试缓存后恢复 | 清除仅测试包的本地授权后取回已有云端 Profile，验证和签包通过；约 1537 毫秒 |
| 官方验签 | 设备原生签出的真实 HAP 通过 SDK `verify-app`，含 codesign 校验 |
| 系统安装与覆盖 | 上述设备签出包在 6.1 安装、启动及再次 `install -r` 全部通过 |
| 云端重复检查 | 测试应用普通 Profile 始终只有一条，未因重启或重新签装重复创建 |
| 客户端回归 | 533 项全部通过；覆盖本地缓存、重启、已知限额、普通 Profile 生命周期、ACL 拒绝、未知创建结果、表单编码、401 刷新保留请求头，以及重新登记同 UDID 后复用 |

现有 6.1 安装器与设备当前账号的新普通 Profile 签名身份不同，直接覆盖被系统以 `9568332` 拒绝；原应用数据未改动。随后使用与旧安装器一致的既有签名材料覆盖部署本地测试候选，保留账号、证书与应用数据。最终候选已移除探针及测试原始 HAP，检查 HAP 内无 `qingqiProfileProbe` 入口或测试 rawfile；测试应用已卸载，测试输入、签包输出和导出文件已清理。

验证文件位于仓库外 `/tmp/qingqi-manual-sign-20261003/`：`all-native-tests.log`、`sdk-device-verify.log`、`final-build.log`、`device-third-result.json`、`device-cloud-reuse-result.json`。认证材料和私钥不进入 Git 或说明文档。

## 商店实际安装失败的补充核验（2026-10-04）

先前独立测试包名能登记 AGC 应用，其成功不能证明任意商店应用在额度耗尽后都能通过普通手动 Profile 安装。6.1 实际队列内 `com.legado.app` / `Legado-1.0.6.158-26090920-signed.hap` 报 `The app pkg's name has been used.`；该设备本地授权只有 PiliPlus、ClashBox、轻启和独立测试包，没有 Legado 的授权。

官方[创建 HarmonyOS 应用](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-create-app-0000002247955506)明确包名全局唯一。[调试签名异常](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-signature-service-18)要求包名已占用时改包名或加入拥有该包名的团队。普通手动 Profile 不能视为任意第三方包名的通用签发替代。

按本机 HoKit 桌面客户端完整请求字段，在自己真实注册的测试应用普通 Profile 请求里附加 `packageName=com.legado.app`，接口 ret 0，但验过 CMS 的真实 `bundle-name` 仍为登记应用 `com.tonghongxiang.hapstore.manualcheck`。没有将该 Profile 用于签装 Legado，没有改包名或改写 Huawei 的授权内容。HoKit 桌面客户端自身说明同账号约每 30 天 150 次、可复用本地 p7b；其第三方包名登记失败也会回到受额度限制的 IDE 路线，没有发现通用的无限普通授权方案。

客户端已将这一包名冲突明确归为等待账号授权，保留原安装包，避免把可恢复的账号条件当成坏包终止；同团队登记竞态先查询一次已有应用，不盲目重复创建。新增两项回归通过。此改动改善失败恢复与说明，不代表已解决没有合法 Profile 的第三方应用首次签装。

### 满额后复用自动签名遗留授权：真实商店更新

在 6.1 常规发现页点击 PiliPlus「更新」，在线下载未签名 `PiliPlus_ohos_2.1.5-ohos_unsigned.hap`，由 2.1.4 / vc6098 覆盖升级至 2.1.5 / vc6170。此验证没有加入 Want 探针、没有用主机 HDC 提交 PiliPlus 安装。

设备任务数据库记录完整 `queued → downloading → verified → package_inspected → profile_ready → signed → signature_verified → installing → installed`，约 10.96 秒；`profile_ready` 阶段约 673 毫秒；`last_error` 为空。新旧版本任务引用同一自动签名授权 `com.example.piliplus-2052206493427620736-4d32998f6e81.p7b`。系统 `bm dump` 确认 2.1.5 / vc6170，更新时刻与新任务吻合，原安装时刻未变。发现页按钮已变为「打开」。

这直接证实已有合法本地 Profile 的应用升级可继续签装。不能据此推断本地无 Profile 且不拥有包名的首次安装也能成功。
