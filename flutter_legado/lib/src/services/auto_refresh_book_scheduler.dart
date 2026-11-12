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
//   触发网络风暴）。并发互斥语义由 Rust 刷新代数按书籍键控保证：自动刷新
//   A 书与用户手动刷新 B 书互不取消；同一本书以最新一次刷新为准，旧在途链
//   返回明确的 `toc refresh superseded`（自动侧计入 cancelled，不是静默）。
// - 新增章节数 = 刷新后 `totalChapterNum` − 刷新前 `totalChapterNum`
//   （对齐原版 `BookChapterList.kt:171-172` 的 lastCheckCount 口径；Rust
//   refreshToc 不写 lastCheckCount，故在 Dart 侧按前后差值计算）；
// - 成功判定按刷新后元信息实变（总章数或末章标题）：Rust 空解析回退旧目录
//   的 no-op 不计入 succeeded；
// - 失败/被取代逐本记录并 debugPrint（原版单本失败也不影响其他书）。
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../constants/pref_keys.dart';
import '../models/book.dart';
import '../models/book_chapter.dart';
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
    this.unchanged = 0,
    this.cancelled = 0,
    this.failed = 0,
    this.newChapters = 0,
  });

  final AutoRefreshBookOutcome outcome;

  /// 实际进入刷新队列的书数
  final int attempted;

  /// 实际发生目录变更（总章数或末章标题变化）的书数
  ///
  /// 「`refreshToc` 未抛异常」不等于成功：Rust 空解析会回退旧目录返回
  /// Ok（no-op），该情形计入 [unchanged]。
  final int succeeded;

  /// 刷新链路成功但目录未变化（含 Rust 空解析回退旧目录的 no-op）
  final int unchanged;

  /// 被同一本书的更新刷新取代（Rust `toc refresh superseded`）的书数
  ///
  /// 同书并发以最新一次为准：旧链在下一页边界中止并返回明确错误；
  /// 其他书籍的刷新不会影响本链（刷新代数按 bookUrl 键控）。
  final int cancelled;

  /// 刷新失败（网络/解析等非取代类错误）的书数（已静默记日志）
  final int failed;

  /// 本轮发现的新增章节总数
  final int newChapters;

  /// 用户可见提示文案；无实际更新时返回 null（失败/无变化不打扰用户）
  String? get notice {
    if (outcome != AutoRefreshBookOutcome.completed || succeeded == 0) {
      return null;
    }
    final base = '已更新 $succeeded 本书的目录';
    final chapterPart = newChapters > 0 ? '，新增 $newChapters 章' : '';
    final cancelPart = cancelled > 0 ? '（$cancelled 本被同书新刷新取代）' : '';
    return '$base$chapterPart$cancelPart';
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

  /// 当前装配实例（应用 dispose 时释放；未装配为 null）
  static AutoRefreshBookScheduler? get instance => _instance;

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
  /// 与上游逐字同口径（2026-11-13 回修）：**不**附加「必须有阅读进度」条件。
  /// `totalChapterNum == 0`（目录未抓取）或 `total=1, durChapterIndex=0`
  /// 的从未打开书籍，上游同样会刷新；此前多出的 `durChapterIndex > 0 ||
  /// durChapterTime > 0` 守卫会漏刷这些书，已移除。
  static bool onlyUpdateReadAllows(Book book) {
    final unreadChapters = book.totalChapterNum - book.durChapterIndex - 1;
    return unreadChapters <= 0;
  }

  /// Rust 目录刷新被同书更新请求取代（分页链在页边界判活失败）
  static bool _isSuperseded(Object error) =>
      error.toString().contains('toc refresh superseded');

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
    var unchanged = 0;
    var cancelled = 0;
    var failed = 0;
    var newChapters = 0;
    for (final book in targets) {
      final beforeTotal = book.totalChapterNum;
      final beforeTitle = book.latestChapterTitle;
      final List<BookChapter> chapters;
      try {
        chapters = await _api.refreshToc(book.bookUrl, book.origin);
      } catch (e) {
        if (_isSuperseded(e)) {
          // 同书并发以最新一次为准：旧链被取消是预期行为，单独计数并记录
          // 明确日志（不并入 failed，避免「静默失败」误导）
          cancelled++;
          debugPrint('[AutoRefreshBook] 刷新被同书新请求取代《${book.name}》: $e');
        } else {
          failed++;
          debugPrint('[AutoRefreshBook] 更新目录失败《${book.name}》: $e');
        }
        continue;
      }
      // 刷新链路成功（含 Rust 空解析回退旧目录的 Ok(no-op)）：读取刷新后
      // 元信息判定是否实际变更；getBook 失败不影响本本成功判定。
      Book? after;
      try {
        after = await _api.getBook(book.bookUrl);
      } catch (e) {
        debugPrint('[AutoRefreshBook] 读取刷新后书籍失败《${book.name}》（按刷新结果计）: $e');
      }
      if (after == null) {
        // 无法比对元信息：以 refreshToc 返回值兜底（空列表视为 no-op）
        if (chapters.isEmpty) {
          unchanged++;
        } else {
          succeeded++;
        }
        continue;
      }
      final delta = after.totalChapterNum - beforeTotal;
      if (delta > 0) newChapters += delta;
      final changed =
          after.totalChapterNum != beforeTotal ||
          after.latestChapterTitle != beforeTitle;
      if (changed) {
        succeeded++;
      } else {
        unchanged++;
      }
    }

    final result = AutoRefreshBookResult(
      outcome: AutoRefreshBookOutcome.completed,
      attempted: targets.length,
      succeeded: succeeded,
      unchanged: unchanged,
      cancelled: cancelled,
      failed: failed,
      newChapters: newChapters,
    );
    debugPrint(
      '[AutoRefreshBook] 完成：尝试 ${result.attempted}，更新 ${result.succeeded}，'
      '无变化 ${result.unchanged}，被取代 ${result.cancelled}，'
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
