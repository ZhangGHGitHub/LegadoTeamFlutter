// ExportFileService Android 自建 SAF 通道单测（D1）
//
// 背景：file_picker 8.3.7 在 Android onActivityResult 内裸写 SAF URI，
// SecurityException 未捕获 → 进程崩溃。Android 改走可注入的
// [FileSaveChannel]（生产实现为 `legado/file_save` 通道），本测锁定：
// 1. 文本/既有文件（filePath 模式）统一走通道，MIME 按扩展名推断；
// 2. 用户取消 → 返回 null；
// 3. 通道异常 → 上抛可读的 FileSaveException；
// 4. 空字节仍交给通道（由原生 EMPTY_BYTES 拒绝），不静默成功；
// 5. 非 Android 不使用该通道（保持 iOS/桌面既有链路）。
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  @override
  Future<SaveFileResult?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    calls.add(<String, Object?>{
      'fileName': fileName,
      'bytes': bytes,
      'mimeType': mimeType,
    });
    final failure = error;
    if (failure != null) throw failure;
    if (cancelled) return null;
    return result;
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
            .having(
              (e) => e.toString(),
              'message',
              '无法写入所选位置，请换一个文件夹重试',
            )
            .having(
              (e) => e.detail,
              'detail',
              contains('MANAGE_DOCUMENTS'),
            ),
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
    expect((channel.calls.single['bytes']! as Uint8List), isEmpty);
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

  test('文件名净化：非法字符在进入通道前替换为下划线', () async {
    await service.saveToLocal(fileName: 'a/b:c*d?.json', content: '{}');
    expect(channel.calls.single['fileName'], 'a_b_c_d_.json');
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
}
