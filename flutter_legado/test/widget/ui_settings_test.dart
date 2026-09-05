// [UI_SYNC_REFACTOR B3] 底栏设置回归守护：label 三档/大屏形态解析与默认值、
// UiSettingsState 默认口径（对齐参考仓默认：悬浮关/显示开/透明度 100）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';

void main() {
  test('BottomBarLabelMode 解析：合法直取/未知回退 auto', () {
    expect(BottomBarLabelMode.fromName('labeled'), BottomBarLabelMode.labeled);
    expect(
      BottomBarLabelMode.fromName('unlabeled'),
      BottomBarLabelMode.unlabeled,
    );
    expect(BottomBarLabelMode.fromName(null), BottomBarLabelMode.auto);
    expect(BottomBarLabelMode.fromName('__bad__'), BottomBarLabelMode.auto);
  });

  test('TabletInterfaceMode 解析：合法直取/未知回退 auto', () {
    expect(
      TabletInterfaceMode.fromName('landscape'),
      TabletInterfaceMode.landscape,
    );
    expect(TabletInterfaceMode.fromName('off'), TabletInterfaceMode.off);
    expect(TabletInterfaceMode.fromName(null), TabletInterfaceMode.auto);
    expect(TabletInterfaceMode.fromName('always'), TabletInterfaceMode.always);
  });

  test('默认口径对齐参考仓：悬浮关/显示开/透明度 100', () {
    const state = UiSettingsState();
    expect(state.useFloatingBottomBar, isFalse);
    expect(state.showBottomView, isTrue);
    expect(state.bottomBarOpacity, 100);
    expect(state.topBarOpacity, 100);
    expect(state.labelVisibilityMode, BottomBarLabelMode.auto);
    expect(state.tabletInterface, TabletInterfaceMode.auto);
  });
}
