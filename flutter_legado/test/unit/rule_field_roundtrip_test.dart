// 批28：原版规则字段往返保真（Dart 模型层）
//
// 覆盖：
// - HighlightRule.group（原版 `HighlightRule.group`，DB 列 `"group" TEXT DEFAULT ''`）
//   在 fromJson / toJson / toExportJson 三态往返；
// - RssSource.enableReadRecord（原版 `RssSource.enableReadRecord`，缺键默认 true）
//   与 nextContentUrl（表单未展示但 Rust 已建模）的 JSON 往返。
//
// 编写：全栈工程师（批28） ｜ 2026-10-28

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/highlight_rules/highlight_rules_state.dart';

void main() {
  group('HighlightRule.group', () {
    test('fromJson → toJson 保留分组', () {
      final rule = HighlightRule.fromJson(<String, dynamic>{
        'id': 7,
        'uuid': '66666666-6666-4666-8666-666666666666',
        'name': '分组规则',
        'pattern': '关键词',
        'group': '重要标注',
      });
      expect(rule.group, '重要标注');
      expect(rule.toJson()['group'], '重要标注');
    });

    test('缺键 / 显式 null → null，且不改写为默认分组', () {
      final missing = HighlightRule.fromJson(<String, dynamic>{
        'pattern': '关键词',
      });
      expect(missing.group, isNull);
      expect(missing.toJson()['group'], isNull);

      final explicitNull = HighlightRule.fromJson(<String, dynamic>{
        'pattern': '关键词',
        'group': null,
      });
      expect(explicitNull.group, isNull);
    });

    test('toExportJson（原版备份形态）同样带 group 且 order 归一', () {
      const rule = HighlightRule(pattern: 'p', sortOrder: 3, group: '导出分组');
      final export = rule.toExportJson();
      expect(export['group'], '导出分组');
      expect(export['order'], 3);
      expect(export.containsKey('sortOrder'), isFalse);
      // 导出 JSON 可被自身解析回来（关联导入路径）
      final decoded = HighlightRule.fromJson(
        jsonDecode(jsonEncode(export)) as Map<String, dynamic>,
      );
      expect(decoded.group, '导出分组');
      expect(decoded.sortOrder, 3);
    });

    test('copyWith 保留 group', () {
      const rule = HighlightRule(pattern: 'p', group: '原分组');
      expect(rule.copyWith(name: '改名').group, '原分组');
    });
  });

  group('RssSource 新字段', () {
    test('enableReadRecord：缺键默认 true，显式 false 保留', () {
      final missing = RssSource.fromJson(<String, dynamic>{
        'sourceUrl': 'https://rss.example.com',
        'sourceName': 'RSS',
      });
      expect(missing.enableReadRecord, isTrue);

      final disabled = RssSource.fromJson(<String, dynamic>{
        'sourceUrl': 'https://rss.example.com',
        'sourceName': 'RSS',
        'enableReadRecord': false,
      });
      expect(disabled.enableReadRecord, isFalse);
      // toJson 键名对齐 Room 列名
      expect(disabled.toJson()['enableReadRecord'], isFalse);
    });

    test('nextContentUrl 往返（RSS 编辑保存不得丢该列）', () {
      final source = RssSource.fromJson(<String, dynamic>{
        'sourceUrl': 'https://rss.example.com',
        'sourceName': 'RSS',
        'nextContentUrl': '.next@href',
      });
      expect(source.nextContentUrl, '.next@href');
      expect(source.toJson()['nextContentUrl'], '.next@href');
      // 再次解析（模拟 Rust 读回 → Dart 解码）等价
      final reparsed = RssSource.fromJson(
        jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
      );
      expect(reparsed.nextContentUrl, '.next@href');
      expect(reparsed.enableReadRecord, isTrue);
    });

    test('编辑重建模型时透传既有新字段（模拟 _buildSource 语义）', () {
      final old = RssSource.fromJson(<String, dynamic>{
        'sourceUrl': 'u',
        'sourceName': '旧名',
        'enableReadRecord': false,
        'nextContentUrl': '.next@href',
      });
      // 与 rss_source_edit_screen._buildSource 相同的透传写法
      final rebuilt = RssSource(
        sourceUrl: old.sourceUrl,
        sourceName: '新名',
        enabled: old.enabled,
        enableReadRecord: old.enableReadRecord,
        nextContentUrl: old.nextContentUrl,
      );
      expect(rebuilt.enableReadRecord, isFalse);
      expect(rebuilt.nextContentUrl, '.next@href');
      expect(rebuilt.sourceName, '新名');
    });
  });
}
