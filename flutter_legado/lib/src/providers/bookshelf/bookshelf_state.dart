import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';
import '../../utils/book_display_tags.dart';

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

/// 新分组位上限（Rust `get_unused_id` 同口径）：1<<30
const int kMaxCustomGroupBit = 1 << 30;

/// 新分组位掩码最大组合值（1<<30 及以下所有位全开）
const int kMaxCustomGroupMask = (1 << 31) - 1;

/// 是否为 2 的幂（1,2,4,…；0/负数返回 false）
bool isPowerOfTwoGroupId(int groupId) =>
    groupId > 0 && (groupId & (groupId - 1)) == 0;

/// 书籍是否属于自定义分组（混合语义，2026-11-06 设备修复）
///
/// - [groupId] 为 2 的幂（新分组）→ `book.group` 位掩码匹配；
/// - [groupId] 为非 2 的幂（旧时间戳/任意 ID）→ `book.group == groupId`；
/// - `book.group` 仍是旧时间戳（> 位掩码最大值）→ 只做 exact 匹配，
///   避免旧书的低位 bit 误命中新 2^n 分组；
/// - `groupId <= 0`（特殊组）不走本 helper。
bool bookBelongsToCustomGroup(Book book, int groupId) {
  if (groupId <= 0) return false;
  if (!isPowerOfTwoGroupId(groupId)) {
    return book.group == groupId;
  }
  // 旧时间戳/任意超大值不是位掩码，只按 exact 兼容
  if (book.group <= 0 || book.group > kMaxCustomGroupMask) {
    return book.group == groupId;
  }
  return (book.group & groupId) != 0;
}

/// 分组分配后的新 `books.group` 值
///
/// - 新 2^n 组：旧位掩码值 OR 新位（保留其它组）；
/// - 旧时间戳组/书籍仍为旧时间戳值：整体改为该组（旧值不做位运算）；
int nextGroupMaskOnAssign(Book book, int groupId) {
  if (groupId <= 0) return book.group;
  if (!isPowerOfTwoGroupId(groupId) ||
      book.group < 0 ||
      book.group > kMaxCustomGroupMask) {
    return groupId;
  }
  return book.group | groupId;
}

/// 从分组移除后的新 `books.group` 值
///
/// - 新 2^n 组：清对应位，保留其它组；
/// - 旧时间戳组：仅当 exact 命中时清 0（不做位运算）；
int nextGroupMaskOnRemove(Book book, int groupId) {
  if (groupId <= 0) return book.group;
  if (!isPowerOfTwoGroupId(groupId)) {
    return book.group == groupId ? 0 : book.group;
  }
  if (book.group < 0 || book.group > kMaxCustomGroupMask) {
    return book.group;
  }
  return book.group & ~groupId;
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
  BookGroup? get selectedGroup =>
      groups.isEmpty ? null : groups[selectedGroupIndex.clamp(0, groups.length - 1)];

  /// 分组内书籍（[group] 为空 = 全部）
  ///
  /// [设置批6a-1] 从 [currentGroupBooks] 抽出，供「隐藏空分组」计数与
  /// 组菜单切换复用；语义与原 switch 完全一致。
  List<Book> booksInGroup(BookGroup? group) {
    if (groups.isEmpty || group == null) return books;
    final groupId = group.groupId;
    if (groupId == BookGroupId.all) return books;
    switch (groupId) {
      case BookGroupId.local:
        return books.where((b) => _isLocal(b)).toList();
      case BookGroupId.audio:
        // [UI-fix v2.0.11] bookType 为位标记，用位运算判定（对齐原版 isAudio）— Reasonix
        return books.where((b) => (b.bookType & BookType.audio) != 0).toList();
      case BookGroupId.video:
        return books.where((b) => (b.bookType & BookType.video) != 0).toList();
      case BookGroupId.netNone:
        return books.where((b) => !_isLocal(b) && b.group == 0).toList();
      case BookGroupId.localNone:
        return books.where((b) => _isLocal(b) && b.group == 0).toList();
      default:
        // 自定义分组：2^n 按位掩码，旧时间戳/任意 ID 按 exact 兼容
        return books
            .where((b) => bookBelongsToCustomGroup(b, groupId))
            .toList();
    }
  }

  /// 当前分组 Tab 下的书籍（纯展示层过滤，对标原版 BooksFragment 按 groupId 查询）
  List<Book> get currentGroupBooks => booksInGroup(selectedGroup);

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
        .where((g) =>
            g.groupId == BookGroupId.all || booksInGroup(g).isNotEmpty)
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
        final names = <String>[
          for (final group in groups)
            if (group.groupId > 0 &&
                bookBelongsToCustomGroup(book, group.groupId) &&
                group.groupName.trim().isNotEmpty)
              group.groupName.trim(),
        ];
        if (names.isNotEmpty) return names.join('、');
        return book.group > 0 ? '分组' : '默认';
      default:
        return '全部';
    }
  }
}
