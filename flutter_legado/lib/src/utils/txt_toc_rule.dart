// TXT 目录规则：原版 `Book.tocUrl` 编解码与选中判定（批43）
//
// 原版把选中的规则写成 `rule + TextFile.spaceChars + replacement`
// （`TxtTocRuleDialog.kt` / `TextFile.getChapterList`），Rust 侧
// `legado_book::txt::split_toc_rule` 按同一分隔符解析。Dart 侧只需：
// 1. 把 `TxtTocRule` 序列化为 `setBookTocRule` 的 `ruleJson` 入参；
// 2. 判断当前书是否已选某条规则（用于弹层勾选态）。
import 'dart:convert';

import '../models/book.dart' show Book, BookType;
import '../models/misc.dart' show TxtTocRule;

/// 原版 `TextFile.spaceChars`（U+1FAC5 / U+1F233 / U+1F3FB）
const String kTxtTocRuleSeparator = '🫅🈳🏻';

/// 本地 TXT 书判定（[批43b P3-4] 全仓唯一 Dart 口径）
///
/// 与 Rust `bookshelf.rs::is_local_txt_book` 严格同构：
/// `is_local_storage_book(book) && is_txt_path(book.book_url)`。
/// 扩展名只看 `bookUrl`（Rust `is_txt_path` 的唯一依据）——若 UI 用
/// `originName` 放宽，会出现「入口可见但 Rust 拒绝」的假入口。
///
/// 历史上有四份口径（阅读器菜单 / 目录页 / 规则弹层 / 详情页，分别混用
/// origin-only、originName、`.txt` 不含 `.text` 等判定），本函数收敛后
/// 这些调用点统一改为调用本函数。
bool isLocalTxtBook(Book book) {
  if (!BookType.isLocalStorageBook(book)) return false;
  final url = book.bookUrl.toLowerCase();
  return url.endsWith('.txt') || url.endsWith('.text');
}

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

/// [批1b-3 审查回修 P3-4] 把当前 `books.tocUrl` 拆回 `setBookTocRule`
/// 的 `ruleJson` 入参（「重新解析目录」复用该单列写做失效通道）。
///
/// 三种形态：
/// - 空白（默认规则）→ `null`（Rust 侧恢复默认，清目录语义不变）；
/// - `rule + 分隔符 + replacement` → 拆回 `{rule, replacement}` JSON
///   （Rust 重编码后存储值逐字还原；直接传 raw tocUrl 会被 Rust 按
///   「无分隔符正则」分支追加多余分隔符并丢失 replacement）；
/// - 无分隔符的历史/手工正则 → 整串作 `rule`、replacement 置空
///   （与 Rust `split_toc_rule` 同口径；写回后存储值追加分隔符，
///   解析语义等价，批43 UI 输入通道规范化既有行为）。
String? buildReparseRuleJson(String tocUrl) {
  final trimmed = tocUrl.trim();
  if (trimmed.isEmpty) return null;
  final sepIndex = trimmed.indexOf(kTxtTocRuleSeparator);
  final rule = sepIndex < 0 ? trimmed : trimmed.substring(0, sepIndex);
  final replacement = sepIndex < 0
      ? ''
      : trimmed.substring(sepIndex + kTxtTocRuleSeparator.length);
  return jsonEncode({'rule': rule, 'replacement': replacement});
}
