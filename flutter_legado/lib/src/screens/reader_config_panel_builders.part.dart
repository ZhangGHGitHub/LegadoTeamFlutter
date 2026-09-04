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
          Text(title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ===== 翻页模式 =====

  Widget _buildFlipMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('翻页模式', Icons.auto_stories_outlined),
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
        _sectionTitle('自动翻页', Icons.timer_outlined),
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('启用自动翻页'),
          value: _config.autoPageTurn,
          onChanged: (v) {
            _config.autoPageTurn = v;
            _commit();
          },
        ),
        if (_config.autoPageTurn) ...[
          Row(
            children: [
              Text('间隔 ${_config.autoPageTurnInterval.toStringAsFixed(0)} 秒',
                  style: Theme.of(context).textTheme.bodyMedium),
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
              Text('翻页方向', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('下一章')),
                    ButtonSegment(value: false, label: Text('上一章')),
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

  // ===== 点击区域 =====

  Widget _buildTapZones() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('点击区域', Icons.touch_app_outlined),
        _tapZoneRow('左侧区域', _config.leftAction, (a) {
          _config.leftAction = a;
          _commit();
        }),
        _tapZoneRow('中间区域', _config.centerAction, (a) {
          _config.centerAction = a;
          _commit();
        }),
        _tapZoneRow('右侧区域', _config.rightAction, (a) {
          _config.rightAction = a;
          _commit();
        }),
      ],
    );
  }

  Widget _tapZoneRow(String label, TapAction current, ValueChanged<TapAction> onPick) {
    // [LAYOUT_PLAN P1] 组内行 vertical12/horizontal8
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
            child: DropdownButton<TapAction>(
              value: current,
              isExpanded: true,
              onChanged: (a) {
                if (a != null) onPick(a);
              },
              items: [
                for (final a in TapAction.values)
                  DropdownMenuItem(value: a, child: Text(a.label)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 段落间距 =====

  Widget _buildParagraphSpacing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('段落间距', Icons.format_line_spacing_outlined),
        Row(
          children: [
            Text('小', style: Theme.of(context).textTheme.bodySmall),
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
            Text('大', style: Theme.of(context).textTheme.bodySmall),
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
        _sectionTitle('字体与排版', Icons.text_fields),
        // 字体选择：跳转字体管理页，返回后触发阅读器重新加载字体
        ListTile(
          dense: true,
          // [LAYOUT_PLAN P1] 组内行 vertical12/horizontal8
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          leading: const Icon(Icons.font_download_outlined, size: 20),
          title: const Text('阅读字体'),
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
            Text('字距', style: Theme.of(context).textTheme.bodyMedium),
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
        _moreRow('首行缩进', _indentLabel(_config.paragraphIndent), () {
          _showChoiceDialog<int>(
            title: '首行缩进',
            current: _config.paragraphIndent,
            options: const {
              0: '无缩进',
              1: '一字符',
              2: '二字符',
              3: '三字符',
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
    const labels = ['无缩进', '一字符', '二字符', '三字符'];
    if (v < 0 || v >= labels.length) return '二字符';
    return labels[v];
  }

  // ===== 更多配置（对标原版 MoreConfigDialog） =====

  Widget _buildMoreConfig() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('更多配置', Icons.tune_outlined),
        // 简繁转换（接 Rust 繁简转换 FFI，对标原版 chineseConvertType）
        Row(
          children: [
            Text('简繁转换', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('不转换')),
                  ButtonSegment(value: 1, label: Text('繁→简')),
                  ButtonSegment(value: 2, label: Text('简→繁')),
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('简繁转换设置失败: $e')),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('两端对齐'),
          subtitle: const Text('正文行尾对齐（末行除外）'),
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
        _moreRow('屏幕方向', _orientationLabel(_config.screenOrientation), () {
          _showChoiceDialog<int>(
            title: '屏幕方向',
            current: _config.screenOrientation,
            options: const {
              0: '跟随系统',
              1: '竖屏',
              2: '横屏',
              3: '自动(传感器)',
              4: '反向竖屏',
              5: '反向横屏',
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
        _moreRow('保持亮屏', _keepLightLabel(_config.keepLight), () {
          _showChoiceDialog<int>(
            title: '保持亮屏',
            current: _config.keepLight,
            options: const {
              0: '默认',
              60: '1 分钟',
              300: '5 分钟',
              600: '10 分钟',
              -1: '常亮',
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('隐藏状态栏'),
          subtitle: const Text('阅读时隐藏系统状态栏'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('隐藏导航栏'),
          subtitle: const Text('阅读时隐藏系统导航栏'),
          value: _config.hideNavigationBar,
          onChanged: (v) {
            _config.hideNavigationBar = v;
            _commit();
          },
        ),
        // 进度条行为（原版第 8 项 progressBarBehavior：调章内页/调章节）
        _moreRow('进度条行为',
            _config.progressBarBehavior == 'page' ? '调章内页' : '调章节', () {
          _showChoiceDialog<String>(
            title: '进度条行为',
            current: _config.progressBarBehavior,
            options: const {
              'page': '调章内页',
              'chapter': '调章节',
            },
            onPick: (v) {
              _config.progressBarBehavior = v;
              _commit();
            },
          );
        }),
        // 自动换源（原版 autoChangeSource：章节加载失败自动切换书源）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('自动换源'),
          subtitle: const Text('章节加载失败时自动切换书源'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('长按选择文本'),
          subtitle: const Text('长按正文段落弹出选择面板'),
          value: _config.selectText,
          onChanged: (v) {
            _config.selectText = v;
            _commit();
          },
        ),
        // 显示亮度控件（原版 showBrightnessView：底栏亮度行显隐）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('显示亮度控件'),
          subtitle: const Text('底栏显示亮度调节滑条'),
          value: _config.showBrightnessView,
          onChanged: (v) {
            _config.showBrightnessView = v;
            _commit();
          },
        ),
        // 滚动翻页无动画（原版 noAnimScrollPage：程序化翻页去除动画）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('滚动翻页无动画'),
          subtitle: const Text('点击/自动翻页直接切换不带动画'),
          value: _config.noAnimScrollPage,
          onChanged: (v) {
            _config.noAnimScrollPage = v;
            _commit();
          },
        ),
        // 显示标题附加区（原版 showReadTitleAddition：顶栏书名后追加章名）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('显示标题附加区'),
          subtitle: const Text('顶栏书名后显示当前章名'),
          value: _config.showReadTitleAddition,
          onChanged: (v) {
            _config.showReadTitleAddition = v;
            _commit();
          },
        ),
        // 工具栏跟随页面（原版 readBarStyleFollowPage：顶/底栏背景与文字色
        // 跟随当前阅读页配色，对标 ReadMenu immersiveMenu）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('工具栏跟随页面'),
          subtitle: const Text('顶/底栏配色跟随阅读页背景'),
          value: _config.readBarStyleFollowPage,
          onChanged: (v) {
            _config.readBarStyleFollowPage = v;
            _commit();
          },
        ),
        // [UI-fix v2.0.4 | 2026-08-08] MoreConfig 第②批：按原版
        // pref_config_read.xml 项序与文案补齐，平台受限项以副标题
        // 灰字诚实标注（不引入新依赖）— Qoder
        // 扩展到刘海（原版 readBodyToLh；仅 Android 生效）
        // [LAYOUT_PLAN P1] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
        SwitchListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('扩展到刘海'),
          subtitle: const Text('正文延伸到刘海区域（仅 Android 生效）'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('填充刘海区域'),
          subtitle: const Text('页面边距避开刘海区域（仅 Android 生效）'),
          value: _config.paddingDisplayCutouts,
          onChanged: (v) {
            _config.paddingDisplayCutouts = v;
            _commit();
          },
        ),
        // 平板/横屏双页（原版 doubleHorizontalPage，4 档；已接入渲染）
        _moreRow('平板/横屏双页',
            _doublePageLabel(_config.doubleHorizontalPage), () {
          _showChoiceDialog<int>(
            title: '平板/横屏双页',
            current: _config.doubleHorizontalPage,
            options: const {
              0: '全局单页',
              1: '全局双页',
              2: '横屏双页',
              3: '平板/横屏双页',
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('使用自定义中文分行'),
          subtitle: const Text('开启后启用中文避头尾与更优断行'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('段首标点悬挂'),
          subtitle: const Text('段首引号等标点悬挂于缩进内，使正文首字与其他段落对齐'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('鼠标滚轮翻页'),
          subtitle: const Text('分页模式下滚轮上下滚动翻页'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('音量键翻页'),
          subtitle: const Text('仅 Android 生效'),
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
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          title: const Text('朗读时音量键翻页'),
          subtitle: const Text('仅 Android 生效'),
          value: _config.volumeKeyPageOnPlay,
          onChanged: (v) {
            _config.volumeKeyPageOnPlay = v;
            _commit();
          },
        ),
        // 滑动翻页阈值（原版 pageTouchSlop：NumberPicker 0-9999，
        // 0=系统默认值；[fix Task#41 | 2026-08-09] 已经 reader_page_view
        // 的 MediaQuery.gestureSettings 覆写拖拽识别阈值，修改即时生效）
        _moreRow('滑动翻页阈值',
            _config.pageTouchSlop == 0 ? '系统默认' : '${_config.pageTouchSlop}px',
            () {
          _showNumberDialog(
            title: '滑动翻页阈值（0 = 系统默认值）',
            current: _config.pageTouchSlop,
            max: 9999,
            onPick: (v) {
              _config.pageTouchSlop = v;
              _commit();
            },
          );
        }),
        // 边缘点击阈值（原版 pageTouchClick：NumberPicker 0-399，
        // 左右边缘多少距离不触发点击；[fix Task#41 | 2026-08-09] 已经
        // reader_screen._handleTap 收缩左右分区边缘死区，修改即时生效）
        _moreRow('边缘点击阈值', '${_config.pageTouchClick}px', () {
          _showNumberDialog(
            title: '边缘点击阈值',
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
    const labels = ['全局单页', '全局双页', '横屏双页', '平板/横屏双页'];
    if (v < 0 || v >= labels.length) return '全局单页';
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
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text) ?? current;
              Navigator.pop(dialogContext);
              onPick(v.clamp(0, max));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // ===== MoreConfig 第①批辅助构建方法 =====

  String _orientationLabel(int v) {
    const labels = ['跟随系统', '竖屏', '横屏', '自动(传感器)', '反向竖屏', '反向横屏'];
    if (v < 0 || v >= labels.length) return '跟随系统';
    return labels[v];
  }

  String _keepLightLabel(int v) {
    switch (v) {
      case 60:
        return '1 分钟';
      case 300:
        return '5 分钟';
      case 600:
        return '10 分钟';
      case -1:
        return '常亮';
      default:
        return '默认';
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
            Text(current,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    )),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                  ? Icon(Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary)
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
        _sectionTitle('亮度控制', Icons.brightness_6_outlined),
        FutureBuilder<bool>(
          future: SystemBrightness.isSupported(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            
            final supported = snapshot.data ?? false;
            if (!supported) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('此设备不支持亮度调节',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
              );
            }

            return FutureBuilder<bool>(
              future: SystemBrightness.isAutoBrightness(),
              builder: (context, autoSnapshot) {
                if (autoSnapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }

                final isAuto = autoSnapshot.data ?? false;

                return Column(
                  children: [
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('自动亮度'),
                      subtitle: const Text('根据环境光自动调节'),
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
                          if (brightnessSnapshot.connectionState != ConnectionState.done) {
                            return const Center(child: CircularProgressIndicator());
                          }

                          final brightness = brightnessSnapshot.data ?? 0.5;

                          return Row(
                            children: [
                              Icon(Icons.brightness_low, size: 20,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                              Icon(Icons.brightness_high, size: 20,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              SizedBox(
                                width: 48,
                                child: Text(
                                  '${(brightness * 100).round()}%',
                                  textAlign: TextAlign.end,
                                  style: Theme.of(context).textTheme.labelMedium,
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
