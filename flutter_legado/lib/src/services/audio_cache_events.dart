import 'dart:async';

/// 音频缓存变更事件载荷（对齐原版 `AudioCacheStateChanged`，
/// `app/src/main/java/io/legado/app/model/AudioCacheStateChanged.kt:3-8`
/// 的 bookUrl/key/cached 三元组——我方目录页只需书标识 + 章节下标即可
/// 触发重查 `audioCacheList`，故裁剪为这两字段）。
class AudioCacheChanged {
  const AudioCacheChanged({
    required this.bookUrl,
    required this.chapterIndex,
  });

  /// 发生缓存变更的书籍 URL（目录页据此过滤他书事件）
  final String bookUrl;

  /// 发生缓存变更的章节下标（emit 侧已知的章标识）
  final int chapterIndex;
}

/// 音频缓存变更进程内事件（对齐原版 `EventBus.AUDIO_CACHE_CHANGED`）
///
/// 原版依据（`app/src/main/java/io/legado/app/`）：
/// - `service/AudioCacheService.kt:222-225`：批量预下载循环里每章
///   `cacheChapter` 成功后 `postEvent(EventBus.AUDIO_CACHE_CHANGED,
///   AudioCacheStateChanged(book.bookUrl, key, true, treeUri))`；
/// - `ui/book/toc/ChapterListFragment.kt:196-208`：目录页订阅该事件，
///   命中当前书后把 key 增量加入 `audioCacheKeys` 并 `notifyItemChanged`
///   ——徽标「下载中逐章实时出现」。
///
/// 我方落地（B2 收口提效，契约零变更）：听书页 `_runAudioCacheBatch`
/// 每章成功后经本单例 notify，目录页订阅后立即重查
/// `BookApi.audioCacheList`（契约 §2.47），把徽标刷新从「≤1s 轮询延迟」
/// 缩短为即时；数据与轮询一致时复用目录页既有「无变化跳过 setState」
/// 守卫，不产生额外重建。
///
/// 约束（有意设计）：
/// - **纯 Dart 进程内事件，零 FFI**（字节与状态均不过 FFI；生命周期与
///   进程内页面栈一致，不做跨进程/持久化）；
/// - broadcast 单例：无订阅者时 notify 为 no-op；订阅方（目录页）负责在
///   `dispose` 时取消订阅，避免页面销毁后仍被回调（防泄漏）；
/// - 控制器不关闭（进程级单例，随进程退出释放）——与既有
///   `AudioService`（`services/audio_service.dart:61-66`）同型。
class AudioCacheEvents {
  AudioCacheEvents._();

  /// 单例实例（只读入口；调用方不得持有/替换控制器）
  static final AudioCacheEvents instance = AudioCacheEvents._();

  final StreamController<AudioCacheChanged> _controller =
      StreamController<AudioCacheChanged>.broadcast();

  /// 章节缓存变更事件流（只读；订阅方在 dispose 时取消订阅）
  Stream<AudioCacheChanged> get stream => _controller.stream;

  /// 通知「某书某章缓存成功」（对齐原版服务循环成功分支 postEvent）
  void notifyChapterCached({
    required String bookUrl,
    required int chapterIndex,
  }) {
    if (_controller.isClosed) return;
    _controller.add(
      AudioCacheChanged(bookUrl: bookUrl, chapterIndex: chapterIndex),
    );
  }
}
