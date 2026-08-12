import 'package:freezed_annotation/freezed_annotation.dart';

import '../../services/source_import_service.dart';

part 'association_state.freezed.dart';

/// 导入类型枚举
enum ImportType {
  /// 书源
  bookSource,

  /// RSS 源
  rssSource,

  /// 替换规则
  replaceRule,

  /// 主题配置
  theme,

  /// HTTP TTS
  httpTts,

  /// 字典规则
  dictRule,

  /// TXT 目录规则
  txtTocRule,
}

/// 导入来源方式
enum ImportSource {
  /// 从 URL 导入
  url,

  /// 从文件导入
  file,

  /// 从剪贴板导入
  clipboard,

  /// 扫码导入（预留）
  qrCode,
}

/// 导入步骤
enum ImportStep {
  /// 选择导入类型
  selectType,

  /// 输入来源
  inputSource,

  /// 预览导入内容
  preview,

  /// 导入完成
  done,
}

/// 关联导入 UI 状态（immutable）
///
/// 职责边界：
/// - [type]：当前选择的导入类型
/// - [source]：当前选择的导入来源方式
/// - [step]：当前导入步骤
/// - [previewItems]：预览项列表
/// - [isLoading] / [error]：API 调用状态
/// - [lastResult]：最近一次导入结果
/// - [urlInput]：URL 输入内容
@freezed
class AssociationState with _$AssociationState {
  const factory AssociationState({
    /// 导入类型
    @Default(ImportType.bookSource) ImportType type,

    /// 导入来源方式
    @Default(ImportSource.url) ImportSource source,

    /// 当前导入步骤
    @Default(ImportStep.selectType) ImportStep step,

    /// 预览项列表
    @Default([]) List<dynamic> previewItems,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 最近一次导入结果
    ImportResult? lastResult,

    /// URL 输入内容
    @Default('') String urlInput,
  }) = _AssociationState;
}

/// 关联导入展示扩展 —— 纯展示层变换
extension AssociationStateDisplay on AssociationState {
  /// 导入类型显示名称
  String get typeName {
    switch (type) {
      case ImportType.bookSource:
        return '书源';
      case ImportType.rssSource:
        return 'RSS 源';
      case ImportType.replaceRule:
        return '替换规则';
      case ImportType.theme:
        return '主题配置';
      case ImportType.httpTts:
        return 'HTTP TTS';
      case ImportType.dictRule:
        return '字典规则';
      case ImportType.txtTocRule:
        return 'TXT 目录规则';
    }
  }

  /// 导入来源显示名称
  String get sourceName {
    switch (source) {
      case ImportSource.url:
        return 'URL';
      case ImportSource.file:
        return '文件';
      case ImportSource.clipboard:
        return '剪贴板';
      case ImportSource.qrCode:
        return '扫码';
    }
  }

  /// 预览项数量
  int get previewCount => previewItems.length;

  /// 是否可以进入下一步
  bool get canProceed {
    switch (step) {
      case ImportStep.selectType:
        return true;
      case ImportStep.inputSource:
        if (source == ImportSource.url) {
          return urlInput.trim().isNotEmpty;
        }
        return true;
      case ImportStep.preview:
        return previewItems.isNotEmpty;
      case ImportStep.done:
        return false;
    }
  }
}
