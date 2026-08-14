import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/book_api.dart';

/// 登录 V2 动态状态协议对话框（对标 Kotlin SourceLoginDialogV2，上游 #402/#488）
///
/// rows 类型：text(需 key)/password/label/select(需 options)/button(需 action)；
/// action 返回命令键：state(对象→更新状态重渲染) / error(对象→键值错误) /
/// login(对象→登录成功) / close(布尔→关闭)。
///
/// 公共组件：书籍详情页与发现页共用登录入口（2026-08-14 发现页修复 R2，
/// 自 book_info_screen 提取）。— DeepSeek Harness + UI
class LoginV2Dialog extends StatefulWidget {
  final BookApi api;
  final String sourceJson;
  final String sourceName;

  const LoginV2Dialog({
    super.key,
    required this.api,
    required this.sourceJson,
    required this.sourceName,
  });

  @override
  State<LoginV2Dialog> createState() => LoginV2DialogState();
}

class LoginV2DialogState extends State<LoginV2Dialog> {
  String _stateJson = '{}';
  List<Map<String, dynamic>> _rows = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _selects = {};
  String? _error;
  bool _busy = false;
  /// action → 剩余秒数（对标 SourceLoginV2Delegate.countdownLeft）
  final Map<String, int> _countdownLeft = {};
  final Map<String, Timer> _countdownTimers = {};
  final Map<String, String> _buttonLabels = {};

  @override
  void initState() {
    super.initState();
    _loadUi();
  }

  @override
  void dispose() {
    for (final t in _countdownTimers.values) {
      t.cancel();
    }
    _countdownTimers.clear();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _startCountdown(String action, int seconds) {
    _countdownTimers.remove(action)?.cancel();
    _countdownLeft[action] = seconds;
    setState(() {});
    _countdownTimers[action] = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_countdownLeft[action] ?? 1) - 1;
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (left <= 0) {
        timer.cancel();
        _countdownTimers.remove(action);
        _countdownLeft.remove(action);
        setState(() {});
      } else {
        setState(() => _countdownLeft[action] = left);
      }
    });
  }

  /// 拉取动态 UI 描述（首次/收到 state 命令后重渲染）
  Future<void> _loadUi() async {
    setState(() => _busy = true);
    try {
      final json = await widget.api.loginUiV2(widget.sourceJson, _stateJson);
      final data = jsonDecode(json);
      final rows = (data is Map && data['rows'] is List)
          ? (data['rows'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      // 预填默认值（text/password → 控制器；select → 选中项）
      for (final row in rows) {
        final key = row['key']?.toString() ?? '';
        final value = row['value']?.toString() ?? '';
        final type = row['type']?.toString() ?? '';
        if (key.isEmpty) continue;
        if (type == 'select') {
          final options = (row['options'] is List)
              ? (row['options'] as List).map((e) => e.toString()).toList()
              : <String>[];
          _selects.putIfAbsent(
            key,
            () => value.isNotEmpty
                ? value
                : (options.isNotEmpty ? options.first : ''),
          );
        } else if (type == 'text' || type == 'password') {
          final ctrl = _controllers.putIfAbsent(key, TextEditingController.new);
          if (ctrl.text.isEmpty && value.isNotEmpty) ctrl.text = value;
        }
      }
      setState(() {
        _rows = rows;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// 收集表单数据（text/password 控制器 + select 选中项）
  Map<String, dynamic> _formJson() {
    final form = <String, dynamic>{};
    for (final e in _controllers.entries) {
      form[e.key] = e.value.text;
    }
    form.addAll(_selects);
    return form;
  }

  /// 执行 action 命令（button 行触发），处理返回命令键
  Future<void> _doAction(String action, {int? countdownSeconds}) async {
    if ((_countdownLeft[action] ?? 0) > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final input = jsonEncode({
        'action': action,
        'stateJson': _stateJson,
        'formJson': _formJson(),
      });
      final resJson =
          await widget.api.loginActionV2(widget.sourceJson, input);
      final res = jsonDecode(resJson);
      if (!mounted) return;
      if (res is! Map) {
        setState(() => _busy = false);
        return;
      }
      if (res['close'] == true || res['login'] is Map) {
        Navigator.pop(context, true);
        return;
      }
      if (res['error'] is Map) {
        final msgs = (res['error'] as Map)
            .values
            .map((v) => v.toString())
            .where((v) => v.isNotEmpty);
        setState(() {
          _error = msgs.isEmpty ? '登录失败' : msgs.join('\n');
          _busy = false;
        });
        return;
      }
      // 成功且配置了 countdown：启动按钮倒计时（对齐 Kotlin）
      if (countdownSeconds != null && countdownSeconds > 0) {
        _startCountdown(action, countdownSeconds);
      }
      if (res['state'] is Map) {
        _stateJson = jsonEncode(res['state']);
        setState(() => _busy = false);
        await _loadUi();
        return;
      }
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('登录 - ${widget.sourceName}'),
      content: SizedBox(
        width: 360,
        child: _busy && _rows.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    for (final row in _rows) _buildRow(row),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
      ],
    );
  }

  /// 按 rows 类型渲染单行（对齐 login_ui_v2.rs 协议）
  Widget _buildRow(Map<String, dynamic> row) {
    final type = row['type']?.toString() ?? '';
    final key = row['key']?.toString() ?? '';
    final name = row['name']?.toString() ?? '';
    final hint = row['hint']?.toString() ?? name;
    switch (type) {
      case 'label':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            name.isNotEmpty ? name : (row['value']?.toString() ?? ''),
          ),
        );
      case 'select':
        final options = (row['options'] is List)
            ? (row['options'] as List).map((e) => e.toString()).toList()
            : <String>[];
        final current = _selects[key] ?? '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DropdownButton<String>(
            value: options.contains(current)
                ? current
                : (options.isNotEmpty ? options.first : null),
            isExpanded: true,
            hint: Text(hint),
            items: [
              for (final o in options)
                DropdownMenuItem<String>(value: o, child: Text(o)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _selects[key] = v);
            },
          ),
        );
      case 'button':
        final action = row['action']?.toString() ?? '';
        final countdownRaw = row['countdown'];
        final countdown = countdownRaw is int
            ? countdownRaw
            : int.tryParse(countdownRaw?.toString() ?? '');
        if (action.isNotEmpty && name.isNotEmpty) {
          _buttonLabels.putIfAbsent(action, () => name);
        }
        final left = _countdownLeft[action] ?? 0;
        final label = left > 0
            ? '${_buttonLabels[action] ?? name} (${left}s)'
            : (_buttonLabels[action] ?? name);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: OutlinedButton(
            onPressed: _busy || action.isEmpty || left > 0
                ? null
                : () => _doAction(action, countdownSeconds: countdown),
            child: Text(label),
          ),
        );
      case 'password':
      case 'text':
      default:
        final ctrl = _controllers.putIfAbsent(key, TextEditingController.new);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: ctrl,
            obscureText: type == 'password',
            decoration: InputDecoration(
              labelText: name.isNotEmpty ? name : null,
              hintText: hint,
            ),
          ),
        );
    }
  }
}
