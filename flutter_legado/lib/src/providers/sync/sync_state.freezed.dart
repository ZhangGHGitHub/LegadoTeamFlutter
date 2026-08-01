// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sync_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$SyncState {
  /// 同步状态
  SyncStatus get status => throw _privateConstructorUsedError;

  /// 上次同步时间（null 表示从未同步）
  DateTime? get lastSyncTime => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 是否自动同步
  bool get autoSync =>
      throw _privateConstructorUsedError; // ===== WebDAV 配置 =====
  /// WebDAV 服务器地址
  String get webDavUrl => throw _privateConstructorUsedError;

  /// WebDAV 账号
  String get webDavUsername => throw _privateConstructorUsedError;

  /// WebDAV 密码
  String get webDavPassword => throw _privateConstructorUsedError;

  /// 远端子目录
  String get remoteDir => throw _privateConstructorUsedError;

  /// 设备名
  String get deviceName => throw _privateConstructorUsedError;

  /// 同步书籍进度
  bool get syncBookProgress => throw _privateConstructorUsedError;

  /// 同步书籍进度增强
  bool get syncBookProgressPlus => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $SyncStateCopyWith<SyncState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SyncStateCopyWith<$Res> {
  factory $SyncStateCopyWith(SyncState value, $Res Function(SyncState) then) =
      _$SyncStateCopyWithImpl<$Res, SyncState>;
  @useResult
  $Res call(
      {SyncStatus status,
      DateTime? lastSyncTime,
      String? error,
      bool autoSync,
      String webDavUrl,
      String webDavUsername,
      String webDavPassword,
      String remoteDir,
      String deviceName,
      bool syncBookProgress,
      bool syncBookProgressPlus});
}

/// @nodoc
class _$SyncStateCopyWithImpl<$Res, $Val extends SyncState>
    implements $SyncStateCopyWith<$Res> {
  _$SyncStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? lastSyncTime = freezed,
    Object? error = freezed,
    Object? autoSync = null,
    Object? webDavUrl = null,
    Object? webDavUsername = null,
    Object? webDavPassword = null,
    Object? remoteDir = null,
    Object? deviceName = null,
    Object? syncBookProgress = null,
    Object? syncBookProgressPlus = null,
  }) {
    return _then(_value.copyWith(
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as SyncStatus,
      lastSyncTime: freezed == lastSyncTime
          ? _value.lastSyncTime
          : lastSyncTime // ignore: cast_nullable_to_non_nullable
              as DateTime?,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      autoSync: null == autoSync
          ? _value.autoSync
          : autoSync // ignore: cast_nullable_to_non_nullable
              as bool,
      webDavUrl: null == webDavUrl
          ? _value.webDavUrl
          : webDavUrl // ignore: cast_nullable_to_non_nullable
              as String,
      webDavUsername: null == webDavUsername
          ? _value.webDavUsername
          : webDavUsername // ignore: cast_nullable_to_non_nullable
              as String,
      webDavPassword: null == webDavPassword
          ? _value.webDavPassword
          : webDavPassword // ignore: cast_nullable_to_non_nullable
              as String,
      remoteDir: null == remoteDir
          ? _value.remoteDir
          : remoteDir // ignore: cast_nullable_to_non_nullable
              as String,
      deviceName: null == deviceName
          ? _value.deviceName
          : deviceName // ignore: cast_nullable_to_non_nullable
              as String,
      syncBookProgress: null == syncBookProgress
          ? _value.syncBookProgress
          : syncBookProgress // ignore: cast_nullable_to_non_nullable
              as bool,
      syncBookProgressPlus: null == syncBookProgressPlus
          ? _value.syncBookProgressPlus
          : syncBookProgressPlus // ignore: cast_nullable_to_non_nullable
              as bool,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SyncStateImplCopyWith<$Res>
    implements $SyncStateCopyWith<$Res> {
  factory _$$SyncStateImplCopyWith(
          _$SyncStateImpl value, $Res Function(_$SyncStateImpl) then) =
      __$$SyncStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {SyncStatus status,
      DateTime? lastSyncTime,
      String? error,
      bool autoSync,
      String webDavUrl,
      String webDavUsername,
      String webDavPassword,
      String remoteDir,
      String deviceName,
      bool syncBookProgress,
      bool syncBookProgressPlus});
}

/// @nodoc
class __$$SyncStateImplCopyWithImpl<$Res>
    extends _$SyncStateCopyWithImpl<$Res, _$SyncStateImpl>
    implements _$$SyncStateImplCopyWith<$Res> {
  __$$SyncStateImplCopyWithImpl(
      _$SyncStateImpl _value, $Res Function(_$SyncStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? lastSyncTime = freezed,
    Object? error = freezed,
    Object? autoSync = null,
    Object? webDavUrl = null,
    Object? webDavUsername = null,
    Object? webDavPassword = null,
    Object? remoteDir = null,
    Object? deviceName = null,
    Object? syncBookProgress = null,
    Object? syncBookProgressPlus = null,
  }) {
    return _then(_$SyncStateImpl(
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as SyncStatus,
      lastSyncTime: freezed == lastSyncTime
          ? _value.lastSyncTime
          : lastSyncTime // ignore: cast_nullable_to_non_nullable
              as DateTime?,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      autoSync: null == autoSync
          ? _value.autoSync
          : autoSync // ignore: cast_nullable_to_non_nullable
              as bool,
      webDavUrl: null == webDavUrl
          ? _value.webDavUrl
          : webDavUrl // ignore: cast_nullable_to_non_nullable
              as String,
      webDavUsername: null == webDavUsername
          ? _value.webDavUsername
          : webDavUsername // ignore: cast_nullable_to_non_nullable
              as String,
      webDavPassword: null == webDavPassword
          ? _value.webDavPassword
          : webDavPassword // ignore: cast_nullable_to_non_nullable
              as String,
      remoteDir: null == remoteDir
          ? _value.remoteDir
          : remoteDir // ignore: cast_nullable_to_non_nullable
              as String,
      deviceName: null == deviceName
          ? _value.deviceName
          : deviceName // ignore: cast_nullable_to_non_nullable
              as String,
      syncBookProgress: null == syncBookProgress
          ? _value.syncBookProgress
          : syncBookProgress // ignore: cast_nullable_to_non_nullable
              as bool,
      syncBookProgressPlus: null == syncBookProgressPlus
          ? _value.syncBookProgressPlus
          : syncBookProgressPlus // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$SyncStateImpl implements _SyncState {
  const _$SyncStateImpl(
      {this.status = SyncStatus.idle,
      this.lastSyncTime,
      this.error,
      this.autoSync = false,
      this.webDavUrl = '',
      this.webDavUsername = '',
      this.webDavPassword = '',
      this.remoteDir = '/legado/',
      this.deviceName = '',
      this.syncBookProgress = true,
      this.syncBookProgressPlus = false});

  /// 同步状态
  @override
  @JsonKey()
  final SyncStatus status;

  /// 上次同步时间（null 表示从未同步）
  @override
  final DateTime? lastSyncTime;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 是否自动同步
  @override
  @JsonKey()
  final bool autoSync;
// ===== WebDAV 配置 =====
  /// WebDAV 服务器地址
  @override
  @JsonKey()
  final String webDavUrl;

  /// WebDAV 账号
  @override
  @JsonKey()
  final String webDavUsername;

  /// WebDAV 密码
  @override
  @JsonKey()
  final String webDavPassword;

  /// 远端子目录
  @override
  @JsonKey()
  final String remoteDir;

  /// 设备名
  @override
  @JsonKey()
  final String deviceName;

  /// 同步书籍进度
  @override
  @JsonKey()
  final bool syncBookProgress;

  /// 同步书籍进度增强
  @override
  @JsonKey()
  final bool syncBookProgressPlus;

  @override
  String toString() {
    return 'SyncState(status: $status, lastSyncTime: $lastSyncTime, error: $error, autoSync: $autoSync, webDavUrl: $webDavUrl, webDavUsername: $webDavUsername, webDavPassword: $webDavPassword, remoteDir: $remoteDir, deviceName: $deviceName, syncBookProgress: $syncBookProgress, syncBookProgressPlus: $syncBookProgressPlus)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SyncStateImpl &&
            (identical(other.status, status) || other.status == status) &&
            (identical(other.lastSyncTime, lastSyncTime) ||
                other.lastSyncTime == lastSyncTime) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.autoSync, autoSync) ||
                other.autoSync == autoSync) &&
            (identical(other.webDavUrl, webDavUrl) ||
                other.webDavUrl == webDavUrl) &&
            (identical(other.webDavUsername, webDavUsername) ||
                other.webDavUsername == webDavUsername) &&
            (identical(other.webDavPassword, webDavPassword) ||
                other.webDavPassword == webDavPassword) &&
            (identical(other.remoteDir, remoteDir) ||
                other.remoteDir == remoteDir) &&
            (identical(other.deviceName, deviceName) ||
                other.deviceName == deviceName) &&
            (identical(other.syncBookProgress, syncBookProgress) ||
                other.syncBookProgress == syncBookProgress) &&
            (identical(other.syncBookProgressPlus, syncBookProgressPlus) ||
                other.syncBookProgressPlus == syncBookProgressPlus));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      status,
      lastSyncTime,
      error,
      autoSync,
      webDavUrl,
      webDavUsername,
      webDavPassword,
      remoteDir,
      deviceName,
      syncBookProgress,
      syncBookProgressPlus);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SyncStateImplCopyWith<_$SyncStateImpl> get copyWith =>
      __$$SyncStateImplCopyWithImpl<_$SyncStateImpl>(this, _$identity);
}

abstract class _SyncState implements SyncState {
  const factory _SyncState(
      {final SyncStatus status,
      final DateTime? lastSyncTime,
      final String? error,
      final bool autoSync,
      final String webDavUrl,
      final String webDavUsername,
      final String webDavPassword,
      final String remoteDir,
      final String deviceName,
      final bool syncBookProgress,
      final bool syncBookProgressPlus}) = _$SyncStateImpl;

  @override

  /// 同步状态
  SyncStatus get status;
  @override

  /// 上次同步时间（null 表示从未同步）
  DateTime? get lastSyncTime;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 是否自动同步
  bool get autoSync;
  @override // ===== WebDAV 配置 =====
  /// WebDAV 服务器地址
  String get webDavUrl;
  @override

  /// WebDAV 账号
  String get webDavUsername;
  @override

  /// WebDAV 密码
  String get webDavPassword;
  @override

  /// 远端子目录
  String get remoteDir;
  @override

  /// 设备名
  String get deviceName;
  @override

  /// 同步书籍进度
  bool get syncBookProgress;
  @override

  /// 同步书籍进度增强
  bool get syncBookProgressPlus;
  @override
  @JsonKey(ignore: true)
  _$$SyncStateImplCopyWith<_$SyncStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
