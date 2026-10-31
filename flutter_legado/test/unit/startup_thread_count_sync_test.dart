// 批9b-2 单元测试：线程数启动同步 + 默认值
//
// 覆盖口径（任务要求）：
// 1. 未设置偏好 → 默认 32，与 Rust 不同则写入一次（Rust 缺省 32 亦生效）；
// 2. 已存旧值（如 16）→ 原样保留并写入 Rust（只改默认、不迁移用户现值）；
// 3. 偏好与 Rust 相同 → 不写库；
// 4. USE_MOCK → 不读不写（Mock 无 DB）；
// 5. Rust 值非整数 → 视为不同并写入偏好值；
// 6. 读取/写入失败 → 静默不崩（Future 正常完成，不抛异常）。
//
// 生产入口：main.dart `syncThreadCountOnStartup`（启动第 5e 步，await 调用）。
// 语义基准：legado-upstream AppConfig.kt:416-419（threadCount 默认 32）；
// Rust 运行期在搜索/下载入口读 caches config:threadCount（契约批9b-2）。
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

  group('批9b-2 线程数启动同步（syncThreadCountOnStartup）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('未设置偏好 → 默认 32 写入 Rust（缺省值亦镜像）', () async {
      final api = _RecordingApi(rustValue: null);

      await syncThreadCountOnStartup(api, useMock: false);

      expect(api.getCalls, [PrefKeys.threadCount]);
      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.key, PrefKeys.threadCount);
      expect(api.setCalls.single.value, '32', reason: '默认值对齐原版 threadCount=32');
    });

    test('已存旧值 16 → 保留现值并写入 Rust（只改默认不迁移）', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 16});
      final api = _RecordingApi(rustValue: null);

      await syncThreadCountOnStartup(api, useMock: false);

      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.value, '16', reason: '用户已设置的值不得被默认值覆盖');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.threadCount), 16);
    });

    test('偏好与 Rust 相同 → 不写库', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 48});
      final api = _RecordingApi(rustValue: '48');

      await syncThreadCountOnStartup(api, useMock: false);

      expect(api.getCalls, [PrefKeys.threadCount]);
      expect(api.setCalls, isEmpty, reason: '值相同不应产生无谓 DB 写');
    });

    test('Rust 值非整数 → 视为不同并写入偏好值', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 32});
      final api = _RecordingApi(rustValue: 'abc');

      await syncThreadCountOnStartup(api, useMock: false);

      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.value, '32');
    });

    test('USE_MOCK → 不读不写（Mock 无 DB）', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 16});
      final api = _RecordingApi(rustValue: null);

      await syncThreadCountOnStartup(api, useMock: true);

      expect(api.getCalls, isEmpty);
      expect(api.setCalls, isEmpty);
    });

    test('读取配置失败 → 静默不崩（Future 正常完成）', () async {
      final api = _RecordingApi(getThrows: true);

      await expectLater(
        syncThreadCountOnStartup(api, useMock: false),
        completes,
        reason: '启动同步失败不得阻断启动',
      );
      expect(api.setCalls, isEmpty);
    });

    test('写入配置失败 → 静默不崩（Future 正常完成）', () async {
      final api = _RecordingApi(setThrows: true);

      await expectLater(
        syncThreadCountOnStartup(api, useMock: false),
        completes,
        reason: 'FFI/DB 失败不得阻断启动',
      );
      expect(api.setCalls, hasLength(1));
    });
  });
}
