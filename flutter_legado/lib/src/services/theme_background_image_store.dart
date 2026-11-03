// [设置批2b-1a | 2026-11-01] 主题容器背景图持久化存储 — 全栈工程师
//
// 语义基准（参考版 legado-with-MD3）：
// - 参考版把大容器背景图复制到 `externalFiles/container_background/large_light/
//   <md5>.<ext>`，SharedPreferences 存**绝对路径**，替换/清除时删除自有旧文件
//   （`ui/config/themeConfig/ThemeConfigViewModel.kt:438-477,501-534`）。
// - 我方 iOS 容器 UUID 会随重签名/重装变化，绝对路径不可迁移（与本地书
//   `LocalBookStore` 同类问题）。故落盘仍按参考版「内容哈希命名 + 按槽位
//   分目录」，但偏好值存**相对应用 Support 目录的可迁移标识**
//   （`theme_backgrounds/large_light/<md5>.<ext>`，正斜杠）；读取侧用当前
//   容器 Support 目录运行时拼接。绝对路径（参考版/旧备份）原样透传，文件
//   缺失时由调用方按「无图」回落。
// - 去重：同一张图重复选择命中同一哈希文件名，不重复写盘；替换/清除只删除
//   Support 根目录内的自有文件，绝不删除外部路径（参考版 deleteOwnedBackground
//   同口径）。
//
// [P2 回修 | 2026-11-01]
// - 存前校验：大小上限 32MB + 引擎试解码（HEIC/改扩展名的非图片在选图时
//   即失败并提示，不把坏图落盘）；
// - 流式 md5（crypto 的 Hash 作为 StreamTransformer）+ 原生 File.copy，
//   避免整文件读入 Dart 堆；落盘先写 `.tmp-<micros>` 再 rename 原子替换；
// - `.9.png` 保留原双扩展名，供 2b-1b 九宫格渲染迁移识别；
// - cleanupOrphansSync：设置页低成本回收未引用的自有图片（含中断残留 tmp）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// 容器背景图落盘/解析/清理
class ThemeBackgroundImageStore {
  ThemeBackgroundImageStore._();

  /// 相对应用 Support 目录的根子目录
  static const String subDir = 'theme_backgrounds';

  /// 槽位名（大容器 / 项目卡面，日夜各一）。
  /// [设置批2b-1b-2b] 新增项目图槽位；`.9.png` 与普通图共用同一槽位。
  static const String largeLightSlot = 'large_light';
  static const String largeDarkSlot = 'large_dark';
  static const String itemLightSlot = 'item_light';
  static const String itemDarkSlot = 'item_dark';

  /// 孤儿清理扫描的槽位（顺序固定）
  static const List<String> slotDirs = <String>[
    largeLightSlot,
    largeDarkSlot,
    itemLightSlot,
    itemDarkSlot,
  ];

  /// 单张图大小上限（32MB）：超过直接拒绝，避免异常大图拖垮内存/磁盘
  static const int maxBytes = 32 * 1024 * 1024;

  /// 中断残留 `.tmp-*` 的最短保留时长：只清理超过该时长的临时文件，
  /// 避免与"正在写入的新图"竞争（参考 10 分钟阈值）。
  static const Duration tmpOrphanMinAge = Duration(minutes: 10);

  /// 允许的图片扩展名（小写、无点）；其余回落到 jpg。
  /// 注意 `.9.png` 不在集合内，由 [_extensionOf] 单独保留双扩展名。
  static const Set<String> _imageExts = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  /// 槽位名只允许小写字母/下划线，防止路径穿越（调用方传固定常量）
  static final RegExp _slotPattern = RegExp(r'^[a-z_]+$');

  /// 自有正式文件名：`<32位小写md5>.<ext>`（含 `.9.png`）
  static final RegExp _ownedFileNamePattern = RegExp(
    r'^[0-9a-f]{32}\.(?:9\.png|jpe?g|png|webp|gif|bmp)$',
  );

  /// 自有原子写临时文件名：`.<32位小写md5>.<ext>.tmp-<micros>`
  static final RegExp _tmpFileNamePattern = RegExp(
    r'^\.[0-9a-f]{32}\..+\.tmp-\d+$',
  );

  /// 测试 seam：应用 Support 目录获取（默认 path_provider）。
  /// 测试可覆盖为返回临时目录，避免触碰真实沙盒。
  static Future<Directory> Function() supportDir = getApplicationSupportDirectory;

  /// 缓存的 Support 绝对路径（[warmWith]/[store]/[ensureWarm] 填充），
  /// 供同步 [resolveSync] 使用（IosGroup build 无 async 上下文）。
  static String? _supportPath;

  /// 预热 [resolveSync] 的基目录缓存。
  static void warmWith(Directory dir) {
    _supportPath = dir.absolute.path;
  }

  /// 基目录缓存是否已就绪（[resolveSync] 可解析相对标识）
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
      // 基目录不可得：resolveSync 原样返回相对标识 → isUsableSync=false，
      // 容器背景按「无图」回落，不阻断页面渲染。
    }
  }

  /// 把 [sourcePath] 拷入 `Support/theme_backgrounds/<slot>/`，返回相对
  /// 可迁移标识（`theme_backgrounds/<slot>/<md5>.<ext>`，正斜杠）。
  ///
  /// - 幂等：源文件已在目标槽位内 → 直接返回相对标识，不做自拷贝。
  /// - 去重：目标文件名（内容哈希）已存在 → 不重复写盘。
  /// - 存前校验：空文件/超 [maxBytes]/引擎不可解码（HEIC 等）→ 抛
  ///   [FormatException]，调用方提示并保留旧图。
  /// - 原子写：先落 `.tmp-<micros>` 再 rename，异常不留下半成品正式文件。
  /// - 失败（源不存在 / 读写异常 / Web）抛出，由调用方提示并保留旧图。
  static Future<String> store(
    String sourcePath, {
    required String slot,
  }) async {
    if (kIsWeb) throw UnsupportedError('Web 端不支持容器背景图');
    if (!_slotPattern.hasMatch(slot)) {
      throw ArgumentError.value(slot, 'slot', '非法槽位名');
    }
    final support = await supportDir();
    final supportPath = support.absolute.path;
    _supportPath = supportPath;

    final sep = Platform.pathSeparator;
    final slotDir = '$supportPath$sep$subDir$sep$slot';
    final source = File(sourcePath).absolute.path;
    final prefix = '$slotDir$sep';

    // 幂等：已在目标槽位内 → 直接返回相对标识
    if (source.startsWith(prefix)) {
      final name = source.substring(prefix.length).replaceAll(sep, '/');
      return '$subDir/$slot/$name';
    }

    final sourceFile = File(source);
    final length = await sourceFile.length();
    if (length <= 0) throw const FormatException('图片内容为空');
    if (length > maxBytes) {
      throw FormatException(
        '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）',
      );
    }
    await _validateDecodable(sourceFile);
    // 流式 md5：不把整文件读入 Dart 堆（32MB 上限已兜底）
    final digest = await md5.bind(sourceFile.openRead()).first;
    final ext = _extensionOf(source);
    final fileName = '$digest.$ext';

    await Directory(slotDir).create(recursive: true);
    final target = File('$slotDir$sep$fileName');
    if (target.existsSync()) return '$subDir/$slot/$fileName';

    // 原子写：同目录临时文件 + rename，避免读到写了一半的文件
    final tmp = File(
      '$slotDir$sep.$fileName.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await sourceFile.copy(tmp.path);
      if (target.existsSync()) {
        // 并发写入同一内容：对方已落正式文件，丢弃本次临时文件
        await _safeDelete(tmp);
      } else {
        await tmp.rename(target.path);
      }
    } on FileSystemException {
      await _safeDelete(tmp);
      // rename 竞态：对方刚好同时落盘 → 视为成功
      if (!target.existsSync()) rethrow;
    }
    return '$subDir/$slot/$fileName';
  }

  /// [设置批2b-1b-2a] 字节流落盘（Android SAF 选图路径）
  ///
  /// SAF 通过 fd 读出字节后直接交给本方法，避免 file_picker 的 Android
  /// MediaStore 路径/压缩链路（陈旧缩略图会触发原生 FATAL）。校验口径与
  /// [store] 完全一致：非空、≤[maxBytes]、引擎可解码；文件名仍按内容 md5，
  /// 先写 `.tmp-<micros>` 再 rename 原子替换。
  ///
  /// [originalName] 仅用于推断扩展名与错误提示（内容哈希才是文件名）。
  static Future<String> storeBytes(
    Uint8List bytes, {
    required String originalName,
    required String slot,
  }) async {
    if (kIsWeb) throw UnsupportedError('Web 端不支持容器背景图');
    if (!_slotPattern.hasMatch(slot)) {
      throw ArgumentError.value(slot, 'slot', '非法槽位名');
    }
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    if (bytes.length > maxBytes) {
      throw FormatException(
        '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）',
      );
    }
    await _validateDecodableBytes(bytes, originalName);

    final support = await supportDir();
    final supportPath = support.absolute.path;
    _supportPath = supportPath;

    final sep = Platform.pathSeparator;
    final slotDir = '$supportPath$sep$subDir$sep$slot';
    final digest = md5.convert(bytes).toString();
    final ext = _extensionOf(originalName);
    final fileName = '$digest.$ext';

    await Directory(slotDir).create(recursive: true);
    final target = File('$slotDir$sep$fileName');
    if (target.existsSync()) return '$subDir/$slot/$fileName';

    final tmp = File(
      '$slotDir$sep.$fileName.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (target.existsSync()) {
        // 并发写入同一内容：对方已落正式文件，丢弃本次临时文件
        await _safeDelete(tmp);
      } else {
        await tmp.rename(target.path);
      }
    } on FileSystemException {
      await _safeDelete(tmp);
      // rename 竞态：对方刚好同时落盘 → 视为成功
      if (!target.existsSync()) rethrow;
    }
    return '$subDir/$slot/$fileName';
  }

  /// 同步：把偏好值解析为真实文件路径。
  ///
  /// - 空串 → 空串（无图）。
  /// - 绝对路径（`/...`、Windows 盘符、参考版/旧备份携带的路径）→ 原样返回，
  ///   由 [isUsableSync] 检查存在性。
  /// - 相对可迁移标识 → 拼到当前 Support 目录；基目录未预热时原样返回，
  ///   调用方按「文件不存在」优雅降级。
  static String resolveSync(String stored) {
    if (stored.isEmpty) return '';
    if (stored.startsWith('/')) return stored;
    if (File(stored).isAbsolute) return stored;
    final root = _supportPath;
    if (root == null) return stored;
    return '$root${Platform.pathSeparator}'
        '${stored.replaceAll('/', Platform.pathSeparator)}';
  }

  /// 同步：偏好值对应的图片当前是否可用（存在且非空文件）。
  ///
  /// 缺失返回 false → 容器背景回落为原主题底色/全局壁纸（不抛异常）。
  /// 含 `..` 段的路径一律视为不可用（备份内容可能被篡改，防路径穿越）。
  static bool isUsableSync(String stored) {
    if (stored.isEmpty) return false;
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

  /// 删除自有背景图文件；只处理 Support 根目录内的路径。
  ///
  /// - 相对标识 → 当前 Support 目录拼接后删除。
  /// - 绝对路径 → 仅当其位于当前 Support 目录内才删除（参考版
  ///   `deleteOwnedBackground` 同口径），外部/参考版设备路径不动。
  /// - 文件不存在 / 删除失败静默（清理是尽力而为，不影响偏好值已清空）。
  static Future<bool> deleteOwned(String stored) async {
    if (stored.isEmpty || kIsWeb) return false;
    await ensureWarm();
    final root = _supportPath;
    if (root == null) return false;
    final resolved = resolveSync(stored);
    if (resolved.isEmpty) return false;
    // 防路径穿越：`theme_backgrounds/../x` 字符串前缀虽是自有目录，
    // 实际会删除 Support 根下/外的文件；含 `..` 段一律不删。
    if (_hasParentSegment(resolved)) return false;
    final owned = resolved.startsWith(
      '$root${Platform.pathSeparator}$subDir${Platform.pathSeparator}',
    );
    if (!owned) return false;
    try {
      final file = File(resolved);
      // 先同步判存在：缺失是常见回落路径，避免无谓的异步 IO 往返
      //（也让 widget 测试等无真实事件循环的调用方不悬挂）
      if (!file.existsSync()) return false;
      await file.delete();
      return true;
    } catch (e) {
      // 清理失败不影响偏好清除/新图生效
      return false;
    }
  }

  /// 低成本孤儿清理（设置页加载时调用）：删除槽位目录中未被引用的自有图片
  /// 与**超过 [tmpOrphanMinAge] 的**中断残留临时文件；非自有命名不动。
  ///
  /// [设置批2b-1b-2b] 扫描 [slotDirs] 四个槽位
  /// （large_light/large_dark/item_light/item_dark），因此调用方 [keep]
  /// 必须同时包含大容器图与项目图的当前值（日/夜共四项）。
  /// [keep] 为当前仍被引用的偏好值（绝对路径或相对标识均可）。
  /// 返回删除数量。基目录未预热时直接返回 0（不触发平台通道）。
  static int cleanupOrphansSync({required Iterable<String> keep}) {
    if (kIsWeb) return 0;
    final root = _supportPath;
    if (root == null) return 0;
    final sep = Platform.pathSeparator;
    final now = DateTime.now();
    final keepPaths = <String>{};
    for (final stored in keep) {
      final resolved = resolveSync(stored);
      if (resolved.isEmpty || _hasParentSegment(resolved)) continue;
      keepPaths.add(File(resolved).absolute.path);
    }
    var removed = 0;
    for (final slot in slotDirs) {
      final dir = Directory('$root$sep$subDir$sep$slot');
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.absolute.path;
        if (keepPaths.contains(path)) continue;
        final name = _baseName(path);
        final isTmp = _tmpFileNamePattern.hasMatch(name);
        if (!isTmp && !_ownedFileNamePattern.hasMatch(name)) continue;
        if (isTmp) {
          // 只清超过保留时长的 tmp：刚写入/并发中的临时文件不动
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
    }
    return removed;
  }

  /// 引擎试解码：显式 `ImageDescriptor.encoded` 接管所有权（成功即释放
  /// buffer），再 `getNextFrame()` 解一帧——只解析头部但帧数据截断的图片
  /// （如截断 PNG）也会在此失败。HEIC 等不支持格式同样抛
  /// [FormatException]。
  static Future<void> _validateDecodable(File file) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // descriptor 已接管解码数据；立即释放 buffer，置空避免 finally 双释放
      buffer.dispose();
      buffer = null;
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      // 真正解一帧：截断 PNG/损坏数据在此暴露（只建 codec 不够）
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } catch (_) {
      throw FormatException('不是可解码的图片：${_baseName(file.path)}');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      // 仅失败且仍由本方法持有的 buffer（成功路径已提前释放）
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
      // descriptor 已接管解码数据；立即释放 buffer，置空避免 finally 双释放
      buffer.dispose();
      buffer = null;
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      // 真正解一帧：截断 PNG/损坏数据在此暴露（只建 codec 不够）
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } catch (_) {
      throw FormatException('不是可解码的图片：${_baseName(originalName)}');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      // 仅失败且仍由本方法持有的 buffer（成功路径已提前释放）
      buffer?.dispose();
    }
  }

  /// 源文件扩展名（小写）；未知/无扩展名回落 jpg；`.9.png` 保留双扩展名
  static String _extensionOf(String path) {
    final name = _baseName(path);
    final lower = name.toLowerCase();
    if (lower.endsWith('.9.png')) return '9.png';
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'jpg';
    final ext = name.substring(dot + 1).toLowerCase();
    return _imageExts.contains(ext) ? ext : 'jpg';
  }

  static String _baseName(String path) {
    // 同时兼容 Windows `\` 与相对标识的 `/`（后者在未预热时原样返回）
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  /// 路径是否含 `..` 段（统一按 / 与 \ 切分，跨平台判定）
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
