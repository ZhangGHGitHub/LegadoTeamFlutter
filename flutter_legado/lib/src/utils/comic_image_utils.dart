// 漫画章节图片 URL 解析工具（对齐原版 HtmlFormatter.formatImagePattern）
// — Reasonix + UI

/// 是否为「复合图片 URL」：`https://host/path.webp,{"headers":{...}}`
///
/// 原版 AnalyzeUrl / ImageUtils 支持 URL 后附 JSON 防盗链 header；
/// 此类 URL 不能用 CachedNetworkImage 直连。
bool isCompositeImageUrl(String url) {
  final comma = url.indexOf(',{');
  return comma > 0;
}

/// 剥离复合 URL 的 `, {json}` 后缀，得到可直连的纯 URL
String stripCompositeImageUrl(String url) {
  final comma = url.indexOf(',{');
  if (comma > 0) return url.substring(0, comma);
  return url;
}

/// 判断是否像图片链接（行解析兜底用；复合 URL 先剥 `, {json}` 再判后缀）
bool looksLikeImageUrl(String url) {
  final base = isCompositeImageUrl(url)
      ? url.substring(0, url.indexOf(',{'))
      : url;
  final lower = base.toLowerCase();
  // 流媒体绝不当图片（非凡 m3u8 / 伪七猫 mp4 等）— Reasonix + UI
  if (RegExp(r'\.(m3u8|mp4|flv|mkv|webm)(\?|#|$)', caseSensitive: false)
      .hasMatch(lower)) {
    return false;
  }
  if (lower.contains('m3u8') ||
      lower.contains('ffzy-plays') ||
      lower.contains('ffzy-play')) {
    return false;
  }
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp') ||
      lower.contains('/image') ||
      lower.contains('/img') ||
      lower.contains('/pic');
}

/// 对齐原版 [HtmlFormatter.formatImagePattern]：
/// 1) `src='url,{json}'` 复合 URL（引号内可含 JSON 双引号）
/// 2) `data-src` / `data-original` / `data-srcset`
/// 3) 普通双引号 `src="..."`
/// 4) 其它 data-* / src 单双引号
///
/// 旧正则 `src=["']([^"']+)["']` 会在 JSON 内第一个 `"` 处截断，
/// 得到 `https://.../a.webp,{` → 下游 Invalid image data。
final RegExp comicImgSrcRegex = RegExp(
  r'''<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>'''
  r'''|<img[^>]*\sdata-(?:src|original|srcset)\s*=\s*['"]([^'">]+)['"][^>]*>'''
  r'''|<img[^>]*\ssrc\s*=\s*"([^">]+)"[^>]*>'''
  r'''|<img[^>]*\s(?:data-[^=>]*|src)=\s*['"]([^'">]*)['"][^>]*>''',
  caseSensitive: false,
);

/// 从章节内容解析图片 URL 列表
///
/// 支持：HTML img（含复合 URL）、每行一个 URL、常见图片后缀行。
List<String> parseComicImageUrls(String content) {
  if (content.isEmpty) return [];

  final urls = <String>[];

  for (final match in comicImgSrcRegex.allMatches(content)) {
    final url =
        match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4);
    if (url != null && url.isNotEmpty) {
      urls.add(url);
    }
  }

  if (urls.isEmpty) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('http') && looksLikeImageUrl(trimmed)) {
        urls.add(trimmed);
      }
    }
  }

  return urls;
}

/// 章节正文是否以图片为主（几乎无纯文本，仅有 `<img>` / 图片 URL 行）。
///
/// 用于文本阅读器兜底：type=0 看图源若仍误进文本页，改为漫画式渲染，
/// 避免把 `<img src="...">` 当纯文字刷屏（必应漫画设备证据）。
/// — Reasonix + UI
bool isImageDominantContent(String content) {
  if (content.trim().isEmpty) return false;
  final urls = parseComicImageUrls(content);
  if (urls.isEmpty) return false;
  final textOnly = content
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), '')
      .trim();
  // 允许极短残留（标点/站点碎片）；有实质段落则仍走文本排版
  return textOnly.length < 24;
}

/// JPEG/PNG/GIF/WEBP/BMP 魔数探测（解密结果校验，避免密文进 Image.memory）
///
/// [cbz 批 D] 补 BMP（"BM" 2 字节，与既有 JPEG 2 字节魔数同精度）：
/// Rust CBZ 图片白名单 `IMAGE_EXTENSIONS` 已收 `.bmp`，Dart 校验不认会
/// 把合法 BMP 页判为「不是有效图片」落错误占位，两端口径须一致。
/// — Reasonix + UI / 全栈工程师 + UI
bool looksLikeImageBytes(List<int> bytes) {
  if (bytes.length < 4) return false;
  // JPEG
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
  // PNG
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true;
  }
  // GIF
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // WEBP: RIFF....WEBP
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  // BMP: "BM"
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  return false;
}
