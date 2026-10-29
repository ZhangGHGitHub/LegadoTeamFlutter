// 阅读主题存储服务（批38｜参考版阅读主题列表管理）
//
// 持久化全部落 SharedPreferences（不进 FFI/业务表）：
// - `reader_theme_list`      自建主题 JSON 数组（内置主题由代码提供，不落盘）
// - `reader_theme_current_id` 当前主题 id（空 = 未应用任何命名主题）
// - `themeGridColumns`       网格列数 2..6，默认 4（键名逐字对齐参考版
//   `PreferKey.themeGridColumns`，见参考版 `ReadSettingsRepository`）
//
// 三个键均登记进 `RestoreIgnorePrefs.readPrefKeys`：随 JSON 备份 `appPrefs`
// 自动往返，勾选「忽略阅读配置」时恢复备份不覆盖本机主题库。
//
// 编写：全栈工程师（批38） ｜ 2026-10-29
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_theme.dart';

/// 阅读主题存储服务
class ReaderThemeService {
  ReaderThemeService();

  /// 自建主题列表键
  static const String themesKey = 'reader_theme_list';

  /// 当前主题 id 键
  static const String currentIdKey = 'reader_theme_current_id';

  /// 网格列数键（对齐参考版 PreferKey.themeGridColumns）
  static const String gridColumnsKey = 'themeGridColumns';

  static const int minGridColumns = 2;
  static const int maxGridColumns = 6;
  static const int defaultGridColumns = 4;

  /// 自建主题 id 自增序号（同一进程内保证不重）
  static int _idSeq = 0;

  /// 生成新的主题 id
  static String newThemeId() {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    _idSeq++;
    return 'theme-$stamp-$_idSeq';
  }

  /// 列数归一（越界/脏数据收敛到 2..6）
  static int normalizeGridColumns(int columns) =>
      columns.clamp(minGridColumns, maxGridColumns);

  /// 读取自建主题（本地持久化损坏时返回空列表，不阻断阅读）
  Future<List<ReaderTheme>> loadCustomThemes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ReaderThemeCodec.decodeStoredList(prefs.getString(themesKey));
    } catch (e) {
      debugPrint('ReaderThemeService.loadCustomThemes 异常: $e');
      return const <ReaderTheme>[];
    }
  }

  /// 保存自建主题（只写非内置条目）
  Future<void> saveCustomThemes(List<ReaderTheme> themes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        themesKey,
        ReaderThemeCodec.encodeStoredList(themes),
      );
    } catch (e) {
      debugPrint('ReaderThemeService.saveCustomThemes 异常: $e');
    }
  }

  /// 读取当前主题 id（空 = 未应用命名主题）
  Future<String> loadCurrentId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(currentIdKey) ?? '';
    } catch (e) {
      debugPrint('ReaderThemeService.loadCurrentId 异常: $e');
      return '';
    }
  }

  /// 写入当前主题 id（null/空 = 清除）
  Future<void> saveCurrentId(String? id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null || id.isEmpty) {
        await prefs.remove(currentIdKey);
      } else {
        await prefs.setString(currentIdKey, id);
      }
    } catch (e) {
      debugPrint('ReaderThemeService.saveCurrentId 异常: $e');
    }
  }

  /// 读取网格列数（默认 4）
  Future<int> loadGridColumns() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(gridColumnsKey);
      if (stored == null) return defaultGridColumns;
      return normalizeGridColumns(stored);
    } catch (e) {
      debugPrint('ReaderThemeService.loadGridColumns 异常: $e');
      return defaultGridColumns;
    }
  }

  /// 写入网格列数（统一 clamp 到 2..6）
  Future<void> saveGridColumns(int columns) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(gridColumnsKey, normalizeGridColumns(columns));
    } catch (e) {
      debugPrint('ReaderThemeService.saveGridColumns 异常: $e');
    }
  }

  /// 内置主题 + 自建主题（内置恒在前；自建保持传入顺序）
  static List<ReaderTheme> mergeThemes(List<ReaderTheme> customThemes) =>
      <ReaderTheme>[
        ...kBuiltInReaderThemes,
        for (final theme in customThemes)
          if (!theme.builtIn) theme,
      ];

  /// 以当前样式快照新建一份自建主题
  ///
  /// [existingNames] 用于冲突加后缀；id 运行时生成。
  static ReaderTheme createTheme({
    required String name,
    required ReaderThemeStyle style,
    required Iterable<String> existingNames,
  }) {
    return ReaderTheme(
      id: newThemeId(),
      name: uniqueReaderThemeName(name, existingNames),
      style: style.normalized(),
    );
  }

  /// 导入 JSON（单份或数组），返回新建的自建主题列表
  ///
  /// - 每份都重新分配 id（不采信导入内容里的 id，避免覆盖现有主题身份）
  /// - 名称与现有/本批已导入名称冲突时自动加 ` (2)` 后缀
  /// - 非法 JSON / 缺字段 / 类型错误抛 [FormatException]，调用方提示原因
  static List<ReaderTheme> importThemes(
    String raw, {
    required Iterable<String> existingNames,
  }) {
    final parsed = ReaderThemeCodec.decodeAll(raw);
    final usedNames = <String>{...existingNames};
    final imported = <ReaderTheme>[];
    for (final source in parsed) {
      final name = uniqueReaderThemeName(source.name, usedNames);
      usedNames.add(name);
      imported.add(
        ReaderTheme(id: newThemeId(), name: name, style: source.style),
      );
    }
    return imported;
  }
}
