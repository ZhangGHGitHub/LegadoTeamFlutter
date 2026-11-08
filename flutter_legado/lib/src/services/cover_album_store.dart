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
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

  /// 同内容已存在（或本批重复）而跳过的张数
  final int duplicateCount;

  const CoverAlbumImportResult({
    this.imported = const <CoverAlbumImage>[],
    this.failures = const <CoverAlbumImportFailure>[],
    this.duplicateCount = 0,
  });

  bool get isEmpty =>
      imported.isEmpty && failures.isEmpty && duplicateCount == 0;
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

  /// 单次批量导入上限（张数 / 总字节）：防止多选大图一次性占满内存
  static const int maxBatchCount = 20;
  static const int maxBatchBytes = 64 * 1024 * 1024;

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

  /// 测试 seam：后台任务执行器（null 走 [Isolate.run]）
  ///
  /// widget 测试 FakeAsync 不便驱动真实 isolate；单测保留真实 Isolate.run
  /// 覆盖哈希/写盘路径，UI 测试注入同步执行器只验证链路。
  @visibleForTesting
  static Future<T> Function<T>(T Function() action)? isolateOverride;

  /// 测试 seam：下一次索引落盘失败（验证内存不先于落盘）
  @visibleForTesting
  static bool failNextIndexWrite = false;

  /// 测试 seam：跳过串行队列（widget 测试的 FakeAsync 不便驱动跨 await
  /// 链；并发串行性由纯 Dart 单测覆盖）
  @visibleForTesting
  static bool bypassSerialization = false;

  static bool get _isFlutterTest =>
      Platform.environment['FLUTTER_TEST'] == 'true';

  /// 变更操作串行队列：所有写操作按调用顺序执行，避免 await 期间旧索引
  /// 回写/删除相册后仍按旧下标写入（P2-1）。
  Future<void> _opTail = Future<void>.value();

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

  /// 串行执行变更操作（action 内部异常原样返回给调用方，队列继续）
  ///
  /// 每个调用方在自己的 zone 内 await 前一个操作的完成信号，再执行
  /// action 并完成自己的信号；避免跨 zone 的 `.then` 链在 widget 测试
  /// FakeAsync 下无法推进。
  Future<T> _serialize<T>(Future<T> Function() action) async {
    // 无真实相册目录的测试宿主（未注入 seam）不需要串行队列：FakeAsync
    // 下跨 await 队列会让恢复流程的 reload 悬挂。
    if (bypassSerialization || (_isFlutterTest && supportDirOverride == null)) {
      return action();
    }
    final previous = _opTail;
    final done = Completer<void>();
    _opTail = done.future;
    try {
      await previous;
      return await action();
    } finally {
      done.complete();
    }
  }

  /// 后台执行 CPU/IO 任务（默认 Isolate.run；测试可注入同步执行器）
  static Future<T> _runBackground<T>(T Function() action) {
    final override = isolateOverride;
    if (override != null) return override(action);
    return Isolate.run(action);
  }

  static void _ensureNotWeb() {
    if (kIsWeb) throw UnsupportedError('Web 端不支持封面相册');
  }

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
  ///
  /// 走变更队列：等待进行中的首次加载/写操作完成后再重置，避免并发
  /// 加载把旧结果写回（P3 reload 并发登记）。
  Future<void> reload() => _serialize(() async {
    final running = _loading;
    // loaded=true 时无需等待（completed future 可能来自其他 zone）；
    // loaded=false 才是真正的首次加载在途，必须等它结束。
    if (running != null && !_loaded) {
      try {
        await running;
      } catch (_) {
        // 首次加载失败不阻断重读
      }
    }
    _loaded = false;
    _loading = null;
    _albums = const <CoverAlbum>[];
    _pendingMigration = null;
    await ensureLoaded();
  });

  Future<void> _load({required bool migrate}) async {
    if (kIsWeb) {
      _loaded = true;
      _loading = null;
      revision.value++;
      return;
    }
    final override = supportDirOverride;
    if (_isFlutterTest && override == null) {
      // 测试环境未注入目录：跳过平台通道（FakeAsync 下可能永不完成）
      debugPrint('[CoverAlbumStore] 测试环境未注入 Support 目录，跳过加载');
      _loaded = true;
      _loading = null;
      revision.value++;
      return;
    }
    try {
      final support = await (override ?? getApplicationSupportDirectory)();
      final root = Directory(
        '${support.absolute.path}${Platform.pathSeparator}$rootSubDir',
      );
      _rootPath = root.path;
      _cleanupStaleIndexTemps(root);
      _albums = await _readIndex(root);
      if (migrate) {
        try {
          _pendingMigration = await _migrateLegacyCovers(root);
        } catch (e) {
          // 迁移失败不回滚已读取索引；下次启动重试（marker 未写入）
          debugPrint('[CoverAlbumStore] 旧封面迁移失败，保留现有索引: $e');
          _pendingMigration = null;
        }
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
  Future<String> createAlbum(String name) => _serialize(() async {
    _ensureNotWeb();
    if (!_loaded) await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const CoverAlbumException('相册名称不能为空');
    }
    final root = _requireRoot();
    final id = _generateAlbumId();
    final album = CoverAlbum(id: id, name: trimmed);
    final dir = Directory(_albumDirPath(root, id));
    dir.createSync(recursive: true);
    final next = <CoverAlbum>[..._albums, album];
    try {
      _persistIndex(root, next);
    } catch (_) {
      _deleteDirectoryQuietlySync(dir);
      rethrow;
    }
    _albums = next;
    revision.value++;
    return id;
  });

  /// 重命名相册
  Future<void> renameAlbum(String albumId, String name) => _serialize(() async {
    _ensureNotWeb();
    if (!_loaded) await ensureLoaded();
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
    // 先落盘成功再更新内存，避免“内存先于落盘”
    _persistIndex(root, next);
    _albums = next;
    revision.value++;
  });

  /// 删除相册（索引移除 + 目录递归清理）
  Future<void> deleteAlbum(String albumId) => _serialize(() async {
    _ensureNotWeb();
    if (!_loaded) await ensureLoaded();
    if (!_albumIdPattern.hasMatch(albumId)) {
      throw const CoverAlbumException('相册标识非法');
    }
    final index = _albums.indexWhere((album) => album.id == albumId);
    if (index < 0) {
      throw const CoverAlbumException('相册不存在或已删除');
    }
    final root = _requireRoot();
    final next = <CoverAlbum>[
      for (final album in _albums)
        if (album.id != albumId) album,
    ];
    _persistIndex(root, next);
    _albums = next;
    _deleteDirectoryQuietlySync(Directory(_albumDirPath(root, albumId)));
    revision.value++;
  });

  /// 批量导入图片（按内容 SHA-256 命名；同一内容不重复写盘）
  ///
  /// 单张校验失败（空/超限/非图/IO）记入 [CoverAlbumImportResult.failures]，
  /// 不阻断同批其他图片；同内容重复计入 [CoverAlbumImportResult.duplicateCount]。
  Future<CoverAlbumImportResult> importImages(
    String albumId, {
    required bool isDark,
    required List<CoverAlbumImageInput> inputs,
  }) => _serialize(() async {
    _ensureNotWeb();
    if (!_loaded) await ensureLoaded();
    if (inputs.isEmpty) return const CoverAlbumImportResult();
    _validateBatch(inputs);
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

    // await 后按 id 重定位：相册被删除（外部/异常路径）时清理已复制文件，
    // 绝不按旧下标回写索引（P2-1）。
    final latestIndex = _albums.indexWhere((item) => item.id == albumId);
    if (latestIndex < 0) {
      _deleteUnreferencedFiles(result.imported);
      throw const CoverAlbumException('相册已删除');
    }
    if (result.imported.isNotEmpty) {
      final latest = _albums[latestIndex];
      final merged = _mergeImages(
        isDark ? latest.darkImages : latest.lightImages,
        result.imported,
      );
      final next = List<CoverAlbum>.of(_albums);
      next[latestIndex] = isDark
          ? latest.copyWith(darkImages: merged)
          : latest.copyWith(lightImages: merged);
      try {
        _persistIndex(root, next);
      } catch (_) {
        // 索引未落盘：内存保持旧列表，删除本次新增的孤儿文件
        _deleteUnreferencedFiles(result.imported);
        rethrow;
      }
      _albums = next;
      revision.value++;
    }
    return result;
  });

  /// 删除单张图片
  ///
  /// 若该文件仍被另一侧引用（日/夜共用同一内容文件）则保留；否则删文件，
  /// 相册目录为空时一并删除。
  Future<void> removeImage(
    String albumId, {
    required bool isDark,
    required String fileName,
  }) => _serialize(() async {
    _ensureNotWeb();
    if (!_loaded) await ensureLoaded();
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
    _persistIndex(root, next);
    _albums = next;

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
  });

  void _validateBatch(List<CoverAlbumImageInput> inputs) {
    if (inputs.length > maxBatchCount) {
      throw CoverAlbumException('单次最多导入 $maxBatchCount 张图片');
    }
    var total = 0;
    for (final input in inputs) {
      total += input.bytes.length;
      if (total > maxBatchBytes) {
        throw CoverAlbumException(
          '本次选择图片总大小超过 ${maxBatchBytes ~/ (1024 * 1024)}MB',
        );
      }
    }
  }

  /// 删除索引未引用的新文件（落盘失败/相册消失时回收）
  void _deleteUnreferencedFiles(List<CoverAlbumImage> images) {
    if (images.isEmpty) return;
    final referenced = <String>{
      for (final album in _albums)
        for (final image in <CoverAlbumImage>[
          ...album.lightImages,
          ...album.darkImages,
        ])
          image.path,
    };
    for (final image in images) {
      if (referenced.contains(image.path)) continue;
      _deleteFileQuietlySync(File(image.path));
    }
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

  /// 书名种子 → 图片下标（对齐参考版 `Random(seed.hashCode).nextInt(n)`）
  ///
  /// [seed] 由调用方按 `name ?? author ?? coverUrl ?? ''` 解析；同一书名
  /// 每次取同一张，空种子也稳定（Random(0) 的结果由 Dart 固定实现）。
  static int coverAlbumSeedIndex(String? seed, int count) {
    if (count <= 0) return 0;
    var hash = 0;
    for (final unit in (seed ?? '').codeUnits) {
      hash = (hash * 31 + unit) & 0xFFFFFFFF;
    }
    return math.Random(hash).nextInt(count);
  }

  /// 测试隔离：恢复默认 seam 并清空内存状态
  @visibleForTesting
  static void resetForTest() {
    supportDirOverride = null;
    decodeOverride = null;
    isolateOverride = null;
    failNextIndexWrite = false;
    bypassSerialization = false;
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
    _opTail = Future<void>.value();
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

  Future<List<CoverAlbum>> _readIndex(Directory root) async {
    // 整个索引读取 + 文件存在性校验放到后台 isolate；大索引/大量图片
    // 不会同步阻塞 UI isolate（测试 seam 内同步执行）。
    ({List<CoverAlbum> albums, bool needsUpgrade}) result;
    try {
      result = await _runBackground(() => _readIndexSync(root.path));
    } catch (e) {
      // isolate 不可用（受限平台/测试宿主）→ 同代码同步兜底
      debugPrint('[CoverAlbumStore] 后台索引读取失败，同步兜底: $e');
      result = _readIndexSync(root.path);
    }
    if (result.needsUpgrade && result.albums.isNotEmpty) {
      try {
        // 旧格式升级写回（小索引，主 isolate 即可）
        _persistIndex(root.path, result.albums);
      } catch (e) {
        debugPrint('[CoverAlbumStore] 旧索引升级写回失败: $e');
      }
    }
    return result.albums;
  }

  static ({List<CoverAlbum> albums, bool needsUpgrade}) _readIndexSync(
    String rootPath,
  ) {
    final indexFile = File('$rootPath${Platform.pathSeparator}$indexFileName');
    if (!indexFile.existsSync()) {
      return (albums: const <CoverAlbum>[], needsUpgrade: false);
    }
    try {
      final decoded = jsonDecode(indexFile.readAsStringSync());
      if (decoded is! Map) {
        return (albums: const <CoverAlbum>[], needsUpgrade: false);
      }
      final rawVersion = decoded['formatVersion'];
      final version = rawVersion is int ? rawVersion : 1;
      final rawAlbums = decoded['albums'];
      if (rawAlbums is! List) {
        return (albums: const <CoverAlbum>[], needsUpgrade: false);
      }
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
            lightImages: _mapExistingImagesSync(rootPath, id, lightRaw),
            darkImages: _mapExistingImagesSync(rootPath, id, darkRaw),
          ),
        );
      }
      return (albums: albums, needsUpgrade: version < formatVersion);
    } catch (e) {
      debugPrint('[CoverAlbumStore] 索引损坏，按空相册处理: $e');
      return (albums: const <CoverAlbum>[], needsUpgrade: false);
    }
  }

  static List<CoverAlbumImage> _mapExistingImagesSync(
    String rootPath,
    String albumId,
    Object? raw,
  ) {
    if (raw is! List) return const <CoverAlbumImage>[];
    final dirPath = _albumDirPath(rootPath, albumId);
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

  /// 清理索引落盘中断残留（仅自有 `.albums.json.tmp-*`）
  void _cleanupStaleIndexTemps(Directory root) {
    try {
      if (!root.existsSync()) return;
      for (final entity in root.listSync()) {
        if (entity is! File) continue;
        final name = _baseName(entity.path);
        if (name.startsWith('.$indexFileName.tmp-')) {
          _deleteFileQuietlySync(entity);
        }
      }
    } catch (_) {
      // 清理失败不阻断加载
    }
  }

  Future<CoverAlbumLegacyMigration?> _migrateLegacyCovers(
    Directory root,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final migrated = prefs.getBool(PrefKeys.coverAlbumMigrated) ?? false;
    // 已迁移且相册非空：无需再扫描旧路径（含缺失文件的日志噪声）
    if (migrated && _albums.isNotEmpty) return null;
    final lightRaw = prefs.getString(PrefKeys.coverDefaultAlbumId);
    final darkRaw = prefs.getString(PrefKeys.coverDefaultAlbumIdDark);
    final lightPaths = _existingLegacyPaths(lightRaw);
    final darkPaths = _existingLegacyPaths(darkRaw);
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
    final next = <CoverAlbum>[
      for (final item in _albums)
        if (item.id != legacyAlbumId) item,
      album,
    ];
    _persistIndex(root.path, next);
    _albums = next;
    await prefs.setBool(PrefKeys.coverAlbumMigrated, true);
    revision.value++;
    debugPrint(
      '[CoverAlbumStore] 旧封面路径已迁移: '
      '日间 ${lightResult.imported.length}、夜间 ${darkResult.imported.length}',
    );
    return CoverAlbumLegacyMigration(
      albumId: legacyAlbumId,
      // 用原始值形态判断（即使夜间文件全部缺失，也要清掉旧路径字符串，
      // 避免后续被当成相册 ID）
      clearDarkSelection: _looksLikeLegacyPaths(darkRaw),
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
    var duplicates = 0;
    final dir = Directory(_albumDirPath(root, albumId));
    dir.createSync(recursive: true);

    for (final input in inputs) {
      try {
        await _validateInput(input);
        // 哈希在后台 isolate 计算：大图不占主 isolate
        final hash = await _runBackground(() {
          final digest = sha256.convert(input.bytes).toString();
          return (digest, _extensionOf(input.displayName));
        });
        final digest = hash.$1;
        final existingFile = _findExistingHashFile(dir, digest);
        final fileName = existingFile == null
            ? '$digest.${hash.$2}'
            : _baseName(existingFile.path);
        final targetPath = '${dir.path}${Platform.pathSeparator}$fileName';
        if (!File(targetPath).existsSync()) {
          // 写临时文件 + rename 也在后台 isolate 完成
          await _runBackground(
            () => _writeAtomicFileSync(dir.path, targetPath, input.bytes),
          );
        }
        if (seenNames.add(fileName)) {
          added.add(CoverAlbumImage(fileName: fileName, path: targetPath));
        } else {
          duplicates++;
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
    return CoverAlbumImportResult(
      imported: added,
      failures: failures,
      duplicateCount: duplicates,
    );
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

  /// 按内容哈希查找相册目录内已有文件（扩展名可能不同；目录很小，同步扫描）
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

  /// 同上临时文件 + rename 原子写（在后台 isolate 内同步执行）
  static void _writeAtomicFileSync(
    String dirPath,
    String targetPath,
    Uint8List bytes,
  ) {
    final fileName = _baseName(targetPath);
    final tmp = File(
      '$dirPath${Platform.pathSeparator}.$fileName'
      '.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      tmp.writeAsBytesSync(bytes, flush: true);
      if (File(targetPath).existsSync()) {
        _deleteFileQuietlySync(tmp);
      } else {
        tmp.renameSync(targetPath);
      }
    } on FileSystemException {
      _deleteFileQuietlySync(tmp);
      // rename 竞态：另一写入方已落正式文件 → 视为成功
      if (!File(targetPath).existsSync()) {
        throw const CoverAlbumException('保存图片失败');
      }
    }
  }

  void _persistIndex(String root, List<CoverAlbum> albums) {
    if (failNextIndexWrite) {
      failNextIndexWrite = false;
      throw const CoverAlbumException('保存封面相册失败（测试注入）');
    }
    final decoded = <String, Object?>{
      'formatVersion': formatVersion,
      'albums': <Map<String, Object?>>[
        for (final album in albums)
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
    File? temp;
    try {
      dir.createSync(recursive: true);
      final target = File('$root${Platform.pathSeparator}$indexFileName');
      temp = File(
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
      // 失败时不留下半成品 tmp（成功路径已 rename 为正式索引）
      final pending = temp;
      if (pending != null) _deleteFileQuietlySync(pending);
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
