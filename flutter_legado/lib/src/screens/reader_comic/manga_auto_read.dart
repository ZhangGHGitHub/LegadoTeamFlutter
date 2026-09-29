import 'dart:math';

/// [P4-3 E3] 自动翻页 / 自动滚动（自动阅读）纯逻辑
///
/// 取证（参考版，legado-with-MD3）：
/// - ui/book/manga/MangaReaderContract.kt L44 `autoReadEnabled` 默认 false
///   （会话态，不持久化）；L136 `autoReadSpeed` 默认 3；
/// - ui/book/manga/MangaSettingsPanel.kt L755-767 AutoReadSettingsContent：
///   开关（ToggleAutoRead）+ 速度滑杆 1..15（AUTO_READ_SPEED）；
/// - ui/book/manga/MangaReaderScreen.kt L200-216 单页式自动翻页：
///   `delay(autoReadSpeed.coerceAtLeast(1) * 1_000L)` 后 `PageStep(1)`
///   （速度 N = N 秒一页，循环直到被依赖项变化取消）；
/// - L677-699 条漫自动滚动：每周期
///   `animateScrollBy(10_000px, tween(ceil(16f/speed*10_000f)ms, Linear))`，
///   实际消耗 < 1px（到章末）→ `NextChapter` + `delay(500L)` 后继续循环；
/// - LaunchedEffect 依赖 menuVisible/activeSheet/settingsCategory：
///   控制栏/面板打开期间循环不执行（对齐原版 ReadMangaActivity
///   L691-694 菜单显示暂停、隐藏恢复）。
///
/// 原版 ScrollTimer（recyclerview/ScrollTimer.kt）同语义：
/// paged 版 `delay(distance*1000L) → scrollPage`；条漫 `scrollBy`。
abstract final class MangaAutoRead {
  /// 默认速度档（Contract L136 autoReadSpeed = 3）
  static const int defaultValue = 3;

  /// 速度档下限（滑杆 1..15，MangaSettingsPanel L765-771）
  static const int minSpeed = 1;

  /// 速度档上限
  static const int maxSpeed = 15;

  /// 条漫单周期滚动像素（参考 L688 `value = 10_000f`）
  static const int webtoonScrollPx = 10000;

  /// 配置键原文 → 速度档（解析失败 → 默认；收敛到 [minSpeed, maxSpeed]）
  static int parse(String? raw) {
    final v = int.tryParse(raw ?? '');
    if (v == null) return defaultValue;
    return v.clamp(minSpeed, maxSpeed);
  }

  /// 单页式自动翻页间隔（参考 L215 `delay(速度×1000)`；速度 0 收敛到 1）
  static Duration pageStepDelay(int speed) {
    return Duration(milliseconds: speed.clamp(minSpeed, maxSpeed) * 1000);
  }

  /// 条漫单周期时长 = ceil(16/速度×10000)ms（参考 L686）
  ///
  /// 速度 N 时每 10000px 耗时 ceil(160000/N) ms：N=1 → 160s（慢速免手
  /// 阅读），N=15 → 10667ms（最快档）。
  static Duration webtoonCycle(int speed) {
    final ms =
        (max(16.0 / speed.clamp(minSpeed, maxSpeed), 0.0) * 10000.0).ceil();
    return Duration(milliseconds: ms);
  }
}
