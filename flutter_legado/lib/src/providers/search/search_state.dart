import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'search_state.freezed.dart';

/// 搜索页不可变状态
///
/// 对标原 SearchProvider 字段，迁移至 Riverpod 后由 [SearchNotifier] 维护。
/// 展示层派生属性（hasResults/isEmpty/hasFilter）以 extension 表达。
@freezed
class SearchState with _$SearchState {
  const factory SearchState({
    /// 当前搜索关键词
    @Default('') String keyword,

    /// 搜索结果列表（已按书名+作者聚合，对齐原版 mergeItems）
    @Default([]) List<SearchResult> results,

    /// 是否正在搜索
    @Default(false) bool isLoading,

    /// 渐进搜索：已完成书源数（对齐原版 onSearchProgress searched）
    @Default(0) int searchedCount,

    /// 渐进搜索：书源总数（对齐原版 onSearchProgress total）
    @Default(0) int totalCount,

    /// 错误信息
    String? error,

    /// 失败书源列表（队列④ P1-B：单源搜索失败原仅 AppLog 留痕、UI 不可见，
    /// 现累积于此并在搜索结果页顶部以非阻断横幅呈现；新关键词搜索 / 清空 /
    /// 页面重开时清空，同关键词续页按源名去重（最新错误优先））
    @Default(<SearchSourceFailure>[]) List<SearchSourceFailure> failedSources,

    /// 精准搜索：选中的书源 URL
    @Default(<String>{}) Set<String> selectedSourceUrls,

    /// 精准搜索：选中的分组
    @Default(<String>{}) Set<String> selectedGroups,

    /// 搜索历史（最近 20 条，经 BookApi 持久化至 Rust search_keywords 表）
    /// [审计修复 §4.5] 清理陈旧注释（实际已不走 SharedPreferences） — Qoder
    @Default([]) List<String> searchHistory,

    /// 输入框实时文本（用于联想过滤，区别于已提交的 [keyword]）
    @Default('') String inputText,

    /// 活动搜索会话的当前页码（批次B G-B-01：新关键词 → 重置为 1；
    /// 同关键词续页 → searchPage++，对齐原版 SearchModel.searchPage）
    @Default(1) int searchPage,

    /// 是否有下一页（批次B G-B-02：当前页非空批次的 OR，Rust 侧 has_more
    /// 累积字段；新搜索开始时乐观置 true，每批事件覆写）
    @Default(false) bool hasMore,

    /// 软挂起态（批次B G-B-04：仅门控未派发书源，已派发任务继续；
    /// 对齐原版 repeatOnLifecycle(RESUMED) → viewModel.pause/resume）
    @Default(false) bool isPaused,

    /// 用户手动停止了本次搜索（对齐原版 SearchActivity.isManualStopSearch）：
    /// 抑制 play FAB 与滚动自动加载，直至新关键词搜索重置
    @Default(false) bool isManualStop,
  }) = _SearchState;
}

/// 单源搜索失败记录（队列④ P1-B：批次错误通道 → 可见 UI 的最小数据载体）
///
/// 数据来自 `searchMultiStream` 批次 JSON 的 `error`（可读错误文案，含
/// 书源能力受限提示，如「此书源需要 Java 脚本能力（…），当前不支持」）
/// 与 `source_name`（缺失时回退「未知书源」）。由 [SearchNotifier] 批次
/// 监听累积进 [SearchState.failedSources]，搜索结果页横幅消费；
/// 不改整体搜索交互（失败源不阻断搜索，对齐原版 SearchModel 静默语义，
/// 仅把「仅 AppLog 留痕」升级为「留痕 + 可见呈现」）。
class SearchSourceFailure {
  const SearchSourceFailure({
    required this.sourceName,
    required this.error,
  });

  /// 书源名（批次 `source_name`；缺失回退「未知书源」）
  final String sourceName;

  /// 批次 `error` 文案（可读错误文本）
  final String error;

  @override
  bool operator ==(Object other) =>
      other is SearchSourceFailure &&
      other.sourceName == sourceName &&
      other.error == error;

  @override
  int get hashCode => Object.hash(sourceName, error);

  @override
  String toString() => '$sourceName: $error';
}

/// 展示层派生属性
extension SearchStateDisplay on SearchState {
  /// 是否有搜索结果
  bool get hasResults => results.isNotEmpty;

  /// 空结果态（已搜索、非加载、有关键词但无结果）
  bool get isEmpty => results.isEmpty && !isLoading && keyword.isNotEmpty;

  /// 是否存在筛选条件（分组或书源）
  bool get hasFilter => selectedSourceUrls.isNotEmpty || selectedGroups.isNotEmpty;

  /// 联想/历史建议列表
  ///
  /// 对标 Android 原版 SearchActivity.upHistory 的前缀联想行为：
  /// - 输入为空 → 返回全部历史（flowByTime）
  /// - 输入非空 → 返回以输入为前缀的历史关键词（flowSearch 前缀匹配）
  ///
  /// 说明：原版前缀匹配由 DB 查询完成；当前 Rust FFI 未暴露前缀搜索，
  /// 故在客户端对已有历史做前缀过滤（行为等价，待 Rust 轨暴露 FFI 后切换）。
  List<String> get suggestions {
    final input = inputText.trim();
    if (input.isEmpty) return searchHistory;
    return searchHistory.where((w) => w.startsWith(input)).toList();
  }
}

/// 同书聚合 + 分桶排序（严格对齐原版 `SearchModel.mergeItems`）
///
/// 原版行为：
/// 1. 同名同作者合并为一条，`addOrigin` 累加来源（红数字 = origins.size）；
/// 2. 分桶 equal(name==key|author==key) → tags(kind 包含) →
///    contains(name|author 包含) → other；precision 时丢弃 other；
/// 3. 各桶内按 `origins.size` 降序。
///
/// 聚合键使用 [formatBookName]/[formatBookAuthor]（对齐原版 BookList 解析后
/// 再 merge；否则「作者：天蚕土豆」与「天蚕土豆」会拆成多条，徽标偏少）。
///
/// [UI-fix v2.0.31 | 2026-08-11] 此前仅分桶、按 origin 分行，用户体感
/// 「源少/噪声大」；现对齐原版同书多源聚合 — Auto
///
/// [2026-08-24] 流式搜索路径已改为 SearchNotifier 内的增量桶维护
/// （_addToBuckets + _materializeResults，每本书仅入桶一次），本函数保留为
/// 纯函数参考实现（一次性结果集聚合 / 单测基准）。
///
/// [P2-20 | 2026-09-22] 本函数与增量桶路径**同语义**（裁决：以运行时增量桶
/// 为准，三条路径——本纯函数 / `SearchNotifier` 增量桶 / Rust
/// `search_aggregate` 单一真源——已统一到同一语义）：入桶前多一层**跨桶
/// `seen` 预去重**，同一 `(name, author, origin)` 仅**首次到达**入桶（落哪个
/// 桶由首次到达决定），后续同键到达一律丢弃（其 origin 已由首条代表，跨源
/// 计数由 `origins` 集合承载）。**键来源（已核对，与运行时逐字一致）**：
/// `SearchNotifier._seenKeys` 的键在 `search_notifier.dart` L324 计算——
/// `'${r.book.name}|${r.book.author}|${r.book.origin}'`，即**原始（未清洗）**
/// 书名/作者 + origin 三段、`|` 分隔；注意它与**桶内聚合键**（本函数
/// `mergeInto` 的 `'$name\u0000$author'`，L175，**清洗后**值两段、不含
/// origin）是**两个不同的键**——seen 键管「是否入桶」，桶内键管「桶内归并
/// 分组」（同书多 origin 仍按桶内键合并累加）。
List<SearchResult> applyPrecisionSearch(
  List<SearchResult> results,
  String key, {
  bool keepOther = true,
}) {
  if (key.isEmpty) return results;

  final equal = <String, SearchResult>{};
  final tags = <String, SearchResult>{};
  final contains = <String, SearchResult>{};
  final other = <String, SearchResult>{};
  // P2-20：跨桶预去重集（键来源与 SearchNotifier._seenKeys 逐字一致，
  // 见函数 docstring「键来源」节：原始 name|author|origin，不含清洗）
  final seen = <String>{};

  void mergeInto(Map<String, SearchResult> bucket, SearchResult item) {
    final name = formatBookName(item.book.name);
    final author = formatBookAuthor(item.book.author);
    final mapKey = '$name\u0000$author';
    final normalized = (name != item.book.name || author != item.book.author)
        ? item.copyWith(book: item.book.copyWith(name: name, author: author))
        : item;
    final existing = bucket[mapKey];
    if (existing == null) {
      bucket[mapKey] = normalized.copyWith(origins: {...normalized.effectiveOrigins});
    } else {
      bucket[mapKey] = existing.withAddedOrigin(normalized);
    }
  }

  for (final r in results) {
    // P2-20：跨桶预去重——键逐字对齐运行时增量路径（search_notifier.dart
    // L324：'${r.book.name}|${r.book.author}|${r.book.origin}'，原始值不做
    // 清洗、含 origin）；同一 (name, author, origin) 仅首次到达入桶（落桶
    // 由首次到达决定），后续同键一律丢弃
    final seenKey = '${r.book.name}|${r.book.author}|${r.book.origin}';
    if (!seen.add(seenKey)) continue;
    final name = formatBookName(r.book.name);
    final author = formatBookAuthor(r.book.author);
    final kind = r.book.kind ?? '';
    if (name == key || author == key) {
      mergeInto(equal, r);
    } else if (kind.contains(key)) {
      mergeInto(tags, r);
    } else if (name.contains(key) || author.contains(key)) {
      mergeInto(contains, r);
    } else if (keepOther) {
      mergeInto(other, r);
    }
  }

  // 稳定排序：origins 数相同保持到达顺序（对齐原版 Kotlin sortedByDescending
  // 的稳定语义；Dart List.sort 不稳定，须以索引作平局裁决，否则同计数结果乱序）
  // — Qoder UI [fix v2.0.102]
  List<SearchResult> sortedBucket(Map<String, SearchResult> bucket) {
    final values = bucket.values.toList();
    final indexed = <(int, SearchResult)>[
      for (var i = 0; i < values.length; i++) (i, values[i]),
    ];
    indexed.sort((a, b) {
      final byCount = b.$2.originsCount.compareTo(a.$2.originsCount);
      return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList();
  }

  return [
    ...sortedBucket(equal),
    ...sortedBucket(tags),
    ...sortedBucket(contains),
    if (keepOther) ...sortedBucket(other),
  ];
}

/// 书名清洗（对齐原版 `BookHelp.formatBookName` / `AppPattern.nameRegex`）
String formatBookName(String name) {
  return name
      .replaceAll(RegExp(r'\s+作\s*者.*|\s+\S+\s+著'), '')
      .trim();
}

/// 作者清洗（对齐原版 `BookHelp.formatBookAuthor` / `AppPattern.authorRegex`）
String formatBookAuthor(String author) {
  return author
      .replaceAll(RegExp(r'^\s*作\s*者[:：\s]+|\s+著'), '')
      .trim();
}
