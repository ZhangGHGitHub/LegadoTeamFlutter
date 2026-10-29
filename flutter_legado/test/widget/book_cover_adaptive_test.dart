// 封面比例开关 widget 测试（批39）
//
// 覆盖：
// - 「限制封面比例」开启（默认）时保持固定高度（既有视觉不变）；
// - 关闭后按已解析原图比例换算高度（0.5 → 宽 × 2），并受上下限约束；
// - 设置切换即时生效（uiSettingsListenable 广播）；
// - [批39 审查回修] 真实图片解码上报比例后：restrict=true 不递增修订号
//   （避免每张封面都触发书架/发现网格整屏重建），restrict=false 才递增；
// - 比例未知时按调用方声明的 height/width 回退（而非固定 5:7）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/cover_aspect_ratio.dart';
import 'package:flutter_legado/src/services/cover_decode_loader.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';

import '../mocks/mocks.dart';

/// 真实 2×1 PNG（解码宽高比 2.0 → 缓存收敛到 maxRatio 1.5）
const String _kPng2x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4z8AARAAI/gH/xp559wAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'http://cover.test/book.jpg';

  setUp(() {
    CoverAspectRatio.clear();
    CoverDecodeLoader.clearForTest();
    uiSettingsListenable.value = const UiSettingsState();
    SharedPreferences.setMockInitialValues({});
    // 预置已解析比例（宽/高 = 0.5 → 高度 = 宽 × 2）
    CoverAspectRatio.remember(url, 0.5);
  });

  Widget host({double width = 70, double height = 100}) => ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockRustApi())],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: BookCover(
                coverUrl: url,
                width: width,
                height: height,
                adaptAspectRatio: true,
                adaptiveMinHeight: 50,
                adaptiveMaxHeight: 200,
              ),
            ),
          ),
        ),
      );

  testWidgets('限制比例开启（默认）：固定高度', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(tester.getSize(find.byType(BookCover)).height, 100);
  });

  testWidgets('关闭后按原图比例自适应，切换设置即时生效', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(tester.getSize(find.byType(BookCover)).height, 100);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BookCover)),
    );
    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(false);
    await tester.pumpAndSettle();

    // 宽 70 / 0.5 = 140（在 50..200 内）
    expect(
      tester.getSize(find.byType(BookCover)).height,
      closeTo(140, 0.01),
    );

    // 再开启恢复固定高度
    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(true);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BookCover)).height, 100);
  });

  testWidgets('自适应高度受上下限约束（横版封面）', (tester) async {
    CoverAspectRatio.remember(url, 2.0); // 横版 → 收敛到 1.5
    await tester.pumpWidget(host());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BookCover)),
    );
    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(false);
    await tester.pumpAndSettle();

    // 宽 70 / 1.5 = 46.7 → 下限 50
    expect(
      tester.getSize(find.byType(BookCover)).height,
      closeTo(50, 0.01),
    );
  });

  // ─── [批39 审查回修] 修订号门控 / 真实图片 / 未知比例回退 ───────────────

  const realUrl = 'http://cover.test/real.png';

  Widget realHost({
    required String coverUrl,
    double width = 70,
    double height = 100,
    String? sourceOrigin,
  }) =>
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockRustApi())],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: BookCover(
                coverUrl: coverUrl,
                width: width,
                height: height,
                sourceOrigin: sourceOrigin,
                adaptAspectRatio: true,
                adaptiveMinHeight: width * 0.5,
                adaptiveMaxHeight: height * 2,
              ),
            ),
          ),
        ),
      );

  /// 等真实图片解码上报（engine 异步，需要 runAsync + 再 pump）
  Future<void> settleRealImage(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('restrict=true：真实图片比例上报不递增修订号', (tester) async {
    // 缓存里已有别的封面比例 → 本次写入不是「首个已知比例」
    CoverAspectRatio.clear();
    CoverAspectRatio.remember('http://cover.test/other.jpg', 0.6);
    CoverDecodeLoader.putCached(
      'src',
      realUrl,
      Uint8List.fromList(base64Decode(_kPng2x1)),
    );
    final revBefore = coverAspectRatioRevision.value;

    await tester.pumpWidget(realHost(coverUrl: realUrl, sourceOrigin: 'src'));
    await settleRealImage(tester);

    // 比例已入缓存（后续列表回收可直接落在最终高度）
    expect(CoverAspectRatio.cached(realUrl), closeTo(1.5, 1e-9));
    // 但限制比例开启（默认）时网格行高固定，不得触发整屏重算
    expect(
      coverAspectRatioRevision.value,
      revBefore,
      reason: 'restrict=true 时逐张封面递增修订号会导致整屏重建',
    );
    expect(tester.getSize(find.byType(BookCover)).height, 100);
  });

  testWidgets('restrict=false：真实图片比例上报递增修订号并自适应高度',
      (tester) async {
    CoverAspectRatio.clear();
    CoverAspectRatio.remember('http://cover.test/other.jpg', 0.6);
    CoverDecodeLoader.putCached(
      'src',
      realUrl,
      Uint8List.fromList(base64Decode(_kPng2x1)),
    );
    uiSettingsListenable.value =
        const UiSettingsState(restrictCoverRatio: false);
    final revBefore = coverAspectRatioRevision.value;

    await tester.pumpWidget(realHost(coverUrl: realUrl, sourceOrigin: 'src'));
    await settleRealImage(tester);

    expect(coverAspectRatioRevision.value, revBefore + 1);
    // 宽 70 / 1.5 = 46.67 → 下限 35（width × 0.5）
    expect(
      tester.getSize(find.byType(BookCover)).height,
      closeTo(70 / 1.5, 0.01),
    );
  });

  testWidgets('比例未知：按 height/width 回退（不是固定 5:7）', (tester) async {
    uiSettingsListenable.value =
        const UiSettingsState(restrictCoverRatio: false);
    // 该 URL 无缓存比例、无本地字节 → 网络图在测试环境不可用，保持未知
    await tester.pumpWidget(
      realHost(coverUrl: 'http://cover.test/unknown.jpg', width: 60, height: 90),
    );
    await tester.pump();

    // 回退用调用方声明的 60:90 → 高度即 90；若按 5:7 会是 84
    expect(CoverAspectRatio.cached('http://cover.test/unknown.jpg'), isNull);
    expect(tester.getSize(find.byType(BookCover)).height, 90);
  });
}
