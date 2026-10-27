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

  /// 其他（提示不支持）
  unsupported,
}

/// 按「口令 → 链接 → JSON → 其他」顺序分流
SharedTextKind classifySharedText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return SharedTextKind.unsupported;
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
    try {
      jsonDecode(text);
      return SharedTextKind.json;
    } on FormatException {
      return SharedTextKind.unsupported;
    }
  }
  return SharedTextKind.unsupported;
}
