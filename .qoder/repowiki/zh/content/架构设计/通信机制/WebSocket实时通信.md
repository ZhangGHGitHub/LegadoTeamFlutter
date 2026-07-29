# WebSocket实时通信

<cite>
**本文引用的文件**   
- [server.rs](file://rust/legado-server/src/server.rs)
- [routes.rs](file://rust/legado-server/src/routes.rs)
- [state.rs](file://rust/legado-server/src/state.rs)
- [lib.rs](file://rust/legado-server/src/lib.rs)
- [ws/mod.rs](file://rust/legado-server/src/ws/mod.rs)
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/connection.rs](file://rust/legado-server/src/ws/connection.rs)
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)
- [error.rs](file://rust/legado-server/src/error.rs)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)
- [api/index.ts](file://modules/web/src/api/index.ts)
- [SourceDebug.vue](file://modules/web/src/components/SourceDebug.vue)
- [BookShelf.vue](file://modules/web/src/views/BookShelf.vue)
</cite>

## 目录
1. [简介](#简介)
2. [项目结构](#项目结构)
3. [核心组件](#核心组件)
4. [架构总览](#架构总览)
5. [详细组件分析](#详细组件分析)
6. [依赖关系分析](#依赖关系分析)
7. [性能考虑](#性能考虑)
8. [故障排查指南](#故障排查指南)
9. [结论](#结论)
10. [附录](#附录)

## 简介
本文件面向Legado项目的WebSocket实时通信能力，系统性说明连接建立、心跳检测、断线重连与连接池管理；定义消息协议（格式、事件类型、状态管理）；覆盖典型使用场景（书籍搜索进度、源调试信息、阅读状态同步等）；并给出序列化、压缩传输与带宽优化建议，以及调试方法与监控指标。

## 项目结构
WebSocket功能由后端Rust服务与前端Web模块共同实现：
- 后端服务位于 rust/legado-server，提供HTTP路由与WebSocket端点，维护连接池、会话状态与业务处理器。
- 前端位于 modules/web，通过store与API层封装WebSocket连接、消息收发与UI联动。

```mermaid
graph TB
subgraph "前端 Web"
UI["页面组件<br/>SourceDebug.vue / BookShelf.vue"]
Store["连接存储<br/>connectionStore.ts"]
API["API封装<br/>api/index.ts"]
end
subgraph "后端 Rust Server"
Routes["路由注册<br/>routes.rs"]
WSMod["WS模块入口<br/>ws/mod.rs"]
Handler["WS处理器<br/>ws/handler.rs"]
Conn["连接抽象<br/>ws/connection.rs"]
Pool["连接池<br/>ws/pool.rs"]
State["全局状态<br/>state.rs"]
H_Source["源处理<br/>handlers/source.rs"]
H_Search["搜索处理<br/>handlers/search.rs"]
H_ReadState["阅读状态处理<br/>handlers/read_state.rs"]
end
UI --> Store --> API
API --> Routes
Routes --> WSMod --> Handler
Handler --> Conn
Handler --> Pool
Handler --> State
Handler --> H_Source
Handler --> H_Search
Handler --> H_ReadState
```

**图表来源** 
- [routes.rs](file://rust/legado-server/src/routes.rs)
- [ws/mod.rs](file://rust/legado-server/src/ws/mod.rs)
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/connection.rs](file://rust/legado-server/src/ws/connection.rs)
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [state.rs](file://rust/legado-server/src/state.rs)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)

**章节来源**
- [server.rs](file://rust/legado-server/src/server.rs)
- [routes.rs](file://rust/legado-server/src/routes.rs)
- [state.rs](file://rust/legado-server/src/state.rs)
- [lib.rs](file://rust/legado-server/src/lib.rs)

## 核心组件
- WebSocket模块入口与路由：负责将HTTP请求升级为WebSocket，并将路径映射到具体处理器。
- 连接处理器：解析消息、分发到业务处理器、维护心跳与超时、错误上报。
- 连接抽象：封装发送/接收、关闭、状态标记、上下文信息。
- 连接池：按主题或会话维度管理活跃连接，支持广播与定向推送。
- 全局状态：保存配置、统计指标、限流策略、订阅关系。
- 业务处理器：针对“源调试”“搜索进度”“阅读状态”等场景的消息编排与转发。
- 前端连接存储与API封装：统一创建连接、自动重连、心跳、消息编解码与事件派发。

**章节来源**
- [ws/mod.rs](file://rust/legado-server/src/ws/mod.rs)
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/connection.rs](file://rust/legado-server/src/ws/connection.rs)
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [state.rs](file://rust/legado-server/src/state.rs)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)
- [api/index.ts](file://modules/web/src/api/index.ts)

## 架构总览
下图展示从浏览器发起WebSocket连接到服务端处理、业务分发与回推的完整流程。

```mermaid
sequenceDiagram
participant FE as "前端页面"
participant Store as "连接存储"
participant API as "API封装"
participant RT as "路由"
participant WS as "WS处理器"
participant POOL as "连接池"
participant H as "业务处理器"
FE->>Store : "初始化连接配置"
Store->>API : "创建WebSocket连接"
API->>RT : "HTTP升级请求"
RT-->>WS : "握手成功，进入WS通道"
WS->>POOL : "注册连接/分配会话ID"
WS->>WS : "启动心跳检测"
WS->>H : "分发消息(类型/参数)"
H-->>WS : "返回结果/事件"
WS-->>API : "发送响应/推送"
API-->>FE : "触发回调/更新UI"
Note over WS,POOL : "断线时触发重连策略"
```

**图表来源** 
- [routes.rs](file://rust/legado-server/src/routes.rs)
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [api/index.ts](file://modules/web/src/api/index.ts)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)

## 详细组件分析

### WebSocket连接生命周期与心跳
- 连接建立：前端通过API封装发起升级请求，后端路由识别并交由WS处理器接管。
- 心跳机制：客户端周期性发送心跳帧，服务端在连接上维护最后活跃时间，超过阈值判定为断开。
- 断线重连：前端检测到断开后执行指数退避重试，携带上次会话ID以尝试恢复上下文。
- 连接回收：服务端定期清理超时连接，释放资源并通知相关订阅者。

```mermaid
flowchart TD
Start(["连接建立"]) --> HeartbeatStart["启动心跳定时器"]
HeartbeatStart --> SendPing{"收到心跳?"}
SendPing --> |是| ResetTimer["重置超时计时器"]
ResetTimer --> SendPing
SendPing --> |否| Timeout["触发超时断开"]
Timeout --> Cleanup["清理连接/释放资源"]
Cleanup --> End(["结束"])
```

**图表来源** 
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/connection.rs](file://rust/legado-server/src/ws/connection.rs)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)

**章节来源**
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/connection.rs](file://rust/legado-server/src/ws/connection.rs)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)

### 连接池与会话管理
- 连接池按主题或会话维度组织活跃连接，支持广播与定向推送。
- 会话元数据包含用户标识、设备信息、订阅列表、权限与限流计数。
- 连接池提供增删查改接口，并在连接关闭时自动清理。

```mermaid
classDiagram
class ConnectionPool {
+register(connection)
+remove(connection)
+broadcast(message)
+sendTo(sessionId, message)
+getActiveCount() int
}
class Session {
+sessionId string
+userId string
+subscriptions list
+lastActive timestamp
+isAlive() bool
}
ConnectionPool --> Session : "管理多个会话"
```

**图表来源** 
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [state.rs](file://rust/legado-server/src/state.rs)

**章节来源**
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [state.rs](file://rust/legado-server/src/state.rs)

### 消息协议设计
- 消息格式：采用JSON结构，包含字段如类型、载荷、时间戳、序列号、压缩标志等。
- 事件类型：
  - 控制类：连接、心跳、认证、订阅、取消订阅、错误。
  - 业务类：源调试日志、搜索进度、阅读状态同步、任务状态更新。
- 状态管理：客户端与服务端各自维护连接状态机（未连接、连接中、已连接、断开、重连中），并通过事件驱动更新UI。

```mermaid
flowchart TD
A["收到消息"] --> B{"解析JSON"}
B --> |失败| E["返回错误事件"]
B --> |成功| C{"判断类型"}
C --> |控制| D1["处理连接/心跳/认证/订阅"]
C --> |业务| D2["分发到对应处理器"]
D1 --> F["生成响应/广播"]
D2 --> F
F --> G["发送回客户端"]
E --> G
```

**图表来源** 
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)

**章节来源**
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)

### 使用场景
- 书籍搜索进度：前端订阅搜索主题，服务端按批次推送进度与结果片段，避免轮询。
- 源调试信息：开发者通过调试面板订阅源日志，实时查看网络请求、规则匹配与异常堆栈。
- 阅读状态同步：多端同步当前页码、书签、阅读偏好，保证一致体验。

```mermaid
sequenceDiagram
participant FE as "前端"
participant WS as "WS处理器"
participant SRC as "源处理器"
participant SRCH as "搜索处理器"
participant RS as "阅读状态处理器"
FE->>WS : "订阅搜索/调试/阅读状态"
WS->>SRCH : "转发搜索请求"
SRCH-->>WS : "推送进度/结果"
WS-->>FE : "更新搜索结果"
FE->>WS : "订阅源调试"
WS->>SRC : "转发调试开关"
SRC-->>WS : "推送日志/错误"
WS-->>FE : "渲染调试面板"
FE->>WS : "同步阅读状态"
WS->>RS : "持久化/广播"
RS-->>WS : "确认/冲突解决"
WS-->>FE : "状态同步完成"
```

**图表来源** 
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)

**章节来源**
- [SourceDebug.vue](file://modules/web/src/components/SourceDebug.vue)
- [BookShelf.vue](file://modules/web/src/views/BookShelf.vue)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)

### 序列化、压缩与带宽优化
- 序列化：统一JSON编码，对大文本字段启用可选压缩标志，服务端按需解压。
- 压缩传输：对批量结果或长日志进行Gzip/Brotli压缩，减少带宽占用。
- 分片与批处理：将大数据拆分为分片消息，结合序列号保证顺序与完整性。
- 去抖与合并：前端对高频事件进行去抖，服务端聚合相似事件后再推送。

**章节来源**
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [api/index.ts](file://modules/web/src/api/index.ts)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)

## 依赖关系分析
- 路由依赖WS模块，WS模块依赖连接抽象、连接池与全局状态。
- 业务处理器依赖数据库与外部网络库，但通过WS处理器解耦。
- 前端依赖API封装与连接存储，屏蔽底层连接细节。

```mermaid
graph LR
Routes["routes.rs"] --> WSMod["ws/mod.rs"]
WSMod --> Handler["ws/handler.rs"]
Handler --> Conn["ws/connection.rs"]
Handler --> Pool["ws/pool.rs"]
Handler --> State["state.rs"]
Handler --> H_Source["handlers/source.rs"]
Handler --> H_Search["handlers/search.rs"]
Handler --> H_ReadState["handlers/read_state.rs"]
API["api/index.ts"] --> Store["connectionStore.ts"]
Store --> UI["SourceDebug.vue / BookShelf.vue"]
```

**图表来源** 
- [routes.rs](file://rust/legado-server/src/routes.rs)
- [ws/mod.rs](file://rust/legado-server/src/ws/mod.rs)
- [ws/handler.rs](file://rust/legado-server/src/ws/handler.rs)
- [ws/connection.rs](file://rust/legado-server/src/ws/connection.rs)
- [ws/pool.rs](file://rust/legado-server/src/ws/pool.rs)
- [state.rs](file://rust/legado-server/src/state.rs)
- [handlers/source.rs](file://rust/legado-server/src/handlers/source.rs)
- [handlers/search.rs](file://rust/legado-server/src/handlers/search.rs)
- [handlers/read_state.rs](file://rust/legado-server/src/handlers/read_state.rs)
- [api/index.ts](file://modules/web/src/api/index.ts)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)
- [SourceDebug.vue](file://modules/web/src/components/SourceDebug.vue)
- [BookShelf.vue](file://modules/web/src/views/BookShelf.vue)

**章节来源**
- [lib.rs](file://rust/legado-server/src/lib.rs)
- [server.rs](file://rust/legado-server/src/server.rs)

## 性能考虑
- 连接池容量与并发：限制最大连接数，避免内存泄漏；按会话隔离资源。
- 心跳间隔与超时：根据网络环境动态调整，降低误判与开销。
- 消息批处理与节流：合并高频事件，减少网络抖动影响。
- 压缩策略：对大负载启用压缩，权衡CPU与带宽。
- 背压与队列：当消费者处理慢时，服务端应限流或丢弃低优先级消息。

[本节为通用指导，不直接分析具体文件]

## 故障排查指南
- 连接问题：检查握手状态码、跨域配置、代理设置；前端记录重连次数与延迟。
- 心跳超时：核对客户端/服务端心跳间隔与超时阈值；观察网络丢包情况。
- 消息丢失：检查序列号与分片重组逻辑；确认订阅关系是否正确。
- 内存与CPU：监控连接池大小、消息队列长度、GC/CPU峰值。
- 错误上报：统一错误事件格式，包含错误码、消息、上下文与堆栈。

**章节来源**
- [error.rs](file://rust/legado-server/src/error.rs)
- [connectionStore.ts](file://modules/web/src/store/connectionStore.ts)
- [api/index.ts](file://modules/web/src/api/index.ts)

## 结论
本项目通过清晰的WS模块分层、稳健的心跳与重连机制、可扩展的连接池与处理器架构，实现了高效的实时通信。配合前端统一的连接存储与API封装，能够快速支撑搜索进度、源调试、阅读状态同步等场景。建议在后续迭代中持续完善监控指标、错误诊断与性能调优，以提升稳定性与用户体验。

[本节为总结性内容，不直接分析具体文件]

## 附录
- 监控指标建议：
  - 连接数、活跃连接、平均延迟、消息吞吐、错误率、重连次数。
  - 订阅分布、热点主题、消息大小分布。
- 调试方法：
  - 前端控制台打印连接状态与消息收发。
  - 后端日志输出握手、心跳、错误与性能指标。
  - 使用抓包工具验证协议与压缩效果。

[本节为补充信息，不直接分析具体文件]