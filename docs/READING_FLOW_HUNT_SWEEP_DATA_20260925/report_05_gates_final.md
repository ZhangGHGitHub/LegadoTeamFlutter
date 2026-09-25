# 门禁与收尾结论（最终状态，2026-09-25）

## 门禁结果（均在 `rust/` 工作区根执行，最终文件状态重跑）

| 门禁 | 命令 | 结果 |
|---|---|---|
| Gate 1 | `timeout 900 cargo test --workspace` | PASS：全部 `test result: ok`，0 failed（含 417/277/305/249/173 各套件），GATE1_EXIT=0（日志 gate1_cargo_test.log） |
| Gate 2 | `timeout 600 cargo clippy --workspace --all-targets -- -D warnings` | PASS：0 warning / 0 error，GATE2_EXIT=0（日志 gate2_clippy_ws.log） |
| Gate 3 | `timeout 600 cargo clippy -p legado-js -p legado-ffi -p legado-server --features quickjs --all-targets -- -D warnings` | PASS：Finished，GATE3_EXIT=0（两次：13 处 lint 修复后、fmt 后各跑一次，日志 gate3_clippy_quickjs.log） |
| Gate 4 (fmt) | `cargo fmt --all` → `cargo fmt --all --check` | 均 exit 0，零 diff |
| 附 | `cargo test -p legado-ffi --features quickjs --test capability_sweep`（默认档不跑 `#[ignore]` 干跑） | 1 passed（静态对账）; 1 ignored（干跑）; 0 failed; 0.39s |

## 干跑执行（-- --ignored，离线，4 路并发池）

- 916 源全量，elapsed 1.63s（单源 3–36ms）
- 分类：ok-离线可跑 856（93.5%）/ c-需网络或登录 48（5.2%）/ b-JS错误 12（1.3%）/ a-缺失Java能力 0 / d-引擎panic 0
- 明细：dry_run_details.json（916 行）；报告：dry_run_report.md

## git 状态（任务约束核验）

- `git status --short` 仅一行：`?? rust/legado-ffi/tests/capability_sweep.rs`（新增清扫入口，未 track）
- `git diff --stat` 为空 → 零已跟踪文件改动（无 .md、零生产逻辑改动，三禁区 `legado-js/src`、`legado-ffi/src`、`legado-net/src` 未触碰）
- HEAD = `1ffee8a5ef feat(js): 补 MessageDigest 与 jsoup Elements 能力（修七猫/77读书搜索失败）`（任务开始前既有提交，本任务零 commit、零 push）
- `.tmp/` 工作产物未被 git 跟踪

## 交付物索引（.tmp/capability_sweep/）

- report_01_recon.md（侦察）· report_02_static.md（静态对账结论）· report_03_dryrun.md（干跑结论）· report_04_triage.md（分诊 + 确认不做）
- static_report.md / .json · dry_run_report.md · dry_run_details.json · capability_names.txt（164 能力面）
- gate1_cargo_test.log · gate2_clippy_ws.log · gate3_clippy_quickjs.log · dry_run_stdout.log
