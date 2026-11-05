# 参与改进

1. Fork 本仓库，从 `main` 新建分支，完成修改后向本仓库 `main` 提交 Pull Request。
2. 安装 Node.js 24、Python 3.12、Rust、CMake 和 C++ 编译工具；依赖及测试步骤见 [.github/workflows/regression.yml](.github/workflows/regression.yml)。执行 `python3 tools/check_local.py`，确保回归通过。
3. 真机构建参考 [native/README.md](native/README.md)，需要 DevEco SDK。将 `native/config/store.example.json` 复制为 `native/store.local.json`，填入自己的 HTTPS 商店地址、公钥摘要和 CA 路径；未配置时仍可运行主机测试，商店联网功能会提示未配置。
4. PR 简要说明问题、修改效果和验证方式；涉及界面请附截图。私钥、Profile、令牌、本地服务配置、构建产物及 `docs/` 不提交。
