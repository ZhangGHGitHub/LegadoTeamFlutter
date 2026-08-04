// E2E 集成测试：导入书源（新御书屋/千夜）后的搜索→加书架→阅读全链路
//
// 前置条件：
//   - 已通过 UI（我的→书源管理→本地导入）导入 yckceo 7631 书源，
//     与测试共用同一 legado.db（getApplicationDocumentsDirectory()）。
//   - 需要预构建的 legado_ffi 动态库（Android x86_64 .so）。
//
// 运行方式：
//   flutter test integration_test/e2e_search_read_test.dart -d emulator-5556
//
// 说明：本文件位于 integration_test/ 目录，不会被 `flutter test` 自动拾取，
// 不影响 test/ 目录下的单元测试基线。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'package:flutter_legado/app.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

/// 目标书源（goal 指定）：yckceo 7631「新御书屋(千夜)」
const _sourceUrl = 'https://www.yckceo.com/yuedu/shuyuan/json/id/7631.json';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E2E: 导入书源→搜索→加书架→打开书籍', (tester) async {
    // 1. 初始化 Rust 引擎（全局一次性：FFI 初始化 + 打开 legado.db）
    final api = RustApi();
    await tester.runAsync(() => api.initialize());

    // 2. 自包含前置：在线下载并导入 yckceo 7631 书源
    //    （集成测试会卸载重装应用，设备数据不持久，必须自行导入）
    await tester.runAsync(() async {
      final resp = await http
          .get(Uri.parse(_sourceUrl))
          .timeout(const Duration(seconds: 30));
      expect(resp.statusCode, 200, reason: '书源下载失败: HTTP ${resp.statusCode}');
      final n = await api.importBookSources(resp.body);
      debugPrint('[E2E] 导入书源数量: $n');
      expect(n, greaterThanOrEqualTo(1), reason: '书源导入失败');
    });

    // 3. 启动真实应用（主页），从书架顶栏进入搜索页
    await tester.pumpWidget(
      const ProviderScope(
        child: LegadoApp(initialRoute: AppRoutes.home),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索').first);
    await tester.pumpAndSettle();
    debugPrint('[E2E] 搜索页已加载');

    // 4. 输入中文关键词并提交搜索
    await tester.enterText(find.byType(TextField).first, '都市');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    debugPrint('[E2E] 已提交搜索：都市');

    // 5. 等待搜索结果（真实网络请求，轮询最多 60 秒）
    // 注意：必须交替「真实等待（runAsync）」与「pump 重建 UI」，
    // 否则状态到达后 widget 树不重建，ListTile 不会出现。
    var foundResult = false;
    for (var i = 0; i < 30 && !foundResult; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();
      foundResult = tester.any(find.byType(ListTile));
    }
    expect(
      foundResult,
      isTrue,
      reason: () {
        final texts = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .where((s) => s.trim().isNotEmpty)
            .toList();
        return '搜索应返回至少一条结果；当前屏幕文本: $texts';
      }(),
    );
    debugPrint('[E2E] 搜索结果已出现');

    // 5b. 保持搜索结果画面 8 秒，供宿主侧 adb 截图取证
    debugPrint('[E2E-HOLD] RESULTS');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 8)));

    // 6. 点击首条结果 → 书籍详情对话框；书名取对话框标题（ListTile title）
    final firstTile = find.byType(ListTile).first;
    await tester.tap(firstTile);
    await tester.pumpAndSettle();
    final bookName = tester
        .widget<Text>(
            find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)).first)
        .data!;
    expect(bookName, isNotEmpty, reason: '书名不应为空');
    debugPrint('[E2E] 首条结果：$bookName');
    debugPrint('[E2E] 已打开书籍详情对话框');

    // 6b. 保持详情对话框画面 8 秒，供宿主截图
    debugPrint('[E2E-HOLD] DIALOG');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 8)));

    // 7. 点击「加入书架」
    final addButton = find.textContaining('加入书架');
    expect(addButton, findsWidgets);
    await tester.tap(addButton.last);
    await tester.pumpAndSettle();
    debugPrint('[E2E] 已加入书架');

    // 8. 返回书架，按书名定位刚加入的书并打开
    await tester.runAsync(() async {
      // 等待 SnackBar 消失
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 书架可能需等待加载；轮询书名文本（同样交替真实等待与 pump）
    var shelfReady = false;
    for (var i = 0; i < 10 && !shelfReady; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      shelfReady = tester.any(find.text(bookName));
    }
    expect(shelfReady, isTrue, reason: '书架应显示刚加入的书「$bookName」');

    // 8b. 保持书架画面 8 秒，供宿主截图
    debugPrint('[E2E-HOLD] SHELF');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 8)));

    await tester.tap(find.text(bookName).first);
    await tester.pumpAndSettle();
    debugPrint('[E2E] 已点击书籍「$bookName」，进入阅读/详情页');

    // 9. 保持最终画面 20 秒，便于宿主侧 adb 截图取证
    debugPrint('[E2E-HOLD] READER');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 20)));
    debugPrint('[E2E] 全链路验证完成');
  });
}
