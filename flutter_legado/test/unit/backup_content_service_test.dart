// C1 逐表备份忽略（BackupContentService）单测
//
// 覆盖：配置键常量、可忽略项清单与参考版对齐、解析容错（fail-open）、
// 保存序列化顺序与未知键剔除、load/save 经 BookApi.getConfig/setConfig 往返。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/backup_content_service.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi api;
  late BackupContentService service;
  late Map<String, String> configs;

  setUpAll(registerFallbacks);

  setUp(() {
    configs = <String, String>{};
    api = MockRustApi();
    when(() => api.getConfig(any())).thenAnswer(
      (invocation) async =>
          configs[invocation.positionalArguments.first as String],
    );
    when(() => api.setConfig(any(), any())).thenAnswer((invocation) async {
      final args = invocation.positionalArguments;
      configs[args[0] as String] = args[1] as String;
    });
    service = BackupContentService(api: api);
  });

  group('BackupContentService 配置键与清单', () {
    test('配置短键与 Rust 侧一致（caches 实际键 config:backupIgnoreTables）', () {
      expect(BackupContentService.configKey, 'backupIgnoreTables');
    });

    test('可忽略项只含参考版 dbIsNotIgnored 实际把守的表', () {
      final keys = BackupContentService.keys;
      // 参考版 Backup.kt:156-222 逐表把守的键（我方有对应表的 15 项）
      expect(
        keys,
        containsAll(<String>[
          'bookmark',
          'bookGroup',
          'bookSource',
          'rssSource',
          'rssStar',
          'replaceRule',
          'readRecord',
          'searchHistory',
          'sourceSub',
          'txtTocRule',
          'httpTTS',
          'keyboardAssists',
          'dictRule',
          'highlightRule',
          'server',
        ]),
      );
      // 参考版无该门控的表不得出现（否则会造出「参考版没有的开关」）
      for (final absent in <String>[
        'books',
        'bookMemos',
        'highlights',
        'autoTasks',
        'coverRules',
        'directLinkUploadRule',
      ]) {
        expect(keys, isNot(contains(absent)), reason: '$absent 参考版无忽略门控');
      }
    });

    test('每个可忽略项都有非空中文标题', () {
      for (final entry in BackupContentService.entries) {
        expect(entry.title.trim(), isNotEmpty, reason: entry.key);
      }
    });
  });

  group('BackupContentService.parse 容错（fail-open）', () {
    test('空/缺失 → 空集（不过滤任何表）', () {
      expect(BackupContentService.parse(null), isEmpty);
      expect(BackupContentService.parse(''), isEmpty);
      expect(BackupContentService.parse('   '), isEmpty);
    });

    test('非法 JSON / 非数组 → 空集', () {
      expect(BackupContentService.parse('not-json'), isEmpty);
      expect(BackupContentService.parse('{"bookmark":true}'), isEmpty);
      expect(BackupContentService.parse('null'), isEmpty);
    });

    test('未知键/非字符串元素被丢弃，已知键保留', () {
      expect(BackupContentService.parse('["bookmark","noSuchTable",1,null]'), {
        'bookmark',
      });
    });

    test('容忍首尾空白', () {
      expect(BackupContentService.parse('[" bookmark "]'), {'bookmark'});
    });
  });

  group('BackupContentService load/save', () {
    test('load 读取 BookApi.getConfig 的原始值并解析', () async {
      await api.setConfig(
        BackupContentService.configKey,
        jsonEncode(['bookmark', 'server']),
      );
      expect(await service.load(), {'bookmark', 'server'});
    });

    test('save 按清单顺序序列化并剔除未知键', () async {
      await service.save({'server', 'unknown', 'bookmark'});
      final raw = await api.getConfig(BackupContentService.configKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as List;
      expect(decoded, ['bookmark', 'server'], reason: '按 entries 顺序、不含未知键');
    });

    test('save 空集写空数组（等价于「不过滤」）', () async {
      await service.save(<String>{});
      expect(await api.getConfig(BackupContentService.configKey), '[]');
      expect(await service.load(), isEmpty);
    });

    test('save → load 往返一致', () async {
      const target = {'bookSource', 'readRecord', 'dictRule'};
      await service.save(target);
      expect(await service.load(), target);
    });
  });
}
