import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../screens/source_login_screen.dart';
import '../widgets/login_v2_dialog.dart';

/// 书源登录统一入口（发现页/详情页/书源管理共用）
///
/// 按 `loginUi` 是否 V2 动态协议分流（对齐原版 `SourceLoginActivity`：
/// hasLoginForm → 动态/表单对话框，否则 WebView/手动凭据页）：
/// - V2：`LoginV2Dialog`（rows 动态渲染，loginActionV2 驱动，登录结果由
///   Rust 侧自动落库 source_login_cache）
/// - 非 V2：`SourceLoginScreen`（手动 Token/Cookies/Headers，存
///   source_login_cache）
///
/// 返回是否登录成功（V2 对话框 login/close 或手动页保存完成）。
/// — DeepSeek Harness + UI（2026-08-14 发现页修复 R2）
Future<bool> showSourceLogin(
  BuildContext context,
  WidgetRef ref,
  BookSource source,
) async {
  final api = ref.read(bookApiProvider);
  final sourceJson = jsonEncode(source.toJson());
  var isV2 = false;
  try {
    isV2 = await api.isLoginUiV2(sourceJson);
  } catch (e) {
    debugPrint('loginUiV2 判定失败: $e');
  }
  if (!context.mounted) return false;

  if (isV2) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => LoginV2Dialog(
        api: api,
        sourceJson: sourceJson,
        sourceName: source.bookSourceName,
      ),
    );
    return ok == true;
  }

  // 旧版协议：手动凭据登录页（WebView 外链 + 手动 Cookie/Header/Token）
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => SourceLoginScreen(
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        loginUrl: source.loginUrl,
      ),
    ),
  );
  return saved == true;
}
