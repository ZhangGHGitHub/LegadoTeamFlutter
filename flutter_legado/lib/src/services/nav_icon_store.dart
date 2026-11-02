// [设置批2b-2a | 2026-11-02] 主导航自定义图标文件存储（对齐参考版
// ThemeConfigRouteScreen.kt:46-77 / ThemeConfigViewModel.selectNavigationIcon）
//
// 参考版口径：
// - 选图走系统图片选择器（GetContent "image/png"）；
// - 图片复制到 `filesDir/nav_icons/`，以**内容摘要**命名（同图重复选择
//   命中同一路径，避免覆盖固定文件名导致缓存到旧图）；
// - 多个槽位可引用同一文件，只有不再被任何槽位引用时才删除；
// - 恢复默认主题配置时整目录删除。
//
// [复核 P2-5/P2-6 | 2026-11-02]
// - 存前校验：32MB 上限 + 引擎试解码（坏图/改扩展名非图片在选择时即失败）；
// - 流式 sha1 + 原子写（`.tmp-<micros>` → rename），失败清理临时文件；
// - 偏好值改存**相对应用 Support 目录的可迁移标识**
//   `nav_icons/<sha1>.<ext>`（正斜杠），读取时按当前 Support 拼接；
//   Android SAF 字节流走 [importBytes]，不再经过 file_picker MediaStore；
// - 旧版本/旧备份的绝对路径原样兼容（存在即可用），删除仍只允许
//   Support/nav_icons 内的自有文件；
// - [cleanupOrphansSync] 回收未引用自有文件与超龄 tmp。
// — 全栈工程师 + UI，2026-11-02
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// 导航自定义图标文件存储
class NavIconStore {
  NavIconStore._();

  /// 相对应用 Support 目录的根子目录
  static const String subDir = 'nav_icons';

  /// 单个图标大小上限（32MB）：与容器图同口径
  static const int maxBytes = 32 * 1024 * 1024;

  /// 中断残留 `.tmp-*` 的最短保留时长（避免与正在写入的新图竞争）
  static const Duration tmpOrphanMinAge = Duration(minutes: 10);

  /// 允许的图片扩展名（小写、无点）；其余回落到 jpg
  static const Set<String> _imageExts = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  /// 自有正式文件名：`<40位小写sha1>.<ext>`
  static final RegExp _ownedFileNamePattern = RegExp(
    r'^[0-9a-f]{40}\.(?:jpe?g|png|webp|gif|bmp)$',
  );

  /// 自有原子写临时文件名：`.<40位sha1>.<ext>.tmp-<micros>`
  static final RegExp _tmpFileNamePattern = RegExp(
    r'^\.[0-9a-f]{40}\..+\.tmp-\d+$',
  );

  /// 测试 seam：应用 Support 目录获取（默认 path_provider）
  static Future<Directory> Function() supportDir =
      getApplicationSupportDirectory;

  /// 缓存的 Support 绝对路径（[ensureWarm]/[importBytes]/[importFromPath] 填充）
  static String? _supportPath;

  /// 预热 [resolveSync]/[isUsableSync] 的基目录缓存
  static void warmWith(Directory dir) {
    _supportPath = dir.absolute.path;
  }

  /// 基目录缓存是否已就绪
  static bool get isWarm => _supportPath != null;

  /// 测试隔离：清除基目录缓存（生产不调用）
  @visibleForTesting
  static void resetWarmCache() {
    _supportPath = null;
  }

  /// 启动/首个消费者：确保基目录缓存可用；失败不抛出（解析侧优雅降级）。
  static Future<void> ensureWarm() async {
    if (_supportPath != null) return;
    try {
      warmWith(await supportDir());
    } catch (_) {
      // 基目录不可得：相对标识按不可用处理，导航回退内置图标
    }
  }

  /// 图标目录（确保已预热后返回）
  static Future<Directory> directory() async {
    await ensureWarm();
    final root = _supportPath;
    if (root == null) {
      throw const FileSystemException('应用 Support 目录不可用');
    }
    final dir = Directory('$root${Platform.pathSeparator}$subDir');
    await dir.create(recursive: true);
    return dir;
  }

  /// 从用户选择的图片文件导入，返回相对可迁移标识
  ///
  /// 返回 `nav_icons/<sha1>.<ext>`；源文件已在目标目录内时直接返回标识。
  /// 空文件/超限/不可解码抛 [FormatException]；读写异常向上抛，由 UI 提示。
  static Future<String> importFromPath(String sourcePath) async {
    if (kIsWeb) throw UnsupportedError('Web 端不支持自定义导航图标');
    if (sourcePath.isEmpty) throw const FormatException('图片路径为空');
    final support = await _ensureSupport();
    final sep = Platform.pathSeparator;
    final dirPath = '$support$sep$subDir';
    final source = File(sourcePath).absolute.path;
    final prefix = '$dirPath$sep';

    // 幂等：已在目标目录内且文件名合法 → 直接返回相对标识
    if (source.startsWith(prefix)) {
      final name = source.substring(prefix.length).replaceAll(sep, '/');
      if (_ownedFileNamePattern.hasMatch(name)) return '$subDir/$name';
    }

    final sourceFile = File(source);
    final length = await sourceFile.length();
    if (length <= 0) throw const FormatException('图片内容为空');
    if (length > maxBytes) {
      throw FormatException(_tooLargeMessage());
    }
    await _validateDecodableFile(sourceFile);

    // 流式 sha1：不把整文件读入 Dart 堆（32MB 上限已兜底）
    final digest = await sha1.bind(sourceFile.openRead()).first;
    final extension = _extensionOf(source);
    final fileName = '$digest.$extension';
    final target = File('$dirPath$sep$fileName');
    if (await target.exists()) return '$subDir/$fileName';

    await Directory(dirPath).create(recursive: true);
    final tmp = File(
      '$dirPath$sep.$fileName.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await sourceFile.copy(tmp.path);
      if (await target.exists()) {
        await _safeDelete(tmp);
      } else {
        await tmp.rename(target.path);
      }
    } on FileSystemException {
      await _safeDelete(tmp);
      if (!await target.exists()) rethrow;
    }
    return '$subDir/$fileName';
  }

  /// 从 SAF/file_picker 读出的字节导入，返回相对可迁移标识
  ///
  /// [originalName] 仅用于推断扩展名与错误提示（内容哈希才是文件名）。
  static Future<String> importBytes(
    Uint8List bytes, {
    required String originalName,
  }) async {
    if (kIsWeb) throw UnsupportedError('Web 端不支持自定义导航图标');
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    if (bytes.length > maxBytes) {
      throw FormatException(_tooLargeMessage());
    }
    await _validateDecodableBytes(bytes, originalName);

    final support = await _ensureSupport();
    final sep = Platform.pathSeparator;
    final dirPath = '$support$sep$subDir';
    // 字节已在内存中，仍按流式 hash 口径处理，便于与文件路径一致
    final digest = await sha1.bind(Stream<Uint8List>.value(bytes)).first;
    final extension = _extensionOf(originalName);
    final fileName = '$digest.$extension';
    final target = File('$dirPath$sep$fileName');
    if (await target.exists()) return '$subDir/$fileName';

    await Directory(dirPath).create(recursive: true);
    final tmp = File(
      '$dirPath$sep.$fileName.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        await _safeDelete(tmp);
      } else {
        await tmp.rename(target.path);
      }
    } on FileSystemException {
      await _safeDelete(tmp);
      if (!await target.exists()) rethrow;
    }
    return '$subDir/$fileName';
  }

  /// 同步：偏好值 → 当前容器可读取的真实路径。
  ///
  /// - 空串/非法相对标识 → 空串（回退内置图标）。
  /// - 绝对路径（旧版本/旧备份）→ 原样返回，由 [isUsableSync] 检查存在性。
  /// - `nav_icons/<sha1>.<ext>` → 拼当前 Support 目录；基目录未预热时返回
  ///   空串（避免误读工作目录同名文件）。
  static String resolveSync(String stored) {
    if (stored.isEmpty) return '';
    if (stored.startsWith('/') || File(stored).isAbsolute) return stored;
    final root = _supportPath;
    if (root == null) return '';
    if (!stored.startsWith('$subDir/')) return '';
    if (_hasParentSegment(stored)) return '';
    return '$root${Platform.pathSeparator}'
        '${stored.replaceAll('/', Platform.pathSeparator)}';
  }

  /// 同步：偏好值对应的图标当前是否可用（存在且非空文件）
  static bool isUsableSync(String stored) {
    final resolved = resolveSync(stored);
    if (resolved.isEmpty) return false;
    if (_hasParentSegment(resolved)) return false;
    try {
      final file = File(resolved);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 旧图标不再被任何槽位引用时删除。
  ///
  /// - 相对标识 → 当前 Support 拼接后删除；
  /// - 旧绝对路径 → 仅当位于当前 `Support/nav_icons/` 内才删除；
  /// - [keep] 中相对/绝对路径混用均按解析后的绝对路径比较。
  /// - 文件不存在/删除失败静默返回 false。
  static Future<bool> deleteIfUnused(
    String stored, {
    required Iterable<String> keep,
  }) async {
    if (stored.isEmpty || kIsWeb) return false;
    await ensureWarm();
    final root = _supportPath;
    if (root == null) return false;
    final resolved = resolveSync(stored);
    if (resolved.isEmpty || _hasParentSegment(resolved)) return false;
    final keepPaths = <String>{};
    for (final item in keep) {
      if (item.isEmpty) continue;
      final path = resolveSync(item);
      if (path.isNotEmpty && !_hasParentSegment(path)) {
        keepPaths.add(File(path).absolute.path);
      }
    }
    if (keepPaths.contains(File(resolved).absolute.path)) return false;
    final ownedPrefix =
        '$root${Platform.pathSeparator}$subDir${Platform.pathSeparator}';
    if (!File(resolved).absolute.path.startsWith(ownedPrefix)) return false;
    try {
      final file = File(resolved);
      if (!await file.exists()) return false;
      await file.delete();
      return true;
    } catch (e) {
      debugPrint('NavIconStore.deleteIfUnused 失败: $e');
      return false;
    }
  }

  /// 清空图标目录（恢复默认时调用）
  static Future<void> deleteAll() async {
    if (kIsWeb) return;
    try {
      await ensureWarm();
      final root = _supportPath;
      if (root == null) return;
      final dir = Directory('$root${Platform.pathSeparator}$subDir');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('NavIconStore.deleteAll 失败: $e');
    }
  }

  /// 低成本孤儿清理（打开图标管理时调用）：删除未引用自有文件与超龄 tmp。
  ///
  /// [keep] 为当前仍被引用的偏好值（相对/绝对均可）。基目录未预热返回 0。
  static int cleanupOrphansSync({required Iterable<String> keep}) {
    if (kIsWeb) return 0;
    final root = _supportPath;
    if (root == null) return 0;
    final keepPaths = <String>{};
    for (final item in keep) {
      final resolved = resolveSync(item);
      if (resolved.isEmpty || _hasParentSegment(resolved)) continue;
      keepPaths.add(File(resolved).absolute.path);
    }
    final sep = Platform.pathSeparator;
    final dir = Directory('$root$sep$subDir');
    if (!dir.existsSync()) return 0;
    final now = DateTime.now();
    var removed = 0;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.absolute.path;
      if (keepPaths.contains(path)) continue;
      final name = _baseName(path);
      final isTmp = _tmpFileNamePattern.hasMatch(name);
      if (!isTmp && !_ownedFileNamePattern.hasMatch(name)) continue;
      if (isTmp) {
        try {
          final modified = entity.statSync().modified;
          if (now.difference(modified) < tmpOrphanMinAge) continue;
        } catch (_) {
          continue;
        }
      }
      try {
        entity.deleteSync();
        removed++;
      } catch (_) {
        // 正被读取/权限异常：跳过，下次再清
      }
    }
    return removed;
  }

  /// 引擎试解码：成功即释放 buffer/codec；截断/改扩展名非图抛 [FormatException]。
  static Future<void> _validateDecodableFile(File file) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      buffer.dispose();
      buffer = null;
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } catch (_) {
      throw FormatException('不是可解码的图片：${_baseName(file.path)}');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// 字节流版本：SAF fd 读取后不落中间文件，直接做同样的引擎试解码。
  static Future<void> _validateDecodableBytes(
    Uint8List bytes,
    String originalName,
  ) async {
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
    } catch (_) {
      throw FormatException('不是可解码的图片：${_baseName(originalName)}');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<String> _ensureSupport() async {
    await ensureWarm();
    final root = _supportPath;
    if (root == null) {
      throw const FileSystemException('应用 Support 目录不可用');
    }
    return root;
  }

  static String _tooLargeMessage() => '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）';

  /// 源文件扩展名（小写）；未知/无扩展名回落 jpg
  static String _extensionOf(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'jpg';
    final ext = name.substring(dot + 1).toLowerCase();
    return _imageExts.contains(ext) ? ext : 'jpg';
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  /// 路径是否含 `..` 段（统一按 / 与 \ 切分）
  static bool _hasParentSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').contains('..');
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不影响主流程
    }
  }
}
