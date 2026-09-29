// [P4-3 波次1b V3] 视频选集/倍速对话框测试（对齐原版 gsyVideo 对话框）
//
// 原版依据：
// - ChoiceEpisodeDialog.kt：靠右浮层（宽度 40%、全高、背景 #80121212），
//   标题「选集（N）」，列表项=章节标题，点击 dismiss 后回调 position，
//   打开时滚动到当前集（setSelectionFromTop）。
// - ChoiceSpeedDialog.kt / VideoPlayer.kt:403：倍速档位
//   [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0].reversed()（降序），
//   项文案 `value + "X"`，点击回调值；入口文案 1.0 时「倍速」、否则「X.XX X」。
//
// 测试形态说明：showDialog 的 Future 仅在对话框 pop 时完成。若把该
// Future 经由 async 助手函数「返回」（return pendingFuture），调用方的
// await 会链式等待对话框关闭，导致不关闭对话框的断言用例永久挂起。
// 因此各用例在本地捕获对话框 Future（late 变量 + 回调注入），助手只
// 负责构建与打开，不做结果链式传递。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/video_settings_dialog.dart';

List<VideoEpisodeItem> _defaultEpisodes() =>
    List.generate(5, (i) => VideoEpisodeItem(title: '第${i + 1}集', chapterIndex: i));

/// 选集入口宿主：点击「打开选集」打开对话框；[onDialogFuture] 在
/// 对话框打开时回传其结果 Future（由用例自行 await，助手不链式返回）。
Widget buildEpisodeHost({
  List<VideoEpisodeItem> episodes = const [],
  int? currentChapterIndex,
  void Function(Future<int?>)? onDialogFuture,
}) {
  final items = episodes.isEmpty ? _defaultEpisodes() : episodes;
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              final result = showVideoEpisodeDialog(
                context,
                episodes: items,
                currentChapterIndex: currentChapterIndex,
              );
              onDialogFuture?.call(result);
            },
            child: const Text('打开选集'),
          ),
        ),
      ),
    ),
  );
}

/// 倍速入口宿主（同 [buildEpisodeHost]）
Widget buildSpeedHost({
  double currentSpeed = 1.0,
  void Function(Future<double?>)? onDialogFuture,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              final result = showVideoSpeedDialog(
                context,
                currentSpeed: currentSpeed,
              );
              onDialogFuture?.call(result);
            },
            child: const Text('打开倍速'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('V3 选集对话框（对齐原版 ChoiceEpisodeDialog）', () {
    testWidgets('渲染标题「选集（N）」与全部集名', (tester) async {
      await tester.pumpWidget(buildEpisodeHost());
      await tester.tap(find.text('打开选集'));
      await tester.pumpAndSettle();
      expect(find.text('选集（5）'), findsOneWidget);
      for (var i = 1; i <= 5; i++) {
        expect(find.text('第$i集'), findsOneWidget);
      }
    });

    testWidgets('点击某集 → 对话框关闭并返回该集绝对章节索引',
        (tester) async {
      late Future<int?> result;
      await tester.pumpWidget(
        buildEpisodeHost(onDialogFuture: (f) => result = f),
      );
      await tester.tap(find.text('打开选集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第3集'));
      await tester.pumpAndSettle();
      expect(await result, 2);
      expect(find.text('选集（5）'), findsNothing);
    });

    testWidgets('点击屏障（面板外）关闭且返回 null', (tester) async {
      late Future<int?> result;
      await tester.pumpWidget(
        buildEpisodeHost(onDialogFuture: (f) => result = f),
      );
      await tester.tap(find.text('打开选集'));
      await tester.pumpAndSettle();
      // 面板靠右（宽 40%），左侧 60% 是透明屏障：点最左侧关闭
      await tester.tapAt(const Offset(10, 400));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('当前集高亮（唯一高亮项 = 当前集）', (tester) async {
      await tester.pumpWidget(
        buildEpisodeHost(currentChapterIndex: 2),
      );
      await tester.tap(find.text('打开选集'));
      await tester.pumpAndSettle();
      final highlighted = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.color ==
                kVideoDialogHighlightColor,
      );
      expect(highlighted, findsOneWidget);
      final item = tester.widget<Container>(highlighted);
      expect(
        find.descendant(of: find.byWidget(item), matching: find.text('第3集')),
        findsOneWidget,
      );
    });

    testWidgets('无当前集时不高亮', (tester) async {
      await tester.pumpWidget(buildEpisodeHost());
      await tester.tap(find.text('打开选集'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.color ==
                  kVideoDialogHighlightColor,
        ),
        findsNothing,
      );
    });
  });

  group('V3 倍速对话框（对齐原版 ChoiceSpeedDialog）', () {
    testWidgets('渲染 8 档且降序排列（3.0 → 0.5）', (tester) async {
      await tester.pumpWidget(buildSpeedHost());
      await tester.tap(find.text('打开倍速'));
      await tester.pumpAndSettle();
      const labels = [
        '3.0X',
        '2.5X',
        '2.0X',
        '1.5X',
        '1.25X',
        '1.0X',
        '0.75X',
        '0.5X',
      ];
      for (final label in labels) {
        expect(find.text(label), findsOneWidget);
      }
      // 垂直顺序：自上而下 3.0 → 0.5
      for (var i = 0; i < labels.length - 1; i++) {
        expect(
          tester.getTopLeft(find.text(labels[i])).dy,
          lessThan(tester.getTopLeft(find.text(labels[i + 1])).dy),
          reason: '$labels[i] 应在 ${labels[i + 1]} 上方',
        );
      }
    });

    testWidgets('点击某档 → 对话框关闭并返回该倍速值', (tester) async {
      late Future<double?> result;
      await tester.pumpWidget(
        buildSpeedHost(onDialogFuture: (f) => result = f),
      );
      await tester.tap(find.text('打开倍速'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5X'));
      await tester.pumpAndSettle();
      expect(await result, 1.5);
    });

    testWidgets('当前倍速档位高亮', (tester) async {
      await tester.pumpWidget(buildSpeedHost(currentSpeed: 1.5));
      await tester.tap(find.text('打开倍速'));
      await tester.pumpAndSettle();
      final highlighted = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.color ==
                kVideoDialogHighlightColor,
      );
      expect(highlighted, findsOneWidget);
      final item = tester.widget<Container>(highlighted);
      expect(
        find.descendant(of: find.byWidget(item), matching: find.text('1.5X')),
        findsOneWidget,
      );
    });

    testWidgets('当前倍速不在档位内（如长按倍速 2.2）不高亮', (tester) async {
      await tester.pumpWidget(buildSpeedHost(currentSpeed: 2.2));
      await tester.tap(find.text('打开倍速'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.color ==
                  kVideoDialogHighlightColor,
        ),
        findsNothing,
      );
    });
  });

  group('入口文案与档位常量（对齐原版 VideoPlayer）', () {
    test('speedEntryLabel：1.0 → 倍速，其余 → X.XX X', () {
      expect(speedEntryLabel(1.0), '倍速');
      expect(speedEntryLabel(1.5), '1.5X');
      expect(speedEntryLabel(0.75), '0.75X');
      expect(speedEntryLabel(3.0), '3.0X');
    });

    test('speedTipLabel：对齐原版 VideoPlayer.kt:411「X倍播放中」（2 秒）',
        () {
      // 注意：倍速对话框 tip 为「X倍播放中」；长按倍速 tip 才是
      // 「X倍速播放中」（VideoPlayer.kt:112），两者文案不同，勿混
      expect(speedTipLabel(1.5), '1.5倍播放中');
      expect(speedTipLabel(0.75), '0.75倍播放中');
    });

    test('kVideoSpeedChoices：对齐原版 [0.5..3.0].reversed()', () {
      expect(
        kVideoSpeedChoices,
        const [3.0, 2.5, 2.0, 1.5, 1.25, 1.0, 0.75, 0.5],
      );
    });
  });
}
