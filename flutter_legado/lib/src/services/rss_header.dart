/// RSS 源请求头解析（批15f）
///
/// 原版 `RssSource.getHeaderMap()` 经 JS 求值得到 header map；Dart 侧无 JS
/// 引擎，且列表/详情封面图由 `CachedNetworkImage` 直接发起请求，无法复用
/// Rust 请求链。此处只做**静态解析**（JSON 对象 / 逐行 `Key: Value`），
/// 覆盖绝大多数防盗链配置；`@js:` / `<js>` 动态 header 与 `coverDecodeJs`
/// 解密不在本批（登记 15g）。
library;

import 'dart:convert';

/// 解析 RSS 源 `header` 字段为 header map
///
/// 口径对齐既有书源/漫画实现（`reader_comic_screen.dart::_parseHeaderMap`）：
/// 1. 空串 → 空 map；
/// 2. 以 `{` 开头 → 按 JSON 对象解析（值 `toString()`）；
/// 3. JSON 解析失败或非对象 → 逐行按第一个 `:` 拆分（行内无 `:` 忽略）；
/// 4. 键/值 trim。
Map<String, String> parseRssHeaderMap(String? header) {
  final trimmed = header?.trim() ?? '';
  if (trimmed.isEmpty) return const {};
  // 动态 header（JS 求值形态）Dart 无引擎，不解析（登记 15g）
  if (trimmed.startsWith('@js:') || trimmed.startsWith('<js>')) {
    return const {};
  }
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return {
          for (final entry in decoded.entries) entry.key: '${entry.value}',
        };
      }
    } catch (_) {
      // 非法 JSON → 走逐行解析
    }
  }
  final map = <String, String>{};
  for (final line in trimmed.split('\n')) {
    final idx = line.indexOf(':');
    if (idx > 0) {
      map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
  }
  return map;
}

/// 用户代理（header 名大小写不敏感；原版 `headerMap["User-Agent"]`）
///
/// 命中返回值非空的第一个 `user-agent`（大小写不敏感）；未配置返回 `null`。
String? rssHeaderUserAgent(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent' &&
        entry.value.trim().isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}
