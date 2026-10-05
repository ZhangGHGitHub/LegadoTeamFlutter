// [V-B4] 视频直链播放进度（config/caches 通道 + 20 天 TTL）
//
// 原版依据（app/src/main/java/io/legado/app/model/VideoPlay.kt）：
// - :56  VIDEO_POS_NAME = "video_pos_"（仅直链模式；键 = URL）
// - :57  VIDEO_POS_SAVE_TIME = 60 * 60 * 24 * 20（20 天）
// - :143 启动读 CacheManager.getLong(VIDEO_POS_NAME + mUrl) → seekOnStart
// - :500 写 CacheManager.put(VIDEO_POS_NAME + videoUrl, durPos, 20 天)
// - CacheManager.get/Repository.get：过期项读取即删除（deadline > now 才算有效）
//
// 我方存储通道：既有 BookApi.getConfig/setConfig（caches 表，物理键带
// `config:` 前缀、TTL=0），逻辑键对齐 video_pos_ 前缀；20 天 TTL 由值内
// savedAt 时间戳在 Dart 侧执行（无新增 FFI）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/utils/video_progress.dart';

void main() {
  group('video_pos_ 键与 20 天 TTL 编解码', () {
    test('逻辑键前缀对齐原版 video_pos_', () {
      expect(
        videoPosKey('https://cdn.example/x.m3u8'),
        'video_pos_https://cdn.example/x.m3u8',
      );
    });

    test('保存 20 天内可恢复（原版 deadline 未到）', () {
      final saved = DateTime(2026, 1, 1, 12);
      final raw = encodeVideoPos(123456, savedAt: saved);
      expect(
        decodeVideoPos(
          raw,
          now: saved.add(const Duration(days: 19, hours: 23)),
        ),
        123456,
      );
    });

    test('到期即过期（deadline 边界视为过期，对齐 deadline > now 判定）', () {
      final saved = DateTime(2026, 1, 1, 12);
      final raw = encodeVideoPos(123456, savedAt: saved);
      expect(decodeVideoPos(raw, now: saved.add(kVideoPosTtl)), isNull);
      expect(
        decodeVideoPos(
          raw,
          now: saved.add(kVideoPosTtl).subtract(const Duration(milliseconds: 1)),
        ),
        123456,
      );
    });

    test('无记录 / 损坏 / 非正数 → null（不猜测）', () {
      final now = DateTime(2026, 10, 3);
      expect(decodeVideoPos(null, now: now), isNull);
      expect(decodeVideoPos('', now: now), isNull);
      expect(decodeVideoPos('not-json', now: now), isNull);
      expect(decodeVideoPos('{"pos":5}', now: now), isNull);
      expect(decodeVideoPos('{"savedAt":1}', now: now), isNull);
      expect(
        decodeVideoPos(
          encodeVideoPos(0, savedAt: DateTime(2026, 1, 1)),
          now: now,
        ),
        isNull,
      );
    });
  });

  group('VideoPosStore（复用 MockBookApi 同一 config/caches 通道）', () {
    test('写入 → 新会话（新 store，内存态丢失）读回同值', () async {
      final api = MockBookApi();
      final t0 = DateTime(2026, 10, 3, 10);
      await VideoPosStore(api, clock: () => t0)
          .write('https://cdn.example/v.mp4', 654321);

      // 模拟重启：新建 store 实例（无任何内存态），只共享底层存储
      final restored = await VideoPosStore(
        api,
        clock: () => t0.add(const Duration(days: 19)),
      ).read('https://cdn.example/v.mp4');
      expect(restored, 654321);
    });

    test('过期读取返回 0 且清理该键（对齐 CacheRepository.get 过期即删）', () async {
      final api = MockBookApi();
      final t0 = DateTime(2026, 10, 3, 10);
      await VideoPosStore(api, clock: () => t0)
          .write('https://cdn.example/v.mp4', 999);

      final store = VideoPosStore(
        api,
        clock: () => t0.add(const Duration(days: 20, seconds: 1)),
      );
      expect(await store.read('https://cdn.example/v.mp4'), 0);
      expect(
        await api.getConfig(videoPosKey('https://cdn.example/v.mp4')),
        isNull,
        reason: '过期项应在读取时被清理，避免残留',
      );
    });

    test('pos <= 0 不写（避免用 0 覆盖有效进度）；clear 清键', () async {
      final api = MockBookApi();
      final store = VideoPosStore(api, clock: () => DateTime(2026, 10, 3));
      await store.write('https://cdn.example/v.mp4', 0);
      expect(
        await api.getConfig(videoPosKey('https://cdn.example/v.mp4')),
        isNull,
      );

      await store.write('https://cdn.example/v.mp4', 42);
      expect(await store.read('https://cdn.example/v.mp4'), 42);
      await store.clear('https://cdn.example/v.mp4');
      expect(await store.read('https://cdn.example/v.mp4'), 0);
    });
  });
}
