// [设置批2b-1b-2a | 2026-11-02] 容器背景图选择器单测 — 全栈工程师
//
// 覆盖：Android SAF 成功（mime=image/* + fd 字节）、取消、异常（提示且不降级
// file_picker）、陈旧 URI 不列出时不触碰 MediaStore；iOS/桌面仍走 file_picker
// 且 allowCompression=false；SAF 字节交给 storeBytes 后仍做 32MB/可解码校验。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saf/saf.dart';

import 'package:flutter_legado/src/services/container_image_picker.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

SafDocumentFile _doc(String name, {int? length}) => SafDocumentFile(
  uri: 'content://test/$name',
  name: name,
  isDir: false,
  length: length ?? _pngBytes.length,
  lastModified: 0,
  mimeType: 'image/png',
);

class _FakeSafGateway implements ContainerSafGateway {
  Future<SafDocumentFile?> Function()? onPick;
  Future<Uint8List> Function(String uri)? onRead;
  int pickCalls = 0;
  int readCalls = 0;
  List<String>? lastMimeTypes;
  String? lastUri;

  @override
  Future<SafDocumentFile?> pickImage({
    List<String> mimeTypes = const <String>['image/*'],
  }) {
    pickCalls++;
    lastMimeTypes = mimeTypes;
    return onPick?.call() ?? Future<SafDocumentFile?>.value();
  }

  @override
  Future<Uint8List> readBytes(String uri) {
    readCalls++;
    lastUri = uri;
    return onRead?.call(uri) ?? Future<Uint8List>.value(Uint8List(0));
  }
}

class _RecordingFilePicker extends FilePicker {
  FilePickerResult? result;
  int pickCalls = 0;
  FileType? type;
  bool? allowCompression;
  bool? withData;
  String? dialogTitle;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCalls++;
    this.dialogTitle = dialogTitle;
    this.type = type;
    this.allowCompression = allowCompression;
    this.withData = withData;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSafGateway saf;
  late _RecordingFilePicker filePicker;
  late FilePicker? originalPicker;
  var pickerInitialized = false;

  setUp(() {
    ContainerImagePicker.resetForTest();
    saf = _FakeSafGateway();
    ContainerImagePicker.safGateway = saf;
    filePicker = _RecordingFilePicker();
    try {
      originalPicker = FilePicker.platform;
      pickerInitialized = true;
    } catch (_) {
      pickerInitialized = false;
    }
    FilePicker.platform = filePicker;
  });

  tearDown(() {
    FilePicker.platform = pickerInitialized ? originalPicker! : FilePickerIO();
    ContainerImagePicker.resetForTest();
  });

  test('Android SAF 成功：pickFile(image/*) + fd 字节，不调用 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async => _doc('picked.png');
    saf.onRead = (_) async => Uint8List.fromList(_pngBytes);

    final picked = await ContainerImagePicker.pick();

    expect(picked, isNotNull);
    expect(picked!.name, 'picked.png');
    expect(picked.bytes, _pngBytes);
    expect(saf.pickCalls, 1);
    expect(saf.readCalls, 1);
    expect(saf.lastMimeTypes, const <String>['image/*']);
    expect(saf.lastUri, 'content://test/picked.png');
    expect(
      filePicker.pickCalls,
      0,
      reason: 'Android 不得回落到 file_picker/MediaStore 路径',
    );
  });

  test('Android SAF 取消/陈旧 URI 不列出：返回 null，不读 fd、不碰 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async => null;

    final picked = await ContainerImagePicker.pick();

    expect(picked, isNull);
    expect(saf.readCalls, 0);
    expect(filePicker.pickCalls, 0);
  });

  test('Android SAF 元数据超 32MB：读字节前拒绝，不调用 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async =>
        _doc('too-big.png', length: ThemeBackgroundImageStore.maxBytes + 1);

    await expectLater(
      ContainerImagePicker.pick(),
      throwsA(
        isA<ContainerImagePickException>().having(
          (e) => e.message,
          'message',
          contains('32MB'),
        ),
      ),
    );
    expect(saf.readCalls, 0, reason: '超大文件不得整体读入内存');
    expect(filePicker.pickCalls, 0);
  });

  test('Android SAF 异常（含 fd 读取失败）：提示重试且不降级 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async => throw StateError('picker unavailable');

    await expectLater(
      ContainerImagePicker.pick(),
      throwsA(
        isA<ContainerImagePickException>().having(
          (e) => e.message,
          'message',
          '无法打开系统图片选择器，请重试',
        ),
      ),
    );
    expect(filePicker.pickCalls, 0);

    // 选择成功但 fd 读取失败（陈旧/被回收 URI）同样提示，不降级
    saf.onPick = () async => _doc('stale.png');
    saf.onRead = (_) async => throw StateError('stale uri');
    await expectLater(
      ContainerImagePicker.pick(),
      throwsA(isA<ContainerImagePickException>()),
    );
    expect(filePicker.pickCalls, 0);
  });

  test('iOS/桌面：SAF 不参与，走 file_picker 且 allowCompression=false', () async {
    ContainerImagePicker.isAndroid = () => false;
    filePicker.result = FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: 'desktop.png',
        size: _pngBytes.length,
        bytes: Uint8List.fromList(_pngBytes),
      ),
    ]);

    final picked = await ContainerImagePicker.pick();

    expect(picked, isNotNull);
    expect(picked!.name, 'desktop.png');
    expect(picked.bytes, _pngBytes);
    expect(filePicker.pickCalls, 1);
    expect(filePicker.type, FileType.image);
    expect(filePicker.allowCompression, isFalse);
    expect(filePicker.withData, isFalse);
    expect(filePicker.dialogTitle, '选择容器背景图片');
    expect(saf.pickCalls, 0);
  });

  test('iOS/桌面 file_picker 取消返回 null', () async {
    ContainerImagePicker.isAndroid = () => false;
    filePicker.result = null;

    expect(await ContainerImagePicker.pick(), isNull);
    expect(saf.pickCalls, 0);
  });

  test('Android SAF 字节仍由 storeBytes 校验：超 32MB/非图拒绝', () async {
    ContainerImagePicker.isAndroid = () => true;
    final temp = await Directory.systemTemp.createTemp('legado_picker_');
    final originalSupportDir = ThemeBackgroundImageStore.supportDir;
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
    addTearDown(() async {
      ThemeBackgroundImageStore.supportDir = originalSupportDir;
      ThemeBackgroundImageStore.resetWarmCache();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    saf.onPick = () async => _doc('big.png');
    saf.onRead = (_) async => Uint8List(ThemeBackgroundImageStore.maxBytes + 1);
    final big = await ContainerImagePicker.pick();
    await expectLater(
      ThemeBackgroundImageStore.storeBytes(
        big!.bytes,
        originalName: big.name,
        slot: 'large_light',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('32MB'),
        ),
      ),
    );

    saf.onPick = () async => _doc('fake.png');
    saf.onRead = (_) async => Uint8List.fromList(const <int>[1, 2, 3]);
    final fake = await ContainerImagePicker.pick();
    await expectLater(
      ThemeBackgroundImageStore.storeBytes(
        fake!.bytes,
        originalName: fake.name,
        slot: 'large_light',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
