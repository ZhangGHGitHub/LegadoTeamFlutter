// RSS WebView `JavaScriptChannel` 真机探针（批21e P2-4）
//
// 用途：在 Android 真机/模拟器上复核 `webview_flutter` 平台注入通道的
// 可发现性与可删除性（契约 §2.5「真机结论」段的原始证据）：
//   1. 页面脚本能否看到通道（typeof / postMessage / 属性描述符 /
//      Object.keys / Object.getOwnPropertyNames）；
//   2. `delete window[channel]` 的返回值与删除后的可见性；
//   3. 捕获的通道对象在删除后是否仍可 `postMessage`（bootstrap 的做法）。
//
// 运行（设备在线时；探针须位于 integration_test/ 才会按设备集成测试执行）：
//   cd flutter_legado
//   flutter test integration_test/rss_webview_channel_probe_test.dart
//     -d 192.168.100.62:5555
//   若 Rust .so 尚未重编，可加 LEGADO_SKIP_RUST_BUILD=1 跳过 FFI 校验。
//
// 归档副本：docs/materials_remote_webview_bridge_20261027/probe/
//
// 探针输出 `PROBE_JSON_BEGIN` / `PROBE_JSON_END` 之间的原始 JSON；测试结束前
// 保留页面 20s 供 `adb exec-out screencap -p` 截图归档。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:flutter_legado/src/services/rss_web_config.dart';

const String _channelName = 'legadoProbeChannel';

/// 批21f P0：终审 5 条 Chrome 执行向量（真机 WebView 复核清洗后不执行）
const String _mxssPayload = '<h3>RSS mXSS sanitizer probe</h3>'
    '<p>清洗后页面（预期 title=SAFE）</p>'
    '<svg><style>&lt;script&gt;document.title=41&lt;/script&gt;</style></svg>'
    '<svg><xmp>&lt;script&gt;document.title=42&lt;/script&gt;</xmp></svg>'
    '<svg><noscript>&lt;script&gt;document.title=43&lt;/script&gt;'
    '</noscript></svg>'
    '<svg><g><style>&lt;script&gt;document.title=44&lt;/script&gt;'
    '</style></g></svg>'
    '<math><annotation-xml><svg><style>&lt;script&gt;'
    'document.title=45&lt;/script&gt;</style></svg></annotation-xml></math>';

const String _probeHtml = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>RSS WebView channel probe</title></head>
<body style="font-family: monospace; padding: 12px;">
<h3>RSS WebView JavaScriptChannel probe</h3>
<pre id="out">running...</pre>
<script>
(function(){
  var name = '$_channelName';
  var results = [];
  var ch = window[name];
  var desc = Object.getOwnPropertyDescriptor(window, name);
  var initial = {
    step: 'initial',
    typeofChannel: typeof ch,
    hasPostMessage: !!(ch && typeof ch.postMessage === 'function'),
    descriptor: desc ? {
      enumerable: desc.enumerable,
      configurable: desc.configurable,
      writable: desc.writable
    } : null,
    inObjectKeys: Object.keys(window).indexOf(name) >= 0,
    inOwnPropertyNames: Object.getOwnPropertyNames(window).indexOf(name) >= 0
  };
  results.push(initial);
  try { ch.postMessage(JSON.stringify(initial)); } catch (e) {}

  var captured = ch;
  var deleteResult = null;
  var deleteError = null;
  try {
    deleteResult = delete window[name];
  } catch (e) {
    deleteError = String(e);
  }
  var after = {
    step: 'after_delete',
    deleteResult: deleteResult,
    deleteError: deleteError,
    typeofAfterDelete: typeof window[name],
    inOwnPropertyNamesAfterDelete:
      Object.getOwnPropertyNames(window).indexOf(name) >= 0
  };
  var capturedWorked = false;
  try {
    // 先发一条占位消息验证捕获对象仍可 postMessage（不带 after 正文，
    // 避免把尚未写入 capturedStillWorks 字段的对象发给宿主）
    captured.postMessage(JSON.stringify({ step: 'after_delete_probe' }));
    capturedWorked = true;
  } catch (e) {
    after.postError = String(e);
  }
  after.capturedStillWorks = capturedWorked;
  results.push(after);
  if (capturedWorked) {
    // 带完整字段（含 capturedStillWorks）再发一次
    try { captured.postMessage(JSON.stringify(after)); } catch (e) {}
  }

  var done = {
    step: 'done',
    capturedStillWorks: capturedWorked,
    typeofAfterDelete: typeof window[name]
  };
  results.push(done);
  if (capturedWorked) {
    try { captured.postMessage(JSON.stringify(done)); } catch (e) {}
  }
  document.getElementById('out').textContent =
    JSON.stringify(results, null, 2);
})();
</script>
</body>
</html>
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android JavaScriptChannel 可发现性/删除/捕获对象探针', (tester) async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    final messages = <Map<String, dynamic>>[];
    final done = Completer<void>();

    await controller.addJavaScriptChannel(
      _channelName,
      onMessageReceived: (message) {
        try {
          final decoded = jsonDecode(message.message);
          if (decoded is Map) {
            final map = Map<String, dynamic>.from(decoded);
            messages.add(map);
            if (map['step'] == 'done' && !done.isCompleted) {
              done.complete();
            }
          }
        } catch (_) {
          messages.add(<String, dynamic>{'raw': message.message});
        }
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    await controller.loadHtmlString(_probeHtml);
    await done.future.timeout(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 200));

    final payload = const JsonEncoder.withIndent('  ').convert(messages);
    // 供宿主采集的原始证据（测试框架逐行透传 stdout）
    // ignore: avoid_print
    print('PROBE_JSON_BEGIN');
    // ignore: avoid_print
    print(payload);
    // ignore: avoid_print
    print('PROBE_JSON_END');

    expect(messages.any((m) => m['step'] == 'initial'), isTrue);
    expect(messages.any((m) => m['step'] == 'done'), isTrue);

    // 批21f P2-4：把批21e 的实测结论固化为断言（Android 15 / webview_flutter）
    final initial = messages.firstWhere((m) => m['step'] == 'initial');
    expect(initial['typeofChannel'], 'object',
        reason: '平台注入的通道对象在页面脚本中必须是 object');
    expect(initial['hasPostMessage'], isTrue, reason: 'postMessage 必须是函数');

    final after = messages.firstWhere((m) => m['step'] == 'after_delete');
    expect(after['deleteResult'], isTrue,
        reason: 'delete window[channel] 必须返回 true（Android 实测）');
    expect(after['deleteError'], isNull);
    expect(after['typeofAfterDelete'], 'undefined',
        reason: '删除后页面全局不再可见通道');
    expect(after['inOwnPropertyNamesAfterDelete'], isFalse,
        reason: '删除后 getOwnPropertyNames 不再包含通道名');
    expect(after['capturedStillWorks'], isTrue,
        reason: '删除前捕获的对象必须仍可 postMessage（bootstrap 依赖）');

    final doneMessage = messages.firstWhere((m) => m['step'] == 'done');
    expect(doneMessage['capturedStillWorks'], isTrue);
    expect(doneMessage['typeofAfterDelete'], 'undefined');

    // 批21f P0：真机 WebView 加载清洗后的 mXSS 页面，确认脚本未执行
    // （title 初始 SAFE；任一向量执行都会把 title 改成 41..45）
    final sanitized = rssStripPageScripts(_mxssPayload)
        .replaceFirst('<head>', '<head><title>SAFE</title>');
    expect(isSanitizedHtmlSafe(sanitized), isTrue);
    await controller.loadHtmlString(sanitized);
    await tester.pump(const Duration(milliseconds: 500));
    final titleRaw =
        await controller.runJavaScriptReturningResult('document.title');
    final title = titleRaw.toString().replaceAll('"', '');
    // ignore: avoid_print
    print('MXSS_TITLE=$title');
    expect(title, 'SAFE', reason: '清洗后 mXSS 向量不得执行（title 被改写）');

    // 先让平台视图完成至少一帧合成，再打印 READY（截图取到清洗后页面）
    await tester.pump(const Duration(milliseconds: 500));
    // ignore: avoid_print
    print('PROBE_READY');
    // 保留页面展示 20s（持续 pump 帧），供 adb screencap 截图归档
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  });
}
