import 'package:freezed_annotation/freezed_annotation.dart';

part 'sync_state.freezed.dart';

/// 同步状态
enum SyncStatus { idle, syncing, success, error }

/// WebDAV 云同步 UI 状态（immutable）
///
/// 对齐 Android 原版 BackupConfigFragment 的 WebDAV 设置组
/// （服务器地址/账号/密码/子目录/设备名/同步书籍进度）。
@freezed
class SyncState with _$SyncState {
  const factory SyncState({
    /// 同步状态
    @Default(SyncStatus.idle) SyncStatus status,

    /// 上次同步时间（null 表示从未同步）
    DateTime? lastSyncTime,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 是否自动同步
    @Default(false) bool autoSync,

    // ===== WebDAV 配置 =====

    /// WebDAV 服务器地址
    @Default('') String webDavUrl,

    /// WebDAV 账号
    @Default('') String webDavUsername,

    /// WebDAV 密码
    @Default('') String webDavPassword,

    /// 远端子目录
    @Default('/legado/') String remoteDir,

    /// 设备名
    @Default('') String deviceName,

    /// 同步书籍进度
    @Default(true) bool syncBookProgress,

    /// 同步书籍进度增强
    @Default(false) bool syncBookProgressPlus,
  }) = _SyncState;
}

/// 同步展示扩展 —— 纯派生计算，不改变数据内容
extension SyncStateDerived on SyncState {
  /// WebDAV 是否已配置完整（地址/账号/密码均非空）
  bool get isConfigured =>
      webDavUrl.isNotEmpty &&
      webDavUsername.isNotEmpty &&
      webDavPassword.isNotEmpty;

  /// 上次同步时间展示文本（对齐原版相对时间描述）
  String get lastSyncTimeLabel {
    if (lastSyncTime == null) return '从未同步';
    final now = DateTime.now();
    final diff = now.difference(lastSyncTime!);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }
}
