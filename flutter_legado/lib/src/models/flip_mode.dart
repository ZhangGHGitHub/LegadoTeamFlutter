/// 翻页模式枚举（高级配置面板使用）
///
/// 与 PageTurnMode 保持 5 种模式一致：
/// - PageTurnMode: scroll / slide / simulate / none / cover（阅读器渲染驱动）
/// - FlipMode: simulation / slide / cover / none / scroll（高级配置面板）
///
/// 映射关系：
/// FlipMode.simulation ↔ PageTurnMode.simulate
/// FlipMode.slide      ↔ PageTurnMode.slide
/// FlipMode.cover      ↔ PageTurnMode.cover
/// FlipMode.none       ↔ PageTurnMode.none
/// FlipMode.scroll     ↔ PageTurnMode.scroll
enum FlipMode {
  /// 仿真翻页（带缩放和阴影动画）
  simulation,
  
  /// 滑动翻页（平滑滑动动画）
  slide,
  
  /// 覆盖翻页（新页面覆盖旧页面）
  cover,
  
  /// 无动画（直接切换）
  none,

  /// 上下滚动（纵向滚动阅读）
  scroll;

  /// 获取显示名称
  String get displayName {
    switch (this) {
      case FlipMode.simulation:
        return '仿真';
      case FlipMode.slide:
        return '滑动';
      case FlipMode.cover:
        return '覆盖';
      case FlipMode.none:
        return '无动画';
      case FlipMode.scroll:
        return '滚动';
    }
  }

  /// 获取图标
  String get icon {
    switch (this) {
      case FlipMode.simulation:
        return '📖';
      case FlipMode.slide:
        return '👈';
      case FlipMode.cover:
        return '📄';
      case FlipMode.none:
        return '⚡';
      case FlipMode.scroll:
        return '📜';
    }
  }

  /// 从索引创建
  static FlipMode fromIndex(int index) {
    if (index < 0 || index >= FlipMode.values.length) {
      return FlipMode.slide; // 默认值
    }
    return FlipMode.values[index];
  }
}
