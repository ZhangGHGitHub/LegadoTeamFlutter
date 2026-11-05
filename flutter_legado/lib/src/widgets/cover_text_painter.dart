// 默认封面书名 / 作者文字绘制（设置批6b-1）
//
// 对齐参考版 `CoilBookCover.kt` 的 `CoverTextOverlay`：
// - 书名：宽/8 粗体；竖排逐字（超出 0.8 高度换列），横排居中最多 3 行；
// - 作者：宽/12；竖排位于右侧（右下角收尾），横排居中在 0.75 高度；
// - 拉丁字母为主的文本强制横排（参考版阈值 > 30% 拉丁字母）；
// - 描边：白色 STROKE（竖排粗 1/10 字号、横排书名 1/12），先描边后填充；
// - 阴影：4px 模糊、偏移 (2,2)/(1,1)，仅填充层，描边层不带阴影；
// - 正文色：`useDefaultColor` 时取主题 secondary，否则取日/夜自定义色。
//
// 布局逻辑抽为纯函数 [computeCoverTextLayout]，供 widget 绘制与单测共用
//（竖排/横排/拉丁强制横排/日夜显隐/描边阴影均可直接断言）。
//
// 编写：全栈工程师（设置批6b-1） ｜ 2026-11-06
import 'package:flutter/material.dart';

import '../models/cover_settings.dart';

/// 竖排单字位置（x 为字符中心，y 为字符顶部）
class CoverTextGlyph {
  final String text;
  final double x;
  final double y;

  const CoverTextGlyph(this.text, this.x, this.y);
}

/// 默认封面文字布局（纯数据，可单测）
class CoverTextLayout {
  final Size size;
  final bool horizontal;
  final bool showName;
  final bool showAuthor;
  final bool showStroke;
  final bool showShadow;
  final int textColor;
  final int shadowColor;
  final double nameFontSize;
  final double authorFontSize;

  /// 横排书名区域（左起点 / 顶起点 / 最大宽）
  final double nameX;
  final double nameY;
  final double nameMaxWidth;

  /// 横排作者基线区域（水平居中、顶起点、最大宽）
  final double authorY;
  final double authorMaxWidth;

  /// 横排文本（竖排时为空）
  final String? horizontalName;
  final String? horizontalAuthor;

  /// 竖排逐字（横排时为空）
  final List<CoverTextGlyph> nameGlyphs;
  final List<CoverTextGlyph> authorGlyphs;

  const CoverTextLayout({
    required this.size,
    required this.horizontal,
    required this.showName,
    required this.showAuthor,
    required this.showStroke,
    required this.showShadow,
    required this.textColor,
    required this.shadowColor,
    required this.nameFontSize,
    required this.authorFontSize,
    required this.nameX,
    required this.nameY,
    required this.nameMaxWidth,
    required this.authorY,
    required this.authorMaxWidth,
    required this.horizontalName,
    required this.horizontalAuthor,
    required this.nameGlyphs,
    required this.authorGlyphs,
  });

  /// 是否需要绘制（书名/作者都隐藏或文本为空时为 false）
  bool get hasText =>
      (showName && (horizontalName ?? '').isNotEmpty) ||
      (showAuthor && (horizontalAuthor ?? '').isNotEmpty) ||
      nameGlyphs.isNotEmpty ||
      authorGlyphs.isNotEmpty;
}

/// 计算默认封面文字布局
///
/// [defaultColor] 为 `useDefaultColor=true` 时使用的主题 secondary 色。
CoverTextLayout computeCoverTextLayout({
  required Size size,
  required String? name,
  required String? author,
  required CoverSettings settings,
  required bool isNight,
  required int defaultColor,
}) {
  final width = size.width;
  final height = size.height;
  final safeName = (name ?? '').trim();
  final safeAuthor = (author ?? '').trim();
  final showName =
      settings.showNameFor(isNight: isNight) && safeName.isNotEmpty;
  final showAuthor =
      settings.showAuthorFor(isNight: isNight) && safeAuthor.isNotEmpty;
  final horizontal = settings.horizontalFor(safeName);
  final textColor = settings.textColorFor(
    isNight: isNight,
    defaultColor: defaultColor,
  );
  final shadowColor = settings.shadowColorFor(isNight: isNight);

  final nameFontSize = width / 8;
  final authorFontSize = width / 12;
  final nameMaxWidth = (width * 0.8).clamp(1.0, double.infinity).toDouble();
  final nameX = (width - nameMaxWidth) / 2;
  final nameY = height * 0.08;
  final authorY = height * 0.75;
  final authorMaxWidth = (width * 0.9).clamp(1.0, double.infinity).toDouble();

  if (width <= 0 || height <= 0) {
    return CoverTextLayout(
      size: size,
      horizontal: horizontal,
      showName: showName,
      showAuthor: showAuthor,
      showStroke: settings.showStroke,
      showShadow: settings.showShadow,
      textColor: textColor,
      shadowColor: shadowColor,
      nameFontSize: nameFontSize,
      authorFontSize: authorFontSize,
      nameX: nameX,
      nameY: nameY,
      nameMaxWidth: nameMaxWidth,
      authorY: authorY,
      authorMaxWidth: authorMaxWidth,
      horizontalName: null,
      horizontalAuthor: null,
      nameGlyphs: const [],
      authorGlyphs: const [],
    );
  }

  final nameGlyphs = <CoverTextGlyph>[];
  final authorGlyphs = <CoverTextGlyph>[];
  if (!horizontal) {
    if (showName) {
      // 参考版：首列 x=0.16w / y=0.16h；超出 0.8h 换到下一列，y 回到 0.2h
      final charHeight = nameFontSize * 1.05;
      var x = width * 0.16;
      var y = height * 0.16;
      for (final rune in safeName.runes) {
        nameGlyphs.add(CoverTextGlyph(String.fromCharCode(rune), x, y));
        y += charHeight;
        if (y > height * 0.8) {
          x += nameFontSize * 1.2;
          y = height * 0.2;
        }
      }
    }
    if (showAuthor) {
      // 参考版：右列 x=0.84w；起始 y 从 0.16h 向上回退作者长度，
      // 最低不小于 0.2h（右下角收尾）
      final charHeight = authorFontSize * 1.05;
      final x = width * 0.84;
      final runes = safeAuthor.runes.toList();
      var y = height * 0.16 - runes.length * charHeight;
      if (y < height * 0.2) y = height * 0.2;
      for (final rune in runes) {
        authorGlyphs.add(CoverTextGlyph(String.fromCharCode(rune), x, y));
        y += charHeight;
      }
    }
  }

  return CoverTextLayout(
    size: size,
    horizontal: horizontal,
    showName: showName,
    showAuthor: showAuthor,
    showStroke: settings.showStroke,
    showShadow: settings.showShadow,
    textColor: textColor,
    shadowColor: shadowColor,
    nameFontSize: nameFontSize,
    authorFontSize: authorFontSize,
    nameX: nameX,
    nameY: nameY,
    nameMaxWidth: nameMaxWidth,
    authorY: authorY,
    authorMaxWidth: authorMaxWidth,
    horizontalName: horizontal && showName ? safeName : null,
    horizontalAuthor: horizontal && showAuthor ? safeAuthor : null,
    nameGlyphs: nameGlyphs,
    authorGlyphs: authorGlyphs,
  );
}

/// 默认封面文字 painter
class CoverTextPainter extends CustomPainter {
  final CoverTextLayout layout;

  const CoverTextPainter(this.layout);

  TextStyle _style({
    required double fontSize,
    required FontWeight weight,
    Color? color,
    Paint? foreground,
    List<Shadow>? shadows,
  }) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      height: 1.15,
      color: foreground == null ? color : null,
      foreground: foreground,
      shadows: shadows,
    );
  }

  List<Shadow>? get _fillShadows => layout.showShadow
      ? [
          Shadow(
            color: Color(layout.shadowColor),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ]
      : null;

  Paint _strokePaint(double strokeWidth) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..color = Colors.white;

  void _paintHorizontal(
    Canvas canvas,
    String text, {
    required double fontSize,
    required FontWeight weight,
    required double left,
    required double top,
    required double maxWidth,
    required int maxLines,
    required bool center,
    required double strokeWidth,
  }) {
    TextPainter buildTextPainter({TextStyle? style}) {
      return TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textAlign: center ? TextAlign.center : TextAlign.start,
        maxLines: maxLines,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth);
    }

    if (layout.showStroke) {
      final stroke = buildTextPainter(
        style: _style(
          fontSize: fontSize,
          weight: weight,
          foreground: _strokePaint(strokeWidth),
        ),
      );
      stroke.paint(canvas, Offset(left, top));
    }
    final fill = buildTextPainter(
      style: _style(
        fontSize: fontSize,
        weight: weight,
        color: Color(layout.textColor),
        shadows: _fillShadows,
      ),
    );
    fill.paint(canvas, Offset(left, top));
  }

  void _paintVerticalGlyphs(
    Canvas canvas,
    List<CoverTextGlyph> glyphs, {
    required double fontSize,
    required FontWeight weight,
  }) {
    final stroke = layout.showStroke
        ? _style(
            fontSize: fontSize,
            weight: weight,
            foreground: _strokePaint(fontSize / 10),
          )
        : null;
    final fill = _style(
      fontSize: fontSize,
      weight: weight,
      color: Color(layout.textColor),
      shadows: _fillShadows,
    );
    for (final glyph in glyphs) {
      if (stroke != null) {
        final tp = TextPainter(
          text: TextSpan(text: glyph.text, style: stroke),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(glyph.x - tp.width / 2, glyph.y));
      }
      final tp = TextPainter(
        text: TextSpan(text: glyph.text, style: fill),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(glyph.x - tp.width / 2, glyph.y));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.horizontal) {
      final name = layout.horizontalName;
      if (name != null) {
        _paintHorizontal(
          canvas,
          name,
          fontSize: layout.nameFontSize,
          weight: FontWeight.bold,
          left: layout.nameX,
          top: layout.nameY,
          maxWidth: layout.nameMaxWidth,
          maxLines: 3,
          center: true,
          strokeWidth: layout.nameFontSize / 12,
        );
      }
      final author = layout.horizontalAuthor;
      if (author != null) {
        _paintHorizontal(
          canvas,
          author,
          fontSize: layout.authorFontSize,
          weight: FontWeight.normal,
          left: (size.width - layout.authorMaxWidth) / 2,
          top: layout.authorY,
          maxWidth: layout.authorMaxWidth,
          maxLines: 1,
          center: true,
          strokeWidth: layout.authorFontSize / 10,
        );
      }
      return;
    }
    if (layout.nameGlyphs.isNotEmpty) {
      _paintVerticalGlyphs(
        canvas,
        layout.nameGlyphs,
        fontSize: layout.nameFontSize,
        weight: FontWeight.bold,
      );
    }
    if (layout.authorGlyphs.isNotEmpty) {
      _paintVerticalGlyphs(
        canvas,
        layout.authorGlyphs,
        fontSize: layout.authorFontSize,
        weight: FontWeight.normal,
      );
    }
  }

  @override
  bool shouldRepaint(CoverTextPainter oldDelegate) => true;
}
