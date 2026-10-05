import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/video_float_window_button.dart';

/// [V-B3] 悬浮窗入口按钮 widget 测试
/// （对齐原版 menu_float_window「悬浮窗」视频页动作；解析出地址前禁用）。
void main() {
  testWidgets('渲染「悬浮窗」tooltip 且点击回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [
            VideoFloatWindowButton(onPressed: () => taps++),
          ],
        ),
      ),
    ));
    expect(find.byType(VideoFloatWindowButton), findsOneWidget);
    expect(find.byTooltip('悬浮窗'), findsOneWidget);
    await tester.tap(find.byType(VideoFloatWindowButton));
    expect(taps, 1);
  });

  testWidgets('onPressed 为空时禁用（解析出地址前）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: const [VideoFloatWindowButton(onPressed: null)],
        ),
      ),
    ));
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
  });
}
