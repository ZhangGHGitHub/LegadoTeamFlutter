// 批9b-4 单元测试：全局 UserAgent 启动同步
//
// 覆盖口径（任务要求）：
// 1. 偏好非空且与 Rust 不同 → 调用一次 setConfig('userAgent', 偏好值)；
// 2. 偏好与 Rust 相同 → 不写库；
// 3. 偏好为空且 Rust 有旧值 → 写空串清除（回落 Rust 内置默认）；
// 4. 偏好为空且 Rust 为空 → 不写库；
// 5. USE_MOCK → 不读不写（Mock 无 DB）；
// 6. 读取/写入失败 → 静默不崩（Future 正常完成，不抛异常）。
//
// 生产入口：main.dart `syncUserAgentOnStartup`（启动第 5d 步，await 调用）。
// 语义基准：legado-upstream AppConfig.kt:48,135,918-925（用户全局 UA，
// 空白回落内置默认）；HttpHelper.kt:70-77（请求期注入）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/main.dart';
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/book_api.dart';

/// 记录 getConfig/setConfig 的桩 BookApi（仅实现被测面）
class _RecordingApi implements BookApi {
  _RecordingApi({
    this.rustValue,
    this.getThrows = false,
    this.setThrows = false,
  });

  String? rustValue;
  final bool getThrows;
  final bool setThrows;
  final List<String> getCalls = <String>[];
  final List<MapEntry<String, String>> setCalls = <MapEntry<String, String>>[];

  @override
  Future<String?> getConfig(String key) async {
    getCalls.add(key);
    if (getThrows) {
      throw StateError('读取配置失败（注入）');
    }
    return rustValue;
  }

  @override
  Future<void> setConfig(String key, String value) async {
    setCalls.add(MapEntry(key, value));
    if (setThrows) {
      throw StateError('写入配置失败（注入）');
    }
    rustValue = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('本桩未实现：${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('批9b-4 全局 UserAgent 启动同步（syncUserAgentOnStartup）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('偏好非空且与 Rust 不同 → 写入一次', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.userAgent: ' GlobalUA/9.9 ',
      });
      final api = _RecordingApi(rustValue: null);

      await syncUserAgentOnStartup(api, useMock: false);

      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.key, PrefKeys.userAgent);
      expect(
        api.setCalls.single.value,
        'GlobalUA/9.9',
        reason: '启动同步写入 trim 后的偏好值（与设置页保存口径一致）',
      );
    });

    test('偏好与 Rust 相同 → 不写库', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.userAgent: 'SameUA/1.0',
      });
      final api = _RecordingApi(rustValue: 'SameUA/1.0');

      await syncUserAgentOnStartup(api, useMock: false);

      expect(api.setCalls, isEmpty, reason: '值相同不应产生无谓 DB 写');
    });

    test('偏好为空且 Rust 有旧值 → 写空串清除（回落内置默认）', () async {
      final api = _RecordingApi(rustValue: 'StaleUA/0.1');

      await syncUserAgentOnStartup(api, useMock: false);

      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.value, '');
    });

    test('偏好为空且 Rust 为空/无值 → 不写库', () async {
      final nullApi = _RecordingApi(rustValue: null);
      await syncUserAgentOnStartup(nullApi, useMock: false);
      expect(nullApi.setCalls, isEmpty);

      final emptyApi = _RecordingApi(rustValue: '   ');
      await syncUserAgentOnStartup(emptyApi, useMock: false);
      expect(emptyApi.setCalls, isEmpty);
    });

    test('USE_MOCK → 不读不写（Mock 无 DB）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.userAgent: 'MockUA/1.0',
      });
      final api = _RecordingApi(rustValue: null);

      await syncUserAgentOnStartup(api, useMock: true);

      expect(api.getCalls, isEmpty);
      expect(api.setCalls, isEmpty);
    });

    test('读取配置失败 → 静默不崩（Future 正常完成）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.userAgent: 'GlobalUA/9.9',
      });
      final api = _RecordingApi(getThrows: true);

      await expectLater(
        syncUserAgentOnStartup(api, useMock: false),
        completes,
        reason: '启动同步失败不得阻断启动',
      );
      expect(api.setCalls, isEmpty);
    });

    test('写入配置失败 → 静默不崩（Future 正常完成）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.userAgent: 'GlobalUA/9.9',
      });
      final api = _RecordingApi(setThrows: true);

      await expectLater(
        syncUserAgentOnStartup(api, useMock: false),
        completes,
        reason: 'FFI/DB 失败不得阻断启动',
      );
      expect(api.setCalls, hasLength(1));
    });
  });
}
