// 私密内容标记 Provider（批9c）
//
// 单例持有 [PrivacyContentSnapshot]：书架、详情、阅读闸门、搜索提示、
// 阅读记录/书签/缓存管理都从这里取同一份私密标记，避免各自读 FFI 后漂移。
// 写入私密标记（批量设私密 / 分组私密开关）后由调用方 `refresh()`。
//
// 编写：全栈工程师（批9c） ｜ 2026-11-09
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/privacy_content_service.dart';
import '../providers.dart';

/// 私密内容标记快照 Provider
final privacyContentProvider =
    NotifierProvider<PrivacyContentNotifier, PrivacyContentSnapshot>(
      PrivacyContentNotifier.new,
    );

/// 私密内容标记加载/刷新
class PrivacyContentNotifier extends Notifier<PrivacyContentSnapshot> {
  Future<PrivacyContentSnapshot>? _loading;
  bool _disposed = false;

  @override
  PrivacyContentSnapshot build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    _loading ??= _load();
    return PrivacyContentSnapshot.empty;
  }

  /// 等待首轮加载完成（书架/详情/闸门在判定前可显式等待）
  Future<PrivacyContentSnapshot> ensureLoaded() => _loading ??= _load();

  /// 重新读取全部标记（批量设私密 / 分组开关保存后调用）
  ///
  /// 串行化在途加载：先等上一轮结束再读，避免旧请求晚到覆盖新标记。
  Future<void> refresh() {
    final previous = _loading;
    final next = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 上一轮失败不阻断本次刷新
        }
      }
      return _load();
    }();
    _loading = next;
    return next;
  }

  Future<PrivacyContentSnapshot> _load() async {
    if (_disposed) return PrivacyContentSnapshot.empty;
    final snapshot = await PrivacyContentService(
      api: ref.read(bookApiProvider),
    ).load();
    if (!_disposed) state = snapshot;
    return snapshot;
  }
}
