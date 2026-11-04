// [批4d] 书签角标渲染测试
//
// 覆盖：默认琥珀书签带、尺寸 0 隐藏、自定义图命中/缺失回落、
// 页面叠放几何（正文 contentTop+2 / right+6）。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/bookmark_badge_image_store.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bookmark_badge.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_chrome.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';

/// 1×1 透明 PNG（自定义图渲染路径用，避免解码失败走 errorBuilder）
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PageInfo _pageInfo() => PageInfo(
  paragraphs: [
    ParagraphInfo(
      lines: const [],
      totalHeight: 20,
      startIndex: 0,
      endIndex: 10,
    ),
  ],
  totalHeight: 20,
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Widget _page({
  required bool showBadge,
  String image = '',
  int size = 10,
  EdgeInsets padding = const EdgeInsets.fromLTRB(20, 24, 20, 24),
  ReaderPageChromeConfig pageChrome = const ReaderPageChromeConfig(),
}) => _host(
  SizedBox(
    width: 300,
    height: 400,
    child: ReaderTypographicPage(
      pageInfo: _pageInfo(),
      pageIndex: 0,
      totalPages: 1,
      chapterTitle: '第一章',
      fontSize: 18,
      lineHeight: 1.5,
      paragraphSpacing: 8,
      backgroundColor: Colors.white,
      textColor: Colors.black,
      contentPadding: padding,
      pageChrome: pageChrome,
      showBookmarkBadge: showBadge,
      bookmarkBadgeImage: image,
      bookmarkBadgeSize: size,
    ),
  ),
);

void main() {
  group('默认角标', () {
    test('几何常量对齐参考（12×24 视口、可见 2/3×5/6、缺口 25%）', () {
      expect(ReaderBookmarkBadgeGeometry.width(10), 10);
      expect(ReaderBookmarkBadgeGeometry.height(10), 20);
      expect(ReaderBookmarkBadgeGeometry.width(0), 0);
      expect(ReaderBookmarkBadgeGeometry.topInset, 0, reason: 'path 自带顶部内缩');
      expect(ReaderBookmarkBadgeGeometry.rightInset, 6);
      expect(ReaderBookmarkBadgeGeometry.referenceWidth, 12);
      expect(ReaderBookmarkBadgeGeometry.referenceHeight, 24);
      expect(
        (
          ReaderBookmarkBadgeGeometry.ribbonLeft,
          ReaderBookmarkBadgeGeometry.ribbonRight,
        ),
        (2, 10),
      );
      expect(
        (
          ReaderBookmarkBadgeGeometry.ribbonTop,
          ReaderBookmarkBadgeGeometry.ribbonBottom,
        ),
        (2, 22),
      );
      expect(
        ReaderBookmarkBadgeGeometry.visibleWidth(10),
        closeTo(20 / 3, 1e-9),
      );
      expect(
        ReaderBookmarkBadgeGeometry.visibleHeight(10),
        closeTo(50 / 3, 1e-9),
      );
      expect(ReaderBookmarkBadgeGeometry.notchDepthRatio, 0.25);
      expect(kBookmarkBadgeDefaultColor, const Color(0xFFFFC107));
    });

    testWidgets('无自定义图 → 默认琥珀书签带，尺寸 10×20', (tester) async {
      await tester.pumpWidget(_host(const ReaderBookmarkBadge(size: 10)));
      expect(
        find.byKey(const ValueKey('bookmark-badge-default')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(ReaderBookmarkBadge)),
        const Size(10, 20),
      );
    });

    testWidgets('size<=0 → 不渲染任何内容', (tester) async {
      await tester.pumpWidget(_host(const ReaderBookmarkBadge(size: 0)));
      expect(
        find.byKey(const ValueKey('bookmark-badge-default')),
        findsNothing,
      );
      expect(tester.getSize(find.byType(ReaderBookmarkBadge)), Size.zero);
    });

    testWidgets('自定义图缺失 → 回落默认书签带', (tester) async {
      await tester.pumpWidget(
        _host(
          const ReaderBookmarkBadge(
            size: 10,
            image: 'bookmark_badges/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png',
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('bookmark-badge-default')),
        findsOneWidget,
        reason: '未预热/文件缺失时 resolveSync 返回 null，走默认样式',
      );
      expect(find.byType(Image), findsNothing);
    });
  });

  group('自定义角标图', () {
    late Directory tempDir;
    late Future<Directory> Function() originalSupportDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('badge_widget_');
      originalSupportDir = BookmarkBadgeImageStore.supportDir;
      BookmarkBadgeImageStore.supportDir = () async => tempDir;
      BookmarkBadgeImageStore.resetWarmCache();
    });

    tearDown(() async {
      BookmarkBadgeImageStore.supportDir = originalSupportDir;
      BookmarkBadgeImageStore.resetWarmCache();
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } catch (_) {
        // Windows 下图片句柄可能尚未释放；临时目录由系统回收
      }
    });

    testWidgets('命中自有标识 → 渲染 Image.file（cover 裁切）', (tester) async {
      // 文件写入/图片解码均走真实 IO：runAsync 内完成，避免 fake async 卡死
      late String id;
      await tester.runAsync(() async {
        id = await BookmarkBadgeImageStore.storeBytes(
          _onePixelPng,
          originalName: 'badge.png',
        );
        await BookmarkBadgeImageStore.ensureWarm();
      });

      await tester.runAsync(() async {
        await tester.pumpWidget(
          _host(ReaderBookmarkBadge(size: 12, image: id)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bookmark-badge-default')),
        findsNothing,
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.contain, reason: '参考 min(w/bw,h/bh) 居中留白');
      expect(
        tester.getSize(find.byType(ReaderBookmarkBadge)),
        const Size(12, 24),
      );
    });
  });

  group('页面叠放', () {
    testWidgets('showBookmarkBadge=false → 无角标', (tester) async {
      await tester.pumpWidget(_page(showBadge: false));
      expect(find.byType(ReaderBookmarkBadge), findsNothing);
    });

    testWidgets('size=0 → 即使本页有书签也不渲染', (tester) async {
      await tester.pumpWidget(_page(showBadge: true, size: 0));
      expect(find.byType(ReaderBookmarkBadge), findsNothing);
    });

    testWidgets('几何：top=contentTop+topInset，right=contentRight+6', (
      tester,
    ) async {
      await tester.pumpWidget(
        _page(
          showBadge: true,
          padding: const EdgeInsets.fromLTRB(11, 23, 37, 19),
        ),
      );
      expect(find.byType(ReaderBookmarkBadge), findsOneWidget);

      final positioned = tester
          .widgetList<Positioned>(
            find.ancestor(
              of: find.byType(ReaderBookmarkBadge),
              matching: find.byType(Positioned),
            ),
          )
          .last;
      expect(positioned.top, 23 + ReaderBookmarkBadgeGeometry.topInset);
      expect(positioned.right, 37 + ReaderBookmarkBadgeGeometry.rightInset);
      expect(positioned.left, isNull);
      expect(positioned.bottom, isNull);
    });

    testWidgets('页眉启用时 top 叠加页眉块高（不被页眉覆盖）', (tester) async {
      const chrome = ReaderPageChromeConfig(
        headerMode: 1,
        headerPaddingTop: 4,
        headerPaddingBottom: 6,
        showHeaderLine: true,
        tipHeaderLeft: 2,
      );
      const padding = EdgeInsets.fromLTRB(11, 23, 37, 19);
      await tester.pumpWidget(
        _page(showBadge: true, padding: padding, pageChrome: chrome),
      );

      final headerHeight = ReaderPageLayoutMetrics.headerBlockHeight(
        tester.element(find.byType(ReaderTypographicPage)),
        chrome,
      );
      expect(headerHeight, greaterThan(0), reason: '页眉启用应有块高');

      final positioned = tester
          .widgetList<Positioned>(
            find.ancestor(
              of: find.byType(ReaderBookmarkBadge),
              matching: find.byType(Positioned),
            ),
          )
          .last;
      expect(
        positioned.top,
        headerHeight + padding.top + ReaderBookmarkBadgeGeometry.topInset,
      );
    });
  });
}
