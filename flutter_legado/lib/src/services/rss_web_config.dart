/// RSS WebView 阅读链纯逻辑（批15f）
///
/// 从原版 `ReadRssViewModel.clHtml` / `loadStartHtml`、`ReadRssActivity`
/// `CustomWebViewClient.shouldInterceptRequest` / `shouldOverrideUrlLoading`
/// 抽取的**无平台依赖**实现，便于单测；WebView 侧只负责调用与注入。
///
/// 对照：
/// - `ReadRssViewModel.kt:258-318`（`clHtml` / `loadStartHtml`）
/// - `ReadRssActivity.kt:630-791`（白/黑名单、`shouldOverrideUrlLoading`）
/// - `StringExtensions.kt:76-83`（`isTrue` 口径）
library;

import 'dart:convert';

/// 无自定义样式时原版注入的默认移动端样式（逐字对齐
/// `ReadRssViewModel.clHtml` 的 `finalStyle`）
const String kRssDefaultContentStyle =
    'img{max-width:100% !important; width:auto; height:auto;}'
    'video{object-fit:fill; max-width:100% !important; width:auto; height:auto;}'
    'body{word-wrap:break-word; height:auto;max-width: 100%; width:auto;}';

/// 预注入脚本在 HTML 中的占位标签（原版经 WebView 资源拦截替换
/// `JS_URL`；Flutter WebView 无该面，改为直接内联脚本）
String? _preloadScriptTag(String? preloadJs) {
  final js = preloadJs?.trim() ?? '';
  if (js.isEmpty) return null;
  return '<script>$js</script>';
}

/// 正文/起始页 HTML 后处理（对齐 `ReadRssViewModel.clHtml`）
///
/// 1. `preloadJs` 非空：插入 `</head>` 前（有 `<head>` 时在开标签后；
///    否则补 `<head>…</head>` 到最前）；
/// 2. 已存在 `</style>`：`style` 非空白时紧跟其后插入 `<style>{style}</style>`；
/// 3. 无 `</style>`：`style` 非空白用 `style`，否则用默认移动端样式，
///    插入 `</head>` 前；无 `</head>` 则插到最前。
String rssClHtml(String content, {String? style, String? preloadJs}) {
  final buffer = StringBuffer();
  final scriptTag = _preloadScriptTag(preloadJs);
  if (scriptTag != null) {
    final headIndex = content.indexOf('<head>');
    if (headIndex >= 0) {
      buffer.write(content.substring(0, headIndex + 6));
      buffer.write(scriptTag);
      buffer.write(content.substring(headIndex + 6));
    } else {
      buffer.write('<head>$scriptTag</head>');
      buffer.write(content);
    }
  } else {
    buffer.write(content);
  }
  final html = buffer.toString();
  final styleEndIndex = html.indexOf('</style>');
  final trimmedStyle = style?.trim() ?? '';
  if (styleEndIndex >= 0) {
    if (trimmedStyle.isEmpty) return html;
    final insertAt = styleEndIndex + 8; // '</style>'.length
    return '${html.substring(0, insertAt)}<style>$trimmedStyle</style>'
        '${html.substring(insertAt)}';
  }
  final finalStyle = trimmedStyle.isEmpty
      ? kRssDefaultContentStyle
      : trimmedStyle;
  final headEndIndex = html.indexOf('</head>');
  if (headEndIndex >= 0) {
    return '${html.substring(0, headEndIndex)}<style>$finalStyle</style>'
        '${html.substring(headEndIndex)}';
  }
  return '<style>$finalStyle</style>$html';
}

/// 起始页注入 `startJs`（对齐 `ReadRssViewModel.loadStartHtml`）
///
/// `startJs` 空白时原样返回；有 `</body>` 时插在其前，否则包装
/// `<body>{html}<script>{js}</script></body>`。脚本正文不 trim（与原版一致，
/// 仅用 trim 判定空）。
String rssInjectStartJs(String startHtml, String? startJs) {
  final js = startJs ?? '';
  if (js.trim().isEmpty) return startHtml;
  final bodyEndIndex = startHtml.indexOf('</body>');
  if (bodyEndIndex >= 0) {
    return '${startHtml.substring(0, bodyEndIndex)}<script>$js</script>'
        '${startHtml.substring(bodyEndIndex)}';
  }
  return '<body>$startHtml<script>$js</script></body>';
}

/// 原版 `String?.isTrue()` 口径（`StringExtensions.kt:76-83`）
///
/// 空/空白/字面量 `null` → false（默认 `nullIsTrue=false`）；
/// 其余 trim 后大小写不敏感匹配 `false|no|not|0|0.0` → false，否则 true。
bool rssIsTrue(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty || text == 'null') return false;
  return !RegExp(
    r'^(?:false|no|not|0|0\.0)$',
    caseSensitive: false,
  ).hasMatch(text);
}

/// 单条白/黑名单模式是否命中 URL
///
/// 对齐原版：`url.startsWith(pattern) || url.matches(pattern.toRegex())`；
/// 正则语法错误 → 视为未命中（原版仅记日志，不中断后续规则）。
bool rssPatternMatches(String url, String pattern) {
  final p = pattern.trim();
  if (p.isEmpty) return false;
  if (url.startsWith(p)) return true;
  try {
    return RegExp(p).hasMatch(url);
  } on FormatException {
    return false;
  }
}

/// 导航白/黑名单判定结果
enum RssNavigationRule {
  /// 未配置该名单（或黑名单存在但未命中）→ 不做额外处理
  none,

  /// 命中白名单
  allow,

  /// 命中黑名单 / 未命中白名单
  block,
}

/// 拆分逗号分隔的白/黑名单（trim、去空；对齐 `splitNotBlank(",")`）
List<String> _splitPatterns(String? rules) => (rules ?? '')
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList(growable: false);

/// 主框架导航白/黑名单判定（对齐 `CustomWebViewClient.shouldInterceptRequest`）
///
/// 原版逻辑：**有黑名单**时只判黑名单（命中 → 空白资源，未命中 → 放行，
/// 不再看白名单）；**无黑名单**且有白名单时，命中白名单才放行，否则空白。
RssNavigationRule rssNavigationRuleDecision({
  required String url,
  String? whitelist,
  String? blacklist,
}) {
  final blocked = _splitPatterns(blacklist);
  if (blocked.isNotEmpty) {
    for (final pattern in blocked) {
      if (rssPatternMatches(url, pattern)) return RssNavigationRule.block;
    }
    return RssNavigationRule.none;
  }
  final allowed = _splitPatterns(whitelist);
  if (allowed.isEmpty) return RssNavigationRule.none;
  for (final pattern in allowed) {
    if (rssPatternMatches(url, pattern)) return RssNavigationRule.allow;
  }
  return RssNavigationRule.block;
}

/// `shouldOverrideUrlLoading` JS 求值脚本（对齐 `ReadRssActivity.kt:770-791`）
///
/// 绑定 `url`（当前导航地址）与 `java`（原版 `RssJsExtensions` 的桩实现，
/// 见 [kRssJavaStubScript]）。原版 `evalJS` 支持「表达式求值」与「脚本内
/// return」两种写法：先按 `eval` 求值（表达式语义），失败再按函数体包裹
/// 执行（`return` 语义）。
///
/// **返回值保持原始类型**（批15f 审查 P0-2）：不能用 `String(...)` 包裹——
/// Android 插件会把字符串结果二次编码为 JSON 字面量（JS 返回 `"false"`
/// 时 Dart 侧收到含引号的 `"\"false\""`），交给 [rssIsTrue] 会恒判 true
/// 导致所有导航被拦截。无返回值（`undefined`）统一返回 `null`，由
/// [rssShouldOverrideResult] 归一为「不拦截」；JS 抛错同样返回 `null`。
String rssShouldOverrideScript(String js, String url) {
  final encodedUrl = jsonEncode(url);
  final encodedJs = jsonEncode(js);
  return '''
(function(){
  var url = $encodedUrl;
  var java = (window.__legadoJava = window.__legadoJava || {});
  var result;
  try {
    result = eval($encodedJs);
  } catch (e1) {
    try {
      result = (function(){\n$js\n})();
    } catch (e2) {
      try { console.error('shouldOverrideUrlLoading 执行失败: ' + (e2 && e2.stack ? e2.stack : e2)); } catch (e3) {}
      return null;
    }
  }
  return (result === undefined) ? null : result;
})()
''';
}

/// 归一 `shouldOverrideUrlLoading` 的 JS 求值结果（批15f 审查 P0-2）
///
/// 平台返回形态差异：
/// - Android 插件对 JS 字符串结果返回 **JSON 编码字面量**（如 JS `false`
///   字符串 → Dart `"\"false\""`，含首尾引号）；布尔/数字返回 JSON 原文
///   （`true` / `false` / `0` / `1`）；
/// - iOS/macOS 直接返回原生 `bool` / `num` / `String`。
///
/// 归一规则（与 [rssParseConsoleLogs] 的 JSON 字面量处理同先例）：
/// - `null` / `undefined` / 空串 → `false`（不拦截）；
/// - `bool` → 原值；`num` → 非 0 为 `true`；
/// - `String` → 先去掉外层 JSON 字符串字面量引号（`jsonDecode`），再按
///   [rssIsTrue] 口径（`false/no/not/0/0.0` → false，其余 → true）。
bool rssShouldOverrideResult(Object? raw) {
  if (raw == null) return false;
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  var text = _unwrapQuotedLiteral(raw.toString());
  if (text.isEmpty || text == 'null' || text == 'undefined') return false;
  return rssIsTrue(text);
}

/// 去掉字符串外层的 JSON 字符串字面量引号（单双引号均兼容）
///
/// Android 插件对 JS 字符串结果返回 `"..."` 形态的 JSON 字面量；单引号
/// 形态（非标准 JSON）仅做去引号，避免非法 JSON 字面量落到语义判定。
String _unwrapQuotedLiteral(String value) {
  final trimmed = value.trim();
  if (trimmed.length < 2) return trimmed;
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is String) return decoded.trim();
    } catch (_) {
      // 非法 JSON 字面量：按原文判定
    }
    return trimmed;
  }
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

/// `java` 桩对象（原版 `RssJsExtensions` 的 Java 绑定）
///
/// Flutter WebView 无 `@JavascriptInterface` 面；本批只提供**空实现**，
/// 保证规则脚本里的 `java.open(...)` / `java.showPhoto(...)` 等调用不抛
/// 「undefined」并使脚本后续逻辑可继续（动作本身不执行，登记 15g）。
const String kRssJavaStubScript = '''
(function(){
  if (window.__legadoJava) return;
  var noop = function(){};
  window.__legadoJava = {
    open: noop,
    searchBook: noop,
    addBook: noop,
    showPhoto: noop,
    put: function(k, v){ return v; },
    get: function(){ return ''; },
    getTag: function(){ return ''; }
  };
})();
''';

/// WebView console 钩子（`showWebLog` 用）
///
/// 原版经 `onConsoleMessage` 实时输出；Flutter WebView 无跨平台 console
/// 回调，这里钩住 `console.*` 写入环形缓冲，由 [kRssConsoleFlushScript]
/// 回读。保留原始 console 行为（继续调用原函数）。
const String kRssConsoleHookScript = '''
(function(){
  if (window.__legadoConsoleHooked) return;
  window.__legadoConsoleHooked = true;
  window.__legadoConsoleLogs = [];
  var levels = ['log', 'info', 'warn', 'error', 'debug'];
  levels.forEach(function(level){
    var original = console[level];
    console[level] = function(){
      try {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
          try { parts.push(String(arguments[i])); } catch (e) { parts.push('[object]'); }
        }
        window.__legadoConsoleLogs.push(level + ': ' + parts.join(' '));
        if (window.__legadoConsoleLogs.length > 200) {
          window.__legadoConsoleLogs.splice(0, window.__legadoConsoleLogs.length - 200);
        }
      } catch (e) {}
      if (original) { try { original.apply(console, arguments); } catch (e) {} }
    };
  });
})();
''';

/// 回读并清空 console 缓冲（返回 JSON 数组字符串）
const String kRssConsoleFlushScript =
    '(function(){var logs=window.__legadoConsoleLogs||[];'
    'window.__legadoConsoleLogs=[];return JSON.stringify(logs);})()';

/// 解析 [kRssConsoleFlushScript] 的返回值（WebView 可能返回带引号串）
List<String> rssParseConsoleLogs(Object? raw) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return const [];
  // Android `runJavaScriptReturningResult` 返回 JSON 编码后的字符串字面量
  final candidate = _unwrapQuotedLiteral(text);
  try {
    final decoded = jsonDecode(candidate);
    if (decoded is List) {
      return decoded.map((e) => '$e').toList(growable: false);
    }
  } catch (_) {}
  return [candidate];
}
