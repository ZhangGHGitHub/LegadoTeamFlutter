// ExportFileService Android 自建 SAF 通道单测（D1 / 批26）
//
// 背景：file_picker 8.3.7 在 Android onActivityResult 内裸写 SAF URI，
// SecurityException 未捕获 → 进程崩溃。Android 改走可注入的
// [FileSaveChannel]（生产实现为 `legado/file_save` 通道），批26 起默认
// 走 SAF 目录树（`ACTION_OPEN_DOCUMENT_TREE` + `createDocument`）。本测锁定：
// 1. 文本/既有文件（filePath 模式）统一走通道，MIME 按扩展名推断；
// 2. 用户取消 → 返回 null；
// 3. 通道异常 → 上抛可读的 FileSaveException；
// 4. 空字节仍交给通道（由原生 EMPTY_BYTES 拒绝），不静默成功；
// 5. Android 默认 tree 模式（useTree=true），chooseTree 可透传；
// 6. 目录树选择的读写（chooseTree/savedTree）与提示文案（回显实际目录）；
// 7. 非 Android 不使用该通道（保持 iOS/桌面既有链路）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/export_file_service.dart';
import 'package:flutter_legado/src/services/file_save_channel.dart';

/// 记录调用的假通道
class _FakeFileSaveChannel extends FileSaveChannel {
  final List<Map<String, Object?>> calls = [];
  SaveFileResult? result = const SaveFileResult(
    location: 'content://com.android.providers.downloads.documents/document/42',
    fileName: 'bookSource_QA (1).json',
  );
  Object? error;
  bool cancelled = false;

  /// 目录树选择结果（chooseTree / savedTree 返回）
  SaveTreeSelection? tree;

  /// chooseTree / savedTree 调用次数
  int chooseTreeCalls = 0;
  int savedTreeCalls = 0;

  @override
  Future<SaveFileResult?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    bool useTree = true,
    bool chooseTree = false,
  }) async {
    calls.add(<String, Object?>{
      'fileName': fileName,
      'bytes': bytes,
      'mimeType': mimeType,
      'useTree': useTree,
      'chooseTree': chooseTree,
    });
    final failure = error;
    if (failure != null) throw failure;
    if (cancelled) return null;
    return result;
  }

  @override
  Future<SaveTreeSelection?> chooseTree() async {
    chooseTreeCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return tree;
  }

  @override
  Future<SaveTreeSelection?> savedTree() async {
    savedTreeCalls++;
    return tree;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeFileSaveChannel channel;
  late ExportFileService service;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    channel = _FakeFileSaveChannel();
    service = ExportFileService(fileSaveChannel: channel);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('文本另存：走通道并回传 content URI，MIME 按扩展名推断', () async {
    final saved = await service.saveToLocal(
      fileName: 'bookSource_QA.json',
      content: '{"a":1}',
    );

    expect(saved, channel.result);
    expect(channel.calls, hasLength(1));
    final call = channel.calls.single;
    expect(call['fileName'], 'bookSource_QA.json');
    expect(call['mimeType'], 'application/json');
    expect(String.fromCharCodes(call['bytes']! as Uint8List), '{"a":1}');
    // 批26：Android 默认目录树模式，且不强制重选目录
    expect(call['useTree'], isTrue);
    expect(call['chooseTree'], isFalse);
  });

  test('filePath 模式：既有文件字节原样交给通道（二进制安全）', () async {
    final dir = Directory.systemTemp.createTempSync('export_channel_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = File('${dir.path}${Platform.pathSeparator}skin.zip')
      ..writeAsBytesSync(<int>[0x50, 0x4b, 0x03, 0x04, 0x00]);

    final saved = await service.saveExistingFile(
      sourcePath: source.path,
      fileName: 'skin.zip',
    );

    expect(saved, channel.result);
    final call = channel.calls.single;
    expect(call['mimeType'], 'application/zip');
    expect((call['bytes']! as Uint8List).toList(), <int>[
      0x50,
      0x4b,
      0x03,
      0x04,
      0x00,
    ]);
  });

  test('用户取消：通道返回 null 时原样向上返回', () async {
    channel.cancelled = true;
    expect(
      await service.saveToLocal(fileName: 'x.json', content: '{}'),
      isNull,
    );
  });

  test('通道异常：上抛可读的 FileSaveException（保留技术详情）', () async {
    channel.error = const FileSaveException(
      code: 'SAVE_FAILED',
      message: '无法写入所选位置，请换一个文件夹重试',
      detail: 'Permission Denial: requires android.permission.MANAGE_DOCUMENTS',
    );

    await expectLater(
      service.saveToLocal(fileName: 'x.json', content: '{}'),
      throwsA(
        isA<FileSaveException>()
            .having((e) => e.code, 'code', 'SAVE_FAILED')
            .having((e) => e.toString(), 'message', '无法写入所选位置，请换一个文件夹重试')
            .having((e) => e.detail, 'detail', contains('MANAGE_DOCUMENTS')),
      ),
    );
  });

  test('空字节：仍交给通道（由原生 EMPTY_BYTES 拒绝），不静默成功', () async {
    channel.error = const FileSaveException(
      code: 'EMPTY_BYTES',
      message: '导出内容为空，未创建文件',
    );

    await expectLater(
      service.saveToLocal(fileName: 'empty.json', content: ''),
      throwsA(
        isA<FileSaveException>().having((e) => e.code, 'code', 'EMPTY_BYTES'),
      ),
    );
    expect(channel.calls, hasLength(1));
    expect(channel.calls.single['bytes']! as Uint8List, isEmpty);
  });

  test('目录树参数：chooseTree=true / useTree=false 原样透传', () async {
    await service.saveToLocal(
      fileName: 'x.json',
      content: '{}',
      chooseTree: true,
    );
    expect(channel.calls.single['chooseTree'], isTrue);
    expect(channel.calls.single['useTree'], isTrue);

    await service.saveToLocal(
      fileName: 'x.json',
      content: '{}',
      useTree: false,
    );
    expect(channel.calls.last['useTree'], isFalse);
  });

  test('「换个位置」：Android 委托通道选择目录', () async {
    channel.tree = const SaveTreeSelection(
      location:
          'content://com.android.externalstorage.documents/tree/primary%3ADownload%2Flegado',
      displayPath: '下载/legado',
      authority: 'com.android.externalstorage.documents',
    );

    final tree = await service.chooseSaveDirectory();

    expect(tree, channel.tree);
    expect(channel.chooseTreeCalls, 1);
  });

  test('已记住目录：Android 读取通道（用于展示当前保存位置）', () async {
    channel.tree = const SaveTreeSelection(
      location:
          'content://com.android.providers.downloads.documents/tree/downloads',
      displayPath: '下载',
    );

    expect(await service.rememberedSaveDirectory(), channel.tree);
    expect(channel.savedTreeCalls, 1);
  });

  test('非 Android：不提供目录树选择/记忆（返回 null）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await service.chooseSaveDirectory(), isNull);
    expect(await service.rememberedSaveDirectory(), isNull);
    expect(channel.chooseTreeCalls, 0);
    expect(channel.savedTreeCalls, 0);
  });

  test('提示文案：使用原生回传的实际文件名（重名 (1) 与磁盘一致）', () {
    expect(
      service.savedMessage(
        saved: channel.result!,
        requestedFileName: 'bookSource_QA.json',
      ),
      '已保存：bookSource_QA (1).json',
    );
  });

  test('提示文案：原生未回传文件名时回落请求名', () {
    expect(
      service.savedMessage(
        saved: const SaveFileResult(location: 'content://x/y'),
        requestedFileName: 'a.json',
      ),
      '已保存：a.json',
    );
  });

  // 批26：目录树保存必须回显实际目录（对齐「已保存到「下载/legado」：xxx」），
  // 否则用户只知道文件名，无法在文件管理器中定位。
  test('提示文案：目录树保存回显实际目录', () {
    const saved = SaveFileResult(
      location:
          'content://com.android.externalstorage.documents/document/'
          'primary%3ADownload%2Flegado%2Fx.json',
      fileName: 'bookSource_QA (1).json',
      viaTree: true,
      displayPath: '下载/legado',
    );
    expect(
      service.savedMessage(
        saved: saved,
        requestedFileName: 'bookSource_QA.json',
      ),
      '已保存到「下载/legado」：bookSource_QA (1).json',
    );
  });

  test('提示文案：目录树英文 Download 前缀规范化为「下载」', () {
    const saved = SaveFileResult(
      location: 'content://x/tree/document/x.json',
      fileName: 'a.json',
      viaTree: true,
      displayPath: 'Download/legado',
    );
    expect(
      service.savedMessage(saved: saved, requestedFileName: 'a.json'),
      '已保存到「下载/legado」：a.json',
    );
  });

  test('提示文案：目录树未回传目录时退回通用文案', () {
    const saved = SaveFileResult(
      location: 'content://x/tree/document/x.json',
      fileName: 'a.json',
      viaTree: true,
    );
    expect(
      service.savedMessage(saved: saved, requestedFileName: 'a.json'),
      '已保存：a.json',
    );
  });

  // P1-1 / P3-3：回退写入「下载」子目录时必须回显目录，否则用户只看到
  // 文件名，无法定位（原 DownloadsProvider 回退写根、提示只有文件名）。
  test('提示文案：MediaStore 回退带「下载」子目录', () {
    const saved = SaveFileResult(
      location: 'content://media/external_primary/file/1000001500',
      fileName: 'bookSource_QA (1).json',
      viaMediaStoreFallback: true,
      downloadDirectory: 'Download/legado/',
    );
    expect(
      service.savedMessage(
        saved: saved,
        requestedFileName: 'bookSource_QA.json',
      ),
      '已保存到「下载/legado」：bookSource_QA (1).json',
    );
  });

  test('提示文案：MediaStore 回退到「下载」根', () {
    const saved = SaveFileResult(
      location: 'content://media/external_primary/file/1000001501',
      fileName: 'a.json',
      viaMediaStoreFallback: true,
      downloadDirectory: 'Download/',
    );
    expect(
      service.savedMessage(saved: saved, requestedFileName: 'a.json'),
      '已保存到「下载」：a.json',
    );
  });

  test('提示文案：回退但原生未回传目录时退回通用文案', () {
    const saved = SaveFileResult(
      location: 'content://media/external_primary/file/1000001502',
      fileName: 'a.json',
      viaMediaStoreFallback: true,
    );
    expect(
      service.savedMessage(saved: saved, requestedFileName: 'a.json'),
      '已保存到下载目录：a.json',
    );
  });

  test('文件名净化：非法字符在进入通道前替换为下划线', () async {
    await service.saveToLocal(fileName: 'a/b:c*d?.json', content: '{}');
    expect(channel.calls.single['fileName'], 'a_b_c_d_.json');
  });

  // P3-5：Dart 与 Kotlin 的 normalizeFileName 同为「替换 + trim」
  test('文件名净化：与原生一致去首尾空白', () async {
    await service.saveToLocal(fileName: '  a.json  ', content: '{}');
    expect(channel.calls.single['fileName'], 'a.json');
    expect(ExportFileService.normalizeFileName('\t a?b.json \n'), 'a_b.json');
  });

  test('非 Android 不使用自建通道（保持 iOS/桌面既有分派）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 桌面端调用 file_picker 平台通道；测试宿主无插件实现应抛
    // MissingPluginException，且绝不能误走 Android 通道。
    await expectLater(
      service.saveToLocal(fileName: 'x.json', content: '{}'),
      throwsA(anything),
    );
    expect(channel.calls, isEmpty);
  });

  // ---------- MethodChannel 契约（参数/回传解析） ----------

  group('MethodChannelFileSaveChannel', () {
    const saveChannel = MethodChannelFileSaveChannel();
    const platformChannel = MethodChannel('legado/file_save');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(platformChannel, null);
    });

    test('saveFile：透传 useTree/chooseTree，解析 viaTree/displayPath', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(platformChannel, (call) async {
        received = call;
        return <String, Object?>{
          'uri': 'content://com.android.externalstorage.documents/document/x',
          'name': 'bookSource_QA (2).json',
          'fallback': 'none',
          'relativeDir': null,
          'viaTree': true,
          'displayPath': '下载/legado',
        };
      });

      final saved = await saveChannel.saveFile(
        fileName: 'bookSource_QA.json',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        mimeType: 'application/json',
        useTree: true,
        chooseTree: true,
      );

      expect(received?.method, 'saveFile');
      final args = received!.arguments as Map<Object?, Object?>;
      expect(args['fileName'], 'bookSource_QA.json');
      expect(args['mimeType'], 'application/json');
      expect(args['useTree'], isTrue);
      expect(args['chooseTree'], isTrue);
      expect(args['bytes'], isA<Uint8List>());
      expect(saved?.viaTree, isTrue);
      expect(saved?.displayPath, '下载/legado');
      expect(saved?.fileName, 'bookSource_QA (2).json');
      expect(saved?.viaMediaStoreFallback, isFalse);
    });

    test('chooseTree：解析目录树回传', () async {
      messenger.setMockMethodCallHandler(platformChannel, (call) async {
        expect(call.method, 'chooseTree');
        return <String, Object?>{
          'uri':
              'content://com.android.providers.downloads.documents/tree/downloads',
          'displayPath': '下载',
          'authority': 'com.android.providers.downloads.documents',
        };
      });

      final tree = await saveChannel.chooseTree();
      expect(tree?.displayPath, '下载');
      expect(tree?.authority, 'com.android.providers.downloads.documents');
    });

    test('savedTree：未记住目录时返回 null', () async {
      messenger.setMockMethodCallHandler(platformChannel, (call) async {
        expect(call.method, 'getSavedTree');
        return null;
      });
      expect(await saveChannel.savedTree(), isNull);
    });

    test('平台错误：错误码映射为中文短句（TREE_WRITE_FAILED）', () async {
      messenger.setMockMethodCallHandler(platformChannel, (call) async {
        throw PlatformException(
          code: 'TREE_WRITE_FAILED',
          message: '',
          details: <String, Object?>{'detail': 'EACCES'},
        );
      });

      await expectLater(
        saveChannel.saveFile(
          fileName: 'x.json',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(
          isA<FileSaveException>()
              .having((e) => e.code, 'code', 'TREE_WRITE_FAILED')
              .having((e) => e.message, 'message', '无法写入所选文件夹，请换一个文件夹重试')
              .having((e) => e.detail, 'detail', 'EACCES'),
        ),
      );
    });
  });
}
