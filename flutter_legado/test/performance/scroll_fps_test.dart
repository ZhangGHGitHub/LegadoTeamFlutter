import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// §4.4 性能基线 —— 列表滚动 FPS 基准测试
///
/// 目标：长列表滚动帧率 > 55 FPS（即平均每帧 CPU 耗时 < 16.7ms）。
///
/// 说明：
/// - widget 测试环境运行在虚拟帧时钟上，无真实 GPU 合成，
///   因此这里测量"滚动过程中每一帧的 CPU 侧 build/layout 耗时"，
///   以平均帧耗时换算估算 FPS，作为滚动流畅度的代理指标。
/// - 估算 FPS = 1000 / 平均帧耗时(ms)。该值反映 Dart 侧构建开销，
///   真实渲染帧率需在设备上以 profile 模式运行并用 DevTools Performance
///   面板观察 Frame Rendering Stats。
/// - 列表项使用与搜索结果/RSS 列表一致的"RepaintBoundary + ValueKey"结构，
///   验证 §4.2 列表渲染优化的实际收益。
void main() {
  testWidgets('列表滚动基准：平均帧耗时 < 16.7ms（估算 > 55 FPS）',
      (tester) async {
    // 构建 200 项的长列表（模拟搜索结果/RSS 文章列表规模）
    final items = List.generate(200, (i) => '列表项 $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            // 与生产代码一致的预缓存范围
            cacheExtent: 300,
            itemCount: items.length,
            itemBuilder: (context, index) {
              // 与 search_screen/rss_articles_screen 一致：
              // RepaintBoundary 隔离 + 稳定 ValueKey
              final item = _ListItem(
                key: ValueKey(items[index]),
                title: items[index],
                subtitle: '副标题 $index',
              );
              return RepaintBoundary(child: item);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // 触发快速滚动（fling），随后逐帧 pump 并测量每帧耗时
    final frameDurations = <int>[];
    final stopwatch = Stopwatch();

    await tester.fling(
      find.byType(ListView),
      const Offset(0, -800),
      1200,
    );

    // 滚动动画持续期间逐帧采样
    for (var i = 0; i < 40; i++) {
      stopwatch
        ..reset()
        ..start();
      await tester.pump(const Duration(milliseconds: 16));
      stopwatch.stop();
      frameDurations.add(stopwatch.elapsedMicroseconds);
    }

    // 让滚动完全结束，避免遗留动画导致测试不稳定
    await tester.pumpAndSettle();

    // 统计平均帧耗时（微秒 → 毫秒）
    final avgMicros =
        frameDurations.reduce((a, b) => a + b) / frameDurations.length;
    final avgMs = avgMicros / 1000.0;
    final estimatedFps = avgMs > 0 ? 1000.0 / avgMs : double.infinity;
    final maxMs = frameDurations.reduce((a, b) => a > b ? a : b) / 1000.0;

    // 记录实际基线数据
    // ignore: avoid_print
    print('[性能基线][列表滚动] 平均帧耗时: ${avgMs.toStringAsFixed(2)}ms, '
        '最大帧耗时: ${maxMs.toStringAsFixed(2)}ms, '
        '估算帧率: ${estimatedFps.toStringAsFixed(1)} FPS（目标 > 55 FPS）');

    // 基准断言：平均帧耗时应 < 16.7ms（对应 60 FPS 的帧预算）
    expect(
      avgMs,
      lessThan(16.7),
      reason: '列表滚动平均帧耗时 ${avgMs.toStringAsFixed(2)}ms 超过 16.7ms 帧预算，'
          '建议检查列表项 build 复杂度或补充 RepaintBoundary',
    );
  });

  testWidgets('列表滚动基准：滚动后内容正确更新', (tester) async {
    final items = List.generate(100, (i) => '列表项 $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            cacheExtent: 300,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = _ListItem(
                key: ValueKey(items[index]),
                title: items[index],
                subtitle: '副标题 $index',
              );
              return RepaintBoundary(child: item);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // 首屏应显示第一项
    expect(find.text('列表项 0'), findsOneWidget);

    // 滚动后应能看到更后面的项
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 1200);
    await tester.pumpAndSettle();

    // 滚动后第一项应离开视口（被回收），后面的项出现
    expect(find.text('列表项 0'), findsNothing);
  });
}

/// 列表项：复刻搜索结果/RSS 文章列表项的结构复杂度
/// （双行文本 + 图标 + 分隔线，覆盖典型列表项的构建开销）
class _ListItem extends StatelessWidget {
  final String title;
  final String subtitle;

  const _ListItem({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.article)),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
