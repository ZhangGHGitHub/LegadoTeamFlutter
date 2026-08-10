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

  // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂（对齐原版
  // HangingPunctuationRule.shouldHang(text, paragraphIndent)）：段首 =
  // 缩进全角空格（indentCount 个）+ 起始引号，且非 RTL（中文排版无 RTL
  // 场景，跳过检查）— Reasonix

  /// 段首可悬挂的起始引号字符
  static const Set<String> hangingChars = {
    '"', '“', '‘', '「', '『', '﹁', '﹃',
  };

  /// 判断段首是否应悬挂（缩进空格 + 起始引号）
  static bool shouldHang(String text, int indentCount) {
    if (indentCount <= 0) return false;
    var pos = 0;
    for (var i = 0; i < indentCount; i++) {
      if (pos >= text.length || text[pos] != '\u3000') return false;
      pos++;
    }
    if (pos >= text.length) return false;
    return hangingChars.contains(text[pos]);
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

  // [UI-fix v2.0.2 | 2026-08-06] 字距与字体接入排版配置（阅读配置面板
  // 字距调节/字体选择；测量与渲染同参，保证分页一致性） — Qoder
  final double letterSpacing;
  final String? fontFamily;

  // [UI-fix v2.0.4 | 2026-08-08] 界面面板对齐原版 ReadStyleDialog：
  // 缩进字符数档位（0-3，对标原版 tvTextIndent "　".repeat(index)）与
  // 文字字重（textBold 映射 FontWeight，测量与渲染同参避免分页偏差） — Qoder
  final int indentCount;
  final FontWeight? fontWeight;

  // [UI-fix v2.0.5 | 2026-08-10] 自定义中文分行开关（对标原版 useZhLayout：
  // true=ZhLayout 中文避头尾断行；false=朴素按宽断行）— Reasonix
  final bool useZhLayout;

  // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂开关（对标原版
  // hangingPunctuation：段首引号悬挂进缩进区，默认 false 对齐原版）— Reasonix
  final bool hangingPunctuation;

  const ParagraphConfig({
    this.fontSize = 16.0,
    this.lineHeight = 1.6,
    this.paragraphSpacing = 8.0,
    this.indent = 0.0,
    this.justify = true,
    this.backgroundColor = Colors.white,
    this.textColor = Colors.black,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.indentCount = 2,
    this.fontWeight,
    this.useZhLayout = true,
    this.hangingPunctuation = false,
  });

  ParagraphConfig copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? indent,
    bool? justify,
    Color? backgroundColor,
    Color? textColor,
    double? letterSpacing,
    String? fontFamily,
    int? indentCount,
    FontWeight? fontWeight,
    bool? useZhLayout,
    bool? hangingPunctuation,
  }) {
    return ParagraphConfig(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      indent: indent ?? this.indent,
      justify: justify ?? this.justify,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      fontFamily: fontFamily ?? this.fontFamily,
      indentCount: indentCount ?? this.indentCount,
      fontWeight: fontWeight ?? this.fontWeight,
      useZhLayout: useZhLayout ?? this.useZhLayout,
      hangingPunctuation: hangingPunctuation ?? this.hangingPunctuation,
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

  // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂宽度（>0 表示该行为悬挂行，
  // 渲染侧行起点左移该宽度进入缩进区）— Reasonix
  final double hangingWidth;

  const LineInfo({
    required this.words,
    required this.width,
    required this.height,
    required this.startIndex,
    required this.endIndex,
    this.hangingWidth = 0,
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

  /// 字符宽度缓存（移植自 TextMeasure.kt 三级缓存）
  final CharWidthCache _charWidthCache = CharWidthCache();

  ParagraphLayoutEngine({
    required this.config,
    required this.context,
  });

  /// 获取字符宽度缓存（供测试使用）
  CharWidthCache get charWidthCache => _charWidthCache;

  /// 排版整个章节内容（仅返回最后一页，保留兼容）
  /// 
  /// 参考 ReadBook.kt 的三章预加载策略
  /// 移植自 TextChapterLayout.kt getTextChapter 方法
  PageInfo layoutChapter(String content, double availableWidth, double pageHeight) {
    final pages = paginateChapter(content, availableWidth, pageHeight);
    if (pages.isEmpty) return const PageInfo(paragraphs: [], totalHeight: 0);
    return pages.last;
  }

  /// 将整章内容排版并分页，返回所有页面
  ///
  /// 移植自 TextChapterLayout.kt getTextChapter + prepareNextPageIfNeed：
  /// 逐段排版，累积到当前页；超出页面高度时开始新页。
  /// 返回的每个 PageInfo 代表一屏内容。
  ///
  /// [UI-fix v2.0.4 | 2026-08-08] 新增 [firstPageHeight]：首页可用高度
  /// （渲染侧首页预留章节标题块，容量小于后续页；不传则与
  /// pageHeight 一致），修复满页正文首页底部 RenderFlex 溢出 — Qoder
  List<PageInfo> paginateChapter(String content, double availableWidth, double pageHeight,
      {double? firstPageHeight}) {
    final paragraphs = _splitParagraphs(content);
    if (paragraphs.isEmpty) return [];

    final pages = <PageInfo>[];
    var currentPageParagraphs = <ParagraphInfo>[];
    var currentHeight = 0.0;

    // 指定页的可用高度：首页按 firstPageHeight，其余页按 pageHeight
    double capacityFor(int pageIndex) =>
        pageIndex == 0 ? (firstPageHeight ?? pageHeight) : pageHeight;

    for (var i = 0; i < paragraphs.length; i++) {
      final para = paragraphs[i];
      final paraInfo = _layoutParagraph(para, availableWidth, isFirst: i == 0);

      // 段落间距（对应 Kotlin durY += textHeight * paragraphSpacing / 10f）
      double spacingHeight = currentPageParagraphs.isNotEmpty ? config.paragraphSpacing : 0.0;

      // 单段超出其起始页容量时，按行拆分到多页（当前页已有内容则
      // 段落从下一页起排，按整页容量判断）
      final startCapacity =
          currentPageParagraphs.isEmpty ? capacityFor(pages.length) : pageHeight;
      if (paraInfo.totalHeight > startCapacity) {
        // 先把之前累积的段落存为一页
        if (currentPageParagraphs.isNotEmpty) {
          pages.add(PageInfo(paragraphs: List.from(currentPageParagraphs), totalHeight: currentHeight));
          currentPageParagraphs = [];
          currentHeight = 0.0;
        }
        // 按行拆分超长段落（首张子页若落在章首页则按首页容量）
        final subPages = _splitTallParagraph(paraInfo, pageHeight,
            firstPageCapacity: capacityFor(pages.length));
        pages.addAll(subPages);
        continue;
      }

      // 检查是否需要换页（对应 Kotlin prepareNextPageIfNeed）
      if (currentPageParagraphs.isNotEmpty &&
          (currentHeight + spacingHeight + paraInfo.totalHeight >
              capacityFor(pages.length))) {
        // 当前页已满，保存并开始新页
        pages.add(PageInfo(paragraphs: List.from(currentPageParagraphs), totalHeight: currentHeight));
        currentPageParagraphs = [paraInfo];
        currentHeight = paraInfo.totalHeight;
      } else {
        currentPageParagraphs.add(paraInfo);
        currentHeight += spacingHeight + paraInfo.totalHeight;
      }
    }

    // 最后一页
    if (currentPageParagraphs.isNotEmpty) {
      pages.add(PageInfo(paragraphs: currentPageParagraphs, totalHeight: currentHeight));
    }

    return pages;
  }

  /// 将超出单页高度的段落按行拆分到多页
  ///
  /// 对应 Kotlin TextChapterLayout 中单段超长时的逐行分页逻辑；
  /// [UI-fix v2.0.4 | 2026-08-08] 支持首张子页按 [firstPageCapacity]
  /// 限容（落在章首页时预留标题块高度）— Qoder
  List<PageInfo> _splitTallParagraph(ParagraphInfo paraInfo, double pageHeight,
      {double? firstPageCapacity}) {
    final pages = <PageInfo>[];
    final textHeight = config.fontSize * config.lineHeight;

    var lineIdx = 0;
    var subPageNo = 0;
    while (lineIdx < paraInfo.lines.length) {
      final capacity =
          subPageNo == 0 ? (firstPageCapacity ?? pageHeight) : pageHeight;
      final linesPerPage = (capacity / textHeight).floor().clamp(1, 9999);
      final endIdx = (lineIdx + linesPerPage).clamp(0, paraInfo.lines.length);
      final pageLines = paraInfo.lines.sublist(lineIdx, endIdx);
      final height = pageLines.length * textHeight;
      pages.add(PageInfo(
        paragraphs: [ParagraphInfo(
          lines: pageLines,
          totalHeight: height,
          startIndex: pageLines.isNotEmpty ? pageLines.first.startIndex : 0,
          endIndex: pageLines.isNotEmpty ? pageLines.last.endIndex : 0,
        )],
        totalHeight: height,
      ));
      lineIdx = endIdx;
      subPageNo++;
    }
    return pages;
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
      // [UI-fix v2.0.4 | 2026-08-08] 缩进改按字符数档位生成全角空格
      // （对应原版 ReadBookConfig.paragraphIndent "　".repeat(index)） — Qoder
      final indentChars = '\u3000' * config.indentCount;
      processableText = '$indentChars$trimmedPara';
    }
    
    // 使用 ZhLayout 中文断行引擎进行分行
    // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂：段首 = 缩进全角空格 +
    // 起始引号时，首行可用宽 + 缩进宽度（标点悬挂进缩进区，对齐原版
    // HangingPunctuationRule + ZhLayout.hangingWidth 语义）— Reasonix
    final hangingWidth = config.hangingPunctuation &&
            config.indent > 0 &&
            ChinesePunctuationRule.shouldHang(processableText, config.indentCount)
        ? config.indent
        : 0.0;
    final lines = _breakLines(
      processableText,
      availableWidth,
      hangingWidth: hangingWidth,
    );
    
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
  ///
  /// [UI-fix v2.0.5 | 2026-08-10] `hangingWidth` > 0 时首行可用宽上限
  /// 增加该宽度（段首标点悬挂）— Reasonix
  List<LineInfo> _breakLines(
    String text,
    double availableWidth, {
    double hangingWidth = 0,
  }) {
    if (text.isEmpty) return [];

    // 测量每个字符的宽度（对应 Kotlin textPaint.getTextWidthsCompat）
    final widthsArray = _measureCharWidths(text, availableWidth);

    // 步骤2：拆分为字符列表 + 宽度列表（对应 Kotlin measureTextSplit）
    final (words, widths) = TextMeasure.splitByWidths(text, widthsArray);

    if (words.isEmpty) return [];

    // [UI-fix v2.0.5 | 2026-08-10] useZhLayout=false：朴素按宽断行
    //（无中文避头尾，对齐原版 useZhLayout=false 走 StaticLayout 语义）— Reasonix
    if (!config.useZhLayout) {
      final plainLines = <LineInfo>[];
      final textHeight = config.fontSize * config.lineHeight;
      var lineStartIdx = 0;
      var lineWidth = 0.0;
      void flushLine(int endIdx) {
        final lineWords = words.sublist(lineStartIdx, endIdx);
        var startOffset = 0;
        for (var i = 0; i < lineStartIdx && i < words.length; i++) {
          startOffset += words[i].length;
        }
        var endOffset = startOffset;
        for (var i = lineStartIdx; i < endIdx && i < words.length; i++) {
          endOffset += words[i].length;
        }
        plainLines.add(LineInfo(
          words: lineWords,
          width: lineWidth,
          height: textHeight,
          startIndex: startOffset,
          endIndex: endOffset,
          // 悬挂仅作用于首行（行起点索引 0）
          hangingWidth: lineStartIdx == 0 ? hangingWidth : 0,
        ));
      }
      for (var i = 0; i < words.length; i++) {
        final w = widths[i];
        final limit = lineStartIdx == 0 ? availableWidth + hangingWidth : availableWidth;
        if (i > lineStartIdx && lineWidth + w > limit) {
          flushLine(i);
          lineStartIdx = i;
          lineWidth = 0.0;
        }
        lineWidth += w;
      }
      if (lineStartIdx < words.length) {
        flushLine(words.length);
      }
      return plainLines;
    }

    // 步骤3：计算中文字符参考宽度（对应 Kotlin cnCharWidthCache）
    final cnCharWidth = _measureSingleChar('我');

    // 步骤4：使用 ZhLayout 断行（对应 Kotlin ZhLayout(text, textPaint, visibleWidth, words, widths, indentSize)）
    final layout = ZhLayout.compute(
      words: words,
      widths: widths,
      availableWidth: availableWidth,
      // [UI-fix v2.0.4 | 2026-08-08] 缩进档位接入断行引擎 — Qoder
      indentSize: config.indent > 0 ? config.indentCount : 0,
      cnCharWidth: cnCharWidth,
      // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂：首行宽度上限放宽 — Reasonix
      hangingWidth: hangingWidth,
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
        // 悬挂仅作用于首行
        hangingWidth: lineIndex == 0 ? hangingWidth : 0,
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
    // [UI-fix v2.0.2 | 2026-08-06] 测量样式同步字距/字体配置 — Qoder
    // [UI-fix v2.0.4 | 2026-08-08] 测量样式同步字重（textBold） — Qoder
    final style = TextStyle(
      fontSize: config.fontSize,
      letterSpacing: config.letterSpacing != 0 ? config.letterSpacing : null,
      fontFamily: config.fontFamily,
      fontWeight: config.fontWeight,
    );

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
      // [UI-fix v2.0.2 | 2026-08-06] 单字宽度测量同步字距/字体配置 — Qoder
      // [UI-fix v2.0.4 | 2026-08-08] 同步字重（textBold） — Qoder
      text: TextSpan(
        text: char,
        style: TextStyle(
          fontSize: config.fontSize,
          letterSpacing:
              config.letterSpacing != 0 ? config.letterSpacing : null,
          fontFamily: config.fontFamily,
          fontWeight: config.fontWeight,
        ),
      ),
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
          fontFamily: config.fontFamily,
          // [UI-fix v2.0.2 | 2026-08-06] 渲染字距 = 配置基础字距 + 两端对齐额外字距 — Qoder
          letterSpacing: (config.letterSpacing +
                  (extraLetterSpacing > 0 ? extraLetterSpacing : 0)) !=
              0
              ? config.letterSpacing +
                  (extraLetterSpacing > 0 ? extraLetterSpacing : 0)
              : null,
        ),
      ),
    );
  }
}

// ===== 跨章节连续分页 =====

/// 章节分页信息
///
/// 记录单个章节的索引及其分页数量，用于跨章节全局页索引映射。
@immutable
class ChapterPageInfo {
  /// 章节索引（对应目录中的位置）
  final int chapterIndex;

  /// 该章节的总页数
  final int pageCount;

  const ChapterPageInfo({
    required this.chapterIndex,
    required this.pageCount,
  });

  @override
  String toString() => 'ChapterPageInfo(chapter: $chapterIndex, pages: $pageCount)';
}

/// 跨章节连续分页器
///
/// 实现全局页索引与 (章节索引, 章内页索引) 的双向映射。
/// 采用链表式存储（非内容拼接），内存高效：
/// - 仅存储每章的页数元数据，不持有章节正文
/// - 支持动态增删章节（预加载/卸载）
/// - 二分查找定位章节，O(log n) 复杂度
class CrossChapterPaginator {
  /// 按章节索引排序的分页信息列表
  final List<ChapterPageInfo> _chapters = [];

  /// 前缀和缓存：_prefixSums[i] = 前 i 章的总页数
  /// _prefixSums[0] = 0, _prefixSums[n] = totalPages
  List<int> _prefixSums = [0];

  /// 缓存是否过期
  bool _dirty = true;

  /// 获取已注册的章节数量
  int get chapterCount => _chapters.length;

  /// 总页数（所有章节页数之和）
  int totalPages() {
    _rebuildPrefixSumsIfNeeded();
    return _prefixSums.isEmpty ? 0 : _prefixSums.last;
  }

  /// 全局页索引 → 所属章节索引
  ///
  /// 使用二分查找在前缀和数组中定位。
  /// 返回 -1 表示无效索引（空列表或越界）。
  int chapterForPage(int globalIndex) {
    if (_chapters.isEmpty || globalIndex < 0) return -1;
    _rebuildPrefixSumsIfNeeded();
    final total = _prefixSums.last;
    if (globalIndex >= total) return -1;

    // 二分查找：找到最后一个 prefixSum <= globalIndex 的位置
    var lo = 0;
    var hi = _chapters.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_prefixSums[mid] <= globalIndex) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _chapters[lo].chapterIndex;
  }

  /// 全局页索引 → 章内页索引
  ///
  /// 返回 -1 表示无效索引。
  int pageInChapter(int globalIndex) {
    if (_chapters.isEmpty || globalIndex < 0) return -1;
    _rebuildPrefixSumsIfNeeded();
    final total = _prefixSums.last;
    if (globalIndex >= total) return -1;

    final chapterSlot = _findChapterSlot(globalIndex);
    if (chapterSlot < 0) return -1;
    return globalIndex - _prefixSums[chapterSlot];
  }

  /// 章节索引 → 该章第一页的全局页索引
  ///
  /// 返回 -1 表示章节未注册。
  int globalIndexForChapterStart(int chapterIndex) {
    final slot = _findSlotByChapterIndex(chapterIndex);
    if (slot < 0) return -1;
    _rebuildPrefixSumsIfNeeded();
    return _prefixSums[slot];
  }

  /// 章节索引 → 该章最后一页的全局页索引
  ///
  /// 返回 -1 表示章节未注册或页数为 0。
  int globalIndexForChapterEnd(int chapterIndex) {
    final slot = _findSlotByChapterIndex(chapterIndex);
    if (slot < 0) return -1;
    _rebuildPrefixSumsIfNeeded();
    final pageCount = _chapters[slot].pageCount;
    if (pageCount <= 0) return -1;
    return _prefixSums[slot] + pageCount - 1;
  }

  /// 获取指定章节的页数
  ///
  /// 返回 0 表示章节未注册。
  int pageCountForChapter(int chapterIndex) {
    final slot = _findSlotByChapterIndex(chapterIndex);
    if (slot < 0) return 0;
    return _chapters[slot].pageCount;
  }

  /// 添加或更新章节分页信息
  ///
  /// 如果章节已存在则更新页数，否则按章节索引排序插入。
  void addChapter(int chapterIndex, int pageCount) {
    final existingSlot = _findSlotByChapterIndex(chapterIndex);
    if (existingSlot >= 0) {
      // 更新已有章节的页数
      _chapters[existingSlot] = ChapterPageInfo(
        chapterIndex: chapterIndex,
        pageCount: pageCount,
      );
    } else {
      // 按章节索引排序插入
      var insertPos = _chapters.length;
      for (var i = 0; i < _chapters.length; i++) {
        if (_chapters[i].chapterIndex > chapterIndex) {
          insertPos = i;
          break;
        }
      }
      _chapters.insert(
        insertPos,
        ChapterPageInfo(chapterIndex: chapterIndex, pageCount: pageCount),
      );
    }
    _dirty = true;
  }

  /// 移除章节
  ///
  /// 移除后全局页索引自动调整。
  void removeChapter(int chapterIndex) {
    final slot = _findSlotByChapterIndex(chapterIndex);
    if (slot >= 0) {
      _chapters.removeAt(slot);
      _dirty = true;
    }
  }

  /// 清空所有章节
  void clear() {
    _chapters.clear();
    _prefixSums = [0];
    _dirty = false;
  }

  /// 判断全局页索引是否有效
  bool isValidGlobalIndex(int globalIndex) {
    if (globalIndex < 0) return false;
    _rebuildPrefixSumsIfNeeded();
    return _prefixSums.isNotEmpty && globalIndex < _prefixSums.last;
  }

  /// 获取全局页索引对应的完整映射信息
  ///
  /// 返回 null 表示无效索引。
  ({int chapterIndex, int pageIndex})? resolve(int globalIndex) {
    final chapter = chapterForPage(globalIndex);
    if (chapter < 0) return null;
    final page = pageInChapter(globalIndex);
    if (page < 0) return null;
    return (chapterIndex: chapter, pageIndex: page);
  }

  // ===== 内部方法 =====

  /// 重建前缀和缓存
  void _rebuildPrefixSumsIfNeeded() {
    if (!_dirty) return;
    _prefixSums = List<int>.filled(_chapters.length + 1, 0);
    for (var i = 0; i < _chapters.length; i++) {
      _prefixSums[i + 1] = _prefixSums[i] + _chapters[i].pageCount;
    }
    _dirty = false;
  }

  /// 根据全局页索引查找所属章节在 _chapters 列表中的槽位
  int _findChapterSlot(int globalIndex) {
    _rebuildPrefixSumsIfNeeded();
    var lo = 0;
    var hi = _chapters.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_prefixSums[mid] <= globalIndex) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 根据章节索引查找在 _chapters 列表中的槽位
  ///
  /// 使用二分查找（列表按 chapterIndex 排序）。
  int _findSlotByChapterIndex(int chapterIndex) {
    var lo = 0;
    var hi = _chapters.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final midIndex = _chapters[mid].chapterIndex;
      if (midIndex == chapterIndex) return mid;
      if (midIndex < chapterIndex) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }
}
