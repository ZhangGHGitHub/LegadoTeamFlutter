# V-B3「视频悬浮窗播放」代码审查报告

- 审查对象：`ed2e68957e` feat(ui): 视频悬浮窗播放（21 文件，+2879/-43）
- 审查基线：原版只读语义基线 `app/src/main/java/io/legado/app/service/VideoPlayService.kt`、`ui/video/VideoPlayerActivity.kt`、`res/layout/video_layout_floating.xml`
- 审查方式：只读静态审查 + 门禁复跑（flutter analyze / flutter test 定向 / `:app:testDebugUnitTest` 定向）+ 依赖图核实（gradle cache / pub cache POM）
- 审查者：独立代码审查代理（本机 Windows 宿主，未做 Android 真机/模拟器实机回归）
- 日期：2026-10-05

---

## Summary: pass（可合并；无阻塞项，2 项建议 + 8 项可选/登记）

本批为仓库首个新增 Android 原生活动能力的批次（1025 行 Kotlin 服务 + manifest 权限），按严格口径审查。**未发现确定性 P0（崩溃 / 泄漏 / 资源不释放 / 权限缺失）**：

- FGS 运行时权限 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 已声明（manifest:19，前批已备，本批服务复用），服务声明 `foregroundServiceType="mediaPlayback"`；
- 服务 onDestroy 释放链完整（player / session / receiver / overlay view / 通知 / MPD 临时文件，`VideoPlayService.kt:822-869`）；
- 双播放器竞态存在**短暂重叠窗口**但被音频焦点仲裁 + 页面 pop/dispose 自愈（见 W1，建议加一行确定性 pause）；
- 后台启动 FGS 的 `ForegroundServiceStartNotAllowedException` 已被捕获（`VideoFloatWindowBridge.kt:178-180`），不崩溃，仅提示语义不准（W4）；
- 从 Service `startActivity` 依赖 SAW 豁免（官方后台启动限制豁免清单明确包含 `SYSTEM_ALERT_WINDOW`），且服务只在 `canDrawOverlays()` 通过后运行——自洽；冷启动 / onNewIntent 双路径齐全，MainActivity `singleTop` + `configChanges` 覆盖旋转，无 pendingReturn 重放问题。

---

## Errors (blocking)

无。

---

## Warnings（按严重度）

### W1【建议 P1】移交悬浮窗前未暂停 Flutter 播放器，存在同 URL 双出声窗口

- 位置：`flutter_legado/lib/src/screens/video_screen.dart:726`（`enterWindow` 调用）、`:659-746`（`_handOffToFloatWindow` 全程无 `_controller.pause()` / 提前 dispose）
- 症状：`bridge.show` 成功后原生 ExoPlayer 才开始 prepare（异步，约 100-400ms），而 Flutter 播放器要等 `Navigator.pop()` 退出转场结束、`dispose()`（`video_screen.dart:988-1007`）才停声。两播放器同 URL、同倍速并发，重叠期可闻回声/叠音。缓释因素：双方均启用音频焦点仲裁（原生 `handleAudioFocus = true`，`VideoPlayService.kt:245-253`；Flutter 侧 `mixWithOthers: false`），焦点切换会快速暂停对方，实际重叠通常 < 数百 ms——但这是靠焦点仲裁兜底，非确定性。
- 原版对照：`VideoPlayerActivity.startFloatingWindow`（`VideoPlayerActivity.kt:729-738`）先 `VideoPlay.savePlayState(playerView)` + `finish()`，活动播放器随生命周期立即停声。
- 修法：`_handOffToFloatWindow` 在 `enterWindow` 之前对已初始化控制器执行 `await _controller.pause()`（捕获 `playing` 状态在前，位置读数不受影响），一行消除竞态窗口；回全屏方向（原生 stopSelf → Dart 重建）时序天然安全，无需改。
- 证据等级：代码时序推演（确定性窗口存在），重叠时长未实测（non-claim：未上真机量双声道）。

### W2【建议 P2】桌面端「悬浮窗」按钮未平台门控，失败提示误导

- 位置：`flutter_legado/lib/src/screens/video_screen.dart:1072-1076`（按钮无 `isSupported` 门控）、`:734-739`（失败一律走 `requestOverlayPermission` + 「请允许显示在其他应用上层」SnackBar）；对照 `platform_bridge_service.dart:955-979`（JS 入口已正确做 `!kIsWeb && Platform.isAndroid` 门控并回退全屏）
- 症状：非 Android 平台点按钮 → `bridge.show` 返回 false → 弹出「悬浮窗权限」引导（桌面无此概念），用户得到错误指引。提交说明「非 Android 平台降级全屏播放页」对 JS 入口成立，对页面按钮入口不成立（部分准确）。
- 修法：按钮 `onPressed` 增加 `VideoFloatWindowBridge.instance.isSupported` 判定（桌面直接隐藏或置灰）；或 `_handOffToFloatWindow` 失败分支按 `isSupported` 区分提示。
- 证据等级：确定性（代码路径必然）。

### W3【建议 P2】`_advance` 与原生 10s completion-exit 竞态，可产生「无会话上下文」的孤儿续播

- 位置：`flutter_legado/lib/src/services/video_float_window.dart:435`（入口 `_active` 判定）、`:448-470`（fetch 章节正文为网络 await，可达数秒）、`:486`（`bridge.show` 前未复核 `_active`）
- 症状：播完 → 原生 `onCompleted` → Dart 解析下一集耗时超过 `COMPLETION_EXIT_DELAY_MS = 10_000L`（`VideoPlayService.kt:119`）→ 原生 `stopAndNotify` 发 `onClosed` → 协调器 `_clearCapture()`（`_active = false`）→ 随后 `_advance` 的 `show()` 成功 → 悬浮窗恢复播放，但捕获上下文已清空：后续连播/进度落库全部失效（`_advance` 首行 `if (!_active) return`）。
- 修法：`await` 解析完成后、`bridge.show` 之前补一次 `if (!_active) return`（连同 fallback 落库走 `_finish`）。
- 证据等级：确定性竞态（触发条件为解析 >10s，低频）。

### W4【建议 P2】FGS 后台启动失败被一律按「无悬浮窗权限」引导

- 位置：`flutter_legado/android/app/src/main/kotlin/io/legado/flutter/VideoFloatWindowBridge.kt:176-180`（catch 后返回 false，未区分异常类型）；调用点 `video_screen.dart:734-739`、`platform_bridge_service.dart:977-979` 均按权限引导收尾
- 症状：Android 12+ 应用退后台后（书源 JS `openVideoPlayer(isFloat=true)` 异步触发、或页面延迟移交）`startForegroundService` 抛 `ForegroundServiceStartNotAllowedException` → 被捕获不崩溃（正确），但用户被引导去开「显示在其他应用上层」——已授权时提示无效且误导。
- 修法：catch 分支按 `IllegalStateException`/消息含 `ForegroundServiceStartNotAllowed` 区分，回报 `onError: "background_start_rejected"`，Dart 提示「请回到应用后重试」。
- 证据等级：确定性（异常路径必然被 catch 吞并误报），未实测后台触发频率。

### W5【可选 P2】`takeOver() ?? probe` 回退可拾取「已被删除的 MPD 临时文件」

- 位置：`flutter_legado/lib/src/services/video_float_window.dart:356`
- 症状：`getState` 与 `takeOver` 之间服务恰好自行停止（onClosed/10s exit）→ `takeOver` 返回 null → 回退用 `probe`（含 `mpdTempPath`）→ 但该文件已随服务 `onDestroy` 按 `deleteMpdOnDestroy=true` 删除（`VideoPlayService.kt:822-849`）→ 页面以 `file://` 起播必然报错。窗口极窄（毫秒级），低频。
- 修法：takeOver 为 null 时直接丢弃 probe（返回 null 走常规解析），或对 `mpdTempPath` 存在性做 `File.exists()` 校验。
- 证据等级：推演竞态，未复现。

### W6【可选 P2】连播解析后 `show` 失败时孤儿 MPD 临时文件

- 位置：`flutter_legado/lib/src/services/video_float_window.dart:468`（`_materializeTarget` 落盘）→ `:486`（`show` 失败）→ `_finish`（`:522-526`）未删除刚落盘文件
- 症状：无权限/服务启动失败时，`legado_video_float_<ts>.mpd` 滞留应用缓存目录（原生从未接手，`onDestroy` 也不会删）。单文件量级、缓存目录、系统可回收——影响小。
- 修法：`show` 失败分支删除 `materialized.mpdPath`。
- 证据等级：确定性，影响微小。

### W7【可选 P2】`build.gradle.kts` 注释版本来源描述失实

- 位置：`flutter_legado/android/app/build.gradle.kts:63-66`
- 症状：注释称「video_player_android 2.9.5 声明 1.8.0，本工程已解析至 1.9.2」；实际 `video_player_android-2.9.5/android/build.gradle.kts:59-64` 直接声明 `exoplayerVersion = "1.9.2"`（含 dash/hls/rtsp/smoothstreaming 全模块）。依赖结论正确（1.9.2 与解析图一致、DASH 模块在 classpath），仅注释依据写错。
- 修法：注释改为「与 video_player_android 2.9.5 声明的 1.9.2 完全一致」。

### W8【可选 P2】无权限时先 startForeground 再检查 canDrawOverlays，通知闪现

- 位置：`flutter_legado/android/app/src/main/kotlin/io/legado/flutter/VideoPlayService.kt:172-177`（`startForegroundCompat` 在 `when` 之前）vs `:204-212`（权限检查在 ACTION_START 分支内）
- 症状：未授权时 JS 入口绕过 Bridge 检查（理论路径）触发服务 → 先置前台并建通知，随后 `stopSelf` 取消——通知/前台短暂闪现。正常入口在 Bridge `show()` 已前置权限检查，实际难触发。原版在 startForeground 前完成权限检查（VideoPlayService.kt:205-215）。
- 修法：把 `canDrawOverlays` 检查提到 `startForegroundCompat` 之前。

### W9【可选 P2】悬浮窗播放钮位置与原版布局不符

- 位置：`VideoPlayService.kt:400-410`（`Gravity.CENTER` 居中）vs 原版 `video_layout_floating.xml`（ENPlayView `alignParentBottom + centerHorizontal + marginBottom 20dp`，底部中央）
- 症状：播放/暂停钮悬浮窗正中，遮挡画面中心；原版在底部中央。四件套（关闭/全屏/播放/底部进度条）齐备，此为形态偏差。
- 修法：`FrameLayout.LayoutParams(dp(44), dp(44), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)` + bottom margin。

### W10【可选 P2】冷启动回全屏时书籍模式上下文丢失（登记差异相邻项）

- 位置：`flutter_legado/lib/src/services/video_float_window.dart:330-336`（`handleReturnState`，`_api/_book` 为空时跳过落库）、`lib/app.dart:196-215`（`book: null` 组装 VideoScreenArgs）
- 症状：悬浮窗播放中任务被划掉 → 进程重启 → 点「全屏」→ 直链模式正常续播；书籍模式退化为单 URL 续播（无章节列表/上下集/落库）。与提交已登记差异（「Dart 引擎不可用时原生仅继续/停止、不连播不落库」）同根，建议在登记差异条目中补一句「冷启动回全屏同样丢失章节上下文」，避免后续批次误判回归。
- 证据等级：确定性，属已登记差异的边界延伸。

---

## 实际核实清单（通过项，附证据）

| # | 审查项 | 结论 | 证据 |
|---|--------|------|------|
| 1 | FGS 运行时权限（P0-4） | 通过 | `AndroidManifest.xml:19` `FOREGROUND_SERVICE_MEDIA_PLAYBACK`（前批已声明，本批服务复用，`git show ed2e68957e^` 核实）；`:183-189` 服务 `foregroundServiceType="mediaPlayback"`；`VideoPlayService.kt:763-775` API 34+ 显式传 type |
| 2 | 资源生命周期（P0-1） | 通过 | `VideoPlayService.kt:822-869`：player.release / noisyReceiver 注销 / mediaSession.release / removeView / 通知 cancel / MPD 删除逐项有且带防御；`START_NOT_STICKY` 不重建无泄漏；连进连出每次走完整 onCreate/onDestroy；`onTaskRemoved` 未覆写与原版一致（原版亦无，悬浮窗存续即预期）；`progressRunnable` 由 `removeCallbacksAndMessages(null)` 兜底 |
| 3 | 双播放器竞态（P0-2） | 有窗口但自愈（W1） | 接管方向：`stateMapAndStop()`（`:336-341`）先停服再回传，Flutter 后建；回全屏方向：`returnToFullscreen()`（`:319-330`）`startActivity` 后立即 `stopSelf`；仅移交方向存在重叠窗口，焦点仲裁（原生 `handleAudioFocus=true`，Flutter `mixWithOthers:false`）兜底 |
| 4 | 状态克隆一致性（P0-3） | 通过 | 复合 URL/MPD 在 Dart 侧经 `resolveVideoPlayTarget` 解析为最终 URL + headers 再移交（`video_screen.dart:659-746`、`platform_bridge_service.dart:958-966`）；原生 `DefaultHttpDataSource` 直用 headers；类型往返保真（speed Double / positionMs Long / headers Map，`VideoFloatState.fromMap` 脏值降级）；MPD：`media3-exoplayer-dash 1.9.2` 在依赖图（`video_player_android-2.9.5/android/build.gradle.kts:59-64` 直接声明全模块，gradle cache 有 1.9.2 AAR）→ `DefaultMediaSourceFactory` 按 .mpd 解析为 DashMediaSource；`mpdTempPath` + `deleteMpdOnDestroy` 所有权在 start/replace/takeOver/return 四路径均一致 |
| 5 | 后台启动 FGS（P0-4） | 不崩溃（W4） | `VideoFloatWindowBridge.kt:178-180` catch 全部异常回报 onError；正常入口（页面按钮/默认悬浮窗）均在 Activity 前台时触发 |
| 6 | SAW 运行时流（P0-5） | 通过 | 前置检查 `canDrawOverlays`（Bridge `:139-142`，服务 `:352-353` 双保险）→ `requestOverlayPermission` 带 package URI + 通用页兜底（`:150-166`）→ 两个入口失败均引导并停留不静默降级（`video_screen.dart:734-739`、`platform_bridge_service.dart:977-979`） |
| 7 | Service startActivity（P0-6） | 通过（依赖 SAW 豁免） | 官方后台 Activity 启动限制豁免清单明确含「已授予 SYSTEM_ALERT_WINDOW 的应用」；服务只在授权后运行，自洽；`singleTop + CLEAR_TOP|SINGLE_TOP|NEW_TASK`（`VideoPlayService.kt:321-330`）+ onNewIntent/冷启动双路径（`VideoFloatWindowBridge.kt:92-110`）；真机/MuMu 表现列入回归清单 |
| 8 | 悬浮窗四件套与拖动贴边（P1-7） | 通过（形态微差 W9） | 关闭（左上）/全屏（右上）/播放钮/2dp 底部进度条齐备；拖动 20px 阈值、松手贴边 200ms 动画、上下留白 30/60（`:462-617`、纯函数 `:1006-1040`），与原版 :497-541/:134-171 数值对齐 |
| 9 | 双服务通知并存（P1-8） | 通过 | 通知 id 0x1E61 vs 音频 0x1E60（`PlaybackForegroundService.kt:34`）、channel `legado_video_float` vs `legado_playback_foreground`（`:33`）互不冲突；mediaPlayback 类型允许多实例，对齐原版 AudioPlayService/VideoPlayService 双服务形态 |
| 10 | 弹幕不进悬浮窗（P1-9） | 通过 | 原版 `video_layout_floating.xml` 全文 67 行，无弹幕视图（grep danmaku 无结果）；登记差异准确 |
| 11 | 桌面降级（P1-10） | 部分成立（W2） | JS 入口正确降级；页面按钮入口未门控 |
| 12 | defaultFloatWindow 接管后再转悬浮 | 通过（对齐原版） | 原版 `VideoPlayerActivity.kt:176-193`：`isNew=true` 且无 action 时一律转发（含接管场景）；本侧 `_maybeAutoEnterFloat`（`video_screen.dart:645-658`）同语义，且 MPD 文件所有权在 stop→restart 链中不丢（takeOver 置 `deleteMpdOnDestroy=false`） |
| 13 | Bridge 风格 / manifest 最小性（P2-11/13） | 通过 | 通道命名 `legado/video_float`、单例 + `dispose` 判等防新例误清（`VideoFloatWindowBridge.kt:63-84`），与既有 Bridge 风格一致；manifest 仅 +13 行（1 权限 + 1 服务）；media3 依赖单行置于既有 androidx.media 旁 |
| 14 | 结构与可测性（P2-11） | 通过 | 5 个纯函数（窗口宽高/贴边 X/Y/通知文案）+ 状态类落文件底部，JVM 单测 10 例 |

## 门禁复跑（真实运行证明）

- `flutter analyze`（6 个改动文件）：No issues found（本机复跑）。
- `flutter test test/unit/video_float_window_test.dart test/widget/video_float_window_button_test.dart`：14/14 通过（本机复跑）。
- `./gradlew :app:testDebugUnitTest --tests io.legado.flutter.VideoPlayServiceLogicTest`：BUILD SUCCESSFUL，XML `tests="10" failures="0" errors="0"`（本机复跑，非仅采信提交说明）。
- 依赖核实：`~/.gradle/caches/modules-2/files-2.1/androidx.media3/` 存在 `media3-exoplayer-dash/1.9.2` AAR；pub cache `video_player_android-2.9.5/android/build.gradle.kts:59-64`。

## Non-claims（未声明项 / limitations）

- 未在 Android 真机/模拟器实跑悬浮窗（Windows 宿主静态审查 + JVM/Dart 测试）；overlay 实际渲染、拖动贴边手感、MediaStyle 通知动作、SAW 授权流程均为静态结论。
- 双播放器重叠的**实际可闻时长**未实测（W1 为时序推演）。
- MuMu/国产 ROM 对 SAW 豁免后台 startActivity、FGS 后台启动的厂商裁剪行为未验证。
- 未验证 4K/超长视频下 overlay resize 性能与 `FLAG_LAYOUT_NO_LIMITS` 在异形屏的表现。

## 真机回归清单（建议合并后补跑）

1. 悬浮窗空白区域拖动 + 松手贴边 + 单击显隐控制条（root `onTouch` 返回 false 的窗口级事件重派路径）。
2. 播放中移交：注意移交瞬间有无双声道叠音（W1 修复前后对比）。
3. 悬浮窗播完自动连播（onCompleted → ACTION_REPLACE）>10s 慢源场景（W3）。
4. 退后台后书源 JS `openVideoPlayer(isFloat=true)`（W4 行为确认）。
5. 划掉任务后：通知「全屏」拉起冷启动续播（直链 + 书籍两种模式）；关闭悬浮窗后进度落库。
6. 听书服务与悬浮窗同时前台：双通知并存、媒体键路由。
7. 无权限首次点击：引导设置页 → 授权 → 返回重试成功。

## 总体结论

**可合并**。无阻塞缺陷；建议合并前或紧随其后修 W1（一行确定性 pause）与 W2（按钮平台门控），W3-W7 可随下批处理。处置：报告归档 `docs/`（leave_native）；W1-W4 建议转为下批检查项（convert_to_check）。
