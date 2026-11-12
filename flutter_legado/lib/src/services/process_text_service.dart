// 文字操作「阅读·搜索」开关（pref 键 `process_text`）
//
// 原版语义（legado-upstream OtherConfigFragment.kt:76,276-279,444-460）：
// `process_text` 控制系统 ACTION_PROCESS_TEXT（长按选中文字后的系统菜单
// 项）是否显示本应用。原版通过 PackageManager.setComponentEnabledSetting
// 启停承载 PROCESS_TEXT intent-filter 的 SharedReceiverActivity 组件，
// 不修改意图内容本身。
//
// 本实现：Android 侧 manifest 用独立 `activity-alias`（.ProcessTextAlias，
// targetActivity=.MainActivity）承载 PROCESS_TEXT intent-filter，原生桥
// `legado/process_text` 启停该别名组件（等价组件启停，主 Activity 不受
// 影响）；选中文字后仍复用既有 ACTION_PROCESS_TEXT → 分享文本链路。
// 非 Android 平台（Windows 桌面端等）无系统文字操作菜单，开关置灰并在
// 设置页标注「仅 Android 支持」，不留死开关。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/pref_keys.dart';
import 'settings_service.dart';

/// 系统文字操作菜单接入状态
enum ProcessTextAvailability {
  /// Android：可启停组件
  supported,

  /// 非 Android 平台：无系统文字操作菜单
  unsupportedPlatform,

  /// Android 但原生桥未注册（旧安装/异常构建）
  bridgeUnavailable,
}

/// 系统「文字操作」菜单开关服务
class ProcessTextMenuService {
  ProcessTextMenuService._();

  static const MethodChannel _channel = MethodChannel('legado/process_text');

  /// 当前平台是否支持（仅 Android 有系统文字操作菜单）
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 读取原生组件当前启用状态
  ///
  /// 非 Android 返回 false；桥异常回退 false（调用方据此显示关闭态）。
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      final enabled = await _channel.invokeMethod<bool>('isEnabled');
      return enabled ?? false;
    } catch (e) {
      debugPrint('[ProcessText] 读取组件状态失败：$e');
      return false;
    }
  }

  /// 启用/禁用 PROCESS_TEXT 入口组件
  ///
  /// 返回实际生效状态；非 Android / 桥未注册或执行失败时返回 null
  /// （调用方据此回滚 UI 并提示，不向界面抛异常）。
  static Future<bool?> setEnabled(bool enabled) async {
    if (!isSupported) return null;
    try {
      final applied = await _channel.invokeMethod<bool>('setEnabled', {
        'enabled': enabled,
      });
      return applied ?? enabled;
    } catch (e) {
      debugPrint('[ProcessText] 设置组件状态失败（enabled=$enabled）：$e');
      return null;
    }
  }

  /// 依据偏好同步原生组件状态（启动时调用）
  ///
  /// 原版在设置页打开时以组件实际状态回写偏好；本实现额外在启动时把
  /// 备份恢复/旧版本残留的偏好应用到组件，避免「偏好关但菜单仍显示」。
  /// 非 Android 平台直接跳过。
  static Future<void> syncFromPref([SettingsService? settings]) async {
    if (!isSupported) return;
    final service = settings ?? SettingsService();
    final enabled = await service.getBoolPref(
      PrefKeys.processText,
      defaultValue: true,
    );
    await setEnabled(enabled);
  }

  /// 探测可用性（设置页展示文案用）
  static Future<ProcessTextAvailability> availability() async {
    if (!isSupported) return ProcessTextAvailability.unsupportedPlatform;
    try {
      await _channel.invokeMethod<bool>('isEnabled');
      return ProcessTextAvailability.supported;
    } catch (e) {
      debugPrint('[ProcessText] 原生桥不可用：$e');
      return ProcessTextAvailability.bridgeUnavailable;
    }
  }
}
