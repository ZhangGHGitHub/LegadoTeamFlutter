# 原版 / 参考版源码更新对照与同步清单（2026-10-28）

> 编写：ZCode 主代理 ｜ 2026-10-28
> 目的：记录本次源码更新结果、变更规模、需要同步到 Rust/Flutter 重构实现的清单，以及需用户裁决的冲突项。

## 一、更新结果

| 仓库 | 位置 | 更新前 | 更新后 | 方式 |
|---|---|---|---|---|
| 原版（Android） | `D:\OH-WorkSpace\LegadoTeam\legado-upstream` | `00c578e9cc`（2026-08-29，v3.26.082823） | `531f9fbf07`（最新，254 commits，644 files，+66302/−4315） | `git fetch upstream` + `reset --hard upstream/master`（本地仅一个空快照提交，无源码改动） |
| 参考版（MD3/Compose） | `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3` | `488a375`（2026-09-28） | `bba5c64df3`（2026-10-25，742 files 变更） | `git fetch` 被 TLS 阻断（schannel/openssl 均 `unexpected eof`），改用 GitHub 官方 tarball 快照同步，提交 `701943e` |
| 主仓内原版副本 | `legado/app`、`legado/modules` | 与旧版上游一致（仅 build 产物/旧 web 资源差异） | 已覆盖为最新上游源码（复制 614 文件，删除 9 个已移除文件；保留 `app/build` 与旧 web 资源） | 脚本按快照同步 |

说明：主仓 `app/`、`modules/` 自提交 `4257d75439`「安卓源码移出 GitHub」后不再跟踪，本次同步不影响 git 状态；`legado-with-MD3` 以单个快照提交保留，历史提交不可追溯（网络恢复后建议重新 `git fetch` 对齐真实历史）。

## 二、原版更新要点（254 commits）

### 数据层（最高优先级）
- Schema **v104 → v113**（`app/schemas/106..113.json`）：
  - `readRecord` 主键由 `(deviceId, bookName)` 改为 **`(deviceId, bookName, author)`**，新增 `lastChapterTitle/lastChapterIndex/lastChapterPos/coverUrl/resolvedAuthor/displayBookName/displayAuthor/metadataEditedAt` 8 列 + 快照索引；
  - 新表 `book_memos`（书备忘）、`book_source_check_states`（书源检验状态）；
  - `rssSources.enableReadRecord`、`highlightRules.group`；
  - `book_sources_part` 视图重建（联查检验状态）。
- 迁移要点：106→107「重建表原样搬运，不拆旧合并作者」；112→113 幂等（先探测列，因上游曾「发列未升版本」）。

### 我方确认的缺口（核验）
- `rust/legado-db/src/schema.rs:45` `SCHEMA_VERSION=112`；`readRecord` 仅 5 列、PK 缺 author（`:442`）。
- `rust/legado-core/src/models/rule/content_rule.rs:5` 无 `contentBatch/maxBatchSize`；RSS 模型无 `enableReadRecord`；高亮模型无 `group`。
- `backup_api.rs:855` `ZIP_DATA_FILES` 仅 21 项，缺 `bookMemo.json`、阅读记录封面目录、封面字体。

### 备份 / WebDAV / 引擎 / 阅读 / 搜索 / RSS
- 备份：新增 `bookMemo.json`（空表也写）、`readRecord.json` 13 字段、封面目录与字体；WebDAV 备份保留数清理（默认 0）、本地导入后自动上传（默认关）、自动备份周期/上传开关、`lastBackup` 语义修正、恢复下划线归一顺序。
- 引擎：**登录头只发同站请求**（`AnalyzeUrl.isLoginHeaderSite`）；正文批量下载（`ContentRule.contentBatch/maxBatchSize` + `BookContent.analyzeContentBatch`）；`ContentRule.toString()` 保留旧字段文本（Rhino 兼容）。
- RSS：**全局**阅读记录开关（按源开关已回退不生效）；`RssWebResourceProxy` 子资源代理（图片/音视频/Range，附源 header/Cookie）。
- 阅读器：字号上限 100、边距上下联动/大控件、首行缩进与高亮胶囊留白、目录显示反转独立开关、翻页拖动跨刷新。
- 搜索：方向范围（全部/向上/向下）+ 锚点 + 选项持久化。
- Web 前端：`app/src/main/assets/web` 全面换代，新增 `js_source_template.js`；新前端依赖服务端 4 个新接口（书源管理/检验状态/开始/停止检验），**只换静态资源会报错**。

## 三、参考版更新要点（1 个月）

- 绝对主体是**阅读配音 cast 家族**（123 文件、+22.6k 行：多角色配音、BGM、音效/变声、AI 配音、音频下载、悬浮胶囊）——我方无对应实现，属新增功能族，需单独立项与用户授权。
- 阅读器：标题字号「相对正文/绝对」开关（默认 `titleSize=4`）、翻页动画「淡入」、顶栏按钮可配置（≤6）、阅读主题列表管理页、预下载向前 N 章、高亮规则高级样式（边框/命中字距行距/气泡偏移）、中文断行三条修复。
- 发现页：**源内容模式**（主页直接浏览选中书源分类，持久化源/分类）、页码跳转（需规则支持 `{{page}}`/`<,>`）、布局入口合并。
- 书架：标签内容三项开关（自定义标签/源分类/字数）+ 标签渲染、批量删除「同时删除本地文件」、搜索按钮点/长按互换、分组管理多选批量删除、详情页删除副本 Sheet。
- 详情页：单本「禁用阅读记录」（DB `Book.disableReadRecord`）、作者其它作品兜底、封面比例开关。
- WebDAV：状态化 `WebDavConfigState`（isConfigured 与 isOk 分离、失败可重试、测试同步后重建授权）——属缺陷修复。
- 设置/文案：464 个新字符串键；「平板界面」改「导航布局」、新增「多栏布局」、电池优化引导、拦截书源内置浏览器、封面比例、作者搜索兜底等。
- RSS 本月几乎无变更（仅分组批量删除与 WebView 容器重构）。
- DB v107→133（cast 族 14 张新表）；对书籍实体仅 `Book.disableReadRecord` 一列；`BookSource/BookChapter/BookGroup` 未变。

## 四、同步清单（按优先级）

### P0 — 数据兼容 / 静默丢数据（原版）
1. `readRecord` 升 v113：PK 加 author + 8 列 + 索引；repository/FFI/Dart 记录页补字段；同名不同作者分开计时（4–6 人日）。
2. `book_memos` 表 + 备份 `bookMemo.json`（空表也写）+ 恢复按 restoredBookUrls 过滤（数据层 1.5 人日）。
3. 规则字段保真：`ContentRule.contentBatch/maxBatchSize`、`HighlightRule.group`、`RssSource.enableReadRecord`（模型+DB+编辑器读改写回，1.5 人日）。
4. 备份白名单扩展（`bookMemo.json`、`readRecord.json` 全字段、`readRecordCovers/`、封面字体），缺失只告警（1 人日）。

### P1 — 行为差异 / 稳定性（原版）
5. 登录头同站判定（`web_book.rs`，0.5 人日）。
6. RSS 阅读记录全局开关（默认 true，弹窗菜单 + 所有写入口判断，0.5 人日）。
7. RSS 子资源代理（Flutter WebView 无 `shouldInterceptRequest`；需平台 View 或 Rust 反代 URL 重写，3–5 人日，先技术验证）。
8. 书源检验状态（表+DAO+规范化+4 个 HTTP 接口+管理页徽标，3 人日）。
9. 内容搜索范围语义（原版 ALL/UP/DOWN vs 我方三档；**与参考版对齐项冲突，先裁决**，2–3 人日）。

### P0 — 参考版用户可见功能（新增能力，需逐项确认授权）
- 发现页源内容模式（3–4 人日）、页码跳转（2 人日）、书架标签内容（2.5 人日）、批量删除本地文件（0.5–1 人日）、详情删除副本 Sheet（1 人日）、单本禁用阅读记录（1.5 人日）、标题字号相对/绝对（0.5 人日）、翻页淡入（1 人日）、分组多选删除（1 人日）、预下载向前 N 章（3 人日，含预取引擎）、WebDAV 入口状态化（0.5 人日）、电池优化/拦截书源浏览器（1 人日）、作者其它作品兜底（1.5 人日）。

### P1/P2（参考版视觉 1:1）
- 阅读主题列表管理页（6–10 人日）、顶栏按钮配置（4 人日）、多栏布局（5–8 人日）、封面设置页/比例（2+1 人日）、高亮规则高级样式与渲染（8–10 人日）、中文断行三条（2 人日）、目录缓存判定（1 人日）、漫画预取/拆段（5 人日）。

### P3 — 无需同步（登记）
- Rhino JSON 初始化、jsoup 1.23.2、jsLib 超大（Flutter 无 Intent 限制）、Kotlin/KSP/Ktor/BC/ Cronet/pdfbox 依赖、`ContentRule.toString()` Rhino 文本兼容、参考版 cast 家族（如需纳入另行立项）、`modules/web` 与 `assets/web` 构建产物（我方 web-dist 独立构建）。

## 五、需用户裁决的冲突项

1. **参考版独有功能是否纳入**：多栏布局、发现源内容、顶栏按钮配置、主题列表、单本关记录、向前预下载、封面比例、拦截书源浏览器、页码跳转、cast 家族——这些在原版基线中不存在，纳入即偏离「未经允许禁止新增原版不存在功能」红线，需逐项授权。
2. **字号上限**：原版 100；参考版排版是否仍为 32，我方当前 12–32。按参考版为视觉目标则维持，按原版能力则放宽，需裁决。
3. **标题字号默认值**：参考版默认相对 +4sp，原版/我方默认 0；直接照搬会改变新装用户视觉。
4. **内容搜索范围**：原版方向搜索（ALL/UP/DOWN + 锚点）vs 我方/参考版三档（当前章/已缓存/联网）；语义冲突。
5. **目录「已缓存」判定**：参考版改为「有正文即缓存」（图片缺失不再显示未缓存），原版严格判定；影响状态图标语义。
6. **`tabletInterface` 文案/概念**：参考版改为「导航布局」并新增「多栏布局」。
7. **Web API 书架去重**：参考版 `source=legado-reader` 按 `author#name` 去重；我方无该参数，第三方插件兼容性差异。
8. **WebDAV 备份保留/自动上传**：原版新增能力（默认关闭/不清理），我方无备份上传链路；是否作为独立专项立项。

## 六、建议排期

1. **先做 P0 数据兼容（原版）**：schema v113 + readRecord + book_memos + 规则字段 + 备份白名单 —— 否则恢复/导出上游数据会静默丢字段，这是当前最高风险。
2. 再做 P1 行为差异（登录头同站、RSS 记录开关），RSS 子资源代理先技术验证。
3. 参考版新增功能按用户授权逐项排期；未裁决的冲突项不动手。
4. 完成上述后再同步 web-dist（依赖书源检验状态 4 个接口）。

## 七、遗留（本次更新前未完成）

- 批25b（口令 IPv6 校验 / SEND 进程恢复重复消费）与批26b（SAF 目录树 SIZE 未知误删等）因自定义子代理额度耗尽未完成，恢复后继续；不影响本次源码更新。

编写：ZCode 主代理 ｜ 2026-10-28
