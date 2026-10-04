# 本地解压依赖

固定源码归档用于离线静态构建，不包含外部解压程序。

| 项目 | 上游来源 | 校验 |
| --- | --- | --- |
| libarchive 3.8.9 | https://github.com/libarchive/libarchive/releases/tag/v3.8.9 | SHA-256 见 CMakeLists.txt |
| bzip2 1.0.8 | https://sourceware.org/bzip2/ | SHA-256 见 CMakeLists.txt |
| xz / liblzma 5.8.4 | https://github.com/tukaani-project/xz/releases/tag/v5.8.4 | SHA-256 见 CMakeLists.txt |

授权文本保存在 `licenses/`；源码归档内保留完整版权、许可证和作者记录。运行时只链接 libarchive、liblzma、libbzip2 所需源码。未启用加密解压或外部命令回退。
