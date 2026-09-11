// explore_screen.dart 的 C8 子项排布 part 文件
// （docs/UI_SCREEN_DIFF_INVENTORY_20260907.md §三 发现源二级页对齐）。
//
// [A4 形态对齐 | full-stack-engineer + UI] 展开区改 3 列 chips 分区网格：
// - 分组标题行（type=url 且无 URL 的分类项）→ 通栏纯文本分节标题
//   （对齐参考版 groupExploreSections 按空 URL 头项分节；标题文案即源数据
//   标题，与原版/参考版同义中文，不另造文案）
// - URL 项（分类/榜单/标签）→ 固定 3 列 chips（内存态重写 style 的
//   layoutFlexBasisPercent=1/3，落库数据不变）
// - 控件项（toggle/select/button/text）→ 保留数据驱动宽度，行为不变
// 点击链路不变：onCategoryTap → _openExploreShow → ExploreShowArgs
// （平板右栏 / 手机 push exploreShow），ERROR 详情弹窗链路随 ExploreKindLayout 保留。
part of 'explore_screen.dart';

/// [A4 形态对齐 | full-stack-engineer + UI] C8 分节结构：
/// 标题（空 URL 头项，可空）+ 分节内子项
class _ExploreC8Section {
  _ExploreC8Section({this.header}) : items = [];

  final ExploreCategory? header;
  final List<ExploreCategory> items;
}

/// 按参考版 groupExploreSections 规则分节：
/// 无 URL 的 url 型项作为分节标题；其后的项归属该节，
/// 直到下一个标题；控件项（toggle/select/button/text）不作标题。
List<_ExploreC8Section> _groupExploreC8Sections(List<ExploreCategory> categories) {
  final sections = <_ExploreC8Section>[];
  _ExploreC8Section? current;
  for (final c in categories) {
    final isHeader = c.type == 'url' && !(c.url?.trim().isNotEmpty ?? false);
    if (isHeader) {
      current = _ExploreC8Section(header: c);
      sections.add(current);
    } else {
      current ??= _ExploreC8Section();
      current.items.add(c);
    }
  }
  return sections;
}

/// 3 列 chips 化（内存态，不改源数据）：
/// - URL 项且非通栏（layoutFlexBasisPercent < 1.0，含无 style 默认 -1.0）
///   → 覆写为 1/3（固定 3 列）
/// - URL 项且通栏（basis >= 1.0，如「排行榜」）→ 保留全宽行不动
/// - 控件项（toggle/select/button/text）→ 保留数据驱动宽度，行为不变
/// [ExploreCategory] 为普通 const 类（非 freezed），逐项重建以覆写 style。
List<ExploreCategory> _forceThreeColumns(List<ExploreCategory> items) {
  return [
    for (final c in items)
      if (c.type == 'url' &&
          (c.url?.trim().isNotEmpty ?? false) &&
          (c.style?.layoutFlexBasisPercent ?? -1.0) < 1.0)
        ExploreCategory(
          title: c.title,
          url: c.url,
          type: c.type,
          action: c.action,
          chars: c.chars,
          defaultValue: c.defaultValue,
          viewName: c.viewName,
          style: (c.style ?? const FlexChildStyle())
              .copyWith(layoutFlexBasisPercent: 1 / 3),
        )
      else
        c,
  ];
}

/// [A4 形态对齐 | full-stack-engineer + UI] 展开区分节 3 列 chips 网格。
///
/// chip 引擎复用 [ExploreKindLayout]（不重复实现控件），
/// 每节一个实例，分节标题为通栏纯文本行。
class _ExploreSectionedChips extends StatelessWidget {
  // 内部私有组件，仅由 _SourceItemState 实例化且无 key 需求（避免
  // unused_element_parameter 警告）
  const _ExploreSectionedChips({
    required this.sourceUrl,
    required this.sourceJson,
    required this.categories,
    this.onCategoryTap,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onCategoryTap;
  final Future<void> Function()? onRefreshCategories;

  @override
  Widget build(BuildContext context) {
    final sections = _groupExploreC8Sections(categories);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final children = <Widget>[];
    for (final section in sections) {
      final header = section.header;
      if (header != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                header.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      }
      children.add(
        ExploreKindLayout(
          sourceUrl: sourceUrl,
          sourceJson: sourceJson,
          categories: _forceThreeColumns(section.items),
          onCategoryTap: onCategoryTap,
          onRefreshCategories: onRefreshCategories,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
