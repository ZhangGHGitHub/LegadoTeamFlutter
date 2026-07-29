---
kind: configuration_system
name: Android SharedPreferences + JSON 文件配置系统
category: configuration_system
scope:
    - '**'
source_files:
    - app/src/main/java/io/legado/app/App.kt
    - app/src/main/java/io/legado/app/help/config/AppConfig.kt
    - app/src/main/java/io/legado/app/help/config/ReadBookConfig.kt
    - app/src/main/java/io/legado/app/help/config/ThemeConfig.kt
    - app/src/main/java/io/legado/app/constant/PreferKey.kt
---

Legado 阅读器的配置系统以 Android SharedPreferences 为核心，辅以 JSON 配置文件和文件系统，形成多层级的运行时配置管理方案。

**核心架构与组件**
- **AppConfig**: 全局应用配置单例，实现 SharedPreferences.OnSharedPreferenceChangeListener 接口，集中管理数千个应用级开关（主题、网络、TTS、导出、WebDAV、漫画模式等），通过 PreferKey 常量统一管理所有配置键名
- **ReadBookConfig**: 阅读界面排版配置，使用 readConfig.json 和 shareReadConfig.json 两个文件存储，支持多套配色方案、字体、背景图、页边距等复杂排版设置
- **ThemeConfig**: 主题配置管理，通过 themeConfig.json 持久化主题定义，支持明/暗/EInk 三种模式的独立配色
- **LocalConfig**: 本地配置封装，直接代理到 "local" SharedPreferences

**配置加载与初始化流程**
1. Application.onCreate() 中注册 SharedPreferences 监听器：`defaultSharedPreferences.registerOnSharedPreferenceChangeListener(AppConfig)`
2. AppConfig 在构造时立即读取所有配置项到内存变量
3. 当任意配置变更时，onSharedPreferenceChanged 回调会同步更新对应内存状态
4. 部分配置（如 DNS 自定义 Hosts）变更时会触发缓存重建

**数据存储策略**
- 简单布尔/数值/字符串配置 → SharedPreferences（按功能域拆分多个 file）
- 复杂对象配置（阅读排版、主题）→ assets/defaultData 默认值 + filesDir JSON 文件覆盖
- 用户资源（背景图、字体）→ externalFiles 目录，按 MD5 命名缓存
- JS Source API Token → 独立 SharedPreferences (js_source_api_credentials)

**配置分层设计**
- 默认配置：assets/defaultData 中的初始数据
- 用户配置：SharedPreferences + JSON 文件
- 运行时状态：内存变量（AppConfig 单例属性）
- 共享配置：ReadBookConfig 的 shareLayout 模式支持跨设备分享排版配置

**关键约束**
- 所有配置键集中在 PreferKey.kt 中统一定义，避免硬编码字符串
- 配置变更必须通过对应的 getter/setter 访问，确保监听器能捕获变更
- 复杂配置（主题、阅读排版）采用 JSON 序列化，支持导入/导出/备份恢复
- EInk 模式作为特殊主题模式，优先于明/暗模式判断