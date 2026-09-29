// [E10 暗色硬编码核实] 视频对话框暗色守护测试
//
// 核实结论（详见汇报）：
// 1. 暗色账本 A1「漫画设置弹层硬编码浅色」已于 commit c1616a1 修复
//    （MangaConfigSheet 全量 scheme 化 + manga_config_sheet_test 守护）；
// 2. 视频屏/漫画屏的黑底（Colors.black 画面底、白色控制文字）为
//    账本 §三.D 登记的「自成黑底体系」（对齐原版 book_ant_10 #141414 /
//    视频黑底），属有意设计，不改；
// 3. 本守护测试锚定两类表面：
//    - 视频设置 Dialog：背景/文字走主题 scheme（dialogTheme.backgroundColor
//      = colorScheme.surfaceContainer，副标题 = onSurfaceVariant），
//      暗色主题下取自 dark scheme、亮色不回归；
//    - V3 选集/倍速浮层：属视频播放器黑底体系，面板底色为固定的
//      #80121212 半透明深色（kVideoDialogPanelColor），亮/暗主题下
//      均保持（视频画面永远黑底，主题化反而会破坏语义）；
//      守护亮色主题下面板不退化为浅色（防误修）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/widgets/video_settings_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<VideoEpisodeItem> episodes() => const [
        VideoEpisodeItem(title: '第1集', chapterIndex: 0),
        VideoEpisodeItem(title: '第2集', chapterIndex: 1),
      ];

  /// 视频设置 Dialog 宿主（按 [mode] 注入 dark/light 主题）
  Future<void> pumpSettingsHost(
    WidgetTester tester,
    ThemeMode mode,
    ThemeData theme,
    ThemeData darkTheme,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        darkTheme: darkTheme,
        themeMode: mode,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showVideoSettingsDialog(context),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
  }

  /// 选集/倍速浮层宿主（按 [mode] 注入 dark/light 主题）
  Future<void> pumpEpisodePanel(
    WidgetTester tester,
    ThemeMode mode,
    ThemeData theme,
    ThemeData darkTheme,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        darkTheme: darkTheme,
        themeMode: mode,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showVideoEpisodeDialog(
                  context,
                  episodes: episodes(),
                  currentChapterIndex: 0,
                ),
                child: const Text('打开选集'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选集'));
    await tester.pumpAndSettle();
  }

  /// 取设置 Dialog 的底板 Material（Dialog 首个后代 Material，
  /// color 来自 dialogTheme.backgroundColor = colorScheme.surfaceContainer；
  /// 不用 ancestor.last——祖先遍历顺序不稳定）
  Material dialogMaterialOf(WidgetTester tester) {
    final dialog = find.byType(Dialog);
    expect(dialog, findsOneWidget, reason: '应只有一个打开的 Dialog');
    return tester.widget<Material>(
      find.descendant(of: dialog, matching: find.byType(Material)).first,
    );
  }

  group('E10 视频设置 Dialog 暗色守护（scheme 化，无硬编码浅色）', () {
    testWidgets('暗色主题：背景/副标题取自 dark scheme', (tester) async {
      await pumpSettingsHost(
        tester,
        ThemeMode.dark,
        AppTheme.light,
        AppTheme.dark,
      );
      expect(tester.takeException(), isNull);

      final dark = AppTheme.dark.colorScheme;

      // Dialog 底板背景 = dialogTheme.backgroundColor =
      // colorScheme.surfaceContainer（app_theme.dart:392-393）
      final dialogMaterial = dialogMaterialOf(tester);
      expect(dialogMaterial.color, dark.surfaceContainer,
          reason: 'Dialog 底板应取自暗色 surfaceContainer（非硬编码浅色）');

      // 长按倍速副标题「3.0x」→ onSurfaceVariant
      expect(
        tester.widget<Text>(find.text('3.0x')).style!.color,
        dark.onSurfaceVariant,
      );

      // 旧硬编码浅色残留检查：Dialog 底板不得为白
      expect(dialogMaterial.color, isNot(Colors.white));
    });

    testWidgets('亮色主题：背景/副标题取自 light scheme（亮色不回归）',
        (tester) async {
      await pumpSettingsHost(
        tester,
        ThemeMode.light,
        AppTheme.light,
        AppTheme.dark,
      );
      expect(tester.takeException(), isNull);

      final light = AppTheme.light.colorScheme;
      final dialogMaterial = dialogMaterialOf(tester);
      expect(dialogMaterial.color, light.surfaceContainer,
          reason: '亮色 Dialog 底板应取自亮色 surfaceContainer');
      expect(
        tester.widget<Text>(find.text('3.0x')).style!.color,
        light.onSurfaceVariant,
      );
    });
  });

  group('E10 V3 选集/倍速浮层守护（视频黑底体系，主题无关为有意设计）',
      () {
    void assertPanelThemeIndependent(WidgetTester tester) {
      // 面板底色 = 固定 #80121212 半透明深色（kVideoDialogPanelColor），
      // 两主题一致——视频画面永远黑底，面板跟随主题化反而是缺陷
      final panels = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.color ==
                  kVideoDialogPanelColor,
        ),
      );
      expect(panels, isNotEmpty, reason: '选集浮层面板应渲染');
      // 项文字固定白色（原版 switch_video_dialog_item #FFFFFF 15sp）
      for (final t in [find.text('第1集'), find.text('第2集')]) {
        expect(tester.widget<Text>(t).style!.color, kVideoDialogTextColor);
      }
    }

    testWidgets('暗色主题：浮层面板保持 #80121212（无异常渲染）',
        (tester) async {
      await pumpEpisodePanel(
        tester,
        ThemeMode.dark,
        AppTheme.light,
        AppTheme.dark,
      );
      expect(tester.takeException(), isNull);
      assertPanelThemeIndependent(tester);
    });

    testWidgets('亮色主题：浮层面板仍为 #80121212（防误修回归）',
        (tester) async {
      await pumpEpisodePanel(
        tester,
        ThemeMode.light,
        AppTheme.light,
        AppTheme.dark,
      );
      expect(tester.takeException(), isNull);
      assertPanelThemeIndependent(tester);
    });
  });
}
