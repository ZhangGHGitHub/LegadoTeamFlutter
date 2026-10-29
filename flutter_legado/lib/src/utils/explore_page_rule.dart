/// 发现分类 URL 的页码规则探测（对标参考版 `AnalyzeUrl.supportsPageSelection`）
///
/// 参考版语义（`legado-with-MD3/.../model/analyzeRule/AnalyzeUrl.kt:803-838`）：
/// 1. 先剥离 `<js>…</js>` / `@js:…` 脚本段，脚本内引用 `page` 变量即视为支持；
/// 2. 再剥离 `{{…}}` 内嵌表达式，表达式内引用 `page` 变量即视为支持；
/// 3. 剩余文本里的 `<…>` 角度括号页码列表（如 `<1,2>`）含逗号即视为支持。
///
/// 本项目在 Dart 侧做等价探测（不引入 FFI）：以正则近似 Rhino AST 的
/// 「`page` 标识符引用」判断——排除属性访问 `obj.page` 与更长标识符
/// （`pageSize` / `pageNo`）。该近似足以匹配参考版的用户可见行为，
/// 解析失败/空规则一律返回 false（不显示页码按钮）。
library;

/// `<js>…</js>`（分组 1）或 `@js:…`（分组 2，吞掉其后全部文本），大小写不敏感
final RegExp _jsPattern = RegExp(
  r'<js>([\s\S]*?)</js>|@js:([\s\S]*)',
  caseSensitive: false,
);

/// `{{…}}` 内嵌表达式（分组 1 = 表达式正文）
final RegExp _expressionPattern = RegExp(r'\{\{([\s\S]*?)\}\}');

/// `<…>` 角度括号（分组 1 = 括号内文本，对齐参考版 `pagePattern = <(.*?)>`）
final RegExp _anglePattern = RegExp(r'<([\s\S]*?)>');

/// `page` 标识符引用：排除 `obj.page` 属性访问与 `pageXxx` 前缀/后缀长名
final RegExp _pageIdentifierPattern = RegExp(
  r'(?<![A-Za-z0-9_$.])page(?![A-Za-z0-9_$])',
);

/// 判断发现分类 URL 规则是否支持直接指定页码
///
/// 支持时发现书单页顶栏展示页码按钮（数字输入跳页）；
/// 不支持时页码按钮整体隐藏，仅保留上滑加载更多/下拉刷新。
bool exploreRuleSupportsPageSelection(String? rule) {
  if (rule == null || rule.trim().isEmpty) return false;

  var usesPage = false;

  // 1. 脚本段：识别 `page` 引用后整段移除（避免其中的 `<…>` 误判为页码列表）
  final withoutScripts = rule.replaceAllMapped(_jsPattern, (match) {
    final bare = match.group(1) ?? '';
    final afterAtJs = match.group(2) ?? '';
    final script = afterAtJs.isNotEmpty ? afterAtJs : bare;
    if (_referencesPage(script)) usesPage = true;
    return '';
  });

  // 2. 内嵌表达式：同理识别后移除
  final withoutExpressions = withoutScripts.replaceAllMapped(
    _expressionPattern,
    (match) {
      if (_referencesPage(match.group(1) ?? '')) usesPage = true;
      return '';
    },
  );

  if (usesPage) return true;

  // 3. 角度括号页码列表：`<1,2>` / `<,2.html>` 等含逗号即支持翻页
  return _anglePattern
      .allMatches(withoutExpressions)
      .any((match) => (match.group(1) ?? '').contains(','));
}

bool _referencesPage(String script) =>
    script.isNotEmpty && _pageIdentifierPattern.hasMatch(script);
