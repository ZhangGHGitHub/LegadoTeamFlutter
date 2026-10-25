import '../providers/association/association_state.dart';

/// 入站 URI 分类（P1-4：深链 / 外部书籍文件 / 其他）
enum IncomingUriKind {
  /// legado:// / yuedu:// 关联导入深链（走关联导入确认框）
  importScheme,

  /// 外部书籍文件（content:// / file://，走本地导入链；对齐原版
  /// FileAssociationActivity 的 ACTION_VIEW 文件分发）
  bookFile,

  /// 不消费（交由原链路/忽略）
  none,
}

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

  /// P1-4：入站 URI 分类（VIEW intent dataString 统一判定入口）
  ///
  /// - legado:// / yuedu:// → [IncomingUriKind.importScheme]
  /// - content:// / file:// → [IncomingUriKind.bookFile]（外部书籍文件，
  ///   manifest 已声明 epub/txt/pdf 的 VIEW intent-filter）
  /// - 其余（http(s) 等）→ [IncomingUriKind.none]
  static IncomingUriKind classifyIncomingUri(String? url) {
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return IncomingUriKind.none;
    if (isImportScheme(trimmed)) return IncomingUriKind.importScheme;
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('content://') || lower.startsWith('file://')) {
      return IncomingUriKind.bookFile;
    }
    return IncomingUriKind.none;
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
    switch (token.isNotEmpty ? token : key) {
      case 'booksource':
        return ImportType.bookSource;
      case 'rsssource':
        return ImportType.rssSource;
      case 'replacerule':
      case 'replace':
        return ImportType.replaceRule;
      case 'theme':
        return ImportType.theme;
      case 'httptts':
        return ImportType.httpTts;
      case 'dictrule':
        return ImportType.dictRule;
      case 'texttocrule':
      case 'txttocrule':
      case 'txtrule':
        return ImportType.txtTocRule;
      default:
        return null;
    }
  }
}
