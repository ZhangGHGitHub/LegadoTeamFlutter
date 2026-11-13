import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [P2-2] 用户可见错误文案禁止裸插值异常对象（回归守卫）
///
/// `BridgeError` 没有自定义 `toString()`，`'保存失败：$e'` 会显示
/// 「Instance of 'BridgeError'」。因此：
/// - screens/widgets 里的用户可见文案；
/// - providers/services 里组装给 UI 的文案（本次批改含 5 个 provider 与
///   多个 service）；
/// 都必须走 `errorMessage(e)`。
///
/// 例外只有两类，且都必须精确：
/// 1. **日志调用实参**（`debugPrint` / `print` / `_log` / `_appendLog` /
///    `logMessage` / `CrashLogService...put`）：仅该调用的括号范围内豁免，
///    同一行其他位置的用户可见插值仍报错——不做整行放过；
/// 2. [allowedSnippets] 中显式列出的非异常对象/转义字面量：仅命中片段本身
///    豁免（同样不整行放过），新增须附理由。
///
/// 生成文件（`.freezed.dart` / `.g.dart`）不含手写文案，跳过；注释
/// （`//` 与 `/* */`，含行内注释）与转义 `\$` 不算命中。扫描根目录与
/// 文件数都有下界断言，避免目录被移动/清空后**真空通过**。
void main() {
  test('用户可见错误文案不得裸插值异常对象（P2-2）', () {
    final violations = <String>[];
    var scannedFiles = 0;
    final perRoot = <String, int>{};

    for (final root in _roots) {
      final dir = Directory(root);
      expect(
        dir.existsSync(),
        isTrue,
        reason: '守卫扫描根目录不存在：$root。目录移动/改名后必须同步更新守卫范围。',
      );
      var rootCount = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // freezed/json_serializable 生成文件不含手写文案（toString 仅供调试）
        if (_isGeneratedFile(entity.path)) continue;
        rootCount++;
        final source = entity.readAsStringSync();
        violations.addAll(_scanSource(entity.path, source));
      }
      expect(
        rootCount,
        greaterThan(40),
        reason:
            '扫描根目录 $root 仅命中 $rootCount 个 dart 文件，疑似被移动/清空；'
            '不得让守卫真空通过。',
      );
      perRoot[root] = rootCount;
      scannedFiles += rootCount;
    }

    expect(
      scannedFiles,
      greaterThan(300),
      reason: '守卫必须实际扫描到文件（当前 $perRoot），否则范围失效会真空通过。',
    );
    expect(
      violations,
      isEmpty,
      reason:
          '用户可见错误文案必须用 errorMessage(e)，禁止裸插值异常对象：\n'
          '${violations.join('\n')}',
    );
  });

  // 守卫自检：防止扫描器/正则改坏后「零命中」真空通过
  test('扫描器自检：日志实参/注释/转义不命中，用户可见插值命中（P2-2）', () {
    const sample = r'''
void f(Object e) {
  // 注释里的 $e 不算
  /// 文档注释里的 ${e} 也不算
  debugPrint('日志里的 $e 不算');
  debugPrint('日志前缀'); Text('用户可见：$e');
  Text('用户可见：${e}');
  Text('用户可见：$err');
  Text('用户可见：$error');
  Text('用户可见：$ex');
  Text('用户可见：$exception');
  Text('转义字面量：\$errorMessage');
  final v = '$errorMessage';
}
''';

    final violations = _scanSource('sample.dart', sample);

    expect(
      violations,
      hasLength(6),
      reason:
          '应命中 5 个用户可见插值 + 1 个「日志之后同一行」插值：\n'
          '${violations.join('\n')}',
    );
    expect(violations.any((v) => v.contains("Text('用户可见：\$e')")), isTrue);
    expect(
      violations.any((v) => v.contains("debugPrint('日志前缀'); Text('用户可见：\$e')")),
      isTrue,
      reason: '日志调用不得整行放过：同一行后续用户可见插值仍须命中',
    );
    expect(violations.any((v) => v.contains('注释')), isFalse);
    expect(
      violations.any((v) => v.contains('日志里的')),
      isFalse,
      reason: '纯日志实参内的插值不命中',
    );
    expect(violations.any((v) => v.contains('转义字面量')), isFalse);
    expect(
      violations.any((v) => v.contains('errorMessage')),
      isFalse,
      reason: '\$errorMessage 不是异常对象插值',
    );
  });
}

/// 扫描单个源文件，返回违规行（`path:line: text`）
List<String> _scanSource(String path, String source) {
  final violations = <String>[];
  final masked = _maskComments(source);
  final logSpans = _logSpans(masked.code, masked.inString);
  final lineStarts = _lineStarts(masked.code);

  for (final match in _interpolation.allMatches(masked.code)) {
    final index = match.start;
    // 字符串里的 `\$e` 是字面量，不是插值
    if (_isEscaped(masked.code, index)) continue;
    // 日志调用实参内部豁免（按括号范围，不整行放过）
    if (logSpans.any((span) => index > span.$1 && index < span.$2)) {
      continue;
    }
    final line = _lineAt(masked.code, lineStarts, index);
    // 例外只覆盖命中位置所在的那段语句（不做整行放过）
    if (_isAllowedAt(masked.code, index)) continue;
    final lineNo = _lineNumber(lineStarts, index);
    violations.add('$path:$lineNo: ${line.trim()}');
  }
  return violations;
}

/// 命中位置是否落在某条 [allowedSnippets] 片段内部
bool _isAllowedAt(String code, int index) {
  for (final snippet in _allowedSnippets) {
    var from = 0;
    while (true) {
      final at = code.indexOf(snippet, from);
      if (at < 0) break;
      if (index >= at && index < at + snippet.length) return true;
      from = at + 1;
    }
  }
  return false;
}

/// 守卫扫描根目录（相对 flutter_legado 包根，`flutter test` 的工作目录）
const _roots = <String>[
  'lib/src/screens',
  'lib/src/widgets',
  'lib/src/providers',
  'lib/src/services',
];

/// 异常对象裸插值：`$e` / `$err` / `$error` / `$ex` / `$exception` / `${e}`
///
/// 注意 `exception` 等长名靠 `\b` 收尾，避免 `$e2` 之类误报。
final _interpolation = RegExp(r'\$(?:e|err|error|ex|exception)\b|\$\{e\}');

/// 允许裸插值原始文本的日志调用（仅其实参括号内豁免）
///
/// `CrashLogService` 为崩溃/诊断日志落盘，与 debugPrint 同属排查用途；
/// `put` 由类内部调用，外部入口按全限定名识别，避免误伤同名缓存方法。
const _logCallNames = <String>[
  'debugPrint',
  'print',
  '_log',
  '_appendLog',
  'logMessage',
  'CrashLogService.instance.put',
];

/// 生成文件：仅调试用 toString/copyWith，不含用户可见文案，不参与守卫
bool _isGeneratedFile(String path) =>
    path.endsWith('.freezed.dart') || path.endsWith('.g.dart');

/// 精确到语句片段的例外（非异常对象/转义字面量/诊断日志），新增须附理由
const _allowedSnippets = <String>[
  // 已有 BridgeError 分支的等价安全写法
  "e is BridgeError ? e.message : '\$e'",
  // 服务端返回的字符串列表/桥协议错误回执，不是异常对象
  "'• \$e'",
  'value.map((e) => \'\$e\')',
  'msgs.map((e) => \'\$e\')',
  'decoded.map((e) => \'\$e\')',
  'deletedRaw.map((e) => \'\$e\')',
  "emit('error: \$e')",
  "submitWebviewResult(key, '[ERROR] \$e')",
  "WebViewEvalOutcome('[ERROR] \$action 执行失败：\$e', '')",
  "_replyError(id, '\$e')",
  // 调试用 toString / 诊断异常消息（非用户可见主文案）
  "String toString() => '\$sourceName: \$error'",
  "String toString() => '\$name: \$error'",
  "PrivacyBiometricOutcome.failure(\$error, detail: \$detail)",
  "throw FormatException('readConfig 值 JSON 解析失败: \$e')",
  // CrashLogService 内的诊断日志（崩溃日志详情面板用于排障）
  "put('发生未捕获的异常\\n\$error', error: error)",
  "put('[布局告警] \$error', error: error)",
  "..writeln('错误: \$error')",
  // 多行 debugPrint 的续行
  'Rust 真源沿用旧值/缺省）: \$e',
  '下一次 build 重试）: \$e',
];

const _lf = 10;
const _space = 32;
const _slash = 47;
const _star = 42;
const _backslash = 92;
const _single = 39;
const _double = 34;
const _lparen = 40;
const _rparen = 41;
const _lowerR = 114;
const _upperR = 82;

bool _isIdentifierChar(int c) =>
    (c >= 48 && c <= 57) || // 0-9
    (c >= 65 && c <= 90) || // A-Z
    (c >= 97 && c <= 122) || // a-z
    c == 95 || // _
    c == 36; // $

/// 把注释替换为空格（保持长度与换行），并标记字符串字面量位置
///
/// 返回的 [code] 保留字符串原文（插值就在字符串里）；[inString] 用于跳过
/// 字符串内的括号，避免 `debugPrint('(x)')` 干扰括号配对。
({String code, List<bool> inString}) _maskComments(String source) {
  final chars = source.codeUnits.toList(growable: false);
  final masked = List<int>.from(chars);
  final inString = List<bool>.filled(chars.length, false);
  var i = 0;
  while (i < chars.length) {
    final c = masked[i];
    if (c == _slash && i + 1 < chars.length) {
      if (masked[i + 1] == _slash) {
        while (i < chars.length && masked[i] != _lf) {
          masked[i] = _space;
          i++;
        }
        continue;
      }
      if (masked[i + 1] == _star) {
        masked[i] = _space;
        masked[i + 1] = _space;
        i += 2;
        while (i < chars.length) {
          if (masked[i] == _star &&
              i + 1 < chars.length &&
              masked[i + 1] == _slash) {
            masked[i] = _space;
            masked[i + 1] = _space;
            i += 2;
            break;
          }
          if (masked[i] != _lf) masked[i] = _space;
          i++;
        }
        continue;
      }
    }
    if (c == _single || c == _double) {
      i = _markString(chars, inString, i);
      continue;
    }
    i++;
  }
  return (code: String.fromCharCodes(masked), inString: inString);
}

/// 从 [start]（引号位置）起标记一个字符串字面量，返回其后的下标
int _markString(List<int> chars, List<bool> inString, int start) {
  final quote = chars[start];
  final triple =
      start + 2 < chars.length &&
      chars[start + 1] == quote &&
      chars[start + 2] == quote;
  // r'...' / R"..." 原始字符串不处理反斜杠转义
  final raw =
      start > 0 &&
      (chars[start - 1] == _lowerR || chars[start - 1] == _upperR) &&
      (start < 2 || !_isIdentifierChar(chars[start - 2]));
  final quoteLen = triple ? 3 : 1;
  var i = start;
  for (var k = 0; k < quoteLen; k++) {
    inString[i] = true;
    i++;
  }
  while (i < chars.length) {
    final c = chars[i];
    if (!raw && c == _backslash) {
      inString[i] = true;
      if (i + 1 < chars.length) inString[i + 1] = true;
      i += 2;
      continue;
    }
    if (c == quote) {
      if (!triple) {
        inString[i] = true;
        return i + 1;
      }
      if (i + 2 < chars.length &&
          chars[i + 1] == quote &&
          chars[i + 2] == quote) {
        inString[i] = true;
        inString[i + 1] = true;
        inString[i + 2] = true;
        return i + 3;
      }
    }
    inString[i] = true;
    i++;
  }
  return i;
}

/// 所有日志调用的实参括号范围 `(open, close)`（左开右闭判定由调用方做）
List<(int, int)> _logSpans(String code, List<bool> inString) {
  final spans = <(int, int)>[];
  for (final name in _logCallNames) {
    final pattern = RegExp(r'(?<![\w$])' + RegExp.escape(name) + r'\s*\(');
    for (final match in pattern.allMatches(code)) {
      if (inString[match.start]) continue;
      final open = code.indexOf('(', match.start);
      final close = _matchingParen(code, inString, open);
      if (close != null) spans.add((open, close));
    }
  }
  return spans;
}

int? _matchingParen(String code, List<bool> inString, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (inString[i]) continue;
    final c = code.codeUnitAt(i);
    if (c == _lparen) {
      depth++;
    } else if (c == _rparen) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// 匹配位置前的连续反斜杠为奇数 → 该 `$` 被转义，是字面量
bool _isEscaped(String code, int index) {
  var count = 0;
  var i = index - 1;
  while (i >= 0 && code.codeUnitAt(i) == _backslash) {
    count++;
    i--;
  }
  return count.isOdd;
}

List<int> _lineStarts(String code) {
  final starts = <int>[0];
  for (var i = 0; i < code.length; i++) {
    if (code.codeUnitAt(i) == _lf) starts.add(i + 1);
  }
  return starts;
}

int _lineNumber(List<int> lineStarts, int index) {
  var low = 0;
  var high = lineStarts.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (lineStarts[mid] <= index) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low + 1;
}

String _lineAt(String code, List<int> lineStarts, int index) {
  final line = _lineNumber(lineStarts, index) - 1;
  final start = lineStarts[line];
  final end = line + 1 < lineStarts.length
      ? lineStarts[line + 1] - 1
      : code.length;
  return code.substring(start, end);
}
