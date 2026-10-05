# 下一批开放项核实调研报告（2026-10-04）

- 调研性质：只读核实（未改任何文件、未动设备；本报告为唯一产出）。
- 基线：HEAD `4c1a4c27c0`（2.0.353+354，B2 音频预下载写入面交付后）。
- 方法：`docs/REFACTORING_ACTIVE_PLAN.md`（下称 Active）登记逐项对当前代码核实；中文搜索一律用 `rg`（Git Bash `grep` 中文不可信）；桩函数逐个回查消费方，不以"存在桩"下结论。
- 结论速览：历史登记八项中 **5 项已实际关闭**（v7a / §二.4 / §二.7 / §三.9 / S0-C），**3 项仍开放**（§二.8 潜伏、§四.16 建议裁决关闭、S0-D 低优）；B2 遗留三条中 **SAF 目录不建议做**、**事件刷新搭车做**、**清理面锁值得做**；另找到 5 项计划外真实缺口，其中 2 项属音频轨道顺延、3 项为目录页/朗读引擎缺口。

---

## 一、任务 1：Active 计划「仍开放」登记逐项核实（Active:486）

### §一.1 v7a —— 已关闭（裁决已落地）

- **证据 1（回退逻辑真实存在）**：`rust/scripts/build-android.ps1:216-225` 每个 ABI 先以 `--features quickjs` 构建，`:225` `$QuickJsUsed[$key] = ($buildExit -eq 0)` 记录真构状态；`:241` `quickjs build failed; retrying without quickjs ...` 回退无 quickjs 重编；`:286` `quickjs = [bool]$QuickJsUsed[$key]` 写入指纹元数据。v7a 降级 .so 经此路径产出，与 P2-16 实证一致。
- **证据 2（裁决闭环）**：P2-24 已于 2026-09-27 关闭（Active:497-499，用户复核维持降级现状）；派生的 P2-25（flutter-release.yml armv7 直传 quickjs 矛盾）同日以 `b991c9d53b` 修正（Active:502）。
- **结论：已关闭。** 无残留动作。

### §二.4 cmap —— 已关闭

- **证据**：`rust/legado-js/src/host_api/query_ttf.rs:290` `parse_cmap`（cmap format 0/4/6，多子表按记录顺序，文件头注释 :5-12 说明与原版 QueryTTF.java 的取舍）、测试 :589/:634/:643 在库；`legado-core/src/query_ttf.rs` 死桩已删（Active:471-472，`9f58655`）。
- **结论：已关闭。** Active:486 的「下一批次」措辞已被 2026-09-03 整合审计的核实更正（Active:471）取代，属登记滞后。

### §二.7 AutoTask REST 死路径 —— 已关闭

- **证据**：提交 `68eb9e785f`（fix(ui): 听书前台服务注册 manifest + AutoTask 删 REST 死降级）；当前 `flutter_legado/lib/src/providers/auto_task/auto_task_notifier.dart:1-8` 已无 `package:http` import（:24 仅存解释性注释）；且 `startServer` 已真实接线（`flutter_legado/lib/src/screens/settings_screen.dart:87`），Web 服务已交付（P5-1 于 2026-10-01 关闭，Active:635-636）。
- **结论：已关闭。** 原「REST 删除=对齐原版」裁决后来被「交付 Web 服务」路线取代（整合审计 :180 方案①），死路径本身已在 P5-2 清理批删除。

### §二.8 Server/FFI 双 DB 连接 —— 仍开放（潜伏，随 Web 服务交付价值变化）

- **证据**：`rust/legado-server/src/state.rs:13` `pub db: Mutex<Database>`；`rust/legado-server/src/server.rs:44` `legado_server::start_server` 自行 `init_database(&config.db_path)`；`rust/legado-ffi/src/api/server_api.rs:114` `server_start` 传 `db_path: "legado.db"`——server 打开的是**自己的连接**，非 FFI `db_state` 单例。缓解因素：连接层统一 WAL + busy_timeout=5000（`rust/legado-db/src/connection.rs:27,36`），同文件双连接在 WAL 下功能正确。
- **交叉证据**：V2 审计（`docs/REFACTOR_DEFECT_AUDIT_V2_20260902.md:97`）标注「已治」与代码现状**矛盾**；整合审计（`docs/REFACTOR_CONSOLIDATED_AUDIT_20260903.md` :27/:171）把 §二.8 归入「Web 服务决策簇」且统一方案（server 复用 FFI 连接或下沉共享 DB 层）从未实施。P5 尾项 `aa49874137`（2026-10-02）接入的是 server 自身 AppState DB（提交正文自述「按 AppState DB 装配三闭包」），未改变双连接格局。同簇相关登记：`legado-server` 无 cookie sink，server 侧 JS 写 cookie 仍内存态（Active:265/283，最小方案 ~40 行）。
- **结论：仍开放（潜伏设计项）。** 现状 WAL 下可正确运行，但 server DB 面越扩越大（P5 连续三批扩 REST 能力），建议与「server cookie sink」合并成一个低优设计小批，**需用户裁决**是否统一连接。

### §三.9 内存限制测试 —— 已关闭

- **证据**：`rust/legado-js/src/engine.rs:996` `test_sandbox_memory_limit`（512KB 上限 + 200MB 分配断言 OOM），`:991-995` `#[cfg_attr(windows, ignore)]` 带书面理由（Windows 历史同型 ACCESS_VIOLATION，当前脚本实测 Windows 不崩、需要时删注解即可恢复），Linux CI 正常跑（Active:474）。
- **结论：已关闭。**

### §四.16 超长文件拆分 + golden 基线 —— 形式上仍开放，建议裁决关闭

- **证据**：全仓无 golden 测试（`flutter_legado/test/` 下 `grep -i golden` 零命中）；当前非生成类超 1400 行文件 9 个：`reader_comic_screen.dart` 3403、`theme_config_screen.dart` 2389、`bookshelf_screen.dart` 1664、`md3_colors.dart` 1643、`manga_config_sheet.dart` 1609、`book_api.dart` 1569、`reader_top_bar.dart` 1528、`audio_notifier.dart` 1494、`toc_screen.dart` 1476。
- **评估**：登记动机是「UI 自由风格下防回归」——该前提已被参考版对齐 + 像素级取证流程取代；文件拆分属纯重构、无用户可见收益（按本项目纪律不立项）。
- **结论：建议向用户裁决后关闭（维持登记不改）。** 若未来做拆分，唯一有工程收益的候选是 `reader_comic_screen.dart`（3403 行，四批功能持续堆叠）。

### S0-C —— 已关闭

- **证据**：`docs/SEARCH_PARITY_S0C_CLOSURE_20260903.md`（2026-09-03 双包同机 5/5 集合级 parity 闭合，Active:483）。
- **结论：已关闭。**

### S0-D 搜索性能剖析 —— 仍开放（探针就绪，剖析未做，当前低优）

- **证据（已做部分）**：分段计时探针在库——`rust/legado-ffi/src/api/search.rs:671/1151/1459/1637` 四处 `[S0-D | 任务 B 2026-09-19]` 计时点，env 门控 `LEGADO_SEARCH_PHASE_TIMING`；2026-09-20 批补 session 关联（Active:463）。
- **证据（未做部分）**：`docs/` 全目录搜索 `S0-D|profil|timing` 无剖析报告；「跑探针→与原版同基线对比→出结论」从未执行。
- **评估**：真实瓶颈已在 P3-4（debug .so 10 倍差、JS 引擎重建、封面 loader）修掉并经用户 2026-09-28 主流程验收（含搜索）。S0-D 的剩余价值是「系统性体检」，无已知痛点驱动。
- **结论：仍开放，建议维持登记不排期**；仅当用户再报「搜索/加载慢」时作为现成工具启用。

---

## 二、任务 2：B2 遗留三条独立评估（Active:773 已知边界①③⑤）

### ① 缓存目录 SAF 语义 —— 不值得做（维持登记，待用户主动提出）

**关键事实（任务书最关心的一点）：原版在现代 Android 上仍可用，但这不是追平的理由。**

- **原版语义 = 纯 opt-in**：`AudioCacheManager.kt:214-217` `getCacheRoot` 在 `treeUri.isNullOrBlank()` 时直接返回 null → `getBookFolder:205-211` 返回 null → 读侧 `getCachedAudio` 永不命中、写侧 `requireBookFolder:224-226` 抛「音频缓存目录不可用」。**原版用户不选目录 = 音频缓存功能整体不可用**；我方默认应用私有 `cache/audio_cache` 开箱即用，在「默认体验」上严格优于原版。SAF 只是原版的可选增强。
- **现代 Android 可用性**：`AudioPlayActivity.kt:114-137` 走 `HandleFileContract`（ACTION_OPEN_DOCUMENT_TREE），Android 11+ 仅禁选存储根/Download 等特殊目录，普通目录（音乐/SD 卡子目录）在 13/14/15 仍可正常选择授权——**原版语义没有死**。
- **用户实际差异**：原版选目录带来三点——缓存位置用户可控（如 SD 卡）、清除应用数据/卸载后文件仍在（文件留存于用户目录）、不受系统「清除缓存」与存储压力回收影响。我方 `cache/` 目录是 OS 可回收域：预下载几十 MB/章的音频可能被系统静默清掉，用户净耗流量。这是唯一实质风险点。
- **我方支持 SAF 的代价**：读面 §2.47 全走 Rust `std::fs` 路径、写面 §2.48 是 Rust 流式下载安装，`content://` 两者皆不可达；字节穿 FFI 违反 §2.46 反例红线。可行路线只剩：(a) Rust 经 jni 调 ContentResolver（工程量大、Windows CI 无法测）；(b) 折中——Rust 照旧下载安装到私有目录，Dart 用 `dart:io` 流式复制进 SAF 树、读侧命中判定 Dart 化或 ExoPlayer 直播 `content://`——读/写两条链全部双路径化。契约 §2.47/§2.48 均动。**L 级多日批**。
- **低成本补偿（可选，亦需裁决）**：把默认根从 `cache/audio_cache` 挪到 `files/audio_cache`（防 OS 回收、防「清除缓存」误伤），改动点仅 `set_audio_cache_dir` 注入值 + 存量目录迁移 + 契约注记，S 级；失去的是系统自动回收能力（需配容量上限策略才稳妥，原版也没有容量上限）。
- **结论：不值得主动做。** 无用户需求记录、原版同为 opt-in、我方默认更可用；仅登记「若用户提出缓存被清/要换目录再立项（L 级）」。若用户在意 OS 回收，可单裁 S 级「cache→files」补偿案。

### ② AUDIO_CACHE_CHANGED 事件驱动徽标 —— 低成本，建议搭车，不值得单独立项

- **实际差异**：原版每章安装完成 post 事件（`AudioCacheService.kt:222-225`）+ 目录订阅逐行刷（`ChapterListFragment.kt:196-208`），即时；我方目录页 1s 轮询（`flutter_legado/lib/src/screens/toc_screen.dart:268-283`，含 audioCacheList，仅音频书调用）。用户可见差异 ≤1 秒；轮询只在目录页打开期间跑、`audioCacheList` 是本地目录列举（毫秒级），耗电可忽略——且该轮询同时服务文本缓存/字数/下载中三份数据，事件化只能省掉其中一次 FFI 调用，Timer 本身省不掉。
- **可复用机制**：Flutter 侧**无全局事件总线**（`rg StreamController.broadcast|EventBus` 仅命中注释；目录刷新为轮询制）。但 B2 下载循环本就在 Dart（`flutter_legado/lib/src/screens/audio_screen.dart:1105` `_runAudioCacheBatch`），每章完成是 Dart 层事件——新增一个 `StreamController.broadcast()` 单例，章节安装成功/失败处 emit，`toc_screen` initState 订阅后立即执行既有轮询函数即可，**零契约、零 FFI、约 1 个小文件 + 接线 + 用例**。
- **结论：值得做但只配搭车**（并入音频收尾批），单独排批不划算。

### ③ 清理面未取章节锁 —— 值得做（与 P2-5 打包为「清理面对齐」小批）

- **真实风险**：`audio_cache_clear_chapter`（`rust/legado-ffi/src/api/audio_cache_api.rs:355-364`）不取 16 片锁，是同步 FFI 在 UI isolate 执行。不取锁的后果 = 用户清理某章恰逢该章在途下载：轻则文件复活（下载完成步骤覆盖清理结果，违背用户意图）、重则互删（净效果缓存丢失、重下耗流量）；无跨章污染、无崩溃。概率低但 UI 可达（菜单未在运行中禁用，对齐原版原版也无禁用）。
- **取锁的正确姿势 = async 化而非直接加锁**：同步 FFI 直接取锁会阻塞 UI isolate 至多 60s（下载全程持锁）→ 真 ANR 风险。修法是把 Rust 导出改 `async fn` + `spawn_blocking` + 分片锁：`rust/legado-ffi/src/ffi.rs` 已有 12 处 `async fn` 导出与 `run_webbook_blocking`（:62）spawn_blocking 先例；Dart 侧签名本就是 `Future<int>`（`book_api.dart:904`），FRB async→Future 映射使 **Dart 调用方零改动**；契约 §2.47 仅措辞微调（同步→异步）+ codegen 再生。
- **顺带同批项**（同属清理面语义，B2 交付时登记待裁决）：
  - P2-5/B2 审查 P2-1：目录仅剩 `.complete` 标记时 clear 返回 0 → UI 报「本章没有缓存」，原版 `hasCacheFiles:374-383` 含标记 → 报「已清除本章缓存」，语义相反（`docs/B2_AUDIO_PREDOWNLOAD_CODE_REVIEW_20261004.md:49`）；
  - B1 登记的旧孤儿文件（`${bookUrl.hashCode}_$i.audio`，support/SAF 目录）清理指引——原计划「择机在预下载服务批一并处理」，B2 已交付，可在本批或下一 UI 批落实。
- **结论：值得做。** S-M 级（Rust 1-2 文件 + 契约措辞 + codegen + Dart 1 文件 + 测试），修复真实误报与竞态，风险低。

---

## 三、任务 3：计划外真实缺口（主动搜索结果）

搜索方法：`rg "TODO|FIXME|XXX|HACK"`（rust/ 全部命中为 `pos:fid:XXXX` 类文档示例，零真标记）；`rg "unimplemented!|todo!|not implemented"`（仅 `frb_generated.rs:10531` codegen 样板，非业务）；中文桩标记 `待实现|未实现|暂不支持`（43 命中逐条过目，全部为诚实报错——Unsupported 算法族对齐原版 Crypto 行为、HLS/多段音频拒绝逐字对齐原版 `requireCacheablePlayUrl`）；Mock 桩全部经 `USE_MOG` 编译期门控（`providers.dart:16-17`，默认 RustApi）；非 quickjs 档 `md5_encode_16` 占位（`encoding.rs:389-403`）无活消费方（唯一调用 `quickjs_impl.rs:1292` 在 quickjs 门控内）。契约一致性：`flutter test test/unit/api_contract_test.dart` **7/7 全绿**（BookApi 290，登记与实现无漂移）。

真实缺口清单（按影响排序，前 5 条）：

1. **目录页 ERROR 态恒不显示（失败数据源缺失）**——`flutter_legado/lib/src/screens/toc_screen.dart:43,76,166-168`：红色重试图标的数据源 `failedChapterIndicesForTest` 是测试注入缝，生产恒空 → 文本书离线缓存失败在目录页完全不可见、不可就地重试（参考版 ERROR→红重试可点）。修复需 Rust 下载任务表记录失败章 + 只读 FFI（可扩展现有 `cacheDownloadRunningChapters` 同型）。**M 级**。P2-29/P2-29b 登记留项，与主流程「离线缓存」直接相关。
2. **目录页未缓存 ⬇ 图标不可点击（参考版可点击单章下载）**——`toc_screen.dart:1131-1133` 图标无手势；`_retryChapterDownload`（:920，ERROR 分支复用 `cacheDownloadStart(idx,idx)`）已存在，NONE 分支未接线。参考版 `canDownload = NONE || ERROR` 同源。**S 级**，可与上一条同批。
3. **朗读条定时停止为页面级本地 Timer（转后台静默失效 + 到点 pause ≠ 原版 stop + 通知无剩余量）**——`flutter_legado/lib/src/widgets/reader/read_aloud_bar.dart:63`（`Timer? _stopTimer`）、:97-98（dispose 即 cancel → 用户设了定时、退出阅读页后朗读永不停且无提示）、:156-175（到点 `pause()`，原版 `BaseReadAloudService.kt:596-599` 到点 `stop`）。`AudioNotifier` 侧 API 全部现成（`audio_notifier.dart:967/984/996`），迁移约 1 文件 + 测试，0.5-1 天；**到点动作 pause→stop 属用户可感知行为变更，需裁决**（`docs/AUDIO_REMAINING_GAPS_SURVEY_20261003.md` 缺口③已给完整证据链）。
4. **引擎管理页行不可选 + 默认引擎不持久化**——`flutter_legado/lib/src/screens/read_aloud_config_screen.dart:184-220` 行无 onTap；`TtsConfig.engineUrl` 仅内存，重启后由 `_ensureDefaultEngine` 自动选（用户选择丢失）；书级 `readConfig.ttsEngine` 字段在模型中就绪但全库无写入点。持久化层级（全局/书级/维持现状）**需用户裁决**后 0.5-1.5 天（同上调研 缺口②主体）。O1（点已选项不关对话框）已在 2026-10-03 修复（`read_aloud_bar.dart:306-340` toggleable 统一 onChanged），不再列为缺口。
5. **§二.8 双 DB 连接 + server 无 cookie sink（潜伏面随 Web 服务扩大）**——见任务 1 §二.8；两者同属「Web 服务数据一致性」簇，合并为低优设计小批。

未发现新问题的方向（如实记录搜索边界）：`rust/` 无未实现宏、无可疑固定值桩；`flutter_legado/lib` 无生产可达的 Mock；契约登记与实现程序化一致。

---

## 四、任务 4：下一批建议（排序）

队列方向（Active:538）为媒体轨道音频收尾 → 其他（设置/RSS/Web）→ Characters/RelatedBooks+AI 摘要。据此给出三个候选：

### 候选 1（首推）：音频轨道收尾组合批

- **内容**：① 朗读条定时下沉 `AudioNotifier`（缺口 3，复用现成 API）；② 清理面对齐——`audio_cache_clear_chapter` async 化 + 取 16 片锁 + P2-5 标记-only 返回值语义 + 旧孤儿文件清理；③ AUDIO_CACHE_CHANGED 等价事件（Dart broadcast，搭车）。
- **解决什么**：退出阅读器后定时静默失效（用户可感知缺陷）；清理竞态与「本章没有缓存」误报；徽标 ≤1s 延迟收敛为即时。
- **规模**：M（Rust 2 文件 + 契约措辞微调 + codegen 再生 + Dart 3-4 文件 + 新用例约 15-20）。
- **风险**：低-中。② 动 FFI 导出形态（有 spawn_blocking 先例、Dart 签名不变）；① 的 pause→stop 是行为变更。
- **需裁决**：两点——到点动作 stop 与否；P2-5 返回值口径（B2 已登记待裁决）。
- **为什么先做**：全部是 B2/音频批次主代理亲登记的待裁决项与顺延项，证据与口径齐备、几乎无设计成本；做完即可正式宣布音频轨道收口，严格符合既定队列；且 ③②① 三项彼此独立可并行派发。

### 候选 2：目录页缓存交互补齐（ERROR 数据源 + NONE 点击下载）

- **解决什么**：离线缓存失败在目录页不可见不可重试、未缓存章不能点图标单章下载（参考版均可）。
- **规模**：M（ERROR 需 Rust 失败记录面 + 只读 FFI/扩展 + 五态渲染接数；NONE 复用 `_retryChapterDownload` S 级）。
- **风险**：低（加法式只读 FFI，C2b/P2-28c 同型授权先例）。
- **需裁决**：无需（P2-29b 已登记增量需求；FFI 同型授权有先例，按流程确认即可）。
- **为什么第二**：用户可见度高且贴主流程，但需先做 Rust 失败记录设计，比候选 1 略重。

### 候选 3（裁决驱动）：朗读引擎默认引擎持久化层级

- **解决什么**：引擎管理页行不可选、重启后用户引擎选择丢失。
- **规模**：裁决后 0.5-1.5 天（全局 config / 书级 `readConfig.ttsEngine` / 维持会话级三选一）。
- **风险**：中（持久化层级影响合成链取值优先级）。
- **需裁决**：是（候选中唯一纯裁决驱动项）。
- **为什么第三**：不裁决就无法开工；影响面（听书用户重启场景）小于前两项。

**明确不建议排期**：SAF 缓存目录（L 级、无需求记录，若用户在意 OS 回收可选 S 级 cache→files 补偿案单裁）；§四.16 拆文件/golden（无用户可见收益，建议裁决关闭）；S0-D 剖析（无痛点驱动，工具已就绪随取随用）；§二.8 + cookie sink（低优设计批，可与「其他（设置/RSS/Web）」站合并考虑）。
