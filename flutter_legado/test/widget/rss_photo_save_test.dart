// RSS 图片保存分派测试（D1 回修 P2-4）
//
// 背景：原实现在 Android MediaStore 返回 null 时回退
// `FilePicker.platform.saveFile(bytes:)`——该链路会在 onActivityResult
// 内裸写 SAF URI，命中 MuMu DownloadStorageProvider 崩溃路径，且 Future
// 可能永久挂起。本测锁定：Android 分支绝不调用 file_picker，改为写应用
// 文档目录且提示可见；图像查看器关闭后不再弹提示。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/rss_articles_screen.dart';

void main() {
  testWidgets('Android MediaStore 返回 null：不回退 file_picker，写文档目录并提示', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('rss_photo_save_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    var pickerCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: RssPhotoViewer(
              url: 'http://example.test/a.png',
              fetchBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
              saver: (bytes, fileName) => saveRssImageBytes(
                bytes: bytes,
                fileName: fileName,
                useMediaStore: true,
                saveToDownloads: (_, _) async => null,
                pickSaveFile: (_, _) async {
                  pickerCalls++;
                  return 'file-picker-should-not-be-called';
                },
                documentsDirectory: () async => dir,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('保存图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(pickerCalls, 0, reason: 'Android 分支禁止回退 file_picker');
    expect(find.textContaining('已保存到文档目录: ${dir.path}'), findsOneWidget);
    final files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.readAsBytesSync(), <int>[1, 2, 3]);
  });

  testWidgets('MediaStore 直写成功：提示 Download 路径且不调用 file_picker', (tester) async {
    var pickerCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: RssPhotoViewer(
              url: 'http://example.test/a.png',
              fetchBytes: () async => Uint8List.fromList(<int>[9]),
              saver: (bytes, fileName) => saveRssImageBytes(
                bytes: bytes,
                fileName: fileName,
                useMediaStore: true,
                saveToDownloads: (_, _) async => 'Download/legado/$fileName',
                pickSaveFile: (_, _) async {
                  pickerCalls++;
                  return null;
                },
                documentsDirectory: () async => Directory.systemTemp,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('保存图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(pickerCalls, 0);
    expect(find.textContaining('已保存: Download/legado/'), findsOneWidget);
  });

  testWidgets('图片查看器关闭后保存完成不再弹提示（可取消）', (tester) async {
    final completer = Completer<String?>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: RssPhotoViewer(
                        url: 'http://example.test/a.png',
                        fetchBytes: () async => Uint8List.fromList(<int>[1]),
                        saver: (_, _) => completer.future,
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('保存图片'));
    await tester.pump();

    // 保存进行中关闭查看器 → 完成后不得再弹保存提示
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('保存图片'), findsNothing);

    completer.complete('已保存到文档目录: /tmp/x.png');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('已保存到文档目录'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
