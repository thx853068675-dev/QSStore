# 轻启·安装器原生客户端（0.4.49）

0.4.49 的公开制品为正式包名的无签名 HAP，由侧载工具为用户自己的设备签名。
构建命令为 `python3 tools/build_unsigned_formal.py --output <unsigned.hap> --version-code 2026100109 --version-name 0.4.49`；脚本清理 Hvigor 缓存、触发 Rust 增量检查，并递归检查产物及内嵌包没有签名。
0.4.49 将 APP/ZIP 本地预览安装、多包上架、后台安装保护与沉浸界面优化纳入正式版。验证范围见 [49 发行说明](../docs/RELEASE-0.4.49.md)。

0.4.48 修复管理页修改分类后的旧卡片缓存，并让发现页的百星、千星、万星卡片各自绘制星点和分级背景。服务端采集优先解析 HAP 启动 Ability 的图标，避免把 AppScope 模板图当成应用图标。构建码 2026093015 让发现页和管理页的安装、更新入口统一入队，管理页按顺序展示并安装，修复全局忙碌状态导致其他卡片按钮无法点击的问题。
6.1 手机运行相同 ARM 签名库的两层签名及安装验证见 [47 验证记录](../docs/RELEASE-47-INNER-SIGNING-20260930.md)。
同一构建码的替换包还修复当前版本显示：管理页读取系统当前版本名，在线安装保存 HAP 实际版本名，旧安装历史不再用于展示当前版本。服务端上架检查改为每个已验证账号每分钟三次并复用五分钟内的同仓库结果。验证范围和真机阻断见 [48 修复记录](../docs/RELEASE-48-VERSION-AND-SUBMIT-20260930.md)。
2026-10-01 的 48 替换构建 `2026100101` 补齐深色导航、选择框及实时主题刷新；首次无安装状态缓存且系统查询不可用时引导识别本机应用。6.1 真机页面检查及 170 项客户端测试结果见 [深色与首轮识别验证](../docs/RELEASE-48-DARK-AND-FIRST-SCAN-20261001.md)。
最新替换构建 `2026100107` 缩短刷新等待，增加华为与导航相同 HDS 浮动材质的悬浮吸顶搜索、透明系统栏、大圆环中央两字显示阶段与真实下载、传包进度，千星卡使用无描边光晕、简化历史版本入口，并让连接弹窗随当前页面展示。详情头部并排显示版本与分类，大小接在上架人之后；标题按钮切换正式版和预览版。端口居中并回填，本地 HAP 先预览，点击安装才入队。减少重复 UDID 与 AGC 设备登记查询，并缩短安装确认轮询的起始间隔。首次安装自动复用或申请调试证书，无需用户提前获取。详情安装按钮使用原生平滑进度与底边细流光，去掉扫光色块。222 项客户端及 9 项 HDC 测试和实机范围见 [刷新与进度验证](../docs/RELEASE-48-REFRESH-PROGRESS-20261001.md)。

这是与现有 Flutter 客户端并存的 ArkTS/ArkUI 工程。系统 HdsTabs、商店列表/详情/历史版本、账号登录、上架、评论、已发布应用管理、可恢复下载、本地 HAP 导入、原生签名及设备安装已接入。签名核心和 HDC TCP 主机均以 Rust 源码静态链接进 `libhap_core.so`；HAP 中没有 Flutter、旧 Go signer 或 `libhdc_z.so`。安装任务在 RDB 中保留阶段和校验信息，签名或安装需要设备时才检查无线调试，并可在端口变化后重新连接继续。

应用名与「关于」里的文案都不再带「预览」字样（0.4.5）；包名仍是独立包名，因为改包名需要匹配的 AGC Profile，会丢掉现有安装。6.1 实机已验证本地 HAP 签名安装、设备端安装版本核对、无线调试端口变化后续接，以及 0.4.0→0.4.1→0.4.2 应用内自更新和重启后自动认领安装任务。另构建了旧正式包名的原生候选包，6.1 首次安装与启动通过；旧正式包在这轮验证前已不在设备上，因此旧沙箱数据覆盖迁移仍待验收。

构建：

```sh
cd native
ohpm install
rustup target add aarch64-unknown-linux-ohos
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。

HAP 清单和签名块读取器主机测试：`python3 tests/test_hap_core.py`。签名模块位于 `rust_signer/`，使用锁定至提交 `519783fd0002603bf518ff8f96a757517fccc00d` 的 [MIT 许可 hapsigner 源码](https://github.com/harmony-contrib/hapsigner-rs)。轻启 HAP 会先重签内嵌工作模块、更新摘要清单，再重签主包；其他 HAP 走普通单包签名。HDC 位于 `hdc_transport/`，从 [MIT 许可 Muka Rust HDC](https://github.com/Attect/muka_rust_hdc) 提取并改为进程内 TCP 主机，许可说明见 `hdc_transport/README.md`。两者均静态链接进入 `libhap_core.so`。构建机需安装 Rust 1.85+、上述 target 与 DevEco SDK；私钥、证书及 Profile 始终在工作区外或应用沙箱内。`signHap` 与 `hdcCommand` NAPI 在后台线程执行。

当前构建使用独立的 `com.tonghongxiang.hapstore.nativepreview` 包名（仅包名保留了 preview 字样）。设备安装需要与包名、目标设备和已有证书匹配的 AGC 调试 Profile；在工作区外准备材料后，可用 `python3 tools/sign_preview.py --input <unsigned.hap> --profile <profile.p7b> --cert <cert.cer> --key <key.pem> --output <signed.hap>` 签名并用官方工具验签。密码默认 `123456`，可用 `QINGQI_SIGN_PASSWORD` 覆盖。正式包名候选可运行 `python3 tools/build_formal_candidate.py --profile <old-formal-profile.p7b> --cert <cert.cer> --key <key.pem> --output <signed.hap>`；该脚本在构建后恢复原来的 `app.json5`。两条路径都不会申请证书槽位，也不会把签名材料复制进仓库。

本地导入的 HAP 会从包内读应用图标（`readHapIcon`，走同一套 ZIP 边界检查），管理页可「同步卸载」把设备上已卸载的记录清掉，详情页头部底色由图标主色调推导（`theme/ColorTint.ets`）。安装阶段会显示成一句话进度，不再只有「继续中…」。

HarmonyOS 6.1 的页面、下载、本地导入、源码 HDC 安装、端口变化续接、自更新及正式包名首次安装结果见 [实机记录](../docs/NATIVE-DEVICE-VERIFICATION-20260928.md)。正式切换仍需带真实旧数据的沙箱覆盖迁移回归。迁移门槛见 [重构方案](../docs/NATIVE-REBUILD.md)。


### 恢复与构建回归

在仓库根目录运行 `node --test native/tests/test_recovery.cjs`，通过 SDK 适配器执行实际
ArkTS 服务类，覆盖过期恢复、备份冲突、证书删除保护和任务超时互斥。测试默认使用
DevEco 自带 TypeScript，可用 `QINGQI_TYPESCRIPT` 指定其它安装位置。

CMake 每次 native build 都调用 Cargo 的增量检查，由 Cargo 跟踪签名器、HDC、
协议 crate 和构建脚本的依赖；不再维护不完整的 Rust 文件清单。
