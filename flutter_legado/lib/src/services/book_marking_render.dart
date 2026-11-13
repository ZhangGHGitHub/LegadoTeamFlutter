/// 书签标记正文渲染数据链（批7b-2b）
///
/// - [`buildMarkingMatches`]：把当前章 `book_marks` 按锚点解析成
///   `HighlightMatch`（UTF-16 半开区间），供与规则命中合并后渲染；
/// - [`mergeHighlightAndMarkingMatches`]：规则命中 + 标记命中的区间合成；
/// - [`mergeHighlightMarkingAndSavedMatches`]：再并入 `highlights` 表的
///   用户手动高亮（设备验收缺陷修复：此前渲染链完全没有消费该表）。
///
/// 纯函数、不依赖 Flutter；单章标记数量正常 < 100，合并采用事件点扫描
/// （起止事件 + 活动区间集合），避免大面积 O(n²) 切分。
library;

import 'dart:convert';

import '../models/book_marking.dart';
import '../models/book_marking_style.dart';
import '../models/highlight_style.dart';
import 'book_marking_range_resolver.dart';

/// 标记命中的 order 基准（高于普通高亮规则 sortOrder，规则通常为 0..n）
const int kBookMarkingMatchOrderBase = 1 << 20;

/// 用户手动高亮（`highlights` 表）命中的 order 基准
///
/// 低于笔记标记（[kBookMarkingMatchOrderBase]）、高于普通规则；实际重叠
/// 优先级由 [`mergeHighlightMarkingAndSavedMatches`] 的层级决定。
const int kSavedHighlightMatchOrderBase = 1 << 19;

/// 把当前章书签标记解析为可渲染命中
///
/// - 跳过禁用标记与无锚点/无法定位的标记；
/// - 样式经 [`BookMarkingStyle.toHighlightStyle`] 转换，无可渲染效果则跳过；
/// - `ruleId` 用负数（`-(序号+1)`）与规则 ID 区分；`order` 取
///   [`kBookMarkingMatchOrderBase`] + 列表序号，保证高于规则。
List<HighlightMatch> buildMarkingMatches({
  required String content,
  required List<BookMarking> markings,
}) {
  if (content.isEmpty || markings.isEmpty) return const [];
  final matches = <HighlightMatch>[];
  var index = 0;
  for (final marking in markings) {
    if (!marking.enabled) continue;
    final anchor = BookMarkingAnchor.tryParse(marking.anchorJson);
    if (anchor == null) continue;
    final range = resolveBookMarkingRange(content, anchor);
    if (range == null) continue;
    final style = BookMarkingStyle.tryParse(
      marking.styleJson,
    )?.toHighlightStyle();
    if (style == null || !style.hasRenderableEffect) continue;
    matches.add(
      HighlightMatch(
        ruleId: -(index + 1),
        start: range.start,
        end: range.end,
        order: kBookMarkingMatchOrderBase + index,
        style: style,
        styleJson: marking.styleJson ?? '',
      ),
    );
    index++;
  }
  return matches;
}

/// 合并规则命中与标记命中
///
/// 优先级：
/// 1. 标记整体高于规则；
/// 2. 标记之间按列表顺序，靠后者优先（DB 查询为 `createdAt ASC`；
///    编辑不会提升优先级，不使用 updatedAt）；
/// 3. 规则之间保持既有语义：`order` 大者优先，同 order 先出现者优先。
///
/// 输出互不重叠、按 `start` 升序；相邻且同样式段合并（合并段继承前一段的
/// `ruleId`/`order`/`styleJson` 元数据）。
/// `marks` 为空时返回 `rules` 的副本（不改变原有结果）。
List<HighlightMatch> mergeHighlightAndMarkingMatches({
  required List<HighlightMatch> rules,
  required List<HighlightMatch> marks,
}) {
  if (marks.isEmpty) return List<HighlightMatch>.of(rules);
  return _mergeTiered(rules: rules, marks: marks, saved: const []);
}

/// 合并规则命中 + 笔记标记 + 用户手动高亮（`highlights` 表）
///
/// 层级优先级：**笔记标记 > 用户手动高亮 > 规则命中**。
///
/// 依据：
/// 1. 用户手动高亮必须高于规则命中——参考版 `ReadBook.highlightRangesOfChapter`
///    以 `rules + manual` 顺序交给 `HighlightMatcher.resolve`，后者的
///    `HighlightStyle.merge` 由后出现的 manual 覆盖规则；且用户点「保存高亮」
///    是显式操作，规则只是自动匹配。
/// 2. 笔记标记继续高于手动高亮，沿用 7b-2b 已冻结的「用户标记高于规则」
///    语义；两类都是显式操作，重叠属边缘场景，保持笔记优先可使既有标记
///    渲染结果零变化（本批只对原先「无任何高亮」的区间新增渲染）。
///
/// 手动高亮之间按列表顺序，靠后者优先（`highlightListByChapter` 为
/// `chapterPos, time` 升序 → 同位置更晚创建者生效，对齐原版
/// `ReadBook.highlights` 的 time 覆盖语义）。
/// `saved` 为空时等价于 [mergeHighlightAndMarkingMatches]。
List<HighlightMatch> mergeHighlightMarkingAndSavedMatches({
  required List<HighlightMatch> rules,
  required List<HighlightMatch> marks,
  required List<HighlightMatch> saved,
}) {
  if (saved.isEmpty) {
    return mergeHighlightAndMarkingMatches(rules: rules, marks: marks);
  }
  return _mergeTiered(rules: rules, marks: marks, saved: saved);
}

/// 三层级合并核心（事件点扫描，输出互不重叠）
List<HighlightMatch> _mergeTiered({
  required List<HighlightMatch> rules,
  required List<HighlightMatch> marks,
  required List<HighlightMatch> saved,
}) {
  final intervals = <_ArenaInterval>[];
  void addAll(List<HighlightMatch> source, int tier) {
    for (var i = 0; i < source.length; i++) {
      final match = source[i];
      if (match.start < 0 || match.end <= match.start) continue;
      intervals.add(
        _ArenaInterval(
          match: match,
          tier: tier,
          index: i,
          styleKey: _styleKey(match.style),
        ),
      );
    }
  }

  addAll(rules, _kTierRule);
  addAll(saved, _kTierSaved);
  addAll(marks, _kTierMark);
  if (intervals.isEmpty) return const [];

  // 事件点：同一位置先处理结束（半开区间 [start,end)）
  final events = <_Event>[];
  for (var id = 0; id < intervals.length; id++) {
    final interval = intervals[id];
    events.add(_Event(pos: interval.match.start, isStart: true, id: id));
    events.add(_Event(pos: interval.match.end, isStart: false, id: id));
  }
  events.sort((a, b) {
    final byPos = a.pos.compareTo(b.pos);
    if (byPos != 0) return byPos;
    if (a.isStart != b.isStart) return a.isStart ? 1 : -1;
    return a.id.compareTo(b.id);
  });

  final active = <int>{};
  final out = <HighlightMatch>[];
  var cursor = 0;
  while (cursor < events.length) {
    final pos = events[cursor].pos;
    while (cursor < events.length && events[cursor].pos == pos) {
      final event = events[cursor];
      if (event.isStart) {
        active.add(event.id);
      } else {
        active.remove(event.id);
      }
      cursor++;
    }
    if (cursor >= events.length || active.isEmpty) continue;
    final nextPos = events[cursor].pos;
    if (nextPos <= pos) continue;
    final winner = _pickWinner(active, intervals);
    if (winner == null) continue;
    _emitSegment(out, pos, nextPos, winner);
  }
  return out;
}

/// 层级：规则 0 < 手动高亮 1 < 笔记标记 2
const int _kTierRule = 0;
const int _kTierSaved = 1;
const int _kTierMark = 2;

class _ArenaInterval {
  const _ArenaInterval({
    required this.match,
    required this.tier,
    required this.index,
    required this.styleKey,
  });

  final HighlightMatch match;

  /// 来源层级（见 `_kTier*`）
  final int tier;

  final int index;
  final String styleKey;
}

class _Event {
  const _Event({required this.pos, required this.isStart, required this.id});

  final int pos;
  final bool isStart;
  final int id;
}

/// 从活动区间集合中选优先级最高者
_ArenaInterval? _pickWinner(Set<int> active, List<_ArenaInterval> intervals) {
  _ArenaInterval? best;
  for (final id in active) {
    final candidate = intervals[id];
    if (best == null || _isHigherPriority(candidate, best)) {
      best = candidate;
    }
  }
  return best;
}

/// 规则索引用于同 order 先出现者优先；标记/手动高亮索引越大优先级越高
bool _isHigherPriority(_ArenaInterval a, _ArenaInterval b) {
  if (a.tier != b.tier) return a.tier > b.tier;
  if (a.tier != _kTierRule) {
    // 标记：列表靠后者优先（createdAt ASC）
    // 手动高亮：chapterPos,time 升序靠后者优先（同位置更晚创建覆盖）
    return a.index > b.index;
  }
  final byOrder = a.match.order.compareTo(b.match.order);
  if (byOrder != 0) return byOrder > 0;
  return a.index < b.index;
}

void _emitSegment(
  List<HighlightMatch> out,
  int start,
  int end,
  _ArenaInterval winner,
) {
  if (start >= end) return;
  if (out.isNotEmpty) {
    final last = out.last;
    if (last.end == start && _styleKey(last.style) == winner.styleKey) {
      // 相邻同样式合并：保留前一段的 ruleId/order/styleJson 元数据
      out[out.length - 1] = HighlightMatch(
        ruleId: last.ruleId,
        start: last.start,
        end: end,
        order: last.order,
        style: last.style,
        styleJson: last.styleJson,
      );
      return;
    }
  }
  out.add(
    HighlightMatch(
      ruleId: winner.match.ruleId,
      start: start,
      end: end,
      order: winner.match.order,
      style: winner.match.style,
      styleJson: winner.match.styleJson,
    ),
  );
}

String _styleKey(HighlightStyle style) => jsonEncode(style.toMap());
