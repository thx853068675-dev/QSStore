# 星仓实机验证记录（2026-09-27）

## 环境与产物

- 手机：HBN-AL00，HarmonyOS API 24，HDC 设备 `3BH0224320005595`。
- 当时验证的正式包：`starstore-0.1.0+2026092706-signed.hap`，33 MB，已签名并安装；私仓仅保留最终构建版本。
- 正式 API：`https://store.example.com`，客户端校验服务端证书 SHA-256。
- 临时联调 API：电脑本地 HTTPS `127.0.0.1:8788`，经 HDC 端口反向映射供手机访问；独立 SQLite 数据库。它只用于真实账号写入链路测试，没有把测试评论写入正式库。

## 实机逐项结果

| 项目 | 结果 | 证据或说明 |
|---|---|---|
| 正式包启动、账号保留、无线调试连接 | 通过 | 升级安装后以端口 45027 连入 |
| 发现页去除“精选/最近更新”行、右上角上架按钮 | 通过 | `dist/verification/discover.jpeg` |
| 91 星应用以列表展示，HAP 图标显示 | 通过 | 同上；大卡片阈值代码为大于 100 星，当前正式数据没有高星样本 |
| 使用已登录的华为开发者账号上架 GitHub 仓库 | 通过（正式 API） | 修复代理后再次从手机提交 `thx853068675-dev/quietstart`，正式库 `submit_task` 状态为 `ok`；联调截图：`dist/verification/local-submit-success.jpeg` |
| 正式 API 中的上架者、HAP 图标、分类、版本 | 通过 | 正式库已导入经验证的上架者身份与图标；`dist/verification/discover.jpeg` |
| 详情页仓库链接跳浏览器 | 通过 | 手机上打开了对应 GitHub 页面 |
| 更新说明折叠、文字排版 | 通过 | `dist/verification/detail-notes.jpeg` |
| 历史版本选择、对应 HAP 选择 | 通过 | `dist/verification/history.jpeg`；选择 v1.0.0 后顶部包名和安装文案同步改变 |
| 旧版真实安装流程、圆环总进度 | 预期失败 | `dist/verification/install-progress.jpeg` 与 `downgrade-result.jpeg`；下载与本机签名走到系统安装，设备因已有 v1.1.0 返回错误 9568263（禁止降级），原应用保留 |
| 评分、评论、账号昵称展示 | 通过（正式 API） | 真实手机以华为账号提交 4 星及评论，正式库有 1 条记录，页面回显昵称和正文；`dist/verification/production-review-success.jpeg` |
| 正式包评论弹层 | 通过 | `dist/verification/review-sheet.jpeg` |
| 第二个包的本机签名、设备授权与安装 | 通过 | 32.8 MB 的 `xiaobai-quietstart-3.1.1-unsigned.hap` 安装成功，提示“已自动更新设备授权”；`dist/verification/second-package-install-success.jpeg` |
| “我的”多应用信息呈现 | 通过（2 包） | “已安装的应用”显示共 2 包，弹层逐行列出两个 bundle 和版本；`dist/verification/two-installed-packages.jpeg` |
| 账号头像 | 部分支持 | 当前 DevEco 登录响应未返回头像，实机显示默认头像。可靠获取需要接入华为 Account Kit 的 `profile` 授权 |

## 服务端修复与回归

正式服务器先前访问 `api.github.com` 和 `cn.devecostudio.huawei.com` 时 TLS 握手超时，评论返回 `503 IDENTITY_UNAVAILABLE`。排查发现 `hapstore-api.service` 从 `/etc/environment` 继承了本地代理 `127.0.0.1:7890`，代理无法完成这些 HTTPS 握手；直连两个目标正常。服务单元现清除代理环境变量并已重启。修复后无效凭证返回 `401 SIGN_IN_REQUIRED`（约 1.1 秒），实机的正式评论与重复上架均成功。详细依赖见 `docs/FEATURE-DEPENDENCIES.md`。

正式 HTTPS 接口用与客户端相同的证书 SHA-256 指纹逐条核对后，`healthz`、应用列表、详情及评论读取均返回 200。正式库现有该账号的 4 星评论 1 条。

## 自动检查

- `flutter analyze lib/`：通过，0 问题。
- `flutter test`：45 个通过。
- `python3 -m unittest discover -s server/tests -v`：8 个通过。

## 11:13 最终版本补充验证

- 最终签名产物为 `dist/starstore-0.1.0+2026092712-signed.hap`，SHA-256 为 `33ae0934177f55535c81d3d75bafe765b4a69008ef37639b06950cfc7bf0490c`。实机升级安装和启动成功，原华为开发者登录态保留。重新连接无线调试后，商店正常显示正式服务应用列表。
- 登录流程重新验证：已有证书时第一步直接完成；连接无线调试后才申请设备授权，未再错误提示证书槽位已满。此前用同一账号成功新建了与本机私钥配对的证书，随后完成 Profile 申请与安装。
- 两阶段上架：手机输入 `thx853068675-dev/quietstart`，服务端返回两个 HAP 供选择；选 `quietstart-1.1.0.hap` 和“工具”后确认，正式服务返回成功并只展示所选包的历史版本。
- 多条评论：同一华为开发者账号提交 4 星 `review-A` 后，之前的 5 星评论仍保留；正式库共两条，平均 4.5 星。
- 详情页只有底部固定安装按钮。点击后蓝色按钮内部显示“下载中 10%”及进度填充，随后在实机完成签名、自动更新设备授权及安装；系统内可查到 `com.tonghongxiang.quietstart`。证据见 `dist/verification/final-install-progress.jpeg` 和 `final-install-success.jpeg`。
- 更新页删除行为的回归测试：同一仓库两条不同 bundle 记录中删除一条，另一条在重载持久化数据后仍保留。实机当前仅有一条商店安装记录，因此未在设备上复现双记录删除场景。
- 头像：Account Kit 授权调用已接入，实机返回 `1001502003`、空 `app_id`。`com.tonghongxiang.hapstore` 尚需 AGC Client ID，当前仍显示默认头像，未通过头像显示验证。
- 静态分析 0 问题；Flutter 47 项测试、服务端 11 项测试通过。正式服务器已更新所选 HAP 复核逻辑，重启后 `/healthz` 返回 200。

## 12:05 华为头像与打开应用补充验证

- 对照本地 `HoKit_1.9.0.hap` 的已编译字符串，确认它在 DevEco 登录后调用 `GOpen.User.getInfo`，读取 `headPictureURL`。华为官方[“Obtaining User Information”文档](https://developer.huawei.com/consumer/en/doc/development/HMSCore-References/get-user-info-0000001060261938)也描述了同一 HTTPS POST 接口。星仓改用现有登录态调用此接口，实机点头像后已显示该账号的真实头像；升级到最终版本后头像仍可恢复。见 `dist/verification/avatar-success.jpeg`。
- 已安装应用的发现页按钮变为“打开”。手机点击后出现系统跨应用启动确认，确认后成功进入 `com.tonghongxiang.quietstart`。详情页底部按钮与更新页的已获取记录也变为“打开”，更新页实机点击后再次成功进入应用。见 `dist/verification/detail-open.jpeg`、`updates-open.jpeg` 和 `open-app-success.jpeg`。
- 新安装时从 HAP 的 `module.json` 保存主 Ability 和模块名，用于启动入口名称不同于 `EntryAbility` 的应用。单元测试覆盖非默认入口及记录重启后的持久化；实机当前安装记录来自旧版，已验证兼容回退入口，非默认入口的真实应用尚无可用样本。
- 最终签名产物为 `dist/starstore-0.1.0+2026092714-signed.hap`，SHA-256 `db4dfdbd32ae06e4840d2a0ccb132b343a9980c976e83c9270dc9ec2509c6a55`。已在 HBN-AL00 升级安装、连接无线调试并启动。静态分析 0 问题，Flutter 48 项测试通过。

## 13:04 HarmonyOS 7.0 证书管理补充验证

- 新接入的 VDE-AL10 为 HarmonyOS 7.0.0.107、API 26，HDC 设备 `3UJ0225318033410`。最终 `0.1.0+2026092718` 已在两台设备升级安装；同一签名 Profile 同时含 VDE-AL10 与原 HBN-AL00 的 UDID。7.0 实机 `bm dump` 确认版本码 `2026092718`，启动进入证书准备页；截图见 `dist/verification/harmony7-build18.jpeg`。
- 7.0 实机登录重现“3 个调试证书槽位已满”。账号现有 `hokit_debug`、`hapstore-debug-10c2a6098e`、`hapstore-desktop-debug` 三张；当前 7.0 设备星仓私钥与三张都不配对，未自动删除团队证书。新弹层读到 3/3 张，列出名称、ID、到期日及逐张删除的二次确认入口。证书到期时间的秒/毫秒解析已修正，页面正确显示 `2027-09-27`。证据为 `dist/verification/harmony7-login.jpeg` 与 `harmony7-cert-manager16.jpeg`。
- 为给 7.0 设备签发本次测试包，桌面构建身份曾占用当时最后一个空槽位并创建 `hapstore-desktop-debug`。构建脚本现默认拒绝无匹配证书时新建，显式 `--allow-new-cert` 才能创建；手机登录在仅剩一槽时也要求用户明确确认。当前无法在不确定用途的情况下安全删除三张之一，7.0 设备的账号登录与后续安装链路待证书处理后复验。
- 最终包签名后再次运行桌面 Profile 准备脚本，同一两台设备的本地 Profile 校验通过，明确输出“未向 AGC 重复申请”；账号证书数量保持 3 张。
- Flutter 静态分析 0 问题，当前共 53 项 Flutter 测试通过，其中包含 CSR 丢失补建、三槽满但旧命名证书复用、仅剩一槽不静默申请、A → B → A 授权本地缓存、到期时间单位转换。
- 最终签名 HAP：`dist/starstore-0.1.0+2026092718-signed.hap`，SHA-256 `f81c4e969e6e460702247c908de5cc057e45db3d2ba4aa7722b0ff4330e0b9ab`。

## 16:30 HarmonyOS 6.1 自动恢复与昵称验证

- 按用户要求只在 HBN-AL00（HarmonyOS 6.1，HDC `3BH0224320005595`）验证；7.0 设备本轮未操作。自动恢复验证版本 `0.1.0+2026092726`，升级后保留登录状态。最终发布版本增加资料接口账号 ID 核对，为 `0.1.0+2026092727`。该包已在 6.1 成功升级安装，`bm dump` 核对版本码 `2026092727`，重新连接无线调试后进入发现页和“我的”页；SHA-256 为 `01647f93c669165e2ddcf5eae3a243c8b76eafe6c1de25a81e001cd8bdc43ff4`。
- 服务端已为该华为账号加密保存一份签名身份；密钥文件权限 `0600`。未授权请求取回身份返回 `401`，授权请求返回同一证书 ID，数据库中没有明文私钥。
- 在 6.1 应用沙箱模拟“本机证书配置丢失”后重新点登录，客户端自动取回私钥，与 AGC 上的有效调试证书公钥配对并复用原证书 ID `2048580648540604608`。恢复前后私钥 SHA-256 一致，AGC 证书数量未增加，没有备份密码或文件选择流程。恢复后清理了同内容的临时回退副本。
- 无线调试设置显示端口 `45027`；填入后连接成功，进入发现页。发现页上架者及“我的”账号均显示华为公开昵称 `童大大`，没有掩码。DevEco 返回的昵称曾带掩码，因此客户端与服务端均改用 `GOpen.User.getInfo` 的 `displayName`；服务端核对账号 ID，不读取证书主体实名。头像此前已在同一设备验证，此次升级后本机资料仍保存头像 URL；本轮截图工具捕获到其他前台应用，未将其作为本轮头像视觉证据。
- 服务器 `/healthz` 返回 `200`，服务处于 `active`。此次未重新上架或发送评论，以免重复产生正式数据；上架和评论实机链路的先前验证见本文件上文。
- 最终 Flutter 静态分析 0 问题，57 项测试通过；服务端 14 项测试通过。

## 17:30 更名、图标与 TLS 校验补充

- 6.1 设备升级安装 `轻启·安装器 0.1.0+2026092730` 成功，`bm dump` 显示版本码 `2026092730`。桌面显示“轻启·安装器”和新图标；新图标沿用轻启的四段绿斜线，加蓝色安装标记。见 `dist/verification/qingqi-v30-launcher.jpeg`。
- 引导页标题收为单行“轻启·安装器”，实机画面无末字孤行；见 `dist/verification/qingqi-v30-setup.jpeg`。签名证书仍显示就绪，升级保留账号状态。
- 元数据客户端在启用证书指纹时使用空信任根，仅在握手阶段确认指纹后发送请求体。回归测试模拟系统已信任错误证书，验证私钥上传请求未到达服务端。相同客户端从构建机经固定 HTTPS 指纹成功读取正式 API 应用列表。最终 Flutter 58 项测试及静态分析通过，服务端 14 项测试通过。
- 最终签名包 SHA-256：`a78bcdb01bec5e82fa30ded2b0665820a210f5f6782a7d0ca6d55f7d1c8f8bd3`。本轮新版在 6.1 已完成升级、桌面与引导页检查；无线调试、发现页、评论和上架的实机验证沿用本文件此前记录。

## 19:30 图标对齐、无线调试重连与两步引导

- 按反馈撤回“启”字方案；安装器图标直接以轻启原图为底图，四段斜线的形状、间距与对齐完全一致，只在右下角增加独立的蓝色安装标记。6.1 桌面已显示新图标与“轻启·安装器”名称，见 `dist/verification/qingqi-v34-setup.png`。
- 内置 HDC 现在通过实际执行 `bm get --udid` 检查连接，不能再凭旧目标列表误判在线；连接新端口时若旧端口不同，先移除旧连接，并要求新端口连接命令与设备应答均成功。应用从系统设置返回后复查连接；断线会显示带旧端口预填的引导页。在线及离线安装开始前也会检查通道，失败时提示重连，避免下载后才发现端口失效。
- “我的 → 无线调试”已显示当前端口 `45671` 并提供重新连接入口，6.1 实机截图见 `dist/verification/qingqi-v34-mine.png`。首次连接页只保留登录与无线调试两步；第三张“开始使用”卡片及无效的“进入商店”按钮已移除。
- 最终 `0.1.0+2026092734` 已在 6.1 设备升级安装，`bm dump` 确认版本码 `2026092734`；签名验证通过。Flutter 61 项测试通过，静态分析 0 问题。SHA-256：`965ee5ba47bddfda18a946d38fe0a7bf19a9ce551efe637ab398902a158a1117`。本轮未操作 7.0 设备。

## 21:00 按需重连、悬浮按钮、新图标与评论头像

- `0.1.0+2026092736` 已在 HarmonyOS 6.1 设备升级安装，`bm dump` 确认版本码 `2026092736`。状态栏与页面底色衔接，发现页列表不显示公告，见 `dist/verification/qingqi-v36-home.png`。首次引导的连接动画现位于按钮内；登录态已恢复，故本轮实机启动未再次进入首次引导。
- 应用详情页移除底部白色栏，只有蓝色安装按钮悬浮，页面内容可在按钮后方滚动；滚动到底部的实机截图为 `dist/verification/qingqi-v36-detail-bottom.png`。桌面图标已替换为用户给出的星星角色图，实机显示与名称见 `dist/verification/qingqi-v36-launcher-ready.png`。
- 本次在详情页安装轻启 1.1.0 时，设备通道不可用，进度停在设备授权阶段并弹出“连接无线调试以继续安装”，未切回引导页；实机截图为 `dist/verification/qingqi-v36-install-progress.png`。其后设备上 `bm dump` 确认 `com.tonghongxiang.quietstart` 版本 1.1.0（版本码 `110003`），发现页按钮变为“打开”。本次未录得重连按钮的完整点击序列；本地 HAP 在等待重连后保留原文件并继续管线由自动测试验证。
- 正式服务器已新增按核验账号保存头像并关联其所有评论的逻辑。实机重新启动后，公开评论 API 的 3 条旧评论均返回 `avatar_url`；详情页三条评论均显示华为账号头像，见 `dist/verification/qingqi-v36-detail-bottom.png`。头像来源核对 GOpen `userID`，没有使用实名或客户端任意传入的网址。
- 最终签名包 `qingqi-installer-0.1.0+2026092736-signed.hap` 已通过官方签名验证，SHA-256 为 `7c9e9d335f19774fd688ede5c5492352c96b190274bba3e0972416c868fa9a55`。Flutter 62 项测试、服务端 15 项测试及静态分析通过。本轮未操作 7.0 设备。

## 21:55 HAP 实际名称与管理页

- 服务端上架预处理现根据所选 HAP 的 `module.json` 标签和 `resources.index` 中的 `labelId` 读取实际应用名称；多 HAP 候选分别显示名称和文件名。生产服务器读取 `quietstart-1.1.0.hap` 得到“轻启”，同步后公开应用详情也返回“轻启”。
- 管理页包含可更新、已获取和当前华为账号上架的应用；删除上架记录需要该账号身份，其他账号被拒绝，删除后公开详情为 404，可重新上架。服务端单元测试覆盖这些权限与行为；生产服务未用真实账号执行删除。
- `0.1.0+2026092737` 已构建并通过官方签名验证，包内版本码 `2026092737`。Flutter 84 项测试、服务端 17 项测试及客户端静态分析通过。SHA-256：`512a99dc20788ecdd68d0ec349097bbfb41f7fec54a7e89acde71508612131f7`。本轮没有继续操作手机，因此 v37 的管理页尚未实机点击验证。
