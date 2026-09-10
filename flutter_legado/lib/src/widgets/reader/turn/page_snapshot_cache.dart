import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'page_snapshot.dart';

/// One set of page bitmaps for horizontal turn painting.
class PageSnapshotTriple {
  PageSnapshotTriple({this.prev, this.cur, this.next});

  ui.Image? prev;
  ui.Image? cur;
  ui.Image? next;

  void dispose() {
    prev?.dispose();
    cur?.dispose();
    next?.dispose();
    prev = null;
    cur = null;
    next = null;
  }
}

typedef SnapshotCapturer =
    Future<ui.Image?> Function(GlobalKey key, {double? pixelRatio});

/// Double-buffered prev/cur/next snapshots (Jingshiro setBitmap timing).
class PageSnapshotCache {
  PageSnapshotCache({SnapshotCapturer? capturer})
    : _capturer = capturer ?? captureBoundary;

  final SnapshotCapturer _capturer;
  PageSnapshotTriple? _display;
  bool _refreshing = false;

  PageSnapshotTriple? get display => _display;

  bool get hasCur => _display?.cur != null;

  /// Capture into a pending triple; swap only when required images succeed.
  /// On failure, keeps the previous [display] intact and returns false.
  Future<bool> refresh({
    required GlobalKey prevKey,
    required GlobalKey curKey,
    required GlobalKey nextKey,
    required double pixelRatio,
    required bool hasPrev,
    required bool hasNext,
  }) async {
    if (_refreshing) return false;
    _refreshing = true;
    try {
      final cur = await _capturer(curKey, pixelRatio: pixelRatio);
      if (cur == null) {
        return false;
      }

      ui.Image? prev;
      if (hasPrev) {
        prev = await _capturer(prevKey, pixelRatio: pixelRatio);
        if (prev == null) {
          cur.dispose();
          return false;
        }
      }

      ui.Image? next;
      if (hasNext) {
        next = await _capturer(nextKey, pixelRatio: pixelRatio);
        if (next == null) {
          cur.dispose();
          prev?.dispose();
          return false;
        }
      }

      final pending = PageSnapshotTriple(prev: prev, cur: cur, next: next);
      final old = _display;
      _display = pending;
      old?.dispose();
      return true;
    } finally {
      _refreshing = false;
    }
  }

  void invalidate() {
    _display?.dispose();
    _display = null;
  }
}
