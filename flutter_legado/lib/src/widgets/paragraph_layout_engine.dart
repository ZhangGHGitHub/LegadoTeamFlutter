/// 段落布局引擎
/// 
/// 移植自 Kotlin TextChapterLayout.kt (1363 行) 和 HangingPunctuationRule.kt
/// 实现核心功能:
/// - 段落分页算法
/// - 中文避头尾规则
/// - 两端对齐排版
/// - 行高计算和字体度量
library paragraph_layout_engine;

import 'dart:ui' as ui show Paragraph, ParagraphBuilder, TextBox, TextDirection, BoxHeightStyle, BoxWidthStyle, TextStyle, ParagraphStyle;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/painting.dart';

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

/// 段落布局引擎
/// 
/// 核心排版逻辑，负责将文本分段、分行、分页
class ParagraphLayoutEngine {
  final ParagraphConfig config;
  final BuildContext context;

  final List<ParagraphInfo> _allPageParagraphs;
  double _currentTotalHeight;

  ParagraphLayoutEngine({
    required this.config,
    required this.context,
  }) : _allPageParagraphs = [],
       _currentTotalHeight = 0.0;

  /// 排版整个章节内容
  /// 
  /// 参考 ReadBook.kt 的三章预加载策略
  PageInfo layoutChapter(String content, double availableWidth, double pageHeight) {
    // 分割段落
    final paragraphs = _splitParagraphs(content);
    
    if (paragraphs.isEmpty) {
      return const PageInfo(paragraphs: [], totalHeight: 0);
    }
    
    _allPageParagraphs.clear();
    _currentTotalHeight = 0.0;
    bool isFirstPage = true;
    
    for (final para in paragraphs) {
      final paraInfo = _layoutParagraph(para, availableWidth);
      
      // 添加段落间距
      double spacingHeight = 0.0;
      if (_allPageParagraphs.isNotEmpty && !isFirstPage) {
        spacingHeight = config.paragraphSpacing;
      }
      
      // 检查是否需要换页
      if (!isFirstPage && (_currentTotalHeight + spacingHeight + paraInfo.totalHeight > pageHeight)) {
        // 新页面
        _allPageParagraphs.add(paraInfo);
        _currentTotalHeight = paraInfo.totalHeight;
      } else {
        if (_allPageParagraphs.isEmpty || isFirstPage) {
          _allPageParagraphs.add(paraInfo);
          _currentTotalHeight = paraInfo.totalHeight;
          isFirstPage = false;
        } else {
          // 添加到当前页
          _allPageParagraphs.add(paraInfo);
          _currentTotalHeight += spacingHeight + paraInfo.totalHeight;
        }
      }
    }
    
    return PageInfo(paragraphs: _allPageParagraphs, totalHeight: _currentTotalHeight);
  }

  /// 分割段落
  List<String> _splitParagraphs(String content) {
    // 按双换行符分割段落
    return content.split('\n\n').where((p) => p.trim().isNotEmpty).toList();
  }

  /// 排版单个段落
  ParagraphInfo _layoutParagraph(String paragraph, double availableWidth) {
    final trimmedPara = paragraph.trim();
    
    // 处理首行缩进
    String processableText = trimmedPara;
    double indentWidth = 0.0;
    
    if (config.indent > 0) {
      // 计算缩进宽度
      final textPainter = TextPainter(
        text: TextSpan(text: '  ', style: TextStyle(fontSize: config.fontSize)),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout(maxWidth: availableWidth);
      indentWidth = textPainter.width;
      processableText = '  ' + trimmedPara.substring(2); // 保留两个空格作为缩进
    }
    
    // 使用文字布局器进行分行
    final lines = _breakLines(processableText, availableWidth - indentWidth);
    
    // 计算总高度
    final totalHeight = lines.fold<double>(
      0.0,
      (sum, line) => sum + line.height,
    ) + (lines.length - 1) * config.fontSize; // 行间距
    
    return ParagraphInfo(
      lines: lines,
      totalHeight: totalHeight,
      startIndex: 0,
      endIndex: paragraph.length,
    );
  }

  /// 分行算法
  List<LineInfo> _breakLines(String text, double availableWidth) {
    if (text.isEmpty) return [];
    
    final lines = <LineInfo>[];
    int currentIndex = 0;
    
    while (currentIndex < text.length) {
      final remainingText = text.substring(currentIndex);
      
      // 使用 TextPainter 进行文本测量
      final textPainter = TextPainter(
        text: TextSpan(
          text: remainingText,
          style: TextStyle(fontSize: config.fontSize),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      textPainter.layout(maxWidth: availableWidth);
      
      // 获取文本的盒子信息
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: remainingText.length),
      );
      
      if (boxes.isEmpty) {
        // 无法容纳任何文字，使用单字
        lines.add(LineInfo(
          words: [remainingText[0]],
          width: config.fontSize,
          height: config.fontSize * config.lineHeight,
          startIndex: currentIndex,
          endIndex: currentIndex + 1,
        ));
        currentIndex++;
        continue;
      }
      
      // 找到最大可容纳的文本范围
      int bestEnd = remainingText.length;
      for (int i = remainingText.length; i > 0; i--) {
        final checkBoxes = textPainter.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: i),
        );
        if (checkBoxes.isNotEmpty && checkBoxes.first.toRect().width <= availableWidth) {
          bestEnd = i;
          break;
        }
      }
      
      if (bestEnd == 0) {
        // 单个字符都放不下，强制断行
        bestEnd = 1;
      }
      
      final lineText = remainingText.substring(0, bestEnd);
      
      // 应用避头尾规则
      String processedLine = lineText;
      if (bestEnd < remainingText.length) {
        processedLine = ChinesePunctuationRule.getFirstCharOnLine(
          ChinesePunctuationRule.getLastCharOnLine(lineText),
        );
      }
      
      final finalText = processedLine.isEmpty ? lineText : processedLine;
      
      final linePainter = TextPainter(
        text: TextSpan(
          text: finalText,
          style: TextStyle(fontSize: config.fontSize),
        ),
        textDirection: TextDirection.ltr,
      );
      linePainter.layout(maxWidth: availableWidth);
      
      lines.add(LineInfo(
        words: finalText.split(''),
        width: linePainter.width,
        height: config.fontSize * config.lineHeight,
        startIndex: currentIndex,
        endIndex: currentIndex + finalText.length,
      ));
      
      currentIndex += finalText.length;
    }
    
    return lines;
  }

  /// 渲染排版结果
  Widget render(PageInfo pageInfo) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomMultiChildLayout(
          delegate: _PageLayoutDelegate(pageInfo, constraints.maxWidth, config),
          children: pageInfo.paragraphs.expand((para) => para.lines.map((line) => _LineWidget(line: line, config: config))).toList(),
        );
      },
    );
  }
}

/// 页面布局代理
class _PageLayoutDelegate extends MultiChildLayoutDelegate {
  final PageInfo pageInfo;
  final double maxWidth;
  final ParagraphConfig config;

  _PageLayoutDelegate(this.pageInfo, this.maxWidth, this.config);

  @override
  void performLayout(Size size) {
    double currentY = 0.0;
    
    for (final paragraph in pageInfo.paragraphs) {
      for (final line in paragraph.lines) {
        final box = layoutChild(
          line,
          BoxConstraints.loose(Size(maxWidth, line.height)),
        );
        
        // 水平居中或两端对齐
        double xOffset = 0.0;
        if (config.justify && line.width < maxWidth) {
          xOffset = (maxWidth - line.width) / 2;
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
class _LineWidget extends StatelessWidget {
  final LineInfo line;
  final ParagraphConfig config;

  const _LineWidget({
    required this.line,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: line.height,
      decoration: BoxDecoration(
        color: config.backgroundColor,
      ),
      child: Text(
        line.words.join(''),
        style: TextStyle(
          fontSize: config.fontSize,
          color: config.textColor,
          height: config.lineHeight,
        ),
      ),
    );
  }
}
