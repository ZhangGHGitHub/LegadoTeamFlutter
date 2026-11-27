// 逐表备份忽略（C1）
//
// 对齐参考版 `BackupConfig.dbIsNotIgnored(tableName, isBackup = true)`
// （`legado-with-MD3/.../help/storage/BackupConfig.kt:129-132`，
// 由 `Backup.kt:156-222` 逐表把守写出项）：备份时可按**表**关闭，
// 被忽略的表不写入备份文件，恢复该备份时本机这些表保持原值。
//
// 存储：caches 表 `config:backupIgnoreTables`（经既有
// `BookApi.getConfig/setConfig`，**零新增 FFI 方法**），值为 JSON 字符串数组，
// 元素为参考版 `dbIgnoreKeys` 的键名。该配置是**设备级**的：不进
// `appPrefs`、不随备份往返（参考版对应文件 `backupDbIgnore.json` 同样不在
// zip 内），避免目标机的忽略策略被旧备份覆盖。
//
// 可忽略项**只收录参考版实际把守的表**：`books`（书架）、`highlights`
// （高亮）、`bookMemos`、`autoTasks`、`coverRules`、`directLinkUploadRule`
// 在参考版没有该开关，故此处同样不提供（详见契约 §2.11 C1 补记）。
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugPrint, immutable, visibleForTesting;

import '../l10n/app_strings.dart';
import 'book_api.dart';

/// 可忽略的备份表（键名逐字对齐参考版 `BackupConfig.dbIgnoreKeys`）
@immutable
class BackupContentEntry {
  const BackupContentEntry(this.key, this.title);

  /// 参考版忽略键（写入 `config:backupIgnoreTables` 的字符串）
  final String key;

  /// 设置项标题（对齐参考版 `dbIgnoreTitle` 的中文名）
  final String title;
}

/// 逐表备份忽略服务
class BackupContentService {
  BackupContentService({required BookApi api}) : _api = api;

  final BookApi _api;

  /// 配置短键（caches 表实际键为 `config:backupIgnoreTables`）
  static const configKey = 'backupIgnoreTables';

  /// 可选忽略项，顺序对齐参考版 `BackupConfig.dbIgnoreKeys`
  ///
  /// 参考版有而本应用 schema 无对应表的 4 项（`homepageModules` /
  /// `homepageCustomSets` / `highlightTagRule` / `tagGroupRule`）不列出；
  /// `bookmark` 在参考版同时把守书签与划线/笔记，故标题合并表述。
  ///
  /// 标题经 [AppStrings] 本地化：首次访问时按启动 locale 生成（与全局
  /// 语言切换一致，重启生效）。
  static final List<BackupContentEntry> entries = List.unmodifiable([
    BackupContentEntry('bookmark', AppStrings.backupContentBookmark),
    BackupContentEntry('bookGroup', AppStrings.backupContentBookGroup),
    BackupContentEntry('bookSource', AppStrings.sources),
    BackupContentEntry('rssSource', AppStrings.backupContentRssSource),
    BackupContentEntry('rssStar', AppStrings.rssFavorites),
    BackupContentEntry('replaceRule', AppStrings.backupContentReplaceRule),
    BackupContentEntry('readRecord', AppStrings.readRecordLabel),
    BackupContentEntry('searchHistory', AppStrings.searchHistory),
    BackupContentEntry(
      'sourceSub',
      AppStrings.backupContentSourceSubscription,
    ),
    BackupContentEntry('txtTocRule', AppStrings.txtTocRulesLabel),
    BackupContentEntry('httpTTS', AppStrings.backupContentHttpTts),
    BackupContentEntry(
      'keyboardAssists',
      AppStrings.backupContentKeyboardAssists,
    ),
    BackupContentEntry('dictRule', AppStrings.backupContentDictRule),
    BackupContentEntry('highlightRule', AppStrings.highlightRulesMenu),
    BackupContentEntry('server', AppStrings.webdavServerConfig),
  ]);

  /// 全部合法键
  static Set<String> get keys => {for (final entry in entries) entry.key};

  /// 读取已忽略的表集合（缺失/损坏 → 空集，即不过滤）
  Future<Set<String>> load() async {
    final raw = await _api.getConfig(configKey);
    return parse(raw);
  }

  /// 持久化忽略表集合
  ///
  /// 只写入 [keys] 内的已知键（未知值丢弃，避免把脏配置带进 Rust），
  /// 按 [entries] 顺序序列化保证「同一集合 → 同一文本」。
  Future<void> save(Set<String> ignored) async {
    final ordered = [
      for (final entry in entries)
        if (ignored.contains(entry.key)) entry.key,
    ];
    await _api.setConfig(configKey, jsonEncode(ordered));
  }

  /// 解析配置文本（宽容：空/非法/非数组 → 空集）
  ///
  /// 与 Rust `parse_ignored_backup_sections` 的 fail-open 口径一致：
  /// 配置坏掉时宁可全量备份，也不静默丢数据。
  @visibleForTesting
  static Set<String> parse(String? raw) {
    if (raw == null) return <String>{};
    final text = raw.trim();
    if (text.isEmpty) return <String>{};
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      debugPrint('BackupContentService: 忽略表配置不是合法 JSON，按空处理：$e');
      return <String>{};
    }
    if (decoded is! List) {
      debugPrint('BackupContentService: 忽略表配置不是数组，按空处理');
      return <String>{};
    }
    final valid = keys;
    return {
      for (final item in decoded)
        if (item is String && valid.contains(item.trim())) item.trim(),
    };
  }
}
