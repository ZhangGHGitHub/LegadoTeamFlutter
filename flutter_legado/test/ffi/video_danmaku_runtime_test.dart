/// V-B1 视频弹幕数据链 Dart↔Rust 真实数据链运行时验证（契约 §2.49）
///
/// 加载 rust/target/debug/legado_ffi.dll（解析策略对齐
/// audio_cache_runtime_test.dart），经真实 FRB wire 在本机回环服务器上跑
/// **完整数据链**（不联网）：
///
/// 1. 导入视频书源（bookSourceType=4，ruleToc 解析目录、ruleContent 含
///    content + subContent）
/// 2. addBook + refreshToc：目录落库（走 refreshToc 链——该链**不登记**
///    fetcher 的 (书源, 章节) → 书 meta 缓存，正是落库 sink 的 DB 兜底
///    反查路径）
/// 3. getChapterContentFull：正文抓取（媒体分支副内容不得拼进正文），
///    抓取链捕获 subContent → 落库章节 variable `danmaku` 键
/// 4. getVideoDanmaku（RustApi + bridge 双通道）：读回副内容原文；
///    幂等重复读一致；无记录书 → null 降级
///
/// 大数据文件分流（≥10000 UTF-16）/阈值口径 / 读失败降级由 Rust 单测覆盖
/// （rust/legado-ffi/src/api/video_api.rs，不联网）。
/// 前置条件：先在 rust/ 下构建 DLL
/// （cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_legado/src/models/book.dart';
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

/// 本机回环服务器：`/toc` 目录页、`/c1` 内容页（含 subContent 副内容）
Future<HttpServer> _startFixtureServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    final path = req.uri.path;
    final String body;
    if (path == '/toc') {
      body = '<html><body><div class="chapter">'
          '<a href="/c1">第1集</a>'
          '</div></body></html>';
    } else if (path == '/c1') {
      body = '<html><body>'
          '<div class="content">https://cdn.example/v.mp4</div>'
          '<div class="sub">{"danmaku":[{"text":"测试弹幕"}]}</div>'
          '</body></html>';
    } else {
      req.response.statusCode = HttpStatus.notFound;
      req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.html;
    req.response.write(body);
    req.response.close();
  });
  return server;
}

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（对齐既有运行时测试守卫）
  if (!Platform.isWindows) {
    test('跳过视频弹幕 FFI 运行时测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  late RustApi api;
  late Directory dbDir;

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_resolveDll()));
    await bridge.init();
    final sep = Platform.pathSeparator;
    dbDir = Directory('.dart_tool${sep}ffi_video_danmaku_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}v_b1_danmaku.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    // 规则数据目录（大数据文件根）= DB 父目录/ruleData：残留清理保证
    // 小数据断言不受上一轮文件影响
    final ruleDir = Directory('${dbDir.path}${sep}ruleData');
    if (ruleDir.existsSync()) {
      ruleDir.deleteSync(recursive: true);
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();
  });

  tearDownAll(() {
    // 关闭连接池前不删库（WAL 由后续进程/测试清理）；仅清理可能残留的
    // 规则数据目录，避免跨轮串扰
    final ruleDir = Directory('${dbDir.path}${Platform.pathSeparator}ruleData');
    if (ruleDir.existsSync()) {
      try {
        ruleDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('端到端：媒体副内容捕获落库 → getVideoDanmaku 读回原文；幂等；无记录 null', () async {
    final server = await _startFixtureServer();
    final port = server.port;
    final base = 'http://127.0.0.1:$port';
    final bookUrl = '$base/book';

    try {
      // 1. 视频书源（bookSourceType=4）
      final imported = await api.importBookSources(
        jsonEncode([
          {
            'bookSourceUrl': base,
            'bookSourceName': 'V-B1 E2E 视频源',
            'bookSourceType': 4,
            'ruleToc': {
              'chapterList': '.chapter@a',
              'chapterName': 'text',
              'chapterUrl': '@href',
            },
            'ruleContent': {
              'content': '.content@text',
              'subContent': '.sub@text',
            },
          },
        ]),
      );
      expect(imported, 1, reason: '视频书源应导入 1 条');

      // 2. 书籍 + 目录（refreshToc 链：不经 fetcher meta 缓存 → 依赖 sink DB 兜底）
      await api.addBook(
        Book(
          bookUrl: bookUrl,
          tocUrl: '$base/toc',
          origin: base,
          originName: 'V-B1 E2E 视频源',
          name: 'V-B1 弹幕测试书',
          author: '测试作者',
          bookType: 4,
        ),
      );
      final chapters = await api.refreshToc(bookUrl, base);
      expect(chapters, isNotEmpty, reason: '目录应解析出 1 集');
      expect(chapters.first.title, '第1集');

      // 3. 正文抓取：媒体分支副内容不得拼进正文，但须被捕获落库
      final content = await api.getChapterContentFull(bookUrl, 0);
      expect(
        content.contains('cdn.example/v.mp4'),
        isTrue,
        reason: '正文应保留播放链接，实际: $content',
      );
      expect(
        content.contains('danmaku'),
        isFalse,
        reason: '媒体分支副内容不得拼进播放链接正文，实际: $content',
      );

      // 4. 查询：读回副内容原文
      final danmaku = await api.getVideoDanmaku(
        bookUrl: bookUrl,
        chapterIndex: 0,
      );
      expect(danmaku, isNotNull, reason: '抓取链捕获后应能读回弹幕');
      expect(danmaku, contains('测试弹幕'));

      // RustApi 与 bridge 双通道一致 + 幂等（重复查询读同一落库值）
      expect(
        await bridge.getVideoDanmaku(bookUrl: bookUrl, chapterIndex: 0),
        danmaku,
      );
      expect(
        await api.getVideoDanmaku(bookUrl: bookUrl, chapterIndex: 0),
        danmaku,
      );

      // 无记录/书不在 DB → null 降级（不抛）
      expect(
        await api.getVideoDanmaku(bookUrl: '$base/ghost', chapterIndex: 0),
        isNull,
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('parseVideoDanmaku（§2.50）：真实 DLL 解析 B 站 XML → 结构化弹幕项；非法 → null', () async {
    const xml = '<i>'
        '<d p="2.0,5,25,16711680">顶部</d>'
        '<d p="0.5,1,25,16777215">滚动</d>'
        '<d p="1,2,25,0">类型2丢弃</d>'
        '</i>';

    // RustApi 通道：JSON → 模型列表（升序、类型过滤、字段口径）
    final items = await api.parseVideoDanmaku(raw: xml);
    expect(items, isNotNull, reason: '真实 DLL 应返回解析结果');
    expect(items!.length, 2, reason: 'type2 应静默丢弃');
    final first = items.first;
    expect(first.timeMs, 500);
    expect(first.type, 1);
    expect(first.textSizeRaw, 25.0);
    expect(first.color, -1); // 0xFFFFFFFF as i32
    expect(first.text, '滚动');
    expect(items.last.type, 5);
    expect(items.last.timeMs, 2000);

    // bridge 直通道与 RustApi 结果一致（同一纯函数）
    final json = await bridge.parseVideoDanmaku(raw: xml);
    expect(json, isNotNull);
    final decoded = (jsonDecode(json!) as List).cast<Map<String, dynamic>>();
    expect(decoded.length, 2);
    expect(decoded.first['text'], '滚动');

    // 非 XML / 空 → null（对齐原版 SAX 无容错）
    expect(await api.parseVideoDanmaku(raw: '不是XML'), isNull);
    expect(await api.parseVideoDanmaku(raw: ''), isNull);
  });
}
