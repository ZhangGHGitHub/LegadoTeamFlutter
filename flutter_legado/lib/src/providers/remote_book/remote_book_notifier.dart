import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/book.dart';
import '../../services/server_service.dart';
import '../../services/settings_service.dart';
import '../../utils/error_message.dart';
import '../providers.dart';
import '../sync/sync_notifier.dart';
import 'remote_book_state.dart';

export 'remote_book_state.dart';

/// 远程导入临时子目录名：`sha1(origin)` 前 12 位（稳定、可复算）
///
/// `origin` 同时含服务器身份（`webDav::` 前缀 + `,{"serverID":N}` 属性）
/// 与完整远程路径，因此同一远程文件始终落同一目录；不同服务器/目录的
/// 同名文件因 origin 不同而彼此隔离，不再互相覆盖后合并为同一书架条目
/// （批22 P3）。
String remoteBookTempKey(String origin) =>
    sha1.convert(utf8.encode(origin)).toString().substring(0, 12);

/// 远程导入临时落盘路径（保留原文件名与扩展名）
///
/// 返回 `<tempRoot>/<sha1(origin) 前 12 位>/<filename>`。保留原文件名与
/// 扩展名，使 Rust `importLocalBook` 仍能按文件名/扩展名解析书名与格式
/// （若直接改名哈希，TXT 书名会退化为哈希值）。
///
/// [filename] 会做路径安全净化：`.` / `..` 直接拒绝（目录穿越），
/// Windows 非法字符 `< > : " | ? *` 与路径分隔符统一替换为 `_`
/// （批22b P3）。
String remoteBookTempPath(String tempRoot, String origin, String filename) {
  final name = filename.trim();
  if (name.isEmpty || name == '.' || name == '..') {
    throw ArgumentError.value(filename, 'filename', '非法的远程文件名');
  }
  final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return '$tempRoot/${remoteBookTempKey(origin)}/$safeName';
}

/// 远程书库 Riverpod Notifier
///
/// 对齐原版 RemoteBookActivity：WebDAV 服务器切换 + 目录浏览 + 下载导入。
/// 列举：`webdavListDir`；导入：`webdavDownloadFile` → `importLocalBook`。
///
/// 批18a：服务器列表数据源切到 servers 表（经 [ServerService]），不再读写
/// `remote_servers` 旧偏好；`id = -1`（默认 WebDAV 同步账号）不在本页展示。
class RemoteBookNotifier extends Notifier<RemoteBookState> {
  final SettingsService _settings = SettingsService();

  static const _bookExts = {
    'epub',
    'txt',
    'mobi',
    'pdf',
    'azw3',
    'umd',
  };
  static const _archiveExts = {'zip', 'rar', '7z'};

  @override
  RemoteBookState build() => const RemoteBookState();

  /// 初始化：加载服务器列表与当前选中，并拉取目录
  ///
  /// DB 读取失败时进入错误态（页面展示原因），不抛给调用方。
  Future<void> init() async {
    try {
      final servers = await _loadServers();
      final serverId = await _settings.getRemoteServerId();
      state = state.copyWith(
        servers: servers,
        // 选中项已不存在/配置无效 → 回退默认 WebDAV（仅改内存状态，
        // 不覆盖用户偏好，对齐原版 isDefaultWebdav 语义）
        serverId: _normalizeServerId(serverId, servers),
        dirStack: const [],
        selectedPaths: {},
        clearError: true,
        clearServerError: true,
      );
    } catch (e) {
      state = state.copyWith(
        servers: const [],
        isLoading: false,
        items: const [],
        error: errorMessage(e),
      );
      return;
    }
    await refresh();
  }

  /// 选中 id 有效性归一：不存在 / config 无效 / url 为空 → 默认 WebDAV（-1）
  int _normalizeServerId(int id, List<RemoteServerConfig> servers) {
    if (id == SettingsService.defaultRemoteServerId) return id;
    for (final server in servers) {
      if (server.id != id) continue;
      if (!server.isValid || server.url.trim().isEmpty) {
        return SettingsService.defaultRemoteServerId;
      }
      return id;
    }
    return SettingsService.defaultRemoteServerId;
  }

  ServerService _serverService() => ServerService(
        api: ref.read(bookApiProvider),
        settings: _settings,
      );

  /// 从 servers 表加载自定义服务器（只保留 `id > 0`）
  ///
  /// 负数 id（`-1` 默认 WebDAV 及其他历史负值）不在本页展示：这些行不属于
  /// 远程书库自定义服务器，展示后若被保存/删除会触发 Service 层拒绝。
  Future<List<RemoteServerConfig>> _loadServers() async {
    final rows = await _serverService().listServers();
    return [
      for (final row in rows)
        if (row.id > 0)
          RemoteServerConfig(
            id: row.id,
            name: row.name,
            url: row.url,
            username: row.username,
            password: row.password,
            sortNumber: row.sortNumber,
            isValid: row.isValid,
          ),
    ];
  }

  RemoteServerConfig? _findServer(int id) {
    for (final s in state.servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 当前是否实际使用默认 WebDAV（选中 id = -1，或选中项不存在/无效）
  bool get _isDefaultServerActive {
    if (state.serverId == SettingsService.defaultRemoteServerId) return true;
    final server = _findServer(state.serverId);
    return server == null || !server.isValid || server.url.trim().isEmpty;
  }

  /// 构建当前服务器的 WebDavConfig JSON
  ///
  /// 选中 id 在列表中不存在（或该行 config 无效）时**回退默认 WebDAV**，
  /// 对齐原版 `RemoteBookViewModel.initData`（`serverDao.get(id)` 为空 →
  /// `AppWebDav.defaultBookWebDav`）与参考版 `RemoteBookRepository.getWebDav`。
  Future<String?> buildActiveConfigJson() async {
    final server = _isDefaultServerActive ? null : _findServer(state.serverId);
    if (server == null) {
      final sync = ref.read(syncNotifierProvider.notifier);
      await sync.loadConfig();
      final s = ref.read(syncNotifierProvider);
      if (!s.isConfigured) return null;
      return sync.buildConfigJson();
    }
    // [批22 P3] 折叠重复斜杠（保留协议）：Rust 直拼 url + remote_dir + path，
    // 自定义服务器无子目录（remote_dir = '/'）。
    final config = BookType.normalizeWebDavConfig(server.url, '');
    return jsonEncode({
      'url': config.url,
      'username': server.username,
      'password': server.password,
      'remote_dir': config.remoteDir,
    });
  }

  Future<void> selectServer(int id) async {
    final serverId = _normalizeServerId(id, state.servers);
    await _settings.setRemoteServerId(serverId);
    state = state.copyWith(
      serverId: serverId,
      dirStack: const [],
      selectedPaths: {},
      clearError: true,
    );
    await refresh();
  }

  /// 新建/编辑服务器（走 servers 表）；返回是否成功
  ///
  /// 失败时把可读原因写入 [RemoteBookState.serverError]（服务器 Sheet 内联
  /// 展示，避免贴底 Sheet 遮挡 SnackBar），不抛给调用方。
  Future<bool> saveServer(RemoteServerConfig server) async {
    try {
      await _serverService().saveServer(
        id: server.id,
        name: server.name,
        url: server.url,
        username: server.username,
        password: server.password,
      );
      final servers = await _loadServers();
      state = state.copyWith(
        servers: servers,
        serverId: _normalizeServerId(state.serverId, servers),
        clearError: true,
        clearServerError: true,
      );
      return true;
    } catch (e) {
      state = state.copyWith(serverError: errorMessage(e));
      return false;
    }
  }

  /// 删除服务器（走 servers 表）；返回是否成功
  ///
  /// 目标行不存在（FFI 返回 false）时同样视为失败：提示「服务器不存在或
  /// 已被删除」并返回 false，避免 UI 误报删除成功。
  Future<bool> deleteServer(int id) async {
    final bool deleted;
    try {
      deleted = await _serverService().deleteServer(id);
    } catch (e) {
      state = state.copyWith(serverError: errorMessage(e));
      return false;
    }
    if (!deleted) {
      state = state.copyWith(serverError: '服务器不存在或已被删除');
      return false;
    }
    try {
      final servers = await _loadServers();
      var serverId = state.serverId;
      if (serverId == id) {
        serverId = SettingsService.defaultRemoteServerId;
        await _settings.setRemoteServerId(serverId);
      }
      state = state.copyWith(
        servers: servers,
        serverId: _normalizeServerId(serverId, servers),
        clearError: true,
        clearServerError: true,
      );
      if (state.serverId == SettingsService.defaultRemoteServerId) {
        await refresh();
      }
      return true;
    } catch (e) {
      state = state.copyWith(serverError: errorMessage(e));
      return false;
    }
  }

  /// 清除服务器 Sheet 的内联错误（打开 Sheet / 用户重新操作前调用）
  void clearServerError() {
    state = state.copyWith(clearServerError: true);
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true, selectedPaths: {});
    try {
      final config = await buildActiveConfigJson();
      if (config == null) {
        state = state.copyWith(
          isLoading: false,
          items: const [],
          // 选中项缺失/无效已回退默认 WebDAV，此处只剩「默认也未配置」
          error: '请先在备份设置中配置默认 WebDAV，或在「服务器配置」中添加服务器',
        );
        return;
      }
      final api = ref.read(bookApiProvider);
      final raw = await api.webdavListDir(config, state.listPath);
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw Exception('目录列表格式错误');
      }
      final shelf = await api.getBooks();
      final onShelf = <String>{};
      for (final b in shelf) {
        // 对齐原版 LocalBook.isOnBookShelf：按远程路径/文件名匹配。
        // 新 `webDav::` origin 带 `,{"serverID":N}` 属性后缀，须先剥离；
        // 存量 `dav:` origin 同样兼容（双前缀）。
        final remotePath = BookType.webDavPathOf(b.origin);
        if (remotePath != null && remotePath.isNotEmpty) {
          onShelf.add(remotePath);
        }
        onShelf.add(b.name);
        if (b.originName.isNotEmpty) onShelf.add(b.originName);
      }

      final items = <RemoteBookItem>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final map = Map<String, dynamic>.from(e);
        final name = (map['name'] as String?)?.trim() ?? '';
        if (name.isEmpty || name == '.' || name == '..') continue;
        final isDir = map['is_dir'] == true;
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        if (!isDir &&
            !_bookExts.contains(ext) &&
            !_archiveExts.contains(ext)) {
          continue;
        }
        // 自身项过滤由 Rust 侧完成（webdav.rs `filter_self_entry`）；
        // 此处不得再用「名称等于当前目录」启发式，否则会误隐藏合法的
        // 同名子目录（如 books/books/）。
        final rel = state.listPath.isEmpty
            ? name
            : '${state.listPath}$name${isDir ? '/' : ''}';
        final size = (map['size'] as num?)?.toInt() ?? 0;
        final last = map['last_modified'] as String?;
        final onBook =
            onShelf.contains(name) || onShelf.any((s) => s.contains(rel));
        items.add(RemoteBookItem(
          filename: name,
          relativePath: isDir ? rel : rel,
          size: size,
          lastModified: last,
          isDir: isDir,
          isOnBookShelf: onBook,
        ));
      }

      state = state.copyWith(isLoading: false, items: items, clearError: true);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        items: const [],
        error: _mapError(e),
      );
    }
  }

  void setFilter(String value) {
    state = state.copyWith(filter: value);
  }

  void setSort(RemoteBookSort key) {
    if (state.sortKey == key) {
      state = state.copyWith(sortAscending: !state.sortAscending);
    } else {
      state = state.copyWith(sortKey: key, sortAscending: true);
    }
  }

  void openDir(RemoteBookItem dir) {
    if (!dir.isDir) return;
    state = state.copyWith(
      dirStack: [...state.dirStack, dir],
      selectedPaths: {},
      filter: '',
    );
    refresh();
  }

  bool goBackDir() {
    if (state.dirStack.isEmpty) return false;
    final stack = [...state.dirStack]..removeLast();
    state = state.copyWith(dirStack: stack, selectedPaths: {}, filter: '');
    refresh();
    return true;
  }

  void toggleSelect(RemoteBookItem item) {
    if (item.isDir || item.isOnBookShelf) return;
    final next = {...state.selectedPaths};
    if (!next.add(item.relativePath)) {
      next.remove(item.relativePath);
    }
    state = state.copyWith(selectedPaths: next);
  }

  void selectAllVisible(bool select) {
    if (!select) {
      state = state.copyWith(selectedPaths: {});
      return;
    }
    final next = <String>{};
    for (final e in state.visibleItems) {
      if (!e.isDir && !e.isOnBookShelf) next.add(e.relativePath);
    }
    state = state.copyWith(selectedPaths: next);
  }

  void revertSelection() {
    final checkable = state.visibleItems
        .where((e) => !e.isDir && !e.isOnBookShelf)
        .map((e) => e.relativePath)
        .toSet();
    final next = <String>{};
    for (final p in checkable) {
      if (!state.selectedPaths.contains(p)) next.add(p);
    }
    state = state.copyWith(selectedPaths: next);
  }

  /// 将选中远程文件下载并导入书架
  Future<void> addSelectedToBookshelf() async {
    final selected = state.items
        .where((e) => state.selectedPaths.contains(e.relativePath))
        .toList();
    if (selected.isEmpty) {
      state = state.copyWith(error: '请先选择要导入的书籍');
      return;
    }
    final config = await buildActiveConfigJson();
    if (config == null) {
      state = state.copyWith(error: 'WebDAV 未配置');
      return;
    }
    state = state.copyWith(isImporting: true, clearError: true, clearImported: true);
    final api = ref.read(bookApiProvider);
    // 默认服务器需要同步账号的 url/remote_dir 拼完整远程 URL；
    // buildActiveConfigJson 已触发 loadConfig，这里再显式加载一次以
    // 兼容自定义服务器分支（无副作用）。
    final syncNotifier = ref.read(syncNotifierProvider.notifier);
    await syncNotifier.loadConfig();
    final dir = Directory('${Directory.systemTemp.path}/legado_remote_books');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    var ok = 0;
    // [P2-7] 失败明细逐条保留（文件名 + 可读原因）；部分失败不得静默。
    final failures = <String>[];
    for (final item in selected) {
      String? localPath;
      var imported = false;
      try {
        final remoteUrl = _remoteUrlOf(item);
        final serverId = _isDefaultServerActive ? null : state.serverId;
        // 对齐原版 RemoteBookViewModel.addToBookshelf：
        // origin = webDavTag + CustomUrl(remoteBook.path)
        //          .putAttribute("serverID", serverID)
        // - remoteBook.path 为完整远程 URL（自定义服务器 = 服务器 url +
        //   相对路径；默认服务器 = 同步账号 url + remote_dir + 相对路径）；
        // - 默认服务器 serverID = null → 不追加属性（原版
        //   AppWebDav.defaultBookWebDav 构造时未传 serverID）。
        //
        // [批22 P3] origin 同时作为临时落盘目录的哈希键：不同服务器/
        // 目录的同名文件不会共用同一临时文件，bookUrl（= 落盘路径）
        // 因而唯一，避免导入后合并为同一书架条目。
        final origin = BookType.buildWebDavOrigin(remoteUrl, serverId: serverId);
        localPath = remoteBookTempPath(dir.path, origin, item.filename);
        // 父目录由 Rust `webdav_download_file` 内部 create_dir_all 创建
        // （batch22b 修正原「要求父目录已存在」的错误注释）。
        await api.webdavDownloadFile(config, item.relativePath, localPath);
        final book = await api.importLocalBook(localPath);
        imported = true;
        await api.updateBook(book.copyWith(
          origin: origin,
          originName: item.filename,
        ));
        ok++;
      } catch (e) {
        // [P2-7] 记录「文件名：可读原因」；循环结束统一交给页面展示
        failures.add('${item.filename}：${errorMessage(e)}');

        // 下载/导入失败：删除临时文件，避免残留。导入成功后的
        // updateBook 失败不清理——bookUrl 仍指向该文件。
        if (!imported && localPath != null) {
          await _deleteTempFileQuietly(localPath);
        }
      }
    }
    state = state.copyWith(
      isImporting: false,
      importedCount: ok,
      importFailures: failures,
      selectedPaths: {},
      // 全部失败时保留单条汇总错误（页面错误态）；部分失败改由
      // importFailures + 结果文案展示，不污染页面级 error。
      error: ok == 0
          ? (failures.isNotEmpty ? failures.first : '导入失败')
          : null,
      clearError: ok > 0,
    );
    if (ok > 0) {
      await refresh();
    }
  }

  /// 静默删除临时文件（清理失败不影响批次结果）
  Future<void> _deleteTempFileQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 忽略清理异常：失败原因已在 lastErr 中记录
    }
  }

  /// 当前服务器下远程文件的完整 URL
  ///
  /// 对齐原版 `WebDavFile.path`（RemoteBookWebDav.listFiles 中由
  /// `NetworkUtils.getAbsoluteURL` 构造的完整 URL）：
  /// - 默认 WebDAV：同步账号 url + remote_dir + 相对路径；
  /// - 自定义服务器：服务器 url + 相对路径。
  String _remoteUrlOf(RemoteBookItem item) {
    if (_isDefaultServerActive) {
      final syncNotifier = ref.read(syncNotifierProvider.notifier);
      final sync = ref.read(syncNotifierProvider);
      return BookType.joinRemoteUrl(
        BookType.joinRemoteUrl(
          sync.webDavUrl,
          syncNotifier.normalizedRemoteDir,
        ),
        item.relativePath,
      );
    }
    final server = _findServer(state.serverId);
    if (server == null || server.url.trim().isEmpty) {
      return item.relativePath;
    }
    return BookType.joinRemoteUrl(server.url, item.relativePath);
  }

  String _mapError(Object e) => errorMessage(e);
}

final remoteBookNotifierProvider =
    NotifierProvider<RemoteBookNotifier, RemoteBookState>(
  RemoteBookNotifier.new,
);
