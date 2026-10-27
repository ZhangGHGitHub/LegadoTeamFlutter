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

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

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

/// 桥模式页面脚本隔离（批21c P0-2，批21e P0 改用 HTML5 DOM 解析，
/// 批21f P0 修复 mXSS）
///
/// 启用宿主桥（源 `preloadJs` 非空且 `enableJs`）时，先把文章/起始页 HTML
/// 中的**页面脚本**剥离，再由调用方注入应用自己的可信脚本（`startJs`/
/// 桥组合脚本）。相对原版这是本地加固差异：原版经 `shouldInterceptRequest`
/// 用外部子资源注入桥（桥不在 DOM），Flutter WebView 无该拦截面，只能内联；
/// 剥离后页面内不存在应用注入之外的 `<script>` 标签。
///
/// 批21d 的手写「逐标签扫描 + 不动点」会被 HTML5 容忍解析绕过（`<!-->`
/// 提前闭合注释、`<!x ">`/`<?x ">` 伪注释引号失配、无引号属性内含引号），
/// 批21e 起改用与浏览器一致的 HTML5 解析器（`package:html`）构建 DOM。
///
/// 批21f P0：**DOM 往返本身会制造 mXSS**。foreign content（`<svg>`/`<math>`
/// 子树）中的 `style`/`xmp`/`noscript`/`iframe` 等元素，其文本节点在
/// `package:html` 序列化时按 HTML rawtext 原样输出——输入里实体编码的
/// `&lt;script&gt;` 在首轮解析时被解码为文本，序列化后变成字面
/// `<script>…</script>`，浏览器二次解析即执行（终审 5 条 Chrome 向量
/// `document.title=41..45`）。因此清洗规则调整为：
/// 1. `parse(html)` 构建 DOM（HTML5 容忍解析；浏览器渲染同一字符串得到同一
///    树，因此不存在「词法扫描看不到但浏览器执行」的残余标签）；
/// 2. **整体删除 `<svg>`、`<math>`、`<plaintext>` 子树**（阅读场景可接受；
///    登记功能损失）：foreign content 的序列化差异是 mXSS 根因；
///    `plaintext` 无结束标签语义（序列化补 `</plaintext>` 后被解析器当
///    文本吞掉，逐轮增长破坏不动点，批21g P2-1）；
/// 3. 删除所有 `script` 元素（含外链/内联/自闭合）；`noscript` 内容按
///    HTML5 解析为 rawtext（不执行脚本），保留；
/// 4. 删除 `<meta http-equiv=refresh>`（可触发非用户手势导航）与 CSP meta
///    （`content-security-policy` / `-report-only`，避免页面策略影响注入）；
/// 5. 删除 `srcdoc` 与所有 `on*` 内联事件属性（大小写不敏感）；
/// 6. URL 属性（href/src/action/formaction/xlink:href/poster/background/
///    cite/longdesc/usemap/manifest/ping/data）值经 HTML 实体解码 + 控制字符
///    剔除后判 scheme，拒绝 `javascript:` / `vbscript:` /
///    `data:text/html` / `data:image/svg+xml` /
///    `data:application/xhtml+xml`；`iframe`/`object`/`embed` 的 `src`/`data`
///    额外拒绝**全部** `data:` 文档（批21e P2-3）；
/// 7. 删除注释节点；
/// 8. `document.outerHtml` 序列化回字符串；
/// 9. **不动点自检**：对序列化结果重新解析并清洗，直到连续两轮结果一致
///    （上限 3 轮），保证 `strip(strip(x)) == strip(x)`。
///
/// **已知差异（契约 §2.5 批21e/21f 已登记）**：DOM 解析会重排/补全标签
/// （例如片段补 `<html><head><body>`、自闭合标签规范化），删除注释节点；
/// 相对批21d 修正 `<style>/<title>/<textarea>/<noscript>` 内字面 `<script>`
/// 被误删的问题（rawtext/RCDATA 语义下它们不是元素；`<pre>` 内未转义
/// `<script>` 是真实元素，浏览器同样执行，仍删除）。**SVG/MathML 内容整体
/// 丢失**为批21f 安全优先的功能损失（含 SVG 图片/公式）；**`<plaintext>`
/// 子树整体丢失**为批21g 不动点修复的功能损失。
String rssStripPageScripts(String html) {
  if (html.isEmpty) return html;
  var current = html;
  String? previous;
  // 不动点：最多 3 轮；连续两轮一致即提前结束
  for (var round = 0; round < 3; round++) {
    final next = _rssStripPageScriptsOnce(current);
    if (previous != null && next == previous) {
      current = next;
      break;
    }
    previous = next;
    current = next;
  }
  // 运行时断言（debug/test）：清洗结果必须通过安全自检；release 不额外解析
  assert(
    isSanitizedHtmlSafe(current),
    'rssStripPageScripts 结果未通过安全自检（mXSS 回归）',
  );
  return current;
}

/// 单轮清洗（[rssStripPageScripts] 的不动点内核）
String _rssStripPageScriptsOnce(String html) {
  final document = html_parser.parse(html);

  // 1) 整体删除 foreign content 根（SVG/MathML）与 `<plaintext>`：
  //    foreign content 子树在序列化时可能按 HTML rawtext 输出（批21f
  //    终审 mXSS 根源）；`plaintext` 更特殊——序列化会补 `</plaintext>`，
  //    而解析器不会再识别结束标签（其内容吞到 EOF），逐轮解析/序列化会
  //    不断增长，破坏 `strip(strip(x)) == strip(x)` 不动点（批21g P2-1）。
  //    两者在阅读场景均可接受整体删除（登记为功能损失）。
  final removedRoots = <dom.Element>[];
  for (final element in document.querySelectorAll('*')) {
    final tag = element.localName;
    if (tag == 'svg' || tag == 'math' || tag == 'plaintext') {
      removedRoots.add(element);
    }
  }
  for (final element in removedRoots) {
    element.remove();
  }

  // 2) meta refresh / CSP（refresh 可产生非用户手势跨文档导航）
  for (final element in document.querySelectorAll('meta')) {
    if (_rssIsBlockedMeta(element)) element.remove();
  }

  // 3) script 元素（noscript 内容由解析器按 rawtext 保留，无元素可删）
  for (final element in document.querySelectorAll('script')) {
    element.remove();
  }

  // 4) srcdoc / on* / 危险 URL 属性
  for (final element in document.querySelectorAll('*')) {
    final rejectAllData =
        _rssEmbeddedDocumentTags.contains(element.localName);
    final keys = element.attributes.keys.toList(growable: false);
    for (final key in keys) {
      final name = key.toString().toLowerCase();
      final value = element.attributes[key] ?? '';
      final drop = name == 'srcdoc' ||
          (name.length > 2 && name.startsWith('on')) ||
          (_rssUrlAttributeNames.contains(name) &&
              _rssIsDangerousUrlValue(value, rejectAllData: rejectAllData));
      if (!drop) continue;
      element.attributes.remove(key);
    }
  }

  // 5) 注释节点
  _rssRemoveCommentNodes(document);

  // 序列化：调用方得到的是浏览器实际渲染的同一棵树（DOM 规范化属已登记
  // 差异），避免「词法看似安全、渲染仍有残余」分叉。
  return document.outerHtml;
}

/// 清洗结果安全自检（纯函数；测试与运行时断言共用）
///
/// 口径与 [rssStripPageScripts] 一致：用同一 HTML5 解析器重新解析后，
/// 以下任一存在即不安全：
/// - `script` 元素（含外链/内联）；
/// - `svg` / `math` / `plaintext` 元素（foreign content 子树 / 吞文档的
///   rawtext 根）；
/// - `on*` 内联事件、`srcdoc`；
/// - URL 属性命中危险 scheme（`iframe`/`object`/`embed` 拒绝全部 `data:`）；
/// - `meta http-equiv=refresh` / CSP meta。
///
/// 注意：本函数**不**校验注释节点（注释不可执行，清洗另行删除）。
bool isSanitizedHtmlSafe(String html) {
  final document = html_parser.parse(html);
  if (document.querySelectorAll('script').isNotEmpty) return false;
  for (final element in document.querySelectorAll('*')) {
    final tag = element.localName;
    if (tag == 'svg' || tag == 'math' || tag == 'plaintext') return false;
    if (tag == 'meta' && _rssIsBlockedMeta(element)) return false;
    final rejectAllData = _rssEmbeddedDocumentTags.contains(tag);
    for (final entry in element.attributes.entries) {
      final name = entry.key.toString().toLowerCase();
      if (name == 'srcdoc') return false;
      if (name.length > 2 && name.startsWith('on')) return false;
      if (_rssUrlAttributeNames.contains(name) &&
          _rssIsDangerousUrlValue(
            entry.value,
            rejectAllData: rejectAllData,
          )) {
        return false;
      }
    }
  }
  return true;
}

/// 需整体删除的 meta（refresh / CSP；属性名大小写不敏感）
bool _rssIsBlockedMeta(dom.Element element) {
  if (element.localName != 'meta') return false;
  String? httpEquiv;
  for (final entry in element.attributes.entries) {
    if (entry.key.toString().toLowerCase() == 'http-equiv') {
      httpEquiv = entry.value.trim().toLowerCase();
      break;
    }
  }
  if (httpEquiv == null) return false;
  return httpEquiv == 'refresh' ||
      httpEquiv == 'content-security-policy' ||
      httpEquiv == 'content-security-policy-report-only';
}

/// 嵌入文档标签：其 `src`/`data` 指向的 `data:` 文档一律拒绝
const Set<String> _rssEmbeddedDocumentTags = <String>{
  'iframe',
  'object',
  'embed',
};

/// 递归删除注释节点（返回是否删除过）
bool _rssRemoveCommentNodes(dom.Node node) {
  var removed = false;
  for (final child in node.nodes.toList(growable: false)) {
    if (child is dom.Comment) {
      child.remove();
      removed = true;
      continue;
    }
    if (child.nodes.isNotEmpty) {
      removed = _rssRemoveCommentNodes(child) || removed;
    }
  }
  return removed;
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
///
/// [rejectAllData]：`iframe`/`object`/`embed` 的 `src`/`data` 指向的
/// 任何 `data:` 文档都拒绝（内嵌文档可自带脚本）。
bool _rssIsDangerousUrlValue(String value, {bool rejectAllData = false}) {
  final decoded = _rssDecodeHtmlEntities(value)
      .replaceAll(RegExp(r'[\u0000-\u0020\u007f]+'), '')
      .toLowerCase();
  if (decoded.startsWith('javascript:') || decoded.startsWith('vbscript:')) {
    return true;
  }
  if (decoded.startsWith('data:text/html') ||
      decoded.startsWith('data:image/svg+xml') ||
      decoded.startsWith('data:application/xhtml+xml')) {
    return true;
  }
  return rejectAllData && decoded.startsWith('data:');
}

/// 正文/起始页 HTML 后处理（对齐 `ReadRssViewModel.clHtml`）
///
/// 1. 预注入脚本非空（[preloadScript] 优先，其次 [preloadJs]）：插入
///    真实 `<head>` 开标签后（无 `<head>` 时补 `<head>…</head>` 到最前）；
/// 2. 已存在真实 `</style>`：`style` 非空白时紧跟其后插入
///    `<style>{style}</style>`；
/// 3. 无 `</style>`：`style` 非空白用 `style`，否则用默认移动端样式，
///    插入真实 `</head>` 前；无 `</head>` 则插到最前。
///
/// 批21g P3-4：插入点由 [_rssFindTagPositions] 定位——跳过注释与
/// rawtext/RCDATA（`script`/`style`/`xmp`/`iframe`/`noembed`/`noframes`/
/// `noscript`/`plaintext`/`title`/`textarea`）内的**字面**标签，避免把
/// 应用脚本/样式注入文本节点（例如 `<title></head></title>`、
/// `<xmp></body></xmp>` 中的伪结束标签）。本函数只做字符串插入、**不**
/// 重新序列化正文，因此对未清洗 HTML 也不会引入 DOM 往返 mXSS。
String rssClHtml(
  String content, {
  String? style,
  String? preloadJs,
  String? preloadScript,
}) {
  final positions = _rssFindTagPositions(content);
  final scriptTag = _preloadScriptTag(preloadJs, preloadScript);
  var html = content;
  var styleCloseEnd = positions.firstStyleCloseEnd;
  var headCloseStart = positions.headCloseStart;
  if (scriptTag != null) {
    final headOpenEnd = positions.headOpenEnd;
    if (headOpenEnd != null) {
      html = '${content.substring(0, headOpenEnd)}$scriptTag'
          '${content.substring(headOpenEnd)}';
      // 后面的插入点整体后移（脚本标签长度）
      final shift = scriptTag.length;
      if (styleCloseEnd != null && styleCloseEnd >= headOpenEnd) {
        styleCloseEnd += shift;
      }
      if (headCloseStart != null && headCloseStart >= headOpenEnd) {
        headCloseStart += shift;
      }
    } else {
      final prefix = '<head>$scriptTag</head>';
      html = '$prefix$content';
      final shift = prefix.length;
      if (styleCloseEnd != null) styleCloseEnd += shift;
      // 补出的 head：样式插到其 `</head>` 前（与旧实现一致）
      headCloseStart = shift - '</head>'.length;
    }
  }
  final trimmedStyle = style?.trim() ?? '';
  if (styleCloseEnd != null) {
    if (trimmedStyle.isEmpty) return html;
    return '${html.substring(0, styleCloseEnd)}<style>$trimmedStyle</style>'
        '${html.substring(styleCloseEnd)}';
  }
  final finalStyle = trimmedStyle.isEmpty
      ? kRssDefaultContentStyle
      : trimmedStyle;
  if (headCloseStart != null) {
    return '${html.substring(0, headCloseStart)}<style>$finalStyle</style>'
        '${html.substring(headCloseStart)}';
  }
  return '<style>$finalStyle</style>$html';
}

/// 起始页注入 `startJs`（对齐 `ReadRssViewModel.loadStartHtml`）
///
/// `startJs` 空白时原样返回；有真实 `</body>` 时插在其前，否则包装
/// `<body>{html}<script>{js}</script></body>`。脚本正文不 trim（与原版一致，
/// 仅用 trim 判定空）。
///
/// 批21g P3-4：`</body>` 同样跳过 rawtext/RCDATA/注释内的字面标签，
/// 避免脚本被注入文本节点而完全不执行。
String rssInjectStartJs(String startHtml, String? startJs) {
  final js = startJs ?? '';
  if (js.trim().isEmpty) return startHtml;
  final bodyCloseStart = _rssFindTagPositions(startHtml).bodyCloseStart;
  if (bodyCloseStart != null) {
    return '${startHtml.substring(0, bodyCloseStart)}<script>$js</script>'
        '${startHtml.substring(bodyCloseStart)}';
  }
  return '<body>$startHtml<script>$js</script></body>';
}

/// 文档内真实标签位置（批21g P3-4）
///
/// 只用于选择字符串插入点，不改写正文。解析口径是 HTML5 tokenizer 的
/// 简化版：跳过注释/声明/伪注释，按 rawtext/RCDATA 语义跳过文本内容，
/// 属性扫描区分引号与无引号值（与包 `html` 的容忍解析一致）。
class _RssTagPositions {
  /// 首个真实 `<head>` 开标签结束后的下标
  int? headOpenEnd;

  /// 首个真实 `</head>` 起始下标
  int? headCloseStart;

  /// 首个真实 `</body>` 起始下标
  int? bodyCloseStart;

  /// 首个真实 `</style>` 结束后的下标
  int? firstStyleCloseEnd;
}

/// 无结束标签语义（内容吞到 EOF）
const String _rssPlaintextTag = 'plaintext';

/// rawtext 元素（内容不按标签解析，直到匹配的结束标签）
const Set<String> _rssRawTextTags = <String>{
  'script',
  'style',
  'xmp',
  'iframe',
  'noembed',
  'noframes',
  'noscript',
  _rssPlaintextTag,
};

/// RCDATA 元素（内容不按标签解析，实体仍解码）
const Set<String> _rssRcdataTags = <String>{
  'title',
  'textarea',
};

_RssTagPositions _rssFindTagPositions(String html) {
  final positions = _RssTagPositions();
  final length = html.length;
  var i = 0;
  while (i < length) {
    final lt = html.indexOf('<', i);
    if (lt < 0) break;
    if (html.startsWith('<!--', lt)) {
      i = _rssSkipComment(html, lt);
      continue;
    }
    // 声明/伪注释（`<!DOCTYPE>`/`<!x ">`/`<?x ">`）：浏览器在首个 `>` 结束
    if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
      final gt = html.indexOf('>', lt + 2);
      i = gt < 0 ? length : gt + 1;
      continue;
    }
    if (html.startsWith('</', lt)) {
      final nameStart = lt + 2;
      final nameEnd = _rssTagNameEnd(html, nameStart);
      final name = html.substring(nameStart, nameEnd).toLowerCase();
      final gt = _rssTagEnd(html, nameEnd);
      if (gt < 0) break;
      if (name == 'head' && positions.headCloseStart == null) {
        positions.headCloseStart = lt;
      } else if (name == 'body' && positions.bodyCloseStart == null) {
        positions.bodyCloseStart = lt;
      } else if (name == 'style' && positions.firstStyleCloseEnd == null) {
        positions.firstStyleCloseEnd = gt + 1;
      }
      i = gt + 1;
      continue;
    }
    final nameStart = lt + 1;
    final nameEnd = _rssTagNameEnd(html, nameStart);
    if (nameEnd == nameStart) {
      // 孤立的 `<`：按普通文本跳过
      i = lt + 1;
      continue;
    }
    final name = html.substring(nameStart, nameEnd).toLowerCase();
    final gt = _rssTagEnd(html, nameEnd);
    if (gt < 0) break;
    if (name == 'head' && positions.headOpenEnd == null) {
      positions.headOpenEnd = gt + 1;
    }
    if (_rssRawTextTags.contains(name) || _rssRcdataTags.contains(name)) {
      if (name == _rssPlaintextTag) {
        // plaintext 无结束标签语义：剩余文档全部是文本
        break;
      }
      final closeEnd = _rssFindRawTextCloseEnd(html, gt + 1, name);
      if (closeEnd < 0) {
        // 未闭合的 rawtext/RCDATA：后续内容全在文本里
        break;
      }
      if (name == 'style' && positions.firstStyleCloseEnd == null) {
        positions.firstStyleCloseEnd = closeEnd;
      }
      i = closeEnd;
      continue;
    }
    i = gt + 1;
  }
  return positions;
}

/// 跳过注释（HTML5 容忍语义：`<!-->`/`<!--->` 是空注释）
int _rssSkipComment(String html, int start) {
  final length = html.length;
  var i = start + 4;
  if (i >= length) return length;
  if (html.codeUnitAt(i) == 0x3E) return i + 1; // <!-->
  if (i + 1 < length &&
      html.codeUnitAt(i) == 0x2D &&
      html.codeUnitAt(i + 1) == 0x3E) {
    return i + 2; // <!--->
  }
  final normal = html.indexOf('-->', i);
  final bang = html.indexOf('--!>', i);
  if (normal < 0 && bang < 0) return length; // 未闭合注释吞到 EOF
  if (normal < 0) return bang + 4;
  if (bang < 0) return normal + 3;
  return normal <= bang ? normal + 3 : bang + 4;
}

/// 标签名结束位置（空白、`/`、`>` 或 EOF）
int _rssTagNameEnd(String html, int start) {
  final length = html.length;
  var i = start;
  while (i < length) {
    final c = html.codeUnitAt(i);
    if (_rssIsTagWhitespace(c) || c == 0x2F || c == 0x3E) break;
    i++;
  }
  return i;
}

/// 标签结束 `>` 的位置（属性扫描；引号/无引号值与 HTML5 一致）
int _rssTagEnd(String html, int start) {
  final length = html.length;
  var i = start;
  while (i < length) {
    final c = html.codeUnitAt(i);
    if (c == 0x3E) return i;
    if (_rssIsTagWhitespace(c) || c == 0x2F) {
      i++;
      continue;
    }
    // 属性名
    final nameStart = i;
    while (i < length) {
      final d = html.codeUnitAt(i);
      if (_rssIsTagWhitespace(d) || d == 0x2F || d == 0x3E || d == 0x3D) {
        break;
      }
      i++;
    }
    if (i == nameStart) {
      i++;
      continue;
    }
    while (i < length && _rssIsTagWhitespace(html.codeUnitAt(i))) {
      i++;
    }
    if (i >= length) return -1;
    if (html.codeUnitAt(i) != 0x3D) continue; // 无属性值
    i++; // '='
    while (i < length && _rssIsTagWhitespace(html.codeUnitAt(i))) {
      i++;
    }
    if (i >= length) return -1;
    final quote = html.codeUnitAt(i);
    if (quote == 0x22 || quote == 0x27) {
      i++;
      while (i < length && html.codeUnitAt(i) != quote) {
        i++;
      }
      if (i < length) i++;
      continue;
    }
    // 无引号属性值：到空白或 `>` 结束（`<div x=a">` 中的引号属于值）
    while (i < length) {
      final d = html.codeUnitAt(i);
      if (_rssIsTagWhitespace(d) || d == 0x3E) break;
      i++;
    }
  }
  return -1;
}

/// 匹配 rawtext/RCDATA 结束标签后的位置（无匹配返回 -1）
int _rssFindRawTextCloseEnd(String html, int from, String name) {
  final length = html.length;
  var i = from;
  while (i < length) {
    final lt = html.indexOf('</', i);
    if (lt < 0) return -1;
    final nameStart = lt + 2;
    final nameEnd = _rssTagNameEnd(html, nameStart);
    if (nameEnd - nameStart == name.length &&
        html.substring(nameStart, nameEnd).toLowerCase() == name) {
      final gt = _rssTagEnd(html, nameEnd);
      if (gt < 0) return -1;
      return gt + 1;
    }
    i = lt + 2;
  }
  return -1;
}

/// HTML5 标签内空白（空格 / `\t` / `\n` / `\f` / `\r`）
bool _rssIsTagWhitespace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;


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
  var java = (window.__rssJava = window.__rssJava || {});
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
  if (window.__rssJava) return;
  var noop = function(){};
  window.__rssJava = {
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
  if (window.__rssConsoleHooked) return;
  window.__rssConsoleHooked = true;
  window.__rssConsoleLogs = [];
  var levels = ['log', 'info', 'warn', 'error', 'debug'];
  levels.forEach(function(level){
    var original = console[level];
    console[level] = function(){
      try {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
          try { parts.push(String(arguments[i])); } catch (e) { parts.push('[object]'); }
        }
        window.__rssConsoleLogs.push(level + ': ' + parts.join(' '));
        if (window.__rssConsoleLogs.length > 200) {
          window.__rssConsoleLogs.splice(0, window.__rssConsoleLogs.length - 200);
        }
      } catch (e) {}
      if (original) { try { original.apply(console, arguments); } catch (e) {} }
    };
  });
})();
''';

/// 回读并清空 console 缓冲（返回 JSON 数组字符串）
const String kRssConsoleFlushScript =
    '(function(){var logs=window.__rssConsoleLogs||[];'
    'window.__rssConsoleLogs=[];return JSON.stringify(logs);})()';

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
