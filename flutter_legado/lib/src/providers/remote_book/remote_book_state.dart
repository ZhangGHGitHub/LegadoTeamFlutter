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
class RemoteServerConfig {
  final int id;
  final String name;
  final String url;
  final String username;
  final String password;

  const RemoteServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
  });

  factory RemoteServerConfig.fromJson(Map<String, dynamic> json) {
    return RemoteServerConfig(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
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
  }) =>
      RemoteServerConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
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
    bool clearError = false,
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
    );
  }
}
