import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/book_grid_item.dart';

/// §4.4 性能基线 —— 冷启动基准测试
///
/// 目标：应用首帧构建 + 布局 + 绘制耗时 < 3000ms（冷启动基准）。
///
/// 说明：
/// - 完整的 LegadoApp 依赖 RustApi FFI 初始化，无法在纯 widget 测试环境运行，
///   因此这里用"代表性应用壳"（MaterialApp + Scaffold + 书架式网格）作为代理，
///   覆盖真实冷启动路径中的核心开销：Material 主题构建、Scaffold 布局、
///   书架网格（BookGridItem）的首帧 build/layout。
/// - widget 测试环境无真实 GPU 渲染，Stopwatch 测量的是 CPU 侧
///   build/layout/pump 耗时，作为冷启动性能的代理指标。
/// - 真实冷启动数据需在设备上以 profile 模式运行 `flutter run --profile`
///   并观察 DevTools 的 App Startup 时间线。
void main() {
  testWidgets('冷启动基准：首帧构建耗时 < 3000ms', (tester) async {
    // 模拟书架数据（不传真实 coverUrl，避免网络/平台通道依赖）
    final books = List.generate(
      60,
      (i) => _FakeBook(title: '书籍 $i', author: '作者 $i'),
    );

    final stopwatch = Stopwatch()..start();

    await tester.pumpWidget(
      MaterialApp(
        title: 'Legado 阅读',
        home: Scaffold(
          appBar: AppBar(title: const Text('书架')),
          body: _BookshelfShell(books: books),
        ),
      ),
    );

    // 等待首帧完成（包含所有同步构建与布局）
    await tester.pump();
    stopwatch.stop();

    final elapsedMs = stopwatch.elapsedMilliseconds;

    // 记录实际基线数据（用于性能回归对比）
    // ignore: avoid_print
    print('[性能基线][冷启动] 首帧构建耗时: ${elapsedMs}ms（目标 < 3000ms）');

    // 冷启动基准断言：首帧必须 < 3s
    expect(
      elapsedMs,
      lessThan(3000),
      reason: '冷启动首帧耗时 ${elapsedMs}ms 超过 3000ms 基准，'
          '建议排查首帧 build 中的重计算或同步 IO',
    );

    // 验证书架网格确实渲染出来（确保测量的是真实路径）
    expect(find.text('书籍 0'), findsOneWidget);
  });

  testWidgets('冷启动基准：首帧布局尺寸正确', (tester) async {
    final books = List.generate(
      10,
      (i) => _FakeBook(title: '书籍 $i', author: '作者 $i'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('书架')),
          body: _BookshelfShell(books: books),
        ),
      ),
    );
    await tester.pump();

    // 网格应填满可用区域
    final gridFinder = find.byType(GridView);
    expect(gridFinder, findsOneWidget);
    final grid = tester.renderObject<RenderBox>(gridFinder);
    expect(grid.size.width, greaterThan(0));
    expect(grid.size.height, greaterThan(0));
  });
}

/// 书架数据替身（纯数据，不依赖 FFI 模型）
class _FakeBook {
  final String title;
  final String author;

  const _FakeBook({required this.title, required this.author});
}

/// 代表性书架壳：复刻 bookshelf_screen 的网格布局结构
///
/// 使用真实的 [BookGridItem] 组件，确保测量覆盖书架列表项的构建开销。
class _BookshelfShell extends StatelessWidget {
  final List<_FakeBook> books;

  const _BookshelfShell({required this.books});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        // 与 bookshelf_screen 保持一致：RepaintBoundary + 稳定 ValueKey
        final item = BookGridItem(
          key: ValueKey(book.title),
          title: book.title,
          author: book.author,
          progress: 0.5,
        );
        return RepaintBoundary(child: item);
      },
    );
  }
}
