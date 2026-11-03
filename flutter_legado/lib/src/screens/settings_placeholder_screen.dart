import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../widgets/app_scaffold.dart';
import '../widgets/empty_state.dart';
import '../widgets/legado_app_bar.dart';

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
    required this.title,
    required this.icon,
    required this.description,
  });

  /// AI 设置占位（参考版「AI 设置」入口）
  const SettingsPlaceholderScreen.ai({super.key})
    : title = 'AI 设置',
      icon = Symbols.auto_awesome_rounded,
      description = '待 Rust AI 能力接入后开放';

  /// 翻译设置占位（参考版「翻译设置」入口）
  const SettingsPlaceholderScreen.translation({super.key})
    : title = '翻译设置',
      icon = Symbols.translate_rounded,
      description = '待 Rust 翻译能力接入后开放';

  /// 实验室占位（参考版「实验室」入口）
  const SettingsPlaceholderScreen.lab({super.key})
    : title = '实验室',
      icon = Symbols.science_rounded,
      description = '待后续实验能力接入后开放';

  /// 页面标题（顶栏与空态共用）
  final String title;

  /// 空态图标
  final IconData icon;

  /// 「暂未支持」说明文案
  final String description;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      topBar: LegadoAppBar(title: Text(title)),
      body: EmptyState(icon: icon, title: '$title暂未支持', subtitle: description),
    );
  }
}
