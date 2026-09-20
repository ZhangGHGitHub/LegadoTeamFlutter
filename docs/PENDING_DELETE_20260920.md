# 目录清理 · 执行记录与待裁决清单（2026-09-20）

> 性质：项目目录整理的分级复核、执行记录与遗留裁决清单。
> 执行：主代理（ZCode 本机通道）｜ 2026-09-20
> **状态：主体清理已执行完毕——释放约 302G，`D:` 可用空间 171G → 473G。** 过程分两阶段：先「移动到 `_pending_delete/` 暂存区」（不删任何东西），经调用链复核后再实际删除。仍保留待裁决的项见 §6.2 末表与 §3.7。

---

## 〇、结论摘要

| 项 | 数值 |
|---|---|
| 第一阶段：暂存区 `_pending_delete/` | **300G**（其中 `rust/target` 单独 292G），276 项根目录残留 + 构建产物 8 项 + 取证目录 5 项 + `probe_icon` |
| 第二阶段：实际删除 | **约 302G**（暂存区整体 + `.e2e_*` 1.4G + `tmp_debug`/`tmp_parity`/`.tmp` 零引用项） |
| 源码改动 | **无**（未改任何源码；P1~P10 交开发 agent） |
| 提交 | `b99538b891`（本文档 + `.gitignore`）、`bb08c173bc`（`probe_icon` 移除，52 文件） |
| 磁盘 | `D:` 可用 **171G → 473G**（使用率 88% → 66%） |
| 第三部分复查 | 7 项全部核查完毕；**其中 2 项初版判定经二次复核被推翻**（见 §3.4 `.tmp/dbsrc`、§3.7 `parity_shots`） |
| **第二轮（项目目录之外，§七）** | `D:\OH-WorkSpace\` 与 `D:\tmp` 的同类残留 **30G 已移入外部暂存区** `D:\OH-WorkSpace\_pending_delete\`，**未删除**，等待裁决 |

> ⚠️ **两处初版误判已在文中标注作废**，请以纠正后的结论为准——这是本次复核最大的收获：
> 1. **P1 严重度**：并非 19 个测试都"假绿"，只有**未标 `#[ignore]` 的 11 个**才是真问题（另 8 个静默跳过是刻意设计）。
> 2. **`docs/parity_shots/` 孤儿目录**：初版称 24 个孤儿，实为**误判**——按目录名全仓重搜后被现行 ledger 引用，**本次一律未动**。

---

## 一、曾移入暂存区的清单（**均已随 §6.2 删除**）

> 本节保留清单与依据，用于追溯"这些东西是什么、为什么可以删"。**全部条目已于 2026-09-20 随 `_pending_delete/` 删除。**

### 1.1 可再生的构建产物（零风险；删除后由构建链重新生成）

| 源路径 | 暂存位置 | 大小 | 备注 |
|---|---|---|---|
| `rust/target/` | `_pending_delete/rust/target` | 292G | cargo 构建缓存；删除后下次 `cargo test/build` **全量重编** |
| `flutter_legado/build/` | `_pending_delete/flutter_legado/build` | 5.2G | Flutter 构建输出 |
| `flutter_legado/windows/flutter/ephemeral/` | 同构路径 | 309M | Flutter 工具自管目录，自动重建 |
| `flutter_legado/android/app/src/main/jniLibs/` | 同构路径 | 105M | 由 `rust/scripts/build-android.ps1` 生成 |
| `node_modules/` | `_pending_delete/node_modules` | 69M | 只服务根 `package.json` 的 commitizen；**`.git/hooks` 无任何 hook，实际未接线** |
| `.gradle/` | `_pending_delete/.gradle` | 26M | Gradle 缓存 |
| `build/`（仓库根） | `_pending_delete/build` | 136K | Gradle reports |
| `.kotlin/` | `_pending_delete/.kotlin` | ~0 | Kotlin 2.0 sessions 缓存 |

**风险**：无。若裁决保留，回移后增量编译缓存原样可用（同盘 rename 秒级）。

### 1.2 根目录一次性调试残留（276 项 / 1.3G）

全部移入 `_pending_delete/root_tmp/`（保持原名扁平存放）。构成：约 60 个 `.tmp_*.py` 探针脚本、约 50 个 `ui_*.xml` uiautomator 转储、20+ 张截图、若干库快照与日志。

其中体积较大的：

| 条目 | 大小 | 说明 |
|---|---|---|
| `tmp_device_probe/`（apk 375M + apk_new 227M） | 609M | 设备探针审计的 APK 与产物；该审计已收口 |
| `.tmp_our_legado.db`(+shm/wal) | ~48M | 我方运行时库快照 |
| `.tmp_hostscan.db` | 43M | 源站扫描库 |
| `.tmp_5558_live2.db` | 39M | **雷电档**（已废弃档位）库快照 |
| `.tmp_orig_live.db`(+shm/wal) | ~11M | 见下"保留项" |
| `.tmp_ipa` / `.tmp_ipa23` / `.tmp_ipa_check` / `.tmp_ios_check` / `.tmp_plist` | ~20M | iOS 图标/旁载探查残留（该任务已收口） |
| `.tmp_run_a` ~ `.tmp_run_a8`、`.tmp_dbg_flow`、`.tmp_nav_src`、`.tmp_e2e_*`、`.tmp_gh`、`.tmp_exp_submit` | ~10M | 一次性驱动产物 |
| `tmp_n2/` | 40K | 零引用 |

**保留未移入的 5 项**（依据见 §四.5）：

| 条目 | 大小 | 保留原因 |
|---|---|---|
| `tmp_debug/` | 558M | 被 **19 个** Rust 测试（26 处读取点）当夹具读取，详见 §三.6 |
| `tmp_parity/` | 835M | 是 Rust 测试的输出目标目录，详见 §三.2 |
| `.tmp_orig_live.db` + `-shm` + `-wal` | ~11M | 被入库文档 `docs/SEARCH_SPEED_COUNT_ROOT_CAUSE_2026-08-25.md` 引用为观测点 |

### 1.3 大块一次性取证目录（5 项 / 448M）

| 源路径 | 大小 | 依据 |
|---|---|---|
| `expired_2026-08/` | 424M | 目录名即"过期"；含 `app-debug.apk` 251M + 5 个 `_verify_batch*`；仅被 `docs/过期文档/` 引用 |
| `_debug_51manga/` | 24M | 仅被 `docs/过期文档/AUDIT_FIX_TASKS_20260814.md` 引用 |
| `_verify_batch4/` | 空（仅 `http_root/` 空壳，0 文件） | 仅被 `docs/过期文档/REFACTORING_AUDIT_REPORT_20260810.md` 引用 |
| `.e2e_p03_5558/` | 288K | **零引用** |
| （`tmp_n2/` 已并入 1.2） | — | — |

### 1.4 iOS 图标探针 App（用户已确认可删）

| 源路径 | 暂存位置 | 大小 | 性质 |
|---|---|---|---|
| `probe_icon/` | `_pending_delete/probe_icon` | 245K | **入库内容**：52 个 tracked 文件 |

**确认依据**：该工程是为判定"旁载语境下 app 能否切换桌面图标"而建的决定性隔离探针，配套流水线 `.github/workflows/probe-icon-build.yml`（注释写明"产出未签名 IPA，供用户用同一工具在同一设备旁载"）。iOS 换图标任务已于 **2026-09-03 收口**（A 降级 + C 文档化落地，企业签出局，见 `docs/IOS_ICON_SWITCH_LIMITATION_20260903.md`）。

> ✅ **已删除并提交**：`bb08c173bc`（52 个文件）。配套 CI 流水线的处置见 §四 P5（**待开发 agent 处理**）。

---

## 二、恢复方法（**已作废：暂存区已于 2026-09-20 实际删除**）

> 本节记录当初的暂存-回移机制，供日后复用同一工作流参考。**当前 `_pending_delete/` 已删除，以下命令不再适用。**

暂存区是**同盘 rename**，回移是秒级操作。任一条目按"从哪来回哪去"即可：

```powershell
# 示例：回移 rust/target
Move-Item D:\OH-WorkSpace\LegadoTeam\legado\_pending_delete\rust\target D:\OH-WorkSpace\LegadoTeam\legado\rust\target

# 示例：回移根目录残留（276 项整批）
Move-Item D:\OH-WorkSpace\LegadoTeam\legado\_pending_delete\root_tmp\* D:\OH-WorkSpace\LegadoTeam\legado\
```

**若需重新清理**：`.gitignore` 中的 `/_pending_delete/` 规则已保留，按 §一 的方式重新建立同名暂存区即可，`git status` 不会被污染。

---

## 三、第三部分复查结论（调用链核查）

> 本节为第二阶段的核查依据。**其中判为「可删」的项已按 §6.2 实际删除**；判为「保留」的项原地未动（`.tmp/dbsrc` 与 `docs/parity_shots` 两处判定经复核被推翻，已在对应小节标注）。

对 7 项大体积取证目录逐项核查"哪里在调用、后续还用不用"。**判定基准**：机器可读结论是否已入库 + 关联任务是否已收口 + 是否存在活调用点。

### 汇总表

| 项 | 大小 | 判定 | 一句话依据 |
|---|---|---|---|
| `.e2e_s0c/` | 1.1G | ✅ **可删** | S0-C 已闭合（2026-09-03），机读结论已入库 |
| `.e2e_r1v/` | 175M | ✅ **可删** | R1 换源实证已完成（2026-09-06），结论已入交接文档 |
| `.e2e_p03/` | 166M | ✅ **可删** | P0-3 已关闭（2026-08-20），机读 verdict 已入库 |
| `.tmp/` | 635M | ⚠️ **部分可删** | 4 个子项有活引用须保留，其余约 250 项零引用 |
| `tmp_parity/` | 835M | ⚠️ **目录必留、内含快照可清** | 目录是 Rust 测试输出目标；6 个历史 db 快照零引用 |
| `tmp_debug/` | 558M | ⚠️ **夹具必留、其余可清** | 3 个 json 夹具被 9 个测试读取；另 337M 零引用 |
| `docs/parity_shots/` | 245M | ⚠️ **33 个保留、24 个孤儿可清** | 两本 ledger/计划引用 33 个版本目录 |

### 3.1 `.e2e_s0c/`（1.1G）→ 可删

- **调用点**：`docs/SEARCH_PARITY_S0C_CLOSURE_20260903.md:6`（"原始 dump/XML/服务器 JSONL 见 `.e2e_s0c/`，不入库"）、`:58`（夹具服务器启动命令示例）；`scripts/s0c_run_same_device.py:36`、`scripts/s0c_compare.py:25`（`OUT = ROOT / ".e2e_s0c"`）。
- **引用者是否活跃**：否。`docs/REFACTORING_ACTIVE_PLAN.md:288` 明写"**S0-C 双包基线：已闭合（2026-09-03）**"。
- **机器可读结论已入库**：`docs/evidence/search_parity_20260903/s0c_report_same_device.json`（3.6K）+ `server_ref_v4.jsonl` + `server_same_device.jsonl`。CLOSURE 文档本身就注明原始 dump"不入库"。
- **内含**：`db/` 502M（设备库快照）+ `base.apk` 264M + `base2.apk` 292M（当时构建的安装包，属构建产物）。
- **残留说明**：两个驱动脚本保留（可复用，重跑会自行重建该目录）。

### 3.2 `.e2e_r1v/`（175M）→ 可删

- **调用点**：`scripts/r1v_switch_e2e.py:31`（`OUT = ROOT / ".e2e_r1v"`）、`:161`（拉起夹具服务器）。
- **引用者是否活跃**：任务已收口。`docs/TASK_HANDOFF_CHANGE_SOURCE_FIX_20260903.md:29` 记录 R1 变量链模拟器 E2E 于 **2026-09-06** 完成同机对照实证（修复前 `.so` vs 重建后 `.so`）；`docs/REFACTORING_ACTIVE_PLAN.md:220` 提及的是夹具脚本 `log_event` 参数缺陷，**已修**。
- **内含**：`app_legado.db` 171M（设备库快照）+ `db_v10/`、`db_u7/` 小快照 + shelfN.png。
- **注意**：交接文档同时记明"驱动脚本 `r1v_switch_e2e.py` 的 uiautomator 文本匹配在 2.0.203（MD3）不可用，本次按截图定坐标人工驱动，**脚本保留供后续适配**"——脚本要留，目录数据可删。

### 3.3 `.e2e_p03/`（166M）→ 可删

- **调用点**：`scripts/e2e_p03_cancel_research.py:43`（`OUT = ROOT / ".e2e_p03"`）；`CHANGELOG.md:2220`（历史记述）；`docs/SEARCH_PARITY_REMEDIATION_PLAN_20260828.md:321`（当时的证据归档说明）。
- **引用者是否活跃**：否。`docs/REFACTORING_ACTIVE_PLAN.md:38`"P0-3 **已关闭**（方案 B）"、`:90`"（已关闭 2026-08-20）"。
- **机器可读结论已入库**：`docs/evidence/search_parity_20260829/p03_e2e_5556_verdict.json`、`p03_e2e_5558_verdict.json`。
- **内含**：`legado.db` 165M + logcat/server JSONL。

### 3.4 `.tmp/`（635M / 310 项）→ 部分可删

**必须保留（有活引用）**：

| 子项 | 大小 | 调用链 |
|---|---|---|
| `corpus/` | — | `docs/RHINO_INTEROP_ANALYSIS_20260920.md`（**当日文档**）引用 |
| `ui/` | — | `scripts/parity_capture_ours.py`、`scripts/parity_capture_ref.py` 的输出目录（活跃采集脚本） |

**建议保留**：

| 子项 | 大小 | 原因 |
|---|---|---|
| `kazusa.apk` | 24M | 参考版 `io.legato.kazusa` 安装包，被 `docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md` 引用；模拟器重置后需重装才能复现视觉对比 |

**低风险可删**（引用仅为已关闭条目/历史记述）：

| 子项 | 大小 | 引用出处与现实 | 处置 |
|---|---|---|---|
| `dbsrc/`（含 `q7.db` 26M） | 305M | `docs/REFACTORING_ACTIVE_PLAN.md:167` 属 **P2-6/P2-7（已关闭 2026-09-19）**，但该条目同时写明"**待用该源 + 真实响应离线复现后定性**" | ❌ **保留（初判作废）**——活跃台账标注为"仍可能需要"，不承担误删风险 |
| `p8_db/` | 155M | 仅 `CHANGELOG.md` 历史记述 | ✅ 已删 |
| `legado-with-MD3/` | 67M | 初判为"被 UI_MD3 文档引用"**不准确**：`docs/design_system.md:12` 引用的是上游仓库名 `HapeLee/legado-with-MD3@<commit>`，非本地目录；本地目录是该参考仓的克隆，可重新克隆 | ✅ 已删 |
| `pending_pushes_20260917.bundle` | 13M | **已核实冗余**：bundle 头指向 `4a4d1003d8`，该提交已在本地库且 `merge-base --is-ancestor` 判定可达 HEAD | ✅ 已删 |
| `ndk-shim/`、`wsl-diag/`、`a4_fixture/`、`device_verify_20260913/`、`diag_wangyue/`、`db_*_v9/` | — | 全仓零引用 | ✅ 已删 |
| 约 250 个一次性探针（`a0-a4.png`、`ui*.xml`、`bookinfo_08_*.py` 等） | 其余 | 全仓零引用 | ⏸ **本次未删**（体积可忽略、需逐文件核引用，收益不成比例） |

### 3.5 `tmp_parity/`（835M）→ 目录必留、内含历史快照可清

- **目录为何必留**：`rust/legado-ffi/src/api/web_book.rs:4532` 把它作为测试输出目标——`"/../../tmp_parity/scan_wave2.jsonl"`，`:4624` 写入（`let _ = std::fs::write(...)`，写失败被忽略）。目录缺失不会 panic，但会静默丢掉该测试的诊断输出。
- **可清内容**（均零引用，已逐个核实）：

| 文件 | 大小 |
|---|---|
| `flutter_live.db` | 309M |
| `flutter_live_5556.db` | 309M |
| `flutter_ok.db` | 156M |
| `flutter_5556.db` | 55M |
| `orig_5558.db` | 37M |
| `sources_5558.json` | 7.7M |

- **必须保留**：`scan_wave2.jsonl`（测试输出，会重写）+ `tmp_parity/` 目录本身。

### 3.6 `tmp_debug/`（558M）→ 夹具必留、其余可清

**必须保留（3 个夹具 + 1 个子目录）**：

| 子项 | 大小 | 调用链 |
|---|---|---|
| `e2e_5558/sources_device.json` | （含于 166M） | `rust/legado-ffi/src/api/web_book.rs`（**18 处**，如 `:3974 :4438 :4528 :4673 :4760 :4831 :4978`）、`explore_api.rs`（**8 处**，如 `:1110 :1207 :1325`）——共 **26 处读取点 / 19 个测试函数** |
| `sources.json` | 7.4M | `rust/legado-ffi/src/api/search.rs:3813`（`probe_all_image_sources_batch`，`#[ignore]`，**用 `.expect("sources.json")` 会 panic**） |
| `src_51.json` / `src_shen.json` | 20K | `rust/legado-ffi/src/api/search.rs:3748-3749`（`probe_manga_sources_from_tmp_debug`，`#[ignore]`） |

**可清内容（零引用，约 337M）**：`apk_verify/` 227M、`verify_0820/` 33M、`apk_x86.so` 29M、`biying/` 23M、`fl2.bin` 15M、`user_test_2026-08-13/` 13M、`verify_0819/`、`parity/`、`search_probe/`、`batch_diag/`、`apk_check/`，加上约 200 个 1–4K 的一次性探针脚本（`fix_*.py`、`add_*.py`、`dump*.py`、`commit_*.txt` 等）。

### 3.7 `docs/parity_shots/`（245M / 526 个入库文件 / 54 个子目录）

**保留 33 个**（被活文档引用）：`docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md` 引用的 `ours_2.0.259/261/262/264/269-283`、`ref_20260913`、`ref_batch4`；`docs/DARK_THEME_PARITY_LEDGER_20260920.md` 引用的 `baseline_flutter`、`ours_2.0.266`、`ours_dark_20260920`、`ref_batch3`、`ref_dark_20260920`；`docs/REFACTORING_ACTIVE_PLAN.md` 引用的 `queue_smoke_20260920`；另有 `ref_20260914`、`ref_batch2`、`pairs_latest`、`tmp_songhe`。

**⚠️ 本节初版判定作废（2026-09-20 二次复核纠正）**：初版称"24 个孤儿目录"，系**误判**——那次 grep 只在 `docs/*.md` 内按 `parity_shots/<name>` 前缀匹配，漏掉了不带前缀的裸目录名引用。按目录名**全仓**重搜后，多数"孤儿"实为**被现行 ledger 引用**：

| 目录 | 实际引用方 |
|---|---|
| `ours_2.0.256`、`ours_2.0.257` | `docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md` |
| `pairs_2.0.260`、`pairs_b2`、`pairs_b2_266`、`pairs_b3` | `docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md` |
| `ref_latest` | `docs/parity_shots/pairs_latest/INDEX.md` |
| 其余（`ours_2.0.258/260/263/265/268/273`、`pairs_2.0.261/262/263`、`pairs_20260914`、`pairs_b3_267`、`pairs_b4`、`ref_b2_map`、`ref_batch1_map`、`source_switch_fix_20260918`） | 仅 `CHANGELOG.md`（历史记述）与 `tmp_d11`（零引用） |

**结论：`docs/parity_shots/` 本次一律不动。** 这些是入库的视觉 parity 证据，误删会破坏 DoD 证据链，且收益仅约 30M，不值得承担误判风险。若日后要瘦身，须按上表逐目录确认后单独裁决。

**单独裁决项**：`tmp_songhe/`（**109M / 379 张截图**）命名带 `tmp_` 却混在证据目录里，被 `CHANGELOG.md` 与 `docs/RULE_TEMPLATE_SEGMENT_FIX_20260917.md` 引用。该修复属 **P2-6，已于 2026-09-18 关闭**（`REFACTORING_ACTIVE_PLAN.md:154`），故其引用属"已收口任务的历史证据"。建议：改名转存到正式证据目录后压缩，或直接删除（关联任务已关闭）。

---

## 四、需要修改的问题清单（交给开发 agent）

> 按优先级排列。前 3 项是**真实缺陷/风险**，后 7 项是**仓库卫生**。

### 【P1】Rust 测试夹具依赖仓库外相对路径，且缺夹具时"静默空跑仍报通过"

- **问题**：**26 处**测试用 `concat!(env!("CARGO_MANIFEST_DIR"), "/../../tmp_debug/e2e_5558/sources_device.json")` 读夹具（`web_book.rs` 18 处 + `explore_api.rs` 8 处，分布在 **19 个测试函数**中），缺失时一律 `eprintln!("...缺失，跳过"); return;`——**测试仍然 PASS**。同理 `web_book.rs:4532` 的输出目录 `tmp_parity/` 也在仓库外。
- **⚠️ 严重度需按 `#[ignore]` 二分（2026-09-20 复核修正）**：19 个里只有 **11 个是真正的问题**——
  - **8 个已标 `#[ignore]`**（如 `test_batch_search_scan_text_sources`、`test_77shuku_search_diag`、`test_js_network_sources_diag`，标注写明"非确定性 CI 测试"）：它们本就不在 CI 跑，静默跳过是**刻意设计**，无问题。
  - **11 个未标 `#[ignore]`**（`web_book.rs`：`test_jsoup_post_redirect_search_diag`、`test_qibuge_catalog_and_content_gbk`、`test_qibuge_search_diag`、`test_qiexs_search_diag`、`test_shushan_real_toc_repro`、`test_taoxiaoshuo_search_diag`、`test_xbqgxs_search_diag`；`explore_api.rs`：`test_aggregate_sources_common_explore_and_header`、`test_explore_real_jslib_get_config_visible`、`test_shushan_booklist_js_with_jslib_and_setup`、`test_shushan_header_rule_injected_to_global_headers`）：**它们在 CI 上会执行、找不到夹具、打印"跳过"、然后 PASS**。其中 `test_shushan_header_rule_injected_to_global_headers` / `test_shushan_booklist_js_with_jslib_and_setup` 从命名看是书山源修复的**回归测试**——却从未真正断言过。**这才是"假绿"的确切范围。**
- **建议**：(1) 把这 11 个或补 `#[ignore]`（若确属网络诊断）或把夹具迁入 `rust/legado-ffi/tests/fixtures/` 让它真正断言——**二者必居其一，不能维持现状**；(2) 夹具迁入后改用 `env!("CARGO_MANIFEST_DIR")` 定位；(3) 把"缺夹具即跳过"的沉默降级改为显式失败或 `#[ignore]`；(4) `search.rs:3813` 对 `tmp_debug/sources.json` 用 `.expect()`（缺夹具 panic）与同族代码姿态不一致，一并统一。
- **涉及文件**：`rust/legado-ffi/src/api/web_book.rs`、`explore_api.rs`、`search.rs`

### 【P2】`tmp_*/` 命名文件被入库，与 `.gitignore` 口径矛盾

- **问题**：`rust/legado-ffi/tmp_songhe.json`、`tmp_songhe_chapters.json`、`tmp_songhe_detail.json`、`tmp_songhe_search.json` 共 4 个文件**已入库**，但命名带 `tmp_`，且 `.gitignore` 中有 `rust/_*` 类规则的口径不一致（本次全仓清理时它们与临时物混在一起，极易被误删）。
- **建议**：移到正式测试夹具目录（如 `rust/legado-ffi/tests/fixtures/songhe/`）并去掉 `tmp_` 前缀；或改为明确的 `*.json` 名并加白名单例外。

### 【P3】`.agents/skills/` 与两个副本的软链不同步（缺 10 个）

- **问题**：权威路径 `.agents/skills/` 有 **53** 个技能，而 `.qoder/skills/` 与 `.claude/skills/` 各只有 **43** 个软链，缺少 10 个：`flutter-add-integration-test`、`flutter-add-widget-preview`、`flutter-add-widget-test`、`flutter-apply-architecture-best-practices`、`flutter-build-responsive-layout`、`flutter-fix-layout-issues`、`flutter-implement-json-serialization`、`flutter-setup-declarative-routing`、`flutter-setup-localization`、`flutter-use-http-package`。
- **另**：新增技能 `apple-ui-designer` 在 `.agents/skills/` 下**尚未提交**（`git status` 显示三处均为未跟踪）。
- **建议**：补齐 10 个软链并提交 `apple-ui-designer`；建议加一个 CI 校验（比对三处条目集合）防止再次漂移。此条与 `AGENTS.md`「修改技能后同步副本」的既有义务不一致。

### 【P4】根目录文件违反"根目录只留约定文件"规定

- **`api.md`**：与 `docs/api.md` **逐字节完全相同**（`diff` 无输出），两者均入库。建议删除根目录那份。
- **`Makefile`**：已入库，但 `AGENTS.md` 明写"当前开发环境为 Windows，无 make 命令：给用户的命令必须是可直接执行的 CMD 或 PowerShell 命令行"。其内容（`cargo check/test/clippy`、`flutter analyze`）与 `rust/scripts/`、`scripts/` 下脚本重复。建议删除或明确标注"仅供 CI/Linux 使用"。

### 【P5】`probe_icon` 已删除，但 CI 流水线与文档引用仍在（**待处理**）

- **现状**：`probe_icon/` 已于 2026-09-20 **实际删除并提交**（`bb08c173bc`，52 个文件）。
- **待处理**：`.github/workflows/probe-icon-build.yml` 的 `paths: ['probe_icon/**']` 再也不会命中，成为**死流水线**，需一并删除（或明确标注已废弃）。
- 同时 `docs/IOS_ICON_SWITCH_LIMITATION_20260903.md`、`docs/REFACTOR_DEFECT_AUDIT_V2_20260902.md` 中对 `probe_icon` 的引用需标注"该探针已于 2026-09-20 归档删除"。

### 【P6】两本重构计划并存，历史计划未归档

- `docs/REFACTORING_PLAN.md` 与 `docs/REFACTORING_ACTIVE_PLAN.md` 并存，而 `AGENTS.md` 明确后者是"**当前唯一**后续重构执行计划"，历史阶段计划应归档到 `docs/过期文档/`。建议归档前者。

### 【P7】`docs/` 下 117 个入库文档中仅 29 个被现行权威文档引用

- 88 个为阶段性报告/交接单，已成孤儿（不被 `AGENTS.md`、`README.md`、`REFACTORING_ACTIVE_PLAN.md`、两本 parity ledger、`TWO_TRACK_DEV_SPEC.md`、`API_CONTRACT.md` 中任何一份引用）。按项目既有归档惯例，建议批量移入 `docs/过期文档/`（**不建议删除**，保留可追溯性）。
- 零散残留：`docs/__pycache__/`（空目录，需 git ignore 已覆盖）、`docs/gate_baseline_test.txt`（316K，未跟踪）。

### 【P8】`docs/parity_shots/tmp_songhe/`（109M）命名与位置不当

- 名为 `tmp_` 却在正式证据目录内，且被活跃文档引用（见 §三.7）。建议改名为 `songhe_template_fix_20260917/` 转存到 `docs/evidence/`，或随 P2-6 关闭一并删除。

### 【P9】`flutter_legado/` 根目录日志与截图残留

- 约 40 个 `flutter_run*.log`、`e2e_test_run*.log`、`task*_run.log` 与 `_*.png`（合计约 5M）散落在模块根目录。虽已被 `.gitignore` 覆盖（无误提交风险），但污染目录结构。建议清理或统一收纳到 `flutter_legado/.artifacts/`（并 ignore 该目录）。
- 另有 `flutter_legado/_debug_db/`（65M）、`_debug_legado.db`（16M）、`_reader_trace.log`（2.4M）等调试残留同类处理。

### 【P10】未跟踪的配置/笔记类新增物需定策

| 路径 | 大小 | 说明 | 建议 |
|---|---|---|---|
| `.agent-teams/pnpm-audit/` | 1K | 2026-08-19 创建的 agent 团队，`members` 与 `tasks` **均为空**，已死 | 删除 |
| `.zcode/plans/*.md` | 24K | 3 份会话计划草稿（2026-09-03~06），内容已实现或已废弃 | 归档或 ignore |
| `.zcodeignore` | — | 内容为 `.gitignore` 前 20 行的副本，工具生成物 | ignore 或删除 |
| `.qoder/specs/UI重构实施方案_task-997.md`（18K）、`.qoder/specs/Legado_Rust+Flutter_转换_19d227d1.md`（27K）、`.qoder/specs/JsExtensions_完整实现计划_19d227d1.md`（14K） | 60K | 早期立项方案，`JavascriptExtensions` 与转换方案均已实现 | 归档到 `docs/过期文档/` |
| `.qoder/legadoteam 开发史.md` | 2M | 开发史记录 | 建议入库（有价值）或转 `docs/` |

---

## 五、本次未处理的其他残留（范围外，仅登记）

以下项**不在**用户指定的第一、二、三部分内，本次一律未动：

| 路径 | 大小 | 备注 |
|---|---|---|
| `.s0_booksource.json` | 7.4M | 已被 `.gitignore` 覆盖（书源快照） |
| `.shot_original_5558.png`、`.shot_refactored_5556.png` | 550K | 旧雷电档（已废弃）截图 |
| `.ui_original.xml`、`.ui_refactored.xml` | 16K | uiautomator 转储 |
| `reasonix.toml` | 34K | 工具配置，已被 ignore |
| `.cursor/`、`.reasonix/` | 1.2M | 工具目录 |
| `docs/parity_shots/tmp_d11/` | 3.5M | 零引用（列于 §三.7 孤儿清单） |
| `scripts/__pycache__/`、`docs/__pycache__/` | 0 | 已在 ignore 覆盖内 |

---

## 六、执行记录

### 6.1 第一阶段：建立暂存区（移入，不删）

| 步骤 | 结果 |
|---|---|
| 建 `_pending_delete/` + `.gitignore` 加 `/_pending_delete/` | ✅（`git check-ignore` 通过，暂存区不出现在 `git status`） |
| 搬移构建产物 8 项 | ✅ 全部 OK |
| 搬移根目录残留 | ✅ **276 项搬移成功、5 项按预期保留、0 错误** |
| 搬移大块取证目录 5 项 | ✅ 全部 OK |
| 搬移 `probe_icon/` | ✅ OK（52 个 tracked 文件显示为 D） |
| 暂存区总量 | **300G** |
| 提交 | `b99538b891`（文档 + `.gitignore`，**不含** probe_icon 删除） |

### 6.2 第二阶段：复核与实删（2026-09-20，用户授权执行）

**已删除（释放约 302G）**：

| 项 | 大小 | 依据 |
|---|---|---|
| `_pending_delete/` 整体 | 300G | 用户裁决；构成见 §一 |
| `probe_icon/` | 52 文件 | 用户确认废弃；提交 `bb08c173bc` |
| `.e2e_s0c/` `.e2e_r1v/` `.e2e_p03/` | 1.4G | 关联任务均已收口，机读结论已入库 `docs/evidence/search_parity_*` |
| `tmp_debug/` 零引用大块（`apk_verify` `verify_0820` `apk_x86.so` `biying` `fl2.bin` `user_test_2026-08-13` `verify_0819` `parity` `search_probe` `batch_diag` `apk_check`） | 340M | 全仓零引用 |
| `tmp_parity/` 6 个历史 db 快照（+ `sources_5558.json`） | ~874M | 全仓零引用；**目录与 `scan_wave2.jsonl` 保留** |
| `.tmp/` 的 `p8_db`(155M) `legado-with-MD3`(67M) `pending_pushes_20260917.bundle`(13M) 及 `ndk-shim` `wsl-diag` `a4_fixture` `device_verify_20260913` `diag_wangyue` `db_*_v9`(6 项) | ~245M | 见 §3.4 |

**磁盘变化**：`D:` 可用空间 **171G → 473G**（使用率 88% → 66%）。

**复核后决定保留（与初版判定不同）**：

| 项 | 大小 | 保留原因 |
|---|---|---|
| `.tmp/dbsrc/`（含 `q7.db`） | 305M | **初版判"可删"作废**：`docs/REFACTORING_ACTIVE_PLAN.md:167` 是**活跃台账**，把该库标为 P2-7 观测点且写明"待用该源 + 真实响应离线复现后定性"——属**仍可能需要**，不动 |
| `docs/parity_shots/` 全部 | 245M | **初版"24 个孤儿"判定作废（误判）**，见 §3.7 纠正说明 |
| `docs/parity_shots/tmp_songhe/` | 109M | 被 `CHANGELOG.md` 与 `RULE_TEMPLATE_SEGMENT_FIX_20260917.md` 引用，待单独裁决 |
| `.tmp/corpus/`、`.tmp/ui/`、`.tmp/kazusa.apk` | 24M+ | 活文档/活跃脚本/参考版安装包 |
| `tmp_debug/e2e_5558/`、`sources.json`、`src_51.json`、`src_shen.json` | 174M | 被 26 处测试读取 |
| `tmp_debug/` 约 200 个 1–4K 一次性探针脚本 | ~1M | 体积可忽略，逐文件核引用收益不成比例，**留待后续** |
| `.tmp/` 约 250 个一次性探针（`a0-a4.png`、`ui*.xml`、`bookinfo_08_*.py` 等） | 其余 | 同上 |

### 6.3 本次未做（属开发 agent 范围或范围外）

- §四 的 P1~P10 **一律未改代码/文档**（用户指定交开发 agent 处理）。
- 另有两处**非本次操作**的并行会话在途改动：`flutter_legado/lib/src/screens/search_content_screen.dart`（深色态输入盒对齐）、`flutter_legado/pubspec.yaml`（新增 `zxing2`/`image` 依赖，PARITY A1）。
- `.gitignore` 中的 `/_pending_delete/` 规则予以保留（暂存区已删除，该规则成为预留约定，供后续同类清理复用）。

---

## 七、项目目录之外的清理（2026-09-20 第二轮，用户指定范围）

> 背景：用户注意到项目**上一级与上上级**（`D:\OH-WorkSpace\`、`D:\tmp`）也有散落的图片与文件。排查后确认**与本轮仓库内清理无关**（仓库内操作全是 `mv`/`rm` 于仓库内部），而是长期积累的**同类残留**，根因是「**命令在哪个目录下执行，产物就落在那里**」的工作目录漂移。
>
> 处置：沿用同一套两阶段做法，移入外部暂存区 `D:\OH-WorkSpace\_pending_delete\`（**同一磁盘 rename，回移秒级**），**未删除任何内容**，等待用户裁决。

### 7.1 残留成因与构成

| 位置 | 大小 | 日期 | 成因 |
|---|---|---|---|
| `D:\OH-WorkSpace\.review_probe\` | 11G | 9/19 | 审查探针输出目录（clippy 日志 + `p12`/`p21`/`p29` 探针各自的 target，37 项） |
| `D:\OH-WorkSpace\_cargo_target_p0_1_legado` +`_new` +`_new2` | 15.8G | 8/19 | P0-1 实验时用 `CARGO_TARGET_DIR` 指到工作区根做的三份 A/B/C 对比编译 |
| `D:\OH-WorkSpace\probe_target\` | 762M | 9/18 | 探针工程的构建产物 |
| `D:\OH-WorkSpace\*.png`（17 张） | 4.6M | 9/5–9/6 | `adb exec-out screencap -p > x.png` 时 cwd 为工作区根，截图落在此处（`a_dialog`/`b_home`/`d_launcher`/`reader_menu`… 对应那两天的阅读器调试） |
| `D:\OH-WorkSpace\LegadoTeam\legado_probe\` | 741M | 9/18 | 一次性探针 Rust 工程（`probe/target/` 占绝大部分） |
| `D:\OH-WorkSpace\LegadoTeam\.tmp_js_test.log` | 98B | 8/26 | 同类残留 |
| `D:\tmp\` 的 110 个条目 | 2.3G | 8–9 月 | 项目探针产物散落：`legado_snap{,2,3}.db`/`p12_legado.db`/`legado_before.db` 库快照、约 60 个 `ui_*.xml`（uiautomator 转储）、`t6_*.png`/`qa*.png`/`ref_*.png`/`d11_*.png` 截图、`logcat_t6.txt`、`defect` 转储，以及 `p27b/`（1.8G，**P2-7b quickjs 崩溃调查 scratch**：CI 失败日志 + stress 日志 + `snap/rust`）与 `legado_probe/` |
| **合计** | **约 30G** | | |

**搬移前核查**：这些目录**当天没有任何文件改动**（唯一当天有改动的是 `LegadoTeam\legado`，即本仓库的清理与并行会话开发）；仓库内对它们**全部零引用**；`D:\tmp` **不是**系统临时目录（`TEMP`/`TMP` 指向 `C:\Users\admin\AppData\Local\Temp` 与 `C:\Windows\TEMP`，`TMPDIR` 未设置），也不在任何用户级/系统级环境变量里。

### 7.2 `D:\tmp` 核查后**保留**的 3 项（不属可删范围）

| 项 | 大小 | 保留原因 |
|---|---|---|
| `md3_ref_legado/` | 58M | **MD3 参考版源码副本**（`HapeLee/legado-with-MD3` 的克隆，干净在 `9db5ae6`、无本地改动）。被入库文档 `docs/UI_MD3_GAP_REPORT_20260903.md:4,24` 按**绝对路径**引用（"本地只读副本 `D:\tmp\md3_ref_legado`"），且本项目**视觉基准即参考版**，属有价值的参照源；体积可忽略，不承担误删风险 |
| `rhino_probe/` | 9K | `RhinoProbe.java`/`.class` **于 2026-09-20 00:45 才被修改**，对应仍登记在案的 Rhino LiveConnect 互操作遗留条目（`REFACTORING_ACTIVE_PLAN.md:215` + `docs/RHINO_INTEROP_ANALYSIS_20260920.md`）——属在途工作，**不动** |
| `readme.md` | 9K | **不是本项目的东西**：是 **NInfer 5090**（本机 Qwen 27B 推理引擎）的 README，属本机 LLM 环境，留待用户自行判断 |

> 另注：`D:\tmp` 目录**本身保留**（只清了内容）。`flutter_legado/tool/gen_md3_colors.py` 以**命令行参数**接收 colors.xml 路径，**不硬编码** `D:\tmp/md3_ref_legado`，故该工具不受影响。

### 7.3 项目目录之外**必须保留**的参照源

| 路径 | 大小 | 说明 |
|---|---|---|
| `LegadoTeam\legado-upstream\` | 34M | 上游原版 Kotlin 源码（原版对齐的功能基准） |
| `OH-WorkSpace\Projects\legado_flutter\` | 73G | 重构版 Flutter 参考源（含 `.git`）；其中 `rust/` 61G 与 `build/` 12G 是构建产物，源码 `lib/` 仅 5.2M——日后瘦身只应动其构建目录 |
| `Projects\legado-main.zip` | 11M | 上游打包副本 |

### 7.4 回移命令

```powershell
# 回移全部外部暂存内容
Move-Item D:\OH-WorkSpace\_pending_delete\* D:\OH-WorkSpace\

# 回移 D:\tmp 的内容
Move-Item D:\OH-WorkSpace\_pending_delete\D_tmp\* D:\tmp\
```

---

编写者：主代理（ZCode 本机通道）｜ 2026-09-20
修订：主代理 ｜ 2026-09-20（P1 严重度按 `#[ignore]` 二分修正；§3.7 parity_shots 孤儿判定作废纠正；补 §六 实删执行记录）
修订：主代理 ｜ 2026-09-20（补 §七：项目目录之外的 `D:\OH-WorkSpace` 与 `D:\tmp` 残留清理，含成因、保留项与回移命令）
