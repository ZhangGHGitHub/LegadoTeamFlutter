import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../l10n/app_strings.dart';
import '../models/backup_inspect_info.dart';
import '../models/book.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_theme_notifier.dart';
import '../providers/reader/reader_top_bar_actions_notifier.dart';
import '../providers/sync/sync_notifier.dart';
import '../providers/theme/theme_colors_notifier.dart';
import '../providers/theme/theme_notifier.dart';
import '../routes.dart';
import '../services/crash_log_service.dart';
import '../services/local_backup_service.dart';
import '../services/restore_ignore_prefs.dart';
import '../services/server_service.dart';
import '../services/settings_service.dart';
import '../services/webdav_server_service.dart';
import '../utils/error_message.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/restore_ignore_dialog.dart';

/// WebDAV 连接测试状态（差异清单 C7「测试配置」行）
///
/// — full-stack-engineer + UI ｜ 2026-09-10
enum _WebDavTestStatus { notTested, testing, success, failed }

/// 备份密码错误码前缀（契约 §2.11 批17a）
///
/// 后端以 `LegadoError::Internal` 返回，Display 形如
/// `Internal error: BACKUP_PASSWORD_INVALID: ...`，Dart 侧必须按「包含」
/// 前缀识别，不能按字符串起始位置判断。
const String _kBackupPasswordRequired = 'BACKUP_PASSWORD_REQUIRED';
const String _kBackupPasswordInvalid = 'BACKUP_PASSWORD_INVALID';
const String _kBackupEncryptedContentCorrupt = 'BACKUP_ENCRYPTED_CONTENT_CORRUPT';

/// 进度框执行结果（三态，批17c P3-6）
///
/// 旧实现忙时返回 `null`，与「已执行且无异常」不可区分——恢复会被误报
/// 成功。`ran=false` 表示本次没有执行任务（另一操作进行中 / 页面已销毁），
/// 调用方必须中止后续步骤且不提示成功。
class _ProgressResult {
  const _ProgressResult.busy()
      : ran = false,
        error = null;

  const _ProgressResult.executed(this.error) : ran = true;

  /// 是否实际执行了任务
  final bool ran;

  /// 捕获的异常（仅 `captureError: true` 且任务抛出时非 null）
  final Object? error;
}

/// 判定备份文件是不是原版 zip 备份（扩展名快判 + **文件魔数**）
///
/// [批17c P3-5] 只看扩展名会把「zip 改名 `.json`」误判为自有 JSON 备份：
/// 不探测密码 → 直接恢复 → 后端因加密内容要求密码 → 用户看不到密码框。
/// 魔数口径与 Rust `is_zip_backup` 完全一致（`PK\x03\x04` 普通条目 /
/// `PK\x05\x06` 空 zip）；读取失败（文件不存在/权限）按非 zip 处理，
/// 由后续恢复流程给出统一错误。
///
/// 同步读 4 字节（不整文件入内存）：文件打开/读取是本地小操作，避免把
/// 「选择备份文件」链路的异步时序复杂化（恢复链其余步骤均为异步）。
bool _isZipBackupFile(String path) {
  if (path.toLowerCase().endsWith('.zip')) return true;
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final head = file.readSync(4);
    if (head.length < 4) return false;
    return head[0] == 0x50 &&
        head[1] == 0x4B &&
        ((head[2] == 0x03 && head[3] == 0x04) ||
            (head[2] == 0x05 && head[3] == 0x06));
  } catch (_) {
    return false;
  } finally {
    try {
      file?.closeSync();
    } catch (_) {
      // 关闭失败不影响判定结果
    }
  }
}

/// 备份与恢复（对齐 BackupConfigFragment + pref_config_backup.xml）
///
/// 结构：
/// 1. WebDav 设置：地址/账号/密码/子目录/设备名/同步进度（含增强）
/// 2. 备份与恢复：备份路径/备份/恢复/恢复忽略/仅保留最新/自动检查
///
/// 顶栏菜单对标 backup_restore.xml：帮助、导入旧版数据、日志。
/// 恢复项长按 → 本地恢复（对标 web_dav_restore.onLongClick）。
///
/// 路由仍为 [AppRoutes.webdavSettings]（历史路径兼容）。
///
/// — UI 子代理 + UI ｜ 2026-08-13
class WebDavSettingsScreen extends ConsumerStatefulWidget {
  const WebDavSettingsScreen({super.key});

  @override
  ConsumerState<WebDavSettingsScreen> createState() =>
      _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends ConsumerState<WebDavSettingsScreen> {
  SettingsService get _settings => ref.read(settingsProvider);

  String _url = '';
  String _user = '';
  String _pass = '';
  String _dir = '/legado/';
  String _device = '';
  String _backupPath = '';
  bool _onlyLatestBackup = true;
  bool _autoCheckNewBackup = true;
  bool _busy = false;

  // ===== WebDAV 备份族（批40，对齐原版 PreferKey/AppConfig）=====

  /// WebDAV 备份保留数量（0 = 不清理）
  int _backupKeepCount = 0;

  /// 导入后自动上传本地书（默认关）
  bool _bookAutoUpload = false;

  /// 自动备份开关/上传 WebDAV/间隔天数
  bool _autoBackup = true;
  bool _autoBackupWebDav = true;
  int _autoBackupIntervalDays = 1;

  /// 「测试配置」行连接测试状态（差异清单 C7）
  _WebDavTestStatus _testStatus = _WebDavTestStatus.notTested;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  /// 加载页面配置
  ///
  /// 批8：WebDAV 账号三要素由 `SyncNotifier.loadConfig()` 从 DB `servers` 表
  /// 读取（首次调用顺带完成旧偏好一次性迁移）；子目录/设备名与备份开关
  /// 仍读偏好。
  ///
  /// 批8 审查回修 P2-5：DB 读取异常不静默——提示中文 SnackBar，页面保持
  /// 默认值（不崩溃、不吞错）。
  Future<void> _loadAll() async {
    try {
      final notifier = ref.read(syncNotifierProvider.notifier);
      await notifier.loadConfig();
      final state = ref.read(syncNotifierProvider);
      final path = await CrashLogService.instance.getBackupPath() ?? '';
      final onlyLatest = await _settings.getBoolPref(
        PrefKeys.onlyLatestBackup,
        defaultValue: true,
      );
      final autoCheck = await _settings.getBoolPref(
        PrefKeys.autoCheckNewBackup,
        defaultValue: true,
      );
      // 批40：WebDAV 备份族偏好（键名对齐原版，默认值同 AppConfig）
      final keepCount = await _settings.getWebDavBackupKeepCount();
      final bookAutoUpload = await _settings.getWebDavBookAutoUpload();
      final autoBackup = await _settings.getAutoBackup();
      final autoBackupWebDav = await _settings.getAutoBackupWebDav();
      final autoBackupDays = await _settings.getAutoBackupIntervalDays();
      if (!mounted) return;
      setState(() {
        _url = state.webDavUrl;
        _user = state.webDavUsername;
        _pass = state.webDavPassword;
        _dir = state.remoteDir;
        _device = state.deviceName;
        _backupPath = path;
        _onlyLatestBackup = onlyLatest;
        _autoCheckNewBackup = autoCheck;
        _backupKeepCount = keepCount;
        _bookAutoUpload = bookAutoUpload;
        _autoBackup = autoBackup;
        _autoBackupWebDav = autoBackupWebDav;
        _autoBackupIntervalDays = autoBackupDays;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('加载 WebDAV 配置失败：$e')),
      );
    }
  }

  /// 保存 WebDAV 配置
  ///
  /// 批8 审查回修 P2-5/P2-6：落库失败以中文 SnackBar 提示（`saveConfig`
  /// 先落库后改状态，失败时状态不前进）。
  Future<void> _saveWebDav() async {
    try {
      await ref.read(syncNotifierProvider.notifier).saveConfig(
            _url,
            _user,
            _pass,
            _dir,
            deviceName: _device,
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存 WebDAV 配置失败：$e')),
      );
    }
  }

  Future<void> _editTextPref({
    required String title,
    required String initial,
    required ValueChanged<String> onSaved,
    bool obscure = false,
    String? hint,
  }) async {
    // 批40 回修 P3-9：controller 由对话框自身持有并在 dispose 中释放
    // （直接在 showDialog 返回后 dispose 会在退场动画重建 TextField 时
    // 触发「used after being disposed」）。
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _TextInputDialog(
        title: title,
        initial: initial,
        hint: hint,
        obscure: obscure,
      ),
    );
    if (result == null) return;
    setState(() => onSaved(result));
    await _saveWebDav();
  }

  /// 编辑「WebDAV 备份保留数量」（批40）
  ///
  /// 对齐原版 `EditTextPreference(key=webDavBackupKeepCount)`：字符串偏好，
  /// 0 = 不清理；非法/负数/超上限（1000，批40 回修 P3-3）在对话框关闭后
  /// 统一提示且不落盘。
  Future<void> _editBackupKeepCount() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => const _TextInputDialog(
        title: 'WebDAV 备份保留数量',
        description: '上传成功后保留最近几份备份；0 表示不自动清理（默认）。',
        hint: '0',
        keyboardType: TextInputType.number,
      ),
    );
    if (result == null || !mounted) return;
    final parsed = int.tryParse(result.trim());
    if (parsed == null ||
        parsed < 0 ||
        parsed > SettingsService.webDavBackupKeepCountMax) {
      _showSnack('请输入 0~${SettingsService.webDavBackupKeepCountMax} 的整数');
      return;
    }
    setState(() => _backupKeepCount = parsed);
    await _settings.setWebDavBackupKeepCount(parsed);
  }

  /// 自动备份行副标题（对齐原版 updateAutoBackupSummary）
  String _autoBackupSummary() {
    if (!_autoBackup) return '已关闭';
    final destination = _autoBackupWebDav ? '本地 + WebDAV' : '仅本地';
    return '每 $_autoBackupIntervalDays 天自动备份（$destination）';
  }

  /// 自动备份配置对话框（对齐原版 configureAutoBackup）
  ///
  /// 三个偏好一次写入：`autoBackup` / `autoBackupWebDav` /
  /// `autoBackupIntervalDays`；间隔天数校验 ≥1（原版同样拒绝 0/非法值）。
  ///
  /// 批40 回修 P3-9：controller 由 [_AutoBackupDialog] 自身持有并释放。
  Future<void> _configureAutoBackup() async {
    final saved = await showDialog<_AutoBackupConfig>(
      context: context,
      builder: (ctx) => _AutoBackupDialog(
        enabled: _autoBackup,
        webDav: _autoBackupWebDav,
        intervalDays: _autoBackupIntervalDays,
      ),
    );
    if (saved == null || !mounted) return;

    setState(() {
      _autoBackup = saved.enabled;
      _autoBackupWebDav = saved.webDav;
      _autoBackupIntervalDays = saved.intervalDays;
    });
    await Future.wait([
      _settings.setAutoBackup(saved.enabled),
      _settings.setAutoBackupWebDav(saved.webDav),
      _settings.setAutoBackupIntervalDays(saved.intervalDays),
    ]);
  }

  Future<void> _pickBackupPath() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择备份路径',
    );
    if (picked == null) return;
    await CrashLogService.instance.setBackupPath(picked);
    if (!mounted) return;
    setState(() => _backupPath = picked);
  }

  /// 本地备份（批40：本地 JSON 备份 + 上传本次备份文件到 WebDAV）
  ///
  /// 对齐原版 `web_dav_backup`（`backupLocked(uploadWebDav=true)`）：
  /// - 上传的是**本次备份文件本身**（不再走 `webdavFullSync` 上传
  ///   bookshelf.json/sources.json，那属「恢复」短按入口）；
  /// - 与自动备份共用 `LocalBackupService` 互斥锁：已有备份在执行时
  ///   提示稍候，不排队；
  /// - 上传失败不影响本地备份成功，SnackBar 分开提示；
  /// - 未配置 WebDAV 时仅本地备份（与既有行为一致）。
  Future<void> _doLocalBackup() async {
    await _runWithProgress('备份中…', () async {
      var dirPath = _backupPath;
      if (dirPath.isEmpty) {
        final picked = await FilePicker.platform.getDirectoryPath();
        if (picked == null) return;
        dirPath = picked;
        await CrashLogService.instance.setBackupPath(dirPath);
        if (mounted) setState(() => _backupPath = dirPath);
      }
      final api = ref.read(bookApiProvider);
      final result = await LocalBackupService.instance.runExclusive(
        () => LocalBackupService.instance.createBackup(
          api: api,
          settings: _settings,
          dirPath: dirPath,
          uploadWebDav: true,
        ),
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (result == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('正在备份或恢复，请稍候')),
        );
        return;
      }
      if (result.uploadError != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '${AppStrings.backupSuccess}：${result.filePath}\n'
              'WebDAV 上传失败：${errorMessage(result.uploadError!)}',
            ),
          ),
        );
        return;
      }
      final upload = result.upload;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            upload == null
                ? '${AppStrings.backupSuccess}：${result.filePath}'
                : '${AppStrings.backupSuccess}：${result.filePath}\n'
                    '已上传 WebDAV：${upload.remoteFileName}',
          ),
        ),
      );
    });
  }

  /// WebDAV 短按「恢复」确认（[批7c] 文案按真实数据方向区分入口）
  ///
  /// 短按并不从远端覆盖本地：`restoreFromWebDav` 先经 `webdavFullSync`
  /// 上传本地书架覆盖远端 `bookshelf.json`，再只消费远端 `sources` 回写
  /// 书源，本地阅读进度不受影响。确认文案必须如实反映该方向，避免用户
  /// 误以为会覆盖本地进度。
  Future<bool> _confirmWebDavSync() {
    return showConfirmDialog(
      context,
      title: '确认同步吗？',
      content: '将上传本地书架并覆盖远端备份（bookshelf.json），同时回写远端书源；'
          '不会覆盖本地阅读进度。如需从备份覆盖本地，请使用长按本地恢复。',
      confirmText: '同步',
      cancelText: '取消',
      isDestructive: true,
    );
  }

  /// 本地恢复确认（长按「恢复」= 用本地备份覆盖书架）
  ///
  /// [批7b] 恢复会把备份中的阅读进度与书籍信息写回库内，覆盖书架中
  /// 已有书籍的当前进度。确认后执行原恢复链；取消返回 false，调用方
  /// 直接中止，不触发任何恢复动作。
  Future<bool> _confirmLocalRestore() {
    return showConfirmDialog(
      context,
      title: '确认恢复吗？',
      content: '恢复书架会覆盖现有书架，包括已有书籍的阅读进度与书籍信息。确定继续吗？',
      confirmText: '恢复',
      cancelText: '取消',
      isDestructive: true,
    );
  }

  /// 默认恢复：优先 WebDAV；失败或未配置则提示（长按走本地）
  Future<void> _doRestore() async {
    final sync = ref.read(syncNotifierProvider);
    if (sync.isConfigured) {
      if (!await _confirmWebDavSync()) return;
      if (!mounted) return;
      await _runWithProgress('恢复中…', () async {
        // 批40 回修 P2-2：恢复与备份/自动备份共用进程内互斥（恢复会写库，
        // 与自动备份并发会互相覆盖）；已有备份执行中直接提示稍候。
        final message = await LocalBackupService.instance.runExclusiveRestore(
          () => ref.read(syncNotifierProvider.notifier).restoreFromWebDav(),
        );
        if (!mounted) return;
        if (message == null) {
          _showSnack('正在备份或恢复，请稍候');
          return;
        }
        await _reloadPrefsAfterRestore();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message.isEmpty ? '恢复完成' : message)),
        );
      });
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('未配置 WebDAV，请长按「恢复」从本地恢复')),
    );
  }

  /// 本地恢复（长按「恢复」）
  ///
  /// 流程：选文件 → zip 忽略项提示 → 覆盖确认 → （zip）只读探测是否需要
  /// 备份密码 → 需要则密码框 → 恢复。
  ///
  /// [批17b] 原版加密 zip 备份：`backupInspect` 判定 `passwordRequired`
  /// 后弹「输入备份密码」；密码只经 FFI 传给 Rust，不写日志/不落盘/
  /// 不进 prefs，也不自动复用本机 `localPassword`。取消密码框即中止，
  /// 不调用 restore（零写入）。JSON 备份不探测、不弹框，走原流程。
  Future<void> _doRestoreFromLocal() async {
    // [批9] 本地恢复支持两种容器：我方单文件 JSON 备份与原版多文件 zip 备份
    // （Rust 侧按文件魔数 PK\x03\x04 分流，FFI 签名不变）。原版 zip 内的
    // 偏好快照 config.xml 与媒体目录不恢复（见 webdav 恢复登记项）。
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择本地备份文件（支持 .json 备份与 .zip 原版备份）',
      type: FileType.custom,
      allowedExtensions: ['json', 'zip'],
    );
    final backupPath = result?.files.single.path;
    if (backupPath == null) return;
    if (!mounted) return;
    // 批17c P3-5：容器按**文件魔数**判定（`.json` 命名的加密 zip 也要弹
    // 密码框）；扩展名只是快判。判定口径与 Rust `is_zip_backup` 一致。
    final isZip = _isZipBackupFile(backupPath);
    if (!mounted) return;
    // [批9 回修 P2-9] zip 备份由 Rust 按原版多文件语义整包恢复，不读取
    // 恢复忽略项；用户已配置忽略项时必须明示「将按备份内容恢复」，
    // 避免忽略项对 zip 静默失效（纯提示，不改变恢复行为）。
    if (isZip) {
      final ignore = await _settings.getRestoreIgnoreConfig();
      if (!mounted) return;
      if (ignore.values.any((enabled) => enabled)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('zip 备份暂不支持忽略项过滤（将按备份内容恢复）'),
          ),
        );
      }
    }
    // [批7c P2-8] 先选文件、后确认：用户看到实际选中的备份再决定是否覆盖，
    // 取消选择时不弹确认框。
    if (!await _confirmLocalRestore()) return;
    if (!mounted) return;

    // [批17b] 仅 zip 容器探测密码；探测只读，不写库、不落盘
    BackupInspectInfo? inspect;
    if (isZip) {
      final api = ref.read(bookApiProvider);
      final inspectResult = await _runWithProgress(
        '检查备份…',
        () async {
          inspect = await api.backupInspect(backupPath);
        },
        captureError: true,
      );
      if (!mounted) return;
      if (!inspectResult.ran) return;
      if (inspectResult.error != null) {
        _showSnack('检查备份失败：${errorMessage(inspectResult.error!)}');
        return;
      }
      if (inspect?.passwordRequired ?? false) {
        await _restoreWithPasswordLoop(
          backupPath,
          inspect!,
          isZipContainer: isZip,
        );
        return;
      }
    }

    var restoreBusy = false;
    final restoreResult = await _runWithProgress(
      '恢复中…',
      () async {
        restoreBusy = !await _performLocalRestore(
          backupPath,
          password: null,
          isZipContainer: isZip,
        );
      },
      captureError: true,
    );
    if (!mounted) return;
    // 忙（另一操作进行中）：不提示成功、不改任何状态
    if (!restoreResult.ran) return;
    // 备份/恢复互斥拒绝（批40 回修 P2-2）：提示稍候，不提示成功
    if (restoreBusy) {
      _showSnack('正在备份或恢复，请稍候');
      return;
    }
    if (restoreResult.error == null) {
      _showSnack(AppStrings.restoreSuccess);
      return;
    }
    final error = restoreResult.error!;
    // 防御：探测称无需密码但后端仍要求（如探测与恢复之间文件被替换）
    if (isZip && _hasBackupErrorPrefix(error, _kBackupPasswordRequired)) {
      await _restoreWithPasswordLoop(
        backupPath,
        inspect ??
            const BackupInspectInfo(
              format: BackupFormat.zip,
              passwordRequired: true,
              passwordProtectedFiles: [],
            ),
        isZipContainer: true,
      );
      return;
    }
    _showRestoreFailure(error);
  }

  /// 执行本地恢复全链（偏好回填 + 业务表恢复 + 页面刷新）
  ///
  /// [password] 仅对原版 zip 备份生效；JSON 备份传 null。
  /// [isZipContainer] 容器判定结果（调用方已按文件魔数算好）；缺省时此处
  /// 现算。zip 容器**不做** JSON 偏好/账号回读（zip 备份没有 `appPrefs`
  /// 段，按 `.json` 扩展名硬读会把压缩字节当 JSON 解析——`.json` 命名的
  /// zip 会在这里抛异常或卡住恢复链）。
  ///
  /// 批40 回修 P2-2：整条恢复链跑在 `LocalBackupService.runExclusiveRestore`
  /// 内（与手动/自动备份共用互斥）；返回 false = 已有备份/恢复执行中，
  /// 本次未执行（调用方提示稍候，不得提示成功）。
  Future<bool> _performLocalRestore(
    String backupPath, {
    String? password,
    bool? isZipContainer,
  }) async {
    final acquired = await LocalBackupService.instance.runExclusiveRestore(
      () async {
        await _performLocalRestoreLocked(
          backupPath,
          password: password,
          isZipContainer: isZipContainer,
        );
        return true;
      },
    );
    return acquired ?? false;
  }

  /// 本地恢复实际执行体（调用方须已持有备份/恢复互斥锁）
  Future<void> _performLocalRestoreLocked(
    String backupPath, {
    String? password,
    bool? isZipContainer,
  }) async {
    final api = ref.read(bookApiProvider);
    final isZip = isZipContainer ?? _isZipBackupFile(backupPath);
    var pathToRestore = backupPath;
    // 批8 审查回修 P1-1：先判定备份账号来源——v1/v2 备份的 WebDAV 账号
    // 只在 appPrefs 里，恢复后须回填 DB（原版 prefs 生效语义）；v3 含
    // servers 段以 DB 为准；无法判定/备份未带账号则不回填。
    final accountSource = isZip
        ? WebDavBackupAccountSource.none
        : await WebDavServerService.backupAccountSource(backupPath);
    final ignore = await _settings.getRestoreIgnoreConfig();
    if (ignore['localBook'] == true && !isZip) {
      pathToRestore = await _backupPathSkippingLocalBooks(backupPath);
    }

    final serverService = ServerService(api: api, settings: _settings);
    // 批18a：远程书库服务器密码以 servers 表为准；恢复旧备份时按 DB 既有
    // id / url+username 保留本机密码（读失败退回旧偏好，不阻断恢复）
    LocalServerPasswordIndex? localPasswords;
    if (!isZip) {
      try {
        localPasswords = await serverService.localPasswordIndex();
      } catch (e) {
        debugPrint('读取本机服务器密码索引失败（退回旧偏好）：$e');
      }
    }

    if (!isZip) {
      await RestoreIgnorePrefs.applyAppPrefsFromBackupFile(
        backupPath,
        ignore,
        localPasswordsById: localPasswords?.byId,
        localPasswordsByEndpoint: localPasswords?.byEndpoint,
      );
    }
    await api.restore(pathToRestore, password: password);
    // 偏好已由上面写回本地；v1/v2 备份把恢复所得账号显式覆盖到 DB
    // （v3 交由恢复器写入的 servers 行，不回读偏好）
    await ref
        .read(syncNotifierProvider.notifier)
        .applyLegacyWebDavPrefsAfterRestore(source: accountSource);
    // 批18a：旧格式备份（无 servers 段或仅 id=-1）携带 remote_servers 时，
    // 恢复后强制重跑一次 prefs → servers 表迁移。失败由
    // [ServerService.forceMigrateAfterRestore] 记崩溃日志并复位迁移标记
    //（下次启动重试）；取舍说明见该方法注释（可能复活旧偏好中已删除的服务器）
    if (!isZip &&
        await ServerService.backupNeedsLegacyRemoteServerMigration(backupPath)) {
      await serverService.forceMigrateAfterRestore();
    }
    if (!mounted) return;
    await _reloadPrefsAfterRestore();
  }

  /// 备份密码重试循环（批17b）
  ///
  /// 每轮：弹密码框 → 关闭后显示进度框执行恢复 → 进度框关闭后判定错误：
  /// - `BACKUP_PASSWORD_INVALID` → 重开密码框并内联提示「密码错误或备份
  ///   已损坏，请重试」，保留上次输入便于修改；
  /// - `BACKUP_PASSWORD_REQUIRED`（防御，如探测后文件被替换）→ 重开密码框；
  /// - `BACKUP_ENCRYPTED_CONTENT_CORRUPT` → 提示备份文件损坏并结束；
  /// - 其他 → 统一错误提示。
  ///
  /// 用户取消密码框即中止：不调用 restore（零写入）。密码只存在于本次
  /// 调用栈与对话框 controller 中，对话框销毁即清空。
  Future<void> _restoreWithPasswordLoop(
    String backupPath,
    BackupInspectInfo inspect, {
    bool? isZipContainer,
  }) async {
    var lastPassword = '';
    String? inlineError;
    while (mounted) {
      final password = await _showBackupPasswordDialog(
        inspect: inspect,
        initialPassword: lastPassword,
        errorText: inlineError,
      );
      // 取消：中止恢复（此前未发生任何写入）
      if (password == null) return;
      lastPassword = password;
      inlineError = null;

      var restoreBusy = false;
      final error = await _runWithProgress(
        '恢复中…',
        () async {
          restoreBusy = !await _performLocalRestore(
            backupPath,
            password: password,
            isZipContainer: isZipContainer,
          );
        },
        captureError: true,
      );
      // 忙（另一操作进行中）或页面已销毁：中止循环，不提示成功
      if (!error.ran) return;
      // 备份/恢复互斥拒绝（批40 回修 P2-2）：中止循环（不重开密码框）
      if (restoreBusy) {
        _showSnack('正在备份或恢复，请稍候');
        return;
      }
      if (error.error == null) {
        _showSnack(AppStrings.restoreSuccess);
        return;
      }
      final failure = error.error!;
      if (_hasBackupErrorPrefix(failure, _kBackupPasswordInvalid)) {
        // 密码错误：进度框已关闭，重开密码框并保留输入
        inlineError = '密码错误或备份已损坏，请重试';
        continue;
      }
      if (_hasBackupErrorPrefix(failure, _kBackupPasswordRequired)) {
        continue;
      }
      _showRestoreFailure(failure);
      return;
    }
  }

  Future<String?> _showBackupPasswordDialog({
    required BackupInspectInfo inspect,
    String initialPassword = '',
    String? errorText,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _BackupPasswordDialog(
        inspect: inspect,
        initialPassword: initialPassword,
        errorText: errorText,
      ),
    );
  }

  /// 是否命中备份密码错误码前缀
  ///
  /// 后端以 `LegadoError::Internal` 返回，Display 形如
  /// `Internal error: BACKUP_PASSWORD_INVALID: ...`，按「包含」识别。
  bool _hasBackupErrorPrefix(Object error, String prefix) =>
      rawErrorMessage(error).contains(prefix);

  /// 恢复失败提示（加密内容损坏单独文案，其余走统一错误映射）
  void _showRestoreFailure(Object error) {
    if (_hasBackupErrorPrefix(error, _kBackupEncryptedContentCorrupt)) {
      _showSnack('备份文件已损坏，无法恢复加密内容');
      return;
    }
    _showSnack('恢复失败：${errorMessage(error)}');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _showRestoreIgnore() async {
    final initial = await _settings.getRestoreIgnoreConfig();
    if (!mounted) return;
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (ctx) => RestoreIgnoreDialog(initial: initial),
    );
    if (result == null) return;
    await _settings.saveRestoreIgnoreConfig(result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存恢复忽略项')),
    );
  }

  Future<void> _doImportOldData() async {
    await _runWithProgress('导入中…', () async {
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择旧版备份目录',
      );
      if (dirPath == null) return;

      final api = ref.read(bookApiProvider);
      final raw = await api.importOldData(dirPath);
      final decoded = jsonDecode(raw);
      String message;
      if (decoded is Map) {
        final msgs = decoded['messages'];
        if (msgs is List && msgs.isNotEmpty) {
          message = msgs.map((e) => '$e').join('\n');
        } else {
          final books = decoded['books'] ?? 0;
          final sources = decoded['bookSources'] ?? 0;
          final rules = decoded['replaceRules'] ?? 0;
          message = '书架 $books · 书源 $sources · 替换规则 $rules';
        }
      } else {
        message = '导入完成';
      }

      ref.read(bookshelfNotifierProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }

  /// 恢复完成后刷新页面与全局状态
  ///
  /// 批8 审查回修 P2-1：`loadConfig()` 从 DB 重读账号（P1-1 的偏好回填已在
  /// 调用方完成，此处读取回填后的权威值），并同步刷新本页行文案。
  Future<void> _reloadPrefsAfterRestore() async {
    await ref.read(syncNotifierProvider.notifier).loadConfig();
    await ref.read(themeNotifierProvider.notifier).load();
    ref.invalidate(themeColorsProvider);
    ref.invalidate(mainPrefsProvider);
    ref.invalidate(bookshelfNotifierProvider);
    // [批37] 顶栏动作配置随 appPrefs 恢复后重读，避免继续用旧配置
    ref.invalidate(readerTopBarActionsProvider);
    // [批38] 阅读主题库/当前 id/列数随 appPrefs 恢复后重读
    ref.invalidate(readerThemeProvider);
    // [批40 回修 P3-4] 备份 appPrefs 会覆盖 WebDAV 备份族偏好；恢复后必须
    // 重读新增设置行（保留数量/导入后自动上传/自动备份三键）与既有两开关，
    // 否则页面继续显示恢复前的旧值。
    final keepCount = await _settings.getWebDavBackupKeepCount();
    final bookAutoUpload = await _settings.getWebDavBookAutoUpload();
    final autoBackup = await _settings.getAutoBackup();
    final autoBackupWebDav = await _settings.getAutoBackupWebDav();
    final autoBackupDays = await _settings.getAutoBackupIntervalDays();
    final onlyLatest = await _settings.getBoolPref(
      PrefKeys.onlyLatestBackup,
      defaultValue: true,
    );
    final autoCheck = await _settings.getBoolPref(
      PrefKeys.autoCheckNewBackup,
      defaultValue: true,
    );
    if (!mounted) return;
    final state = ref.read(syncNotifierProvider);
    setState(() {
      _url = state.webDavUrl;
      _user = state.webDavUsername;
      _pass = state.webDavPassword;
      _dir = state.remoteDir;
      _device = state.deviceName;
      _backupKeepCount = keepCount;
      _bookAutoUpload = bookAutoUpload;
      _autoBackup = autoBackup;
      _autoBackupWebDav = autoBackupWebDav;
      _autoBackupIntervalDays = autoBackupDays;
      _onlyLatestBackup = onlyLatest;
      _autoCheckNewBackup = autoCheck;
    });
  }

  Future<String> _backupPathSkippingLocalBooks(String backupPath) async {
    final raw = await File(backupPath).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return backupPath;
    final books = decoded['books'];
    if (books is! List) return backupPath;

    decoded['books'] = books.where((item) {
      if (item is! Map) return true;
      final origin = item['origin']?.toString() ?? '';
      final type = item['type'];
      final typeInt = type is int ? type : int.tryParse('$type') ?? 0;
      final isLocal = BookType.isLocalOrigin(origin) ||
          (typeInt & BookType.local) != 0;
      return !isLocal;
    }).toList();

    final dir = Directory.systemTemp;
    final out = File(
      '${dir.path}${Platform.pathSeparator}legado_restore_no_local_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await out.writeAsString(jsonEncode(decoded));
    return out.path;
  }

  /// 在模态进度框内执行 [task]
  ///
  /// [captureError] 为 true 时不弹通用错误提示，而是把异常返回给调用方
  /// （用于「进度框关闭后再进入密码重试循环」的本地恢复流程）。为 false
  /// 时沿用统一错误文案提示（[errorMessage]）。
  ///
  /// 返回**三态**结果（P3-6）：`ran=false` 表示本次没有执行任务（另一个
  /// 操作正在进行 / 页面已销毁）——调用方**不得**把它当成功提示，也不得
  /// 继续后续步骤。旧实现忙时返回 `null`，与「执行成功且无异常」的返回
  /// 值不可区分，恢复会被误报成功。
  Future<_ProgressResult> _runWithProgress(
    String label,
    Future<void> Function() task, {
    bool captureError = false,
  }) async {
    if (!mounted || _busy) return const _ProgressResult.busy();
    setState(() => _busy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
    Object? captured;
    try {
      await task();
    } catch (e) {
      if (captureError) {
        captured = e;
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage(e))),
        );
      }
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => _busy = false);
      } else {
        // 页面已销毁：进度框随页面一起消失，仅复位忙标记（不再 setState）
        _busy = false;
      }
    }
    return _ProgressResult.executed(captured);
  }

  // ===== 测试配置（差异清单 C7：参考版有「测试配置」行，我方新增） =====

  /// 对当前已填写的 WebDAV 配置发起一次连通性探测（纯客户端行为，不落库）
  ///
  /// 判定：PROPFIND（Depth: 0）+ 已填账号密码 Basic Auth，5 秒超时；
  /// 200/207 → 成功；401/403 → 认证失败；其他非 2xx/异常/超时 → 失败。
  /// 测试期间该行禁用防重入；结果以 SnackBar 呈现并更新行尾状态。
  /// — full-stack-engineer + UI ｜ 2026-09-10
  Future<void> _testWebDavConnection() async {
    if (_testStatus == _WebDavTestStatus.testing) return;
    final messenger = ScaffoldMessenger.of(context);
    final url = _url.trim();
    if (url.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请先填写服务器地址')),
      );
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('服务器地址需要以 http(s):// 开头'),
        ),
      );
      return;
    }

    setState(() => _testStatus = _WebDavTestStatus.testing);
    final client = http.Client();
    try {
      final request = http.Request('PROPFIND', Uri.parse(url));
      // Basic Auth 使用已填账号/密码（均为空时不带 Authorization 头，避免误触发 401）
      if (_user.isNotEmpty || _pass.isNotEmpty) {
        request.headers['Authorization'] = 'Basic '
            '${base64Encode(utf8.encode('$_user:$_pass'))}';
      }
      request.headers['Depth'] = '0';
      final streamed = await client.send(request).timeout(const Duration(seconds: 5));
      final response = await http.Response.fromStream(streamed);
      // 探测期间已离开页面则不再更新 UI（client 由 finally 关闭）
      if (!mounted) return;
      final code = response.statusCode;
      final ok = code == 200 || code == 207;
      setState(() {
        _testStatus =
            ok ? _WebDavTestStatus.success : _WebDavTestStatus.failed;
      });
      if (ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text('连接成功')),
        );
      } else if (code == 401 || code == 403) {
        messenger.showSnackBar(
          const SnackBar(content: Text('认证失败，请检查账号/密码')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text('连接失败（HTTP $code）')),
        );
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _testStatus = _WebDavTestStatus.failed);
      messenger.showSnackBar(
        const SnackBar(content: Text('连接超时（5 秒内未响应）')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _testStatus = _WebDavTestStatus.failed);
      messenger.showSnackBar(
        SnackBar(content: Text('连接失败：${_summarizeProbeError(e)}')),
      );
    } finally {
      client.close();
    }
  }

  /// 探测失败原因摘要（限 40 字符，防 SnackBar 溢出）
  String _summarizeProbeError(Object e) {
    final raw = e.toString().split('\n').first;
    return raw.length > 40 ? '${raw.substring(0, 40)}…' : raw;
  }

  /// 「测试配置」行尾状态标签
  ///
  /// 颜色：成功=主题 primary、失败=主题 error、其余=正文色
  Widget _buildTestStatusLabel() {
    final theme = Theme.of(context);
    final (label, color) = switch (_testStatus) {
      _WebDavTestStatus.notTested => ('未测试', null),
      _WebDavTestStatus.testing => ('测试中…', null),
      _WebDavTestStatus.success => ('✓ 连接成功', theme.colorScheme.primary),
      _WebDavTestStatus.failed => ('✗ 失败', theme.colorScheme.error),
    };
    return Text(
      label,
      style: theme.textTheme.labelMedium?.copyWith(color: color),
    );
  }

  void _showHelp() {
    showHelp(context, HelpAssets.webDavHelp);
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncNotifierProvider);
    final notifier = ref.read(syncNotifierProvider.notifier);

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: const Text('备份与恢复'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.help_rounded),
            tooltip: '帮助',
            onPressed: _showHelp,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'import_old':
                  _doImportOldData();
                case 'log':
                  Navigator.pushNamed(context, AppRoutes.appLog);
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'import_old',
                child: Text('导入旧版数据'),
              ),
              PopupMenuItem(
                value: 'log',
                child: Text('日志'),
              ),
            ],
          ),
        ],
      ),
      body: IosGroupedBody(
        // [LAYOUT_PLAN P3] 列表边距 16dp 走 IosGroupedBody（全局标尺）
        child: ListView(
          // [LAYOUT_PLAN P3] 底部 bottom32 保留
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const IosSectionHeader('WebDav 设置'),
            IosGroup(
              flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              children: [
                IosListTile(
                  title: 'WebDAV 服务器地址',
                  subtitle: _url.isEmpty ? '输入你的服务器地址' : _url,
                  onTap: () => _editTextPref(
                    title: 'WebDAV 服务器地址',
                    initial: _url,
                    hint: 'https://dav.example.com/',
                    onSaved: (v) => _url = v,
                  ),
                ),
                IosListTile(
                  title: 'WebDAV 账号',
                  subtitle: _user.isEmpty ? '输入你的 WebDAV 账号' : _user,
                  onTap: () => _editTextPref(
                    title: 'WebDAV 账号',
                    initial: _user,
                    onSaved: (v) => _user = v,
                  ),
                ),
                IosListTile(
                  title: 'WebDAV 密码',
                  subtitle: _pass.isEmpty ? '输入你的密码' : '*' * _pass.length,
                  onTap: () => _editTextPref(
                    title: 'WebDAV 密码',
                    initial: _pass,
                    obscure: true,
                    onSaved: (v) => _pass = v,
                  ),
                ),
                IosListTile(
                  title: '子目录',
                  subtitle: _dir.isEmpty ? 'legado' : _dir,
                  onTap: () => _editTextPref(
                    title: '子目录',
                    initial: _dir,
                    hint: 'legado',
                    onSaved: (v) => _dir = v,
                  ),
                ),
                IosListTile(
                  title: '设备名称',
                  subtitle: _device.isEmpty ? '用于区分不同设备的备份' : _device,
                  onTap: () => _editTextPref(
                    title: '设备名称',
                    initial: _device,
                    onSaved: (v) => _device = v,
                  ),
                ),
                // 差异清单 C7：参考版有「测试配置」行 → 连通性+认证探测（纯客户端）
                IosListTile(
                  title: '测试配置',
                  subtitle: '连接测试服务器地址与账号',
                  trailing: _buildTestStatusLabel(),
                  // 测试期间禁用防重入
                  onTap: _testStatus == _WebDavTestStatus.testing
                      ? null
                      : _testWebDavConnection,
                ),
                // [批40] 对齐原版 pref_config_backup.xml：
                // webDavBackupKeepCount（默认 0=不清理）+ webDavBookAutoUpload
                IosListTile(
                  title: 'WebDAV 备份保留数量',
                  subtitle: _backupKeepCount <= 0
                      ? '0（不自动清理）'
                      : '$_backupKeepCount（仅保留最近 $_backupKeepCount 份）',
                  onTap: _busy ? null : _editBackupKeepCount,
                ),
                SettingSwitchRow(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: '导入后自动上传本地书',
                  subtitle: '导入本地书后自动上传到 WebDAV 的 books 目录',
                  value: _bookAutoUpload,
                  onChanged: (v) async {
                    setState(() => _bookAutoUpload = v);
                    await _settings.setWebDavBookAutoUpload(v);
                  },
                ),
                SettingSwitchRow(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: '同步书籍进度',
                  subtitle: '在多设备间同步书籍阅读进度',
                  value: syncState.syncBookProgress,
                  onChanged: (v) => notifier.setSyncBookProgress(v),
                ),
                SettingSwitchRow(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: '同步书籍进度增强',
                  subtitle: '同步更详细的阅读进度信息',
                  value: syncState.syncBookProgressPlus,
                  onChanged: syncState.syncBookProgress
                      ? (v) => notifier.setSyncBookProgressPlus(v)
                      : null,
                ),
              ],
            ),

            const IosSectionHeader('备份与恢复'),
            IosGroup(
              flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              children: [
                IosListTile(
                  title: '备份路径',
                  subtitle:
                      _backupPath.isEmpty ? '请选择备份路径' : _backupPath,
                  onTap: _busy ? null : _pickBackupPath,
                ),
                IosListTile(
                  title: '备份',
                  subtitle: '本地和 WebDav 一起备份',
                  onTap: _busy ? null : _doLocalBackup,
                ),
                // 短按 WebDAV 优先；长按本地恢复
                GestureDetector(
                  onLongPress: _busy ? null : _doRestoreFromLocal,
                  child: IosListTile(
                    title: '恢复',
                    subtitle: '优先从 WebDav 恢复，长按从本地恢复',
                    onTap: _busy ? null : _doRestore,
                  ),
                ),
                IosListTile(
                  title: '恢复忽略列表',
                  subtitle: '恢复时忽略一些内容不恢复，方便不同手机配置不同',
                  onTap: _busy ? null : _showRestoreIgnore,
                ),
                SettingSwitchRow(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: '仅保留最新备份',
                  subtitle: '本地备份仅保留最新备份文件',
                  value: _onlyLatestBackup,
                  onChanged: (v) {
                    setState(() => _onlyLatestBackup = v);
                    _settings.setBoolPref(PrefKeys.onlyLatestBackup, v);
                  },
                ),
                // [批40] 对齐原版 autoBackup Preference（点击弹配置对话框）
                IosListTile(
                  title: '自动备份',
                  subtitle: _autoBackupSummary(),
                  onTap: _busy ? null : _configureAutoBackup,
                ),
                SettingSwitchRow(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: '自动检查新备份',
                  subtitle: '打开软件时检查是否有新备份，有新备份时提示是否更新',
                  value: _autoCheckNewBackup,
                  onChanged: (v) {
                    setState(() => _autoCheckNewBackup = v);
                    _settings.setBoolPref(PrefKeys.autoCheckNewBackup, v);
                  },
                ),
              ],
            ),
            if (syncState.lastSyncTimeLabel.isNotEmpty)
              IosSectionFooter('上次同步：${syncState.lastSyncTimeLabel}'),
          ],
        ),
      ),
    );
  }
}

/// 输入备份密码对话框（批17b）
///
/// - 列出受保护文件的中文标签（`servers.json` → 服务器配置、
///   `cookies.json` → 登录信息、`runtimeSourceCache.json` → 书源运行变量）；
/// - 密码默认隐藏，可切换显示；关闭自动更正/联想输入；
/// - 首次不预填（不复用本机 `localPassword`）；重试时回填上次输入便于修改；
/// - controller 随对话框销毁并清空，密码不落盘、不写日志、不进 prefs。
class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({
    required this.inspect,
    this.initialPassword = '',
    this.errorText,
  });

  final BackupInspectInfo inspect;

  /// 上次尝试输入的密码（仅重试回填；首次为空串）
  final String initialPassword;

  /// 内联错误提示（密码错误重试时显示）
  final String? errorText;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  late final TextEditingController _controller;
  bool _obscure = true;

  /// 本地校验提示（空/纯空白提交时显示，优先于外部传入的重试提示）
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPassword);
  }

  @override
  void dispose() {
    // 密码不保留：对话框销毁即清空并释放
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  /// 受保护文件 → 中文标签
  static String _labelFor(String file) => switch (file) {
        'servers.json' => '服务器配置',
        'cookies.json' => '登录信息',
        'runtimeSourceCache.json' => '书源运行变量',
        _ => file,
      };

  /// 提交校验（P2-2）：空/纯空白不得静默成功
  ///
  /// 后端把空串视作「未提供密码」（空密码密钥）——对仅 servers 加密的包，
  /// 空提交会让 servers 条目 warn 跳过，UI 却提示「恢复成功」，用户静默
  /// 丢失服务器配置。故 `passwordRequired` 为真时必须在对话框内拦截；
  /// **密码原文不 trim**（仅用于判空），含空格的真实密码照原样透传。
  void _submit() {
    final password = _controller.text;
    if (password.trim().isEmpty) {
      setState(() => _validationError = '请输入备份密码');
      return;
    }
    Navigator.pop(context, password);
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.inspect.passwordProtectedFiles;
    return AlertDialog(
      // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺）
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      title: const Text('输入备份密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('该备份包含已加密的内容，请输入备份密码：'),
          if (files.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...files.map(
              (file) => Text('· ${_labelFor(file)}（$file）'),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            onChanged: (value) {
              // 用户开始补输：收起本地校验提示（重试提示保留到下一次提交）
              if (_validationError != null && value.trim().isNotEmpty) {
                setState(() => _validationError = null);
              }
            },
            decoration: InputDecoration(
              labelText: '备份密码',
              errorText: _validationError ?? widget.errorText,
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 单行文本输入对话框（批40 回修 P3-9）
///
/// controller 由本 State 持有并在 [dispose] 中释放：若在 `showDialog`
/// 返回后立刻 dispose，退场动画重建 TextField 会触发
/// 「A TextEditingController was used after being disposed」。
class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    this.initial = '',
    this.hint,
    this.description,
    this.obscure = false,
    this.keyboardType,
  });

  final String title;
  final String initial;
  final String? hint;
  final String? description;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _controller,
      autofocus: true,
      obscureText: widget.obscure,
      keyboardType: widget.keyboardType,
      decoration: InputDecoration(hintText: widget.hint),
    );
    return AlertDialog(
      // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺）
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: Text(widget.title),
      content: widget.description == null
          ? field
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.description!),
                const SizedBox(height: 12),
                field,
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 自动备份配置对话框返回值（三个偏好一次写入）
class _AutoBackupConfig {
  const _AutoBackupConfig({
    required this.enabled,
    required this.webDav,
    required this.intervalDays,
  });

  final bool enabled;
  final bool webDav;
  final int intervalDays;
}

/// 自动备份配置对话框（批40；批40 回修 P3-9 改为 StatefulWidget 持有 controller）
class _AutoBackupDialog extends StatefulWidget {
  const _AutoBackupDialog({
    required this.enabled,
    required this.webDav,
    required this.intervalDays,
  });

  final bool enabled;
  final bool webDav;
  final int intervalDays;

  @override
  State<_AutoBackupDialog> createState() => _AutoBackupDialogState();
}

class _AutoBackupDialogState extends State<_AutoBackupDialog> {
  late bool _enabled;
  late String _destination;
  late final TextEditingController _daysController;
  String? _daysError;

  @override
  void initState() {
    super.initState();
    _enabled = widget.enabled;
    _destination = widget.webDav ? 'webdav' : 'local';
    _daysController = TextEditingController(text: '${widget.intervalDays}');
  }

  @override
  void dispose() {
    _daysController.dispose();
    super.dispose();
  }

  void _submit() {
    final days = int.tryParse(_daysController.text.trim());
    if (days == null || days < 1) {
      setState(() => _daysError = '请输入大于 0 的整数');
      return;
    }
    Navigator.pop(
      context,
      _AutoBackupConfig(
        enabled: _enabled,
        webDav: _destination == 'webdav',
        intervalDays: days,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: const Text('自动备份'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用自动备份'),
              subtitle: const Text('启动或回到前台时检查，按间隔最多备份一次；手动备份不受影响'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            RadioGroup<String>(
              groupValue: _destination,
              onChanged: (v) => setState(
                () => _destination = v ?? _destination,
              ),
              child: IgnorePointer(
                ignoring: !_enabled,
                child: Opacity(
                  opacity: _enabled ? 1 : 0.5,
                  child: const Column(
                    children: [
                      RadioListTile<String>(
                        value: 'local',
                        title: Text('仅本地'),
                      ),
                      RadioListTile<String>(
                        value: 'webdav',
                        title: Text('本地 + WebDAV'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            TextField(
              controller: _daysController,
              enabled: _enabled,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '备份间隔（天）',
                hintText: '1',
                errorText: _daysError,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
