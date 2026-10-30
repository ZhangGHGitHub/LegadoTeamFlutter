// TXT 目录规则：原版 `Book.tocUrl` 编解码与选中判定（批43）
//
// 原版把选中的规则写成 `rule + TextFile.spaceChars + replacement`
// （`TxtTocRuleDialog.kt` / `TextFile.getChapterList`），Rust 侧
// `legado_book::txt::split_toc_rule` 按同一分隔符解析。Dart 侧只需：
// 1. 把 `TxtTocRule` 序列化为 `setBookTocRule` 的 `ruleJson` 入参；
// 2. 判断当前书是否已选某条规则（用于弹层勾选态）。
import 'dart:convert';

import '../models/misc.dart' show TxtTocRule;

/// 原版 `TextFile.spaceChars`（U+1F945 / U+1F333 / U+1F3FB）
const String kTxtTocRuleSeparator = '🫅🈳🏻';

/// 规则 + 分隔符 + replacement 的存储形态（原版 `Book.tocUrl`）
String txtTocRuleStorageValue(TxtTocRule rule) =>
    '${rule.rule}$kTxtTocRuleSeparator${rule.replacement}';

/// 当前书是否选中该规则（逐字对齐原版 `initSelectedName`）
bool isTxtTocRuleSelected(String tocUrl, TxtTocRule rule) =>
    tocUrl == txtTocRuleStorageValue(rule);

/// 当前书是否使用默认规则（`tocUrl` 空白 → 解析时自动选默认规则）
bool isDefaultTxtTocRule(String tocUrl) => tocUrl.trim().isEmpty;

/// 从存储值提取目录正则（用于「当前书使用自定义规则」提示）
///
/// 无分隔符时整串视为正则（与 Rust `split_toc_rule` 同口径）。
String? txtTocRuleRuleOf(String tocUrl) {
  final trimmed = tocUrl.trim();
  if (trimmed.isEmpty) return null;
  final index = trimmed.indexOf(kTxtTocRuleSeparator);
  if (index < 0) return trimmed;
  final rule = trimmed.substring(0, index).trim();
  return rule.isEmpty ? null : rule;
}

/// 规则序列化为 Rust `setBookTocRule` 入参 JSON
String encodeTxtTocRuleJson(TxtTocRule rule) => jsonEncode({
      'name': rule.name,
      'rule': rule.rule,
      'replacement': rule.replacement,
    });
