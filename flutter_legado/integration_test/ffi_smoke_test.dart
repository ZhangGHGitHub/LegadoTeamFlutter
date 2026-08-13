// Flutter↔Rust 端到端 FFI 集成冒烟测试
//
// 覆盖点：
//   1. RustApi.initialize() — 验证 Rust 运行时初始化 + 数据库打开
//   2. getVersion() — 验证 FFI 往返调用返回有效版本号
//   3. getBookSources() — 验证真实 DB 查询往返（不依赖外网）
//
// 限制：
//   - 不覆盖真实书源联网搜索/下载
//   - 不覆盖 JS 引擎执行（需 quickjs feature 但此处仅验证 DB 路径）
//   - 需要预构建的 legado_ffi 动态库（DLL/SO/DYLIB）
//
// 运行方式：
//   flutter test integration_test -d windows
//   （需要先 cargo build -p legado-ffi --features quickjs）
//
// 注意：此文件位于 integration_test/ 目录，不会被 `flutter test` 自动拾取，
// 因此不影响 test/ 目录下的单元测试基线。

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Flutter↔Rust FFI 集成冒烟', () {
    late RustApi api;

    setUpAll(() async {
      api = RustApi();
    });

    testWidgets('initialize() 不抛异常', (tester) async {
      // 验证 Rust 运行时初始化 + tokio runtime 创建 + DB 打开
      await api.initialize();
      // 无异常即通过
    });

    testWidgets('getVersion() 返回有效版本号', (tester) async {
      await api.initialize();
      final version = await api.getVersion();
      // 版本号应为非空字符串，格式类似 "0.1.0"
      expect(version, isNotEmpty);
      expect(version, contains('.'));
    });

    testWidgets('getBookSources() FFI 往返正常', (tester) async {
      await api.initialize();
      // sourceList() 是纯 DB 查询，不依赖外网
      // 空数据库返回空列表也是合法的
      final sources = await api.getBookSources();
      expect(sources, isA<List>());
      // 不抛异常 + 返回结构合理即通过
    });
  });
}
