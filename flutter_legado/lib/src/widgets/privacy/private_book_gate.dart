// 媒体阅读器私密闸门（A3 补齐：漫画 / 听书 / 视频）
//
// 与文本阅读器 [PrivateReadGate] 同语义，差别只在「书」的来源：
// - 文本阅读器由 `ReaderNotifier.currentBook` 持有当前书，gate 直接读；
// - 漫画/听书/视频由路由参数携带（`bookUrl` 字符串 / `Book` 对象），
//   故本闸门显式接收 [bookUrl] 与可选的 [book]。
//
// 行为（对齐文本闸门，fail-closed）：
// - 策略/私密标记未就绪 → 只渲染带锁占位，**不组合**内容（防首帧明文）；
// - 未授权 → 全屏锁定页取代内容，内容组件根本不进入树（不加载章节、
//   不发起任何网络请求）；进入自动弹一次验证，取消退回上一页；
// - 离开页面（gate dispose / 换书）撤销 EveryTime 单本授权；
// - 总开关关闭或「打开书籍时验证」关闭时直接放行（不误锁）。
//
// 编写：全栈工程师（A3 私密闸门补齐） ｜ 2026-11-17
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../../providers/privacy/privacy_content_notifier.dart';
import '../../providers/privacy/privacy_notifier.dart';
import '../../services/privacy_content_service.dart';
import 'private_locked_page.dart';
import 'privacy_splash_placeholder.dart';
import 'privacy_unlock_dialog.dart';

/// 媒体阅读器（漫画/听书/视频）路由私密闸门
class PrivateBookGate extends ConsumerStatefulWidget {
  const PrivateBookGate({
    super.key,
    required this.bookUrl,
    required this.child,
    this.book,
    this.title = '私密内容',
    this.description = '验证后继续',
    this.actionText = '验证并继续',
  });

  /// 当前内容对应的书籍 URL（空 = 无书身份，无法判定，直接放行）
  final String bookUrl;

  /// 路由已携带的书籍对象（可为空：漫画路由只传 bookUrl）
  final Book? book;

  /// 授权后渲染的内容（阅读器/播放器）
  final Widget child;

  /// 锁定页标题
  final String title;

  /// 锁定页说明（无密码时由 [privacyLockedDescription] 覆盖）
  final String description;

  /// 锁定页动作文案（无密码时由 [privacyLockedActionText] 覆盖）
  final String actionText;

  @override
  ConsumerState<PrivateBookGate> createState() => _PrivateBookGateState();
}

class _PrivateBookGateState extends ConsumerState<PrivateBookGate> {
  String? _bookUrl;

  /// 每个目标只自动弹一次；换书后重置
  bool _autoUnlockRequested = false;

  /// dispose 阶段不能读 ref；提前捕获用于撤销授权
  PrivacyNotifier? _privacyNotifier;

  /// 本次判定使用的有效 URL（[bookUrl] 优先，其次路由书籍）
  String get _effectiveBookUrl {
    final direct = widget.bookUrl.trim();
    if (direct.isNotEmpty) return direct;
    return widget.book?.bookUrl.trim() ?? '';
  }

  @override
  void initState() {
    super.initState();
    _privacyNotifier = ref.read(privacyNotifierProvider.notifier);
  }

  @override
  void dispose() {
    // 离开页面即撤销本次授权（EveryTime；其它频率 no-op）。
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
      title: '验证后继续',
    );
    if (!mounted) return;
    if (unlocked) return;
    _exit();
  }

  /// 由快照与路由书籍解析判定用的书籍事实
  ///
  /// 快照书籍优先（含分组归属与最新私密标记）；其次路由对象；最后按
  /// 「URL 是否在私密 URL 集合」合成最小书籍（只影响单本授权判定）。
  Book? _resolveFactsBook(String bookUrl, PrivacyContentSnapshot content) {
    final fromSnapshot = content.booksByUrl[bookUrl];
    if (fromSnapshot != null) return fromSnapshot;
    final routed = widget.book;
    if (routed != null && routed.bookUrl == bookUrl) return routed;
    // 书架快照未含该书（如临时书/刚加入）：按私密 URL 集合合成最小事实，
    // 保证「单本标记」仍能拦截；未命中返回 null 交调用方 fail-open 放行。
    if (content.privateBookUrls.contains(bookUrl)) {
      return Book(bookUrl: bookUrl, isPrivate: true);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyNotifierProvider);
    final content = ref.watch(privacyContentProvider);
    final bookUrl = _effectiveBookUrl;

    // 换书：撤销上一本的 EveryTime 授权，并允许对新书再自动弹一次
    if (bookUrl != _bookUrl) {
      final previous = _bookUrl;
      _bookUrl = bookUrl;
      _autoUnlockRequested = false;
      if (previous != null && previous.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(privacyNotifierProvider.notifier).revokeBook(previous);
        });
      }
    }

    // 无书身份（如直链播放）：无法判定私密，立即放行，不做任何占位，
    // 避免给非书籍内容加一次无谓的加载闪烁。
    if (bookUrl.isEmpty) return widget.child;

    // 策略未就绪：不得先渲染内容（首帧明文）。
    if (!privacy.loaded) {
      return const PrivacySplashPlaceholder(
        key: ValueKey('privateBookGateSplash'),
      );
    }
    // 总开关关闭 / 关闭「打开书籍时验证」：与判定函数同口径，直接放行
    //（不必等标记快照，避免非私密用户首帧多一次 IO 等待）。
    if (!privacy.enabled || !privacy.verifyOnOpenBook) return widget.child;
    // 标记未就绪：先不组合内容（fail-closed 占位）
    if (!content.loaded) {
      return const PrivacySplashPlaceholder(
        key: ValueKey('privateBookGateSplash'),
      );
    }

    final factsBook = _resolveFactsBook(bookUrl, content);
    if (factsBook == null) return widget.child;
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
      key: const ValueKey('privateBookGateLocked'),
      body: SafeArea(
        child: PrivateLockedPage(
          title: widget.title,
          description: privacyLockedDescription(
            privacy,
            fallback: widget.description,
          ),
          actionText: privacyLockedActionText(
            privacy,
            fallback: widget.actionText,
          ),
          onAction: () => _requestUnlock(bookUrl),
        ),
      ),
    );
  }
}
