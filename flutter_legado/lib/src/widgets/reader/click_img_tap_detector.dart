// 正文图片点击五档手势分发 — 全栈工程师 + UI
//
// 把 utils/click_img_way.dart 的纯决策落到手势层：
// - passThrough：不挂手势，点击穿透给页面（原版 handled=false）
// - consume/preview/runAction：挂 GestureDetector 消费点击
// - "4" 双击档：首击消费（onTap 空实现），双击窗口内第二击执行决策
//
// 消费点：image-dominant 图片页与正文行内图片（批16）分别经
// ReaderImageDominantBody / ReaderImageRenderConfig 注入 onPreview 与
// onRunAction；[onRunAction] 接 `BookApi.evalImageAction`（契约 §2.21）。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../utils/click_img_way.dart';

/// 图片动作执行回调（`click`/`js` 源码 + 图片地址）
typedef ClickImgActionRunner =
    Future<void> Function(String action, String imgSrc);

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

  /// 执行书源 `click`/`js` 动作（契约 §2.21）
  ///
  /// 为空时按旧口径回退 [onPreview]（调用方未接线 action 的兜底）。
  final ClickImgActionRunner? onRunAction;

  final Widget child;

  const ClickImgTapDetector({
    super.key,
    required this.clickImgWay,
    required this.onlineText,
    required this.options,
    required this.onPreview,
    this.onRunAction,
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
        onPreview();
      case ClickImgTapEffect.runAction:
        // click 优先、js 兜底（"0"/"2" 档 click 非空才 runAction；
        // "2" 档仅 js 时走 js；"4" 档只有 click 会进入本分支）
        final action = options.click ?? options.js;
        final runner = onRunAction;
        if (action == null || runner == null) {
          onPreview();
        } else {
          // P3-6：result 绑定传完整 src（保留复合参数），对齐参考版
          unawaited(runner(action, options.actionSrc));
        }
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
