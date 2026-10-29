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

  group('BookType.isLocalBook（类型感知，对齐 Kotlin Book.isLocal）', () {
    test('type == 0：按 origin 判定（本地/WebDAV 为真，在线为假）', () {
      expect(
        BookType.isLocalBook(
          const Book(bookUrl: '/tmp/a.txt', origin: 'loc_book'),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/tmp/a.epub',
            origin: 'webDav::https://dav.example.com/books/a.epub',
          ),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/tmp/a.epub',
            origin: 'dav:https://dav.example.com/books/a.epub',
          ),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalBook(
          const Book(bookUrl: 'https://src/1', origin: 'https://src'),
        ),
        isFalse,
      );
    });

    test('type 含 local 位：无论 origin 均为本地书', () {
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/tmp/a.txt',
            origin: 'loc_book',
            bookType: BookType.text | BookType.local,
          ),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/tmp/a.epub',
            origin: 'webDav::https://dav.example.com/books/a.epub',
            bookType: BookType.text | BookType.local,
          ),
        ),
        isTrue,
      );
    });

    test('type 非 0 且无 local 位：即使 origin 是 loc_book 也不是本地书', () {
      // 原版备份导入的 `loc_book::xxx.zip` 等在线书：type 非 0 且无
      // local 位，origin-only 判定会误当本地书（P3-2 回归点）
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: 'loc_book::xxx.zip',
            origin: 'loc_book',
            bookType: BookType.text | BookType.webFile,
          ),
        ),
        isFalse,
      );
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/tmp/a.epub',
            origin: 'webDav::https://dav.example.com/books/a.epub',
            bookType: BookType.text,
          ),
        ),
        isFalse,
      );
    });

    // ===== 批22b P1-1：原版 Kotlin local 位（256）兼容 =====
    test('原版位域 type=264（text|local）判为本地书', () {
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/storage/emulated/0/Books/a.txt',
            origin: 'loc_book',
            bookType: BookType.text | BookType.kotlinLocal,
          ),
        ),
        isTrue,
      );
    });

    test('原版压缩包内书籍 type=776（text|local|archive）判为本地书', () {
      const archiveBit = 512; // Kotlin BookType.archive
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/storage/emulated/0/Books/a.epub',
            origin: 'loc_book::books.zip',
            bookType: BookType.text | BookType.kotlinLocal | archiveBit,
          ),
        ),
        isTrue,
      );
    });

    test('原版位域 type=264 + WebDAV origin 判为本地书', () {
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: '/tmp/remote.epub',
            origin: 'webDav::https://dav.example.com/books/remote.epub',
            originName: 'remote.epub',
            bookType: BookType.text | BookType.kotlinLocal,
          ),
        ),
        isTrue,
      );
    });

    test('在线书 type=8 + http origin 判为非本地书', () {
      expect(
        BookType.isLocalBook(
          const Book(
            bookUrl: 'https://source.example.com/book/1',
            origin: 'https://source.example.com',
            bookType: BookType.text,
          ),
        ),
        isFalse,
      );
    });
  });

  group('BookType.canUpdateToc（更新全部目录过滤）', () {
    test('原版位域 264/776 不入选', () {
      expect(
        BookType.canUpdateToc(
          const Book(bookUrl: '/tmp/a.txt', origin: 'loc_book', bookType: 264),
        ),
        isFalse,
      );
      expect(
        BookType.canUpdateToc(
          const Book(
            bookUrl: '/tmp/a.epub',
            origin: 'loc_book::books.zip',
            bookType: 776,
          ),
        ),
        isFalse,
      );
    });

    test('本仓库 Rust 位域 local(0x1000) 不入选', () {
      expect(
        BookType.canUpdateToc(
          const Book(
            bookUrl: '/tmp/a.txt',
            origin: 'loc_book',
            bookType: BookType.text | BookType.local,
          ),
        ),
        isFalse,
      );
    });

    test('在线书且 canUpdate=true 入选；canUpdate=false 不入选', () {
      expect(
        BookType.canUpdateToc(
          const Book(
            bookUrl: 'https://src/1',
            origin: 'https://src',
            bookType: BookType.text,
          ),
        ),
        isTrue,
      );
      expect(
        BookType.canUpdateToc(
          const Book(
            bookUrl: 'https://src/2',
            origin: 'https://src',
            bookType: BookType.text,
            canUpdate: false,
          ),
        ),
        isFalse,
      );
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

  group('BookType.collapseSlashes（只归一 path，批22b P2-3）', () {
    test('query 内的 http:// 不被折叠', () {
      expect(
        BookType.collapseSlashes('https://host/dav?x=http://y'),
        'https://host/dav?x=http://y',
      );
    });

    test('query / fragment 原样保留，仅折叠 path 重复斜杠', () {
      expect(
        BookType.collapseSlashes('https://host//dav//?x=http://y#f//g'),
        'https://host/dav/?x=http://y#f//g',
      );
    });

    test('userinfo 含 // 不被折叠（保留原值）', () {
      expect(
        BookType.collapseSlashes('https://user:p//w@host//dav//a.epub'),
        'https://user:p//w@host//dav//a.epub',
      );
      expect(
        BookType.collapseSlashes('https://us//er@host//a'),
        'https://us//er@host//a',
      );
    });

    test('协议相对 //host 保留前导双斜杠，只折叠 path', () {
      expect(
        BookType.collapseSlashes('//host//dav//a.epub'),
        '//host/dav/a.epub',
      );
    });

    test('空 host 的 https:// 不被折成 https:', () {
      expect(BookType.collapseSlashes('https://'), 'https://');
      final config = BookType.normalizeWebDavConfig('https://', '');
      expect(config.url, 'https://');
    });

    test('相对路径仍按正则折叠（不触发 Uri 百分号编码）', () {
      expect(BookType.collapseSlashes('/legado//books//'), '/legado/books/');
      expect(BookType.collapseSlashes('my dir//x'), 'my dir/x');
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

    test('基址内部重复斜杠同样折叠（批22 P3）', () {
      expect(
        BookType.joinRemoteUrl('https://dav.example.com//dav//', 'a.epub'),
        'https://dav.example.com/dav/a.epub',
      );
      expect(
        BookType.joinRemoteUrl('https://dav.example.com', 'books//a.epub'),
        'https://dav.example.com/books/a.epub',
      );
    });
  });

  group('BookType.normalizeWebDavConfig（配置直拼无 //，批22 P3）', () {
    test('url 以 / 结尾 + dir 以 / 开头：直拼后恰为单斜杠', () {
      final config = BookType.normalizeWebDavConfig(
        'https://dav.example.com/dav/',
        '/legado/',
      );
      expect(config.url, 'https://dav.example.com/dav');
      expect(config.remoteDir, '/legado/');
      expect('${config.url}${config.remoteDir}books/a.epub',
          'https://dav.example.com/dav/legado/books/a.epub');
    });

    test('dir 为空：remote_dir 归一为 /', () {
      final config =
          BookType.normalizeWebDavConfig('https://dav.example.com/', '');
      expect(config.url, 'https://dav.example.com');
      expect(config.remoteDir, '/');
      expect('${config.url}${config.remoteDir}books/a.epub',
          'https://dav.example.com/books/a.epub');
    });

    test('dir 无首尾斜杠：补成 /dir/ 形态', () {
      final config =
          BookType.normalizeWebDavConfig('https://dav.example.com', 'legado');
      expect(config.url, 'https://dav.example.com');
      expect(config.remoteDir, '/legado/');
    });

    test('dir 内部重复斜杠折叠（保留协议 ://）', () {
      final config = BookType.normalizeWebDavConfig(
        'https://dav.example.com//root//',
        '//legado//books//',
      );
      expect(config.url, 'https://dav.example.com/root');
      expect(config.remoteDir, '/legado/books/');
      expect(
        config.url,
        startsWith('https://'),
        reason: '协议分隔 :// 不得被折叠',
      );
    });
  });

  // [批35b P3-3] 删除源文件准入判定：与 Rust `is_local_storage_book` 同构
  group('BookType.isLocalStorageBook（Rust 真源，删除源文件准入）', () {
    test('type == 0：按 origin 判定（本地/WebDAV 为真）', () {
      expect(
        BookType.isLocalStorageBook(
          const Book(bookUrl: '/tmp/a.txt', origin: 'loc_book'),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalStorageBook(
          const Book(
            bookUrl: '/tmp/a.epub',
            origin: 'webDav::https://dav.example.com/books/a.epub',
          ),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalStorageBook(
          const Book(bookUrl: 'https://src/1', origin: 'https://src'),
        ),
        isFalse,
      );
    });

    test('type 非 0 含 local 位：为真（双位域兼容）', () {
      expect(
        BookType.isLocalStorageBook(
          const Book(
            bookUrl: '/tmp/a.txt',
            origin: 'https://src',
            bookType: BookType.text | BookType.local,
          ),
        ),
        isTrue,
      );
      expect(
        BookType.isLocalStorageBook(
          const Book(
            bookUrl: '/tmp/a.txt',
            origin: 'https://src',
            bookType: BookType.text | BookType.kotlinLocal,
          ),
        ),
        isTrue,
      );
    });

    test('type 非 0 无 local 位但 origin 为 loc_book/WebDAV：为真（Rust 分支）', () {
      // isLocalBook 在此为 false（只看 local 位），isLocalStorageBook 为 true
      // —— 与 Rust 删除原文件的准入判断一致，弹窗不得漏显「删除源文件」。
      const localOriginBook = Book(
        bookUrl: '/tmp/a.epub',
        origin: 'loc_book',
        bookType: BookType.text,
      );
      expect(BookType.isLocalBook(localOriginBook), isFalse);
      expect(BookType.isLocalStorageBook(localOriginBook), isTrue);

      const webdavOriginBook = Book(
        bookUrl: '/tmp/a.epub',
        origin: 'webDav::https://dav.example.com/books/a.epub',
        bookType: BookType.text,
      );
      expect(BookType.isLocalStorageBook(webdavOriginBook), isTrue);
    });

    test('在线书（type 非 0、非 local 位、http origin）为假', () {
      expect(
        BookType.isLocalStorageBook(
          const Book(
            bookUrl: 'https://src/1',
            origin: 'https://src',
            bookType: BookType.text,
          ),
        ),
        isFalse,
      );
    });

    test('origin 前后空白不影响判定（与 Rust trim 一致）', () {
      expect(
        BookType.isLocalStorageBook(
          const Book(bookUrl: '/tmp/a.txt', origin: ' loc_book '),
        ),
        isTrue,
      );
    });
  });
}
