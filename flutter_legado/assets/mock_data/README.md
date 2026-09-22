# Mock 书架样例（合成脱敏）

`bookshelf_sample.json` 是 Flutter 端 `MockBookApi`（`USE_MOCK` 开发模式，见
`lib/src/services/mock_book_api.dart`）的书架数据源，替代此前的硬编码占位数据
（REFACTORING_PLAN §6.4 的 TODO 项）。

## 来源与脱敏口径

- 原计划从原 Android 端真实书架导出 JSON（`.tmp/db_oldapp_v9` 的 42 本原版快照）；
  该快照已于 2026-09-20 目录清理中删除，故按批准改为**合成式脱敏样例**。
- 结构严格对齐 `Book` 模型序列化键名（`lib/src/models/book.dart`，生成器
  `book.g.dart`；契约 `docs/API_CONTRACT.md` §2.2）：键名/类型与真实书架导出
  的 `Book.toJson` 输出一致，含必填字段与常用可选字段（readConfig 嵌套对象、
  originBookUrl 换源形态、customTag/customIntro/charset 等）。
- 共 10 本，字段分布有代表性：
  - `bookType` 位标记：TEXT=8（5 本）、IMAGE=64（2 本）、AUDIO=32（1 本）、
    LOCAL=0x1000（2 本）；
  - 网络书 8 本（`origin` 为 http(s) 示例地址）、本地书 2 本（`origin=loc_book`、
    `bookUrl` 为 `file://`）；
  - 封面：有 5 本 / 无 5 本；分组：group 0（未分组）6 本、group 1 2 本、
    group 2 2 本（mock 内置分组：1=科幻、2=收藏）；
  - 阅读进度三态：未读（`durChapterIndex=0`，3 本）/ 在读（4 本）/
    读完（`durChapterIndex=totalChapterNum-1`，3 本）。
- **全部内容虚构**：书名/作者/简介/章节标题均为示例文案；所有 http(s) URL
  主机名仅 `example.com`（`bookUrl` 用 `mock://` 协议、本地书用 `file://`，
  不指向任何真实站点）；不含任何真实站点域名或可能指向真人的信息。
- 脱敏护栏：`test/unit/bookshelf_sample_test.dart` 会断言样例内任何 http(s)
  主机名必须为 `example.com`，防止将来误贴真实数据。

## 消费方式

`MockBookApi` 构造器为同步，资产读取为异步：书架相关方法经
`_ensureBooksLoaded()` 守卫惰性加载本文件（`rootBundle.loadString`），
`initialize()` 亦会确保加载完成。运行：`flutter run -d windows --dart-define=USE_MOCK=true`。
