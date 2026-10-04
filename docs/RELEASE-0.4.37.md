# 轻启·安装器 0.4.37

## 修复

- 首次获取证书时，不再对 ECC 公钥调用不支持的 `getEncodedDer('X509')`，解决新用户遇到的本机 `fail401`。该公钥指纹此前没有被使用。
- 6.1 实机显示系统 `cert.generateCsr` 对新生成的 EC 私钥报 `generate csr failed`，现由应用已有的 Rust 签名模块从同一把 PKCS#8 私钥生成并签署 PKCS#10 CSR；没有申请第二把密钥或额外占用证书槽位。
- 没有可用证书时，「证书重置」直接进入复用优先的一键获取流程。无请求体的华为登录与 AGC 查询不再传空 `extraData`。

## 验证

- HarmonyOS 6.1 / API 24：隔离预览包仅在本机生成密钥和 CSR，日志 `QINGQI_CSR_PROBE_OK true`。探针未访问 AGC，验证后已卸载。
- Rust CSR 单测验证请求的公钥与私钥相同、签名有效；Rust 3 项、ArkTS/Node 106 项通过。
- 正式 HAP 经官方 SDK `verify-app` 通过，已在设备 `3BH0224320005595` 升级安装并启动，设备报告版本 `0.4.37` / `2026093001`。
- 尚未用其他开发者账号走完整 AGC 发证流程；这需要该账号授权且会占用其证书槽位。本轮未为测试申请证书。

## 制品

- `dist/quietstart-installer-0.4.37-device6.1-signed.hap`
- SHA-256：`b2c62eef9510987fcbe6da90c4a9cc02627cf44bfe5315098393921c526b2544`
