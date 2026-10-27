// 批18b：远程书库 origin 对齐原版/参考版（`webDav::` 前缀 + serverID 属性）
//
// 原版证据：
// - `app/src/main/java/io/legado/app/constant/BookType.kt:76`
//   `const val webDavTag = "webDav::"`
// - `app/src/main/java/io/legado/app/ui/book/import/remote/RemoteBookViewModel.kt:141-143`
//   `BookType.webDavTag + CustomUrl(remoteBook.path).putAttribute("serverID", serverID)`
// - `app/src/main/java/io/legado/app/model/analyzeRule/CustomUrl.kt:42-47`
//   `toString() = url + "," + GSON.toJson(attribute)`
//
// 本仓库批18b 前的存量 origin 使用 `dav:` 前缀，读取侧永久兼容（双前缀），
// 不做存量迁移。

import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BookType.isWebDavOrigin（双前缀）', () {
    test('新前缀 webDav:: 命中（默认服无属性 / 自定义服带 serverID）', () {
      expect(
        BookType.isWebDavOrigin('webDav::https://dav.example.com/books/a.epub'),
        isTrue,
      );
      expect(
        BookType.isWebDavOrigin(
          'webDav::https://dav.example.com/books/a.epub,{"serverID":12}',
        ),
        isTrue,
      );
    });

    test('存量前缀 dav: 命中（完整 URL / 相对路径两种历史形态）', () {
      expect(
        BookType.isWebDavOrigin('dav:https://dav.example.com/books/a.epub'),
        isTrue,
      );
      expect(BookType.isWebDavOrigin('dav:books/a.epub'), isTrue);
    });

    test('非 WebDAV origin 不命中', () {
      expect(BookType.isWebDavOrigin('loc_book'), isFalse);
      expect(BookType.isWebDavOrigin('https://source.example.com'), isFalse);
      expect(BookType.isWebDavOrigin(''), isFalse);
      // 大小写敏感（对齐 Kotlin startsWith 默认大小写敏感）
      expect(BookType.isWebDavOrigin('webdav::https://x/a.epub'), isFalse);
    });
  });

  group('BookType.isLocalOrigin（loc_book / WebDAV 双前缀）', () {
    test('本地与 WebDAV origin 均为本地书', () {
      expect(BookType.isLocalOrigin('loc_book'), isTrue);
      expect(BookType.isLocalOrigin('webDav::https://x/a.epub'), isTrue);
      expect(BookType.isLocalOrigin('dav:https://x/a.epub'), isTrue);
    });

    test('在线书源 origin 不是本地书', () {
      expect(BookType.isLocalOrigin('https://source.example.com'), isFalse);
      expect(BookType.isLocalOrigin(''), isFalse);
    });
  });

  group('BookType.webDavPathOf（剥离前缀与属性后缀）', () {
    test('新格式：剥离 webDav:: 与 ,{"serverID":N} 后缀', () {
      expect(
        BookType.webDavPathOf(
          'webDav::https://dav.example.com/books/a.epub,{"serverID":12}',
        ),
        'https://dav.example.com/books/a.epub',
      );
      expect(
        BookType.webDavPathOf('webDav::https://dav.example.com/books/a.epub'),
        'https://dav.example.com/books/a.epub',
      );
    });

    test('原版 CustomUrl 允许逗号后空白（paramPattern \\s*,\\s*(?=\\{)）', () {
      expect(
        BookType.webDavPathOf(
          'webDav::https://dav.example.com/books/a.epub, {"serverID":12}',
        ),
        'https://dav.example.com/books/a.epub',
      );
    });

    test('存量格式：dav: 完整 URL / 相对路径原样返回', () {
      expect(
        BookType.webDavPathOf('dav:https://dav.example.com/books/a.epub'),
        'https://dav.example.com/books/a.epub',
      );
      expect(BookType.webDavPathOf('dav:books/a.epub'), 'books/a.epub');
    });

    test('非 WebDAV origin 返回 null', () {
      expect(BookType.webDavPathOf('loc_book'), isNull);
      expect(BookType.webDavPathOf('https://source.example.com'), isNull);
    });
  });

  group('BookType.buildWebDavOrigin（写入格式逐字对齐原版）', () {
    test('默认服务器（serverID=null）不追加属性，仅 webDav:: + URL', () {
      expect(
        BookType.buildWebDavOrigin(
          'https://dav.jianguoyun.com/dav/legado/books/a.epub',
        ),
        'webDav::https://dav.jianguoyun.com/dav/legado/books/a.epub',
      );
    });

    test('自定义服务器追加 ,{"serverID":<int>}（GSON 单键序列化）', () {
      expect(
        BookType.buildWebDavOrigin(
          'https://dav11.example.com/root/books/a.epub',
          serverId: 12,
        ),
        'webDav::https://dav11.example.com/root/books/a.epub,{"serverID":12}',
      );
    });

    test('构造结果可被 webDavPathOf 往返还原', () {
      const url = 'https://dav.example.com/books/a.epub';
      for (final serverId in <int?>[null, -1, 12]) {
        final origin = BookType.buildWebDavOrigin(url, serverId: serverId);
        expect(BookType.webDavPathOf(origin), url);
        expect(BookType.isWebDavOrigin(origin), isTrue);
      }
    });
  });

  group('BookType.joinRemoteUrl（斜杠归一）', () {
    test('基址带/不带尾斜杠、片段带/不带前斜杠均拼成单斜杠', () {
      expect(
        BookType.joinRemoteUrl('https://dav.example.com/', '/legado/'),
        'https://dav.example.com/legado/',
      );
      expect(
        BookType.joinRemoteUrl(
          BookType.joinRemoteUrl('https://dav.example.com/', '/legado/'),
          'books/a.epub',
        ),
        'https://dav.example.com/legado/books/a.epub',
      );
      expect(
        BookType.joinRemoteUrl('https://dav.example.com', 'books/a.epub'),
        'https://dav.example.com/books/a.epub',
      );
    });

    test('保留 scheme 的 //（不误伤 https://）', () {
      expect(
        BookType.joinRemoteUrl('https://dav.example.com/', 'a.epub'),
        startsWith('https://dav.example.com/'),
      );
    });
  });
}
