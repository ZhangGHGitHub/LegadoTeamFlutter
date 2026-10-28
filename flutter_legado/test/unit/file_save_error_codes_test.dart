// Kotlin/Dart 错误码表一致性测试（批26b P3-7）
//
// 背景：Android 保存错误码有两份面向用户的兜底文案——Kotlin
// `SaveFileBridge.reasonOf`（原生 replyError 的 message）与 Dart
// `MethodChannelFileSaveChannel.errorReasons`（平台异常 message 为空时）。
// 新增/修改错误码时若只改一侧，用户会看到不一致文案。本测试直接读取
// Kotlin 源文件并逐条比对两张表，作为跨语言契约的守门测试。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/file_save_channel.dart';

/// 从当前目录向上查找 Kotlin 桥接源码（兼容从 flutter_legado 或仓库根运行）
File _findBridgeSource() {
  const relative =
      'android/app/src/main/kotlin/io/legado/flutter/SaveFileBridge.kt';
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}$relative');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('未找到 $relative（起点 ${Directory.current.path}）');
}

void main() {
  test('Dart 错误码表与 Kotlin reasonOf 逐条一致', () {
    final source = _findBridgeSource().readAsStringSync();
    final start = source.indexOf('internal fun reasonOf');
    expect(start, greaterThanOrEqualTo(0), reason: '未找到 reasonOf');

    // reasonOf 位于 companion 内（缩进 8），函数体在 4 空格缩进处收尾
    final end = source.indexOf('\n    }', start);
    expect(end, greaterThan(start), reason: '未找到 reasonOf 结尾');

    final kotlinReasons = <String, String>{};
    final entry = RegExp(r'"([A-Z][A-Z0-9_]*)"\s*->\s*"([^"]*)"');
    for (final match in entry.allMatches(source.substring(start, end))) {
      kotlinReasons[match.group(1)!] = match.group(2)!;
    }

    expect(kotlinReasons, isNotEmpty, reason: '未能从 Kotlin 源解析错误码');
    // 两张表必须完全相同（新增错误码只改一侧会在这里失败）
    expect(MethodChannelFileSaveChannel.errorReasons, kotlinReasons);
  });
}
