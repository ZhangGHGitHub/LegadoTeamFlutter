/// 批16a/16d 自动任务导入 FFI 边界运行时验证（P1-3）
///
/// 加载 `rust/target/debug/legado_ffi.dll`，经真实 FRB wire 校验
/// `autoTaskPrepareImported` 的 JSON 边界：
/// - Dart `AutoTaskRule.toJson()` 的 camelCase locals（customOrder/lastRunAt）
///   在合并后必须原样保留（缺陷：旧实现按 snake_case 反序列化 → 清零 →
///   REPLACE 覆盖丢运行历史）；
/// - snake_case 历史 locals 仍可读取（serde alias 兼容）。
///
/// 本用例不打开数据库（prepare_imported 为纯函数），不联网。
/// 前置条件：先在 rust/ 下构建 DLL
/// （cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

String _resolveDll() {
  const libName = 'legado_ffi.dll';
  final sep = Platform.pathSeparator;
  final candidates = <String>[
    '${Directory.current.parent.path}${sep}rust${sep}target${sep}debug$sep$libName',
    '${Directory.current.path}$sep..${sep}rust${sep}target${sep}debug$sep$libName',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

void main() {
  if (!Platform.isWindows) {
    test('跳过自动任务导入 FFI 边界测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_resolveDll()));
    await bridge.init();
  });

  test('camelCase locals 合并后保留 customOrder/lastRunAt（P1-3）', () async {
    final localJson = jsonEncode([
      {
        'id': 'task-1',
        'name': '本地任务',
        'enable': true,
        'cron': '*/30 * * * *',
        'script': 'print(1)',
        'customOrder': 5,
        'lastRunAt': 1712345678901,
        'lastResult': '成功',
        'lastLog': '日志',
      },
    ]);
    final importedJson = jsonEncode([
      {
        'id': 'task-1',
        'name': '导入任务',
        'enable': false,
        'cron': '0 8 * * *',
        'script': 'print(2)',
      },
    ]);

    final mergedJson = await bridge.autoTaskPrepareImported(
      localTasksJson: localJson,
      importedJson: importedJson,
    );
    final merged = (jsonDecode(mergedJson) as List)
        .cast<Map<String, dynamic>>();
    expect(merged, hasLength(1));
    expect(merged.single['customOrder'], 5);
    expect(merged.single['lastRunAt'], 1712345678901);
    expect(merged.single['lastResult'], '成功');
    expect(merged.single['lastLog'], '日志');
    expect(merged.single['name'], '导入任务');
    expect(merged.single['enable'], false);
  });

  test('snake_case 历史 locals 仍可读取（serde alias）', () async {
    final localJson = jsonEncode([
      {
        'id': 'legacy-1',
        'name': '旧本地任务',
        'custom_order': 9,
        'last_run_at': 111,
      },
    ]);
    final mergedJson = await bridge.autoTaskPrepareImported(
      localTasksJson: localJson,
      importedJson: jsonEncode([
        {'id': 'legacy-1', 'name': '导入', 'script': 'x'},
      ]),
    );
    final merged = (jsonDecode(mergedJson) as List)
        .cast<Map<String, dynamic>>();
    expect(merged.single['customOrder'], 9);
    expect(merged.single['lastRunAt'], 111);
  });
}
