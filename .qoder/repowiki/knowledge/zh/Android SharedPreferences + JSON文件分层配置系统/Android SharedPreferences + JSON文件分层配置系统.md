---
kind: configuration_system
name: Android SharedPreferences + JSON文件分层配置系统
category: configuration_system
scope:
    - '**'
source_files:
    - app/src/main/java/io/legado/app/help/config/AppConfig.kt
    - app/src/main/java/io/legado/app/help/config/LocalConfig.kt
    - app/src/main/java/io/legado/app/help/config/ReadBookConfig.kt
    - app/src/main/java/io/legado/app/help/config/ThemeConfig.kt
    - app/src/main/java/io/legado/app/help/config/SourceConfig.kt
    - app/src/main/java/io/legado/app/constant/PreferKey.kt
    - app/src/main/java/io/legado/app/App.kt
---

Legado 阅读器的配置系统基于 Android 原生 SharedPreferences 与本地 JSON 文件构建，采用按功能域划分的多对象管理模式，在 app/src/main/java/io/legado/app/help/config 目录下集中实现。

**核心架构与分层**
- 应用级全局配置：AppConfig 单例对象（约890行），通过 SharedPreferences 存储所有应用级开关、网络、TTS、导出、WebDAV、漫画等配置项，实现 SharedPreferences.OnSharedPreferenceChangeListener 实时监听变化并同步内存状态
- 本地运行时配置：LocalConfig 直接委托给 SharedPreferences 代理模式，管理密码、版本标记、隐私协议同意状态等轻量级本地数据
- 阅读界面配置：ReadBookConfig 使用 readConfig.json 和 shareReadConfig.json 两个文件存储阅读排版、背景、字体、颜色等复杂结构配置，支持导入导出 ZIP 包
- 主题配置：ThemeConfig 使用 themeConfig.json 管理多套主题方案，支持白天/夜间/墨水屏三套配色及在线背景图缓存
- 书源评分配置：SourceConfig 使用独立 "SourceConfig" SharedPreferences 命名空间存储书源评分数据

**启动初始化流程**
App.kt 的 onCreate() 中完成配置系统初始化：注册 defaultSharedPreferences 的监听器到 AppConfig、初始化主题模式、预加载 Cronet、清理过期缓存、同步阅读记录等。onConfigurationChanged() 响应系统主题切换重新应用主题。

**配置持久化策略**
- 简单键值对：统一通过 PreferKey.kt 集中定义 key 常量，使用 getPrefXxx/putPrefXxx 扩展函数读写
- 复杂对象：JSON 序列化存储到 filesDir 下的 .json 文件，使用 GSON 进行反序列化
- 敏感信息：password 字段用于加密备份数据中的敏感配置
- 默认值：每个配置项都有明确的默认值，缺失时回退到安全默认

**实时响应机制**
AppConfig 实现 OnSharedPreferenceChangeListener，当关键配置（如字体大小、主题模式、点击区域等）变化时，立即更新内存中的对应属性，无需重启即可生效。

**Flutter/Rust 侧配置**
Flutter 端通过 flutter_rust_bridge 调用 Rust 核心库，Rust 侧使用 serde 进行 JSON 序列化，Cargo workspace 管理各 crate 依赖。配置文件主要位于 assets/defaultData/*.json 中作为默认数据。

**约束与约定**
- 所有 SharedPreferences key 必须声明在 PreferKey 对象中
- 复杂配置类使用 @Keep 注解防止混淆
- JSON 文件路径集中在各自 Config 对象的 companion object 中定义
- 配置变更通过事件总线或回调通知 UI 层刷新