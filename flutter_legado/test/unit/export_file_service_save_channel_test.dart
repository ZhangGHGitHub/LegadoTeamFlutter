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
  String? result =
      'content://com.android.providers.downloads.documents/document/42';
  Object? error;
  bool cancelled = false;

  @override
  Future<String?> saveFile({
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
    final path = await service.saveToLocal(
      fileName: 'bookSource_QA.json',
      content: '{"a":1}',
    );

    expect(path, channel.result);
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

    final path = await service.saveExistingFile(
      sourcePath: source.path,
      fileName: 'skin.zip',
    );

    expect(path, channel.result);
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

  test('通道异常：上抛可读的 FileSaveException', () async {
    channel.error = const FileSaveException(
      code: 'SAVE_FAILED',
      message: '写入文件失败（x.json）：Permission Denial',
    );

    await expectLater(
      service.saveToLocal(fileName: 'x.json', content: '{}'),
      throwsA(
        isA<FileSaveException>()
            .having((e) => e.code, 'code', 'SAVE_FAILED')
            .having(
              (e) => e.toString(),
              'message',
              contains('Permission Denial'),
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

  test('提示文案：移动端只显示文件名（content URI 不展示给用户）', () {
    expect(
      service.savedMessage(path: channel.result!, fileName: 'a.json'),
      '已保存：a.json',
    );
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
