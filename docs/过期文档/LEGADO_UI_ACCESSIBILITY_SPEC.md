# Legado 安卓阅读 App：10 个界面无障碍设计说明

源码范围严格限定为 app/src/main。检查依据包括 app/src/main/res/layout、res/menu、res/values 与 app/src/main/java/io/legado/app/ui。颜色对比度按 WCAG 2.1 AA 普通文本至少 4.5:1、大文本至少 3:1；触摸目标按 Android 建议最小 48dp。

## 全局结论

- 颜色：日间 onSurface(#171C1F)/surface(#F8FAFC)=16.42:1，onSurfaceVariant(#40484C)/surface=8.92:1，primary(#00658A)/surface=6.22:1，onPrimary/primary=6.50:1；夜间 onSurface(#DFE3E6)/surface(#0F1416)=14.37:1，onSurfaceVariant(#C0C8CC)/surface=10.93:1，primary(#6FD1FF)/surface=10.81:1，onPrimary/primary=7.64:1，均满足 AA。封面、自定义主题和错误色需运行时抽样。
- 触摸：IconButton、Chip、Switch、ListItem、Button、FAB 按 48dp 触控盒；view_search.xml 的 SearchView 明确为 30dp 高，属于不满足项，应外包 48dp 触控盒。
- 内容描述：封面、搜索、返回、更多、添加、停止、切换、播放、目录等功能控件必须提供 contentDescription 或可读文本；自绘 ReadView 必须暴露章节、段落和进度语义。
- 字体缩放：列表/表单支持系统字体 200%，摘要允许换行；网格标题不得裁切关键信息；阅读页正文跟随系统字号并重新分页，工具栏可滚动或折行。
- 焦点顺序：页面标题/返回 → 搜索/筛选 → 内容列表 → 浮动操作 → 底部导航；阅读器先章节标题再正文，再阅读控制；模态打开后焦点困在模态内，关闭后回到触发控件。

## 1. 书架页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 书名 onSurface、作者/章节 onSurfaceVariant，满足 AA；封面文字需叠加 scrim 后再测。 | 对动态封面文字增加 scrim 或移到封面外；自定义主题切换时自动校验。 |
| 触摸目标尺寸 | 卡片、IconButton、Tab、FAB、NavigationBar 满足；view_search.xml SearchView 原始 30dp 不满足。 | 外包 48dp 高可点击盒，设置 minWidth/minHeight=48dp；Tab 最小 48dp 高。 |
| 内容描述 | 封面朗读书名、作者、进度；未读 Badge 合并进卡片描述；搜索、更多、添加需描述。 | iv_cover 设置动态 contentDescription；卡片设置 stateDescription；装饰性进度条不聚焦。 |
| 字体缩放 | 200% 时网格标题可能截断，列表模式更稳。 | 关闭关键书名硬性 lines=2 或提供完整 TalkBack 文本；大字号网格降为列表。 |
| 焦点顺序 | TitleBar → 分组 Tab → 继续阅读 → 书籍卡片 → FAB → 底部导航。 | 设置 traversalAfter/Before；ViewPager 提供分组和页码；选择态批量栏置首。 |

## 2. 发现页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 搜索提示和结果摘要 onSurfaceVariant=8.92:1，满足 AA；选中 Chip 文字使用 onSurface。 | 动态标签执行 4.5:1 检查；错误图标不单独承载颜色信息。 |
| 触摸目标尺寸 | 卡片和 Chip 需 48dp 触控盒；SearchView 30dp 视觉高度存在风险。 | 增加 48dp 外层触控容器；Chip 视觉 32dp 但触控区扩展至 48dp。 |
| 内容描述 | 搜索框、分类 Chip、分组展开按钮、结果封面/加入书架需描述。 | 动态 Adapter 补 contentDescription/stateDescription；折叠控件提供展开/收起状态。 |
| 字体缩放 | 大字号下结果卡片易挤压封面与摘要。 | 摘要允许换行，封面至少 72dp；200% 时允许卡片转列表。 |
| 焦点顺序 | TitleBar → SearchBar → 分类 Chip 组 → 分组标题 → 结果列表 → FastScroller。 | Chip 组声明 collection heading；FastScroller 仅用户触发时进入焦点。 |

## 3. RSS 订阅页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 源名称、未读数与 surface 对比满足 AA；图标不能单独表达未读。 | 未读同时输出“18 条未读”；自定义图标背景增加 outline。 |
| 触摸目标尺寸 | 源卡满足；添加按钮为 48dp IconButton；四列网格在窄屏可能过窄。 | 窄屏降为 2 列并保持最小 48dp 点击盒。 |
| 内容描述 | 源图标、未读徽标、添加/收藏/刷新需描述；装饰性图标隐藏。 | 卡片描述合并源名称、未读数、更新时间；网格声明 collectionInfo。 |
| 字体缩放 | 4 列网格在 200% 下名称易截断。 | 大字号自动 2 列/列表；名称允许最多 3 行。 |
| 焦点顺序 | TitleBar → SearchBar → 分组 Chip → RSS 源按行 → 底部导航。 | RecyclerView 设置 collectionItemInfo；刷新后恢复原源卡焦点。 |

## 4. 我的/设置页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 标题、摘要和图标使用 onSurface/onSurfaceVariant，满足 AA；禁用项需达到大文本 3:1。 | 禁用正文不要低于 4.5:1；错误 Banner 使用 errorContainer/onErrorContainer。 |
| 触摸目标尺寸 | Preference、Switch、Slider、按钮可满足 48dp；自定义图标操作需检查 padding。 | Preference row 设置 minHeight=48dp；Slider 使用透明 48dp 触控轨道。 |
| 内容描述 | 开关朗读标题与当前值；滑杆输出数值与范围；颜色选择、主题预览需描述。 | 补 stateDescription、rangeInfo；装饰性预览标记为非重要。 |
| 字体缩放 | 列表结构利于大字号，但副标题若 singleLine 会截断。 | 摘要改为可换行；避免固定高度。 |
| 焦点顺序 | TitleBar → 分组标题 → 设置项 → 二级页返回；Dialog 首焦点为标题或当前值。 | Preference 层级顺序；Dialog 打开请求焦点，关闭恢复触发项。 |

## 5. 搜索页与搜索结果页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 输入文本、结果标题和摘要满足 AA；停止 FAB 图标与容器至少 3:1。 | 来源标签与封面叠加文字执行运行时检查；错误横幅使用 errorContainer。 |
| 触摸目标尺寸 | 停止 FAB、结果卡满足；SearchView 30dp 不满足；历史 Chip 需扩展触控盒。 | 外层统一 48dp minHeight；清除按钮用 48dp IconButton hitSlop。 |
| 内容描述 | 搜索框、清除、范围筛选、停止、加入书架、结果封面必须描述。 | 停止按钮输出“停止搜索，已完成 n/m 个书源”；结果合并书名/作者/来源。 |
| 字体缩放 | 历史、摘要和进度文本可能挤压。 | 进度改为可换行 Snackbar/LiveRegion；大字号结果卡转纵向。 |
| 焦点顺序 | 返回 → 搜索框 → 范围/历史 → 结果列表 → 停止 FAB。 | 搜索完成后 live region 更新并将焦点移到第一条结果或错误视图；隐藏 FAB 不得聚焦。 |

## 6. 书籍详情页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 标题、作者、简介使用 onSurface/onSurfaceVariant，满足 AA；封面标题需单独测量。 | 封面文字加 scrim；按钮使用 primary/onPrimary 与 primaryContainer/onSurface。 |
| 触摸目标尺寸 | 返回、开始阅读、加入书架、目录和底部操作栏按 48dp 设计。 | 检查 tv_intro_toggle 的 48dp 高度；图标按钮补足 padding。 |
| 内容描述 | 封面、换源、换封面、目录、开始阅读、加入书架、简介展开需描述。 | 简介 toggle 输出展开/收起；按钮输出当前书架状态。 |
| 字体缩放 | 长文本可增长；横向元数据行可能溢出。 | 使用约束/弹性布局换行；不要依赖 singleLine；简介支持滚动。 |
| 焦点顺序 | 返回 → 标题/作者 → 标签 → 开始阅读 → 加入书架 → 简介 → 目录 → 底部操作。 | 底部固定操作放入最后焦点组；滚动后标题栏保留可访问标题。 |

## 7. 目录页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 章节文本 onSurface、辅助状态 onSurfaceVariant 满足 AA；当前章节容器文字使用 onSurface。 | 已读/未读不只用颜色，增加文本或图标；检查自定义高亮色。 |
| 触摸目标尺寸 | 章节行最小 48dp；搜索框、Tab、FastScroller 需 48dp 触控盒。 | FastScroller 视觉可窄但 hit target 保持 48dp；Tab 增加 vertical padding。 |
| 内容描述 | 章节行朗读卷名、章节名、已读/当前状态；搜索、返回、快速滚动需描述。 | 设置 collectionInfo/collectionItemInfo；当前章节 stateDescription=正在阅读。 |
| 字体缩放 | 章节名可换行；卷标题与章节数横排可能冲突。 | 章节行使用 minHeight；章节数移到下一行或允许折行。 |
| 焦点顺序 | 返回 → Tab → 搜索 → 卷标题 → 章节行 → 快速滚动。 | 搜索命中后焦点移到第一条命中章节；加载更多后焦点留在原章节。 |

## 8. 阅读页（日间）

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 正文 onSurface/readerSurface 满足 AA；用户自定义背景/文字颜色可能不满足。 | 保存前做对比度检查；低于 4.5:1 时提示并自动修正。 |
| 触摸目标尺寸 | 中央点击区是手势区域；菜单按钮、滑杆、上一章/下一章应≥48dp。 | 菜单 IconButton 设 48dp；边缘翻页提供可访问按钮替代。 |
| 内容描述 | ReadView 自绘正文、标题、进度、菜单、书签、高亮、朗读必须可访问。 | 实现 AccessibilityNodeProvider/虚拟节点，按章节/段落暴露文本；设置 heading、scrollable、progressBarRangeInfo。 |
| 字体缩放 | 跟随系统字号并重新分页；菜单在 200% 下可滚动。 | 正文使用 sp 与动态行高；菜单改可滚动 BottomSheet；禁止裁切章节标题。 |
| 焦点顺序 | 章节标题 → 正文段落 → 上一章/下一章 → 进度 → 菜单；菜单打开后焦点困在菜单。 | 中央手势区不抢焦点；关闭菜单恢复触发控件；章节标题设置 heading。 |

## 9. 阅读页（夜间）

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 夜间正文对比度 14.37:1，辅助文字 10.93:1，满足 AA；避免纯黑背景。 | 自定义夜间色仍执行 4.5:1；高亮使用低饱和 primaryContainer 并保留文字语义。 |
| 触摸目标尺寸 | 与日间相同，菜单、Slider、主题切换需≥48dp。 | 低亮度不缩小控件；保留 48dp 触控盒和 focus ring。 |
| 内容描述 | 另需朗读当前夜间模式状态和亮度/背景值。 | Switch 输出夜间模式已开启/关闭；颜色预览提供名称和对比度结果。 |
| 字体缩放 | 夜间长阅读需支持大字号；菜单 200% 下可滚动。 | 保证昼夜切换不重置字号；菜单使用可滚动列表。 |
| 焦点顺序 | 主题 → 亮度 → 字体 → 进度；其余同日间。 | 使用 heading 分组；关闭菜单焦点回到正文当前位置。 |

## 10. 书源管理页

| 检查项 | 现状与判定 | 不满足项改进建议 |
|---|---|---|
| 颜色对比度 | 书源名称/URL 使用 onSurface/onSurfaceVariant 满足 AA；启用状态不能只靠颜色。 | Switch 同时输出启用/停用文本；错误状态使用图标 + 文案 + error 语义色。 |
| 触摸目标尺寸 | 书源行、Switch、更多、添加 FAB 和批量栏按 48dp 设计；拖拽句柄需扩大 hit target。 | 句柄视觉 24dp，外层设置 48dp 可抓取区域；行高至少 72dp。 |
| 内容描述 | 图标、启用、更多、拖拽、添加、导入/扫码需要描述。 | 行合并描述“书源名、URL、已启用/已停用”；拖拽输出长按拖动排序。 |
| 字体缩放 | URL 与摘要在 200% 下易截断；尾部操作会挤压文本。 | URL 允许折行或复制完整文本；大字号时尾部操作移入更多菜单。 |
| 焦点顺序 | 返回 → 搜索 → 分组 Chip → 书源行（名称/状态/更多）→ 添加 FAB；选择态先批量栏。 | 设置行内 traversal 顺序；拖拽后焦点留在移动后的同一行；导入 Dialog 关闭恢复焦点。 |

## 验收清单

| 项目 | 验收标准 | 重点对象 |
|---|---|---|
| 对比度 | 普通文本 ≥4.5:1，大文本/图标 ≥3:1；动态封面和自定义主题抽样通过 | 正文、摘要、Badge、按钮、阅读器自定义背景 |
| 触摸目标 | 所有点击、切换、拖拽元素 hit target ≥48dp | SearchView、Chip、IconButton、FastScroller、拖拽句柄 |
| TalkBack | 无未标记控件；状态、选中、进度和错误可朗读 | CoverImageView、ReadView、动态 Adapter、Preference |
| 字体缩放 | 系统字体 200% 不遮挡、不丢失关键操作；阅读器重新分页 | 网格/列表、详情简介、搜索结果、阅读菜单 |
| 焦点 | 顺序符合视觉和任务流程；模态焦点可困住并正确恢复 | BottomSheet、Dialog、搜索结果、阅读器菜单 |

— Codex + UI，2026-08-29
