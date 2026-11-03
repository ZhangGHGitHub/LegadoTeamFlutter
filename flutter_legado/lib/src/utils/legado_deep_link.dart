import 'dart:io';

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

/// 应用内路由深链（M3 我的页：`legado://dict` / `legado://dict_rule`）
///
/// 与导入深链（`legado://import/<type>?src=...`）区分：路由深链只带 host，
/// 目标是应用内命名页面，不涉及网络拉取与关联导入确认框。
enum LegadoRouteDeepLink {
  /// 字典查询页（`AppRoutes.dict`）
  dict,

  /// 字典规则管理页（`AppRoutes.dictRule`）
  dictRule,
}

/// 外部文件分流类型（批16d；对齐原版 FileAssociationViewModel.dispatch）
///
/// 原版对非压缩包文件先做 JSON 内容嗅探，再按书籍后缀判定，最后落到
/// 「文件不支持」对话框；压缩包则在文件名匹配后先解压、只取书籍文件。
enum IncomingFileKind {
  /// 书籍文件（txt/epub/umd/pdf/mobi/azw/azw3 → 本地导入确认链）
  bookFile,

  /// JSON 导入内容（书源/RSS/规则等 → 关联导入确认框）
  json,

  /// 压缩包（zip/rar/7z → 解压导入对话框；7z 走 `archiveList7zFiles` /
  /// `archiveImport7z`，不支持加密/分卷）
  archive,

  /// 不支持的文件（弹「仍然导入」兜底框）
  unsupported,
}

/// `legado://` / `yuedu://` 深链解析结果（对齐原版 OnLineImportActivity）
///
/// 典型格式：`legado://import/bookSource?src=https://...`
class LegadoDeepLink {
  /// 书籍文件后缀（对齐原版 AppPattern.bookFileRegex：
  /// txt|epub|umd|pdf|mobi|azw3|azw，大小写不敏感）
  static const Set<String> bookFileExtensions = {
    'txt',
    'epub',
    'umd',
    'pdf',
    'mobi',
    'azw',
    'azw3',
  };

  /// 压缩包后缀（对齐原版 AppPattern.archiveFileRegex：zip|rar|7z）
  static const Set<String> archiveFileExtensions = {'zip', 'rar', '7z'};

  /// JSON 内容嗅探上限（对齐原版 InputStreamExtensions.JSON_SNIFF_LIMIT）
  static const int jsonSniffLimit = 64 * 1024;

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

  /// [M3 我的页 | 2026-11-03] 识别应用内路由深链
  ///
  /// 支持 `legado://dict`、`legado://dict_rule` 及 `yuedu://` 同构形式：
  /// - host 级（`legado://dict`）与三斜杠空 host（`legado:///dict`）；
  /// - 查询串忽略（`?src=...` 即使存在也不改变路由语义）；
  /// - scheme/host 大小写不敏感（`Uri` 解析已归一）；
  /// - **不**匹配 `legado://import/...`（path 非空）与未知 host，
  ///   返回 null 后交回既有导入分流，导入语义不变。
  static LegadoRouteDeepLink? tryParseRoute(String url) {
    final trimmed = url.trim();
    if (!isImportScheme(trimmed)) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final host = uri.host;
    if (host.isEmpty) {
      // legado:///dict → host 为空、pathSegments = ['dict']
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length != 1) return null;
      return _routeByName(segments.single);
    }
    // host 级路由深链不接受额外路径；legado://import/xxx 归导入分流
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    return _routeByName(host);
  }

  static LegadoRouteDeepLink? _routeByName(String name) {
    switch (name.toLowerCase()) {
      case 'dict':
        return LegadoRouteDeepLink.dict;
      case 'dict_rule':
        return LegadoRouteDeepLink.dictRule;
      default:
        return null;
    }
  }

  /// 取路径/文件名后缀（小写、不含点；无后缀返回空串）
  ///
  /// 只按最后一个路径段判定，兼容 content:// 文档 URI 的编码路径。
  static String extensionOf(String pathOrName) {
    final trimmed = pathOrName.trim();
    if (trimmed.isEmpty) return '';
    final slash = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    final name = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// 是否压缩包后缀（zip/rar/7z）
  static bool isArchivePath(String pathOrName) =>
      archiveFileExtensions.contains(extensionOf(pathOrName));

  /// 是否书籍文件后缀
  static bool isBookFilePath(String pathOrName) =>
      bookFileExtensions.contains(extensionOf(pathOrName));

  /// 仅按后缀分类（不做内容嗅探；测试与快速判定用）
  static IncomingFileKind classifyFileExtension(String pathOrName) {
    final ext = extensionOf(pathOrName);
    if (archiveFileExtensions.contains(ext)) return IncomingFileKind.archive;
    if (ext == 'json') return IncomingFileKind.json;
    if (bookFileExtensions.contains(ext)) return IncomingFileKind.bookFile;
    return IncomingFileKind.unsupported;
  }

  /// 按原版 FileAssociationViewModel.dispatch 顺序分类
  ///
  /// 1. 压缩包后缀 → [IncomingFileKind.archive]（先于内容嗅探，与原版一致：
  ///    压缩包不当作 JSON 解析，解压后只取书籍文件）；
  /// 2. [jsonContent] 为真 → [IncomingFileKind.json]（原版 looksLikeJson：
  ///    .txt 里装 JSON 也走关联导入）；
  /// 3. 书籍后缀 → [IncomingFileKind.bookFile]；
  /// 4. 其余 → [IncomingFileKind.unsupported]（含「.json 后缀但内容不是
  ///    JSON」——原版同样落到不支持分支）。
  static IncomingFileKind classifyFile(
    String pathOrName, {
    required bool jsonContent,
  }) {
    if (isArchivePath(pathOrName)) return IncomingFileKind.archive;
    if (jsonContent) return IncomingFileKind.json;
    if (isBookFilePath(pathOrName)) return IncomingFileKind.bookFile;
    return IncomingFileKind.unsupported;
  }

  /// JSON 内容嗅探（对齐原版 InputStreamExtensions.looksLikeJson）
  ///
  /// 在前 [jsonSniffLimit] 字节内跳过空格/制表/换行/回车，首个字节为
  /// `{` 或 `[` 视为 JSON；空内容或只有空白返回 false。
  static bool looksLikeJsonBytes(List<int> bytes) {
    final limit =
        bytes.length < jsonSniffLimit ? bytes.length : jsonSniffLimit;
    for (var i = 0; i < limit; i++) {
      final b = bytes[i];
      // 0x20 空格 / 0x09 制表 / 0x0A 换行 / 0x0D 回车
      if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) continue;
      return b == 0x7B || b == 0x5B; // '{' / '['
    }
    return false;
  }

  /// 异步读取文件头部做 JSON 嗅探（对齐原版 looksLikeJson）
  ///
  /// P2-7：`File.open` + `RandomAccessFile.read` 异步读，不在 UI 分流链路
  /// 同步阻塞；只读前 [jsonSniffLimit] 字节。读失败按非 JSON（原版同样
  /// 在 IO 异常时静默落到非 JSON 分支）。
  static Future<bool> looksLikeJsonFile(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final bytes = await handle.read(jsonSniffLimit);
      return looksLikeJsonBytes(bytes);
    } catch (_) {
      return false;
    } finally {
      try {
        await handle?.close();
      } catch (_) {
        // 关闭失败不影响分类结果
      }
    }
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
      case 'highlightrule':
        return ImportType.highlightRule;
      case 'autotask':
        return ImportType.autoTask;
      case 'texttocrule':
      case 'txttocrule':
      case 'txtrule':
        return ImportType.txtTocRule;
      default:
        return null;
    }
  }
}
