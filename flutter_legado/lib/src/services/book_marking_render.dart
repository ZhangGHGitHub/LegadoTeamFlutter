/// 书签标记正文渲染数据链（批7b-2b）
///
/// - [`buildMarkingMatches`]：把当前章 `book_marks` 按锚点解析成
///   `HighlightMatch`（UTF-16 半开区间），供与规则命中合并后渲染；
/// - [`mergeHighlightAndMarkingMatches`]：规则命中 + 标记命中的区间合成。
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

  final intervals = <_ArenaInterval>[];
  for (var i = 0; i < rules.length; i++) {
    final rule = rules[i];
    if (rule.start < 0 || rule.end <= rule.start) continue;
    intervals.add(
      _ArenaInterval(
        match: rule,
        isMark: false,
        index: i,
        styleKey: _styleKey(rule.style),
      ),
    );
  }
  for (var i = 0; i < marks.length; i++) {
    final mark = marks[i];
    if (mark.start < 0 || mark.end <= mark.start) continue;
    intervals.add(
      _ArenaInterval(
        match: mark,
        isMark: true,
        index: i,
        styleKey: _styleKey(mark.style),
      ),
    );
  }
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

class _ArenaInterval {
  const _ArenaInterval({
    required this.match,
    required this.isMark,
    required this.index,
    required this.styleKey,
  });

  final HighlightMatch match;
  final bool isMark;
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

/// 规则索引用于同 order 先出现者优先；标记索引越大优先级越高
bool _isHigherPriority(_ArenaInterval a, _ArenaInterval b) {
  if (a.isMark != b.isMark) return a.isMark;
  if (a.isMark) return a.index > b.index;
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
