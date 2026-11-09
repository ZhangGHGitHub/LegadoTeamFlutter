// 隐私启动闸门（设置批9b）
//
// 语义对齐参考版 `PrivateAppStartGate.kt:64-137`：
// - 条件：enabled && hasPassword && verifyOnAppStart &&
//   !appStartVerified && !sessionUnlocked → 全屏锁；
// - 取消/退出 = 关闭应用（SystemNavigator.pop）；
// - 输错密码留在锁页重试；回车提交；连续提交防抖；
// - 凭据读取失败（fail-closed）只显示「无法读取隐私凭据」+ 重试，
//   绝不显示应用内容；
// - 异步加载期间只显示纯色占位，不得先闪现主页；
// - 应用回后台按 Notifier 的 unlockScope/宽限策略失效后，锁页重新出现。
//
// 挂载点：`app.dart` MaterialApp.builder 最内层（直接包住 Navigator child），
// 保证任何路由/弹层都位于闸门之后。
//
// 编写：全栈工程师（设置批9b） ｜ 2026-11-09
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../../providers/privacy/privacy_notifier.dart';

/// 应用启动隐私闸门
class PrivacyAppStartGate extends ConsumerStatefulWidget {
  const PrivacyAppStartGate({super.key, required this.child});

  /// 应用内容（Navigator 子树）；锁定/加载/凭据错误时不构建显示
  final Widget child;

  @override
  ConsumerState<PrivacyAppStartGate> createState() =>
      _PrivacyAppStartGateState();
}

class _PrivacyAppStartGateState extends ConsumerState<PrivacyAppStartGate>
    with WidgetsBindingObserver {
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocusNode = FocusNode();

  bool _submitting = false;
  bool _retrying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(privacyNotifierProvider.notifier).handleLifecycleState(state);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await ref
        .read(privacyNotifierProvider.notifier)
        .unlock(password);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!ok) _error = '密码错误';
    });
    if (ok) {
      _passwordController.clear();
      _passwordFocusNode.unfocus();
    }
  }

  Future<void> _retryCredentials() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    await ref.read(privacyNotifierProvider.notifier).retryCredentialCheck();
    if (!mounted) return;
    setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyNotifierProvider);

    Widget? overlay;
    if (!privacy.loaded) {
      // 加载未完成：纯色占位，绝不显示 child（避免主页/闪屏内容闪现）
      overlay = _SplashPlaceholder(key: const ValueKey('privacyGateSplash'));
    } else if (privacy.credentialError != null) {
      // fail-closed：凭据读取失败时只允许重试，不显示任何应用内容
      //（与 enabled 无关——读失败时无法判定是否启用了应用锁）
      overlay = _buildCredentialError(context);
    } else if (privacy.needsAppStartLock) {
      overlay = _buildLockScreen(context);
    }

    // 始终保留 child 挂载（Offstage 不显示/不参与语义/暂停动画），
    // 避免锁定与解锁之间重建 Navigator 导致路由栈与页面状态丢失
    // （后台宽限失效后重新上锁时尤为重要）。未锁定时不建 overlay，
    // Stack 只承载唯一的可见 child。
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: overlay != null,
          child: ExcludeSemantics(
            excluding: overlay != null,
            child: TickerMode(enabled: overlay == null, child: widget.child),
          ),
        ),
        if (overlay != null)
          Positioned.fill(child: _GateOverlayHost(child: overlay)),
      ],
    );
  }

  Widget _buildCredentialError(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _OpaqueGatePage(
      key: const ValueKey('privacyCredentialErrorPage'),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.lock_rounded, size: 48, color: scheme.error),
                const SizedBox(height: 16),
                Text(
                  '无法读取隐私凭据',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '为保护私密内容，凭据恢复前不会显示应用内容。请重试。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const ValueKey('privacyCredentialRetryButton'),
                  onPressed: _retrying ? null : _retryCredentials,
                  child: _retrying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('重试'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('privacyCredentialExitButton'),
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('退出应用'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockScreen(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _OpaqueGatePage(
      key: const ValueKey('privacyLockScreen'),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.lock_rounded, size: 56, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  '隐私空间',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '输入隐私密码以继续',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  key: const ValueKey('privacyUnlockPasswordField'),
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  autofocus: true,
                  obscureText: true,
                  enabled: !_submitting,
                  enableSuggestions: false,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: '隐私密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const ValueKey('privacyUnlockError'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: scheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('privacyUnlockButton'),
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('解锁'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('privacyExitAppButton'),
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('退出应用'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 闸门局部 Overlay 宿主
///
/// `MaterialApp.builder` 位于 Navigator 之外，闸门子树没有 Navigator 的
/// Overlay；锁页 TextField 的选区手柄与输入法浮层要求 Overlay 祖先。
/// 此处为闸门内容提供独立 Overlay（条目在 child 更新时重建），
/// 不依赖被 Offstage 的应用 Navigator。
class _GateOverlayHost extends StatefulWidget {
  const _GateOverlayHost({required this.child});

  final Widget child;

  @override
  State<_GateOverlayHost> createState() => _GateOverlayHostState();
}

class _GateOverlayHostState extends State<_GateOverlayHost> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    _entry = OverlayEntry(builder: (_) => widget.child);
  }

  @override
  void didUpdateWidget(covariant _GateOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry?.markNeedsBuild();
  }

  @override
  void dispose() {
    final entry = _entry;
    if (entry != null) {
      // Overlay 可能在宿主之前卸载；remove() 会先清空归属再安全返回
      entry.remove();
      entry.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_entry!]);
  }
}

/// 不透明闸门页（遮挡下层壁纸/内容）
class _OpaqueGatePage extends StatelessWidget {
  const _OpaqueGatePage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(child: child),
    );
  }
}

/// 加载占位：纯色背景 + 低透明度锁图标（无动画、无业务内容）
class _SplashPlaceholder extends StatelessWidget {
  const _SplashPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Icon(
          Symbols.lock_rounded,
          size: 48,
          color: scheme.primary.withValues(alpha: 0.25),
        ),
      ),
    );
  }
}
