/*
 * [V-B3] 视频悬浮窗（Android 全局 overlay，非 PiP）Flutter 侧桥与状态机
 *
 * ## 技术方案结论（Dart ↔ 原生分工）
 *
 * 原版悬浮窗 = TYPE_APPLICATION_OVERLAY 窗口内完整原生播放器
 * （`VideoPlayService.kt` + `FloatingPlayer.kt`，显示真实画面 + 关闭/全屏/
 * 播放/底部进度条），播放器移交是「状态克隆」而非实例共享
 * （`VideoPlay.savePlayState/clonePlayState`，VideoPlay.kt:386-398）。
 *
 * Flutter `video_player` 的渲染纹理归 Flutter 引擎渲染面，**无法**进入独立
 * WindowManager 窗口（插件不暴露底层 ExoPlayer 实例），故：
 * - 播放：原生服务内自建 Media3 ExoPlayer + SurfaceView（见 VideoPlayService.kt）；
 * - 移交：Dart 保存 url/header/位置/倍速/播放态 → 原生新建播放器续播；
 *   返回全屏时原生把位置经 Intent 交回 Dart，重建 Flutter 播放器；
 * - 章节上下文（解析下一集、进度落库、弹幕）留在 Dart：原生只发
 *   onCompleted/onSkipNext/onSkipPrevious 事件，Dart 解析新 URL 后
 *   ACTION_REPLACE 续播（对齐原版 `VideoPlay.upDurIndex` 的自动连播语义）。
 *
 * ## 本批登记差异
 * - 悬浮窗内无弹幕：原版 `video_layout_floating.xml` 亦无弹幕层 → 不做；
 * - Dart 引擎不可用（用户划掉任务）时原生仅继续/停止播放，不自动连播、
 *   进度不落库（原版逻辑全在原生层可继续；登记差异）。
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../utils/video_play_utils.dart';
import '../utils/video_progress.dart';
import 'book_api.dart';

/// 悬浮窗播放状态（Dart → 原生；原生 → Dart 回全屏/接管共用）
@immutable
class VideoFloatWindowState {
  const VideoFloatWindowState({
    required this.url,
    this.title = '',
    this.bookName = '',
    this.headers = const {},
    this.positionMs = 0,
    this.playing = true,
    this.speed = 1.0,
    this.bookUrl,
    this.chapterIndex = -1,
    this.chapterTitle,
    this.directUrl,
    this.hasPrev = false,
    this.hasNext = false,
    this.mpdTempPath,
  });

  /// 实际播放地址（http(s) 或 MPD 临时文件 file:// URI）
  final String url;

  /// 当前集标题（通知/元数据）
  final String title;

  /// 书籍名（通知元数据 artist）
  final String bookName;

  /// 播放 header（对齐 AnalyzeUrl.headerMap）
  final Map<String, String> headers;

  final int positionMs;
  final bool playing;
  final double speed;

  /// 书籍模式上下文（null = 直链模式）
  final String? bookUrl;
  final int chapterIndex;
  final String? chapterTitle;

  /// 直链模式进度键（原版 `video_pos_<url>`）
  final String? directUrl;

  final bool hasPrev;
  final bool hasNext;

  /// MPD 临时清单文件路径（服务关闭时删除；交回 Dart 时移交所有权）
  final String? mpdTempPath;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'url': url,
        'title': title,
        'bookName': bookName,
        'headers': headers,
        'positionMs': positionMs,
        'playing': playing,
        'speed': speed,
        'bookUrl': bookUrl,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'directUrl': directUrl,
        'hasPrev': hasPrev,
        'hasNext': hasNext,
        'mpdTempPath': mpdTempPath,
      };

  static VideoFloatWindowState? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    final headers = <String, String>{};
    final rawHeaders = raw['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null) headers['$k'] = '$v';
      });
    }
    return VideoFloatWindowState(
      url: url,
      title: raw['title']?.toString() ?? '',
      bookName: raw['bookName']?.toString() ?? '',
      headers: headers,
      positionMs: _asInt(raw['positionMs']),
      playing: raw['playing'] is bool ? raw['playing'] as bool : true,
      speed: _asDouble(raw['speed'], 1.0),
      bookUrl: raw['bookUrl']?.toString(),
      chapterIndex: _asInt(raw['chapterIndex'], -1),
      chapterTitle: raw['chapterTitle']?.toString(),
      directUrl: raw['directUrl']?.toString(),
      hasPrev: raw['hasPrev'] == true,
      hasNext: raw['hasNext'] == true,
      mpdTempPath: raw['mpdTempPath']?.toString(),
    );
  }

  VideoFloatWindowState copyWith({
    String? url,
    String? title,
    String? bookName,
    Map<String, String>? headers,
    int? positionMs,
    bool? playing,
    double? speed,
    String? bookUrl,
    int? chapterIndex,
    String? chapterTitle,
    String? directUrl,
    bool? hasPrev,
    bool? hasNext,
    String? mpdTempPath,
  }) =>
      VideoFloatWindowState(
        url: url ?? this.url,
        title: title ?? this.title,
        bookName: bookName ?? this.bookName,
        headers: headers ?? this.headers,
        positionMs: positionMs ?? this.positionMs,
        playing: playing ?? this.playing,
        speed: speed ?? this.speed,
        bookUrl: bookUrl ?? this.bookUrl,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        chapterTitle: chapterTitle ?? this.chapterTitle,
        directUrl: directUrl ?? this.directUrl,
        hasPrev: hasPrev ?? this.hasPrev,
        hasNext: hasNext ?? this.hasNext,
        mpdTempPath: mpdTempPath ?? this.mpdTempPath,
      );

  /// 悬浮窗当前内容是否与将要打开的播放页同源。
  ///
  /// 原版语义：进入 VideoPlayerActivity 一律 stop 悬浮窗服务，但静态
  /// VideoPlay 状态（同一进程）决定新页面内容——同源则续播、异源则换内容。
  /// 本侧以 bookUrl（书籍模式）/ directUrl|url（直链模式）判定同源。
  bool isSameContent({String? bookUrl, String? videoUrl}) {
    if (bookUrl != null && this.bookUrl != null) return bookUrl == this.bookUrl;
    if (bookUrl == null && videoUrl != null) {
      return directUrl == videoUrl || url == videoUrl;
    }
    return false;
  }
}

int _asInt(Object? raw, [int fallback = 0]) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw') ?? fallback;
}

double _asDouble(Object? raw, [double fallback = 0]) {
  if (raw is double) return raw;
  if (raw is num) return raw.toDouble();
  return double.tryParse('$raw') ?? fallback;
}

/// Flutter → Android 悬浮窗通道（`legado/video_float`，与 VideoFloatWindowBridge.kt 对应）
class VideoFloatWindowBridge {
  VideoFloatWindowBridge();

  /// 全局单例（测试可替换为 Fake）
  static VideoFloatWindowBridge instance = VideoFloatWindowBridge();

  static const MethodChannel channel = MethodChannel('legado/video_float');

  /// 平台门控覆写（widget/单元测试在 Windows 宿主强制 Android 分支）
  bool? supportedOverride;

  bool get isSupported => supportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// 最近一次 [show] 失败的原始错误码（供调用方分流提示；成功/未调用为 null）
  ///
  /// 与 `VideoFloatWindowBridge.kt` 的 `show` 返回约定对齐：
  /// - `no_overlay_permission`：无 SYSTEM_ALERT_WINDOW 权限；
  /// - `background_start_rejected`：Android 12+ 后台启动前台服务被系统拒绝；
  /// - `start_service_failed` / `channel_unavailable` / `unsupported`：其他失败。
  String? lastShowError;

  /// 是否有悬浮窗权限（Settings.canDrawOverlays）
  Future<bool> canDrawOverlays() async {
    if (!isSupported) return false;
    try {
      return await channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「显示在其他应用上层」设置页（特殊权限无运行时弹窗）
  Future<void> requestOverlayPermission() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>('requestOverlayPermission');
    } catch (_) {}
  }

  /// 显示/替换悬浮窗内容；false = 启动失败（原因见 [lastShowError]）
  ///
  /// 原生返回 `true`（已提交启动）或错误码字符串（失败）。
  Future<bool> show(VideoFloatWindowState state) async {
    if (!isSupported) {
      lastShowError = 'unsupported';
      return false;
    }
    try {
      final raw = await channel.invokeMethod<dynamic>('show', state.toMap());
      if (raw == true) {
        lastShowError = null;
        return true;
      }
      lastShowError = raw is String ? raw : 'start_service_failed';
      return false;
    } catch (_) {
      lastShowError = 'channel_unavailable';
      return false;
    }
  }

  /// 当前悬浮窗状态（不停止服务）；null = 未运行
  Future<VideoFloatWindowState?> getState() async {
    if (!isSupported) return null;
    try {
      final raw = await channel.invokeMethod<dynamic>('getState');
      return VideoFloatWindowState.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  /// 接管：取出最终状态并停止悬浮窗服务（对齐原版 Activity 创建即停服务）
  Future<VideoFloatWindowState?> takeOver() async {
    if (!isSupported) return null;
    try {
      final raw = await channel.invokeMethod<dynamic>('takeOver');
      return VideoFloatWindowState.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  /// 静默关闭悬浮窗（不回调 onClosed；用于播完且无续播内容时）
  Future<void> dismiss() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>('dismiss');
    } catch (_) {}
  }

  /// 注册原生事件处理器并拉取冷启动的「回全屏」状态。
  /// 在 [LegadoApp] 首帧前调用（app.dart），重复调用安全。
  void attach() {
    if (!isSupported) return;
    channel.setMethodCallHandler((call) async {
      return VideoFloatWindowCoordinator.instance.handleNativeEvent(call);
    });
    unawaited(_consumeInitialReturn());
  }

  Future<void> _consumeInitialReturn() async {
    try {
      final raw = await channel.invokeMethod<dynamic>('getInitialFloatReturn');
      if (raw != null) {
        await VideoFloatWindowCoordinator.instance.handleReturnState(raw);
      }
    } catch (_) {}
  }

  /// 注销事件处理器（进程级单例一般不调用；保留以备测试与热重载）
  void detach() {
    channel.setMethodCallHandler(null);
  }
}

/// 悬浮窗会话协调器：进入时捕获章节上下文，原生事件驱动连播/进度落库/回全屏。
///
/// 单例由 app.dart 注入两个回调：
/// - [openFullscreen]：回全屏导航（避免 services → routes 反向依赖）
/// - [onNotice]：用户可见提示（SnackBar）
class VideoFloatWindowCoordinator {
  VideoFloatWindowCoordinator({VideoFloatWindowBridge? bridge})
      : _bridgeOverride = bridge;

  static VideoFloatWindowCoordinator instance = VideoFloatWindowCoordinator();

  final VideoFloatWindowBridge? _bridgeOverride;

  VideoFloatWindowBridge get bridge =>
      _bridgeOverride ?? VideoFloatWindowBridge.instance;

  /// 平台/桥可用性（非 Android 一律 false，调用方据此降级全屏页）
  bool get isSupported => bridge.isSupported;

  /// 最近一次 [enterWindow] 失败原因码（供 UI 分流提示；成功/未调用为 null）
  ///
  /// 取值为 [VideoFloatWindowBridge.lastShowError] 的错误码集合。
  String? lastEnterError;

  /// 打开系统「显示在其他应用上层」设置页（[enterWindow] 因无权限失败时调用）
  Future<void> requestOverlayPermission() =>
      bridge.requestOverlayPermission();

  /// app.dart 注入：把回传状态导航到视频播放页（Book 为交接会话捕获的上下文）
  void Function(VideoFloatWindowState state, Book? book)? openFullscreen;

  /// app.dart 注入：用户可见提示
  void Function(String message)? onNotice;

  Book? _book;
  List<BookChapter> _chapters = const [];
  Map<String, String> _sourceHeaders = const {};
  BookApi? _api;
  int _chapterIndex = -1;
  double _speed = 1.0;
  bool _active = false;

  /// 会话标识：每次成功进入 / 清除会话时自增，用于连播异步链的失效复核。
  /// [W3]：慢源回调迟到时可能已经换了会话，仅复核 `_active` 不足以区分
  /// 「同一会话」与「已重建的新会话」。
  int _sessionId = 0;

  @visibleForTesting
  bool get isCapturing => _active;

  /// 进入悬浮窗：先显示，成功后捕获章节上下文供后续连播/落库
  Future<bool> enterWindow({
    required VideoFloatWindowState state,
    Book? book,
    List<BookChapter>? chapters,
    Map<String, String>? sourceHeaders,
    BookApi? api,
  }) async {
    lastEnterError = null;
    final ok = await bridge.show(state);
    if (ok) {
      _book = book;
      _chapters = chapters ?? const [];
      _sourceHeaders = sourceHeaders ?? const {};
      _api = api;
      _chapterIndex = state.chapterIndex;
      _speed = state.speed;
      _active = true;
      _sessionId++;
    } else {
      // [W2/W4] 失败原因透传：权限缺失 / FGS 后台启动受限 / 其他
      lastEnterError = bridge.lastShowError ?? 'start_service_failed';
    }
    return ok;
  }

  /// 进入播放页时探测悬浮窗：
  /// - 同源 → 接管（停止服务并返回最终状态交由页面续播）；
  /// - 异源且存在 → 落库旧内容进度后关闭；
  /// - 无 → null。
  Future<VideoFloatWindowState?> probeAndTakeOver({
    String? bookUrl,
    String? videoUrl,
    BookApi? api,
  }) async {
    final probe = await bridge.getState();
    if (probe == null) return null;
    if (probe.isSameContent(bookUrl: bookUrl, videoUrl: videoUrl)) {
      final taken = await bridge.takeOver() ?? probe;
      // [W5] getState 与 takeOver 之间服务可能已自行停止（播完 10s 退出 /
      // returnToFullscreen 等），其 onDestroy 会删除 MPD 临时文件；此时
      // 回退的 probe 指向不存在的 file:// 清单，直接丢弃本次接管（返回
      // null）交由页面常规解析，避免必然失败的起播
      final mpd = taken.mpdTempPath;
      if (mpd != null && mpd.isNotEmpty && !await File(mpd).exists()) {
        _clearCapture();
        return null;
      }
      _clearCapture();
      return taken;
    }
    if (api != null) await writeProgressForState(api, probe);
    await bridge.dismiss();
    _clearCapture();
    return null;
  }

  /// 进度落库（书籍 → updateReadingProgress；直链 → video_pos_，对齐原版 saveRead）
  Future<void> writeProgressForState(
    BookApi api,
    VideoFloatWindowState state,
  ) async {
    if (state.positionMs <= 0) return;
    try {
      if (state.bookUrl != null && state.bookUrl!.isNotEmpty) {
        await api.updateReadingProgress(
          bookUrl: state.bookUrl!,
          chapterIndex: state.chapterIndex < 0 ? 0 : state.chapterIndex,
          chapterPos: state.positionMs,
        );
      } else if (state.directUrl != null && state.directUrl!.isNotEmpty) {
        await VideoPosStore(api).write(state.directUrl!, state.positionMs);
      }
    } catch (_) {}
  }

  /// 原生 → Dart 事件分发（由 VideoFloatWindowBridge.attach 注册）
  Future<dynamic> handleNativeEvent(MethodCall call) async {
    switch (call.method) {
      case 'onClosed':
        await _onClosed(call.arguments);
        return null;
      case 'onCompleted':
        await _advance(1, call.arguments);
        return null;
      case 'onSkipNext':
        await _advance(1, call.arguments);
        return null;
      case 'onSkipPrevious':
        await _advance(-1, call.arguments);
        return null;
      case 'onError':
        final msg = (call.arguments is Map)
            ? '${(call.arguments as Map)['message'] ?? ''}'
            : '${call.arguments}';
        debugPrint('[VideoFloat] 原生错误：$msg');
        onNotice?.call('悬浮窗播放出错');
        return null;
      default:
        return null;
    }
  }

  /// 回全屏（MainActivity Intent 单路径）：落库进度 + 导航到视频页续播
  Future<void> handleReturnState(Object? raw) async {
    final state = VideoFloatWindowState.fromMap(raw);
    if (state == null) return;
    final api = _api;
    final book = _book;
    if (api != null) await writeProgressForState(api, state);
    _clearCapture();
    openFullscreen?.call(state, book);
  }

  Future<void> _onClosed(Object? raw) async {
    final state = VideoFloatWindowState.fromMap(raw);
    final api = _api;
    if (state != null && api != null) {
      await writeProgressForState(api, state);
    }
    _clearCapture();
  }

  /// 连播/切集（对齐原版 VideoPlay.upDurIndex，VideoPlay.kt:474-490）：
  /// 目标索引越界 → 提示「已播放完」并结束；解析成功 → ACTION_REPLACE 续播。
  Future<void> _advance(int delta, Object? fallbackRaw) async {
    if (!_active) return;
    final session = _sessionId;
    final fallback = VideoFloatWindowState.fromMap(fallbackRaw);
    final api = _api;
    final book = _book;
    if (api == null || book == null || _chapters.isEmpty) {
      await _finish(fallback);
      return;
    }
    var next = _chapterIndex + delta;
    while (next >= 0 && next < _chapters.length && _chapters[next].isVolume) {
      next += delta;
    }
    if (next < 0 || next >= _chapters.length) {
      // 对齐原版 upDurIndex：越界 toast「已播放完」（上一集越界不提示）
      if (delta > 0) onNotice?.call('已播放完');
      await _finish(fallback);
      return;
    }
    try {
      final chapter = _chapters[next];
      final content = book.origin.isNotEmpty
          ? await api.fetchChapterContent(book.bookUrl, chapter.url, book.origin)
          : await api.getChapterContent(book.bookUrl, next);
      final target = resolveVideoPlayTarget(
        content: content,
        chapterUrl: chapter.url,
        sourceHeaders: _sourceHeaders,
      );
      if (!target.isMpd && target.url.isEmpty) {
        onNotice?.call('章节未解析出视频地址');
        await _finish(fallback);
        return;
      }
      final materialized = await _materializeTarget(target);
      // 切换前落库旧集进度（对齐原版 saveRead 的「离集即存」语义）
      if (fallback != null) await writeProgressForState(api, fallback);
      if (!_active || session != _sessionId) {
        // [W3] 慢源解析/落库期间会话可能已清除（原生 10s 完播退出）或
        // 已被新会话取代（页面接管后再次移交）：静默丢弃本次推进，不产生
        // 无上下文的孤儿续播；刚落盘的 MPD 一并清理
        await _deleteMpdQuietly(materialized.mpdPath);
        return;
      }
      final state = VideoFloatWindowState(
        url: materialized.url,
        title: chapter.title,
        bookName: book.name,
        headers: target.headers,
        positionMs: 0,
        playing: true,
        speed: _speed,
        bookUrl: book.bookUrl,
        chapterIndex: next,
        chapterTitle: chapter.title,
        hasPrev: _hasPlayable(next, -1),
        hasNext: _hasPlayable(next, 1),
        mpdTempPath: materialized.mpdPath,
      );
      final ok = await bridge.show(state);
      if (!ok) {
        // [W6] show 失败（无权限/服务启动被拒）时原生从未接手该 MPD 文件，
        // 服务 onDestroy 也不会删（deleteMpdOnDestroy 仅在装载后生效）
        await _deleteMpdQuietly(materialized.mpdPath);
        onNotice?.call('悬浮窗已停止');
        await _finish(fallback);
        return;
      }
      _chapterIndex = next;
    } catch (e) {
      debugPrint('[VideoFloat] 连播失败：$e');
      onNotice?.call('连播失败：$e');
      await _finish(fallback);
    }
  }

  bool _hasPlayable(int from, int delta) {
    var i = from + delta;
    while (i >= 0 && i < _chapters.length) {
      if (!_chapters[i].isVolume) return true;
      i += delta;
    }
    return false;
  }

  /// MPD 清单落临时文件（原生 ExoPlayer 播 file://，与原版 VideoPlay 写 videoTempFile 同型）
  Future<({String url, String? mpdPath})> _materializeTarget(
    VideoPlayTarget target,
  ) async {
    if (!target.isMpd) return (url: target.url, mpdPath: null);
    final dir = await getTemporaryDirectory();
    final name = 'legado_video_float_${DateTime.now().millisecondsSinceEpoch}.mpd';
    final file = File('${dir.path}/$name');
    await file.writeAsString(target.mpdContent!);
    return (url: file.uri.toString(), mpdPath: file.path);
  }

  /// 静默删除 MPD 临时文件（[W3] 会话失效丢弃 / [W6] show 失败清孤儿清单）
  Future<void> _deleteMpdQuietly(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _finish(VideoFloatWindowState? fallback) async {
    final api = _api;
    if (fallback != null && api != null) {
      await writeProgressForState(api, fallback);
    }
    _clearCapture();
    await bridge.dismiss();
  }

  void _clearCapture() {
    _book = null;
    _chapters = const [];
    _sourceHeaders = const {};
    _api = null;
    _chapterIndex = -1;
    _speed = 1.0;
    _active = false;
    _sessionId++;
  }

  @visibleForTesting
  void resetForTest() => _clearCapture();
}
