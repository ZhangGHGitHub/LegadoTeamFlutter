import 'package:shared_preferences/shared_preferences.dart';

import 'rust_api.dart';

/// 缓存管理服务
///
/// 提供缓存统计、清理功能和自动过期策略配置。
/// 对应 Android 原版 CacheBookService 中的缓存管理功能。
class CacheService {
  final RustApi _api;

  /// 自动过期天数持久化键
  static const _keyAutoExpireDays = 'cache_auto_expire_days';

  CacheService(this._api);

  /// 获取缓存统计信息
  ///
  /// 返回 Map 包含：
  /// - totalSize: 缓存总大小（字节）
  /// - bookCount: 缓存书籍数量
  /// - chapterCount: 缓存章节数量
  Future<Map<String, dynamic>> getCacheStats() async {
    final totalSize = await _api.getCacheSize();
    // 通过 Rust 侧获取缓存书籍和章节统计
    final bookCount = await _api.getCacheBookCount();
    final chapterCount = await _api.getCacheChapterCount();
    return {
      'totalSize': totalSize,
      'bookCount': bookCount,
      'chapterCount': chapterCount,
    };
  }

  /// 清除缓存
  ///
  /// [before] 若指定，则仅清除该时间之前的缓存；
  /// 若为 null，则清除全部缓存。
  /// 返回清除的缓存大小（字节）。
  Future<int> clearCache({DateTime? before}) async {
    final sizeBefore = await _api.getCacheSize();
    if (before != null) {
      await _api.clearCacheBefore(before.millisecondsSinceEpoch);
    } else {
      await _api.clearCache();
    }
    final sizeAfter = await _api.getCacheSize();
    final cleared = sizeBefore - sizeAfter;
    return cleared > 0 ? cleared : 0;
  }

  /// 设置自动过期天数
  ///
  /// [days] 为 0 表示永不过期。
  Future<void> setAutoExpireDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyAutoExpireDays, days);
  }

  /// 获取当前自动过期天数配置
  ///
  /// 返回 0 表示永不过期，默认值为 0。
  Future<int> getAutoExpireDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyAutoExpireDays) ?? 0;
  }

  /// 格式化缓存大小为可读字符串
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
