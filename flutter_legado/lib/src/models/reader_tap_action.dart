// 阅读器九宫格点击动作（批4a）
//
// 参考 `feature/reader/core/gesture/ReaderTapAction.kt:3-18`：
// legacyValue -1..13，顺序/文案对齐参考中文资源。9 个区域键名见
// `PrefKeys.clickAction*`（逐字对齐参考 PreferKey）。
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'package:flutter/foundation.dart' show immutable;

@immutable
enum ReaderTapAction {
  none(-1, '无操作'),
  menu(0, '菜单'),
  nextPage(1, '下一页'),
  previousPage(2, '上一页'),
  nextChapter(3, '下一章'),
  previousChapter(4, '上一章'),
  previousParagraph(5, '朗读上一段'),
  nextParagraph(6, '朗读下一段'),
  addBookmark(7, '添加书签'),
  editContent(8, '编辑内容'),
  toggleReplace(9, '替换开关'),
  catalog(10, '目录'),
  search(11, '全文搜索'),
  syncProgress(12, '同步阅读进度'),
  toggleReadAloud(13, '朗读暂停继续');

  final int code;
  final String label;

  const ReaderTapAction(this.code, this.label);

  /// 按 legacyValue 解析；未知值回落 none（对齐参考 fromLegacyValue）
  static ReaderTapAction fromCode(int? code) {
    for (final action in values) {
      if (action.code == code) return action;
    }
    return none;
  }

  /// 点击坐标 → 3×3 区域下标（0..8，行优先）；越界返回 -1。
  ///
  /// 参考 `ReaderTapActionGrid.actionAt`：x/y 各三等分；此处用全局屏幕
  /// 坐标与尺寸，避免依赖正文画布局部坐标。
  static int zoneIndexAt({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    if (width <= 0 ||
        height <= 0 ||
        x < 0 ||
        y < 0 ||
        x > width ||
        y > height) {
      return -1;
    }
    final column = x < width / 3
        ? 0
        : x < width * 2 / 3
        ? 1
        : 2;
    final row = y < height / 3
        ? 0
        : y < height * 2 / 3
        ? 1
        : 2;
    return row * 3 + column;
  }
}
