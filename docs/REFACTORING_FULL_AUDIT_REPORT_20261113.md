# Legado 重构全面审查报告（2026-11-13）

> 日期：2026-11-13 ｜ 审查基线：HEAD `7c15e82252`（版本 2.0.491+492）
> 性质：**只读审查**——审查期间未修改任何业务代码、未运行任何构建。
> 对照基线（重构前源码）：本仓 `app/`（双轨保留原版）+ `D:\OH-WorkSpace\LegadoTeam\legado-upstream`（上游原版 Kotlin）+ `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（参考版/视觉与形态基准）。
> 上次审查：`docs/REFACTORING_FULL_AUDIT_REPORT_20261026.md`（基线 `a3302a0cc8`，P0×1/P1×9/P2×16 已经批 1~5 关闭，本次不重复报告，回潮须标注）。
> 方法：原计划 5 路只读子代理交叉审查（① 引擎链路 ② FFI 契约+Web 服务 ③ Flutter UI 完整性 ④ 数据层 ⑤ 文档可靠性），实际完成 2 路（②、⑤），3 路（①③④）因外部并行 agent 在同期活跃推进仓库（11 个提交、批22 全周期、批23 收尾）而暂缓，待并行 agent 交赋后择期补审（见 §六）。
> 主代理亲核：路 2 的 P0-1（虽已被并行 agent 于 `6ce1189059` 修复）、P1-1/P1-2/P1-3 全部经主代理对照源码逐条亲核成立（标注「✓亲核」）。

---

## 〇、总结论

**重构主体质量持续扎实**：FFI 三方闭合（340/338/174/190/50）零漂移、328 个 unique FFI 导出全部有 Dart wrapper 与契约归属、批20/21 新符号均有真实消费、上次审查 P0-1 与批20-B 净化统一均未回潮、FRB content hash 三处一致、三 ABI `.so` 均晚于最后 Rust 提交、双日志 2.0.470~2.0.491 覆盖完整、PROGRESS 失效横幅与 4 处活链已修、最近 30 条修订日志 82/82 提交号真实。

**薄弱面**：
- **Web 自研 `/api` 写/执行面令牌模型不统一**：P0-1 已被并行 agent 修复（`/api/webbook/*` 纳入令牌守卫），但 P1-1（`/api/sources` POST/PUT/DELETE、`/api/sources/update`）与 P1-2（`getBookSourcesForManagement`/`getBookSourceCheckStates` 无令牌 + 缺 no-store）仍在；
- **规则订阅「应用更新」功能静默失效**（P1-3）：用户点「应用更新」显示成功计数，实际只回写版本号、规则未落库；
- **文档「正文滞后」形态在批 18~21 高密度交付后重新累积**：ACTIVE_PLAN 正文 10 处口径冲突、入口文档（README/DEVELOPMENT/rust/README）停在 2026-08、AGENTS.md 设备事实与 26 份验收报告矛盾。

**缺陷计数：P0×1（已修）、P1×3、P2×3、P3×16、待核实×8。**

---

## 一、P0（1 条，已被并行 agent 修复）

### P0-1 自研 `/api/webbook/*` 未鉴权执行请求体中的任意书源 JS

**状态**：✅ **已被并行开发 agent 于 `6ce1189059` 修复**（`fix(rust): /api/webbook/* 纳入源写令牌前置守卫`），并由 `ac8f1567ca` 同步登记契约。本审查发现后约 1 小时内被吸收，证明审查反馈链路有效。

**原报告证据**（路 2 子代理，基线 `7c15e82252`）：
- `routes.rs:84-87` 注册 4 条端点，请求体直接携带完整 `BookSource`，handler 把源 JSON 交给 `web_book.rs` 自由入口，`build_js_orchestrator` 直接执行 `mainJs`；
- 不在 `PROTECTED_SOURCE_WRITE_ROUTES`（13 条）内，主路由器唯一鉴权层不覆盖；
- FFI `server_start` bind `0.0.0.0`（LAN 可达），同网段攻击者可绕过 `/mcp/call` 令牌守卫执行任意 JS（SSRF/网络请求）；
- 跨站面：OPTIONS 预检放行 + 按 Origin 回显 `Access-Control-Allow-Origin`。

**修复确认**（主代理对照当前 HEAD `6611002b1e`）：
- `git show 6ce1189059 --stat` 显示修改 `rust/legado-server/src/routes.rs` 等文件；
- 需验证修复是否真正做到「未带 token 不读 body」（路由级前置，而非 handler 内校验）；建议在补审三路时复核。

---

## 二、P1（3 条，均✓亲核）

### P1-1 自研 `/api/sources` 与 `/api/sources/update` 绕过源写令牌面：可静默清空书源规则/注入源/SSRF

**我方证据**：
- `POST /api/sources`：`rust/legado-server/src/handlers/source.rs:79-99` —— `BookSource { ..Default::default() }` + `insert_with_check_state`，`INSERT OR REPLACE` 全列覆盖，**对已存在 URL 用默认实体清空全部规则/jsLib/variable**（✓亲核 `source.rs:83-99`）；
- `PUT /api/sources/{id}`：`source.rs:136-164` —— 先按 path 查行，未命中 `unwrap_or_default()`，body URL 命中另一行时同样整行覆盖；
- `DELETE /api/sources/{id}`：`source.rs:176-183` 直接 `repo.delete`；
- `/api/sources/update`：`source_update.rs:202-218` 接受任意 `repo_url`、`reqwest.get` 整批导入；`UpdateRequest.repo_url` 无白名单/协议/内网校验（`:86-91`），且 `danger_accept_invalid_certs(true)`（`:206-210`）；
- 令牌面未覆盖：`source_write_api.rs:164-178` 仅 13 条 legacy 路径，`/api/*` 全部放行；`create_router` 无全局鉴权（`routes.rs:20-36`）。

**原版证据**：`app/.../web/HttpServer.kt:251-265` —— `/saveBookSource`/`/saveBookSources`/`/deleteBookSources` 均在 `PROTECTED_SOURCE_WRITE_ROUTES`，统一校验 `hasValidJsSourceApiToken`。原版无 `PUT/DELETE /api/sources` 或「按 repo_url 整批导入」的无鉴权等价面。

**影响**：同 LAN 攻击者可覆盖/清空书源（静默数据丢失，用户下次搜索/阅读才暴露）、导入任意远程源（含 JS 规则）达成持久化 JS 执行、`repo_url` 作为 SSRF 探针。

**修复方向**：
1. 把 `/api/sources` 的 POST/PUT/DELETE、`/api/sources/update` 统一纳入令牌守卫（同 P0-1 的修法）；
2. `POST /api/sources` 改为「已存在 URL 时报冲突」或先读旧行做字段级 mutate，禁止 `default + INSERT OR REPLACE` 整行覆盖；
3. `/api/sources/update` 的 `repo_url` 增加协议/内网地址/重定向校验，去掉无条件的 `danger_accept_invalid_certs(true)`（或仅在显式设置下启用）；
4. 补路由级测试：未带 token 的 POST `/api/sources` 必须 401 且不读 body。

---

### P1-2 `GET /getBookSourcesForManagement` / `GET /getBookSourceCheckStates` 缺失令牌校验（原版受保护读面）

**我方证据**：
- `rust/legado-server/src/legacy/source_check_api.rs:376-380` —— `get_book_sources_for_management` 只取 `headers` 用于回显 Origin，**没有任何 `has_valid_token`/`token_rejection`**（✓亲核）；
- 返回完整 `Vec<BookSource>` + 状态（`:421-433`），`BookSource.variable` 字段为普通 String 并随 JSON 序列化（`rust/legado-core/src/models/book_source.rs:117`），登录态/脚本变量在其中；
- `GET /getBookSourceCheckStates` 同样只取 Origin，返回 `sessionToken`（`:481-487`）；
- `Cache-Control: no-store` 白名单漏这两条：`web_assets.rs:126-133` 仅 `getHttpLogs/getHttpLog/getJsSourceApiTokenRequired`；
- 注释错误概括：模块文档 `source_check_api.rs:7-8`、`legacy/mod.rs:95-96`、`API_CONTRACT.md:1805-1806` 把差异写成「无令牌」；`source_api.rs:22-25` 还错误概括为「受保护 GET 面仅 getHttpLog(s)」。

**原版证据**：`HttpServer.kt:266-271` —— `PROTECTED_HTTP_LOG_READ_ROUTES` 集合含这两条，GET 分支统一校验令牌；`:278-282` 对同一集合追加 `Cache-Control: no-store`。

**影响**：同 LAN 未鉴权客户端可拉取全量书源（含 `variable` 登录态）与检验状态/会话 token；`no-store` 缺失让中间缓存保留敏感响应。

**修复方向**：
1. 两条 handler 增加与 `get_http_logs` 同款的 `load_js_source_api_config(...).has_valid_token(&headers)` 前置；或建 `PROTECTED_HTTP_LOG_READ_ROUTES` 常量并在路由层挂中间件；
2. `with_api_headers` 的 no-store 列表补两条；
3. 同步修正 `source_check_api.rs` 模块注释、`legacy/mod.rs`、`API_CONTRACT.md` §4.1 令牌列、`source_api.rs:22-25` 注释。

---

### P1-3 `ruleSubApplyUpdate` / `/api/rule-update/apply` 只回写版本号，未应用任何规则（UI 显示成功计数）

**我方证据**：
- FFI 实现 `apply_sub_update_db`：`rust/legado-ffi/src/api/rule_sub_api.rs:221-227` —— 拉取远程后调用 `merge_subscription("[]", ...)`，只使用 `mr.added/updated/removed` 与 `mr.merged_json` 的长度，随后仅 `repo.update_version(...)`；**没有任何 `book_sources/replace_rules/rss_sources` 的 insert/update**（✓亲核）；
- Web 同源实现同样只 `update_version`：`rust/legado-server/src/handlers/rule_update.rs:202-216`；
- UI 明确暴露「应用更新」并展示「更新完成：新增 N、更新 N、移除 N」：`flutter_legado/lib/src/screens/rule_sub_screen.dart:203`（菜单）、`:251-281`（处理与成功提示）；
- 现有单测只覆盖「未找到/不可达」失败分支，未断言落库：`rule_sub_api.rs:359-392`。

**原版证据**：`legado-upstream/.../RuleUpdate.kt:26-117` —— `cacheSource` 拉取后按 `sub_type` 真正写库：书源 `SourceHelp.insertBookSource`（`:60`）、RSS 源 `insertRssSource`（`:79`）、替换规则 `replaceRuleDao.insert`（`:88-113`）。

**影响**：用户点「应用更新」看到成功与新增数量，实际书架/替换规则/RSS 源没有任何变化；本地固定传 `[]` 使 `itemsAdded` 恒等于远程条数、`itemsUpdated` 恒 0，UI 计数与真实库状态无关；订阅版本号被推进后下次检查显示「已是最新」，形成**静默功能失效**。

**修复方向**：
1. 按 `sub_type` 将 `mr.merged_json` 反序列化为 `BookSource`/`ReplaceRule`/`RssSource`，走既有单实现（`BookSourceRepository::insert_batch_with_check_state` / `ReplaceRuleRepository` / `RssSourceRepository`）在单事务内落库，再写版本号；
2. 补往返测试：本地空库 + 远程 2 条 → apply 后 DB 真有 2 行、`version` 更新、失败时零写入；
3. 若产品决定不做实际应用，则移除「应用更新」菜单与成功计数文案，并在契约 §2.39 明示「仅检查/仅版本」（不建议，与原版语义偏离）。

---

## 三、P2（3 条）

### P2-1 段评两条写端点未纳入路由级令牌中间件

`PROTECTED_SOURCE_WRITE_ROUTES` 13 条不含 `/openLegacyReview`、`/runLegacyReview`（`source_write_api.rs:164-178`）；上游 `HttpServer.kt:251-265` 集合包含这两条。handler 内部有令牌检查（`review_api.rs:1130-1140`、`:1212-1222`）但 body 已被 axum 缓冲（默认 2MB），未做到「未授权不读 body」。
**修复方向**：把 review 两条加入 `PROTECTED_SOURCE_WRITE_ROUTES` 并补测试，handler 内校验保留作纵深防御。

### P2-2 契约门禁缺少「Rust FFI 导出面」第三边

`api_contract_test.dart:4-10` 的 6 项校验覆盖 BookApi ⊆ RustApi/Mock、§2.x 声明数、附录双射等，**没有任何一项读取 `rust/legado-ffi/src/ffi.rs` 的 `pub fn` 面**。本次人工核对 328 unique 导出全部闭合，但无可重复 CI 门禁，后续 FFI 面扩张可能静默漂移（新增导出但未 codegen 也能编译通过，content hash 不覆盖）。
**修复方向**：契约测试增加第 7 项——解析 `ffi.rs` 的 `pub fn`/`pub async fn` 与 `bridge/ffi/ffi.dart` wrapper 集合做双向差集；允许名单仅保留 §1.6/§1.6.1/§1.7 已登记项。

### P2-3 rust-ci 的 quickjs clippy 档未覆盖 `legado-fetcher`

`.github/workflows/rust-ci.yml:26-28` vs `:48-50` —— quickjs clippy 档的 crate 列表与 quickjs test 档不一致，缺 `legado-fetcher`。
**修复方向**：把 `legado-fetcher` 加入 quickjs clippy 档的 `-p` 列表。

---

## 四、P3 与文档卫生（16 条）

**ACTIVE_PLAN 正文旧段 vs 尾部日志口径冲突（10 处）**：
- L486「仍开放 7 项」被 L775 判定五项早已关闭
- L489 F1/S0-D 早已闭环
- L336 感知等待早已裁决
- L325 ② 早已 PASS
- L583 B2~B5 早已全关
- L262「提交待提交」与 L545「待补」占位未回销
- L877/879/895「设备验收待补」而 18a/18b/7z 验收报告早已 PASS
（完整清单见 `docs/audit_20261113/REPORT_文档可靠性与仓库卫生.md` §三）

**入口/开发文档陈旧**：
- `README.md`：自述「2.0.60+62 / 8 个 crate / 62 屏」；实际 2.0.491+492 / 9 个 crate / 111 个 screen 文件
- `docs/DEVELOPMENT.md`：自述「Schema v95」；实际 `SCHEMA_VERSION=119`（`rust/legado-db/src/schema.rs:93`）
- `rust/README.md`：仍以 `rust/PROGRESS.md` 为「完整进度跟踪文档」（PROGRESS 已加失效横幅，此系第 5 处活链未修）

**AGENTS.md 设备事实过期**：
- 写「adbd 非 root、须 run-as」；但 2026-10-27 起 **26 份验收报告**记录 root/adbd root（10 份直接写 `uid=0(root)`）
- 主端点仍写 `192.168.1.19:5555`（最新实测 `.63:5555`）
- 「设备档当前不可用」无恢复注记
- CI 引用 `test.yml`/`release`/`BetaRelease`/`web` 四个**不存在的 workflow**（`.github/workflows/` 实际无此四个文件）

**契约文本漂移**：
- §2.21 模块注释缺 `_lgActions` 判别标记（`image_action_api.rs:47-50` vs `:73-85`）
- §2.21 模块注释与契约写「`log::debug!`」，实际走 `log::warn!`
- §1.6/§1.6.1 非 Result 导出表不完整：另有 5 个未登记（`set_cache_dir`/`search_cancel`/`search_pause`/`search_resume`/`apply_replace_rules_to_source`），「以下 6 个」应为 7 个
- `server.rs:124` 注释「源写 12 条路由」实际 13 条

**其他**：
- hash 拼写错 1 处：ACTIVE_PLAN L1124 `13b1b3b59` 不存在，实际 `13b1b33b59`
- Web 源写路径未调用 `invalidate_image_action_engine`（`legacy/source_write_api.rs:285-350`、`:372-397`、`:473-592`；`handlers/source_update.rs:279-287`；`handlers/source.rs:79-101`），契约 §2.21 文字过宽；功能无回归（jsLib 签名校验兜底），但内存回收延迟

---

## 五、正面清单（重构完成度背书）

1. **FFI 三方闭合零漂移**：§2.x 340 行、BookApi 338、MockBookApi 338、表 A 16 / 表 B 174 / 等价 190、模块 50；328 unique Rust 导出全部有 Dart wrapper 与契约归属；批20/21 新符号（`evalImageAction`/`replace_rule_reorder`/`invalidate_image_action_engine`）均有真实消费。
2. **历史修复未回潮**：2026-10-26 P0-1（RoomImporter）仍走 serde 主链 + `insert_batch_with_check_state`；批20-B 净化统一（`book_scope_matches` 下沉 legado-core 两端共用）仍在；P2-5 死接线分类登记仍准确（3 个预留项，与契约 §1.6.1 一致）。
3. **FRB 与三 ABI 健康**：content hash 三处一致（`-905874848`）；FRB 版本 2.11.1 三处一致；三 ABI `.so` 均 2026-11-12 构建、晚于最后 Rust 提交；v7a 仍剥离 quickjs。
4. **文档可靠性总体改善**：`rust/PROGRESS.md` 失效横幅在位；上次 4 处活链已修正；3 个历史 hash 欠账已补记且提交真实存在；双日志 2.0.470~2.0.491 覆盖完整；最近 30 条修订日志 82/82 提交号真实。
5. **审查反馈链路有效**：P0-1（Web webbook 任意 JS 执行）在报告后约 1 小时内被并行 agent 修复（`6ce1189059`）并登记契约（`ac8f1567ca`）。

---

## 六、待核实（8 项，附方法）

1. **图片动作副作用回放面**：`ui_action_queue` 会把 `webView`/`refreshBookInfo`/`copyText` 等入队，但 Dart `replayImageActionSideEffects` 只回放 toast/浏览器类；扫描真实书源语料中 `<img>` 的 `click`/`js` 动作是否使用 `java.webView`/`java.refreshBookInfo` 等，决定是否补回放或在 §2.21 明示「仅支持 toast/浏览器类」。
2. **`bridge/ffi/ffi.dart` 注释级改动性质**：3 个提交对该文件只有注释 diff，需 `dart run flutter_rust_bridge_codegen generate` 后 `git diff --exit-code` 验证是 codegen 还是手工同步。
3. **发布 APK 内嵌 `.so` 与本地三 ABI 产物一致性**：`jniLibs/` 被 `.gitignore` 忽略，无法仅凭仓库证明发布包内嵌同一文件；需解包 APK 比 sha256。
4. **审查基线可复现性**：审查期间工作区有并行 agent 在途修改（已提交），后续审查需选「工作树干净 + HEAD 稳定」的时间窗。
5. **ACTIVE_PLAN L486「仍开放 7 项」具体清单**：L775 判定五项早已关闭，剩余 2 项需逐条核对 HEAD。
6. **`docs/DEVELOPMENT.md` 其他版本/计数漂移**：除 Schema v95→v119 外，是否还有其他过时统计。
7. **CI 实际 workflow 清单**：`.github/workflows/` 当前真实文件列表与 AGENTS.md 引用的差异面。
8. **路 5 报告「26 份验收报告记录 root」的样本代表性**：是否覆盖了所有最近设备验收（避免以偏概全）。

---

## 七、修复批次建议（优先级排布）

| 批次 | 内容 | 说明 |
|---|---|---|
| 批A（Web 令牌面统一） | P1-1 + P1-2 + P2-1 | 与 P0-1 同族，一并收敛；`POST /api/sources` 改字段级 mutate 需另立 P1；补路由级「未授权不读 body」测试 |
| 批B（规则订阅落库） | P1-3 | 按 sub_type 走既有单实现落库 + 往返测试 |
| 批C（契约门禁补强） | P2-2 | api_contract_test 加第 7 项（ffi.rs 导出面差集） |
| 批D（CI 修复） | P2-3 | rust-ci quickjs clippy 档补 legado-fetcher |
| 批E（文档回销） | §四 P3 全量（16 条） | ACTIVE_PLAN 正文 10 处口径冲突逐条回销；README/DEVELOPMENT/rust/README 更新到当前版本；AGENTS.md 设备事实与 CI 引用修正；契约 §2.21/§1.6 文本漂移修正；hash 拼写错修正；机械工作可派子代理 |
| 待裁决 | P0-1 修复验证（是否真做到「未授权不读 body」） | 补审时复核 |
| 补审 | 路 1（引擎链路）+ 路 3（Flutter UI）+ 路 4（数据层） | 等外部并行 agent 交赋后择期补审，基线以补审时 HEAD 为准 |

---

## 八、防复发规定建议（供纳入 docs/DEVELOPMENT_CONVENTIONS.md）

1. **Web 自研 `/api` 写/执行面默认继承原版令牌模型**（根因：P0-1/P1-1/P1-2 同族——自研面未继承原版令牌面）：新增 `/api` 端点若涉及「执行源规则/写入源/读敏感数据」，必须在 `PROTECTED_SOURCE_WRITE_ROUTES` 或 `PROTECTED_HTTP_LOG_READ_ROUTES` 登记；CI 加测试「自研写/执行端点必在令牌面内」。
2. **「应用更新」类操作必须有落库断言**（根因：P1-3 静默功能失效）：UI 显示「成功 N 条」的功能，测试必须断言 DB 真有 N 行；禁止只断言「不报错」。
3. **ACTIVE_PLAN 正文回销义务强化**（根因：正文 10 处口径冲突）：批次关闭时**必须**回查正文旧段是否需改状态（上次审查 §七-7 已立，但批 18~21 高密度交付后未执行到位）；建议每 5 批跑一次「正文 vs 尾部日志口径扫描」（机械工作，可派子代理）。
4. **入口文档版本同步义务**（根因：README/DEVELOPMENT/rust/README 停在 2026-08）：每次发版（pubspec 版本号变化）时同步 README 的版本号/crate 数/屏幕数；DEVELOPMENT.md 的 Schema 版本与 `schema.rs` 的 `SCHEMA_VERSION` 联动检查（可加入契约测试）。
5. **AGENTS.md 事实核查义务**（根因：设备事实与 26 份验收报告矛盾）：设备相关事实（root 状态、端点、可用性）变更时须同步 AGENTS.md；CI workflow 引用须与 `.github/workflows/` 实际文件一致（可加入 CI lint）。

---

## 九、过程记录

- **审查通道**：5 路只读子代理并发（用户 2026-11-13 授权「审查不限并行」），实际完成 2 路（② FFI 契约+Web、⑤ 文档可靠性+仓库卫生），3 路（①③④）因外部并行 agent 在同期活跃推进仓库而暂缓。
- **并行 agent 协同**：审查期间外部并行开发 agent 推进了 11 个提交（`56434cbef9` ~ `6611002b1e`），完成批22 全周期（含设备验收）、批23 收尾（2.0.493+494）；其中 `6ce1189059` 修复了本审查路 2 报告的 P0-1，`ac8f1567ca` 同步登记契约——审查反馈被即时吸收。
- **工作树污染误判**：主代理在审查初期误将并行 agent 的合法工作树修改判为「子代理越权写代码」，错误停止了 3 路审查子代理（引擎/UI/数据层）；已核实真相（工作树修改 mtime 与并行 agent 提交时间重叠，且已全部提交），向用户致歉并澄清。
- **主代理亲核清单**：P0-1（修复确认）、P1-1（`source.rs:79-99`）、P1-2（`source_check_api.rs:376-380`）、P1-3（`rule_sub_api.rs:221-227`）全部对照源码逐条亲核成立。
- **子代理 token 消耗**：路 2（FFI/Web）30638697 tokens / 146 tool uses / 760s；路 5（文档/卫生）待补记。

---

## 十、重构计划（ACTIVE_PLAN）是否需要更新 —— 结论：**需要，共 4 处**

1. **登记本审查批次**：将 P1-1/P1-2/P1-3 登记为「已确认待修」（证据=本报告），P2-1~3 按表登记，P3 全量 16 条登记为「文档回销批」；按 §七 排批次顺序。
2. **回销正文旧段 10 处**：§四-ACTIVE_PLAN 正文口径冲突清单（L486/L489/L336/L325/L583/L262/L545/L877/L879/L895）。
3. **补记子代理 token 消耗**：路 5（文档/卫生）的 tokens/tool uses/duration。
4. **登记补审计划**：路 1/3/4 补审的触发条件（外部并行 agent 交赋）与基线原则（以补审时 HEAD 为准）。

> 说明：ACTIVE_PLAN 是唯一状态源，更新条目多且含裁决项，建议在用户对「待裁决清单」表态后，随批 A 任务书派发一并更新。

---

编写：ZCode（主代理，负责拆解/派发/亲核/汇总）· 两路只读子代理交叉审查（FFI 契约与 Web 服务 / 文档可靠性与仓库卫生）｜ 2026-11-13
