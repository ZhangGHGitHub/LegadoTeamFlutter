import 'package:flutter/foundation.dart';

import '../../constants/pref_keys.dart';
import '../../services/book_api.dart';
import '../../services/settings_service.dart';

/// 漫画「已读章节图片保留数」清理触发器（契约 §2.46 `retainComicImages`）
///
/// 对齐原版 `BookHelp.clearComicCache` 的**触发时机**（原版在
/// `BookHelp.clearInvalidCache` 启动清理时执行；本重构版按任务要求改为
/// 漫画阅读器打开/翻章成功后触发，使设置「保留数量」当次阅读即生效）。
///
/// 职责边界：只做「读偏好 → 调 FFI → 静默降级」，窗口判定/正文解析/文件
/// 删除全部在 Rust（UI 层不含业务逻辑）。
///
/// 去重与限流：
/// - 同书同章节索引只触发一次（`_lastKey`），避免同章重载/重试反复调用；
/// - 排队任务只保留最后一个（`_seq`），快速翻章时不为每个中间章各扫一遍
///   目录；窗口覆盖当前章，最终一次即可；
/// - [reset] 用于换书/换源：作废排队中的旧书任务并允许同索引再次触发。
class MangaImageRetention {
  MangaImageRetention({
    required BookApi api,
    required SettingsService settings,
  })  : _api = api,
        _settings = settings;

  final BookApi _api;
  final SettingsService _settings;

  /// 串行链：任意时刻至多一个清理调用在途（Rust 侧为同步文件删除）
  Future<void> _tail = Future<void>.value();

  /// 最近一次已排队的 (bookUrl, chapterIndex)
  String? _lastKey;

  /// 排队序号：只执行最后一次排队任务
  int _seq = 0;

  /// 会话代数：换书/换源后作废排队任务
  int _generation = 0;

  /// 打开/翻章成功后调用（fire-and-forget；返回的 future 便于测试等待）
  Future<void> onChapterOpened({
    required String bookUrl,
    required int chapterIndex,
  }) {
    final key = '$bookUrl\u0000$chapterIndex';
    if (_lastKey == key) return Future<void>.value();
    _lastKey = key;
    final seq = ++_seq;
    final generation = _generation;
    final task = _tail.then((_) async {
      // 已被更新的章节/换书取代：跳过（最后一次排队任务才真正执行）
      if (seq != _seq || generation != _generation) return;
      await _run(bookUrl: bookUrl, chapterIndex: chapterIndex);
    });
    _tail = task.catchError((_) {});
    return task;
  }

  /// 换书/换源时复位（允许同索引再次触发，并作废旧任务）
  void reset() {
    _generation++;
    _seq++;
    _lastKey = null;
  }

  Future<void> _run({
    required String bookUrl,
    required int chapterIndex,
  }) async {
    try {
      final retain = await _settings.getIntPref(
        PrefKeys.imageRetainNum,
        defaultValue: 0,
      );
      if (retain <= 0) return; // 0 = 不清理（对齐原版 AppConfig 默认 0）
      final preDownload = await _settings.getIntPref(
        PrefKeys.preDownloadNum,
        defaultValue: 10,
      );
      await _api.retainComicImages(
        bookUrl: bookUrl,
        durIndex: chapterIndex,
        retain: retain,
        preDownload: preDownload,
      );
    } catch (e) {
      // 清理失败静默：缓存是加速器不是数据源，不影响阅读主流程
      debugPrint('[MangaImageRetention] 图片保留清理失败（静默）：$e');
    }
  }
}
