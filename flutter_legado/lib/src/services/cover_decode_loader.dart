import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/comic_image_utils.dart';
import 'book_api.dart';

/// 封面解密排队票：列表项 dispose 时 [cancel] 释放槽位（未进入 FFI 的请求直接丢弃）
///
/// — Reasonix + UI
class CoverDecodeTicket {
  CoverDecodeTicket._(this._onCancel);
  final void Function() _onCancel;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel();
  }
}

/// 封面解密加载器 — LRU 缓存 + 并发上限 + 请求去重 + 取消不可见项
///
/// 对齐原版 Glide 列表行为：搜索/书架若对每条结果无节流并发 FFI
/// `fetchImageWithDecode`，漫画源封面极易卡顿。本类保证：
/// - 无 coverDecodeJs（且非复合 URL）→ 调用方走轻量 CachedNetworkImage
/// - 有解密需求 → 全局最多 [maxConcurrent] 路 FFI；结果 LRU 缓存
/// - 相同 URL 在 FFI 进行中合并；dispose 仅取消排队，不污染 in-flight 结果
///
/// — Reasonix + UI
class CoverDecodeLoader {
  CoverDecodeLoader._();

  /// 列表封面解密并发上限
  static const int maxConcurrent = 3;

  /// 解密结果内存缓存条目上限
  static const int maxCacheEntries = 64;

  static final LinkedHashMap<String, Uint8List> _bytesCache =
      LinkedHashMap<String, Uint8List>();

  /// origin → patched sourceJson；空串表示无需解密
  static final Map<String, String> _patchedSourceByOrigin = {};

  /// cacheKey → 已进入 FFI 的 Future（仅 fetch 开始后注册，避免取消污染）
  static final Map<String, Future<Uint8List?>> _inflight = {};

  static int _active = 0;
  static final Queue<_QueuedFetch> _waitQueue = Queue<_QueuedFetch>();

  @visibleForTesting
  static int get debugActiveCount => _active;

  @visibleForTesting
  static int get debugQueueLength => _waitQueue.length;

  @visibleForTesting
  static int get debugCacheSize => _bytesCache.length;

  static String cacheKey(String originOrEmpty, String url) =>
      '$originOrEmpty\u0000$url';

  /// 将 coverDecodeJs 映射为 ruleContent.imageDecode（复用既有 FFI）
  ///
  /// 返回：patched JSON；空串=无需解密；null=JSON 解析失败
  static String? patchSourceJsonForCoverDecode(String sourceJson) {
    Map<String, dynamic>? map;
    try {
      map = jsonDecode(sourceJson) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
    if (map == null) return null;
    final coverDecode = (map['coverDecodeJs'] as String?)?.trim();
    if (coverDecode == null || coverDecode.isEmpty) {
      return '';
    }
    final patched = Map<String, dynamic>.from(map);
    final ruleContent = Map<String, dynamic>.from(
      (patched['ruleContent'] as Map?)?.cast<String, dynamic>() ?? {},
    );
    ruleContent['imageDecode'] = coverDecode;
    patched['ruleContent'] = ruleContent;
    return jsonEncode(patched);
  }

  /// 解析书源并缓存 origin → patched JSON
  static Future<String?> resolvePatchedSourceJson({
    required BookApi api,
    String? sourceJson,
    String? sourceOrigin,
  }) async {
    if (sourceJson != null && sourceJson.isNotEmpty) {
      final patched = patchSourceJsonForCoverDecode(sourceJson);
      if (patched != null &&
          sourceOrigin != null &&
          sourceOrigin.isNotEmpty) {
        _patchedSourceByOrigin[sourceOrigin] = patched;
      }
      return patched;
    }
    final origin = sourceOrigin?.trim() ?? '';
    if (origin.isEmpty) return '';
    final cached = _patchedSourceByOrigin[origin];
    if (cached != null) return cached;
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == origin) {
          final patched =
              patchSourceJsonForCoverDecode(jsonEncode(s.toJson())) ?? '';
          _patchedSourceByOrigin[origin] = patched;
          return patched;
        }
      }
      _patchedSourceByOrigin[origin] = '';
      return '';
    } catch (e) {
      debugPrint('封面书源解析失败: $e');
      return null;
    }
  }

  /// 是否需要走 FFI（coverDecodeJs 或复合 URL）
  static bool needsFfiDecode({
    required String coverUrl,
    required String? patchedSourceJson,
  }) {
    if (isCompositeImageUrl(coverUrl)) return true;
    return patchedSourceJson != null && patchedSourceJson.isNotEmpty;
  }

  static Uint8List? getCached(String originOrEmpty, String url) {
    final key = cacheKey(originOrEmpty, url);
    final hit = _bytesCache.remove(key);
    if (hit == null) return null;
    _bytesCache[key] = hit;
    return hit;
  }

  static void putCached(String originOrEmpty, String url, Uint8List bytes) {
    if (!looksLikeImageBytes(bytes)) return;
    final key = cacheKey(originOrEmpty, url);
    _bytesCache.remove(key);
    _bytesCache[key] = bytes;
    while (_bytesCache.length > maxCacheEntries) {
      _bytesCache.remove(_bytesCache.keys.first);
    }
  }

  /// 加载解密封面字节。
  ///
  /// [onTicket]：排队时下发票证，dispose 时 cancel；进入 FFI / 命中缓存时传 null。
  /// 取消后返回 null；失败返回 null（不抛到 UI）。
  static Future<Uint8List?> load({
    required BookApi api,
    required String coverUrl,
    required String patchedSourceJson,
    String originOrEmpty = '',
    required bool Function() isCancelled,
    void Function(CoverDecodeTicket? ticket)? onTicket,
  }) async {
    final notify = onTicket ?? (_) {};
    final hit = getCached(originOrEmpty, coverUrl);
    if (hit != null) {
      notify(null);
      return hit;
    }

    final key = cacheKey(originOrEmpty, coverUrl);
    final existing = _inflight[key];
    if (existing != null) {
      notify(null);
      final bytes = await existing;
      if (isCancelled()) return null;
      return bytes;
    }

    if (isCancelled()) {
      notify(null);
      return null;
    }

    return _enqueue(
      api: api,
      coverUrl: coverUrl,
      patchedSourceJson: patchedSourceJson,
      originOrEmpty: originOrEmpty,
      isCancelled: isCancelled,
      onTicket: notify,
    );
  }

  static Future<Uint8List?> _enqueue({
    required BookApi api,
    required String coverUrl,
    required String patchedSourceJson,
    required String originOrEmpty,
    required bool Function() isCancelled,
    required void Function(CoverDecodeTicket? ticket) onTicket,
  }) {
    // 再次检查：排队期间可能已有同 URL 进入 FFI
    final key = cacheKey(originOrEmpty, coverUrl);
    final existing = _inflight[key];
    if (existing != null) {
      onTicket(null);
      return existing.then((bytes) {
        if (isCancelled()) return null;
        return bytes;
      });
    }

    if (_tryClaimSlot()) {
      onTicket(null);
      return _runFetch(
        api: api,
        coverUrl: coverUrl,
        patchedSourceJson: patchedSourceJson,
        originOrEmpty: originOrEmpty,
        isCancelled: isCancelled,
        slotClaimed: true,
      );
    }

    final queued = _QueuedFetch();
    _waitQueue.add(queued);
    final ticket = CoverDecodeTicket._(() {
      queued.cancelled = true;
      if (!queued.gate.isCompleted) queued.gate.complete(false);
      _waitQueue.remove(queued);
      _pumpQueue();
    });
    onTicket(ticket);

    return queued.gate.future.then((proceed) {
      onTicket(null);
      if (!proceed || isCancelled() || ticket.isCancelled) {
        return null;
      }
      // 出队后再查缓存 / in-flight
      final cached = getCached(originOrEmpty, coverUrl);
      if (cached != null) {
        _pumpQueue();
        return cached;
      }
      final flying = _inflight[key];
      if (flying != null) {
        return flying.then((bytes) {
          if (isCancelled()) return null;
          return bytes;
        });
      }
      // gate 完成表示已占到槽（_pumpQueue 同步 claim）
      if (!_tryClaimSlot()) {
        // 极端竞争：重新排队
        return _enqueue(
          api: api,
          coverUrl: coverUrl,
          patchedSourceJson: patchedSourceJson,
          originOrEmpty: originOrEmpty,
          isCancelled: isCancelled,
          onTicket: onTicket,
        );
      }
      return _runFetch(
        api: api,
        coverUrl: coverUrl,
        patchedSourceJson: patchedSourceJson,
        originOrEmpty: originOrEmpty,
        isCancelled: isCancelled,
        slotClaimed: true,
      );
    });
  }

  /// 同步占用并发槽，避免 async 间隙超限
  static bool _tryClaimSlot() {
    if (_active >= maxConcurrent) return false;
    _active++;
    return true;
  }

  static Future<Uint8List?> _runFetch({
    required BookApi api,
    required String coverUrl,
    required String patchedSourceJson,
    required String originOrEmpty,
    required bool Function() isCancelled,
    required bool slotClaimed,
  }) async {
    void releaseSlot() {
      if (slotClaimed) {
        _active--;
        _pumpQueue();
      }
    }

    if (isCancelled()) {
      releaseSlot();
      return null;
    }

    final key = cacheKey(originOrEmpty, coverUrl);
    final existing = _inflight[key];
    if (existing != null) {
      releaseSlot();
      final bytes = await existing;
      if (isCancelled()) return null;
      return bytes;
    }

    final completer = Completer<Uint8List?>();
    _inflight[key] = completer.future;
    try {
      final sourceForFfi =
          patchedSourceJson.isEmpty ? '{}' : patchedSourceJson;
      final resp = await api.fetchImageWithDecode(coverUrl, sourceForFfi);
      final decoded = jsonDecode(resp) as Map<String, dynamic>;
      final b64 = decoded['base64'] as String?;
      Uint8List? bytes;
      if (b64 != null && b64.isNotEmpty) {
        final raw = base64Decode(b64);
        if (looksLikeImageBytes(raw)) {
          putCached(originOrEmpty, coverUrl, raw);
          bytes = raw;
        }
      }
      if (!completer.isCompleted) completer.complete(bytes);
      if (isCancelled()) return null;
      return bytes;
    } catch (e) {
      debugPrint('封面 coverDecodeJs 失败: $e');
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      _inflight.remove(key);
      releaseSlot();
    }
  }

  static void _pumpQueue() {
    while (_active < maxConcurrent && _waitQueue.isNotEmpty) {
      final next = _waitQueue.removeFirst();
      if (next.cancelled) continue;
      if (!next.gate.isCompleted) next.gate.complete(true);
      return;
    }
  }

  @visibleForTesting
  static void clearForTest() {
    _bytesCache.clear();
    _patchedSourceByOrigin.clear();
    _inflight.clear();
    _active = 0;
    while (_waitQueue.isNotEmpty) {
      final w = _waitQueue.removeFirst();
      if (!w.gate.isCompleted) w.gate.complete(false);
    }
  }

  @visibleForTesting
  static void seedPatchedSource(String origin, String patchedJson) {
    _patchedSourceByOrigin[origin] = patchedJson;
  }
}

class _QueuedFetch {
  final Completer<bool> gate = Completer<bool>();
  bool cancelled = false;
}
