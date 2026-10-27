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

/// HTML 内联 `<script>` 正文转义：`</script` → `<\/script`（大小写不敏感）
///
/// 批21b：宿主桥组合脚本可能包含 `</script` 字面量（规则脚本/字符串），
/// 不转义会提前闭合标签。转义只影响 HTML 解析器，JS 字符串/正则中的
/// `<\/script` 与原值等价。
String rssEscapeScriptBody(String javaScript) {
  if (!javaScript.contains('</')) return javaScript;
  return javaScript.replaceAll(
    RegExp(r'</script', caseSensitive: false),
    r'<\/script',
  );
}

/// 预注入脚本在 HTML 中的占位标签（原版经 WebView 资源拦截替换
/// `JS_URL`；Flutter WebView 无该面，改为直接内联脚本）
///
/// 批21b：优先使用 [preloadScript]（宿主桥组合脚本：console 钩子 →
/// 通道/握手 → Rust 桥头 → 同步面 → `preloadJs`）；未提供时回落裸
/// `preloadJs`（无宿主绑定）。正文统一做 `</script` 转义，避免脚本内容
/// 提前闭合标签。
String? _preloadScriptTag(String? preloadJs, String? preloadScript) {
  final explicit = preloadScript;
  if (explicit != null && explicit.trim().isNotEmpty) {
    return '<script>${rssEscapeScriptBody(explicit)}</script>';
  }
  final js = preloadJs?.trim() ?? '';
  if (js.isEmpty) return null;
  return '<script>${rssEscapeScriptBody(js)}</script>';
}

/// 桥模式页面脚本隔离（批21c P0-2，批21d P0-A 不动点加固）
///
/// 启用宿主桥（源 `preloadJs` 非空且 `enableJs`）时，先把文章/起始页 HTML
/// 中的**页面脚本**剥离，再由调用方注入应用自己的可信脚本（`startJs`/
/// 桥组合脚本）。相对原版这是本地加固差异：原版经 `shouldInterceptRequest`
/// 用外部子资源注入桥（桥不在 DOM），Flutter WebView 无该拦截面，只能内联；
/// 剥离后页面内不存在应用注入之外的 `<script>` 标签。
///
/// 批21d 起改为**逐标签扫描 + 循环到不动点**（不再依赖单条正则）：
/// 1. 删除所有 `<script ...>` 开始标签（含未闭合、带属性、`<script/src=…>`）
///    与 `</script` 结束标签；每轮剥离后重新扫描，防止
///    `<sc<script>ript>` 这类拆分重组在删除后重新拼成 `<script>`；
/// 2. 删除 `srcdoc` 属性与 `on*=` 内联事件（大小写/引号/无引号）；
/// 3. URL 属性（href/src/action/formaction/xlink:href/poster/…）的值先做
///    HTML 实体解码并剔除控制字符，命中 `javascript:` / `vbscript:` /
///    `data:text/html` 则删除整个属性；
/// 4. 引号属性值内的 `<script>` 按 HTML 解析语义保留（浏览器不会把它当标签），
///    避免 `<img alt="<script>x</script>">` 被破坏。
///
/// **已知功能损失（契约 §2.5 批21d 已登记）**：`<pre><code>` 中字面
/// `<script>` 示例会被删除；依赖页面脚本/内联事件的懒加载图片、视频嵌入、
/// 动态交互将失效；`srcdoc` 内嵌文档被移除。iframe/object 同源嵌入仍是
/// 残余风险（跨源 iframe 无法读取父文档）。
String rssStripPageScripts(String html) {
  if (html.isEmpty) return html;
  var current = html;
  // 删除标签可能让前后文本重新拼成 `<script>`；每轮严格缩短或不变，
  // 因此循环必然收敛（上限仅作防御）。
  for (var pass = 0; pass < 8; pass++) {
    final next = _rssStripPageScriptsPass(current);
    if (next == current) break;
    current = next;
  }
  return current;
}

/// URL 属性名（值命中危险 scheme 时整体删除）
const Set<String> _rssUrlAttributeNames = <String>{
  'href',
  'src',
  'action',
  'formaction',
  'xlink:href',
  'poster',
  'background',
  'cite',
  'longdesc',
  'usemap',
  'manifest',
  'ping',
  'data',
};

/// HTML 命名实体（scheme 判定所需子集；数字实体另行解析）
const Map<String, String> _rssNamedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00a0',
  'colon': ':',
  'tab': '\t',
  'newline': '\n',
  'sol': '/',
  'bsol': '\\',
  'lpar': '(',
  'rpar': ')',
  'semi': ';',
};

final RegExp _rssEntityPattern =
    RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);?');

/// 递归解码 HTML 实体（最多 4 层，`&amp;#106;` 等嵌套编码同样覆盖）
String _rssDecodeHtmlEntities(String value) {
  var current = value;
  for (var round = 0; round < 4; round++) {
    var changed = false;
    current = current.replaceAllMapped(_rssEntityPattern, (match) {
      final body = match[1]!;
      String? decoded;
      if (body.startsWith('#')) {
        final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final digits = hex ? body.substring(2) : body.substring(1);
        final code = int.tryParse(digits, radix: hex ? 16 : 10);
        if (code != null && code >= 0 && code <= 0x10FFFF) {
          decoded = String.fromCharCode(code);
        }
      } else {
        decoded = _rssNamedEntities[body.toLowerCase()];
      }
      if (decoded == null) return match[0]!;
      changed = true;
      return decoded;
    });
    if (!changed) break;
  }
  return current;
}

/// 属性值 scheme 判定：实体解码 + 剔除空白/控制字符后匹配危险 scheme
bool _rssIsDangerousUrlValue(String value) {
  final decoded = _rssDecodeHtmlEntities(value)
      .replaceAll(RegExp(r'[\u0000-\u0020\u007f]+'), '')
      .toLowerCase();
  return decoded.startsWith('javascript:') ||
      decoded.startsWith('vbscript:') ||
      decoded.startsWith('data:text/html');
}

bool _rssIsHtmlSpace(String char) {
  final code = char.codeUnitAt(0);
  return code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0c ||
      code == 0x0d;
}

bool _rssIsTagNameChar(int code) =>
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    (code >= 0x30 && code <= 0x39) ||
    code == 0x2d || // -
    code == 0x3a || // :
    code == 0x5f; // _

bool _rssIsAttrNameChar(String char) {
  if (_rssIsHtmlSpace(char)) return false;
  return char != '=' && char != '>' && char != '/' && char != '<';
}

/// 找标签结束 `>`（引号内 `>` 不算）；未闭合返回 -1
int _rssFindTagEnd(String html, int from) {
  String? quote;
  for (var i = from; i < html.length; i++) {
    final char = html[i];
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '>') return i + 1;
  }
  return -1;
}

/// 查找 `</script` 结束标签起点（大小写不敏感，要求标签名边界）
int _rssFindScriptEndTag(String html, int from) {
  const needle = '</script';
  final lower = html.toLowerCase();
  var index = from;
  while (index < html.length) {
    final found = lower.indexOf(needle, index);
    if (found < 0) return -1;
    final after = found + needle.length;
    if (after >= html.length) return found;
    final char = lower[after];
    if (char == '>' || char == '/' || _rssIsHtmlSpace(char)) return found;
    index = found + 1;
  }
  return -1;
}

/// 单轮剥离：逐标签扫描，删除 script/srcdoc/on*/危险 URL 属性
String _rssStripPageScriptsPass(String html) {
  final out = StringBuffer();
  var index = 0;
  while (index < html.length) {
    final lt = html.indexOf('<', index);
    if (lt < 0) {
      out.write(html.substring(index));
      break;
    }
    out.write(html.substring(index, lt));
    // 注释/声明原样保留（浏览器不执行其内脚本，避免误改正文注释）
    if (html.startsWith('<!--', lt)) {
      final end = html.indexOf('-->', lt + 4);
      if (end < 0) {
        out.write(html.substring(lt));
        break;
      }
      out.write(html.substring(lt, end + 3));
      index = end + 3;
      continue;
    }
    if (lt + 1 < html.length && (html[lt + 1] == '!' || html[lt + 1] == '?')) {
      final end = _rssFindTagEnd(html, lt + 2);
      if (end < 0) {
        out.write(html.substring(lt));
        break;
      }
      out.write(html.substring(lt, end));
      index = end;
      continue;
    }
    var cursor = lt + 1;
    // `<\s*script>`：HTML 规范不允许标签名带空白，但这里保守识别为标签
    while (cursor < html.length && _rssIsHtmlSpace(html[cursor])) {
      cursor++;
    }
    var closing = false;
    if (cursor < html.length && html[cursor] == '/') {
      closing = true;
      cursor++;
      while (cursor < html.length && _rssIsHtmlSpace(html[cursor])) {
        cursor++;
      }
    }
    final nameStart = cursor;
    while (cursor < html.length &&
        _rssIsTagNameChar(html.codeUnitAt(cursor))) {
      cursor++;
    }
    final name = html.substring(nameStart, cursor).toLowerCase();
    if (name.isEmpty) {
      out.write('<');
      index = lt + 1;
      continue;
    }
    final tagEnd = _rssFindTagEnd(html, cursor);
    if (name == 'script') {
      if (closing) {
        // `</script ...>`：删到标签结束；未闭合删到结尾
        index = tagEnd < 0 ? html.length : tagEnd;
        continue;
      }
      if (tagEnd < 0) {
        // `<script` 未闭合（连 `>` 都没有）：保守删到结尾
        index = html.length;
        continue;
      }
      final rawTag = html.substring(lt, tagEnd);
      // 自闭合形式没有脚本正文，只删标签本身
      if (rawTag.trimRight().endsWith('/>')) {
        index = tagEnd;
        continue;
      }
      // 外链脚本没有脚本正文：只删开始标签，保留后续正文
      if (RegExp(r'(?:^|[\s/])src\s*=', caseSensitive: false)
          .hasMatch(rawTag)) {
        index = tagEnd;
        continue;
      }
      // 内联脚本：连同脚本正文一起删除到最近的 `</script` 结束标签
      final endStart = _rssFindScriptEndTag(html, tagEnd);
      if (endStart < 0) {
        index = html.length;
      } else {
        final endTagEnd = _rssFindTagEnd(html, endStart + 8);
        index = endTagEnd < 0 ? html.length : endTagEnd;
      }
      continue;
    }
    if (tagEnd < 0) {
      // 非 script 的未闭合标签原样保留（避免误删正文）
      out.write(html.substring(lt));
      break;
    }
    final rawTag = html.substring(lt, tagEnd);
    out.write(closing ? rawTag : _rssSanitizeTag(rawTag));
    index = tagEnd;
  }
  return out.toString();
}

/// 属性白名单式重建：删除 srcdoc、on* 与危险 URL 属性，其余原样保留
String _rssSanitizeTag(String rawTag) {
  var cursor = 1;
  while (cursor < rawTag.length && _rssIsHtmlSpace(rawTag[cursor])) {
    cursor++;
  }
  while (cursor < rawTag.length && _rssIsTagNameChar(rawTag.codeUnitAt(cursor))) {
    cursor++;
  }
  final buffer = StringBuffer(rawTag.substring(0, cursor));
  while (cursor < rawTag.length) {
    final whitespaceStart = cursor;
    while (cursor < rawTag.length && _rssIsHtmlSpace(rawTag[cursor])) {
      cursor++;
    }
    final whitespace = rawTag.substring(whitespaceStart, cursor);
    if (cursor >= rawTag.length) break;
    if (rawTag[cursor] == '>') {
      buffer.write(whitespace);
      buffer.write('>');
      cursor++;
      break;
    }
    if (rawTag[cursor] == '/' &&
        cursor + 1 < rawTag.length &&
        rawTag[cursor + 1] == '>') {
      buffer.write(whitespace);
      buffer.write('/>');
      cursor += 2;
      break;
    }
    if (rawTag[cursor] == '/') {
      buffer.write(whitespace);
      buffer.write('/');
      cursor++;
      continue;
    }
    final attrNameStart = cursor;
    while (cursor < rawTag.length && _rssIsAttrNameChar(rawTag[cursor])) {
      cursor++;
    }
    if (cursor == attrNameStart) {
      buffer.write(whitespace);
      buffer.write(rawTag[cursor]);
      cursor++;
      continue;
    }
    final attrName = rawTag.substring(attrNameStart, cursor);
    var lookahead = cursor;
    while (lookahead < rawTag.length && _rssIsHtmlSpace(rawTag[lookahead])) {
      lookahead++;
    }
    String? attrValue;
    var attrRawEnd = cursor;
    if (lookahead < rawTag.length && rawTag[lookahead] == '=') {
      cursor = lookahead + 1;
      while (cursor < rawTag.length && _rssIsHtmlSpace(rawTag[cursor])) {
        cursor++;
      }
      if (cursor < rawTag.length &&
          (rawTag[cursor] == '"' || rawTag[cursor] == "'")) {
        final quote = rawTag[cursor];
        final valueStart = cursor + 1;
        cursor++;
        while (cursor < rawTag.length && rawTag[cursor] != quote) {
          cursor++;
        }
        attrValue = rawTag.substring(valueStart, cursor);
        if (cursor < rawTag.length) cursor++; // 闭合引号
      } else {
        final valueStart = cursor;
        while (cursor < rawTag.length &&
            !_rssIsHtmlSpace(rawTag[cursor]) &&
            rawTag[cursor] != '>') {
          cursor++;
        }
        attrValue = rawTag.substring(valueStart, cursor);
      }
      attrRawEnd = cursor;
    }
    final lower = attrName.toLowerCase();
    final drop = lower == 'srcdoc' ||
        (lower.length > 2 && lower.startsWith('on')) ||
        (attrValue != null &&
            _rssUrlAttributeNames.contains(lower) &&
            _rssIsDangerousUrlValue(attrValue));
    if (drop) continue;
    buffer.write(whitespace.isEmpty ? ' ' : whitespace);
    buffer.write(rawTag.substring(attrNameStart, attrRawEnd));
  }
  return buffer.toString();
}

/// 正文/起始页 HTML 后处理（对齐 `ReadRssViewModel.clHtml`）
///
/// 1. 预注入脚本非空（[preloadScript] 优先，其次 [preloadJs]）：插入
///    `</head>` 前（有 `<head>` 时在开标签后；否则补 `<head>…</head>`
///    到最前）；
/// 2. 已存在 `</style>`：`style` 非空白时紧跟其后插入 `<style>{style}</style>`；
/// 3. 无 `</style>`：`style` 非空白用 `style`，否则用默认移动端样式，
///    插入 `</head>` 前；无 `</head>` 则插到最前。
String rssClHtml(
  String content, {
  String? style,
  String? preloadJs,
  String? preloadScript,
}) {
  final buffer = StringBuffer();
  final scriptTag = _preloadScriptTag(preloadJs, preloadScript);
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

/// singleUrl 订阅源打开分流（对齐 `RssFragment.openRss`，`RssFragment.kt:180-196`）
///
/// 原版：`url.startsWith("http", true)` → `ReadRssActivity.start(..., url)`
/// （站内阅读 WebView URL 直开）；否则 `context?.openUrl(url)`（系统处理）。
/// 本函数按 scheme 精确判定 http/https，避免 `httpx:` 之类误命中。
bool rssIsHttpUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
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
