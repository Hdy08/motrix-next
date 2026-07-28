# 变更日志

本文件使用中文记录可回溯的源码变更。每次源码提交都应记录改动、影响、验证和交付产物；完整提交历史以 Git 为准。

## 2026-07-28

### `7b36896` - fix: preserve git status leading whitespace

- 改动内容：原生命令输出仅裁剪结尾换行，不再移除 `git status --short` 用于表示工作区状态的前导空格，修复完整打包成功后最终状态守卫误报的问题。
- 影响范围：仅影响打包脚本的原生命令文本解析与最终工作区校验，不改变构建产物、应用运行时或清理范围。
- 验证结果：PowerShell 7.6.4 与 Windows PowerShell 5.1 均通过带前导空格的 `git status --short` 回归测试；上一提交的完整前后端测试、release/NSIS 构建、SHA-256 校验和清理流程已执行通过。
<!-- package-slot source=7b36896 -->
- 安装包：待生成
- SHA-256：待生成
- 构建提交：待生成
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
