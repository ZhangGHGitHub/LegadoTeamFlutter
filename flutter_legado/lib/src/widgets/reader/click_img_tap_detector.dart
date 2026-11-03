// 正文图片点击五档手势分发 — 全栈工程师 + UI
//
// 把 utils/click_img_way.dart 的纯决策落到手势层：
// - passThrough：不挂手势，点击穿透给页面（原版 handled=false）
// - consume/preview/runAction：挂 GestureDetector 消费点击
// - "4" 双击档：首击消费（onTap 空实现），双击窗口内第二击执行决策
//
// 说明：本仓库文本阅读器尚无行内图片渲染（见实现登记），本组件当前唯一
// 消费点是 image-dominant 图片页；后续补行内渲染时可直接复用。

import 'package:flutter/material.dart';

import '../../utils/click_img_way.dart';

/// 图片点击手势分发器
class ClickImgTapDetector extends StatelessWidget {
  /// clickImgWay 原始值（内部按 [clampClickImgWay] 钳制）
  final String clickImgWay;

  /// 是否在线文本书（原版 `Book.isOnLineTxt` 语义，仅 "2" 档使用）
  final bool onlineText;

  /// 图片 URL 及其复合参数（click/js/headers）
  final ClickImgUrlOptions options;

  /// 打开图片预览（对齐原版 PhotoDialog）
  final VoidCallback onPreview;

  final Widget child;

  const ClickImgTapDetector({
    super.key,
    required this.clickImgWay,
    required this.onlineText,
    required this.options,
    required this.onPreview,
    required this.child,
  });

  ClickImgTapEffect _resolve({required bool doubleTap}) => resolveClickImgTap(
        way: clickImgWay,
        onlineText: onlineText,
        hasClick: options.hasClick,
        hasJs: options.hasJs,
        doubleTap: doubleTap,
      );

  void _apply(ClickImgTapEffect effect) {
    switch (effect) {
      case ClickImgTapEffect.preview:
      case ClickImgTapEffect.runAction:
        // 当前构建无 action 执行能力（kClickImgActionSupported=false），
        // 纯决策已把 action 回退为 preview；此处兜底同口径
        onPreview();
      case ClickImgTapEffect.consume:
      case ClickImgTapEffect.passThrough:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final single = _resolve(doubleTap: false);
    // 关闭/非在线文本无 action 等场景不消费：让父级页面点击生效
    if (single == ClickImgTapEffect.passThrough) return child;

    if (clampClickImgWay(clickImgWay) == '4') {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 首击立即消费且不动作（对齐原版 doubleClick=false 时 handled=true）
        onTap: () {},
        onDoubleTap: () => _apply(_resolve(doubleTap: true)),
        child: child,
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _apply(single),
      child: child,
    );
  }
}
