// L10N 阶段 3 验收测试：书籍详情 / 发现 / 字典
//
// 覆盖：
// 1. 三个界面（book_info / explore / dict）抽取出的代表性 key 在 en 下无
//    中文残留、在 zh 下为中文，且 zh/en 不同形（同形项如 URL 提示单独排除）。
// 2. 参数化文案在两种 locale 下插值正确（批39/45 审查教训回归：插值变量
//    两侧同名、不能丢；中文顿号 vs 英文逗号）。
// 3. 列表分隔符：删除确认中的规则名连接使用 `AppStrings.listSeparator`
//    （zh「、」/ en「, 」），不在界面内硬编码。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';

/// 各界面代表性 key（静态 getter）
const Map<String, List<String Function()>> _samples = {
  '书籍详情': [
    _biReadAction,
    _biBookInfoEditTooltip,
    _biBookInfoUnavailable,
    _biDisableReadRecord,
    _biSetBookVariable,
    _biCopyBookUrl,
    _biCopyTocUrl,
    _biAllowUpdate,
    _biDeleteAlert,
    _biUploadToRemote,
    _biCreateUpdateTask,
    _biGroupSettings,
    _biSplitLongChapter,
    _biCacheDownloadQueue,
    _biMarkAsPrivate,
    _biSetPasswordFirst,
    _biPrivateBookTitle,
    _biVerifyToViewBookInfo,
    _biCallbackNotHandled,
    _biSplitAfterShelf,
    _biSetPasswordInPrivacy,
    _biMarkedPrivate,
    _biUnmarkedPrivate,
    _biSourceNotExist,
    _biUploadLocalOnly,
    _biWebdavExistsConfirm,
    _biUploading,
    _biUploadSavedFailed,
    _biUploadSuccess,
    _biWebdavNotConfiguredTitle,
    _biWebdavNotConfiguredDesc,
    _biBookVariableHint,
    _biAddToShelfFirst,
    _biBookVariableSaved,
    _biBookVariableSaveFailed,
    _biCreateTaskFailed,
    _biFinishedReading,
    _biDownloaded,
    _biInBookshelf,
    _biAddToShelfShort,
    _biViewChapters,
    _biBookSource,
    _biCharacters,
    _biRelatedBooks,
    _biRemoveFromShelfTitle,
    _biRemoveFromShelfFailedNoReason,
    _biLocalNoLogin,
    _biSourceForBookNotFound,
    _biLoginSuccess,
    _biTocEmpty,
    _biDownloadAndImport,
    _biInvalidArchive,
  ],
  '发现': [
    _exFilterSourcesHint,
    _exSwitchToSourceContent,
    _exEmpty,
    _exSelectCategory,
    _exCategoryHint,
    _exUninstalled,
    _exNoCategories,
  ],
  '字典': [
    _dictCannotOpenOnline,
    _dictLookupTitle,
    _dictRulesManageTitle,
    _dictRuleManagement,
    _dictSearchHint,
    _dictStartHint,
    _dictOnlineFallback,
    _dictLocalDictionary,
    _dictUseOnlineBelow,
    _dictOnlineDictionary,
    _dictNoRulesTapManage,
    _dictNoRulesTapAdd,
    _dictImportDefault,
    _dictAddRule,
    _dictAddDictionaryRule,
    _dictAddDictRuleEntry,
    _dictRuleName,
    _dictRuleQueryUrl,
    _dictWordPlaceholder,
    _dictDeleteRuleTitle,
    _dictExportRules,
    _dictEditDictRule,
    _dictImportLocal,
    _dictImportOnline,
    _dictImportQr,
    _dictImportPassphrase,
    _dictQrMissing,
    _dictInvalidHttpUrl,
    _dictNewRule,
    _dictRuleManagementTitle,
    _dictMoreOptions,
    _dictExitMultiSelect,
    _dictDeselectAll,
    _dictEnableSelected,
    _dictDisableSelected,
    _dictExportSelected,
    _dictDeleteSelected,
    _dictLoading,
    _dictNoRules,
    _dictNoRulesHint,
    _dictQueryUrlNotConfigured,
    _dictRuleNameRequired,
    _dictQueryUrlLabel,
    _dictShowRuleLabel,
    _dictShowRuleHint,
    _dictLocalImportHint,
  ],
};

String _biReadAction() => AppStrings.readAction;
String _biBookInfoEditTooltip() => AppStrings.bookInfoEditTooltip;
String _biBookInfoUnavailable() => AppStrings.bookInfoUnavailable;
String _biDisableReadRecord() => AppStrings.bookDisableReadRecord;
String _biSetBookVariable() => AppStrings.setBookVariable;
String _biCopyBookUrl() => AppStrings.copyBookUrl;
String _biCopyTocUrl() => AppStrings.copyTocUrl;
String _biAllowUpdate() => AppStrings.allowUpdate;
String _biDeleteAlert() => AppStrings.deleteAlert;
String _biUploadToRemote() => AppStrings.uploadToRemote;
String _biCreateUpdateTask() => AppStrings.createBookUpdateTask;
String _biGroupSettings() => AppStrings.groupSettings;
String _biSplitLongChapter() => AppStrings.splitLongChapter;
String _biCacheDownloadQueue() => AppStrings.cacheDownloadQueue;
String _biMarkAsPrivate() => AppStrings.markAsPrivate;
String _biSetPasswordFirst() => AppStrings.setPasswordFirst;
String _biPrivateBookTitle() => AppStrings.privateBookTitle;
String _biVerifyToViewBookInfo() => AppStrings.verifyToViewBookInfo;
String _biCallbackNotHandled() => AppStrings.callbackNotHandled;
String _biSplitAfterShelf() => AppStrings.splitLongChapterTakesEffectAfterShelf;
String _biSetPasswordInPrivacy() => AppStrings.setPasswordInPrivacyFirst;
String _biMarkedPrivate() => AppStrings.markedPrivate;
String _biUnmarkedPrivate() => AppStrings.unmarkedPrivate;
String _biSourceNotExist() => AppStrings.sourceNotExist;
String _biUploadLocalOnly() => AppStrings.uploadToRemoteLocalOnly;
String _biWebdavExistsConfirm() => AppStrings.webdavUrlExistsConfirm;
String _biUploading() => AppStrings.uploadingToRemote;
String _biUploadSavedFailed() => AppStrings.uploadSavedRecordFailed;
String _biUploadSuccess() => AppStrings.uploadToRemoteSuccess;
String _biWebdavNotConfiguredTitle() => AppStrings.webdavNotConfiguredTitle;
String _biWebdavNotConfiguredDesc() => AppStrings.webdavNotConfiguredDesc;
String _biBookVariableHint() => AppStrings.bookVariableHint;
String _biAddToShelfFirst() => AppStrings.addToShelfFirst;
String _biBookVariableSaved() => AppStrings.bookVariableSaved;
String _biBookVariableSaveFailed() => AppStrings.bookVariableSaveFailed;
String _biCreateTaskFailed() => AppStrings.createTaskFailed;
String _biFinishedReading() => AppStrings.finishedReading;
String _biDownloaded() => AppStrings.downloadedLabel;
String _biInBookshelf() => AppStrings.inBookshelfLabel;
String _biAddToShelfShort() => AppStrings.addToShelfShort;
String _biViewChapters() => AppStrings.viewChapters;
String _biBookSource() => AppStrings.bookSourceLabel;
String _biCharacters() => AppStrings.charactersLabel;
String _biRelatedBooks() => AppStrings.relatedBooksLabel;
String _biRemoveFromShelfTitle() => AppStrings.removeFromShelfTitle;
String _biRemoveFromShelfFailedNoReason() =>
    AppStrings.removeFromShelfFailedNoReason;
String _biLocalNoLogin() => AppStrings.localBookNoSourceLogin;
String _biSourceForBookNotFound() => AppStrings.sourceForBookNotFound;
String _biLoginSuccess() => AppStrings.loginSuccess;
String _biTocEmpty() => AppStrings.tocEmpty;
String _biDownloadAndImport() => AppStrings.downloadAndImportFile;
String _biInvalidArchive() => AppStrings.invalidArchiveFormat;

String _exFilterSourcesHint() => AppStrings.exploreFilterSourcesHint;
String _exSwitchToSourceContent() => AppStrings.switchToSourceContent;
String _exEmpty() => AppStrings.exploreEmpty;
String _exSelectCategory() => AppStrings.selectExploreCategory;
String _exCategoryHint() => AppStrings.exploreCategoryHint;
String _exUninstalled() => AppStrings.uninstalled;
String _exNoCategories() => AppStrings.noCategories;

String _dictCannotOpenOnline() => AppStrings.cannotOpenOnlineDict;
String _dictLookupTitle() => AppStrings.dictLookupTitle;
String _dictRulesManageTitle() => AppStrings.dictRulesManageTitle;
String _dictRuleManagement() => AppStrings.ruleManagement;
String _dictSearchHint() => AppStrings.dictSearchHint;
String _dictStartHint() => AppStrings.dictStartHint;
String _dictOnlineFallback() => AppStrings.dictOnlineFallbackHint;
String _dictLocalDictionary() => AppStrings.localDictionary;
String _dictUseOnlineBelow() => AppStrings.dictUseOnlineBelow;
String _dictOnlineDictionary() => AppStrings.onlineDictionary;
String _dictNoRulesTapManage() => AppStrings.noDictRulesTapManage;
String _dictNoRulesTapAdd() => AppStrings.noRulesTapAddBelow;
String _dictImportDefault() => AppStrings.importDefaultAction;
String _dictAddRule() => AppStrings.addRuleAction;
String _dictAddDictionaryRule() => AppStrings.addDictionaryRule;
String _dictAddDictRuleEntry() => AppStrings.addDictRuleEntry;
String _dictRuleName() => AppStrings.dictRuleName;
String _dictRuleQueryUrl() => AppStrings.dictRuleQueryUrl;
String _dictWordPlaceholder() => AppStrings.dictWordPlaceholderHint;
String _dictDeleteRuleTitle() => AppStrings.deleteRuleTitle;
String _dictExportRules() => AppStrings.exportDictRules;
String _dictEditDictRule() => AppStrings.editDictRule;
String _dictImportLocal() => AppStrings.importLocalAction;
String _dictImportOnline() => AppStrings.importOnlineAction;
String _dictImportQr() => AppStrings.importQrAction;
String _dictImportPassphrase() => AppStrings.importPassphraseAction;
String _dictQrMissing() => AppStrings.qrContentMissing;
String _dictInvalidHttpUrl() => AppStrings.invalidHttpUrl;
String _dictNewRule() => AppStrings.newRuleAction;
String _dictRuleManagementTitle() => AppStrings.dictRuleManagement;
String _dictMoreOptions() => AppStrings.moreOptions;
String _dictExitMultiSelect() => AppStrings.exitMultiSelect;
String _dictDeselectAll() => AppStrings.deselectAll;
String _dictEnableSelected() => AppStrings.enableSelected;
String _dictDisableSelected() => AppStrings.disableSelected;
String _dictExportSelected() => AppStrings.exportSelected;
String _dictDeleteSelected() => AppStrings.deleteSelected;
String _dictLoading() => AppStrings.loadingDictRules;
String _dictNoRules() => AppStrings.noDictRules;
String _dictNoRulesHint() => AppStrings.noDictRulesHint;
String _dictQueryUrlNotConfigured() => AppStrings.queryUrlNotConfigured;
String _dictRuleNameRequired() => AppStrings.ruleNameRequired;
String _dictQueryUrlLabel() => AppStrings.dictRuleQueryUrlLabel;
String _dictShowRuleLabel() => AppStrings.dictRuleShowRuleLabel;
String _dictShowRuleHint() => AppStrings.dictRuleShowRuleHint;
String _dictLocalImportHint() => AppStrings.dictLocalImportHint;

/// 中文字符（CJK 统一表意文字 + 中文标点）
final _cjk = RegExp(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]');

void main() {
  group('L10N 阶段 3：en 下无中文残留、zh 下为中文', () {
    for (final entry in _samples.entries) {
      test(entry.key, () {
        for (final getter in entry.value) {
          AppStrings.setLocale('en');
          final en = getter();
          expect(
            _cjk.hasMatch(en),
            isFalse,
            reason: 'en 下出现中文：${entry.key} -> $en',
          );

          AppStrings.setLocale('zh');
          final zh = getter();
          expect(
            _cjk.hasMatch(zh),
            isTrue,
            reason: 'zh 下缺少中文：${entry.key} -> $zh',
          );
          expect(
            zh,
            isNot(equals(en)),
            reason: 'zh/en 同形（应显式翻译）：${entry.key} -> $zh',
          );
        }
      });
    }
  });

  group('L10N 阶段 3：参数化文案双语插值', () {
    setUp(() => AppStrings.setLocale('zh'));
    tearDown(() => AppStrings.setLocale('zh'));

    test('书籍详情：更新任务名 / 阅读进度 / 目录统计', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.updateTaskName('三体'), '更新 三体');
      expect(AppStrings.readChapters(3), '已读 3 章');
      expect(AppStrings.totalChapters(120), '共 120 章');
      expect(AppStrings.readingWithTitle('第一章'), '在读 · 第一章');
      expect(AppStrings.latestWithTitle('第51章'), '最新 · 第51章');
      expect(AppStrings.tocUpdated(88), '目录已更新，共 88 章');

      AppStrings.setLocale('en');
      expect(AppStrings.updateTaskName('Three Body'), 'Update Three Body');
      expect(AppStrings.readChapters(3), '3 chapters read');
      expect(AppStrings.totalChapters(120), '120 chapters');
      expect(AppStrings.readingWithTitle('Chapter 1'), 'Reading · Chapter 1');
      expect(AppStrings.latestWithTitle('Chapter 51'), 'Latest · Chapter 51');
      expect(AppStrings.tocUpdated(88), 'Chapters updated, 88 in total');
    });

    test('书籍详情：错误与书架切换文案', () {
      AppStrings.setLocale('zh');
      expect(
        AppStrings.operationFailedWith('网络错误'),
        '操作失败：网络错误',
      );
      expect(
        AppStrings.customButtonFailedWith('超时'),
        '自定义按钮执行失败: 超时',
      );
      expect(
        AppStrings.featureSupportedLater('导出'),
        '「导出」后续版本支持',
      );
      expect(
        AppStrings.confirmRemoveFromShelf('三体'),
        '确定将《三体》移出书架吗？',
      );
      expect(
        AppStrings.removedFromShelf('三体'),
        '《三体》已移出书架',
      );
      expect(
        AppStrings.addedToShelf('三体'),
        '《三体》已加入书架',
      );
      expect(
        AppStrings.chapterCacheCleared(12),
        '已清除 12 条章节缓存',
      );
      expect(
        AppStrings.fileTypeUnsupported('a.epub'),
        '文件类型不支持：a.epub',
      );
      expect(
        AppStrings.importedToShelf('本地书'),
        '《本地书》已导入书架',
      );

      AppStrings.setLocale('en');
      expect(
        AppStrings.operationFailedWith('Network error'),
        'Operation failed: Network error',
      );
      expect(
        AppStrings.customButtonFailedWith('timeout'),
        'Custom button failed: timeout',
      );
      expect(
        AppStrings.featureSupportedLater('Export'),
        '"Export" will be supported in a later version',
      );
      expect(
        AppStrings.confirmRemoveFromShelf('Three Body'),
        'Remove "Three Body" from the bookshelf?',
      );
      expect(
        AppStrings.removedFromShelf('Three Body'),
        '"Three Body" removed from the bookshelf',
      );
      expect(
        AppStrings.addedToShelf('Three Body'),
        '"Three Body" added to the bookshelf',
      );
      expect(
        AppStrings.chapterCacheCleared(12),
        'Cleared 12 chapter cache entries',
      );
      expect(
        AppStrings.fileTypeUnsupported('a.epub'),
        'Unsupported file type: a.epub',
      );
      expect(
        AppStrings.importedToShelf('Local book'),
        '"Local book" imported to the bookshelf',
      );
    });

    test('字典：查询结果与规则批量操作文案', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.dictWordNotFound('apple'), '本地词典未收录「apple」');
      expect(AppStrings.defaultDictRulesImported(5), '已导入 5 条原版默认词典规则');
      expect(AppStrings.dictRulesImported(7), '已导入 7 条字典规则');
      expect(AppStrings.defaultDictRuleRulesImported(5), '已导入 5 条默认字典规则');
      expect(AppStrings.rulesToggled(true, 2), '已启用 2 条规则');
      expect(AppStrings.rulesToggled(false, 2), '已禁用 2 条规则');
      expect(
        AppStrings.batchToggleFailedWith(true, '超时'),
        '批量启用失败：超时',
      );
      expect(
        AppStrings.batchToggleFailedWith(false, '超时'),
        '批量禁用失败：超时',
      );
      expect(AppStrings.rulesDeleted(3), '已删除 3 条规则');
      expect(AppStrings.ruleAddedNamed('必应'), '已添加规则「必应」');
      expect(AppStrings.ruleUpdatedNamed('必应'), '已更新规则「必应」');
      expect(AppStrings.selectedItemsCount(4), '已选 4 项');

      AppStrings.setLocale('en');
      expect(
        AppStrings.dictWordNotFound('apple'),
        '"apple" is not in the local dictionary',
      );
      expect(
        AppStrings.defaultDictRulesImported(5),
        'Imported 5 default dictionary rules',
      );
      expect(AppStrings.dictRulesImported(7), 'Imported 7 dictionary rules');
      expect(
        AppStrings.defaultDictRuleRulesImported(5),
        'Imported 5 default dictionary rules',
      );
      expect(AppStrings.rulesToggled(true, 2), 'Enabled 2 rules');
      expect(AppStrings.rulesToggled(false, 2), 'Disabled 2 rules');
      expect(
        AppStrings.batchToggleFailedWith(true, 'timeout'),
        'Failed to enable the selected rules: timeout',
      );
      expect(
        AppStrings.batchToggleFailedWith(false, 'timeout'),
        'Failed to disable the selected rules: timeout',
      );
      expect(AppStrings.rulesDeleted(3), 'Deleted 3 rules');
      expect(AppStrings.ruleAddedNamed('Bing'), 'Rule "Bing" added');
      expect(AppStrings.ruleUpdatedNamed('Bing'), 'Rule "Bing" updated');
      expect(AppStrings.selectedItemsCount(4), '4 selected');
    });
  });

  group('L10N 阶段 3：列表分隔符与既有约定一致', () {
    test('删除确认的规则名连接使用 listSeparator（zh 顿号 / en 逗号加空格）', () {
      AppStrings.setLocale('zh');
      final zhSeparator = AppStrings.listSeparator;
      expect(zhSeparator, '、');
      expect(
        AppStrings.confirmDeleteDictRules(2, 'A${AppStrings.listSeparator}B'),
        '确定删除选中的 2 条字典规则吗？\n（A、B）',
      );

      AppStrings.setLocale('en');
      expect(AppStrings.listSeparator, ', ');
      expect(
        AppStrings.confirmDeleteDictRules(2, 'A${AppStrings.listSeparator}B'),
        'Delete the 2 selected dictionary rules?\n(A, B)',
      );
    });
  });
}
