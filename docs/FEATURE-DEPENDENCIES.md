# 发现与详情页的数据依赖

## 已接入的数据

| 功能 | 来源 | 服务端存储或接口 |
|---|---|---|
| 应用星数、大卡片条件 | GitHub 仓库 `stargazers_count` | `app.stars`，`GET /api/v1/apps?sort=stars`；大卡片阈值为 **>100** |
| 应用图标 | 优先读取经 GitHub SHA-256 摘要验证的 HAP 内图标，失败时用 GitHub 仓库头像 | `app_icon`，`GET /api/v1/apps/{id}/icon`；离线种子导出版本 2 包含图标 |
| 应用名称 | 上架预处理读取所选 HAP 的 `module.json` 标签及 `resources.index` 中 `labelId` 对应的字符串 | `app.display_name`；无法解析时保留已有名称，首次上架回退仓库名 |
| 应用分类 | GitHub topics 和仓库简介关键词；无法判断时显示“其他” | `app.category`；不再统一默认为“工具” |
| 上架者 | 服务端核对 DevEco 登录凭证得到的账号 ID 和华为开放资料接口返回的昵称 | `publisher`；应用响应中的 `publisher_name` |
| 我上架的应用 | 已验证华为账号与 `publisher.account_id` 匹配 | `GET/DELETE /api/v1/me/apps`；删除后从公开商店隐藏，历史数据保留 |
| 历史版本 | GitHub Releases 和每个 `.hap` 附件 | `GET /api/v1/apps/{id}/releases`；安装时客户端再读 HAP 的真实包名和版本 |
| 星级与评论 | 已验证的华为开发者账号 | `review`；`GET/POST /api/v1/apps/{id}/reviews`；同一账号可提交多条，均计入平均星级 |

“上架者”表示把仓库提交到本店的华为开发者账号，**不表示其拥有 GitHub 仓库**。仓库所有权仍由独立的 `verified` 状态表达。

## 生产服务的外部依赖

正式服务器需要访问 `api.github.com`、GitHub Release 下载地址、`cn.devecostudio.huawei.com:443` 和 `account.cloud.huawei.com:443`。2026-09-27 曾因 `hapstore-api.service` 继承 `/etc/environment` 中的本地 HTTP 代理 `127.0.0.1:7890`，导致 TLS 握手超时和评论的 `503 IDENTITY_UNAVAILABLE`。服务器直连这些地址正常；现已用 systemd `UnsetEnvironment` 清除该服务的代理变量。重启后无效凭证可在约 1 秒内返回 401，真实手机已通过正式服务提交 4 星评论并重新提交 GitHub 仓库，两个写入链路均成功。

部署时须保留[服务单元配置](../server/deploy/install.sh)中的代理清除设置，或提供确实可用的代理。账号 JWT 仅通过 HTTPS 发给服务端用于核验，不写入数据库；不能因为外部身份服务暂不可用而信任客户端自填昵称。浏览、搜索、图标、分类、历史版本和评论读取仍只依赖本地 SQLite 索引，可用 `hapstore.transfer` 离线导入。HAP 本体不长期留在服务器。

## 头像

客户端优先用 DevEco 开发者登录态的 access token，向华为开放资料接口 `GOpen.User.getInfo` 以 HTTPS POST 请求昵称 `displayName` 和头像 `headPictureURL`；请求 `getNickName=1`，只使用昵称，不使用证书实名。实机已成功显示头像并在升级后恢复，无须额外 AGC Client ID。若该接口未返回头像，用户点头像可尝试 Account Kit `profile` 授权；这个备用路径仍需要 AGC Client ID。客户端仅接受 HTTPS 头像 URL，保存在本机账号状态中。服务端另用已核验的账号资料保存头像 URL，并在评论列表中返回；账号再次核验后，其已有评论也会显示头像。
