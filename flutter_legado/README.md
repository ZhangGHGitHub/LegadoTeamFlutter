| `make check` | Rust check + Flutter analyze |
| `make test` | Rust test + Flutter test |
| `make build` | 完整构建（Release）|

---

## 项目进度（截至 2026-07-30）

### 当前状态：39 屏幕 + 13 Provider + 24 FFI API，flutter analyze 0 issues，flutter test 167 passed，148/148 任务已完成

### 已完成
- 39 个页面：书架、书籍详情、阅读器（3 种翻页 + 夜间模式 + 配置面板 + 仿真动画）、搜索、书内搜索、书源管理、书源编辑、书源发现、书源调试、书源登录、听书播放器、朗读配置、定时任务、书签管理、替换规则、阅读统计、设置、主题配置、RSS、RSS 文章、RSS 收藏、RSS 源编辑、浏览器、词典、字体、二维码、导入、换源、换封面、书籍分组、关联导入、欢迎页、关于、视频播放、漫画阅读
- 13 个 Provider：Bookshelf、Reader、Search、Source、Sync、ReadingStats、Audio、AutoTask、Bookmark、Discover、ReplaceRule、Rss、Association
- 服务层：RustApi（1026 行 FFI 联通）、SettingsService、BackupService、SourceImportService、PlatformChannel、RustBridge
- 国际化：中英文双语切换
- Android 平台桥接：WebView/TTS/通知/文件选择器 4 个 MethodChannel
- APK 构建验证通过（雷电模拟器 x86_64）
- 24 个测试文件 / 167 tests passed

### 待完成
- Cronet QUIC 优化

> Rust 侧详细开发指南见 [DEVELOPMENT.md](../rust/DEVELOPMENT.md)
