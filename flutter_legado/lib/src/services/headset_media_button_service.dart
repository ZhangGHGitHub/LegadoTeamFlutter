import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/pref_keys.dart';
import '../models/book.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/providers.dart';
import 'audio_service.dart';
import 'book_api.dart';
import 'settings_service.dart';

/// 耳机媒体键种类
///
/// 对齐原版 `MediaButtonReceiver.kt:49-67`：上一首/下一首键走段落（或章节）
/// 移动，其余键（播放/暂停/耳机钩子）走「朗读/播放控制」。
enum HeadsetMediaKey {
  /// 播放/暂停/耳机钩子（KEYCODE_MEDIA_PLAY_PAUSE=85、HEADSETHOOK=79 等）
  toggle,

  /// KEYCODE_MEDIA_NEXT=87
  next,

  /// KEYCODE_MEDIA_PREVIOUS=88
  previous;

  /// 原生 keyCode → 媒体键种类（未知键一律按 toggle，对齐原版 `else` 分支）
  static HeadsetMediaKey fromKeyCode(int keyCode) {
    switch (keyCode) {
      case 87:
        return HeadsetMediaKey.next;
      case 88:
        return HeadsetMediaKey.previous;
      default:
        return HeadsetMediaKey.toggle;
    }
  }
}

/// 耳机媒体键决策结果
enum HeadsetMediaAction {
  /// 已有播放会话且正在播放 → 暂停
  pausePlayback,

  /// 已有播放会话且已暂停 → 恢复
  resumePlayback,

  /// 已有播放会话 → 下一段/下一章
  nextItem,

  /// 已有播放会话 → 上一段/上一章
  previousItem,

  /// 有阅读页/听书页活动 → 交给页面处理（避免与页面重复启动）
  dispatchToActivity,

  /// 从最近阅读书启动/恢复朗读
  startReadAloud,

  /// 非播放状态下 `readAloudByMediaButton=false` → 忽略
  ignoreStartDisabled,

  /// 后台且 `mediaButtonOnExit=false` → 忽略
  ignoreExitDisabled,

  /// 非播放状态下的上一首/下一首 → 忽略（不负责启动朗读）
  ignoreNoPlayback,
}

/// 耳机媒体键纯决策函数
///
/// 语义基准（原版 `MediaButtonReceiver.kt:73-118`，参考版同构）：
/// 1. TTS/音频播放服务运行 → 播放/暂停切换；
/// 2. 否则 `isMediaKey && !readAloudByMediaButton` → 忽略；
/// 3. 有 ReadBook/AudioPlay Activity 且应用在前台（路由可见）→ 事件交给活动处理；
/// 4. 否则 `mediaButtonOnExit || activitySize>0 || !isMediaKey`
///    → 从最近阅读书启动/恢复朗读；
/// 5. 其余（后台且 mediaButtonOnExit=false）→ 忽略。
///
/// 上一首/下一首键只在播放会话存在时生效（对齐原版：这两个键不触发
/// 「启动朗读」）。后台即便页面处理器仍挂载也不分派（避免向不可见页面
/// 启动朗读/闪烁 UI）。
HeadsetMediaAction decideHeadsetMediaAction({
  required HeadsetMediaKey key,
  required bool hasPlaybackSession,
  required bool isPlaying,
  required bool isMediaKey,
  required bool readAloudByMediaButton,
  required bool mediaButtonOnExit,
  required bool activityHandlerAttached,
  required bool appForeground,
}) {
  if (hasPlaybackSession) {
    switch (key) {
      case HeadsetMediaKey.next:
        return HeadsetMediaAction.nextItem;
      case HeadsetMediaKey.previous:
        return HeadsetMediaAction.previousItem;
      case HeadsetMediaKey.toggle:
        return isPlaying
            ? HeadsetMediaAction.pausePlayback
            : HeadsetMediaAction.resumePlayback;
    }
  }
  if (key != HeadsetMediaKey.toggle) {
    return HeadsetMediaAction.ignoreNoPlayback;
  }
  if (isMediaKey && !readAloudByMediaButton) {
    return HeadsetMediaAction.ignoreStartDisabled;
  }
  // [批9b-5 回修] 页面处理器只在应用前台（路由可见）时接管；后台挂载的
  // 阅读器/听书页不得被投递事件（否则会向不可见页面启动朗读）
  if (activityHandlerAttached && appForeground) {
    return HeadsetMediaAction.dispatchToActivity;
  }
  if (mediaButtonOnExit || appForeground || !isMediaKey) {
    return HeadsetMediaAction.startReadAloud;
  }
  return HeadsetMediaAction.ignoreExitDisabled;
}

/// 耳机键可驱动的音频控制面（AudioNotifier 适配层，便于单测注入 fake）
abstract class HeadsetMediaAudioController {
  bool get hasActivePlayback;
  bool get isPlaying;
  bool get isStreamMode;

  void pause();
  Future<void> resume();
  Future<void> skipNext();
  Future<void> skipPrevious();
  Future<void> nextParagraph();
  Future<void> prevParagraph();

  Future<void> startReadAloud({
    required String bookUrl,
    required String bookName,
    required int chapterIndex,
    int? startChapterPos,
  });

  Future<void> releaseMediaSession();
}

/// [AudioNotifier] → [HeadsetMediaAudioController] 适配
class AudioNotifierHeadsetController implements HeadsetMediaAudioController {
  AudioNotifierHeadsetController(this._notifier);

  final AudioNotifier _notifier;

  AudioState get _state => _notifier.audioState;

  @override
  bool get hasActivePlayback =>
      _state.bookUrl.isNotEmpty && _state.state != PlayerState.idle;

  @override
  bool get isPlaying => _state.isPlaying;

  @override
  bool get isStreamMode => _state.isStreamMode;

  @override
  void pause() => _notifier.pause();

  @override
  Future<void> resume() => _notifier.resumeOrPlay();

  @override
  Future<void> skipNext() => _notifier.next();

  @override
  Future<void> skipPrevious() => _notifier.previous();

  @override
  Future<void> nextParagraph() => _notifier.nextParagraph();

  @override
  Future<void> prevParagraph() => _notifier.prevParagraph();

  @override
  Future<void> startReadAloud({
    required String bookUrl,
    required String bookName,
    required int chapterIndex,
    int? startChapterPos,
  }) =>
      _notifier.startReadAloud(
        bookUrl: bookUrl,
        bookName: bookName,
        chapterIndex: chapterIndex,
        startChapterPos: startChapterPos,
      );

  @override
  Future<void> releaseMediaSession() => _notifier.releaseMediaSession();
}

/// 耳机媒体键服务（批9b-5）
///
/// 静态接收器 [Kotlin `MediaButtonReceiver`] 经通道
/// `legado/headset_media_button` 把 KeyEvent 送到这里，按
/// [decideHeadsetMediaAction] 决策后驱动 [AudioNotifier]：
/// - 播放会话存在 → 暂停/恢复/切段（与 MediaSession 回调二选一，
///   会话活跃时原生侧不转发，见 `MediaButtonReceiver` 注释）；
/// - 否则按 `readAloudByMediaButton` / `mediaButtonOnExit` / 前后台状态：
///   阅读页挂载 → 页面处理；其他前台页面或允许退出响应 → 从最近阅读书
///   启动朗读；否则忽略。
///
/// 限制：进程被系统杀死后无法拉起 Flutter 引擎（未做 headless engine），
/// 冷启动按键只在系统把广播投递到静态接收器且引擎可建立时生效。
/// 未纳入：视频悬浮窗 `VideoPlayService` 的独立 MediaSession（其媒体键由
/// 视频自身会话处理）、原版 `mediaButtonPerNext` 偏好、iOS/桌面（无静态
/// 媒体键接收器）。会话/静态接收器的 250ms 去抖见 [debounceWindow]。
///
/// — 全栈工程师 ｜ 2026-11-04
class HeadsetMediaButtonService with WidgetsBindingObserver {
  HeadsetMediaButtonService({
    required HeadsetMediaAudioController Function() audio,
    required BookApi bookApi,
    required SettingsService settings,
    bool Function()? isAppForeground,
    Stream<MediaButtonEvent>? mediaButtonStream,
  })  : _audio = audio,
        _bookApi = bookApi,
        _settings = settings,
        _foregroundOverride = isAppForeground,
        _mediaButtonStreamOverride = mediaButtonStream;

  /// 与 Kotlin `HeadsetMediaButtonBridge.CHANNEL` 同名
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'legado/headset_media_button',
  );

  /// 事件去抖窗口（覆盖长按重复/系统与接收器重复投递；测试置零）
  @visibleForTesting
  static Duration debounceWindow = const Duration(milliseconds: 250);

  final HeadsetMediaAudioController Function() _audio;
  final BookApi _bookApi;
  final SettingsService _settings;
  final bool Function()? _foregroundOverride;
  final Stream<MediaButtonEvent>? _mediaButtonStreamOverride;

  StreamSubscription<MediaButtonEvent>? _mediaSessionSub;

  bool _started = false;
  DateTime? _lastHandledAt;
  AppLifecycleState? _lifecycleState;

  /// 前台页面处理器栈（阅读器/听书页可同时挂载）
  ///
  /// 使用栈而不是单槽：听书页压在阅读页之上时两者都存活，返回后应恢复由
  /// 阅读页处理；单槽会在听书页 dispose 后丢失阅读页处理器。
  final List<({Object owner, void Function(HeadsetMediaKey key) handler})>
      _activityHandlers = [];

  /// 是否已挂载前台处理器（诊断/测试）
  bool get hasActivityHandler => _activityHandlers.isNotEmpty;

  /// 启动：注册原生通道、会话媒体键兜底与生命周期观察者
  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler(_onMethodCall);
    // 会话活跃时系统把媒体键交给 MediaSession（AudioNotifier 处理播放/暂停）；
    // 但「会话存在且已停播」时 AudioNotifier 不再盲目重播，由本服务按两偏好
    // 决策（否则会绕过 mediaButtonOnExit/readAloudByMediaButton）。
    _mediaSessionSub =
        (_mediaButtonStreamOverride ?? AudioService.instance.mediaButtonStream)
            .listen(_onMediaSessionButton);
    try {
      // Dart 处理器已注册：请原生侧清空启动窗口积压事件
      await channel.invokeMethod<int>('ready');
    } on MissingPluginException {
      // 非 Android / 测试环境：无原生接收器，静默
    } on PlatformException catch (e) {
      debugPrint('[耳机按键] ready 握手失败（忽略）：$e');
    }
  }

  /// 停止（测试/宿主销毁用）：注销通道与观察者
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
    await _mediaSessionSub?.cancel();
    _mediaSessionSub = null;
    _activityHandlers.clear();
  }

  /// 阅读器/听书页等前台页挂载时登记处理器（后挂载者优先）
  void attachActivityHandler(
    Object owner,
    void Function(HeadsetMediaKey key) handler,
  ) {
    _activityHandlers.removeWhere((entry) => identical(entry.owner, owner));
    _activityHandlers.add((owner: owner, handler: handler));
  }

  /// 页面销毁时注销（owner 校验，避免旧页面误清新页面）
  void detachActivityHandler(Object owner) {
    _activityHandlers.removeWhere((entry) => identical(entry.owner, owner));
  }

  /// 处理一次媒体键（也供 Dart 侧兜底调用/单测）
  Future<void> handleKey(HeadsetMediaKey key) async {
    final now = DateTime.now();
    final last = _lastHandledAt;
    if (last != null && now.difference(last) < debounceWindow) {
      debugPrint('[耳机按键] 去抖窗口内重复事件，忽略（$key）');
      return;
    }
    _lastHandledAt = now;
    try {
      final onExit = await _settings.getBoolPref(
        PrefKeys.mediaButtonOnExit,
        defaultValue: true,
      );
      final readAloudByButton = await _settings.getBoolPref(
        PrefKeys.readAloudByMediaButton,
        defaultValue: false,
      );
      final audio = _audio();
      final action = decideHeadsetMediaAction(
        key: key,
        hasPlaybackSession: audio.hasActivePlayback,
        isPlaying: audio.isPlaying,
        isMediaKey: true,
        readAloudByMediaButton: readAloudByButton,
        mediaButtonOnExit: onExit,
        activityHandlerAttached: hasActivityHandler,
        appForeground: _isAppForeground(),
      );
      await _execute(action, audio, key);
    } catch (e) {
      // 媒体键是用户随手操作：任何失败静默，不影响阅读/播放主流程
      debugPrint('[耳机按键] 处理失败（忽略）：$e');
    }
  }

  Future<void> _execute(
    HeadsetMediaAction action,
    HeadsetMediaAudioController audio,
    HeadsetMediaKey key,
  ) async {
    switch (action) {
      case HeadsetMediaAction.pausePlayback:
        audio.pause();
      case HeadsetMediaAction.resumePlayback:
        await audio.resume();
      case HeadsetMediaAction.nextItem:
        if (audio.isStreamMode) {
          await audio.skipNext();
        } else {
          await audio.nextParagraph();
        }
      case HeadsetMediaAction.previousItem:
        if (audio.isStreamMode) {
          await audio.skipPrevious();
        } else {
          await audio.prevParagraph();
        }
      case HeadsetMediaAction.dispatchToActivity:
        if (_activityHandlers.isNotEmpty) {
          _activityHandlers.last.handler(key);
        }
      case HeadsetMediaAction.startReadAloud:
        await _startFromLastReadBook(audio);
      case HeadsetMediaAction.ignoreStartDisabled:
        debugPrint('[耳机按键] 未开启「耳机按键启动朗读」，且当前无播放，忽略');
      case HeadsetMediaAction.ignoreExitDisabled:
        debugPrint('[耳机按键] 已退出且未开启「全程响应耳机按键」，忽略');
      case HeadsetMediaAction.ignoreNoPlayback:
        debugPrint('[耳机按键] 无播放会话，忽略上一首/下一首键');
    }
  }

  /// 从最近阅读的书启动朗读（对齐原版 `bookDao.lastReadBook`：
  /// `type & text > 0 ORDER BY durChapterTime DESC LIMIT 1`）
  Future<void> _startFromLastReadBook(HeadsetMediaAudioController audio) async {
    final books = await _bookApi.getBooks();
    final candidates = books
        .where((book) =>
            book.bookUrl.isNotEmpty && (book.bookType & BookType.text) != 0)
        .toList()
      ..sort((a, b) => b.durChapterTime.compareTo(a.durChapterTime));
    if (candidates.isEmpty) {
      debugPrint('[耳机按键] 书架无最近阅读的文本，忽略启动朗读');
      return;
    }
    final book = candidates.first;
    debugPrint('[耳机按键] 从最近阅读启动朗读：${book.name}');
    await audio.startReadAloud(
      bookUrl: book.bookUrl,
      bookName: book.name,
      chapterIndex: book.durChapterIndex,
      // [批9b-5 回修] 同章内保留章内位置（对齐原版 ReadBook.loadContent →
      // readAloud 从 durChapterPos 继续，而不是回到章首）
      startChapterPos: book.durChapterPos,
    );
  }

  /// MediaSession 播放键兜底（会话活跃但已停播时）
  ///
  /// AudioNotifier 对「空闲态播放键」不再直接 `play()`（会绕过两个偏好），
  /// 改由本服务按 [decideHeadsetMediaAction] 决策；播放/暂停中的事件仍由
  /// AudioNotifier 的会话订阅处理，这里用 `hasActivePlayback` 跳过，避免双处理。
  Future<void> _onMediaSessionButton(MediaButtonEvent event) async {
    if (event != MediaButtonEvent.play) return;
    try {
      if (_audio().hasActivePlayback) return;
      await handleKey(HeadsetMediaKey.toggle);
    } catch (e) {
      debugPrint('[耳机按键] 会话播放键处理失败（忽略）：$e');
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'onMediaButton') return;
    final args = call.arguments;
    if (args is! Map) return;
    final int keyCode;
    final int action;
    final int repeat;
    switch (args) {
      case {'keyCode': final int k, 'action': final int a, 'repeat': final int r}:
        keyCode = k;
        action = a;
        repeat = r;
      case {'keyCode': final int k, 'action': final int a}:
        keyCode = k;
        action = a;
        repeat = 0;
      default:
        return;
    }
    if (action != 0) return; // KeyEvent.ACTION_DOWN=0（原版只处理按下）
    if (repeat > 0) {
      debugPrint('[耳机按键] 长按重复事件（repeat=$repeat），忽略');
      return;
    }
    await handleKey(HeadsetMediaKey.fromKeyCode(keyCode));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_releaseSessionOnBackgroundIfNeeded());
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// 后台且「全程响应耳机按键」关闭、当前无播放 → 释放会话
  ///
  /// 与 `releaseMediaSession` 的保留语义配套：开关开时会话保留（后台媒体键
  /// 仍可控制朗读）；开关关时退出后台即释放，按键回到静态接收器并按
  /// [HeadsetMediaAction.ignoreExitDisabled] 忽略。
  Future<void> _releaseSessionOnBackgroundIfNeeded() async {
    try {
      final onExit = await _settings.getBoolPref(
        PrefKeys.mediaButtonOnExit,
        defaultValue: true,
      );
      if (onExit) return;
      final audio = _audio();
      if (audio.hasActivePlayback) return;
      await audio.releaseMediaSession();
    } catch (e) {
      debugPrint('[耳机按键] 后台释放媒体会话失败（忽略）：$e');
    }
  }

  bool _isAppForeground() {
    final override = _foregroundOverride;
    if (override != null) return override();
    final state = _lifecycleState ?? WidgetsBinding.instance.lifecycleState;
    return switch (state) {
      null => true,
      AppLifecycleState.resumed => true,
      AppLifecycleState.inactive => true, // 通知栏下拉等仍属 Activity 存活
      AppLifecycleState.hidden => false,
      AppLifecycleState.paused => false,
      AppLifecycleState.detached => false,
    };
  }
}

/// 耳机媒体键服务 Provider（应用启动时 start，阅读器挂载时 attach）
final headsetMediaButtonServiceProvider =
    Provider<HeadsetMediaButtonService>((ref) {
  HeadsetMediaAudioController? controller;
  return HeadsetMediaButtonService(
    audio: () => controller ??= AudioNotifierHeadsetController(
      ref.read(audioNotifierProvider.notifier),
    ),
    bookApi: ref.read(bookApiProvider),
    settings: ref.read(settingsProvider),
  );
});
