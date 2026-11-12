# Legado 重构全面审查（2026-11-13）五路任务书

> 审查基线：HEAD `7c15e82252`（版本 2.0.491+492）
> 性质：**只读审查**——审查期间**禁止**修改任何业务代码、禁止运行任何构建/测试命令（除 git log/git grep/rg 等只读检索外）
> 对照基线：
> - 本仓 `app/`（双轨保留的原版 Kotlin）
> - `D:\OH-WorkSpace\LegadoTeam\legado-upstream`（上游 gedoor/legado 最新）
> - `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（参考版/视觉与形态基准）
> - 上次审查：`docs/REFACTORING_FULL_AUDIT_REPORT_20261026.md`（基线 `a3302a0cc8`）
> - 唯一状态源：`docs/REFACTORING_ACTIVE_PLAN.md`
>
> 公共要求（五路共用）：
> 1. 每条发现给双侧 file:line 证据（我方 + 原版/参考版）；「缺失」类结论必须 `git log -S <符号>` 排除改名/移位。
> 2. 严禁凭记忆/印象下结论；「未接线」「未实现」「死代码」必须全仓 rg 裸名重搜（含路由名/FFI 符号/manifest 声明三类）。
> 3. 已知历史坑（不要重复报告）：core 同名死桩曾误导两轮审计；so 陈旧盲点（verify 只校验 FRB hash）；freezed List identity；Git Bash grep 中文零命中（中文检索用 pwsh Select-String 或 rg -n --encoding utf-8）。
> 4. 上次审查已关闭的 P0/P1/P2 见 ACTIVE_PLAN L811~843（审查批 1~5），**不要重复报告**；但**回潮**（修复后又坏）须作为新发现报告并注明「回潮」。
> 5. 分级口径：P0=用户可达的静默数据丢失/崩溃/安全；P1=用户可见功能缺陷/契约违反；P2=技术债/边界缺陷/不一致；P3=文档卫生/小毛病。
> 6. 报告格式：每条发现 = 标题 + 我方证据 file:line + 原版/参考版证据 file:line + 影响 + 修复方向。**不确定的列入「待核实」并附核实方法，不得猜。**
> 7. 报告落盘到 `docs/audit_20261113/REPORT_<路名>.md`，末尾署名与日期。
> 8. 上次审查以来的增量面：941 提交 / 21 版本号（2.0.470 → 2.0.491+492），批次 6~21 全部经独立审查+设备验收——审查重点应放在**增量面引入的新缺陷**与**跨批次交互**。

---

## 路 1：引擎链路（Rust parser/fetcher/js/core/book）

**范围**：`rust/legado-parser`、`rust/legado-fetcher`、`rust/legado-js`、`rust/legado-core`、`rust/legado-book`

**必查点**：
- 批15/17 `@js:` 生产执行链路（`replace_rule_js.rs`、engine 缓存、IIFE 构造、超时/预算）是否有绕过/副作用泄漏
- 批16 行内图片：Rust 侧 `<img>` 保留与 `,{json}` 复合头在 fetcher→ffi→dart 链路上的字段完整性
- 批20/21 图片 action 执行：`evalImageAction`、引擎 LRU 缓存（上限 4）、jsLib 签名失效、`java.get/put` 源作用域、UI action 队列信封
- 批21 文件访问门控收紧：`allow_file_access=false` 白名单、RAR 条目名校验、字体 `file://` 预检——是否有绕过面（符号链接/UNC/verbatim/多字节切片 panic）
- 上次 P1-1/P1-2/P1-3 修复（is_volume/is_pay/tag 透传、ruleContent.title、downloadUrls）是否回潮
- 目录串行/并发两条路径是否仍为单一转换函数（P2-3 不得回潮为双实现）
- 转换层是否仍有 `false/None` 兜底硬编码（违反防复发规定 §八-3）
- QuickJS 引擎：capability_ledger 是否有新增未登记哨兵；`java.io.InputStream` shim 是否仍按登记面
- `@webjs` 无订阅者时是否仍静默回退空串（P2-2 是否真修了告警登记）
- `speakText/speakSpeed` TTS 模板绑定（上次「待核实 4」）

**特别关注**：批 15~21 引入的 QuickJS 引擎复用（thread-local / LRU）在并发与 panic 路径下的安全性；`ui_action_queue` 线程局部会话栈是否有泄漏路径。

---

## 路 2：FFI 契约 + Web 服务（Rust ffi/server + Dart 绑定）

**范围**：`rust/legado-ffi`、`rust/legado-server`、`flutter_legado/lib/rust_api*`、`flutter_legado/lib/api/`、`docs/API_CONTRACT.md`

**必查点**：
- FFI 三方闭合：契约 §2.x 声明数 == Rust pub async fn == Dart BookApi == MockBookApi；计数基线是否仍同步（附录 340 / BookApi 337 / 表 B 173 / 等价 189 / 模块 50，批21 后是否有漂移）
- 死接线：Rust 已 pub 但 Dart 零调用（或反向）——用裸名 rg 全仓；批 20/21 新增 `evalImageAction`、`invalidate_image_action_engine`、`reorder_replace_rules` 是否都有真实消费
- 契约文本与实现的语义漂移：§2.21 信封格式 `{"_lgActions",result,actions}` 是否与 Dart 解析一致；§2.8 替换规则作用域/配置面差异登记是否仍准确
- Web 服务（`legado-server`）：
  - B3/B4/B5 批次交付的写端点/管理端点/段评/WS 是否仍工作；路由注册面 vs 契约面
  - `/mcp/call` 令牌要求与 `PROTECTED_SOURCE_WRITE_ROUTES`（13 条）——是否有未保护的写路由
  - `purify_content` 在 Web 链路的配置面/作用域面差异是否仍按契约 §2.8 登记（批20-B 已统一，验收是否回潮）
  - Web 书源仓库更新链（上次 P0-1 修复点）是否仍走 `BookSourceRepository::insert_batch` 而非 RoomImporter
- FRB 生成物：`frb_generated.rs`/`frb_generated.dart` content hash 与 pubspec/lock 一致性；是否有手改生成物痕迹（git log 检查）
- 三 ABI `.so` 新旧：armv7 是否 2026-11-11 之后构建（批19 重建）；`quickjs` feature 在 v7a 是否仍被剥离
- 「接口声明但 Dart 未消费」/「Dart 调用但 Rust 已删」类漂移

**特别关注**：批 18~21 高密度的 FFI 面扩张（图片动作/重排/隐私/字体）是否破坏契约测试不变量。

---

## 路 3：Flutter UI 完整性（flutter_legado/lib）

**范围**：`flutter_legado/lib/`（全部 Dart UI、providers、notifiers、services）；对照 `app/` 原版 46 Activity/Fragment 与 `legado-with-MD3`

**必查点**：
- 屏幕对照：原版 46 屏逐一对照是否有新增断链/未接线；批 1~21 引入的新屏（隐私设置/启动锁/主题包管理/备份三选 Sheet/替换规则排序/字体设置/行内图片渲染）是否有未授权新增功能
- 死路由/死入口：`routes.dart` 中路由是否都有真实入口；上次 P2-16 `/cache_settings` 处置后是否有新增死路由
- 长按/点击交互：批 21 图片动作五档矩阵（`click_img_way` 0~4）在 image-dominant/inline-image 两条渲染链是否一致
- 隐私链：批 9a~9d 私密标记/脱敏/闸门——是否有 fail-open 面（搜索/记录/书签按书名+作者反查是否改名即破）
- 主题：批 13/14 的 12 色槽与主题包 zip——夜间继承、0=未设置、导入不自动应用等约定是否被后续批次破坏
- 备份/恢复：批 10/11 三选 Sheet + 批 18 线1 清扫——临时目录清理、密码 zip 循环、busy 互斥、`lastSeenRemoteBackupMtime` 写点
- TTS：批 5c/9b-5c/18 线2 的语速解析单点（`applyTtsSpeedPreference`）是否有新增绕开点
- 行内图片：批 16 分段/测量/重排——跨页丢字、首页利用率、异步预测量代际取消是否在后续改动中回潮
- 「有开关无功能」类：Dart 端 prefs 键是否都被 Rust/服务真实消费（逐键抽查最近 30 个新增 PrefKeys）

**特别关注**：白名单外是否有未授权新增（按 AGENTS.md 重构红线）；形态类与参考版的一致性（视觉冲突以参考版为准）。

---

## 路 4：数据层（Rust db + 备份/恢复 + 迁移）

**范围**：`rust/legado-db`、`rust/legado-ffi/src/api/backup_api.rs`、`flutter_legado/lib/services/backup*`、`flutter_legado/lib/services/webdav*`、schema 迁移链

**必查点**：
- schema 迁移链：当前最新版本号（批9a 提到 119）；90→119 每版迁移是否幂等、是否有跳号；migration_tests 覆盖
- 备份覆盖面：上次 P1-9 后是否扩展；当前 BackupData 字段清单 vs 原版 19 类；version 字段是否引入（上次建议 §八-9）
- 恢复语义：P1-6/7/8 修复后是否回潮；ReadRecord 的 deviceId 较新者胜合并是否仍在；readConfig 双形态归一是否仍工作
- 「恢复即丢数据」族新成员：批 1~21 新增的表/字段（highlightRules 的 uuid/applyToBody、books.isPrivate、book_groups.isPrivate、replace_rules.sortOrder、theme 12 槽、appFontPath）是否都进了备份/恢复/导出链
- 隐私数据外流面：books.isPrivate/book_groups.isPrivate 在备份/导出/Web/进度同步的处理是否与批 9c/9d 登记的「参考版口径」一致（用户 2026-11-11 裁决维持参考口径 + 补明示文案）
- 双 DB 面：是否有 S28 遗留的双写/漂移
- 死字段/死表：当前 schema 中是否有全仓零读写的表或列（按裸名 rg）
- 多设备/并发：readRecord 查询是否带 deviceId 过滤；`update_progress` 防回滚闸是否在恢复路径仍正确

**特别关注**：批 18 线1 临时目录清扫（`legado_webdav_only_*`/`legado_webdav_restore_*`）的时间口径（目录与最新直接子项 mtime 取大者）是否有边缘 case；恢复中途被杀的孤儿目录是否有兜底。

---

## 路 5：文档可靠性 + 仓库卫生

**范围**：`docs/`、`AGENTS.md`、`README.md`、`CHANGELOG.md`、`flutter_legado/assets/updateLog.md`、`rust/PROGRESS.md`（应已失效横幅）、`.github/workflows/`

**必查点**：
- ACTIVE_PLAN 正文旧段 vs 尾部日志：是否仍有「未修/仍开放」与「已修/已关闭」并存的口径冲突（上次发现 8 条，须全部回销核查 + 新增扫描）
- hash 欠账：是否有「待补记」类未补；抽查最近 30 个修订日志的提交号是否真实存在（git cat-file -t）
- 双日志同步：CHANGELOG.md 与 updateLog.md 是否覆盖 2.0.470~2.0.492 全部版本；版本号是否单调；缺失条目
- 失效文档：`rust/PROGRESS.md` 横幅是否仍在；4 处活链是否已修正；是否新增其他「第二状态源」
- 文档存放规范：根目录是否只有约定文件；新建计划/报告是否都在 docs/
- AGENTS.md：adbd root 表述是否已修；MuMu 端点描述是否与最新实测一致；「并行上限=2」与用户 2026-11-11 「后续开发并行两个子代理」、2026-11-13「审查不限并行」的最新口径是否一致（应已修订？）
- CI：`.github/workflows/` 是否覆盖当前所有验证入口；上次审查以来是否新增/删除 workflow
- 仓库卫生：根目录/`.tmp_*`/`nul`/`rust/_p03_*` 等杂物的 .gitignore 覆盖；`.zcode/` 未跟踪目录是否该入 ignore
- 登记项计数：ACTIVE_PLAN 中「待用户裁决」「待核验」「P3 登记」类条目的真实数量与最新状态

**特别关注**：批 18~21 的修订日志密度高，核查是否有「日志说关了但正文/代码未改」的漂移；版本号 2.0.491+492 在双日志中的记录是否完整。

---

## 交付与汇总

- 每路独立落盘 `docs/audit_20261113/REPORT_<路名>.md`，末尾署名与日期
- 主代理亲核全部 P0/P1 关键证据后汇总到 `docs/REFACTORING_FULL_AUDIT_REPORT_20261113.md` 并登记 ACTIVE_PLAN
- 完成后按 §七 排批次建议

编写：ZCode 主代理 ｜ 2026-11-13
