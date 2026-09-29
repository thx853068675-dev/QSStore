# HAP 商店 · 元数据服务（已上线）

> 生产地址：**https://47.98.250.230/api/v1**（自签证书，客户端校验证书指纹）
> 状态：**运行中** · systemd 托管 · 开机自启

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
| GET | `/api/v1/apps/{id}/releases` | 版本列表（含 asset 与镜像链）。支持 `page` `page_size`（上限 50） |
| GET | `/api/v1/apps/{id}/releases/{tag}` | 单版本 |
| GET | `/api/v1/apps/{id}/icon` | 优先返回 HAP 图标，缺失时 302 跳转至 GitHub 头像 |
| GET | `/api/v1/apps/{id}/reviews` | 评分与评论列表。支持 `page` `page_size`（上限 50） |
| POST | `/api/v1/apps/{id}/reviews` | 已验证华为开发者账号新增评分与评论（同账号可多条） |
| GET | `/api/v1/signing-identity` | 已验证账号取回加密保存的签名身份；无记录时 `identity` 为 `null` |
| POST | `/api/v1/signing-identity` | 首台设备上传与 AGC 调试证书配对的 P-256 私钥；同账号首次写入生效 |
| GET | `/api/v1/categories` | 分类统计 |
| GET | `/api/v1/stats` | 全局统计 |
| POST | `/api/v1/submit/prepare` | 检查 GitHub Release，返回各 HAP 的实际应用名、包名与建议分类；需 Bearer 凭证 |
| POST | `/api/v1/submit/confirm` | 携带 `draft_token`、`asset_name`、`category` 确认上架；重新核对所选 HAP |
| GET | `/api/v1/me/apps` | 获取当前已验证华为账号上架的公开应用 |
| DELETE | `/api/v1/me/apps/{id}` | 当前上架者删除应用的公开展示；保留历史数据以便重新上架 |
| POST | `/api/v1/submit` | 兼容旧版客户端的上架接口 |
| GET | `/api/v1/submit/{task_id}` | 上架进度 |
| POST | `/api/v1/apps/{id}/download-event` | 匿名下载计数 |
| POST | `/api/v1/apps/{id}/report` | 举报 |
| GET | `/api/v1/admin/sync` | **仅本机** 探测采集通道 |
| POST | `/api/v1/admin/sync` | **仅本机** 手动触发采集 |
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

`/apps` 与 `/apps/{id}` 还带 `latest_asset`：最新版本里**最大的**那个 HAP 附件
（与客户端选中默认版本的规则一致），字段同 `/releases` 里的 asset
（`name` `size` `sha256` `url` `mirror_urls` `bundle_name` `version_code` …），
没有可用附件时为 `null`。

客户端要用它判断「这个应用装没装、本机版本是不是落后」：`bundle_name` 与
`version_code` 只在 releases 里才有，没有这个字段时客户端得为目录里**每个**
应用单独请求一次 `/releases` —— 一屏 30 个应用就是 30 次往返。

**安全**：全站安全响应头、按 IP 限流（默认 120/分，上架 3/小时）、管理接口仅本机、请求体上限 32KB、SQLite 全参数化。

上架、评价及签名身份接口使用 `Authorization: Bearer <DevEco JWT>` 验证华为账号。客户端同时发送 `X-Huawei-Access-Token`，服务端用华为 `GOpen.User.getInfo` 的 `getNickName=1` 获取公开昵称和 `headPictureURL` 头像，并核对返回的 `userID` 与 JWT 账号一致。评论列表返回 `avatar_url`；头像按账号保存，因此账号再次核验后，已有评论也会显示头像。资料接口暂不可用时回退完整账号 ID；不使用证书主体中的实名。

签名身份在服务端以独立随机密钥通过 AES-256-GCM 加密，密钥位于 `/var/lib/hapstore/identity-vault.key`，权限 `0600`。设备取回后会从 AGC 下载当前账号的有效调试证书，只有私钥与证书公钥配对才采用。密钥文件与数据库必须一起备份；丢失密钥文件则现有密文无法恢复。

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
