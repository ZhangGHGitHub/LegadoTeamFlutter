// RSS 图片查看器 data: URI 接线组件测试（批15g③）
//
// 对齐原版 `ReadRssViewModel.webData2bitmap`（`ReadRssViewModel.kt:248-256`）：
// - `data:image/...;base64,...` 直接解码展示/保存，不走网络下载；
// - 保存扩展名按 MIME；
// - 非法/超长 base64 给明确错误，不崩溃。
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/rss_articles_screen.dart';

/// 1x1 透明 PNG（68 字节，PNG 魔数合法）
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  Future<void> pumpViewer(
    WidgetTester tester, {
    required String url,
    RssPhotoSaver? saver,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: RssPhotoViewer(url: url, title: '图片', saver: saver),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('data: URI 直接解码展示（Image.memory，不发起网络）', (tester) async {
    await pumpViewer(tester, url: 'data:image/png;base64,$_pngBase64');

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>());
    expect(
      (image.image as MemoryImage).bytes,
      base64Decode(_pngBase64),
      reason: 'data: URI 应解码为原始字节交给 Image.memory',
    );
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('data: URI 保存：字节来自解码，扩展名按 MIME', (tester) async {
    Uint8List? savedBytes;
    String? savedName;
    await pumpViewer(
      tester,
      url: 'data:image/jpeg;base64,$_pngBase64',
      saver: (bytes, fileName) async {
        savedBytes = bytes;
        savedName = fileName;
        return '已保存: $fileName';
      },
    );

    await tester.tap(find.byTooltip('保存图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(savedBytes, base64Decode(_pngBase64));
    expect(savedName, endsWith('.jpg'), reason: 'image/jpeg → .jpg');
    expect(find.textContaining('已保存: rss-'), findsOneWidget);
  });

  testWidgets('非法 base64：展示明确错误，保存失败不崩溃', (tester) async {
    var saverCalls = 0;
    await pumpViewer(
      tester,
      url: 'data:image/png;base64,@@@bad@@@',
      saver: (_, _) async {
        saverCalls++;
        return null;
      },
    );

    expect(find.text('base64 数据无效'), findsOneWidget);

    await tester.tap(find.byTooltip('保存图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(saverCalls, 0, reason: '解码失败时不得进入保存动作');
    expect(find.textContaining('保存图片失败：base64 数据无效'), findsOneWidget);
  });

  testWidgets('缺少 base64 标记：展示明确错误', (tester) async {
    await pumpViewer(tester, url: 'data:image/png,AAAA');

    expect(find.text('data URI 缺少 base64 编码'), findsOneWidget);
  });

  testWidgets('普通 URL 仍走网络图片组件（回归：不误判为 data URI）', (tester) async {
    await pumpViewer(tester, url: 'https://s.test/a.png');

    // 非 data: URI 时渲染 CachedNetworkImage（内部包 Image），不显示 data 错误
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.textContaining('base64'), findsNothing);
  });
}
