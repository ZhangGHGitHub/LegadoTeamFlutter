/// 远程书库条目（对齐原版 RemoteBook / WebDavFileInfo）
class RemoteBookItem {
  final String filename;
  final String relativePath;
  final int size;
  final String? lastModified;
  final bool isDir;
  final bool isOnBookShelf;

  const RemoteBookItem({
    required this.filename,
    required this.relativePath,
    this.size = 0,
    this.lastModified,
    this.isDir = false,
    this.isOnBookShelf = false,
  });

  RemoteBookItem copyWith({bool? isOnBookShelf}) => RemoteBookItem(
        filename: filename,
        relativePath: relativePath,
        size: size,
        lastModified: lastModified,
        isDir: isDir,
        isOnBookShelf: isOnBookShelf ?? this.isOnBookShelf,
      );
}

/// 远程书库自定义服务器（对齐原版 Server + WebDavConfig）
///
/// 批18a 起数据源为 servers 表（`id > 0`，`type = WEBDAV`）；`id = 0` 表示
/// 新建（由 Rust 分配主键）。[isValid] = false 表示该行 config 非法
/// （单行容错，仍可展示/编辑/删除）。
class RemoteServerConfig {
  final int id;
  final String name;
  final String url;
  final String username;
  final String password;

  /// servers 表排序号（编辑时原样保留；新建为 0）
  final int sortNumber;

  /// config 是否可解析为可用 WebDAV 配置
  final bool isValid;

  const RemoteServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
    this.sortNumber = 0,
    this.isValid = true,
  });

  factory RemoteServerConfig.fromJson(Map<String, dynamic> json) {
    return RemoteServerConfig(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      sortNumber: (json['sortNumber'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'username': username,
        'password': password,
      };

  RemoteServerConfig copyWith({
    int? id,
    String? name,
    String? url,
    String? username,
    String? password,
    int? sortNumber,
    bool? isValid,
  }) =>
      RemoteServerConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        sortNumber: sortNumber ?? this.sortNumber,
        isValid: isValid ?? this.isValid,
      );
}

/// 远程书库排序（对齐原版 RemoteBookSort）
enum RemoteBookSort { name, time }

/// 远程书库页状态（对齐原版 RemoteBookActivity）
class RemoteBookState {
  final bool isLoading;
  final bool isImporting;
  final List<RemoteBookItem> items;
  final List<RemoteBookItem> dirStack;
  final Set<String> selectedPaths;
  final String filter;
  final RemoteBookSort sortKey;
  final bool sortAscending;
  final int serverId;
  final List<RemoteServerConfig> servers;
  final int? importedCount;
  final String? error;

  /// 服务器 Sheet 内联错误（保存/删除失败原因）
  ///
  /// 与 [error] 分离：Sheet 贴底弹出时 SnackBar 会被遮挡，服务器操作失败
  /// 改在 Sheet 内列表上方内联展示；页面级 [error] 仍用于目录列举/导入。
  final String? serverError;

  const RemoteBookState({
    this.isLoading = false,
    this.isImporting = false,
    this.items = const [],
    this.dirStack = const [],
    this.selectedPaths = const {},
    this.filter = '',
    this.sortKey = RemoteBookSort.time,
    this.sortAscending = false,
    this.serverId = -1,
    this.servers = const [],
    this.importedCount,
    this.error,
    this.serverError,
  });

  /// 展示路径（对齐原版 tvPath：默认 books/，自定义服务器从 / 起）
  String get displayPath {
    final isDefault = serverId == -1;
    final buf = StringBuffer(isDefault ? 'books/' : '/');
    for (final d in dirStack) {
      buf.write(d.filename);
      buf.write('/');
    }
    return buf.toString();
  }

  /// 当前相对 remote_dir 的列举路径
  String get listPath {
    if (serverId == -1) {
      if (dirStack.isEmpty) return 'books/';
      return 'books/${dirStack.map((e) => e.filename).join('/')}/';
    }
    if (dirStack.isEmpty) return '';
    return '${dirStack.map((e) => e.filename).join('/')}/';
  }

  List<RemoteBookItem> get visibleItems {
    final q = filter.trim().toLowerCase();
    var list = q.isEmpty
        ? items
        : items.where((e) => e.filename.toLowerCase().contains(q)).toList();
    int cmp(RemoteBookItem a, RemoteBookItem b) {
      final dirCmp = (b.isDir ? 1 : 0) - (a.isDir ? 1 : 0);
      if (dirCmp != 0) return dirCmp;
      if (sortKey == RemoteBookSort.name) {
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      }
      return (a.lastModified ?? '').compareTo(b.lastModified ?? '');
    }

    list = [...list]..sort(cmp);
    if (!sortAscending) {
      // 目录仍置顶，目录内文件倒序
      final dirs = list.where((e) => e.isDir).toList();
      final files = list.where((e) => !e.isDir).toList().reversed.toList();
      if (sortKey == RemoteBookSort.name) {
        dirs.sort((a, b) =>
            b.filename.toLowerCase().compareTo(a.filename.toLowerCase()));
      }
      list = [...dirs, ...files];
    }
    return list;
  }

  RemoteBookState copyWith({
    bool? isLoading,
    bool? isImporting,
    List<RemoteBookItem>? items,
    List<RemoteBookItem>? dirStack,
    Set<String>? selectedPaths,
    String? filter,
    RemoteBookSort? sortKey,
    bool? sortAscending,
    int? serverId,
    List<RemoteServerConfig>? servers,
    int? importedCount,
    String? error,
    String? serverError,
    bool clearError = false,
    bool clearServerError = false,
    bool clearImported = false,
  }) {
    return RemoteBookState(
      isLoading: isLoading ?? this.isLoading,
      isImporting: isImporting ?? this.isImporting,
      items: items ?? this.items,
      dirStack: dirStack ?? this.dirStack,
      selectedPaths: selectedPaths ?? this.selectedPaths,
      filter: filter ?? this.filter,
      sortKey: sortKey ?? this.sortKey,
      sortAscending: sortAscending ?? this.sortAscending,
      serverId: serverId ?? this.serverId,
      servers: servers ?? this.servers,
      importedCount:
          clearImported ? null : (importedCount ?? this.importedCount),
      error: clearError ? null : (error ?? this.error),
      serverError:
          clearServerError ? null : (serverError ?? this.serverError),
    );
  }
}
