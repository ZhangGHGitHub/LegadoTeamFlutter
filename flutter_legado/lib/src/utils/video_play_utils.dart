// 视频播放地址解析（对齐原版 VideoPlay + AnalyzeUrl.headerMap）
// — Reasonix + UI

import 'dart:convert';

import 'comic_image_utils.dart';
import 'url_utils.dart';

/// 默认桌面 Chrome UA（书源未配置 header 时 CDN/HLS 常校验 UA）
const String kDefaultVideoUserAgent =
    'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/101.0.4951.61 Mobile Safari/537.36';

/// 播放目标：直链 / 复合 URL 解析后的纯 URL + header，或 MPD 清单文本
class VideoPlayTarget {
  /// 可交给播放器的 http(s) URL（MPD 时为空，改用 [mpdContent]）
  final String url;

  /// 防盗链 / UrlOption headers（对齐 AnalyzeUrl.headerMap）
  final Map<String, String> headers;

  /// MPD/DASH 清单原文（非空时需写临时文件后以 file 播放）
  final String? mpdContent;

  const VideoPlayTarget({
    required this.url,
    this.headers = const {},
    this.mpdContent,
  });

  bool get isMpd => mpdContent != null && mpdContent!.isNotEmpty;
}

/// 音视频正文准备：去掉副内容污染行；MPD 保留完整 XML。
///
/// 原版视频 `subContent` 走 putDanmaku，不拼进播放链接；重构曾误拼 `\n`+副内容，
/// 导致 `_extractVideoUrl` / MPD 判定失败。
String prepareVideoContent(String content) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) return '';
  // 对齐 VideoPlay：MPD/DASH 清单保留全文；HTML 壳交 extract 抽 src
  if (isMpdVideoContent(trimmed)) return trimmed;
  for (final line in trimmed.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isNotEmpty) return t;
  }
  return trimmed;
}

/// 是否 MPD/DASH 清单（对齐 VideoPlay「`<` 开头当 MPD」意图，但排除 HTML 壳）
bool isMpdVideoContent(String content) {
  final t = content.trimLeft();
  if (!t.startsWith('<')) return false;
  final upper = t.toUpperCase();
  // 明确 DASH/MPD；`<?xml ...><MPD` 也算
  if (upper.startsWith('<MPD') || upper.startsWith('<?XML')) return true;
  if (upper.contains('<MPD') || upper.contains('URN:MPEG:DASH:SCHEMA:MPD')) {
    return true;
  }
  // 纯 `<` 开头但像 HTML 播放器页 → 交给 extractVideoUrl 抽 src
  return false;
}

/// 是否像可播视频/流地址（含无后缀的 CDN 路径，如非凡 vip.ffzy-plays）
bool looksLikeVideoUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final base = isCompositeImageUrl(trimmed)
      ? trimmed.substring(0, trimmed.indexOf(',{'))
      : trimmed;
  final lower = base.toLowerCase();
  if (!(lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('//'))) {
    return false;
  }
  if (RegExp(r'\.(m3u8|mp4|flv|mkv|webm|mov)(\?|#|$)', caseSensitive: false)
      .hasMatch(lower)) {
    return true;
  }
  // MacCMS / 常见播放 CDN（无扩展名直链）
  if (lower.contains('ffzy-plays') ||
      lower.contains('ffzy-play') ||
      lower.contains('/play/') ||
      lower.contains('m3u8') ||
      lower.contains('/video/') ||
      lower.contains('vodplay')) {
    return true;
  }
  return false;
}

/// 正文是否 HLS/m3u8 清单（`#EXTM3U`），此时应回退 chapterUrl
bool isM3u8PlaylistContent(String content) {
  final t = content.trimLeft();
  return t.startsWith('#EXTM3U') || t.startsWith('#EXTINF');
}

/// 从章节正文提取视频链接
///
/// 支持：纯 URL、复合 `url,{json}`、`<iframe/video/source/embed src>`；
/// 兜底取首个 `https?://`（勿在 MPD 上调用）。
String extractVideoUrl(String content) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) return '';
  if (isMpdVideoContent(trimmed)) return trimmed;

  // 已是 http(s) / 协议相对 / 复合 URL：取首段即可
  if (trimmed.startsWith('http://') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('//') ||
      trimmed.startsWith('/')) {
    return trimmed;
  }

  for (final tag in ['iframe', 'video', 'source', 'embed']) {
    final tagM = RegExp(
      '<$tag[^>]+src=["\']([^"\'>]+)["\']',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (tagM != null) {
      final tagUrl = tagM.group(1)!.trim();
      if (tagUrl.isNotEmpty) return tagUrl;
    }
  }

  final m = RegExp(r'https?://\S+').firstMatch(trimmed);
  if (m == null) return trimmed;
  // 复合 URL 含 JSON 时勿剥尾部 `}`
  final raw = m.group(0)!.trim();
  if (isCompositeImageUrl(raw)) return raw;
  return raw.replaceAll(RegExp(r'[)\]>"\x27]+$'), '');
}

/// 解析 `url,{ "headers": {...}, ... }`（对齐 AnalyzeUrl UrlOption）
({String url, Map<String, String> headers}) splitUrlOption(String raw) {
  final trimmed = raw.trim();
  final comma = trimmed.indexOf(',{');
  if (comma <= 0) {
    return (url: trimmed, headers: const {});
  }
  final urlPart = trimmed.substring(0, comma).trim();
  final optPart = trimmed.substring(comma + 1).trim();
  if (!optPart.startsWith('{') || !optPart.endsWith('}')) {
    return (url: trimmed, headers: const {});
  }
  try {
    final decoded = jsonDecode(optPart);
    if (decoded is! Map) {
      return (url: urlPart, headers: const {});
    }
    final map = <String, String>{};
    final headersNode = decoded['headers'];
    if (headersNode is Map) {
      headersNode.forEach((k, v) {
        if (k != null && v != null) map['$k'] = '$v';
      });
    }
    // 少数书源把 UA/Referer 写在 UrlOption 顶层
    for (final key in ['User-Agent', 'Referer', 'Cookie', 'Origin']) {
      final v = decoded[key];
      if (v != null && '$v'.isNotEmpty) map[key] = '$v';
    }
    return (url: urlPart, headers: map);
  } catch (_) {
    return (url: urlPart, headers: const {});
  }
}

/// 解析书源 header 字符串（JSON 或 key: value 行）
Map<String, String> parseSourceHeaderMap(String header) {
  final trimmed = header.trim();
  if (trimmed.isEmpty) return const {};
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries)
            if (e.key != null && e.value != null) '${e.key}': '${e.value}',
        };
      }
    } catch (_) {}
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

/// 在目录中选可播放章节索引（跳过卷标题，对齐 VideoPlay.upEpisodes）
int findPlayableChapterIndex(List<bool> isVolumeFlags, int preferred) {
  if (isVolumeFlags.isEmpty) return 0;
  final n = isVolumeFlags.length;
  final start = preferred.clamp(0, n - 1);
  if (!isVolumeFlags[start]) return start;
  for (var i = start + 1; i < n; i++) {
    if (!isVolumeFlags[i]) return i;
  }
  for (var i = start - 1; i >= 0; i--) {
    if (!isVolumeFlags[i]) return i;
  }
  return start;
}

/// 合并书源 header + UrlOption header，并补默认 UA / Referer
Map<String, String> mergeVideoHeaders({
  required Map<String, String> sourceHeaders,
  required Map<String, String> optionHeaders,
  String? referer,
}) {
  final map = <String, String>{...sourceHeaders, ...optionHeaders};
  map.remove('proxy');
  map.remove('Proxy');
  if (!map.keys.any((k) => k.toLowerCase() == 'user-agent')) {
    map['User-Agent'] = kDefaultVideoUserAgent;
  }
  if (referer != null &&
      referer.startsWith('http') &&
      !map.keys.any((k) => k.toLowerCase() == 'referer')) {
    map['Referer'] = referer;
  }
  return map;
}

/// 从章节正文解析播放目标（对齐 VideoPlay.startPlay + AnalyzeUrl）
///
/// 非凡等 MacCMS：章节 URL 已是 m3u8；正文规则 `result=baseUrl`，或 JS 失败时
/// 正文变成 `#EXTM3U` 清单 → 回退 [chapterUrl]。— Reasonix + UI
VideoPlayTarget resolveVideoPlayTarget({
  required String content,
  required String chapterUrl,
  Map<String, String> sourceHeaders = const {},
}) {
  final prepared = prepareVideoContent(content);
  final headersFor = (Map<String, String> optionHeaders) => mergeVideoHeaders(
        sourceHeaders: sourceHeaders,
        optionHeaders: optionHeaders,
        referer: chapterUrl,
      );

  if (prepared.isEmpty || isM3u8PlaylistContent(prepared)) {
    if (looksLikeVideoUrl(chapterUrl)) {
      final split = splitUrlOption(chapterUrl.trim());
      return VideoPlayTarget(
        url: resolveAbsoluteUrl(chapterUrl, split.url),
        headers: headersFor(split.headers),
      );
    }
    if (prepared.isEmpty) {
      return const VideoPlayTarget(url: '');
    }
    // 清单但无可用 chapterUrl：无法交给 URL 播放器
    return const VideoPlayTarget(url: '');
  }
  if (isMpdVideoContent(prepared)) {
    return VideoPlayTarget(
      url: '',
      headers: headersFor(const {}),
      mpdContent: prepared,
    );
  }

  final extracted = extractVideoUrl(prepared);
  final split = splitUrlOption(extracted);
  var abs = resolveAbsoluteUrl(chapterUrl, split.url);
  // 正文非 URL（toast/桥接杂质）时回退章节地址
  if (!looksLikeVideoUrl(abs) && looksLikeVideoUrl(chapterUrl)) {
    final chap = splitUrlOption(chapterUrl.trim());
    abs = resolveAbsoluteUrl(chapterUrl, chap.url);
    return VideoPlayTarget(url: abs, headers: headersFor(chap.headers));
  }
  return VideoPlayTarget(
    url: abs,
    headers: headersFor(split.headers),
  );
}
