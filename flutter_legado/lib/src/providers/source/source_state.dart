import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';
import '../../services/source_import_service.dart';

part 'source_state.freezed.dart';

/// 书源排序方式（对标 Android `BookSourceSort`）
enum SourceSort {
  /// 手动排序（按 customOrder，原版 Default）
  manual,

  /// 自动排序（按权重 weight，原版 Weight）
  weight,

  /// 按名称
  name,

  /// 按 URL
  url,

  /// 按更新时间（lastUpdateTime）
  update,

  /// 按启用状态（enabled）
  enable,

  /// 按响应时间（respondTime）
  respond,
}

/// 书源管理 UI 状态（immutable）
///
/// 职责边界（对标 Android BookSourceActivity）：
/// - [sources]：全部书源列表
/// - [loading] / [error]：API 调用状态
/// - [filterKeyword]：搜索过滤关键词
/// - [selectedGroup]：分组筛选（null = 全部）
/// - [sort] / [sortAscending]：排序方式与方向
/// - [batchMode] / [selectedUrls]：批量选择模式
/// - [lastImportResult]：最近一次导入结果
@freezed
class SourceState with _$SourceState {
  const factory SourceState({
    /// 全部书源列表
    @Default([]) List<BookSource> sources,

    /// 是否正在加载
    @Default(false) bool loading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 搜索过滤关键词
    @Default('') String filterKeyword,

    /// 选中分组（null = 全部）
    String? selectedGroup,

    /// 排序方式
    @Default(SourceSort.manual) SourceSort sort,

    /// 是否升序
    @Default(true) bool sortAscending,

    /// 是否处于批量选择模式
    @Default(false) bool batchMode,

    /// 批量选中的书源 URL 集合
    @Default(<String>{}) Set<String> selectedUrls,

    /// 最近一次导入结果
    ImportResult? lastImportResult,
  }) = _SourceState;
}

/// 书源管理展示扩展 —— 纯展示层变换，不改变数据内容
extension SourceStateFiltering on SourceState {
  /// 所有分组名称列表
  List<String> get groups {
    final set = <String>{};
    for (final source in sources) {
      set.add(source.bookSourceGroup ?? '未分组');
    }
    return set.toList()..sort();
  }

  /// 已启用书源（经分组过滤 + 排序）
  List<BookSource> get enabledSources => _applyGroupFilter(
        sources.where((s) => s.enabled).toList(),
      );

  /// 已禁用书源（经分组过滤 + 排序）
  List<BookSource> get disabledSources => _applyGroupFilter(
        sources.where((s) => !s.enabled).toList(),
      );

  /// 过滤后的书源列表（关键词 + 分组 + 排序）
  List<BookSource> get filteredSources {
    var list = sources;
    if (filterKeyword.isNotEmpty) {
      final kw = filterKeyword.toLowerCase();
      list = list.where((s) {
        return s.bookSourceName.toLowerCase().contains(kw) ||
            (s.bookSourceGroup?.toLowerCase().contains(kw) ?? false) ||
            s.bookSourceUrl.toLowerCase().contains(kw);
      }).toList();
    }
    return _applyGroupFilter(list);
  }

  /// 按分组归类（基于 filteredSources）
  Map<String, List<BookSource>> get groupedSources {
    final map = <String, List<BookSource>>{};
    for (final source in filteredSources) {
      final group = source.bookSourceGroup ?? '未分组';
      map.putIfAbsent(group, () => []).add(source);
    }
    return map;
  }

  /// 判断书源是否被选中
  bool isSelected(String sourceUrl) => selectedUrls.contains(sourceUrl);

  /// 选中数量
  int get selectedCount => selectedUrls.length;

  /// 是否全选
  bool get isAllSelected {
    final filtered = filteredSources;
    if (filtered.isEmpty) return false;
    return filtered.every((s) => selectedUrls.contains(s.bookSourceUrl));
  }

  // ─── 内部辅助 ───────────────────────────────────────

  List<BookSource> _applyGroupFilter(List<BookSource> list) {
    final filtered = selectedGroup == null
        ? list
        : list.where((s) {
            final group = s.bookSourceGroup ?? '未分组';
            return group == selectedGroup;
          }).toList();
    return _applySort(filtered);
  }

  /// 按当前 [sort]/[sortAscending] 排序（对标 Android upBookSource 排序逻辑）
  List<BookSource> _applySort(List<BookSource> list) {
    final result = List<BookSource>.of(list);
    result.sort(_comparator);
    return result;
  }

  int _comparator(BookSource a, BookSource b) {
    int result;
    switch (sort) {
      case SourceSort.manual:
        result = a.customOrder.compareTo(b.customOrder);
        break;
      case SourceSort.weight:
        result = b.weight.compareTo(a.weight); // 默认权重高优先
        break;
      case SourceSort.name:
        result = a.bookSourceName.compareTo(b.bookSourceName);
        break;
      case SourceSort.url:
        result = a.bookSourceUrl.compareTo(b.bookSourceUrl);
        break;
      case SourceSort.update:
        result = b.lastUpdateTime.compareTo(a.lastUpdateTime); // 默认新优先
        break;
      case SourceSort.enable:
        result = (b.enabled ? 1 : 0).compareTo(a.enabled ? 1 : 0); // 默认启用优先
        break;
      case SourceSort.respond:
        result = a.respondTime.compareTo(b.respondTime); // 默认快优先
        break;
    }
    if (!sortAscending) result = -result;
    if (result != 0) return result;
    // 稳定次序：按 URL 兑底
    return a.bookSourceUrl.compareTo(b.bookSourceUrl);
  }
}
