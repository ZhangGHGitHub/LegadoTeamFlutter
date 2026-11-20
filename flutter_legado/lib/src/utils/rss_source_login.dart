// RSS 源登录执行入口（C3）
//
// 背景：`RssSource` 的 `loginUrl` / `loginUi` / `loginCheckJs` 三字段在
// `rss_source_edit_screen.dart` 可编辑，但**没有执行登录的 UI 入口**
// （此前注释「RSS 登录 UI 尚未接线」）。RSS 列表/正文链的登录门控
// （`legado-fetcher::rss::login::gate_login`）在 `loginCheckJs` 判定未登录时
// 返回 `LoginRequired`，用户无从补救。
//
// 本文件是 RSS 侧登录入口的唯一实现，按原版 `SourceLoginActivity`
// （`app/.../ui/login/SourceLoginActivity.kt:20-45`，`type = "rssSource"`）
// 的三路分流执行：
//
// 1. **loginUi 为 V2 动态状态协议** → `LoginV2Dialog`（`loginUiV2` /
//    `loginActionV2` 驱动；Rust 侧 `login_ui_v2` 按 `BookSource` 建模，
//    故这里把 `RssSource` 归一为等价 `BookSource` 视图后传入）。
// 2. **loginUi 为经典 JSON 行协议** → `ClassicLoginDialog`（`loginUrl` 的 JS
//    + 按钮 action；表单值经 `putLoginInfo` 落库）。
// 3. **无 loginUi** → `WebViewLoginScreen`（内置 WebView 打开 `loginUrl`，
//    Cookie 自动落库 `loginHeader`）。
//
// 登录态统一落 `source_login_cache`（`loginHeader_<sourceUrl>` /
// `userInfo_<sourceUrl>`），RSS 列表/正文请求链读同一键空间，故登录结果
// 对后续请求立即生效。
//
// **执行链缺口（已在本批修复）**：JS 形态 `loginUrl`（如
// `@js:...source.putLoginHeader(...)`）经 `rssWebViewHostCall('run', ...)`
// 执行时，此前只写引擎变量表不落 `source_login_cache` → 「执行成功但列表
// 仍报未登录」。`legado-ffi/src/api/rss_web_bridge.rs::host_call` 已在
// `run` 收尾补 `sync_login_cache_from_js`（见该文件 C3 注释）。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../screens/source_login_screen.dart';
import '../screens/webview_login_screen.dart';
import '../services/book_api.dart';
import '../utils/webview_support.dart';
import '../widgets/classic_login_dialog.dart';
import '../widgets/login_v2_dialog.dart';

/// RSS 源是否有可执行的登录配置（对齐 `BaseSource.hasLogin()`：
/// `loginUrl` 非空白 **或** `loginUi` 为非空非 `[]` 表单）
bool rssSourceHasLogin(RssSource source) =>
    (source.loginUrl ?? '').trim().isNotEmpty || _hasLoginForm(source.loginUi);

bool _hasLoginForm(String? loginUi) {
  final form = (loginUi ?? '').trim();
  if (form.isEmpty) return false;
  // 对齐 Kotlin `hasLoginForm`：去空白后为 `[]` 视为无表单
  return form.replaceAll(RegExp(r'\s'), '') != '[]';
}

/// 把 [RssSource] 归一为登录链所需的 `BookSource` 视图
///
/// Rust 侧 `login_ui_v2` / `classic_login_dialog` 的动作求值按 `BookSource`
/// 建模（`book_source_url` / `login_url` / `login_ui` / `js_lib` / `header`）。
/// RSS 源与书源在这几个字段上语义一致，仅主键字段名不同
/// （`sourceUrl` vs `bookSourceUrl`），故做一次无损映射；其余字段留空
/// （RSS 登录脚本不消费搜索/目录规则）。
BookSource rssSourceAsLoginView(RssSource source) => BookSource(
  bookSourceUrl: source.sourceUrl,
  bookSourceName: source.sourceName,
  loginUrl: source.loginUrl,
  loginUi: source.loginUi,
  jsLib: source.jsLib,
  header: source.header,
  enabled: source.enabled,
);

/// 显示 RSS 源登录界面并返回是否登录成功
///
/// 与 [showSourceLogin]（书源）同构，差别只在入参类型与「无登录配置」时的
/// 提示文案。调用方：RSS 源管理页单项菜单、RSS 列表页菜单、
/// `java.open('login')` 桥动作。
Future<bool> showRssSourceLogin(
  BuildContext context,
  WidgetRef ref,
  RssSource source,
) async {
  if (!rssSourceHasLogin(source)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(AppStrings.rssLoginNotConfigured)),
    );
    return false;
  }
  final api = ref.read(bookApiProvider);
  final view = rssSourceAsLoginView(source);
  final sourceJson = jsonEncode(view.toJson());

  // 1) V2 动态状态协议（loginUi 为 JS 脚本形态）
  var isV2 = false;
  try {
    isV2 = await api.isLoginUiV2(sourceJson);
  } catch (e) {
    debugPrint('[RSS 登录] loginUiV2 判定失败：$e');
  }
  if (!context.mounted) return false;
  if (isV2) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => LoginV2Dialog(
        api: api,
        sourceJson: sourceJson,
        sourceName: source.sourceName,
      ),
    );
    return ok == true;
  }

  // 2) 经典 loginUi 表单（对齐原版 hasLoginForm → SourceLoginDialog）
  if (_hasLoginForm(source.loginUi)) {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ClassicLoginDialog(api: api, source: view),
    );
    return ok == true;
  }

  // 3) 无表单：内置 WebView 打开 loginUrl，Cookie 自动落库 loginHeader
  //    （对齐原版 WebViewLoginFragment；standalone 固定 root 全屏）
  //
  //    非 WebView 平台（Windows/Linux 桌面）无 webview_flutter 实现，
  //    打开本页只会渲染空白/抛错 —— 回退既有手动凭据页（Cookie/Header/
  //    Token 手工录入），能力不丢。
  if (!isWebViewPlatformSupported) {
    final saved = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(
        builder: (_) => SourceLoginScreen(
          sourceUrl: source.sourceUrl,
          sourceName: source.sourceName,
          loginUrl: source.loginUrl,
        ),
      ),
    );
    return saved == true;
  }
  final saved = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      builder: (_) => WebViewLoginScreen(
        api: api,
        sourceUrl: source.sourceUrl,
        sourceName: source.sourceName,
        loginUrl: source.loginUrl ?? '',
        header: source.header,
      ),
    ),
  );
  return saved == true;
}

/// 直接执行 JS 形态的 RSS 登录脚本（无 UI，供自动化/调试复用）
///
/// 走 `rssWebViewHostCall('run', ...)`：在源上下文（jsLib + setup + `source`/
/// `java`/`cookie` 绑定）执行脚本，Rust 侧在 `run` 收尾同步
/// `loginHeader_<url>` / `userInfo_<url>` 到 `source_login_cache`（C3）。
///
/// [script] 为纯 JS（`@js:` / `<js>` 包裹会被剥离）。返回执行结果原文。
/// 脚本执行失败抛异常（调用方需提示用户）。
Future<String> runRssLoginScript(
  BookApi api,
  RssSource source,
  String script,
) async {
  final raw = script.trim();
  final js = _stripJsWrapper(raw);
  final envelope = await api.rssWebViewHostCall(
    source.sourceUrl,
    'run',
    jsonEncode([js]),
  );
  final decoded = jsonDecode(envelope);
  if (decoded is! Map) {
    throw const FormatException('RSS 登录脚本返回非法信封');
  }
  if (decoded['ok'] != true) {
    throw StateError('${decoded['error'] ?? '登录脚本执行失败'}');
  }
  return decoded['value']?.toString() ?? '';
}

/// 剥离 `@js:` / `<js>...</js>` 包裹（对齐原版 `getLoginJs`）
String _stripJsWrapper(String script) {
  final lower = script.toLowerCase();
  if (lower.startsWith('<js>')) {
    final end = script.lastIndexOf('</js>');
    return end > 0 ? script.substring(4, end) : script.substring(4);
  }
  if (lower.startsWith('@js:')) return script.substring(4);
  return script;
}
