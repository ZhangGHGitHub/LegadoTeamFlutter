import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../widgets/app_scaffold.dart';
import '../widgets/empty_state.dart';
import '../widgets/legado_app_bar.dart';

/// AI 聊天占位页
///
/// [M1 我的页信息架构 | full-stack-engineer + UI] 用户裁决（2026-11-03）：
/// 「其他」组增加「AI 聊天」入口，先做入口 + 占位壳，**明确暂未支持**，
/// 不接任何 LLM/网络能力；后续 Rust 能力立项后再替换本页。
///
/// 口径与既有 AI/翻译/实验室占位一致：不提供输入框或伪对话，避免用户
/// 误以为功能可用。
class AiChatScreen extends StatelessWidget {
  const AiChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: const LegadoAppBar(title: Text('AI 聊天')),
      body: const EmptyState(
        icon: Symbols.auto_awesome_rounded,
        title: 'AI 聊天暂未支持',
        subtitle: '待 Rust 能力接入后开放',
      ),
    );
  }
}
