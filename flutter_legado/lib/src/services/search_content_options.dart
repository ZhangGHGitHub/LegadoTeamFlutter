import 'settings_service.dart';

/// 正文搜索选项（批33：由进程内静态升级为 SharedPreferences 持久化）
///
/// 背景：原版把「替换 / 正则 / 搜索范围」放在 `SearchContentViewModel`
/// 的进程内静态（关闭页面重进保留、进程重启丢失）；参考版把范围默认设为
/// 「仅本书（已缓存）」。本类按批33 裁决收敛：
/// - 默认范围 [SettingsService.searchScopeCached]（只搜已缓存，对齐原版/
///   参考版口径）；
/// - 三档范围与替换/正则开关均持久化，重进与重启后保持上次选择。
///
/// 纯数据 + 读写封装，便于单测；UI 层只持有实例并调用 [load]/[save]。
class SearchContentOptions {
  SearchContentOptions({SettingsService? settings})
      : _settings = settings ?? SettingsService();

  final SettingsService _settings;

  /// 搜索前是否应用替换净化规则（原版 replaceEnabled，默认 false）
  bool useReplace = false;

  /// 关键词是否按正则解释（原版 regexReplace，默认 false）
  bool useRegex = false;

  /// 搜索范围，取值见 [SettingsService.searchScopeCurrent] /
  /// [SettingsService.searchScopeCached] / [SettingsService.searchScopeNetwork]
  String scope = SettingsService.searchScopeDefault;

  /// 从持久化恢复（缺失/非法值回退默认）
  Future<void> load() async {
    useReplace = await _settings.getSearchContentUseReplace();
    useRegex = await _settings.getSearchContentUseRegex();
    scope = await _settings.getSearchContentScope();
  }

  /// 写入持久化（三键一并保存，调用方不需感知键名）
  Future<void> save() async {
    await _settings.setSearchContentUseReplace(useReplace);
    await _settings.setSearchContentUseRegex(useRegex);
    await _settings.setSearchContentScope(scope);
  }
}
