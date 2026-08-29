# Legado 安卓阅读 App：微动效规格

源码范围严格限定为 app/src/main。现状依据来自 app/src/main/res/anim/anim_readbook_top_in.xml、anim_readbook_top_out.xml、anim_readbook_bottom_in.xml、anim_readbook_bottom_out.xml，app/src/main/res/animator/button_scale_animator.xml，以及 app/src/main/java/io/legado/app/ui/book/read/ReadBookActivity.kt、ReadView.kt、PageDelegate.kt、base/adapter/animations/* 和 MainActivity.kt。下表是在 Android 原生现状基础上对齐 Material 3 Motion 的推荐规格；“建议新增/统一”表示 M3 推荐，不宣称源码当前已实现。

| 场景 | 触发条件 | 动画类型 | 持续时间（ms） | 缓动曲线 | 是否可中断 | 源码依据 / M3 依据 |
|---|---|---|---:|---|---|---|
| 底部导航栏切换 Tab 指示器 | 点击或键盘切换四个 menu 项 | NavigationBar selectedIndicator 位置/尺寸插值，图标和标签颜色同步 | 250 | M3 standard / FastOutSlowIn（0.2,0,0,1） | 是；新 Tab 取消当前插值并从当前值接续 | 源码：activity_main.xml、MainActivity.kt；M3：NavigationBar indicator 200-300ms |
| 书架网格/列表切换 | BookshelfFragment 布局菜单切换展示样式 | Shared-axis X：旧布局淡出/缩放，新布局淡入，保留滚动锚点 | 300 | M3 emphasized decelerate（0.05,0.7,0.1,1） | 是；再次切换反向或接续 | 源码：fragment_books.xml、BooksAdapterGrid.kt、BooksAdapterList.kt、BaseBookshelfFragment.kt；M3：shared-axis |
| 搜索框展开与收起 | 点击 view_search/search_view，提交、返回或清除 | Container transform：宽度/圆角/色层 morph，图标与文本 cross-fade，键盘同步 | 250/200 | M3 standard；收起 emphasized accelerate（0.3,0,0.8,0.15） | 是；焦点变化或返回键立即吸附端点 | 源码：view_search.xml、SearchActivity.kt、ExploreFragment.kt、RssFragment.kt；M3：SearchBar transform |
| 阅读页顶部/底部栏呼出隐藏 | ReadView 中央热区点击或菜单动作 | 顶栏 translateY(-100%)+alpha，底栏 translateY(100%)+alpha | 220/180 | standard / emphasized accelerate | 是；重复点击、翻页、返回可取消并保持进度 | 源码：activity_book_read.xml、ReadBookActivity.kt、anim_readbook_top/bottom_in/out.xml；M3：transient surface 150-250ms |
| 翻页动画 | 左右滑动、边缘点击、音量键 | 水平 translationX；相邻页静态，支持 reduced motion 瞬时切换 | 220 | LinearInterpolator（现状）或 M3 standard | 是；连续滑动接续，取消手势回弹 | 源码：PageDelegate.kt Scroller+LinearInterpolator、ReadView.kt prev/cur/next；M3：手势动画可打断 |
| FAB 显示隐藏 | 书架滚动、搜索开始/停止、添加动作可用性变化 | scale 0.8→1 + alpha 0→1；隐藏反向；不改变布局占位 | 200/150 | emphasized decelerate / standard accelerate | 是；滚动方向反转时 cancel 并接续 | 源码：activity_book_search.xml#fb_start_stop、BaseBookshelfFragment.kt、FAB 控件；M3：FAB 150-250ms |
| 卡片点击水波纹 | 点击书架卡片、搜索结果、RSS 源卡、书源行 | bounded ripple；pressed overlay=surfaceVariant；抬起后 80ms settle，可 elevation +1dp | 180+80 | M3 standard（0.2,0,0,1） | 是；触摸取消、滚动、多指立即停止 | 源码：item 布局 clickable/focusable、selectableItemBackground；M3：StateLayer pressed/focus 12%，ripple 150-250ms |

## 统一实现约束

| 项目 | 规格 | 源码依据 / M3 依据 |
|---|---|---|
| 动效缩放 | 遵循系统 animator duration scale；scale=0 跳过非必要动画并保留状态变化 | 源码：ReadBookActivity.kt 使用 ValueAnimator.areAnimatorsEnabled()；M3：reduced motion |
| 可中断性 | 保存 Animator 引用；新状态先 cancel，再从当前值接续；禁止排队过时动画 | 源码：ReadBookActivity.kt、PaddingConfigDialog.kt 已采用 cancel；M3：interruptible motion |
| 状态优先级 | 错误、停止、返回优先于装饰性过渡；加载不阻塞返回 | 源码：搜索/阅读生命周期；M3：functional feedback priority |
| 性能 | 优先 transform/alpha，避免布局重排；列表动画仅可见项 | 源码：RecyclerAdapter 动画类、ReadView 页面缓存；M3：render-friendly motion |

— Codex + UI，2026-08-29
