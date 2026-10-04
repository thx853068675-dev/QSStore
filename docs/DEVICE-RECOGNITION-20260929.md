# 6.1 外部侧载识别与启动验证

设备：`3BH0224320005595`，HarmonyOS 6.1。本轮设备候选安装器为 0.4.30 / 2026092927，使用已有签名材料，官方验签后覆盖安装。

## 实际问题与修复

- 系统 `bm dump -n com.tonghongxiang.quietstart` 确认轻启为 1.1.0 / 110003；商店发布附件也为同一包名、同一版本。
- 安装器数据库有该包的 `retryable_error` 旧任务，目标版本同为 110003。该任务遮盖了系统已安装状态。
- NAPI 入口只允许 HDC 操作 0–5，ArkTS/Rust 已调用操作 6，实机日志为 `TypeError: Invalid HDC operation`。补齐操作 6 的原生参数范围。
- 实机 `bm dump -a` 只有包名，不能从中读取版本。改为先确认包存在，再查询目录涉及包的 `bm dump -n`，解析真实 versionCode。
- 系统权限不足时复用短期设备查询结果；查询未知不再当作未安装。设备确认相同版本后自动收尾旧暂停任务。
- 启动外部安装应用不能只传 bundleName。现解析 entryModuleName / hapModuleInfos 中的真实启动 Ability，发现、管理、详情共用启动逻辑。

## HoKit 参考依据

本地 `HoKit_1.9.0.hap` 字节码中，商店 `refreshInstalledApps` 调用 HDC `bm dump -g` 列出侧载包，随后 `getInstalledAppVersionsBatch` 查询各包；应用管理另外使用 `bm dump -a -l`。参考其“先列包，再查询版本”方式，本项目保留全量存在性清单，并用整数 versionCode 判断更新，未直接采用 versionName 文本比较。

## 实机通过项

1. 修复后的应用内日志读到 `com.tonghongxiang.quietstart:110003`。
2. 详情页自动显示「打开应用」，旧「安装暂停 · 继续」消失。
3. 点击详情页「打开应用」，系统提示“轻启·安装器想要打开轻启”；确认后进入轻启首页，页面显示 `v1.1.0(110003)`，`aa dump -l` 确认轻启 EntryAbility 为 FOREGROUND。
4. 管理页「已安装」显示轻启、版本 1.1.0、「打开」；点击后再次进入轻启首页。
5. 本轮没有重装轻启，没有修改其版本；仅更新安装器并核实/启动目标应用。

证据保存在本机 `/tmp/recognition-device-evidence/`：`detail-fixed.json`、`quietstart-opened.json`、`quietstart-opened.jpeg`、`manage-recognition.json`、`manage-recognition.jpeg`、`manage-open-result.json`。

回归测试 87 项通过，包含新增 8 项侧载识别/启动测试。构建与官方签名校验通过。商店当前没有比 110003 更高的轻启版本，因此真实在线升级未在本轮执行；高版本匹配由自动化测试覆盖。
