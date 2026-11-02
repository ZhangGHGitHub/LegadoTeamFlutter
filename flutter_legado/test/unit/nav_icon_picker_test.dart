// [复核 P1 | 2026-11-02] 导航图标选图分支测试（复用 ContainerImagePicker）
//
// 覆盖：Android SAF 成功（image/* + fd 字节、不触碰 file_picker）、取消、
// 自定义 32MB 上限、SAF 异常不降级、iOS/桌面 file_picker 参数
//（allowCompression:false / withData:false / 标题）、平台元数据超限、
// 选图字节交给 NavIconStore.importBytes 的落盘/坏图拒绝。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saf/saf.dart';

import 'package:flutter_legado/src/services/container_image_picker.dart';
import 'package:flutter_legado/src/services/nav_icon_store.dart';

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
    return onRead?.call(uri) ?? Future<Uint8List>.value(Uint8List(0));
  }
}

class _RecordingFilePicker extends FilePicker {
  FilePickerResult? result;
  int pickCalls = 0;
  String? dialogTitle;
  FileType? type;
  bool? allowCompression;
  bool? withData;

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

Future<ContainerImagePick?> _pickNavIcon() => ContainerImagePicker.pick(
  maxBytes: NavIconStore.maxBytes,
  dialogTitle: '选择导航图标',
);

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
    saf.onPick = () async => _doc('home.png');
    saf.onRead = (_) async => Uint8List.fromList(_pngBytes);

    final picked = await _pickNavIcon();

    expect(picked, isNotNull);
    expect(picked!.name, 'home.png');
    expect(picked.bytes, _pngBytes);
    expect(saf.pickCalls, 1);
    expect(saf.readCalls, 1);
    expect(saf.lastMimeTypes, const <String>['image/*']);
    expect(filePicker.pickCalls, 0, reason: 'Android 不得触碰 MediaStore');
  });

  test('Android SAF 取消：返回 null，不读 fd、不碰 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async => null;

    expect(await _pickNavIcon(), isNull);
    expect(saf.readCalls, 0);
    expect(filePicker.pickCalls, 0);
  });

  test('Android SAF 元数据超 32MB：读字节前拒绝，不调用 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async =>
        _doc('too-big.png', length: NavIconStore.maxBytes + 1);

    await expectLater(
      _pickNavIcon(),
      throwsA(
        isA<ContainerImagePickException>().having(
          (e) => e.message,
          'message',
          contains('32MB'),
        ),
      ),
    );
    expect(saf.readCalls, 0);
    expect(filePicker.pickCalls, 0);
  });

  test('Android SAF 异常（含 fd 读取失败）：提示重试且不降级 file_picker', () async {
    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async => throw StateError('picker unavailable');

    await expectLater(
      _pickNavIcon(),
      throwsA(
        isA<ContainerImagePickException>().having(
          (e) => e.message,
          'message',
          '无法打开系统图片选择器，请重试',
        ),
      ),
    );
    expect(filePicker.pickCalls, 0);

    saf.onPick = () async => _doc('stale.png');
    saf.onRead = (_) async => throw StateError('stale uri');
    await expectLater(
      _pickNavIcon(),
      throwsA(isA<ContainerImagePickException>()),
    );
    expect(filePicker.pickCalls, 0);
  });

  test('iOS/桌面：file_picker 参数正确且元数据超限在读字节前拒绝', () async {
    ContainerImagePicker.isAndroid = () => false;
    filePicker.result = FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: 'desktop.png',
        size: _pngBytes.length,
        bytes: Uint8List.fromList(_pngBytes),
      ),
    ]);

    final picked = await _pickNavIcon();
    expect(picked, isNotNull);
    expect(picked!.bytes, _pngBytes);
    expect(filePicker.pickCalls, 1);
    expect(filePicker.type, FileType.image);
    expect(filePicker.allowCompression, isFalse);
    expect(filePicker.withData, isFalse);
    expect(filePicker.dialogTitle, '选择导航图标');
    expect(saf.pickCalls, 0);

    // 元数据已超限：即使 bytes 为空也应在读取前失败
    filePicker.result = FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: 'huge.png',
        size: NavIconStore.maxBytes + 1,
        bytes: null,
      ),
    ]);
    await expectLater(
      _pickNavIcon(),
      throwsA(
        isA<ContainerImagePickException>().having(
          (e) => e.message,
          'message',
          contains('32MB'),
        ),
      ),
    );
  });

  test('iOS/桌面 file_picker 取消返回 null', () async {
    ContainerImagePicker.isAndroid = () => false;
    filePicker.result = null;
    expect(await _pickNavIcon(), isNull);
    expect(saf.pickCalls, 0);
  });

  test('选图字节交给 NavIconStore.importBytes：合法落盘/坏图拒绝', () async {
    final temp = await Directory.systemTemp.createTemp('legado_nav_pick_');
    final originalSupport = NavIconStore.supportDir;
    NavIconStore.supportDir = () async => temp;
    NavIconStore.warmWith(temp);
    addTearDown(() async {
      NavIconStore.supportDir = originalSupport;
      NavIconStore.resetWarmCache();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    ContainerImagePicker.isAndroid = () => true;
    saf.onPick = () async => _doc('home.png');
    saf.onRead = (_) async => Uint8List.fromList(_pngBytes);
    final picked = await _pickNavIcon();
    final stored = await NavIconStore.importBytes(
      picked!.bytes,
      originalName: picked.name,
    );
    expect(stored, matches(RegExp(r'^nav_icons/[0-9a-f]{40}\.png$')));
    expect(NavIconStore.isUsableSync(stored), isTrue);

    saf.onPick = () async => _doc('fake.png');
    saf.onRead = (_) async => Uint8List.fromList(const <int>[1, 2, 3, 4]);
    final fake = await _pickNavIcon();
    await expectLater(
      NavIconStore.importBytes(fake!.bytes, originalName: fake.name),
      throwsA(isA<FormatException>()),
    );
  });
}
