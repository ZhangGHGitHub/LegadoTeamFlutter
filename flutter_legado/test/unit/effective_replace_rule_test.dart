// 批7a P2-1 单元测试：替换净化生效值与全局默认 provider
//
// 背景：菜单勾选态/切换取反此前只看 readConfig.useReplaceRule ?? true，
// 与 Rust 三级语义（显式值 → 图片/epub 默认关 → 全局 replaceEnableDefault）
// 不一致。本测试固定 effectiveReplaceRuleEnabled 与 provider 读取口径。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/widgets/reader/reader_action_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Book textBook({ReadConfig? config}) => Book(
        bookUrl: 'https://book.example.com/1',
        origin: 'https://source.example.com',
        originName: 'book.txt',
        name: '普通书',
        bookType: BookType.text,
        readConfig: config,
      );

  group('effectiveReplaceRuleEnabled（对齐 Rust use_replace_rule_for_book）', () {
    test('显式 false 即使全局 true 仍不启用', () {
      expect(
        effectiveReplaceRuleEnabled(
          textBook(config: const ReadConfig(useReplaceRule: false)),
          true,
        ),
        isFalse,
      );
    });

    test('显式 true 即使全局 false / 图片书也启用（显式优先）', () {
      expect(
        effectiveReplaceRuleEnabled(
          textBook(config: const ReadConfig(useReplaceRule: true)),
          false,
        ),
        isTrue,
      );
      final imageWithExplicitTrue = Book(
        bookUrl: 'books/a.cbz',
        origin: BookType.localTag,
        originName: 'a.cbz',
        bookType: BookType.local | BookType.image,
        readConfig: const ReadConfig(useReplaceRule: true),
      );
      expect(effectiveReplaceRuleEnabled(imageWithExplicitTrue, true), isTrue);
    });

    test('普通书 null 配置跟随全局默认', () {
      expect(effectiveReplaceRuleEnabled(textBook(), false), isFalse);
      expect(effectiveReplaceRuleEnabled(textBook(), true), isTrue);
      expect(effectiveReplaceRuleEnabled(null, false), isFalse);
    });

    test('图片类书 null 配置默认关闭', () {
      final image = Book(
        bookUrl: 'books/a.cbz',
        origin: BookType.localTag,
        originName: 'a.cbz',
        bookType: BookType.local | BookType.image,
      );
      expect(effectiveReplaceRuleEnabled(image, true), isFalse);
    });

    test('本地 epub null 配置默认关闭（originName 为准）', () {
      final epub = Book(
        bookUrl: 'books/a',
        origin: BookType.localTag,
        originName: 'a.epub',
        bookType: BookType.local,
      );
      expect(effectiveReplaceRuleEnabled(epub, true), isFalse);
    });

    test('本地书 originName 为空即使 bookUrl 以 .epub 结尾也不判定 epub', () {
      final epub = Book(
        bookUrl: 'books/a.EPUB',
        origin: BookType.localTag,
        originName: '',
        bookType: BookType.local,
      );
      expect(
        effectiveReplaceRuleEnabled(epub, true),
        isTrue,
        reason: '与 Rust/Kotlin 一致只看 originName，不回退 bookUrl',
      );
    });

    test('在线书 bookUrl 以 .epub 结尾不算本地 epub', () {
      final online = Book(
        bookUrl: 'https://book.example.com/a.epub',
        origin: 'https://source.example.com',
        originName: '',
        bookType: BookType.text,
      );
      expect(effectiveReplaceRuleEnabled(online, true), isTrue);
    });
  });

  group('replaceEnableDefaultProvider', () {
    test('读取 prefs：false → false', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        await container.read(replaceEnableDefaultProvider.future),
        isFalse,
      );
    });

    test('读取 prefs：缺省 → true', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        await container.read(replaceEnableDefaultProvider.future),
        isTrue,
      );
    });
  });
}
