// L10N 阶段 2 验收测试：主题 / 朗读 / WebDAV / 订阅源 / 书源编辑
//
// 覆盖：
// 1. 5 个界面（theme_config / read_aloud_settings / webdav_settings /
//    rss_source_manage / source_edit）抽取出的代表性 key 在 en 下无中文残留、
//    在 zh 下为中文。
// 2. 参数化文案在两种 locale 下插值正确（批39 审查教训回归：插值变量两侧
//    同名、不能丢；中文顿号 vs 英文逗号）。
// 3. 列表分隔符：`AppStrings.listSeparator` 在 zh 为「、」、en 为「, 」。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';

/// 各界面代表性 key（静态 getter）
const Map<String, List<String Function()>> _samples = {
  '主题设置': [
    _themeTopBarButtonStyle,
    _themeMultiPaneLayout,
    _themeEyeProtection,
    _themeContainerBackground,
    _themeRestoreDefault,
  ],
  '朗读设置': [
    _raDefaultInterface,
    _raPlayerBackground,
    _raCacheRetention,
    _raSpeakEngine,
    _raMultiSpeaker,
  ],
  'WebDAV 设置': [
    _webdavKeepCount,
    _webdavConfirmSync,
    _webdavServerConfig,
    _webdavKeepLatestOnly,
    _webdavBackupPassword,
  ],
  '订阅源管理': [
    _rssSearchHint,
    _rssImportLocal,
    _rssRemoveFromGroup,
    _rssLoginSuccess,
    _rssExportSources,
  ],
  '书源编辑': [
    _sourceBasicInfo,
    _sourceFieldBookSourceUrl,
    _sourceFieldChapterList,
    _sourceAutoComplete,
    _sourceReview,
  ],
};

String _themeTopBarButtonStyle() => AppStrings.topBarButtonStyle;
String _themeMultiPaneLayout() => AppStrings.multiPaneLayout;
String _themeEyeProtection() => AppStrings.eyeProtection;
String _themeContainerBackground() => AppStrings.containerBackground;
String _themeRestoreDefault() => AppStrings.restoreDefault;

String _raDefaultInterface() => AppStrings.raDefaultInterface;
String _raPlayerBackground() => AppStrings.raPlayerBackground;
String _raCacheRetention() => AppStrings.raCacheRetention;
String _raSpeakEngine() => AppStrings.raSpeakEngine;
String _raMultiSpeaker() => AppStrings.raMultiSpeaker;

String _webdavKeepCount() => AppStrings.webdavKeepCount;
String _webdavConfirmSync() => AppStrings.webdavConfirmSync;
String _webdavServerConfig() => AppStrings.webdavServerConfig;
String _webdavKeepLatestOnly() => AppStrings.webdavKeepLatestOnly;
String _webdavBackupPassword() => AppStrings.webdavBackupPassword;

String _rssSearchHint() => AppStrings.rssSearchHint;
String _rssImportLocal() => AppStrings.rssImportLocal;
String _rssRemoveFromGroup() => AppStrings.rssRemoveFromGroup;
String _rssLoginSuccess() => AppStrings.rssLoginSuccess;
String _rssExportSources() => AppStrings.rssExportSources;

String _sourceBasicInfo() => AppStrings.sourceBasicInfo;
String _sourceFieldBookSourceUrl() => AppStrings.sourceFieldBookSourceUrl;
String _sourceFieldChapterList() => AppStrings.sourceFieldChapterList;
String _sourceAutoComplete() => AppStrings.sourceAutoComplete;
String _sourceReview() => AppStrings.sourceReview;

/// 中文字符检测（CJK 统一表意文字基本区）
bool _hasCjk(String value) => RegExp(r'[\u4e00-\u9fff]').hasMatch(value);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppStrings.setLocale('zh'));

  group('L10N 阶段 2：5 个界面抽取的文案双语齐备', () {
    for (final entry in _samples.entries) {
      group(entry.key, () {
        for (final sample in entry.value) {
          test('英文 locale 下无中文残留（${sample()}）', () {
            AppStrings.setLocale('en');
            final value = sample();
            expect(value, isNotEmpty);
            expect(
              _hasCjk(value),
              isFalse,
              reason: '英文 locale 下仍出现中文：$value',
            );
          });

          test('中文 locale 下为中文（${sample()}）', () {
            AppStrings.setLocale('zh');
            final value = sample();
            expect(value, isNotEmpty);
            expect(_hasCjk(value), isTrue, reason: '中文 locale 下缺少中文：$value');
          });
        }
      });
    }
  });

  group('L10N 阶段 2：参数化文案双语插值（插值变量不丢）', () {
    test('主题：百分比 / 模糊半径 / 底色透明度 / 阴影大小', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.currentPercent(72), '当前 72%');
      expect(AppStrings.blurRadiusValue(18), '模糊半径 18dp');
      expect(AppStrings.blurAlphaValue(200), '底色透明度 200/255');
      expect(AppStrings.navBarShadowValue(4), '当前阴影大小（elevation）：4');
      expect(AppStrings.blurDetailValue(18, 200), '半径 18 dp · 底色 200/255');

      AppStrings.setLocale('en');
      expect(AppStrings.currentPercent(72), 'Current 72%');
      expect(AppStrings.blurRadiusValue(18), 'Blur radius 18dp');
      expect(AppStrings.blurAlphaValue(200), 'Base opacity 200/255');
      expect(AppStrings.navBarShadowValue(4), 'Current elevation: 4');
      expect(AppStrings.blurDetailValue(18, 200), 'Radius 18 dp · Base 200/255');
    });

    test('主题：主题应用 / 保存 / 导入导出失败原因', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.themeAppliedNamed('暗夜'), '已应用主题「暗夜」');
      expect(AppStrings.themeSavedNamed('暗夜'), '已保存主题「暗夜」');
      expect(
        AppStrings.exportThemePackageFailedWithReason('磁盘已满'),
        '导出主题包失败：磁盘已满',
      );

      AppStrings.setLocale('en');
      expect(AppStrings.themeAppliedNamed('Night'), 'Applied theme "Night"');
      expect(AppStrings.themeSavedNamed('Night'), 'Saved theme "Night"');
      expect(
        AppStrings.exportThemePackageFailedWithReason('disk full'),
        'Failed to export the theme package: disk full',
      );
    });

    test('朗读：缓存统计三行拼接不丢变量', () {
      AppStrings.setLocale('zh');
      expect(
        AppStrings.raCacheStats(12, '3.5 MB'),
        '系统 TTS 合成缓存：12 个文件，共 3.5 MB。\n'
        '缓存仅用于加速重复段落朗读，清理后可随时重新生成。',
      );
      expect(
        AppStrings.raCacheRetentionInRow('30 分钟'),
        '当前保留：30 分钟（在「缓存保留时间」行设置）',
      );
      expect(
        AppStrings.raCacheSummary(12, '3.5 MB', '30 分钟'),
        '12 个文件 · 3.5 MB · 保留 30 分钟',
      );
      expect(AppStrings.raCacheCleared(5), '已清理 5 个缓存文件');
      expect(
        AppStrings.raSplitSelected(3),
        '已选 3 个标点；连续标点归入同一单元',
      );

      AppStrings.setLocale('en');
      expect(
        AppStrings.raCacheStats(12, '3.5 MB'),
        'System TTS cache: 12 files, 3.5 MB in total.\n'
        'The cache only speeds up repeated paragraphs; '
        'it can be regenerated at any time after clearing.',
      );
      expect(
        AppStrings.raCacheRetentionInRow('30 min'),
        'Currently keeping: 30 min (set in the Cache retention row)',
      );
      expect(
        AppStrings.raCacheSummary(12, '3.5 MB', '30 min'),
        '12 files · 3.5 MB · keeping 30 min',
      );
      expect(AppStrings.raCacheCleared(5), 'Cleared 5 cache files');
      expect(
        AppStrings.raSplitSelected(3),
        '3 punctuation marks selected; consecutive punctuation stays in one unit',
      );
    });

    test('WebDAV：备份路径 + 远端文件名 + 失败原因三态', () {
      AppStrings.setLocale('zh');
      expect(
        AppStrings.backupUploadedLocalOnly('/tmp/b.json'),
        '备份成功：/tmp/b.json',
      );
      expect(
        AppStrings.backupUploadedWithRemote('/tmp/b.json', 'remote.json'),
        '备份成功：/tmp/b.json\n已上传 WebDAV：remote.json',
      );
      expect(
        AppStrings.backupUploadedWithError('/tmp/b.json', '401'),
        '备份成功：/tmp/b.json\nWebDAV 上传失败：401',
      );
      expect(
        AppStrings.webdavAutoBackupInterval(7, '本地 + WebDAV'),
        '每 7 天自动备份（本地 + WebDAV）',
      );
      expect(
        AppStrings.webdavRemoteRestoreConfirmDesc('bk.json'),
        '将下载远端备份「bk.json」并覆盖本地书架，包括已有书籍的阅读进度与书籍信息。确定继续吗？',
      );
      expect(AppStrings.webdavProbeFailedHttp(500), '连接失败（HTTP 500）');
      expect(AppStrings.checkedCount(3), '已勾选 3 项');
      expect(
        AppStrings.legacyImportSummary(10, 5, 2),
        '书架 10 · 书源 5 · 替换规则 2',
      );

      AppStrings.setLocale('en');
      expect(
        AppStrings.backupUploadedLocalOnly('/tmp/b.json'),
        'Backup successful: /tmp/b.json',
      );
      expect(
        AppStrings.backupUploadedWithRemote('/tmp/b.json', 'remote.json'),
        'Backup successful: /tmp/b.json\nUploaded to WebDAV: remote.json',
      );
      expect(
        AppStrings.backupUploadedWithError('/tmp/b.json', '401'),
        'Backup successful: /tmp/b.json\nWebDAV upload failed: 401',
      );
      expect(
        AppStrings.webdavAutoBackupInterval(7, 'Local + WebDAV'),
        'Auto backup every 7 days (Local + WebDAV)',
      );
      expect(
        AppStrings.webdavRemoteRestoreConfirmDesc('bk.json'),
        'This downloads the remote backup "bk.json" and overwrites the local '
        'bookshelf, including reading progress and book details of existing '
        'books. Continue?',
      );
      expect(AppStrings.webdavProbeFailedHttp(500), 'Connection failed (HTTP 500)');
      expect(AppStrings.checkedCount(3), '3 selected');
      expect(
        AppStrings.legacyImportSummary(10, 5, 2),
        'Books 10 · Sources 5 · Replace rules 2',
      );
    });

    test('订阅源：删除确认 / 分组增删 / 分享标题', () {
      AppStrings.setLocale('zh');
      expect(
        AppStrings.rssConfirmDeleteNamed('人民网'),
        '确定要删除订阅源「人民网」吗？',
      );
      expect(
        AppStrings.rssConfirmDeleteSelected(4),
        '确定要删除选中的 4 个订阅源吗？',
      );
      expect(
        AppStrings.rssGroupAdded('新闻'),
        '已为所选订阅源添加分组「新闻」',
      );
      expect(
        AppStrings.rssGroupRemoved('新闻'),
        '已从所选订阅源移除分组「新闻」',
      );
      expect(AppStrings.rssShareTitle(2), '订阅源分享（2 个）');
      expect(AppStrings.rssSelectAllCount(3, 10), '全选 3/10');

      AppStrings.setLocale('en');
      expect(
        AppStrings.rssConfirmDeleteNamed('People Daily'),
        'Delete the RSS source "People Daily"?',
      );
      expect(
        AppStrings.rssConfirmDeleteSelected(4),
        'Delete the 4 selected RSS sources?',
      );
      expect(
        AppStrings.rssGroupAdded('News'),
        'Added group "News" to the selected RSS sources',
      );
      expect(
        AppStrings.rssGroupRemoved('News'),
        'Removed group "News" from the selected RSS sources',
      );
      expect(AppStrings.rssShareTitle(2), 'Share RSS sources (2)');
      expect(AppStrings.rssSelectAllCount(3, 10), 'Select all 3/10');
    });

    test('书源编辑：必填提示 / 摘要无障碍标签', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.sourceFieldRequired('源名称'), '请输入源名称');
      expect(
        AppStrings.sourceSettingsSummary('文本 | 启用', false),
        '设置, 文本 | 启用, 展开',
      );
      expect(
        AppStrings.sourceSettingsSummary('文本 | 启用', true),
        '设置, 文本 | 启用, 收起',
      );

      AppStrings.setLocale('en');
      expect(AppStrings.sourceFieldRequired('Source Name'), 'Enter Source Name');
      expect(
        AppStrings.sourceSettingsSummary('Text | Enable', false),
        'Settings, Text | Enable, expand',
      );
      expect(
        AppStrings.sourceSettingsSummary('Text | Enable', true),
        'Settings, Text | Enable, collapse',
      );
    });
  });

  group('L10N 阶段 2：列表分隔符与既有约定一致', () {
    test('zh 用顿号、en 用逗号加空格', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.listSeparator, '、');
      AppStrings.setLocale('en');
      expect(AppStrings.listSeparator, ', ');
    });
  });
}
