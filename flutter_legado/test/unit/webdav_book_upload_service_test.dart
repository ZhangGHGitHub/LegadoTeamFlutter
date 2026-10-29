// 批40：WebDavBookUploadService 单测
//
// 覆盖：远端文件名/路径规则（originName 优先、空则取 basename）、开关
// 关闭/未配置跳过、上传成功回写 origin 与 lastCheckTime、上传失败/记录
// 回写失败均返回 failed（不抛给导入链路）、本地书相对标识解析（批40
// 回修 P1-1：iOS 批量导入为 `books/<name>`，上传前必须还原绝对路径）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/local_book_store.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_book_upload_service.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServersRustApi api;
  late SettingsService settings;
  late WebDavBookUploadService service;

  const book = Book(
    bookUrl: '/storage/emulated/0/Books/斗破苍穹.epub',
    name: '斗破苍穹',
    author: '天蚕土豆',
    origin: 'local',
    originName: '斗破苍穹.epub',
  );

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WebDavBookUploadService.resetAutoUploadQueueForTest();
    api = FakeServersRustApi();
    settings = SettingsService();
    service = WebDavBookUploadService(api: api, settings: settings);

    when(() => api.webdavUploadFile(any(), any(), any()))
        .thenAnswer((_) async {});
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.updateBook(any())).thenAnswer((_) async {});
  });

  void seedDefaultServer() {
    api.seedServer(
      config: jsonEncode({
        'url': 'https://dav.example.com/',
        'username': 'u',
        'password': 'p',
      }),
    );
  }

  group('远端命名规则', () {
    test('originName 优先', () {
      expect(webDavBookRemoteFileName(book), '斗破苍穹.epub');
      expect(webDavBookRemotePath(book), 'books/斗破苍穹.epub');
    });

    test('originName 为空时取 bookUrl basename（兼容 / 与 \\）', () {
      const a = Book(bookUrl: '/a/b/三体.txt');
      const b = Book(bookUrl: r'D:\Books\三体.txt');
      expect(webDavBookRemoteFileName(a), '三体.txt');
      expect(webDavBookRemoteFileName(b), '三体.txt');
    });
  });

  group('autoUploadAfterImport', () {
    test('开关关闭 → disabled，不上传', () async {
      seedDefaultServer();
      expect(
        await service.autoUploadAfterImport(book),
        BookAutoUploadOutcome.disabled,
      );
      verifyNever(() => api.webdavUploadFile(any(), any(), any()));
    });

    test('未配置 WebDAV → notConfigured，不上传', () async {
      await settings.setWebDavBookAutoUpload(true);
      expect(
        await service.autoUploadAfterImport(book),
        BookAutoUploadOutcome.notConfigured,
      );
      verifyNever(() => api.webdavUploadFile(any(), any(), any()));
    });

    test('上传成功 → uploaded，回写 origin 与 lastCheckTime', () async {
      await settings.setWebDavBookAutoUpload(true);
      seedDefaultServer();

      expect(
        await service.autoUploadAfterImport(book),
        BookAutoUploadOutcome.uploaded,
      );
      verify(
        () => api.webdavUploadFile(
          any(),
          'books/斗破苍穹.epub',
          '/storage/emulated/0/Books/斗破苍穹.epub',
        ),
      ).called(1);

      final updated = verify(() => api.updateBook(captureAny())).captured.single
          as Book;
      expect(updated.origin, startsWith('webDav::'));
      expect(
        updated.origin,
        contains('https://dav.example.com/legado/books/'),
      );
      expect(updated.lastCheckTime, greaterThan(0));
    });

    test('上传失败 → failed，不回写记录（不抛给导入链路）', () async {
      await settings.setWebDavBookAutoUpload(true);
      seedDefaultServer();
      when(() => api.webdavUploadFile(any(), any(), any()))
          .thenThrow(Exception('网络不可用'));

      expect(
        await service.autoUploadAfterImport(book),
        BookAutoUploadOutcome.failed,
      );
      verifyNever(() => api.updateBook(any()));
    });

    test('记录回写失败 → failed（上传已发生）', () async {
      await settings.setWebDavBookAutoUpload(true);
      seedDefaultServer();
      when(() => api.updateBook(any())).thenThrow(Exception('DB 写入失败'));

      expect(
        await service.autoUploadAfterImport(book),
        BookAutoUploadOutcome.failed,
      );
      verify(() => api.webdavUploadFile(any(), any(), any())).called(1);
    });
  });

  group('uploadBook 阶段化异常', () {
    test('上传阶段失败 → stage=upload', () async {
      seedDefaultServer();
      when(() => api.webdavUploadFile(any(), any(), any()))
          .thenThrow(Exception('HTTP 500'));
      final target = await service.resolveTarget();

      await expectLater(
        service.uploadBook(book: book, target: target!),
        throwsA(
          isA<WebDavBookUploadException>().having(
            (e) => e.stage,
            'stage',
            WebDavBookUploadStage.upload,
          ),
        ),
      );
    });

    test('记录阶段失败 → stage=record', () async {
      seedDefaultServer();
      when(() => api.updateBook(any())).thenThrow(Exception('DB 写入失败'));
      final target = await service.resolveTarget();

      await expectLater(
        service.uploadBook(book: book, target: target!),
        throwsA(
          isA<WebDavBookUploadException>().having(
            (e) => e.stage,
            'stage',
            WebDavBookUploadStage.record,
          ),
        ),
      );
    });
  });

  group('本地书路径解析（批40 回修 P1-1）', () {
    test('相对标识（iOS 批量导入）→ 上传前解析为 Documents 绝对路径', () async {
      final docs = Directory.systemTemp.createTempSync('legado_docs_');
      addTearDown(() => docs.deleteSync(recursive: true));
      LocalBookStore.warmWith(docs);

      await settings.setWebDavBookAutoUpload(true);
      seedDefaultServer();

      const relativeBook = Book(
        bookUrl: 'books/三体.epub',
        name: '三体',
        author: '刘慈欣',
        origin: 'local',
        originName: '三体.epub',
      );

      expect(
        await service.autoUploadAfterImport(relativeBook),
        BookAutoUploadOutcome.uploaded,
      );

      final sep = Platform.pathSeparator;
      final expected = [docs.path, 'books', '三体.epub'].join(sep);
      // 远端相对路径不变，本地读取路径必须是当前容器的绝对路径
      verify(
        () => api.webdavUploadFile(any(), 'books/三体.epub', expected),
      ).called(1);
    });

    test('绝对路径原样上传（非 iOS 存量书行为不变）', () async {
      await settings.setWebDavBookAutoUpload(true);
      seedDefaultServer();

      expect(
        await service.autoUploadAfterImport(book),
        BookAutoUploadOutcome.uploaded,
      );
      verify(
        () => api.webdavUploadFile(
          any(),
          'books/斗破苍穹.epub',
          '/storage/emulated/0/Books/斗破苍穹.epub',
        ),
      ).called(1);
    });
  });

  group('自动上传串行（批40 回修 P2-3）', () {
    test('逐本导入：第二次上传在第一次完成后开始', () async {
      await settings.setWebDavBookAutoUpload(true);
      seedDefaultServer();

      const secondBook = Book(
        bookUrl: '/books/b.txt',
        name: '本地书B',
        author: '',
        origin: 'local',
        originName: 'b.txt',
      );
      final gate = Completer<void>();
      final started = <String>[];
      when(() => api.webdavUploadFile(any(), any(), any())).thenAnswer((inv) async {
        final remote = inv.positionalArguments[1] as String;
        started.add(remote);
        if (started.length == 1) await gate.future;
      });

      final first = service.autoUploadAfterImport(book);
      final second = service.autoUploadAfterImport(secondBook);

      // 第一次上传阻塞在 gate 上：第二次不得开始
      await pumpEventQueue();
      expect(
        started,
        ['books/斗破苍穹.epub'],
        reason: '第二次上传必须等第一次完成（原版串行语义）',
      );

      gate.complete();
      expect(await first, BookAutoUploadOutcome.uploaded);
      expect(await second, BookAutoUploadOutcome.uploaded);
      expect(started, ['books/斗破苍穹.epub', 'books/b.txt']);
    });
  });
}
