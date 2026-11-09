// 隐私设置页（设置批9b；审查回修 P2-3/P3）
//
// 语义对齐参考版 `PrivateConfigScreen.kt:65-205`：
// - 进入验证：enabled && hasPassword 时先要求输入当前密码（只校验、不授予
//   会话解锁），通过后才显示设置项；取消返回上一页；未设密码直接进入
//   （本身是设密码入口）；
// - 凭据组：启用私密功能（默认 false）、设置/修改密码、清除密码、
//   生物快捷解锁（批9d：需已有密码且平台可用；开启走系统认证并封装
//   32B 随机令牌，关闭清除信封与原生密钥）；
// - 验证时机组：进入私密分组（默认 true）、打开私密书籍（默认 true）、
//   启动应用（默认 false）、验证频率（EveryTime/AppSession/UntilBackground，
//   默认 AppSession）、离开后台宽限（0/30/120/180/300，默认 0，仅
//   UntilBackground 显示）；
// - 说明组：密码仅存本机、不随备份导出，忘记密码无法访问私密内容。
//
// 密码对话框：无密码时只填新密码+确认；已有密码时先验当前密码。改密失败
// 的旧密错误内联提示「密码错误」，其他失败提示重试。清除密码必须二次
// 确认并输入当前密码；保存中禁止返回/点击遮罩；清除成功后无条件关闭
// enabled（避免无凭据锁死）并提示「私密功能已关闭」。
//
// 编写：全栈工程师（设置批9b） ｜ 2026-11-09（审查回修同日）
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../providers/privacy/privacy_content_notifier.dart';
import '../providers/privacy/privacy_notifier.dart';
import '../providers/privacy/privacy_state.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/legado_app_bar.dart';

/// 隐私设置页（设置主页「隐私」入口）
class PrivacySettingsScreen extends ConsumerStatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  ConsumerState<PrivacySettingsScreen> createState() =>
      _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends ConsumerState<PrivacySettingsScreen>
    with WidgetsBindingObserver {
  final TextEditingController _verifyController = TextEditingController();
  bool _verified = false;
  bool _verifying = false;
  bool _biometricBusy = false;
  String? _verifyError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // [批9d] 进入设置页刷新生物状态：首次设密后无需重启即可开启开关
    final notifier = ref.read(privacyNotifierProvider.notifier);
    unawaited(
      notifier.ensureLoaded().then((_) {
        if (mounted) return notifier.refreshBiometricStatus();
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _verifyController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 认证/通道异常导致 busy 常驻时，回到前台允许重试
    if (_biometricBusy && mounted) {
      setState(() => _biometricBusy = false);
    }
    unawaited(
      ref.read(privacyNotifierProvider.notifier).refreshBiometricStatus(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyNotifierProvider);
    final hasReadError =
        privacy.policyError != null || privacy.credentialError != null;
    final needsVerification =
        !hasReadError && privacy.enabled && privacy.hasPassword && !_verified;

    Widget body;
    if (!privacy.loaded) {
      body = const Center(child: CircularProgressIndicator());
    } else if (hasReadError) {
      body = _buildReadError(context);
    } else if (needsVerification) {
      body = _buildVerifyGate(context);
    } else {
      body = _buildBody(context, privacy);
    }
    return AppScaffold(
      topBar: const LegadoAppBar(title: Text('隐私')),
      body: body,
    );
  }

  /// 策略/凭据读取失败：设置页也不展示可编辑项，只允许重试
  Widget _buildReadError(BuildContext context) {
    return Center(
      key: const ValueKey('privacySettingsReadError'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.lock_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            const Text('无法读取隐私设置，请重试'),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('privacySettingsReadRetry'),
              onPressed: () => unawaited(
                ref
                    .read(privacyNotifierProvider.notifier)
                    .retryCredentialCheck(),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 进入设置页前的密码验证（只校验，不授予会话解锁）
  Widget _buildVerifyGate(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('privacySettingsVerifyGate'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.lock_rounded, size: 48, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                '验证隐私密码',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '输入当前隐私密码以进入隐私设置',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                key: const ValueKey('privacySettingsVerifyField'),
                controller: _verifyController,
                obscureText: true,
                enabled: !_verifying,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _verify(),
                decoration: const InputDecoration(
                  labelText: '隐私密码',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_verifyError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _verifyError!,
                  key: const ValueKey('privacySettingsVerifyError'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: scheme.error),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('privacySettingsVerifyButton'),
                  onPressed: _verifying ? null : _verify,
                  child: _verifying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('验证'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('privacySettingsVerifyCancel'),
                onPressed: _verifying
                    ? null
                    : () => Navigator.of(context).maybePop(),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _verify() async {
    if (_verifying) return;
    final password = _verifyController.text;
    if (password.isEmpty) {
      setState(() => _verifyError = '请输入密码');
      return;
    }
    setState(() {
      _verifying = true;
      _verifyError = null;
    });
    final ok = await ref
        .read(privacyNotifierProvider.notifier)
        .verifyPasswordOnly(password);
    if (!mounted) return;
    setState(() {
      _verifying = false;
      if (ok) {
        _verified = true;
        _verifyController.clear();
      } else {
        _verifyError = '密码错误';
      }
    });
  }

  Widget _buildBody(BuildContext context, PrivacyState privacy) {
    final notifier = ref.read(privacyNotifierProvider.notifier);
    final markersUnavailable = ref
        .watch(privacyContentProvider)
        .markersUnavailable;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (markersUnavailable)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '私密标记暂不可用，当前按未锁定显示；请稍后重试或检查数据库。',
              key: const ValueKey('privacyMarkersUnavailable'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const IosSectionHeader('凭据'),
        IosGroup(
          children: [
            SettingSwitchRow(
              key: const ValueKey('privacyEnabledSwitch'),
              title: '启用私密功能',
              subtitle: '保护私密分组与私密书籍',
              value: privacy.enabled,
              onChanged: (value) =>
                  unawaited(_toggleEnabled(context, notifier, privacy, value)),
            ),
            IosListTile(
              key: const ValueKey('privacyPasswordRow'),
              title: privacy.hasPassword ? '修改密码' : '设置密码',
              subtitle: privacy.hasPassword ? '修改前需验证当前密码' : '设置后才能开启私密功能',
              value: privacy.hasPassword ? '已设置' : '未设置',
              onTap: () => unawaited(_editPassword(context, notifier, privacy)),
            ),
            IosListTile(
              key: const ValueKey('privacyClearPasswordRow'),
              title: '清除密码',
              subtitle: '需验证当前密码',
              enabled: privacy.hasPassword,
              onTap: privacy.hasPassword
                  ? () => unawaited(_clearPassword(context, notifier))
                  : null,
            ),
            SettingSwitchRow(
              key: const ValueKey('privacyBiometricSwitch'),
              title: '生物快捷解锁',
              subtitle: _biometricSubtitle(privacy),
              value: privacy.biometricConfigured,
              onChanged: _biometricSwitchEnabled(privacy)
                  ? (value) =>
                        unawaited(_toggleBiometric(context, notifier, value))
                  : null,
            ),
          ],
        ),
        const IosSectionHeader('验证时机'),
        IosGroup(
          children: [
            SettingSwitchRow(
              key: const ValueKey('privacyVerifyEnterGroupSwitch'),
              title: '进入私密分组时验证',
              value: privacy.verifyOnEnterGroup,
              onChanged: (value) => unawaited(
                _applyPolicy(
                  context,
                  () => notifier.setVerifyOnEnterGroup(value),
                ),
              ),
            ),
            SettingSwitchRow(
              key: const ValueKey('privacyVerifyOpenBookSwitch'),
              title: '打开私密书籍时验证',
              value: privacy.verifyOnOpenBook,
              onChanged: (value) => unawaited(
                _applyPolicy(
                  context,
                  () => notifier.setVerifyOnOpenBook(value),
                ),
              ),
            ),
            SettingSwitchRow(
              key: const ValueKey('privacyVerifyAppStartSwitch'),
              title: '启动应用时验证',
              subtitle: '下次启动应用时需要密码',
              value: privacy.verifyOnAppStart,
              onChanged: (value) => unawaited(
                _applyPolicy(
                  context,
                  () => notifier.setVerifyOnAppStart(value),
                ),
              ),
            ),
            IosListTile(
              key: const ValueKey('privacyUnlockScopeRow'),
              title: '验证频率',
              subtitle: '「每次进入」仅作用于私密分组与书籍',
              showChevron: false,
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<PrivacyUnlockScope>(
                  key: const ValueKey('privacyUnlockScopeDropdown'),
                  value: privacy.unlockScope,
                  isDense: true,
                  items: [
                    for (final scope in PrivacyUnlockScope.values)
                      DropdownMenuItem(value: scope, child: Text(scope.label)),
                  ],
                  onChanged: (scope) {
                    if (scope != null) {
                      unawaited(
                        _applyPolicy(
                          context,
                          () => notifier.setUnlockScope(scope),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
            if (privacy.unlockScope == PrivacyUnlockScope.untilBackground)
              IosListTile(
                key: const ValueKey('privacyBackgroundGraceRow'),
                title: '离开后宽限',
                subtitle: '离开应用超过该时长后重新验证',
                showChevron: false,
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const ValueKey('privacyBackgroundGraceDropdown'),
                    value: privacy.backgroundGraceSeconds,
                    isDense: true,
                    items: [
                      for (final seconds in kPrivacyBackgroundGraceOptions)
                        DropdownMenuItem(
                          value: seconds,
                          child: Text(privacyBackgroundGraceLabel(seconds)),
                        ),
                    ],
                    onChanged: (seconds) {
                      if (seconds != null) {
                        unawaited(
                          _applyPolicy(
                            context,
                            () => notifier.setBackgroundGraceSeconds(seconds),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
          ],
        ),
        const IosSectionFooter(
          '「应用会话内」在本次应用运行期间只验证一次，离开后台不失效；'
          '「离开后台后」离开超过宽限时间后才需要重新验证。',
        ),
        const IosSectionHeader('说明'),
        IosGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text(
                '隐私密码仅保存在本机，不随备份导出。启用私密功能后，'
                '忘记密码将无法访问私密内容。启动应用验证只在下次启动'
                '应用时触发；私密书籍与分组在书架、详情与阅读器中均按'
                '验证状态脱敏或放行。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 策略写入失败时回滚并提示（setter 返回 false）
  Future<void> _applyPolicy(
    BuildContext context,
    Future<bool> Function() action,
  ) async {
    final ok = await action();
    if (!ok && context.mounted) {
      _showMessage(context, '保存失败，请重试');
    }
  }

  Future<void> _toggleEnabled(
    BuildContext context,
    PrivacyNotifier notifier,
    PrivacyState privacy,
    bool value,
  ) async {
    if (!value) {
      final ok = await notifier.setEnabled(false);
      if (!ok && context.mounted) {
        _showMessage(context, '保存失败，请重试');
      }
      return;
    }
    if (!privacy.hasPassword) {
      final created = await showDialog<bool>(
        context: context,
        builder: (_) => PrivacyPasswordDialog(
          hasPassword: false,
          onSubmit: (newPassword, _) => notifier.setPassword(newPassword),
        ),
      );
      if (created != true || !mounted) return;
      // 用户刚设置了密码，等同已完成设置页验证，避免立即弹验证页
      setState(() => _verified = true);
    }
    final enabled = await notifier.setEnabled(true);
    if (!mounted) return;
    if (enabled) {
      setState(() => _verified = true);
    } else if (context.mounted) {
      final hasPassword = ref.read(privacyNotifierProvider).hasPassword;
      _showMessage(context, hasPassword ? '保存失败，请重试' : '请先设置隐私密码');
    }
  }

  Future<void> _editPassword(
    BuildContext context,
    PrivacyNotifier notifier,
    PrivacyState privacy,
  ) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => PrivacyPasswordDialog(
        hasPassword: privacy.hasPassword,
        onSubmit: (newPassword, oldPassword) =>
            notifier.setPassword(newPassword, oldPassword: oldPassword),
      ),
    );
    if (changed == true && context.mounted) {
      _showMessage(context, privacy.hasPassword ? '密码已修改' : '密码已设置');
    }
  }

  Future<void> _clearPassword(
    BuildContext context,
    PrivacyNotifier notifier,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PrivacyClearPasswordDialog(
        onClear: (password) => notifier.clearPassword(password: password),
      ),
    );
    if (result != true || !mounted || !context.mounted) return;
    final wasEnabled = ref.read(privacyNotifierProvider).enabled;
    // 清密成功后无条件关闭 enabled，不依赖对话框返回值/先前快照
    final disabled = await notifier.setEnabled(false);
    if (!mounted || !context.mounted) return;
    if (!disabled) {
      _showMessage(context, '保存失败，请重试');
      return;
    }
    _showMessage(context, wasEnabled ? '私密功能已关闭' : '密码已清除');
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// [批9d] 生物开关副标题：按密码/平台能力给出具体原因
  String _biometricSubtitle(PrivacyState privacy) {
    if (privacy.biometricConfigured) {
      final status = privacy.biometricStatus;
      if (status != null && !status.available) {
        return '已开启；当前生物识别不可用，可关闭';
      }
      return '已开启，解锁时可使用指纹或面容';
    }
    if (!privacy.hasPassword) return '请先设置隐私密码';
    final status = privacy.biometricStatus;
    if (status == null) return '正在读取生物识别状态';
    if (!status.available) return status.unavailableMessage;
    return '使用指纹或面容快速解锁';
  }

  /// [批9d] 生物开关是否可操作
  ///
  /// 关闭方向（已配置）始终可操作——平台能力暂时不可用/读取失败时，用户
  /// 仍需能主动清除信封与原生密钥；只有开启方向受密码与平台可用性限制。
  bool _biometricSwitchEnabled(PrivacyState privacy) {
    if (_biometricBusy) return false;
    if (privacy.biometricConfigured) return true;
    if (!privacy.hasPassword) return false;
    final status = privacy.biometricStatus;
    return status != null && status.available;
  }

  /// [批9d] 开关生物快捷解锁
  ///
  /// 开启：平台认证并封装新令牌 → Rust 写入；失败不点亮开关并提示原因。
  /// 关闭：Rust 清除三键 → 原生销毁密钥；失败保持开关并提示重试。
  Future<void> _toggleBiometric(
    BuildContext context,
    PrivacyNotifier notifier,
    bool value,
  ) async {
    if (_biometricBusy) return;
    setState(() => _biometricBusy = true);
    if (value) {
      final outcome = await notifier.enableBiometric();
      if (!mounted) return;
      setState(() => _biometricBusy = false);
      if (!outcome.isSuccess && context.mounted) {
        _showMessage(context, outcome.userMessage);
      }
    } else {
      final ok = await notifier.disableBiometric();
      if (!mounted) return;
      setState(() => _biometricBusy = false);
      if (!ok && context.mounted) {
        _showMessage(context, '关闭失败，请重试');
      }
    }
  }
}

/// 设置/修改隐私密码对话框
class PrivacyPasswordDialog extends StatefulWidget {
  const PrivacyPasswordDialog({
    super.key,
    required this.hasPassword,
    required this.onSubmit,
  });

  /// 是否已有密码（决定是否显示「当前密码」并校验旧密）
  final bool hasPassword;

  /// 提交回调（由设置页注入 Notifier，便于直接测试对话框）
  final Future<PrivacyPasswordChangeResult> Function(
    String newPassword,
    String? oldPassword,
  )
  onSubmit;

  @override
  State<PrivacyPasswordDialog> createState() => _PrivacyPasswordDialogState();
}

class _PrivacyPasswordDialogState extends State<PrivacyPasswordDialog> {
  final TextEditingController _oldController = TextEditingController();
  final TextEditingController _newController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _saving = false;
  String? _oldError;
  String? _error;

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final oldPassword = _oldController.text;
    final newPassword = _newController.text;
    final confirm = _confirmController.text;
    final trimmed = newPassword.trim();
    setState(() {
      _oldError = null;
      _error = null;
    });
    if (widget.hasPassword && oldPassword.isEmpty) {
      setState(() => _oldError = '请输入当前密码');
      return;
    }
    if (trimmed.isEmpty) {
      setState(() => _error = '新密码不能为空');
      return;
    }
    if (trimmed.runes.length > 128) {
      setState(() => _error = '新密码不能超过 128 个字符');
      return;
    }
    if (newPassword != confirm) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() => _saving = true);
    final result = await widget.onSubmit(
      newPassword,
      widget.hasPassword ? oldPassword : null,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    switch (result) {
      case PrivacyPasswordChangeResult.success:
        Navigator.of(context).pop(true);
      case PrivacyPasswordChangeResult.oldPasswordWrong:
        setState(() => _oldError = '密码错误');
      case PrivacyPasswordChangeResult.invalidPassword:
        setState(() => _error = '新密码不能为空或超过 128 个字符');
      case PrivacyPasswordChangeResult.failure:
        setState(() => _error = '设置密码失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('privacyPasswordDialog'),
      scrollable: true,
      title: Text(widget.hasPassword ? '修改密码' : '设置密码'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.hasPassword) ...[
              TextField(
                key: const ValueKey('privacyOldPasswordField'),
                controller: _oldController,
                obscureText: true,
                enabled: !_saving,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '当前密码'),
              ),
              if (_oldError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _oldError!,
                  key: const ValueKey('privacyOldPasswordError'),
                  style: TextStyle(color: scheme.error),
                ),
              ],
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('privacyNewPasswordField'),
              controller: _newController,
              obscureText: true,
              enabled: !_saving,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '新密码'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('privacyConfirmPasswordField'),
              controller: _confirmController,
              obscureText: true,
              enabled: !_saving,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: '确认新密码'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const ValueKey('privacyPasswordError'),
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('privacyPasswordSaveButton'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}

/// 清除隐私密码对话框（二次确认 + 当前密码；保存中禁止返回/遮罩关闭）
class PrivacyClearPasswordDialog extends StatefulWidget {
  const PrivacyClearPasswordDialog({super.key, required this.onClear});

  /// 验证并清除回调；区分密码错误与 API/写入失败
  final Future<PrivacyClearPasswordResult> Function(String password) onClear;

  @override
  State<PrivacyClearPasswordDialog> createState() =>
      _PrivacyClearPasswordDialogState();
}

class _PrivacyClearPasswordDialogState
    extends State<PrivacyClearPasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _clearing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _clear() async {
    if (_clearing) return;
    final password = _controller.text;
    if (password.isEmpty) {
      setState(() => _error = '请输入当前密码');
      return;
    }
    setState(() {
      _clearing = true;
      _error = null;
    });
    final result = await widget.onClear(password);
    if (!mounted) return;
    switch (result) {
      case PrivacyClearPasswordResult.success:
        Navigator.of(context).pop(true);
      case PrivacyClearPasswordResult.passwordWrong:
        setState(() {
          _clearing = false;
          _error = '密码错误';
        });
      case PrivacyClearPasswordResult.failure:
        setState(() {
          _clearing = false;
          _error = '清除失败，请重试';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_clearing,
      child: AlertDialog(
        key: const ValueKey('privacyClearPasswordDialog'),
        scrollable: true,
        title: const Text('清除密码'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('清除后私密内容将不再要求密码。确定清除吗？'),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('privacyClearPasswordField'),
                controller: _controller,
                obscureText: true,
                enabled: !_clearing,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _clear(),
                decoration: const InputDecoration(labelText: '当前密码'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('privacyClearPasswordError'),
                  style: TextStyle(color: scheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _clearing
                ? null
                : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('privacyClearPasswordConfirmButton'),
            onPressed: _clearing ? null : _clear,
            child: _clearing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('清除'),
          ),
        ],
      ),
    );
  }
}
