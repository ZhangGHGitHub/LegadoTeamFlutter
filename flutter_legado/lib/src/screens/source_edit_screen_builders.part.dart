// source_edit_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SourceEditBuilders 承载：字段导航 / 设置面板 / 表单构建。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'source_edit_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SourceEditBuilders on _SourceEditScreenState {

  /// 字段导航条（对齐原版 field_nav：当前 Tab 字段名横向滚动条，
  /// 选中字段下方显示主色高亮指示线，点击跳转聚焦）
  Widget _buildFieldNav() {
    final fields = switch (_lastFieldNavTab) {
      1 => _SourceEditScreenState._searchFields,
      2 => _SourceEditScreenState._exploreFields,
      3 => _SourceEditScreenState._infoFields,
      4 => _SourceEditScreenState._tocFields,
      5 => _SourceEditScreenState._contentFields,
      6 => _SourceEditScreenState._reviewFields,
      _ => _SourceEditScreenState._basicFields,
    };
    final colorScheme = Theme.of(context).colorScheme;
    // 选中字段：焦点字段优先，无焦点时默认首个字段（对齐原版默认高亮首项）
    final selected = fields.any((f) => f.key == _selectedNavField)
        ? _selectedNavField
        : fields.firstOrNull?.key;
    return Container(
      // 对齐原版 field_nav：TabLayout 高度 48dp，无水平 padding（贴边），
      // 每个字段项等宽 72dp（对齐原版 scrollable TabLayout tabMinWidth）
      height: 48,
      color: colorScheme.surfaceContainerLow,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final field in fields)
            SizedBox(
              width: 72,
              child: InkWell(
                onTap: () => _focusField(field.key),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        field.label.replaceAll(
                          RegExp(r'（.*）|\(.*\)'),
                          '',
                        ),
                        // 显式行高 1.0：48dp 栏高内文本+指示线不溢出
                        //（部分测试字体行高偏大）
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.0,
                          fontWeight: field.key == selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: field.key == selected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // 选中指示线（对齐原版 TabLayout 选中项主色横线）
                      Container(
                        height: 2,
                        width: 26,
                        decoration: BoxDecoration(
                          color: field.key == selected
                              ? colorScheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 字段导航条点击：滚动到字段并聚焦
  void _focusField(String key) {
    final fieldKey = _fieldKeys[key];
    final context = fieldKey?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    _focus(key).requestFocus();
  }

  /// 可折叠「设置」卡片（对齐原版 options_card：卡片在 Tab 栏上方；
  /// 收起态显示「设置」+ 摘要「类型 | 启用 | 发现 | CookieJar | 段评 |
  /// 事件监听 | 定制按钮」+ 展开箭头；展开显示 类型：下拉 + 开关）
  Widget _buildSettingsPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    Widget checkChip(String label, bool value, ValueChanged<bool> onChanged) {
      return SizedBox(
        width: 132,
        child: CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(
            label,
            style: const TextStyle(fontSize: 14),
          ),
          value: value,
          onChanged: (v) => setState(() => onChanged(v ?? false)),
        ),
      );
    }

    // 摘要（对齐原版 tvOptionsSummary：类型 + 勾选开关 join(" | ")）
    final summaryParts = <String>[_SourceEditScreenState._typeLabels[_bookSourceType]];
    void addSummary(String label, bool checked) {
      if (checked) summaryParts.add(label);
    }

    addSummary('启用', _enabled);
    addSummary('发现', _enabledExplore);
    addSummary('CookieJar', _cookieJar);
    addSummary('段评', _reviewEnabled);
    addSummary('事件监听', _eventListener);
    addSummary('定制按钮', _customButton);
    final summary = summaryParts.join(' | ');

    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 收起态 header：对齐原版 options_header（minHeight 48dp、
          // paddingStart 12dp / paddingEnd 4dp、内层 paddingVertical 4dp、
          // 「设置」16sp + 摘要 12sp 单行 + 展开箭头 40dp）
          InkWell(
            onTap: () =>
                setState(() => _settingsExpanded = !_settingsExpanded),
            // Semantics：合并节点文案对齐原版「设置, 摘要, 展开/收起」
            child: Semantics(
              label:
                  '设置, $summary, ${_settingsExpanded ? '收起' : '展开'}',
              button: true,
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '设置',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            Text(
                              summary,
                              // 对齐原版 tv_options_summary：单行省略
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          _settingsExpanded
                              ? Symbols.expand_less_rounded
                              : Symbols.expand_more_rounded,
                          size: 24,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ),
          ),
          if (_settingsExpanded) ...[
            // 展开内容：对齐原版 options_content（类型行 minHeight 48dp +
            // Flexbox 勾选框，paddingHorizontal 12/8、paddingBottom 4）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text('类型：', style: TextStyle(color: colorScheme.onSurface)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _bookSourceType,
                    isDense: true,
                    onChanged: (v) => setState(() => _bookSourceType = v ?? 0),
                    items: [
                      for (var i = 0; i < _SourceEditScreenState._typeLabels.length; i++)
                        DropdownMenuItem(value: i, child: Text(_SourceEditScreenState._typeLabels[i])),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Wrap(
                children: [
                  checkChip('启用', _enabled, (v) => _enabled = v),
                  checkChip('发现', _enabledExplore, (v) => _enabledExplore = v),
                  checkChip('CookieJar', _cookieJar, (v) => _cookieJar = v),
                  checkChip('段评', _reviewEnabled, (v) => _reviewEnabled = v),
                  checkChip('事件监听', _eventListener, (v) => _eventListener = v),
                  checkChip('定制按钮', _customButton, (v) => _customButton = v),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 通用表单 Tab：按字段列表构建 [TextFormField]
  /// 水平无 padding（对齐原版 RecyclerView 无 padding + item 贴边）
  Widget _buildFormTab(List<_Field> fields, {List<Widget> leading = const []}) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      children: [...leading, for (final field in fields) _buildField(field)],
    );
  }

  /// 构建单个表单字段
  ///
  /// 对齐原版 item_source_edit（TextInputLayout + CodeView）：
  /// - 无边框框、无背景填充（全局主题的灰色圆角填充框在此覆盖为透明，
  ///   与原版一致）；仅标签（灰字小号）在上、输入内容在下
  /// - 字段底部保留细分割线（Material 下划线样式，对齐原版 TextInputLayout
  ///   默认分隔线；聚焦时变主色）
  /// - 默认单行（minLines=1），输入/内容增长时展开到 [field.maxLines]
  Widget _buildField(_Field field) {
    _fieldLabels[field.key] = field.label;
    final colorScheme = Theme.of(context).colorScheme;
    final separator = Theme.of(context).dividerTheme.color ??
        colorScheme.outlineVariant;
    return KeyedSubtree(
      key: _fieldKeys.putIfAbsent(field.key, GlobalKey.new),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: TextFormField(
          controller: _ctrl(field.key),
          focusNode: _focus(field.key),
          minLines: 1,
          maxLines: field.maxLines,
          decoration: InputDecoration(
            labelText: field.required ? '${field.label} *' : field.label,
            labelStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
            hintText: field.hint,
            hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
            // 无框无背景（对齐原版 TextInputLayout，仅底部细分割线）
            filled: false,
            border: InputBorder.none,
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: separator, width: 0.5),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colorScheme.primary, width: 1),
            ),
            isDense: true,
            // 水平 12dp 内容边距（对齐原版 item_source_edit CodeView
            // paddingHorizontal=12dp：字段贴边但内容文字留 12dp 内边距）
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            suffixIconConstraints:
                const BoxConstraints(minWidth: 36, minHeight: 36),
            suffixIcon: field.maxLines >= 2
                ? IconButton(
                    tooltip: '代码编辑',
                    icon: const Icon(Symbols.code_rounded, size: 20),
                    onPressed: () => _openCodeEditForField(
                      field.key,
                      title: field.label,
                    ),
                  )
                : null,
          ),
          validator: field.required
              ? (value) => (value == null || value.trim().isEmpty)
                    ? '请输入${field.label}'
                    : null
              : null,
        ),
      ),
    );
  }
}
