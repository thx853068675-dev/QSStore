# 原生分支审查与待办交接

对 `codex/native-arkts-rebuild`（审查基线 `4884b10`）的一轮代码审查，共 8 项问题。
本文件记录逐项状态与后续工作所需的上下文，供接续开发使用。

> **2026-09-29 更新**：8 项全部处理完毕（`1c49cf1` → `a61ddd0`）。
> 服务端已部署（`reviews` 的 `total`、列表的 `latest_asset` 都已上线）；
> 客户端已在实机 `hdc -t 3BH0224320005595` 上装包验证。

## 实机验证怎么做（别再踩一遍）

```sh
D=3BH0224320005595
# 1) 构建同包名候选包（设备上装的是正式包名 com.tonghongxiang.hapstore）
cd native
P=/Users/tonghongxiang/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3
$P tools/build_formal_candidate.py \
  --profile ~/Documents/hap_installer/store/com_tonghongxiang_hapstore.p7b \
  --cert ~/Documents/hap_installer/store/hapstore-debug.cer \
  --key  ~/Documents/hap_installer/store/key.pem --output /tmp/q.hap
# 2) 装、起、截图
hdc -t $D install -r /tmp/q.hap
hdc -t $D shell "aa force-stop com.tonghongxiang.hapstore"
hdc -t $D shell "aa start -a EntryAbility -b com.tonghongxiang.hapstore"
hdc -t $D shell "snapshot_display -f /data/local/tmp/s.jpeg"
hdc -t $D file recv /data/local/tmp/s.jpeg /tmp/s.jpeg
```

**点击必须用 `uinput`，不要用 `uitest uiInput`**：

```sh
hdc -t $D shell "uinput -T -c 670 474"   # 可用
hdc -t $D shell "uitest uiInput click 670 474"   # 这个包上完全没反应，别浪费时间
```

截图坐标是物理像素（这台是 1260×2844），与 ArkUI 的 vp 不同，换算约 ×3。
底部导航在 y≈2700：发现 x≈250、本地 x≈420、管理 x≈740、我的 x≈1030。

## 当前状态

- 分支 `codex/native-arkts-rebuild`，HEAD 见 `git log -1`，工作区应为干净
- 本分支已 checkout 在独立 worktree：
  `/Users/tonghongxiang/.codex/worktrees/qingqi-native-rebuild/Tong Store`
  （主工作区的 `Tong Store` 目录停在 `main`，没有 `native/`，别在那边改）
- 构建、签名、实机验证的完整命令见 [../native/README.md](../native/README.md)
- 实机：`hdc -t 3BH0224320005595`（HarmonyOS 6.1，API 24，深色模式已开）

### 构建（一条命令，产出已签名正式包）

```sh
cd native
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export PATH="$NODE_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
python3 tools/build_formal_candidate.py \
  --profile ~/Documents/hap_installer/store/com_tonghongxiang_hapstore.p7b \
  --cert    ~/Documents/hap_installer/store/hapstore-debug.cer \
  --key     ~/Documents/hap_installer/store/key.pem \
  --output  /tmp/out.hap
```

签名材料在仓库外，脚本不会把它们复制进仓库，也不会申请证书槽位。

## 已完成

| # | 问题 | 提交 |
|---|---|---|
| 5 | 401/403 被外层 catch 误加 `TRANSIENT`，失效登录态被当成临时故障继续使用 | `03d5135` |
| 1 | 删「安装任务」区块时把恢复入口一并删掉，中断任务重启后不可见 | `d6f615a` |
| 6 | 更新检查只遍历安装历史，扫描发现的 `storeInstalled` 永远没有更新按钮 | `d6f615a` |
| 7 | 正常下载超过两分钟也被中断 | `1c49cf1` |
| 8 | 列表分页没有真正接通 | `4f987ed` |
| 4 | 同一安装任务可重复执行 | `9c85303` |
| 2 | 新用户无法完成首次签名 | `0ec73bc` |
| 3 | 可以直接删除正在使用的证书 | `a61ddd0` |

`#1` 采用的是紧凑方案：只在确有未完成任务时，于「已安装」上方显示一行
「N 个安装未完成 + 继续」，无任务时完全不占版面。

## 待办

### #8 的部署前置【必须先做】

`#8` 改了服务端 `GET /api/v1/apps/{id}/reviews`，让它与另外两个列表一样返回
`total`。**新客户端依赖这个字段判断「还有没有下一页」**，旧服务端不返回时会被
当成只有一页。所以要先部署服务端，再装新客户端：

```sh
cd "Tong Store"
scp -i ~/.ssh/ts_hapstore_ed25519 -r server/hapstore server/run.py root@47.98.250.230:/opt/hapstore/
ssh -i ~/.ssh/ts_hapstore_ed25519 root@47.98.250.230 'systemctl restart hapstore-api'
```

冒烟：`curl -k "https://47.98.250.230/api/v1/apps/1/reviews?page=1&page_size=5"`
应能看到 `"total": <条数>`。

### 本轮实机已验证（3BH0224320005595，Pura 70 PRO，API 24）

- **目录卡片按钮**：未安装的应用显示「安装」，本机已装的显示「打开」；
  点「安装」后管理页出现「1 个安装未完成 · 轻启」，作业确实入队并下载了
  6.6 MB 的 HAP，随后按设计弹出「连接无线调试」。
- **已装判定改用系统查询**：走 `bundleManager.getBundleInfoSync`，不再依赖
  无线调试；应用第一次绘制就知道自己已经装过了。
- **卡片点击分区**：点右侧按钮不再被整卡的跳转吃掉（之前会直接进详情页）。
- **详情页头部取色**：轻启的图标算出的浅绿底已生效。
- **应用名**：桌面图标下方已显示「轻启·安装器」，不再带「预览」。

### 仍需实机验收的部分

1. **首次签名（`#2`）**：用**没有已配对调试证书的华为账号**登录 → 我的 →
   「准备签名身份」。预期：本机生成 P-256 私钥（`identity.pem`，权限 0600）→
   `cert.generateCsr` 产出 CSR → 复用或申请 AGC 证书 → 卡片显示证书名与到期日。
   这一步用了 `cryptoFramework`（API 12+）与 `cert.generateCsr`（API 18+），
   设备为 API 24，理论上可用；若 `generateCsr` 报错，先在 hilog 里看是
   `19030001`（加密操作失败）还是参数校验失败，`DeviceIdentity.buildCsr` 已按
   「先 PEM 字符串、失败退回 PKCS#8 DER 字节」两条路尝试。
2. **槽位守卫（`#2`/`#3`）**：账号已有 3 张调试证书且都不配对时，「准备签名身份」
   必须拒绝申请；只剩 1 张时第一次点击只提示，按钮变成「占用最后槽位并申请」，
   再点才真的申请。删除任一证书时，若没有别的证书能配上本机私钥，必须拒绝删除。
3. **下载停滞判定（`#7`）**：拉一个较大的包，确认超过 2 分钟仍在继续下载
   （不再切镜像重下），断网 60 秒后确认切换到下一个镜像。
4. **任务互斥（`#4`）**：同一个应用在详情页点安装后，立刻回发现页再点一次，
   第二次应直接提示「该任务已在执行中」，不再出现两遍授权/签名/安装。
5. **本地 HAP 图标与阶段进度（上一轮 #3）**：导入一个本地 HAP，确认管理页
   显示包内图标，且安装过程显示「正在下载安装包 / 正在签名 / 正在安装到设备」
   而不是一直「继续中…」。
6. **同步卸载（上一轮 #4）**：在系统设置里卸载一个轻启装过的应用，回管理页点
   「同步卸载」，该条记录应消失；断网时点它应提示无法核对且**不删任何记录**。

### 结构问题（未动）

- `pages/Index.ets` 已 1800+ 行，混合了页面、证书、账号、更新扫描与任务调度
- 详情页 `pages/Detail.ets` 重复实现了安装与重连流程
- 建议顺序：先抽统一的安装调度、账号状态与证书管理服务，再拆页面组件
  （安装调度的互斥部分已由 `jobs/JobScheduler.ets` 收口，可作为起点）
- 删除安装记录目前只删数据库，原包与签名包长期堆积，需要缓存清理策略

## 本轮复盘：#2 的两条「硬约束」里有一条是错的

原文写「`cert.generateCsr` 在 API 26 才有」。查 SDK 声明，该接口是
**`@since 18`**（`createX500DistinguishedName` 是 `@since 12`），设备为 API 24，
所以完全可用，不需要改签名核心去接受 HUKS 句柄。

真正卡住的只有「密钥必须可导出」这一条：`PrivateKeyInfo.key` 只收密钥数据本身，
HUKS 留在密钥库里的密钥导不出来。解法不是改架构，而是换成
`cryptoFramework.createAsyKeyGenerator('ECC256')` —— 它生成的 P-256 私钥可以
`getEncodedDer('PKCS8')` 导出，正好满足前两者。见 `data/DeviceIdentity.ets`。

另一处要注意：**EC 私钥的 `getEncodedPem` 要 API 26**（PEM 导出只支持 RSA 到
26 才加 EC），所以 PEM 要自己用 `util.Base64Helper` 包，不能调它。

## 本轮新增的踩坑记录

- **`util.Base64Helper` 是实例类**，`encodeToStringSync` / `decodeSync` 都要
  `new util.Base64Helper()`，写成静态调用编译不过
- **`getEncodedDer` 的 format 参数**：私钥 `'PKCS8'`、公钥 `'X509'`（SPKI）
- **`fileIo.openSync` 的 mode 位**：`CREATE` 是 `0o100`、`TRUNC` 是 `0o1000`，
  与 POSIX 的权限位（`0o600`）可以直接按位或，用来把私钥写成仅属主可读
- **`keyMatchesCertificate` 只收文件路径**，没有「字节 + 路径」的重载；
  校验内存里的证书字节要先落一个临时文件
- **`request.agent` 没有 `pause`/`remove` 函数**，只有 `getTask(id)` 返回的
  `Task` 对象上才有 `pause()` / `remove()`；`State` 枚举里是 `WAITING`
  （没有 `PENDING`），活着的状态是 `INITIALIZED/WAITING/RUNNING/RETRYING`
- **`Config.timeout`**：`connectionTimeout` 只约束建连（默认 60 秒），
  `totalTimeout` 默认是 604800 秒。原来那个 120 秒总上限完全来自客户端轮询循环，
  与系统超时无关

## 结构问题

- `pages/Index.ets` 已 1800+ 行，混合了页面、证书、账号、更新扫描与任务调度
- 详情页 `pages/Detail.ets` 重复实现了安装与重连流程
- 建议顺序：先抽统一的安装调度、账号状态与证书管理服务，再拆页面组件
  （安装调度互斥已由 `jobs/JobScheduler.ets` 收口，可作为起点）
- 删除安装记录目前只删数据库，原包与签名包长期堆积，需要缓存清理策略

## 踩过的坑（ArkTS 与工具链）

- **ArkTS 禁用 `Function.apply` / `Function.call`**，回调式确认框要用状态驱动
- **`catch` 到的是 `Object`，不能直接 `throw`**，必须 `throw new Error(String(e))`
- **`Column` 等容器不支持 `fontColor`**，文本样式不会向下继承，需逐个组件设色
- **`Select` 的 `Font` 类型没有 `color` 字段**，文字色要用 `fontColor`，
  另有 `selectedOptionBgColor` / `optionBgColor` / `menuBackgroundColor`
- **`swipeAction` 必须用 `SwipeActionItem` 对象形式**并给 `actionAreaDistance`；
  直接塞 `CustomBuilder` 会让按钮参与布局，把卡片挤窄、文字被截断
- **改代码不要用「从 A 到 B」的区间切片**：`ctx.closePath()` 这类片段会重复出现，
  定位会落到更早的位置（曾因此切坏文件两次）。用唯一的函数边界做锚点，每次
  改完校验括号深度与 `build()` 位置
- **`git push` 到 github 偶发超时**，重试即可
- 构建命令**不要用 `grep` 过滤输出**，失败会被管道退出码掩盖，看起来像成功

## 仓库

| 仓库 | 说明 |
|---|---|
| `thx853068675-dev/starstore-harmonyos` | 私有，完整历史，主工作仓 |
| `thx853068675-dev/QSStore` | 公开，单提交起点，后端地址已替换为占位符 |

公开仓是 0.4.4 的快照，**不含本文件所述的任何修复**。建议 P1 全部清掉后统一
同步并发布 0.4.5，而不是每修一条同步一次。
