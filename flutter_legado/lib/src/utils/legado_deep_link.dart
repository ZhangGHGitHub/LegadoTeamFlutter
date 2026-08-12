import '../providers/association/association_state.dart';

/// `legado://` / `yuedu://` 深链解析结果（对齐原版 OnLineImportActivity）
///
/// 典型格式：`legado://import/bookSource?src=https://...`
class LegadoDeepLink {
  /// 原始 URI
  final String raw;

  /// 查询参数 `src`（导入内容 URL）
  final String srcUrl;

  /// 可映射到关联导入页的类型；无法映射时为 null（需用户自选）
  final ImportType? importType;

  /// 路径片段（如 `bookSource` / `rssSource`）
  final String pathKey;

  const LegadoDeepLink({
    required this.raw,
    required this.srcUrl,
    required this.importType,
    required this.pathKey,
  });

  /// 是否为 legado/yuedu 导入协议
  static bool isImportScheme(String url) {
    final lower = url.trim().toLowerCase();
    return lower.startsWith('legado://') || lower.startsWith('yuedu://');
  }

  /// 解析失败返回 null（缺 src 或非法 URI）
  static LegadoDeepLink? tryParse(String url) {
    final trimmed = url.trim();
    if (!isImportScheme(trimmed)) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final src = uri.queryParameters['src']?.trim() ?? '';
    if (src.isEmpty) return null;

    // legado://import/bookSource → host=import, path=/bookSource
    final path = uri.path;
    final host = uri.host.toLowerCase();
    final pathKey = _pathKey(host, path);
    return LegadoDeepLink(
      raw: trimmed,
      srcUrl: src,
      importType: _mapImportType(host, pathKey),
      pathKey: pathKey,
    );
  }

  static String _pathKey(String host, String path) {
    if (path.isNotEmpty && path != '/') {
      return path.replaceFirst(RegExp(r'^/'), '');
    }
    return host;
  }

  static ImportType? _mapImportType(String host, String pathKey) {
    final key = pathKey.toLowerCase();
    // importonline 变体：host 即为类型（booksource / rsssource / replace）
    final token = (host == 'importonline' || host == 'import') ? key : host;
    switch (token) {
      case 'booksource':
        return ImportType.bookSource;
      case 'rsssource':
        return ImportType.rssSource;
      case 'replacerule':
      case 'replace':
        return ImportType.replaceRule;
      case 'theme':
        return ImportType.theme;
      default:
        // 再看 pathKey（legado://import/bookSource）
        switch (key) {
          case 'booksource':
            return ImportType.bookSource;
          case 'rsssource':
            return ImportType.rssSource;
          case 'replacerule':
          case 'replace':
            return ImportType.replaceRule;
          case 'theme':
            return ImportType.theme;
          default:
            // httpTTS / dictRule / textTocRule / autoTask / readConfig 等：
            // Association 暂无独立类型 → P1-12；此处返回 null 让用户自选
            return null;
        }
    }
  }
}
