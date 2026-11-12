import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';
import '../../providers/privacy/privacy_state.dart';
import '../../utils/book_display_tags.dart';
import '../../utils/book_group_match.dart';

// [批9c] 分组匹配工具抽至 utils/book_group_match.dart（隐私判定共用），
// 继续 re-export，既有 `import bookshelf_state.dart` 的调用方无需改动。
export '../../utils/book_group_match.dart';

part 'bookshelf_state.freezed.dart';

/// 书架分组模式 —— 纯展示层概念，仅决定 UI 如何分块显示
enum GroupMode { none, bySource, byGroup }

/// 书籍分组特殊 ID（对标 Kotlin BookGroup companion object）
class BookGroupId {
  static const int all = -1; // 全部
  static const int local = -2; // 本地
  static const int audio = -3; // 音频
  static const int netNone = -4; // 网络未分组
  static const int localNone = -5; // 本地未分组
  static const int video = -6; // 视频
}

/// 书架 UI 状态（immutable）
///
/// 职责边界说明（对齐 UI_RESTRUCTURE_PLAN.md §0.3）：
/// - [books]：Rust API 返回的原始数据，Notifier 不做业务处理；
///   展示层排序见 `utils/bookshelf_sort.dart`（设置批6a-1）
/// - [isLoading] / [error]：API 调用状态
/// - [groupMode]：展示层变换（溢出菜单的「不分组/按来源/按分组」）
///
/// [设置批6a-1] 网格/列表与显示标签总开关迁移至
/// `BookshelfSettings`（参考版同名设置面板），本状态不再保存布局偏好。
@freezed
class BookshelfState with _$BookshelfState {
  const factory BookshelfState({
    /// Rust 返回的书籍列表（原始顺序；展示层按设置排序）
    @Default([]) List<Book> books,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 展示层：分组显示模式
    @Default(GroupMode.none) GroupMode groupMode,

    /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
    @Default([]) List<BookGroup> groups,

    /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
    @Default(0) int selectedGroupIndex,

    /// [UI_SYNC_REFACTOR T3] 批量选择模式（对齐参考 SelectionBottomBar 态）
    @Default(false) bool isBatchMode,

    /// 批量选中的书籍 URL 集合
    @Default({}) Set<String> selectedUrls,

    /// [批35] 标签内容 - 用户标签（`Book.customTag`）
    @Default(true) bool showCustomTags,

    /// [批35] 标签内容 - 书源分类（`Book.kind`）
    @Default(true) bool showSourceTags,

    /// [批35] 标签内容 - 字数（`Book.wordCount`）
    @Default(true) bool showWordCount,

    /// [批9c] 单本私密 URL 快照（`privacyGetPrivateBookUrls`）
    ///
    /// 与 `Book.isPrivate` 取并集判定：列表接口可能滞后于刚写入的标记，
    /// 隐私服务快照是私密判定的真源（Rust 侧同库同事务）。
    @Default(<String>{}) Set<String> privateBookUrls,

    /// [批9c] 私密分组 ID 快照（`privacyGetPrivateGroupIds`）
    @Default(<int>{}) Set<int> privateGroupIds,

    /// [批9c] 私密标记是否已加载完成
    ///
    /// false 时书架先不渲染锁定态（列表与标记并行加载，避免闪烁）；
    /// 加载失败按「未锁定」处理，不误锁整库（见 PrivacyContentService）。
    @Default(false) bool privacyLoaded,

    /// 书架内搜索过滤模式（对齐参考版 `BookshelfUiState.isSearch`）
    ///
    /// 开启时顶栏下方出现过滤输入条，当前分组列表按 [filterQuery] 实时筛选；
    /// 关闭时 [filterQuery] 一并清空（对齐参考版 `setSearchMode(false)`）。
    @Default(false) bool isFilterMode,

    /// 书架内搜索过滤关键词（本地展示层过滤，不触发数据请求）
    @Default('') String filterQuery,
  }) = _BookshelfState;
}

/// 分组展示扩展 —— 纯展示层变换，不改变数据内容
extension BookshelfStateGrouping on BookshelfState {
  /// 书籍是否为空且不在加载中
  bool get isEmpty => currentGroupBooks.isEmpty && !isLoading;

  /// 是否存在多个分组 Tab（对标原版：多分组时顶栏显示 TabLayout）
  bool get hasGroupTabs => groups.length > 1;

  /// [批35] 某本书在当前标签开关下的展示标签（总开关关闭 → 空）
  ///
  /// 纯展示层计算（对齐参考版 `BookShelfItem.getDisplayTags`）：不改
  /// `Book` 数据，空值/空白项不产生标签；书卡与列表行共用此入口。
  ///
  /// [设置批6a-1] 总开关改由 `BookshelfSettings.bookshelfShowTag` 传入
  /// （书架页 watch 设置后调用），本扩展不再保存重复的 `showTag` 字段。
  List<String> displayTagsOf(Book book, {bool showTag = true}) {
    if (!showTag) return const [];
    return bookDisplayTags(
      book,
      showCustomTags: showCustomTags,
      showSourceTags: showSourceTags,
      showWordCount: showWordCount,
    );
  }

  /// 当前选中分组
  BookGroup? get selectedGroup => groups.isEmpty
      ? null
      : groups[selectedGroupIndex.clamp(0, groups.length - 1)];

  /// [批9c] 该分组是否为私密分组
  bool isGroupPrivate(int groupId) => privateGroupIds.contains(groupId);

  /// [批9c] 书籍是否属于任一私密分组
  ///
  /// 复用 [bookBelongsToCustomGroup]（2^n 位掩码 / 旧时间戳 exact），
  /// 不做裸位与：旧时间戳书籍的低位 bit 不能误命中新 2^n 分组。
  bool isBookInPrivateGroup(Book book) =>
      privateGroupIds.any((gid) => bookBelongsToCustomGroup(book, gid));

  /// [批9c] 书籍是否为私密内容（单本标记 ∪ 私密分组）
  ///
  /// 单本标记取 `Book.isPrivate` 与隐私服务快照的并集：快照覆盖批量
  /// 写入后列表尚未刷新的窗口。
  bool isBookPrivateContent(Book book) =>
      book.isPrivate ||
      privateBookUrls.contains(book.bookUrl) ||
      isBookInPrivateGroup(book);

  /// [批9c] 书籍此刻是否应脱敏
  ///
  /// 与详情页/阅读闸门共用 [PrivacyState.isBookLocked] 同一套授权语义：
  /// 总开关关闭或关闭「打开书籍时验证」时不脱敏；EveryTime 下仅刚验证过
  /// 的目标（或已授权分组）放行。
  bool isBookContentLocked(Book book, PrivacyState privacy) =>
      privacyLoaded &&
      privacy.isBookLocked(book, isPrivate: isBookPrivateContent(book));

  /// [批9c] 分组内容区是否应整页锁定
  bool isGroupContentLocked(int groupId, PrivacyState privacy) =>
      privacyLoaded &&
      privacy.isGroupContentLocked(groupId, isPrivate: isGroupPrivate(groupId));

  /// UI 消费别名（对齐参考版 `BookshelfUiState.isGroupLocked`）
  bool isGroupLocked(int groupId, PrivacyState privacy) =>
      isGroupContentLocked(groupId, privacy);

  /// 分组内书籍（[group] 为空 = 全部）
  ///
  /// [设置批6a-1] 从 [currentGroupBooks] 抽出，供「隐藏空分组」计数与
  /// 组菜单切换复用；语义与原 switch 完全一致。
  ///
  /// [批9c] 公开视图剔除私密分组书（对齐参考版 SQL `PUBLIC_BOOK_FILTER`：
  /// `group=0 or group & privateMask = 0`）：「全部/本地/音频/视频/未关联」
  /// 与普通自定义分组都看不到私密组书；私密分组自己的 Tab 保留全部组内书，
  /// 由 UI 渲染整页锁定。
  List<Book> booksInGroup(BookGroup? group) {
    if (groups.isEmpty || group == null) {
      return books.where((b) => !isBookInPrivateGroup(b)).toList();
    }
    final groupId = group.groupId;
    if (groupId == BookGroupId.all) {
      return books.where((b) => !isBookInPrivateGroup(b)).toList();
    }
    switch (groupId) {
      case BookGroupId.local:
        return books
            .where((b) => _isLocal(b) && !isBookInPrivateGroup(b))
            .toList();
      case BookGroupId.audio:
        // [UI-fix v2.0.11] bookType 为位标记，用位运算判定（对齐原版 isAudio）— Reasonix
        return books
            .where(
              (b) =>
                  (b.bookType & BookType.audio) != 0 &&
                  !isBookInPrivateGroup(b),
            )
            .toList();
      case BookGroupId.video:
        return books
            .where(
              (b) =>
                  (b.bookType & BookType.video) != 0 &&
                  !isBookInPrivateGroup(b),
            )
            .toList();
      case BookGroupId.netNone:
        return books
            .where(
              (b) => !_isLocal(b) && b.group == 0 && !isBookInPrivateGroup(b),
            )
            .toList();
      case BookGroupId.localNone:
        return books
            .where(
              (b) => _isLocal(b) && b.group == 0 && !isBookInPrivateGroup(b),
            )
            .toList();
      default:
        // 自定义分组：2^n 按位掩码，旧时间戳/任意 ID 按 exact 兼容。
        // 私密分组自己的 Tab 保留全部组内书（内容区整页锁定）。
        final groupPrivate = isGroupPrivate(groupId);
        return books
            .where(
              (b) =>
                  bookBelongsToCustomGroup(b, groupId) &&
                  (groupPrivate || !isBookInPrivateGroup(b)),
            )
            .toList();
    }
  }

  /// 当前分组 Tab 下的书籍（纯展示层过滤，对标原版 BooksFragment 按 groupId 查询）
  List<Book> get currentGroupBooks => booksInGroup(selectedGroup);

  /// 书架内过滤是否实际生效（模式开 + 关键词非空白）
  bool get isFiltering => isFilterMode && filterQuery.trim().isNotEmpty;

  /// 按书架内搜索关键词过滤（对齐参考版 `filterBooks` / `matchesSearchKey`：
  /// 书名/作者/来源名/分类/自定义标签，大小写不敏感）。
  ///
  /// [exclude] 供 UI 传入「私密且未授权」判定：过滤态下先剔除锁定书再匹配，
  /// 否则「能否搜到书名」本身即泄露私密内容（对齐参考版
  /// `hidePrivateFromSearch`）。未过滤/空关键词原样返回。
  List<Book> filterBooks(
    List<Book> source, {
    bool Function(Book book)? exclude,
  }) {
    final query = filterQuery.trim().toLowerCase();
    if (!isFilterMode || query.isEmpty) return source;
    return source
        .where((book) => exclude == null || !exclude(book))
        .where((book) => _matchesFilter(book, query))
        .toList();
  }

  /// 单本书是否命中过滤关键词（参考版同口径：五个字段任一包含即命中）
  static bool _matchesFilter(Book book, String lowerQuery) {
    bool hit(String? value) =>
        value != null && value.toLowerCase().contains(lowerQuery);
    return hit(book.name) ||
        hit(book.author) ||
        hit(book.originName) ||
        hit(book.kind) ||
        hit(book.customTag);
  }

  /// 隐藏空分组后的可见分组列表（「全部」始终保留，空书架保留空态骨架）
  ///
  /// [设置批6a-1] 对齐参考版 `hideEmptyGroups`：只影响顶部 Tab/组菜单，
  /// 不改数据源；选中组被隐藏时由调用方回退索引 0。
  List<BookGroup> visibleGroups({bool hideEmpty = true}) {
    if (groups.isEmpty) {
      return const [BookGroup(groupId: BookGroupId.all, groupName: '全部')];
    }
    if (!hideEmpty) return groups;
    final visible = groups
        .where(
          (g) => g.groupId == BookGroupId.all || booksInGroup(g).isNotEmpty,
        )
        .toList();
    return visible.isEmpty
        ? const [BookGroup(groupId: BookGroupId.all, groupName: '全部')]
        : visible;
  }

  /// 指定分组书籍数（对齐参考版 showBookCount 计数口径）
  int bookCountOf(BookGroup group) => booksInGroup(group).length;

  /// 本地书判定（对齐 Kotlin `Book.isLocal`：type == 0 时看 origin，
  /// 否则看 local 位；WebDAV origin 新 `webDav::` 与存量 `dav:` 均识别）
  bool _isLocal(Book b) => BookType.isLocalBook(b);

  /// 分组后的书籍，用于展示分组头
  ///
  /// 仅改变呈现形式（按来源/分组分块显示），不改变数据本身
  Map<String, List<Book>> get groupedBooks => groupedBooksOf(currentGroupBooks);

  /// 对指定书籍列表分组（[设置批6a-1] 供排序后的可见列表复用）
  Map<String, List<Book>> groupedBooksOf(List<Book> source) {
    if (groupMode == GroupMode.none) {
      return {'全部': source};
    }
    final map = <String, List<Book>>{};
    for (final book in source) {
      final key = _getGroupKey(book);
      map.putIfAbsent(key, () => []).add(book);
    }
    return map;
  }

  String _getGroupKey(Book book) {
    switch (groupMode) {
      case GroupMode.bySource:
        return book.originName.isNotEmpty ? book.originName : '本地';
      case GroupMode.byGroup:
        // 展示组名而不是 groupId 数字：位掩码可能命中多个组，按组顺序
        // 「、」连接；无匹配组名时回落「分组」，未分组回落「默认」。
        final names = bookGroupNames(book, groups);
        if (names.isNotEmpty) return names.join('、');
        return book.group > 0 ? '分组' : '默认';
      default:
        return '全部';
    }
  }
}
