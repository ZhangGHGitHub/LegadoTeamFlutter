// 书源 URL 匹配与复合 URL 解析（C4/C7 共用）
//
// 背景：
// - 书架「添加网址」与 RSS WebView `java.addBook` 都需要「按 URL 找书源」；
// - 此前书架侧自实现一份 Dart 正则匹配（C7 已下沉 FFI），RSS 侧无实现 →
//   若各自再写会形成第三份。
//
// 本文件是**唯一** Dart 侧入口：
// - 正则判定走 FFI `matchesBookUrlPattern`（Rust 唯一真源，锚定全匹配）；
// - 主域名兜底保留 Dart（纯 host 相等比较，无正则语义分叉风险）。
//
// 对齐原版：
// - `AddToBookshelfDialog.ViewModel.load`（`app/.../ui/association/AddToBookshelfDialog.kt:104-147`）
//   的三段匹配顺序：UrlOption.origin → `getBookSourceAddBook(baseUrl)` →
//   `hasBookUrlPattern` 逐条正则；
// - `NetworkUtils.getBaseUrl`（`NetworkUtils.kt:192-204`）的
//   `scheme://authority` 口径与 `@js:` 前缀剥离。

import 'dart:convert';

import '../models/models.dart';
import '../services/book_api.dart';

/// 复合书籍 URL 的解析结果
///
/// 输入形如 `https://host/book/1,{"origin":"https://source"}`：
/// - [url] 为剥离 `,{json}` 后缀后的可请求地址；
/// - [origin] 为 UrlOption 中的 `origin`（指定书源 bookSourceUrl），可为 null。
class BookUrlOption {
  const BookUrlOption({required this.url, this.origin});

  /// 纯 URL（已剥离 `,{json}` 复合后缀）
  final String url;

  /// UrlOption 指定的书源 URL（对齐 `UrlOption.getOrigin()`）
  final String? origin;

  @override
  String toString() => 'BookUrlOption(url: $url, origin: $origin)';
}

/// 解析书籍 URL 的复合参数（对齐 `AnalyzeUrl.paramPattern = \s*,\s*(?=\{)`）
///
/// 无 `,{json}` 后缀、JSON 非法、或 `origin` 为空/非字符串时 fail-closed：
/// 保留原 URL、origin 为 null（不抛错，避免坏数据阻断添加）。
BookUrlOption parseBookUrlOption(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const BookUrlOption(url: '');
  final sep = RegExp(r'\s*,\s*(?=\{)').firstMatch(trimmed);
  if (sep == null) return BookUrlOption(url: trimmed);
  final url = trimmed.substring(0, sep.start).trim();
  final jsonPart = trimmed.substring(sep.end);
  String? origin;
  try {
    final decoded = jsonDecode(jsonPart);
    if (decoded is Map) {
      final value = decoded['origin'];
      if (value is String && value.trim().isNotEmpty) {
        origin = value.trim();
      }
    }
  } catch (_) {
    // 复合后缀非法 JSON：按纯 URL 处理
  }
  return BookUrlOption(
    url: url.isEmpty ? trimmed : url,
    origin: origin,
  );
}

/// 解析书源 URL 的基地址（对齐 `NetworkUtils.getBaseUrl`）
///
/// - `@js:` 之后的部分不是传输 URL，先截断；
/// - 仅接受 http/https，且 host 非空；否则返回 null。
String? bookUrlBase(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final jsIndex = trimmed.toLowerCase().indexOf('@js:');
  final target = jsIndex >= 0 ? trimmed.substring(0, jsIndex) : trimmed;
  final lower = target.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return null;
  }
  final uri = Uri.tryParse(target);
  if (uri == null || uri.host.isEmpty) return null;
  return '${target.substring(0, target.indexOf('://'))}://${uri.authority}';
}

/// 按 URL 匹配书源（对齐 `AddToBookshelfDialog.ViewModel.load` 三段顺序）
///
/// 1. [preferredOrigin]（UrlOption 的 `origin`）精确命中 `bookSourceUrl`；
/// 2. `bookSourceUrl` 与 URL 基地址相等（去尾斜杠归一，兼容存量源）；
/// 3. 逐条 `bookUrlPattern` 正则（**FFI** `matchesBookUrlPattern`，全匹配语义）；
/// 4. 主域名兜底（host 相等，对齐既有书架行为）。
///
/// [sources] 应为**已启用**书源列表（调用方负责过滤）。
Future<BookSource?> matchBookSourceForUrl(
  BookApi api,
  List<BookSource> sources,
  String url, {
  String? preferredOrigin,
}) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  String norm(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');

  // 1. UrlOption 指定源（对齐 `getBookSource(it)`）
  final origin = preferredOrigin?.trim() ?? '';
  if (origin.isNotEmpty) {
    for (final s in sources) {
      if (s.bookSourceUrl == origin || norm(s.bookSourceUrl) == norm(origin)) {
        return s;
      }
    }
  }

  // 2. 基地址精确命中（对齐 `getBookSourceAddBook(baseUrl)`）
  final base = bookUrlBase(trimmed);
  if (base != null) {
    final normBase = norm(base);
    for (final s in sources) {
      if (norm(s.bookSourceUrl) == normBase) return s;
    }
  }

  // 3. bookUrlPattern 逐条正则（Rust 唯一真源；非法 pattern 由 Rust 静默 false）
  for (final s in sources) {
    final pattern = s.bookUrlPattern;
    if (pattern == null || pattern.trim().isEmpty) continue;
    if (await api.matchesBookUrlPattern(pattern, trimmed)) return s;
  }

  // 4. 主域名兜底（原版无此段，属既有 Flutter 侧放宽，保留以兼容存量源）
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) {
    for (final s in sources) {
      final sUri = Uri.tryParse(s.bookSourceUrl);
      if (sUri != null && sUri.host == uri.host) return s;
    }
  }
  return null;
}
