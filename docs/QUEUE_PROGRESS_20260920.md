# 执行队列进度记录（2026-09-20，子代理暂停时点）

> 性质：长期队列的**进度快照与续跑交接**。用途：子代理通道调整/会话中断后据此恢复，避免在途工作丢失或重复。
> 记录人：主代理（ZCode 本机通道）｜ 2026-09-20
> **触发**：用户指令「子代理需要调整，记录进度，然后暂停子代理」——两个在跑子代理已 `TaskStop`。

---

## 一、已收口批次（全部已提交并推送，CI 双绿）

| 批次 | 关键提交 | 说明 |
|---|---|---|
| P2-7(b) 沙箱 SIGSEGV | `d689584fef` + `36bc435921` | gdb 实证为 quickjs-ng 0.8 `build_backtrace` 重入 OOM UAF；用例改单次巨量分配；CI 撤销无效隔离 |
| 提交卫生 | `548bbc5004` | 根目录工具产物清理 + 忽略规则 |
| P2-17 联网用例 | `de1803bc15` + `e5da605fd1` | 11 例 `#[ignore]`；后 9 例夹具化转离线（`f101b8f673`） |
| P2-15 收口 | `6d2a5c29cc` / `e5da605fd1` | cache 宿主接线（frb 薄桥 + Dart 注入 + 写失败限流）；overlay 收窄与陈旧让位 |
| P2-18 Flutter CI | `f97efdfcb2` | `setup-android` 的 `tools` 包已下线 → 恢复长期被 skip 的 analyze/test 门禁 |
| P2-11 五小项 | `d13d1a04e5` / `16f6e09e92` / `0fe222a3c8` | 复合键反查、缓存清理策略、java.lang 严格语义、getStringList 对齐、**顶层 return 规则静默吞空根因修复** |
| P2-16 rquickjs 升级 | `b662d71741` + `36bc435921` | 0.9→0.12.2 零断点；原崩溃配方转正为回归断言（Windows+WSL 双端实证） |
| P3-6 收口 | `deb0e87005` / `473968bcaf` | F1 loginCheckJs 三叉点对齐、错误八分类（契约加法式）、S0-D 计时、三入口一致性测试；实机探针验证（`efaf4a52f9`/`e27e0f6721`） |
| RenderFlex + 崩溃误报 | `323bb61e4e` / `e150c86309` / `91825ec2b3` / `ca3032a2ff` | 三屏右溢修复 + 溢出守卫 13→59 屏；非致命布局告警不再误报为崩溃 |
| 深色 Batch A + M1 | `c1616a1fc3` / `2d298159e2` / `2de89c4d02` | 漫画弹层等 scheme 化；**M1 深色阅读背景跟随主题（默认纯黑）** |
| 深色台账与采集 | `db512336aa` / `742af2e475` / `c83cef775c` | 台账建立；参考版优先 7 屏深色采集；我方采集 + 8 组配对差分（M1 为唯一必修项） |
| Rhino 实证与口径 | `0adb9f30bd` / `77ebca96e2` | 详解文档 + 916 源合集实测（`importClass`/`Java.type` 0 命中；书山/番茄已消失） |
| 口径落档 | `069c5aa723` / `f4c5102d95` / `9fcf403514` / `f8f7832ac5` | 全域口径（视觉照参考版/功能倾向我方）；MuMu ROM 清单更正；设备双车道（Test/Test2） |
| 用户侧目录清理 | `b99538b891` / `bb08c173bc` / `5d33f7bf0c` / `d3accef580` | 用户会话执行；主代理已复核（无跟踪文件误删、无断链、保留项在位） |

**当前版本**：`2.0.300+301`（pubspec）｜**本地与远端一致**（0/0）。

---

## 二、暂停时点：两个子代理的在途状态

### 2.1 A 组对齐（A1/A4/A5/A6）——**有未提交代码改动，必须接管**
`git status` 未提交的跟踪文件（**未验证、可能不完整**，续跑前先 `flutter analyze && flutter test` 判可用性）：

| 文件 | 改动 | 对应项 |
|---|---|---|
| `flutter_legado/lib/src/screens/qrcode_screen.dart` | +378/-… 大改 | **A1 扫码改全屏扫描器**（参考版形态） |
| `flutter_legado/lib/src/widgets/reader/reader_menu_panel.dart` | -166 行 | **A5 菜单收敛到参考版 5 键** |
| `flutter_legado/lib/src/screens/search_content_screen.dart` | +21 | **A6 输入盒配色**（含污染复核） |
| `flutter_legado/pubspec.yaml` + `pubspec.lock` | +4 / +24 | **新增依赖 `zxing2 ^0.2.4` + `image ^4.8.0`**（图库二维码本地解码）——**新依赖尚未按规范做依赖评估**（技术选型/许可/维护性），续跑时补 |
| A4 详情入口 | 未开始（该代理按"证据不足先报告"要求，未动） | 需先补参考版单击语义证据 |

**在途改动补丁备份**：`.tmp/inflight/a_group_20260920.patch`（`git diff` 全量导出，防后续 git 操作误清；若工作树被清可 `git apply` 恢复）。

未产出汇报；A2/A3 的"对齐事实清单"也未写完（需设备侧补采：参考 12 主题卡名称/颜色、外观页干净基线）。

### 2.2 M1 + 崩溃修复设备验证——**产出了部分证据，未写判定**
证据（已落 `docs/parity_shots/queue_smoke_20260920/`，前缀 `m1b_`，共 32 项）：
- `m1b_00_resume_state.png` / `m1b_01_shelf_dump.xml` / `m1b_02_book_detail.png` / `m1b_03_reader_dark.png` / `m1b_05_reader_dump.xml` / `m1b_06_verify_screen.png` / `m1b_07_reader_dump2.xml` / `m1b_09_ours_reader_top_crop.png` 等。

**主代理快速采样（非正式判定）**：我方深色阅读器正文区均值 **(23,23,23)**，参考 `ref_dark_20260920/10_reader.png` 同区 **（27,27,27）**——**数量级一致，M1 看起来已生效**（此前为纯白 255）。**待办**：正式采样（避开文字的空区）出判定、M1-b 阅读中切主题即时生效、M1-c 显式选择保留、M1-d chrome 可读性、崩溃误报复核（`crash_log.txt` 无新增崩溃段 + 冷启动不弹窗）、三探针回归；最后写 `VERIFY_M1_20260920.md`。

---

## 三、续跑队列（按序，复工即可用）

| 序 | 任务 | 备注 |
|---|---|---|
| ① | **A 组续跑**：先验在途改动可编译（analyze/test）→ 补新依赖评估 → A4 先取证后改 → A1/A5/A6 收尾并跑门禁 | 复用 §2.1 的在途文件，勿重写 |
| ② | **M1 验证收尾**：按 §2.2 待办清单跑完 + 写小结 | 设备：Test `192.168.1.19:5555` |
| ③ | A-4 死默认改必填（含 code-reviewer）/ A-5 删 `app_colors.dart`（先验无动态引用→在用槽位改 MD3→全量测试）/ N6 保留页面+收起入口+登记授权偏离 | 用户已裁决 |
| ④ | 能力受限提示 + 未知类告警（合并机制；favcomic 文案对齐原版/参考版；不建 JVM 桥） | 用户已裁决 |
| ⑤ | 七猫 588KB / favcomic 16KB jsLib 夹具入库 + 端到端测试 | 语料 `.tmp/corpus/qimao_jslib.js` 在；另可从 `.tmp/corpus/yckceo_1283.json` 取 favcomic |
| ⑥ | P2-3 Mock 书架样例：改用**合成式脱敏**（源数据 `.tmp/db_oldapp_v9` 已随清理删除）+ 替换 `mock_book_api.dart` 占位 | 产物先给用户过目 |
| ⑦ | A2/A3 设备轮：参考 12 主题卡名称/颜色事实提取 + 外观页干净基线重采 → 对齐（视觉照参考版） | 建议放 **Test2** |
| ⑧ | 688/712 自证：`📂网阅小说`(book15.net) / `🏷松鹤庭沐·言璃`(so.html5.qq.com#v2修复版) 均在 916 源合集内，自行注入验证 | 建议放 **Test2** |
| ⑨ | **目录治理批 P1~P10**（用户侧清单）：P1 11 个"假绿"测试（补 ignore 或迁夹具）、P2 4 个入库 `tmp_songhe*.json`、P3 技能三处同步、P4 根目录 `api.md`/`Makefile`、P5 probe-icon 死流水线、P6/P7 文档归档、P8/P9 证据与日志残留、P10 未跟踪物定策 | 详见 `docs/PENDING_DELETE_20260920.md` §四 |
| ⑩ | 可选排期两项：P1-1 项2 聚合下沉 + 跨端夹具校验；P1-2 项3 重试/cookie/charset 逐项评估 | 用户指定排最后 |
| ⑪ | 收尾：全队列交付报告（含 Mock 产物过目、证据索引、CI 状态） | 交付时喊用户 |

---

## 四、环境与口径速查（复工免查）

- **设备**：Test = MuMu index 1，`192.168.1.19:5555`（主验证档，含三包）；**Test2** = MuMu index 0，`127.0.0.1:16384`（并行档，三包齐；override `wm size 1080x1920` + `wm density 480`，**重启后需重跑**）。启动：`MuMuManager.exe control -v <idx> launch`。
- **MuMu ROM 绕行**：adbd 即 root + 自带 sqlite3；中文输入走 `search_keywords` 注入或历史 chip（`input text` 仅 ASCII）；`screencap` 用 `exec-out`；uiautomator 自杀噪声；`secure` 静默回滚用 `global`。
- **口径**：视觉一律照参考版（全域）；功能实现倾向我方、差异特别大才上报；参考版即 `io.legato.kazusa`（源码副本 `D:\tmp\md3_ref_legado`）。
- **参考源**：上游 Kotlin `D:\OH-WorkSpace\LegadoTeam\legado-upstream`；重构版 Flutter `D:\OH-WorkSpace\Projects\legado_flutter`（源码 `lib/` 5.2M）。
- **构建注意**：`rust/target` 与 `flutter_legado/build`、`jniLibs` 已随目录清理删除 → **下次本地构建为全量重编**；CI 不受影响。
- **门禁两档**：`cargo test --workspace` 与 `--features legado-ffi/quickjs`；clippy 两档；`flutter analyze` + `flutter test`。

---

编写者：主代理（ZCode 本机通道）｜ 2026-09-20
