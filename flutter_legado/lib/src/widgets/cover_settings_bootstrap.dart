// 封面设置冷启动预热（设置批6b-1 审查 R-P2-2）
//
// LegadoApp 以本 Widget 包裹应用树：initState 仅 ref.read
// (coverSettingsProvider)（不 watch、不重建），Provider 异步加载完成后
// 把持久化值写入 coverSettingsListenable，首屏书架/搜索/发现/详情由该
// listenable 通知刷新。抽成独立 Widget 便于直接回归测试「根节点预热」
// 契约，避免测试复制一份假 initState。
//
// [设置批6b-2] 同时预热封面相册索引（幂等），首屏 BookCover 无需等待。
//
// 编写：全栈工程师（设置批6b-1 审查） ｜ 2026-11-06
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/cover_settings/cover_settings_notifier.dart';
import '../services/cover_album_store.dart';

/// 应用根预热壳：只读一次 Provider，渲染子节点
class CoverSettingsBootstrap extends ConsumerStatefulWidget {
  final Widget child;

  const CoverSettingsBootstrap({super.key, required this.child});

  @override
  ConsumerState<CoverSettingsBootstrap> createState() =>
      _CoverSettingsBootstrapState();
}

class _CoverSettingsBootstrapState
    extends ConsumerState<CoverSettingsBootstrap> {
  @override
  void initState() {
    super.initState();
    // 只 read（不 watch MaterialApp build）：加载完成后由
    // coverSettingsListenable 通知 BookCover/详情页重建，不触发整树重建。
    ref.read(coverSettingsProvider);
    // 相册索引预热（Notifier 加载时也会 ensureLoaded，这里提前并行）
    unawaited(CoverAlbumStore.instance.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
