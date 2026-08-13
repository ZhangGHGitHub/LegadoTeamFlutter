import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/offline_cache_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

/// 离线缓存页测试（[UI-fix v2.0.17 | 2026-08-11] 新增页，对齐原版
/// CacheActivity：书籍列表/缓存进度/下载控制/单本导出 — Reasonix）
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
      ],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  Book makeBook(String url, String name,
          {int total = 10, int bookType = 0, String author = '作者A'}) =>
      Book(
        bookUrl: url,
        name: name,
        author: author,
        totalChapterNum: total,
        bookType: bookType,
      );

  /// 预置空任务列表与空缓存（多数用例公共 stub）
  void stubEmptyCache() {
    when(() => mockApi.cacheDownloadList()).thenAnswer((_) async => '[]');
    when(() => mockApi.listCachedChapterUrls(any()))
        .thenAnswer((_) async => const <String>[]);
  }

  testWidgets('离线缓存 书架为空时显示空态', (tester) async {
    when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
    stubEmptyCache();

    await tester.pumpWidget(wrap(const OfflineCacheScreen()));
    await tester.pump();

    expect(find.text('离线缓存'), findsOneWidget);
    expect(find.text('书架暂无书籍'), findsOneWidget);
  });

  testWidgets('离线缓存 渲染书籍列表与缓存进度（对齐 item_download.xml 三行布局）',
      (tester) async {
    final b1 = makeBook('u1', '书一', total: 10);
    final b2 = makeBook('u2', '书二', total: 20, bookType: BookType.local);
    when(() => mockApi.getBooks()).thenAnswer((_) async => [b1, b2]);
    stubEmptyCache();
    when(() => mockApi.listCachedChapterUrls('u1'))
        .thenAnswer((_) async => ['c1', 'c2', 'c3']);

    await tester.pumpWidget(wrap(const OfflineCacheScreen()));
    await tester.pump();
    await tester.pump();

    expect(find.text('书一'), findsOneWidget);
    expect(find.text('书二'), findsOneWidget);
    expect(find.text('作者A'), findsNWidgets(2));
    // 缓存进度行「已缓存 N/总章节数」（对齐原版 download_count）
    expect(find.text('已缓存 3/10'), findsOneWidget);
    // 本地书进度行显示「本地书籍」（原版 isLocal 短路）
    expect(find.text('本地书籍'), findsOneWidget);
    // 在线书有播放下载按钮，本地书无；导出按钮每本一个
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.widgetWithText(TextButton, '导出'), findsNWidgets(2));
  });

  testWidgets('离线缓存 下载按钮触发 cacheDownloadStart（download_all 0..末章）',
      (tester) async {
    final b1 = makeBook('u1', '书一', total: 10);
    when(() => mockApi.getBooks()).thenAnswer((_) async => [b1]);
    stubEmptyCache();
    when(() => mockApi.cacheDownloadStart(any(), any(), any()))
        .thenAnswer((_) async => 1);

    await tester.pumpWidget(wrap(const OfflineCacheScreen()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pump();

    verify(() => mockApi.cacheDownloadStart('u1', 0, 9)).called(1);
    // 启动后提示加入队列
    expect(find.text('《书一》已加入缓存队列'), findsOneWidget);
  });

  testWidgets('离线缓存 顶栏菜单「全部缓存」批量启动（确认对话框）', (tester) async {
    final b1 = makeBook('u1', '书一', total: 10);
    final b2 = makeBook('u2', '书二', total: 20);
    when(() => mockApi.getBooks()).thenAnswer((_) async => [b1, b2]);
    stubEmptyCache();
    when(() => mockApi.cacheDownloadStart(any(), any(), any()))
        .thenAnswer((_) async => 1);

    await tester.pumpWidget(wrap(const OfflineCacheScreen()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('缓存操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部缓存'));
    await tester.pumpAndSettle();

    // 原版 sureCacheBook 确认对话框
    expect(find.text('缓存所有书籍'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    verify(() => mockApi.cacheDownloadStart('u1', 0, 9)).called(1);
    verify(() => mockApi.cacheDownloadStart('u2', 0, 19)).called(1);
  });

  testWidgets('离线缓存 菜单「缓存当前章节之后」按当前章起点批量启动', (tester) async {
    // 书一已读到第 3 章（durChapterIndex=2）
    final b1 = Book(
      bookUrl: 'u1',
      name: '书一',
      author: '作者A',
      totalChapterNum: 10,
      durChapterIndex: 2,
    );
    when(() => mockApi.getBooks()).thenAnswer((_) async => [b1]);
    stubEmptyCache();
    when(() => mockApi.cacheDownloadStart(any(), any(), any()))
        .thenAnswer((_) async => 1);

    await tester.pumpWidget(wrap(const OfflineCacheScreen()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('缓存操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存当前章节之后'));
    await tester.pumpAndSettle();

    expect(find.text('缓存所有书籍当前章节之后'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // download_after：起点 = durChapterIndex（含当前章），终点 = 末章
    verify(() => mockApi.cacheDownloadStart('u1', 2, 9)).called(1);
  });

  testWidgets('离线缓存 进行中任务显示下载进度与停止按钮', (tester) async {
    final b1 = makeBook('u1', '书一', total: 10);
    when(() => mockApi.getBooks()).thenAnswer((_) async => [b1]);
    when(() => mockApi.cacheDownloadList()).thenAnswer((_) async =>
        '[{"taskId":7,"bookUrl":"u1","status":"running","total":10,"completed":4,"failed":0}]');
    when(() => mockApi.listCachedChapterUrls('u1'))
        .thenAnswer((_) async => const <String>[]);

    await tester.pumpWidget(wrap(const OfflineCacheScreen()));
    await tester.pump();
    await tester.pump();

    expect(find.text('下载中 4/10'), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    when(() => mockApi.cacheDownloadCancel(7)).thenAnswer((_) async => true);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();

    verify(() => mockApi.cacheDownloadCancel(7)).called(1);
    expect(find.text('已停止《书一》下载'), findsOneWidget);
  });
}
