// 文本阅读器私密闸门（批9c）
//
// 对齐参考版 `PrivateReadGate`：未授权时**不组合阅读器**，用全屏锁定页
// 取代内容（不是“先打开再遮住”）；进入自动弹一次验证，取消退回上一页，
// 成功继续。离开阅读器（gate dispose / 换书）撤销 EveryTime 目标授权。
//
// 仅文本阅读器（`/reader`）；漫画参考版无 gate，本批不接入。
//
// 编写：全栈工程师（批9c） ｜ 2026-11-09
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/privacy/privacy_content_notifier.dart';
import '../../providers/privacy/privacy_notifier.dart';
import '../../providers/reader/reader_notifier.dart';
import 'private_locked_page.dart';
import 'privacy_unlock_dialog.dart';

/// 文本阅读器路由私密闸门（深链兜底）
class PrivateReadGate extends ConsumerStatefulWidget {
  const PrivateReadGate({super.key, required this.child});

  /// 授权后渲染的内容（阅读器）
  final Widget child;

  @override
  ConsumerState<PrivateReadGate> createState() => _PrivateReadGateState();
}

class _PrivateReadGateState extends ConsumerState<PrivateReadGate> {
  String? _bookUrl;

  /// 每个目标只自动弹一次；换书后重置
  bool _autoUnlockRequested = false;

  /// [批9c] dispose 阶段不能读 ref；提前捕获用于撤销授权
  PrivacyNotifier? _privacyNotifier;

  @override
  void initState() {
    super.initState();
    _privacyNotifier = ref.read(privacyNotifierProvider.notifier);
  }

  @override
  void dispose() {
    // 离开阅读器即撤销本次授权（EveryTime；其它频率 no-op）。
    // dispose 阶段不能同步改 provider 状态，延后到微任务。
    final notifier = _privacyNotifier;
    final url = _bookUrl;
    if (notifier != null) {
      Future.microtask(() {
        try {
          notifier.revokeBook(url);
        } catch (_) {
          // 退出流程不因撤销失败中断
        }
      });
    }
    super.dispose();
  }

  /// 取消验证 = 放弃打开：退回上一页（没有上一页则留在原地）
  void _exit() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.maybePop();
    }
  }

  Future<void> _requestUnlock(String bookUrl) async {
    final unlocked = await showPrivacyUnlockDialog(
      context,
      ref,
      bookUrl: bookUrl,
      title: '验证后阅读',
    );
    if (!mounted) return;
    if (unlocked) return;
    // 用户取消/无密码：按约定退出阅读器路由（回到上一页）
    _exit();
  }

  @override
  Widget build(BuildContext context) {
    final readerBook = ref.watch(
      readerNotifierProvider.select((s) => s.currentBook),
    );
    final privacy = ref.watch(privacyNotifierProvider);
    final content = ref.watch(privacyContentProvider);
    final bookUrl = readerBook?.bookUrl;

    // 换书：撤销上一本的 EveryTime 授权，并允许对新书再自动弹一次
    if (bookUrl != _bookUrl) {
      final previous = _bookUrl;
      _bookUrl = bookUrl;
      _autoUnlockRequested = false;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(privacyNotifierProvider.notifier).revokeBook(previous);
        });
      }
    }

    // 策略/私密标记未就绪：先不组合阅读器（防止首帧泄漏）
    if (!privacy.loaded || !content.loaded) {
      return const SizedBox.expand();
    }
    if (bookUrl == null || readerBook == null) return widget.child;

    final factsBook = content.booksByUrl[bookUrl] ?? readerBook;
    final isPrivate = content.isBookPrivate(factsBook);
    final locked =
        isPrivate && privacy.isBookLocked(factsBook, isPrivate: true);
    if (!locked) return widget.child;

    if (!_autoUnlockRequested) {
      _autoUnlockRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _requestUnlock(bookUrl);
      });
    }

    return Scaffold(
      key: const ValueKey('privateReadGateLocked'),
      body: SafeArea(
        child: PrivateLockedPage(
          title: '私密书籍',
          description: privacyLockedDescription(privacy, fallback: '验证后阅读本书'),
          actionText: privacyLockedActionText(privacy, fallback: '验证并阅读'),
          onAction: () => _requestUnlock(bookUrl),
        ),
      ),
    );
  }
}
