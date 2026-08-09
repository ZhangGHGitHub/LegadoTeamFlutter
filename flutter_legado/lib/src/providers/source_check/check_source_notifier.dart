import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../providers.dart';
import '../source/source_notifier.dart';

/// 单个书源的校验结果消息（对标原版列表项 checkSourceMessage 展示）
class CheckSourceMessage {
  /// 展示文本（如「校验成功 321ms」「搜索失败：超时」）
  final String text;

  /// 是否全部校验步骤通过
  final bool ok;

  const CheckSourceMessage({required this.text, required this.ok});
}

/// 书源校验会话状态
///
/// 对标原版 CheckSourceService + EventBus.CHECK_SOURCE/CHECK_SOURCE_DONE：
/// - 校验进行中：进度（done/total）+ 当前书源名持续回推
/// - 每个书源完成即写入 [messages]（列表项展示校验结果）
/// - 全部结束后对失效书源追加「失效」分组（对标 source.addGroup）
class CheckSourceState {
  /// 是否正在校验
  final bool checking;

  /// 是否已有过校验会话（控制结果消息展示生命周期）
  final bool hasSession;

  /// 已完成数量
  final int done;

  /// 总数量
  final int total;

  /// 当前正在校验的书源名
  final String currentName;

  /// 每个书源的校验消息（URL → 消息）
  final Map<String, CheckSourceMessage> messages;

  /// 最近一次会话是否被取消
  final bool cancelled;

  const CheckSourceState({
    this.checking = false,
    this.hasSession = false,
    this.done = 0,
    this.total = 0,
    this.currentName = '',
    this.messages = const {},
    this.cancelled = false,
  });

  /// 失效书源数量
  int get invalidCount => messages.values.where((m) => !m.ok).length;

  CheckSourceState copyWith({
    bool? checking,
    bool? hasSession,
    int? done,
    int? total,
    String? currentName,
    Map<String, CheckSourceMessage>? messages,
    bool? cancelled,
  }) {
    return CheckSourceState(
      checking: checking ?? this.checking,
      hasSession: hasSession ?? this.hasSession,
      done: done ?? this.done,
      total: total ?? this.total,
      currentName: currentName ?? this.currentName,
      messages: messages ?? this.messages,
      cancelled: cancelled ?? this.cancelled,
    );
  }
}

/// 书源校验 Notifier（接通契约 §2.3 checkSource* 三方法）
///
/// 职责边界（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 调用 BookApi.checkSourcesStream / cancelCheckSources → 更新 immutable State
/// - 进度 JSON 解析在本层完成（UI 层仅消费 [CheckSourceState]）
/// - 校验关键词持久化对齐原版 `CheckSource.keyword`
/// - [Task #40 | 2026-08-09] §5.13-2：校验配置（超时/各步开关）持久化
///   对齐原版 `CheckSource.putConfig`，启动校验时并入 configJson — Qoder
class CheckSourceNotifier extends Notifier<CheckSourceState> {
  /// 校验关键词持久化键（对标原版 CacheManager「checkSourceKeyword」语义）
  static const _keywordKey = 'check_source_keyword';

  /// 校验配置持久化键（超时 + 各步开关，对标原版 CheckSource.putConfig）
  static const _configKey = 'check_source_config';

  /// 原版默认校验关键词
  static const defaultKeyword = '我的';

  /// 默认单步超时（毫秒，对齐原版 CheckSource.timeout 默认 180000）
  static const defaultStepTimeoutMs = 180000;

  StreamSubscription<Map<String, dynamic>>? _subscription;

  @override
  CheckSourceState build() {
    ref.onDispose(() => _subscription?.cancel());
    return const CheckSourceState();
  }

  /// 读取持久化的校验关键词（无记录时返回原版默认值「我的」）
  Future<String> loadKeyword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keywordKey) ?? defaultKeyword;
  }

  /// 加载校验配置（合并后可直接作为 checkSource* 的 configJson）
  ///
  /// [Task #40 | 2026-08-09] §5.13-2 — Qoder
  /// 字段一一对应契约 §2.3 CheckerConfig：keyword / step_timeout_ms /
  /// check_search / check_toc / check_content / detect_captcha /
  /// detect_redirect；缺失/损坏项回落 Rust 侧默认值。
  Future<Map<String, dynamic>> loadCheckConfig() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> saved = const {};
    final raw = prefs.getString(_configKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) saved = decoded.cast<String, dynamic>();
      } catch (_) {
        // 损坏数据按默认配置处理
      }
    }
    return <String, dynamic>{
      'keyword': prefs.getString(_keywordKey) ?? defaultKeyword,
      'step_timeout_ms': (saved['step_timeout_ms'] is num)
          ? (saved['step_timeout_ms'] as num).toInt()
          : defaultStepTimeoutMs,
      'check_search': saved['check_search'] == false ? false : true,
      'check_toc': saved['check_toc'] == false ? false : true,
      'check_content': saved['check_content'] == false ? false : true,
      'detect_captcha': saved['detect_captcha'] == false ? false : true,
      'detect_redirect': saved['detect_redirect'] == false ? false : true,
    };
  }

  /// 保存校验配置（keyword 归入既有 [_keywordKey]，其余存 [_configKey]，
  /// 与既有持久化结构保持一致，下次校验时生效）
  ///
  /// [Task #40 | 2026-08-09] §5.13-2 — Qoder
  Future<void> saveCheckConfig(Map<String, dynamic> config) async {
    final prefs = await SharedPreferences.getInstance();
    // [fix Task#45 | 2026-08-09] 空关键词移除键而非写空串（Med2）：
    // 避免下次 loadKeyword 读到空串造成预填漂移；移除后
    // loadKeyword 仍回落默认关键词，既有返回契约不变 — Qoder
    final keyword = config['keyword'];
    if (keyword is String && keyword.isNotEmpty) {
      await prefs.setString(_keywordKey, keyword);
    } else {
      await prefs.remove(_keywordKey);
    }
    final body = Map<String, dynamic>.from(config)..remove('keyword');
    await prefs.setString(_configKey, jsonEncode(body));
  }

  /// 启动批量校验（对标原版 CheckSource.start）
  ///
  /// [sourceUrls] 待校验书源 URL 列表；[keyword] 校验关键词
  /// （非空时覆盖并持久化；空串回落持久化/默认关键词）；
  /// 超时与各步开关从持久化校验配置并入 configJson（Task #40 §5.13-2）。
  Future<void> start({
    required List<String> sourceUrls,
    String? keyword,
  }) async {
    if (state.checking || sourceUrls.isEmpty) return;
    final kw = (keyword ?? '').trim();
    // [Task #40 | 2026-08-09] §5.13-2：并入持久化校验配置（超时/各步开关，
    // 「校验书源配置」对话框保存后于下次校验生效）；非空关键词覆盖并持久化 — Qoder
    final config = await loadCheckConfig();
    if (kw.isNotEmpty) {
      config['keyword'] = kw;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keywordKey, kw);
    }
    _subscription?.cancel();
    state = state.copyWith(
      checking: true,
      hasSession: true,
      done: 0,
      total: sourceUrls.length,
      currentName: '',
      messages: const {},
      cancelled: false,
    );
    _subscription = ref
        .read(bookApiProvider)
        .checkSourcesStream(
          sourceUrls,
          configJson: jsonEncode(config),
        )
        .listen(
          _onProgress,
          onError: (Object _) {
            state = state.copyWith(checking: false, cancelled: true);
          },
          onDone: () {
            state = state.copyWith(checking: false);
          },
        );
  }

  /// 取消正在进行的校验（对标原版 CheckSource.stop）
  Future<void> cancel() async {
    if (!state.checking) return;
    state = state.copyWith(checking: false, cancelled: true);
    await ref.read(bookApiProvider).cancelCheckSources();
  }

  /// 清除校验结果消息（退出会话展示）
  void clearMessages() {
    state = const CheckSourceState();
  }

  /// 处理单条进度事件（字段见契约 §2.3 CheckProgress）
  void _onProgress(Map<String, dynamic> event) {
    final result = (event['result'] is Map)
        ? (event['result'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final url = (result['source_url'] ?? '').toString();
    final name = (event['source_name'] ?? '').toString();
    final index = (event['index'] is num)
        ? (event['index'] as num).toInt()
        : state.done;
    final total = (event['total'] is num)
        ? (event['total'] as num).toInt()
        : state.total;
    final isLast = event['is_last'] == true;

    final message = _buildMessage(result);
    final messages = Map<String, CheckSourceMessage>.from(state.messages);
    if (url.isNotEmpty) messages[url] = message;

    state = state.copyWith(
      done: index + 1,
      total: total,
      currentName: name,
      messages: messages,
      checking: !isLast,
    );

    // 全部完成：对失效书源追加「失效」分组（对标原版 addGroup 副作用）
    if (isLast) {
      final invalidUrls = messages.entries
          .where((e) => !e.value.ok)
          .map((e) => e.key)
          .toSet();
      if (invalidUrls.isNotEmpty) {
        ref
            .read(sourceNotifierProvider.notifier)
            .addGroupToUrls(invalidUrls, '失效');
      }
    }
  }

  /// 由 CheckResult 构造展示消息（对标原版 checkSourceMessage 语义）
  CheckSourceMessage _buildMessage(Map<String, dynamic> result) {
    final searchOk = result['search_ok'] == true;
    final tocOk = result['toc_ok'] == true;
    final contentOk = result['content_ok'] == true;
    final timeMs = (result['total_time_ms'] is num)
        ? (result['total_time_ms'] as num).toInt()
        : 0;
    final captcha = (result['captcha'] is Map)
        ? (result['captcha'] as Map).cast<String, dynamic>()
        : null;
    final captchaDetected = captcha?['detected'] == true;

    String text;
    bool ok;
    if (!searchOk) {
      text = '搜索失败${_errorSuffix(result['search_error'])}';
      ok = false;
    } else if (!tocOk) {
      text = '目录失效${_errorSuffix(result['toc_error'])}';
      ok = false;
    } else if (!contentOk) {
      text = '正文失效${_errorSuffix(result['content_error'])}';
      ok = false;
    } else {
      text = '校验成功';
      ok = true;
    }
    if (captchaDetected) text = '$text（疑似验证码拦截）';
    return CheckSourceMessage(text: '$text ${timeMs}ms', ok: ok);
  }

  String _errorSuffix(Object? error) {
    final text = (error ?? '').toString().trim();
    return text.isEmpty ? '' : '：$text';
  }
}

/// 书源校验 Notifier 全局 Provider
final checkSourceNotifierProvider =
    NotifierProvider<CheckSourceNotifier, CheckSourceState>(
      CheckSourceNotifier.new,
    );
