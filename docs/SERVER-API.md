# HAP 商店 · 元数据服务（已上线）

> 生产地址：**https://47.98.250.230/api/v1**（自签证书，客户端校验证书指纹）
> 状态：生产服务由 systemd 托管；本轮后台刷新及缓存改动已于 2026-10-02 部署，健康和缓存接口验证通过。

---

## 一、当前能力

```bash
# 健康检查
curl -k https://47.98.250.230/api/v1/healthz

# 应用列表
curl -k "https://47.98.250.230/api/v1/apps?page_size=10"

# 应用详情
curl -k https://47.98.250.230/api/v1/apps/1

# 版本列表（含每个 HAP 的 sha256 与镜像链）
curl -k "https://47.98.250.230/api/v1/apps/1/releases?page_size=3"
```

实测响应（生产数据）：

```json
{
  "display_name": "quietstart",
  "repo": "thx853068675-dev/quietstart",
  "stars": 90,
  "releases_count": 3,
  "latest": {"tag": "v1.1.0", "name": "轻启 1.1.0", "published_at": "2026-09-25T04:11:27Z"}
}
```

---

## 二、API 一览

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/apps` | 列表。支持 `q` `category` `sort` `featured` `page` `page_size` |
| GET | `/api/v1/apps/{id}` | 详情 |
| GET | `/api/v1/apps/{id}/releases` | 版本列表（含 asset 与镜像链）。支持 `page` `page_size`（上限 50），默认仅正式版；`prerelease=1` 手动查看预览版 |
| GET | `/api/v1/apps/{id}/releases/{tag}` | 单版本 |
| GET | `/api/v1/apps/{id}/icon` | 返回选中安装包的真实图标；缺失返回 404，支持 `?v=<icon_rev>` 和 ETag |
| POST | `/api/v1/apps/{id}/refresh` | 去重入队后台检查；60 秒内已采集则返回 `fresh` |
| GET | `/api/v1/apps/{id}/refresh` | 查询 `pending/running/done/failed/fresh` 与 `last_error` |
| POST | `/api/v1/apps/refresh-stale` | 兼容旧客户端，仅按新鲜度入队，不在请求中采集 |
| GET | `/api/v1/apps/{id}/reviews` | 评分与评论列表。支持 `page` `page_size`（上限 50） |
| POST | `/api/v1/apps/{id}/reviews` | 已验证华为开发者账号新增评分与评论（同账号可多条） |
| GET | `/api/v1/signing-identity` | 已验证账号取回加密保存的签名身份；无记录时 `identity` 为 `null` |
| POST | `/api/v1/signing-identity` | 备份 P-256 签名身份；首次写入或携带已确认版本进行 CAS 轮换，冲突返回 409 |
| POST | `/api/v1/submit/prepare` | 检查 GitHub Release；APP/ZIP 由后台解析，返回草稿与检查状态；需 Bearer 凭证 |
| POST | `/api/v1/submit/status` | 携带 `draft_token` 查询 APP/ZIP 检查状态，仅草稿所属账号可访问 |
| POST | `/api/v1/submit/confirm` | 携带 `draft_token`、`asset_names`、`category` 确认多包上架；兼容旧 `asset_name` 单包接口 |
| GET | `/api/v1/categories` | 获取上架和配置共用的软件分类列表 |
| POST | `/api/v1/me/apps/{id}/category` | 上架者修改 `category`；需要已验证账号，分类在后续采集中保留 |
| GET | `/api/v1/me/apps` | 获取当前已验证华为账号上架的公开应用 |
| DELETE | `/api/v1/me/apps/{id}` | 当前上架者删除应用的公开展示；保留历史数据以便重新上架 |
| GET | `/api/v1/admin/sync` | **仅本机** 探测采集通道 |
| POST | `/api/v1/admin/sync` | **仅本机** 入队到统一后台采集 worker |
| POST | `/api/v1/admin/apps/{id}/hide` | **仅本机** 上下架 |
| POST | `/api/v1/admin/apps/{id}/feature` | **仅本机** 精选 |

统一响应包装：

```json
{"ok": true,  "data": {...}, "server_time": "...", "api_version": 1}
{"ok": false, "error": {"code": "...", "message": "...", "hint": "..."}}
```

三个列表接口（`/apps`、`/apps/{id}/releases`、`/apps/{id}/reviews`）的 `data` 都是同一个分页信封：

```json
{"items": [...], "total": 128, "page": 2, "page_size": 30}
```

`total` 是符合条件的**服务端总条数**，不是当前页长度；客户端据此判断是否还有下一页，
不要用 `items.length` 反推。`/reviews` 额外带 `summary`（`{count, average}`）。
`page` 从 1 开始。`page_size` 上限：`/apps` 100，`/releases` 与 `/reviews` 50。

`/apps` 与 `/apps/{id}` 返回 `latest_assets`：最新可安装正式版中全部已上架包，包含
`name`、`size`、`sha256`、`url`、`mirror_urls`、`bundle_name`、`version_code` 等信息。
`latest_asset` 保留为默认包，兼容旧客户端；无可用包时为空。

APP/ZIP 预处理返回 `inspection_status`（`pending`、`running`、`ready`），状态接口
返回相同草稿内容；解析失败返回 `INVALID_PACKAGE_ARCHIVE`。检查完成才允许确认。
`supports_multi_select: true` 表示可使用 `asset_names` 选择最多 32 个有效包。
ZIP 候选 URL 使用 `#qingqi-package=<URL 编码条目名>` 表示下载后提取的 APP/HAP，
摘要与下载大小对应原始 ZIP。服务端解析仍要求可信的 GitHub 摘要并核对实际下载。

客户端直接用包名与版本判断本地安装与更新；多变体无法唯一匹配时由用户在详情
选择。发现页默认包、管理更新队列和详情选中包共享安装任务状态。

**安全**：全站安全响应头、普通接口按 IP 限流（默认 120/分），上架预处理按已验证账号限流（3/分）。同一账号、同一仓库五分钟内重复检查复用预处理结果；无效地址不占次数；429 响应提供实际剩余等待时间。管理接口仅本机、请求体上限 32KB、SQLite 全参数化。

上架、评价及签名身份接口使用 `Authorization: Bearer <DevEco JWT>` 验证华为账号。客户端同时发送 `X-Huawei-Access-Token`，服务端用华为 `GOpen.User.getInfo` 的 `getNickName=1` 获取公开昵称和 `headPictureURL` 头像，并核对返回的 `userID` 与 JWT 账号一致。评论列表返回 `avatar_url`；头像按账号保存，因此账号再次核验后，已有评论也会显示头像。资料接口暂不可用时回退完整账号 ID；不使用证书主体中的实名。

签名身份在服务端以独立随机密钥通过 AES-256-GCM 加密，密钥位于 `/var/lib/hapstore/identity-vault.key`，权限 `0600`。设备取回后会从 AGC 下载当前账号的有效调试证书，只有私钥与证书公钥配对才采用。密钥文件与数据库必须一起备份；丢失密钥文件则现有密文无法恢复。

---

## 本轮服务优化

公开目录、详情、版本和评论 GET 提供 `ETag` 与 `Cache-Control: public, max-age=30, must-revalidate`，命中 `If-None-Match` 返回无响应体的 304。账号、草稿、私钥备份及管理接口仍为 `no-store`。图标修订地址匹配 `icon_rev` 时可长期缓存；上架状态仍在读取时核实，已下架应用不返回图标。

刷新接口只执行短事务并返回状态，例如：

```json
{"ok":true,"data":{"app_id":1,"status":"pending","queued":true}}
```

重复请求返回已有任务状态，`queued:false` 表示没有新增任务。准备草稿、补全目录和检查更新共用单个后台 worker，三类任务轮流执行；定时采集和管理员批量同步也使用同一队列。管理员指定单个仓库的诊断同步仍直接执行。失败最多尝试四次并退避，GitHub 配额冷却会推迟所有使用同一凭证的仓库请求。采集中的应用下架后不会重新公开。

服务器只缓存可信摘要对应的已解析包元数据与图标，不保存整包。`artifact_inspection` 上限 512 条/64 MB、单条 4 MB；同一 ZIP 选择多个包可复用一次下载结果。GitHub API 使用条件请求，缓存上限 128 条/64 MB，缓存键隔离凭证和 Accept 类型；数据库不保存 GitHub Token。

新表 `refresh_task`、`artifact_inspection`、`github_http_cache` 由启动时幂等创建。客户端查询后台刷新状态需要匹配本轮服务端；旧服务刷新接口返回同步结果时新版客户端仍可读取，旧客户端不会自动等待本轮后台任务完成。

详细改动见 [优化报告](LOCAL-OPTIMIZATION-20261001.md)。2026-10-02 部署前已备份数据库、身份加密密钥及旧服务代码，备份目录 `/opt/hapstore-backups/2026100201`。新运行环境为 `/opt/hapstore-venv-2026100201`，保留原服务环境与代理设置。生产数据库副本迁移和全部 216 条身份解密验证通过，应用、评论及身份数量未变化；目录及图标条件请求、健康接口和刷新状态接口已核对。

---

## 三、一个重要的工程发现：versionCode 要从 pack.info 读

实测轻启的同一个包，两个来源的版本号**不一致**：

| 来源 | quietstart-1.1.0 | quietstart-1.0.0 |
|---|---|---|
| `module.json` → `app.versionCode` | 110003 | — |
| **`pack.info` → `summary.app.version.code`** | 110003 | **100008** |

**设备安装时认的是 `pack.info`。** 这正是我用 1.1.0 装机时报 `9568263 不支持降级安装` 的原因——设备上装的是 `110011`，而包里 module.json 写 110003。

采集器因此**优先读 pack.info**，读不到才回退 module.json。若按 module.json 判断"是否有新版本"，会给用户推送错误的更新提示。

---

## 四、采集通道与服务代理

### 4.1 实测结论

早期从服务器探测 GitHub 和 DevEco 的 HTTPS 握手超时，被误判为云侧出站拦截。2026-09-27 排查确认：`hapstore-api.service` 继承的本地代理 `127.0.0.1:7890` 无法完成这些握手；使用 `curl --noproxy '*'` 直连成功。服务单元现用 `UnsetEnvironment` 清除代理变量，手机直连正式服务的上架和评论已成功。

### 4.2 采集与离线后备

```
生产服务器直连 GitHub API → 采集可信摘要与 Release 元数据
另有网络故障时：有网电脑采集 → transfer export → 服务器 import
```

- 采集器在服务端直连运行，可信摘要只从 GitHub API 取得。
- 出站临时不可用时，可用导出/导入做离线播种。
- 后台线程每 6 小时自动刷新；服务代理配置见 `server/deploy/install.sh`。

### 4.3 导出 / 导入

```bash
# 在有网环境采集并导出
HAPSTORE_DB=/tmp/dev.db python3 -c "from hapstore import collector,db; db.init_db(); collector.sync_app('owner/repo')"
python3 -m hapstore.transfer export seed.json

# 生产服务器导入（幂等，可重复执行）
cd /opt/hapstore && HAPSTORE_DB=/var/lib/hapstore/hapstore.db \
  python3 -m hapstore.transfer import seed.json
```

> 导出文件**只含索引元信息，不含任何 HAP 文件本体**——服务端从不存包。

---

## 五、客户端下载链（不经服务器）

服务端为每个 HAP 附件返回 4 个候选地址：

```json
"mirror_urls": [
  "https://gh-proxy.com/https://github.com/.../quietstart-0.9.55.hap",
  "https://ghfast.top/https://github.com/.../quietstart-0.9.55.hap",
  "https://ghproxy.net/https://github.com/.../quietstart-0.9.55.hap",
  "https://github.com/.../quietstart-0.9.55.hap"
]
```

**实测下载闭环**：

```
镜像下载 4.3 MB（gh-proxy）        耗时 1.5 秒
sha256  6004cf8e931c6b39a135…      与 API 声明完全一致 ✅
大小    4273737                    完全一致 ✅
校验    有效 HAP，19 个条目 ✅
```

手机端会并行探测这几个地址取最快者，**主包不经过服务器**——这也是这套方案能在 1.6 GB 内存的小机器上跑起来的前提。

---

## 六、部署信息

| 项 | 值 |
|---|---|
| 代码位置 | `/opt/hapstore` |
| 数据库 | `/var/lib/hapstore/hapstore.db`（SQLite WAL） |
| 服务 | `systemctl {status,restart} hapstore-api` |
| 监听 | `127.0.0.1:8787`（**仅本机**，由 nginx 反代） |
| 对外 | `https://47.98.250.230/api/v1/*` |
| 日志 | `journalctl -u hapstore-api -f` |
| 依赖 | Python 3.12、`cryptography`（签名身份加密） |

### systemd 加固

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/hapstore
```

### 重新部署

```bash
cd "Tong Store"
scp -i ~/.ssh/ts_hapstore_ed25519 -r server/hapstore server/run.py root@47.98.250.230:/opt/hapstore/
ssh -i ~/.ssh/ts_hapstore_ed25519 root@47.98.250.230 'systemctl restart hapstore-api'
```

---

## 七、待办

| 项 | 说明 |
|---|---|
| 自动采集 | 正式服务直连可用；`/api/v1/admin/sync` 可手动触发 |
| 归属验证 | 设计已定（`.hapstore/verify.txt` + nonce），未实现 |
| 分类自动识别 | 已按仓库 topics 和简介映射，无法判断时显示「其他」 |
| HTTPS | 已启用 IP 证书及客户端证书指纹校验 |

## 签名身份备份版本

`GET /api/v1/signing-identity` 的 `identity` 包含 `cert_id`、`private_key_pem` 和
`revision`（从 1 开始）。旧数据库启动时自动补充 revision，不改动已保存的私钥。

首次 POST 提交 `cert_id`、`private_key_pem`。轮换必须额外提交本机在**切换前已经
确认并持久保存**的 `replace_cert_id`、`replace_revision`，服务端匹配成功后原子替换并
递增版本。禁止把冲突响应或临时查询到的最新版本直接用作重试期望值。

成功响应的 data 包含 `synced: true`、`cert_id`、`revision`、`created`、`replaced`。
相同证书与私钥的重试幂等；未确认版本、旧版本或不同私钥的冲突返回
`409 IDENTITY_CONFLICT`，客户端保留本机材料及原有期望版本。

部署顺序：先更新服务端，再更新客户端。旧客户端仍能读取与首次备份；不携带 revision
的旧式轮换会被拒绝，不能覆盖新设备的备份。
