// 批9b-3：漫画已读图片保留数触发器（契约 §2.46 retainComicImages）
//
// 语义钉住：
// - 打开/翻章后读取 imageRetainNum（默认 0）与 preDownloadNum（默认 10），
//   以 (bookUrl, 当前章索引) 调用 FFI；
// - imageRetainNum = 0 → 不调用（不清理，对齐原版 AppConfig 默认值）；
// - 同书同索引只触发一次；换章后再次触发；reset 后可重新触发；
// - 快速连翻只执行最后一次排队任务（窗口覆盖当前章，避免逐章扫目录）；
// - FFI/偏好异常静默（不抛给阅读流程）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_image_retention.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

/// 记录 retainComicImages 调用参数；可模拟抛错。
class _RecordingApi extends MockBookApi {
  final List<(String, int, int, int)> calls = [];
  bool shouldThrow = false;

  @override
  Future<int> retainComicImages({
    required String bookUrl,
    required int durIndex,
    required int retain,
    required int preDownload,
  }) async {
    calls.add((bookUrl, durIndex, retain, preDownload));
    if (shouldThrow) throw StateError('模拟清理失败');
    return 0;
  }
}

void main() {
  late _RecordingApi api;
  late MangaImageRetention retention;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _RecordingApi();
    retention = MangaImageRetention(
      api: api,
      settings: SettingsService(),
    );
  });

  test('翻章成功：按 imageRetainNum/preDownloadNum 传参调用', () async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.imageRetainNum: 3,
      PrefKeys.preDownloadNum: 5,
    });
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 7,
    );
    expect(api.calls, [('https://a.com/book/1', 7, 3, 5)],
        reason: '窗口参数 dur=7 / retain=3 / preDownload=5 须原样传给 Rust');
  });

  test('preDownloadNum 未设置时回落默认 10', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 2});
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 4,
    );
    expect(api.calls, [('https://a.com/book/1', 4, 2, 10)]);
  });

  test('imageRetainNum=0（默认）不调用清理', () async {
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 0,
    );
    expect(api.calls, isEmpty, reason: '0=不清理，不得触发 FFI');
  });

  test('同书同章去重：重复调用只触发一次', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 3});
    final first = retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 2,
    );
    final second = retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 2,
    );
    await Future.wait([first, second]);
    expect(api.calls, hasLength(1));
  });

  test('换章触发新窗口；reset 后同章可再次触发', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 3});
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 2,
    );
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 3,
    );
    expect(api.calls.map((c) => c.$2), [2, 3]);

    retention.reset();
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 3,
    );
    expect(api.calls.map((c) => c.$2), [2, 3, 3],
        reason: 'reset（换书/换源）后同索引须重新评估窗口');
  });

  test('快速连翻只执行最后一次排队任务', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 3});
    final futures = [
      retention.onChapterOpened(
          bookUrl: 'https://a.com/book/1', chapterIndex: 1),
      retention.onChapterOpened(
          bookUrl: 'https://a.com/book/1', chapterIndex: 2),
      retention.onChapterOpened(
          bookUrl: 'https://a.com/book/1', chapterIndex: 3),
    ];
    await Future.wait(futures);
    expect(api.calls.map((c) => c.$2), [3],
        reason: '中间章任务应被最后一次取代（窗口覆盖当前章）');
  });

  test('清理失败静默：异常不向阅读流程传播', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 3});
    api.shouldThrow = true;
    await expectLater(
      retention.onChapterOpened(
        bookUrl: 'https://a.com/book/1',
        chapterIndex: 1,
      ),
      completes,
      reason: 'FFI 失败必须静默降级（缓存是加速器不是数据源）',
    );
    // 失败后仍可对下一章继续尝试
    api.shouldThrow = false;
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/1',
      chapterIndex: 2,
    );
    expect(api.calls.map((c) => c.$2), [1, 2]);
  });

  test('备份/恢复：imageRetainNum 随 appPrefs 往返（不受阅读配置忽略）', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 0});
    final all = await RestoreIgnorePrefs.collectForBackup(const {});
    expect(all[PrefKeys.imageRetainNum], 0,
        reason: '默认 0 也必须原样导出（不能因值为 0 被丢掉）');
    final ignored = await RestoreIgnorePrefs.collectForBackup(
      const {'readConfig': true},
    );
    expect(
      ignored.containsKey(PrefKeys.imageRetainNum),
      isTrue,
      reason: '参考版 BackupConfig.readPrefKeys 未收录该键 → 任何忽略组合下均往返',
    );
  });

  test('换书 reset 后旧书排队任务被作废', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 3});
    final oldTask = retention.onChapterOpened(
      bookUrl: 'https://a.com/book/old',
      chapterIndex: 1,
    );
    retention.reset();
    await retention.onChapterOpened(
      bookUrl: 'https://a.com/book/new',
      chapterIndex: 1,
    );
    await oldTask;
    expect(
      api.calls.map((c) => c.$1),
      ['https://a.com/book/new'],
      reason: 'reset 应作废旧书排队任务（只清理新书）',
    );
  });
}
