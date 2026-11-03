// [批1b-2b | 2026-11-04] image-dominant 图片页五档点击接线测试 —
// 全栈工程师
//
// 文本排版引擎尚无行内图片渲染，图片当前只在 ReaderImageDominantBody
// （整章图片兜底页）出现；本用例锁定 clickImgWay 从阅读页透传到图片点击
// 的实际效果：
// 1. "1" 预览：点图打开既有全屏查看器（PhotoDialog 等价物）
// 2. "3" 关闭：点图穿透给页面（呼出/收起菜单）
// 3. "2" 在线文本书 + click 动作：无 action 执行能力 → 回退预览
// 4. "2" 本地书（非在线文本）：不消费 → 页面点击生效
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart'
    show RssPhotoViewer;
import 'package:flutter_legado/src/widgets/reader/reader_image_dominant_body.dart';

const _plainImg = '<img src="https://cdn.example.com/a.jpg">';
const _actionImg =
    '<img src="https://cdn.example.com/a.jpg,{"click":"act()"}">';

Book _book({required int type, required String origin}) => Book(
      bookUrl: 'https://book.example.com/1',
      name: '测试书',
      bookType: type,
      origin: origin,
    );

class _ToggleCounter {
  int value = 0;
}

Future<_ToggleCounter> _pumpPage(
  WidgetTester tester, {
  required String way,
  required String content,
  required Book book,
}) async {
  final counter = _ToggleCounter();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: ReaderImageDominantBody(
            content: content,
            book: book,
            clickImgWay: way,
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

void main() {
  testWidgets('"1" 预览：点图打开全屏图片查看器', (tester) async {
    await _pumpPage(
      tester,
      way: '1',
      content: _plainImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RssPhotoViewer), findsOneWidget);
  });

  testWidgets('"3" 关闭点击：点图穿透给页面（不打开预览）', (tester) async {
    final counter = await _pumpPage(
      tester,
      way: '3',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump(const Duration(milliseconds: 400));

    expect(counter.value, 1, reason: 'handled=false → 页面点击（toggleControls）生效');
    expect(find.byType(RssPhotoViewer), findsNothing);
  });

  testWidgets('"2" 在线文本书 + click 动作：执行能力缺失 → 回退预览', (tester) async {
    await _pumpPage(
      tester,
      way: '2',
      content: _actionImg,
      book: _book(type: 8, origin: 'https://source.example.com'),
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RssPhotoViewer), findsOneWidget);
  });

  testWidgets('"2" 本地书：不消费（对齐 isOnLineTxt 门槛）', (tester) async {
    final counter = await _pumpPage(
      tester,
      way: '2',
      content: _actionImg,
      book: _book(type: 8 | BookType.local | BookType.kotlinLocal,
          origin: BookType.localTag),
    );
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump(const Duration(milliseconds: 400));

    expect(counter.value, 1);
    expect(find.byType(RssPhotoViewer), findsNothing);
  });
}
