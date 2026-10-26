// 直链上传 Dart 侧定向测试（契约 §2.51，批16a）
//
// 覆盖 Dart 侧可验证面：
// 1. MockBookApi 上传语义形状（文件名 / 压缩后缀 / 规则标记）；
// 2. 规则非法（上传 URL/下载规则空）→ 明确错误；
// 3. `content` / `filePath` 二选一约束；
// 4. camelCase / snake_case 规则键兼容。
//
// Rust 侧上传语义（multipart 部件、zip 压缩、下载规则 JSONPath/正则/@js
// 三形态、网络错误、无 quickjs 降级）由
// `rust/legado-net/src/direct_link_upload.rs` 与
// `rust/legado-ffi/src/api/direct_link_upload_api.rs` 覆盖。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/mock_book_api.dart';

void main() {
  // MockBookApi 构造经惰性样例资产读取（rootBundle）→ 需绑定初始化
  TestWidgetsFlutterBinding.ensureInitialized();

  String rule({
    String uploadUrl = 'https://up.example/upload',
    String downloadRule = r'$.data.url',
    bool compress = false,
    bool snakeCase = false,
  }) => jsonEncode(
    snakeCase
        ? {
            'upload_url': uploadUrl,
            'download_url_rule': downloadRule,
            'summary': '测试',
            'compress': compress,
          }
        : {
            'uploadUrl': uploadUrl,
            'downloadUrlRule': downloadRule,
            'summary': '测试',
            'compress': compress,
          },
  );

  group('MockBookApi 直链上传（契约 §2.51）', () {
    test('content 上传返回含文件名与内容长度的直链', () async {
      final api = MockBookApi();
      final url = await api.directLinkUpload(
        ruleJson: rule(),
        fileName: 'sources.json',
        contentType: 'application/json',
        content: '[]',
      );
      expect(url, contains('/sources.json'));
      expect(url, contains('size=2'));
      expect(url, contains('rule=${Uri.encodeComponent(r'$.data.url')}'));
    });

    test('compress=true 且非 zip 类型 → 文件名加 .zip', () async {
      final api = MockBookApi();
      final url = await api.directLinkUpload(
        ruleJson: rule(compress: true),
        fileName: 'rules.json',
        contentType: 'application/json',
        content: '[1,2,3]',
      );
      expect(url, contains('/rules.json.zip'));
    });

    test('contentType 已是 application/zip → 不二次加 .zip（对齐 Rust 语义）', () async {
      final api = MockBookApi();
      final url = await api.directLinkUpload(
        ruleJson: rule(compress: true),
        fileName: 'pack.zip',
        contentType: 'application/zip',
        filePath: 'C:/tmp/pack.zip',
      );
      expect(url, contains('/pack.zip'));
      expect(url, isNot(contains('.zip.zip')));
    });

    test('snake_case 规则键兼容（历史配置）', () async {
      final api = MockBookApi();
      final url = await api.directLinkUpload(
        ruleJson: rule(snakeCase: true),
        fileName: 'a.txt',
        contentType: 'text/plain',
        content: 'hello',
      );
      expect(url, contains('/a.txt'));
    });

    test('上传 URL 未配置 → StateError（不上传）', () async {
      final api = MockBookApi();
      expect(
        () => api.directLinkUpload(
          ruleJson: rule(uploadUrl: '   '),
          fileName: 'a.txt',
          contentType: 'text/plain',
          content: 'x',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('上传 URL 未配置'),
          ),
        ),
      );
    });

    test('下载链接规则未配置 → StateError', () async {
      final api = MockBookApi();
      expect(
        () => api.directLinkUpload(
          ruleJson: rule(downloadRule: ''),
          fileName: 'a.txt',
          contentType: 'text/plain',
          content: 'x',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('下载链接规则未配置'),
          ),
        ),
      );
    });

    test('content 与 filePath 必须二选一', () async {
      final api = MockBookApi();
      expect(
        () => api.directLinkUpload(
          ruleJson: rule(),
          fileName: 'a.txt',
          contentType: 'text/plain',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => api.directLinkUpload(
          ruleJson: rule(),
          fileName: 'a.txt',
          contentType: 'text/plain',
          content: 'x',
          filePath: 'C:/tmp/a.txt',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('filePath 空串 → StateError（对齐 Rust「上传文件路径为空」）', () async {
      final api = MockBookApi();
      expect(
        () => api.directLinkUpload(
          ruleJson: rule(),
          fileName: 'a.txt',
          contentType: 'text/plain',
          filePath: '   ',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('上传文件路径为空'),
          ),
        ),
      );
    });
  });
}
