import 'package:flutter/material.dart';

import '../../screens/reader_config_panel.dart';

/// 阅读页避让系统状态栏的顶部 inset（对标原版 TitleBar fitStatusBar /
/// WindowInsetsCompat.Type.systemBars）。
///
/// 沉浸式 edge-to-edge（`setDecorFitsSystemWindows(false)`）下
/// [MediaQuery.padding] 的 top 可能为 0，须用 [MediaQuery.viewPadding]，
/// 否则顶栏标题/页眉会与电量、时间重叠。
double readerSystemStatusBarInset(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).top;

/// 正文区稳定顶 inset：readBodyToLh 且未隐藏状态栏时预留（不随工具栏显隐
/// 变化，避免切换 ReadMenu 时正文上跳；外层 SafeArea 已避让时不再重复）。
double readerContentStatusBarInset(
  BuildContext context, {
  required bool hideStatusBar,
  required bool readBodyToLh,
}) {
  if (hideStatusBar || !readBodyToLh) return 0;
  return readerSystemStatusBarInset(context);
}

/// 顶栏/状态条 overlay inset：正文延伸至状态栏时须显式避让系统栏。
double readerOverlayStatusBarInset(
  BuildContext context, {
  required bool readBodyToLh,
}) {
  if (!readBodyToLh) return 0;
  return readerSystemStatusBarInset(context);
}

/// 阅读页页眉/页脚与标题样式（对标原版 ReadBookConfig + ReadTipConfig）
class ReaderPageChromeConfig {
  final int headerMode;
  final int footerMode;
  final bool hideStatusBar;

  final double headerPaddingTop;
  final double headerPaddingBottom;
  final double headerPaddingLeft;
  final double headerPaddingRight;
  final double footerPaddingTop;
  final double footerPaddingBottom;
  final double footerPaddingLeft;
  final double footerPaddingRight;
  final bool showHeaderLine;
  final bool showFooterLine;

  final int tipHeaderLeft;
  final int tipHeaderMiddle;
  final int tipHeaderRight;
  final int tipFooterLeft;
  final int tipFooterMiddle;
  final int tipFooterRight;

  final int titleMode;
  final int titleSize;
  final int titleTopSpacing;
  final int titleBottomSpacing;

  const ReaderPageChromeConfig({
    this.headerMode = 0,
    this.footerMode = 0,
    this.hideStatusBar = false,
    this.headerPaddingTop = 0,
    this.headerPaddingBottom = 0,
    this.headerPaddingLeft = 16,
    this.headerPaddingRight = 16,
    this.footerPaddingTop = 6,
    this.footerPaddingBottom = 6,
    this.footerPaddingLeft = 16,
    this.footerPaddingRight = 16,
    this.showHeaderLine = false,
    this.showFooterLine = true,
    this.tipHeaderLeft = 2,
    this.tipHeaderMiddle = 0,
    this.tipHeaderRight = 3,
    this.tipFooterLeft = 1,
    this.tipFooterMiddle = 0,
    this.tipFooterRight = 6,
    this.titleMode = 0,
    this.titleSize = 0,
    this.titleTopSpacing = 0,
    this.titleBottomSpacing = 0,
  });

  factory ReaderPageChromeConfig.fromAdvanced(ReaderAdvancedConfig c) {
    return ReaderPageChromeConfig(
      headerMode: c.headerMode,
      footerMode: c.footerMode,
      hideStatusBar: c.hideStatusBar,
      headerPaddingTop: c.headerPaddingTop,
      headerPaddingBottom: c.headerPaddingBottom,
      headerPaddingLeft: c.headerPaddingLeft,
      headerPaddingRight: c.headerPaddingRight,
      footerPaddingTop: c.footerPaddingTop,
      footerPaddingBottom: c.footerPaddingBottom,
      footerPaddingLeft: c.footerPaddingLeft,
      footerPaddingRight: c.footerPaddingRight,
      showHeaderLine: c.showHeaderLine,
      showFooterLine: c.showFooterLine,
      tipHeaderLeft: c.tipHeaderLeft,
      tipHeaderMiddle: c.tipHeaderMiddle,
      tipHeaderRight: c.tipHeaderRight,
      tipFooterLeft: c.tipFooterLeft,
      tipFooterMiddle: c.tipFooterMiddle,
      tipFooterRight: c.tipFooterRight,
      titleMode: c.titleMode,
      titleSize: c.titleSize,
      titleTopSpacing: c.titleTopSpacing,
      titleBottomSpacing: c.titleBottomSpacing,
    );
  }

  String get layoutKey =>
      '${headerMode}_${footerMode}_${hideStatusBar}_'
      '${headerPaddingTop}_${headerPaddingBottom}_${headerPaddingLeft}_${headerPaddingRight}_'
      '${footerPaddingTop}_${footerPaddingBottom}_${footerPaddingLeft}_${footerPaddingRight}_'
      '${showHeaderLine}_${showFooterLine}_'
      '${tipHeaderLeft}_${tipHeaderMiddle}_${tipHeaderRight}_'
      '${tipFooterLeft}_${tipFooterMiddle}_${tipFooterRight}_'
      '${titleMode}_${titleSize}_${titleTopSpacing}_${titleBottomSpacing}';

  bool get showPageHeader {
    switch (headerMode.clamp(0, 2)) {
      case 1:
        return true;
      case 2:
        return false;
      default:
        return hideStatusBar;
    }
  }

  bool get showPageFooter => footerMode != 1;

  bool get hasHeaderTips =>
      tipHeaderLeft != 0 || tipHeaderMiddle != 0 || tipHeaderRight != 0;

  bool get hasFooterTips =>
      tipFooterLeft != 0 || tipFooterMiddle != 0 || tipFooterRight != 0;
}

class ReaderTipContext {
  final String bookName;
  final String chapterTitle;
  final int pageIndex;
  final int totalPages;
  final int? globalPageIndex;
  final int? globalTotalPages;
  final double readProgress;
  final int chapterIndex;
  final int chapterCount;
  final int batteryLevel;

  const ReaderTipContext({
    this.bookName = '',
    this.chapterTitle = '',
    required this.pageIndex,
    required this.totalPages,
    this.globalPageIndex,
    this.globalTotalPages,
    this.readProgress = 0,
    this.chapterIndex = 0,
    this.chapterCount = 0,
    this.batteryLevel = 100,
  });

  String get time {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  String get pageText => '${pageIndex + 1}';
  String get totalPagesText => '$totalPages';
  String get readProgressText => '${(readProgress * 100).toStringAsFixed(1)}%';
  String get chapterText => chapterCount > 0 ? '${chapterIndex + 1}' : '';
  String get totalChaptersText => chapterCount > 0 ? '$chapterCount' : '';
}

String readerLegacyTipText(int tip, ReaderTipContext ctx) {
  switch (tip) {
    case 7:
      return ctx.bookName;
    case 1:
      return ctx.chapterTitle;
    case 2:
      return ctx.time;
    case 3:
      return '';
    case 10:
      return '${ctx.batteryLevel}%';
    case 4:
      return '${ctx.pageText}/${ctx.totalPagesText}';
    case 5:
      return ctx.readProgressText;
    case 11:
      if (ctx.chapterCount <= 0) return '';
      return '${ctx.chapterText}/${ctx.totalChaptersText}';
    case 6:
      return '${ctx.pageText}/${ctx.totalPagesText}  ${ctx.readProgressText}';
    case 8:
      return ctx.time;
    case 9:
      return '${ctx.time} ${ctx.batteryLevel}%';
    default:
      return '';
  }
}

bool readerTipShowsBatteryIcon(int tip) => tip == 3;

class ReaderPageTipBar extends StatelessWidget {
  final EdgeInsets padding;
  final int leftTip;
  final int middleTip;
  final int rightTip;
  final ReaderTipContext tipContext;
  final Color textColor;
  final bool showDivider;
  final bool dividerOnTop;

  const ReaderPageTipBar({
    super.key,
    required this.padding,
    required this.leftTip,
    required this.middleTip,
    required this.rightTip,
    required this.tipContext,
    required this.textColor,
    this.showDivider = false,
    this.dividerOnTop = false,
  });

  static const _tipStyle = TextStyle(fontSize: 12);

  @override
  Widget build(BuildContext context) {
    final color = textColor.withValues(alpha: 0.55);
    final divider = Divider(
      height: 1,
      thickness: 1,
      color: textColor.withValues(alpha: 0.12),
    );

    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDivider && dividerOnTop) divider,
          Row(
            children: [
              Expanded(child: _slot(leftTip, color, Alignment.centerLeft)),
              Expanded(child: _slot(middleTip, color, Alignment.center)),
              Expanded(child: _slot(rightTip, color, Alignment.centerRight)),
            ],
          ),
          if (showDivider && !dividerOnTop) divider,
        ],
      ),
    );
  }

  Widget _slot(int tip, Color color, Alignment alignment) {
    if (tip == 0) return const SizedBox.shrink();
    if (tip == 8) {
      return Align(
        alignment: alignment,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tipContext.time, style: _tipStyle.copyWith(color: color)),
            const SizedBox(width: 6),
            Icon(Icons.battery_std, size: 14, color: color),
          ],
        ),
      );
    }
    if (readerTipShowsBatteryIcon(tip)) {
      return Align(
        alignment: alignment,
        child: Icon(Icons.battery_std, size: 14, color: color),
      );
    }
    final text = readerLegacyTipText(tip, tipContext);
    if (text.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: alignment,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _tipStyle.copyWith(color: color),
      ),
    );
  }
}

class ReaderPageLayoutMetrics {
  static const _tipStyle = TextStyle(fontSize: 12);
  static const _legacyIndicatorStyle = TextStyle(fontSize: 11);

  static double measureTipBarHeight({
    required EdgeInsets padding,
    required BuildContext context,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: '0', style: _tipStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final line = painter.height;
    painter.dispose();
    return padding.top + padding.bottom + line;
  }

  static double measureLegacyPageIndicatorHeight(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      text: TextSpan(
        text: '0/0',
        style: baseStyle.merge(_legacyIndicatorStyle),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final h = 8 + painter.height;
    painter.dispose();
    return h;
  }

  static double headerBlockHeight(
    BuildContext context,
    ReaderPageChromeConfig chrome,
  ) {
    if (!chrome.showPageHeader || !chrome.hasHeaderTips) return 0;
    return measureTipBarHeight(
          context: context,
          padding: EdgeInsets.fromLTRB(
            chrome.headerPaddingLeft,
            chrome.headerPaddingTop,
            chrome.headerPaddingRight,
            chrome.headerPaddingBottom,
          ),
        ) +
        (chrome.showHeaderLine ? 1 : 0);
  }

  static double footerBlockHeight(
    BuildContext context,
    ReaderPageChromeConfig chrome,
  ) {
    if (chrome.showPageFooter && chrome.hasFooterTips) {
      return measureTipBarHeight(
            context: context,
            padding: EdgeInsets.fromLTRB(
              chrome.footerPaddingLeft,
              chrome.footerPaddingTop,
              chrome.footerPaddingRight,
              chrome.footerPaddingBottom,
            ),
          ) +
          (chrome.showFooterLine ? 1 : 0);
    }
    return measureLegacyPageIndicatorHeight(context);
  }
}
