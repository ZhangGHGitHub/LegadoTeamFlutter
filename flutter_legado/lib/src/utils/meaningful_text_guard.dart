/// [R-NaN / C2 N1 / U4] 跨页共享的渲染层脏数据守卫（双端兜底之渲染端）
///
/// 数据源头已同步清洗：Rust 解析层 `normalize_js_rule_result` 拒收 JS
/// NaN/null/undefined 与未渲染模板残留（`{{$.xxx}}` / `{$xxx}`，
/// 台账 0917 U4），`word_count_format` 拒收 "NaN"。但第三方书源 JS
/// **字符串**拼接产物（如规则显式产出 "NaN : NaN"、"9.9分|{{$.x}}"）
/// 与占位文案不经 Rust 清洗路径，仍可能到达 UI——本守卫为渲染层兜底：
/// 空串 / "NAN" 及其拼接形 / 第三方占位串 / 未渲染模板残留均视为
/// 「无数据」，对应行/标签不渲染。
///
/// 用法：详情页（book_info_screen_builders.part）分类 chip、字数 chip、
/// 信息聚合行统一经 [isMeaningfulText] 过滤后渲染。
library;

/// 未渲染书源模板变量残留：出现 `{{` 或 `{$` 即残留（**成对与未闭合
/// 均算**——书源 JS 规则截断可产出未闭合形 `{{$.categoryInfoV4`，
/// 2.0.277 瀚海书阁 kind 实锤）。判据与 Rust 解析层
/// `contains_unrendered_template` 同源。
final _unrenderedTemplateRe = RegExp(r'\{\{|\{\$');

/// 第三方书源占位串（无数据文案，非真实内容）
const Set<String> kPlaceholderTexts = {'暂无专辑', '暂无简介'};

/// 字符串是否含未渲染模板变量残留（`{{...}}` / `{$...}`）
bool hasUnrenderedTemplate(String v) => _unrenderedTemplateRe.hasMatch(v);

/// "NaN" 拼接形判定（如 "NaN : NaN"：全部分隔符切分后每段均为 NAN）
///
/// 注意：`toUpperCase` 产物为全大写 'NAN'（非 'NaN'），判据必须与
/// 'NAN' 比（[R-NaN 2.0.273 核图复修] 同源逻辑）。
bool isNanJoined(String v) {
  final parts = v
      .split(RegExp(r'[\s:：,，;；、/|+&·~\-_]+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return false;
  return parts.every((p) => p.toUpperCase() == 'NAN');
}

/// [R-NaN / C2 N1 / U4] 判定文本是否「有数据可渲染」：
/// 空串、精确 "NaN"、"NaN" 拼接形、第三方占位串、未渲染模板残留
/// 均返回 false（不渲染）。
bool isMeaningfulText(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return false;
  if (v.toUpperCase() == 'NAN') return false;
  if (isNanJoined(v)) return false;
  if (kPlaceholderTexts.contains(v)) return false;
  return !hasUnrenderedTemplate(v);
}
