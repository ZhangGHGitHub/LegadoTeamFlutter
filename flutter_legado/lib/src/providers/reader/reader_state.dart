import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'reader_state.freezed.dart';

/// 翻页模式
///
/// 对齐安卓原版 5 种翻页动画：覆盖/滑动/仿真/滚动/无动画
/// 注意：cover 追加在末尾（index=4），避免破坏已有持久化索引映射
enum PageTurnMode {
  scroll, // 上下滚动
  slide, // 左右滑动
  simulate, // 仿真翻页
  none, // 无动画（直接切换）
  cover; // 覆盖（新页从右向左覆盖旧页，旧页不动）

  /// 获取显示名称
  String get displayName {
    switch (this) {
      case PageTurnMode.scroll:
        return '滚动';
      case PageTurnMode.slide:
        return '滑动';
      case PageTurnMode.simulate:
        return '仿真';
      case PageTurnMode.none:
        return '无动画';
      case PageTurnMode.cover:
        return '覆盖';
    }
  }

  /// 获取图标
  String get icon {
    switch (this) {
      case PageTurnMode.scroll:
        return '📜';
      case PageTurnMode.slide:
        return '👈';
      case PageTurnMode.simulate:
        return '📖';
      case PageTurnMode.none:
        return '⚡';
      case PageTurnMode.cover:
        return '📄';
    }
  }

  /// 从持久化名称恢复枚举值（兼容旧版 int 索引存储）
  static PageTurnMode fromStorage(String? name, int? legacyIndex) {
    // 优先使用 name 存储（新版）
    if (name != null && name.isNotEmpty) {
      for (final mode in PageTurnMode.values) {
        if (mode.name == name) return mode;
      }
    }
    // 回退：旧版 int 索引映射（0=scroll,1=slide,2=simulate,3=none）
    if (legacyIndex != null &&
        legacyIndex >= 0 &&
        legacyIndex < PageTurnMode.values.length) {
      return PageTurnMode.values[legacyIndex];
    }
    // 默认覆盖模式（对齐安卓原版）
    return PageTurnMode.cover;
  }
}

/// 阅读背景预设
class ReaderBackground {
  static const white = Color(0xFFFFFFFF);
  static const green = Color(0xFFCCEBCC);
  static const brown = Color(0xFFD4A574);
  static const dark = Color(0xFF1A1A1A);
  static const eyeProtect = Color(0xFFE8E0C8);

  static const List<Color> presets = [white, green, brown, eyeProtect, dark];
  static const List<String> labels = ['白色', '绿色', '棕色', '护眼', '夜间'];
}

/// 阅读器 UI 状态（immutable）
///
/// 职责边界说明（对齐 UI_RESTRUCTURE_PLAN.md §3.2 铁律）：
/// - [currentBook] / [chapters] / [chapterContent]：Rust API 返回的纯数据
/// - [isLoading] / [error]：API 调用状态
/// - [showControls]：工具栏显隐（UI 交互状态）
/// - [fontSize] / [lineHeight] / [backgroundColor] / [pageTurnMode]：阅读设置
///
/// 文本解析/净化/替换全部由 Rust 在 getChapterContent 内部完成，
/// UI 侧拿到的 [chapterContent] 已是最终渲染文本。
@freezed
class ReaderState with _$ReaderState {
  const factory ReaderState({
    /// 当前阅读的书籍
    Book? currentBook,

    /// 章节目录列表（Rust 返回，已排序）
    @Default([]) List<BookChapter> chapters,

    /// 当前章节索引
    @Default(0) int currentChapterIndex,

    /// 当前章节内阅读位置
    @Default(0) int currentChapterPos,

    /// 当前章节正文（Rust 已完成净化/替换的最终文本）
    @Default('') String chapterContent,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 工具栏是否显示
    @Default(false) bool showControls,

    // ===== 阅读设置 =====

    /// 字体大小
    @Default(18.0) double fontSize,

    /// 行高倍数
    @Default(1.6) double lineHeight,

    /// 背景色
    @Default(ReaderBackground.white) Color backgroundColor,

    /// 翻页模式
    @Default(PageTurnMode.cover) PageTurnMode pageTurnMode,

    // ===== 跨章节连续分页 =====

    /// 全局页索引（跨章节连续编号，从 0 开始）
    @Default(0) int globalPageIndex,

    /// 全局总页数（所有章节页数之和）
    @Default(0) int totalPages,
  }) = _ReaderState;
}

/// 阅读器状态派生属性扩展
extension ReaderStateDerived on ReaderState {
  /// 是否存在上一章
  bool get hasPreviousChapter => currentChapterIndex > 0;

  /// 是否存在下一章
  bool get hasNextChapter => currentChapterIndex < chapters.length - 1;

  /// 当前章节对象
  BookChapter? get currentChapter {
    if (chapters.isEmpty) return null;
    if (currentChapterIndex >= chapters.length) return null;
    return chapters[currentChapterIndex];
  }

  /// 阅读进度（0.0 ~ 1.0）
  double get readingProgress {
    if (chapters.isEmpty) return 0;
    return (currentChapterIndex + 1) / chapters.length;
  }

  /// 是否为夜间（深色）背景
  bool get isDarkBackground => backgroundColor == ReaderBackground.dark;

  /// 正文文字颜色（根据背景自动适配）
  Color get textColor =>
      isDarkBackground ? const Color(0xFFCCCCCC) : const Color(0xFF333333);
}
