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
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// 容器背景图落盘/解析/清理
class ThemeBackgroundImageStore {
  ThemeBackgroundImageStore._();

  /// 相对应用 Support 目录的根子目录
  static const String subDir = 'theme_backgrounds';

  /// 允许的图片扩展名（小写、无点）；其余回落到 jpg
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

    final bytes = await File(source).readAsBytes();
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    final ext = _extensionOf(source);
    final hash = md5.convert(bytes).toString();
    final fileName = '$hash.$ext';
    await Directory(slotDir).create(recursive: true);
    final target = File('$slotDir$sep$fileName');
    if (!target.existsSync()) {
      await target.writeAsBytes(bytes, flush: true);
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

  /// 源文件扩展名（小写）；未知/无扩展名回落 jpg
  static String _extensionOf(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'jpg';
    final ext = name.substring(dot + 1).toLowerCase();
    return _imageExts.contains(ext) ? ext : 'jpg';
  }

  /// 路径是否含 `..` 段（统一按 / 与 \ 切分，跨平台判定）
  static bool _hasParentSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').contains('..');
  }
}
