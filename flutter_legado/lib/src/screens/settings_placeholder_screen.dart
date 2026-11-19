import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_strings.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/empty_state.dart';
import '../widgets/legado_app_bar.dart';

/// 占位页类型（决定标题/说明文案，文案在 build 时按当前语言解析）
enum _PlaceholderKind { ai, translation, lab }

/// 设置占位页（AI 设置 / 翻译设置 / 实验室）
///
/// [设置批10a | 2026-11-04 用户裁决] 参考版设置主页含「AI 设置」「翻译
/// 设置」「实验室」三个入口，但 Rust 侧暂未提供 LLM / 翻译 / 实验能力。
/// 本批只做「入口 + 页面壳」并明确标注暂未支持，不接任何功能。
///
/// 口径与既有 AI 聊天占位页一致：页面只有标题、图标、说明与返回，
/// 不提供输入框、网络请求、开关或伪功能，避免用户误以为能力已可用；
/// 后续 Rust 能力立项后再以真实页面替换对应路由。
///
/// — 全栈工程师 + UI ｜ 2026-11-04
class SettingsPlaceholderScreen extends StatelessWidget {
  /// 通用构造：调用方提供标题/图标/说明（便于测试与后续复用）
  const SettingsPlaceholderScreen({
    super.key,
    required String title,
    required this.icon,
    required String description,
  }) : _title = title,
       _description = description,
       _kind = null;

  /// AI 设置占位（参考版「AI 设置」入口）
  const SettingsPlaceholderScreen.ai({super.key})
    : _title = null,
      _description = null,
      _kind = _PlaceholderKind.ai,
      icon = Symbols.auto_awesome_rounded;

  /// 翻译设置占位（参考版「翻译设置」入口）
  const SettingsPlaceholderScreen.translation({super.key})
    : _title = null,
      _description = null,
      _kind = _PlaceholderKind.translation,
      icon = Symbols.translate_rounded;

  /// 实验室占位（参考版「实验室」入口）
  const SettingsPlaceholderScreen.lab({super.key})
    : _title = null,
      _description = null,
      _kind = _PlaceholderKind.lab,
      icon = Symbols.science_rounded;

  /// 调用方显式指定的标题（null 时按 [_kind] 解析）
  final String? _title;

  /// 调用方显式指定的说明文案（null 时按 [_kind] 解析）
  final String? _description;

  /// 占位页类型（null 表示通用构造）
  final _PlaceholderKind? _kind;

  /// 空态图标
  final IconData icon;

  /// 页面标题（顶栏与空态共用）
  String get title =>
      _title ??
      switch (_kind) {
        _PlaceholderKind.ai => AppStrings.aiSettingsEntry,
        _PlaceholderKind.translation => AppStrings.translationSettingsEntry,
        _PlaceholderKind.lab => AppStrings.labSettingsEntry,
        null => '',
      };

  /// 「暂未支持」说明文案
  String get description =>
      _description ??
      switch (_kind) {
        _PlaceholderKind.ai => AppStrings.aiSettingsUnavailableDesc,
        _PlaceholderKind.translation =>
          AppStrings.translationSettingsUnavailableDesc,
        _PlaceholderKind.lab => AppStrings.labSettingsUnavailableDesc,
        null => '',
      };

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      topBar: LegadoAppBar(title: Text(title)),
      body: EmptyState(
        icon: icon,
        title: AppStrings.notSupportedNamed(title),
        subtitle: description,
      ),
    );
  }
}
