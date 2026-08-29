# iOS 轨可行性勘察与实施计划（Flutter + Rust 三端通用）

> 2026-08-30 用户授权：「原生缺口也需要补齐」「重构为 Flutter+Rust 三端通用版本」——iOS 轨正式立项，
> 属超出原版 Android 范围的新平台工程，授权记录于此。
> 勘察基线：commit 9138bb4d47（fork master），Windows 本机 + GitHub Actions。

## 一、勘察结论总表

| 层 | 现状 | 结论 |
|---|---|---|
| Flutter 平台脚手架 | ios/ linux/ macos/ web/ windows/ 全部存在（flutter create 默认模板） | 壳在，未接线 |
| ios/ 工程 | **无 Podfile**（CocoaPods 集成缺失→任何插件在 iOS 无法链接）；AppDelegate/SceneDelegate 模板原样；Info.plist 无 CFBundleURLTypes（深链未配） | 需初始化 |
| Rust FFI | legado-ffi crate-type 已含 `staticlib` ✓（iOS 静态链接必需）；frb_generated.io.dart 存在；Android 走 jniLibs .so + 脚本产物，无 rust_builder/cargokit | iOS 装载路径待接线 |
| JS 引擎 | rquickjs 0.9（cc 编译 QuickJS C 源码，官方支持 iOS 目标）；quickjs 为可选 feature | 可编译，需 iOS 编译参数验证 |
| 音频播放 | StreamAudioPlayer 基于 video_player（AVPlayer） | **天然跨端 ✓ 无需改** |
| 听书 TTS | 双链路：系统 TTS（Android TtsBridge）+ httpTts（Rust 合成音频→video_player 播放） | 后者跨端 ✓；前者 iOS 缺 |
| 原生桥 | android/ 下 10 个 Kotlin 桥（见 §三对照表），Dart 侧 8+ MethodChannel | 全部需 iOS 替代或插件化 |
| Android-only 插件 | `saf`（Storage Access Framework）用于 5+ 页面 | iOS 需条件化（file_picker 兜底） |
| CI | 无任何 iOS 构建；macos runner 未使用 | 需新增 ios-build 工作流 |

**关键约束：本机为 Windows，无 macOS**——iOS 构建/调试全流程只能依赖 GitHub Actions 迭代
（push → macos runner 构建 → 模拟器冒烟截图/artifact 回传），单次迭代 10-15 分钟。

## 二、macOS runner 与打包要求（详解）

**费用**：本仓库为公开仓库（private=false）→ GitHub 托管 runner **全部免费无限**（含 macOS）；
私有仓库 macOS 分钟按 10× 计费。当前无成本顾虑。

**Runner 规格**：`macos-15`（Apple Silicon，预装 Xcode 16.x / CocoaPods / Ruby，内存充足）。
Flutter 3.41.7 需 Xcode 15+，选 macos-14/15 即可；cargokit/Rust 构建时自行安装 rustup。

**未签名 ipa 的标准 CI 流程**（无苹果开发者证书时）：

```yaml
- flutter build ios --release --no-codesign   # 产出 .app（build/ios/iphoneos/）
- mkdir Payload && cp -r build/ios/iphoneos/Runner.app Payload/
- zip -r app-unsigned.ipa Payload             # 手打 ipa（zip 换后缀）
- actions/upload-artifact 上传
```

`flutter build ipa` 不加签名参数会直接失败，故走上面的 `--no-codesign` + 手动打包。

**签名与安装方式矩阵**（决定用户拿到 ipa 后怎么装）：

| 方式 | 成本 | 有效期 | 限制 |
|---|---|---|---|
| 未签名 + AltStore/Sideloadly 自签 | 免费 Apple ID | 7 天 | 3 应用上限，需电脑定期刷新 |
| 未签名 + 爱思助手自签 | 免费 Apple ID | 7 天 | 同上 |
| TrollStore | 免费 | 永久 | 仅特定 iOS 版本（14.0-16.6.1 等） |
| 开发者账号 ad-hoc（$99/年） | $99/年 | 1 年 | 100 台设备/年，需登记 UDID；可配 P12+profile secrets 在 CI 内签名 |
| TestFlight（同 $99 账号） | $99/年 | 每版 90 天 | 内测 100 人/外部 10000 人，苹果审核 |
| 企业 In-House 证书 | $299/年 | 至吊销 | 随时可能被苹果吊销，风险高 |

**建议**：P1 先产出未签名 ipa（您用爱思/AltStore 自签验证功能）；若确认长期用，
再上 $99 开发者账号配 CI secrets 自动签名 + TestFlight 分发。

## 三、原生缺口 → 现成打包方案对照（优先用成熟插件，不重写原生）

| 缺口（Android 现状） | iOS 对应 | 现成方案（pub.dev） | 状态 |
|---|---|---|---|
| 系统朗读 TtsBridge（TextToSpeech） | AVSpeechSynthesizer | **flutter_tts** | 跨端成熟 |
| 后台播放三件套：PlaybackForegroundService + MediaSessionBridge + 通知 | UIBackgroundModes audio + MPNowPlayingInfoCenter + 远程控制 | **audio_service**（ryanheise，事实标准） | 跨端成熟；已知 iOS 后台挂起边界 issue #458，长音频需实测 |
| 后台隐身 WebView JS 求值 WebViewBridge（backstageEval，反爬验证） | HeadlessInAppWebView（WKWebView） | **flutter_inappwebview** | 跨端成熟 |
| 登录 WebView 页 | WKWebView | **webview_flutter**（已在用） | iOS 原生支持 ✓ |
| 登录 Cookie 同步 CookieBridge（系统 CookieManager） | WKHTTPCookieStore | flutter_inappwebview 的 CookieManager | 跨端 |
| 下载/任务通知 NotificationService | UNUserNotificationCenter | **flutter_local_notifications** | 跨端成熟 |
| 设备标识 device_id（ANDROID_ID） | identifierForVendor | **device_info_plus** | 跨端 |
| 亮度 system_brightness | UIScreen.brightness | **screen_brightness** | 跨端 |
| 文件选择 legado/file_picker + saf（SAF 仅 Android） | 沙盒 + UIDocumentPicker | **file_picker**（已在用）；saf 调用点条件化（isAndroid 走原路，iOS 走 file_picker） | 需小改造 |
| 深链 legado:// 导入 OnLineImportActivity | CFBundleURLTypes + SceneDelegate | **app_links**（或手写 plist+通道） | 跨端 |
| 自动任务 AutoTaskJobBridge（WorkManager） | BGTaskScheduler（OS 严格限执行窗口） | **workmanager**（iOS 支持但受限）；iOS 降级策略：前台定时器执行 | 跨端（iOS 降级） |
| 亮度之外的屏幕常亮 | idleTimerDisabled | wakelock_plus | 备选 |

**插件替换原则**：Dart 侧把 8+ 条 MethodChannel 调用收敛进 `platform_bridge_service.dart`
单一抽象层，逐条加平台分支；Android 路径保持现 Kotlin 桥不动（不回归），iOS 走插件。

## 四、Rust 侧 iOS 缺口与接线清单

1. 新增 target：`aarch64-apple-ios`（真机）+ `aarch64-apple-ios-sim`（模拟器）；
   `cargo build -p legado-ffi --features quickjs --target aarch64-apple-ios`（staticlib 已在 crate-type）
2. quickjs（rquickjs-sys）iOS 编译参数验证（min iOS 版本宏、bitcode）
3. 产物形态：`lipo` 合成 xcframework（device+simulator）或仅真机 .a
4. Xcode 接线二选一：**方案 A（推荐）** 引入 rust_builder/cargokit pod（FRB 官方路径，pod install 时 cargo 自动构建）；
   **方案 B** CI 预编 .a + 本地 podspec 引用（贴近现有脚本产物流）
5. FRB 装载：确认 frb_generated.io.dart 的 iOS 分支用 `DynamicLibrary.process()`（静态链接标准姿势）+
   Runner-Bridging-Header 暴露符号
6. DB/目录路径：path_provider iOS 沙盒（Application Support）→ db_open 路径注入已有参数化 ✓

## 五、分阶段实施计划

**P0 准备（半天）**：ios/ 初始化 Podfile（`flutter precache --ios` + pod init 产物经 CI 生成）；
规划 ios-build.yml 骨架；建立「iOS 冒烟 = 模拟器启动到书架 + 截图回传」验收模板。

**P1 FFI 接线 + CI 首包（1-2 天，里程碑：模拟器跑起来）**
- ios-build.yml（macos-15）：rust iOS 双 target 构建 → xcframework → Podfile/工程接线 →
  `flutter build ios --no-codesign` → 未签名 ipa artifact
- FRB iOS 装载 + AppDelegate 初始化 + 首页不崩
- 模拟器冒烟（simctl boot iPhone 15 + 安装 + 启动截图 + 崩溃日志检查）
- **验收门**：模拟器进入书架空态、书源页可开（无 FFI 崩溃日志）、ipa artifact 可下载

**P2 原生功能补齐（2-4 天，里程碑：核心功能 iOS 可用）**
- 按 §三对照表逐条引入插件（每条独立提交，Android 不回归）
- 顺序：TTS（flutter_tts）→ 听书后台（audio_service，含 UIBackgroundModes）→
  WebView 登录/反爬（webview_flutter 已通 + flutter_inappwebview headless）→
  通知/深链/设备号/亮度 → 自动任务 iOS 降级策略
- saf 调用点条件化（5+ 页面）
- **验收门**：iOS 模拟器逐功能清单 + Android 5556 冒烟不回归 + flutter analyze/test 全绿

**P3 三端收敛（2-3 天，里程碑：三端同一套代码可构建）**
- Windows（现有主力）行为基线固化；macos/linux 目录 FFI 接线冒烟（dylib/framework 装载）
- platform_bridge 抽象层文档化；CI 矩阵化（android/ios/windows 三产物）
- **验收门**：三端冒烟清单 + 文档交接

## 六、风险与边界

- 无 macOS 本机：全部 iOS 迭代走 Actions，节奏受 CI 时长限制；模拟器截图是主要回传手段
- audio_service iOS 后台挂起（issue #458）：听书长音频场景需真机实测，备选方案静音保活
- 未签名 ipa 的装机门槛（自签 7 天）；若要正式分发需 $99 开发者账号（用户后续决策）
- iOS 沙盒无 SAF：书源本地导入/下载目录交互需按 iOS 习惯重排（file_picker + Files.app）
- 自动任务在 iOS 后台受 OS 强约束，功能语义降级为「前台定时执行」——与原版 Android 行为有差异，属平台限制
- 历史包袱：纯重构红线已由用户 2026-08-30 指令解锁 iOS 轨；Android 行为基准仍为对齐目标

编写者：Qoder + Bridge ｜ 2026-08-30
