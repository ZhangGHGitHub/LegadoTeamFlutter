import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

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
/// - [books]：Rust API 返回的原始数据（已排序），Notifier 不做任何业务处理
/// - [isLoading] / [error]：API 调用状态
/// - [isGridView] / [groupMode]：展示层变换，仅改变呈现形式
/// - [showRecentReading] / [showStats]：用户偏好开关，持久化到 SharedPreferences
@freezed
class BookshelfState with _$BookshelfState {
  const factory BookshelfState({
    /// Rust 返回的书籍列表（已排序，UI 层不做排序）
    @Default([]) List<Book> books,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 展示层：网格/列表视图模式
    @Default(true) bool isGridView,

    /// 展示层：分组显示模式
    @Default(GroupMode.none) GroupMode groupMode,

    /// 用户偏好：是否显示最近阅读区域
    @Default(true) bool showRecentReading,

    /// 用户偏好：是否显示阅读统计
    @Default(true) bool showStats,

    /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
    @Default([]) List<BookGroup> groups,

    /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
    @Default(0) int selectedGroupIndex,
  }) = _BookshelfState;
}

/// 分组展示扩展 —— 纯展示层变换，不改变数据内容
extension BookshelfStateGrouping on BookshelfState {
  /// 书籍是否为空且不在加载中
  bool get isEmpty => currentGroupBooks.isEmpty && !isLoading;

  /// 是否存在多个分组 Tab（对标原版：多分组时顶栏显示 TabLayout）
  bool get hasGroupTabs => groups.length > 1;

  /// 当前选中分组
  BookGroup? get selectedGroup =>
      groups.isEmpty ? null : groups[selectedGroupIndex.clamp(0, groups.length - 1)];

  /// 当前分组 Tab 下的书籍（纯展示层过滤，对标原版 BooksFragment 按 groupId 查询）
  List<Book> get currentGroupBooks {
    if (!hasGroupTabs) return books;
    final groupId = selectedGroup?.groupId;
    if (groupId == null || groupId == BookGroupId.all) return books;
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
        // 自定义分组：book.group 为位掩码，包含该分组位即属于该组
        return books.where((b) => b.group & groupId != 0).toList();
    }
  }

  bool _isLocal(Book b) =>
      b.origin == BookType.localTag || (b.bookType & BookType.local) != 0;

  /// 分组后的书籍，用于展示分组头
  ///
  /// 仅改变呈现形式（按来源/分组分块显示），不改变数据本身
  Map<String, List<Book>> get groupedBooks {
    final source = currentGroupBooks;
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
        return book.group > 0 ? '分组 ${book.group}' : '默认';
      default:
        return '全部';
    }
  }
}
