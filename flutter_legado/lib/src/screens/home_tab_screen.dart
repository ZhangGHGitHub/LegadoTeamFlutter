import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/privacy/privacy_content_notifier.dart';
import '../providers/privacy/privacy_notifier.dart';
import '../providers/privacy/privacy_state.dart';
import '../providers/providers.dart';
import '../providers/read_record/read_record_notifier.dart';
import '../routes.dart';
import '../services/privacy_content_service.dart';
import '../utils/book_open_utils.dart';
import '../widgets/book_cover.dart';
import '../widgets/privacy/private_locked_cover.dart';

/// 首页页签（对齐参考版首页布局）
///
/// [UI_SYNC_REFACTOR S6 | 2026-09-08] 差异清单批六：参考版有「首页」页签
/// （最近阅读卡 + 累计阅读统计 + 今日阅读目标表盘），我方此前无此页签 — Qoder
/// 数据源：书架（最近阅读）+ 阅读记录（本书数/总时长/今日时长）。
/// 今日目标分钟数存本地偏好 homeReadGoalMinutes（默认 30，可编辑）。
/// 首页模块管理（自定义集/书源模块）为参考版深功能，登记后续批次。
class HomeTabScreen extends ConsumerStatefulWidget {
  const HomeTabScreen({super.key});

  @override
  ConsumerState<HomeTabScreen> createState() => _HomeTabScreenState();
}

class _HomeTabScreenState extends ConsumerState<HomeTabScreen> {
  /// 今日目标分钟数（本地偏好，默认 30 对齐参考版初始值）
  int _goalMinutes = 30;

  /// 今日已读秒数（readRecordDailyList 当日项）
  int _todaySeconds = 0;

  /// 是否已加载今日时长（避免日列表未就绪时表盘归零闪烁）
  bool _todayLoaded = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaitedLoad();
    });
  }

  /// 拉取阅读记录与今日时长（阅读记录页同源 API）
  Future<void> unawaitedLoad() async {
    unawaitedInit();
    try {
      await ref.read(readRecordNotifierProvider.notifier).load();
      final year = DateTime.now().year;
      final daily = await ref
          .read(bookApiProvider)
          .readRecordDailyList(year)
          .catchError((_) => <Map<String, dynamic>>[]);
      if (!mounted) return;
      final todayKey = _dayKey(DateTime.now());
      for (final e in daily) {
        final date = (e['date'] ?? '').toString();
        if (date == todayKey) {
          _todaySeconds = (e['seconds'] as num?)?.toInt() ?? 0;
          break;
        }
      }
    } catch (_) {
      // 统计加载失败不阻断首页，表盘保持 0
    }
    if (!mounted) return;
    setState(() => _todayLoaded = true);
  }

  Future<void> unawaitedInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _goalMinutes = prefs.getInt('homeReadGoalMinutes') ?? 30;
      });
    } catch (_) {
      // 偏好读取失败保持默认目标
    }
  }

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _editGoal() async {
    var draft = _goalMinutes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('今日阅读目标'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () {
                      if (draft > 5) {
                        setDialogState(() => draft -= 5);
                      }
                    },
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                  Text('$draft 分钟',
                      style: Theme.of(dialogContext).textTheme.titleMedium),
                  IconButton(
                    onPressed: () {
                      if (draft < 480) {
                        setDialogState(() => draft += 5);
                      }
                    },
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ],
              ),
              Slider(
                value: draft.clamp(5, 480).toDouble(),
                min: 5,
                max: 480,
                divisions: 95,
                label: '$draft',
                onChanged: (v) => setDialogState(() => draft = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted && draft != _goalMinutes) {
      setState(() => _goalMinutes = draft);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('homeReadGoalMinutes', draft);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final records = ref.watch(
        readRecordNotifierProvider.select((s) => s.records));
    final totalMs = ref.watch(
        readRecordNotifierProvider.select((s) => s.totalReadTimeMs));
    final books = ref.watch(
        bookshelfNotifierProvider.select((s) => s.books));
    // [审查] 首页最近阅读与阅读记录页共用同一份私密策略/标记快照：
    // 私密书未授权时不得在首页明文展示书名/作者/章节名。
    final privacy = ref.watch(privacyNotifierProvider);
    final privacyContent = ref.watch(privacyContentProvider);

    // 最近阅读：按阅读记录 lastRead 取最近一条，再按「物理书名+作者」
    // 反查书架/隐私快照（含批31 改名别名桥），不再用裸书名匹配。
    final recent = _resolveRecentRead(
      records: records,
      books: books,
      privacy: privacy,
      privacyContent: privacyContent,
    );
    final readBooks =
        records.where((r) => r.readTime > 0).length;
    final totalHours = (totalMs / 3600000).toStringAsFixed(1);
    final goalSeconds = _goalMinutes * 60;
    final progress = goalSeconds <= 0
        ? 0.0
        : (_todaySeconds / goalSeconds).clamp(0.0, 1.0);
    final todayMinutes = (_todaySeconds / 60).round();

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          // [1-2 ①] 参考版层级：动作钮行在上（右对齐），大标题独占下一行（左对齐、更大）。
          // 参考版该行另有 ⋮（「首页组件」入口，属模块管理域，用户裁决暂不实施，仅保留台账登记）
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '其他设置',
                icon: const Icon(Icons.settings_rounded),
                onPressed: () =>
                    Navigator.pushNamed(context, AppRoutes.otherSettings),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '首页',
            // 参考版量测：标题字高 77px ≈ 28sp（现 headlineMedium 24sp → 放大至 28）
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontSize: 28),
          ),
          const SizedBox(height: 16),
          // ===== 最近阅读卡 =====
          // [审查] 三态：正常 / 私密未授权占位 / 隐私快照未就绪中性占位。
          if (recent != null) _buildRecentCard(recent, cs),
          if (recent != null) const SizedBox(height: 12),
          // ===== 统计双卡 =====
          Row(
            children: [
              Expanded(
                child: _HomeCard(
                  child: Row(
                    children: [
                      Icon(Symbols.bar_chart_rounded, color: cs.primary),
                      const SizedBox(width: 10),
                      // [FIX 2026-09-19 P2-13②] 数值列限宽 + 省略号截断，防 Row 右溢
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('累计阅读',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                            Text('$readBooks 本',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HomeCard(
                  child: Row(
                    children: [
                      Icon(Symbols.schedule_rounded, color: cs.primary),
                      const SizedBox(width: 10),
                      // [FIX 2026-09-19 P2-13②] 数值列限宽 + 省略号截断，防 Row 右溢
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('阅读时长',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                            Text('$totalHours 小时',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ===== 今日阅读目标表盘 =====
          _HomeCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // [1-2 ③] 参考版目标图标=同心圆靶形（radar），替换时钟形
                    Icon(Symbols.radar_rounded, color: cs.primary),
                    const SizedBox(width: 10),
                    Text('今日阅读目标',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    // [1-2 ③] 参考版编辑钮=白底圆形浮钮（表面色+投影），替换裸图标
                    _GoalEditFab(onTap: _editGoal),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _GoalDialPainter(
                      progress: _todayLoaded ? progress : 0,
                      trackColor: cs.surfaceContainerHighest,
                      progressColor: cs.primary,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _todayLoaded
                                ? '$todayMinutes / $_goalMinutes'
                                : '— / $_goalMinutes',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text('分钟',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBadge(Book book, ColorScheme cs) {
    final total = book.totalChapterNum;
    final percent = total > 0
        ? ((book.durChapterIndex + 1) / total * 100).round()
        : 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$percent%',
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: cs.onSurfaceVariant)),
    );
  }

  /// 解析最近阅读视图（隐私脱敏三态 + 批31 改名别名桥）
  ///
  /// [审查] 旧实现用 `Book.name == record.bookName` 裸书名匹配且不做隐私
  /// 判定：私密书作为最近阅读时首页会明文展示书名/作者/章节名；私密书
  /// 改名后旧记录又匹配不到 → 卡片消失。现改为按「物理书名 + 作者」经
  /// [PrivacyContentSnapshot.findBookByNameAuthor] 反查（内部已并入
  /// [PrivacyRecordAliasStore] 登记的改名别名），并以同一快照判定锁定态。
  _RecentReadView? _resolveRecentRead({
    required List<ReadRecordShow> records,
    required List<Book> books,
    required PrivacyState privacy,
    required PrivacyContentSnapshot privacyContent,
  }) {
    if (records.isEmpty) return null;
    final sorted = [...records]
      ..sort((a, b) => b.lastRead.compareTo(a.lastRead));
    final top = sorted.first;

    // 首帧竞态：策略或私密标记尚未就绪时，空快照会把私密书判成「非私密」
    // （fail-open）。此处先渲染中性占位，等快照加载完成再决定正常/锁定，
    // 绝不按未就绪状态明文渲染身份信息。
    if (!privacy.loaded || (privacy.enabled && !privacyContent.loaded)) {
      return _RecentReadView(record: top, mode: _RecentReadMode.pending);
    }

    final book = _resolveRecentBook(top, books, privacyContent);
    // 记录键可能因历史作者形态/改名边界反查不到候选；若最终落到一本
    // 私密书，仍按书籍维度补一次锁定判定（fail-closed，宁占位不泄漏）。
    final locked = _isRecentLocked(top, privacy, privacyContent) ||
        (book != null && privacyContent.isBookLocked(book, privacy));
    if (locked) {
      // 锁定态仍可保留书对象用于取模糊封面（不渲染任何文本身份）。
      return _RecentReadView(
        record: top,
        mode: _RecentReadMode.locked,
        book: book,
      );
    }
    if (book == null) return null; // 书架无书：与既有行为一致，不显示卡片
    return _RecentReadView(
      record: top,
      mode: _RecentReadMode.normal,
      book: book,
    );
  }

  /// 最近阅读是否应脱敏（与阅读记录页同一判定）
  ///
  /// 记录的展示名可能被用户改过，物理名才是落库键；两把键都查，
  /// 避免任一形态漏判。
  bool _isRecentLocked(
    ReadRecordShow item,
    PrivacyState privacy,
    PrivacyContentSnapshot privacyContent,
  ) {
    if (!privacy.loaded ||
        !privacy.enabled ||
        !privacy.verifyOnOpenBook ||
        !privacyContent.loaded) {
      return false;
    }
    final physical = item.physicalBookName.isNotEmpty
        ? item.physicalBookName
        : item.bookName;
    final keys = <PrivacyRecordKey>[
      PrivacyRecordKey(physical, item.author),
      if (item.bookName != physical)
        PrivacyRecordKey(item.bookName, item.author),
    ];
    return keys.any((key) => privacyContent.isRecordLocked(key, privacy));
  }

  /// 反查最近阅读对应的当前书籍
  ///
  /// 优先走隐私快照（含改名别名），快照未持有书籍时退回书架定向匹配。
  Book? _resolveRecentBook(
    ReadRecordShow item,
    List<Book> books,
    PrivacyContentSnapshot privacyContent,
  ) {
    final physical = item.physicalBookName.isNotEmpty
        ? item.physicalBookName
        : item.bookName;
    Book? resolved;
    if (privacyContent.loaded) {
      resolved = privacyContent.findBookByNameAuthor(physical, item.author);
      if (resolved == null && item.bookName != physical) {
        resolved = privacyContent.findBookByNameAuthor(
          item.bookName,
          item.author,
        );
      }
    }
    final candidate = resolved;
    if (candidate != null) {
      // 书架上可能有更新的阅读进度，优先使用同 URL 的书架实例。
      for (final book in books) {
        if (book.bookUrl == candidate.bookUrl) return book;
      }
      return candidate;
    }
    return _matchShelfBook(item, books);
  }

  /// 快照未持有书籍时的书架匹配（无书私密标记/无改名历史的常规路径）
  ///
  /// 匹配按三级放宽（[审查 P1-1]：批32 收紧为「名+作者严格双等」后，
  /// 阅读器新写记录作者为空、展示作者又可能是合并串 `甲、乙`，导致首页
  /// 最近阅读卡静默消失，而阅读记录页仍能打开同一记录）：
  /// 1. 物理名 + 展示作者精确相等（最严，保持原行为）；
  /// 2. 展示作者按 `、` / 历史 `\u001F` 拆段后逐段匹配（复用
  ///    [PrivacyContentSnapshot.authorTokens]，覆盖 `甲、乙` vs `甲`）；
  /// 3. 裸名兜底：同名非空时取第一条，与阅读记录页 `findBookByName`
  ///    同口径（作者为空是阅读器新写记录的常态）。
  ///
  /// **匹配放宽不降低隐私安全性**：是否脱敏由 [_isRecentLocked]
  /// （记录键 → 全部同名候选 fail-closed）与
  /// [PrivacyContentSnapshot.isBookLocked] 在渲染前独立判定，开书侧还有
  /// `book_utils.ensurePrivateAccess` 第二道闸门；此处只决定「展示哪本
  /// 书架实例」，不参与锁定判定。
  Book? _matchShelfBook(ReadRecordShow item, List<Book> books) {
    final physical = item.physicalBookName.isNotEmpty
        ? item.physicalBookName
        : item.bookName;
    final author = item.author.trim();

    Book? matchByName(String name) {
      if (author.isNotEmpty) {
        for (final book in books) {
          if (book.name == name && book.author == author) return book;
        }
        // 展示作者可能是历史合并串（`甲、乙`）或编码串，拆段后逐段匹配
        for (final token in PrivacyContentSnapshot.authorTokens(author)) {
          for (final book in books) {
            if (book.name == name && book.author == token) return book;
          }
        }
      }
      // 裸名兜底：同名非空取第一条（对齐 findBookByName 的 firstOrNull）
      for (final book in books) {
        if (book.name == name) return book;
      }
      return null;
    }

    return matchByName(physical) ??
        (item.bookName != physical ? matchByName(item.bookName) : null);
  }

  Widget _recentLabel(ColorScheme cs) => Row(
    children: [
      Icon(Symbols.menu_book_rounded, size: 18, color: cs.primary),
      const SizedBox(width: 6),
      Text('最近阅读',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: cs.primary)),
    ],
  );

  /// 最近阅读卡：正常 / 锁定 / 首帧中性占位
  Widget _buildRecentCard(_RecentReadView recent, ColorScheme cs) {
    switch (recent.mode) {
      case _RecentReadMode.pending:
        // 中性骨架：不含任何书名/作者/章节文本，也不响应点击。
        return _HomeCard(
          key: const ValueKey('homeRecentCard'),
          child: Row(
            children: [
              Container(
                key: const ValueKey('homeRecentPending'),
                width: 64,
                height: 88,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _recentLabel(cs),
                    const SizedBox(height: 10),
                    _RecentSkeletonBar(
                        width: 150, color: cs.surfaceContainerHighest),
                    const SizedBox(height: 8),
                    _RecentSkeletonBar(
                        width: 96, color: cs.surfaceContainerHighest),
                    const SizedBox(height: 8),
                    _RecentSkeletonBar(
                        width: 120, color: cs.surfaceContainerHighest),
                  ],
                ),
              ),
            ],
          ),
        );
      case _RecentReadMode.locked:
        final book = recent.book;
        return _HomeCard(
          key: const ValueKey('homeRecentCard'),
          onTap: () => _openRecent(recent.record),
          child: Row(
            children: [
              PrivateLockedCover(
                width: 64,
                height: 88,
                coverUrl: book?.customCoverUrl ?? book?.coverUrl,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _recentLabel(cs),
                    const SizedBox(height: 8),
                    Row(
                      key: const ValueKey('homeRecentLocked'),
                      children: [
                        Icon(Symbols.lock_rounded,
                            size: 16, color: cs.primary),
                        const SizedBox(width: 6),
                        Text('私密书籍',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '内容已隐藏，解锁后查看',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      case _RecentReadMode.normal:
        final book = recent.book;
        if (book == null) return const SizedBox.shrink();
        return _HomeCard(
          key: const ValueKey('homeRecentCard'),
          onTap: () => _openRecent(recent.record),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                height: 88,
                child: BookCover(
                  coverUrl: book.customCoverUrl ?? book.coverUrl,
                  bookName: book.name,
                  bookAuthor: book.author,
                  width: 64,
                  height: 88,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _recentLabel(cs),
                    const SizedBox(height: 8),
                    Text(book.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    if (book.durChapterTitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        book.durChapterTitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              _progressBadge(book, cs),
            ],
          ),
        );
    }
  }

  /// 打开最近阅读（点击前兜底隐私校验，与阅读记录页一致）
  ///
  /// 未授权私密记录：仅提示「请先在书架解锁」，既不打开阅读器/详情，
  /// 也不把书名作为关键词发给第三方搜索。加载期间页面被弹出则直接返回。
  Future<void> _openRecent(ReadRecordShow record) async {
    try {
      await ref.read(privacyNotifierProvider.notifier).ensureLoaded();
      final privacyContent = await ref
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      if (!mounted) return;
      final privacy = ref.read(privacyNotifierProvider);
      final book = _resolveRecentBook(
        record,
        ref.read(bookshelfNotifierProvider).books,
        privacyContent,
      );
      final locked = _isRecentLocked(record, privacy, privacyContent) ||
          (book != null && privacyContent.isBookLocked(book, privacy));
      if (locked) {
        _showRecentMessage('该书为私密内容，请先在书架解锁后再打开');
        return;
      }
      if (book == null) {
        _showRecentMessage('书籍已不在书架中');
        return;
      }
      // 与阅读记录页同链路：分流编排统一在 BookOpenUtils.openBook
      // （未读进详情 + 书源类型位解析后按类型进阅读器）
      await BookOpenUtils.openBook(context, ref, book);
    } catch (e) {
      debugPrint('[首页] 最近阅读打开失败：$e');
      if (!mounted) return;
      _showRecentMessage('打开失败，请稍后重试');
    }
  }

  void _showRecentMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 首页最近阅读卡的隐私三态
enum _RecentReadMode {
  /// 正常展示（非私密或已授权）
  normal,

  /// 私密且未授权：只显示中性占位与模糊封面
  locked,

  /// 隐私策略/标记尚未加载：只显示无身份信息的中性骨架
  pending,
}

/// 最近阅读卡解析结果
class _RecentReadView {
  const _RecentReadView({
    required this.record,
    required this.mode,
    this.book,
  });

  final ReadRecordShow record;
  final _RecentReadMode mode;

  /// 解析到的当前书籍（锁定态可为 null，用于取封面）
  final Book? book;
}

/// 首帧占位骨架条
class _RecentSkeletonBar extends StatelessWidget {
  const _RecentSkeletonBar({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

/// 首页卡片基座（圆角 24 + surfaceContainerLow，与阅读界面弹层卡一致）
class _HomeCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _HomeCard({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );
  }
}

/// [1-2 ③] 目标卡编辑钮：白底圆形浮钮（参考版量测 ≈40dp 表面色圆 + 投影，
/// 图标 onSurface；替换原裸 IconButton）
class _GoalEditFab extends StatelessWidget {
  final VoidCallback onTap;

  const _GoalEditFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 2,
      shape: const CircleBorder(),
      child: SizedBox(
        width: 40,
        height: 40,
        child: IconButton(
          tooltip: '编辑目标',
          icon: const Icon(Icons.edit_rounded, size: 20),
          color: cs.onSurface,
          onPressed: onTap,
        ),
      ),
    );
  }
}

/// 今日目标半圆表盘（对齐参考版半环造型：背景弧 + 进度弧 + 底部缺口）
class _GoalDialPainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color progressColor;

  _GoalDialPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.72);
    final radius =
        (size.width < size.height ? size.width : size.height) * 0.62;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..color = progressColor;
    // 半圆：自左侧水平起顺时针扫 180°
    const startAngle = 3.141592653589793;
    const sweep = 3.141592653589793;
    canvas.drawArc(rect, startAngle, sweep, false, track);
    if (progress > 0) {
      canvas.drawArc(rect, startAngle, sweep * progress, false, arc);
    }
  }

  @override
  bool shouldRepaint(_GoalDialPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.progressColor != progressColor;
}
