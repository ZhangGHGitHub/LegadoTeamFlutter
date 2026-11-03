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
}
