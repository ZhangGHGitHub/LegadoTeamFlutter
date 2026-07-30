/// 翻页模式枚举
enum FlipMode {
  /// 仿真翻页（带缩放和阴影动画）
  simulation,
  
  /// 滑动翻页（平滑滑动动画）
  slide,
  
  /// 覆盖翻页（新页面覆盖旧页面）
  cover,
  
  /// 无动画（直接切换）
  none;

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
