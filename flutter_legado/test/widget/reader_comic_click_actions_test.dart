// [P4-3 E5] 漫画屏九区点击 + 长按菜单（分享/复制/存图）
//
// 取证（参考版，legado-with-MD3）：
// - ui/book/manga/MangaReaderInteraction.kt L15-24 mangaClickRegionIndex
//   （3x3 网格 row*3+column；coerceAtLeast(1) 防零除），L26-32
//   mangaClickActionAt（getOrNull ?: 0），L34-41 nextMangaClickAction
//   （-1→0→1→2→3→4→-1 循环）；
// - ui/book/manga/MangaReaderContract.kt L132 longPressEnabled 默认 true，
//   L167 clickActions 默认 [-1, -1, 1, 2, 0, 1, 2, 1, 1]；
// - ui/book/manga/MangaReaderScreen.kt L705-736（条漫点击 1/2=滚一屏）、
//   L737-796（条漫长按 → LongPressPage）、L1082-1095（单页 onLongClick）、
//   L1945-1969 动作语义（-1 无 / 0 菜单 / 1 下一页 / 2 上一页 /
//   3 下一章 / 4 上一章）；
// - ui/book/manga/MangaReaderSheets.kt L179-252 页面操作底栏
//   （单页：保存图片/分享/复制/设置封面；宽页 spread 变体不在范围）；
// - 参考版 ReadMangaActivity.kt L149-154：ShareImage → share(临时文件,
//   "image/jpeg")；CopyImage → ClipboardManager.setPrimaryClip(
//   ClipData.newUri(...))（URI 复制）；
// - 原版 ReadMangaActivity.kt L242-276：长按存图（用户先选目录，
//   文件写入所选目录）+ L559/L750 menu_manga_long_click_save_image 开关。
//
// 本测试验证：
// 1. 九区映射 / 边界收敛 / 零尺寸视口 / 动作解析 / 短列表回退 /
//    动作循环 / 默认值（纯函数，对齐参考版单元测试期望值）；
// 2. 页面图片字节解析：内存命中（不触碰 API）/ 磁盘命中 / FFI 回退 /
//    全空 → null；
// 3. 单页 L2R(1)：右上点击 → 下一页、左中点击 → 上一页（页脚 + 进度）；
// 4. 条漫：右上点击 → 下滚一屏（恰好一个视口高、无切章副作用）；
//    左上点击（-1）无任何副作用；
// 5. 中心点击（action 0）→ 控制栏显隐切换；
// 6. 长按图片项 → 底栏菜单（保存图片/分享图片/复制链接）；点「复制链接」
//    → 剪贴板写入图片链接（参考版 CopyImage 的文本降级，见实现说明）。
//
// [P4-3 M4 批2] 行为开关组 + 背景色（原版语义取证：
// - AppConfig.kt L747-748 volumeKeyPage 默认 **true** / L749-750
//   reverseVolumeKeyPage 默认 false；L880-881 disableMangaScale 默认
//   **true**；L886-887 mangaLongClickSaveImage 默认 **true**；
//   L892-893 disableMangaPageAnim 默认 false；L906-907 disableClickScroll
//   默认 false；L940-941 hideMangaTitle 默认 false；
// - PreferKey.kt L134/L136/L219/L220/L221 键名即值（对齐 MangaConfigKeys）；
// - 参考版 MangaSettings disableMangaCrossFade 默认 false（淡入开启）；
//   mangaBgColor 新增键（默认 0xFF000000 黑 = 原版硬编码黑零变化）；
// - 音量键翻页：平台无按键拦截通道 → 仅持久化登记，行为待平台支持
//   （禁止改 Android 壳工程）；hideMangaTitle 映射 0 图卷章分隔页 +
//   导航区标题隐藏（我方无独立章节标题页，不硬造）。
//
// [P4-3 W2-fix P1-2] 条漫点击「下一页」距章尾不足一视口时：先滚完剩余
// 距离到章尾（部分消费），真正到章边界（consumed < 1）才切下一章
//（对齐参考版 performWebtoonTap L705-732）。
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_click_actions.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_page_image_resolver.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/widgets/manga/manga_config_sheet.dart';

// [P4-3 M4 批2] 面板接线用例需断言面板类型（MangaConfigSheet）
import 'package:flutter_legado/src/services/mock_book_api.dart';

// [D2 修复] 存图 MediaStore 通道与平台分派（通道 mock + 分派覆写）
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/services/platform_channel.dart';

// [D1 修复] 存图回归测试桩注入（path_provider 平台接口为传递依赖，
// 测试直引以覆写 instance 保持 hermetic，不改 pubspec）
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 1x1 透明 PNG（RGBA，68 字节，CRC 校验通过的合法编码）
///
/// 注意：reader_comic_scroll_mode_test 等早期文件共享的 1x1 PNG 常量
/// IDAT 块 CRC 损坏，引擎 codec 会拒解（Image errorBuilder 回退占位）；
/// 条漫滚动用例依赖图片解码后的真实项高，故此处使用合法字节。
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8'
    'AAAAASUVORK5CYII=';

/// 含 imageDecode 规则的漫画书源（对齐 favcomic 形态）
BookSource _buildComicSource() {
  return BookSource(
    bookSourceUrl: 'https://manga.example.com',
    bookSourceName: '测试漫画源',
    bookSourceGroup: '漫画',
    bookSourceType: 2,
    enabled: true,
    ruleContent: ContentRule(
      content: '.x',
      imageDecode: 'decode(result);',
    ),
    customOrder: 0,
    lastUpdateTime: 0,
    respondTime: 0,
    weight: 0,
  );
}

/// [P4-3 E5] 测试 Mock：可注入滚动模式 / 磁盘缓存 / 记录进度与解码调用
///
/// [W2-fix] 新增 [chapterCount] 注入（条漫章尾部分消费切章用例需多章）；
/// [P4-3 M4 批2] 新增 [isVolume] 注入（0 图卷章分隔页用例）+
/// [setConfigCalls] 记录（面板持久化接线断言）
class _ClickActionsMockApi extends MockBookApi {
  _ClickActionsMockApi({
    required this.source,
    required this.progressCalls,
    Map<String, String>? configs,
    this.durChapterPos = 0,
    this.imageCount = 3,
    this.chapterCount = 1,
    this.diskBytes,
    this.isVolume = false,
  }) : _configs = configs ?? {};

  final BookSource source;
  /// 进度写入记录 [[chapterIndex, chapterPos], ...]
  final List<List<int>> progressCalls;
  final Map<String, String> _configs;
  final int durChapterPos;
  final int imageCount;
  final int chapterCount;
  /// 磁盘缓存注入（null = 未命中）
  final List<int>? diskBytes;
  /// [P4-3 M4 批2] 章节 isVolume 标记（0 图卷章分隔页用例）
  final bool isVolume;
  final List<String> decodeCalls = [];
  int imageCacheCalls = 0;

  /// [P4-3 M4 批2] setConfig 调用记录（面板持久化接线断言）
  final List<({String key, String value})> setConfigCalls = [];

  @override
  Future<List<BookSource>> getBookSources() async => [source];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: 'https://manga.example.com/comic/1/',
        name: '测试漫画',
        author: '作者',
        origin: source.bookSourceUrl,
        originName: source.bookSourceName,
        canUpdate: true,
        totalChapterNum: chapterCount,
        durChapterPos: durChapterPos,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async =>
      List<BookChapter>.generate(
        chapterCount,
        (i) => BookChapter(
          index: i,
          url: 'https://manga.example.com/comic/1/ch${i + 1}.html',
          title: '第${i + 1}章',
          isVolume: isVolume,
        ),
      );

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return List.generate(
      imageCount,
      (i) => '<p><img src="https://cdn.example.com/img/$i.jpg"></p>',
    ).join();
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    decodeCalls.add(url);
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    _configs[key] = value;
    // [P4-3 M4 批2] 记录持久化调用（面板行为开关/背景色接线断言）
    setConfigCalls.add((key: key, value: value));
  }

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    progressCalls.add([chapterIndex, chapterPos]);
  }

  @override
  Future<List<int>?> getImageCache(String bookUrl, String url) async {
    imageCacheCalls++;
    return diskBytes;
  }
}

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://comic/1')),
  );
}

_ClickActionsMockApi _buildApi({
  Map<String, String>? configs,
  int durChapterPos = 0,
  int imageCount = 3,
  int chapterCount = 1,
  List<int>? diskBytes,
  bool isVolume = false,
  required List<List<int>> progressCalls,
}) {
  return _ClickActionsMockApi(
    source: _buildComicSource(),
    progressCalls: progressCalls,
    configs: configs,
    durChapterPos: durChapterPos,
    imageCount: imageCount,
    chapterCount: chapterCount,
    diskBytes: diskBytes,
    isVolume: isVolume,
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _ClickActionsMockApi api,
  ProviderContainer container,
) async {
  await tester.pumpWidget(_buildApp(container));
  // 等待异步加载（getBook → getChapters → fetchChapterContent → 解码渲染）
  await tester.pumpAndSettle();
  // 条漫/长按用例依赖图片解码后的真实项高（见 settleImageDecode）
  await _settleImageDecode(tester);
}

/// 等待引擎完成 PNG 解码（真实事件循环，供条漫内容高度生效）
///
/// 条漫项的 [Image.memory] 解码走引擎平台线程，其完成回调是真实异步——
/// [WidgetController.pumpAndSettle] 只推进假时间，等不到它；未解码时
/// 图片项高度为 0（intrinsic size 未知），可滚动范围为 0，「下滚一屏」
/// 会被误判为章节末尾（触发无操作切章）。[runAsync] 让真实事件循环
/// 转一轮，解码回调到达后 [pump] 一帧让布局按解码尺寸重排。
Future<void> _settleImageDecode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

/// 等待滚动范围稳定并返回稳定值（[W2-fix]）
///
/// 图片项「占位（屏高 0.6）→ FFI 解码后真实高度」的切换发生在真实事件
/// 循环（每 200ms 一轮 [runAsync] + 一帧布局），收敛前 [ScrollPosition]
/// 的 maxScrollExtent 会漂移，条漫「距章尾定位」用例须先等其稳定。
Future<double> _settleExtentStable(WidgetTester tester) async {
  var prev = -1.0;
  for (var i = 0; i < 10; i++) {
    await _settleImageDecode(tester);
    final cur = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .maxScrollExtent;
    if (cur > 0 && cur == prev) return cur;
    prev = cur;
  }
  return prev;
}

/// [P4-3 M4 批2] 条漫滚到真实底部（强制构建章尾导航区 sliver）
///
/// 本 SDK 的 [ScrollPosition.jumpTo] 不收敛越界值（jumpTo(100000) 后
/// pixels 仍为 100000、视口完全脱离内容 → 尾部 sliver 不构建）；
/// 须迭代跳「当前范围内 maxScrollExtent」：每跳一次视口落当前底部、
/// 强制构建尾部 sliver，extent 由「已构建项平均高估算」收敛到真值
///（3×800+导航区−600），图片解码稳定后再跳一次锁定新底部。
Future<void> _jumpToWebtoonBottom(WidgetTester tester) async {
  final pos =
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  for (var i = 0; i < 5; i++) {
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pump();
  }
  await _settleExtentStable(tester);
  pos.jumpTo(pos.maxScrollExtent);
  await tester.pump();
}

/// mock 系统剪贴板通道（setData 记录写入文本；getData 返回空）。
/// 先例：replace_rule_edit_test.dart mockClipboard（SDK 3.44 方法名
/// Clipboard.*；兼容旧版 SystemClipboard.*）。
List<String> mockClipboard(WidgetTester tester) {
  final written = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
        case 'SystemClipboard.setData':
          final args = call.arguments as Map<Object?, Object?>;
          // 本 SDK 版本 setData 参数即 {'text': ...}（SDK clipboard.dart L36-39）
          final value = args['text'] ?? args['value'];
          if (value is Map) {
            written.add(value['text'] as String? ?? '');
          } else if (value is String) {
            written.add(value);
          }
          return null;
        case 'Clipboard.getData':
        case 'SystemClipboard.getData':
          return null;
        default:
          return null;
      }
    },
  );
  return written;
}

// =====================================================================
// [D1 修复] 保存图片回归测试桩
//
// D1 根因：file_picker 8.x 在 Android/iOS 的 saveFile 必传 bytes
// （FilePickerIO.saveFile：bytes == null → 抛 ArgumentError
// 「Bytes are required on Android & iOS when saving a file.」）。
// 旧 _savePageImage 漏传 bytes → 保存恒失败、取消兜底分支永不可达。
// 桩经 FilePicker.platform / PathProviderPlatform.instance 平台注入：
// ① 断言 saveFile 收到 bytes（D1 回归）；② 取消（返回 null）时
// 兜底写应用文档目录落盘。
// =====================================================================

/// [D1 修复] FilePicker 桩：记录 saveFile 实参，返回固定 [result]
/// （非 null = 用户选中路径；null = 用户取消保存对话框）
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);
  final String? result;
  Uint8List? capturedBytes;
  String? capturedFileName;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    capturedBytes = bytes;
    capturedFileName = fileName;
    return result;
  }
}

/// [D1 修复] path_provider 平台桩：文档目录固定返回 [docDir]
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docDir);
  final String docDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docDir;
}

/// 注入 FilePicker 平台桩并登记恢复（原实例为 registrant 初始化值；
/// 若宿主未初始化则恢复为 FilePickerIO，不影响后续用例）
void _useFakeFilePicker(_FakeFilePicker fake) {
  FilePicker? original;
  var initialized = false;
  try {
    original = FilePicker.platform;
    initialized = true;
  } catch (_) {
    // late 未初始化（测试宿主 registrant 无本平台分支）
  }
  FilePicker.platform = fake;
  addTearDown(() => FilePicker.platform = initialized ? original! : FilePickerIO());
}

void main() {
  group('[P4-3 E5] 九区点击区域（对齐 mangaClickRegionIndex）', () {
    test('九区映射：900x1800 视口每格中心点 → 0..8（参考测试同值）', () {
      const w = 900.0;
      const h = 1800.0;
      const cells = [
        (150.0, 300.0, 0),
        (450.0, 300.0, 1),
        (750.0, 300.0, 2),
        (150.0, 900.0, 3),
        (450.0, 900.0, 4),
        (750.0, 900.0, 5),
        (150.0, 1500.0, 6),
        (450.0, 1500.0, 7),
        (750.0, 1500.0, 8),
      ];
      for (final cell in cells) {
        expect(
          MangaClickActions.regionIndex(cell.$1, cell.$2, w, h),
          cell.$3,
          reason: '(${"${cell.$1},${cell.$2}"}) → 期望区 ${cell.$3}',
        );
      }
    });

    test('边界外触摸收敛到边缘区域（-20,-20 → 0；920,1820 → 8）', () {
      expect(MangaClickActions.regionIndex(-20, -20, 900, 1800), 0);
      expect(MangaClickActions.regionIndex(920, 1820, 900, 1800), 8);
    });

    test('零尺寸视口不抛异常（宽度/高度按 1 兜底，参考版 coerceAtLeast(1)）',
        () {
      // 1/(1/3)=3 → 收敛到 2；区域 = 2*3+2 = 8
      expect(MangaClickActions.regionIndex(1, 1, 0, 0), 8);
    });

    test('动作解析：点 → 区域 → 动作（参考测试示例列表）', () {
      const actions = [-1, 0, 3, 2, 0, 1, 4, 1, 2];
      // 900x1800：(750,300)→区2→3；(150,900)→区3→2；
      // (150,1500)→区6→4；(450,900)→区4→0
      expect(MangaClickActions.actionAt(actions, 750, 300, 900, 1800), 3);
      expect(MangaClickActions.actionAt(actions, 150, 900, 900, 1800), 2);
      expect(MangaClickActions.actionAt(actions, 150, 1500, 900, 1800), 4);
      expect(MangaClickActions.actionAt(actions, 450, 900, 900, 1800), 0);
    });

    test('列表不足 9 项时越界区回退 0（对齐 getOrNull ?: 0）', () {
      expect(MangaClickActions.actionAt(const [-1, -1], 450, 900, 900, 1800), 0);
    });

    test('动作循环 -1→0→1→2→3→4→-1（对齐 nextMangaClickAction）', () {
      expect(MangaClickActions.cycleNext(-1), 0);
      expect(MangaClickActions.cycleNext(0), 1);
      expect(MangaClickActions.cycleNext(1), 2);
      expect(MangaClickActions.cycleNext(2), 3);
      expect(MangaClickActions.cycleNext(3), 4);
      expect(MangaClickActions.cycleNext(4), -1);
    });

    test('默认 clickActions（对齐 Contract L167）', () {
      expect(MangaClickActions.defaultActions, const [-1, -1, 1, 2, 0, 1, 2, 1, 1]);
    });
  });

  group('[P4-3 E5] 页面图片字节解析（内存 → 磁盘 → FFI 回退）', () {
    final progressCalls = <List<int>>[];
    _ClickActionsMockApi api({List<int>? diskBytes}) {
      return _ClickActionsMockApi(
        source: _buildComicSource(),
        progressCalls: progressCalls,
        diskBytes: diskBytes,
      );
    }

    final pngBytes = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02
    ]);

    test('内存缓存命中：直接返回，不触碰磁盘/FFI API', () async {
      final a = api();
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
        memoryCached: pngBytes,
      );
      expect(result, isNotNull);
      expect(result!.bytes, equals(pngBytes));
      expect(result.suffix, '.png');
      expect(a.imageCacheCalls, 0, reason: '内存命中不应再查磁盘');
    });

    test('内存未命中 → 磁盘缓存命中（jpg 魔数 → 后缀 .jpg）', () async {
      final disk = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x01];
      final a = api(diskBytes: disk);
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
      );
      expect(result, isNotNull);
      expect(result!.bytes, equals(disk));
      expect(result.suffix, '.jpg');
      expect(a.imageCacheCalls, 1);
    });

    test('双未命中 + 提供 sourceJson → FFI 解码回退（base64 → PNG）',
        () async {
      final a = api();
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
        sourceJson: '"{}"',
      );
      expect(result, isNotNull, reason: 'FFI 回退应解出 PNG 字节');
      expect(result!.suffix, '.png');
      expect(a.decodeCalls, ['https://cdn.example.com/img/0.jpg']);
    });

    test('缓存全空且无 sourceJson → null（不旁路直连）', () async {
      final a = api();
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
      );
      expect(result, isNull);
      expect(a.decodeCalls, isEmpty, reason: '无 sourceJson 不得走 FFI 解码');
    });
  });

  group('[P4-3 E5] 九区点击 + 长按菜单（整页行为）', () {
    // 测试视口 800x600：列界 0/267/533/800，行界 0/200/400/600。
    // 默认 clickActions[-1,-1,1,2,0,1,2,1,1]：
    //   左上(133,100) 区0 → -1 无；右上(667,100) 区2 → 1 下一页；
    //   左中(133,300) 区3 → 2 上一页；中心(400,300) 区4 → 0 菜单。

    testWidgets('单页 L2R：右上点击 → 下一页；左中点击 → 上一页',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(
        configs: const {'mangaScrollMode': '1'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 右上区（区2）action 1 → 下一页
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);
      expect(progressCalls, contains(equals([0, 1])));

      // 左中区（区3）action 2 → 上一页
      await tester.tapAt(const Offset(133, 300));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数1/3'), findsOneWidget);
    });

    testWidgets('条漫：右上点击 → 下滚一屏（恰好一个视口高，无副作用）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.byType(ListView), findsWidgets);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 顶部初始位置
      final pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos.pixels, closeTo(0, 0.01));

      // 右上区（区2）action 1 → 条漫下滚一屏（参考版 MangaReaderScreen
      // L705-736「滚一屏」= 一个视口高；条漫无页单位，页脚页数在顶部
      // 因懒加载估算 maxScrollExtent 不变，属预期，不在此断言）
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      final pos2 =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos2.pixels, closeTo(600, 1),
          reason: '一屏 = 视口高 600（animateTo 300ms 终止于目标）');
      // 无切章副作用：单章未跳章，未触发章末切章
      expect(find.textContaining('章节1/1'), findsOneWidget);
      // 页级估算未变（顶部一屏后仍为第 0 页）→ 不产生进度写入
      expect(progressCalls, isEmpty);
    });

    // [P4-3 W2-fix P1-2] 对齐参考版 performWebtoonTap（L705-732）：
    // animateScrollBy 部分消费（目标被章边界钳制），只有真正已在章边界
    //（consumed < 1）才切章；旧实现距章尾不足一视口时直接跳章、
    // 跳过剩余内容。
    testWidgets('条漫：距章尾不足一视口点「下一页」先滚完剩余再切章（P1-2）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls, chapterCount: 2);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // [W2-fix] 先滚到底部强制构建尾部项（末张图 + 底部章节导航），
      // 再等滚动范围稳定：ListView.builder 对未构建尾部项按「已构建项
      // 平均高度」估算 maxScrollExtent（底部导航实际 ~148px 会被估算成
      // 800px，extent 虚高 652px），未滚到底前读到的稳定值不可信；
      // 滚到底后全部项已构建，extent 收敛到实际值（3×800+148−600=1948）
      final pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      pos.jumpTo(100000); // 越界 → jumpTo 收敛到当前 maxScrollExtent
      await tester.pump();
      final extent = await _settleExtentStable(tester);
      expect(extent, greaterThan(600),
          reason: '三页内容高应超过一个视口（600px）');

      // 移到距章尾不足一视口（600px）处：剩余 300px
      pos.jumpTo(extent - 300);
      await tester.pump();

      // 右上区（区2，action 1）= 下一页：先滚完剩余 300px 到章尾
      //（目标被章边界钳制、部分消费），不切章
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      final pos2 =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos2.pixels, closeTo(pos2.maxScrollExtent, 1),
          reason: '应滚完剩余距离停在章尾（对齐 animateScrollBy 部分消费；'
              'extent 用 settle 后重读值，防解码期漂移）');
      expect(find.textContaining('章节1/2'), findsOneWidget,
          reason: '未真正到章边界（consumed ≥ 1）不应切章'
              '（旧实现 target > maxScrollExtent 即跳章、跳过章尾内容）');

      // 再点：已停在章边界（无可滚距离）→ 切下一章
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '章边界处点「下一页」= 切下一章（consumed < 1 语义）');
    });

    testWidgets('左上点击（区0 = 无动作）：无控制栏、无滚动、无进度',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await tester.tapAt(const Offset(133, 100));
      await tester.pumpAndSettle();

      // 控制栏未出现（顶栏书名文本不在树中）
      expect(find.text('测试漫画'), findsNothing);
      // 仍停在第 1 页，未产生进度写入
      expect(find.textContaining('页数1/3'), findsOneWidget);
      expect(progressCalls, isEmpty);
    });

    testWidgets('中心点击（action 0）→ 控制栏显隐切换', (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.text('测试漫画'), findsNothing);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsOneWidget,
          reason: '中心点击 = 菜单动作，顶栏（书名）应出现');

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsNothing,
          reason: '再次中心点击应收起控制栏');
    });

    testWidgets('长按图片项 → 底栏菜单（保存/分享/复制链接）', (tester) async {
      final progressCalls = <List<int>>[];
      // [P4-3 M4 批2] 长按存图默认开启（长按直接存图，原版默认 true）→
      // 本用例显式注入 false，保持测「长按弹菜单」的旧语义
      final api = _buildApi(
        progressCalls: progressCalls,
        configs: const {'mangaLongClickSaveImage': 'false'},
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 长按第 1 张图（顶部区域）
      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      expect(find.text('保存图片'), findsOneWidget);
      expect(find.text('分享图片'), findsOneWidget);
      // [W2-fix P2-4] 复制的是图片链接文本（URI 复制降级），文案对齐行为
      expect(find.text('复制链接'), findsOneWidget);

      // 点「复制链接」→ 关闭菜单 + 剪贴板写入图片链接
      final written = mockClipboard(tester);
      await tester.tap(find.text('复制链接'));
      await tester.pumpAndSettle();
      expect(find.text('复制链接'), findsNothing, reason: '菜单应已关闭');
      expect(
        written,
        contains('https://cdn.example.com/img/0.jpg'),
        reason: '复制链接 = 图片链接文本（参考版 CopyImage 的文本降级）',
      );
      expect(find.text('已复制图片链接'), findsOneWidget);
    });
  });

  // =====================================================================
  // [P4-3 M4 批2] 行为开关组 + 背景色
  // 原版语义取证（app/src/main/java/io/legado/app/）：
  // - AppConfig.kt L747-748 volumeKeyPage 默认 **true** / L749-750
  //   reverseVolumeKeyPage 默认 false；L880-881 disableMangaScale 默认
  //   **true**；L886-887 mangaLongClickSaveImage 默认 **true**；
  //   L892-893 disableMangaPageAnim 默认 false；L906-907 disableClickScroll
  //   默认 false；L940-941 hideMangaTitle 默认 false；
  // - PreferKey.kt L134/L136/L219/L220/L221 键名即值（MangaConfigKeys 对齐）；
  // - 参考版 MangaSettings：disableMangaCrossFade 默认 false（淡入开启）、
  //   background 0xFF000000；MangaSettingsPanel L334-561 开关顺序；
  // - 原版 ReadMangaActivity L239-250 长按存图分支（开关开=直接存图、
  //   关=页操作菜单）；
  // - 音量键翻页：平台无按键拦截通道 → 仅持久化登记（键落库断言），
  //   行为待平台支持，禁止改 Android 壳工程；
  // - hideMangaTitle：我方无独立章节标题页 → 映射 0 图卷章分隔页标题 +
  //   章节导航区标题隐藏（不硬造）。
  group('[P4-3 M4 批2] 行为开关组 + 背景色', () {
    testWidgets('disableClickScroll=true：翻页动作 1/2 失效，菜单 0 保留',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(
        configs: const {'mangaScrollMode': '1', 'disableClickScroll': 'true'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 右上区（区2 = 动作1 下一页）→ 被禁用
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: '禁用点击翻页 → 翻页动作 1/2 失效（对齐参考版 L714/L1953）');
      expect(progressCalls, isEmpty, reason: '未翻页 → 无进度写入');

      // 中心区（区4 = 动作0 菜单）保留 → 控制栏出现
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsOneWidget,
          reason: '菜单动作 0 保留');
    });

    testWidgets('disableMangaScale 默认 true：缩放层不渲染', (tester) async {
      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);
      expect(find.byType(InteractiveViewer), findsNothing,
          reason: '原版默认 disableMangaScale=true → 无 InteractiveViewer');
    });

    testWidgets('disableMangaScale=false：缩放层渲染', (tester) async {
      final api = _buildApi(
        configs: const {'disableMangaScale': 'false'},
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('disableMangaPageAnim=true：单页翻页即时跳转（jump）',
        (tester) async {
      final api = _buildApi(
        configs: const {'mangaScrollMode': '1', 'disableMangaPageAnim': 'true'},
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.textContaining('页数1/3'), findsOneWidget);
      // 右上区（动作1）→ jumpToPage 即时切换：单帧（100ms）后页已切换
      await tester.tapAt(const Offset(667, 100));
      await tester.pump(); // 100ms
      expect(find.textContaining('页数2/3'), findsOneWidget,
          reason: 'jump 即时切换（对照组 300ms 动画中点 150ms 前不切换）');
    });

    testWidgets('disableMangaPageAnim 默认 false：单页翻页走 300ms 动画',
        (tester) async {
      final api = _buildApi(
        configs: const {'mangaScrollMode': '1'},
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.textContaining('页数1/3'), findsOneWidget);
      // 右上区（动作1）→ animateToPage 300ms 进行中：
      // 单帧（100ms）尚未过切换中点，页脚仍在第 1 页
      await tester.tapAt(const Offset(667, 100));
      await tester.pump(); // 100ms
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: '动画进行中（100ms < 300ms 中点），页面未切换');

      // 动画完成后切换
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);
    });

    testWidgets('hideMangaTitle=true：条漫导航区标题隐藏（不硬造章节标题页）',
        (tester) async {
      final api = _buildApi(
        configs: const {'hideMangaTitle': 'true'},
        chapterCount: 2,
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _jumpToWebtoonBottom(tester);

      expect(find.text('第1章'), findsNothing,
          reason: 'hideMangaTitle → 导航区标题隐藏');
      expect(find.text('下一章'), findsOneWidget,
          reason: '导航区已构建、按钮保留（防误判为整区缺失）');
    });

    testWidgets('hideMangaTitle 默认 false：条漫导航区标题显示',
        (tester) async {
      final api = _buildApi(
        chapterCount: 2,
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _jumpToWebtoonBottom(tester);

      expect(find.text('第1章'), findsOneWidget);
      expect(find.text('下一章'), findsOneWidget);
    });

    testWidgets('hideMangaTitle=true：0 图卷章分隔页标题隐藏（按钮保留）',
        (tester) async {
      final api = _buildApi(
        configs: const {'hideMangaTitle': 'true'},
        imageCount: 0,
        chapterCount: 2,
        isVolume: true,
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.text('第1章'), findsNothing,
          reason: 'hideMangaTitle → 0 图卷章分隔页标题隐藏');
      expect(find.text('下一章'), findsOneWidget,
          reason: '分隔页导航按钮保留');
    });

    testWidgets('0 图卷章默认：分隔页标题显示（对照）', (tester) async {
      final api = _buildApi(
        imageCount: 0,
        chapterCount: 2,
        isVolume: true,
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.text('第1章'), findsOneWidget);
      expect(find.text('下一章'), findsOneWidget);
    });

    testWidgets('mangaLongClickSaveImage 默认 true：长按直接存图（不弹菜单）',
        (tester) async {
      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 长按第 1 张图 → 直接走存图分支（对齐原版 ReadMangaActivity L239-250）
      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('保存图片'), findsNothing,
          reason: '长按存图开启 → 不弹页操作菜单');
      // widget 测试无 FilePicker 平台通道 → 存图 catch 兜底提示
      // （证明走了存图分支而非菜单分支）
      expect(
        find.textContaining('保存图片失败'),
        findsOneWidget,
        reason: '存图分支触发（FilePicker MissingPluginException 被 catch）',
      );
    });

    testWidgets('mangaLongClickSaveImage=false：长按弹页操作菜单',
        (tester) async {
      final api = _buildApi(
        configs: const {'mangaLongClickSaveImage': 'false'},
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      expect(find.text('保存图片'), findsOneWidget,
          reason: '长按存图关闭 → 长按弹现有页操作菜单');
      expect(find.text('分享图片'), findsOneWidget);
    });

    testWidgets('disableMangaCrossFade 默认 false：图片加载淡入包裹渲染',
        (tester) async {
      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.byKey(const ValueKey('mangaImageFade')), findsWidgets,
          reason: '默认淡入开启（参考版 disableMangaCrossFade=false）');
    });

    testWidgets('disableMangaCrossFade=true：淡入包裹不渲染', (tester) async {
      final api = _buildApi(
        configs: const {'disableMangaCrossFade': 'true'},
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.byKey(const ValueKey('mangaImageFade')), findsNothing);
    });

    testWidgets('mangaBgColor 默认黑：Scaffold 背景 0xFF000000',
        (tester) async {
      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        const Color(0xFF000000),
        reason: '默认背景黑（对齐原版硬编码黑，零变化）',
      );
    });

    testWidgets('mangaBgColor 持久化白（十进制 ARGB）：Scaffold 背景生效',
        (tester) async {
      // 0xFFFFFFFF = 4294967295（十进制 ARGB 持久化格式）
      final api = _buildApi(
        configs: const {'mangaBgColor': '4294967295'},
        progressCalls: <List<int>>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        const Color(0xFFFFFFFF),
      );
    });

    testWidgets('面板接线：行为开关 + 色板点选 → setConfig 持久化',
        (tester) async {
      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 中心点击 → 控制栏 → 齿轮打开设置面板
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
      await tester.pumpAndSettle();
      expect(find.byType(MangaConfigSheet), findsOneWidget,
          reason: '设置面板已打开');

      // 面板 ListView 为惰性 sliver（视口 ± cacheExtent 外不构建）→
      // 先滚「其他」卡入视野（面板 ListView = 树中最后一个）
      final panelList = find.byType(ListView).last;
      await tester.dragUntilVisible(
        find.text('禁用点击翻页'),
        panelList,
        const Offset(0, -300),
      );
      expect(find.text('其他'), findsOneWidget,
          reason: '「其他」区块渲染（滚入视野后构建）');
      // 禁用点击翻页（默认 false → true）
      await tester.tap(find.text('禁用点击翻页'));
      await tester.pump();
      // 音量键翻页（默认 true → false；仅持久化，行为待平台支持）
      await tester.tap(find.text('音量键翻页'));
      await tester.pump();
      // 背景色板：白色 swatch（0xFFFFFFFF = 4294967295）。
      // swatch 行位于「其他」卡最底行，dragUntilVisible 尾部
      // ensureVisible 默认最小滚动（swatch 可能仅一角入视口，tap 命中
      // 测试不命中 → 点选无效）→ 面板 Scrollable（树中最后一个；
      // 面板内容无图片，extent 不漂移，单次 jump 到底即整行入视口）
      final panelPos =
          tester.state<ScrollableState>(find.byType(Scrollable).last).position;
      panelPos.jumpTo(panelPos.maxScrollExtent);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mangaBgSwatch-4294967295')));
      await tester.pump();

      expect(
        api.setConfigCalls,
        contains((key: 'disableClickScroll', value: 'true')),
        reason: '禁用点击翻页持久化',
      );
      expect(
        api.setConfigCalls,
        contains((key: 'volumeKeyPage', value: 'false')),
        reason: '音量键翻页（关闭）持久化',
      );
      expect(
        api.setConfigCalls,
        contains((key: 'mangaBgColor', value: '4294967295')),
        reason: '背景色（十进制 ARGB）持久化',
      );
    });

  });

  // [P4-3 M4 批3] 滤镜入口（锚点跳到面板内色彩滤镜区）
  //
  // 原版取证：ReadMangaActivity L605-608 menu_manga_color_filter →
  // showDialogFragment(MangaColorFilterDialog())（独立对话框）；我方
  // 色彩滤镜已并入面板区块（M2）→ 入口改面板内锚点跳转
  // （ScrollController + GlobalKey + Scrollable.ensureVisible，
  // ensureVisible alignment 0.0 = 目标顶边对齐视口顶边，即时跳）。
  // 「点击区域设置」（九区编辑器，原版 ClickActionConfigDialog /
  // 参考版 ClickActionsSettingsContent L772-801）登记不做，
  // 面板不放假按钮。
  group('[P4-3 M4 批3] 滤镜入口锚点跳转', () {
    testWidgets('点「滤镜」入口 → 色彩滤镜区顶边对齐面板视口顶边',
        (tester) async {
      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 中心点击 → 控制栏 → 齿轮打开设置面板
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
      await tester.pumpAndSettle();
      expect(find.byType(MangaConfigSheet), findsOneWidget,
          reason: '设置面板已打开');

      // 初始：面板滚动位置 0，阅读模式区在视口内、色彩滤镜区在视口外
      final panelPos =
          tester.state<ScrollableState>(find.byType(Scrollable).last).position;
      expect(panelPos.pixels, 0, reason: '面板初始滚动位置在顶部');
      expect(find.text('阅读模式'), findsOneWidget);

      // 点「滤镜」入口（面板头部固定行，不随滚动）
      await tester.tap(find.text('滤镜'));
      await tester.pump();

      // 锚点跳转：色彩滤镜区顶边对齐面板视口顶边（alignment 0.0），
      // 滚动偏移 > 0。偏移量 16 = _section 区块标题上内边距
      // （fromLTRB(4,16,4,8)）——ensureVisible 对齐的是锚点容器
      // 顶边，标题 Text 顶边低 16px
      final listRect = tester.getRect(find.byType(ListView).last);
      final targetRect = tester.getRect(find.text('色彩滤镜'));
      expect(targetRect.top - listRect.top, closeTo(16, 1.0),
          reason: '色彩滤镜区顶边应对齐面板视口顶边（ensureVisible 0.0）');
      expect(find.text('色彩滤镜'), findsOneWidget,
          reason: '色彩滤镜区已滚入视口');
      expect(panelPos.pixels, greaterThan(0),
          reason: '锚点跳转改变了面板滚动偏移');
    });
  });

  // =====================================================================
  // [D1 修复] 保存图片 bytes 传入 + 取消兜底
  // 根因：file_picker 8.x saveFile 缺 bytes 必填（Android/iOS 抛
  // ArgumentError）；暴露自 M4 长按接线，影响波次2 起全部保存入口
  // （长按直接存图 + 页操作菜单「保存图片」共用 _savePageImage）。
  // 触发路径：默认 mangaLongClickSaveImage=true → 长按直接存图。
  // =====================================================================
  group('[D1 修复] 保存图片 bytes 传入与取消兜底', () {
    testWidgets('成功路径：saveFile 收到 bytes，选中路径落盘', (tester) async {
      // 真实 IO 事件在 fake-async 测试体里须经 runAsync 转动
      //（先例 _settleImageDecode 注释：真实事件循环只有 runAsync 可等）
      final tempDir = (
        await tester.runAsync(() => Directory.systemTemp.createTemp('d1_save_'))
      )!;
      addTearDown(() => tempDir.delete(recursive: true));
      final chosenPath = '${tempDir.path}/manga-chosen.png';
      final fake = _FakeFilePicker(chosenPath);
      _useFakeFilePicker(fake);

      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 长按第 1 张图 → 默认直接存图分支
      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('已保存:'), findsOneWidget,
          reason: 'saveFile 返回选中路径 → 成功分支（非失败提示）');
      expect(fake.capturedBytes, isNotNull,
          reason: 'D1 回归：saveFile 必须收到 bytes（旧代码漏传恒失败）');
      expect(
        fake.capturedBytes!.take(4).toList(),
        equals(const [0x89, 0x50, 0x4E, 0x47]),
        reason: '传入 bytes 为 PNG 字节（页面图片解析结果）',
      );
      expect(fake.capturedFileName, endsWith('.png'),
          reason: '文件扩展名按魔数推断');
      expect(File(chosenPath).existsSync(), isTrue, reason: '选中路径落盘');
      expect(
        File(chosenPath).readAsBytesSync(),
        equals(fake.capturedBytes),
        reason: '落盘内容 = saveFile 收到的 bytes',
      );
    });

    testWidgets('取消路径：saveFile 返回 null → 文档目录兜底落盘',
        (tester) async {
      // 真实 IO 事件在 fake-async 测试体里须经 runAsync 转动
      final tempDir = (
        await tester.runAsync(() => Directory.systemTemp.createTemp('d1_cancel_'))
      )!;
      addTearDown(() => tempDir.delete(recursive: true));

      // 文档目录覆写为 temp 目录（hermetic，不碰真实 Documents）
      final originalProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      addTearDown(() => PathProviderPlatform.instance = originalProvider);

      final fake = _FakeFilePicker(null); // 用户取消保存对话框
      _useFakeFilePicker(fake);

      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('已保存到文档目录'), findsOneWidget,
          reason: '取消（saveFile 返回 null）→ 文档目录兜底分支');
      expect(fake.capturedBytes, isNotNull,
          reason: '取消分支同样收到 bytes（bytes 仅平台实际存文件时消费）');
      final files = tempDir
          .listSync()
          .where((e) => e is File && e.path.endsWith('.png'))
          .toList();
      expect(files, hasLength(1), reason: '兜底目录应落盘 1 个文件');
      expect(
        (files.single as File).readAsBytesSync(),
        equals(fake.capturedBytes),
        reason: '兜底落盘内容 = 页面图片字节',
      );
    });
  });

  // =====================================================================
  // [D2 修复] 保存图片 MediaStore 通道与平台分派
  // 根因：MuMu DownloadStorageProvider 拒写（SecurityException: requires
  // MANAGE_DOCUMENTS）× file_picker 8.3.7 FilePickerDelegate 仅 catch
  // IOException → 未捕获异常抛主线程 FATAL（m4b_fatal_stack_d2.txt）。
  // Android 改走 legado/storage 通道（MediaStore 直写 Download/legado/，
  // 不弹 SAF 对话框）；通道失败 → 文档目录兜底；非 Android 保持
  // file_picker saveFile（D1 修复态）。
  // 分派可测性：Platform.isAndroid 在 Windows 测试宿主不可伪造，经
  // PlatformBridgeService.saveViaDownloadsOverride 强制分支。
  // =====================================================================
  group('[D2 修复] 保存图片 MediaStore 通道与平台分派', () {
    /// mock legado/storage 通道（teardown 自动恢复）
    void mockStorageChannel(
      WidgetTester tester,
      Future<Object?> Function(MethodCall call) handler,
    ) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlatformChannel.storage, handler);
      addTearDown(
        () => messenger.setMockMethodCallHandler(PlatformChannel.storage, null),
      );
    }

    testWidgets('Android 分支：通道成功 → Download/legado 提示，不走 file_picker',
        (tester) async {
      final channelCalls = <MethodCall>[];
      mockStorageChannel(tester, (call) async {
        channelCalls.add(call);
        return 'Download/legado/manga-d2.png';
      });
      PlatformBridgeService.instance.saveViaDownloadsOverride = true;
      addTearDown(() =>
          PlatformBridgeService.instance.saveViaDownloadsOverride = null);
      final fake = _FakeFilePicker('must-not-use-file-picker');
      _useFakeFilePicker(fake);

      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 长按第 1 张图 → 默认直接存图分支
      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('已保存: Download/legado/'), findsOneWidget,
          reason: 'Android 分支通道成功 → toast 相对路径');
      expect(channelCalls, hasLength(1),
          reason: 'Android 分支必须调用 MediaStore 通道');
      final args =
          channelCalls.single.arguments as Map<Object?, Object?>;
      expect(args['fileName'], endsWith('.png'),
          reason: '通道参数 fileName 保留扩展名（按魔数推断）');
      expect(
        (args['bytes'] as List<int>).take(4).toList(),
        equals(const [0x89, 0x50, 0x4E, 0x47]),
        reason: '通道参数 bytes 为页面图片 PNG 字节',
      );
      expect(fake.capturedBytes, isNull,
          reason: 'Android 分支不走 file_picker（D2 绕开 SAF）');
    });

    testWidgets('Android 分支：通道失败 → 文档目录兜底', (tester) async {
      // 真实 IO 事件在 fake-async 测试体里须经 runAsync 转动
      final tempDir =
          (await tester.runAsync(() => Directory.systemTemp.createTemp('d2_fail_')))!;
      addTearDown(() => tempDir.delete(recursive: true));
      final originalProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      addTearDown(() => PathProviderPlatform.instance = originalProvider);

      mockStorageChannel(tester, (call) async {
        // 模拟原生端 provider 拒写（result.error → PlatformException）
        throw PlatformException(
          code: 'SAVE_FAILED',
          message: 'provider rejected write',
        );
      });
      PlatformBridgeService.instance.saveViaDownloadsOverride = true;
      addTearDown(() =>
          PlatformBridgeService.instance.saveViaDownloadsOverride = null);
      final fake = _FakeFilePicker('must-not-use-file-picker');
      _useFakeFilePicker(fake);

      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('已保存到文档目录'), findsOneWidget,
          reason: '通道失败 → 文档目录兜底（现有逻辑）');
      expect(fake.capturedBytes, isNull,
          reason: 'Android 分支不走 file_picker');
      final files = tempDir
          .listSync()
          .where((e) => e is File && e.path.endsWith('.png'))
          .toList();
      expect(files, hasLength(1), reason: '兜底目录应落盘 1 个文件');
      expect(
        (files.single as File).readAsBytesSync().take(4).toList(),
        equals(const [0x89, 0x50, 0x4E, 0x47]),
        reason: '兜底落盘内容 = 页面图片字节',
      );
    });

    testWidgets('非 Android 分支：不调通道，走 file_picker saveFile',
        (tester) async {
      // 真实 IO 事件在 fake-async 测试体里须经 runAsync 转动
      final tempDir = (
        await tester.runAsync(() => Directory.systemTemp.createTemp('d2_other_'))
      )!;
      addTearDown(() => tempDir.delete(recursive: true));
      final chosenPath = '${tempDir.path}/manga-other.png';

      var channelCalls = 0;
      mockStorageChannel(tester, (call) async {
        channelCalls++;
        return 'Download/legado/should-not-happen.png';
      });
      PlatformBridgeService.instance.saveViaDownloadsOverride = false;
      addTearDown(() =>
          PlatformBridgeService.instance.saveViaDownloadsOverride = null);
      final fake = _FakeFilePicker(chosenPath);
      _useFakeFilePicker(fake);

      final api = _buildApi(progressCalls: <List<int>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('已保存:'), findsOneWidget,
          reason: '非 Android 走 file_picker saveFile 成功分支');
      expect(fake.capturedBytes, isNotNull,
          reason: 'file_picker saveFile 必须收到 bytes（D1 回归）');
      expect(File(chosenPath).existsSync(), isTrue, reason: '选中路径落盘');
      expect(channelCalls, 0, reason: '非 Android 不得调用 MediaStore 通道');
    });
  });
}
