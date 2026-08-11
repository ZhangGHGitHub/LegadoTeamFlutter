// 网络 URL 绝对化（对齐原版 NetworkUtils.getAbsoluteURL）— Reasonix + UI

/// 以 [baseUrl]（通常为章节 URL）解析相对 [url]。
String resolveAbsoluteUrl(String baseUrl, String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  final base = Uri.tryParse(baseUrl);
  if (base == null || !base.hasScheme || base.host.isEmpty) {
    return trimmed;
  }
  return base.resolve(trimmed).toString();
}
