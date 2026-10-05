// [V-B4] 视频直链播放进度（仅直链模式；书籍模式走 saveRead/durChapterPos）
//
// 原版依据（app/src/main/java/io/legado/app/model/VideoPlay.kt）：
// - :56  VIDEO_POS_NAME = "video_pos_"（键 = 播放链接原文）
// - :57  VIDEO_POS_SAVE_TIME = 60 * 60 * 24 * 20（20 天）
// - :143 启动播放前读 CacheManager.getLong(VIDEO_POS_NAME + mUrl) → seekOnStart
// - :500 写入 CacheManager.put(VIDEO_POS_NAME + videoUrl, durPos, 20 天)
// - CacheManager.get（help/CacheManager.kt:100-112）：deadline > now 才算有效，
//   过期读返回 null；CacheRepository 移植版读取过期项时即删除。
//
// 存储通道：复用既有 BookApi.getConfig/setConfig（caches 表，物理键带
// `config:` 前缀、TTL 固定为 0），逻辑键对齐 video_pos_ 前缀；20 天 TTL 由
// 值内 savedAt 时间戳在 Dart 侧判定（无新增 FFI、无契约变更）。— V-B4
import 'dart:convert';

import '../services/book_api.dart';

/// 直链进度逻辑键前缀（对齐原版 VideoPlay.kt:56）
const String kVideoPosKeyPrefix = 'video_pos_';

/// 直链进度有效期（对齐原版 VideoPlay.kt:57 的 60*60*24*20 秒）
const Duration kVideoPosTtl = Duration(days: 20);

/// 直链进度逻辑键：`video_pos_<播放链接原文>`
String videoPosKey(String url) => '$kVideoPosKeyPrefix$url';

/// 编码直链进度（毫秒 + 保存时刻），供 20 天 TTL 判定
String encodeVideoPos(int posMs, {required DateTime savedAt}) => jsonEncode({
      'pos': posMs,
      'savedAt': savedAt.millisecondsSinceEpoch,
    });

/// 解码并校验直链进度；无记录 / 损坏 / 非正数 / 已过期一律返回 null。
///
/// 过期边界对齐原版 `deadline > now`：保存时刻 + 20 天整即视为过期。
int? decodeVideoPos(String? raw, {required DateTime now}) {
  if (raw == null || raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final pos = decoded['pos'];
  final savedAt = decoded['savedAt'];
  if (pos is! int || savedAt is! int || pos <= 0) return null;
  final saved = DateTime.fromMillisecondsSinceEpoch(savedAt);
  if (!now.isBefore(saved.add(kVideoPosTtl))) return null;
  return pos;
}

/// 直链播放进度存取（持久化层为既有 config/caches 通道）
class VideoPosStore {
  VideoPosStore(this._api, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final BookApi _api;
  final DateTime Function() _clock;

  /// 读进度（毫秒）；无记录/过期/读失败一律 0（降级不抛）。
  /// 过期/损坏项读取即清理（对齐原版 CacheRepository.get 的过期即删）。
  Future<int> read(String url) async {
    if (url.isEmpty) return 0;
    final key = videoPosKey(url);
    String? raw;
    try {
      raw = await _api.getConfig(key);
    } catch (_) {
      return 0;
    }
    final pos = decodeVideoPos(raw, now: _clock());
    if (pos == null && raw != null && raw.isNotEmpty) {
      try {
        await _api.deleteConfig(key);
      } catch (_) {}
    }
    return pos ?? 0;
  }

  /// 写进度（毫秒）；url 为空或 pos <= 0 时跳过（避免用 0 覆盖有效进度）
  Future<void> write(String url, int posMs) async {
    if (url.isEmpty || posMs <= 0) return;
    await _api.setConfig(
      videoPosKey(url),
      encodeVideoPos(posMs, savedAt: _clock()),
    );
  }

  /// 清除进度（对齐 CacheManager.delete）
  Future<void> clear(String url) async {
    if (url.isEmpty) return;
    await _api.deleteConfig(videoPosKey(url));
  }
}
