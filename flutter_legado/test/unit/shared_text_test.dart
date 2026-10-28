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

    // 批25b P3-2：超长文本（按 UTF-8 字节）拒绝解析
    test('超过 1 MiB → tooLarge，恰好 1 MiB 仍进入常规分流', () {
      final over = String.fromCharCodes(
        List<int>.filled(maxSharedTextBytes + 1, 0x61),
      );
      expect(classifySharedText(over), SharedTextKind.tooLarge);

      final exact = String.fromCharCodes(
        List<int>.filled(maxSharedTextBytes, 0x61),
      );
      expect(classifySharedText(exact), isNot(SharedTextKind.tooLarge));

      // 多字节字符按 UTF-8 计：35 万个汉字 ≈ 1.05 MiB
      final chinese = String.fromCharCodes(List<int>.filled(350000, 0x4E2D));
      expect(classifySharedText(chinese), SharedTextKind.tooLarge);
    });

    // 批25b P3-2：超深 JSON 拒绝（防御 jsonDecode 递归栈溢出）
    test('JSON 嵌套深度：64 层放行、65 层拒绝', () {
      String nested(int depth) =>
          '${List<String>.filled(depth, '[').join()}'
          '${List<String>.filled(depth, ']').join()}';

      expect(classifySharedText(nested(maxJsonDepth)), SharedTextKind.json);
      expect(
        classifySharedText(nested(maxJsonDepth + 1)),
        SharedTextKind.tooDeepJson,
      );
    });

    test('字符串字面量内的括号不计入 JSON 深度', () {
      final brackets = List<String>.filled(maxJsonDepth + 10, '[').join();
      final json = '{"a":"$brackets"}';
      expect(classifySharedText(json), SharedTextKind.json);
    });
  });
}
