import 'package:flutter_legado/src/services/deep_link_service.dart';
import 'package:flutter_legado/src/utils/legado_deep_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// P1-4 外部书籍文件打开断链修复 —— URI 识别分支单测
///
/// 覆盖：
/// 1. VIEW intent dataString 分类（legado:// 深链 / content:// file:// 书籍
///    文件 / 其他协议不消费），与 legado:// 深链互不干扰；
/// 2. 深链识别既有语义回归（isImportScheme 不受新分类影响）；
/// 3. 确认框文件名推导（落盘路径 → 文件名，跨平台分隔符）。
void main() {
  group('LegadoDeepLink.classifyIncomingUri（P1-4 VIEW intent 分类）', () {
    test('legado:// 归为关联导入深链', () {
      expect(
        LegadoDeepLink.classifyIncomingUri(
          'legado://import/bookSource?src=https://example.com/s.json',
        ),
        IncomingUriKind.importScheme,
      );
    });

    test('yuedu:// 归为关联导入深链', () {
      expect(
        LegadoDeepLink.classifyIncomingUri('yuedu://import/rssSource?src=x'),
        IncomingUriKind.importScheme,
      );
    });

    test('content:// 归为外部书籍文件（原被静默丢弃的断链形态）', () {
      expect(
        LegadoDeepLink.classifyIncomingUri(
          'content://com.android.externalstorage.documents/document/primary%3ADownload/book.epub',
        ),
        IncomingUriKind.bookFile,
      );
    });

    test('file:// 归为外部书籍文件', () {
      expect(
        LegadoDeepLink.classifyIncomingUri('file:///storage/emulated/0/a.txt'),
        IncomingUriKind.bookFile,
      );
    });

    test('http(s) 与空串不消费', () {
      expect(
        LegadoDeepLink.classifyIncomingUri('https://example.com/book.epub'),
        IncomingUriKind.none,
      );
      expect(LegadoDeepLink.classifyIncomingUri(''), IncomingUriKind.none);
      expect(LegadoDeepLink.classifyIncomingUri(null), IncomingUriKind.none);
      expect(
        LegadoDeepLink.classifyIncomingUri('mailto:a@b.c'),
        IncomingUriKind.none,
      );
    });

    test('与 legado:// 深链互不干扰：isImportScheme 判定不受影响', () {
      // 文件 URI 不是深链
      expect(
        LegadoDeepLink.isImportScheme('content://a/b.epub'),
        isFalse,
      );
      // 深链解析仍正常（回归既有用例语义）
      expect(
        LegadoDeepLink.isImportScheme('legado://import/theme?src=x'),
        isTrue,
      );
    });
  });

  group('DeepLinkService 文件导入确认框文件名推导', () {
    test('Windows 落盘路径取末段文件名', () {
      expect(
        DeepLinkService.displayNameFromPath(
            r'D:\app\files\external_import\三国演义.epub'),
        '三国演义.epub',
      );
    });

    test('POSIX 落盘路径取末段文件名（Android 实际形态）', () {
      expect(
        DeepLinkService.displayNameFromPath(
            '/data/user/0/io.legado.flutter/files/external_import/斗破.txt'),
        '斗破.txt',
      );
    });

    test('无分隔符的裸路径原样返回', () {
      expect(DeepLinkService.displayNameFromPath('book.pdf'), 'book.pdf');
    });
  });
}
