// 外部分享文本分流（批25）
//
// 对齐 Android 原版 `SharedReceiverActivity` 的接收面（ACTION_SEND /
// ACTION_PROCESS_TEXT，text/plain），并按本批授权口径把分流扩展为：
// 分享口令 → 口令导入；http(s) URL → 打开确认；legado:// / yuedu:// →
// 关联导入；JSON 文本 → 关联导入；其余 → 明确提示不支持。
//
// 原版仅把分享文本全部当搜索词：多 URL 时回首页，否则进入搜索页。
// 该差异已登记（本批为用户授权超集）。
import 'dart:convert';

import '../services/source_share_passphrase.dart';

/// 分享文本 UTF-8 字节上限（批25b）：超过即拒绝解析并明确提示，
/// 避免超大文本拖垮分流与导入链路。
const int maxSharedTextBytes = 1024 * 1024;

/// JSON 最大嵌套层级（批25b）：超深 JSON 在 `jsonDecode` 递归解析中可能
/// 触发栈溢出，先做深度扫描直接拒绝。
const int maxJsonDepth = 64;

/// 分享文本类型
enum SharedTextKind {
  /// 源分享口令（含「复制口令到阅读导入」前缀）
  passphrase,

  /// http:// / https:// 链接
  httpUrl,

  /// legado:// / yuedu:// 关联导入协议
  importScheme,

  /// 合法 JSON（对象或数组）
  json,

  /// 超过 [maxSharedTextBytes] 的文本（拒绝解析）
  tooLarge,

  /// 嵌套层级超过 [maxJsonDepth] 的 JSON（拒绝解析）
  tooDeepJson,

  /// 其他（提示不支持）
  unsupported,
}

/// 按「超限 → 口令 → 链接 → JSON → 其他」顺序分流
SharedTextKind classifySharedText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return SharedTextKind.unsupported;
  if (utf8.encode(text).length > maxSharedTextBytes) {
    return SharedTextKind.tooLarge;
  }
  if (SourceSharePassphrase.looksLikePassphrase(text)) {
    return SharedTextKind.passphrase;
  }
  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return SharedTextKind.httpUrl;
  }
  if (lower.startsWith('legado://') || lower.startsWith('yuedu://')) {
    return SharedTextKind.importScheme;
  }
  final first = text.codeUnitAt(0);
  if (first == 0x7B || first == 0x5B) {
    // '{' / '['
    // 先做深度预检：Dart 的递归下降解析在超深输入下会抛 StackOverflowError，
    // 该 Error 在栈耗尽时不可安全捕获/恢复，只能提前拒绝；
    // 其余解析失败（FormatException）按「不支持」处理，不向上抛。
    if (!_isJsonWithinDepthLimit(text)) return SharedTextKind.tooDeepJson;
    try {
      jsonDecode(text);
      return SharedTextKind.json;
    } on FormatException {
      return SharedTextKind.unsupported;
    }
  }
  return SharedTextKind.unsupported;
}

/// JSON 嵌套深度是否不超过 [maxJsonDepth]
///
/// 扫描时跳过字符串字面量（含 `\` 转义），字符串内的括号不计入深度；
/// 只做深度预检，JSON 语法合法性仍由 [jsonDecode] 判定。
bool _isJsonWithinDepthLimit(String text) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5C) {
        // '\'
        escaped = true;
      } else if (code == 0x22) {
        // '"'
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
      continue;
    }
    if (code == 0x7B || code == 0x5B) {
      // '{' / '['
      depth++;
      if (depth > maxJsonDepth) return false;
    } else if (code == 0x7D || code == 0x5D) {
      // '}' / ']'
      depth--;
    }
  }
  return true;
}
