// reader_config_panel.dart 的 part 文件（体检 §三.16 超长文件拆分）。
// extension _ReaderConfigBuilders 承载 build 之后的各区块构建方法（原样搬移）；生命周期/build 留在主类。
part of 'reader_config_panel.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _ReaderConfigBuilders on _ReaderConfigPanelState {
  Widget _sectionTitle(String title, IconData icon) {
    // [LAYOUT_PLAN P1] 组内标题行 vertical12/horizontal8（全局行规范）
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 翻页模式 =====

  Widget _buildFlipMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppStrings.flipMode, Icons.auto_stories_outlined),
        SegmentedButton<FlipMode>(
          segments: [
            for (final mode in FlipMode.values)
              ButtonSegment(
                value: mode,
                label: Text(mode.displayName),
                icon: Text(mode.icon),
              ),
          ],
          selected: {_config.flipMode},
          onSelectionChanged: (sel) {
            _config.flipMode = sel.first;
            _commit();
          },
        ),
      ],
    );
  }

  // ===== 自动翻页 =====

  Widget _buildAutoPageTurn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppStrings.autoPageTurn, Icons.timer_outlined),
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.enableAutoPageTurn),
          value: _config.autoPageTurn,
          onChanged: (v) {
            _config.autoPageTurn = v;
            _commit();
          },
        ),
        if (_config.autoPageTurn) ...[
          Row(
            children: [
              Text(
                AppStrings.autoPageTurnIntervalLabel(
                  _config.autoPageTurnInterval.toStringAsFixed(0),
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Expanded(
                child: Slider(
                  value: _config.autoPageTurnInterval,
                  min: 3,
                  max: 60,
                  divisions: 57,
                  onChanged: (v) {
                    _config.autoPageTurnInterval = v;
                    _commit();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                AppStrings.pageTurnDirection,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      label: Text(AppStrings.nextChapter),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text(AppStrings.previousChapter),
                    ),
                  ],
                  selected: {_config.autoPageTurnForward},
                  onSelectionChanged: (sel) {
                    _config.autoPageTurnForward = sel.first;
                    _commit();
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ===== 点击区域（[批4a] 九宫格单行入口）=====

  Widget _buildClickActionEntry() {
    return ListTile(
      key: const ValueKey('reader-click-action-entry'),
      // [LAYOUT_PLAN P1] 组内行 vertical12/horizontal8
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      leading: const Icon(Icons.touch_app_outlined),
      title: Text(AppStrings.clickActionSheetTitle),
      subtitle: Text(AppStrings.nineGridZonesHint),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => ClickActionConfigSheet.show(
        context,
        config: _config.copy(),
        onChanged: (cfg) {
          _config = cfg.copy();
          _commit();
        },
      ),
    );
  }

  // ===== 自定义翻页键 / 按键长按（[批4b] 阅读器 more 页） =====

  Widget _buildKeyPageControls() {
    return Column(
      children: [
        ListTile(
          key: const ValueKey('reader-page-key-entry'),
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          leading: const Icon(Icons.keyboard_outlined),
          title: Text(AppStrings.customPageKey),
          subtitle: Text(
            _config.prevKeyCodes.isEmpty && _config.nextKeyCodes.isEmpty
                ? AppStrings.pageKeysNotSet
                : AppStrings.pageKeysSummary(
                    _config.prevKeyCodes, _config.nextKeyCodes),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => PageKeyConfigSheet.show(
            context,
            config: _config.copy(),
            onChanged: (cfg) {
              _config = cfg.copy();
              _commit();
            },
          ),
        ),
        SwitchListTile(
          key: const ValueKey('reader-key-page-longpress-switch'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.keyLongPressPageTurn),
          subtitle: Text(AppStrings.keyLongPressPageTurnHint),
          value: _config.keyPageOnLongPress,
          onChanged: (v) {
            _config.keyPageOnLongPress = v;
            _commit();
          },
        ),
      ],
    );
  }

  // ===== 选择菜单配置（[批4c]） =====

  Widget _buildSelectionMenuEntry() {
    return ListTile(
      key: const ValueKey('reader-select-menu-entry'),
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      leading: const Icon(Icons.format_list_bulleted),
      title: Text(AppStrings.selectionMenuLabel),
      subtitle: Text(AppStrings.selectionMenuHint),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => TextSelectMenuConfigSheet.show(
        context,
        config: _config.copy(),
        onChanged: (cfg) {
          _config = cfg.copy();
          _commit();
        },
      ),
    );
  }

  // ===== 滑动书签 / 角标 / 振动（[批4d]） =====

  Widget _buildSwipeBookmarkConfig() {
    final badgeSize = _config.bookmarkBadgeSize.clamp(0, 50);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('reader-swipe-bookmark-switch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text(AppStrings.swipeDownAddBookmark),
          subtitle: Text(AppStrings.swipeDownAddBookmarkHint),
          value: _config.swipeToAddBookmark,
          onChanged: (v) {
            _config.swipeToAddBookmark = v;
            _commit();
          },
        ),
        ListTile(
          key: const ValueKey('reader-bookmark-badge-size'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text(AppStrings.bookmarkBadgeSize),
          trailing: Text('${badgeSize}dp'),
        ),
        Slider(
          key: const ValueKey('reader-bookmark-badge-size-slider'),
          value: badgeSize.toDouble(),
          min: 0,
          max: 50,
          divisions: 50,
          label: '${badgeSize}dp',
          onChanged: (v) =>
              setState(() => _config.bookmarkBadgeSize = v.round()),
          onChangeEnd: (_) => _commit(),
        ),
        ListTile(
          key: const ValueKey('reader-bookmark-badge-image'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text(AppStrings.bookmarkBadge),
          subtitle: Text(_config.bookmarkBadgeImage.isEmpty
              ? AppStrings.defaultLabel
              : AppStrings.customImage),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: const ValueKey('reader-bookmark-badge-pick'),
                onPressed: _pickBookmarkBadgeImage,
                child: Text(_config.bookmarkBadgeImage.isEmpty
                    ? AppStrings.selectLabel
                    : AppStrings.changeLabel),
              ),
              if (_config.bookmarkBadgeImage.isNotEmpty)
                IconButton(
                  key: const ValueKey('reader-bookmark-badge-reset'),
                  tooltip: AppStrings.resetBookmarkBadge,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.restart_alt, size: 20),
                  onPressed: () {
                    _config.bookmarkBadgeImage = '';
                    _commit();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVibratorConfig() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('reader-slider-vibrator-switch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text(AppStrings.vibrateSlider),
          value: _config.sliderVibrator,
          onChanged: (v) {
            _config.sliderVibrator = v;
            _commit();
          },
        ),
        SwitchListTile(
          key: const ValueKey('reader-select-vibrator-switch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text(AppStrings.vibrateSelectText),
          value: _config.selectVibrator,
          onChanged: (v) {
            _config.selectVibrator = v;
            _commit();
          },
        ),
      ],
    );
  }

  Future<void> _pickBookmarkBadgeImage() async {
    try {
      final pick = await ContainerImagePicker.pick(
        maxBytes: BookmarkBadgeImageStore.maxBytes,
        dialogTitle: AppStrings.pickBookmarkBadgeImage,
      );
      if (pick == null || !mounted) return;
      final identifier = await BookmarkBadgeImageStore.storeBytes(
        pick.bytes,
        originalName: pick.name,
      );
      if (!mounted) return;
      _config.bookmarkBadgeImage = identifier;
      _commit();
    } on ContainerImagePickException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(AppStrings.bookmarkBadgeSaveFailed(errorMessage(e))),
        ),
      );
    }
  }

  // ===== 段落间距 =====

  Widget _buildParagraphSpacing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppStrings.paragraphSpacing, Icons.format_line_spacing_outlined),
        Row(
          children: [
            Text(AppStrings.fontSmall,
                style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              child: Slider(
                value: _config.paragraphSpacing,
                min: 0,
                max: 48,
                divisions: 16,
                label: _config.paragraphSpacing.toStringAsFixed(0),
                onChanged: (v) {
                  _config.paragraphSpacing = v;
                  _commit();
                },
              ),
            ),
            Text(AppStrings.fontLarge,
                style: Theme.of(context).textTheme.bodySmall),
            SizedBox(
              width: 48,
              child: Text(
                '${_config.paragraphSpacing.toStringAsFixed(0)}px',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===== 字体与排版（对标原版 TextFontStyleDialog + ReadBookConfig） =====

  Widget _buildTypography() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppStrings.typography, Icons.text_fields),
        // 字体选择：跳转字体管理页，返回后触发阅读器重新加载字体
        ListTile(
          dense: true,
          // [LAYOUT_PLAN P1] 组内行 vertical12/horizontal8
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          leading: const Icon(Icons.font_download_outlined, size: 20),
          title: Text(AppStrings.readingFont),
          subtitle: Text(_fontLabel),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.pushNamed(context, AppRoutes.fonts);
            if (!mounted) return;
            await _loadFontLabel();
            // 通知阅读器重建内容区（ReaderPageView.didUpdateWidget 重读字体）
            widget.onChanged?.call(_config.copy());
          },
        ),
        // 字距调节（对标原版 ReadBookConfig.letterSpacing）
        // [UI-fix v2.0.4 | 2026-08-08] 语义升级为 em：-0.5~1.0 步长 0.02
        // （对标原版 dsbTextLetterSpacing (it-50)/100）— Qoder
        Row(
          children: [
            Text(AppStrings.letterSpacingShort,
                style: Theme.of(context).textTheme.bodyMedium),
            Expanded(
              child: Slider(
                value: _config.letterSpacing.clamp(-0.5, 1.0),
                min: -0.5,
                max: 1.0,
                divisions: 75,
                label: _config.letterSpacing.toStringAsFixed(2),
                onChanged: (v) {
                  _config.letterSpacing = v;
                  _commit();
                },
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                _config.letterSpacing.toStringAsFixed(2),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
        // 首行缩进（对标原版 tvTextIndent 缩进选择器）
        // [UI-fix v2.0.4 | 2026-08-08] bool 开关升级为 0-3 字符档位 — Qoder
        _moreRow(AppStrings.firstLineIndent, _indentLabel(_config.paragraphIndent),
            () {
          _showChoiceDialog<int>(
            title: AppStrings.firstLineIndent,
            current: _config.paragraphIndent,
            options: {
              0: AppStrings.indentNone,
              1: AppStrings.indent1,
              2: AppStrings.indent2,
              3: AppStrings.indent3,
            },
            onPick: (v) {
              _config.paragraphIndent = v;
              _commit();
            },
          );
        }),
      ],
    );
  }

  /// 缩进档位显示文案
  String _indentLabel(int v) {
    final labels = [
      AppStrings.indentNone,
      AppStrings.indent1,
      AppStrings.indent2,
      AppStrings.indent3,
    ];
    if (v < 0 || v >= labels.length) return AppStrings.indent2;
    return labels[v];
  }

  // ===== 顶栏按钮入口（批37，对齐参考版 SystemMenuPage「顶栏按钮」）=====

  /// 阅读器顶栏动作配置入口（选择/排序/恢复默认）
  Widget _buildTopBarActionsEntry() {
    return ListTile(
      // [LAYOUT_PLAN P1] 组内行 vertical12/horizontal8
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      leading: const Icon(Icons.view_week_outlined),
      title: Text(AppStrings.topBarButtons),
      subtitle: Text(AppStrings.topBarButtonsHint),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => ReaderTopBarConfigSheet.show(context),
    );
  }

  // ===== 更多配置（对标原版 MoreConfigDialog） =====

  /// [批3a] 「更多配置」构建；[includeToolbarFollowPage] 仅 all 页保留旧
  /// 「工具栏跟随页面」开关（all 页保持原样），more 页由菜单系统新配置替代。
  Widget _buildMoreConfig({bool includeToolbarFollowPage = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppStrings.moreConfig, Icons.tune_outlined),
        // 简繁转换（接 Rust 繁简转换 FFI，对标原版 chineseConvertType）
        Row(
          children: [
            Text(AppStrings.chineseConversion,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                    value: 0,
                    label: Text(AppStrings.convertNone),
                  ),
                  ButtonSegment(
                    value: 1,
                    label: Text(AppStrings.t2sShort),
                  ),
                  ButtonSegment(
                    value: 2,
                    label: Text(AppStrings.s2tShort),
                  ),
                ],
                selected: {_convertType},
                onSelectionChanged: (sel) async {
                  final type = sel.first;
                  setState(() => _convertType = type);
                  try {
                    await ref.read(bookApiProvider).setChineseConvertType(type);
                    // 转换类型变更后重新加载当前章正文
                    if (mounted) {
                      unawaited(
                        ref
                            .read(readerNotifierProvider.notifier)
                            .reloadChapterContent(),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(
                        SnackBar(
                          content: Text(
                            AppStrings.chineseConvertFailed(errorMessage(e)),
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 两端对齐（对标原版 MoreConfig textFullJustify）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.textJustify),
          subtitle: Text(AppStrings.textJustifyHint),
          value: _config.textFullJustify,
          onChanged: (v) {
            _config.textFullJustify = v;
            _commit();
          },
        ),
        // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批无平台依赖项：
        // 按原版 pref_config_read.xml 项序与文案补齐，每项真实生效
        // （对标 MoreConfigDialog.onSharedPreferenceChanged 事件语义）— Qoder
        // 屏幕方向（原版第 1 项 screenOrientation）
        _moreRow(AppStrings.screenOrientationLabel,
            _orientationLabel(_config.screenOrientation), () {
          _showChoiceDialog<int>(
            title: AppStrings.screenOrientationLabel,
            current: _config.screenOrientation,
            options: {
              0: AppStrings.themeSystem,
              1: AppStrings.portraitLabel,
              2: AppStrings.landscapeLabel,
              3: AppStrings.orientationAutoSensor,
              4: AppStrings.orientationPortraitReverse,
              5: AppStrings.orientationLandscapeReverse,
            },
            onPick: (v) {
              _config.screenOrientation = v;
              _commit();
            },
          );
        }),
        // 保持亮屏（原版第 2 项 keep_light；平台限制诚实标注：项目未引入
        // wakelock 依赖（不改 pubspec），设置仅持久化，待平台能力接入后生效，
        // 与 audio_screen 的 audioWakeLock 标注一致）
        _moreRow(AppStrings.keepScreenAwake, _keepLightLabel(_config.keepLight),
            () {
          _showChoiceDialog<int>(
            title: AppStrings.keepScreenAwake,
            current: _config.keepLight,
            options: {
              0: AppStrings.defaultLabel,
              60: AppStrings.minutes1,
              300: AppStrings.minutes5,
              600: AppStrings.minutes10,
              -1: AppStrings.keepAlways,
            },
            onPick: (v) {
              _config.keepLight = v;
              _commit();
            },
          );
        }),
        // 隐藏状态栏（原版第 3 项：SystemUiMode 移除顶部 overlay）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.hideStatusBarLabel),
          subtitle: Text(AppStrings.hideStatusBarHint),
          value: _config.hideStatusBar,
          onChanged: (v) {
            _config.hideStatusBar = v;
            _commit();
          },
        ),
        // 隐藏导航栏（原版第 4 项：SystemUiMode 移除底部 overlay）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.hideNavigationBarLabel),
          subtitle: Text(AppStrings.hideNavigationBarHint),
          value: _config.hideNavigationBar,
          onChanged: (v) {
            _config.hideNavigationBar = v;
            _commit();
          },
        ),
        // 进度条行为（原版第 8 项 progressBarBehavior：调章内页/调章节）
        _moreRow(
          AppStrings.progressBarBehaviorLabel,
          _config.progressBarBehavior == 'page'
              ? AppStrings.progressBarPage
              : AppStrings.progressBarChapter,
          () {
            _showChoiceDialog<String>(
              title: AppStrings.progressBarBehaviorLabel,
              current: _config.progressBarBehavior,
              options: {
                'page': AppStrings.progressBarPage,
                'chapter': AppStrings.progressBarChapter,
              },
              onPick: (v) {
                _config.progressBarBehavior = v;
                _commit();
              },
            );
          },
        ),
        // 自动换源（原版 autoChangeSource：章节加载失败自动切换书源）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.autoChangeSourceLabel),
          subtitle: Text(AppStrings.autoChangeSourceHint),
          value: _config.autoChangeSource,
          onChanged: (v) {
            _config.autoChangeSource = v;
            _commit();
          },
        ),
        // 长按选择文本（原版 selectText：长按正文选区面板启停）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.selectTextLongPressLabel),
          subtitle: Text(AppStrings.selectTextLongPressHint),
          value: _config.selectText,
          onChanged: (v) {
            _config.selectText = v;
            _commit();
          },
        ),
        // [批3b] 亮度调节控件（模式/位置）已回迁到阅读菜单系统
        // 「全局」子页，避免「更多」页重复入口。
        // 滚动翻页无动画（原版 noAnimScrollPage：程序化翻页去除动画）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.noAnimScrollPageLabel),
          subtitle: Text(AppStrings.noAnimScrollPageHint),
          value: _config.noAnimScrollPage,
          onChanged: (v) {
            _config.noAnimScrollPage = v;
            _commit();
          },
        ),
        // [批1b-2b] 点击图片方式（原版 clickImgWay：0 默认行为/1 预览/
        // 2 兼容旧版/3 关闭/4 双击生效；参考版默认 "2"）。文本阅读器
        // 尚无行内图片渲染，当前消费点为 image-dominant 图片页 —
        // 语义见 utils/click_img_way.dart
        _moreRow(AppStrings.clickImageActionLabel,
            clickImgWayLabel(_config.clickImgWay), () {
          _showChoiceDialog<String>(
            title: AppStrings.clickImageActionLabel,
            current: clampClickImgWay(_config.clickImgWay),
            options: kClickImgWayOptions,
            onPick: (v) {
              _config.clickImgWay = v;
              _commit();
            },
          );
        }),
        // 显示标题附加区（原版 showReadTitleAddition：顶栏书名后追加章名）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.showTitleAdditionLabel),
          subtitle: Text(AppStrings.showTitleAdditionHint),
          value: _config.showReadTitleAddition,
          onChanged: (v) {
            _config.showReadTitleAddition = v;
            _commit();
          },
        ),
        // [批3a] more 页由菜单系统「全局 → 工具栏样式」承载；all 页
        // 保持原样保留旧开关（旧键仍参与一次性迁移）。
        if (includeToolbarFollowPage) ...[
          // 工具栏跟随页面（原版 readBarStyleFollowPage：顶/底栏背景与文字色
          // 跟随当前阅读页配色，对标 ReadMenu immersiveMenu）
          // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              vertical: 12,
              horizontal: 8,
            ),
            title: Text(AppStrings.toolbarFollowPageLabel),
            subtitle: Text(AppStrings.toolbarFollowPageHint),
            value: _config.readBarStyleFollowPage,
            onChanged: (v) {
              _config.readBarStyleFollowPage = v;
              _commit();
            },
          ),
        ],
        // [UI-fix v2.0.4 | 2026-08-08] MoreConfig 第②批：按原版
        // pref_config_read.xml 项序与文案补齐，平台受限项以副标题
        // 灰字诚实标注（不引入新依赖）— Qoder
        // 扩展到刘海（原版 readBodyToLh；仅 Android 生效）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.extendToCutoutLabel),
          subtitle: Text(AppStrings.extendToCutoutHint),
          value: _config.readBodyToLh,
          onChanged: (v) {
            _config.readBodyToLh = v;
            _commit();
          },
        ),
        // 填充刘海区域（原版 paddingDisplayCutouts；仅 Android 生效）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.fillDisplayCutoutLabel),
          subtitle: Text(AppStrings.fillDisplayCutoutHint),
          value: _config.paddingDisplayCutouts,
          onChanged: (v) {
            _config.paddingDisplayCutouts = v;
            _commit();
          },
        ),
        // 平板/横屏双页（原版 doubleHorizontalPage，4 档；已接入渲染）
        _moreRow(AppStrings.dualPageHorizontalLabel,
            _doublePageLabel(_config.doubleHorizontalPage), () {
          _showChoiceDialog<int>(
            title: AppStrings.dualPageHorizontalLabel,
            current: _config.doubleHorizontalPage,
            options: {
              0: AppStrings.dualPageGlobalSingle,
              1: AppStrings.dualPageGlobalDouble,
              2: AppStrings.dualPageLandscapeDouble,
              3: AppStrings.dualPageHorizontalLabel,
            },
            onPick: (v) {
              _config.doubleHorizontalPage = v;
              _commit();
            },
          );
        }),
        // 使用自定义中文分行（原版 useZhLayout；关闭后走朴素按宽断行）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.useZhLayoutLabel),
          subtitle: Text(AppStrings.useZhLayoutHint),
          value: _config.useZhLayout,
          onChanged: (v) {
            _config.useZhLayout = v;
            _commit();
          },
        ),
        // 段首标点悬挂（原版 hangingPunctuation；已接入排版引擎）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.hangingPunctuationLabel),
          subtitle: Text(AppStrings.hangingPunctuationHint),
          value: _config.hangingPunctuation,
          onChanged: (v) {
            _config.hangingPunctuation = v;
            _commit();
          },
        ),
        // 鼠标滚轮翻页（原版 mouseWheelPage；桌面端真实生效）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.mouseWheelPageLabel),
          subtitle: Text(AppStrings.mouseWheelPageHint),
          value: _config.mouseWheelPage,
          onChanged: (v) {
            _config.mouseWheelPage = v;
            _commit();
          },
        ),
        // 音量键翻页（原版 volumeKeyPage；桌面端无音量键事件）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.mangaVolumeKey),
          subtitle: Text(AppStrings.androidOnlyLabel),
          value: _config.volumeKeyPage,
          onChanged: (v) {
            _config.volumeKeyPage = v;
            _commit();
          },
        ),
        // 朗读时音量键翻页（原版 volumeKeyPageOnPlay；仅 Android 生效）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 8,
          ),
          title: Text(AppStrings.volumeKeyPageOnPlayLabel),
          subtitle: Text(AppStrings.androidOnlyLabel),
          value: _config.volumeKeyPageOnPlay,
          onChanged: (v) {
            _config.volumeKeyPageOnPlay = v;
            _commit();
          },
        ),
        // 滑动翻页阈值（原版 pageTouchSlop：NumberPicker 0-9999，
        // 0=系统默认值；[fix Task#41 | 2026-08-09] 已经 reader_page_view
        // 的 MediaQuery.gestureSettings 覆写拖拽识别阈值，修改即时生效）
        _moreRow(
          AppStrings.pageTouchSlopLabel,
          _config.pageTouchSlop == 0
              ? AppStrings.raSystemDefault
              : '${_config.pageTouchSlop}px',
          () {
            _showNumberDialog(
              title: AppStrings.pageTouchSlopDialogTitle,
              current: _config.pageTouchSlop,
              max: 9999,
              onPick: (v) {
                _config.pageTouchSlop = v;
                _commit();
              },
            );
          },
        ),
        // 边缘点击阈值（原版 pageTouchClick：NumberPicker 0-399，
        // 左右边缘多少距离不触发点击；[fix Task#41 | 2026-08-09] 已经
        // reader_screen._handleTap 收缩左右分区边缘死区，修改即时生效）
        _moreRow(AppStrings.edgeClickThresholdLabel,
            '${_config.pageTouchClick}px', () {
          _showNumberDialog(
            title: AppStrings.edgeClickThresholdLabel,
            current: _config.pageTouchClick,
            max: 399,
            onPick: (v) {
              _config.pageTouchClick = v;
              _commit();
            },
          );
        }),
      ],
    );
  }

  // ===== MoreConfig 第②批辅助构建方法 =====

  /// 双页模式档位显示文案（对齐原版 R.array.double_page_title）
  String _doublePageLabel(int v) {
    final labels = [
      AppStrings.dualPageGlobalSingle,
      AppStrings.dualPageGlobalDouble,
      AppStrings.dualPageLandscapeDouble,
      AppStrings.dualPageHorizontalLabel,
    ];
    if (v < 0 || v >= labels.length) return AppStrings.dualPageGlobalSingle;
    return labels[v];
  }

  /// 数值输入对话框（对标原版 NumberPickerDialog，桌面端用文本输入）
  void _showNumberDialog({
    required String title,
    required int current,
    required int max,
    required ValueChanged<int> onPick,
  }) {
    final controller = TextEditingController(text: current.toString());
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: '0 ~ $max'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppStrings.cancel),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text) ?? current;
              Navigator.pop(dialogContext);
              onPick(v.clamp(0, max));
            },
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
  }

  // ===== MoreConfig 第①批辅助构建方法 =====

  String _orientationLabel(int v) {
    final labels = [
      AppStrings.themeSystem,
      AppStrings.portraitLabel,
      AppStrings.landscapeLabel,
      AppStrings.orientationAutoSensor,
      AppStrings.orientationPortraitReverse,
      AppStrings.orientationLandscapeReverse,
    ];
    if (v < 0 || v >= labels.length) return AppStrings.themeSystem;
    return labels[v];
  }

  String _keepLightLabel(int v) {
    switch (v) {
      case 60:
        return AppStrings.minutes1;
      case 300:
        return AppStrings.minutes5;
      case 600:
        return AppStrings.minutes10;
      case -1:
        return AppStrings.keepAlways;
      default:
        return AppStrings.defaultLabel;
    }
  }

  /// 列表选择行（当前值 + 点击弹出单选对话框）
  Widget _moreRow(String title, String current, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        // [LAYOUT_PLAN P1] 组内行 vertical12/horizontal8
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
            ),
            Flexible(
              child: Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_drop_down,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 单选对话框（对标原版 ListPreference 弹层选择交互；
  /// [UI-fix v2.0.4 | 2026-08-08] RadioListTile 改 ListTile+勾选，
  /// 避开 groupValue/onChanged 弃用 API — Qoder）
  void _showChoiceDialog<T>({
    required String title,
    required T current,
    required Map<T, String> options,
    required ValueChanged<T> onPick,
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          for (final entry in options.entries)
            ListTile(
              title: Text(entry.value),
              trailing: current == entry.key
                  ? Icon(
                      Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary,
                    )
                  : null,
              onTap: () {
                Navigator.pop(dialogContext);
                onPick(entry.key);
              },
            ),
        ],
      ),
    );
  }

  // ===== 亮度控制 =====

  Widget _buildBrightnessControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppStrings.brightnessControlSection,
            Icons.brightness_6_outlined),
        FutureBuilder<bool>(
          future: SystemBrightness.isSupported(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
              return const Center(child: AppCircularProgressIndicator());
            }

            final supported = snapshot.data ?? false;
            if (!supported) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  AppStrings.brightnessUnsupported,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }

            return FutureBuilder<bool>(
              future: SystemBrightness.isAutoBrightness(),
              builder: (context, autoSnapshot) {
                if (autoSnapshot.connectionState != ConnectionState.done) {
                  // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
                  return const Center(child: AppCircularProgressIndicator());
                }

                final isAuto = autoSnapshot.data ?? false;

                return Column(
                  children: [
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(AppStrings.autoBrightness),
                      subtitle: Text(AppStrings.autoBrightnessHint),
                      value: isAuto,
                      onChanged: (v) async {
                        await SystemBrightness.setAutoBrightness(v);
                        setState(() {});
                      },
                    ),
                    if (!isAuto) ...[
                      const SizedBox(height: 8),
                      FutureBuilder<double>(
                        future: SystemBrightness.getBrightness(),
                        builder: (context, brightnessSnapshot) {
                          if (brightnessSnapshot.connectionState !=
                              ConnectionState.done) {
                            // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
                            return const Center(
                              child: AppCircularProgressIndicator(),
                            );
                          }

                          final brightness = brightnessSnapshot.data ?? 0.5;

                          return Row(
                            children: [
                              Icon(
                                Icons.brightness_low,
                                size: 20,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              Expanded(
                                child: Slider(
                                  value: brightness,
                                  min: 0.0,
                                  max: 1.0,
                                  divisions: 20,
                                  label: '${(brightness * 100).round()}%',
                                  onChanged: (v) async {
                                    await SystemBrightness.setBrightness(v);
                                    setState(() {});
                                  },
                                ),
                              ),
                              Icon(
                                Icons.brightness_high,
                                size: 20,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              SizedBox(
                                width: 48,
                                child: Text(
                                  '${(brightness * 100).round()}%',
                                  textAlign: TextAlign.end,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }
}
