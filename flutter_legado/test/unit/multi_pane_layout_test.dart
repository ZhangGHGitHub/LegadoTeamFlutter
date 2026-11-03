// [设置批2b-2b] 多栏布局判定纯函数测试
//
// 阈值/最小窗格尺寸语义对齐参考版：
// - `ui/widget/components/navigation/AppAdaptiveNavigation.kt:56-85`
//   （auto/landscape ≥840，always ≥744，off 关闭）；
// - `ui/main/MainAdaptiveLayout.kt:26-29,150-181`
//   （左 360、右 360、间距 24、高 ≥320）。
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/multi_pane_layout.dart';

void main() {
  group('MultiPaneMode 解析', () {
    test('合法值直取，未知/空值回退 auto', () {
      expect(MultiPaneMode.fromName('auto'), MultiPaneMode.auto);
      expect(MultiPaneMode.fromName('landscape'), MultiPaneMode.landscape);
      expect(MultiPaneMode.fromName('always'), MultiPaneMode.always);
      expect(MultiPaneMode.fromName('off'), MultiPaneMode.off);
      expect(MultiPaneMode.fromName(null), MultiPaneMode.auto);
      expect(MultiPaneMode.fromName(''), MultiPaneMode.auto);
      expect(MultiPaneMode.fromName('__bad__'), MultiPaneMode.auto);
    });

    test('枚举名与参考版持久化取值一致', () {
      expect(MultiPaneMode.values.map((m) => m.name).toList(), [
        'auto',
        'landscape',
        'always',
        'off',
      ]);
    });
  });

  group('auto：宽 ≥840dp（横竖不限）', () {
    test('839 不启用、840 启用', () {
      expect(
        resolveMultiPane(MultiPaneMode.auto, const Size(839, 700)),
        isFalse,
      );
      expect(
        resolveMultiPane(MultiPaneMode.auto, const Size(840, 700)),
        isTrue,
      );
    });

    test('竖屏 840x1200 也启用（auto 不看方向）', () {
      expect(
        resolveMultiPane(MultiPaneMode.auto, const Size(840, 1200)),
        isTrue,
      );
    });

    test('宽 1200 但高度 319 不启用（最小高度 320）', () {
      expect(
        resolveMultiPane(MultiPaneMode.auto, const Size(1200, 319)),
        isFalse,
      );
      expect(
        resolveMultiPane(MultiPaneMode.auto, const Size(1200, 320)),
        isTrue,
      );
    });
  });

  group('landscape：宽 > 高且宽 ≥840dp', () {
    test('839x700 不启用；840x700 启用', () {
      expect(
        resolveMultiPane(MultiPaneMode.landscape, const Size(839, 700)),
        isFalse,
      );
      expect(
        resolveMultiPane(MultiPaneMode.landscape, const Size(840, 700)),
        isTrue,
      );
    });

    test('竖屏或正方形不启用', () {
      expect(
        resolveMultiPane(MultiPaneMode.landscape, const Size(900, 1200)),
        isFalse,
      );
      expect(
        resolveMultiPane(MultiPaneMode.landscape, const Size(900, 900)),
        isFalse,
      );
    });
  });

  group('always：宽 ≥744dp', () {
    test('743 不启用、744 启用（360+24+360）', () {
      expect(
        resolveMultiPane(MultiPaneMode.always, const Size(743, 600)),
        isFalse,
      );
      expect(
        resolveMultiPane(MultiPaneMode.always, const Size(744, 600)),
        isTrue,
      );
    });

    test('always 不受横竖方向限制（744x1200 启用）', () {
      expect(
        resolveMultiPane(MultiPaneMode.always, const Size(744, 1200)),
        isTrue,
      );
    });

    test('744 但高度 319 不启用', () {
      expect(
        resolveMultiPane(MultiPaneMode.always, const Size(744, 319)),
        isFalse,
      );
    });
  });

  group('窗口尺寸 vs 窗格尺寸（含 Rail 场景）', () {
    test('auto 阈值按窗口宽：窗格 760 + 窗口 840 启用，窗口 839 不启用', () {
      // 默认 auto 下 840dp 窗口扣 Rail（约 80dp）后窗格仅 760dp；
      // 若拿窗格宽比 840 会永远不分栏，故阈值必须用窗口宽。
      expect(
        resolveMultiPane(
          MultiPaneMode.auto,
          const Size(760, 620),
          windowSize: const Size(840, 700),
        ),
        isTrue,
      );
      expect(
        resolveMultiPane(
          MultiPaneMode.auto,
          const Size(759, 620),
          windowSize: const Size(839, 700),
        ),
        isFalse,
      );
    });

    test('always 阈值用窗口宽，最小窗格仍按扣 Rail 后宽度', () {
      // 窗口 839 ≥744 且窗格 759 ≥744 → 启用
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(759, 620),
          windowSize: const Size(839, 700),
        ),
        isTrue,
      );
      // 窗口 900 很宽，但窗格 700 放不下左 360 + 间距 24 + 右 360 → 不启用
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(700, 620),
          windowSize: const Size(900, 700),
        ),
        isFalse,
      );
    });

    test('landscape 方向按窗口宽高，不看扣 Rail 后的窗格', () {
      // 窗格近似正方形，但完整窗口是横屏 → 启用
      expect(
        resolveMultiPane(
          MultiPaneMode.landscape,
          const Size(760, 760),
          windowSize: const Size(900, 600),
        ),
        isTrue,
      );
      // 完整窗口是竖屏 → 不启用
      expect(
        resolveMultiPane(
          MultiPaneMode.landscape,
          const Size(760, 760),
          windowSize: const Size(900, 1000),
        ),
        isFalse,
      );
    });

    test('窗口尺寸无限时安全返回 false', () {
      expect(
        resolveMultiPane(
          MultiPaneMode.auto,
          const Size(760, 620),
          windowSize: const Size(double.infinity, 700),
        ),
        isFalse,
      );
    });
  });

  group('off 与最小窗格约束', () {
    test('off 任意宽高均不启用', () {
      expect(
        resolveMultiPane(MultiPaneMode.off, const Size(2000, 1200)),
        isFalse,
      );
    });

    test('容器左栏 420dp：always 需 420+24+360=804dp', () {
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(803, 600),
          leftWidth: 420,
        ),
        isFalse,
      );
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(804, 600),
          leftWidth: 420,
        ),
        isTrue,
      );
    });

    test('自定义右栏/间距参与最小宽度判定', () {
      // 360 + 16 + 400 = 776；770 宽虽已过 always 的 744 断点，但两栏
      // 放不下 → 不启用；776 恰好放下。
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(770, 600),
          leftWidth: 360,
          rightWidth: 400,
          gap: 16,
        ),
        isFalse,
      );
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(776, 600),
          leftWidth: 360,
          rightWidth: 400,
          gap: 16,
        ),
        isTrue,
      );
    });

    test('无限尺寸（未约束布局）不启用', () {
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(double.infinity, 600),
        ),
        isFalse,
      );
      expect(
        resolveMultiPane(
          MultiPaneMode.always,
          const Size(900, double.infinity),
        ),
        isFalse,
      );
    });
  });

  group('列表-详情右栏宽度（书架/发现/RSS 2b-2c）', () {
    test('可用宽 < 744 返回 0（不占位）', () {
      expect(resolveListDetailRightWidth(600), 0);
      expect(resolveListDetailRightWidth(743.9), 0);
    });

    test('744 起左 360 + 间距 24 + 右 360', () {
      expect(resolveListDetailRightWidth(744), 360);
    });

    test('左栏按可用宽 40% 增长，右栏占剩余且 ≥360', () {
      // 840：左 360（40% 不足最小宽，取 360），右 456
      expect(resolveListDetailRightWidth(840), 456);
      // 1000：左 400，右 576
      expect(resolveListDetailRightWidth(1000), 576);
      // 1280：左 512，右 744
      expect(resolveListDetailRightWidth(1280), 744);
      for (final width in [744.0, 800.0, 900.0, 1280.0, 1600.0]) {
        final right = resolveListDetailRightWidth(width);
        expect(right, greaterThanOrEqualTo(kMultiPaneRightWidth));
      }
    });

    test('无限/非有限宽度返回 0', () {
      expect(resolveListDetailRightWidth(double.infinity), 0);
      expect(resolveListDetailRightWidth(double.nan), 0);
    });

    test('自定义间距/最小宽度按同一口径计算', () {
      // 360+16+300=676 下限；700 时左 360，右 324
      expect(
        resolveListDetailRightWidth(
          700,
          leftWidth: 360,
          rightWidth: 300,
          gap: 16,
        ),
        324,
      );
    });
  });
}
