// 批9b-1 单元测试：「自动清除过期搜索」启动接线
//
// 覆盖口径（任务要求）：
// 1. 开关 true（默认，无偏好键）→ 调用一次且参数 ≈ now - 1 天（容差 5s）；
// 2. 开关 false → 不调用；
// 3. USE_MOCK → 不调用（Mock 环境跳过，避免测试触碰 DB）；
// 4. 开关读取/FFI 调用失败 → 静默不崩（返回完成，不抛异常）。
//
// 生产入口：main.dart `clearExpiredSearchBooksOnStartup`（unawaited 调用）。
// 契约：docs/API_CONTRACT.md §2.15 `clearExpiredSearchBooks`（FFI
// `search_books_clear_expired`）；语义基准 legado-upstream App.kt:114-117。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/main.dart';
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/book_api.dart';

/// 记录 clearExpiredSearchBooks 调用参数的桩 BookApi
///
/// 仅实现被测面（未实现方法抛 UnimplementedError）；清理失败场景由
/// [clearThrows] 注入异常。
class _RecordingApi implements BookApi {
  _RecordingApi({this.clearThrows = false});

  final bool clearThrows;
  final List<int> clearCalls = <int>[];

  @override
  Future<int> clearExpiredSearchBooks(int beforeTimestampMs) async {
    if (clearThrows) {
      throw StateError('FFI 清理失败（注入）');
    }
    clearCalls.add(beforeTimestampMs);
    return 3;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('本桩未实现：${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('批9b-1 自动清除过期搜索启动接线（clearExpiredSearchBooksOnStartup）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('开关默认 true（无偏好键）→ 调用一次且参数 ≈ now - 1 天', () async {
      final api = _RecordingApi();
      final beforeRun = DateTime.now().millisecondsSinceEpoch;

      await clearExpiredSearchBooksOnStartup(api, useMock: false);

      final afterRun = DateTime.now().millisecondsSinceEpoch;
      expect(api.clearCalls.length, 1, reason: '开关开（默认）应恰好调用一次');
      // 原版 clearTime = now - TimeUnit.DAYS.toMillis(1) = now - 86400000
      expect(api.clearCalls.single, greaterThanOrEqualTo(beforeRun - 86400000));
      expect(
        api.clearCalls.single,
        lessThanOrEqualTo(afterRun - 86400000),
        reason: '阈值应为运行时刻减整 1 天（容差 5s 覆盖取时刻间隙）',
      );
      expect(api.clearCalls.single, closeTo(beforeRun - 86400000, 5000));
    });

    test('开关显式 true → 调用一次', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.autoClearExpired: true,
      });
      final api = _RecordingApi();

      await clearExpiredSearchBooksOnStartup(api, useMock: false);

      expect(api.clearCalls.length, 1);
    });

    test('开关 false → 不调用', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.autoClearExpired: false,
      });
      final api = _RecordingApi();

      await clearExpiredSearchBooksOnStartup(api, useMock: false);

      expect(api.clearCalls, isEmpty, reason: '关闭时不清理（对齐原版语义）');
    });

    test('USE_MOCK 模式 → 不调用（Mock 环境跳过，避免触碰 DB）', () async {
      final api = _RecordingApi();

      await clearExpiredSearchBooksOnStartup(api, useMock: true);

      expect(api.clearCalls, isEmpty);
    });

    test('FFI 清理失败 → 静默不崩（Future 正常完成）', () async {
      final api = _RecordingApi(clearThrows: true);

      await expectLater(
        clearExpiredSearchBooksOnStartup(api, useMock: false),
        completes,
        reason: '清理失败静默降级，不阻断启动',
      );
    });

    test('unawaited 语义：返回 Future 独立执行不抛未捕获异常', () async {
      final api = _RecordingApi(clearThrows: true);
      // 生产调用形态为 unawaited(...)：失败仅 debugPrint，
      // zone 不应收到未捕获异常（本测试自行 await 捕获验证）
      final f = clearExpiredSearchBooksOnStartup(api, useMock: false);
      unawaited(f);
      await expectLater(f, completes);
    });
  });
}
