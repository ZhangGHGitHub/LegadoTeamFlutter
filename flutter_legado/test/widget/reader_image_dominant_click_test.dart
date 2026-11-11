// [批1b-2b | 2026-11-04] image-dominant 图片页五档点击接线测试 —
// 全栈工程师；[批20-A | 2026-11-12] 接入书源 action 执行断言
//
// 锁定 clickImgWay 从阅读页透传到图片点击的实际效果：
// 1. "1" 预览：点图打开既有全屏查看器（PhotoDialog 等价物），不执行 action
// 2. "3" 关闭：点图穿透给页面（呼出/收起菜单），不执行 action
// 3. "2" 在线文本书 + click/js 动作：调用 evalImageAction（Mock 断言参数）
// 4. "2" 本地书（非在线文本）：不消费、不执行 action
// 5. "0" 默认行为：单击 click 动作 → evalImageAction
// 6. "4" 双击：第二次点击执行 click 动作；无动作时回退预览
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart'
    show bookApiProvider;
import 'package:flutter_legado/src/screens/rss_articles_screen.dart'
    show RssPhotoViewer;
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/reader_image_dominant_body.dart';

const _plainImg = '<img src="https://cdn.example.com/a.jpg">';
const _actionImg =
    '<img src="https://cdn.example.com/a.jpg,{"click":"act()"}">';
const _jsActionImg =
    '<img src="https://cdn.example.com/a.jpg,{"js":"legacy()"}">';

const _bookUrl = 'https://book.example.com/1';
const _chapterIndex = 3;

Book _book({required int type, required String origin}) =>
    Book(bookUrl: _bookUrl, name: '测试书', bookType: type, origin: origin);

class _ToggleCounter {
  int value = 0;
}

/// 捕获 evalImageAction 调用参数的 Mock（返回可断言结果）
class _CapturingApi extends MockBookApi {
  final List<String> bookUrls = [];
  final List<int> chapterIndexes = [];
  final List<String> actions = [];
  final List<String> imgSrcs = [];

  @override
  Future<String> evalImageAction(
    String bookUrl,
    int chapterIndex,
    String action,
    String imgSrc,
  ) async {
    bookUrls.add(bookUrl);
    chapterIndexes.add(chapterIndex);
    actions.add(action);
    imgSrcs.add(imgSrc);
    return 'mock:$action';
  }
}

Future<_ToggleCounter> _pumpPage(
  WidgetTester tester, {
  required String way,
  required String content,
  required Book book,
  _CapturingApi? api,
}) async {
  final counter = _ToggleCounter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [if (api != null) bookApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Scaffold(
          body: ReaderImageDominantBody(
            content: content,
            book: book,
            clickImgWay: way,
            chapterIndex: _chapterIndex,
            onToggleControls: () => counter.value++,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return counter;
}

/// 双击（两次 tap 落在 Flutter 双击窗口内）
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('"1" 预览：点图打开全屏图片查看器，不执行 action', (tester) async {
    final api = _CapturingApi();
    await _pumpPage(
      tester,
      way: '1',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RssPhotoViewer), findsOneWidget);
    expect(api.actions, isEmpty);
  });

  testWidgets('"3" 关闭点击：点图穿透给页面，不执行 action', (tester) async {
    final api = _CapturingApi();
    final counter = await _pumpPage(
      tester,
      way: '3',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump(const Duration(milliseconds: 400));

    expect(counter.value, 1, reason: 'handled=false → 页面点击（toggleControls）生效');
    expect(find.byType(RssPhotoViewer), findsNothing);
    expect(api.actions, isEmpty);
  });

  testWidgets('"2" 在线文本书 + click 动作：调用 evalImageAction（参数断言）', (tester) async {
    final api = _CapturingApi();
    await _pumpPage(
      tester,
      way: '2',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.actions, ['act()']);
    expect(api.bookUrls, [_bookUrl]);
    expect(api.chapterIndexes, [_chapterIndex]);
    expect(api.imgSrcs, ['https://cdn.example.com/a.jpg']);
    expect(
      find.byType(RssPhotoViewer),
      findsNothing,
      reason: '执行 action 时不再回退预览',
    );
  });

  testWidgets('"2" 在线文本书 + 仅 js 动作：调用 evalImageAction', (tester) async {
    final api = _CapturingApi();
    await _pumpPage(
      tester,
      way: '2',
      content: _jsActionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.actions, ['legacy()']);
    expect(api.imgSrcs, ['https://cdn.example.com/a.jpg']);
  });

  testWidgets('"0" 默认行为：单击 click 动作 → evalImageAction', (tester) async {
    final api = _CapturingApi();
    await _pumpPage(
      tester,
      way: '0',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.actions, ['act()']);
    expect(api.chapterIndexes, [_chapterIndex]);
  });

  testWidgets('"4" 双击：第二次点击执行 click 动作', (tester) async {
    final api = _CapturingApi();
    await _pumpPage(
      tester,
      way: '4',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await _doubleTap(tester, find.byType(CachedNetworkImage));

    expect(api.actions, ['act()']);
  });

  testWidgets('"4" 双击 + 无动作：回退预览（不执行 action）', (tester) async {
    final api = _CapturingApi();
    await _pumpPage(
      tester,
      way: '4',
      content: _plainImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
      api: api,
    );
    await _doubleTap(tester, find.byType(CachedNetworkImage));

    expect(find.byType(RssPhotoViewer), findsOneWidget);
    expect(api.actions, isEmpty);
  });

  testWidgets('"2" 本地书：不消费、不执行 action（对齐 isOnLineTxt 门槛）', (tester) async {
    final api = _CapturingApi();
    final counter = await _pumpPage(
      tester,
      way: '2',
      content: _actionImg,
      book: _book(
        type: 8 | BookType.local | BookType.kotlinLocal,
        origin: BookType.localTag,
      ),
      api: api,
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump(const Duration(milliseconds: 400));

    expect(counter.value, 1);
    expect(find.byType(RssPhotoViewer), findsNothing);
    expect(api.actions, isEmpty);
  });
}
