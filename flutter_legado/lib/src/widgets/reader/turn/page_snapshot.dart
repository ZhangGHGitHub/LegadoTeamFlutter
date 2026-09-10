import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

Future<ui.Image?> captureBoundary(GlobalKey key, {double? pixelRatio}) async {
  final boundary =
      key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null || !boundary.hasSize) return null;
  final dpr = (pixelRatio ?? 1.0).clamp(1.0, 2.5);
  try {
    return await boundary.toImage(pixelRatio: dpr);
  } catch (_) {
    return null;
  }
}
