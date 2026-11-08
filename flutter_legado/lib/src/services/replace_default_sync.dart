/// 替换净化总开关（replaceEnableDefault）prefs ↔ Rust config 同步（批7a 闭环）
///
/// 背景：该开关此前只写 SharedPreferences，Rust 阅读链读 caches
/// `config:replaceEnableDefault` 恒缺省 true，导致「其他设置」里的总开关
/// 对阅读净化无效。本文件统一两条写入路径：
/// - 开关切换：[saveReplaceEnableDefault] 同步写 prefs（UI 真源）与 config
///   （Rust 阅读链真源）；
/// - 冷启动：[syncReplaceEnableDefaultOnStartup] 把存量 prefs 值幂等同步到
///   config（老用户已设 false 时补写；默认 true 且 Rust 缺省时不写库）。
library;

import 'package:flutter/foundation.dart';

import '../constants/pref_keys.dart';
import 'book_api.dart';
import 'crash_log_service.dart';
import 'settings_service.dart';

/// 解析 Rust config 值的有效布尔（对齐 Rust `get_replace_enable_default`）
///
/// 缺省/空串/非法 → true；`"false"` / `"0"`（忽略大小写与首尾空白）→ false。
bool parseReplaceEnableDefaultConfig(String? raw) {
  final normalized = (raw ?? '').trim().toLowerCase();
  return normalized != 'false' && normalized != '0';
}

/// 总开关切换：同时写 SharedPreferences 与 Rust config（值 "true"/"false"）
///
/// prefs 写失败由 [SettingsService] 内部吞掉；config 写失败向上抛，由调用方
/// 提示（UI 真源已保存，不回滚）。
///
/// [onPrefsWritten] 在 prefs 写入之后、config 写入之前调用：调用方借此让
/// 缓存 provider 失效，不受 config 成败影响（审查 P3）。
Future<void> saveReplaceEnableDefault(
  BookApi api,
  bool value, {
  VoidCallback? onPrefsWritten,
}) async {
  await SettingsService().setBoolPref(PrefKeys.replaceEnableDefault, value);
  onPrefsWritten?.call();
  await api.setConfig(
    PrefKeys.replaceEnableDefault,
    value ? 'true' : 'false',
  );
}

/// 备份恢复后：把恢复的 prefs 总开关值同步到 Rust config（失败静默）
///
/// 与 UserAgent / threadCount 恢复后同步同口径：备份 appPrefs 可能替换该键，
/// 不同步会让同会话 Rust 阅读链继续按旧默认；失败只记 AppLog，不阻断恢复。
/// 调用方在恢复偏好写回后执行本函数，并随后 invalidate
/// `replaceEnableDefaultProvider`（provider 缓存失效与 config 成败无关）。
Future<void> syncReplaceEnableDefaultAfterRestore(BookApi api) async {
  try {
    final enabled = await SettingsService().getBoolPref(
      PrefKeys.replaceEnableDefault,
      defaultValue: true,
    );
    await api.setConfig(
      PrefKeys.replaceEnableDefault,
      enabled ? 'true' : 'false',
    );
  } catch (e) {
    debugPrint('恢复后同步替换净化默认开关失败（不阻断恢复）：$e');
  }
}

/// 冷启动：把存量 prefs 总开关值幂等同步到 Rust config
///
/// 仅当 Rust 有效值与 prefs 不同才写库；默认 true 且 Rust 缺省（有效 true）
/// 时不产生写入。[useMock] 为 true 时跳过（Mock 无 DB）；任何失败静默记录、
/// 不阻断启动（与 UserAgent / 线程数启动同步同口径）。
Future<void> syncReplaceEnableDefaultOnStartup(
  BookApi api, {
  required bool useMock,
}) async {
  try {
    if (useMock) {
      return;
    }
    final pref = await SettingsService().getBoolPref(
      PrefKeys.replaceEnableDefault,
      defaultValue: true,
    );
    final rustEffective = parseReplaceEnableDefaultConfig(
      await api.getConfig(PrefKeys.replaceEnableDefault),
    );
    if (pref == rustEffective) {
      return;
    }
    await api.setConfig(
      PrefKeys.replaceEnableDefault,
      pref ? 'true' : 'false',
    );
    debugPrint('[启动] 替换净化默认开关已同步到 Rust：$pref');
  } catch (e) {
    // 静默失败：同步属启动附带维护，失败不影响用户可见流程；
    // 仅记 AppLog 内存，不写 crash_log（同 UserAgent / 线程数同步口径）。
    CrashLogService.instance.put(
      '[启动] 替换净化默认开关同步失败（不阻断启动）：$e',
      error: e,
    );
  }
}
