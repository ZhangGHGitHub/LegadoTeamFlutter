// 批28：源保存「原 JSON 补丁」回归测试（先红后绿）
//
// 缺陷根因：源编辑器 `_buildSource()` 用模型重建整个 BookSource / 规则对象，
// Dart 模型未建模的规则键（如 `ruleContent.contentBatch` / `maxBatchSize`，
// 以及未来新增的原版字段）在 `fromJson → toJson` 往返中被丢弃，用户编辑保存
// 一次即静默丢字段。修复方式：以原始 JSON 为底做深合补丁，未编辑键原样保留。
//
// 编写：全栈工程师（批28） ｜ 2026-10-28

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
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

    /// 批28b（P3-7）：删除书源后缓存应可单条移除；达上限按 FIFO 淘汰最旧
    test('forget 单条移除与 maxEntries 上限淘汰', () {
      BookSourceRawCache.remember({
        'bookSourceUrl': 'https://forget.example',
        'bookSourceName': '待删',
      });
      expect(BookSourceRawCache.lookup('https://forget.example'), isNotNull);
      BookSourceRawCache.forget('https://forget.example');
      expect(
        BookSourceRawCache.lookup('https://forget.example'),
        isNull,
        reason: '删除书源后不得继续用旧原文做补丁底稿',
      );

      // 填满上限后再插入新键：最旧条目被淘汰、新条目保留
      for (var i = 0; i < BookSourceRawCache.maxEntries; i++) {
        BookSourceRawCache.remember({
          'bookSourceUrl': 'https://cap.example/$i',
          'bookSourceName': '源$i',
        });
      }
      BookSourceRawCache.remember({
        'bookSourceUrl': 'https://cap.example/new',
        'bookSourceName': '新源',
      });
      expect(
        BookSourceRawCache.lookup('https://cap.example/0'),
        isNull,
        reason: '超上限应淘汰最旧条目',
      );
      expect(BookSourceRawCache.lookup('https://cap.example/new'), isNotNull);
    });
  });

  group('buildPatchedSourcePayload 保存载荷接线', () {
    /// 批28b（P2-2③）：RustApi.updateBookSource 使用的载荷构造函数，
    /// 模型往返丢掉的 `ruleContent.contentBatch/maxBatchSize` 必须由原始 JSON 补回
    test('模型往返后仍保留原始批量正文规则与未知键', () async {
      final original = <String, dynamic>{
        'bookSourceUrl': 'https://payload.example',
        'bookSourceName': '旧名',
        'ruleContent': <String, dynamic>{
          'content': '.old@text',
          'contentBatch': 'batch@js:result',
          'maxBatchSize': 20,
          'futureRuleKey': 'keep-me',
        },
      };

      // 前置：Dart 模型确实未建模 contentBatch/maxBatchSize，往返后丢失
      final edited = BookSource.fromJson(
        original,
      ).copyWith(bookSourceName: '新名').toJson();
      expect(
        (edited['ruleContent'] as Map<String, dynamic>).containsKey(
          'contentBatch',
        ),
        isFalse,
        reason: '前置条件：模型未建模该键',
      );

      final payload = await buildPatchedSourcePayload(
        edited,
        resolveOriginal: (url) async {
          expect(url, 'https://payload.example', reason: '应按编辑后的 URL 查原始 JSON');
          return original;
        },
      );

      expect(payload['bookSourceName'], '新名', reason: '编辑值应覆盖原始值');
      final rule = payload['ruleContent'] as Map<String, dynamic>;
      expect(rule['content'], '.old@text');
      expect(
        rule['contentBatch'],
        'batch@js:result',
        reason: '载荷必须保留 contentBatch',
      );
      expect(rule['maxBatchSize'], 20, reason: '载荷必须保留 maxBatchSize');
      expect(rule['futureRuleKey'], 'keep-me', reason: '未建模的未知键也必须保留');
    });

    test('原始 JSON 未命中时退化为编辑值', () async {
      final edited = <String, dynamic>{
        'bookSourceUrl': 'https://miss.example',
        'bookSourceName': '新源',
      };
      final payload = await buildPatchedSourcePayload(
        edited,
        resolveOriginal: (_) async => null,
      );
      expect(payload, edited);
    });

    /// 批31b P3-1：`bookshelfCount` 是 Rust `source_list` 的派生书架数，
    /// 不属于书源持久化形状。补丁底稿（原始 JSON 缓存）命中时不得把该键
    /// 带进 `sourceUpdate` 载荷（否则源保存/导出/备份被派生值污染）。
    test('派生字段 bookshelfCount 不进入补丁载荷', () async {
      final original = <String, dynamic>{
        'bookSourceUrl': 'https://count.example',
        'bookSourceName': '旧名',
        // Rust getBookSources 平铺的派生计数
        'bookshelfCount': 5,
      };
      final edited = <String, dynamic>{
        'bookSourceUrl': 'https://count.example',
        'bookSourceName': '新名',
      };

      final payload = await buildPatchedSourcePayload(
        edited,
        resolveOriginal: (_) async => original,
      );

      expect(payload['bookSourceName'], '新名');
      expect(
        payload.containsKey('bookshelfCount'),
        isFalse,
        reason: '派生计数字段必须从保存载荷剔除',
      );

      // 编辑值若携带该键同样剔除（防御非模型来源的调用方）
      final payload2 = await buildPatchedSourcePayload(<String, dynamic>{
        'bookSourceUrl': 'https://count.example',
        'bookshelfCount': 9,
      }, resolveOriginal: (_) async => null);
      expect(payload2.containsKey('bookshelfCount'), isFalse);
    });
  });
}
