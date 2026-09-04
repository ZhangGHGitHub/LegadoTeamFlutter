// P1-3: API 契约自动校验 —— docs/API_CONTRACT.md ↔ 三服务文件交叉核对
//
// 校验项（任一处漂移即 CI 失败）：
// 1. BookApi ⊆ RustApi、BookApi ⊆ MockBookApi（名称级）
// 2. 公共额外方法钉死：RustApi = {toString, refreshReadBookConfig}，MockBookApi = ∅
//    （refreshReadBookConfig 为 R 批 R4 进程注入补推入口，不经 BookApi，见契约 §1.6.1）
// 3. 每个 BookApi 方法都在契约中登记（§2.x 直接行或 §1.7 命名等价对）
// 4. §2.x 每节声明数 == 实际行数
// 5. 附录与 §2.x 按标题双射镜像，合计行 = 附录各行之和
// 6. 文档声明的 BookApi 总数 == book_api.dart 程序化计数
//
// 编写：主 Agent ｜ 2026-08-22

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final bNames = _extractMethods(
    _read('lib/src/services/book_api.dart'),
    'BookApi',
  );
  final rNames = _extractMethods(
    _readWithParts('lib/src/services/rust_api.dart'),
    'RustApi',
  );
  final mNames = _extractMethods(
    _readWithParts('lib/src/services/mock_book_api.dart'),
    'MockBookApi',
  );

  final doc = _read('../docs/API_CONTRACT.md');
  final dlines = doc.split('\n');

  bool hasSec17 = false;
  bool hasAppTotal = false;

  // ---------- §1.7 命名等价对：BookApi 名 -> 契约/FFI 登记名 ----------
  final pairs = <String, String>{};
  {
    int secIdx = -1;
    for (int i = 0; i < dlines.length; i++) {
      if (dlines[i].startsWith('### 1.7')) {
        secIdx = i;
        break;
      }
    }
    hasSec17 = secIdx >= 0;
    for (
      int i = secIdx + 1;
      i < dlines.length &&
          !dlines[i].startsWith('### ') &&
          !dlines[i].startsWith('## ');
      i++
    ) {
      String l = dlines[i];
      if (!l.startsWith('|')) continue;
      final cells = _cells(l);
      if (cells.length >= 2 &&
          cells[0].length > 1 &&
          cells[0].codeUnitAt(0) == 96) {
        pairs[_strip(cells[0])] = _contractName(cells[1]);
      }
    }
  }

  // ---------- §2.x 章节：声明数、实际行、行名 ----------
  final sections = <_Sec>[];
  {
    String curId = '';
    String curTitle = '';
    int declared = -1;
    int actual = 0;
    final rowNames = <String>{};

    void flush() {
      if (curId != '') {
        sections.add(
          _Sec(
            curId,
            _normTitle(curTitle),
            declared,
            actual,
            Set<String>.of(rowNames),
          ),
        );
      }
    }

    for (final l in dlines) {
      if (l.startsWith('### 2.')) {
        flush();
        curId = l.substring(4, l.indexOf(' ', 4));
        curTitle = l.substring(l.indexOf(' ', 4) + 1);
        declared = _declaredIn(l);
        actual = 0;
        rowNames.clear();
        continue;
      }
      if (curId != '' && (l.startsWith('### ') || l.startsWith('## '))) {
        flush();
        curId = '';
        continue;
      }
      if (curId != '' && _isRow(l)) {
        actual++;
        rowNames.add(_rowName(l));
      }
    }
    flush();
  }

  // ---------- 附录：行（标题+计数）与合计 ----------
  final appRows = <_AppRow>[];
  int statedTotal = -1;
  {
    int totIdx = -1;
    for (int i = 0; i < dlines.length; i++) {
      if (dlines[i].trimLeft().startsWith('|') && dlines[i].contains('合计')) {
        totIdx = i;
      }
    }
    hasAppTotal = totIdx >= 0;
    if (totIdx >= 0) {
      String tl = dlines[totIdx].replaceAll('*', '');
      statedTotal = _lastNumber(tl);
      int i = totIdx - 1;
      while (i >= 0 && dlines[i].trimLeft().startsWith('|')) {
        final cells = _cells(dlines[i]);
        if (cells.length == 3 && _isNum(cells[0]) && _isNum(cells[2])) {
          appRows.add(_AppRow(_normTitle(cells[1]), int.parse(cells[2])));
        }
        i--;
      }
    }
  }

  final bSet = bNames.toSet();
  final allRowNames = <String>{};
  for (final s in sections) {
    allRowNames.addAll(s.rowNames);
  }
  // 方法章节 = 标题声明了「N 个方法」的 §2.x 节（§2.44 备注节除外）
  final methodSections = sections.where((s) => s.declared >= 0).toList();

  group('API 契约自动校验', () {
    test('契约文档结构前置（§1.7 与附录合计行存在）', () {
      expect(hasSec17, isTrue, reason: 'API_CONTRACT.md 缺少 §1.7 命名等价表');
      expect(hasAppTotal, isTrue, reason: 'API_CONTRACT.md 缺少附录合计行');
    });

    test('BookApi ⊆ RustApi 且 BookApi ⊆ MockBookApi', () {
      expect(bNames, isNotEmpty, reason: '解析器失效：未提取到任何 BookApi 方法');
      final missingInR = bNames.where((n) => !rNames.contains(n)).toList()
        ..sort();
      expect(
        missingInR,
        isEmpty,
        reason: '以下 BookApi 方法未在 RustApi 实现：$missingInR',
      );
      final missingInM = bNames.where((n) => !mNames.contains(n)).toList()
        ..sort();
      expect(
        missingInM,
        isEmpty,
        reason: '以下 BookApi 方法未在 MockBookApi 实现：$missingInM',
      );
    });

    test('公共额外方法钉死：RustApi={toString, refreshReadBookConfig}，MockBookApi=∅', () {
      final rExtra =
          rNames.where((n) => !n.startsWith('_') && !bSet.contains(n)).toList()
            ..sort();
      expect(rExtra, [
        'refreshReadBookConfig',
        'toString',
      ], reason: 'RustApi 公共额外方法集合漂移（新增/删除了 BookApi 之外的公共方法）：$rExtra');
      final mExtra =
          mNames.where((n) => !n.startsWith('_') && !bSet.contains(n)).toList()
            ..sort();
      expect(mExtra, isEmpty, reason: 'MockBookApi 出现 BookApi 之外的公共方法：$mExtra');
    });

    test('每个 BookApi 方法都在契约中登记（直接行或 §1.7 等价对）', () {
      final unregistered =
          bNames
              .where((n) => !allRowNames.contains(n) && !pairs.containsKey(n))
              .toList()
            ..sort();
      expect(
        unregistered,
        isEmpty,
        reason:
            '以下 BookApi 方法未在 API_CONTRACT.md §2.x 登记（新接口必须先冻结契约）：$unregistered',
      );
      // §1.7 的契约名侧必须真实存在于 §2.x 行中
      final phantom =
          pairs.values.where((v) => !allRowNames.contains(v)).toList()..sort();
      expect(phantom, isEmpty, reason: '§1.7 引用了不存在的契约登记名：$phantom');
    });

    test('§2.x 每节声明数 == 实际行数', () {
      expect(methodSections.length, greaterThan(30), reason: '章节解析异常（方法章节过少）');
      final bad = methodSections
          .where((s) => s.declared != s.actual)
          .map((s) => '${s.id} 声明 ${s.declared} / 实际 ${s.actual}')
          .toList();
      expect(bad, isEmpty, reason: '章节标题计数与实际行不一致：$bad');
    });

    test('附录与 §2.x 按标题双射镜像，合计行 = 各行之和', () {
      final secTitles = methodSections.map((s) => s.title).toList();
      expect(
        secTitles.toSet().length,
        secTitles.length,
        reason: '§2.x 方法章节标题重复',
      );
      final appTitles = appRows.map((r) => r.title).toList();
      expect(appTitles.toSet().length, appTitles.length, reason: '附录行标题重复');
      expect(
        appTitles.toSet(),
        secTitles.toSet(),
        reason: '附录行与 §2.x 方法章节标题不一一对应（新增模块须同步附录）',
      );
      final mismatched = <String>[];
      for (final s in methodSections) {
        int c = -1;
        for (final r in appRows) {
          if (r.title == s.title) {
            c = r.count;
            break;
          }
        }
        if (c != s.actual) {
          mismatched.add('${s.title}: 附录 $c / §2.x 实际 ${s.actual}');
        }
      }
      expect(mismatched, isEmpty, reason: '附录计数与 §2.x 实际行不一致：$mismatched');
      int sum = 0;
      for (final r in appRows) {
        sum += r.count;
      }
      expect(
        statedTotal,
        sum,
        reason: '附录合计行（$statedTotal）≠ 附录各行之和（$sum），请更新合计',
      );
    });

    test('文档声明的 BookApi 总数 == 程序化计数', () {
      int docCount = -1;
      for (final l in dlines) {
        if (l.contains('BookApi 接口当前共')) {
          docCount = _firstNumberAfter(l, '共');
          break;
        }
      }
      expect(
        docCount,
        bNames.length,
        reason: '文档声明 $docCount ≠ book_api.dart 实际 ${bNames.length}，请同步更新文档计数',
      );
    });
  });
}

class _Sec {
  _Sec(this.id, this.title, this.declared, this.actual, this.rowNames);
  final String id;
  final String title;
  final int declared;
  final int actual;
  final Set<String> rowNames;
}

class _AppRow {
  _AppRow(this.title, this.count);
  final String title;
  final int count;
}

// ---------- 解析工具（行扫描，不依赖正则） ----------

String _read(String p) => File(p).readAsStringSync();

/// 读取主文件并拼接其 part 文件内容（体检 §三.16 超长文件拆分后，
/// 类成员方法分布在分域 part 文件中；契约门禁按文本逐行提取，拼接后语义不变）
String _readWithParts(String p) {
  final src = File(p).readAsStringSync();
  final buf = StringBuffer(src);
  final partRe = RegExp("^part '([^']+)';", multiLine: true);
  final baseDir = p.substring(0, p.lastIndexOf('/') + 1);
  for (final m in partRe.allMatches(src)) {
    buf.write('\n');
    buf.write(File('$baseDir${m.group(1)}').readAsStringSync());
  }
  return buf.toString();
}

bool _isIdentChar(int c) {
  return (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 95;
}

final List<String> _blockStarts = [
  'final',
  'var',
  'return',
  'if',
  'for',
  'while',
  'switch',
  'case',
  'break',
  'continue',
  'throw',
  'new',
  'import',
  'export',
  'part',
  'class',
  'enum',
  'mixin',
  'const',
  'true',
  'false',
  'null',
  'async',
  'await',
  'try',
  'catch',
  'do',
  'else',
  'required',
  'super',
  'this',
  'operator',
  'late',
];

bool _candidate(String line) {
  if (line.length < 4) return false;
  if (line.codeUnitAt(0) != 32 || line.codeUnitAt(1) != 32) return false;
  if (line.codeUnitAt(2) == 32) return false;
  String rest = line.substring(2);
  for (final w in _blockStarts) {
    if (rest.startsWith(w)) return false;
  }
  int c0 = rest.codeUnitAt(0);
  if (c0 == 64 || c0 == 125 || c0 == 123) return false; // @ } {
  if (rest.startsWith('//') || rest.startsWith('*')) return false;
  return line.contains('(');
}

List<String> _extractMethods(String src, String className) {
  final names = <String>{};
  for (final line in src.split('\n')) {
    if (!_candidate(line)) continue;
    int p = line.indexOf('(');
    if (p <= 2) continue;
    int e = p - 1;
    while (e > 2 && _isIdentChar(line.codeUnitAt(e))) {
      e--;
    }
    if (e < 3) continue;
    String name = line.substring(e + 1, p);
    if (name.isEmpty || name == className) continue;
    bool hasType = false;
    bool bad = false;
    for (int i = 3; i < e; i++) {
      int c = line.codeUnitAt(i);
      if (c == 61) {
        bad = true;
        break;
      }
      if (_isIdentChar(c) ||
          c == 60 ||
          c == 62 ||
          c == 91 ||
          c == 93 ||
          c == 42) {
        hasType = true;
      }
    }
    if (bad || !hasType) continue;
    names.add(name);
  }
  return names.toList();
}

bool _isRow(String l) {
  return l.length > 2 && l.codeUnitAt(0) == 124 && l.codeUnitAt(2) == 96;
}

/// 契约行首列的方法名：去反引号，截到第一个 '('。
String _rowName(String l) {
  String cell = _strip(_cells(l)[0]);
  int p = cell.indexOf('(');
  if (p >= 0) cell = cell.substring(0, p);
  return cell.trim();
}

/// §1.7 右列契约名：去反引号，截到第一个全角括号「（」。
String _contractName(String cell) {
  String c = _strip(cell);
  int p = c.indexOf('\u{FF08}');
  if (p >= 0) c = c.substring(0, p);
  return _strip(c);
}

/// 标题归一化：截到第一个全角括号「（」并 trim。
String _normTitle(String t) {
  int p = t.indexOf('\u{FF08}');
  if (p >= 0) t = t.substring(0, p);
  return t.trim();
}

/// 章节标题中「N 个方法」的 N；无则 -1。
int _declaredIn(String l) {
  int k = l.indexOf('个方法');
  if (k < 0) return -1;
  int i = k - 1;
  while (i >= 0 && l.codeUnitAt(i) == 32) {
    i--;
  }
  while (i >= 0) {
    int c = l.codeUnitAt(i);
    if (c >= 48 && c <= 57) {
      i--;
    } else {
      break;
    }
  }
  if (i < 0 || i + 1 >= k) return -1;
  return int.parse(l.substring(i + 1, k));
}

List<String> _cells(String l) {
  final parts = l.split('|');
  final out = <String>[];
  for (final p in parts) {
    final t = p.trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

bool _isNum(String s) {
  if (s.isEmpty) return false;
  for (int i = 0; i < s.length; i++) {
    int c = s.codeUnitAt(i);
    if (c < 48 || c > 57) return false;
  }
  return true;
}

/// 去掉两端反引号与空白。
String _strip(String s) {
  while (s.isNotEmpty && (s.codeUnitAt(0) == 96 || s.codeUnitAt(0) == 32)) {
    s = s.substring(1);
  }
  while (s.isNotEmpty &&
      (s.codeUnitAt(s.length - 1) == 96 || s.codeUnitAt(s.length - 1) == 32)) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 取字符串中最后一个数字串（合计行用，先去掉 *）。
int _lastNumber(String l) {
  int s2 = -1;
  String last = '';
  for (int i = 0; i < l.length; i++) {
    int c = l.codeUnitAt(i);
    if (c >= 48 && c <= 57) {
      if (s2 < 0) s2 = i;
    } else if (s2 >= 0) {
      last = l.substring(s2, i);
      s2 = -1;
    }
  }
  if (s2 >= 0) last = l.substring(s2);
  return last.isEmpty ? -1 : int.parse(last);
}

/// 「BookApi 接口当前共 **N**」中 N：marker 之后第一段数字。
int _firstNumberAfter(String l, String marker) {
  int k = l.indexOf(marker);
  if (k < 0) return -1;
  int i = k + marker.length;
  while (i < l.length && !(l.codeUnitAt(i) >= 48 && l.codeUnitAt(i) <= 57)) {
    i++;
  }
  int s3 = i;
  while (i < l.length && l.codeUnitAt(i) >= 48 && l.codeUnitAt(i) <= 57) {
    i++;
  }
  if (s3 == i) return -1;
  return int.parse(l.substring(s3, i));
}
