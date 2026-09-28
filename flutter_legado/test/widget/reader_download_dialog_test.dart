// [P2-27 | 2026-09-28] 阅读器「离线缓存」范围对话框 UI 回归
//
// 针对缺陷 P2-27（用户裁决：原版语义为准）：阅读器顶栏下载入口必须
// 弹「离线缓存」章节范围对话框（对齐原版
// BaseReadBookActivity.showBookDownloadDialog / 参考版 DownloadSheet），
// 菜单面板顶栏的自创「直接缓存当前章」行为移除：
// ① 菜单面板顶栏点下载 → 弹「离线缓存」对话框（tooltip 对齐原版
//    menu_download 的 offline_cache 语义），点击时不发起任何缓存
//    （verifyNever）；确认后 cacheDownloadStart(start-1, end-1)
//    （0-based 含端点）+ 统一成功反馈
//    「已加入缓存队列：N 章（可在书籍菜单「缓存管理」查看进度）」。
// ② 共享对话框默认值对齐原版：起始 = 当前章（1-based =
//    currentChapterIndex + 1，对应原版 book.durChapterIndex + 1）、
//    结束 = 总章数。
// ③ 顶栏对话框标题「离线缓存」（原「缓存后续章节」）与默认起始
//    = 当前章（原自创 durChapterIndex + 2）——改造前必红。
// ④ 既有校验保留：空输入（起始→1 / 结束→总章数）、无效范围
//    （start < 1 || end > 总章数 || start > end →「章节范围无效」，
//    不发起下载）。
//
// 夹具同 reader_force_refresh_test（stubOpenBook / makeContainer /
// wrapMenuPanel / wrapTopBar）；本文件不引用新共享实现
// reader_download_dialog.dart 的符号，只经公共 UI（tooltip/对话框
// 文本/输入框默认值/mocktail 验证）断言——改造前可编译可运行，
// 红 = 断言失败（非编译错误）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar.dart';

import '../mocks/mocks.dart';

const _testBook = Book(
  bookUrl: 'https://book.com/1',
  name: '测试书籍',
  author: '作者',
  origin: 'https://source-a.com',
  originName: '源A',
  durChapterIndex: 1,
  durChapterPos: 3,
);

const _toc = [
  BookChapter(url: 'https://book.com/1/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/1/c2', title: '第二章', index: 1),
];

/// 打开书籍的最小 stub（对标 reader_notifier_test 的 stubOpenBook）
void stubOpenBook(MockRustApi api) {
  when(() => api.getChapters(any())).thenAnswer((_) async => _toc);
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((_) async => '正文');
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
}

ProviderContainer makeContainer(MockRustApi mockApi) {
  return ProviderContainer(
    overrides: [bookApiProvider.overrideWithValue(mockApi)],
  );
}

Widget wrapMenuPanel(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            ReaderMenuPanel(
              visible: true,
              onBack: () {},
              onAddBookmark: () {},
              onOpenCatalog: () {},
              onOpenSettings: () {},
              onOpenAdvancedConfig: () {},
              onOpenContentSearch: () {},
              onReadAloud: () {},
              onToggleAutoPage: () {},
              onOpenReplaceRules: () {},
            ),
          ],
        ),
      ),
    ),
  );
}

Widget wrapTopBar(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Stack(children: [ReaderTopBar(onAddBookmark: () {})]),
      ),
    ),
  );
}

/// 预置缓存批量任务 stub（返回任务数 0，不校验参数）
void stubCacheDownload(MockRustApi api) {
  when(
    () => api.cacheDownloadStart(any(), any(), any()),
  ).thenAnswer((_) async => 0);
}

/// 对话框内两个输入框的 controller 初始文本（[起始, 结束]）
List<String?> dialogFieldValues(WidgetTester tester) {
  final fields = tester.widgetList<TextField>(find.byType(TextField));
  return [fields.first.controller?.text, fields.last.controller?.text];
}

void main() {
  setUpAll(registerFallbacks);

  group('① 菜单面板顶栏下载钮 → 弹「离线缓存」对话框', () {
    testWidgets('点下载 → 弹对话框且点击时不发起缓存（verifyNever）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下载（离线缓存）'));
      await tester.pumpAndSettle();

      // 对话框弹出（标题 = 原版 offline_cache 文案）
      expect(find.text('离线缓存'), findsOneWidget);
      expect(find.text('开始缓存'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      // 自创「直接缓存当前章」行为已移除：点击时不发起任何下载
      verifyNever(() => mockApi.cacheDownloadStart(any(), any(), any()));
      expect(find.text('当前章已加入缓存队列'), findsNothing);

      // 取消关闭且不发起下载
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('离线缓存'), findsNothing);
      verifyNever(() => mockApi.cacheDownloadStart(any(), any(), any()));
    });

    testWidgets('默认值 = 当前章（1-based）/ 总章数', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);
      // 当前章 index = 1（第二章，来自 testBook.durChapterIndex）
      expect(container.read(readerNotifierProvider).currentChapterIndex, 1);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下载（离线缓存）'));
      await tester.pumpAndSettle();

      // 起始 = 当前章（1-based = 1 + 1 = 2），结束 = 总章数 = 2
      final values = dialogFieldValues(tester);
      expect(values.first, '2');
      expect(values.last, '2');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('确认默认范围 → (1, 1) 0-based + 统一成功反馈', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下载（离线缓存）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始缓存'));
      await tester.pumpAndSettle();

      // 默认 起始2/结束2 → 0-based (1, 1)
      verify(() => mockApi.cacheDownloadStart('https://book.com/1', 1, 1))
          .called(1);
      expect(
        find.text('已加入缓存队列：1 章（可在书籍菜单「缓存管理」查看进度）'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('自定义范围 1→2 → (0, 1) 0-based', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下载（离线缓存）'));
      await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      await tester.enterText(find.byWidget(fields.first), '1');
      await tester.enterText(find.byWidget(fields.last), '2');
      await tester.tap(find.text('开始缓存'));
      await tester.pumpAndSettle();

      verify(() => mockApi.cacheDownloadStart('https://book.com/1', 0, 1))
          .called(1);
      expect(
        find.text('已加入缓存队列：2 章（可在书籍菜单「缓存管理」查看进度）'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('无效范围（起始 > 结束）→「章节范围无效」且不发起下载', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下载（离线缓存）'));
      await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      await tester.enterText(find.byWidget(fields.first), '2');
      await tester.enterText(find.byWidget(fields.last), '1');
      await tester.tap(find.text('开始缓存'));
      await tester.pumpAndSettle();

      expect(find.text('章节范围无效'), findsOneWidget);
      verifyNever(() => mockApi.cacheDownloadStart(any(), any(), any()));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('空输入 → 起始=1/结束=总章数 → (0, 1) 0-based', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下载（离线缓存）'));
      await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      await tester.enterText(find.byWidget(fields.first), '');
      await tester.enterText(find.byWidget(fields.last), '');
      await tester.tap(find.text('开始缓存'));
      await tester.pumpAndSettle();

      // 空输入：起始 → 1、结束 → 总章数 2 → 0-based (0, 1)
      verify(() => mockApi.cacheDownloadStart('https://book.com/1', 0, 1))
          .called(1);
      expect(
        find.text('已加入缓存队列：2 章（可在书籍菜单「缓存管理」查看进度）'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('② 顶栏对话框：标题/默认值对齐原版', () {
    testWidgets('标题 = 「离线缓存」，默认起始 = 当前章（原 +2 自创偏差已删）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapTopBar(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('缓存（离线缓存）'));
      await tester.pumpAndSettle();

      // 标题对齐原版 offline_cache（改造前为「缓存后续章节」）
      expect(find.text('离线缓存'), findsOneWidget);
      // 默认起始 = 当前章（1-based = 2；改造前自创为 durChapterIndex + 2 = 3）
      final values = dialogFieldValues(tester);
      expect(values.first, '2');
      expect(values.last, '2');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('确认默认范围 → (1, 1) 0-based + 统一成功反馈', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      stubCacheDownload(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapTopBar(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('缓存（离线缓存）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始缓存'));
      await tester.pumpAndSettle();

      verify(() => mockApi.cacheDownloadStart('https://book.com/1', 1, 1))
          .called(1);
      expect(
        find.text('已加入缓存队列：1 章（可在书籍菜单「缓存管理」查看进度）'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
