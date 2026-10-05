# 轻启·安装器原生工程

ArkTS/ArkUI 客户端，Rust 签名器与 HDC 静态链接到 NAPI。元数据、上架和评论由 `server/` 提供；安装包直接下载到设备。

```sh
cd native && ohpm install && cd ..
rustup target add aarch64-unknown-linux-ohos
python3 native/tools/build_unsigned_formal.py --output /tmp/qingqi-installer-unsigned.hap
python3 tools/check_local.py --offline --build --output /tmp/qingqi-check
```

需要 DevEco SDK、Rust、Node、Python。发布默认使用 release，`--build-mode debug` 用于诊断。无签名包交由设备侧签装；`build_formal_candidate.py` 可用工作区外的签名材料生成设备测试包。私钥、Profile、产物和验证资料不提交到源码仓库。

工程保留独立开发包名；发布脚本临时使用正式包名并在结束时恢复。保留账号、私钥、Profile 和安装记录的旧版迁移逻辑。

依赖：[hapsigner-rs](https://github.com/harmony-contrib/hapsigner-rs) 固定提交见 `rust_signer/Cargo.toml`；[Muka Rust HDC](https://github.com/Attect/muka_rust_hdc) 来源与许可见 `hdc_transport/README.md`；解压依赖见 `third_party/archive/NOTICE.md`。
