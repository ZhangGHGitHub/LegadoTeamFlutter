// 书架布局配置 Sheet（设置批6a-1）
//
// 覆盖：五段结构、参考版默认值、横竖屏条件、网格/列表条件显隐、
// 更多信息/简介/标签子项、滑块范围、禁用项、文件夹 8 项隐藏、即时持久化。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/widgets/bookshelf/bookshelf_config_sheet.dart';
import 'package:flutter_legado/src/widgets/setting_slider_row.dart';

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    Size size = const Size(400, 6000),
    double? viewportWidth,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // 同一用例内多次 pumpSheet 时强制重建容器，避免沿用上一次的
        // 设置状态（ProviderScope 为 const 时会复用 Element/Container）。
        key: UniqueKey(),
        child: MaterialApp(
          home: Scaffold(
            body: BookshelfConfigSheet(viewportWidth: viewportWidth),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  SettingSliderRow slider(WidgetTester tester, String key) =>
      tester.widget<SettingSliderRow>(find.byKey(ValueKey(key)));

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    if (target.evaluate().isNotEmpty) return;
    await tester.scrollUntilVisible(
      target,
      300,
      scrollable: find.byType(Scrollable).last,
    );
  }

  testWidgets('五段结构与参考默认值（竖屏网格）', (tester) async {
    await pumpSheet(tester);

    for (final section in ['分组', '排序', '布局', '角标', '其他']) {
      expect(find.text(section), findsWidgets, reason: '缺少分段：$section');
    }
    expect(find.text('顶部标签'), findsOneWidget);
    expect(find.text('按阅读时间'), findsOneWidget);
    expect(find.text('降序'), findsOneWidget);
    expect(find.text('网格'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    // 竖屏默认 3 列
    expect(slider(tester, 'bookshelfGridColumnsSlider').value, 3);
    expect(slider(tester, 'bookshelfTitleMaxLinesSlider').value, 2);
    expect(slider(tester, 'bookshelfGridCoverWidthSlider').value, 120);
    expect(slider(tester, 'bookshelfRefreshLimitSlider').value, 0);
  });

  testWidgets('横屏使用独立布局配置（默认 7 列）', (tester) async {
    await pumpSheet(tester, size: const Size(3000, 2400));

    expect(find.text('横屏'), findsOneWidget);
    expect(slider(tester, 'bookshelfGridColumnsSlider').value, 7);
  });

  testWidgets('列表/网格布局条件显隐', (tester) async {
    await pumpSheet(
      tester,
      prefs: {BookshelfSettings.keyBookshelfLayoutModePortrait: 0},
    );
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('显示分隔线'), findsOneWidget);
    expect(find.text('日间卡片背景色'), findsOneWidget);
    expect(find.text('夜间卡片背景色'), findsOneWidget);
    expect(find.text('精简详情'), findsOneWidget);
    expect(find.text('网格样式'), findsNothing);
    expect(find.text('网格封面宽'), findsNothing);

    await pumpSheet(
      tester,
      prefs: {BookshelfSettings.keyBookshelfLayoutModePortrait: 1},
    );
    expect(find.text('网格样式'), findsOneWidget);
    expect(find.text('网格封面宽'), findsOneWidget);
    expect(find.text('显示分隔线'), findsNothing);
  });

  testWidgets('「更多信息」子项条件显隐（简介/位置/行数/标签）', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyShowBookIntro: false,
      },
    );
    expect(find.text('更多信息'), findsOneWidget);
    expect(find.text('显示简介'), findsNothing);
    expect(find.text('显示最新章节'), findsNothing);

    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyShowBookIntro: true,
        BookshelfSettings.keyBookshelfShowIntro: false,
        BookshelfSettings.keyBookshelfIntroMaxLines: 3,
      },
    );
    await scrollTo(tester, find.text('显示简介'));
    expect(find.text('显示简介'), findsOneWidget);
    // 简介关闭 → 位置/行数不显示
    expect(find.text('简介显示在内容下方'), findsNothing);
    expect(find.text('简介行数'), findsNothing);

    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyShowBookIntro: true,
        BookshelfSettings.keyBookshelfShowIntro: true,
        BookshelfSettings.keyBookshelfShowTag: false,
        BookshelfSettings.keyBookshelfIntroMaxLines: 3,
      },
    );
    expect(find.text('简介显示在内容下方'), findsOneWidget);
    expect(find.text('简介行数'), findsOneWidget);
    expect(
      tester
          .widget<SettingSliderRow>(
            find.byKey(const ValueKey('bookshelfIntroMaxLinesSlider')),
          )
          .value,
      3,
    );
    // 标签关闭 → 标签内容入口隐藏
    expect(find.text('显示标签'), findsOneWidget);
    expect(find.text('标签显示内容'), findsNothing);
  });

  testWidgets('网格模式不显示列表专属「更多信息」子项', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 1,
        BookshelfSettings.keyShowBookIntro: true,
        BookshelfSettings.keyBookshelfShowIntro: true,
      },
    );
    expect(find.text('更多信息'), findsNothing);
    expect(find.text('简介显示在内容下方'), findsNothing);
    expect(find.text('简介行数'), findsNothing);
  });

  testWidgets('滑块范围对齐参考（网格 1–15 / 列表 1–5 / 封面宽 40–150/120）', (tester) async {
    await pumpSheet(tester);
    final gridCols = slider(tester, 'bookshelfGridColumnsSlider');
    expect(gridCols.min, 1);
    expect(gridCols.max, 15);
    final gridCover = slider(tester, 'bookshelfGridCoverWidthSlider');
    expect(gridCover.min, 40);
    expect(gridCover.max, 150);
    final titleLines = slider(tester, 'bookshelfTitleMaxLinesSlider');
    expect(titleLines.min, 1);
    expect(titleLines.max, 5);
    final refresh = slider(tester, 'bookshelfRefreshLimitSlider');
    expect(refresh.min, 0);
    expect(refresh.max, 100);

    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyShowBookIntro: true,
        BookshelfSettings.keyBookshelfShowIntro: true,
      },
    );
    await scrollTo(
      tester,
      find.byKey(const ValueKey('bookshelfListColumnsSlider')),
    );
    final listCols = slider(tester, 'bookshelfListColumnsSlider');
    expect(listCols.min, 1);
    expect(listCols.max, 5);
    final listCover = slider(tester, 'bookshelfListCoverWidthSlider');
    expect(listCover.min, 40);
    expect(listCover.max, 120);
    await scrollTo(
      tester,
      find.byKey(const ValueKey('bookshelfIntroMaxLinesSlider')),
    );
    final introLines = slider(tester, 'bookshelfIntroMaxLinesSlider');
    expect(introLines.min, 0);
    expect(introLines.max, 10);
  });

  testWidgets('网格模式同样提供显示标签/标签内容开关（审查 P2）', (tester) async {
    await pumpSheet(
      tester,
      prefs: {BookshelfSettings.keyBookshelfLayoutModePortrait: 1},
    );
    expect(find.text('显示标签'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bookshelfShowTagSwitch')),
      findsOneWidget,
    );
    expect(find.text('标签显示内容'), findsOneWidget);
  });

  testWidgets('窄屏列表列数超出可读范围时给出收敛提示（审查 P1-1）', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfLayoutListPortrait: 5,
      },
    );
    expect(find.textContaining('最多 2 列'), findsOneWidget);
    expect(find.textContaining('超出将按 2 列显示'), findsOneWidget);
  });

  testWidgets('列表列数提示使用书架实际 pane 宽（审查 P2-2）', (tester) async {
    // 窗口 1000dp，但书架 pane 只有 600dp（多栏/窄 pane）：
    // 600dp 最多 3 列，不能按窗口宽提示 6 列。
    await pumpSheet(
      tester,
      size: const Size(1000, 6000),
      viewportWidth: 600,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfLayoutListPortrait: 5,
      },
    );
    expect(find.textContaining('当前书架宽度最多 3 列'), findsOneWidget);
    expect(find.textContaining('最多 6 列'), findsNothing);
  });

  testWidgets('文件夹 8 项仅分组样式=文件夹时显示（6a-2）', (tester) async {
    await pumpSheet(tester);
    // 默认（顶部标签）：文件夹配置与重置入口全部隐藏
    expect(BookshelfConfigSheet.folderPrefKeys, hasLength(8));
    expect(find.text('文件夹根目录'), findsNothing);
    expect(find.text('文件夹布局模式'), findsNothing);
    expect(find.text('文件夹列表样式'), findsNothing);
    expect(
      find.byKey(const ValueKey('bookshelfFolderResetButton')),
      findsNothing,
    );

    // 分组样式=文件夹 → 文件夹根目录段出现
    await pumpSheet(tester, prefs: {BookshelfSettings.keyBookGroupStyle: 2});
    expect(find.text('文件夹'), findsOneWidget); // 下拉当前值
    expect(find.text('文件夹根目录'), findsOneWidget);
    expect(find.text('文件夹布局模式'), findsOneWidget);
    // 默认竖屏文件夹网格 3 列（参考默认）
    expect(slider(tester, 'bookshelfFolderGridColumnsSlider').value, 3);
    expect(find.text('文件夹列表样式'), findsNothing, reason: '网格模式不显示列表样式');
    expect(
      find.byKey(const ValueKey('bookshelfFolderResetButton')),
      findsOneWidget,
    );
  });

  testWidgets('文件夹列表模式：列数/封面宽/列表样式/横排封面数量', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookGroupStyle: 2,
        BookshelfSettings.keyBookshelfFolderLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfGroupListStyle: 0,
      },
    );
    expect(find.text('文件夹列表样式'), findsOneWidget);
    final listColumns = slider(tester, 'bookshelfFolderListColumnsSlider');
    expect(listColumns.value, 1);
    expect(listColumns.min, 1);
    expect(listColumns.max, 5);
    final coverWidth = slider(tester, 'bookshelfFolderListCoverWidthSlider');
    expect(coverWidth.value, 84);
    expect(coverWidth.min, 40);
    expect(coverWidth.max, 120);
    // 列表样式 0 分组：横排封面数量隐藏
    expect(
      find.byKey(const ValueKey('bookshelfFolderCoverCountSlider')),
      findsNothing,
    );

    // 列表样式 2 横排封面 → 数量滑块 1–10
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookGroupStyle: 2,
        BookshelfSettings.keyBookshelfFolderLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfGroupListStyle: 2,
        BookshelfSettings.keyBookshelfGroupCoverCount: 6,
      },
    );
    final coverCount = slider(tester, 'bookshelfFolderCoverCountSlider');
    expect(coverCount.value, 6);
    expect(coverCount.min, 1);
    expect(coverCount.max, 10);
  });

  testWidgets('文件夹网格列数滑块 1–15（横竖屏独立）', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookGroupStyle: 2,
        BookshelfSettings.keyBookshelfFolderLayoutGridPortrait: 9,
      },
    );
    final portrait = slider(tester, 'bookshelfFolderGridColumnsSlider');
    expect(portrait.value, 9);
    expect(portrait.min, 1);
    expect(portrait.max, 15);

    await pumpSheet(
      tester,
      size: const Size(3000, 2400),
      prefs: {
        BookshelfSettings.keyBookGroupStyle: 2,
        BookshelfSettings.keyBookshelfFolderLayoutGridLandscape: 11,
      },
    );
    final landscape = slider(tester, 'bookshelfFolderGridColumnsSlider');
    expect(landscape.value, 11);
    expect(landscape.min, 1);
    expect(landscape.max, 15);
  });

  testWidgets('文件夹布局与重置：写盘并恢复 8 项默认', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        BookshelfSettings.keyBookGroupStyle: 2,
        BookshelfSettings.keyBookshelfFolderLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfFolderLayoutGridPortrait: 9,
        BookshelfSettings.keyBookshelfFolderLayoutModeLandscape: 0,
        BookshelfSettings.keyBookshelfFolderLayoutGridLandscape: 11,
        BookshelfSettings.keyBookshelfFolderLayoutListPortrait: 4,
        BookshelfSettings.keyBookshelfFolderLayoutListLandscape: 5,
        BookshelfSettings.keyBookshelfGroupListStyle: 2,
        BookshelfSettings.keyBookshelfGroupCoverCount: 8,
        // 共享键：重置文件夹布局不得修改
        BookshelfSettings.keyBookshelfListCoverWidth: 100,
        BookshelfSettings.keyShowBookCount: false,
      },
    );
    await tester.tap(find.byKey(const ValueKey('bookshelfFolderResetButton')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(BookshelfSettings.keyBookshelfFolderLayoutModePortrait),
      1,
    );
    expect(
      prefs.getInt(BookshelfSettings.keyBookshelfFolderLayoutGridPortrait),
      3,
    );
    expect(
      prefs.getInt(BookshelfSettings.keyBookshelfFolderLayoutModeLandscape),
      1,
    );
    expect(
      prefs.getInt(BookshelfSettings.keyBookshelfFolderLayoutGridLandscape),
      7,
    );
    expect(
      prefs.getInt(BookshelfSettings.keyBookshelfFolderLayoutListPortrait),
      1,
    );
    expect(
      prefs.getInt(BookshelfSettings.keyBookshelfFolderLayoutListLandscape),
      1,
    );
    expect(prefs.getInt(BookshelfSettings.keyBookshelfGroupListStyle), 0);
    expect(prefs.getInt(BookshelfSettings.keyBookshelfGroupCoverCount), 4);
    // 共享键保持不变
    expect(prefs.getInt(BookshelfSettings.keyBookshelfListCoverWidth), 100);
    expect(prefs.getBool(BookshelfSettings.keyShowBookCount), isFalse);
    // 重置后竖屏默认网格 3 列
    expect(slider(tester, 'bookshelfFolderGridColumnsSlider').value, 3);
  });

  testWidgets('分组样式选择文件夹并持久化（即时写盘）', (tester) async {
    await pumpSheet(tester);
    // 点击下拉当前值（ListTile 本体不触发 DropdownButton）
    await tester.tap(find.text('顶部标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件夹').last);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(BookshelfSettings.keyBookGroupStyle), 2);
    expect(find.text('文件夹根目录'), findsOneWidget);
  });

  testWidgets('搜索直达（书架内搜索过滤延期）保持默认且禁用', (tester) async {
    await pumpSheet(tester);
    final row = find.byKey(const ValueKey('bookshelfSearchDirectSwitch'));
    expect(row, findsOneWidget);
    final sw = tester.widget<Switch>(
      find.descendant(of: row, matching: find.byType(Switch)),
    );
    expect(sw.value, isTrue);
    expect(sw.onChanged, isNull);
  });

  testWidgets('开关即时持久化（隐藏空分组 / 快速滚动条）', (tester) async {
    await pumpSheet(tester);

    await tester.tap(
      find.byKey(const ValueKey('bookshelfHideEmptyGroupsSwitch')),
    );
    await tester.pumpAndSettle();
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(BookshelfSettings.keyHideEmptyGroups), isFalse);

    await tester.tap(find.byKey(const ValueKey('bookshelfFastScrollerSwitch')));
    await tester.pumpAndSettle();
    prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(BookshelfSettings.keyShowBookshelfFastScroller),
      isTrue,
    );
  });

  testWidgets('取色器复用 ContainerColorDialog', (tester) async {
    await pumpSheet(
      tester,
      prefs: {BookshelfSettings.keyBookshelfLayoutModePortrait: 0},
    );

    await tester.tap(find.byKey(const ValueKey('bookshelfDayCardColorRow')));
    await tester.pumpAndSettle();

    expect(find.text('HEX'), findsOneWidget);
    expect(find.text('恢复默认（跟随主题）'), findsOneWidget);
  });
}
