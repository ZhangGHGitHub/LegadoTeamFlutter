// 外部分享文本分流单测（批25）
import 'package:flutter_legado/src/utils/shared_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifySharedText', () {
    test('分享口令优先于 URL/JSON', () {
      const passphrase =
          '复制口令到阅读导入#L:example电com/a！sy©0¥Legado^';
      expect(
        classifySharedText(passphrase),
        SharedTextKind.passphrase,
      );
      // 口令内嵌 URL 也不能被误判为 httpUrl
      expect(
        classifySharedText('前缀 $passphrase 后缀'),
        SharedTextKind.passphrase,
      );
    });

    test('http / https 链接', () {
      expect(
        classifySharedText('https://example.com/a.json'),
        SharedTextKind.httpUrl,
      );
      expect(
        classifySharedText('  http://example.com/a  '),
        SharedTextKind.httpUrl,
      );
      expect(
        classifySharedText('HTTPS://EXAMPLE.COM/A'),
        SharedTextKind.httpUrl,
      );
    });

    test('legado / yuedu 导入协议', () {
      expect(
        classifySharedText('legado://import/bookSource?src=https://a'),
        SharedTextKind.importScheme,
      );
      expect(
        classifySharedText('yuedu://import/rssSource?src=https://a'),
        SharedTextKind.importScheme,
      );
    });

    test('合法 JSON（对象/数组）', () {
      expect(
        classifySharedText('{"bookSourceName":"A"}'),
        SharedTextKind.json,
      );
      expect(
        classifySharedText('  [{"name":"A"}]'),
        SharedTextKind.json,
      );
    });

    test('非法 JSON / 普通文本 → unsupported', () {
      expect(classifySharedText('{not json'), SharedTextKind.unsupported);
      expect(classifySharedText('hello world'), SharedTextKind.unsupported);
      expect(classifySharedText(''), SharedTextKind.unsupported);
      expect(classifySharedText('   '), SharedTextKind.unsupported);
    });
  });
}
