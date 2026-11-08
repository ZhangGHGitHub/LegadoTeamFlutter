// 封面相册多选选择器测试（设置批6b-2 审查回修 P2-2）
//
// 覆盖：选择阶段不读取字节（惰性句柄）、单张超限跳过不中止整批、
// 张数 >20 / 总大小 >64MB 拒绝、单张 readBytes 只在调用时执行。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/cover_album_image_picker.dart';
import 'package:flutter_legado/src/services/cover_album_store.dart';

CoverAlbumImagePick _pick(
  String name, {
  required int size,
  void Function()? onRead,
}) {
  return CoverAlbumImagePick(
    name: name,
    size: size,
    read: () async {
      onRead?.call();
      return Uint8List(size);
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(CoverAlbumImagePicker.resetForTest);

  test('选择阶段只取元数据，readBytes 惰性执行', () async {
    var reads = 0;
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [_pick('a.png', size: 10, onRead: () => reads++)],
        );
    final batch = await CoverAlbumImagePicker.pickImages();
    expect(batch.picks, hasLength(1));
    expect(batch.picks.single.size, 10);
    expect(reads, 0, reason: '选择阶段不得把字节读入内存');
    final bytes = await batch.picks.single.readBytes();
    expect(bytes, hasLength(10));
    expect(reads, 1);
  });

  test('单张超限只跳过该张，不中止整批', () async {
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            _pick('huge.png', size: CoverAlbumStore.maxBytes + 1),
            _pick('ok.png', size: 10),
          ],
        );
    final batch = await CoverAlbumImagePicker.pickImages();
    expect(batch.picks.map((p) => p.name), <String>['ok.png']);
    expect(batch.failures, hasLength(1));
    expect(batch.failures.single.name, 'huge.png');
    expect(batch.failures.single.message, contains('图片过大'));
  });

  test('张数超过 20 拒绝整批', () async {
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            for (var i = 0; i <= CoverAlbumImagePicker.maxCount; i++)
              _pick('$i.png', size: 1),
          ],
        );
    await expectLater(
      CoverAlbumImagePicker.pickImages(),
      throwsA(
        isA<CoverAlbumImagePickerException>().having(
          (e) => e.message,
          'message',
          contains('最多导入 20 张'),
        ),
      ),
    );
  });

  test('总大小超过 64MB 拒绝整批', () async {
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            for (var i = 0; i < 5; i++) _pick('$i.png', size: 20 * 1024 * 1024),
          ],
        );
    await expectLater(
      CoverAlbumImagePicker.pickImages(),
      throwsA(
        isA<CoverAlbumImagePickerException>().having(
          (e) => e.message,
          'message',
          contains('总大小超过 64MB'),
        ),
      ),
    );
  });
}
