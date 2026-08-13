# 仓库根目录工程文件说明（F4-6）

> 根目录仅保留约定文件（见 AGENTS.md「文档存放」）；下列为**经登记的工程辅助物**，非临时产物。

| 路径 | 用途 | 处置 |
|---|---|---|
| `Makefile` | Rust/Flutter 快捷目标（`make test` / `make lint` / `build-windows` 等） | **保留**；Windows 主开发仍推荐 PowerShell 脚本 |
| `package.json` | 历史 Commitizen 配置（`cz-conventional-changelog`） | **保留**；不参与 Flutter/Rust 构建；`node_modules/` 已 gitignore |
| `reasonix.toml` | Reasonix 本地工具配置 | **不入库**（`.gitignore`）；开发者本机放置 |

**临时文件规范**（F4-2）：`tmp_*`、`_debug_db/`、`scripts/_tmp_*`、`flutter_legado/crash_last_screenshot.png` 等见 `.gitignore`，不得提交。

编写者：Cursor 子代理 ｜ 2026-08-14
