/// 用户手动高亮（`highlights` 表）正文渲染数据链
///
/// 缺陷背景（设备验收）：保存侧 `TextSelectionPanel._saveHighlight` 把
/// 高亮写入 `highlights` 表（`style` 形如
/// `{"type":"background","color":"#AARRGGBB"}`），但正文渲染链只读取
/// `highlight_rules` 的规则命中，`highlightListByChapter` 零调用方——
/// 用户点「已添加高亮」后正文内联永不显示。本文件负责把
/// `highlightListByChapter` 返回的 `BookHighlight[]` 转换为渲染层使用的
/// [HighlightMatch]（UTF-16 半开区间）。
///
/// 坐标口径：`chapterPos/chapterPosEnd` 为章节正文偏移（保存侧
/// `chapterOffsetOfSelection` 已扣除首行缩进全角空格），与规则命中
/// `highlightRuleMatch` 的 `start/end`、`LineInfo.chapterStartIndex` 同一
/// 坐标系（均以 `ReaderState.chapterContent` 为基准），因此渲染侧**不再**
/// 叠加/扣除缩进列。
///
/// `layoutTitleLength`：原版把正文位置定义为「排版位置 - 标题长度」
/// （`BookHighlight.bodyStart`）。我方 `chapterContent` 不含标题（标题由
/// 页面头单独渲染），故对带标题长度的历史记录（原版导入/备份恢复）需先
/// 减去该偏移；本应用保存的记录写 `0`，不做任何调整。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/highlight_style.dart';
import 'book_marking_render.dart' show kSavedHighlightMatchOrderBase;

/// 解析 `highlights.style` 为可渲染样式
///
/// 支持两类形态：
/// 1. 本应用保存的简化样式 `{"type":"background","color":"#AARRGGBB"}`
///    （参考版口径；`type` 可为 background/underline/strike/text）；
/// 2. 原版 `HighlightStyle` 完整 JSON（`fill`/`textColor`/`underline`/
///    `strike` 等），用于兼容导入/备份恢复的历史记录。
///
/// 无法映射/无渲染效果的样式返回 null（调用方跳过并记录日志），不抛错。
HighlightStyle? parseSavedHighlightStyle(String? rawStyle) {
  if (rawStyle == null || rawStyle.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(rawStyle);
  } catch (_) {
    debugPrint('[highlight] 跳过无法解析的高亮样式: $rawStyle');
    return null;
  }
  if (decoded is! Map) {
    debugPrint('[highlight] 跳过非对象高亮样式: $rawStyle');
    return null;
  }
  final map = decoded.map((k, v) => MapEntry(k.toString(), v));

  final typeRaw = map['type'];
  if (typeRaw is String && typeRaw.trim().isNotEmpty) {
    final type = typeRaw.trim().toLowerCase();
    final color = _parseColor(map['color']);
    switch (type) {
      case 'background':
      case 'bg':
        return color == 0 ? null : HighlightStyle(fill: color);
      case 'underline':
        return HighlightStyle(
          underline: HighlightUnderline(
            kind: map['kind'] is String
                ? (map['kind'] as String).toUpperCase()
                : 'SOLID',
            color: color,
            width: map['width'] is num ? (map['width'] as num).toDouble() : 1,
            distance: map['distance'] is num
                ? (map['distance'] as num).toDouble()
                : 0,
          ),
        );
      case 'strike':
      case 'strikethrough':
        return HighlightStyle(strike: true, strikeColor: color);
      case 'text':
      case 'foreground':
      case 'font':
        return color == 0 ? null : HighlightStyle(textColor: color);
      default:
        debugPrint('[highlight] 跳过无法映射的高亮样式 type=$type（$rawStyle）');
        return null;
    }
  }

  // 兼容原版 HighlightStyle 完整 JSON（无 type 键）
  final style = HighlightStyle.fromMap(map);
  return style.hasRenderableEffect ? style : null;
}

/// 把 `highlightListByChapter` 返回的 `BookHighlight[]` JSON 转换为命中区间
///
/// - 区间非法/越界（正文已变化）按内容长度裁剪，裁剪后退化则跳过；
/// - 样式无法映射（[parseSavedHighlightStyle] 返回 null）跳过；
/// - `ruleId` 用负数（`-(序号+1)`）与规则 ID 区分；`order` 取
///   [kSavedHighlightMatchOrderBase] + 序号；
/// - 保持数据库返回顺序（`chapterPos, time` 升序）：合并时列表靠后者
///   （同位置更晚创建）优先，对齐原版 `ReadBook.anchors` 的 time 覆盖语义。
List<HighlightMatch> buildSavedHighlightMatches({
  required String content,
  required String rawJson,
}) {
  if (content.isEmpty || rawJson.isEmpty || rawJson == 'null') return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (_) {
    debugPrint('[highlight] 跳过高亮列表 JSON 解析失败: $rawJson');
    return const [];
  }
  if (decoded is! List) return const [];

  final matches = <HighlightMatch>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    try {
      final map = item.map((k, v) => MapEntry(k.toString(), v));
      final chapterPos = _asInt(map['chapterPos']);
      final chapterPosEnd = _asInt(map['chapterPosEnd']);
      if (chapterPos == null || chapterPosEnd == null) continue;
      // 原版排版位置含标题长度；我方 chapterContent 不含标题，历史记录先减
      final titleLength = _asInt(map['layoutTitleLength']) ?? -1;
      final titleOffset = titleLength >= 0 ? titleLength : 0;
      var start = chapterPos - titleOffset;
      var end = chapterPosEnd - titleOffset;
      if (end <= start) continue;
      start = start.clamp(0, content.length);
      end = end.clamp(0, content.length);
      if (end <= start) continue;

      final styleJson = map['style'] is String ? map['style'] as String : '';
      final style = parseSavedHighlightStyle(styleJson);
      if (style == null) continue;

      final index = matches.length;
      matches.add(
        HighlightMatch(
          ruleId: -(index + 1),
          start: start,
          end: end,
          order: kSavedHighlightMatchOrderBase + index,
          style: style,
          styleJson: styleJson,
        ),
      );
    } catch (e) {
      // 单条坏记录不连累整章：跳过并记录
      debugPrint('[highlight] 跳过单条高亮记录: $e');
    }
  }
  return matches;
}

/// 颜色解析：`#AARRGGBB` / `#RRGGBB` / `0xAARRGGBB` / 数值
int _parseColor(Object? raw) {
  if (raw is num) return normalizeArgb(raw);
  if (raw is String) {
    var text = raw.trim();
    if (text.startsWith('#')) {
      text = text.substring(1);
    } else if (text.startsWith('0x') || text.startsWith('0X')) {
      text = text.substring(2);
    }
    if (text.length == 6) text = 'FF$text';
    if (text.length == 8) {
      final parsed = int.tryParse(text, radix: 16);
      if (parsed != null) return parsed & 0xFFFFFFFF;
    }
  }
  return 0;
}

int? _asInt(Object? value) => value is num ? value.toInt() : null;
