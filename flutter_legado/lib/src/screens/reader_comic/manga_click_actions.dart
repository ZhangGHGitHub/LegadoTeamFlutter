/// [P4-3 E5] 漫画屏九区（3x3）点击动作配置
///
/// 取证（参考版，legado-with-MD3）：
/// - ui/book/manga/MangaReaderInteraction.kt L15-24 mangaClickRegionIndex：
///   column = (x / (width.coerceAtLeast(1) / 3)).toInt().coerceIn(0, 2)，
///   row = (y / (height.coerceAtLeast(1) / 3)).toInt().coerceIn(0, 2)，
///   区域 = row * 3 + column（行优先，左上角为 0）；
/// - L26-32 mangaClickActionAt：clickActions.getOrNull(region) ?: 0；
/// - L34-41 nextMangaClickAction：-1→0→1→2→3→4→-1 循环；
/// - ui/book/manga/MangaReaderContract.kt L167 默认配置
///   [-1, -1, 1, 2, 0, 1, 2, 1, 1]
///   （顶行 无/无/下一页；中行 上一页/菜单/下一页；底行 上一页/下一页/下一页）；
/// - ui/book/manga/MangaReaderScreen.kt L1945-1969 动作语义：
///   -1 无动作 / 0 菜单 / 1 下一页 / 2 上一页 / 3 下一章 / 4 上一章。
///
/// 本类为纯函数（无 UI 依赖），供阅读屏九区点击分发与单元测试直接使用。
/// 九宫格编辑器（参考版 MangaSettingsPanel L774-804）与「长按存图」开关
/// （L528-534）不在本波范围，默认配置固定为 [defaultActions]。
abstract final class MangaClickActions {
  /// 无动作
  static const int none = -1;

  /// 切换菜单（控制栏显隐）
  static const int menu = 0;

  /// 下一页（条漫 = 下滚一屏）
  static const int next = 1;

  /// 上一页（条漫 = 上滚一屏）
  static const int prev = 2;

  /// 下一章
  static const int nextChapter = 3;

  /// 上一章
  static const int prevChapter = 4;

  /// 默认九区配置（对齐参考版 Contract L167）
  static const List<int> defaultActions = [-1, -1, 1, 2, 0, 1, 2, 1, 1];

  /// 点 (x,y) 在 [width]x[height] 视口中的九区索引（行优先 row*3+column）。
  ///
  /// 越界坐标收敛到边缘区域（对齐参考版 coerceIn(0, 2)）；
  /// 零尺寸视口按 1 兜底（对齐 coerceAtLeast(1) 防零除）。
  static int regionIndex(double x, double y, double width, double height) {
    final w = width > 0 ? width : 1;
    final h = height > 0 ? height : 1;
    final column = (x / (w / 3)).toInt().clamp(0, 2);
    final row = (y / (h / 3)).toInt().clamp(0, 2);
    return row * 3 + column;
  }

  /// 点 (x,y) 所在区域对应的点击动作；列表不足 9 项时回退 0（菜单），
  /// 对齐参考版 `clickActions.getOrNull(region) ?: 0`。
  static int actionAt(
    List<int> actions,
    double x,
    double y,
    double width,
    double height,
  ) {
    final index = regionIndex(x, y, width, height);
    return index < actions.length ? actions[index] : menu;
  }

  /// 配置循环的下一个动作（对齐参考版 nextMangaClickAction：
  /// -1→0→1→2→3→4→-1）。预留给后续九宫格编辑器使用。
  static int cycleNext(int action) => action == prevChapter ? none : action + 1;
}
