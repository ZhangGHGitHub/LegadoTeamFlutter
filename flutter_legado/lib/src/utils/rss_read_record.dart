// RSS 已读写入门控（批29）
//
// 对齐原版 `ReadRss.kt:51` `if (AppConfig.enableRssReadRecord)`：
// 全局开关关闭时**不新增**阅读记录（已有记录保留，重新开启恢复写入）。
// 所有 RSS 已读写入入口（列表打开、详情/桥动作打开、后续 JS 扩展）统一经
// 本函数判定，避免开关语义散落。
import '../services/book_api.dart';

/// 按全局开关执行 RSS 已读写入
///
/// - [enabled] 为 false 时直接短路，不触达 [BookApi.rssMarkRead]；
/// - 写入失败不阻断阅读（对齐原版 `runCatching` 仅记日志语义）。
Future<void> rssMarkReadIfEnabled(
  BookApi api,
  bool enabled, {
  required String origin,
  required String title,
  String? link,
  int type = 0,
  String? sort,
  String? image,
  String? pubDate,
  int? durPos,
}) async {
  if (!enabled) return;
  try {
    await api.rssMarkRead(
      origin,
      title,
      link: link,
      type: type,
      sort: sort,
      image: image,
      pubDate: pubDate,
      durPos: durPos,
    );
  } catch (_) {
    // 历史写入失败不阻断阅读
  }
}
