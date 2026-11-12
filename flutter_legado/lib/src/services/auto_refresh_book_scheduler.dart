// 自动刷新书架（对齐原版 MainActivity.onPostCreate → upAllBookToc）
//
// 原版语义（legado-upstream MainActivity.kt:171-178 / MainViewModel.kt:105-160）：
// - `AppConfig.autoRefreshBook`（pref 键 `auto_refresh`）为 true 时，冷启动后
//   `postDelayed(2000)` 触发 `upAllBookToc()`；
// - `AppConfig.onlyUpdateRead`（pref 键 `onlyUpdateRead`）为 true 时，
//   `addToWaitUp` 跳过 `getUnreadChapterNum() > 0` 的书
//   （即只刷新没有未读章节、已读到最后一章的书）；
// - 刷新完由 BookShelf Fragment 自行观察 EventBus 更新书架与「更新中」计数。
//
// 本实现差异（已登记于提交正文，不改平台契约）：
// - 只在进程内执行一次（不挂 resumed），避免回前台反复刷；
// - 串行逐本 `refreshToc`（原版用 threadCount 线程池；串行可避免启动即
//   触发网络风暴，且与书架「更新目录」交互互不抢占）；
// - 新增章节数 = 刷新后 `totalChapterNum` − 刷新前 `totalChapterNum`
//   （对齐原版 `BookChapterList.kt:171-172` 的 lastCheckCount 口径；Rust
//   refreshToc 不写 lastCheckCount，故在 Dart 侧按前后差值计算）；
// - 失败逐本吞掉并 debugPrint（原版单本失败也不影响其他书）。
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../constants/pref_keys.dart';
import '../models/book.dart';
import 'book_api.dart';
import 'settings_service.dart';

/// 自动刷新书架的执行结果（便于单测断言与日志）
enum AutoRefreshBookOutcome {
  /// `auto_refresh` 开关关闭
  disabled,

  /// 本进程已执行过（只执行一次）
  alreadyRan,

  /// 没有符合条件的书（空书架 / 全是本地书 / onlyUpdateRead 过滤后为空）
  nothingToUpdate,

  /// 已尝试刷新（成功数见 [AutoRefreshBookResult.succeeded]）
  completed,
}

/// 自动刷新书架结果
class AutoRefreshBookResult {
  const AutoRefreshBookResult({
    required this.outcome,
    this.attempted = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.newChapters = 0,
  });

  final AutoRefreshBookOutcome outcome;

  /// 实际进入刷新队列的书数
  final int attempted;

  /// 刷新成功（`refreshToc` 未抛异常）的书数
  final int succeeded;

  /// 刷新失败的书数（失败已静默记日志）
  final int failed;

  /// 本轮发现的新增章节总数
  final int newChapters;

  /// 用户可见提示文案；无成功项时返回 null（失败不打扰用户）
  String? get notice {
    if (outcome != AutoRefreshBookOutcome.completed || succeeded == 0) {
      return null;
    }
    final base = '已更新 $succeeded 本书的目录';
    return newChapters > 0 ? '$base，新增 $newChapters 章' : base;
  }
}

/// 冷启动自动刷新书架调度器（进程内单例）
///
/// 装配：`app.dart` initState → [attach]（首帧后延迟 [startupDelay] 执行）。
/// 与 `AutoBackupScheduler` 一样不阻塞启动；失败不影响应用可用性。
class AutoRefreshBookScheduler {
  AutoRefreshBookScheduler({
    required BookApi api,
    SettingsService? settings,
    this.startupDelay = const Duration(seconds: 2),
    Future<void> Function()? onBookshelfChanged,
    void Function(AutoRefreshBookResult result)? onResult,
  }) : _api = api,
       _settings = settings ?? SettingsService(),
       _onBookshelfChanged = onBookshelfChanged,
       _onResult = onResult;

  final BookApi _api;
  final SettingsService _settings;

  /// 首帧后到开始刷新的延迟（对齐原版 `postDelayed(2000)`）
  final Duration startupDelay;

  /// 刷新结束后的书架重载回调（注入以避开 services → providers 依赖）
  final Future<void> Function()? _onBookshelfChanged;

  /// 结果回调（UI 轻量提示；无成功项时不回调）
  final void Function(AutoRefreshBookResult result)? _onResult;

  bool _ran = false;
  bool _disposed = false;
  Timer? _startupTimer;

  static AutoRefreshBookScheduler? _instance;

  /// 装配入口（app.dart initState，对齐 [AutoBackupScheduler.attach]）
  ///
  /// 重复调用幂等。首帧渲染完成后延迟 [startupDelay] 执行一次；不注册
  /// 生命周期观察者（原版也只在 onCreate 触发，回前台不刷新）。
  static AutoRefreshBookScheduler attach({
    required BookApi api,
    SettingsService? settings,
    Future<void> Function()? onBookshelfChanged,
    void Function(AutoRefreshBookResult result)? onResult,
    Duration startupDelay = const Duration(seconds: 2),
  }) {
    final existing = _instance;
    if (existing != null) return existing;
    final instance = AutoRefreshBookScheduler(
      api: api,
      settings: settings,
      startupDelay: startupDelay,
      onBookshelfChanged: onBookshelfChanged,
      onResult: onResult,
    );
    _instance = instance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (instance._disposed) return;
      instance._startupTimer = Timer(instance.startupDelay, () {
        unawaited(instance.run());
      });
    });
    return instance;
  }

  /// 测试用：清空单例并取消未触发的启动定时器
  @visibleForTesting
  static void resetForTest() {
    _instance?._cancelTimer();
    _instance = null;
  }

  /// 解除定时器与单例（应用退出时可选调用）
  void dispose() {
    _disposed = true;
    _cancelTimer();
    if (identical(_instance, this)) _instance = null;
  }

  void _cancelTimer() {
    _startupTimer?.cancel();
    _startupTimer = null;
  }

  /// 仅更新「已读完」的书（对齐原版 `Book.getUnreadChapterNum()`）
  ///
  /// 原版 `addToWaitUp`：`if (onlyUpdateRead && book.getUnreadChapterNum() > 0)
  /// return@forEach`；`getUnreadChapterNum = max(totalChapterNum - durChapterIndex
  /// - 1, 0)`（Book.kt:172），即只刷新读到最后一章、无未读章节的书。
  ///
  /// 附加「有过阅读进度」必要条件（`durChapterIndex > 0 || durChapterTime > 0`）：
  /// 目录尚未抓取（`totalChapterNum == 0`）且从未打开过的书不算「已读完」，
  /// 避免把刚导入、从未阅读的书误判为已读完。
  static bool onlyUpdateReadAllows(Book book) {
    final unreadChapters = book.totalChapterNum - book.durChapterIndex - 1;
    if (unreadChapters > 0) return false;
    return book.durChapterIndex > 0 || book.durChapterTime > 0;
  }

  /// 是否需要刷新这本书（更新目录的通用前置过滤 + onlyUpdateRead 过滤）
  static bool shouldRefresh({
    required Book book,
    required bool onlyUpdateRead,
  }) {
    if (!BookType.canUpdateToc(book)) return false;
    if (onlyUpdateRead && !onlyUpdateReadAllows(book)) return false;
    return true;
  }

  /// 执行一次自动刷新（进程内只生效一次；重复调用返回 alreadyRan）
  ///
  /// 不抛异常：单本失败计数后继续，整体失败静默记日志。
  Future<AutoRefreshBookResult> run() async {
    if (_ran) {
      return const AutoRefreshBookResult(
        outcome: AutoRefreshBookOutcome.alreadyRan,
      );
    }
    // 先占位再读偏好：即使开关关闭，也算「本轮已判定」，避免回前台重试
    _ran = true;
    _cancelTimer();

    final bool autoRefresh;
    final bool onlyUpdateRead;
    try {
      autoRefresh = await _settings.getBoolPref(
        PrefKeys.autoRefreshBook,
        defaultValue: false,
      );
      onlyUpdateRead = await _settings.getBoolPref(
        PrefKeys.onlyUpdateRead,
        defaultValue: false,
      );
    } catch (e) {
      debugPrint('[AutoRefreshBook] 读取偏好失败（跳过）：$e');
      return const AutoRefreshBookResult(
        outcome: AutoRefreshBookOutcome.disabled,
      );
    }
    if (!autoRefresh) {
      return const AutoRefreshBookResult(
        outcome: AutoRefreshBookOutcome.disabled,
      );
    }

    List<Book> targets;
    try {
      final books = await _api.getBooks();
      targets = books
          .where((b) => shouldRefresh(book: b, onlyUpdateRead: onlyUpdateRead))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[AutoRefreshBook] 读取书架失败（跳过）：$e');
      return const AutoRefreshBookResult(
        outcome: AutoRefreshBookOutcome.nothingToUpdate,
      );
    }
    if (targets.isEmpty) {
      debugPrint('[AutoRefreshBook] 没有符合刷新条件的书籍，跳过');
      return const AutoRefreshBookResult(
        outcome: AutoRefreshBookOutcome.nothingToUpdate,
      );
    }

    var succeeded = 0;
    var failed = 0;
    var newChapters = 0;
    for (final book in targets) {
      final before = book.totalChapterNum;
      try {
        await _api.refreshToc(book.bookUrl, book.origin);
        final after = await _api.getBook(book.bookUrl);
        final afterTotal = after?.totalChapterNum ?? before;
        final delta = afterTotal - before;
        if (delta > 0) newChapters += delta;
        succeeded++;
      } catch (e) {
        failed++;
        debugPrint('[AutoRefreshBook] 更新目录失败《${book.name}》: $e');
      }
    }

    final result = AutoRefreshBookResult(
      outcome: AutoRefreshBookOutcome.completed,
      attempted: targets.length,
      succeeded: succeeded,
      failed: failed,
      newChapters: newChapters,
    );
    debugPrint(
      '[AutoRefreshBook] 完成：尝试 ${result.attempted}，成功 ${result.succeeded}，'
      '失败 ${result.failed}，新增 ${result.newChapters} 章',
    );

    if (succeeded > 0) {
      final onChanged = _onBookshelfChanged;
      if (onChanged != null) {
        try {
          await onChanged();
        } catch (e) {
          debugPrint('[AutoRefreshBook] 书架重载失败（忽略）：$e');
        }
      }
      final onResult = _onResult;
      if (onResult != null) {
        try {
          onResult(result);
        } catch (e) {
          debugPrint('[AutoRefreshBook] 结果提示回调失败（忽略）：$e');
        }
      }
    }
    return result;
  }
}
