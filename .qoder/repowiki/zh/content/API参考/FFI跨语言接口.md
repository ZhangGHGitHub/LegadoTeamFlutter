# FFI跨语言接口

<cite>
**本文引用的文件**   
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)
- [rust/legado-ffi/src/bridge.rs](file://rust/legado-ffi/src/bridge.rs)
- [rust/legado-ffi/src/ffi.rs](file://rust/legado-ffi/src/ffi.rs)
- [rust/legado-ffi/src/frb_generated.rs](file://rust/legado-ffi/src/frb_generated.rs)
- [rust/legado-ffi/src/db_state.rs](file://rust/legado-ffi/src/db_state.rs)
- [rust/legado-ffi/src/runtime.rs](file://rust/legado-ffi/src/runtime.rs)
- [rust/legado-core/src/types.rs](file://rust/legado-core/src/types.rs)
- [rust/legado-core/src/error.rs](file://rust/legado-core/src/error.rs)
- [flutter_legado/flutter_rust_bridge.yaml](file://flutter_legado/flutter_rust_bridge.yaml)
- [app/build.gradle](file://app/build.gradle)
- [gradle.properties](file://gradle.properties)
- [rust/legado-ffi/src/api/cache_api.rs](file://rust/legado-ffi/src/api/cache_api.rs)
- [rust/legado-ffi/src/api/archive_import_api.rs](file://rust/legado-ffi/src/api/archive_import_api.rs)
- [rust/legado-ffi/src/api/download_api.rs](file://rust/legado-ffi/src/api/download_api.rs)
- [rust/legado-net/src/quic.rs](file://rust/legado-net/src/quic.rs)
</cite>

## 更新摘要
**变更内容**   
- 新增缓存API模块（114行），提供缓存管理、清理、统计等跨语言接口
- 新增归档导入API模块（161行），支持多种格式文件的导入与转换
- 新增下载API模块（62行），实现异步下载任务管理与进度回调
- 新增QUIC API模块（334行），提供高性能网络传输能力
- 扩展FFI接口架构，增强跨语言调用功能

## 目录
1. [简介](#简介)
2. [项目结构](#项目结构)
3. [核心组件](#核心组件)
4. [架构总览](#架构总览)
5. [详细组件分析](#详细组件分析)
6. [新增API模块详解](#新增api模块详解)
7. [依赖关系分析](#依赖关系分析)
8. [性能考量](#性能考量)
9. [故障排查指南](#故障排查指南)
10. [结论](#结论)
11. [附录](#附录)

## 简介
本文件面向使用 Rust 与 Android/Kotlin、Flutter/Dart 进行跨语言集成的开发者，系统性说明 Legado 项目中 FFI（外部函数接口）的调用方式、数据类型映射、内存管理、异步模式、错误传播以及各平台集成最佳实践。文档以代码仓库中的 FFI 实现为依据，提供可追溯的文件来源与图示，帮助读者快速理解并安全地扩展接口。

**最新更新**：新增了多个FFI API模块，包括缓存管理、归档导入、下载任务和QUIC网络传输功能，大幅扩展了跨语言接口的功能范围。

## 项目结构
Legado 将 FFI 相关能力集中在 Rust 侧的 legado-ffi crate 中，并通过 flutter_rust_bridge（FRB）为 Flutter/Dart 生成桥接代码；Android/Kotlin 侧通过 Gradle 构建 Rust 原生库并在应用层调用。关键目录与职责：
- Rust FFI 入口与导出：位于 rust/legado-ffi/src 下，包含桥接、运行时、数据库状态、错误类型等。
- **新增API模块**：位于 rust/legado-ffi/src/api/ 目录下，包含缓存API、归档导入API、下载API等专门的功能模块。
- Flutter 桥接配置：位于 flutter_legado/flutter_rust_bridge.yaml，定义 FRB 的生成规则与目标语言。
- Android 构建：位于 app/build.gradle 与 gradle.properties，负责编译 Rust 到 .so 并打包进 APK。

```mermaid
graph TB
subgraph "Flutter/Dart"
DartApp["Dart 应用"]
DartBridge["FRB 生成的 Dart 绑定"]
end
subgraph "Rust FFI"
FfiLib["FFI 库(lib.rs)"]
Bridge["桥接(bridge.rs)"]
Runtime["运行时(runtime.rs)"]
DBState["数据库状态(db_state.rs)"]
Types["公共类型(types.rs)"]
Error["错误(error.rs)"]
ApiModules["API模块(api/)"]
CacheApi["缓存API(cache_api.rs)"]
ArchiveApi["归档导入API(archive_import_api.rs)"]
DownloadApi["下载API(download_api.rs)"]
QuicApi["QUIC API(quic.rs)"]
end
subgraph "Android/Kotlin"
KotlinApp["Kotlin 应用"]
NdkCall["NDK/JNI 调用"]
end
DartApp --> DartBridge --> FfiLib
KotlinApp --> NdkCall --> FfiLib
FfiLib --> Bridge
FfiLib --> Runtime
FfiLib --> DBState
FfiLib --> Types
FfiLib --> Error
FfiLib --> ApiModules
ApiModules --> CacheApi
ApiModules --> ArchiveApi
ApiModules --> DownloadApi
ApiModules --> QuicApi
```

**图表来源** 
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)
- [rust/legado-ffi/src/bridge.rs](file://rust/legado-ffi/src/bridge.rs)
- [rust/legado-ffi/src/runtime.rs](file://rust/legado-ffi/src/runtime.rs)
- [rust/legado-ffi/src/db_state.rs](file://rust/legado-ffi/src/db_state.rs)
- [rust/legado-core/src/types.rs](file://rust/legado-core/src/types.rs)
- [rust/legado-core/src/error.rs](file://rust/legado-core/src/error.rs)
- [rust/legado-ffi/src/api/cache_api.rs](file://rust/legado-ffi/src/api/cache_api.rs)
- [rust/legado-ffi/src/api/archive_import_api.rs](file://rust/legado-ffi/src/api/archive_import_api.rs)
- [rust/legado-ffi/src/api/download_api.rs](file://rust/legado-ffi/src/api/download_api.rs)
- [rust/legado-net/src/quic.rs](file://rust/legado-net/src/quic.rs)

**章节来源**
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)
- [flutter_legado/flutter_rust_bridge.yaml](file://flutter_legado/flutter_rust_bridge.yaml)
- [app/build.gradle](file://app/build.gradle)
- [gradle.properties](file://gradle.properties)

## 核心组件
- FFI 库入口与导出：统一暴露给 Dart 和 Kotlin 的函数集合，负责路由到具体业务模块。
- 桥接层：处理跨语言参数编解码、生命周期与所有权转移。
- 运行时：封装线程模型、协程/回调调度、资源初始化与清理。
- 数据库状态：维护 SQLite/持久化连接的生命周期与并发访问策略。
- 公共类型与错误：定义跨语言共享的数据结构与错误码/异常信息。
- **新增API模块**：专门化的功能模块，提供缓存管理、文件导入、下载任务和网络传输等高级功能。

**章节来源**
- [rust/legado-ffi/src/bridge.rs](file://rust/legado-ffi/src/bridge.rs)
- [rust/legado-ffi/src/runtime.rs](file://rust/legado-ffi/src/runtime.rs)
- [rust/legado-ffi/src/db_state.rs](file://rust/legado-ffi/src/db_state.rs)
- [rust/legado-core/src/types.rs](file://rust/legado-core/src/types.rs)
- [rust/legado-core/src/error.rs](file://rust/legado-core/src/error.rs)

## 架构总览
下图展示 Flutter/Dart 与 Android/Kotlin 如何通过 FRB 与 JNI/NDK 调用 Rust FFI，以及数据在跨语言边界上的流转路径。

```mermaid
sequenceDiagram
participant Dart as "Dart 应用"
participant FRB as "FRB 绑定"
participant Rust as "Rust FFI"
participant Core as "核心逻辑"
participant DB as "数据库状态"
participant API as "API模块"
participant Net as "网络层"
Dart->>FRB : 调用跨语言方法
FRB->>Rust : 序列化参数并调用 C ABI
Rust->>API : 分发到API模块
API->>Core : 调用核心业务逻辑
Core->>DB : 读取/写入数据
Core->>Net : 网络请求
DB-->>Core : 返回结果或错误
Net-->>Core : 返回网络响应
Core-->>API : 构造业务对象
API-->>Rust : 构造响应对象
Rust-->>FRB : 序列化返回值
FRB-->>Dart : 返回 Future/Promise 结果
```

**图表来源** 
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)
- [rust/legado-ffi/src/frb_generated.rs](file://rust/legado-ffi/src/frb_generated.rs)
- [rust/legado-ffi/src/db_state.rs](file://rust/legado-ffi/src/db_state.rs)
- [rust/legado-ffi/src/api/cache_api.rs](file://rust/legado-ffi/src/api/cache_api.rs)
- [rust/legado-net/src/quic.rs](file://rust/legado-net/src/quic.rs)

## 详细组件分析

### FFI 库入口与导出（lib.rs）
- 职责：集中导出跨语言可调用的函数，注册 FRB 接口，统一错误包装与日志。
- 关键点：
  - 对外暴露的函数需遵循 C ABI，确保跨语言稳定。
  - 对复杂对象采用句柄/指针传递，避免大对象拷贝。
  - 错误类型统一转换为跨语言可识别的错误码或字符串。
  - **新增**：统一管理新增的API模块，提供统一的调用入口。

**章节来源**
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)

### 桥接层（bridge.rs）
- 职责：处理 Dart/Kotlin 与 Rust 之间的参数编解码、生命周期管理与内存所有权。
- 关键点：
  - 基本类型直接映射（如 i32、f64、bool、String）。
  - 复杂对象通过结构体序列化/反序列化或句柄引用。
  - 集合类型（Vec、HashMap）按约定序列化为数组/字典。
  - 生命周期：由 FRB 或 JNI 管理临时缓冲，避免悬垂指针。
  - **新增**：支持新增API模块的复杂数据结构编解码。

**章节来源**
- [rust/legado-ffi/src/bridge.rs](file://rust/legado-ffi/src/bridge.rs)

### 运行时（runtime.rs）
- 职责：管理线程池、异步任务调度、资源初始化与清理。
- 关键点：
  - 支持回调与 Future/Promise 模式，保证跨语言异步一致性。
  - 错误传播：将 Rust 错误转换为上层可捕获的异常或错误对象。
  - 资源清理：在进程退出或上下文销毁时释放句柄与缓存。
  - **新增**：优化新增API模块的资源管理和异步调度。

**章节来源**
- [rust/legado-ffi/src/runtime.rs](file://rust/legado-ffi/src/runtime.rs)

### 数据库状态（db_state.rs）
- 职责：维护数据库连接、事务与并发访问控制。
- 关键点：
  - 单例或受控实例，避免多连接竞争。
  - 读写分离与锁机制，防止死锁与数据不一致。
  - 迁移与版本管理，确保数据结构演进兼容。
  - **新增**：支持缓存API的数据库操作优化。

**章节来源**
- [rust/legado-ffi/src/db_state.rs](file://rust/legado-ffi/src/db_state.rs)

### 公共类型与错误（types.rs, error.rs）
- 职责：定义跨语言共享的数据结构与错误语义。
- 关键点：
  - 类型映射表：Rust 类型与 Dart/Kotlin 类型的对应关系。
  - 错误码规范：区分网络、解析、IO、业务错误，便于上层处理。
  - 可选字段与默认值：明确空值语义，避免歧义。
  - **新增**：扩展错误类型以支持新增API模块的特殊错误场景。

**章节来源**
- [rust/legado-core/src/types.rs](file://rust/legado-core/src/types.rs)
- [rust/legado-core/src/error.rs](file://rust/legado-core/src/error.rs)

### Flutter 桥接配置（flutter_rust_bridge.yaml）
- 职责：定义 FRB 生成规则，包括输入输出类型、异步模式、错误处理。
- 关键点：
  - 指定 Rust 源文件与 Dart 输出目录。
  - 配置 Future/Promise 行为与回调签名。
  - 自定义类型映射与序列化策略。
  - **新增**：配置新增API模块的类型映射和异步行为。

**章节来源**
- [flutter_legado/flutter_rust_bridge.yaml](file://flutter_legado/flutter_rust_bridge.yaml)

### Android 构建集成（build.gradle, gradle.properties）
- 职责：编译 Rust 为 .so 并打包进 APK，配置 NDK 工具链。
- 关键点：
  - 设置 target_abi 与优化级别。
  - 链接依赖库与符号保留规则。
  - 调试与发布版本的差异化配置。
  - **新增**：支持新增API模块的构建配置。

**章节来源**
- [app/build.gradle](file://app/build.gradle)
- [gradle.properties](file://gradle.properties)

## 新增API模块详解

### 缓存API模块（cache_api.rs）
- 职责：提供缓存管理、清理、统计等跨语言接口。
- 主要功能：
  - 缓存项的增删改查操作
  - 缓存大小统计和清理
  - 缓存过期时间管理
  - 异步缓存操作支持
- 数据类型：支持字符串、二进制数据和结构化数据的缓存
- 错误处理：提供详细的缓存操作错误码

**章节来源**
- [rust/legado-ffi/src/api/cache_api.rs](file://rust/legado-ffi/src/api/cache_api.rs)

### 归档导入API模块（archive_import_api.rs）
- 职责：支持多种格式文件的导入与转换。
- 主要功能：
  - 支持EPUB、MOBI、TXT等多种电子书格式
  - 批量导入和增量更新
  - 元数据提取和格式转换
  - 导入进度回调和错误报告
- 文件格式：自动识别和验证文件格式
- 性能优化：流式处理大文件，减少内存占用

**章节来源**
- [rust/legado-ffi/src/api/archive_import_api.rs](file://rust/legado-ffi/src/api/archive_import_api.rs)

### 下载API模块（download_api.rs）
- 职责：实现异步下载任务管理与进度回调。
- 主要功能：
  - 创建和管理下载任务
  - 断点续传和并发下载
  - 实时进度回调和状态监控
  - 下载队列和优先级管理
- 网络支持：支持HTTP、HTTPS和FTP协议
- 错误恢复：自动重试和错误恢复机制

**章节来源**
- [rust/legado-ffi/src/api/download_api.rs](file://rust/legado-ffi/src/api/download_api.rs)

### QUIC API模块（quic.rs）
- 职责：提供高性能网络传输能力。
- 主要功能：
  - QUIC协议支持和连接管理
  - 零RTT连接建立
  - 多路复用和流量控制
  - 连接迁移和错误恢复
- 性能优势：相比传统TCP显著提升传输效率
- 兼容性：向后兼容HTTP/2和HTTP/3

**章节来源**
- [rust/legado-net/src/quic.rs](file://rust/legado-net/src/quic.rs)

```mermaid
graph TD
subgraph "新增API模块架构"
CacheAPI["缓存API<br/>cache_api.rs"]
ArchiveAPI["归档导入API<br/>archive_import_api.rs"]
DownloadAPI["下载API<br/>download_api.rs"]
QuicAPI["QUIC API<br/>quic.rs"]
CacheAPI --> Core["核心业务逻辑"]
ArchiveAPI --> Core
DownloadAPI --> Network["网络层"]
QuicAPI --> Network
Core --> DB["数据库"]
Network --> Internet["互联网"]
CacheAPI -.-> Stats["统计信息"]
ArchiveAPI -.-> Format["格式转换"]
DownloadAPI -.-> Progress["进度回调"]
QuicAPI -.-> Performance["性能优化"]
end
```

**图表来源** 
- [rust/legado-ffi/src/api/cache_api.rs](file://rust/legado-ffi/src/api/cache_api.rs)
- [rust/legado-ffi/src/api/archive_import_api.rs](file://rust/legado-ffi/src/api/archive_import_api.rs)
- [rust/legado-ffi/src/api/download_api.rs](file://rust/legado-ffi/src/api/download_api.rs)
- [rust/legado-net/src/quic.rs](file://rust/legado-net/src/quic.rs)

## 依赖关系分析
Rust FFI 模块依赖核心业务库（core）、数据库（db）、网络（net）等，对外仅暴露稳定的 C ABI。Flutter/Dart 通过 FRB 生成绑定，Android/Kotlin 通过 JNI/NDK 调用。

```mermaid
graph LR
FFI["legado-ffi"] --> Core["legado-core"]
FFI --> DB["legado-db"]
FFI --> Net["legado-net"]
FFI --> Parser["legado-parser"]
FFI --> JS["legado-js"]
FFI --> Book["legado-book"]
FFI --> Server["legado-server"]
FFI --> CacheAPI["缓存API"]
FFI --> ArchiveAPI["归档导入API"]
FFI --> DownloadAPI["下载API"]
FFI --> QuicAPI["QUIC API"]
Dart["Dart 绑定"] --> FFI
Kotlin["Kotlin JNI"] --> FFI
Net --> QuicAPI
```

**图表来源** 
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)
- [rust/Cargo.toml](file://rust/Cargo.toml)
- [rust/legado-ffi/src/api/cache_api.rs](file://rust/legado-ffi/src/api/cache_api.rs)
- [rust/legado-ffi/src/api/archive_import_api.rs](file://rust/legado-ffi/src/api/archive_import_api.rs)
- [rust/legado-ffi/src/api/download_api.rs](file://rust/legado-ffi/src/api/download_api.rs)
- [rust/legado-net/src/quic.rs](file://rust/legado-net/src/quic.rs)

**章节来源**
- [rust/legado-ffi/src/lib.rs](file://rust/legado-ffi/src/lib.rs)
- [rust/Cargo.toml](file://rust/Cargo.toml)

## 性能考量
- 零拷贝传输：优先使用指针/句柄传递大对象，避免频繁序列化。
- 批量操作：合并多次调用为单次批处理，减少跨语言开销。
- 异步并行：利用线程池与协程提升吞吐，注意背压与限流。
- 内存池：复用常用对象，降低 GC 压力。
- 监控与埋点：记录耗时与错误率，定位瓶颈。
- **新增优化**：针对新增API模块的性能优化，包括缓存预加载、流式处理和连接池管理。

[本节为通用指导，无需特定文件来源]

## 故障排查指南
- 常见错误：
  - 类型不匹配：检查 FRB 配置与类型映射。
  - 内存泄漏：确认句柄释放与生命周期管理。
  - 异步回调丢失：验证线程切换与事件循环。
  - 崩溃与段错误：检查空指针与越界访问。
  - **新增问题**：API模块特定的错误，如缓存失效、导入失败、下载中断等。
- 调试技巧：
  - 启用详细日志与堆栈跟踪。
  - 使用 Valgrind/AddressSanitizer 检测内存问题。
  - 分模块隔离测试，逐步缩小范围。
  - **新增调试**：针对新增API模块的专项调试工具和监控指标。

**章节来源**
- [rust/legado-core/src/error.rs](file://rust/legado-core/src/error.rs)
- [rust/legado-ffi/src/runtime.rs](file://rust/legado-ffi/src/runtime.rs)

## 结论
Legado 的 FFI 设计以稳定性与性能为核心，通过 FRB 与 JNI/NDK 实现跨语言高效通信。随着新增的缓存API、归档导入API、下载API和QUIC API模块，跨语言接口的功能得到了显著扩展。遵循本文档的类型映射、内存管理与异步模式规范，可安全扩展接口并保障跨平台一致性。建议在新功能开发中严格遵循错误传播与资源清理最佳实践，持续监控性能指标。

[本节为总结性内容，无需特定文件来源]

## 附录
- 类型映射速查：
  - i32/i64/u32/u64 → int/long
  - f32/f64 → float/double
  - bool → boolean
  - String → string
  - Vec<T> → List<T>
  - HashMap<K,V> → Map<K,V>
  - Option<T> → nullable T
- 异步模式：
  - Dart：Future/Promise
  - Kotlin：Coroutine/Callback
  - Rust：async/await + 回调
- 集成步骤：
  - 配置 FRB 与 Gradle
  - 生成绑定代码
  - 调用示例与错误处理
- **新增API使用指南**：
  - 缓存API：适用于数据缓存和临时存储场景
  - 归档导入API：用于批量导入电子书文件
  - 下载API：处理大文件下载和进度监控
  - QUIC API：需要高性能网络传输的场景

[本节为参考信息，无需特定文件来源]