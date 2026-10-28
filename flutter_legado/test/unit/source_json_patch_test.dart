// 批28：源保存「原 JSON 补丁」回归测试（先红后绿）
//
// 缺陷根因：源编辑器 `_buildSource()` 用模型重建整个 BookSource / 规则对象，
// Dart 模型未建模的规则键（如 `ruleContent.contentBatch` / `maxBatchSize`，
// 以及未来新增的原版字段）在 `fromJson → toJson` 往返中被丢弃，用户编辑保存
// 一次即静默丢字段。修复方式：以原始 JSON 为底做深合补丁，未编辑键原样保留。
//
// 编写：全栈工程师（批28） ｜ 2026-10-28

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/utils/source_json_patch.dart';

void main() {
  group('patchSourceJson 原 JSON 补丁', () {
    test('未建模的顶层与规则字段原样保留', () {
      final original = <String, dynamic>{
        'bookSourceUrl': 'https://a.example',
        'bookSourceName': '旧名',
        'ruleContent': <String, dynamic>{
          'content': '.old@text',
          // Dart 模型未建模的原版批量正文规则
          'contentBatch': 'batch@js:result',
          'maxBatchSize': 20,
          // 未来新增字段同样应保留
          'futureRuleKey': 'keep-me',
        },
      };
      // 编辑后的模型 JSON：只有表单建模过的键
      final edited = <String, dynamic>{
        'bookSourceUrl': 'https://a.example',
        'bookSourceName': '新名',
        'ruleContent': <String, dynamic>{'content': '.new@text'},
      };

      final patched = patchSourceJson(original, edited);

      expect(patched['bookSourceName'], '新名', reason: '编辑值应覆盖原始值');
      final rule = patched['ruleContent'] as Map<String, dynamic>;
      expect(rule['content'], '.new@text', reason: '编辑过的规则键应更新');
      expect(rule['contentBatch'], 'batch@js:result', reason: '未编辑键必须保留');
      expect(rule['maxBatchSize'], 20, reason: '未编辑键必须保留');
      expect(rule['futureRuleKey'], 'keep-me', reason: '未知键必须保留');
    });

    test('显式 null 表示清空（不被原始值补偿）', () {
      final original = <String, dynamic>{
        'bookSourceGroup': '分组A',
        'ruleContent': <String, dynamic>{
          'contentBatch': 'batch',
          'maxBatchSize': 9,
        },
      };
      final edited = <String, dynamic>{
        'bookSourceGroup': null,
        'ruleContent': <String, dynamic>{'contentBatch': null},
      };

      final patched = patchSourceJson(original, edited);

      expect(patched['bookSourceGroup'], isNull, reason: 'null 应清空原始值');
      final rule = patched['ruleContent'] as Map<String, dynamic>;
      expect(rule['contentBatch'], isNull, reason: 'null 应清空原始值');
      expect(rule['maxBatchSize'], 9, reason: '未出现的键仍应保留');
    });

    test('非 Map 值（列表/标量）以编辑值为准，不做元素级合并', () {
      final original = <String, dynamic>{
        'exploreUrl': 'old',
        'ruleSearch': <String, dynamic>{'bookList': 'a'},
      };
      final edited = <String, dynamic>{
        'exploreUrl': 'new',
        'ruleSearch': <String, dynamic>{'bookList': 'b'},
        'extraList': <dynamic>[1, 2, 3],
      };

      final patched = patchSourceJson(original, edited);

      expect(patched['exploreUrl'], 'new');
      expect(patched['extraList'], <dynamic>[1, 2, 3]);
      expect((patched['ruleSearch'] as Map<String, dynamic>)['bookList'], 'b');
    });

    test('原始 JSON 缺失/null 时退化为编辑值', () {
      final edited = <String, dynamic>{'bookSourceUrl': 'u'};
      expect(patchSourceJson(null, edited), edited);
    });

    test('不修改入参（纯函数）', () {
      final original = <String, dynamic>{
        'ruleContent': <String, dynamic>{'contentBatch': 'batch'},
      };
      final edited = <String, dynamic>{
        'ruleContent': <String, dynamic>{'content': 'x'},
      };
      final snapshotOriginal = Map<String, dynamic>.from(
        original['ruleContent'] as Map,
      );
      patchSourceJson(original, edited);
      expect(original['ruleContent'], snapshotOriginal);
    });
  });

  group('BookSourceRawCache 原始 JSON 缓存', () {
    setUp(BookSourceRawCache.clear);

    test('按 bookSourceUrl 索引列表 JSON，并在补丁后可回写', () {
      BookSourceRawCache.rememberAllJson(
        '[{"bookSourceUrl":"https://a.example","bookSourceName":"A",'
        '"ruleContent":{"contentBatch":"batch","maxBatchSize":5}}]',
      );
      final raw = BookSourceRawCache.lookup('https://a.example');
      expect(raw, isNotNull);
      expect(
        (raw!['ruleContent'] as Map<String, dynamic>)['contentBatch'],
        'batch',
      );

      // 回写补丁结果后再次读取应看到合并值
      final patched = patchSourceJson(raw, <String, dynamic>{
        'bookSourceUrl': 'https://a.example',
        'bookSourceName': 'A2',
      });
      BookSourceRawCache.remember(patched);
      expect(
        BookSourceRawCache.lookup('https://a.example')!['bookSourceName'],
        'A2',
      );
      expect(
        (BookSourceRawCache.lookup('https://a.example')!['ruleContent']
            as Map<String, dynamic>)['contentBatch'],
        'batch',
      );
    });

    test('非法 JSON / 空串不抛错且不污染缓存', () {
      BookSourceRawCache.rememberAllJson('');
      BookSourceRawCache.rememberAllJson('not-json');
      BookSourceRawCache.rememberAllJson('{"not":"array"}');
      expect(BookSourceRawCache.lookup('https://a.example'), isNull);
    });

    test('无 bookSourceUrl 的条目跳过', () {
      BookSourceRawCache.rememberAllJson(
        '[{"bookSourceName":"无 URL"},{"bookSourceUrl":"u2","bookSourceName":"B"}]',
      );
      expect(BookSourceRawCache.lookup(''), isNull);
      expect(BookSourceRawCache.lookup('u2'), isNotNull);
    });
  });
}
