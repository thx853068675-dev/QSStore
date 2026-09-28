# 源码 HDC 传输层

本目录由 [Muka Rust HDC](https://github.com/Attect/muka_rust_hdc) 的 `hdc` 与 `hdc-protocol` 改编，基准提交 `4a2d9c42059b3ff346f4d3f533cf781a5fbe70ba`，采用 MIT 许可。原许可文本保留在 [LICENSE.upstream](LICENSE.upstream)。

本项目把原先的命令行主机改为应用进程内的 TCP 主机：只监听 `127.0.0.1:38710`，RSA 主机密钥保存在应用沙箱，NAPI 仅允许设备列表、TCP 连接、读取 UDID、查询包版本及安装沙箱内 HAP。安装任务运行时会在设备端核对目标版本。没有从可写目录运行 HDC 可执行文件。

该依赖仍包含上游的 USB 和转发实现，当前应用没有把这些接口暴露给 ArkTS。后续可以单独裁剪未使用代码，前提是保持无线配对、端口变化和安装回归通过。
