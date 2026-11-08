// 封面相册存储（设置批6b-2）
//
// 语义基准（参考版 legado-with-MD3）：
// - `CoverAlbumRepository.kt:42-455`：目录 `externalFilesDir/cover_albums/`，
//   索引 `albums.json`（formatVersion=2，只存相对文件名）；图片按内容
//   SHA-256 命名，先写临时文件再 rename；同一内容不重复写盘；删除图片
//   后若相册两侧都不再引用该文件则删文件，相册删除时整目录清理。
// - 旧版偏好 `defaultCover` / `defaultCoverDark`（逗号分隔的绝对路径）
//   迁移到 `default-cover` 相册的日/夜列表，迁移完成写幂等标记
//   `cover_album_migrated`；缺失/不可读文件跳过。
//
// 我方差异（已登记）：
// - 目录使用 `getApplicationSupportDirectory()/cover_albums/`（iOS 容器
//   Support 目录；不依赖 Android externalFilesDir）；索引仍只存文件名，
//   跨重装/迁移时整目录随应用沙盒走，不写绝对路径。
// - 相册文件不随 JSON 备份/跨设备传输；`defaultCover`/`defaultCoverDark`
//   与迁移标记均属设备级偏好（见 RestoreIgnorePrefs）。
// - 导入在字节层校验：非空、≤32MB、引擎可解码（截断/HEIC/改名非图拒绝），
//   单张失败不阻断同批其他图片，返回可读失败原因。
//
// 编写：全栈工程师（设置批6b-2） ｜ 2026-11-09
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 相册内的一张封面图（索引只保存 [fileName]，[path] 为运行时绝对路径）
class CoverAlbumImage {
  /// 文件名（`<64位小写sha256>.<ext>`）
  final String fileName;

  /// 当前设备上的绝对路径（索引不持久化）
  final String path;

  const CoverAlbumImage({required this.fileName, required this.path});

  String get id => fileName;
}

/// 封面相册（不可变）
class CoverAlbum {
  final String id;
  final String name;
  final List<CoverAlbumImage> lightImages;
  final List<CoverAlbumImage> darkImages;

  const CoverAlbum({
    required this.id,
    required this.name,
    this.lightImages = const <CoverAlbumImage>[],
    this.darkImages = const <CoverAlbumImage>[],
  });

  int get lightCount => lightImages.length;
  int get darkCount => darkImages.length;

  /// 列表预览：优先日间首图，其次夜间首图
  String? get previewPath => lightImages.isNotEmpty
      ? lightImages.first.path
      : (darkImages.isNotEmpty ? darkImages.first.path : null);

  CoverAlbum copyWith({
    String? name,
    List<CoverAlbumImage>? lightImages,
    List<CoverAlbumImage>? darkImages,
  }) {
    return CoverAlbum(
      id: id,
      name: name ?? this.name,
      lightImages: lightImages ?? this.lightImages,
      darkImages: darkImages ?? this.darkImages,
    );
  }
}

/// 待导入的图片字节（SAF/file_picker 统一口径）
class CoverAlbumImageInput {
  final String displayName;
  final Uint8List bytes;

  const CoverAlbumImageInput({required this.displayName, required this.bytes});
}

/// 单张导入失败（可读原因）
class CoverAlbumImportFailure {
  final String displayName;
  final String message;

  const CoverAlbumImportFailure({
    required this.displayName,
    required this.message,
  });
}

/// 批量导入结果：成功项 + 失败项（单张失败不阻断同批）
class CoverAlbumImportResult {
  final List<CoverAlbumImage> imported;
  final List<CoverAlbumImportFailure> failures;

  const CoverAlbumImportResult({
    this.imported = const <CoverAlbumImage>[],
    this.failures = const <CoverAlbumImportFailure>[],
  });

  bool get isEmpty => imported.isEmpty && failures.isEmpty;
}

/// 旧偏好迁移结果（供 Notifier 写入选中的相册 ID）
class CoverAlbumLegacyMigration {
  /// 迁移目标相册 ID（固定 `default-cover`）
  final String albumId;

  /// 旧 `defaultCoverDark` 是否为路径列表；是则需清空该键（其内容已迁移
  /// 到同一相册的夜间列表，避免被误当成相册 ID）
  final bool clearDarkSelection;

  const CoverAlbumLegacyMigration({
    required this.albumId,
    required this.clearDarkSelection,
  });
}

/// 相册操作失败（UI 直接展示 message）
class CoverAlbumException implements Exception {
  final String message;

  const CoverAlbumException(this.message);

  @override
  String toString() => message;
}

/// 封面相册存储（单例；索引与内存列表为唯一数据源）
///
/// [revision] 在列表/图片变化后自增，BookCover 与设置页按此重建；
/// [ensureLoaded] 幂等，首次调用读取索引并执行旧偏好迁移。
class CoverAlbumStore {
  CoverAlbumStore._();

  static final CoverAlbumStore instance = CoverAlbumStore._();

  static const int formatVersion = 2;
  static const String rootSubDir = 'cover_albums';
  static const String indexFileName = 'albums.json';

  /// 旧偏好迁移目标相册 ID（参考版 LEGACY_DEFAULT_ALBUM_ID）
  static const String legacyAlbumId = 'default-cover';

  /// 迁移目标相册默认名（参考版 `R.string.default_cover`）
  static const String legacyAlbumName = '默认封面';

  /// 单张图大小上限（32MB）
  static const int maxBytes = 32 * 1024 * 1024;

  /// 允许的图片扩展名（小写无点）；其余回落 `img`（参考版同口径）
  static const Set<String> _imageExts = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  /// 相册 ID 白名单：生成值/迁移值均为字母数字、下划线、短横线
  static final RegExp _albumIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  /// 自有图片文件名：64 位小写 sha256 + 1..8 位扩展名
  static final RegExp _imageFileNamePattern = RegExp(
    r'^[0-9a-f]{64}\.[a-z0-9]{1,8}$',
  );

  /// 旧偏好路径列表识别（逗号分隔 / 含路径分隔符 / file:// / 图片后缀）
  static final RegExp _imagePathExtPattern = RegExp(
    r'\.(?:jpe?g|png|webp|gif|bmp)$',
    caseSensitive: false,
  );

  /// 测试 seam：应用 Support 目录覆盖（null 走 path_provider）
  ///
  /// [设置批6b-2 测试基建] widget 测试的 FakeAsync 无法完成
  /// path_provider 的平台通道 Future，测试必须注入临时目录；未注入时
  /// 测试环境跳过加载（空相册回落内置封面），避免既有测试悬挂。
  @visibleForTesting
  static Future<Directory> Function()? supportDirOverride;

  /// 测试 seam：图片可解码校验（null 走真实引擎解码）
  ///
  /// widget 测试的 FakeAsync 不便驱动引擎解码；单测仍使用真实解码覆盖
  /// 截断/非图拒绝，UI 测试注入 `true` 只验证落盘/索引/UI 链路。
  @visibleForTesting
  static Future<bool> Function(Uint8List bytes)? decodeOverride;

  static bool get _isFlutterTest =>
      Platform.environment['FLUTTER_TEST'] == 'true';

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<CoverAlbum> _albums = const <CoverAlbum>[];
  bool _loaded = false;
  Future<void>? _loading;
  String? _rootPath;
  CoverAlbumLegacyMigration? _pendingMigration;

  /// 是否已完成首次加载（失败也置 true，后续走空相册回落）
  bool get isLoaded => _loaded;

  /// 索引根目录是否可用（平台目录获取失败时为 null）
  bool get hasRoot => _rootPath != null;

  List<CoverAlbum> get albums => List<CoverAlbum>.unmodifiable(_albums);

  CoverAlbum? albumById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final album in _albums) {
      if (album.id == id) return album;
    }
    return null;
  }

  /// 取出一次性的旧偏好迁移结果（Notifier 写入选中的相册 ID）
  CoverAlbumLegacyMigration? takePendingMigration() {
    final migration = _pendingMigration;
    _pendingMigration = null;
    return migration;
  }

  /// 加载索引（幂等）
  ///
  /// [migrate] 仅供测试关闭旧偏好迁移；生产始终为 true。
  Future<void> ensureLoaded({bool migrate = true}) {
    if (_loaded) return Future<void>.value();
    final running = _loading;
    if (running != null) return running;
    final future = _load(migrate: migrate);
    _loading = future;
    return future;
  }

  /// 备份恢复后重读索引与迁移状态（文件不变，仅刷新内存）
  Future<void> reload() async {
    _loaded = false;
    _loading = null;
    _albums = const <CoverAlbum>[];
    _pendingMigration = null;
    await ensureLoaded();
  }

  Future<void> _load({required bool migrate}) async {
    if (kIsWeb) {
      _loaded = true;
      revision.value++;
      return;
    }
    final override = supportDirOverride;
    if (_isFlutterTest && override == null) {
      // 测试环境未注入目录：跳过平台通道（FakeAsync 下可能永不完成）
      debugPrint('[CoverAlbumStore] 测试环境未注入 Support 目录，跳过加载');
      _loaded = true;
      revision.value++;
      return;
    }
    try {
      final support = await (override ?? getApplicationSupportDirectory)();
      final root = Directory(
        '${support.absolute.path}${Platform.pathSeparator}$rootSubDir',
      );
      _rootPath = root.path;
      _albums = _readIndex(root);
      if (migrate) {
        _pendingMigration = await _migrateLegacyCovers(root);
      }
    } catch (e) {
      // 平台目录不可得/索引读取异常：保持空列表，封面回落内置默认图
      debugPrint('[CoverAlbumStore] 加载失败，使用空相册: $e');
      _rootPath = null;
      _albums = const <CoverAlbum>[];
      _pendingMigration = null;
    } finally {
      _loaded = true;
      _loading = null;
      revision.value++;
    }
  }

  /// 创建相册（名称去首尾空白；重名允许，对齐参考版）
  Future<String> createAlbum(String name) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const CoverAlbumException('相册名称不能为空');
    }
    final root = _requireRoot();
    final id = _generateAlbumId();
    final album = CoverAlbum(id: id, name: trimmed);
    Directory(_albumDirPath(root, id)).createSync(recursive: true);
    _albums = <CoverAlbum>[..._albums, album];
    _persistIndex(root);
    revision.value++;
    return id;
  }

  /// 重命名相册
  Future<void> renameAlbum(String albumId, String name) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const CoverAlbumException('相册名称不能为空');
    }
    final index = _albums.indexWhere((album) => album.id == albumId);
    if (index < 0) {
      throw const CoverAlbumException('相册不存在或已删除');
    }
    final root = _requireRoot();
    final next = List<CoverAlbum>.of(_albums);
    next[index] = next[index].copyWith(name: trimmed);
    _albums = next;
    _persistIndex(root);
    revision.value++;
  }

  /// 删除相册（索引移除 + 目录递归清理）
  Future<void> deleteAlbum(String albumId) async {
    await ensureLoaded();
    if (!_albumIdPattern.hasMatch(albumId)) {
      throw const CoverAlbumException('相册标识非法');
    }
    final index = _albums.indexWhere((album) => album.id == albumId);
    if (index < 0) {
      throw const CoverAlbumException('相册不存在或已删除');
    }
    final root = _requireRoot();
    _albums = <CoverAlbum>[
      for (final album in _albums)
        if (album.id != albumId) album,
    ];
    _persistIndex(root);
    _deleteDirectoryQuietlySync(Directory(_albumDirPath(root, albumId)));
    revision.value++;
  }

  /// 批量导入图片（按内容 SHA-256 命名；同一内容不重复写盘）
  ///
  /// 单张校验失败（空/超限/非图/IO）记入 [CoverAlbumImportResult.failures]，
  /// 不阻断同批其他图片。
  Future<CoverAlbumImportResult> importImages(
    String albumId, {
    required bool isDark,
    required List<CoverAlbumImageInput> inputs,
  }) async {
    await ensureLoaded();
    if (inputs.isEmpty) return const CoverAlbumImportResult();
    final index = _albums.indexWhere((album) => album.id == albumId);
    if (index < 0) {
      throw const CoverAlbumException('相册不存在或已删除');
    }
    final root = _requireRoot();
    final album = _albums[index];
    final result = await _copyInputs(
      root: root,
      albumId: albumId,
      existing: isDark ? album.darkImages : album.lightImages,
      inputs: inputs,
    );
    if (result.imported.isNotEmpty) {
      final merged = _mergeImages(
        isDark ? album.darkImages : album.lightImages,
        result.imported,
      );
      final next = List<CoverAlbum>.of(_albums);
      next[index] = isDark
          ? album.copyWith(darkImages: merged)
          : album.copyWith(lightImages: merged);
      _albums = next;
      _persistIndex(root);
      revision.value++;
    }
    return result;
  }

  /// 删除单张图片
  ///
  /// 若该文件仍被另一侧引用（日/夜共用同一内容文件）则保留；否则删文件，
  /// 相册目录为空时一并删除。
  Future<void> removeImage(
    String albumId, {
    required bool isDark,
    required String fileName,
  }) async {
    await ensureLoaded();
    final index = _albums.indexWhere((album) => album.id == albumId);
    if (index < 0) {
      throw const CoverAlbumException('相册不存在或已删除');
    }
    if (!_isSafeFileName(fileName)) {
      throw const CoverAlbumException('图片标识非法');
    }
    final album = _albums[index];
    final images = isDark ? album.darkImages : album.lightImages;
    if (!images.any((image) => image.fileName == fileName)) return;

    final remaining = images
        .where((image) => image.fileName != fileName)
        .toList(growable: false);
    final updated = isDark
        ? album.copyWith(darkImages: remaining)
        : album.copyWith(lightImages: remaining);
    final root = _requireRoot();
    final next = List<CoverAlbum>.of(_albums);
    next[index] = updated;
    _albums = next;
    _persistIndex(root);

    final stillUsed =
        updated.lightImages.any((image) => image.fileName == fileName) ||
        updated.darkImages.any((image) => image.fileName == fileName);
    if (!stillUsed) {
      final dir = Directory(_albumDirPath(root, albumId));
      _deleteFileQuietlySync(
        File('${dir.path}${Platform.pathSeparator}$fileName'),
      );
      _deleteEmptyDirectoryQuietlySync(dir);
    }
    revision.value++;
  }

  /// 按书名种子确定性选择相册图（日/夜列表独立）
  ///
  /// 返回 null 表示无相册、相册不存在或对应日/夜列表为空 → 调用方回落
  /// 内置默认封面。相册图只读本地文件，不联网。
  String? imagePathForAlbum(
    String? albumId, {
    required bool isDark,
    required String? seed,
  }) {
    final album = albumById(albumId);
    if (album == null) return null;
    final images = isDark ? album.darkImages : album.lightImages;
    if (images.isEmpty) return null;
    return images[coverAlbumSeedIndex(seed, images.length)].path;
  }

  /// 书名种子 → 图片下标（稳定、跨平台一致）
  ///
  /// 与 Kotlin `String.hashCode()` 同构：32 位溢出累加
  /// `h = h * 31 + codeUnit`；空种子固定取第 0 张。
  static int coverAlbumSeedIndex(String? seed, int count) {
    if (count <= 0) return 0;
    var hash = 0;
    for (final unit in (seed ?? '').codeUnits) {
      hash = (hash * 31 + unit) & 0xFFFFFFFF;
    }
    return hash % count;
  }

  /// 测试隔离：恢复默认 seam 并清空内存状态
  @visibleForTesting
  static void resetForTest() {
    supportDirOverride = null;
    decodeOverride = null;
    instance._resetState();
  }

  @visibleForTesting
  void resetState() => _resetState();

  void _resetState() {
    _albums = const <CoverAlbum>[];
    _loaded = false;
    _loading = null;
    _rootPath = null;
    _pendingMigration = null;
  }

  // ===== 内部实现 =====

  String _requireRoot() {
    final root = _rootPath;
    if (root == null) {
      throw const CoverAlbumException('封面相册目录不可用');
    }
    return root;
  }

  static String _albumDirPath(String root, String albumId) =>
      '$root${Platform.pathSeparator}$albumId';

  static String _generateAlbumId() {
    final random = math.Random.secure();
    final now = DateTime.now().microsecondsSinceEpoch;
    final suffix = List<String>.generate(
      4,
      (_) => random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'),
    ).join();
    return 'album-$now-$suffix';
  }

  List<CoverAlbum> _readIndex(Directory root) {
    final indexFile = File(
      '${root.path}${Platform.pathSeparator}$indexFileName',
    );
    if (!indexFile.existsSync()) return const <CoverAlbum>[];
    try {
      final decoded = jsonDecode(indexFile.readAsStringSync());
      if (decoded is! Map) return const <CoverAlbum>[];
      final rawVersion = decoded['formatVersion'];
      final version = rawVersion is int ? rawVersion : 1;
      final rawAlbums = decoded['albums'];
      if (rawAlbums is! List) return const <CoverAlbum>[];
      final albums = <CoverAlbum>[];
      final seenIds = <String>{};
      for (final raw in rawAlbums) {
        if (raw is! Map) continue;
        final id = '${raw['id'] ?? ''}'.trim();
        // 路径安全：非法/重复 ID 直接跳过（备份/手改索引的穿越防护）
        if (!_albumIdPattern.hasMatch(id) || !seenIds.add(id)) continue;
        final rawName = '${raw['name'] ?? ''}'.trim();
        final name = rawName.isEmpty ? id : rawName;
        // v1 只有 images 单列表：日/夜都从它恢复（参考版按选择推断，
        // 我方无旧版选择语义，双列表同源更保守），随后以 v2 落盘。
        final lightRaw = version >= formatVersion
            ? raw['lightImages']
            : raw['images'];
        final darkRaw = version >= formatVersion
            ? raw['darkImages']
            : raw['images'];
        albums.add(
          CoverAlbum(
            id: id,
            name: name,
            lightImages: _mapExistingImages(root, id, lightRaw),
            darkImages: _mapExistingImages(root, id, darkRaw),
          ),
        );
      }
      if (version < formatVersion && albums.isNotEmpty) {
        // 旧格式升级：立即以 v2 原子写回（失败不阻断读取）
        try {
          _albums = albums;
          _persistIndex(root.path);
        } catch (e) {
          debugPrint('[CoverAlbumStore] 旧索引升级写回失败: $e');
        }
      }
      return albums;
    } catch (e) {
      debugPrint('[CoverAlbumStore] 索引损坏，按空相册处理: $e');
      return const <CoverAlbum>[];
    }
  }

  List<CoverAlbumImage> _mapExistingImages(
    Directory root,
    String albumId,
    Object? raw,
  ) {
    if (raw is! List) return const <CoverAlbumImage>[];
    final dirPath = _albumDirPath(root.path, albumId);
    final seen = <String>{};
    final out = <CoverAlbumImage>[];
    for (final item in raw) {
      if (item is! String) continue;
      final fileName = item.trim();
      // 只接受单层文件名：拒绝分隔符/`..`/空名（防路径穿越）
      if (!_isSafeFileName(fileName) || !seen.add(fileName)) continue;
      final file = File('$dirPath${Platform.pathSeparator}$fileName');
      if (!_isNonEmptyFile(file)) continue;
      out.add(CoverAlbumImage(fileName: fileName, path: file.path));
    }
    return out;
  }

  Future<CoverAlbumLegacyMigration?> _migrateLegacyCovers(
    Directory root,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final migrated = prefs.getBool(PrefKeys.coverAlbumMigrated) ?? false;
    // 已迁移且相册非空：无需再扫描旧路径（含缺失文件的日志噪声）
    if (migrated && _albums.isNotEmpty) return null;
    final lightPaths = _existingLegacyPaths(
      prefs.getString(PrefKeys.coverDefaultAlbumId),
    );
    final darkPaths = _existingLegacyPaths(
      prefs.getString(PrefKeys.coverDefaultAlbumIdDark),
    );
    final needsRecovery =
        migrated &&
        _albums.isEmpty &&
        (lightPaths.isNotEmpty || darkPaths.isNotEmpty);
    if (migrated && !needsRecovery) return null;
    if (lightPaths.isEmpty && darkPaths.isEmpty) {
      // 无旧路径也写标记：避免每次启动重复扫描 preferences
      await prefs.setBool(PrefKeys.coverAlbumMigrated, true);
      return null;
    }

    final existingIndex = _albums.indexWhere(
      (album) => album.id == legacyAlbumId,
    );
    final existing = existingIndex >= 0 ? _albums[existingIndex] : null;
    final base = CoverAlbum(
      id: legacyAlbumId,
      name: existing?.name ?? legacyAlbumName,
      lightImages: existing?.lightImages ?? const <CoverAlbumImage>[],
      darkImages: existing?.darkImages ?? const <CoverAlbumImage>[],
    );

    final lightResult = await _copyInputs(
      root: root.path,
      albumId: legacyAlbumId,
      existing: base.lightImages,
      inputs: await _readLegacyInputs(lightPaths),
    );
    final darkResult = await _copyInputs(
      root: root.path,
      albumId: legacyAlbumId,
      existing: base.darkImages,
      inputs: await _readLegacyInputs(darkPaths),
    );
    final album = base.copyWith(
      lightImages: _mergeImages(base.lightImages, lightResult.imported),
      darkImages: _mergeImages(base.darkImages, darkResult.imported),
    );
    _albums = <CoverAlbum>[
      for (final item in _albums)
        if (item.id != legacyAlbumId) item,
      album,
    ];
    _persistIndex(root.path);
    await prefs.setBool(PrefKeys.coverAlbumMigrated, true);
    revision.value++;
    debugPrint(
      '[CoverAlbumStore] 旧封面路径已迁移: '
      '日间 ${lightResult.imported.length}、夜间 ${darkResult.imported.length}',
    );
    return CoverAlbumLegacyMigration(
      albumId: legacyAlbumId,
      clearDarkSelection: darkPaths.isNotEmpty,
    );
  }

  /// 旧偏好值是否为「逗号分隔的图片路径」；相册 ID 不参与迁移
  bool _looksLikeLegacyPaths(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return false;
    if (text.contains(',')) return true;
    if (text.contains('/') || text.contains('\\')) return true;
    if (text.toLowerCase().startsWith('file:')) return true;
    return _imagePathExtPattern.hasMatch(text);
  }

  List<File> _existingLegacyPaths(String? raw) {
    if (!_looksLikeLegacyPaths(raw)) return const <File>[];
    final out = <File>[];
    for (final part in raw!.split(',')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      try {
        var path = trimmed;
        if (path.toLowerCase().startsWith('file:')) {
          path = Uri.parse(path).toFilePath(windows: Platform.isWindows);
        }
        final file = File(path);
        if (!_isNonEmptyFile(file)) {
          debugPrint('[CoverAlbumStore] 旧封面路径缺失/为空，跳过: $trimmed');
          continue;
        }
        out.add(file);
      } catch (e) {
        debugPrint('[CoverAlbumStore] 旧封面路径不可读，跳过: $trimmed ($e)');
      }
    }
    return out;
  }

  Future<List<CoverAlbumImageInput>> _readLegacyInputs(List<File> files) async {
    final inputs = <CoverAlbumImageInput>[];
    for (final file in files) {
      try {
        final length = await file.length();
        if (length <= 0 || length > maxBytes) {
          debugPrint('[CoverAlbumStore] 旧封面超过体积限制，跳过: ${file.path}');
          continue;
        }
        inputs.add(
          CoverAlbumImageInput(
            displayName: _baseName(file.path),
            bytes: await file.readAsBytes(),
          ),
        );
      } catch (e) {
        debugPrint('[CoverAlbumStore] 旧封面读取失败，跳过: ${file.path} ($e)');
      }
    }
    return inputs;
  }

  Future<CoverAlbumImportResult> _copyInputs({
    required String root,
    required String albumId,
    required List<CoverAlbumImage> existing,
    required List<CoverAlbumImageInput> inputs,
  }) async {
    final seenNames = existing.map((image) => image.fileName).toSet();
    final added = <CoverAlbumImage>[];
    final failures = <CoverAlbumImportFailure>[];
    final dir = Directory(_albumDirPath(root, albumId));
    dir.createSync(recursive: true);

    for (final input in inputs) {
      try {
        await _validateInput(input);
        final digest = sha256.convert(input.bytes).toString();
        final existingFile = _findExistingHashFile(dir, digest);
        final fileName = existingFile == null
            ? '$digest.${_extensionOf(input.displayName)}'
            : _baseName(existingFile.path);
        final target = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (!target.existsSync()) {
          _writeAtomically(dir, target, input.bytes);
        }
        if (seenNames.add(fileName)) {
          added.add(CoverAlbumImage(fileName: fileName, path: target.path));
        }
      } on CoverAlbumException catch (e) {
        failures.add(
          CoverAlbumImportFailure(
            displayName: input.displayName,
            message: e.message,
          ),
        );
      } catch (e) {
        failures.add(
          CoverAlbumImportFailure(
            displayName: input.displayName,
            message: '导入失败：$e',
          ),
        );
      }
    }
    return CoverAlbumImportResult(imported: added, failures: failures);
  }

  /// 合并图片列表（按文件名去重，保留原顺序）
  List<CoverAlbumImage> _mergeImages(
    List<CoverAlbumImage> existing,
    List<CoverAlbumImage> added,
  ) {
    final seen = existing.map((image) => image.fileName).toSet();
    return <CoverAlbumImage>[
      ...existing,
      for (final image in added)
        if (seen.add(image.fileName)) image,
    ];
  }

  Future<void> _validateInput(CoverAlbumImageInput input) async {
    if (input.bytes.isEmpty) {
      throw const CoverAlbumException('图片内容为空');
    }
    if (input.bytes.length > maxBytes) {
      throw CoverAlbumException('图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）');
    }
    if (!await _isDecodable(input.bytes)) {
      throw CoverAlbumException('不是可解码的图片：${_baseName(input.displayName)}');
    }
  }

  /// 引擎试解码：只解一帧，截断/非图/不支持格式在此拒绝
  Future<bool> _isDecodable(Uint8List bytes) async {
    final override = decodeOverride;
    if (override != null) return override(bytes);
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      buffer.dispose();
      buffer = null;
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      return true;
    } catch (_) {
      return false;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// 按内容哈希查找相册目录内已有文件（扩展名可能不同）
  File? _findExistingHashFile(Directory dir, String digest) {
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = _baseName(entity.path);
        if (name.startsWith('$digest.') &&
            _imageFileNamePattern.hasMatch(name)) {
          return entity;
        }
      }
    } catch (e) {
      debugPrint('[CoverAlbumStore] 扫描相册目录失败: $e');
    }
    return null;
  }

  void _writeAtomically(Directory dir, File target, Uint8List bytes) {
    final fileName = _baseName(target.path);
    final tmp = File(
      '${dir.path}${Platform.pathSeparator}.$fileName'
      '.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      tmp.writeAsBytesSync(bytes, flush: true);
      if (target.existsSync()) {
        _deleteFileQuietlySync(tmp);
      } else {
        tmp.renameSync(target.path);
      }
    } on FileSystemException {
      _deleteFileQuietlySync(tmp);
      // rename 竞态：另一写入方已落正式文件 → 视为成功
      if (!target.existsSync()) {
        throw const CoverAlbumException('保存图片失败');
      }
    }
  }

  void _persistIndex(String root) {
    final decoded = <String, Object?>{
      'formatVersion': formatVersion,
      'albums': <Map<String, Object?>>[
        for (final album in _albums)
          <String, Object?>{
            'id': album.id,
            'name': album.name,
            'lightImages': <String>[
              for (final image in album.lightImages) image.fileName,
            ],
            'darkImages': <String>[
              for (final image in album.darkImages) image.fileName,
            ],
          },
      ],
    };
    final dir = Directory(root);
    try {
      dir.createSync(recursive: true);
      final target = File('$root${Platform.pathSeparator}$indexFileName');
      final temp = File(
        '$root${Platform.pathSeparator}.$indexFileName'
        '.tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      temp.writeAsStringSync(jsonEncode(decoded), flush: true);
      try {
        temp.renameSync(target.path);
      } on FileSystemException {
        // Windows 上目标存在时 rename 失败：删除后重试（索引可重建，
        // 非图片数据，不做额外的 fsync 保证）
        if (target.existsSync()) target.deleteSync();
        temp.renameSync(target.path);
      }
    } catch (e) {
      throw CoverAlbumException('保存封面相册失败：$e');
    }
  }

  static bool _isSafeFileName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains('\\')) return false;
    if (name.contains('..')) return false;
    if (name.startsWith('.')) return false;
    return _imageFileNamePattern.hasMatch(name) || !name.contains(':');
  }

  static bool _isNonEmptyFile(File file) {
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }

  static String _extensionOf(String name) {
    final base = _baseName(name);
    final dot = base.lastIndexOf('.');
    if (dot < 0 || dot == base.length - 1) return 'img';
    final ext = base.substring(dot + 1).toLowerCase();
    return _imageExts.contains(ext) ? ext : 'img';
  }

  static void _deleteFileQuietlySync(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 清理失败不阻断主流程
    }
  }

  static void _deleteDirectoryQuietlySync(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不阻断主流程
    }
  }

  static void _deleteEmptyDirectoryQuietlySync(Directory dir) {
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) {
        dir.deleteSync();
      }
    } catch (_) {
      // 清理失败不阻断主流程
    }
  }
}
