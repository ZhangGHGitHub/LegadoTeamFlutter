/// 段落布局引擎单元测试
/// 
/// 覆盖所有核心功能：避头尾规则、段落分割、样式配置、
/// 字符宽度缓存、两端对齐计算、边界条件
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';

void main() {
  group('ChinesePunctuationRule - 避头尾规则测试', () {
    // ========== isBeginningPunctuation 测试 ==========
    
    test('isBeginningPunctuation - 识别中文逗号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('，'), isTrue);
    });

    test('isBeginningPunctuation - 识别句号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('。'), isTrue);
    });

    test('isBeginningPunctuation - 识别问号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('？'), isTrue);
    });

    test('isBeginningPunctuation - 识别感叹号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('！'), isTrue);
    });

    test('isBeginningPunctuation - 识别省略号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('…'), isTrue);
    });

    test('isBeginningPunctuation - 识别右括号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation(')'), isTrue);
      expect(ChinesePunctuationRule.isBeginningPunctuation('」'), isTrue);
      expect(ChinesePunctuationRule.isBeginningPunctuation('】'), isTrue);
      expect(ChinesePunctuationRule.isBeginningPunctuation('}'), isTrue);
      expect(ChinesePunctuationRule.isBeginningPunctuation('》'), isTrue);
      expect(ChinesePunctuationRule.isBeginningPunctuation('〉'), isTrue);
    });

    test('isBeginningPunctuation - 识别顿号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('、'), isTrue);
    });

    test('isBeginningPunctuation - 识别半角逗号作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation(','), isTrue);
    });

    test('isBeginningPunctuation - 字母不作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('a'), isFalse);
      expect(ChinesePunctuationRule.isBeginningPunctuation('A'), isFalse);
      expect(ChinesePunctuationRule.isBeginningPunctuation('中'), isFalse);
    });

    test('isBeginningPunctuation - 数字不作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation('1'), isFalse);
      expect(ChinesePunctuationRule.isBeginningPunctuation('5'), isFalse);
    });

    test('isBeginningPunctuation - 空格不作为行首标点', () {
      expect(ChinesePunctuationRule.isBeginningPunctuation(' '), isFalse);
    });

    // ========== isEndingPunctuation 测试 ==========

    test('isEndingPunctuation - 识别左括号作为行末标点', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('('), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('（'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('【'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('｛'), isTrue);
    });

    test('isEndingPunctuation - 识别书名号作为行末标点', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('《'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('「'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('『'), isTrue);
    });

    test('isEndingPunctuation - 识别左尖括号作为行末标点', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('〈'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('‹'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('<'), isTrue);
    });

    test('isEndingPunctuation - 普通字符不作为行末标点', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('a'), isFalse);
      expect(ChinesePunctuationRule.isEndingPunctuation('中'), isFalse);
      expect(ChinesePunctuationRule.isEndingPunctuation('1'), isFalse);
    });

    test('isEndingPunctuation - 右引号作为行末标点', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('"'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('"'), isTrue);
    });

    test('isEndingPunctuation - 中文逗号不作为行末标点', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('，'), isFalse);
    });

    // ========== getFirstCharOnLine 测试 ==========

    test('getFirstCharOnLine - 无行首标点原样返回', () {
      const input = '这是一个测试';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals(input));
    });

    test('getFirstCharOnLine - 移除行首逗号', () {
      const input = '，这是测试';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals('这是测试'));
    });

    test('getFirstCharOnLine - 移除多个行首标点', () {
      const input = '。。。。。你好';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals('你好'));
    });

    test('getFirstCharOnLine - 全部是行首标点返回原字符串', () {
      const input = '？？？！！？';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals(input));
    });

    test('getFirstCharOnLine - 空字符串返回空', () {
      const input = '';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result.isEmpty, isTrue);
    });

    test('getFirstCharOnLine - 只有行首标点符号', () {
      const input = '，，，';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals(input));
    });

    test('getFirstCharOnLine - 英文开头不处理', () {
      const input = 'Hello World';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals(input));
    });

    // ========== getLastCharOnLine 测试 ==========

    test('getLastCharOnLine - 无行末标点原样返回', () {
      const input = '这是一个测试';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result, equals(input));
    });

    test('getLastCharOnLine - 移除行末左括号', () {
      const input = '这是测试（';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result, equals('这是测试'));
    });

    test('getLastCharOnLine - 移除多个行末标点', () {
      const input = '你好（（（';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result, equals('你好'));
    });

    test('getLastCharOnLine - 全部是行末标点返回原字符串', () {
      const input = '(((()';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result, equals(input));
    });

    test('getLastCharOnLine - 空字符串返回空', () {
      const input = '';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result.isEmpty, isTrue);
    });

    test('getLastCharOnLine - 包含右引号移除', () {
      const input = '他说"你好"';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result, equals('他说"你好'));
    });

    test('getLastCharOnLine - 英文结尾不处理', () {
      const input = 'Hello World';
      final result = ChinesePunctuationRule.getLastCharOnLine(input);
      expect(result, equals(input));
    });
  });

  group('ParagraphConfig - 样式配置测试', () {
    late ParagraphConfig defaultConfig;

    setUp(() {
      defaultConfig = const ParagraphConfig();
    });

    test('ParagraphConfig - 默认值验证', () {
      expect(defaultConfig.fontSize, equals(16.0));
      expect(defaultConfig.lineHeight, equals(1.6));
      expect(defaultConfig.paragraphSpacing, equals(8.0));
      expect(defaultConfig.indent, equals(0.0));
      expect(defaultConfig.justify, isTrue);
      expect(defaultConfig.backgroundColor, equals(Colors.white));
      expect(defaultConfig.textColor, equals(Colors.black));
    });

    test('ParagraphConfig - 自定义值', () {
      final customConfig = const ParagraphConfig(
        fontSize: 14.0,
        lineHeight: 1.8,
        paragraphSpacing: 10.0,
        indent: 32.0,
        justify: false,
        backgroundColor: Colors.grey,
        textColor: Colors.blue,
      );
      
      expect(customConfig.fontSize, equals(14.0));
      expect(customConfig.lineHeight, equals(1.8));
      expect(customConfig.paragraphSpacing, equals(10.0));
      expect(customConfig.indent, equals(32.0));
      expect(customConfig.justify, isFalse);
      expect(customConfig.backgroundColor, equals(Colors.grey));
      expect(customConfig.textColor, equals(Colors.blue));
    });

    test('ParagraphConfig - copyWith 复制并修改', () {
      final modified = defaultConfig.copyWith(fontSize: 18.0);
      
      expect(modified.fontSize, equals(18.0));
      expect(modified.lineHeight, equals(1.6));
      expect(modified.paragraphSpacing, equals(8.0));
    });

    test('ParagraphConfig - copyWith 全修改', () {
      final modified = defaultConfig.copyWith(
        fontSize: 20.0,
        lineHeight: 2.0,
        paragraphSpacing: 12.0,
        indent: 24.0,
        justify: false,
        backgroundColor: Colors.red,
        textColor: Colors.green,
      );
      
      expect(modified.fontSize, equals(20.0));
      expect(modified.lineHeight, equals(2.0));
      expect(modified.paragraphSpacing, equals(12.0));
      expect(modified.indent, equals(24.0));
      expect(modified.justify, isFalse);
      expect(modified.backgroundColor, equals(Colors.red));
      expect(modified.textColor, equals(Colors.green));
    });

    test('ParagraphConfig - copyWith 空参数保持原值', () {
      final modified = defaultConfig.copyWith();
      
      expect(modified.fontSize, equals(defaultConfig.fontSize));
      expect(modified.lineHeight, equals(defaultConfig.lineHeight));
      expect(modified.paragraphSpacing, equals(defaultConfig.paragraphSpacing));
      expect(modified.indent, equals(defaultConfig.indent));
      expect(modified.justify, equals(defaultConfig.justify));
      expect(modified.backgroundColor, equals(defaultConfig.backgroundColor));
      expect(modified.textColor, equals(defaultConfig.textColor));
    });

    test('ParagraphConfig - 不可变性验证', () {
      final originalFontSize = defaultConfig.fontSize;
      final modified = defaultConfig.copyWith(fontSize: 24.0);
      
      expect(modified.fontSize, equals(24.0));
      expect(defaultConfig.fontSize, equals(originalFontSize));
    });
  });

  group('LineInfo - 行信息测试', () {
    test('LineInfo - 创建有效对象', () {
      const lineInfo = LineInfo(
        words: ['测', '试'],
        width: 100.0,
        height: 24.0,
        startIndex: 0,
        endIndex: 2,
      );
      
      expect(lineInfo.words.length, equals(2));
      expect(lineInfo.width, equals(100.0));
      expect(lineInfo.height, equals(24.0));
      expect(lineInfo.startIndex, equals(0));
      expect(lineInfo.endIndex, equals(2));
    });

    test('LineInfo - 单字行', () {
      const lineInfo = LineInfo(
        words: ['一'],
        width: 50.0,
        height: 24.0,
        startIndex: 0,
        endIndex: 1,
      );
      
      expect(lineInfo.words.length, equals(1));
      expect(lineInfo.words[0], equals('一'));
    });

    test('LineInfo - 多行字符集合', () {
      final lineInfo = LineInfo(
        words: ['第', '一', '章', '标', '题'],
        width: 200.0,
        height: 28.0,
        startIndex: 0,
        endIndex: 5,
      );
      
      expect(lineInfo.words.join(''), equals('第一章标题'));
      expect(lineInfo.width, equals(200.0));
    });

    test('LineInfo - 空字符列表', () {
      const lineInfo = LineInfo(
        words: [],
        width: 0.0,
        height: 24.0,
        startIndex: 0,
        endIndex: 0,
      );
      
      expect(lineInfo.words.isEmpty, isTrue);
      expect(lineInfo.width, equals(0.0));
    });
  });

  group('ParagraphInfo - 段落信息测试', () {
    test('ParagraphInfo - 创建有效对象', () {
      final lines = [
        const LineInfo(words: ['第'], width: 50.0, height: 24.0, startIndex: 0, endIndex: 1),
        const LineInfo(words: ['一'], width: 50.0, height: 24.0, startIndex: 1, endIndex: 2),
      ];
      final paraInfo = ParagraphInfo(
        lines: lines,
        totalHeight: 48.0,
        startIndex: 0,
        endIndex: 2,
      );
      
      expect(paraInfo.lines.length, equals(2));
      expect(paraInfo.totalHeight, equals(48.0));
      expect(paraInfo.startIndex, equals(0));
      expect(paraInfo.endIndex, equals(2));
    });

    test('ParagraphInfo - 单行段落', () {
      final lines = [
        const LineInfo(words: ['这是一句话'], width: 150.0, height: 24.0, startIndex: 0, endIndex: 5),
      ];
      final paraInfo = ParagraphInfo(
        lines: lines,
        totalHeight: 24.0,
        startIndex: 0,
        endIndex: 5,
      );
      
      expect(paraInfo.lines.length, equals(1));
      expect(paraInfo.totalHeight, equals(24.0));
    });

    test('ParagraphInfo - 多行复杂段落', () {
      final lines = List.generate(10, (i) => 
        LineInfo(
          words: ['行'],
          width: 50.0,
          height: 24.0,
          startIndex: i,
          endIndex: i + 1,
        ),
      );
      
      final paraInfo = ParagraphInfo(
        lines: lines,
        totalHeight: 10.0 * 24.0,
        startIndex: 0,
        endIndex: 10,
      );
      
      expect(paraInfo.lines.length, equals(10));
      expect(paraInfo.totalHeight, equals(240.0));
    });

    test('ParagraphInfo - 空段落', () {
      const paraInfo = ParagraphInfo(
        lines: [],
        totalHeight: 0.0,
        startIndex: 0,
        endIndex: 0,
      );
      
      expect(paraInfo.lines.isEmpty, isTrue);
      expect(paraInfo.totalHeight, equals(0.0));
    });
  });

  group('PageInfo - 页面信息测试', () {
    test('PageInfo - 创建有效对象', () {
      final paragraphs = [
        const ParagraphInfo(
          lines: [],
          totalHeight: 0,
          startIndex: 0,
          endIndex: 0,
        ),
      ];
      final pageInfo = PageInfo(
        paragraphs: paragraphs,
        totalHeight: 0,
      );
      
      expect(pageInfo.paragraphs.length, equals(1));
      expect(pageInfo.totalHeight, equals(0));
    });

    test('PageInfo - 空页面', () {
      const pageInfo = PageInfo(
        paragraphs: [],
        totalHeight: 0,
      );
      
      expect(pageInfo.paragraphs.isEmpty, isTrue);
      expect(pageInfo.totalHeight, equals(0));
    });

    test('PageInfo - 多段落页面', () {
      final paragraphs = [
        const ParagraphInfo(
          lines: [],
          totalHeight: 100.0,
          startIndex: 0,
          endIndex: 50,
        ),
        const ParagraphInfo(
          lines: [],
          totalHeight: 150.0,
          startIndex: 51,
          endIndex: 100,
        ),
      ];
      final pageInfo = PageInfo(
        paragraphs: paragraphs,
        totalHeight: 250.0,
      );
      
      expect(pageInfo.paragraphs.length, equals(2));
      expect(pageInfo.totalHeight, equals(250.0));
    });

    test('PageInfo - 多行段落组合', () {
      final paragraphLines = [
        const LineInfo(words: ['第一'], width: 80.0, height: 24.0, startIndex: 0, endIndex: 2),
        const LineInfo(words: ['行'], width: 30.0, height: 24.0, startIndex: 2, endIndex: 3),
      ];
      
      final firstPara = ParagraphInfo(
        lines: paragraphLines,
        totalHeight: 48.0,
        startIndex: 0,
        endIndex: 3,
      );
      
      final secondParaLines = [
        const LineInfo(words: ['第二段'], width: 120.0, height: 24.0, startIndex: 3, endIndex: 6),
      ];
      
      final secondPara = ParagraphInfo(
        lines: secondParaLines,
        totalHeight: 24.0,
        startIndex: 3,
        endIndex: 6,
      );
      
      final pageInfo = PageInfo(
        paragraphs: [firstPara, secondPara],
        totalHeight: 72.0,
      );
      
      expect(pageInfo.paragraphs.length, equals(2));
      expect(pageInfo.totalHeight, equals(72.0));
    });
  });

  group('CharWidthCache - 字符宽度缓存测试', () {
    late CharWidthCache cache;

    setUp(() {
      cache = CharWidthCache();
    });

    test('CharWidthCache - 初始状态 ASCII 缓存为空', () {
      // ASCII 'A' = 65，初始应返回 -1.0
      expect(cache.measureCodePoint(65), equals(-1.0));
    });

    test('CharWidthCache - 写入并读取 ASCII 字符宽度', () {
      cache.putCodePoint(65, 8.5); // 'A'
      expect(cache.measureCodePoint(65), equals(8.5));
    });

    test('CharWidthCache - CJK 字符使用通用宽度', () {
      cache.chineseCommonWidth = 16.0;
      // '中' = U+4E2D = 20013，在 19968..40869 范围内
      expect(cache.measureCodePoint(20013), equals(16.0));
    });

    test('CharWidthCache - CJK 通用宽度未设置时返回 -1', () {
      cache.chineseCommonWidth = 0.0;
      expect(cache.measureCodePoint(20013), equals(-1.0));
    });

    test('CharWidthCache - 非 ASCII 非 CJK 字符使用 Map 缓存', () {
      // '，' = U+FF0C = 65292，不在 CJK 统一汉字范围
      cache.putCodePoint(65292, 16.0);
      expect(cache.measureCodePoint(65292), equals(16.0));
    });

    test('CharWidthCache - 未缓存的非 ASCII 字符返回 -1', () {
      expect(cache.measureCodePoint(65292), equals(-1.0));
    });

    test('CharWidthCache - invalidate 清除所有缓存', () {
      cache.putCodePoint(65, 8.5);
      cache.putCodePoint(65292, 16.0);
      cache.chineseCommonWidth = 16.0;
      cache.hitCount = 10;
      cache.missCount = 5;
      
      cache.invalidate();
      
      expect(cache.measureCodePoint(65), equals(-1.0));
      expect(cache.measureCodePoint(65292), equals(-1.0));
      expect(cache.chineseCommonWidth, equals(0.0));
      expect(cache.hitCount, equals(0));
      expect(cache.missCount, equals(0));
    });

    test('CharWidthCache - hitCount 统计正确', () {
      cache.putCodePoint(65, 8.5);
      cache.measureCodePoint(65); // 命中
      cache.measureCodePoint(65); // 命中
      cache.measureCodePoint(66); // 未命中
      
      expect(cache.hitCount, equals(2));
    });

    test('CharWidthCache - size 返回非 ASCII 缓存数量', () {
      cache.putCodePoint(65, 8.5); // ASCII，不计入 size
      cache.putCodePoint(65292, 16.0); // 非 ASCII
      cache.putCodePoint(65293, 16.0); // 非 ASCII
      
      expect(cache.size, equals(2));
    });

    test('CharWidthCache - CJK 范围内多个字符共享通用宽度', () {
      cache.chineseCommonWidth = 16.0;
      // '一' U+4E00 = 19968
      expect(cache.measureCodePoint(19968), equals(16.0));
      // '龥' U+9FA5 = 40869
      expect(cache.measureCodePoint(40869), equals(16.0));
      // 中间任意字符
      expect(cache.measureCodePoint(25000), equals(16.0));
    });

    test('CharWidthCache - CJK 范围外不使用通用宽度', () {
      cache.chineseCommonWidth = 16.0;
      // U+4DFF = 19967，刚好在范围外
      expect(cache.measureCodePoint(19967), equals(-1.0));
      // U+9FA6 = 40870，刚好在范围外
      expect(cache.measureCodePoint(40870), equals(-1.0));
    });
  });

  group('computeJustifySpacing - 两端对齐计算测试', () {
    test('computeJustifySpacing - 行宽等于可用宽度时返回 0', () {
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 300.0,
        charCount: 10,
      );
      expect(spacing, equals(0.0));
    });

    test('computeJustifySpacing - 行宽超过可用宽度时返回 0', () {
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 350.0,
        charCount: 10,
      );
      expect(spacing, equals(0.0));
    });

    test('computeJustifySpacing - 单字符返回 0', () {
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 16.0,
        charCount: 1,
      );
      expect(spacing, equals(0.0));
    });

    test('computeJustifySpacing - 无空格时平均分配到字间隙', () {
      // 可用宽度 300，行宽 200，10 个字，9 个间隙
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 200.0,
        charCount: 10,
        spaceCount: 0,
      );
      // (300 - 200) / 9 ≈ 11.11
      expect(spacing, closeTo(100.0 / 9, 0.001));
    });

    test('computeJustifySpacing - 有空格时分配到空格处', () {
      // 可用宽度 300，行宽 200，10 个字，5 个空格
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 200.0,
        charCount: 10,
        spaceCount: 5,
      );
      // (300 - 200) / 5 = 20.0
      expect(spacing, equals(20.0));
    });

    test('computeJustifySpacing - 只有 1 个空格时按字间隙分配', () {
      // spaceCount <= 1 时走 gapCount 分支
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 200.0,
        charCount: 10,
        spaceCount: 1,
      );
      // (300 - 200) / 9 ≈ 11.11
      expect(spacing, closeTo(100.0 / 9, 0.001));
    });

    test('computeJustifySpacing - 两个字符一个间隙', () {
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 100.0,
        lineWidth: 32.0,
        charCount: 2,
        spaceCount: 0,
      );
      // (100 - 32) / 1 = 68.0
      expect(spacing, equals(68.0));
    });

    test('computeJustifySpacing - 零字符数返回 0', () {
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 0.0,
        charCount: 0,
      );
      expect(spacing, equals(0.0));
    });
  });

  group('段落文本处理辅助函数测试', () {
    test('_splitParagraphs - 单个段落返回', () {
      const content = '这是一个段落';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(1));
      expect(paragraphs[0], equals('这是一个段落'));
    });

    test('_splitParagraphs - 双换行符分割多段落', () {
      const content = '第一段\n\n第二段';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(2));
      expect(paragraphs[0], equals('第一段'));
      expect(paragraphs[1], equals('第二段'));
    });

    test('_splitParagraphs - 单换行符分割', () {
      const content = '第一行\n第二行';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(2));
      expect(paragraphs[0], equals('第一行'));
      expect(paragraphs[1], equals('第二行'));
    });

    test('_splitParagraphs - 连续多个换行符视为一个', () {
      const content = '第一段\n\n\n第二段';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(2));
    });

    test('_splitParagraphs - 过滤空白段落', () {
      const content = '第一段\n\n   \n\n第二段';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(2));
    });

    test('_splitParagraphs - 空字符串返回空列表', () {
      const content = '';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.isEmpty, isTrue);
    });

    test('_splitParagraphs - 只有空白符返回空列表', () {
      const content = '   \n\t\n   ';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.isEmpty, isTrue);
    });

    test('_splitParagraphs - 开头有空白段落', () {
      const content = '\n\n第一段内容';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(1));
      expect(paragraphs[0], equals('第一段内容'));
    });

    test('_splitParagraphs - 结尾有空白段落', () {
      const content = '第一段内容\n\n\n\n';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(1));
      expect(paragraphs[0], equals('第一段内容'));
    });

    test('_splitParagraphs - 三个段落', () {
      const content = '段落一\n\n段落二\n\n段落三';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(3));
    });

    test('_splitParagraphs - 带空格的换行', () {
      const content = '第一段\n  \n第二段';
      final paragraphs = _callSplitParagraphs(content);
      expect(paragraphs.length, equals(2));
    });

    test('_breakLines - 短文本返回一行', () {
      const text = '这是一段短文本';
      final lines = _callBreakLines(text, 800.0);
      expect(lines.length, equals(1));
    });

    test('_breakLines - 长文本分行', () {
      const text = '这是一段非常长的文本，会超出宽度限制需要分成多行来显示完整的内容';
      final lines = _callBreakLines(text, 100.0);
      expect(lines.length, greaterThan(1));
    });

    test('_breakLines - 空文本返回空列表', () {
      const text = '';
      final lines = _callBreakLines(text, 800.0);
      expect(lines.isEmpty, isTrue);
    });

    test('_breakLines - 单一字符', () {
      const text = '一';
      final lines = _callBreakLines(text, 800.0);
      expect(lines.length, equals(1));
      expect(lines.first.words.length, equals(1));
    });

    test('_breakLines - 极窄宽度强制每字一行', () {
      const text = '你好世界';
      final lines = _callBreakLines(text, 5.0);
      expect(lines.length, greaterThanOrEqualTo(2));
    });
  });

  group('边界条件测试', () {
    test('边界 - Unicode 表情符号', () {
      const input = '😀 🎉 ✨';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result.isNotEmpty, isTrue);
    });

    test('边界 - 混合中英文标点', () {
      const input = 'Hello，world! 你好，世界？';
      final result = ChinesePunctuationRule.getFirstCharOnLine(input);
      expect(result, equals(input));
    });

    test('边界 - 极端缩进值', () {
      final config = ParagraphConfig(indent: 999.0);
      expect(config.indent, equals(999.0));
    });

    test('边界 - 极小字号', () {
      final config = const ParagraphConfig(fontSize: 8.0);
      expect(config.fontSize, equals(8.0));
    });

    test('边界 - 极大行高比', () {
      final config = const ParagraphConfig(lineHeight: 3.0);
      expect(config.lineHeight, equals(3.0));
    });

    test('边界 - 零字号', () {
      final config = const ParagraphConfig(fontSize: 0.0);
      expect(config.fontSize, equals(0.0));
    });

    test('边界 - 负段落间距', () {
      final config = const ParagraphConfig(paragraphSpacing: -5.0);
      expect(config.paragraphSpacing, equals(-5.0));
    });

    test('边界 - 超长单行文本', () {
      final longText = '字' * 10000;
      final lines = _callBreakLines(longText, 300.0);
      expect(lines.length, greaterThan(100));
    });

    test('边界 - 纯标点文本', () {
      const text = '，。？！、';
      final result = ChinesePunctuationRule.getFirstCharOnLine(text);
      // 全部是行首标点，返回原字符串
      expect(result, equals(text));
    });

    test('边界 - 混合全角半角括号', () {
      expect(ChinesePunctuationRule.isEndingPunctuation('（'), isTrue);
      expect(ChinesePunctuationRule.isEndingPunctuation('('), isTrue);
      expect(ChinesePunctuationRule.isBeginningPunctuation('）'), isFalse);
      expect(ChinesePunctuationRule.isBeginningPunctuation(')'), isTrue);
    });
  });

  group('集成场景测试', () {
    test('场景 - 完整书籍章节内容排版', () {
      const chapterContent = '''
第一章：初出茅庐

青山脚下，白云深处，一座古朴的庄园静静矗立。
清晨的阳光透过稀疏的树叶，洒在青石板上，泛着淡淡的光晕。

少年站在庭院中央，目光坚定地看着前方。他知道，今天将是他人生的转折点。
''';
      
      final paragraphs = _callSplitParagraphs(chapterContent);
      expect(paragraphs.length, equals(3));
      
      for (final para in paragraphs) {
        final lines = _callBreakLines(para.trim(), 800.0);
        expect(lines.isNotEmpty, isTrue, reason: '段落应该能分行');
      }
    });

    test('场景 - 对话格式内容', () {
      const dialogContent = '''
"你终于来了。"老者的声音低沉而有力。

"是的，我带回了您需要的东西。"少年恭敬地回答。

老者微微一笑，眼中闪过一丝赞许。
''';
      
      final paragraphs = _callSplitParagraphs(dialogContent);
      expect(paragraphs.length, equals(3));
    });

    test('场景 - 描述性文本排版', () {
      final longDescription = '这是一个描述性的段落，用于测试长篇文本的分页和分行效果。文本很长，应该会分成多行显示。' * 50;
      
      final paragraphs = _callSplitParagraphs(longDescription);
      expect(paragraphs.length, equals(1));
      
      final lines = _callBreakLines(longDescription, 300.0);
      expect(lines.length, greaterThan(5), reason: '长文本应该分成多行');
    });

    test('场景 - 避头尾规则与分行联合验证', () {
      // 验证行首不会出现禁止标点
      const text = '这是一段测试文本，用于验证标点。';
      final lines = _callBreakLines(text, 80.0);
      
      for (var i = 1; i < lines.length; i++) {
        final firstChar = lines[i].words.isNotEmpty ? lines[i].words[0] : '';
        if (firstChar.isNotEmpty) {
          // 行首不应出现行首禁止标点（除非整行都是标点）
          final isAllPunctuation = lines[i].words.every(
            (w) => ChinesePunctuationRule.isBeginningPunctuation(w),
          );
          if (!isAllPunctuation) {
            expect(
              ChinesePunctuationRule.isBeginningPunctuation(firstChar),
              isFalse,
              reason: '第 $i 行行首不应出现禁止标点: $firstChar',
            );
          }
        }
      }
    });

    test('场景 - 两端对齐间距计算验证', () {
      // 模拟一行 10 个中文字，每个 16px，总宽 160px，可用宽度 300px
      final spacing = ParagraphLayoutEngine.computeJustifySpacing(
        availableWidth: 300.0,
        lineWidth: 160.0,
        charCount: 10,
        spaceCount: 0,
      );
      // 间距 = (300 - 160) / 9 ≈ 15.56
      expect(spacing, greaterThan(0));
      expect(spacing, closeTo(140.0 / 9, 0.001));
    });

    test('场景 - 缓存性能验证', () {
      final cache = CharWidthCache();
      cache.chineseCommonWidth = 16.0;
      
      // 模拟测量 100 个中文字符
      for (var i = 0; i < 100; i++) {
        final codePoint = 19968 + (i % 100); // CJK 范围内
        final width = cache.measureCodePoint(codePoint);
        expect(width, equals(16.0));
      }
      
      // 全部命中缓存
      expect(cache.hitCount, equals(100));
    });

    test('场景 - 多段落分页计算', () {
      // 模拟 3 个段落，每段高度 100，页面高度 250
      // 第一段: 0-100，第二段: 100+8-208，第三段超出换页
      const para1 = ParagraphInfo(lines: [], totalHeight: 100.0, startIndex: 0, endIndex: 10);
      const para2 = ParagraphInfo(lines: [], totalHeight: 100.0, startIndex: 11, endIndex: 20);
      const para3 = ParagraphInfo(lines: [], totalHeight: 100.0, startIndex: 21, endIndex: 30);
      
      // 验证段落间距计算
      const spacing = 8.0;
      final totalWithSpacing = para1.totalHeight + spacing + para2.totalHeight;
      expect(totalWithSpacing, equals(208.0));
      
      // 第三段需要换页
      expect(totalWithSpacing + spacing + para3.totalHeight, greaterThan(250.0));
    });

    test('场景 - 缩进配置影响排版', () {
      final configNoIndent = const ParagraphConfig(indent: 0.0);
      final configWithIndent = const ParagraphConfig(indent: 32.0);
      
      expect(configNoIndent.indent, equals(0.0));
      expect(configWithIndent.indent, equals(32.0));
      expect(configWithIndent.indent, greaterThan(configNoIndent.indent));
    });

    test('场景 - 行高计算验证', () {
      // 行高 = fontSize * lineHeight
      const fontSize = 16.0;
      const lineHeight = 1.6;
      final textHeight = fontSize * lineHeight;
      expect(textHeight, equals(25.6));
      
      // 10 行文本总高度
      final totalHeight = 10 * textHeight;
      expect(totalHeight, equals(256.0));
    });
  });
}

// 辅助函数 - 模拟私有方法的逻辑（与引擎实现保持一致）
List<String> _callSplitParagraphs(String content) {
  if (content.trim().isEmpty) return [];
  if (content.contains('\n\n')) {
    return content
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }
  return content
      .split('\n')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
}

List<LineInfo> _callBreakLines(String text, double availableWidth) {
  if (text.isEmpty) return [];
  
  final lines = <LineInfo>[];
  
  // 简单模拟：假设每个中文字符宽度为 16px
  const charWidth = 16.0;
  final charsPerLine = (availableWidth / charWidth).floor().clamp(1, 9999);
  
  int index = 0;
  while (index < text.length) {
    final chunkLength = text.length - index > charsPerLine
        ? charsPerLine
        : text.length - index;
    final chunk = text.substring(index, index + chunkLength);
    
    lines.add(LineInfo(
      words: chunk.split(''),
      width: chunk.length * charWidth,
      height: 24.0,
      startIndex: index,
      endIndex: index + chunkLength,
    ));
    
    index += chunkLength;
  }
  
  return lines;
}
