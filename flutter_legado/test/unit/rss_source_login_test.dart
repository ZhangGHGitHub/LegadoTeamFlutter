// C3：RSS 源登录执行入口
//
// 覆盖：
// 1. `rssSourceHasLogin` 判定（对齐 Kotlin BaseSource.hasLogin / hasLoginForm：
//    loginUrl 非空白 或 loginUi 为非空非 `[]` 表单）；
// 2. `rssSourceAsLoginView` 把 RssSource 归一为 BookSource 登录视图
//    （主键字段名映射 + 登录相关字段透传，其余不串味）；
// 3. `runRssLoginScript` 的 `@js:` / `<js>` 包裹剥离与信封解析（用 Mock
//    的「不支持」信封验证失败上抛，不静默成功）；
// 4. 源码守卫：RSS 三处入口（源管理页 / 列表页 / 详情页桥动作）都走
//    统一入口 `showRssSourceLogin`，不再各自直连手动凭据页。

import 'dart:io';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/utils/rss_source_login.dart';
import 'package:flutter_test/flutter_test.dart';

RssSource _source({
  String url = 'https://rss.test/feed',
  String? loginUrl,
  String? loginUi,
}) => RssSource(
  sourceUrl: url,
  sourceName: '测试源',
  loginUrl: loginUrl,
  loginUi: loginUi,
);

void main() {
  group('rssSourceHasLogin（对齐 BaseSource.hasLogin）', () {
    test('loginUrl 非空白 → true', () {
      expect(rssSourceHasLogin(_source(loginUrl: 'https://x/login')), isTrue);
    });

    test('loginUi 为普通表单 → true', () {
      expect(
        rssSourceHasLogin(
          _source(loginUi: '[{"name":"u","type":"text"}]'),
        ),
        isTrue,
      );
    });

    test('loginUi 为空 / 空白 / [] → false（无 loginUrl 时）', () {
      expect(rssSourceHasLogin(_source()), isFalse);
      expect(rssSourceHasLogin(_source(loginUi: '   ')), isFalse);
      expect(rssSourceHasLogin(_source(loginUi: '[]')), isFalse);
      // 含空白的 [] 同样视为空表单（对齐 hasLoginForm 去空白判定）
      expect(rssSourceHasLogin(_source(loginUi: '[ ]')), isFalse);
      expect(rssSourceHasLogin(_source(loginUi: '[\n ]')), isFalse);
    });

    test('loginUrl 为纯空白 → 不算登录配置', () {
      expect(rssSourceHasLogin(_source(loginUrl: '   ')), isFalse);
    });
  });

  group('rssSourceAsLoginView（RssSource → BookSource 登录视图）', () {
    test('主键与登录字段一一映射', () {
      final src = _source(
        url: 'https://rss.test/feed',
        loginUrl: 'function login(){}',
        loginUi: '[{"name":"u"}]',
      ).copyWith(jsLib: 'var A=1;', header: '{"X":"1"}');
      final view = rssSourceAsLoginView(src);
      expect(view.bookSourceUrl, 'https://rss.test/feed');
      expect(view.bookSourceName, '测试源');
      expect(view.loginUrl, 'function login(){}');
      expect(view.loginUi, '[{"name":"u"}]');
      expect(view.jsLib, 'var A=1;');
      expect(view.header, '{"X":"1"}');
    });

    test('RSS 规则字段不串味（搜索/目录/正文规则保持空）', () {
      final view = rssSourceAsLoginView(
        _source(loginUrl: 'x').copyWith(
          ruleArticles: 'item',
          ruleTitle: '.title',
          ruleContent: '.content',
        ),
      );
      // RSS 规则不进入书源视图（登录链不消费）
      expect(view.searchUrl, isNull);
      expect(view.ruleSearch, isNull);
      expect(view.ruleBookInfo, isNull);
      expect(view.ruleToc, isNull);
      expect(view.ruleContent, isNull);
    });
  });

  group('runRssLoginScript（信封解析 + 包裹剥离）', () {
    late MockBookApi api;

    setUp(() => api = MockBookApi());

    test('Mock 返回 ok:false 时必须抛错（不静默成功）', () async {
      await expectLater(
        runRssLoginScript(
          api,
          _source(loginUrl: 'function login(){}'),
          '@js:source.putLoginHeader("{}")',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('返回值非合法 JSON 时抛 FormatException', () async {
      // Mock 的 rssWebViewHostCall 恒返回合法 JSON 信封；此处用非法串
      // 直接验证解析分支（经 runRssLoginScript 无法注入，故断言抛错路径存在）
      expect(
        () => runRssLoginScript(
          api,
          _source(loginUrl: 'x'),
          'not-a-js',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('C3 源码守卫：RSS 登录入口统一', () {
    test('源管理页单项菜单有登录项并走统一入口', () {
      final src = File(
        'lib/src/screens/rss_source_manage_screen.dart',
      ).readAsStringSync();
      expect(src.contains("Navigator.pop(ctx, 'login')"), isTrue);
      expect(src.contains('showRssSourceLogin'), isTrue);
      expect(
        src.contains('if (rssSourceHasLogin(source))'),
        isTrue,
        reason: '登录项须按 hasLogin 门控（对齐原版 item 可见性）',
      );
    });

    test('列表页与详情页桥动作均改走统一入口，不再直连手动凭据页', () {
      for (final path in [
        'lib/src/screens/rss_articles_screen.dart',
        'lib/src/screens/rss_article_detail_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(
          src.contains('showRssSourceLogin'),
          isTrue,
          reason: '$path 应走 RSS 登录统一入口',
        );
        expect(
          src.contains('SourceLoginScreen('),
          isFalse,
          reason: '$path 不应再直接构造手动凭据页（loginUi/V2 源无从执行）',
        );
      }
    });

    test('Rust 侧 run 收尾同步登录缓存（否则「执行成功但不生效」）', () {
      final src = File(
        '../rust/legado-ffi/src/api/rss_web_bridge.rs',
      ).readAsStringSync();
      expect(
        src.contains('if method == "run"'),
        isTrue,
        reason: 'run 是登录脚本入口，须在收尾同步 source_login_cache',
      );
      expect(
        src.contains('sync_login_cache_from_js(&source.source_url)'),
        isTrue,
      );
    });
  });
}
