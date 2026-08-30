# 会话更新日志（2026-08-29 ~ 2026-08-31）

> 本文档汇总该会话内各批次任务的完成汇报原文要点，按时间顺序排列；每条含交付内容、验证结果与提交哈希，供回溯与交接。详细技术细节以各提交正文、CHANGELOG 与专项文档为准。
> 会话主线：热力图契约 → 搜索/换源 parity 修复 → 双包实测 → GitHub CI 治理 → 安卓源码移出 GitHub → iOS 轨立项与 P1/P2 全程。

---

## 一、热力图每日时长聚合契约（2026-08-29，版本 2.0.126+131）

**任务来源**：U 侧 UI_MD3_PLAN 登记需求「热力图『每日时长』模式需 Rust 契约先行」。

**交付内容**：
- `legado-db` 新增 `readRecordDaily` 日聚合表（date TEXT PK + durationSeconds，懒建表无迁移）及 `add_daily_seconds` / `list_daily_year`
- api 层 `putReadRecord` 写路径单作用域增量聚合（增量 = 新 readTime − 旧 readTime，仅 > 0 入账，本地时区）
- 新增 `readRecordDailyList(year)` FFI（返回 `[{date, seconds}]` 日期升序），FRB 绑定重生成
- `BookApi`/`RustApi`/`MockBookApi` 三层补齐；API_CONTRACT §2.12（5→6 方法、口径 264→265）

**验证**：workspace 2483/0、quickjs 397/0、fmt 干净、flutter analyze 0、flutter test 1312 全绿。

**提交**：`94e947d`（后经 amend 归一 API_CONTRACT 行尾）。

**附带根治**：`js_executor` 缓存测试并行竞态（精确 len 断言改容量不变式，MAX_ENTRIES pub 化）——该缺陷会确定性击穿 CI quickjs 门禁。

---

## 二、搜索/换源 parity 审计 D1-D6 修复（2026-08-29，版本 2.0.127+132）

**任务来源**：`docs/SEARCH_CHANGE_SOURCE_PARITY_AUDIT_20260829.md`（只读审计，用户指示落地修复）。

**交付内容**：
- **D1（换源"结果变少"主因）**：Dart 两处分组分隔符从仅逗号补齐为原版全集 `,;，；`（notifier 预过滤 + screen 分组聚合）——分号分组书源不再被 Dart 预过滤整源丢弃
- **D2**：换源候选不再剔除 bookUrl 为空条目（对齐 BookList.kt:281-284 回退 baseUrl 入列；保留展示+点击兜底报错）
- **D3**：`multi_source_search` 补落库 searchBooks（对齐 SearchModel 两入口均落库）
- **D4**：JS 书源结果应用 precision filter（原版传入 JsSourceBook.searchAwait 口径）
- **D5**：换源筛选框只按书名 contains（移除源名匹配）
- **D6**：换源同名判定收紧为 trim 后字面全等（删除括号归一化）；读库改原样书名查询

**验证**：workspace 2482/0、quickjs 397/0、analyze 0、flutter test 1313 全绿（含新增 D1 回归测试）。

**提交**：`133914f0f1`。

---

## 三、双包同书一致性实测（2026-08-30）

**背景**：用户问「模拟器测试过搜索同一书籍结果一致吗？换源结果一致吗？」——此前只有冒烟+单测级，本次补做实测。

**方法**：5556 同机双包（原版 com.legado.app.release + 重构版），同关键词「斗破苍穹」，真实网络，ADBKeyboard + uiautomator 清点。

**结论**：
- 主搜索首屏聚合与排序规则一致（首行同名同作者、桶内按来源数降序）；我方收集显著更快（5 分钟 9582 行 vs 原版 15 分钟 631 行），无"系统性变少"证据
- 换源：结构一致；我方"找到 465 个匹配书源"（DB 路径，实测验证 D1/D2/D6 修复）；原版弹窗快照 82 候选且持续增长
- 严格终态对比在此环境不可达（双侧 15-20 分钟均无法搜完，与 S0-C 结论一致），需夹具化受控环境

**遗留**：S0-C 关闭需用户三选一（debug 原包 run-as 读库 / 禁用真实源跑夹具 / 换 AS 模拟器环境）。

---

## 四、GitHub workflow 错误修复（2026-08-30）

**根因三处**：
- Sync Upstream 每日失败：上游 gedoor/legado 仅剩 `main` 分支而任务 fetch `master`；且其功能（自动同步上游安卓源码）与后续指令冲突 → 删除
- flutter-ci android-ffi-sync E0463：rustup `--default-toolchain none` 后直接编译 → 改 dtolnay/rust-toolchain@stable
- test.yml 0 秒失败：job 级 if 引用 secrets 上下文 + 注释缩进混乱被 GitHub 判无效文件

**提交**：`9b4649ac7a`（推送至 fork master）。

---

## 五、安卓源码移出 GitHub（2026-08-30）

**用户指令**：① 上传部分确认安卓源码并移除；② 本地把安卓源码目录加入不上传名单。

**交付内容**：
- `git rm --cached app modules`（约 2540 文件解除跟踪，本地磁盘保留参照）
- `.gitignore` 新增 `/app/`、`/modules/` 名单
- 删除全部安卓工作流（test/BetaRelease/release/cronet/web/TestRelease）与 legado.jks 签名密钥
- 远端视图收敛为 Flutter/Rust 双 CI + 轻量工具流

**验证**：远端根目录无 app/modules；后续推送零失败 run。

**注意**：历史提交仍含安卓源码旧快照，彻底抹除需 filter-repo 重写（未授权不执行）。

---

## 六、iOS 轨可行性勘察（2026-08-30）

**用户授权**：「原生缺口也需要补齐」「重构为 Flutter+Rust 三端通用版本」——iOS 轨正式立项。

**勘察结论**（详见 `docs/IOS_TRACK_FEASIBILITY_20260830.md`）：
- ios/ 脚手架存在但无 Podfile；legado-ffi 已含 staticlib ✓；rquickjs 支持 iOS 目标
- 10 个 Android 原生桥均有成熟跨端插件替代（audio_service/flutter_tts/flutter_inappwebview 等）
- 公开仓库 macOS runner 免费无限；未签名 ipa 需自签（7 天）
- 关键约束：Windows 本机，iOS 迭代全依赖 GitHub Actions
- 计划分 P0 准备 / P1 FFI 接线+CI 首包 / P2 原生补齐 / P3 三端收敛

**提交**：`2aa028af5b`。

---

## 七、iOS 轨 P1 里程碑（2026-08-30，版本 2.0.128+132）

**里程碑**：ios-build.yml（macos-15）全绿——**未签名 ipa 产出** + **iOS 模拟器启动到书架**（截图证据），Rust FFI 静态链接实测工作（初始化 142ms、ttsSetCacheDir ok、DB 打开）。

**过程排障（每层独立提交）**：
1. rust-toolchain.toml 锁定 1.97.1：target 全装进 stable 致 E0463 → 改在 rust/ 目录内 `rustup target add`（同根因顺带治好 flutter-ci android-ffi-sync）
2. rquickjs-sys 0.9 无 iOS 预置绑定 → apple 目标启用 bindgen 运行时生成
3. app/ 编译期依赖三处（dictRules/coverRule 种子 JSON、18 个 web help md）→ 收入 rust/assets/
4. unrar（C++）libc++ 链接缺失 → 与 Android 同策略排除 iOS（archive.rs 降级分支扩 any(android, ios)）
5. cdylib 链接缺 compiler-rt → `cargo rustc --crate-type staticlib`
6. 模拟器 bindgen 三元组 `-simulator` 覆盖；模拟器构建改 debug（flutter 不支持 simulator+release）
7. Flutter 版本统一 3.44.8（book_group_screen onReorderItem 需 3.44+）；flutter-ci 补 workflow_dispatch

**提交**：`1f58b665f8` 起至 `853563397b`。

---

## 八、iOS 轨 P2-A 五通道插件化（2026-08-30，版本 2.0.129+132）

**交付内容**（每条 Android 走既有 Kotlin 桥零回归、iOS 走插件双分支）：

| 通道 | iOS 方案 | 关键适配 |
|---|---|---|
| TTS 朗读 | flutter_tts 4.2.5 | 语速刻度折算（Android 1.0 常速 ≈ iOS rate 0.5） |
| 通知 | flutter_local_notifications 18.0.1 | 固定 id 1/2；前台服务通知 iOS 空实现 |
| 亮度 | screen_brightness 2.1.11 | 仅应用窗口亮度可调 |
| 设备号 | device_info_plus 11.5.0 | identifierForVendor，消除 P1 降级项（模拟器实测注入成功） |
| 深链 | app_links 6.4.1 + Info.plist scheme | 初始链路 + 流式监听 |

**验证**：iOS Build / Flutter CI / Integration Smoke 三工作流全绿。

**提交**：`0e00cc5275` + 登记 `419f142d15`。

---

## 九、iOS 轨 P2-B Cookie 捕获与后台听书基础（2026-08-30，版本 2.0.130+132）

**交付内容**：
- 登录 Cookie：iOS WKHTTPCookieStore 不被 webview_flutter 暴露读取——`_syncCookie` 加 iOS 分支经 document.cookie 捕获（局限：httpOnly 读不到，注释注明；Android 通道无此限制）
- 后台听书基础：Info.plist UIBackgroundModes=audio + AppDelegate AVAudioSession .playback/.spokenAudio（不加 mixWithOthers，对齐 Android 音频焦点独占语义）
- **两项对照表条目销记**（既有实现已覆盖，避免无谓依赖）：saf 条件化（调用点本有 isAndroid 守卫）；backstageEval 反爬求值（回退链路本就基于 webview_flutter=WKWebView）

**验证**：三工作流全绿；analyze 0、单测 928 全绿。

**提交**：`281e4c0943` + 登记 `bd966f5eaa`。

---

## 十、iOS 轨 P2-C 锁屏控制/Now Playing（2026-08-31）

**方案**：不引入 audio_service（避免与 Android 既有 MediaSessionBridge 冲突及入口重构），原生 MPNowPlayingInfoCenter + MPRemoteCommandCenter 对齐 MediaSessionBridge.kt 通道协议。

**交付内容**：
- 新增 `NowPlayingBridge.swift`：逐方法对齐通道协议（init/release/requestAudioFocus/abandonAudioFocus/updatePlaybackState/updateMetadata/setPlaying/setWakeLock；下行 onPlay/onPause/onSkipToNext/onSkipToPrevious/onStop/onAudioFocusChange）
- 远程命令接 MPRemoteCommandCenter（播放/暂停/上下曲/停止；拖动进度暂不启用——协议无 seek 方向）
- 系统中断（来电/Siri）经 AVAudioSession interruptionNotification 映射焦点事件
- 通道注册：AppDelegate `didInitializeImplicitFlutterEngine` 经 `pluginRegistry.registrar(forPlugin:).messenger()`（registry 协议无 messenger，API 归属经 3.44.8 引擎头文件 FlutterPlugin.h 核实）
- NowPlayingBridge.swift 手动注册进 Runner.xcodeproj（经典 PBX 组四处）

**过程排障（CI 实测三轮）**：registrar 可空需 if-let；messenger 是零参方法需调用；MPNowPlayingPlaybackStatus 系非公 API 删除（播放状态由 playbackRate 表达）；addObserver 需显式 queue: .main。

**验证**：iOS Build / Flutter CI / Integration Smoke 全绿。

**提交**：`707829d88f` → `1d154c3e90` → `5c20e4d9e6`（登记待补）。

---

## 十一、剩余待办（P3 / 收尾）

- [ ] P2-C 登记落 CHANGELOG/台账/版本递增（本批提交已完成，文档登记为下一提交）
- [ ] 自动任务 iOS 降级策略（workmanager/BGTaskScheduler 受 OS 约束）
- [ ] 逐功能真机走查：朗读出声/通知弹出/深链唤起/退后台续播/锁屏控制（需用户自签安装实测）
- [ ] P3 三端收敛：Windows 基线固化 + macOS/Linux 冒烟 + CI 三产物矩阵
- [ ] S0-C 原版端终态对比三选一决策（debug 原包 / 禁用真实源 / 换环境）
- [ ] GitHub 历史中安卓源码旧快照彻底清除（需 filter-repo，待授权）
- [ ] Dependabot 旧安卓依赖 PR 清理

---

编写者：Qoder + Bridge ｜ 2026-08-31
