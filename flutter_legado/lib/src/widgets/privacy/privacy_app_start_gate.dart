// 隐私启动闸门（设置批9b；审查回修 P1-1/P2-1/P2-2/P2-4）
//
// 语义对齐参考版 `PrivateAppStartGate.kt:64-137`：
// - 条件：enabled && hasPassword && verifyOnAppStart &&
//   !appStartVerified && !sessionUnlocked → 全屏锁；
// - 取消/退出 = 关闭应用（SystemNavigator.pop）；
// - 输错密码留在锁页重试；回车提交；连续提交防抖；
// - 策略/凭据读取失败（fail-closed）只显示错误 + 重试，绝不显示应用内容；
// - 异步加载期间只显示纯色占位，不得先闪现主页；
// - 应用回后台按 Notifier 的 unlockScope/宽限策略失效后，锁页重新出现；
// - 锁页存在时消费系统返回键（gate 在 Navigator 之外，否则会 pop 隐藏路由）；
// - 隐藏内容用 ExcludeFocus 禁止焦点；锁页出现后显式聚焦密码框；
// - 不透明页按 viewInsets.bottom 抬升，避免软键盘遮挡解锁/退出按钮。
//
// 挂载点：`app.dart` MaterialApp.builder 最内层（直接包住 Navigator child），
// 保证任何路由/弹层都位于闸门之后。
//
// 编写：全栈工程师（设置批9b） ｜ 2026-11-09（审查回修同日）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../../providers/privacy/privacy_notifier.dart';
import '../../providers/privacy/privacy_state.dart';

/// 闸门是否应阻止应用交互（占位/读取错误/锁页）
///
/// 供启动闸门与根级返回键守卫共用。
bool privacyGateBlocksApp(PrivacyState privacy) =>
    !privacy.loaded ||
    privacy.policyError != null ||
    privacy.credentialError != null ||
    privacy.needsAppStartLock;

/// 根级返回键守卫
///
/// `WidgetsBinding.handlePopRoute` 按 observer 注册顺序派发，
/// `WidgetsApp` 自身在 MaterialApp 构建时先注册并直接
/// `navigator.maybePop()`；闸门位于 builder 内、注册更晚，单靠闸门的
/// didPopRoute 无法阻止隐藏路由被 pop。因此在 LegadoApp（MaterialApp
/// 之上）用本守卫提前注册，锁页存在时返回 true 消费返回键。
class PrivacyBackGuard with WidgetsBindingObserver {
  PrivacyBackGuard(this.readPrivacy);

  /// 读取当前隐私状态（由宿主注入，避免守卫持有 WidgetRef）
  final PrivacyState Function() readPrivacy;

  @override
  Future<bool> didPopRoute() async => privacyGateBlocksApp(readPrivacy());
}

/// 应用启动隐私闸门
class PrivacyAppStartGate extends ConsumerStatefulWidget {
  const PrivacyAppStartGate({super.key, required this.child});

  /// 应用内容（Navigator 子树）；锁定/加载/读取错误时不显示
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
  bool _focusScheduled = false;
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

  /// 锁页/占位/错误页存在时消费系统返回键
  ///
  /// 闸门在 MaterialApp.builder 中位于 Navigator 之外，返回键默认会
  /// pop 被 Offstage 的应用路由；这里返回 true 阻止穿透。
  @override
  Future<bool> didPopRoute() async {
    return privacyGateBlocksApp(ref.read(privacyNotifierProvider));
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

  Future<void> _retryLoad() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    await ref.read(privacyNotifierProvider.notifier).retryCredentialCheck();
    if (!mounted) return;
    setState(() => _retrying = false);
  }

  /// [批9d] 启动闸门生物快捷解锁：成功置会话/启动标记；取消/失败留在锁页
  Future<void> _submitBiometric() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final outcome = await ref
        .read(privacyNotifierProvider.notifier)
        .unlockWithBiometric(appStart: true);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!outcome.isSuccess) _error = outcome.userMessage;
    });
    if (outcome.isSuccess) {
      _passwordController.clear();
      _passwordFocusNode.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyNotifierProvider);
    final lockVisible =
        privacy.loaded &&
        privacy.policyError == null &&
        privacy.credentialError == null &&
        privacy.needsAppStartLock;

    // 锁页出现后 post-frame 显式聚焦密码框；隐藏子树由 ExcludeFocus
    // 禁止焦点，避免 Offstage 下的 autofocus 抢走输入焦点。
    if (!lockVisible) {
      _focusScheduled = false;
    } else if (!_focusScheduled) {
      _focusScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = ref.read(privacyNotifierProvider);
        if (current.needsAppStartLock &&
            current.policyError == null &&
            current.credentialError == null) {
          _passwordFocusNode.requestFocus();
        }
      });
    }

    Widget? overlay;
    if (!privacy.loaded) {
      // 加载未完成：纯色占位，绝不显示 child（避免主页/闪屏内容闪现）
      overlay = _SplashPlaceholder(key: const ValueKey('privacyGateSplash'));
    } else if (privacy.policyError != null) {
      // fail-closed：策略读取失败时只允许重试，不显示任何应用内容
      overlay = _buildErrorPage(
        context,
        pageKey: const ValueKey('privacyPolicyErrorPage'),
        retryKey: const ValueKey('privacyPolicyRetryButton'),
        exitKey: const ValueKey('privacyPolicyExitButton'),
        title: '无法读取隐私设置',
        description: '为保护私密内容，隐私设置恢复前不会显示应用内容。请重试。',
      );
    } else if (privacy.credentialError != null) {
      // fail-closed：凭据读取失败时只允许重试，不显示任何应用内容
      //（与 enabled 无关——读失败时无法判定是否启用了应用锁）
      overlay = _buildErrorPage(
        context,
        pageKey: const ValueKey('privacyCredentialErrorPage'),
        retryKey: const ValueKey('privacyCredentialRetryButton'),
        exitKey: const ValueKey('privacyCredentialExitButton'),
        title: '无法读取隐私凭据',
        description: '为保护私密内容，凭据恢复前不会显示应用内容。请重试。',
      );
    } else if (privacy.needsAppStartLock) {
      overlay = _buildLockScreen(context, privacy);
    }

    // 始终保留 child 挂载（Offstage 不显示/不参与语义/暂停动画），
    // 避免锁定与解锁之间重建 Navigator 导致路由栈与页面状态丢失
    //（后台宽限失效后重新上锁时尤为重要）。未锁定时不建 overlay，
    // Stack 只承载唯一的可见 child。
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: overlay != null,
          child: ExcludeFocus(
            excluding: overlay != null,
            child: ExcludeSemantics(
              excluding: overlay != null,
              child: TickerMode(enabled: overlay == null, child: widget.child),
            ),
          ),
        ),
        if (overlay != null)
          Positioned.fill(child: _GateOverlayHost(child: overlay)),
      ],
    );
  }

  Widget _buildErrorPage(
    BuildContext context, {
    required Key pageKey,
    required Key retryKey,
    required Key exitKey,
    required String title,
    required String description,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return _OpaqueGatePage(
      key: pageKey,
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
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: retryKey,
                  onPressed: _retrying ? null : _retryLoad,
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
                  key: exitKey,
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

  Widget _buildLockScreen(BuildContext context, PrivacyState privacy) {
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
                if (privacy.biometricUsable)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('privacyLockBiometricButton'),
                      onPressed: _submitting ? null : _submitBiometric,
                      icon: const Icon(Symbols.fingerprint_rounded, size: 18),
                      label: const Text('使用生物识别'),
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

/// 不透明闸门页（遮挡下层壁纸/内容；软键盘弹起时抬升内容）
class _OpaqueGatePage extends StatelessWidget {
  const _OpaqueGatePage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: AnimatedPadding(
        key: const ValueKey('privacyGateKeyboardPadding'),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SafeArea(child: child),
      ),
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
