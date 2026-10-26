import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/utils/legado_deep_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批16d：外部文件 VIEW 分流分类单测
///
/// 覆盖：
/// 1. 后缀分类（书籍 / JSON / 压缩包 / 不支持），大小写与无后缀边界；
/// 2. 按原版 FileAssociationViewModel.dispatch 顺序的分类（压缩包优先、
///    JSON 内容嗅探优先于书籍后缀、.json 后缀但内容非 JSON → 不支持）；
/// 3. JSON 内容嗅探（对齐原版 InputStreamExtensions.looksLikeJson）；
/// 4. 关联导入类型识别补齐 highlightRule / autoTask 且既有类型不回归。
void main() {
  group('LegadoDeepLink 外部文件后缀分类', () {
    test('书籍文件后缀全部归为 bookFile', () {
      const names = [
        'book.txt',
        'book.epub',
        'book.umd',
        'book.pdf',
        'book.mobi',
        'book.azw',
        'book.azw3',
      ];
      for (final name in names) {
        expect(
          LegadoDeepLink.classifyFileExtension(name),
          IncomingFileKind.bookFile,
          reason: name,
        );
        expect(LegadoDeepLink.isBookFilePath(name), isTrue, reason: name);
      }
    });

    test('书籍后缀大小写不敏感', () {
      expect(
        LegadoDeepLink.classifyFileExtension('BOOK.EPUB'),
        IncomingFileKind.bookFile,
      );
      expect(
        LegadoDeepLink.classifyFileExtension('book.TXT'),
        IncomingFileKind.bookFile,
      );
      expect(
        LegadoDeepLink.classifyFileExtension('book.Azw3'),
        IncomingFileKind.bookFile,
      );
    });

    test('JSON 后缀归为 json', () {
      expect(
        LegadoDeepLink.classifyFileExtension('sources.json'),
        IncomingFileKind.json,
      );
      expect(
        LegadoDeepLink.classifyFileExtension('SOURCES.JSON'),
        IncomingFileKind.json,
      );
    });

    test('压缩包后缀归为 archive', () {
      for (final name in ['a.zip', 'a.rar', 'a.7z', 'A.ZIP', 'A.7Z']) {
        expect(
          LegadoDeepLink.classifyFileExtension(name),
          IncomingFileKind.archive,
          reason: name,
        );
        expect(LegadoDeepLink.isArchivePath(name), isTrue, reason: name);
      }
    });

    test('7z 单独可识别（供服务层给「暂不支持」提示）', () {
      expect(LegadoDeepLink.isSevenZipPath('a.7z'), isTrue);
      expect(LegadoDeepLink.isSevenZipPath('a.7Z'), isTrue);
      expect(LegadoDeepLink.isSevenZipPath('a.zip'), isFalse);
      expect(LegadoDeepLink.isSevenZipPath('a.rar'), isFalse);
    });

    test('未知后缀 / 无后缀 / 空串归为 unsupported', () {
      for (final name in [
        'a.docx',
        'a.apk',
        'a',
        '/path/to/noext',
        'a.',
        '',
      ]) {
        expect(
          LegadoDeepLink.classifyFileExtension(name),
          IncomingFileKind.unsupported,
          reason: name,
        );
      }
    });

    test('路径取末段后缀（content:// 落盘路径形态）', () {
      expect(
        LegadoDeepLink.classifyFileExtension(
          '/data/user/0/io.legado.flutter/files/external_import/三国演义.epub',
        ),
        IncomingFileKind.bookFile,
      );
      expect(
        LegadoDeepLink.classifyFileExtension(
          r'D:\app\files\external_import\sources.json',
        ),
        IncomingFileKind.json,
      );
    });
  });

  group('LegadoDeepLink.classifyFile（原版 dispatch 顺序）', () {
    test('压缩包优先于 JSON 内容嗅探', () {
      expect(
        LegadoDeepLink.classifyFile('a.zip', jsonContent: true),
        IncomingFileKind.archive,
      );
    });

    test('JSON 内容优先于书籍后缀（txt 里装 JSON 也走关联导入）', () {
      expect(
        LegadoDeepLink.classifyFile('a.txt', jsonContent: true),
        IncomingFileKind.json,
      );
      expect(
        LegadoDeepLink.classifyFile('noext', jsonContent: true),
        IncomingFileKind.json,
      );
    });

    test('.json 后缀但内容不是 JSON → 不支持（对齐原版 looksLikeJson）', () {
      expect(
        LegadoDeepLink.classifyFile('sources.json', jsonContent: false),
        IncomingFileKind.unsupported,
      );
    });

    test('书籍后缀 + 非 JSON → bookFile', () {
      expect(
        LegadoDeepLink.classifyFile('book.epub', jsonContent: false),
        IncomingFileKind.bookFile,
      );
    });

    test('未知后缀 + 非 JSON → unsupported', () {
      expect(
        LegadoDeepLink.classifyFile('a.bin', jsonContent: false),
        IncomingFileKind.unsupported,
      );
    });
  });

  group('LegadoDeepLink.looksLikeJsonBytes（原版 looksLikeJson）', () {
    test('对象与数组起始视为 JSON', () {
      expect(LegadoDeepLink.looksLikeJsonBytes('{"a":1}'.codeUnits), isTrue);
      expect(LegadoDeepLink.looksLikeJsonBytes('[1,2]'.codeUnits), isTrue);
    });

    test('前导空白不影响判定', () {
      expect(
        LegadoDeepLink.looksLikeJsonBytes(' \t\r\n  ['.codeUnits),
        isTrue,
      );
    });

    test('其他内容与空内容不是 JSON', () {
      expect(LegadoDeepLink.looksLikeJsonBytes('hello'.codeUnits), isFalse);
      expect(LegadoDeepLink.looksLikeJsonBytes(''.codeUnits), isFalse);
      expect(LegadoDeepLink.looksLikeJsonBytes('  \n\t'.codeUnits), isFalse);
    });

    test('UTF-8 BOM 起始不是 JSON（原版同样不跳过 BOM）', () {
      expect(LegadoDeepLink.looksLikeJsonBytes([0xEF, 0xBB, 0xBF, 0x7B]),
          isFalse);
    });

    test('嗅探上限 64KB（超限内容不再扫描）', () {
      final padding = List<int>.filled(LegadoDeepLink.jsonSniffLimit, 0x20);
      expect(LegadoDeepLink.looksLikeJsonBytes([...padding, 0x7B]), isFalse);
    });
  });

  group('AssociationNotifier.detectType（对齐 BaseAssociationViewModel）', () {
    test('highlightRule：type 字段命中', () {
      expect(
        AssociationNotifier.detectType({
          'type': 'highlightRule',
          'rules': <dynamic>[],
        }),
        ImportType.highlightRule,
      );
    });

    test('autoTask：cron + script 命中', () {
      expect(
        AssociationNotifier.detectType({
          'name': '每日更新',
          'cron': '0 0 * * *',
          'script': '<js>java.log("x")</js>',
        }),
        ImportType.autoTask,
      );
    });

    test('既有类型识别不回归', () {
      expect(
        AssociationNotifier.detectType({'bookSourceUrl': 'https://a'}),
        ImportType.bookSource,
      );
      expect(
        AssociationNotifier.detectType({'sourceUrl': 'https://a'}),
        ImportType.rssSource,
      );
      expect(
        AssociationNotifier.detectType({'pattern': 'a'}),
        ImportType.replaceRule,
      );
      expect(
        AssociationNotifier.detectType({'themeName': 't'}),
        ImportType.theme,
      );
      expect(
        AssociationNotifier.detectType({'showRule': 'r'}),
        ImportType.dictRule,
      );
      expect(
        AssociationNotifier.detectType({'name': 'n', 'rule': 'r'}),
        ImportType.txtTocRule,
      );
      expect(
        AssociationNotifier.detectType({'name': 'n', 'url': 'https://a'}),
        ImportType.httpTts,
      );
    });

    test('原版判定顺序：name+rule 优先于 cron+script', () {
      expect(
        AssociationNotifier.detectType({
          'name': 'n',
          'rule': 'r',
          'cron': '0 0 * * *',
          'script': 'x',
        }),
        ImportType.txtTocRule,
      );
    });

    test('无法识别返回 null', () {
      expect(AssociationNotifier.detectType({'foo': 'bar'}), isNull);
    });
  });
}
