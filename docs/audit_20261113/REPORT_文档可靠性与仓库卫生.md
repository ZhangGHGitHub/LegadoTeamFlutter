# Legado 文档可靠性与仓库卫生审查报告（2026-11-13）

> 审查基线：HEAD `7c15e822524bfd8641fc3687703b51825f8ea035`（`docs: 批21 设备验收归档与计划登记`，pubspec `2.0.491+492`）
> 审查性质：只读。仅使用 `git log` / `git cat-file` / `git show` / `git check-ignore` / `rg` / `python -I` 读取与统计，未修改任何被审查文件、未运行构建/测试。
> 对照：任务书 `docs/audit_20261113/BRIEF.md`「路 5：文档可靠性 + 仓库卫生」；上次审查 `docs/REFACTORING_FULL_AUDIT_REPORT_20261026.md`（基线 `a3302a0cc8`）。
> 说明：本路为文档/仓库卫生类审查，除个别 CI/代码事实外不具备「原版 vs 参考版」双基准语义；证据以 `file:line`、提交对象存在性与命令输出为准。所有 path:line 均为本次审查时点事实。

---

## 〇、结论摘要

**计数：P0×0、P1×0、P2×1、P3×12、待核实×5。**

总体判断：**文档可靠性较 2026-10-26 审查有明显改善，但「正文滞后」这一形态没有根治，并在批 18~21 的高密度交付后重新累积。** 正面项：`rust/PROGRESS.md` 失效横幅已在位、4 处活链已修正、3 个历史 hash 欠账已补记且提交真实存在、双日志 2.0.470~2.0.491 覆盖完整、`api_contract` 相关文档未在本路发现虚报。负面项：ACTIVE_PLAN 正文仍有 10 处与尾部日志相反的口径；三份入口/开发文档（README、docs/DEVELOPMENT.md、rust/README.md）停在 2026-08 的版本、crate 数、schema 版本与测试统计；AGENTS.md 的设备事实（root、端点、可用性）与最近 26 份设备验收报告冲突，且引用了 4 个不存在的 CI workflow。

**最严重的 3 条**

| 排序 | 编号 | 摘要 |
|---|---|---|
| 1 | P3-4 | ACTIVE_PLAN 正文旧段与尾部日志仍有 10 处口径冲突（含 L486「仍开放 7 项」被 L775 判定五项早已关闭、L489 F1/S0-D 早已闭环、L336 感知等待早已裁决、L325 ② 早已 PASS） |
| 2 | P3-1/P3-2/P3-3 | 入口与开发文档陈旧：README 写「2.0.60+62 / 8 个 crate / 62 屏」，实际 2.0.491+492 / 9 个 crate / 111 个 screen 文件；docs/DEVELOPMENT.md 写「Schema v95」，实际 `SCHEMA_VERSION=119`；rust/README.md 仍以 PROGRESS.md 为「完整进度跟踪文档」 |
| 3 | P3-8/P3-9 | AGENTS.md 设备事实与 CI 引用过期：写「adbd 非 root、须 run-as」，但 2026-10-27 起 26 份验收报告记录 root/adbd root（10 份直接写 `uid=0(root)`）；主端点仍写 `192.168.1.19:5555`（最新实测 `.63`）；「设备档当前不可用」无恢复注记；CI 引用 `test.yml`/`release`/`BetaRelease`/`web` 均不存在 |

---

## 一、审查范围、方法与关键事实

### 1.1 范围

`docs/`（含 `过期文档/` 引用关系）、`AGENTS.md`、`README.md`、`CHANGELOG.md`、`flutter_legado/assets/updateLog.md`、`rust/PROGRESS.md`、`rust/README.md`、`docs/DEVELOPMENT.md`、`docs/VERSION_CONTROL.md`、`.github/workflows/`、`.gitignore`、仓库根目录与 `.zcode/`。

### 1.2 方法

- ACTIVE_PLAN 全文 1254 行按行扫描；正文（L1~660）与尾部修订日志（L661~1253）分别提取状态词（未修/仍开放/待裁决/待核验/待办/剩余/待补）后交叉比对。
- 最近 30 条修订日志（L1200~L1253）中的全部 82 个唯一反引号 hex 串逐个 `git cat-file -t`；再对全文件 1021 个唯一 hex 串做全量对象存在性核验。
- 双日志按标题正则解析全部版本号、日期、顺序；区间 2.0.470~2.0.491 逐版本比对。
- 设备/CI/仓库卫生事实以 `rg`、`git check-ignore`、`git ls-files`、`git status` 与文件系统计数核验。

### 1.3 环境事实（非缺陷）

- 审查开始时工作树**不干净**：4 个已跟踪文件被修改、8 个未跟踪文件；其中 `flutter_legado/lib/src/services/process_text_service.dart`、`auto_refresh_book_scheduler.dart`、`android/.../ProcessTextBridge.kt` 的 mtime 为 2026-11-13 00:58~01:01，属并行会话在途开发。本报告结论只基于 HEAD 已跟踪内容；这些未提交改动不影响文档结论，但影响「审查基线可复现」的表述（见待核实 V-4）。
- `docs/audit_20261113/` 为本次审查新建目录（未跟踪），符合任务书落盘要求。

---

## 二、P2（1 条）

### P2-1 rust-ci 的 quickjs clippy 档未覆盖 `legado-fetcher`

**证据（我方）**

- `.github/workflows/rust-ci.yml:26-28`：quickjs clippy 命令为
  `cargo clippy -p legado-js -p legado-ffi -p legado-server --features quickjs --all-targets -- -D warnings`，**不含 `-p legado-fetcher`**。
- `.github/workflows/rust-ci.yml:48-50`：同一工作流却已运行
  `cargo test -p legado-fetcher --features quickjs`，说明 fetcher 的 quickjs 档被视为需要门禁。
- `rust/legado-fetcher/Cargo.toml:37-39`：`quickjs = ["legado-js/quickjs"]`；`rust/legado-fetcher/src` 内 `cfg(feature = "quickjs")` 共 **40 处**。
- `rust/legado-server/Cargo.toml:46`：server 的 quickjs feature 透传 `legado-fetcher/quickjs`，但 `-p legado-server --all-targets` 只 lint server 自身目标，不 lint 依赖 crate 的源码。

**对照/核验**：上次审查已把 quickjs clippy 档作为「CI 上锁」证据（ACTIVE_PLAN L699）；本次为新增 crate（`legado-fetcher`，2026-10-01 下沉）未同步纳入 lint 面的漏项，不是回潮。

**影响**：fetcher 的 quickjs 门控代码可编译、可跑测试，但 clippy 告警/错误不会阻断 CI；`-D warnings` 的保证在该 crate 的 quickjs 档缺位。属技术债/门禁边界缺陷，无直接用户可见影响。

**修复方向**：把 `-p legado-fetcher` 加入 rust-ci.yml:28 的 clippy quickjs 命令（与 :48 测试档对齐）；若担心与 server 重复，可改为 `--workspace --features quickjs` 但需评估 feature 统一后的编译面。

---

## 三、P3（12 条）

### P3-1 根 README.md 严重陈旧（版本、crate 数、页面数、提交规范四处失真）

**证据（我方）**

- `README.md:13`：「Rust 核心引擎（8 个 crate）」——实际 `rust/Cargo.toml:3-12` 的 workspace 成员为 **9 个**（含 2026-10-01 新增的 `legado-fetcher`）。
- `README.md:22`：「Flutter UI 层（62 个 Screen 页面）」——`flutter_legado/lib/src/screens/` 下 `.dart` 文件为 **111 个**（`find` 计数）。
- `README.md:70`：「当前版本：**2.0.60+62**」——实际 `flutter_legado/pubspec.yaml:4` 为 `2.0.491+492`。
- `README.md:73`：「提交规范：中文说明 + `[Rust]` / `[UI]` / `[docs]` 前缀」——与 `AGENTS.md:57` 明确「`fix(ui)`/`fix(rust)` 取代旧式 `[UI]`/`[Rust]`/`[Tool]` 前缀」相反。
- 另：`README.md:43` 快速开始只演示 `cargo test -p legado-ffi --features quickjs`，与 AGENTS/CI 的 workspace 级门禁不一致（次要）。

**对照/核验**：`git log -1 --format=%ad` 确认 HEAD 为 2026-11-12；上次审查未覆盖根 README，故本条为**新增**，非回潮。

**影响**：README 是外部用户与 agent 的第一入口；版本号差 431 个 patch、crate 数少 1、提交规范与项目硬约束相反，会直接误导新会话与贡献者。

**修复方向**：更新版本号、crate 列表（补 `legado-fetcher`）、页面数口径（或改为「100+ 屏」不写死）、提交规范改为约定式提交；快速开始改为 `cargo test --workspace`（可另注 single-crate 用法）。

---

### P3-2 docs/DEVELOPMENT.md 陈旧：Schema v95 vs 实际 v119、8 crate、2026-08-02 测试统计

**证据（我方）**

- `docs/DEVELOPMENT.md:94`：「Rust workspace（8 个 crate）」。
- `docs/DEVELOPMENT.md:100`：「legado-db：数据库：SQLite **Schema v95** + 17 Repository」——实际 `rust/legado-db/src/schema.rs:93` 为 `pub const SCHEMA_VERSION: u32 = 119;`。
- `docs/DEVELOPMENT.md:212-215`：测试统计表写 Rust 默认 1409 / QuickJS 327 / FFI 105 / Flutter 952，注明「2026-08-02 实测」；HEAD 侧最近记录为 `flutter test 5705 通过 + 1 跳过`（ACTIVE_PLAN L1253）、`cargo 默认档 3942 通过`（同条）。
- `docs/DEVELOPMENT.md:108`：「Flutter 测试（24 个文件）」——`flutter_legado/test` 下 `.dart` 文件为 **520 个**（`find` 计数）。

**对照/核验**：docs/README.md:66,70 仍把 `DEVELOPMENT.md` 列为「规范类」当前文档，未归档、未加失效横幅。

**影响**：开发者按 v95 理解迁移链会漏掉 24 个 schema 版本；测试数字落后约 3~6 倍，无法作为基线。

**修复方向**：更新 crate 数、schema 版本（建议改为「见 `SCHEMA_VERSION` 常量」避免再次写死）、测试统计改为「以 CI/最新批次为准」或删除具体数字；文件头加「最后核对日期」。

---

### P3-3 rust/README.md 仍把 PROGRESS.md 当「完整进度跟踪文档」——第二状态源的第 5 条活链

**证据（我方）**

- `rust/README.md:202`：「## 项目进度（截至 2026-08-01）」。
- `rust/README.md:204`：「> 完整进度跟踪文档见 [PROGRESS.md](./PROGRESS.md)」。
- `rust/README.md:206`：「当前状态：148/148 原子任务已完成，Rust 1409 测试默认通过 / Flutter 952 通过（2026-08-02 实测）」。
- `rust/PROGRESS.md:3` 已有失效横幅（2026-08-07 冻结，当前状态见 ACTIVE_PLAN）——横幅本身**在**，但 README 的邀请语与 148/148 数字未同步。

**对照/核验**：上次审查点名的 4 处活链已修正且本次复核通过：
`docs/DEVELOPMENT.md:105,296`、`docs/VERSION_CONTROL.md:124`、`rust/DEVELOPMENT.md:756` 均已加「冻结/历史快照」注记。`rust/README.md:204` 是第 5 处，未被上次清单覆盖。

**影响**：读者从 rust/README 进入会拿到 2026-08-01 的 148/148 进度与 1409 测试数，构成事实上的第二状态源；违反 `docs/REFACTORING_ACTIVE_PLAN.md:5` 的「唯一状态源」约定。

**修复方向**：把 `rust/README.md:202-220` 整段改为历史快照横幅 + 指向 ACTIVE_PLAN，或删除具体数字；在「4 处活链」清单中补第 5 处并回销。

---

### P3-4 ACTIVE_PLAN 正文旧段与尾部日志仍有 10 处口径冲突（核心发现）

以下每条均为「正文仍写未修/开放/待裁决/待补」而「尾部日志（或验收文档）已关闭/已落地」。逐条给双侧行号。

| # | 正文位置与原文要点 | 尾部/外部已闭环证据 | 冲突性质 |
|---|---|---|---|
| 1 | `REFACTORING_ACTIVE_PLAN.md:486`：「**仍开放**：§一.1 v7a、§二.4 cmap、§二.7/§二.8、§三.9、§四.16、S0-C 原版端、S0-D」 | 同文件 `:775`（2026-10-04）：「**Active 计划第 486 行的『仍开放』六项复核结果——五项早已关闭**……仍开放=§二.8、S0-D」 | 正文列 7 组 vs 日志「六项复核、五项已关」，正文未注记 |
| 2 | `:489`：「**剩余（2026-09-03 更新）**：S0-D 性能剖析……F1 loginCheckJs 语义对齐（P1）」 | `:463`（2026-09-20 批次）：「本批完成最后实质项——F1 loginCheckJs 语义对齐」；`:692`（2026-09-20）：「P3-6 剩余面收口（F1……+ S0-D 计时……）」 | 两项均已闭环，正文仍列「剩余」 |
| 3 | `:202`：「**P2-11 本批审查剩余项**（开放，2026-09-18）」 | `:692`：「P2-11 五小项全关（d13d1a04e5/16f6e09e92/0fe222a3c8）」；`:694`：「P2-11 回头关闭 ①②③④ 与 §201」 | 段头「开放」未回销 |
| 4 | `:294`：「**待裁决点**：① 语义取舍……② 裁决后需同步的落点」 | `:290`（同段标题）：「P2-20……**2026-09-23 已闭环**——裁决『以运行时增量桶语义为准』并三路径统一」；`:297-299` 为落地记录 | 已闭环段内仍保留「待裁决点」 |
| 5 | `:325`：「**新登记（本轮实机发现，未修）**：……② 换源后 `books.totalChapterNum` 未随新源目录同步」 | `:339`（2026-09-25）：「② 目录派生字段同步 PASS：换源前后 DB `totalChapterNum 3→5`……与目录页/新源逐项一致」；① 亦由 `:330` 关闭 | ② 已 PASS，正文仍标「未修」 |
| 6 | `:336`：「**待用户裁决**：换源/目录的感知等待——A/B/C」 | `:386`：「**已裁决选 B 关闭（2026-10-02）**」；`:749`：「目录渐进渲染裁决（同日）……裁决选 B……该决策关闭」 | 已裁决，正文未注记 |
| 7 | `:583`：「**待办（大面批次……）**：B2 剩余 / B3 / B4 / B5」 | `:584`：B2 完成 `0293436050`；`:721`（B4 首批）、`:723`（B4 全量）、`:725-727`（B3 关闭）、`:589`（B5 关闭） | B2~B5 全关，段头「待办」未回销 |
| 8 | `:262`：「已裁决并落地（2026-10-02 REST 三态批，**提交待提交**）」 | `:261` 与 `:739`：提交 `9c0bacffe0`（`git cat-file -t` = commit） | 「待提交」占位残留 |
| 9 | `:545`：「[P4-1 关闭记录] 4 代码/测试提交 + 版本收尾 **`待补`**（2.0.323+324）」 | `:550`：「**版本收尾 `8c832361fa`（2.0.323+324）**」 | 「待补」占位未回销 |
| 10 | `:877`/`:879`/`:895`：「18a 设备验收待补」「18a+18b 合并设备验收待补」「7z 设备验收待补」 | `docs/DEVICE_ACCEPTANCE_20261027_18_REMOTE_BOOK.md:1-10`（18a/18b 场景 1/2/4/5/7/8 PASS，3/6 回修后 PASS）；`docs/DEVICE_ACCEPTANCE_20261027_24_7Z.md:1-14`（逐场景 PASS/缺陷登记）| 验收已发生，计划未回销 |

**影响**：ACTIVE_PLAN 自称「唯一状态源」（`:5`），正文却是 8~10 月的历史层；任何按正文派单/裁决的 agent 会重复处理已关闭项、或把已裁决项再次上报用户。10 处中第 1/2/6 条直接影响「当前还能做什么」的判断。

**修复方向**：按 `docs/DEVELOPMENT_CONVENTIONS.md:292` 的「文档回销义务」逐条回销：把段头/段题改为「已关闭（日期/证据）」，保留原文作历史；对 L486 建议整段重写为「2026-10-04 复核结论：仅 §二.8、S0-D 仍开放」。建议在文件顶部新增「当前开放项快照（每次批次关闭时更新）」小节，避免读者必须从 600 行正文 + 600 行日志中自行归纳。

**补充：已确认 10 处之外，仍有 25 条「提交待收口」模板语**（见 P3-6）。

---

### P3-5 ACTIVE_PLAN 尾部仍有 4 组未回销/失联登记项

| # | 位置 | 原文要点 | 核验结果 |
|---|---|---|---|
| 1 | `:561` | 「**待办：2.0.325 装机冒烟 + V3 设备点验**（用非凡资源网视频书实测选集/倍速浮层）」 | 在后续 600 余行日志中未检索到该 2.0.325 冒烟/V3 点验的关闭记录；V3 属 P4-3 视频能力，后续视频轨道有相关交付，但未与 L561 待办串联回销 → 待核实（V-2） |
| 2 | `:569` | 「**波次 2 登记尾项**：⑧ 孤儿 overlay、P2 关闭自动翻页不取消在飞 glide、P2-2 智能适配等价全屏、P2-3 无书源书保存/分享恒失败、P2-5 条漫间隔首末 padding、P2-7 touchSlop、点验低项、前波 ① 搜索结果列表死态」 | 后续日志无逐项关闭记录；代码侧可见 `touchSlop` 已参数化（`reader_page_view.dart:1408`），但无法证明其余项已处置 → 待核实（V-2） |
| 3 | `:578` | 「`custom_progress.dart` **死代码待清理批**」 | `flutter_legado/lib/src/widgets/custom_progress.dart` 仍存在；全 `lib/` 零生产引用，仅 `test/widget/custom_progress_test.dart` 引用 → **登记项仍真实开放且失联** |
| 4 | `:1243` | 2026-11-11「开放项盘点」：A1 未开工 6 项（含 A1-1 图片 action、A1-2 净化统一、A1-3 armv7、A1-6 应用字体）、B2 架构 3 项等 | A1-1/A1-2 已由批20（`:1251`）关闭、A1-3/A1-6 已由批19（`:1249`）关闭、B2-1/B2-2 由批20 关闭、B2-3 由批19 关闭；盘点本身未回销，后续仅靠 `:1251`/`:1253` 的「下一步」收敛到 A1-4/A1-5 → **盘点快照已过期** |

**影响**：第 3 项是可验证的死代码债（违反 DEVELOPMENT_CONVENTIONS §8「周期性零引用清理」）；第 4 项让「剩余待办」需要读 3 条日志才能拼出；第 1/2 项让读者无法判断漫画/视频尾项是否已处置。

**修复方向**：`custom_progress.dart` 纳入下一批零引用清理或移 `docs/pending_deletion/`；`:1243` 追加「2026-11-12 回销：A1-1/A1-2/A1-3/A1-6、B2-1/B2-2/B2-3 已关闭」；`:561`/`:569` 逐项标状态或转入正式 P3 台账。

---

### P3-6 修订日志中的 hash 拼写错误（1 处）与 25 条「提交待收口」模板语

**证据（我方）**

- `docs/REFACTORING_ACTIVE_PLAN.md:1124`（批6a-2 设备验收回修）记录回修提交 `738d138d95` / **`13b1b3b59`**。
  - `git cat-file -t 13b1b3b59` → **missing**（不存在）。
  - 实际提交为 **`13b1b33b59`**：`git log -1 --format='%h %s' 13b1b33b59` → `13b1b33b59 test(ui): 覆盖文件夹列表窄列组名/计数可见矩阵`。
  - 同条另一 hash `738d138d95` 存在（`git cat-file -t` = commit）。
- 全文件 1021 个唯一反引号 hex 串核验结果：`git cat-file --batch-check` 报 9 个非对象值，其中 8 个是**非提交值**（`2147483648` 整数、`d41d8cd98f00b204` 空串 MD5、`0d77d39892b67931`/`628631f07321b22d`/`a8105204604a0b11`/`d6c3ee232ffba2238d1bc491af344938`/`dd0c69c4cc0ef6b5` 内容 hash/键、`e1c1e416` 上游 quickjs-ng 提交），**唯一真实的仓库提交拼写错误就是 `13b1b3b59`**。
- 最近 30 条修订日志（L1200~L1253）共 82 个唯一 hash：`git cat-file -t` **82/82 全部为 commit**，无缺失。
- 「提交待收口」共 **25 条**（L751、L753、L755、L759、L763、L765、L767、L771、L773、L775、L777、L779、L781、L783、L785、L787、L789、L793、L797、L800、L801、L803、L804、L805、L808），均为 2026-10-03~10-07 条目。
  - 抽查 `2.0.344+345`：`git log --all --grep='2.0.344\|2.0.345'` 命中 `c9a3c58e49`/`641fcc893f` 等收尾提交；`2.0.370` 命中 `70a84680dd chore: 审查批1 收尾（版本 2.0.370+371...）`，且两版本均在双日志有标题。
  - 结论：**不是真实欠账**，是模板语未回销，但会污染「hash/收尾欠账」扫描。

**影响**：`13b1b3b59` 会让按提交号追溯/复核的 agent 找不到对象；25 条「待收口」会让审计误判存在 25 个未提交批次。

**修复方向**：改正为 `13b1b33b59`；批量把 25 条的「提交待收口」改为「已收口（版本提交见 CHANGELOG）」，或在条目末追加统一回销行。

---

### P3-7 双日志同步：470~491 覆盖完整；仅历史区间有 3 类单调性瑕疵

**证据（我方）**

- 区间 2.0.470~2.0.491：`CHANGELOG.md` 22 个标题、`flutter_legado/assets/updateLog.md` 22 个标题，**集合完全一致、日期逐版本一致、无缺失**。
- `2.0.492` 不是独立 versionName：`flutter_legado/pubspec.yaml:4` 为 `2.0.491+492`，双日志以 `2.0.491` 记录，属正常口径（versionCode 不单列标题）。
- 上一轮两个缺口已修：`CHANGELOG.md:2901` 已有 `## [2.0.200]`、`:2862` 已有 `## [2.0.203]`；`updateLog` 已有 `2.0.336`（`rg` 命中 1 处）。updateLog 的版本化条目起点为 2.0.267（L1012），2.0.200/203 早于其起点，**不构成缺失**（修正上次报告未说明的边界）。
- 历史单调性瑕疵：
  - `updateLog.md:994` 为 `2.0.272`，`:997` 为 `2.0.273`（272 在 273 之前，逆序）。
  - `CHANGELOG.md:4964/4971/4998` 三处标题均为 `## [2.0.3]`（日期 08-08/08-07/08-06），同名版本重复 3 次。
  - `CHANGELOG.md:3886` 的 `2.0.125` 出现在 `2.0.112` 之后；`:3923` 的 `2.0.110` 出现在 `2.0.109` 之后（均为 2026-08 历史回填）。

**影响**：对 470~492 区间无影响；历史区间的重复版本名会让 `git tag`/发布脚本按版本号定位时歧义。

**修复方向**：仅需在 CHANGELOG 的重复 2.0.3 条目标注实际 versionCode（如 `2.0.3+4`），或在文件头声明「2.0.3 为三日连续构建共用 versionName」；updateLog 272/273 对调顺序即可。

---

### P3-8 AGENTS.md 设备事实陈旧：root 状态、端点、设备可用性三处与最新验收冲突

**证据（我方）**

- `AGENTS.md:71`：「2026-10-03 实测修正：该机 `adb shell` **非 root**（uid=2000，无 su），`/data/data/<pkg>/` 私有目录读写须 `run-as`（仅 debug 包可调试）」。
  - 反证（同仓、同实例「Test测试」、`.62:5555`）：
    - `docs/DEVICE_ACCEPTANCE_20261027_18_REMOTE_BOOK.md:15`：`adb shell id` = `uid=0(root)`
    - `docs/DEVICE_ACCEPTANCE_20261101_BATCH2B1B1.md:27`：**明确点名**「与 `docs/REFACTORING_ACTIVE_PLAN.md` 中『非 root、需 run-as』的旧表述不同；本轮直接读取 `/data/data/<pkg>/shared_prefs/...` 取证」
    - 另有 `DEVICE_ACCEPTANCE_20261028_BATCH31.md:18`、`..._BATCH34.md:18`、`20261029_BATCH35/36/37/38/40`、`20261030_BATCH39_43.md:19`、`20261101_BATCH1B2A.md:25`、`20261102_BATCH2B2A.md:35`、`20261103_BATCH2B1B2B.md:28`/`M1/M2/M3`、`20261104_BATCH2B2C.md:39` 等；`rg -l 'uid=0|adbd.*root' docs/DEVICE_ACCEPTANCE_*.md` 共命中 **26 份**验收报告（其中 10 份直接写 `uid=0(root)`）。
- `AGENTS.md:67`：主测试档端点写死 `192.168.1.19:5555`；最新计划 `docs/REFACTORING_ACTIVE_PLAN.md:1253` 记录批21 设备地址已漂到 **`192.168.100.63:5555`**，`:1249` 记录 `.62:5555`。`AGENTS.md:74` 虽有「端点时效性、执行前必须探测」的免责声明，但主 bullet 仍会被当作当前事实读取。
- `AGENTS.md:72`：「⚠ 设备档当前不可用（2026-09-24 实测，恢复前派设备任务=白跑）」——2026-09-27 起设备已恢复并持续用于 09-27~11-12 的几十批验收；该行没有「已恢复」注记，与 `:67-70` 的现行用法自相矛盾。

**对照/核验**：ACTIVE_PLAN `:27` 也是同一「非 root」口径；两处同源，均停留在 2026-10-03 的一次实测。设备的 root 能力可能随 MuMu 版本/启动方式变化，正确表述应是「以当次 `adb shell id` 实测为准；近月多数验收为 uid=0(root)」而非断言非 root。

**影响**：agent 按 AGENTS 会拒绝直接读写私有目录，改用 `run-as`（release 包不可调试时直接失败），或误判「设备不可用」而不派任务——直接影响验收效率与证据质量。

**修复方向**：`AGENTS.md:71` 改为「root 状态随实例/启动方式变化，派单前 `adb shell id` 实测；2026-10-27 以来 Test 实例多为 uid=0(root)；非 root 时用 run-as（仅 debug）」；`:72` 加「2026-09-27 已恢复，当前以实时探测为准」；`:67` 端点改为「历史记录：192.168.1.19:5555（2026-09 时点）；最新实测见 ACTIVE_PLAN 批19~21 条目，执行前必须 `MuMuManager info -v all`」。同步修 ACTIVE_PLAN `:27`。

---

### P3-9 AGENTS.md 的 CI 引用与模块地图过期（4 个不存在的 workflow + 缺 legado-fetcher）

**证据（我方）**

- 实际 `.github/workflows/` 仅 8 个文件：`flutter-ci.yml`、`flutter-release.yml`、`integration-smoke.yml`、`ios-build.yml`、`pr-review.yml`、`rust-ci.yml`、`stale.yml`、`triage-labels.yml`。
- `AGENTS.md:22`：「Android 单元测试……（CI：`.github/workflows/test.yml`）」——**test.yml 不存在**（`.github/workflows/` 中无此文件）。
- `AGENTS.md:25`：「CI 总览：`.github/workflows/`（test / rust-ci / flutter-ci / release / BetaRelease / web 等）」——`test.yml`、`release.yml`、`BetaRelease`、`web` 均不存在；实际存在但未列出的有 `integration-smoke`、`ios-build`、`pr-review`、`stale`、`triage-labels`。
- `AGENTS.md:17`：Rust 工作区列表为 `legado-book / core / db / ffi / js / net / parser / server`——缺 `legado-fetcher`（`rust/Cargo.toml:3-12` 第 7 个成员）。
- 关联：`docs/REFACTORING_ACTIVE_PLAN.md:35` 仍以 `rust-ci.yml:26-31` 作为 FFI CI 证据，行号已漂移但语义尚可；不单列。

**对照/核验**：上次审查后的 workflow 变更仅 1 个提交（`f5afe02347` 对 rust-ci.yml +5 行，2026-10-26），无新增/删除 workflow；因此这些引用在 10-26 前就已失效（app/ 与 Android workflow 按用户 2026-08-30「安卓源码不上传 GitHub」指令删除）。

**影响**：agent 按 AGENTS 去查 `test.yml` 会找不到；`BetaRelease`/`web` 是不存在的验证入口；模块地图漏 `legado-fetcher` 会让新会话误判 crate 边界。

**修复方向**：删除 Android CI 引用或改为「本地 `./gradlew ...`，Android workflow 已按 2026-08-30 指令移除」；CI 总览改为实际 8 个文件并注明各自职责；模块地图补 `legado-fetcher`（可注明「server/ffi 共享书源抓取实现」）。

---

### P3-10 仓库卫生：`.zcode/` 未入 ignore；根目录 68 个 `tmp_*` + `.tmp/` 4.5GB 本地杂物

**证据（我方）**

- `git status --porcelain -uall` 中 `?? .zcode/plans/plan-sess_3b4caee6-b481-44e9-a4f0-d07f06f6caa5.md`；`git check-ignore -v .zcode` **无输出**（未忽略）；`.gitignore` 仅第 113 行忽略 `.zcodeignore`（文件），未忽略 `.zcode/`。
- 根目录 `ls -d tmp_*` = **68** 项、`ls -d .tmp*` = **4** 项；`.tmp/` 磁盘占用 **4.5GB**（`du -sh .tmp`）。
- 覆盖核验（`git check-ignore -v`）：`nul` → `.gitignore:94`；`.tmp_orig_live.db` → `:72`；`tmp_batch3a_book.txt` → `:49`；`rust/nul` → `:94`；`rust/_p03_commit_msg.txt` → `:80`；`rust/timing_book_out.txt` → `:78`；`docs/gate_baseline_test.txt` → `:121`。**全部已覆盖，且 `git ls-files` 无任何被跟踪的 `nul`/`tmp_*`/`_p03_*`/`.tmp` 文件**——上次审查「已正确覆盖，仅本地清理项」的结论仍成立。
- 根目录 `.md` 仅 `AGENTS.md`、`CHANGELOG.md`、`README.md`（+ `LICENSE` 非 md），符合 `AGENTS.md:50` 与 `docs/README.md:80-85` 的存放规范；本批新增的 `docs/DEVICE_ACCEPTANCE_*`、`docs/audit_20261113/` 均在 `docs/` 下，规范合规。
- `docs/materials_1111d|1112a|1112b` 等证据目录已被跟踪（58/50/103 文件），属有意入库的设备验收证据，不算杂物。

**影响**：`.zcode/` 会作为 untracked 目录长期出现在每次 `git status`，易被误提交；4.5GB `.tmp/` 不占仓库但占本地磁盘。均无用户可见影响。

**修复方向**：`.gitignore` 增加 `.zcode/`；本地清理 `tmp_*`/`.tmp*`/`.tmp/` 可择机执行（不属于仓库缺陷）。若 `.zcode/plans` 需要保留，可改为 `!.zcode/plans/` 例外规则。

---

### P3-11 零引用死代码：6 个孤儿组件 + `custom_progress.dart` 仍只有测试引用

**证据（我方）**

- 6 个组件文件仍在：`flutter_legado/lib/src/widgets/search_bar_widget.dart`、`swipe_action.dart`、`source_card.dart`、`tag_chip.dart`、`badge_widget.dart`、`chapter_tile.dart`。
- 全 `flutter_legado/lib` 搜索其 import/类名：**零生产引用**（`rg 'widgets/<name>.dart|<ClassName>' lib` 仅命中文件自身）；仅 `test/widget/*_test.dart` 引用（7 个测试文件）。
- ACTIVE_PLAN `:583`（2026-09-30）原话：「**待用户裁决**：6 个孤儿组件仅测试引用零生产接线（search_bar_widget/swipe_action/source_card/tag_chip/badge_widget/chapter_tile）——接线 or 移待删除目录」。此后全文档无回销。
- `custom_progress.dart` 同样：全 `lib/` 零生产引用，仅 `test/widget/custom_progress_test.dart`；对应 ACTIVE_PLAN `:578`「`custom_progress.dart` 死代码待清理批」，无后续记录。

**影响**：违反 `docs/DEVELOPMENT_CONVENTIONS.md:293`「周期性零引用清理」；孤儿测试会持续消耗 CI 时间并制造「组件仍在用」的错觉。

**修复方向**：把 6 组件 + `custom_progress.dart` 列入下一批零引用清理：按用户裁决移 `docs/pending_deletion/` 或接线；无论哪种，都应在 ACTIVE_PLAN `:583`/`:578` 回销，避免再次失联。

---

### P3-12 docs/VERSION_CONTROL.md 冻结在 2026-07-30 的 v2.1.0，无失效标注

**证据（我方）**

- `docs/VERSION_CONTROL.md:1`「# 项目版本控制记录」；`:3`「## v2.1.0 - 重构功能修正版 (2026-07-30)」；文件 161 行，正文大量 `file:///d:/OH-WorkSpace/LegadoTeam/legado/flutter_legado/legado/app/...` 旧路径与 2026-07 的删除/新增记录。
- 文件头无「历史/冻结」横幅，而 `docs/README.md:66,72` 仍把它列为「规范类」当前文档。
- 对比：`rust/PROGRESS.md:3` 已有失效横幅；`docs/VERSION_CONTROL.md` 是同类历史状态文档但未加。

**影响**：读者会把它当作现行版本控制规范；其中的 v2.1.0 与当前 2.0.491+492 的版本序列冲突，且旧路径已不可用。属低风险文档卫生问题。

**修复方向**：文件头加「2026-07-30 冻结，历史记录；当前版本与提交规范见 CHANGELOG / AGENTS.md」；或移入 `docs/过期文档/` 并更新 docs/README 索引。

---

## 四、待核实（5 条，附核实方法）

### V-1 上次审查 8 条中的 A5「振幅待验证」是否已正式回销

- 事实：`REFACTORING_ACTIVE_PLAN.md:805`（2026-10-07 iOS 保活实施）仍写「振幅 0.02 ≈ -34dBFS……**待实机验证**」；紧接的 `:808`（同日第二轮）写「**保活 C+A 实机验收通过**——用户实测『10 分钟网站依然可以访问』」。
- 判断：该冲突**事实上已由次日日志闭环**，但未按 2026-10-26 的回销格式在 L805 加注（上次修复只动了 L26/L261/L265/L697 + 3 个 hash）。
- 核实方法：在 L805 末追加「2026-10-07 实机验收通过，见下条」即可；若认为相邻日志已足够，可判为「无需修复」。
- 归类：部分回销（P3 子项，不单列计数）。

### V-2 ACTIVE_PLAN L561「2.0.325 装机冒烟 + V3 设备点验」与 L569 波次2 尾项的当前状态

- 事实：两条自 2026-09-30 后无关闭记录；代码侧可见 `touchSlop` 已参数化（`reader_page_view.dart:1408`），`manga_page_scale_type.dart:42` 存在「智能适配」模式，说明部分项可能已在后续批次顺手落地，但文档无回销。
- 核实方法：对 L569 逐项在 `docs/DEVICE_ACCEPTANCE_*.md` 与 `git log --grep` 搜关键词（孤儿 overlay/自动翻页 glide/无书源保存/touchSlop/点验低项）；对 L561 搜 2.0.325 冒烟记录与 V3 视频选集/倍速的设备验收（可能并入视频轨道 V-B4）。
- 本次不判缺陷，只登记「无法从文档判定」。

### V-3 `docs/EXPERT_TEAM_WORKFLOW.md` 已被归档，但 agent harness 仍按该路径引用

- 事实：`docs/EXPERT_TEAM_WORKFLOW.md` **不存在**；实际文件在 `docs/过期文档/EXPERT_TEAM_WORKFLOW.md`；`docs/过期文档/ARCHIVE_MAP_20260922.md:10` 记载「P7 判定无引用」而归档。本次审查所用 agent 工作流（系统提示中的「8 步工作流，内容来源：docs/EXPERT_TEAM_WORKFLOW.md 第二章」）仍指向已归档路径。
- 影响：属 agent 配置层漂移，不是仓库文件缺陷；但会让后续 agent 找不到流程正本。
- 核实方法：由主代理检查 harness/agent 配置文件（不在本仓）并改指 `docs/REFACTORING_WORKFLOW.md`；或在 `docs/过期文档/EXPERT_TEAM_WORKFLOW.md` 头部加「当前流程以 REFACTORING_WORKFLOW.md 为准」。

### V-4 审查基线工作树不干净（并行会话在途）

- 事实：HEAD `7c15e82252`，但 `git status` 有 4 个已跟踪文件修改（`flutter_legado/android/.../AndroidManifest.xml`、`MainActivity.kt`、`lib/app.dart`、`other_settings_screen.dart`）与 8 个未跟踪文件；3 个新源码文件 mtime 为 2026-11-13 00:58~01:01。
- 影响：本报告所有文件行号/内容均取自 HEAD 已跟踪版本；若并行会话后续提交，行号可能漂移。不构成本路缺陷。审查结束前复核发现该并行会话已把这批文件 `git add` 进暂存区（`git status` 显示 10 项 staged），进一步证实其为在途开发而非本路产物。
- 核实方法：主代理汇总前 `git status` 复核；建议在总报告中声明「审查时点工作树含并行会话改动」。

### V-5 用户 2026-11-13「审查不限并行」未入 AGENTS/工作流文档

- 事实：`AGENTS.md:90` 与 `docs/REFACTORING_WORKFLOW.md:58` 均写「同一时间最多两个子代理并行」；全仓仅 `docs/audit_20261113/BRIEF.md:112` 提到 2026-11-13「审查不限并行」。2026-11-11 用户「后续开发并行两个子代理」与 AGENTS 的 2 一致，无冲突；**冲突只在 11-13 的审查例外没有落文档**。
- 影响：本次五路并行审查与 AGENTS 字面规则相抵；若后续继续按 AGENTS 执行，审查批次无法复现。
- 核实方法：由主代理在 ACTIVE_PLAN 或 AGENTS 补一句「开发任务并行上限 2；只读审查批次不受此限，由任务书单独授权」；或确认「审查不限并行」只属本次一次性指令、不写入长期规则。

---

## 五、上次审查（2026-10-26）文档项回销核查

| 上次项 | 本次核查结果 | 证据 |
|---|---|---|
| `rust/PROGRESS.md` 失效横幅 | **已修** | `rust/PROGRESS.md:3` 横幅完整（2026-08-07 冻结 + 指向 ACTIVE_PLAN） |
| 4 处活链（docs/DEVELOPMENT.md:105,296、docs/VERSION_CONTROL.md:124、rust/DEVELOPMENT.md:756） | **已修** | 4 处均含「冻结/历史快照」注记；第 5 处 `rust/README.md:204` 漏网（见 P3-3） |
| ACTIVE_PLAN 正文 8 条口径 | **部分修复** | L26/L261/L265/L697 已回销；A5 振幅仅靠相邻日志闭环（V-1）；另有 10 处新/旧冲突（P3-4） |
| 3 个 hash 欠账（43a5096376/9c0bacffe0/f40601141c） | **已修** | 三 hash 均 `git cat-file -t` = commit；L734/737/739 均含「2026-10-26 补记」；`2ba7f963df` 报告提交亦真实 |
| 双日志补缺（updateLog 2.0.336、CHANGELOG 2.0.200/203） | **已修** | `CHANGELOG.md:2901/2862`、`updateLog` 2.0.336 均存在；470~491 双日志 22/22 对齐 |
| AGENTS.md adbd root | **已改但已被环境推翻** | `AGENTS.md:71` 已按 2026-10-03 实测改「非 root」，但 2026-10-27 起 26 份验收报告记录 root/adbd root（P3-8） |
| `legacy/mod.rs:21-23` B3/B4 注释 | **已处理** | 2026-10-26 审计登记明确「B3/B4 编号口径作废，以本条清单为准」；本次未发现活引用 |
| TASK_HANDOFF 完结标注 | **已处理** | `ACTIVE_PLAN:825` 记录 `07f5ac760c` 完结横幅 |

**结论**：上次 8 条（5 处正文口径 + 3 个 hash 欠账）中，4 处正文回销 + 3 个 hash 补记已确认落地，A5 振幅仅靠相邻日志闭环（V-1）；另有 PROGRESS 失效横幅与 4 处活链这 2 个独立文档项亦已落地。但**新累积的正文滞后（P3-4/P3-5）已超过上次修复量**，说明「只追加尾部日志」的习惯仍在。

---

## 六、正面清单（本次核验通过）

1. **hash 真实性高**：最近 30 条修订日志 82/82 提交号真实存在；全文件唯一真实拼写错误仅 1 处（P3-6）。
2. **双日志 470~491 完整**：22 个 versionName 在 CHANGELOG 与 updateLog 一一对应，日期一致；2.0.491 条目内容量与 updateLog 同步（CHANGELOG 6 条 / updateLog 6 条）。
3. **文档存放规范合规**：根目录 md 仅 AGENTS/README/CHANGELOG；新增报告均在 `docs/`；`docs/audit_20261113/` 符合规范。
4. **仓库忽略规则有效**：`nul`、`tmp_*`、`.tmp*`、`rust/_p03_*`、`*.db`、证据目录例外均正确；`git ls-files` 无被跟踪杂物。
5. **CI 主体覆盖充分**：rust-ci 含 fmt/check/clippy 两档/test/quickjs 四 crate（js/fetcher/ffi/server）/audit；flutter-ci 含 FFI 构建+hash 校验+analyze+test；另有 integration-smoke、ios-build、flutter-release；自 2026-10-26 以来无 workflow 删除。
6. **尾部日志与代码一致性抽查通过**：批18~21 的关键符号（`TempDirCleaner`、`normalized_rar_entry_name`、`scan_rar5_entry_names`、`evalImageAction`、`invalidate_image_action_engine`、`appFontPath`、`prepareRemoteBackup`/`restorePreparedBackup`、`replayImageActionSideEffects`）均在代码中真实存在，未发现「日志说做了但符号不存在」。
7. **归档文档引用可解析**：ACTIVE_PLAN 点名的 10 个 `docs/过期文档/*` 路径全部存在。


---

## 七、登记项计数（任务书必查点）

按状态词逐行统计 `docs/REFACTORING_ACTIVE_PLAN.md`（正文 L1~660 / 尾部 L661~1253）：

| 类别 | 正文提及 | 尾部提及 | 去重后的实质在案项（本次判定） |
|---|---|---|---|
| 「待用户裁决」 | 5 处 | 17 处 | **3 组**：`L583` 6 个孤儿组件接线/移待删除目录；`L606` 参考版中间键语义（我方保持自动翻页键）；`L640` 在案 4 项（Material You 动态取色默认槽位、首页模块解禁、animateItem 三件套、A* 9 项待素材）。另 `L294`（P2-20）与 `L336`（感知等待）属**已闭环但因未回销仍被计数**的假阳性 |
| 「待核验」 | 3 处 | 4 处 | **1 项**：`L631` P3-8 iOS 三端收敛（低优）。正文另 2 处是 §一 的状态定义（L9/L13），不是条目；尾部 4 处为各批「待核验」引用，其中批19 的 `other_settings_screen.dart:607`「本地密码用于 Web 服务鉴权」误导项仅存在于日志、未进正文台账 |
| 「P3 登记」 | 散布于 P3 段与各批日志 | 散布 | **无统一计数口径**。最新盘点 `L1243` 把技术债归为 A3 共 7 类；各批尾日志还有大量「P3 登记」条目（如批18 5 项、批19 5 项、批20 6 项、批21 5 项），其中多数是「如实登记不修」，无法用单一数字表达。建议后续在 ACTIVE_PLAN 顶部维护「P3 台账索引」而非依赖全文搜索 |
| 尾部最新盘点 `L1243` | — | 1 处 | 原列 A1 未开工 6 / A2 已裁决不做 3 / A3 技术债 7 类 / B1 待裁决 5 / B2 架构 3 / B3 风险接受 2。经批18~20 回销后，**实际未决收窄为**：A1-4 TTS 实际发声、A1-5 生物识别真机链路、A3 技术债 7 类、B1-3/4/5、B3 全部；A1-1/2/3/6、B1-1/2、B2-1/2/3 已关闭（`L1247`/`L1249`/`L1251`） |

**结论**：计数层面的主要问题不是「条数多」，而是**同一状态存在三个口径**（正文旧段、尾部盘点、后续批日志的「下一步」），且没有一处维护「当前开放项快照」。这与 P3-4/P3-5 同根。

---

## 八、修复建议排序

| 顺序 | 内容 | 类型 | 建议批次 |
|---|---|---|---|
| 1 | P3-4：10 处正文口径冲突逐条回销；顶部新增「当前开放项快照」 | 文档 | 下一文档批（可 1 个子代理，纯机械） |
| 2 | P3-8/P3-9：AGENTS.md 设备事实（root/端点/恢复）+ CI 引用 + 模块地图 | 文档 | 与 #1 同批 |
| 3 | P3-1/P3-2/P3-3/P3-12：README、DEVELOPMENT、rust/README、VERSION_CONTROL 四处入口/开发文档刷新 | 文档 | 同批或紧接 |
| 4 | P3-6：修正 `13b1b3b59`；清理 25 条「提交待收口」模板；P3-5 的 `custom_progress` 死代码 | 文档+死代码 | 同批 |
| 5 | P2-1：rust-ci quickjs clippy 补 `-p legado-fetcher` | CI | 可随下一次 CI 改动 |
| 6 | P3-10：`.gitignore` 加 `.zcode/`；本地清理 `tmp_*`/`.tmp` | 卫生 | 随时 |
| 7 | P3-7：历史日志 272/273 对调、2.0.3 注明 versionCode | 文档（低优） | 择机 |
| 8 | P3-11：6 个孤儿组件 + `custom_progress` 的用户裁决 | 产品裁决 | 待用户 |

---

## 九、证据复现命令（只读）

```bash
# 1) 版本覆盖比对
python -I - <<'PY'
# 解析 CHANGELOG '## [x.y.z] - date' 与 updateLog '**YYYY/MM/DD（x.y.z）**'
# 结果：470~491 各 22 条，集合/日期一致；2.0.492 仅存在于 pubspec '2.0.491+492'
PY

# 2) hash 抽查
git cat-file -t 13b1b3b59        # missing
git cat-file -t 13b1b33b59       # commit（实际提交）
git log -1 --format='%h %s' 13b1b33b59

# 3) 全文件 hash 批量核验（1021 unique）
#    结果：9 非对象值 = 8 非提交值 + 1 拼写错误

# 4) 正文/日志冲突
rg -n '仍开放|待用户裁决|提交待提交|待补|设备验收待补' docs/REFACTORING_ACTIVE_PLAN.md --encoding utf-8

# 5) 双日志历史单调性
rg -n '^## \[2\.0\.3\]' CHANGELOG.md
rg -n '^\*\*2026/09/17（2\.0\.27[0-4]）' flutter_legado/assets/updateLog.md

# 6) 入口文档陈旧
rg -n '2\.0\.60|8 个 crate|62 个 Screen|Schema v95' README.md docs/DEVELOPMENT.md
rg -n 'SCHEMA_VERSION' rust/legado-db/src/schema.rs

# 7) AGENTS 设备事实
rg -n '非 root|192\.168\.1\.19|当前不可用|test\.yml|BetaRelease' AGENTS.md
rg -n 'uid=0\(root\)' docs/DEVICE_ACCEPTANCE_*.md | wc -l

# 8) 仓库卫生
git check-ignore -v .zcode/plans/plan-sess_3b4caee6-b481-44e9-a4f0-d07f06f6caa5.md || echo "not ignored"
git status --porcelain=v1 -uall
ls -d tmp_* | wc -l; du -sh .tmp
```

---

— 文档可靠性与仓库卫生审查子代理 ｜ 2026-11-13
