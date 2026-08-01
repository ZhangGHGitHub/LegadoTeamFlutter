// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'auto_task_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$AutoTaskState {
  /// 定时任务列表
  List<AutoTask> get tasks => throw _privateConstructorUsedError;

  /// 是否正在加载任务列表
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $AutoTaskStateCopyWith<AutoTaskState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AutoTaskStateCopyWith<$Res> {
  factory $AutoTaskStateCopyWith(
          AutoTaskState value, $Res Function(AutoTaskState) then) =
      _$AutoTaskStateCopyWithImpl<$Res, AutoTaskState>;
  @useResult
  $Res call({List<AutoTask> tasks, bool isLoading, String? error});
}

/// @nodoc
class _$AutoTaskStateCopyWithImpl<$Res, $Val extends AutoTaskState>
    implements $AutoTaskStateCopyWith<$Res> {
  _$AutoTaskStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? tasks = null,
    Object? isLoading = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      tasks: null == tasks
          ? _value.tasks
          : tasks // ignore: cast_nullable_to_non_nullable
              as List<AutoTask>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$AutoTaskStateImplCopyWith<$Res>
    implements $AutoTaskStateCopyWith<$Res> {
  factory _$$AutoTaskStateImplCopyWith(
          _$AutoTaskStateImpl value, $Res Function(_$AutoTaskStateImpl) then) =
      __$$AutoTaskStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<AutoTask> tasks, bool isLoading, String? error});
}

/// @nodoc
class __$$AutoTaskStateImplCopyWithImpl<$Res>
    extends _$AutoTaskStateCopyWithImpl<$Res, _$AutoTaskStateImpl>
    implements _$$AutoTaskStateImplCopyWith<$Res> {
  __$$AutoTaskStateImplCopyWithImpl(
      _$AutoTaskStateImpl _value, $Res Function(_$AutoTaskStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? tasks = null,
    Object? isLoading = null,
    Object? error = freezed,
  }) {
    return _then(_$AutoTaskStateImpl(
      tasks: null == tasks
          ? _value._tasks
          : tasks // ignore: cast_nullable_to_non_nullable
              as List<AutoTask>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$AutoTaskStateImpl implements _AutoTaskState {
  const _$AutoTaskStateImpl(
      {final List<AutoTask> tasks = const [],
      this.isLoading = false,
      this.error})
      : _tasks = tasks;

  /// 定时任务列表
  final List<AutoTask> _tasks;

  /// 定时任务列表
  @override
  @JsonKey()
  List<AutoTask> get tasks {
    if (_tasks is EqualUnmodifiableListView) return _tasks;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_tasks);
  }

  /// 是否正在加载任务列表
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  @override
  String toString() {
    return 'AutoTaskState(tasks: $tasks, isLoading: $isLoading, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AutoTaskStateImpl &&
            const DeepCollectionEquality().equals(other._tasks, _tasks) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(runtimeType,
      const DeepCollectionEquality().hash(_tasks), isLoading, error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$AutoTaskStateImplCopyWith<_$AutoTaskStateImpl> get copyWith =>
      __$$AutoTaskStateImplCopyWithImpl<_$AutoTaskStateImpl>(this, _$identity);
}

abstract class _AutoTaskState implements AutoTaskState {
  const factory _AutoTaskState(
      {final List<AutoTask> tasks,
      final bool isLoading,
      final String? error}) = _$AutoTaskStateImpl;

  @override

  /// 定时任务列表
  List<AutoTask> get tasks;
  @override

  /// 是否正在加载任务列表
  bool get isLoading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$AutoTaskStateImplCopyWith<_$AutoTaskStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
