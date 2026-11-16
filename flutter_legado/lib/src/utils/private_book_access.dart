// 无交互私密放行判定（A3：悬浮窗等「无页面上下文」入口复用）
//
// 页面入口（书架/详情/阅读记录/各阅读器路由闸门）能在需要时弹验证框；
// 但视频悬浮窗的创建点在 `VideoFloatWindowCoordinator`（无 BuildContext、
// 可能在原生事件回调里触发），不能弹框。此时只能做「静默判定」：
// 未授权即拒绝创建，并提示用户回应用内验证。
//
// fail-open 口径与 `BookOpenUtils.ensurePrivateAccess` 一致：策略/标记读取
// 失败、无法反查书籍时按「非私密」放行，绝不因一次 IO 失败锁死播放。
//
// 编写：全栈工程师（A3 浮窗闸门） ｜ 2026-11-17
import '../models/models.dart';
import '../providers/privacy/privacy_state.dart';
import '../services/privacy_content_service.dart';

/// 书籍是否可在「不弹验证框」的前提下放行
///
/// 返回 true 的充分条件之一：
/// - 总开关关闭 / 关闭「打开书籍时验证」；
/// - 私密标记快照未就绪（调用方应先 `ensureLoaded`；未就绪按 fail-open）；
/// - 书籍不是私密内容（单本标记 ∪ 私密分组）；
/// - 该书籍/所属分组已获准（会话级放行或 EveryTime 目标授权）。
bool isBookAllowedWithoutPrompt(
  Book book,
  PrivacyState privacy,
  PrivacyContentSnapshot content,
) {
  if (!privacy.enabled || !privacy.verifyOnOpenBook) return true;
  if (!content.loaded) return true;
  final facts = content.booksByUrl[book.bookUrl] ?? book;
  if (!content.isBookPrivate(facts)) return true;
  return privacy.isBookTargetGranted(facts);
}
