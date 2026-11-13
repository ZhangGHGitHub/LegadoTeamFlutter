import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/book.dart';
import '../../models/misc.dart';
import '../../services/settings_service.dart';
import '../../services/webdav_server_service.dart';
import '../providers.dart';
import 'sync_state.dart';

export 'sync_state.dart';

/// WebDAV 云同步 Riverpod Notifier
///
/// 对接真实的 BookApi WebDAV 契约（webdavFullSync / importBookSources），
/// 对齐 Android 原版 BackupConfigFragment 的 WebDAV 设置组
/// （服务器地址/账号/密码/子目录/设备名/同步书籍进度）。
///
/// 批8（用户裁决②）：账号三要素以 DB `servers` 表为权威（`id = -1` 的
/// WEBDAV 行，读经 `webdavServersList`、写经 `webdavServerSave`）；
/// 旧偏好 `sync_webdav_*` 首次加载时一次性迁移，之后不再读写。
class SyncNotifier extends Notifier<SyncState> {
  final SettingsService _settings = SettingsService();

  @override
  SyncState build() {
    // 原 SyncProvider 构造不自动加载，配置由页面 initState 触发 loadConfig()
    return const SyncState();
  }

  /// 远端子目录（保证以 '/' 结尾；Rust WebDavClient 拼接
  /// full_url = url + remote_dir + path，直接拼接 path）
  ///
  /// [批22 P3] 折叠重复斜杠（保留协议 `://`）并统一首尾各一个 `/`：
  /// 旧偏好可能存 `/legado/` 与用户输入 `//backup//` 等形态，直拼会产生
  /// `//`。空目录沿用默认 `/legado/`。
  String get normalizedRemoteDir {
    final dir = state.remoteDir.trim();
    return BookType.normalizeWebDavConfig(
      '',
      dir.isEmpty ? '/legado/' : dir,
    ).remoteDir;
  }

  /// 构建 Rust 侧 WebDavConfig 期望的 JSON（{url, username, password, remote_dir}）
  ///
  /// [Task #52 | 2026-08-10] 补齐 remote_dir（legado-net WebDavConfig 必需字段，
  /// 缺失会导致 Rust 侧配置解析失败） — Qoder
  ///
  /// [批22 P3] url 去尾斜杠、remote_dir 归一首尾单斜杠（Rust 直拼无 `//`）。
  String buildConfigJson() {
    final config =
        BookType.normalizeWebDavConfig(state.webDavUrl, normalizedRemoteDir);
    return jsonEncode({
      'url': config.url,
      'username': state.webDavUsername,
      'password': state.webDavPassword,
      'remote_dir': config.remoteDir,
    });
  }

  // ===== 配置管理 =====

  /// 保存 WebDAV 配置
  ///
  /// 批8 审查回修 P2-6：先落库、后改内存状态——DB 写入失败时状态不前进，
  /// 异常上抛给调用方（设置页统一经 SnackBar 提示），避免「界面显示已保存、
  /// 实际未落库」的假成功。
  Future<void> saveConfig(
    String url,
    String username,
    String password,
    String dir, {
    String deviceName = '',
  }) async {
    final webDavUrl = url.trim();
    final webDavUsername = username.trim();
    final remoteDir = dir.trim().isEmpty ? '/legado/' : dir.trim();
    final device = deviceName.trim();
    // 批8：url/username/password 写入 DB servers 表（id = -1 的 WEBDAV 行）；
    // 子目录/设备名仍为偏好（原版 AppConfig.webDavDir/webDavDeviceName 同为偏好）
    await _webDavServerService().saveSyncServer(
      url: webDavUrl,
      username: webDavUsername,
      password: password,
    );
    await _settings.setWebDavRemoteDir(remoteDir);
    await _settings.setWebDavDeviceName(device);
    state = state.copyWith(
      webDavUrl: webDavUrl,
      webDavUsername: webDavUsername,
      webDavPassword: password,
      remoteDir: remoteDir,
      deviceName: device,
    );
  }

  /// 本地恢复后按备份格式回填旧偏好账号（批8 审查回修 P1-1）
  ///
  /// - 备份含 `servers` 段（v3）：以备份 DB 行为准，**不回读偏好**，返回 false；
  /// - v1/v2 且备份携带账号键：把恢复所得偏好账号覆盖到 DB `id = -1` 行
  ///   （三项全空时不写库），返回是否实际写入；
  /// - 无法判定或备份未携带账号：不回填（避免设备残留偏好覆盖当前配置）。
  ///
  /// 对齐原版 `Restore.kt:455-470`：恢复 prefs 后 WebDAV 账号立即生效。
  Future<bool> applyLegacyWebDavPrefsAfterRestore({
    required WebDavBackupAccountSource source,
  }) async {
    if (source != WebDavBackupAccountSource.legacyPrefs) return false;
    final applied = await _webDavServerService().applyLegacyPrefsOverwrite();
    return applied != null;
  }

  /// 加载已保存的 WebDAV 配置
  ///
  /// 批8：账号三要素改从 DB servers 表读取（首次调用触发旧偏好一次性迁移）；
  /// 子目录/设备名/同步开关仍读偏好。
  Future<void> loadConfig() async {
    final server = await _webDavServerService().loadSyncServer();
    state = state.copyWith(
      webDavUrl: server.url,
      webDavUsername: server.username,
      webDavPassword: server.password,
      remoteDir: await _settings.getWebDavRemoteDir(),
      deviceName: await _settings.getWebDavDeviceName(),
      syncBookProgress: await _settings.getSyncBookProgress(),
      syncBookProgressPlus: await _settings.getSyncBookProgressPlus(),
      autoSync: await _settings.getAutoSync(),
      lastSyncTime: await _settings.getLastSyncTime(),
    );
  }

  /// servers 表服务（每次按当前 BookApi 实例构造，轻量无状态）
  WebDavServerService _webDavServerService() => WebDavServerService(
        api: ref.read(bookApiProvider),
        settings: _settings,
      );

  /// 切换自动同步
  Future<void> toggleAutoSync(bool enabled) async {
    state = state.copyWith(autoSync: enabled);
    await _settings.setAutoSync(enabled);
  }

  /// 设置「同步书籍进度」开关
  Future<void> setSyncBookProgress(bool enabled) async {
    state = state.copyWith(syncBookProgress: enabled);
    await _settings.setSyncBookProgress(enabled);
  }

  /// 设置「同步书籍进度增强」开关
  Future<void> setSyncBookProgressPlus(bool enabled) async {
    state = state.copyWith(syncBookProgressPlus: enabled);
    await _settings.setSyncBookProgressPlus(enabled);
  }

  // ===== 单书进度拉取 / 覆盖（对齐 AppWebDav.getBookProgress / uploadBookProgress）=====

  /// 进度文件相对路径：`bookProgress/{name}_{author}.json`
  String bookProgressRemotePath(String name, String author) =>
      'bookProgress/${_progressFileName(name, author)}';

  /// 上传当前书籍进度到 WebDAV（对齐 menu_cover_progress）
  Future<void> uploadBookProgress(Book book) async {
    if (!state.isConfigured) {
      throw StateError('请先配置 WebDAV');
    }
    if (!state.syncBookProgress) {
      throw StateError('未开启「同步书籍进度」');
    }
    final progress = BookProgress(
      name: book.name,
      author: book.author,
      durChapterIndex: book.durChapterIndex,
      durChapterPos: book.durChapterPos,
      durChapterTime: book.durChapterTime,
      durChapterTitle: book.durChapterTitle,
    );
    final api = ref.read(bookApiProvider);
    await api.webdavUpload(
      buildConfigJson(),
      bookProgressRemotePath(book.name, book.author),
      jsonEncode(progress.toJson()),
    );
  }

  /// 拉取远程进度；无文件 / 解析失败返回 null
  Future<BookProgress?> fetchBookProgress(Book book) async {
    if (!state.isConfigured) return null;
    try {
      final api = ref.read(bookApiProvider);
      final jsonStr = await api.webdavDownload(
        buildConfigJson(),
        bookProgressRemotePath(book.name, book.author),
      );
      if (jsonStr.trim().isEmpty) return null;
      final map = jsonDecode(jsonStr);
      if (map is! Map<String, dynamic>) return null;
      return BookProgress.fromJson(map);
    } catch (e) {
      debugPrint('SyncNotifier.fetchBookProgress: $e');
      return null;
    }
  }

  /// 对齐 ReadBook.syncProgress：云端更快 → 回调；本地更快或缺云端 → 上传
  ///
  /// 返回值：`cloud`=云端更新、`uploaded`=已上传本地、`same`=一致、`skipped`=开关关闭
  Future<String> syncBookProgressForBook(
    Book book, {
    required Future<void> Function(BookProgress cloud) onCloudNewer,
  }) async {
    if (!state.syncBookProgress) return 'skipped';
    if (!state.isConfigured) {
      throw StateError('请先配置 WebDAV');
    }
    final cloud = await fetchBookProgress(book);
    if (cloud == null ||
        cloud.durChapterIndex < book.durChapterIndex ||
        (cloud.durChapterIndex == book.durChapterIndex &&
            cloud.durChapterPos < book.durChapterPos)) {
      await uploadBookProgress(book);
      return 'uploaded';
    }
    if (cloud.durChapterIndex > book.durChapterIndex ||
        cloud.durChapterPos > book.durChapterPos) {
      await onCloudNewer(cloud);
      return 'cloud';
    }
    return 'same';
  }

  static String _progressFileName(String name, String author) {
    // 对齐 Kotlin：normalizeFileName + UrlUtil.replaceReservedChar
    var base = '${name}_$author'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    const reserved = {
      '%': '%25',
      ' ': '%20',
      '"': '%22',
      '#': '%23',
      '&': '%26',
      '(': '%28',
      ')': '%29',
      '+': '%2B',
      ',': '%2C',
      '/': '%2F',
      ':': '%3A',
      ';': '%3B',
      '<': '%3C',
      '=': '%3D',
      '>': '%3E',
      '?': '%3F',
      '@': '%40',
      '\\': '%5C',
    };
    final buf = StringBuffer();
    for (final rune in base.runes) {
      final ch = String.fromCharCode(rune);
      buf.write(reserved[ch] ?? ch);
    }
    return '${buf.toString()}.json';
  }

  // ===== 同步操作（真实 BookApi 调用） =====

  /// 备份到 WebDAV（上传本地书架 + 书源）
  ///
  /// 调用真实 webdavFullSync，对齐原版 web_dav_backup。
  Future<void> backupToWebDav() async {
    if (!state.isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return;
    }
    _setStatus(SyncStatus.syncing);
    try {
      final api = ref.read(bookApiProvider);
      final (localBooks, localSources) = await _collectLocalData();
      await api.webdavFullSync(buildConfigJson(), localBooks, localSources);
      await _markSyncSuccess();
    } catch (e) {
      _setError('备份失败: $e');
    }
  }

  /// WebDAV 全量同步（上传本地书架/书源，再回写远端书源）
  ///
  /// 调用真实 webdavFullSync：先上传本地书架覆盖远端 bookshelf.json，再
  /// 取远端合并数据，书源经 importBookSources 回写；书架批量回写受限于
  /// BookApi 暂无批量导入契约，登记为跨轨需求。
  /// 返回用于展示的结果描述（方向是同步，不是「恢复」）。
  Future<String> restoreFromWebDav() async {
    if (!state.isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return '请先配置 WebDAV 服务器信息';
    }
    _setStatus(SyncStatus.syncing);
    try {
      final api = ref.read(bookApiProvider);
      final (localBooks, localSources) = await _collectLocalData();
      final result =
          await api.webdavFullSync(buildConfigJson(), localBooks, localSources);
      var imported = 0;
      final remote = jsonDecode(result) as Map<String, dynamic>;
      final remoteSources = remote['sources']?.toString() ?? '';
      if (remoteSources.isNotEmpty && remoteSources != '[]') {
        imported = await api.importBookSources(remoteSources);
      }
      await _markSyncSuccess();
      // [审查 P2-6] 该链路上传本地书架覆盖远端并回写远端书源，用户可见
      // 结果文案按「同步」表述，避免与「恢复（远端覆盖本地）」方向混淆。
      return '同步完成，回写 $imported 条书源';
    } catch (e) {
      _setError('同步失败: $e');
      return '同步失败: $e';
    }
  }

  // ===== Internal helpers =====

  /// 序列化本地书架 + 书源为 JSON（供 webdavFullSync 上传）
  Future<(String, String)> _collectLocalData() async {
    final api = ref.read(bookApiProvider);
    final books = await api.getBooks();
    final sources = await api.getBookSources();
    final localBooks = jsonEncode(books.map((e) => e.toJson()).toList());
    final localSources = jsonEncode(sources.map((e) => e.toJson()).toList());
    return (localBooks, localSources);
  }

  Future<void> _markSyncSuccess() async {
    final now = DateTime.now();
    state = state.copyWith(
      lastSyncTime: now,
      status: SyncStatus.success,
      error: null,
    );
    await _settings.setLastSyncTime(now);
  }

  void _setStatus(SyncStatus status) {
    state = state.copyWith(status: status, error: null);
  }

  void _setError(String message) {
    state = state.copyWith(status: SyncStatus.error, error: message);
    debugPrint('SyncNotifier 错误: $message');
  }
}

/// WebDAV 云同步 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(syncNotifierProvider);
/// ref.read(syncNotifierProvider.notifier).backupToWebDav();
/// ```
final syncNotifierProvider = NotifierProvider<SyncNotifier, SyncState>(
  SyncNotifier.new,
);
