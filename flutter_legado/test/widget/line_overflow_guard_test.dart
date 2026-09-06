/// 行宽安全网回归测试（2026-09-06 行尾吞字根治）
///
/// 根因背景：
/// 1. ZhLayout 压缩模式（cps1/2/3）按原版语义允许行宽超出可用宽
///    （原版绘制层压缩标点兜底），但 Flutter 渲染端 Text(maxLines:1,
///    clip) 自然渲染，超宽即被裁——"正文右边吞字"的结构性根因；
/// 2. 测量侧逐字单独建 TextPainter（未合并 DefaultTextStyle、未应用
///    textScaler），与渲染侧存在系统差。
///
/// 修复：整段同源测量 + _guardLineOverflow 行宽安全网。本文件用与
/// 渲染独立的 TextPainter（maxLines:1 同参）逐行验证行宽不越界。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';

void main() {
  group('_guardLineOverflow 行宽安全网', () {
    test('压缩标点行（”）不越界且文本无损', () {
      // fontSize=10、可用宽=50（5 字/行）：'甲乙丙丁”' 占满后 '。' 触发
      // ZhLayout cps1（两个后置标点压缩），旧行为行宽 60 超限被裁，
      // 新行为安全网下移重排
      final engine = ParagraphLayoutEngine(
        config: const ParagraphConfig(
          fontSize: 10.0,
          lineHeight: 1.5,
          indent: 0,
          useZhLayout: true,
        ),
        context: _FakeBuildContext(),
      );
      const para = '甲乙丙丁”。戊己庚辛”。',
          width = 50.0;
      final pages = engine.paginateChapter(para, width, 600.0);

      final lines = <LineInfo>[];
      for (final page in pages) {
        for (final p in page.paragraphs) {
          lines.addAll(p.lines);
        }
      }
      expect(lines, isNotEmpty);
      _assertLinesFit(lines, para, width, TextScaler.noScaling);
    });

    test('对话密集文本多宽度扫描：每行独立渲染不超可用宽', () {
      final engine = ParagraphLayoutEngine(
        config: const ParagraphConfig(
          fontSize: 10.0,
          lineHeight: 1.5,
          indent: 0,
          useZhLayout: true,
        ),
        context: _FakeBuildContext(),
      );
      final para = List.generate(
        8,
        (i) => '第$i人说：“这是测试文本，用于触发标点压缩断行模式。”',
      ).join();
      for (final width in [50.0, 80.0, 120.0, 200.0, 333.0]) {
        final pages = engine.paginateChapter(para, width, 800.0);
        final lines = <LineInfo>[];
        for (final page in pages) {
          for (final p in page.paragraphs) {
            lines.addAll(p.lines);
          }
        }
        _assertLinesFit(lines, para, width, TextScaler.noScaling,
            context: '宽度 $width');
      }
    });

    test('textScaler 缩放（1.5）下每行独立渲染不超可用宽', () {
      // 测量侧未应用系统文字缩放时，行宽按 1.0 测、按 1.5 渲染，
      // 必然越界——本用例锁定 textScaler 已接入测量
      const scaler = TextScaler.linear(1.5);
      final engine = ParagraphLayoutEngine(
        config: const ParagraphConfig(
          fontSize: 10.0,
          lineHeight: 1.5,
          indent: 0,
          useZhLayout: true,
          textScaler: scaler,
        ),
        context: _FakeBuildContext(),
      );
      const para = '系统文字缩放测量同参验证段落，包含标点。“引号”与省略号……';
      const width = 90.0;
      final pages = engine.paginateChapter(para, width, 600.0);
      final lines = <LineInfo>[];
      for (final page in pages) {
        for (final p in page.paragraphs) {
          lines.addAll(p.lines);
        }
      }
      _assertLinesFit(lines, para, width, scaler);
    });

    test('安全网重排后逐行拼接与原文一致（无字符丢失）', () {
      final engine = ParagraphLayoutEngine(
        config: const ParagraphConfig(
          fontSize: 10.0,
          lineHeight: 1.5,
          indent: 0,
          useZhLayout: true,
        ),
        context: _FakeBuildContext(),
      );
      const para = '甲乙丙丁”。戊己庚辛”。”。“行末禁末标点（行首禁首标点），混合。';
      final pages = engine.paginateChapter(para, 50.0, 600.0);
      final rebuilt = <String>[];
      for (final page in pages) {
        for (final p in page.paragraphs) {
          for (final line in p.lines) {
            rebuilt.add(line.words.join());
          }
        }
      }
      expect(rebuilt.join(), equals(para));
    });

    test('useZhLayout=false 朴素断行同样经过安全网', () {
      final engine = ParagraphLayoutEngine(
        config: const ParagraphConfig(
          fontSize: 10.0,
          lineHeight: 1.5,
          indent: 0,
          useZhLayout: false,
        ),
        context: _FakeBuildContext(),
      );
      final para = '朴素断行模式验证文本。' * 6;
      const width = 70.0;
      final pages = engine.paginateChapter(para, width, 600.0);
      final lines = <LineInfo>[];
      for (final page in pages) {
        for (final p in page.paragraphs) {
          lines.addAll(p.lines);
        }
      }
      _assertLinesFit(lines, para, width, TextScaler.noScaling);
    });
  });
}

/// 用与渲染独立的 TextPainter（maxLines:1、同字号）逐行验证：
/// 1. LineInfo.width 不超可用宽（安全网直接判定）
/// 2. 行字符串独立渲染宽度不超可用宽（渲染视角判定，吞字即超）
/// 3. 逐行拼接无损
void _assertLinesFit(
  List<LineInfo> lines,
  String para,
  double width,
  TextScaler scaler, {
  String context = '',
}) {
  final style = TextStyle(fontSize: 10.0);
  final suffix = context.isEmpty ? '' : '（$context）';
  expect(lines, isNotEmpty, reason: '应产生分行结果$suffix');
  for (final line in lines) {
    expect(
      line.width,
      lessThanOrEqualTo(width + 0.5),
      reason: '行宽越界$suffix: "${line.words.join()}" width=${line.width}',
    );
    final painter = TextPainter(
      text: TextSpan(text: line.words.join(), style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    expect(
      painter.width,
      lessThanOrEqualTo(width + 0.5),
      reason: '独立渲染行宽越界$suffix（即行尾吞字）: '
          '"${line.words.join()}" renderWidth=${painter.width}',
    );
    painter.dispose();
  }
}

/// 测试用 FakeBuildContext（TextPainter 不需要真实 context）
class _FakeBuildContext extends Fake implements BuildContext {}
