/// 私密书改名别名存储测试（审查 P2-4）
///
/// 覆盖：登记去重、按 bookUrl 删除（书籍删除入口）、clear（清空记录入口）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/privacy_record_alias_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = PrivacyRecordAliasStore();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> registerAliases() async {
    await store.register(oldName: '旧书一', oldAuthor: '甲', bookUrl: 'u1');
    await store.register(oldName: '旧书二', oldAuthor: '乙', bookUrl: 'u2');
  }

  test('按 bookUrl 删除：只移除该书的别名，其它条目保留', () async {
    await registerAliases();

    await store.removeByBookUrl('u1');

    final aliases = await store.load();
    expect(aliases.map((a) => a.bookUrl), ['u2']);
    expect(aliases.single.name, '旧书二');
  });

  test('批量按 bookUrl 删除：一次移除多本', () async {
    await registerAliases();

    await store.removeByBookUrls(['u1', 'u2']);

    expect(await store.load(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(PrefKeys.privacyRecordAliases),
      isNull,
      reason: '删空后不应留下空数组/旧明文',
    );
  });

  test('clear：清空全部别名并从偏好移除键', () async {
    await registerAliases();

    await store.clear();

    expect(await store.load(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(PrefKeys.privacyRecordAliases), isFalse);
  });

  test('删除不存在的 bookUrl：不写坏既有别名', () async {
    await registerAliases();

    await store.removeByBookUrl('u404');

    expect((await store.load()).map((a) => a.bookUrl), ['u1', 'u2']);
  });
}
