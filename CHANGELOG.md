# 变更日志

本文件使用中文记录可回溯的源码变更。每次源码提交都应记录改动、影响、验证和交付产物；完整提交历史以 Git 为准。

## 2026-07-29

### `0869c8a` - fix: refine background and speedometer opacity

- 改动内容：将自定义背景图片不透明度的默认值从 35% 调整为 50%，并将内置任务列表水印的固定 35% 设计透明度与该配置解耦；速度限制按钮不再对整个元素应用 `opacity`，改为仅通过 `color-mix` 调整背景和边框透明度，使速度、限速数值等前景文本始终保持原有不透明度。
- 影响范围：新安装、缺失或非法配置修复及恢复默认设置会使用 50% 背景图片不透明度；已有合法保存值（包括 35%）保持不变，不新增配置迁移。速度限制按钮的背景和边框继续响应透明度设置，前景内容及其原有状态样式不再被额外淡化。
- 验证结果：ESLint、Prettier、仓库完整性、`vue-tsc`、95 个前端测试文件（2160 项测试）、隔离目录 Vite 生产构建、Rust 格式、Clippy、全目标检查及 516 项 Rust 测试通过；生产 CSS 已确认使用背景/边框百分比混色且不存在旧的整元素透明度规则。
<!-- package-slot source=0869c8a -->
- 安装包：`MotrixNext_3.9.7-beta.8_x64-setup_20260729-014105_5d6dbe8.exe`
- SHA-256：`4E6503912A9D16237D4FF4221B0B5822373966C8677CBA7EAD35B6891D6A4B1C`
- 构建提交：`5d6dbe8`
<!-- package-slot-end -->

### `cbf6b8b` - fix: embed frontend assets in packaged app

- 改动内容：修复 Windows 打包 overlay 将绝对 `frontendDist` 误解析为外部 URL、导致 Tauri 不嵌入前端资源的问题；改用相对 `src-tauri` 的 `target/package-work/frontend`，并在写入配置前校验其既非绝对路径也非 URL。打包后会从 Cargo metadata 定位当前应用 EXE，并流式确认 Vite 的唯一主入口文件名已实际嵌入二进制，未嵌入时禁止发布安装包。
- 影响范围：仅影响本地 Windows 打包和产物校验流程，不改变应用源码或运行时行为。`MotrixNext_3.9.7-beta.8_x64-setup_20260728-235452_ed17bd7.exe` 已确认为缺少前端资源的无效产物，不应安装或分发。
- 验证结果：已由 Tauri 2.11.2/tauri-utils 2.9.2 源码确认根因；Windows 绝对路径会命中 URL 分支并生成空嵌入资源集合。PowerShell 7.6.4 与 Windows PowerShell 5.1 解析、流式二进制入口检查正反用例及 `CleanOnly` 通过。第一次完整运行在 Vite 阶段遇到一次性 Node/libuv 断言，未发布安装包且临时产物已清理；单独复跑 Vite 成功，随后第二次完整运行通过 ESLint、Prettier、仓库完整性、`vue-tsc`、94 个前端测试文件（2159 项测试）、Rust 格式、Clippy、全目标检查及 516 项 Rust 测试，前端入口嵌入校验、release/NSIS 构建、SHA-256 校验、Changelog 更新和最终清理均成功。新安装包为 16,600,693 字节，`dist` 仅含安装包，依赖与 sidecar 已保留。
<!-- package-slot source=cbf6b8b -->
- 安装包：`MotrixNext_3.9.7-beta.8_x64-setup_20260729-005356_e69a678.exe`
- SHA-256：`0F42327B5355190AADA357F3ACBFB19ABEA06735C8BCE2C21F4AE49177608F63`
- 构建提交：`e69a678`
<!-- package-slot-end -->

## 2026-07-28

### `c647a41` - fix: harden dist cleanup failures

- 改动内容：将 `dist` 非安装包清理拆为完整预扫描与实际删除两个阶段；遇到 reparse point、包含 `.exe` 的子目录或其他可预知风险时，在删除开始前统一拒绝。实际删除前会重新读取并复核项目，且无论清理成功或失败都会校验既有安装包快照和最终目录结构，再聚合返回全部错误。
- 影响范围：仅强化本地打包脚本的异常处理与安全删除边界，不改变安装包内容、命名、应用运行时或正常清理结果。
- 验证结果：PowerShell 7.6.4 与 Windows PowerShell 5.1 解析及重复 `CleanOnly` 通过；含嵌套 `.exe` 的目录会在删除开始前阻断，锁定文件会正确返回失败，reparse point 会被拒绝且目标目录不受影响，解除条件后均可恢复清理。ESLint、Prettier、仓库完整性、`vue-tsc`、94 个前端测试文件（2159 项测试）、Rust 格式、Clippy、全目标检查及 516 项 Rust 测试通过，release/NSIS 构建、安装包多阶段校验、Changelog 更新和最终清理成功。四个安装包的文件名、长度和 SHA-256 均保持有效，`dist` 仅含安装包，依赖与 sidecar 已保留。
<!-- package-slot source=c647a41 -->
- 安装包：`MotrixNext_3.9.7-beta.8_x64-setup_20260728-235452_ed17bd7.exe`
- SHA-256：`83249ABDF11D0156B5AE1275F3236A7A12A188DE77649D1D582B012E321A8DF6`
- 构建提交：`ed17bd7`
<!-- package-slot-end -->

### `376186a` - build: retain installers only in dist

- 改动内容：打包脚本不再生成 `.sha256` 旁车文件；普通打包与 `CleanOnly` 都会安全删除 `dist` 中的前端产物、子目录及其他非安装包内容，并强制验证最终仅保留根目录 `.exe` 安装包。清理前后通过文件名、长度和 SHA-256 快照保护既有安装包，遇到 reparse point 或包含 `.exe` 的子目录时拒绝递归删除。
- 影响范围：仅影响本地 Windows 打包、安装包归档及清理流程；SHA-256 改为只记录在本文件。保留既有安装包、`node_modules`、`src-tauri\binaries`、Cargo/Rust 工具链与缓存，不影响后续重新打包。
- 验证结果：PowerShell 7.6.4 与 Windows PowerShell 5.1 解析通过，二者的 `CleanOnly` 正常路径及重复执行通过；ESLint、Prettier、仓库完整性、`vue-tsc`、94 个前端测试文件（2159 项测试）、Rust 格式、Clippy、全目标检查及 516 项 Rust 测试通过，release/NSIS 构建、安装包多阶段校验、Changelog 更新和最终清理均成功。三个安装包的文件名、长度和 SHA-256 均保持有效，`dist` 仅含安装包，依赖与 sidecar 已保留。
<!-- package-slot source=376186a -->
- 安装包：`MotrixNext_3.9.7-beta.8_x64-setup_20260728-232528_a6b514a.exe`
- SHA-256：`61C1ACEFDDFC195C60EB19C1F3D9BE95618BA5E9F96721147CB559405FB27E3D`
- 构建提交：`a6b514a`
<!-- package-slot-end -->

### `7b36896` - fix: preserve git status leading whitespace

- 改动内容：原生命令输出仅裁剪结尾换行，不再移除 `git status --short` 用于表示工作区状态的前导空格，修复完整打包成功后最终状态守卫误报的问题。
- 影响范围：仅影响打包脚本的原生命令文本解析与最终工作区校验，不改变构建产物、应用运行时或清理范围。
- 验证结果：PowerShell 7.6.4 与 Windows PowerShell 5.1 均通过带前导空格的 `git status --short` 回归测试；上一提交的完整前后端测试、release/NSIS 构建、SHA-256 校验和清理流程已执行通过。
<!-- package-slot source=7b36896 -->
- 安装包：`MotrixNext_3.9.7-beta.8_x64-setup_20260728-230821_2cd56ee.exe`
- SHA-256：`0EE060850818A38718CFF3A22CBF77C7CB6AD7AD4DCBFF5AE3272737ABC8D8E2`
- 构建提交：`2cd56ee`
<!-- package-slot-end -->

### `7bf003f` - build: add safe package and cleanup script

- 改动内容：新增根目录单文件 Windows 打包与清理脚本；隔离前端构建目录，使用固定白名单清理临时产物，以无覆盖方式归档带时间和提交短哈希的 NSIS 安装包，并执行 PE、长度及 SHA-256 多阶段校验。
- 影响范围：仅影响本地测试、Windows NSIS 打包、安装包归档及临时产物清理流程；不改变应用运行时功能。保留 `dist` 既有文件、`node_modules`、Cargo/Rust 工具链与缓存，后续仍可直接重新打包。
- 验证结果：PowerShell 7.6.4 与 Windows PowerShell 5.1 解析及安全清理通过；无覆盖写入、中文 Changelog 原子更新、并发内容保护、脏工作区拒绝和 reparse point 拒绝测试通过；ESLint、Prettier、仓库完整性、`vue-tsc`、94 个前端测试文件（2159 项测试）、Rust 格式、Clippy、全目标检查及 516 项 Rust 测试均通过。首次完整运行已完成 release/NSIS 构建、安装包复核与临时目录清理，最终工作树校验因前导空格被裁剪而误报，产物和清理状态经独立复核有效。
<!-- package-slot source=7bf003f -->
- 安装包：`MotrixNext_3.9.7-beta.8_x64-setup_20260728-225847_cf018e4.exe`
- SHA-256：`F3535903140286FFC18036FEF384E29CC839ED676DEB29D522CA3B599F710E3C`
- 构建提交：`cf018e4`
<!-- package-slot-end -->
