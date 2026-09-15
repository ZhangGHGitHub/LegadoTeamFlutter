// source_edit_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SourceEditBuilders 承载：设置段 / 扁平表单分组构建
//（[B2-C2 2-8] 字段导航条与 Tab 表单随扁平化移除）。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'source_edit_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SourceEditBuilders on _SourceEditScreenState {
  /// 可折叠「设置」段（[B2-C2 2-8] 扁平化对齐参考版 ref 09：取消分组卡片
  /// 外壳，改为平铺段落 + 底部细分割线；收起态显示「设置」+ 摘要「类型 |
  /// 启用 | 发现 | CookieJar | 段评 | 事件监听 | 定制按钮」+ 展开箭头；
  /// 展开显示 类型：下拉 + 开关，交互行为与文案不变）
  Widget _buildSettingsSection() {
    final colorScheme = Theme.of(context).colorScheme;
    Widget checkChip(String label, bool value, ValueChanged<bool> onChanged) {
      return SizedBox(
        width: 132,
        child: CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: const TextStyle(fontSize: 14)),
          value: value,
          onChanged: (v) => setState(() => onChanged(v ?? false)),
        ),
      );
    }

    // 摘要（对齐原版 tvOptionsSummary：类型 + 勾选开关 join(" | ")）
    final summaryParts = <String>[
      _SourceEditScreenState._typeLabels[_bookSourceType],
    ];
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

    return Container(
      // [B2-C2 2-8] 扁平化：取消卡片外壳，全宽平铺 + 底部细分割线收段
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color:
                Theme.of(context).dividerTheme.color ??
                colorScheme.outlineVariant,
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 收起态 header：对齐原版 options_header（minHeight 48dp、
          // paddingStart 12dp / paddingEnd 4dp、内层 paddingVertical 4dp、
          // 「设置」16sp + 摘要 12sp 单行 + 展开箭头 40dp）
          InkWell(
            onTap: () => setState(() => _settingsExpanded = !_settingsExpanded),
            // Semantics：合并节点文案对齐原版「设置, 摘要, 展开/收起」
            child: Semantics(
              label: '设置, $summary, ${_settingsExpanded ? '收起' : '展开'}',
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
                      for (
                        var i = 0;
                        i < _SourceEditScreenState._typeLabels.length;
                        i++
                      )
                        DropdownMenuItem(
                          value: i,
                          child: Text(_SourceEditScreenState._typeLabels[i]),
                        ),
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

  /// 扁平单列规则分组段（[B2-C2 2-8] 对齐参考版 ref 09）：分组标题 +
  /// 该组字段顺序平铺（字段定义与顺序沿用原各 Tab 的数据驱动列表，
  /// 零行为变更；外层统一由单滚动列承载）
  Widget _buildFormSection(String title, List<_Field> fields) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分组标题（主色小号加粗，与正文区分；对齐参考版扁平分组头）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ),
        for (final field in fields) _buildField(field),
      ],
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
    final separator =
        Theme.of(context).dividerTheme.color ?? colorScheme.outlineVariant;
    // [B2-C2 2-8] 字段标签渲染为「常显」独立 Text（对齐原版 TextInputLayout
    // 标签在上/输入在下的形态，且保证可访问性文本可被 uiautomator 命中，
    // 而非 Material 浮动 labelText——后者在有值时不暴露为独立可访问节点）。
    final label = field.required ? '${field.label} *' : field.label;
    return KeyedSubtree(
      key: _fieldKeys.putIfAbsent(field.key, GlobalKey.new),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            TextFormField(
              // [B2-C2 2-8] 标签已上移为常显 Text（见上），为保持可测性，
              // 字段以 ValueKey('sf_<field.key>') 稳定标识（供 widget 测试
              // find.byKey 定位；field.key 各分组内唯一）。
              key: ValueKey<String>('sf_${field.key}'),
              controller: _ctrl(field.key),
              focusNode: _focus(field.key),
              minLines: 1,
              maxLines: field.maxLines,
              decoration: InputDecoration(
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
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
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
          ],
        ),
      ),
    );
  }
}
