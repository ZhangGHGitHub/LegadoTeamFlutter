// [设置批2b-2a | 2026-11-02] 首页主导航顺序/显隐纯函数测试
//
// 语义基准（参考版）：
// - MainDestination.ordered（`ui/main/MainDestination.kt:39-47`）去重 +
//   补齐缺失项；
// - MainNavigationSettingsSheet.isRouteVisible（63-68）仅首页/发现/订阅可
//   显隐，书架/我的恒显示；
// - AppShellSettings（7-9,20-21）默认值。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/main_tab.dart';

void main() {
  group('orderedMainTabs 顺序解析', () {
    test('默认顺序：五页签完整', () {
      expect(
        orderedMainTabs(kDefaultMainNavigationOrder),
        kDefaultMainTabOrder,
      );
    });

    test('去重/去空白/忽略未知 route，并补齐缺失项', () {
      expect(orderedMainTabs(' rss, rss ,bogus, explore '), [
        MainTab.rss,
        MainTab.explore,
        MainTab.home,
        MainTab.bookshelf,
        MainTab.my,
      ]);
    });

    test('空串回退完整默认顺序', () {
      expect(orderedMainTabs(''), kDefaultMainTabOrder);
    });
  });

  group('visibleMainTabs 显隐', () {
    test('默认全部可见且保持顺序', () {
      expect(
        visibleMainTabs(
          order: kDefaultMainNavigationOrder,
          showHome: true,
          showDiscovery: true,
          showRss: true,
        ),
        kDefaultMainTabOrder,
      );
    });

    test('仅首页/发现/订阅可隐藏，书架/我的恒显示', () {
      expect(
        visibleMainTabs(
          order: kDefaultMainNavigationOrder,
          showHome: false,
          showDiscovery: false,
          showRss: false,
        ),
        [MainTab.bookshelf, MainTab.my],
      );
    });

    test('顺序变化后可见列表跟随顺序', () {
      expect(
        visibleMainTabs(
          order: 'my,bookshelf,home,explore,rss',
          showHome: true,
          showDiscovery: false,
          showRss: false,
        ),
        [MainTab.my, MainTab.bookshelf, MainTab.home],
      );
    });

    test('至少保留一项：异常空配置回退书架', () {
      expect(
        visibleMainTabs(
          order: 'home,explore,rss',
          showHome: false,
          showDiscovery: false,
          showRss: false,
        ),
        isNotEmpty,
      );
    });
  });

  group('reorderVisibleTabs 拖拽排序', () {
    const all = kDefaultMainTabOrder;
    const visible = [MainTab.home, MainTab.bookshelf, MainTab.explore];

    test('旧 onReorder 语义：向下拖动目标索引减一', () {
      expect(
        reorderVisibleTabs(
          visible: visible,
          all: all,
          oldIndex: 0,
          newIndex: 2,
        ),
        [
          MainTab.bookshelf,
          MainTab.home,
          MainTab.explore,
          MainTab.rss,
          MainTab.my,
        ],
      );
    });

    test('onReorderItem 语义：newIndex 已调整，直接插入', () {
      expect(
        reorderVisibleTabs(
          visible: visible,
          all: all,
          oldIndex: 0,
          newIndex: 1,
          newIndexAdjusted: true,
        ),
        [
          MainTab.bookshelf,
          MainTab.home,
          MainTab.explore,
          MainTab.rss,
          MainTab.my,
        ],
      );
    });

    test('落点越过隐藏项时夹到可见区末尾，隐藏项保持顺序', () {
      expect(
        reorderVisibleTabs(
          visible: visible,
          all: all,
          oldIndex: 0,
          newIndex: 4,
          newIndexAdjusted: true,
        ),
        [
          MainTab.bookshelf,
          MainTab.explore,
          MainTab.home,
          MainTab.rss,
          MainTab.my,
        ],
      );
    });

    test('越界 oldIndex 保持原顺序', () {
      expect(
        reorderVisibleTabs(
          visible: visible,
          all: all,
          oldIndex: 9,
          newIndex: 0,
          newIndexAdjusted: true,
        ),
        all,
      );
    });
  });

  test('serializeMainTabs 去重并补齐缺失项', () {
    expect(
      serializeMainTabs([MainTab.rss, MainTab.home, MainTab.rss]),
      'rss,home,bookshelf,explore,my',
    );
  });
}
