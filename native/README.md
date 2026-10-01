# 轻启·安装器原生工程（0.4.49）

当前客户端使用 ArkTS/ArkUI 与鸿蒙 HDS 材质。Rust 签名器和 HDC 通过 C++ NAPI 静态链接到 `libhap_core.so`；不包含 Flutter 或旧 Go signer。商店数据、评论和上架依赖元数据服务器，下载包直接来自 GitHub 或镜像。

## 包名与构建

工程配置保留独立开发包名 `com.tonghongxiang.hapstore.nativepreview`。发布脚本临时改为正式包名 `com.tonghongxiang.hapstore`，构建无签名 HAP，完成后恢复配置；正式与独立开发沙箱不会自动共享账号数据。

```sh
# 在 native/ 下准备依赖
 ohpm install
 rustup target add aarch64-unknown-linux-ohos
# 在仓库根目录执行
python3 native/tools/build_unsigned_formal.py --output /tmp/qingqi-installer-0.4.49-unsigned.hap
python3 tools/check_local.py --offline --build --output /tmp/qingqi-check
```

DevEco 默认路径为 `/Applications/DevEco-Studio.app`。构建脚本设置 SDK、JBR 和 Node 路径，并清理 Hvigor 缓存，避免 Rust 改动后复用陈旧静态库。主机测试通过 `QINGQI_TYPESCRIPT` 支持其它 TypeScript 安装位置。

开发时也可用 Hvigor `assembleHap -p product=default -p buildMode=debug --no-daemon` 构建独立包。需要实机运行时，用工作区外的证书、私钥和 Profile 调用 `tools/sign_preview.py`；这些工具不申请证书、不向仓库复制签名材料。密码默认 `123456`，可通过 `QINGQI_SIGN_PASSWORD` 覆盖。

## 安装生命周期

- `InstallCoordinator` 持有进程级 FIFO，页面仅提交、展示或恢复任务。启动恢复与账号读取在执行器中进行，隐藏页面不再持有队列。
- `WirelessDebugLifecycle` 在后台无任务时释放无线调试，前台静默恢复已配对端口；执行、扫描和连接共享忙碌保护，快速前后台切换使用世代标记取消过期结果。端口变化后仅在需要安装或用户主动识别时请求重新连接。
- `JobScheduler` 对所有任务串行执行，并按任务 ID 去重。超时或取消可以结束界面等待，但执行锁和后台任务持续到真实调用退出；等待中的任务取消后不能重新启动。
- `JobStore` 持久化阶段、源地址、实际文件摘要、证书 ID、设备授权和用户确认的已安装身份。取消与缓存回收先记清理日志，再删除引用，重启继续清理。
- `AssetDownload` 接管系统代理的后台任务。HTTP 成功仍须解析实际包名和版本；错误内容尝试下一来源。下载最后一次网络失败保留断点。在线安装不强制匹配目录 SHA，实际摘要仍用于本机缓存恢复。
- `PackageArchive` 检查 HAP、APP 和 ZIP 的路径、数量、展开大小及模块身份。APP 预览、图标与权限读取复用已解出的模块；文件变化会失效，缓存最多保留两个 APP，合计 512 MB（更大的单包独占）。导入、解压与签名前检查可用存储。
- `NativeJobRuntime` 核对授权、签名与设备安装结果。可复用旧应用证书时直接覆盖；经用户确认的普通应用重装先传完整包并校验，再次核对旧应用身份，然后卸载并安装。自更新使用已有设备端独立替换路径，并预先备份签名身份。
- `InstallReconnect` 与 `InstallConfirmation` 把连接、清除数据确认交给当前可见页面。账号、设备条件恢复只唤醒对应暂停任务，清除数据需要用户明确确认。

系统后台执行仍由系统授权和调度；真实安装阶段不提供系统没有返回的虚假百分比。冷启动恢复核实实际文件和已安装版本，数据库阶段本身不是安装成功的证据。

## 缓存与错误

已完成任务的原包、签名包保留最多 24 小时或合计 512 MB；历史安装身份继续保留。缓存删除保护仍被未完成任务引用的文件。预览文件超过 24 小时在启动时清理；用户源文件、证书与私钥不属于清理范围。

`AccountService` 合并同一账号的并发刷新，五分钟内复用校验结果，刷新迟到时不会恢复已退出账号。AGC 和商店 HTTP 401 只静默刷新一次；登录过期、权限不足、限流与网络错误分别保留状态和提示。

## 验证和依赖来源

本轮仅本地验证，结果和限制见 [本轮报告](../docs/LOCAL-OPTIMIZATION-20261001.md)。过去的设备证据独立保留在 [0.4.49 发行记录](../docs/RELEASE-0.4.49.md)与[实机报告](../docs/NATIVE-DEVICE-VERIFICATION-20260928.md)，不代表本轮修改已经过真机。

签名器依赖锁定提交 `519783fd0002603bf518ff8f96a757517fccc00d` 的 [hapsigner-rs](https://github.com/harmony-contrib/hapsigner-rs)。HDC 从 [Muka Rust HDC](https://github.com/Attect/muka_rust_hdc) 提取并改为进程内 TCP 主机。两者许可为 MIT，来源说明见 `hdc_transport/README.md`。Rust 构建由 Cargo 跟踪依赖，Hvigor 发布脚本负责确保进入原生构建。
