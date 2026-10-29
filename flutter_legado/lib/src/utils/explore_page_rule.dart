/// 发现分类 URL 的页码规则探测（对标参考版 `AnalyzeUrl.supportsPageSelection`）
///
/// 参考版语义（`legado-with-MD3/.../model/analyzeRule/AnalyzeUrl.kt:803-838`）：
/// 1. 先剥离 `<js>…</js>` / `@js:…` 脚本段，脚本内引用 `page` 变量即视为支持；
/// 2. 再剥离 `{{…}}` 内嵌表达式，表达式内引用 `page` 变量即视为支持；
/// 3. 剩余文本里的 `<…>` 角度括号页码列表（如 `<1,2>`）含逗号即视为支持。
///
/// 本项目在 Dart 侧做等价探测（不引入 FFI）：
/// - 脚本/表达式先屏蔽字符串与注释再匹配 `page` 标识符（参考版用 Rhino AST
///   判断，`'page'` 字符串、`/* page */` 注释、局部 `var page` 均不算引用）；
/// - 属性访问 `obj.page` 与更长标识符（`pageSize` / `pageNo`）不算引用；
/// - 额外识别本项目 Rust `AnalyzeUrl` 实际支持的 `{page}` 与 `{page,a,b}`
///   花括号页码写法（参考版 Kotlin 侧不支持，但 Rust 侧会替换页码，属引擎
///   能力对齐，非用户可见功能新增）；
/// - 解析失败/空规则一律返回 false（不显示页码按钮）。
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

/// `page` 标识符引用：排除 `obj.page` 属性访问、`pageXxx`/`xxxPage` 长名，
/// 以及对象字面量的属性键位（`{page: 1}` 的 `page:`）
final RegExp _pageIdentifierPattern = RegExp(
  r'(?<![A-Za-z0-9_$.])page(?![A-Za-z0-9_$]|\s*:)',
);

/// 局部声明会遮蔽全局 `page`（参考版 AST 只认 `definingScope == null` 的 Name）
final RegExp _localPageDeclarationPattern = RegExp(
  r'\b(?:var|let|const)\s+page\b',
);

/// 函数形参遮蔽：`function (page) {}` / `(page) => …`
final RegExp _pageParameterPattern = RegExp(
  r'function\b[^(]*\([^)]*\bpage\b[^)]*\)|\([^()]*\bpage\b[^()]*\)\s*=>',
);

/// Rust `AnalyzeUrl.replace_page` 支持的独立页码键 `{page}`
final RegExp _bracePagePattern = RegExp(r'\{page\s*\}');

/// Rust `AnalyzeUrl.replace_page_list_brace` 支持的页码列表 `{page,a,b}`
final RegExp _bracePageListPattern = RegExp(r'\{page\s*,[^}]*\}');

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

  // 剩余 URL 文本：先屏蔽引号字符串（如 @Header:{"x":"page"}），再判定页码标记
  final plain = _maskQuotedStrings(withoutExpressions);

  // 3. Rust 引擎支持的 `{page}` / `{page,a,b}` 花括号页码
  if (_bracePagePattern.hasMatch(plain) ||
      _bracePageListPattern.hasMatch(plain)) {
    return true;
  }

  // 4. 角度括号页码列表：`<1,2>` / `<,2.html>` 等含逗号即支持翻页
  return _anglePattern
      .allMatches(plain)
      .any((match) => (match.group(1) ?? '').contains(','));
}

/// 脚本/表达式是否引用了全局 `page` 变量
bool _referencesPage(String script) {
  if (script.isEmpty) return false;
  final masked = _maskJsStringsAndComments(script);
  if (masked.trim().isEmpty) return false;
  // 局部声明/形参会遮蔽全局 page → 不算页码引用（对齐参考版 AST 判定）
  if (_localPageDeclarationPattern.hasMatch(masked)) return false;
  if (_pageParameterPattern.hasMatch(masked)) return false;
  return _pageIdentifierPattern.hasMatch(masked);
}

/// 屏蔽 JS 字符串字面量与注释（模板 `${…}` 内的表达式保留）
String _maskJsStringsAndComments(String code) {
  final out = StringBuffer();
  var i = 0;
  while (i < code.length) {
    final c = code[i];
    final next = i + 1 < code.length ? code[i + 1] : '';
    // 行注释
    if (c == '/' && next == '/') {
      i += 2;
      while (i < code.length && code[i] != '\n' && code[i] != '\r') {
        i++;
      }
      out.write(' ');
      continue;
    }
    // 块注释
    if (c == '/' && next == '*') {
      i += 2;
      while (i + 1 < code.length && !(code[i] == '*' && code[i + 1] == '/')) {
        i++;
      }
      i = i + 1 < code.length ? i + 2 : code.length;
      out.write(' ');
      continue;
    }
    // 单/双引号字符串：整体屏蔽
    if (c == "'" || c == '"') {
      i = _skipQuotedIndex(code, i, c);
      out.write(' ');
      continue;
    }
    // 模板字符串：保留 `${…}` 表达式，其余屏蔽
    if (c == '`') {
      i = _maskTemplateInto(code, i, out);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 屏蔽引号字符串（URL 文本用；不处理 `//`，避免误伤 `https://`）
String _maskQuotedStrings(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == "'" || c == '"') {
      i = _skipQuotedIndex(text, i, c);
      out.write(' ');
      continue;
    }
    if (c == '`') {
      i = _maskTemplateInto(text, i, out);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 模板字符串：把 `${…}` 内的表达式按 JS 规则屏蔽后保留，其余文本屏蔽
int _maskTemplateInto(String code, int start, StringBuffer out) {
  var i = start + 1;
  while (i < code.length) {
    final c = code[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == '`') {
      i++;
      break;
    }
    if (c == r'$' && i + 1 < code.length && code[i + 1] == '{') {
      final end = _skipBracedExpression(code, i + 2);
      out.write(' ');
      out.write(_maskJsStringsAndComments(code.substring(i + 2, end)));
      out.write(' ');
      i = end + 1;
      continue;
    }
    i++;
  }
  out.write(' ');
  return i;
}

/// 跳过引号字符串，返回结束引号之后的下标
int _skipQuotedIndex(String code, int start, String quote) {
  var i = start + 1;
  while (i < code.length) {
    final c = code[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == quote) return i + 1;
    i++;
  }
  return code.length;
}

/// 跳过 `${…}` 表达式（花括号配对，忽略内部字符串/模板），返回 `}` 下标
int _skipBracedExpression(String code, int start) {
  var depth = 1;
  var i = start;
  while (i < code.length) {
    final c = code[i];
    if (c == "'" || c == '"') {
      i = _skipQuotedIndex(code, i, c);
      continue;
    }
    if (c == '`') {
      i = _skipTemplateIndex(code, i);
      continue;
    }
    if (c == '{') {
      depth++;
      i++;
      continue;
    }
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
      i++;
      continue;
    }
    i++;
  }
  return code.length;
}

/// 跳过模板字符串（含嵌套 `${…}`），返回结束反引号之后的下标
int _skipTemplateIndex(String code, int start) {
  var i = start + 1;
  while (i < code.length) {
    final c = code[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == '`') return i + 1;
    if (c == r'$' && i + 1 < code.length && code[i + 1] == '{') {
      i = _skipBracedExpression(code, i + 2) + 1;
      continue;
    }
    i++;
  }
  return code.length;
}
