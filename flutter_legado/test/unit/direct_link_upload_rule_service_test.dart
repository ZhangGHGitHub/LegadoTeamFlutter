// 直链上传规则服务单测（批16b）
//
// 覆盖：内置默认规则资产读取（3 条，索引 0 为默认）、配置往返（4 字段
// camelCase、忽略 expiryDate）、字段校验失败、清除回落默认、坏配置回退、
// 测试上传调用参数（§2.51 test.json / application/json / {}）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/direct_link_upload_rule_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 捕获 directLinkUpload 入参的 Mock（配置读写沿用 MockBookApi 内存实现）
class _CapturingBookApi extends MockBookApi {
  final List<Map<String, Object?>> uploadCalls = [];
  Object? uploadError;
  String uploadResult = 'https://download.example/test.json';

  @override
  Future<String> directLinkUpload({
    required String ruleJson,
    required String fileName,
    required String contentType,
    String? content,
    String? filePath,
  }) async {
    uploadCalls.add(<String, Object?>{
      'ruleJson': ruleJson,
      'fileName': fileName,
      'contentType': contentType,
      'content': content,
      'filePath': filePath,
    });
    final error = uploadError;
    if (error != null) throw error;
    return uploadResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CapturingBookApi api;
  late DirectLinkUploadRuleService service;

  setUp(() {
    api = _CapturingBookApi();
    service = DirectLinkUploadRuleService(api);
  });

  String ruleJson({
    String uploadUrl = 'https://up.example/upload',
    String downloadUrlRule = r'$.data.url',
    String summary = '测试规则',
    Object? compress = false,
    Map<String, Object?> extra = const {},
  }) => jsonEncode(<String, Object?>{
    'uploadUrl': uploadUrl,
    'downloadUrlRule': downloadUrlRule,
    'summary': summary,
    'compress': compress,
    ...extra,
  });

  group('内置默认规则', () {
    test('资产读取 3 条，索引 0 为默认且字段为 camelCase 4 字段', () async {
      final rules = await service.loadDefaultRules();
      expect(rules, hasLength(3));
      expect(rules.first.summary, contains('喵公子网盘①'));
      expect(
        rules.first.uploadUrl,
        startsWith('https://sy.nyasama.net/shuyuan'),
      );
      expect(rules.first.downloadUrlRule, contains(r'$.data@js:'));
      expect(rules[2].uploadUrl, startsWith('http://v2.jt12.eu/up-v2.php'));
      expect(rules.first.toJson().keys.toSet(), <String>{
        'uploadUrl',
        'downloadUrlRule',
        'summary',
        'compress',
      });
      expect(rules.every((r) => r.compress == false), isTrue);
      // summary 为必填字段，内置 3 条规则应全部非空
      expect(rules.every((r) => r.summary.trim().isNotEmpty), isTrue);
    });

    test('资产 JSON 非法时包装为规则异常（统一文案体系）', () async {
      final broken = DirectLinkUploadRuleService(
        api,
        assetLoader: (_) async => '{bad json',
      );
      await expectLater(
        broken.loadDefaultRules(),
        throwsA(
          isA<DirectLinkUploadRuleException>().having(
            (e) => e.message,
            'message',
            '内置直链上传规则不是有效的 JSON',
          ),
        ),
      );
    });

    test('未配置时生效规则 = 默认第 1 条，且不标记降级', () async {
      final result = await service.resolveEffectiveRule();
      expect(result.degraded, isFalse);
      final defaults = await service.loadDefaultRules();
      expect(result.rule, defaults.first);
      expect(await service.getEffectiveRule(), result.rule);
    });
  });

  group('配置往返', () {
    test('保存后回读生效规则，仅持久化 4 字段（忽略 expiryDate）', () async {
      await service.saveRule(
        ruleJson(
          uploadUrl: 'https://up.example/a,{"method":"POST"}',
          summary: '自定义规则',
          compress: true,
          extra: const {'expiryDate': 30},
        ),
      );

      final raw = await api.getConfig(DirectLinkUploadRuleService.configKey);
      expect(raw, isNotNull);
      final saved = jsonDecode(raw!) as Map<String, dynamic>;
      expect(saved.keys.toSet(), <String>{
        'uploadUrl',
        'downloadUrlRule',
        'summary',
        'compress',
      });
      expect(saved['compress'], isTrue);
      expect(saved.containsKey('expiryDate'), isFalse);

      final effective = await service.getEffectiveRule();
      expect(effective.summary, '自定义规则');
      expect(effective.uploadUrl, 'https://up.example/a,{"method":"POST"}');
      expect(effective.compress, isTrue);
    });

    test('snake_case 规则键兼容解析', () async {
      final rule = service.parseRule(
        jsonEncode(<String, Object?>{
          'upload_url': 'https://up.example/snake',
          'download_url_rule': r'$.msg',
          'summary': '蛇形',
          'compress': false,
        }),
      );
      expect(rule.uploadUrl, 'https://up.example/snake');
      expect(rule.downloadUrlRule, r'$.msg');
      expect(rule.summary, '蛇形');
    });

    test('清除配置后回落默认第 1 条', () async {
      await service.saveRule(ruleJson(summary: '待清除'));
      expect(
        await api.getConfig(DirectLinkUploadRuleService.configKey),
        isNotNull,
      );

      await service.clearRule();
      expect(
        await api.getConfig(DirectLinkUploadRuleService.configKey),
        isNull,
      );

      final effective = await service.getEffectiveRule();
      final defaults = await service.loadDefaultRules();
      expect(effective, defaults.first);
    });

    test('配置损坏时 getEffectiveRule 回退默认，loadSavedRule 显式报错', () async {
      await api.setConfig(DirectLinkUploadRuleService.configKey, '{bad json');

      await expectLater(
        service.loadSavedRule(),
        throwsA(isA<DirectLinkUploadRuleException>()),
      );
      final result = await service.resolveEffectiveRule();
      expect(result.degraded, isTrue);
      expect(result.rule.summary, contains('喵公子网盘①'));
      expect(await service.getEffectiveRule(), result.rule);
    });

    test('可解析但语义非法的配置（{} / 必填为空）同样回落默认并标记降级', () async {
      final badConfigs = <String>[
        '{}',
        jsonEncode(<String, Object?>{
          'uploadUrl': 'https://up.example/up',
          'downloadUrlRule': '',
          'summary': '',
          'compress': false,
        }),
      ];
      for (final badConfig in badConfigs) {
        await api.setConfig(DirectLinkUploadRuleService.configKey, badConfig);
        final result = await service.resolveEffectiveRule();
        expect(result.degraded, isTrue, reason: badConfig);
        final defaults = await service.loadDefaultRules();
        expect(result.rule, defaults.first, reason: badConfig);
      }
    });
  });

  group('规则校验', () {
    Future<void> expectInvalid(String raw, String message) async {
      await expectLater(
        service.saveRule(raw),
        throwsA(
          isA<DirectLinkUploadRuleException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
    }

    test('上传 Url 为空', () async {
      await expectInvalid(ruleJson(uploadUrl: ''), '上传Url不能为空');
    });

    test('上传 Url 非 http(s) 或缺少主机名', () async {
      await expectInvalid(
        ruleJson(uploadUrl: 'ftp://up.example/u'),
        '上传Url不是有效的 http(s) 地址',
      );
      await expectInvalid(
        ruleJson(uploadUrl: 'https:///u'),
        '上传Url不是有效的 http(s) 地址',
      );
    });

    test('下载 Url 规则为空', () async {
      await expectInvalid(ruleJson(downloadUrlRule: '  '), '下载Url规则不能为空');
    });

    test('compress 非布尔值', () async {
      await expectInvalid(ruleJson(compress: 'true'), '字段 compress 必须是布尔值');
    });

    test('字段类型不符 / 非 JSON 对象 / 非法 JSON', () async {
      await expectInvalid(
        jsonEncode(<String, Object?>{'uploadUrl': 123}),
        '字段 uploadUrl 必须是字符串',
      );
      await expectInvalid('[]', '规则必须是 JSON 对象');
      await expectInvalid('not json', '规则不是有效的 JSON');
      await expectInvalid('  ', '规则内容为空');
    });

    test('注释必填：空注释拒绝', () async {
      await expectInvalid(ruleJson(summary: '  '), '注释不能为空');
      await service.saveRule(
        ruleJson(
          uploadUrl: 'https://up.example/u,{"method":"POST"}',
          summary: '有注释',
        ),
      );
      final effective = await service.getEffectiveRule();
      expect(effective.summary, '有注释');
    });
  });

  group('测试上传（§2.51）', () {
    test('调用参数：test.json / application/json / {} / 规范化 4 字段', () async {
      final result = await service.testRule(
        ruleJson(
          uploadUrl: 'https://up.example/up',
          summary: '测试',
          compress: true,
          extra: const {'expiryDate': 7},
        ),
      );
      expect(result, 'https://download.example/test.json');
      expect(api.uploadCalls, hasLength(1));
      final call = api.uploadCalls.single;
      expect(call['fileName'], 'test.json');
      expect(call['contentType'], 'application/json');
      expect(call['content'], '{}');
      expect(call['filePath'], isNull);
      final sent =
          jsonDecode(call['ruleJson']! as String) as Map<String, dynamic>;
      expect(sent.keys.toSet(), <String>{
        'uploadUrl',
        'downloadUrlRule',
        'summary',
        'compress',
      });
      expect(sent['compress'], isTrue);
    });

    test('校验失败不发起上传，异常上抛', () async {
      await expectLater(
        service.testRule(ruleJson(uploadUrl: '')),
        throwsA(isA<DirectLinkUploadRuleException>()),
      );
      expect(api.uploadCalls, isEmpty);
    });

    test('上传错误上抛给调用方', () async {
      api.uploadError = Exception('上传失败,body');
      await expectLater(
        service.testRule(ruleJson()),
        throwsA(isA<Exception>()),
      );
    });
  });
}
