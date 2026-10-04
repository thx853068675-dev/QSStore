# 原生客户端 0.4.17 发布说明

对应提交 `8f53fa8` 之后（分支 `codex/native-arkts-rebuild`）。下拉刷新找不到新版本。

## 制品

| 项 | 值 |
|---|---|
| 文件 | `dist/qingqi-native-formal-0.4.17-device6.1-signed.hap` |
| SHA-256 | `d4ae4d04fdc657d20355d9429be092e0a2527765deab3df4f6c67d98ae0b1443` |
| 包名 | `com.tonghongxiang.hapstore`（正式包名） |
| versionCode / versionName | `2026092914` / `0.4.17` |

**这是本机自用的候选包**：Profile 只绑定一台设备，装到别的设备会被系统拒绝。

## 0.4.17 新增

### 根因：下拉刷新只读缓存目录，从不触发采集

`GET /apps` 返回的是服务端**缓存**的目录，`latest_asset` 要等采集周期
（线上 `HAPSTORE_SYNC_INTERVAL=1800`，即 30 分钟）才会更新。所以下拉刷新看到的
永远是旧版本，必须进详情页点「检查更新」—— 那条路会调
`POST /apps/{id}/refresh`，让服务端**立刻**去 GitHub 重采这一个仓库。

修法是把同一件事搬进下拉刷新，并且**只采该采的**：

- 服务端新增 `POST /api/v1/apps/refresh-stale`：批量重采。可传 `app_ids` 点名，
  不传则按「最过期的」兜底采几个。按 IP 限流（6 次/小时），一次最多 4 个应用、
  总时长 12 秒封顶 —— GitHub 采集单个应用实测要 10 秒以上，不设上限会把一次
  下拉刷新拖成几十秒。
- 客户端下拉刷新的顺序改为：**先拉列表 → 与设备对账拿到真实版本 → 算出落后的
  应用 → 点名让服务端重采 → 有变化再拉一次列表**。判定只看**设备上的版本**
  （对账时写入的 `installedVersions`），不看安装记录：记录是「当时装的那个」，
  可能比设备上的旧，拿它当依据会把已经最新的应用也送去重采。
- 一次下拉最多点名 2 个应用。用户关心的是自己装了的那几个，不是整个目录；
  无差别重采既慢又会把 GitHub 配额烧光。

### 顺带修掉的一个静默 bug

批量重采起初直接在 `apps_needing_sync()` 的返回值上取 `app["repo"]`，但那个函数
返回的是**原始 SQLite Row**（列名是 `repo_full_name`，没有 `get_app` 那层的对外
别名）。结果取到空串 → 循环里 `continue` → 接口"成功"返回「考虑了 N 个应用、
刷新 0 个」，什么都没做。

新增 `db.stale_published_apps()` 走 `_row_to_app`，字段与 `get_app` 一致。这个坑
原来的测试看不见（它们 mock 掉了 `sync_app`，不经过这个字段），所以补了两条
**字段级**用例专门盯住它。

## 验证

| 检查 | 结果 |
|---|---|
| ArkTS 发现页刷新/竞态 | 19 项通过（新增 3 项） |
| ArkTS 恢复/并发/CAS | 17 项通过 |
| ArkTS 安装任务状态 | 16 项通过 |
| ArkTS 本地目录/更新 | 11 项通过 |
| Python 服务端 | 28 项通过（新增 5 项） |
| C++ HAP 核心 | 17 项通过 |
| Rust | 2 项通过 |
| ArkTS + arm64 原生库 + HAP 构建 | 通过，官方 `hap-sign-tool` 验签 `verify-app success` |

其中一条端到端用例走完整链路：下拉 → 对账写入设备版本 → 算出只有 id=1 落后 →
点名只传 `[1]`。

**线上实测**（服务端已部署）：`POST /apps/refresh-stale` 带 `{"app_ids":[1]}` 返回
HTTP 200、12.5 秒、`refreshed: [(1, 'thx853068675-dev/quietstart')]`。

**未实机复验**：客户端改动未在设备上确认（设备当时不可用）。
