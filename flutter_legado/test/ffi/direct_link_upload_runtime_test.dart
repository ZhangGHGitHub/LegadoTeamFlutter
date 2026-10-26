/// 批16a 直链上传真实 DLL 运行时验证（契约 §2.51）
///
/// 加载 `rust/target/debug/legado_ffi.dll`（解析策略对齐既有 test/ffi 用例），
/// 经真实 FRB wire 在本机回环 HTTP 服务器上跑（**不联网**）：
///
/// 1. POST multipart：文件部件字段名/文件名/内容 + 选项 headers 透传；
/// 2. `compress=true`：文件名加 `.zip`、部件类型 `application/zip`、内容为
///    合法 zip（PK 头）；
/// 3. `@js:` + `result` 级联：下载规则求值真实走 QuickJS；
/// 4. 二选一/空参数：content+filePath 同时提供、filePath 空串、上传 URL 空
///    均明确报错（对齐 Rust 错误语义，不静默降级）。
///
/// 前置条件：先在 rust/ 下构建 DLL
/// （cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 从 rust/target/debug 解析真实 DLL 路径（对齐 rust_api.dart 的搜索策略）
String _resolveDll() {
  const libName = 'legado_ffi.dll';
  final sep = Platform.pathSeparator;
  final candidates = <String>[
    // flutter test 的 Directory.current 即 flutter_legado/
    '${Directory.current.parent.path}${sep}rust${sep}target${sep}debug$sep$libName',
    '${Directory.current.path}$sep..${sep}rust${sep}target${sep}debug$sep$libName',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

/// 回环上传服务捕获的请求
class _CapturedUpload {
  _CapturedUpload({
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> headers;
  final List<int> body;

  String get bodyText => utf8.decode(body, allowMalformed: true);
  String header(String name) => headers[name.toLowerCase()] ?? '';
}

void main() {
  if (!Platform.isWindows) {
    test('跳过直链上传 FFI 运行时测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  late RustApi api;
  late HttpServer server;
  late List<_CapturedUpload> captured;
  late String responseJson;

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_resolveDll()));
    await bridge.init();
    api = RustApi();
    captured = [];
    responseJson = '{"code":0,"data":{"url":"https://dl.example/f/uploaded"}}';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
      }
      captured.add(
        _CapturedUpload(
          method: req.method,
          path: req.uri.path,
          headers: {
            for (final name in ['content-type', 'x-upload-token'])
              name: req.headers.value(name) ?? '',
          },
          body: bytes,
        ),
      );
      req.response.headers.contentType = ContentType.json;
      req.response.write(responseJson);
      await req.response.close();
    });
  });

  tearDown(() {
    captured.clear();
    responseJson = '{"code":0,"data":{"url":"https://dl.example/f/uploaded"}}';
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  String uploadUrl() => 'http://127.0.0.1:${server.port}/upload';

  String rule({
    String? url,
    String downloadRule = r'$.data.url',
    bool compress = false,
  }) => jsonEncode({
    'uploadUrl':
        url ??
        '${uploadUrl()},{"method":"POST","headers":{"X-Upload-Token":"tk-1"},'
            '"body":{"file":"fileRequest","title":"书源合集"}}',
    'downloadUrlRule': downloadRule,
    'summary': '运行时测试',
    'compress': compress,
  });

  test('POST multipart：字段/文件名/内容与选项 headers 到达 Rust 网络层', () async {
    final result = await api.directLinkUpload(
      ruleJson: rule(),
      fileName: 'sources.json',
      contentType: 'application/json',
      content: '[]',
    );
    expect(result, 'https://dl.example/f/uploaded');

    final req = captured.single;
    expect(req.method, 'POST');
    expect(req.path, '/upload');
    expect(req.header('x-upload-token'), 'tk-1');
    expect(
      req.header('content-type'),
      startsWith('multipart/form-data; boundary='),
    );
    final text = req.bodyText;
    expect(
      text,
      contains(
        'Content-Disposition: form-data; name="file"; filename="sources.json"',
      ),
    );
    expect(text, contains('Content-Type: application/json\r\n\r\n[]'));
    expect(text, contains('name="title"\r\n\r\n书源合集'));
  });

  test('compress=true：文件名 .zip、类型 application/zip、内容为 zip', () async {
    final result = await api.directLinkUpload(
      ruleJson: rule(compress: true),
      fileName: 'rules.json',
      contentType: 'application/json',
      content: '[1,2,3]',
    );
    expect(result, 'https://dl.example/f/uploaded');

    final req = captured.single;
    final text = req.bodyText;
    expect(text, contains('filename="rules.json.zip"'));
    expect(text, contains('Content-Type: application/zip'));
    // zip 局部文件头 "PK\x03\x04"
    final pk = req.body.indexOf(0x50);
    expect(pk, greaterThan(0));
    expect(req.body.sublist(pk, pk + 2), [0x50, 0x4B]);
  });

  test('@js: 下载规则：result 绑定前序 JSONPath 结果', () async {
    responseJson = '{"code":0,"data":"abc123"}';
    final result = await api.directLinkUpload(
      ruleJson: rule(
        downloadRule: r"$.data@js:'https://shuyuan.example/' + result",
      ),
      fileName: 'a.txt',
      contentType: 'text/plain',
      content: 'x',
    );
    expect(result, 'https://shuyuan.example/abc123');
  });

  test('二选一/空参数：明确报错（不发起网络请求）', () async {
    // content + filePath 同时提供
    await expectLater(
      api.directLinkUpload(
        ruleJson: rule(),
        fileName: 'a.txt',
        contentType: 'text/plain',
        content: 'x',
        filePath: 'C:/tmp/a.txt',
      ),
      throwsA(anything),
    );
    // filePath 空串（对齐 Rust「上传文件路径为空」）
    await expectLater(
      api.directLinkUpload(
        ruleJson: rule(),
        fileName: 'a.txt',
        contentType: 'text/plain',
        filePath: '',
      ),
      throwsA(anything),
    );
    // 上传 URL 未配置
    await expectLater(
      api.directLinkUpload(
        ruleJson: jsonEncode({
          'uploadUrl': '',
          'downloadUrlRule': r'$.data.url',
          'summary': '空 URL',
          'compress': false,
        }),
        fileName: 'a.txt',
        contentType: 'text/plain',
        content: 'x',
      ),
      throwsA(anything),
    );
    expect(captured, isEmpty, reason: '参数错误应在网络请求前拦截');
  });
}
