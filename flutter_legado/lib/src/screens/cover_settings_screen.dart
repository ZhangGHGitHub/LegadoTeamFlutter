// 封面设置独立页（设置批6b-1）
//
// 对齐参考版 `CoverConfigScreen.kt`（18 项）：
// 1) 仅 WiFi / 封面规则 / 总是使用默认封面 / 默认封面（相册 6b-2）/
//    字体阴影 / 字体描边 / 默认字体色 / 限制封面比例；
// 2) 封面信息方向（竖/横）；
// 3) 网络书籍角标设置（本批只显示灰置行，过滤另立项）；
// 4) 白天：正文色 / 阴影色 / 显示书名 / 显示作者（作者随书名禁用）；
// 5) 夜间：同白天四项，独立持久化。
//
// 入口：设置主页一级「封面设置」；外观页旧「封面设置」行已移除。
// 数据：CoverSettingsNotifier（键名对齐参考版 PreferKey）；取色复用
// ContainerColorDialog（返回 0 = 恢复默认）。
//
// 编写：全栈工程师（设置批6b-1） ｜ 2026-11-06
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/cover_settings.dart';
import '../providers/cover_settings/cover_settings_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../services/cover_album_store.dart';
import '../utils/color_hex.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/container_color_dialog.dart';
import '../widgets/cover_rule_config_dialog.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/legado_app_bar.dart';
import 'cover_album_select_sheet.dart';

/// 封面设置页（参考版 CoverConfigScreen 1:1 分组）
class CoverSettingsScreen extends ConsumerWidget {
  const CoverSettingsScreen({super.key});

  /// 18 项设置行数量（覆盖测试断言用；封面规则为 1 项无持久化字段）
  static const settingItemCount = 18;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(coverSettingsProvider);
    final notifier = ref.read(coverSettingsProvider.notifier);

    void update(CoverSettings Function(CoverSettings current) transform) {
      notifier.update(transform);
    }

    Future<void> pickColor({
      required String title,
      required int initialColor,
      required int defaultColor,
      required CoverSettings Function(CoverSettings current, int color) apply,
    }) async {
      final picked = await showDialog<int>(
        context: context,
        builder: (_) => ContainerColorDialog(
          title: title,
          initialColor: initialColor,
          defaultHint: AppStrings.restoreDefault,
        ),
      );
      if (picked == null) return;
      // ContainerColorDialog 的「恢复默认」返回 0；封面文字色不允许
      // 透明，按参考版默认色（白天黑 / 夜间白）处理。
      final color = picked == 0 ? defaultColor : picked;
      update((current) => apply(current, color));
    }

    return AppScaffold(
      topBar: LegadoAppBar(title: Text(AppStrings.coverSettingsEntry)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          IosGroup(
            children: [
              SettingSwitchRow(
                key: const ValueKey('coverOnlyWifiSwitch'),
                title: AppStrings.onlyWifi,
                subtitle: AppStrings.onlyWifiHint,
                value: settings.loadOnlyOnWifi,
                onChanged: (value) =>
                    update((s) => s.copyWith(loadOnlyOnWifi: value)),
              ),
              IosListTile(
                key: const ValueKey('coverRuleRow'),
                title: AppStrings.coverRules,
                subtitle: AppStrings.coverRuleHint,
                onTap: () => _openCoverRule(context, ref),
              ),
              SettingSwitchRow(
                key: const ValueKey('coverUseDefaultSwitch'),
                title: AppStrings.alwaysUseDefaultCover,
                subtitle: AppStrings.alwaysUseDefaultCoverHint,
                value: settings.useDefaultCover,
                onChanged: (value) =>
                    update((s) => s.copyWith(useDefaultCover: value)),
              ),
              // 相册选择（6b-2）：内置封面 / 相册列表 Sheet + 管理入口
              ValueListenableBuilder<int>(
                valueListenable: CoverAlbumStore.instance.revision,
                builder: (context, _, _) {
                  final album = CoverAlbumStore.instance.albumById(
                    settings.defaultAlbumId,
                  );
                  return IosListTile(
                    key: const ValueKey('coverDefaultAlbumRow'),
                    title: AppStrings.defaultCover,
                    subtitle: album == null
                        ? AppStrings.builtInCover
                        : AppStrings.coverAlbumSummary(
                            album.name, album.lightCount, album.darkCount),
                    onTap: () => _openDefaultAlbum(context, ref),
                  );
                },
              ),
              SettingSwitchRow(
                key: const ValueKey('coverShadowSwitch'),
                title: AppStrings.showFontShadow,
                value: settings.showShadow,
                onChanged: (value) =>
                    update((s) => s.copyWith(showShadow: value)),
              ),
              SettingSwitchRow(
                key: const ValueKey('coverStrokeSwitch'),
                title: AppStrings.showFontStroke,
                value: settings.showStroke,
                onChanged: (value) =>
                    update((s) => s.copyWith(showStroke: value)),
              ),
              SettingSwitchRow(
                key: const ValueKey('coverDefaultColorSwitch'),
                title: AppStrings.useDefaultFontColor,
                subtitle: AppStrings.useDefaultFontColorHint,
                value: settings.useDefaultColor,
                onChanged: (value) =>
                    update((s) => s.copyWith(useDefaultColor: value)),
              ),
              SettingSwitchRow(
                key: const ValueKey('coverRestrictRatioSwitch'),
                title: AppStrings.restrictCoverRatio,
                subtitle: AppStrings.restrictCoverRatioHint,
                value: settings.restrictCoverRatio,
                onChanged: (value) =>
                    update((s) => s.copyWith(restrictCoverRatio: value)),
              ),
            ],
          ),
          IosGroup(
            children: [
              _OrientationRow(
                key: const ValueKey('coverInfoOrientationDropdown'),
                value: settings.infoOrientation,
                onChanged: (value) =>
                    update((s) => s.copyWith(infoOrientation: value)),
              ),
            ],
          ),
          IosSectionHeader(AppStrings.networkBookBadge),
          IosGroup(
            children: [
              // 过滤逻辑另立项：本批只展示灰置行，不接线行为
              IosListTile(
                key: const ValueKey('coverNetworkBadgeRow'),
                title: AppStrings.networkBookBadgeSetting,
                subtitle: AppStrings.notImplementedYet,
                value: AppStrings.showAllLabel,
                showChevron: false,
                enabled: false,
              ),
            ],
          ),
          IosSectionHeader(AppStrings.dayLabel),
          IosGroup(children: _dayRows(settings, update, pickColor)),
          IosSectionHeader(AppStrings.nightMode),
          IosGroup(children: _nightRows(settings, update, pickColor)),
        ],
      ),
    );
  }

  List<Widget> _dayRows(
    CoverSettings settings,
    void Function(CoverSettings Function(CoverSettings current)) update,
    Future<void> Function({
      required String title,
      required int initialColor,
      required int defaultColor,
      required CoverSettings Function(CoverSettings current, int color) apply,
    })
    pickColor,
  ) {
    return [
      _ColorRow(
        key: const ValueKey('coverTextColorRow'),
        title: AppStrings.checkStepContent,
        color: settings.textColor,
        onTap: () => pickColor(
          title: AppStrings.coverTextColorDay,
          initialColor: settings.textColor,
          defaultColor: 0xFF000000,
          apply: (current, color) => current.copyWith(textColor: color),
        ),
      ),
      _ColorRow(
        key: const ValueKey('coverShadowColorRow'),
        title: AppStrings.shadowLabel,
        color: settings.shadowColor,
        onTap: () => pickColor(
          title: AppStrings.shadowColorDay,
          initialColor: settings.shadowColor,
          defaultColor: 0xFF000000,
          apply: (current, color) => current.copyWith(shadowColor: color),
        ),
      ),
      SettingSwitchRow(
        key: const ValueKey('coverShowNameSwitch'),
        title: AppStrings.showNameLabel,
        subtitle: AppStrings.showNameHint,
        value: settings.showName,
        onChanged: (value) => update((s) => s.copyWith(showName: value)),
      ),
      SettingSwitchRow(
        key: const ValueKey('coverShowAuthorSwitch'),
        title: AppStrings.showAuthorLabel,
        subtitle: AppStrings.showAuthorHint,
        value: settings.showAuthor,
        // 参考版：作者开关随书名禁用（书名关闭时不绘制作者）
        onChanged: settings.showName
            ? (value) => update((s) => s.copyWith(showAuthor: value))
            : null,
      ),
    ];
  }

  List<Widget> _nightRows(
    CoverSettings settings,
    void Function(CoverSettings Function(CoverSettings current)) update,
    Future<void> Function({
      required String title,
      required int initialColor,
      required int defaultColor,
      required CoverSettings Function(CoverSettings current, int color) apply,
    })
    pickColor,
  ) {
    return [
      _ColorRow(
        key: const ValueKey('coverTextColorDarkRow'),
        title: AppStrings.checkStepContent,
        color: settings.textColorDark,
        onTap: () => pickColor(
          title: AppStrings.coverTextColorNight,
          initialColor: settings.textColorDark,
          defaultColor: 0xFFFFFFFF,
          apply: (current, color) => current.copyWith(textColorDark: color),
        ),
      ),
      _ColorRow(
        key: const ValueKey('coverShadowColorDarkRow'),
        title: AppStrings.shadowLabel,
        color: settings.shadowColorDark,
        onTap: () => pickColor(
          title: AppStrings.shadowColorNight,
          initialColor: settings.shadowColorDark,
          defaultColor: 0xFFFFFFFF,
          apply: (current, color) => current.copyWith(shadowColorDark: color),
        ),
      ),
      SettingSwitchRow(
        key: const ValueKey('coverShowNameDarkSwitch'),
        title: AppStrings.showNameLabel,
        subtitle: AppStrings.showNameHint,
        value: settings.showNameDark,
        onChanged: (value) => update((s) => s.copyWith(showNameDark: value)),
      ),
      SettingSwitchRow(
        key: const ValueKey('coverShowAuthorDarkSwitch'),
        title: AppStrings.showAuthorLabel,
        subtitle: AppStrings.showAuthorHint,
        value: settings.showAuthorDark,
        onChanged: settings.showNameDark
            ? (value) => update((s) => s.copyWith(showAuthorDark: value))
            : null,
      ),
    ];
  }

  /// 默认封面选择：应用内置封面（null）或相册；选择后写 defaultAlbumId
  Future<void> _openDefaultAlbum(BuildContext context, WidgetRef ref) async {
    await CoverAlbumStore.instance.ensureLoaded();
    if (!context.mounted) return;
    final selection = await CoverAlbumSelectSheet.show(
      context,
      onManage: () {
        Navigator.pushNamed(context, AppRoutes.coverAlbums);
      },
    );
    if (selection == null) return;
    await ref
        .read(coverSettingsProvider.notifier)
        .update(
          (current) => current.copyWith(
            defaultAlbumId: selection.albumId,
            // 单行「默认封面」同时决定日/夜：清空遗留的夜间独立相册选择
            defaultAlbumIdDark: null,
          ),
        );
  }

  Future<void> _openCoverRule(BuildContext context, WidgetRef ref) async {
    final api = ref.read(bookApiProvider);
    await showCoverRuleConfigDialog(
      context,
      loadRule: api.getCoverRule,
      saveRule: api.saveCoverRule,
      deleteRule: api.deleteCoverRule,
      onSearch: api.searchCoverRules,
    );
  }
}

/// 封面信息方向下拉行（0 竖向 / 1 横向）
class _OrientationRow extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _OrientationRow({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IosListTile(
      title: AppStrings.coverInfoOrientation,
      showChevron: false,
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value == CoverSettings.infoOrientationLandscape ? '1' : '0',
          items: [
            DropdownMenuItem(
              value: '0',
              child: Text(AppStrings.coverOrientationPortrait),
            ),
            DropdownMenuItem(
              value: '1',
              child: Text(AppStrings.coverOrientationLandscape),
            ),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}

/// 颜色设置行（HEX + 圆形色块；点击打开 ContainerColorDialog）
class _ColorRow extends StatelessWidget {
  final String title;
  final int color;
  final VoidCallback onTap;

  const _ColorRow({
    super.key,
    required this.title,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IosListTile(
      title: title,
      showChevron: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            argbToHex(color),
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Color(color),
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
