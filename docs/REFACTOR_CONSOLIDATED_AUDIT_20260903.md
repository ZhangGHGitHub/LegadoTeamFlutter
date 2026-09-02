# Legado 重构深度体检整合报告

> 编制日期：2026-09-03
> 性质：只读审计整合报告（审计过程未改动任何业务代码）
> 最新审计基线：HEAD `4fc08cb977`（master，含 upstream 3.26.082823 合并）
> 编写者：GLM-5.3-Flash
>
> 本报告整合并替代以下三份报告。**文中缺陷编号（§x.x / D1-D6 / E1-E2 / N1-N7）继续有效**，供代码注释与 CI 工作流回溯引用：
> - ① `REFACTOR_DEFECT_AUDIT_20260828.md`（2026-08-28 首轮体检 18 项；含 2026-08-29 复查附录）
> - ② `SEARCH_CHANGE_SOURCE_PARITY_AUDIT_20260829.md`（2026-08-29 搜索/换源 parity 专项 D1-D6）
> - ③ 2026-09-03 第三轮核对与新扫描（上轮计划完成度核对 + 新发现 N1-N7，本报告首次成文）

---

## 一、审计方法与范围

- **第一轮（08-28）**：通读执行计划与 5 份审计文档；对 `rust/`（8 crate）与 `flutter_legado/`（68 页面）做桩标记/错误处理/并发/性能/平台通道/大文件扫描；原版 UI 功能域逐项对照；CI 与工作区卫生清点。
- **第二轮（08-29）**：对「源集合 → 请求构建 → 单源解析 → 过滤 → 去重 → 聚合分桶 → 超时/取消 → 换源双路径」逐环节做重构轨 vs 原版 Kotlin 源码比对（原版关键文件：WebBook/BookList/SearchModel/ChangeBookSourceViewModel/SearchBookDao/SearchScope）。
- **第三轮（09-03）**：逐项实测上两份报告 24 项的修复完成度（以当前 HEAD 代码为准，不采信台账自报）；重新扫描新增缺陷。

---

## 二、总体结论

1. **主线完成度扎实**：原版 20 个 UI 功能域在 Flutter 侧几乎全覆盖；搜索/换源 parity 战役（P3-6）核心语义已全部落地（S0-B/S0-E/阶段三/P0-3 收尾），主搜索链路与原版逐环节对齐；唯一遗留 S0-C 原版端证据采集受环境阻断（LDPlayer + 盲操作约束，三条续作路径已登记于专项计划 §8.6/§8.8）。
2. **修复战役有效但有 1 例虚假闭环**：上两轮 24 项中约 13 项真实闭环、3 项按决策闭环；§一.2 前台服务台账声称已闭环，实测发现服务类已实现但 **manifest 未注册——引入比原缺陷更严重的新 P0（N1，播放即崩）**。
3. **剩余确凿缺口**：Web 服务功能域未接线（N3）、字体反爬 cmap 空壳（§二.4）、JS 源绕过精准搜索（D4）、REST 死降级路径（§二.7）及配套双 DB 潜伏（§二.8）。
4. **工程卫生明显改善**：.gitignore/CI fmt+quickjs clippy/引擎缓存容量/热点锁中毒恢复均已落地；剩余为 golden 测试 0、超长文件、生成代码漂移、cargo audit。

---

## 三、首轮体检 18 项：清单与最终状态（截至 2026-09-03）

### P0（发布硬伤 / 资产风险）

| # | 条目 | 原始证据 | 最终状态 | 修复/决策证据 |
|---|---|---|---|---|
| 1 | armeabi-v7a `.so` 无 QuickJS，`@js:` 规则静默空结果 | `jniLibs/armeabi-v7a/liblegado_ffi.so.meta "quickjs":false` | ✅ **决策闭环**：实测 rquickjs-sys 0.9.0 无 armv7 绑定（bindgen 产物 32 位不兼容），决策=发布矩阵显式剔除 v7a JS；v7a .so 维持降级 + `.meta` 机读标注 + flutter-ci verify 告警不阻断；rquickjs 补绑定为独立上游议题 | `8ecfc47c65` |
| 2 | 后台听书无前台服务，退后台被冻结 | manifest 仅 `AutoTaskJobService`；`MediaSessionBridge.kt` 无 startForeground | ⚠️ **虚假闭环 → 升级为新 P0（见 §五 N1）**：`PlaybackForegroundService` 类已实现（`405e82a413`），但三个 variant 的 manifest 均未注册该服务，听书开始播放即崩溃 | — |
| 3 | 会话级搜索取消修复批次未提交（资产风险） | 工作树 7 文件 224+/124- | ✅ 已入库：`c5f82a854`（P0-3 强化取消）、`4330acaf9`（S0-E 主路径收敛）、`837516a08`（阶段三） | — |

### P1（功能正确性缺口）

| # | 条目 | 原始证据 | 最终状态 | 修复证据 |
|---|---|---|---|---|
| 4 | 书源字体反爬 cmap 解析空壳（正文乱码） | `query_ttf.rs:62` 自注"简化实现：构建基本的 ASCII 映射" | ❌ **未修**（登记下一批次） | — |
| 5 | AutoTask Custom JS 假成功 | `auto_task.rs` do_custom_js"验证脚本非空即视为成功" | ✅ **已修**：FFI `execute_task` 截获 Custom 动作走 `execute_auto_task_js` 真实求值（QuickJS 引擎缓存 + Response/Jsoup 桥）；调度器已接真实路径（`auto_task_scheduler.dart:273`）；残留死代码见 §五 N2 | `bde0dddfa2` |
| 6 | WebDAV PROPFIND 字符串 split 解析脆弱（静默变空） | `remote_book.rs:219` `split("<D:response>")` | ✅ **已修**：改为本地名大小写不敏感扫描（`split_blocks_ci`/`find_tag_value_ci`），`D:`/`d:`/无前缀/自定义前缀全兼容，legado-net 232/0 | `de4a69d3ea` |
| 7 | AutoTask REST 降级死路径 + 静默吞错 | `auto_task_notifier.dart:41` 指 `127.0.0.1:8080`，`serverStart` 零调用方；连接错误吞成空列表 | ❌ **未实施**（决策"删除 REST 对齐原版"已登记）；并入功能域缺口 §五 N3 一并处理 | `8ecfc47c65`（仅登记） |
| 8 | Server/FFI 两套 DB 连接并存（潜伏） | `server/state.rs:12` `Mutex<Database>` vs FFI `db_state.rs:20` `Pool` | ❌ **未修**（server 未启动故未爆发；与 N3 同簇，须先设计） | — |

### P2（健壮性与工程门禁）

| # | 条目 | 原始证据 | 最终状态 | 修复证据 |
|---|---|---|---|---|
| 9 | JS 引擎内存限制测试 Windows skip（沙箱安全线无回归防护） | `engine.rs:961` `#[ignore = "...ACCESS_VIOLATION on Windows"]` | ❌ 未修（建议 CI Linux runner 启用） | — |
| 10 | CI 盲区：clippy 从未 lint quickjs 路径、无 fmt、verify 只查 debug 双 ABI | rust-ci/flutter-ci | ✅ **大部分已修**：`cargo fmt --all --check`、`cargo clippy -p legado-js -p legado-ffi --features quickjs -- -D warnings`、flutter-ci verify 扩展 release+armv7（带告警）、全量 fmt 前置 141 文件、test.yml 按「安卓源码不上传」调整触发策略；仅缺 `cargo audit`（见 §五 N7） | `8ac2410a0c` + `4518c0df71` |
| 11 | 网络链路 e2e 语义靠模拟器冒烟（12 项 #[ignore] 需网络） | reader.rs/search.rs/image_api.rs | 信息项（理由成立） | — |
| 12 | 生产路径 `lock().unwrap()` 中毒级联 | 81 处 | 🟡 部分修复：82→77；`CURRENT_SEARCH_SESSION` 等热点锁已改中毒恢复（`into_inner`） | `e41dbd5554` |
| 13 | MOBI LZMA(compression=17481)/加密内容未实现 | `mobi.rs:21` | 维持边界登记（建议导入失败提示显式化） | — |
| 14 | 引擎缓存 MAX_ENTRIES=8 与搜索并发 32 不匹配（LRU 抖动） | `engine_cache.rs:14` | ✅ **已修**：容量 8→32 | `e41dbd5554` |

### P3（卫生与可维护性）

| # | 条目 | 原始证据 | 最终状态 | 修复证据 |
|---|---|---|---|---|
| 15 | 工作区 169→180 项未跟踪杂物，无 .gitignore 规则 | `.tmp_*`/`.shot_*`/`_p03_*`/timing 输出 | ✅ **已修**：`.tmp_*`/`.shot_*`/`rust/.tmp_*` 规则已补，未跟踪降至 16 项 | `e41dbd5554` |
| 16 | 超长文件（book_info_screen 2165 行等 7 个 >1300 行）+ golden 测试 0 | `matchesGoldenFile` 零命中 | ❌ 未修（长期批次） | — |
| 17 | UI 层直连网络先例（`auto_task_notifier.dart:7` package:http）+ reader 主 isolate jsonDecode | notifier L7/L41 | ❌ 随 §二.7 未实施 | — |
| 18 | 已声明平台边界（RSS 图文桌面纯文本/悬浮窗降级/qrcode 桌面占位） | STUB 台账 D5 等 | 维持登记（非缺陷） | — |

---

## 四、搜索/换源 parity 专项（第二轮）

### 4.1 已确认对齐的环节（防止误判）

| 环节 | 原版 | 重构 | 判定 |
|---|---|---|---|
| 源集合 | `allEnabledPart`（SearchScope.kt:108+） | `list_enabled_sources`（search.rs:1007） | ✅ |
| 单源超时 | `withTimeout(30000)`（SearchModel.kt:120）/换源 60s | `SEARCH_SOURCE_TIMEOUT=30s`/`SWITCH_SOURCE_TIMEOUT=60s` | ✅ |
| 失败隔离 | `mapParallelSafe` 吞异常（FlowExtensions.kt:59） | drive `catch_unwind` + Err 批次 | ✅ |
| bookUrlPattern 直连/空列表回退/loginCheckJs 双路径 | WebBook.kt:74-110、BookList.kt:62-108 | S0-E `4330acaf9`（search.rs:1214-1312） | ✅ |
| `+`/`-` 前缀、按 bookUrl 去重、LinkedHashSet 保序 | BookList.kt:90-147 | split_book_list_prefix/dedup（search.rs:1496/1508） | ✅（dedup 键多书名，方向=我们更多） |
| precision 三字段"或"语义 | SearchModel.kt:121-125 | precision_filter_match（search.rs:1455） | ✅（仅 JS 源漏，见 D4） |
| 聚合四分桶 + 桶内 name+author 合并 origins + origin 数排序 | SearchModel.kt:146-215 | _addToBuckets/_materializeResults（search_notifier.dart:386-369） | ✅，`_keepOther=!precision` |
| 规则语法 `\|\|`/`&&`/`%%`/`##`/`@js:` | AnalyzeByJSoup.splitRule | html.rs:620 + analyze_rule.rs:626-671 批量回退 | ✅ |
| HTTP：UA 默认、Cookie 持久化、重定向、GBK 解码 | OkHttp | client.rs + http_state DbCookiePersistence | ✅ |
| 换源排序 | bookScore→sourceScore→originOrder | source_matcher.rs:113-122 | ✅（仅序） |

### 4.2 分叉清单与状态

| 项 | 原始发现 | 最终状态 |
|---|---|---|
| D1【P1】换源分组分隔符缺 `;`/`；`，`;`分隔组的书源被 Dart 预过滤整源丢弃 | `change_source_notifier.dart:84` `[,，]`、`change_source_screen.dart:121` `split(',')`；Rust 侧 `source_group_contains` 四分隔符齐全但被架空 | ✅ **已修**：两处均改为 `RegExp(r'[,;，；]')`。主搜索侧 `_splitGroupRegex` 一直完整——解释了"搜索正常、换源变少"的不对称 |
| D2【P1】换源剔除"无详情页 URL"候选（原版回退 baseUrl 照常入列表） | `source_switch.rs` search_for_switch `filter(!book_url.is_empty())`（Task #21） | ✅ **已修（对齐原版）**：不再过滤，空 URL 候选保留展示、切换时 `switch_book_source` 兜底报错（注释引 BookList.kt:281-284） |
| D3【P2】一次性入口 `search_books`/`multi_source_search` 不落库，换源 DB 缓存偏少 | 仅 `run_multi_stream` 有 `persist_search_books`（search.rs:619-621）；原版两入口最终都落库 | ❌ 未修（当前 UI 仅用流式主路径，无实际影响；或文档钉死仅流式入口为生产路径） |
| D4【P2】JS 书源绕过 precision filter | `search.rs:1041` 提前 return `search_js_source`；原版 filter 传入 `JsSourceBook.searchAwait`（WebBook.kt:47） | ❌ 未修 → 并入 §五 N4（精准搜索开启时 JS 源多出未过滤行） |
| D5【P3】换源筛选框 `sourceName\|\|bookName` 比原版仅 name 更宽 | change_source_screen.dart:478-486 | ❌ 未修（方向=更多，低优先） |
| D6【P3】同名归一化（剥首尾括号/作者规范化）比原版字面全等更宽 | source_matcher.rs:178-215；DB 路径传 `format_book_name` | ❌ 未修（方向=更多，低优先） |

### 4.3 环境级嫌疑（对比前必须排除）

- **E1【P0 关联】ARM32 真机**：v7a 无 QuickJS（§三.1 决策闭环为"剔除 v7a JS"）——所有 `@js:` 规则书源静默空，搜索/换源都会大幅少于原版。x86_64 模拟器不受影响。**任何结果数量对比前先确认 APK ABI 与 quickjs 状态。**
- **E2 书源库与配置基线**：双方书源库同源同快照、启用数一致、`precisionSearch`/`changeSourceCheckAuthor`/`searchGroup`/`changeSourceLoad*` 配置一致（原版换源开启 loadInfo/Toc/WordCount 时自己也会因抓取失败丢候选）。
- **S0-C 原版端终态证据**：重构端 7 夹具源确定性通过；原版端受 LDPlayer + release + 盲操作约束无法自动化闭环（§8.6 保持 DEFERRED 不标绿）。续作三路径：① debug 原版 + run-as 直导 DB；② 禁用真实源仅留夹具源重搜（成本最低，推荐）；③ Android Studio 官方模拟器（10.0.2.2 主机别名）。

---

## 五、第三轮新发现（2026-09-03）

### N1【P0·新引入】听书前台服务未注册 manifest——播放即崩（虚假闭环）

- `MediaSessionBridge.kt:331-340`：每个播放态变化（playing/buffering）无条件执行 `ctx.startForegroundService(Intent(ctx, PlaybackForegroundService::class.java))`，stopped 才 stopService；
- `PlaybackForegroundService.kt` 存在于 `app/src/main/kotlin/io/legado/flutter/`，但 **`main`/`debug`/`profile` 三个 AndroidManifest 均无该 `<service>` 声明**（逐文件 grep 确认）；manifest 仅 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC`，缺 Android 14 要求的 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`，也无 `android:foregroundServiceType="mediaPlayback"`；
- **后果**：Android 8+ 上 startForegroundService 指向未注册组件抛 `IllegalStateException` → 用户一点开听书/音频播放即崩溃。比修复前（后台被冻结）更严重。台账"manifest 注册与权限…冒烟通过"未覆盖播放链路，属虚假闭环。
- **修复面极小**：manifest 注册 service（mediaPlayback 类型，exported=false）+ 补权限。

### N2【P3】旧假成功桩残留为可回潮死代码

`legado-core/src/auto_task.rs:199-205` `do_custom_js` 仍被 `AutoTaskRunner::execute`（auto_task.rs:134）引用。当前生产入口（auto_task_api.rs:92）已截获 Custom，但未来任何直接调 `AutoTaskRunner::execute` 的新代码会重新踩中假成功。建议删除该分支或改为返回明确错误。

### N3【P1】Web 服务功能域未接线

原版"Web 服务"（设置开关启动 server → 浏览器访问书架/传书/网页阅读，webPort 1122）在重构轨只有设置项外壳：`other_settings_screen.dart` 有 Web 服务唤醒锁、端口设置（L80/443/671），但 `startServer` 全库零调用（`rust_api.dart:1962` 定义后无人调）；`legado-server` crate 能力齐备（auto_task REST 等路由）但进程内从未启动。功能域="有设置、无服务"。与 §二.7/§二.8 同一决策簇，建议一并设计。

### N4【P2】= D4 未修（JS 源绕过 precision filter）

### N5【P3】两处新登记的简化点

- `legado-net/src/source_checker.rs:511`：书源调试"简化实现：提取第一个 href 链接作为章节 URL"——只影响调试信息精度，评估对齐；
- `legado-ffi/src/api/reader.rs:307`：getChapterUrl 简化（返回章节 URL 供 Dart 处理）——注释自述设计内，建议在 STUB 台账补登记。

### N6【P2·卫生】38 个未提交改动，其中 13 个生成代码

`models/*.freezed.dart`、`*.g.dart` 等 13 个生成文件 + 2 screens + services/providers 处于已修改未提交状态——codegen 漂移或在途批次。生成代码漂移会让"干净树编译失败"（G4 `bb521c366` 已发生过一次）重演，本批次完成后须成组提交。

### N7【P3】rust-ci 仍缺 `cargo audit`（依赖漏洞门禁）

---

## 六、文档口径与治理

| 项 | 状态 | 说明 |
|---|---|---|
| Active Plan P3-6 口径矛盾（08-28 发现） | ✅ 已解决 | 总表挂 2026-08-29 进度更新，与专项计划一致 |
| S0 DEFERRED 台账 | ✅ 清晰 | §8.6 明确"重构端通过、原版端环境阻断，保持 DEFERRED 不标绿" |
| AGENTS.md 冒烟端口口径 | ❌ 未同步 | 仍写 5556/5558，实际本轮为 5554/5556 |
| **虚假闭环教训** | ⚠️ 新增 | §一.2 案例表明"冒烟通过"不覆盖播放链路；听书/音频验收必须含"实际播放 ≥10s + 退后台续播 + 崩溃检查"步骤（建议冒烟脚本新增 -CheckPlayback） |

---

## 七、验证确认的良好面（避免误伤）

- 搜索三入口解析器统一（`search_single_source → parse_search_response_ex`），S6 驱动器分叉已消除；originOrder 透传 `customOrder`；会话级取消 + ptr_eq 身份复检 + 持久化前丢弃质量良好。
- Flutter 业务代码显式 TODO 仅 2 处（均为已登记素材项）；Rust 业务 crate 无 `unimplemented!`/`todo!`（唯一命中在 FRB 生成代码，属已登记不可达项）。
- 搜索页流订阅/定时器清理完整；排版引擎 `Isolate.run`/`compute` 隔离。
- 页面对照原版无整域缺失（原版 ui/widget 仅自定义控件库）；`legado-book` 格式面完整（txt/epub/mobi/umd/pdf/导出，除 §三.13 两项）。
- Cookie 持久化（Task #72，DB 崩溃恢复不丢）、G4 限速、UA 兜底、GBK 解码、非 2xx 仍解析等网络语义对齐原版。
- 修复治理机制运转良好：台账/复查/决策登记（v7a/REST/S0-C）闭环纪律成立（除 §一.2 一例外）。

---

## 八、改进方案与执行计划

### 批次 1（P0·发版阻断，改动极小）

- **N1**：manifest 注册 `PlaybackForegroundService`（`android:foregroundServiceType="mediaPlayback"`、`exported="false"`）+ 补 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 权限。
- 验收：模拟器实际播放听书 ≥10s + 退后台 60s 续播 + 崩溃检查；冒烟脚本考虑新增 `-CheckPlayback`。

### 批次 2（P1·功能收口，同一决策簇）

- **N3 + §二.7 + §二.8 合并设计**：① 若本版交付 Web 服务：设置开关 → `startServer(webPort)`，双 DB 访问统一（server 复用 FFI db_state 连接或下沉共享 DB 层）；② 若不交付：删除 REST 死降级路径与设置壳，`auto_task_notifier` 改纯 FFI + 失败可见，移除 `package:http` 依赖（连带 §四.17）。
- 验收：`flutter analyze/test` + 5556 冒烟 +（若交付）PC 浏览器访问书架实测。

### 批次 3（P2·parity 收尾）

- **N4/D4**：`search_js_source` 加 precision 参数并套用 `precision_filter_match`（对齐原版 filter 传参），补 1 个 quickjs 单测；
- **D3**：一次性入口补 `persist_search_books`，或文档钉死仅流式入口为生产路径；
- **§二.4 字体反爬**：实现真实 cmap format 4/12 解析（对齐原版），离线字体样本单测。

### 批次 4（P2/P3·健壮性与卫生）

- §二.8（若批次 2 未含则单列）；§三.9 内存限制测试在 CI Linux runner 启用；N2 删除死桩；N5 两处简化点评估/登记；N7 补 `cargo audit`；N6 在途批次成组提交；§三.12 剩余锁逐步收敛。

### 批次 5（P3·长期）

- §四.16：5 个超 1400 行文件拆分 + 阅读器/书架 golden 快照基线（UI 自由风格下防回归）；
- S0-C 按三路径择机闭环（推荐"仅保留夹具源"路径）；
- upstream diff 专项：原版 3.26.082823 新增/变更特性 → Flutter 轨跟进评估清单。

---

## 九、状态口径

| 口径 | 定义 |
|---|---|
| ✅ 闭环 | 有源码落点 + 独立实测验证 + 关闭提交 |
| ✅ 决策闭环 | 有明确决策记录（含理由与替代措施），非工程完成 |
| 🟡 部分闭环 | 主路径已修，残留子项单独登记 |
| ❌ 未修 | 已登记待批次，不得宣称完成 |
| ⚠️ 虚假闭环 | 台账/提交声称完成但实测推翻（本报告 §三.2 → N1 案例为唯一一例） |

---

编写者：GLM-5.3-Flash ｜ 2026-09-03
（整合来源：REFACTOR_DEFECT_AUDIT_20260828.md ｜ SEARCH_CHANGE_SOURCE_PARITY_AUDIT_20260829.md ｜ 2026-09-03 第三轮核对）
