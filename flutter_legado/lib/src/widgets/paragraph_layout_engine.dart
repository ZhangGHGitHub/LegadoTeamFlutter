/// 段落布局引擎
/// 
/// 移植自 Kotlin TextChapterLayout.kt (1363 行) 和 HangingPunctuationRule.kt
/// 实现核心功能:
/// - 段落分页算法
/// - 中文避头尾规则
/// - 两端对齐排版
/// - 行高计算和字体度量
/// - 字符宽度缓存（移植自 TextMeasure.kt）
library;

import 'package:flutter/material.dart';
import 'zh_layout.dart';

/// 中文标点悬挂规则
/// 
/// 移植自 HangingPunctuationRule.kt
class ChinesePunctuationRule {
  /// 不能出现在行首的标点
  static const Set<String> beginningPunctuation = {
    '，', '、', '。', '？', '！', '…', '〃', '』', '「」', '」', ',', "'", '"', ')', '〕', '】', '}', '〉', '》',
  };

  /// 不能出现在行末的标点  
  static const Set<String> endingPunctuation = {
    '（', '〔', '「', '《', '『', '【', '｛', '〈', '(', '[', '{', '‹', '<', '', "'", '"', '•',
  };

  /// 检查字符是否为行首标点
  static bool isBeginningPunctuation(String char) => beginningPunctuation.contains(char);

  /// 检查字符是否为行末标点
  static bool isEndingPunctuation(String char) => endingPunctuation.contains(char);

  /// 获取合适的行首替代字符
  static String getFirstCharOnLine(String line) {
    if (line.isEmpty) return '';
    
    final firstChar = line[0];
    if (!isBeginningPunctuation(firstChar)) {
      return line; // 第一个字符可以放在行首
    }
    
    // 找到第一个非行首标点的位置
    for (int i = 0; i < line.length; i++) {
      if (!isBeginningPunctuation(line[i])) {
        return line.substring(i);
      }
    }
    return line;
  }

  /// 获取合适的行末替代字符
  static String getLastCharOnLine(String line) {
    if (line.isEmpty) return '';
    
    final lastChar = line[line.length - 1];
    if (!isEndingPunctuation(lastChar)) {
      return line; // 最后一个字符可以放在行末
    }
    
    // 找到最后一个非行末标点的位置
    for (int i = line.length - 1; i >= 0; i--) {
      if (!isEndingPunctuation(line[i])) {
        return line.substring(0, i + 1);
      }
    }
    return line;
  }
}

/// 段落样式配置
@immutable
class ParagraphConfig {
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double indent;
  final bool justify;
  final Color backgroundColor;
  final Color textColor;

  const ParagraphConfig({
    this.fontSize = 16.0,
    this.lineHeight = 1.6,
    this.paragraphSpacing = 8.0,
    this.indent = 0.0,
    this.justify = true,
    this.backgroundColor = Colors.white,
    this.textColor = Colors.black,
  });

  ParagraphConfig copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? indent,
    bool? justify,
    Color? backgroundColor,
    Color? textColor,
  }) {
    return ParagraphConfig(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      indent: indent ?? this.indent,
      justify: justify ?? this.justify,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
    );
  }
}

/// 行信息
@immutable
class LineInfo {
  final List<String> words;
  final double width;
  final double height;
  final int startIndex;
  final int endIndex;

  const LineInfo({
    required this.words,
    required this.width,
    required this.height,
    required this.startIndex,
    required this.endIndex,
  });
}

/// 段落信息
@immutable
class ParagraphInfo {
  final List<LineInfo> lines;
  final double totalHeight;
  final int startIndex;
  final int endIndex;

  const ParagraphInfo({
    required this.lines,
    required this.totalHeight,
    required this.startIndex,
    required this.endIndex,
  });
}

/// 页面信息
@immutable
class PageInfo {
  final List<ParagraphInfo> paragraphs;
  final double totalHeight;

  const PageInfo({
    required this.paragraphs,
    required this.totalHeight,
  });
}

/// 字符宽度缓存
///
/// 移植自 TextMeasure.kt 的三级缓存策略：
/// - ASCII 字符使用定长数组（128 个槽位）
/// - CJK 统一汉字（U+4E00-U+9FA5）使用通用宽度
/// - 其他 Unicode 字符使用 Map 缓存
class CharWidthCache {
  /// ASCII 字符宽度缓存（对应 Kotlin asciiWidths: FloatArray(128)）
  final List<double> _asciiWidths = List<double>.filled(128, -1.0);

  /// 其他 Unicode 字符宽度缓存（对应 Kotlin codePointWidths: SparseArray）
  final Map<int, double> _codePointWidths = {};

  /// 中文通用字符宽度（对应 Kotlin chineseCommonWidth）
  double chineseCommonWidth = 0.0;

  /// 缓存命中次数（性能统计）
  int hitCount = 0;

  /// 缓存未命中次数（性能统计）
  int missCount = 0;

  /// 查询字符宽度缓存
  ///
  /// 对应 Kotlin measureCodePoint(codePoint: Int): Float
  /// 返回 -1.0 表示未缓存
  double measureCodePoint(int codePoint) {
    if (codePoint < 128) {
      final w = _asciiWidths[codePoint];
      if (w >= 0) hitCount++;
      return w;
    }
    // 中文 Unicode 范围 U+4E00 - U+9FA5（对应 Kotlin 19968..40869）
    if (codePoint >= 19968 && codePoint <= 40869) {
      if (chineseCommonWidth > 0) {
        hitCount++;
        return chineseCommonWidth;
      }
      return -1.0;
    }
    final cached = _codePointWidths[codePoint];
    if (cached != null) {
      hitCount++;
      return cached;
    }
    return -1.0;
  }

  /// 写入字符宽度缓存
  void putCodePoint(int codePoint, double width) {
    if (codePoint < 128) {
      _asciiWidths[codePoint] = width;
    } else {
      _codePointWidths[codePoint] = width;
    }
  }

  /// 清除所有缓存（对应 Kotlin invalidate()）
  void invalidate() {
    _asciiWidths.fillRange(0, 128, -1.0);
    _codePointWidths.clear();
    chineseCommonWidth = 0.0;
    hitCount = 0;
    missCount = 0;
  }

  /// 缓存大小（已缓存的非 ASCII 字符数量）
  int get size => _codePointWidths.length;
}

/// 段落布局引擎
/// 
/// 核心排版逻辑，负责将文本分段、分行、分页
class ParagraphLayoutEngine {
  final ParagraphConfig config;
  final BuildContext context;

  final List<ParagraphInfo> _allPageParagraphs;
  double _currentTotalHeight;

  /// 字符宽度缓存（移植自 TextMeasure.kt 三级缓存）
  final CharWidthCache _charWidthCache = CharWidthCache();

  ParagraphLayoutEngine({
    required this.config,
    required this.context,
  }) : _allPageParagraphs = [],
       _currentTotalHeight = 0.0;

  /// 获取字符宽度缓存（供测试使用）
  CharWidthCache get charWidthCache => _charWidthCache;

  /// 排版整个章节内容
  /// 
  /// 参考 ReadBook.kt 的三章预加载策略
  /// 移植自 TextChapterLayout.kt getTextChapter 方法
  PageInfo layoutChapter(String content, double availableWidth, double pageHeight) {
    // 分割段落
    final paragraphs = _splitParagraphs(content);
    
    if (paragraphs.isEmpty) {
      return const PageInfo(paragraphs: [], totalHeight: 0);
    }
    
    _allPageParagraphs.clear();
    _currentTotalHeight = 0.0;
    
    for (var i = 0; i < paragraphs.length; i++) {
      final para = paragraphs[i];
      final paraInfo = _layoutParagraph(para, availableWidth, isFirst: i == 0);
      
      // 段落间距计算（对应 Kotlin durY += textHeight * paragraphSpacing / 10f）
      double spacingHeight = 0.0;
      if (_allPageParagraphs.isNotEmpty) {
        spacingHeight = config.paragraphSpacing;
      }
      
      // 检查是否需要换页（对应 Kotlin prepareNextPageIfNeed）
      if (_allPageParagraphs.isNotEmpty &&
          (_currentTotalHeight + spacingHeight + paraInfo.totalHeight > pageHeight)) {
        // 超出页面高度，开始新页面
        _allPageParagraphs.clear();
        _allPageParagraphs.add(paraInfo);
        _currentTotalHeight = paraInfo.totalHeight;
      } else {
        if (_allPageParagraphs.isEmpty) {
          _allPageParagraphs.add(paraInfo);
          _currentTotalHeight = paraInfo.totalHeight;
        } else {
          // 添加到当前页
          _allPageParagraphs.add(paraInfo);
          _currentTotalHeight += spacingHeight + paraInfo.totalHeight;
        }
      }
    }
    
    return PageInfo(paragraphs: List.from(_allPageParagraphs), totalHeight: _currentTotalHeight);
  }

  /// 分割段落
  ///
  /// 移植自 Kotlin splitNotBlank：按换行符分割，过滤空白段落
  /// 支持双换行符（\n\n）和单换行符（\n）两种分段模式
  List<String> _splitParagraphs(String content) {
    if (content.trim().isEmpty) return [];
    // 优先按双换行符分割；如果没有双换行符则按单换行符分割
    if (content.contains('\n\n')) {
      return content
          .split(RegExp(r'\n\s*\n'))
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
    }
    // 单换行符分割（对应 Kotlin contents.forEach 逐段处理）
    return content
        .split('\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  /// 排版单个段落
  ///
  /// 移植自 TextChapterLayout.kt setTypeText：
  /// - 首行缩进（对应 Kotlin paragraphIndent + indentCharWidth）
  /// - 行高计算（对应 Kotlin textHeight * lineSpacingExtra）
  ParagraphInfo _layoutParagraph(String paragraph, double availableWidth, {bool isFirst = false}) {
    final trimmedPara = paragraph.trim();
    if (trimmedPara.isEmpty) {
      return const ParagraphInfo(lines: [], totalHeight: 0, startIndex: 0, endIndex: 0);
    }
    
    // 处理首行缩进（对应 Kotlin paragraphIndent）
    // indent > 0 时，在文本前添加全角空格作为缩进
    String processableText = trimmedPara;
    
    if (config.indent > 0) {
      // 使用全角空格实现缩进（对应 Kotlin ChapterProvider.indentChar）
      const indentChars = '\u3000\u3000'; // 两个全角空格
      processableText = '$indentChars$trimmedPara';
    }
    
    // 使用 ZhLayout 中文断行引擎进行分行
    final lines = _breakLines(processableText, availableWidth);
    
    // 计算总高度（对应 Kotlin durY += textHeight * lineSpacingExtra）
    final textHeight = config.fontSize * config.lineHeight;
    final totalHeight = lines.isEmpty ? 0.0 : lines.length * textHeight;
    
    return ParagraphInfo(
      lines: lines,
      totalHeight: totalHeight,
      startIndex: 0,
      endIndex: paragraph.length,
    );
  }

  /// 分行算法（使用 ZhLayout 中文断行引擎）
  ///
  /// 移植自 TextChapterLayout.kt 第 940-948 行：
  /// 1. 测量每个字符宽度
  /// 2. 使用 ZhLayout 进行中文标点感知断行
  List<LineInfo> _breakLines(String text, double availableWidth) {
    if (text.isEmpty) return [];

    // 步骤1：测量每个字符的宽度（对应 Kotlin textPaint.getTextWidthsCompat）
    final widthsArray = _measureCharWidths(text, availableWidth);

    // 步骤2：拆分为字符列表 + 宽度列表（对应 Kotlin measureTextSplit）
    final (words, widths) = TextMeasure.splitByWidths(text, widthsArray);

    if (words.isEmpty) return [];

    // 步骤3：计算中文字符参考宽度（对应 Kotlin cnCharWidthCache）
    final cnCharWidth = _measureSingleChar('我');

    // 步骤4：使用 ZhLayout 断行（对应 Kotlin ZhLayout(text, textPaint, visibleWidth, words, widths, indentSize)）
    final layout = ZhLayout.compute(
      words: words,
      widths: widths,
      availableWidth: availableWidth,
      indentSize: config.indent > 0 ? 2 : 0,
      cnCharWidth: cnCharWidth,
    );

    // 步骤5：根据断行结果构建 LineInfo 列表
    final lines = <LineInfo>[];
    final textHeight = config.fontSize * config.lineHeight;

    for (var lineIndex = 0; lineIndex < layout.lineCount; lineIndex++) {
      final lineStartIdx = layout.getLineStart(lineIndex);
      final lineEndIdx = layout.getLineEnd(lineIndex);

      // 提取当前行的字符
      final lineWords = words.sublist(
        lineStartIdx.clamp(0, words.length),
        lineEndIdx.clamp(0, words.length),
      );
      final lineWidth = layout.getLineWidth(lineIndex);

      // 计算原始文本中的起止索引
      var startOffset = 0;
      for (var i = 0; i < lineStartIdx && i < words.length; i++) {
        startOffset += words[i].length;
      }
      var endOffset = startOffset;
      for (var i = lineStartIdx; i < lineEndIdx && i < words.length; i++) {
        endOffset += words[i].length;
      }

      lines.add(LineInfo(
        words: lineWords,
        width: lineWidth,
        height: textHeight,
        startIndex: startOffset,
        endIndex: endOffset,
      ));
    }

    return lines;
  }

  /// 测量每个字符的宽度（带缓存）
  ///
  /// 移植自 TextMeasure.kt measureTextSplit：
  /// 1. 先查缓存（ASCII 数组 / CJK 通用宽度 / Map）
  /// 2. 未命中则使用 TextPainter 测量并写入缓存
  List<double> _measureCharWidths(String text, double maxWidth) {
    final widths = List<double>.filled(text.length, 0.0);
    final style = TextStyle(fontSize: config.fontSize);

    // 确保中文通用宽度已初始化
    if (_charWidthCache.chineseCommonWidth <= 0) {
      _charWidthCache.chineseCommonWidth = _measureSingleChar('一');
    }

    for (var i = 0; i < text.length; i++) {
      final codePoint = text.codeUnitAt(i);
      final cached = _charWidthCache.measureCodePoint(codePoint);
      if (cached >= 0) {
        widths[i] = cached;
      } else {
        // 缓存未命中，使用 TextPainter 精确测量
        _charWidthCache.missCount++;
        final painter = TextPainter(
          text: TextSpan(text: text[i], style: style),
          textDirection: TextDirection.ltr,
        );
        painter.layout(maxWidth: maxWidth);
        final w = painter.width;
        painter.dispose();
        widths[i] = w;
        _charWidthCache.putCodePoint(codePoint, w);
      }
    }
    return widths;
  }

  /// 测量单个字符宽度（用于中文字符参考宽度）
  ///
  /// 对应 Kotlin paint.measureText("一")
  double _measureSingleChar(String char) {
    final painter = TextPainter(
      text: TextSpan(text: char, style: TextStyle(fontSize: config.fontSize)),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  /// 计算两端对齐的额外字间距
  ///
  /// 移植自 TextChapterLayout.kt addCharsToLineMiddle：
  /// - residualWidth = visibleWidth - desiredWidth
  /// - 有空格时：d = residualWidth / spaceSize
  /// - 无空格时：d = residualWidth / gapCount
  static double computeJustifySpacing({
    required double availableWidth,
    required double lineWidth,
    required int charCount,
    int spaceCount = 0,
  }) {
    if (lineWidth >= availableWidth || charCount <= 1) return 0.0;
    final residualWidth = availableWidth - lineWidth;
    if (spaceCount > 1) {
      // 有空格时分配到空格处（对应 Kotlin spaceSize > 1 分支）
      return residualWidth / spaceCount;
    }
    // 无空格时平均分配到每个字间隙（对应 Kotlin gapCount = words.lastIndex）
    final gapCount = charCount - 1;
    return gapCount > 0 ? residualWidth / gapCount : 0.0;
  }

  /// 渲染排版结果
  Widget render(PageInfo pageInfo) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomMultiChildLayout(
          delegate: _PageLayoutDelegate(pageInfo, constraints.maxWidth, config),
          children: pageInfo.paragraphs.expand((para) {
            return para.lines.asMap().entries.map((entry) {
              final lineIdx = entry.key;
              final line = entry.value;
              final isLastLine = lineIdx == para.lines.length - 1;
              final isSingleLine = para.lines.length == 1;
              // 两端对齐：非最后一行且非单行
              final shouldJustify = config.justify && !isLastLine && !isSingleLine;
              return _LineWidget(
                line: line,
                config: config,
                isJustified: shouldJustify,
                availableWidth: constraints.maxWidth,
              );
            });
          }).toList(),
        );
      },
    );
  }
}

/// 页面布局代理
///
/// 对齐策略移植自 TextChapterLayout.kt：
/// - addCharsToLineFirst: 首行缩进 + 两端对齐
/// - addCharsToLineMiddle: 无缩进两端对齐（字间距分配）
/// - addCharsToLineNatural: 自然排列（最后一行/标题）
class _PageLayoutDelegate extends MultiChildLayoutDelegate {
  final PageInfo pageInfo;
  final double maxWidth;
  final ParagraphConfig config;

  _PageLayoutDelegate(this.pageInfo, this.maxWidth, this.config);

  @override
  void performLayout(Size size) {
    double currentY = 0.0;

    for (final paragraph in pageInfo.paragraphs) {
      for (var lineIdx = 0; lineIdx < paragraph.lines.length; lineIdx++) {
        final line = paragraph.lines[lineIdx];
        layoutChild(
          line,
          BoxConstraints.loose(Size(maxWidth, line.height)),
        );

        // 对齐策略（对应 Kotlin addCharsToLineFirst/Middle/Natural）
        double xOffset = 0.0;
        final isLastLine = lineIdx == paragraph.lines.length - 1;
        final isSingleLine = paragraph.lines.length == 1;

        if (!config.justify || isLastLine || isSingleLine) {
          // 自然排列（addCharsToLineNatural）：最后一行/单行左对齐
          xOffset = 0.0;
        } else {
          // 两端对齐（addCharsToLineMiddle）：字间距分配
          xOffset = 0.0; // 起始位置不变，字间距在渲染层处理
        }

        positionChild(line, Offset(xOffset, currentY));
        currentY += line.height;
      }
      currentY += config.paragraphSpacing;
    }
  }

  @override
  bool shouldRelayout(_PageLayoutDelegate oldDelegate) => false;
}

/// 行 Widget
///
/// 两端对齐渲染移植自 TextChapterLayout.kt addCharsToLineMiddle：
/// - 有空格时：将剩余宽度分配到空格处
/// - 无空格时：将剩余宽度平均分配到每个字间隙
class _LineWidget extends StatelessWidget {
  final LineInfo line;
  final ParagraphConfig config;
  final bool isJustified;
  final double availableWidth;

  const _LineWidget({
    required this.line,
    required this.config,
    this.isJustified = false,
    this.availableWidth = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final text = line.words.join('');

    // 两端对齐：计算额外字间距
    // 对应 Kotlin: residualWidth / gapCount
    double extraLetterSpacing = 0.0;
    if (isJustified && availableWidth > 0 && line.width < availableWidth) {
      final residualWidth = availableWidth - line.width;
      final gapCount = line.words.length - 1;
      if (gapCount > 0) {
        extraLetterSpacing = residualWidth / gapCount;
      }
    }

    return Container(
      height: line.height,
      decoration: BoxDecoration(
        color: config.backgroundColor,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: config.fontSize,
          color: config.textColor,
          height: config.lineHeight,
          letterSpacing: extraLetterSpacing > 0 ? extraLetterSpacing : null,
        ),
      ),
    );
  }
}
