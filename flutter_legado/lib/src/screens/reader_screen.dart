import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/book.dart';
import '../models/book_source.dart';
import '../models/reader_tap_action.dart';
import '../models/source_match.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/bookmark/bookmark_notifier.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../services/headset_media_button_service.dart';
import '../services/platform_bridge_service.dart';
import '../utils/app_route_observer.dart';
import '../utils/book_open_utils.dart';
import '../widgets/reader/read_aloud_bar.dart';
import '../widgets/reader/auto_turn_panel.dart';
import '../widgets/reader/reader_page_chrome.dart';
import '../widgets/reader/reader_image_dominant_body.dart';
import '../widgets/reader/reader_action_helpers.dart';
import '../widgets/reader/reader_page_view.dart';
import '../widgets/reader/reader_settings_sheet.dart';
import '../widgets/reader/reader_status_strip.dart';
import '../widgets/reader/reader_menu_panel.dart';
import '../widgets/reader/review_detail_sheet.dart';
import '../utils/comic_image_utils.dart';
import '../utils/source_login_prompt.dart';
import '../utils/volume_key_page_gate.dart';
import 'reader_config_panel.dart';

/// 阅读器页面（Riverpod ConsumerStatefulWidget 薄壳）
///
/// 状态由 [ReaderNotifier] 管理；分页/翻页渲染由 [ReaderPageView] 承担；
/// 工具栏/目录/设置/状态栏拆分为独立子组件（widgets/reader/）。
/// 本文件仅负责编排：高级配置、自动翻页、点击区域、预加载、书签、正文搜索。
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, this.volumeKeyPageGate});

  /// [批1b-2a] 音量键节流闸门注入点（仅测试：注入假时钟使 600ms 窗口
  /// 断言不依赖真实时间；生产为 null，由 State 内部新建）
  @visibleForTesting
  final VolumeKeyPageGate? volumeKeyPageGate;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver, RouteAware {
  final GlobalKey<ReaderPageViewState> _pageViewKey =
      GlobalKey<ReaderPageViewState>();

  /// 阅读器高级配置（自动翻页/点击区域/段距/状态栏）
  ReaderAdvancedConfig _advConfig = ReaderAdvancedConfig();

  /// [批4d] 已加载书签的书键（bookName + bookAuthor），避免重复查库
  String? _bookmarkBookKey;

  /// [批4a] 点击 DOWN 坐标（九宫格分区用）与长按抑制标记
  ///
  /// 实测外层无竞争长按识别器时，长按释放仍会走 onTapUp；按审查允许的
  /// 兜底方案使用 kLongPressTimeout(500ms) 抑制九宫格分发。
  Offset? _tapDownPosition;
  Timer? _tapHoldTimer;
  bool _tapWasLong = false;

  /// [批1b-2a] 音量键翻页节流闸门（keyPageOnLongPress=false 时长按 repeat
  /// 忽略 + 同方向 600ms leading 节流；对齐原版 ReadBookActivity
  /// handleKeyPage/keyPageDebounce）
  late final VolumeKeyPageGate _volumeKeyPageGate =
      widget.volumeKeyPageGate ?? VolumeKeyPageGate();

  /// [设备验收 P1] Android 原生音量键捕获是否由本页开启。
  ///
  /// 冷启动直达阅读器时 FlutterView 可能未聚焦，HardwareKeyboard 收不到
  /// 音量键 → 改走原生 ReaderKeysBridge（与焦点无关），由 native 消费后
  /// 经 `volumeKey` 事件回传 Dart。桌面/iOS 无该通道，保留
  /// HardwareKeyboard 路径。此标记与原生侧真实开关同步，dispose/切书/
  /// 菜单/子路由按需关闭，避免误拦截系统音量。
  bool _nativeVolumeKeyCaptureActive = false;

  /// [批9b-5] 耳机媒体键服务（阅读器挂载期间登记前台处理器：
  /// 无播放会话时按键按「活动内处理」语义交本页切换朗读）
  HeadsetMediaButtonService? _headsetMediaButtonService;

  /// [设备验收 P1] 是否注册了桌面键盘 handler（Android 不注册，防双触发）
  bool _hardwareKeyboardHandlerRegistered = false;

  /// 自动翻页定时器
  Timer? _autoTimer;

  /// 上一章是否处于加载状态（用于检测章节加载完成以触发预加载）
  bool _wasLoading = false;

  /// 已触发过预加载的章节索引（避免重复预加载）
  int _lastPreloadedIndex = -1;

  /// [UI-fix v2.0.1 | 2026-08-06] 朗读控制条是否被手动收起
  /// （收起后朗读继续，再次点击底栏朗读按钮重新展开） — Qoder
  bool _aloudBarHidden = false;

  /// 段评摘要（P2-9 ruleReview；禁止接本地 CommentService）
  Map<int, int> _reviewCounts = {};
  Map<int, String> _reviewKeys = {};
  String? _reviewSourceJson;
  int _reviewLoadToken = 0;

  // [UI-fix v2.0.3 | 2026-08-08] 自动换源（autoChangeSource）防循环状态 — Qoder

  /// 自动换源进行中（避免并发触发）
  bool _autoSwitching = false;

  /// 当前正在自动换源的书 bookUrl（换书时重置尝试计数）
  String? _autoSwitchBookUrl;

  /// 同一本书连续自动换源尝试次数（上限 3 次，避免无可用源时死循环）
  int _autoSwitchAttempts = 0;

  static const int _autoSwitchMaxAttempts = 3;

  /// F6：跟踪主题日夜，变化时重载布局桶（shareLayout=false）
  bool? _layoutIsNight;

  /// [P2-30] 退出判定进行中标记（防系统返回连点触发多路判定/重复弹窗）
  bool _exitPending = false;

  /// [批31b P1-1] 目录页在栈上（打开目录前置位，didPopNext 消费后复位）。
  ///
  /// 只对「目录返回」重读 DB 书籍快照：目录页会持久化书籍配置
  /// （reverseToc/reverseTocDisplay/useReplaceRule），阅读器持有的旧快照
  /// 必须同步；而其他路由（设置/替换规则等）返回不涉及书籍配置，
  /// 避免每次关闭弹窗都多一次 DB 读。
  bool _tocRouteOpen = false;

  // ===== [批1b-1 审查回修 P1-2] keepLight 屏幕超时定时器 =====

  /// 保持亮屏超时定时器（keepLight>0 档：到点清 flag 恢复系统息屏；
  /// 对齐参考版 ReadBookController screenOffRunnable 到点 keepScreenOn(false)）
  Timer? _keepLightTimer;

  /// 当前生效的保持亮屏秒值（交互重挂判定用；-1=常亮 0=系统策略）
  int _keepLightSeconds = 0;

  /// 保持亮屏是否已置 flag（交互重挂仅在 flag 已置时重置计时）
  bool _keepScreenOnActive = false;

  /// 应用 keep_light 档位（进入/设置变更/交互重挂共用）
  ///
  /// - 0（默认）：清 flag + 取消定时器，交还系统息屏策略；
  /// - -1（常亮）：置 flag + 取消定时器（不自动清）；
  /// - \>0（限时秒）：置 flag + 重置 [Timer]（keepLight 秒后到点清 flag，
  ///   对齐参考版 screenTimeOut 到点语义）。
  void _applyKeepLight(int seconds) {
    _keepLightSeconds = seconds;
    _keepLightTimer?.cancel();
    _keepLightTimer = null;
    if (seconds == 0) {
      if (_keepScreenOnActive) {
        _keepScreenOnActive = false;
        unawaited(PlatformBridgeService.instance.setKeepScreenOn(false));
      }
      return;
    }
    if (!_keepScreenOnActive) {
      _keepScreenOnActive = true;
      unawaited(PlatformBridgeService.instance.setKeepScreenOn(true));
    }
    if (seconds > 0) {
      _keepLightTimer = Timer(Duration(seconds: seconds), () {
        // 到点清 flag（对齐参考版 screenOffRunnable → keepScreenOn(false)）；
        // 下次用户交互（翻页/点击正文）经 _reprioritizeKeepLight 重挂
        _keepScreenOnActive = false;
        unawaited(PlatformBridgeService.instance.setKeepScreenOn(false));
      });
    }
  }

  /// 用户主交互（翻页/点击正文）后重挂保持亮屏：keepLight>0 时重置计时，
  /// -1 时确保 flag 常亮（对齐参考版 onResume/交互后 screenOffTimerStart
  /// 重挂语义；0 档不动作）— 审查回修 P1-2
  void _reprioritizeKeepLight() {
    if (_keepLightSeconds == 0) return;
    _applyKeepLight(_keepLightSeconds);
  }

  /// 退出阅读器：取消定时器 + 清 flag 恢复系统息屏策略（对齐参考版销毁
  /// 路径 restoreActivityWindowState → keepScreenOn(originalKeepScreenOn)）
  void _teardownKeepLight() {
    _keepLightTimer?.cancel();
    _keepLightTimer = null;
    _keepLightSeconds = 0;
    _keepScreenOnActive = false;
    unawaited(PlatformBridgeService.instance.setKeepScreenOn(false));
  }

  @override
  void initState() {
    super.initState();
    // F6：音量键翻页（对标 volumeKeyPage / volumeKeyPageOnPlay）
    // [设备验收 P1] Android 走原生 ReaderKeysBridge 捕获（不依赖
    // FlutterView 焦点）；桌面/iOS 无该通道，保留 HardwareKeyboard。
    // 两条路径互斥，Android 不注册键盘 handler，防原生+Dart 双翻页。
    _hardwareKeyboardHandlerRegistered =
        !PlatformBridgeService.instance.volumeKeyCaptureSupported;
    if (_hardwareKeyboardHandlerRegistered) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
    }
    // [C3-hunt | 2026-09-24] 注册 App 生命周期观察者：切后台/分离时
    // 落盘章内进度（见 didChangeAppLifecycleState）
    WidgetsBinding.instance.addObserver(this);
    // [批1b-1 审查回修 P1-2] 翻页成功 → 保持亮屏计时重挂（集中接线：
    // ReaderPageView 所有翻页成功路径回调至此；dispose 还原默认实现）
    ReaderPageView.onPageTurnInteraction = _reprioritizeKeepLight;
    // [批9b-5] 耳机媒体键：阅读页存在时按原版「活动内处理」语义
    //（MediaButtonReceiver → EventBus → ReadBookActivity.onClickReadAloud），
    // 由本页切换朗读，而不是由服务直接启动另一份朗读
    _headsetMediaButtonService = ref.read(headsetMediaButtonServiceProvider);
    _attachHeadsetHandler();
    // [批4b] 录制态变化 → 重算 page 键捕获（Sheet 打开时路由不 current
    // 也要保持捕获以接收 recordKey）
    PlatformBridgeService.instance.keyRecording.addListener(
      _syncVolumeKeyCapture,
    );
    // [批4d] 首帧后按当前书加载书签（openBook 可能早于本路由挂载）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadBookmarksForCurrentBook();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme.of 不可在 initState 调用；首次与日夜切换时加载高级配置
    final isNight = Theme.of(context).brightness == Brightness.dark;
    if (_layoutIsNight == null || _layoutIsNight != isNight) {
      unawaited(_loadAdvancedConfig());
    }
    _layoutIsNight = isNight;
    // [批31b P1-1] 订阅全局路由观察器：目录页 pop 回阅读器（didPopNext）
    // 时重读 DB 书籍快照。RouteObserver.subscribe 对同一路由幂等，重复
    // didChangeDependencies 不会重复登记。
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
    // [设备验收 P1] 进入阅读器即按门控开启原生捕获（走 didChangeDependencies
    // 而非 initState：ModalRoute 依赖在此可用）；首帧后再同步一次，覆盖
    // 路由 isCurrent 尚未稳定的瞬间。_sync 内部按状态去重，不会重复 enable。
    _syncVolumeKeyCapture();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncVolumeKeyCapture();
    });
  }

  @override
  void dispose() {
    _tapHoldTimer?.cancel();
    PlatformBridgeService.instance.keyRecording.removeListener(
      _syncVolumeKeyCapture,
    );
    if (_hardwareKeyboardHandlerRegistered) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    // [设备验收 P1] 退出阅读器立即交还系统音量（仅在本页确实开启时
    // 关闭，避免误关上层漫画阅读器的捕获）
    _disableNativeVolumeKeyCapture();
    // [批1b-1 审查回修 P1-2] 还原翻页回调默认实现（防泄漏到非阅读页）
    ReaderPageView.onPageTurnInteraction = () {};
    // [C3-hunt | 2026-09-24] 注销生命周期观察者（与 initState 配对）
    WidgetsBinding.instance.removeObserver(this);
    // [批9b-5] 注销耳机媒体键前台处理器（与 initState 配对；owner 校验
    // 防止下一阅读器实例已接管后被旧实例误清）
    _headsetMediaButtonService?.detachActivityHandler(this);
    // [批31b P1-1] 注销路由观察（与 didChangeDependencies 配对，
    // 防销毁后回调泄漏）
    appRouteObserver.unsubscribe(this);
    _autoTimer?.cancel();
    // [批1b-2a] 清空音量键节流状态（无 Timer，重置即无残留；防跨书/重进
    // 阅读器沿用上次翻页时间导致首次按键被误节流）
    _volumeKeyPageGate.reset();
    // [UI-fix v2.0.3 | 2026-08-08] 退出阅读器恢复系统 UI 与方向
    // （hideStatusBar/hideNavigationBar/screenOrientation 仅阅读页内生效，
    // 对标原版 ReadBookActivity 退出时 upSystemUiMode 还原）— Qoder
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    // [批1b-1 审查回修 P1-2] 退出阅读器：取消超时定时器 + 清除保持亮屏
    // flag，恢复系统息屏策略（对齐参考版销毁路径
    // restoreActivityWindowState → keepScreenOn(originalKeepScreenOn)）—
    // 全栈工程师
    _teardownKeepLight();
    // [设置批5a-1] 退出阅读器：keepReadAloudOnExit=false 时停止由阅读器
    // 发起的朗读（听书页/后台会话由 Notifier 内的来源标记排除）。
    // ref 在 super.dispose() 前仍可用；异常吞掉，退出流程不因朗读清理失败中断。
    try {
      unawaited(ref.read(audioNotifierProvider.notifier).onReaderExit());
    } catch (e) {
      // [设备验收 P1] 不再静默：记录原因，但不改变退出流程
      debugPrint('阅读器 dispose 停止朗读失败（忽略）: $e');
    }
    super.dispose();
  }

  // [C3-hunt | 2026-09-24] App 生命周期 → 章内进度落盘
  //
  // 对齐原版 ReadBookActivity.onPause() → ReadBook.saveRead()
  // （切后台即落盘，进程被回收/划掉不丢章内位置）。修复前章内进度
  // （updatePosition）只改内存 state，落库仅在翻章/目录跳章/换源重载/
  // PopScope 返回退出时触发——按 HOME 进后台后 force-stop 重进会回到
  // 上次翻章位置（章首）（C3 缺陷，真机实测：翻到 4/16 页 → HOME →
  // force-stop → 重进回到 1/16，DB durChapterPos 仍 0）。
  //
  // 与既有 PopScope 路径的关系：触发条件不同（系统生命周期 vs 返回退出），
  // 落库操作收敛到同一个幂等的 notifier.saveProgress()（写库失败静默，
  // 重复写同一进度无副作用），两者可共存互不冲突。
  //
  // 不引入「章内翻页节流落库」：原版仅在 换章/后台/退出 时机落盘，
  // 逐页写库属超范围行为变更；C3 缺陷（后台/被杀丢位置）由本钩子完整修复。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // 切后台/窗口分离/进程分离：当前章内位置立即落库
        unawaited(ref.read(readerNotifierProvider.notifier).saveProgress());
      case AppLifecycleState.resumed:
      case AppLifecycleState.hidden:
        break;
    }
  }

  // ===== [设备验收 P1] 路由变化 → 原生音量键捕获同步 =====
  //
  // 子路由（目录/设置/换源等）压栈时阅读器非当前路由，必须交还系统音量；
  // 返回本页后再恢复。didPopNext 延迟到下一帧：上层若为漫画阅读器，
  // 其 dispose 释放租约与本人 didPopNext 的先后顺序不固定，帧末再
  // acquire 可确保最终由本页持有（PlatformBridgeService 租约 API 同时
  // 保证中间态不抖动）。

  @override
  void didPush() {
    _syncVolumeKeyCapture();
  }

  @override
  void didPushNext() {
    _syncVolumeKeyCapture();
    // [批9b-5 回修] 路由被覆盖（目录/设置/听书页等）时注销耳机键处理器：
    // 不可见页面不再接收媒体键；didPopNext 恢复
    _headsetMediaButtonService?.detachActivityHandler(this);
  }

  /// [批31b P1-1] 目录页返回：重读 DB 书籍快照并同步 `currentBook`
  ///
  /// 目录页可直接持久化 `ReadConfig`（目录显示反转/倒序目录/使用替换规则），
  /// 阅读器持有的打开时快照若不刷新，后续整书 `updateBook`（设置保存、
  /// 进度回写、退出落盘等）会用旧快照把已落库配置还原（真机路径：
  /// 目录勾选显示反转 → 返回 → 阅读器保存设置 → 重开目录反转丢失）。
  ///
  /// 进度四列保留阅读器内存值：`currentBook` 的进度由阅读过程实时回写
  /// （见 ReaderNotifier._syncCurrentBookProgress），DB 可能落后于内存
  /// 章内位置，不能让 DB 快照回退。
  @override
  void didPopNext() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncVolumeKeyCapture();
    });
    // [批9b-5 回修] 上层路由退出 → 重新登记耳机键处理器
    _attachHeadsetHandler();
    if (!_tocRouteOpen) return;
    _tocRouteOpen = false;
    unawaited(_refreshCurrentBookFromDb());
  }

  /// [批9b-5] 登记阅读页耳机键处理器（initState/didPopNext 复用）
  void _attachHeadsetHandler() {
    _headsetMediaButtonService?.attachActivityHandler(this, _onHeadsetMediaKey);
  }

  Future<void> _refreshCurrentBookFromDb() async {
    final current = ref.read(readerNotifierProvider).currentBook;
    if (current == null) return;
    try {
      final fresh = await ref.read(bookApiProvider).getBook(current.bookUrl);
      if (!mounted || fresh == null) return;
      final latest = ref.read(readerNotifierProvider).currentBook;
      // 重读期间已换书/退出：丢弃迟到结果
      if (latest == null || latest.bookUrl != fresh.bookUrl) return;
      ref
          .read(readerNotifierProvider.notifier)
          .updateCurrentBook(
            fresh.copyWith(
              durChapterIndex: latest.durChapterIndex,
              durChapterTitle: latest.durChapterTitle,
              durChapterPos: latest.durChapterPos,
              durChapterTime: latest.durChapterTime,
            ),
          );
    } catch (_) {
      // 读取失败保留内存快照（不阻断阅读）
    }
  }

  // ===== [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批系统级生效 =====

  /// 应用隐藏状态栏/导航栏与屏幕方向（对标原版 MoreConfigDialog
  /// onSharedPreferenceChanged：hideStatusBar/hideNavigationBar → UP_CONFIG
  /// 重建沉浸式；screenOrientation → setOrientation）— Qoder
  ///
  /// [menuVisible] 为 true 时强制显示状态栏（对标原版
  /// `upSystemUiVisibility(toolBarHide=false)`，ReadMenu 展开时不隐藏状态栏）。
  void _applySystemChrome(ReaderAdvancedConfig cfg, {bool? menuVisible}) {
    final showMenu =
        menuVisible ?? ref.read(readerNotifierProvider).showControls;
    final overlays = <SystemUiOverlay>[];
    if (!cfg.hideStatusBar || showMenu) overlays.add(SystemUiOverlay.top);
    if (!cfg.hideNavigationBar) overlays.add(SystemUiOverlay.bottom);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: overlays,
    );
    SystemChrome.setPreferredOrientations(
      _orientationsFor(cfg.screenOrientation),
    );
    // [批1b-1] keep_light（保持亮屏）：0=默认（交还系统策略）/ >0=限时
    // 秒数（到点清 flag，交互重挂）/ -1=常亮。经平台通道对 Activity
    // window 增删 FLAG_KEEP_SCREEN_ON（对齐参考版
    // ReadBookController.keepScreenOn，非 PARTIAL_WAKE_LOCK）；iOS/桌面
    // 无基准恒 no-op（PlatformBridgeService 内灰字留痕）— 全栈工程师
    _applyKeepLight(cfg.keepLight);
  }

  /// 原版 screen_direction_value → Flutter DeviceOrientation 映射
  List<DeviceOrientation> _orientationsFor(int orientation) {
    switch (orientation) {
      case 1: // 竖屏
        return const [DeviceOrientation.portraitUp];
      case 2: // 横屏
        return const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      case 3: // 自动(传感器)
        return DeviceOrientation.values.toList();
      case 4: // 反向竖屏
        return const [DeviceOrientation.portraitDown];
      case 5: // 反向横屏
        return const [DeviceOrientation.landscapeRight];
      default: // 跟随系统：空列表解除锁定
        return const [];
    }
  }

  Future<void> _loadAdvancedConfig() async {
    // F6：按当前主题亮度选择日/夜布局桶（shareLayout 时走共用桶）
    final isNight = Theme.of(context).brightness == Brightness.dark;
    _layoutIsNight = isNight;
    final config = await ReaderAdvancedConfig.load(isNight: isNight);
    if (!mounted) return;
    setState(() => _advConfig = config);
    ref.read(readerAdvConfigProvider.notifier).apply(config);
    _syncAutoTimer();
    // [UI-fix v2.0.3 | 2026-08-08] 进入阅读器即应用隐藏栏/方向配置 — Qoder
    _applySystemChrome(config);
    // [设备验收 P1] 配置落定后重算原生捕获（volumeKeyPage /
    // volumeKeyPageOnPlay 可能关闭捕获，交还系统音量）
    _syncVolumeKeyCapture();
  }

  /// [设备验收 P1] 原生音量键捕获通道是否支持（Android 壳；桌面/iOS false）
  bool get _nativeVolumeKeySupported =>
      PlatformBridgeService.instance.volumeKeyCaptureSupported;

  /// 当前上下文是否允许音量键翻页（桌面键盘/旧协议共用）
  ///
  /// - 阅读菜单展开：交还系统；
  /// - 目录/设置等子路由压栈：不生效；
  /// - volumeKeyPage 关闭，或朗读中且 volumeKeyPageOnPlay 关闭。
  bool get _volumeKeyContextAllows {
    if (ref.read(readerNotifierProvider).showControls) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final cfg = ref.read(readerAdvConfigProvider) ?? _advConfig;
    final aloud = ref.read(audioNotifierProvider).isPlaying;
    return cfg.volumeKeyPage && (!aloud || cfg.volumeKeyPageOnPlay);
  }

  /// [批4b] page 键捕获门控：录制态不受菜单/路由限制；否则需菜单收起
  /// 且阅读器为当前路由（自定义/硬编码不依赖 volumeKeyPage）
  bool get _pageKeyContextAllows {
    final bridge = PlatformBridgeService.instance;
    if (bridge.keyRecording.value) return true;
    if (ref.read(readerNotifierProvider).showControls) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return true;
  }

  /// [批4b] 同步 Android 原生 page 键捕获（含音量/自定义/硬编码）
  ///
  /// 自定义键始终可用；音量键由原生按 volumeEnabled 分流（Dart 侧
  /// volumeKeyPage/朗读开关只影响 volume source）。
  void _syncVolumeKeyCapture() {
    if (!mounted) return;
    final bridge = PlatformBridgeService.instance;
    if (!bridge.pageKeyCaptureSupported) return;
    final shouldCapture = _pageKeyContextAllows;
    if (!shouldCapture) {
      if (!_nativeVolumeKeyCaptureActive) return;
      _nativeVolumeKeyCaptureActive = false;
      unawaited(bridge.releasePageKeyCapture(this));
      return;
    }
    _nativeVolumeKeyCaptureActive = true;
    final cfg = ref.read(readerAdvConfigProvider) ?? _advConfig;
    final aloud = ref.read(audioNotifierProvider).isPlaying;
    unawaited(
      bridge.acquirePageKeyCapture(
        this,
        prevKeys: cfg.prevKeyCodes,
        nextKeys: cfg.nextKeyCodes,
        volumeEnabled: cfg.volumeKeyPage && (!aloud || cfg.volumeKeyPageOnPlay),
        hardcodedEnabled: true,
        onEvent: _handleNativePageKey,
      ),
    );
  }

  /// [设备验收 P1 / 批4b] 强制关闭原生 capture（dispose/切书路径）
  void _disableNativeVolumeKeyCapture() {
    if (!_nativeVolumeKeyCaptureActive) return;
    final bridge = PlatformBridgeService.instance;
    if (!bridge.pageKeyCaptureSupported) return;
    _nativeVolumeKeyCaptureActive = false;
    unawaited(bridge.releasePageKeyCapture(this));
  }

  /// [批4b] 原生 pageKey 事件入口
  Future<void> _handleNativePageKey(PageKeyEvent event) async {
    if (!mounted) return;
    if (event.source == 'volume') {
      // 音量 source 维持原 volumeKeyPage/播放中开关语义
      if (!_volumeKeyContextAllows) return;
    } else if (!_pageKeyContextAllows) {
      return;
    }
    final pageView = _pageViewKey.currentState;
    if (pageView == null) return;
    final cfg = ref.read(readerAdvConfigProvider) ?? _advConfig;
    if (!_volumeKeyPageGate.shouldTurnPage(
      direction: event.direction,
      longPress: event.longPress,
      keyPageOnLongPress: cfg.keyPageOnLongPress,
    )) {
      return;
    }
    if (event.direction == 'down') {
      pageView.nextPageOrChapter();
    } else {
      pageView.prevPageOrChapter();
    }
  }

  /// 统一音量键翻页处理（原生事件与桌面 Keyboard 共用）
  ///
  /// [批1b-2a] 对齐原版 ReadBookActivity.volumeKeyPage → handleKeyPage：
  /// - `keyPageOnLongPress=true`：每个 keydown 都翻页（含长按 repeat）；
  /// - false：长按 repeat 忽略；普通按键同方向 600ms 内只翻一次。
  ///
  /// @return 是否应由调用方消费事件（门控未通过或页面视图未就绪时 false）
  bool _handleVolumeKey(String direction, bool longPress) {
    if (!mounted || !_volumeKeyContextAllows) return false;
    final pageView = _pageViewKey.currentState;
    if (pageView == null) return false;
    final cfg = ref.read(readerAdvConfigProvider) ?? _advConfig;
    if (!_volumeKeyPageGate.shouldTurnPage(
      direction: direction,
      longPress: longPress,
      keyPageOnLongPress: cfg.keyPageOnLongPress,
    )) {
      return true; // 语义生效但被节流/忽略：仍消费，避免系统调音量
    }
    if (direction == 'down') {
      pageView.nextPageOrChapter();
    } else {
      pageView.prevPageOrChapter();
    }
    return true;
  }

  /// 桌面/iOS 音量键（HardwareKeyboard 路径）
  ///
  /// Android 走原生捕获，本 handler 不注册；防御性返回 false 防双触发。
  /// 菜单/子路由/配置门控在 [_volumeKeyContextAllows] 统一处理。
  bool _onHardwareKey(KeyEvent event) {
    if (_nativeVolumeKeySupported) return false;
    final isVolUp = event.logicalKey == LogicalKeyboardKey.audioVolumeUp;
    final isVolDown = event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
    if (!isVolUp && !isVolDown) return false;
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return false;
    }
    if (!_volumeKeyContextAllows) return false;

    // 抬起事件：对齐原版 onKeyUp → volumeKeyPage(NONE) 只消费不翻页
    if (event is KeyUpEvent) return true;

    return _handleVolumeKey(isVolDown ? 'down' : 'up', event is KeyRepeatEvent);
  }

  /// 根据配置同步自动翻页定时器
  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    final cfg = _advConfig;
    if (!cfg.autoPageTurn) return;
    final seconds = cfg.autoPageTurnInterval.round().clamp(3, 120);
    _autoTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted) return;
      final pageView = _pageViewKey.currentState;
      if (pageView == null) return;
      if (cfg.autoPageTurnForward) {
        pageView.nextPageOrChapter();
      } else {
        pageView.prevPageOrChapter();
      }
    });
  }

  /// 加载当前章段评摘要（对齐 ReadBookActivity.loadReviewSummaryIfNeeded）
  Future<void> _loadReviewSummary() async {
    final token = ++_reviewLoadToken;
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null || book.origin.isEmpty) {
      if (mounted && token == _reviewLoadToken) {
        setState(() {
          _reviewCounts = {};
          _reviewKeys = {};
          _reviewSourceJson = null;
        });
      }
      return;
    }
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      BookSource? matched;
      for (final s in sources) {
        if (s.bookSourceUrl == book.origin) {
          matched = s;
          break;
        }
      }
      if (matched == null) {
        if (mounted && token == _reviewLoadToken) {
          setState(() {
            _reviewCounts = {};
            _reviewKeys = {};
            _reviewSourceJson = null;
          });
        }
        return;
      }
      final rr = matched.ruleReview;
      final isJs = (matched.mainJs ?? '').trim().isNotEmpty;
      final enabled =
          isJs ||
          (rr != null &&
              rr.enabled &&
              (rr.reviewSummaryUrl ?? '').trim().isNotEmpty);
      if (!enabled) {
        if (mounted && token == _reviewLoadToken) {
          setState(() {
            _reviewCounts = {};
            _reviewKeys = {};
            _reviewSourceJson = null;
          });
        }
        return;
      }
      final chapter = state.currentChapter;
      final request = <String, dynamic>{
        'chapterUrl': chapter?.url ?? '',
        'book': book.toJson(),
        if (chapter != null) 'chapter': chapter.toJson(),
      };
      final sourceJson = jsonEncode(matched.toJson());
      final raw = await api.reviewGetSummary(sourceJson, jsonEncode(request));
      if (!mounted || token != _reviewLoadToken) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final countsRaw = map['counts'] as Map? ?? {};
      final keysRaw = map['keys'] as Map? ?? {};
      final counts = <int, int>{};
      for (final e in countsRaw.entries) {
        final k = int.tryParse(e.key.toString());
        final v = (e.value as num?)?.toInt();
        if (k != null && v != null && v > 0) counts[k] = v;
      }
      final keys = <int, String>{};
      for (final e in keysRaw.entries) {
        final k = int.tryParse(e.key.toString());
        if (k != null) keys[k] = e.value.toString();
      }
      setState(() {
        _reviewCounts = counts;
        _reviewKeys = keys;
        _reviewSourceJson = sourceJson;
      });
    } catch (_) {
      if (mounted && token == _reviewLoadToken) {
        setState(() {
          _reviewCounts = {};
          _reviewKeys = {};
          _reviewSourceJson = null;
        });
      }
    }
  }

  void _onReviewTap(int paragraphIndex, int count) {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    final chapter = state.currentChapter;
    final sourceJson = _reviewSourceJson;
    if (book == null || chapter == null || sourceJson == null) return;
    final paraData = _reviewKeys[paragraphIndex] ?? '$paragraphIndex';
    ReviewDetailSheet.show(
      context,
      api: ref.read(bookApiProvider),
      sourceJson: sourceJson,
      bookUrl: book.bookUrl,
      chapterUrl: chapter.url,
      chapterIndex: state.currentChapterIndex,
      paragraphIndex: paragraphIndex,
      paragraphData: paraData,
      totalCount: count,
      bookJson: book.toJson(),
      chapterJson: chapter.toJson(),
    );
  }

  /// 章节内容加载完成后，后台预加载相邻章节
  void _maybePreloadAdjacentChapters(ReaderState state) {
    if (_wasLoading && !state.isLoading && state.error == null) {
      final index = state.currentChapterIndex;
      if (index != _lastPreloadedIndex) {
        _lastPreloadedIndex = index;
        _preloadAdjacentChapters(state);
        unawaited(_loadReviewSummary());
      }
    }
    _wasLoading = state.isLoading;
  }

  /// 预加载当前章节的前后各 2 章内容，提升翻页阅读体验（静默失败）
  ///
  /// 对齐计划 Phase 2.7：前后各 2 章的 API 调用编排，实现翻页无等待感。
  /// 此处仅决定「何时预载」，文本解析/净化/替换由 Rust 内部完成。
  ///
  /// [F1-hunt F5 | 2026-09-24] getChapterContent → getChapterContentFull
  /// （缓存+网络合并，与阅读器章节加载 / ReaderPageView 相邻章预载同
  /// 链路）：修复前 getChapterContent 仅读本地缓存（Rust 侧未缓存时
  /// 返回 need_fetch 占位，结果被丢弃），在线书从未缓存的章节上预载
  /// 是 no-op，±2 章暖缓存窗口完全失效。保留预载（±2 窗口意图不变），
  /// 改走 Full 路径：缓存命中直接返回、未命中联网抓取并回写缓存，
  /// 无需 Rust 侧改动。
  void _preloadAdjacentChapters(ReaderState state) {
    final book = state.currentBook;
    final chapters = state.chapters;
    if (book == null || chapters.isEmpty) return;

    final api = ref.read(bookApiProvider);
    final index = state.currentChapterIndex;

    // 前后各预加载 2 章（按距离由近及远，越靠近当前章越优先）
    for (var offset = 1; offset <= 2; offset++) {
      final next = index + offset;
      if (next < chapters.length) {
        unawaited(
          api.getChapterContentFull(book.bookUrl, next).catchError((_) => ''),
        );
      }
      final prev = index - offset;
      if (prev >= 0) {
        unawaited(
          api.getChapterContentFull(book.bookUrl, prev).catchError((_) => ''),
        );
      }
    }
  }

  // ===== [P2-30 | 未入架书退出提示] =====
  //
  // 对齐原版 ReadBookActivity.finish() 三路语义（参考版 closeReadBook 同款）：
  // 1. 已入架（DB 记录存在且未打 notShelf 位）→ 直接退出（现状不变）；
  // 2. 未入架 + 「返回时提示放入书架」开关（PrefKeys.showAddToShelfAlert，
  //    既有设置项，默认开）关闭 → 静默退出且清理未入架书的临时落库记录
  //    （对齐原版 !showAddToShelfAlert 分支 removeFromBookshelf，书不残留）；
  // 3. 未入架 + 开关开启 → 弹「放入书架」对话框：
  //    确认 → 清 notShelf 位入架（复用 bookshelf addBook upsert）→ 落库进度 → 退出；
  //    取消/ dismiss → 清理未入架临时记录并退出（书不残留）。
  //
  // 在架判定以 DB 记录的 notShelf 位为准（BookOpenUtils.isInBookshelf）：
  // 路由带入的内存 Book 是瘦壳（openBook 只回写媒体类型位，不带 notShelf 位），
  // 不可作为在架依据——与 book_info_screen 的判定数据源一致。

  /// 通知朗读会话「阅读器即将退出」（设备验收 P1）
  ///
  /// `keepReadAloudOnExit=false`（默认）时停止由阅读器发起的朗读。必须在
  /// 真正 `Navigator.pop` 之前调用：dispose 阶段 ref 可能已失效，不能作为
  /// 唯一时机。onReaderExit 幂等，重复调用安全。
  void _notifyReadAloudExit() {
    try {
      unawaited(ref.read(audioNotifierProvider.notifier).onReaderExit());
    } catch (e) {
      debugPrint('退出阅读器停止朗读失败（忽略）: $e');
    }
  }

  /// 退出判定入口（PopScope 拦截所有 pop 尝试后调用）
  Future<void> _onExitPop(BuildContext context) async {
    // [批1a 审查回修 | 2026-10-31] disableReturnKey 语义对齐原版
    // ReadBookActivity.kt:391-414（onBackPressed）：
    // `if (getPrefBoolean("disableReturnKey") && !menuLayoutIsVisible)
    // return@addCallback` —— **仅「开关开启且菜单未展开」时吞返回**；
    // 菜单展开时不拦截，继续走既有退出判定（保证至少一条可达退出路径，
    // 避免开启后死锁）— 全栈工程师
    final cfg = ref.read(readerAdvConfigProvider) ?? _advConfig;
    if (cfg.disableReturnKey &&
        !ref.read(readerNotifierProvider).showControls) {
      return;
    }
    if (_exitPending) return;
    _exitPending = true;
    try {
      final book = ref.read(readerNotifierProvider).currentBook;
      if (book == null) {
        if (context.mounted) {
          _notifyReadAloudExit();
          Navigator.pop(context);
        }
        return;
      }
      // 在架判定：DB 记录权威（查询失败按未入架处理，对齐原版默认
      // inBookshelf=false 语义；未入架书不会走到删除在架书的分支）
      var inShelf = false;
      try {
        final dbBook = await ref.read(bookApiProvider).getBook(book.bookUrl);
        inShelf = BookOpenUtils.isInBookshelf(dbBook);
      } catch (_) {
        inShelf = false;
      }
      final notifier = ref.read(readerNotifierProvider.notifier);
      if (inShelf) {
        // 已入架 → 直接退出（现状不变：进度落库 + pop）
        await notifier.saveProgress();
        if (context.mounted) {
          _notifyReadAloudExit();
          Navigator.pop(context);
        }
        return;
      }
      // 未入架：读「返回时提示放入书架」开关（既有设置项，默认开启）
      final showAlert = await ref
          .read(settingsProvider)
          .getBoolPref(PrefKeys.showAddToShelfAlert, defaultValue: true);
      if (!context.mounted) return;
      if (!showAlert) {
        // 开关关 → 静默退出且书不残留（对齐原版第二路）
        await _removeNotShelfBook(book);
        if (context.mounted) {
          _notifyReadAloudExit();
          Navigator.pop(context);
        }
        return;
      }
      // 默认路 → 弹「放入书架」提示
      final confirmed = await _showAddToShelfDialog(context, book.name);
      if (!context.mounted) return;
      if (confirmed) {
        // 确认 → 入架（复用 book_info_screen 同款调用：清 notShelf 位 +
        // addBook 原地 upsert，不会级联删章节目录）→ 落库进度 → 退出
        final ok = await ref
            .read(bookshelfNotifierProvider.notifier)
            .addBook(
              book.copyWith(bookType: book.bookType & ~BookType.notShelf),
            );
        if (!context.mounted) return;
        if (!ok) {
          // 入架失败：可见提示且不退出（项目规则：用户可见失败必须提示）
          final err = ref.read(bookshelfNotifierProvider).error;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err != null ? '加入书架失败：$err' : '加入书架失败')),
          );
          return;
        }
        await notifier.saveProgress();
        if (context.mounted) {
          _notifyReadAloudExit();
          Navigator.pop(context);
        }
      } else {
        // 取消 → 退出且未入架书不残留（对齐原版第三路 noButton 分支）
        await _removeNotShelfBook(book);
        if (context.mounted) {
          _notifyReadAloudExit();
          Navigator.pop(context);
        }
      }
    } finally {
      _exitPending = false;
    }
  }

  /// 清理未入架书的临时落库记录（对齐原版 removeFromBookshelf：
  /// 仅删除本次会话以 notShelf 临时入库的书；已入架书不会进入本方法）
  Future<void> _removeNotShelfBook(Book book) async {
    try {
      await ref.read(bookApiProvider).deleteBook(book.bookUrl);
    } catch (_) {
      // 清理失败不阻断退出（极端残留仅影响占位行，不污染书架列表）
    }
  }

  /// 「放入书架」确认对话框（对齐参考版 AppAlertDialog：标题「放入书架」、
  /// 正文「是否将《书名》放入书架？」、取消/确认；圆角按钮走主题
  /// dialogTheme 28dp 大圆角容器 + FilledButton 确认，与既有 Dialog 风格一致）。
  /// 返回 true=确认入架；false=取消/dismiss（含系统返回关闭对话框，
  /// 对齐参考版 onDismiss → ExitWithoutAddingCurrentBookToBookshelf）。
  Future<bool> _showAddToShelfDialog(BuildContext context, String bookName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放入书架'),
        content: Text('是否将《$bookName》放入书架？'),
        actionsAlignment: MainAxisAlignment.end,
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    // 朗读控制条显隐依赖全局朗读状态（朗读进行中时替代底部功能栏）
    final audio = ref.watch(audioNotifierProvider);
    final book = state.currentBook;
    final aloudActive =
        book != null &&
        audio.bookUrl == book.bookUrl &&
        audio.state != PlayerState.idle;

    _maybePreloadAdjacentChapters(state);

    // 必应漫画等：正文仅为 <img> HTML 时勿走文本排版（会刷裸标签）
    final imageDominant =
        book != null &&
        !state.isLoading &&
        state.chapterContent.isNotEmpty &&
        isImageDominantContent(state.chapterContent);

    // [UI-fix v2.0.3 | 2026-08-08] 自动换源监听：章节加载新产生错误时，
    // autoChangeSource 开启且在线书 → 自动搜索替代书源并切换（对标原版
    // ReadBook AutoChangeSource 加载失败自动换源语义的最小路径）— Qoder
    ref.listen(readerNotifierProvider, (prev, next) {
      if (next.error != null && prev?.error == null) {
        unawaited(_maybePromptSourceLogin(next));
        _maybeAutoChangeSource(next);
      }
    });
    // 工具栏显隐时同步系统状态栏（对标原版 ReadMenu 动画回调 upSystemUiVisibility）
    // [设备验收 P1] 菜单展开 → 关闭 Android 原生音量键捕获（交还系统音量）；
    // 收起菜单 → 按门控恢复。桌面路径由 _volumeKeyContextAllows 直接拦截。
    ref.listen(readerNotifierProvider.select((s) => s.showControls), (
      prev,
      next,
    ) {
      if (prev != next) {
        _applySystemChrome(_advConfig, menuVisible: next);
        _syncVolumeKeyCapture();
      }
    });
    // [设备验收 P1] volumeKeyPage / 朗读时翻页开关变化 → 重算原生捕获
    ref.listen(
      readerAdvConfigProvider.select(
        (c) => (
          c?.volumeKeyPage,
          c?.volumeKeyPageOnPlay,
          c?.prevKeyCodes,
          c?.nextKeyCodes,
        ),
      ),
      (prev, next) {
        if (prev != next) _syncVolumeKeyCapture();
      },
    );
    // [设备验收 P1] 朗读开始/停止 → volumeKeyPageOnPlay=false 时交还音量键
    ref.listen(audioNotifierProvider.select((s) => s.isPlaying), (prev, next) {
      if (prev != next) _syncVolumeKeyCapture();
    });
    // [批4d] 首进/同页换书：按书名+作者重载书签快照
    ref.listen(
      readerNotifierProvider.select(
        (s) => s.currentBook == null
            ? null
            : '${s.currentBook!.name}\u0000${s.currentBook!.author}',
      ),
      (prev, next) {
        if (prev != next) _loadBookmarksForCurrentBook();
      },
    );
    // [设备验收 P1] 切书：先关闭捕获，等新书状态落定后按门控恢复
    // （仅同页 openBook 路径；正常换书走新路由由 dispose 关闭）
    ref.listen(readerNotifierProvider.select((s) => s.currentBook?.bookUrl), (
      prev,
      next,
    ) {
      if (prev == next) return;
      if (next == null) {
        _disableNativeVolumeKeyCapture();
        return;
      }
      if (prev != null) {
        _disableNativeVolumeKeyCapture();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncVolumeKeyCapture();
        });
        return;
      }
      _syncVolumeKeyCapture();
    });
    // [批1b-1 审查回修 P2-4] keep_light 值变更即时生效：阅读器内有多条
    // 改值路径（高级面板 onChanged / 界面 Sheet _commitAdv / 独立阅读
    // 设置页），其中 Sheet 与独立页仅推 provider 不回调 State——listen
    // keepLight 统一覆盖（对齐参考版 MoreConfigDialog
    // onSharedPreferenceChanged keepLight → postEvent 即时语义）。
    // _applyKeepLight 内部幂等（值未变时 flag 已置/定时器重置亦无害），
    // _advConfig 字段由 didChangeDependencies/面板回调另行回写。
    ref.listen(readerAdvConfigProvider.select((c) => c?.keepLight), (
      prev,
      next,
    ) {
      if (next != null && prev != next) {
        _applyKeepLight(next);
      }
    });

    return PopScope<Object?>(
      // [P2-30] 退出判定统一收敛到 onPopInvokedWithResult（canPop=false 使
      // 系统返回/手势返回/ Navigator.maybePop —— 阅读顶栏「返回/回书架」
      // 按钮即此路径 —— 全部先过判定函数再 pop，对齐原版 finish() 单一
      // 退出路径）。注意：裸 Navigator.pop()（应用内无此调用点）不受
      // canPop 拦截，直接 didPop=true 走兜底落库分支（保持既有行为：
      // 进度落库 + 退出，不弹窗）。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(notifier.saveProgress());
          // [设备验收 P1] 裸 pop 兜底：同样通知朗读退出（幂等）
          _notifyReadAloudExit();
        } else {
          unawaited(_onExitPop(context));
        }
      },
      child: Scaffold(
        backgroundColor: state.backgroundColor,
        // F6：刘海/挖孔边距（paddingDisplayCutouts / readBodyToLh）
        body: Builder(
          builder: (context) {
            final cfg = ref.watch(readerAdvConfigProvider) ?? _advConfig;
            Widget body = GestureDetector(
              onTapDown: imageDominant
                  ? null
                  : (details) {
                      _tapDownPosition = details.globalPosition;
                      _tapWasLong = false;
                      _tapHoldTimer?.cancel();
                      _tapHoldTimer = Timer(
                        kLongPressTimeout,
                        () => _tapWasLong = true,
                      );
                    },
              onTapCancel: imageDominant
                  ? null
                  : () {
                      _tapHoldTimer?.cancel();
                      _tapDownPosition = null;
                    },
              onTapUp: imageDominant
                  ? null
                  : (details) {
                      _tapHoldTimer?.cancel();
                      _handleTap(context, details);
                    },
              child: Stack(
                children: [
                  if (imageDominant)
                    ReaderImageDominantBody(
                      content: state.chapterContent,
                      book: book,
                      // [批1b-2b] 正文图片点击五档（文本行内图片待渲染；
                      // 图片当前仅在该兜底页出现，档位在此消费）
                      clickImgWay: cfg.clickImgWay,
                      imageStyle: book.readConfig?.imageStyle,
                      onToggleControls: notifier.toggleControls,
                      hasNextChapter: state.hasNextChapter,
                      hasPrevChapter: state.hasPreviousChapter,
                      onNextChapter: notifier.nextChapter,
                      onPrevChapter: notifier.prevChapter,
                    )
                  else
                    ReaderPageView(
                      key: _pageViewKey,
                      // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 用户反馈④：
                      // 阅读页头部补章节链接与书源名（书名在菜单顶栏）— Qoder
                      // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 书源名优先取 Book.originName
                      //（同步可靠），解析结果作兜底 — Qoder
                      // [UI-fix v2.0.4 | 2026-08-08] 共享配置源：面板/界面 Sheet 的
                      // 修改统一推送 readerAdvConfigProvider，watch 触发重建并同步
                      // _advConfig（Stack 子级按序求值，后续 ReaderStatusStrip 等
                      // 消费点拿到最新配置；provider 未加载完成时兜底用自加载值）— Qoder
                      paragraphSpacing:
                          (_advConfig =
                                  ref.watch(readerAdvConfigProvider) ??
                                  _advConfig)
                              .paragraphSpacing,
                      // [UI-fix v2.0.2 | 2026-08-06] 阅读配置面板新增排版参数接入分页渲染 — Qoder
                      letterSpacing: _advConfig.letterSpacing,
                      paragraphIndent: _advConfig.paragraphIndent,
                      textFullJustify: _advConfig.textFullJustify,
                      // [UI-fix v2.0.3 | 2026-08-06] 页面边距接入分页渲染 — Qoder
                      marginTop: _advConfig.pageMarginTop,
                      marginBottom: _advConfig.pageMarginBottom,
                      marginLeft: _advConfig.pageMarginLeft,
                      marginRight: _advConfig.pageMarginRight,
                      pageChrome: ReaderPageChromeConfig.fromAdvanced(
                        _advConfig,
                      ),
                      readBodyToLh: cfg.readBodyToLh,
                      // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批：长按选择
                      // 文本开关与滚动翻页无动画接入内容区 — Qoder
                      selectText: _advConfig.selectText,
                      noAnimScroll: _advConfig.noAnimScrollPage,
                      // [UI-fix v2.0.4 | 2026-08-08] 界面面板字重/自定义文字色与
                      // MoreConfig 第②批鼠标滚轮翻页接入内容区 — Qoder
                      textBold: _advConfig.textBold,
                      // [C3 斜体 | Qoder UI] 斜体透传（参考版行内面板开关）
                      italic: _advConfig.italic,
                      customTextColor: _advConfig.customTextColor,
                      mouseWheelPage: _advConfig.mouseWheelPage,
                      // [UI-fix v2.0.5 | 2026-08-10] 双页模式档位透传（对标原版
                      // doubleHorizontalPage 0-3 档）— Reasonix
                      doubleHorizontalPage: _advConfig.doubleHorizontalPage,
                      // [UI-fix v2.0.5 | 2026-08-10] 中文分行开关透传（对标原版
                      // useZhLayout）— Reasonix
                      useZhLayout: _advConfig.useZhLayout,
                      // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂透传（对标原版
                      // hangingPunctuation）— Reasonix
                      hangingPunctuation: _advConfig.hangingPunctuation,
                      reviewCounts: _reviewCounts,
                      onReviewTap: _onReviewTap,
                    ),
                  if (!state.showControls)
                    ReaderStatusStrip(
                      config: _advConfig,
                      readBodyToLh: cfg.readBodyToLh,
                    ),
                  // [LAYOUT_PLAN P4] 全局页胶囊：showControls 条件挂载保持不变；
                  // 进度指示 220ms 透明度动效缺口：胶囊随菜单同挂载/卸载，进场已由
                  // 顶/底栏 slide+fade 覆盖，独立 fade 待后续统一补（登记缺口，不大改）。
                  // [LAYOUT_PLAN P4] 搜索 pill 缺口：底栏全文搜索为 mini FAB（非 pill
                  // 形态），pill 化待设计收敛，暂不改结构。
                  // 全局页码指示器（跨章节连续分页已注册时显示）
                  if (state.showControls &&
                      state.totalPages > 0 &&
                      !imageDominant)
                    Positioned(
                      bottom: 80,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            // [深色主题 Batch A-3] black54 → onSurfaceVariant：
                            // 亮态 def #53433E（深色胶囊，观感等效旧 black54+白字）；
                            // 暗态 def #D8C4BE（修复旧 black54 在黑底上近不可见），
                            // 深色观感留 Batch B 对照参考阅读器截图复核
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '全局页 ${state.globalPageIndex + 1} / ${state.totalPages}',
                            // [深色主题 Batch A-3] 白字 → surface（亮态 #F5F5F5≈白；
                            // 暗态 #424242 深字，与 onSurfaceVariant 亮底互为对比）
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.surface,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // [C10 对齐 | Qoder UI] 自动翻页运行时浮条：翻页进行中、菜单未展开
                  //（朗读浮条为底部另一占用方，互斥显示）时浮于正文底部，支持速度
                  // 步进与 目录/停止/设置 快捷操作（对齐参考版「即开即调」形态）
                  if (_advConfig.autoPageTurn &&
                      !state.showControls &&
                      !aloudActive)
                    Positioned(
                      bottom: 24,
                      left: 0,
                      right: 0,
                      child: Center(
                        // 浮条自身消费点击：避免点在标签/空白处透传到正文显隐手势
                        child: GestureDetector(
                          onTap: () {},
                          child: AutoTurnPanel(
                            intervalSeconds: _advConfig.autoPageTurnInterval,
                            onIntervalChanged: _setAutoPageInterval,
                            onStop: _toggleAutoPage,
                            onOpenCatalog: () => unawaited(_openToc()),
                            onOpenSettings: () =>
                                ReaderSettingsSheet.show(context),
                          ),
                        ),
                      ),
                    ),
                  // [UI_SYNC_REFACTOR S2-1] 单块底部面板（五分区，替代顶/底栏
                  // 两块分立；朗读态与面板互斥显示——S2-2 将朗读条并入面板路由页）
                  if (aloudActive && !_aloudBarHidden)
                    ReadAloudBar(
                      onDismiss: () => setState(() => _aloudBarHidden = true),
                      onOpenCatalog: () => unawaited(_openToc()),
                      onBackstage: () => Navigator.of(context).maybePop(),
                    )
                  else
                    ReaderMenuPanel(
                      visible: state.showControls,
                      onBack: () => Navigator.of(context).maybePop(),
                      onAddBookmark: () => unawaited(_addBookmark(state)),
                      onOpenCatalog: () => unawaited(_openToc()),
                      onOpenSettings: () => ReaderSettingsSheet.show(context),
                      onOpenAdvancedConfig: () => _openAdvancedConfig(context),
                      onOpenContentSearch: () => _openContentSearch(state),
                      onReadAloud: _onReadAloudTap,
                      onToggleAutoPage: _toggleAutoPage,
                      onOpenReplaceRules: () =>
                          Navigator.pushNamed(context, AppRoutes.replaceRules),
                      brightnessMode: _advConfig.readBrightnessMode,
                      brightnessVwPos: _advConfig.readBrightnessVwPos,
                      progressBehavior: _advConfig.progressBarBehavior,
                      onSeekPage: (page) =>
                          _pageViewKey.currentState?.goToPage(page),
                      // [批3a P1-1] paddingDisplayCutouts 的外层 Padding 已含
                      // 导航栏 inset，面板不再重复叠加
                      parentHandlesBottomInset: cfg.paddingDisplayCutouts,
                      styleFollowPage: _advConfig.readBarStyleFollowPage,
                    ),
                ],
              ),
            );
            // F6：填充刘海 / 扩展到刘海
            if (cfg.paddingDisplayCutouts) {
              final vp = MediaQuery.viewPaddingOf(context);
              body = Padding(
                padding: EdgeInsets.only(
                  top: cfg.readBodyToLh ? 0 : vp.top,
                  left: vp.left,
                  right: vp.right,
                  bottom: vp.bottom,
                ),
                child: body,
              );
            } else if (!cfg.readBodyToLh) {
              body = SafeArea(
                left: true,
                right: true,
                top: true,
                bottom: false,
                child: body,
              );
            }
            return body;
          },
        ),
      ),
    );
  }

  // ===== 交互 =====

  /// 打开独立目录页（对标原版 ll_catalog → TocActivity）
  ///
  /// [UI-fix v2.0.4 | 2026-08-08] 目录入口由侧边抽屉改为独立目录页
  /// TocScreen（/toc 路由，传当前 Book）；页面 pop 返回选中章节原始
  /// index（int）后跳转对应章节 — Qoder
  Future<void> _openToc() async {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    // [批31b P1-1] 标记目录在栈上：didPopNext 时重读 DB 书籍快照
    //（目录页可能已持久化 readConfig，见 _refreshCurrentBookFromDb）
    _tocRouteOpen = true;
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.toc,
      arguments: book,
    );
    if (!mounted) return;
    // 兜底：目录页异常路径未触发 didPopNext 时也不长期持有标记
    _tocRouteOpen = false;
    if (result is int) {
      await ref.read(readerNotifierProvider.notifier).goToChapter(result);
    }
  }

  /// [批9b-5] 耳机媒体键前台事件
  ///
  /// 对齐原版 `ReadBookActivity.observeLiveBus`（EventBus.MEDIA_BUTTON →
  /// onClickReadAloud）：播放会话存在时决策层已直接暂停/恢复，不会走到这里；
  /// 仅在无播放会话时由本页启动/切换朗读。
  void _onHeadsetMediaKey(HeadsetMediaKey key) {
    if (!mounted) return;
    if (key != HeadsetMediaKey.toggle) return;
    _onReadAloudTap();
  }

  /// 底栏朗读按钮点击处理
  ///
  /// [UI-fix v2.0.1 | 2026-08-06] 去除存根 SnackBar，打通朗读链路：
  /// 对标原版 ReadBookActivity.onClickReadAloud —— 朗读进行中再次点击为
  /// 播放/暂停切换并重新展开控制条；未启动时从当前章启动朗读 — Qoder
  void _onReadAloudTap() {
    final state = ref.read(readerNotifierProvider);
    final audio = ref.read(audioNotifierProvider);
    final book = state.currentBook;
    final aloudActive =
        book != null &&
        audio.bookUrl == book.bookUrl &&
        audio.state != PlayerState.idle;

    if (aloudActive) {
      final notifier = ref.read(audioNotifierProvider.notifier);
      if (audio.isPlaying) {
        notifier.pause();
      } else {
        unawaited(notifier.play());
      }
      setState(() => _aloudBarHidden = false);
      return;
    }
    unawaited(_startReadAloud(state));
  }

  /// 底栏自动翻页 FAB（对标原版 fabAutoPage → autoPage）
  void _toggleAutoPage() {
    _advConfig = _advConfig.copy()..autoPageTurn = !_advConfig.autoPageTurn;
    unawaited(_advConfig.save());
    ref.read(readerAdvConfigProvider.notifier).apply(_advConfig.copy());
    _syncAutoTimer();
    if (mounted) setState(() {});
  }

  /// 调整自动翻页间隔（运行时浮条速度步进；范围与定时器 clamp(3,120) 一致）
  void _setAutoPageInterval(double seconds) {
    _advConfig = _advConfig.copy()
      ..autoPageTurnInterval = seconds.clamp(3, 120);
    unawaited(_advConfig.save());
    ref.read(readerAdvConfigProvider.notifier).apply(_advConfig.copy());
    _syncAutoTimer(); // 间隔变更需重建定时器周期
    if (mounted) setState(() {});
  }

  /// 启动当前书的朗读（链路：AudioNotifier.startReadAloud → play → audioSpeak）
  ///
  /// [设置批5a-1] `defaultReadAloudInterface=player` 时启动成功后进入听书
  /// 播放器（对齐参考版「默认朗读界面：播放器」）；经典模式下保持阅读器
  /// 内朗读条，不跳页。
  Future<void> _startReadAloud(ReaderState state) async {
    final book = state.currentBook;
    if (book == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法启动朗读：未打开书籍')));
      return;
    }
    setState(() => _aloudBarHidden = false);
    final notifier = ref.read(audioNotifierProvider.notifier);
    // [设置批5b] 「按页」划分需要当前章分页信息：取分页快照的页首偏移，
    // 并用章号校验避免章节切换窗口把旧章页首带到新章；无分页/章号不一致
    // 时传 null，AudioNotifier 内回退整段。
    final pageView = _pageViewKey.currentState;
    final pageChapterMatches =
        pageView != null &&
        pageView.currentPageChapterIndex == state.currentChapterIndex;
    final pageStarts = pageChapterMatches
        ? pageView.currentChapterPageStarts
        : null;
    // [审查回修 P3] 从当前页起读（0 由 startChapterPos>0 守卫忽略）；
    // 按页模式配合 pageStarts 从当前页单元开始，其它模式定位到所在段落。
    final startChapterPos = pageChapterMatches
        ? pageView.currentPageStartPos
        : null;
    await notifier.startReadAloud(
      bookUrl: book.bookUrl,
      bookName: book.name,
      chapterIndex: state.currentChapterIndex,
      startChapterPos: startChapterPos,
      pageStarts: pageStarts,
      fromReader: true,
    );
    if (!mounted) return;
    // 启动失败（无章节/加载失败）不跳页，避免进入空白播放器
    final audio = ref.read(audioNotifierProvider);
    if (!audio.hasChapters ||
        audio.state == PlayerState.idle ||
        audio.state == PlayerState.error ||
        audio.bookUrl != book.bookUrl) {
      return;
    }
    final interface = await ref
        .read(settingsProvider)
        .getStringPref(
          PrefKeys.defaultReadAloudInterface,
          defaultValue: 'classic',
        );
    if (!mounted || interface != 'player') return;
    await Navigator.pushNamed(context, AppRoutes.audio, arguments: book);
  }

  /// 根据九宫格点击配置执行对应功能（批4a）
  ///
  /// 区域按 DOWN 坐标 x/y 各三等分（行优先 0..8）；保留 pageTouchClick
  /// 左右边缘死区与长按/选区手势（仅在 TapUp 且未升级为长按时进入）。
  void _handleTap(BuildContext context, TapUpDetails details) {
    final down = _tapDownPosition;
    final wasLong = _tapWasLong;
    _tapDownPosition = null;
    _tapWasLong = false;
    if (wasLong) return;
    final position = down ?? details.globalPosition;
    final size = MediaQuery.of(context).size;
    final screenWidth = size.width;
    final tapX = position.dx;
    final notifier = ref.read(readerNotifierProvider.notifier);
    final pageView = _pageViewKey.currentState;
    final menuState = ref.read(readerNotifierProvider);

    // [批4a P2-1] 菜单展开时空白区点击只收起菜单（等价参考
    // ReaderMenuDismissLayer）；面板按钮 InkWell 已先消费，不影响。
    if (menuState.showControls) {
      notifier.hideControls();
      return;
    }

    // [fix Task#41 / Task#45] pageTouchClick 边缘死区（左右边缘 px 内不
    // 落入任何分区）；钳制到半屏以内，中央至少保留 2px 可点击区。
    final deadZone = math.min(
      _advConfig.pageTouchClick.toDouble(),
      screenWidth / 2 - 1,
    );
    if (deadZone > 0 && (tapX < deadZone || tapX > screenWidth - deadZone)) {
      return;
    }

    // [批1b-1 审查回修 P1-2] 主交互（点击正文）重挂保持亮屏计时
    _reprioritizeKeepLight();

    final zoneIndex = ReaderTapAction.zoneIndexAt(
      x: position.dx,
      y: position.dy,
      width: size.width,
      height: size.height,
    );
    if (zoneIndex < 0) return;
    final action = _advConfig.tapActionAt(zoneIndex);

    final readerState = ref.read(readerNotifierProvider);
    final audioNotifier = ref.read(audioNotifierProvider.notifier);
    dispatchReaderTapAction(
      action,
      ReaderTapActionDelegate(
        toggleControls: notifier.toggleControls,
        nextPage: () => pageView?.nextPageOrChapter(),
        previousPage: () => pageView?.prevPageOrChapter(),
        nextChapter: () => unawaited(notifier.nextChapter()),
        previousChapter: () => unawaited(notifier.prevChapter()),
        previousParagraph: () => unawaited(audioNotifier.prevParagraph()),
        nextParagraph: () => unawaited(audioNotifier.nextParagraph()),
        addBookmark: () => unawaited(_addBookmark(readerState)),
        editContent: () => unawaited(showReaderEditContentDialog(context, ref)),
        toggleReplace: () => toggleReaderReplaceRule(context, ref),
        catalog: () => unawaited(_openToc()),
        search: () => _openContentSearch(readerState),
        syncProgress: () => unawaited(syncReaderProgress(context, ref)),
        toggleReadAloud: () {
          final audio = ref.read(audioNotifierProvider);
          toggleReaderReadAloud(
            isPlaying: audio.isPlaying,
            isIdle: audio.state == PlayerState.idle,
            pause: audioNotifier.pause,
            resume: () => unawaited(audioNotifier.resumeOrPlay()),
          );
        },
      ),
    );
  }

  // [UI-fix v2.0.3 | 2026-08-06] 修复点击翻页失效回归 —— Qoder
  // 根因：此前点击翻页经 ReaderNotifier.nextGlobalPage/prevGlobalPage 仅更新
  // 全局页索引状态（globalPageIndex/currentChapterPos），却未驱动 ReaderPageView
  // 内部的 PageController；且「globalPageIndex 未变才回退章级翻页」的判定在同章
  // 翻页时永不成立（同章翻页必然改变 globalPageIndex），导致点击后视觉上不翻页。
  // 现改为在 _handleTap 中直接调用 ReaderPageView.next/prevPageOrChapter()：
  // 既驱动 PageController 完成各模式（仿真/滑动/覆盖/无动画/滚动）视觉翻页与
  // 跨章无缝切换，又经其内部 updatePosition() 同步全局页码指示器。

  /// [批4d] 当前书变化/首次进入 → 按书名+作者加载书签列表。
  ///
  /// 与参考 ReaderBookmarkState 一致，书签快照只服务当前书；书键带作者，
  /// 避免同名书书签混入。
  void _loadBookmarksForCurrentBook() {
    if (!mounted) return;
    final book = ref.read(readerNotifierProvider).currentBook;
    final key = book == null ? null : '${book.name}\u0000${book.author}';
    if (key == _bookmarkBookKey) return;
    _bookmarkBookKey = key;
    if (book == null) return;
    unawaited(
      ref
          .read(bookmarkNotifierProvider.notifier)
          .loadByBook(book.name, book.author),
    );
  }

  /// 添加书签（chapterPos=当前屏页首；摘要取页首可见行正文）
  Future<void> _addBookmark(ReaderState state) async {
    final book = state.currentBook;
    final chapter = state.currentChapter;
    if (book == null || chapter == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法添加书签：未打开书籍')));
      return;
    }
    final content = state.chapterContent;
    final summary = content.length > 100 ? content.substring(0, 100) : content;
    // [批4d] 顶栏书签从章首改为当前屏页首；章号/章名与 pos/text 统一取
    // PageView 页上下文，避免章切换窗口出现「新章号 + 旧页偏移」。
    final pageView = _pageViewKey.currentState;
    final chapterIndex =
        pageView?.currentPageChapterIndex ?? state.currentChapterIndex;
    final chapterName = pageView?.currentPageChapterTitle ?? chapter.title;
    final chapterPos = pageView?.currentPageStartPos ?? 0;
    final pageText = pageView?.currentPageStartText ?? '';
    final bookmarkText = pageText.trim().isEmpty ? summary : pageText;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(bookmarkNotifierProvider.notifier)
          .addBookmark(
            bookName: book.name,
            bookAuthor: book.author,
            chapterIndex: chapterIndex,
            chapterPos: chapterPos,
            chapterName: chapterName,
            bookText: bookmarkText,
          );
      messenger?.showSnackBar(SnackBar(content: Text('已添加书签：$chapterName')));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('添加书签失败：$e')));
    }
  }

  /// 打开正文搜索页面
  void _openContentSearch(ReaderState state) {
    final book = state.currentBook;
    if (book == null) return;
    Navigator.pushNamed(context, AppRoutes.searchContent, arguments: book);
  }

  /// 打开高级设置面板，配置变更后实时应用
  Future<void> _openAdvancedConfig(BuildContext context) async {
    await ReaderConfigPanel.show(
      context,
      config: _advConfig,
      onChanged: (cfg) {
        _advConfig = cfg;
        _syncAutoTimer();
        // [UI-fix v2.0.3 | 2026-08-08] 面板内变更隐藏栏/方向等系统级
        // 配置后立即生效（对标原版 onSharedPreferenceChanged 即时语义）— Qoder
        _applySystemChrome(cfg);
        if (mounted) setState(() {});
      },
    );
  }

  // ===== [UI-fix v2.0.3 | 2026-08-08] 自动换源最小路径 =====
  // 对标原版 ReadBook 内容加载失败后 AutoChangeSource 按书名搜替代源并切换：
  // 复用 searchSource/switchSource FFI（与换源页同源链路）；完整重试策略/
  // 失败源禁用等复杂逻辑留待后续批次 — Qoder

  /// loginCheckJs 判定未登录时自动拉起登录页（§5.14-18）
  Future<void> _maybePromptSourceLogin(ReaderState state) async {
    if (!isSourceLoginRequiredError(state.error)) return;
    final book = state.currentBook;
    if (book == null) return;
    if (BookType.isLocalOrigin(book.origin)) {
      return;
    }
    BookSource? source;
    try {
      final sources = await ref.read(bookApiProvider).getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == book.origin) {
          source = s;
          break;
        }
      }
    } catch (_) {
      return;
    }
    if (!mounted || source == null) return;
    await promptSourceLoginIfNeeded(
      context,
      error: state.error,
      source: source,
    );
  }

  /// 章节加载失败时尝试自动换源（在线书且开关开启时）
  void _maybeAutoChangeSource(ReaderState state) {
    if (!_advConfig.autoChangeSource) return;
    if (_autoSwitching) return;
    final book = state.currentBook;
    if (book == null) return;
    // 本地书/WebDAV 书无书源可换（对标原版仅网络书自动换源）
    if (BookType.isLocalOrigin(book.origin)) {
      return;
    }
    if (_autoSwitchBookUrl != book.bookUrl) {
      _autoSwitchBookUrl = book.bookUrl;
      _autoSwitchAttempts = 0;
    }
    if (_autoSwitchAttempts >= _autoSwitchMaxAttempts) return;
    _autoSwitchAttempts++;
    unawaited(_doAutoChangeSource(book));
  }

  /// 执行自动换源：搜索替代书源 → 取首个非同源候选 → switchSource → 重开书
  Future<void> _doAutoChangeSource(Book book) async {
    _autoSwitching = true;
    try {
      final api = ref.read(bookApiProvider);
      final matches = (await api.searchSource(
        book.name,
        book.author,
      )).map(SourceMatch.fromJson).toList();
      SourceMatch? target;
      for (final m in matches) {
        if (m.sourceUrl.isNotEmpty && m.sourceUrl != book.origin) {
          target = m;
          break;
        }
      }
      if (!mounted) return;
      if (target == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('自动换源：无可用替代书源')));
        return;
      }
      final updatedJson = await api.switchSource(
        book.bookUrl,
        target.sourceUrl,
        target.bookUrl,
      );
      var newBookUrl = target.bookUrl;
      try {
        final decoded = jsonDecode(updatedJson);
        if (decoded is Map<String, dynamic>) {
          final url = decoded['bookUrl'] as String?;
          if (url != null && url.isNotEmpty) newBookUrl = url;
        }
      } catch (_) {
        // 解析失败回退候选项 bookUrl（与换源页同策略）
      }
      if (!mounted) return;
      final updated = book.copyWith(
        bookUrl: newBookUrl,
        origin: target.sourceUrl,
        originName: target.sourceName,
        // [P2-8 审查 P1-1] 自动换源后内存对象须带上新源详情页地址，
        // 否则后续任意一次「保存阅读设置」会用缺该字段的 Book 覆盖 DB 列
        originBookUrl: target.bookUrl,
      );
      final notifier = ref.read(readerNotifierProvider.notifier);
      notifier.updateCurrentBook(updated);
      await notifier.openBook(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('章节加载失败，已自动换源：${target.sourceName}')),
      );
      // 换源成功后重置尝试计数（新书源可再次触发）
      _autoSwitchAttempts = 0;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('自动换源失败: $e')));
      }
    } finally {
      _autoSwitching = false;
    }
  }
}
