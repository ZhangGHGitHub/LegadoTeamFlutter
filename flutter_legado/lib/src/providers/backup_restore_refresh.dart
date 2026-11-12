// 备份恢复后的全局状态刷新（批10 从 webdav_settings_screen.dart 抽取）
//
// 恢复链（本地长按恢复、WebDAV 远端自动检查确认恢复）成功后必须让
// 依赖 appPrefs 的全局状态在同一会话立即重读：主题/护眼/背景层/书架布局/
// 封面设置/阅读器菜单，以及同步到 Rust caches 的 userAgent/threadCount/
// replaceEnableDefault。设置页与启动自动检查共用本函数，避免两套刷新链
// 漂移。
//
// 页面自身的局部状态（输入框文案等）仍由调用方在刷新后自行 setState。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../services/process_text_service.dart';
import '../services/replace_default_sync.dart';
import 'bookshelf/bookshelf_notifier.dart';
import 'bookshelf_settings/bookshelf_settings_notifier.dart';
import 'cover_settings/cover_settings_notifier.dart';
import 'main_prefs_notifier.dart';
import 'providers.dart';
import 'reader/reader_menu_style_notifier.dart';
import 'reader/reader_theme_notifier.dart';
import 'reader/reader_top_bar_actions_notifier.dart';
import 'sync/sync_notifier.dart';
import 'theme/eye_protection_notifier.dart';
import 'theme/theme_colors_notifier.dart';
import 'theme/theme_notifier.dart';
import 'ui_settings/ui_settings_notifier.dart';

/// 恢复备份后重读全局偏好（不更新任何页面局部状态）
Future<void> reloadAppStateAfterBackupRestore(WidgetRef ref) async {
  await ref.read(syncNotifierProvider.notifier).loadConfig();
  await ref.read(themeNotifierProvider.notifier).load();
  ref.invalidate(themeColorsProvider);
  // [设置批2a-1] 备份 appPrefs 可能替换护眼模式六键：恢复后 await 重读，
  // 让全局叠加层与外观设置页在同一会话即时生效；用 reload 而非 invalidate
  // 避免 provider 重建时先以默认值渲染一帧（护眼会闪一下关闭）。
  await ref.read(eyeProtectionProvider.notifier).reload();
  // [设置批2b-1a] 容器不透明度/容器背景图路径/背景图虚化半径随 appPrefs
  // 恢复，恢复后 await 重读，保证同会话即时生效。
  await ref.read(uiSettingsProvider.notifier).reload();
  ref.invalidate(mainPrefsProvider);
  ref.invalidate(bookshelfNotifierProvider);
  // [设置批6a-1] 书架布局配置随 appPrefs 恢复后 await 重读，避免继续用
  // 旧布局/排序渲染（reload 而非 invalidate，防止默认值中间帧）。
  await ref.read(bookshelfSettingsProvider.notifier).reload();
  // [设置批6b-1] 封面设置随 appPrefs 恢复后 await 重读。
  await ref.read(coverSettingsProvider.notifier).reload();
  // [批37] 顶栏动作配置 / [批3a] 阅读器菜单样式 / [批38] 阅读主题。
  ref.invalidate(readerTopBarActionsProvider);
  ref.invalidate(readerMenuStyleProvider);
  ref.invalidate(readerThemeProvider);

  final settings = ref.read(settingsProvider);
  // 批9b-4 审查回修 P2-2：备份 appPrefs 可能替换 userAgent，恢复完成后
  // 必须同步到 Rust（caches config:userAgent + 运行期默认 UA），否则同
  // 会话内 prefs 与 Rust 分叉，重启前网络请求仍用旧 UA。失败不阻断恢复。
  try {
    final userAgent = (await settings.getStringPref(PrefKeys.userAgent)).trim();
    await ref.read(bookApiProvider).setConfig(PrefKeys.userAgent, userAgent);
  } catch (e) {
    debugPrint('恢复后同步 UserAgent 失败（不阻断恢复）：$e');
  }
  // 批9b-2 审查回修：备份 appPrefs 同样可能替换 threadCount，恢复后与
  // UserAgent 同口径同步 Rust（caches config:threadCount），避免同会话
  // prefs/Rust 分叉；存量 >256 夹逼到 UI 上限。失败不阻断恢复。
  try {
    final threadCount = (await settings.getIntPref(
      PrefKeys.threadCount,
      defaultValue: 16,
    )).clamp(1, 256);
    await ref
        .read(bookApiProvider)
        .setConfig(PrefKeys.threadCount, '$threadCount');
  } catch (e) {
    debugPrint('恢复后同步线程数失败（不阻断恢复）：$e');
  }
  // [批7a 复核 P2-N1] 备份 appPrefs 可能替换 replaceEnableDefault：恢复后
  // 同步 Rust caches 配置；失败静默不阻断恢复。无论 config 写入成败，
  // 随后都让缓存 provider 失效，下次菜单 watch 重读 prefs。
  await syncReplaceEnableDefaultAfterRestore(ref.read(bookApiProvider));
  ref.invalidate(replaceEnableDefaultProvider);
  // process_text：备份 appPrefs 可能替换「文字操作显示搜索」开关，恢复后
  // 立即把偏好应用到 Android PROCESS_TEXT 入口组件。否则同会话打开设置页
  // 会用组件旧状态反写偏好（对齐原版 read-back 语义），静默丢弃恢复值。
  // 非 Android 平台内部直接跳过；失败不阻断恢复。
  try {
    await ProcessTextMenuService.syncFromPref(settings);
  } catch (e) {
    debugPrint('恢复后同步文字操作开关失败（不阻断恢复）：$e');
  }
}
