// 书籍分组匹配工具（书架展示 / 隐私判定共用）
//
// 从 `providers/bookshelf/bookshelf_state.dart` 抽出：隐私内容判定
// （`services/privacy_content_service.dart`、`providers/privacy/*`）与书架
// 派生过滤必须复用**同一份**混合语义，避免长出第二套判定后漂移。
// `bookshelf_state.dart` 仍 re-export 本文件，既有调用方 import 不变。
//
// 编写：全栈工程师（批9c） ｜ 2026-11-09
import '../models/models.dart';

/// 新分组位掩码最大组合值（1<<30 及以下所有位全开）
const int kMaxCustomGroupMask = (1 << 31) - 1;

/// 是否为 2 的幂（1,2,4,…；0/负数返回 false）
bool isPowerOfTwoGroupId(int groupId) =>
    groupId > 0 && (groupId & (groupId - 1)) == 0;

/// 书籍是否属于自定义分组（混合语义，2026-11-06 设备修复）
///
/// - [groupId] 为 2 的幂（新分组）→ `book.group` 位掩码匹配；
/// - [groupId] 为非 2 的幂（旧时间戳/任意 ID）→ `book.group == groupId`；
/// - `book.group` 仍是旧时间戳（> 位掩码最大值）→ 只做 exact 匹配，
///   避免旧书的低位 bit 误命中新 2^n 分组；
/// - `groupId <= 0`（特殊组）不走本 helper。
bool bookBelongsToCustomGroup(Book book, int groupId) {
  if (groupId <= 0) return false;
  if (!isPowerOfTwoGroupId(groupId)) {
    return book.group == groupId;
  }
  // 旧时间戳/任意超大值不是位掩码，只按 exact 兼容
  if (book.group <= 0 || book.group > kMaxCustomGroupMask) {
    return book.group == groupId;
  }
  return (book.group & groupId) != 0;
}

/// 书籍命中的自定义分组名（按传入组顺序；空名过滤，旧时间戳 exact）
List<String> bookGroupNames(Book book, Iterable<BookGroup> groups) => [
  for (final group in groups)
    if (group.groupId > 0 &&
        bookBelongsToCustomGroup(book, group.groupId) &&
        group.groupName.trim().isNotEmpty)
      group.groupName.trim(),
];

/// 分组分配后的新 `books.group` 值
///
/// - 新 2^n 组：旧位掩码值 OR 新位（保留其它组）；
/// - 旧时间戳组/书籍仍为旧时间戳值：整体改为该组（旧值不做位运算）。
int nextGroupMaskOnAssign(Book book, int groupId) {
  if (groupId <= 0) return book.group;
  if (!isPowerOfTwoGroupId(groupId) ||
      book.group < 0 ||
      book.group > kMaxCustomGroupMask) {
    return groupId;
  }
  return book.group | groupId;
}

/// 从分组移除后的新 `books.group` 值
///
/// - 新 2^n 组：清对应位，保留其它组；
/// - 旧时间戳组：仅当 exact 命中时清 0（不做位运算）。
int nextGroupMaskOnRemove(Book book, int groupId) {
  if (groupId <= 0) return book.group;
  if (!isPowerOfTwoGroupId(groupId)) {
    return book.group == groupId ? 0 : book.group;
  }
  if (book.group < 0 || book.group > kMaxCustomGroupMask) {
    return book.group;
  }
  return book.group & ~groupId;
}
