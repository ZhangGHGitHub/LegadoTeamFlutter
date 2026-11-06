// 封面对本地路径识别单测（设置批6b-1 设备回归 P2-1）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/cover_local_path.dart';

void main() {
  test('网络地址 / data URI / 空值不是本地封面', () {
    expect(localCoverFilePath(null), isNull);
    expect(localCoverFilePath(''), isNull);
    expect(localCoverFilePath('https://cover.test/a.jpg'), isNull);
    expect(localCoverFilePath('http://cover.test/a.jpg'), isNull);
    expect(localCoverFilePath('data:image/png;base64,AAAA'), isNull);
  });

  test('绝对路径原样返回（POSIX / Windows）', () {
    expect(
      localCoverFilePath('/data/user/0/app/covers/a.jpg'),
      '/data/user/0/app/covers/a.jpg',
    );
    expect(
      localCoverFilePath(r'C:\Users\me\covers\a.jpg'),
      r'C:\Users\me\covers\a.jpg',
    );
    expect(
      localCoverFilePath('C:/Users/me/covers/a.jpg'),
      'C:/Users/me/covers/a.jpg',
    );
  });

  test('file:// URI 转为本地路径', () {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}cover.png',
    );
    final uri = Uri.file(file.path).toString();
    expect(localCoverFilePath(uri), file.path);
  });

  test('相对路径按本地路径返回（由调用方判断存在性）', () {
    expect(localCoverFilePath('covers/a.jpg'), 'covers/a.jpg');
    expect(isLocalCoverUrl('covers/a.jpg'), isTrue);
    expect(isLocalCoverUrl('https://cover.test/a.jpg'), isFalse);
  });
}
