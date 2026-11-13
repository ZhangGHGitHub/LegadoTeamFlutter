import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [P2-4] UI 层错误文案禁止裸插值 `$e` 回归守卫
///
/// `BridgeError` 无自定义 `toString()`，`'保存失败：$e'` 会显示
/// 「Instance of 'BridgeError'」。UI 层（screens/widgets）用户可见文案
/// 必须走 `errorMessage(e)`；日志（debugPrint/_log/_appendLog）不受限，
/// 以便排查保留原始异常。
///
/// 允许的例外（非异常对象/桥协议/日志续行）在 [allowedSnippets] 中显式
/// 列出；新增例外须附理由，不得直接放宽整目录。
void main() {
  test('screens/widgets 用户可见文案不得裸插值 \$e（P2-4）', () {
    final roots = [Directory('lib/src/screens'), Directory('lib/src/widgets')];
    final violations = <String>[];

    const logMarkers = ['debugPrint(', 'print(', '_log(', '_appendLog'];
    const allowedSnippets = [
      // 已有 BridgeError 分支的等价安全写法
      "e is BridgeError ? e.message : '\$e'",
      // 服务端返回的字符串列表/桥协议错误回执，不是异常对象
      "'• \$e'",
      "value.map((e) => '\$e')",
      "msgs.map((e) => '\$e')",
      "emit('error: \$e')",
      "submitWebviewResult(key, '[ERROR] \$e')",
      // 多行 debugPrint 的续行
      'Rust 真源沿用旧值/缺省）: \$e',
      '下一次 build 重试）: \$e',
    ];

    final interpolation = RegExp(r'\$e\b');
    for (final root in roots) {
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//')) continue;
          if (logMarkers.any(line.contains)) continue;
          if (allowedSnippets.any(line.contains)) continue;
          if (interpolation.hasMatch(line)) {
            violations.add('${entity.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '用户可见错误文案必须用 errorMessage(e)，禁止裸插值 \$e：\n'
          '${violations.join('\n')}',
    );
  });
}
