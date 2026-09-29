# 服务器重置与加固报告

> 目标机：`47.98.250.230`（阿里云 ECS · Ubuntu 24.04.4 LTS · 1 vCPU / 1.6 GB RAM / 40 GB）
> 主机名：`iZbp1gujoifp6zdmkh6wd9Z` · 时区 Asia/Shanghai（已 NTP 同步）
> 执行时间：2026-09-26 · 执行方式：全程 SSH，可回退

---

## 一、执行摘要

| 指标 | 加固前 | 加固后 |
|---|---|---|
| **可用内存** | 699 MB | **1236 MB**（+537 MB） |
| **磁盘占用** | 16 G / 43% | **14 G / 36%** |
| **入站防火墙** | 无（全部端口裸奔） | **UFW 默认拒绝**，仅放行 22/80/443 |
| **SSH 认证** | `root` + **密码**登录，零公钥 | **仅密钥**，密码通道彻底关闭 |
| **爆破防护** | 无（已累计 25 次失败尝试） | **nftables 封禁**，实测生效 |
| **无用常驻服务** | ModemManager / fwupd / multipathd | 全部 stop + disable + mask |
| **内核加固** | 默认 | 21 项安全参数已应用 |

**一句话**：从「公网裸奔 + 密码可爆破 + 开放代理」的状态，收敛为「默认拒绝 + 仅密钥 + 自动封禁」的可用基线。

---

## 二、风险盘点（加固前实测）

| 项目 | 实测状态 | 等级 |
|---|---|---|
| UFW 防火墙 | `Status: inactive` | 🔴 高 |
| fail2ban | 未安装 | 🔴 高 |
| SSH | `PermitRootLogin yes` + `PasswordAuthentication yes`，`authorized_keys` 0 字节 | 🔴 高 |
| 爆破痕迹 | auth.log 累计 **25 次** `Failed password`，主要来源 `43.106.63.33`（20 次） | 🟠 中 |
| **7890/TCP** | **privoxy 正向代理监听 `0.0.0.0`，无认证** | ⚫ **极高** |
| 80/TCP | nginx → LobeChat，公网可达 | 🟠 中 |
| 无用服务 | ModemManager / fwupd / multipathd 常驻，占用约 100 MB | 🟡 低 |
| 已在运行的容器 | `lobe-chat`（lobehub/lobe-chat:latest，restart=always，占约 492 MB） | — |

---

## 三、已执行动作

### 3.1 备份（全部可回退）

```
/root/ts-pre-hardening/20260926-193647/          # 配置快照
    ├── _etc_ssh_sshd_config
    ├── _etc_nginx_sites-enabled_default
    ├── _etc_privoxy_config
    ├── _etc_shadowsocks.json
    ├── _etc_apt_sources.list
    ├── sshd_config.d/
    ├── enabled-units.txt                        # 加固前所有自启服务
    ├── listening.txt                            # 加固前监听端口
    └── docker.txt                               # 加固前容器清单
/root/ts-pre-hardening/20260926-194238-sshd/     # SSH 专项备份
```

### 3.2 服务重置

| 动作 | 说明 |
|---|---|
| **LobeChat 停用** | `restart=no` + `stop`。**镜像与 `/root/lobehub-db` 数据完整保留** |
| 恢复命令 | `docker start lobe-chat`（需同时恢复 80 端口反代） |
| apt 缓存清理 | `apt-get clean` |
| journal 限容 | 限制 200 MB |
| 旧日志清理 | 删除 `*.gz` 与轮转文件、清空 `btmp` |
| 临时目录 | 清空 `/tmp`、`/var/tmp` |
| Docker 清理 | `container prune` |

### 3.3 暴力破解防护（零依赖自研）

**背景**：该机出站 80/443 的应用层数据被阿里云侧丢弃（详见第五章），**无法 `apt install fail2ban`**。因此用系统自带的 `nft` + `python3` 自建了等效实现。

```
nft 表 inet ts_guard
  └── set banned (ipv4_addr, flags timeout)      ← 封禁名单，内核按 TTL 自动过期
  └── chain input (hook input, priority -150)    ← ip saddr @banned counter drop
```

| 组件 | 路径 / 名称 | 作用 |
|---|---|---|
| 守护脚本 | `/usr/local/sbin/ts-guard.py` | 解析 `auth.log` 最近 600 秒，同 IP 失败 ≥5 次即封禁 1 小时 |
| 定时器 | `ts-guard.timer` | 每 60 秒执行一次（`enabled` + `active`） |
| 开机恢复 | `ts-firewall-restore.service` | 重建 nft 表与 drop 规则（`enabled`） |
| 日志 | `/var/log/ts-guard.log` | 记录每次封禁 |

**设计要点**：
- 封禁表是**独立的 nft 表**（`inet ts_guard`），不挂在 ufw 链上 → **`ufw reload` 不会被冲掉**（这是前两版实现的踩坑点）
- 优先级 `-150` 高于 ufw 的 `filter`(0)，被封 IP 在任何规则之前就被丢弃
- 私网/回环永不封禁，避免自锁
- 任何异常静默退出，绝不阻塞系统

**端到端实测记录**：

| 步骤 | 结果 |
|---|---|
| 将本机 IP `139.226.99.179` 加入封禁集 | ✅ 成功写入，`timeout 30s` |
| 从本机 SSH 连接 | ✅ `Connection closed by 47.98.250.230 port 22`（5 秒内被拒） |
| 从本机访问 80 端口 | ✅ `http_code=000`（同时被阻断） |
| 查看 drop 规则计数 | ✅ `packets 50 bytes 4704 drop`（确实在丢包） |
| 等待 30 秒 TTL 到期 | ✅ 元素自动消失，无需人工干预 |
| 再次 SSH | ✅ `RECOVERED_OK`（自动解封） |

### 3.4 UFW 防火墙

```
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)

22/tcp   ALLOW   Anywhere    # SSH
80/tcp   ALLOW   Anywhere    # HTTP
443/tcp  ALLOW   Anywhere    # HTTPS
（IPv6 同步）
```

**关键处理：Docker 绕过问题**
Docker 会直接操作 iptables、绕过 UFW 的 INPUT 链。已在 `/etc/ufw/after.rules` 写入 `DOCKER-USER` 兜底（放行 RFC1918 内网，其余 `DROP`），实测生效（1 条 DROP）。**这样即使将来再起容器，也不会意外暴露端口。**

### 3.5 SSH 加固

配置文件：`/etc/ssh/sshd_config.d/99-ts-hardening.conf`

| 参数 | 值 | 说明 |
|---|---|---|
| `PasswordAuthentication` | **no** | 密码通道彻底关闭 |
| `KbdInteractiveAuthentication` | no | 关闭键盘交互式认证 |
| `PermitRootLogin` | prohibit-password | root 仅限密钥 |
| `PubkeyAuthentication` | yes | 启用公钥 |
| `MaxAuthTries` | 4 | 降低爆破容忍 |
| `LoginGraceTime` | 30 | 缩短挂起窗口 |
| `X11Forwarding` / `AllowAgentForwarding` / `AllowTcpForwarding` / `PermitTunnel` | no | 精简攻击面 |
| `AllowUsers` | root | 白名单 |

**验证结果**：
- 密钥登录 → ✅ `KEY_LOGIN_OK`
- 密码登录 → ✅ `root@47.98.250.230: Permission denied (publickey).`
- 强制密码认证 → ✅ `Permission denied (publickey).`

### 3.6 内核与网络加固

文件：`/etc/sysctl.d/99-ts-hardening.conf`

| 类别 | 参数（已复验生效） |
|---|---|
| 网络 | `tcp_syncookies=1`、`rp_filter=1`、`accept_redirects=0`、`accept_source_route=0`、`log_martians=1`、`icmp_echo_ignore_broadcasts=1`、`tcp_rfc1337=1` |
| 内核信息保护 | `dmesg_restrict=1`、`kptr_restrict=2`、`sysrq=0` |
| 文件系统 | `protected_hardlinks=1`、`protected_symlinks=1`、`suid_dumpable=0` |
| Docker 兼容 | `ip_forward=1`（保留） |

### 3.7 自动安全更新

`unattended-upgrades` 已启用（`Update-Package-Lists=1`、`Unattended-Upgrade=1`、`AutocleanInterval=7`），且**配置为不自动重启**，避免中断服务。
> ⚠️ 当前出站被封，apt 无法拉取更新；出站恢复后自动生效。

---

## 四、加固后状态

### 4.1 资源

```
内存: used=376MB  total=1612MB  avail=1236MB      （加固前 used=913MB avail=699MB）
磁盘: used=14G    total=40G     avail=24G   (36%) （加固前 16G / 43%）
负载: 0.07 0.09 0.04
```

### 4.2 监听端口（全部已收敛）

| 端口 | 进程 | 暴露面 | 状态 |
|---|---|---|---|
| 22 | sshd | 公网 | ✅ 仅密钥 |
| 80 | nginx | 公网 | ✅ 受 UFW 管控 |
| 443 | — | 公网 | ✅ 已放行，待 M1 部署 TLS |
| **7890** | **privoxy** | **公网** | ⚠️ **按你要求暂不动，见 6.1** |
| 1080 | ss-local | 仅 localhost | ✅ 安全 |
| 53 | systemd-resolve | 仅 localhost | ✅ 安全 |

### 4.3 加固后仍存在的定时任务（已审计，无可疑项）

`ts-guard`（自建）、`sysstat-collect`、`fwupd-refresh`、`dpkg-db-backup`、`logrotate`、`privoxy-cleanup`、`sysstat-summary`、`e2scrub_all`
- root crontab：**0 条**
- `/etc/cron.d`：`e2scrub_all`、`sysstat`（均为系统自带）

### 4.4 入侵排查结论

- 无可登录的非 root 账号（uid≥1000 且具 shell 的账号：**0 个**）
- root crontab 为空，无可疑计划任务
- 无可疑进程监听公网端口
- 爆破尝试（25 次）**全部失败**，无成功入侵迹象
- 唯一异常是 7890 开放代理（配置疏忽，非入侵）

---

## 五、关键发现：出站网络异常（**需要你操作**）

### 5.1 现象

| 测试 | 结果 |
|---|---|
| `ping 223.5.5.5` | ✅ 通（1.4ms） |
| TCP 握手 `223.5.5.5:80` / `:443` / `api.github.com:443` | ✅ **全部 OPEN** |
| HTTP 实际拉取（baidu / aliyun / npmmirror / qq / github） | ❌ **全部超时，0 字节** |
| 阿里云元数据服务 `100.100.100.200` | ✅ 正常（0.004s） |
| 不分片 ping 1472 字节（MTU 测试） | ✅ 通（MTU 1500 正常） |
| 本机 iptables OUTPUT 链 | ✅ `policy ACCEPT`，0 包被拦 |

### 5.2 结论

**TCP 三次握手能完成（很可能被中间设备代答），但应用层数据被丢弃。** 已排除以下原因：
- ❌ 本机防火墙（OUTPUT 全 ACCEPT，无规则）
- ❌ MTU / MSS 问题（1500 全通，clamp 后无改善）
- ❌ DNS 问题（解析正常）
- ❌ 网卡 offload 问题（关闭后无改善）

→ **判定为阿里云侧（安全组出方向规则 或 云防火墙）的应用层拦截。**

### 5.3 需要你操作

请在 **阿里云控制台** 依次检查：

1. **ECS → 安全组 → 出方向规则**
   - 确认存在：协议 `全部`（或 TCP），端口范围 `1/65535`（或 80/443），授权对象 `0.0.0.0/0`，策略 **允许**
2. **云防火墙 → 出方向策略**
   - 检查是否有针对 `0.0.0.0/0` 的阻断规则
3. **若使用 NAT 网关 / 共享带宽**，检查是否有策略限制

### 5.4 恢复后的验证命令

```bash
# 一行验证（在服务器执行）
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://api.github.com/rate_limit
# 期望输出：200
```

同时 apt 也会恢复可用，届时可补装 fail2ban 作为额外一层（当前自研方案已满足需求，非必需）：
```bash
apt-get update && apt-get install -y fail2ban
```

> **出站放行前，项目不受影响**：采集器会自动降级走镜像链（`gh-proxy.com` 已实测可用），商店浏览与下载始终正常。详见设计文档 §8.2。

---

## 六、遗留事项与运维须知

### 6.1 ⚠️ 7890 开放代理（你选择暂不处理）

**现状**：`privoxy` 监听 `0.0.0.0:7890`，无认证；上游 `ss-local`（`1.170.211.59:36324`）已失效——实测**连百度都超时**。

**风险**：
- 公网任何扫描器都能发现并使用它
- 可能被用作跳板，导致 IP 被列入黑名单
- 阿里云可能因异常流量告警

**一键收紧**（随时可执行，不影响其他服务）：
```bash
sed -i 's/^listen-address .*/listen-address 127.0.0.1:7890/' /etc/privoxy/config
systemctl restart privoxy
```

### 6.2 🔑 登录方式已变更（**请立即备份私钥**）

```bash
ssh -i ~/.ssh/ts_hapstore_ed25519 root@47.98.250.230
```

- ✅ 私钥位置：本机 `~/.ssh/ts_hapstore_ed25519`
- ❌ 原密码 `thx@765256` **已不能再用于 SSH**
- ⚠️ **请把私钥复制到密码管理器或离线介质**——丢失后只能通过阿里云控制台 VNC 救援
- 建议在 `~/.ssh/config` 中添加别名：

```
Host hapstore
    HostName 47.98.250.230
    User root
    IdentityFile ~/.ssh/ts_hapstore_ed25519
    ServerAliveInterval 60
```

### 6.3 回退方式

```bash
# 回退 SSH（重新允许密码登录）
cp /root/ts-pre-hardening/20260926-194238-sshd/sshd_config /etc/ssh/
rm -f /etc/ssh/sshd_config.d/99-ts-hardening.conf
systemctl reload ssh

# 回退防火墙
ufw disable

# 回退封禁
systemctl disable --now ts-guard.timer ts-firewall-restore.service
nft delete table inet ts_guard

# 恢复 LobeChat
docker start lobe-chat
```

### 6.4 日常巡检建议

| 频率 | 命令 | 关注点 |
|---|---|---|
| 每日 | `tail -20 /var/log/ts-guard.log` | 是否有新封禁 |
| 每日 | `nft list set inet ts_guard banned` | 当前封禁名单 |
| 每周 | `free -m; df -h /` | 资源余量 |
| 每周 | `journalctl -p err --since "7 days ago" \| tail -30` | 系统错误 |
| 每月 | `ss -tulnp` | 是否有意外新增监听端口 |
| 每月 | `systemctl list-timers --all` | 是否有意外新增定时任务 |

---

## 七、执行脚本清单（可复用）

全部脚本已保存在工作区 `tools/` 目录，可用于其他服务器：

| 脚本 | 用途 |
|---|---|
| [`harden-phase1.sh`](../tools/harden-phase1.sh) | 备份配置 + 安装管理公钥 |
| [`harden-phase2b.sh`](../tools/harden-phase2b.sh) | 服务重置 + UFW + 内核加固 + 清理 |
| [`harden-phase3-ssh.sh`](../tools/harden-phase3-ssh.sh) | SSH 关闭密码登录 |
| [`harden-guard-final.sh`](../tools/harden-guard-final.sh) | nftables 封禁系统（零依赖 fail2ban 等效） |
| [`verify-hardening.sh`](../tools/verify-hardening.sh) | 9 大项加固复验 |
| [`sshx.exp`](../tools/sshx.exp) / [`scpx.exp`](../tools/scpx.exp) | 密码时代的 SSH/scp 辅助（现已被密钥取代） |

---

## 八、复盘：本阶段踩过的坑

记录下来，避免在 M1 部署时重犯：

| # | 坑 | 教训 |
|---|---|---|
| 1 | 用 `pkill -f "apt-get"` 清理卡死进程，结果**模式匹配到 sshd 自身命令行，把会话杀了** | 杀进程时避免用会匹配到自身命令行的宽泛模式 |
| 2 | 探测脚本写错，`command -v` 判断逻辑反了，把**所有工具都报告为"OK"**，实际 `ipset` 根本没装 | 探测类脚本必须输出实际路径，不能只输出布尔值 |
| 3 | 把 `-m set --match-set` 规则写进 `ufw-before.rules`，但系统**没有 ipset**，规则静默失效 | 加固前先确认依赖真实存在 |
| 4 | 封禁规则排在 `ufw-user-input` **之后**，而 22 端口在那里已被 ACCEPT → 规则永不生效 | iptables 规则顺序即优先级，必须放在 ACCEPT 之前 |
| 5 | `ufw reload` 会**冲掉挂在 ufw 链上的自定义规则** | 自定义封禁必须放**独立 nft 表**，不要寄生在 ufw 链上 |
| 6 | 停用服务时用了 `systemctl list-unit-files \| grep -q "^${s}\.service"`，匹配失败导致静默跳过 | 停用后用 `is-enabled` 复验，别信"执行过了" |
| 7 | `ufw --force enable` 之后 `ufw.conf` 仍显示 `ENABLED=no`，后续 `reload` 被跳过 | 启用后必须读回 `ufw.conf` 确认持久化 |

---

## 九、⚠️ 后续发现的严重缺陷：UFW 规则集从未真正加载

> 这是 M1 部署元数据服务时才暴露出来的，属于**必须记录**的问题。

### 9.1 现象

元数据服务部署后，从服务器**本机**访问 `127.0.0.1:8787` **超时**。
进一步做 A/B 对照：连一个最简的 `http.server` 在 loopback 上也连不通 —— 说明不是应用问题。

### 9.2 根因

对比内核与文件中的规则数：

```
内核 nft chain ip filter ufw-before-input :  1 条规则（只有 jump ufw-user-input）
文件 /etc/ufw/before.rules                : 12 条规则
```

**内核里缺失了 `before.rules` 的全部内容**，包括：

- `-A ufw-before-input -i lo -j ACCEPT`（允许 loopback）
- `-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`（允许已建立连接）
- 以及 ICMP、DHCP、组播等全部基础放行规则

**为什么之前没发现**：我在启用阶段只验证了 22/80/443 —— 而这三个端口恰好都有显式的 `ufw-user-input` ACCEPT 规则，或（nginx）绑在 `0.0.0.0` 上。**所有 loopback 流量其实一直被丢弃。**

### 9.3 触发条件

`ufw reload` 在防火墙**首次 enable 之前**会被静默跳过（日志：`Firewall not enabled (skipping reload)`）。
当时 `ufw.conf` 里是 `ENABLED=no`，于是 `before.rules` 从未被载入内核。

### 9.4 修复与验证

```bash
ufw disable && ufw --force enable     # 强制完整加载
```

修复后：

```
内核规则数: 1 → 13
含 iifname "lo" accept ✅
含 ct state related,established accept ✅
loopback 连接测试: 200 ✅
API 直连 200 / 经 nginx 200 ✅
SSH 仍可用 ✅
```

### 9.5 教训

| 教训 | 说明 |
|---|---|
| **加固后必须对比「内核规则」与「文件规则」** | 只看 `ufw status` 会误判；要 `nft list chain ip filter ufw-before-input` 与 `grep -c '^-A ufw-before-input' /etc/ufw/before.rules` 对照 |
| **不能只测「我关心的端口」** | 22/80/443 通不代表规则集正确；应测 loopback 与 conntrack |
| **`ufw reload` 不是可靠的加载手段** | 首次启用必须显式 enable；变更后应验证内核状态 |
| 服务绑定 `127.0.0.1` 时**尤其危险** | 反代架构（nginx → 127.0.0.1:8787）会被这类缺陷完全打断 |

### 9.6 对既有结论的影响

本文第三章「已执行的加固动作」与第四章「加固后状态」中关于 UFW 的描述，在修复前是**不完整**的：
文件层面配置正确，但内核层面直到本次修复才真正生效。**现已修复并复验。**
