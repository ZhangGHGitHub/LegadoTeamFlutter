import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/md3_heatmap_calendar.dart';
import 'read_record_daily_view.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/privacy/privacy_content_notifier.dart';
import '../providers/privacy/privacy_notifier.dart';
import '../providers/providers.dart';
import '../providers/read_record/read_record_notifier.dart';
import '../routes.dart';
import '../services/privacy_content_service.dart';
import '../utils/book_open_utils.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/md3_fast_scroller.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../utils/error_message.dart';
import '../widgets/pill_divider.dart';
import '../widgets/privacy/private_locked_cover.dart';

/// 阅读记录页（对齐原版 `ReadRecordActivity`）
///
/// 功能：总时长、可搜索书单、按书名/时长/最后阅读排序、
/// 启用记录开关、清空单本/全部；点击进阅读或搜索。
/// UI 仅渲染与交互；数据经 [ReadRecordNotifier] → BookApi。
/// — Auto + UI
class ReadRecordScreen extends ConsumerStatefulWidget {
  const ReadRecordScreen({super.key});

  @override
  ConsumerState<ReadRecordScreen> createState() => _ReadRecordScreenState();
}

class _ReadRecordScreenState extends ConsumerState<ReadRecordScreen> {
  // [UI_SYNC_REFACTOR R3] 快速滚动条控制器
  final ScrollController _listController = ScrollController();
  final _searchController = TextEditingController();

  /// 列表视图模式（0=按书 现状，1=按天 差异清单 C5）
  int _viewMode = 0;

  /// 每日时长数据（readRecordDailyList 既有契约；null=未加载）
  List<Map<String, dynamic>>? _daily;

  /// 加载每日时长（按天视图数据源；失败保持 null 走空态）
  Future<void> _loadDailyForView() async {
    try {
      final list = await ref
          .read(bookApiProvider)
          .readRecordDailyList(DateTime.now().year);
      if (!mounted) return;
      setState(() => _daily = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _daily = const []);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(readRecordNotifierProvider.notifier).load();
      // 按天视图数据（懒加载一次；切到按天时立即可用）
      _loadDailyForView();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readRecordNotifierProvider);
    final colorScheme = Theme.of(context).colorScheme;

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: TextField(
          controller: _searchController,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索',
            // [B3] 顶栏沉浸搜索框：三态显式无边框，防主题底线式渗入
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintStyle: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          style: Theme.of(context).textTheme.titleMedium,
          onChanged: (q) =>
              ref.read(readRecordNotifierProvider.notifier).setSearchQuery(q),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序与设置',
            onSelected: _onMenuSelected,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'sort_name',
                checked: state.sortMode == ReadRecordSortMode.name,
                child: const Text('按书名排序'),
              ),
              CheckedPopupMenuItem(
                value: 'sort_read_long',
                checked: state.sortMode == ReadRecordSortMode.readTime,
                child: const Text('按阅读时长'),
              ),
              CheckedPopupMenuItem(
                value: 'sort_last_read',
                checked: state.sortMode == ReadRecordSortMode.lastRead,
                child: const Text('按最后阅读'),
              ),
              const PillMenuDivider(),
              CheckedPopupMenuItem(
                value: 'enable_record',
                checked: state.enableRecord,
                child: const Text('启用阅读记录'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 差异清单 C5：累计成就卡（已读 N 本 / 累计 X）+ 清空入口
          ReadAchievementCard(
            readBooks: state.records.where((r) => r.readTime > 0).length,
            totalDurationText: formatDuring(state.totalReadTimeMs),
            onClearAll: state.records.isEmpty && state.totalReadTimeMs == 0
                ? null
                : () => _confirmClearAll(context),
          ),
          // 视图切换（按书=现状 / 按天=时间线）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('按书')),
                  ButtonSegment(value: 1, label: Text('按天')),
                ],
                selected: {_viewMode},
                onSelectionChanged: (sel) =>
                    setState(() => _viewMode = sel.first),
              ),
            ),
          ),
          // [LAYOUT_PLAN P3] 分隔线走 tonal 舍 outlineVariant（对齐 file_manage/offline_cache 样板）
          const Divider(height: 1, indent: 16, endIndent: 16),
          Expanded(
            child: _viewMode == 1
                ? ReadRecordDailyView(
                    daily: _daily,
                    formatSeconds: (sec) => formatDuring(sec * 1000),
                    onRetry: _loadDailyForView,
                  )
                : _buildBody(context, state),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, ReadRecordState state) {
    if (state.isLoading && state.records.isEmpty) {
      return const LoadingIndicator(message: '加载阅读记录...');
    }
    if (state.error != null && state.records.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(readRecordNotifierProvider.notifier).load(),
      );
    }
    if (state.records.isEmpty) {
      return EmptyState(
        icon: Symbols.history_rounded,
        title: state.searchQuery.isEmpty ? '暂无阅读记录' : '未找到匹配的记录',
      );
    }
    // [批9c] 私密且未获准的记录：书名/作者/时长/章节一律不渲染，
    // 只留模糊封面（时间保留）；反查不到书籍按非私密处理（fail-open）。
    final privacy = ref.watch(privacyNotifierProvider);
    final privacyContent = ref.watch(privacyContentProvider);
    // [LAYOUT_PLAN P4 收尾] 下拉 M3 化：裸 RefreshIndicator → CustomRefreshIndicator
    // [UI_SYNC_REFACTOR R3] 千级记录快速滚动条
    return CustomRefreshIndicator(
      onRefresh: () => ref.read(readRecordNotifierProvider.notifier).load(),
      child: Md3FastScroller(
        controller: _listController,
        child: ListView.separated(
          controller: _listController,
          // [LAYOUT_PLAN P3] 页面水平边距 16dp；纵向留白 8dp
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: state.records.length + 1,
          separatorBuilder: (_, _) => const Divider(
            height: 1,
            // [LAYOUT_PLAN P3] 分隔线走 tonal 舍 outlineVariant（对齐 file_manage/offline_cache 样板）
            indent: 16,
            endIndent: 16,
          ),
          itemBuilder: (context, index) {
            // [阅读热力图] 默认收起的可选区块（用户授权新增，AGENTS 红线
            // 2026-08-29 口径）：时长模式 = readRecordDailyList（Rust 契约
            // 2026-08-29）；计数模式 = 记录 lastRead 落日去重
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                  title: Text(
                    '阅读热力图',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  subtitle: Text(
                    '近一年每日阅读情况',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  children: [_HeatmapSection(records: state.records)],
                ),
              );
            }
            final item = state.records[index - 1];
            final recordKey = _recordKeyOf(item);
            final locked = privacyContent.isRecordLocked(recordKey, privacy);
            final resolvedBook = privacyContent.findBookByNameAuthor(
              recordKey.name,
              recordKey.author,
            );
            // [审查 P2-3] 改名后记录仍持旧名：按别名锚回当前书籍时展示
            // 当前书名（用户自定义显示名优先，不覆盖）。
            final displayName = locked
                ? item.bookName
                : _displayNameOf(privacyContent, item);
            final lockedBook = locked ? resolvedBook : null;
            return _ReadRecordTile(
              item: item,
              displayName: displayName,
              lastReadText: _formatDate(item.lastRead),
              durationText: formatDuring(item.readTime),
              locked: locked,
              lockedCoverUrl:
                  lockedBook?.customCoverUrl ?? lockedBook?.coverUrl,
              onTap: () => _openRecord(context, item),
              onClear: () => _confirmDelete(context, item),
            );
          },
        ),
      ),
    );
  }

  /// 记录的脱敏反查键（物理书名优先；历史行物理名缺失时回退展示名）
  static PrivacyRecordKey _recordKeyOf(ReadRecordShow item) => PrivacyRecordKey(
    item.physicalBookName.isNotEmpty ? item.physicalBookName : item.bookName,
    item.author,
  );

  /// [审查 P2-3] 改名后按别名锚回当前书籍
  ///
  /// 仅当记录未使用自定义显示名（`bookName == physicalBookName`）时生效：
  /// 用户显式编辑过的显示名优先，不被当前书名覆盖。
  static Book? _resolveRenamedBook(
    PrivacyContentSnapshot content,
    ReadRecordShow item,
  ) {
    final physical = item.physicalBookName.isNotEmpty
        ? item.physicalBookName
        : item.bookName;
    if (physical != item.bookName) return null;
    return content.findBookByNameAuthor(physical, item.author);
  }

  /// 列表/删除确认/搜索关键词共用的展示书名
  ///
  /// 改名后旧记录显示当前书名（审查 P2-3）；反查不到时保持库内展示值。
  static String _displayNameOf(
    PrivacyContentSnapshot content,
    ReadRecordShow item,
  ) {
    final book = _resolveRenamedBook(content, item);
    if (book != null && book.name.trim().isNotEmpty) return book.name;
    return item.bookName;
  }

  Future<void> _onMenuSelected(String value) async {
    final notifier = ref.read(readRecordNotifierProvider.notifier);
    switch (value) {
      case 'sort_name':
        await notifier.setSortMode(ReadRecordSortMode.name);
      case 'sort_read_long':
        await notifier.setSortMode(ReadRecordSortMode.readTime);
      case 'sort_last_read':
        await notifier.setSortMode(ReadRecordSortMode.lastRead);
      case 'enable_record':
        await notifier.toggleEnableRecord();
    }
  }

  Future<void> _openRecord(BuildContext context, ReadRecordShow item) async {
    final notifier = ref.read(readRecordNotifierProvider.notifier);
    // v113：记录按显示名/作者聚合，打开书籍须用物理书名定位书架
    final physicalName = item.physicalBookName.isNotEmpty
        ? item.physicalBookName
        : item.bookName;
    // [审查 P2-3 兜底] 跳转前隐私校验（fail-closed）：先等策略/标记就绪，
    // 再按物理名与显示名各查一次。未授权的私密记录既不打开书籍，也绝不把
    // 书名作为关键词发给第三方书源搜索（锁定行虽已禁用 onTap，此处兜住
    // 「列表渲染后标记才生效/状态滞后」的窗口）。
    await ref.read(privacyNotifierProvider.notifier).ensureLoaded();
    final privacyContent = await ref
        .read(privacyContentProvider.notifier)
        .ensureLoaded();
    final privacy = ref.read(privacyNotifierProvider);
    final locked =
        privacyContent.isRecordLocked(
          PrivacyRecordKey(physicalName, item.author),
          privacy,
        ) ||
        privacyContent.isRecordLocked(
          PrivacyRecordKey(item.bookName, item.author),
          privacy,
        );
    if (locked) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('该书为私密内容，请先在书架解锁后再打开')));
      return;
    }
    final book =
        await notifier.findBookByName(physicalName) ??
        // [审查 P2-3] 已改名：按别名锚回当前书籍，避免落进「书架无书」
        // 分支把旧书名带进第三方搜索。
        privacyContent.findBookByNameAuthor(physicalName, item.author) ??
        (item.bookName == physicalName
            ? null
            : privacyContent.findBookByNameAuthor(item.bookName, item.author));
    if (!context.mounted) return;
    if (book == null) {
      // 对齐原版：书架无书 → 带书名打开搜索
      // [设置批2b-2b P1-3] 阅读记录可位于「我的」容器 nested Navigator 内，
      // 搜索必须打开在根导航（全屏），不能关进右栏/My 页签。
      // [审查 P2-3] 关键词取别名解析后的当前书名（非私密才可达此分支）。
      await Navigator.of(context, rootNavigator: true).pushNamed(
        AppRoutes.search,
        arguments: _displayNameOf(privacyContent, item),
      );
      return;
    }
    await _openBook(context, book);
  }

  /// 对齐原版 startActivityForBook（分流编排统一在 BookOpenUtils.openBook）
  ///
  /// [设置批2b-2b P1-3] 阅读记录在「我的」容器 nested Navigator 内时，
  /// 阅读器/书详必须走根导航；[BookOpenUtils.openBook] 的
  /// `useGlobalNavigator` 经 `PlatformBridgeService.navigatorKey` 落根栈。
  Future<void> _openBook(BuildContext context, Book book) async {
    await BookOpenUtils.openBook(context, ref, book, useGlobalNavigator: true);
  }

  Future<void> _confirmDelete(BuildContext context, ReadRecordShow item) async {
    // [批9c 回修 P1-1] 锁定态删除确认文案不得出现真实书名
    final privacy = ref.read(privacyNotifierProvider);
    final privacyContent = ref.read(privacyContentProvider);
    final physicalName = item.physicalBookName.isNotEmpty
        ? item.physicalBookName
        : item.bookName;
    final locked =
        privacyContent.isRecordLocked(
          PrivacyRecordKey(physicalName, item.author),
          privacy,
        ) ||
        // 显示名被用户改过时物理名反查会失败；再用显示名兜底，避免 fail-open
        // 在锁定态露出真实显示书名。
        privacyContent.isRecordLocked(
          PrivacyRecordKey(item.bookName, item.author),
          privacy,
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        // [批27b P2-2] FFI 按物理书名删除该书**全部作者**的记录（契约 §2.12），
        // 文案须明示范围，避免用户误以为只删当前作者行
        content: Text(
          locked
              ? '将删除本书全部作者的阅读记录，确定吗？'
              // [审查 P2-3] 改名后展示当前书名（物理旧名不外露）
              : '将删除「${_displayNameOf(privacyContent, item)}」该书全部作者的阅读记录，确定吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      // v113：FFI 按物理书名删除该书全部作者记录（契约 §2.12）
      final success = await ref
          .read(readRecordNotifierProvider.notifier)
          .deleteByName(physicalName);
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '已删除阅读记录'
                  : '删除失败：${ref.read(readRecordNotifierProvider).error ?? '未知错误'}',
            ),
          ),
        );
    }
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: const Text('确定删除全部阅读记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await ref.read(readRecordNotifierProvider.notifier).clearAll();
    }
  }
}

/// 时长格式化（对齐原版 formatDuring，单位毫秒）
String formatDuring(int mss) {
  if (mss <= 0) return '0秒';
  final days = mss ~/ (1000 * 60 * 60 * 24);
  final hours = (mss % (1000 * 60 * 60 * 24)) ~/ (1000 * 60 * 60);
  final minutes = (mss % (1000 * 60 * 60)) ~/ (1000 * 60);
  final seconds = (mss % (1000 * 60)) ~/ 1000;
  final buf = StringBuffer();
  if (days > 0) buf.write('$days天');
  if (hours > 0) buf.write('$hours小时');
  if (minutes > 0) buf.write('$minutes分钟');
  if (seconds > 0) buf.write('$seconds秒');
  final time = buf.toString();
  return time.isEmpty ? '0秒' : time;
}

class _ReadRecordTile extends StatelessWidget {
  final ReadRecordShow item;

  /// [审查 P2-3] 展示书名：改名后由别名解析为当前书名（用户自定义显示名除外）
  final String displayName;
  final String durationText;
  final String lastReadText;
  final VoidCallback onTap;
  final VoidCallback onClear;

  /// [批9c] 私密且未获准：不渲染书名/作者/时长，只留模糊封面与时间
  final bool locked;
  final String? lockedCoverUrl;

  const _ReadRecordTile({
    required this.item,
    required this.displayName,
    required this.durationText,
    required this.lastReadText,
    required this.onTap,
    required this.onClear,
    this.locked = false,
    this.lockedCoverUrl,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final secondary = colorScheme.onSurfaceVariant;
    if (locked) {
      // 脱敏行：读屏也不给（描述里拼的正是书名/章节）；时间不是身份信息，保留
      return Semantics(
        container: true,
        child: ExcludeSemantics(
          child: InkWell(
            key: const ValueKey('readRecordLockedTile'),
            // P2 复审：锁定行不得经 onTap 打开书籍/跳搜索（书名会经搜索框
            // 自动填入而泄漏）；删除入口保留在右侧「清空」。
            onTap: null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  PrivateLockedCover(
                    width: 40,
                    height: 56,
                    coverUrl: lockedCoverUrl,
                    bookName: item.bookName,
                    bookAuthor: item.author,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 原书名列/作者列/时长列全部不渲染
                        const SizedBox(height: 18),
                        if (lastReadText.isNotEmpty)
                          Text(
                            '最后阅读：$lastReadText',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: secondary),
                          ),
                      ],
                    ),
                  ),
                  TextButton(onPressed: onClear, child: const Text('清空')),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  // v113：展示作者（displayAuthor 优先，空回退物理作者）
                  if (item.author.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: secondary),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '阅读时长：$durationText',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: secondary),
                  ),
                  if (lastReadText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '最后阅读：$lastReadText',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: secondary),
                    ),
                  ],
                ],
              ),
            ),
            TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
      ),
    );
  }
}

/// 热力图区块：懒加载每日时长（readRecordDailyList）+ 时长/本数双模式切换
class _HeatmapSection extends ConsumerStatefulWidget {
  final List<ReadRecordShow> records;

  const _HeatmapSection({required this.records});

  @override
  ConsumerState<_HeatmapSection> createState() => _HeatmapSectionState();
}

class _HeatmapSectionState extends ConsumerState<_HeatmapSection> {
  Md3HeatmapMode _mode = Md3HeatmapMode.duration;
  Map<DateTime, int>? _dailySeconds;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDaily();
  }

  Future<void> _loadDaily() async {
    try {
      final list = await ref
          .read(bookApiProvider)
          .readRecordDailyList(DateTime.now().year);
      if (!mounted) return;
      final map = <DateTime, int>{};
      for (final e in list) {
        final date = (e['date'] ?? '').toString();
        final seconds = (e['seconds'] as num?)?.toInt() ?? 0;
        if (date.isEmpty) continue;
        final parts = date.split('-');
        if (parts.length != 3) continue;
        map[DateTime(
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2]),
            )] =
            seconds;
      }
      setState(() => _dailySeconds = map);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dailyCounts = Md3HeatmapCalendar.aggregateDailyBookCount(
      widget.records.map((r) => (bookName: r.bookName, lastRead: r.lastRead)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<Md3HeatmapMode>(
          segments: const [
            ButtonSegment(
              value: Md3HeatmapMode.duration,
              label: Text('按时长'),
              icon: Icon(Symbols.timer_rounded, size: 16),
            ),
            ButtonSegment(
              value: Md3HeatmapMode.count,
              label: Text('按本数'),
              icon: Icon(Symbols.menu_book_rounded, size: 16),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (selection) =>
              setState(() => _mode = selection.first),
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Text(
            '每日时长加载失败：$_error',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          )
        else
          Md3HeatmapCalendar(
            dailySeconds: _dailySeconds ?? const {},
            dailyCounts: dailyCounts,
            mode: _dailySeconds == null && _mode == Md3HeatmapMode.duration
                ? Md3HeatmapMode.count
                : _mode,
            endDate: DateTime.now(),
          ),
      ],
    );
  }
}
