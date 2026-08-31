package io.legado.flutter

/**
 * 启动图标变体 Activity（对齐原版 WelcomeActivity.kt 末尾的
 * `class Launcher1 : WelcomeActivity()` ×6 桩类）。
 *
 * 各自在 manifest 中携带 launcher1~6 图标并默认禁用；
 * [LauncherIconBridge] 通过 setComponentEnabledSetting 切换哪个可见，
 * 从而更换桌面显示的应用图标。功能与 MainActivity 完全一致（继承其全部行为）。
 */
class Launcher1 : MainActivity()

class Launcher2 : MainActivity()

class Launcher3 : MainActivity()

class Launcher4 : MainActivity()

class Launcher5 : MainActivity()

class Launcher6 : MainActivity()
