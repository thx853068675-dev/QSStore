# 轻启·安装器原生客户端（0.4.5）

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

HAP 清单和签名块读取器主机测试：`python3 tests/test_hap_core.py`。签名模块位于 `rust_signer/`，使用锁定至提交 `519783fd0002603bf518ff8f96a757517fccc00d` 的 [MIT 许可 hapsigner 源码](https://github.com/harmony-contrib/hapsigner-rs)。HDC 位于 `hdc_transport/`，从 [MIT 许可 Muka Rust HDC](https://github.com/Attect/muka_rust_hdc) 提取并改为进程内 TCP 主机，许可说明见 `hdc_transport/README.md`。两者均静态链接进入 `libhap_core.so`。构建机需安装 Rust 1.85+、上述 target 与 DevEco SDK；私钥、证书及 Profile 始终在工作区外或应用沙箱内。`signHap` 与 `hdcCommand` NAPI 在后台线程执行。

当前构建使用独立的 `com.tonghongxiang.hapstore.nativepreview` 包名（仅包名保留了 preview 字样）。设备安装需要与包名、目标设备和已有证书匹配的 AGC 调试 Profile；在工作区外准备材料后，可用 `python3 tools/sign_preview.py --input <unsigned.hap> --profile <profile.p7b> --cert <cert.cer> --key <key.pem> --output <signed.hap>` 签名并用官方工具验签。密码默认 `123456`，可用 `QINGQI_SIGN_PASSWORD` 覆盖。正式包名候选可运行 `python3 tools/build_formal_candidate.py --profile <old-formal-profile.p7b> --cert <cert.cer> --key <key.pem> --output <signed.hap>`；该脚本在构建后恢复原来的 `app.json5`。两条路径都不会申请证书槽位，也不会把签名材料复制进仓库。

本地导入的 HAP 会从包内读应用图标（`readHapIcon`，走同一套 ZIP 边界检查），管理页可「同步卸载」把设备上已卸载的记录清掉，详情页头部底色由图标主色调推导（`theme/ColorTint.ets`）。安装阶段会显示成一句话进度，不再只有「继续中…」。

HarmonyOS 6.1 的页面、下载、本地导入、源码 HDC 安装、端口变化续接、自更新及正式包名首次安装结果见 [实机记录](../docs/NATIVE-DEVICE-VERIFICATION-20260928.md)。正式切换仍需带真实旧数据的沙箱覆盖迁移回归。迁移门槛见 [重构方案](../docs/NATIVE-REBUILD.md)。
