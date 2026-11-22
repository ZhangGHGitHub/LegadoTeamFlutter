# 角色卡 Characters 调研报告（R42 阶段 2 前置）

**调研日期**：2026-11-23
**调研对象**：参考版 `legado-with-MD3`（同步 main@bba5c64，Room `version = 133`）
**我方基线**：HEAD `6f32c2e115`，DB `SCHEMA_VERSION = 119`
**授权依据**：`docs/过期文档/UI_ONE_TO_ONE_CLONE_PLAN_20260905.md` §〇（2026-09-05 用户授权纳入角色卡 Characters，路径「先调研参考 ViewModel 数据源 → 契约先行 → Rust 轨排期」）
**性质**：只读调研。未修改任何 `flutter_legado/lib/**`、`rust/**` 代码；本文件为唯一产出。

---

## 结论摘要（先看这段）

1. **数据来源：100% 本地表，写入方三类，其中「能真正产生数据」的只有两条半**——
   - ① **用户手动录入**（`BookCharacterDetailViewModel.save()`）：唯一无需外部依赖、任何设备可用的写入路径；
   - ② **AI 识别**（`IdentifyBookCharactersUseCase` + `AiToolRepository.save_book_character_profile` 等 5 个 AI 工具）：**依赖外部 LLM 服务**（`ai_provider_profiles` / `ai_model_profiles` / `ai_task_presets` / `ai_artifacts` 共 4 张 AI 表 + `data/repository/ai/` 全套 SSE/HTTP 客户端）；
   - ③ **朗读配音镜像**（`CastProfileMirror.ensure/backfillAll`、`CastMemoryMirror`）：**不是独立数据源**——它只是把 `cast_characters`（配音角色）行复制成人物档案，而 `cast_characters` 本身要靠「多角色朗读 + AI 场景分配」产生，我方朗读「角色与配乐」页签当前**全部置灰未实现**（`read_aloud_settings_screen.dart:1289` 注释「本批全部置灰」）。
   - **书源规则完全不参与**：参考版 `BookInfoRule.kt` 13 字段中**没有任何 characters 相关字段**（只有 `relatedBooks` 是独有扩展），故**不需要书源规则扩展**。
2. **不做 AI 的前提下，该功能仍有意义但价值大幅缩水**：可交付「手动录入角色档案 + 详情页横向卡片区 + 空态隐藏」。参考版自身的空态文案就是「还没有人物档案」，即**参考版也接受纯手动建档**这条路径（`BookCharacterListScreen.kt:326` + `BookCharacterDetailScreen` 新建入口）。
3. **最小集 = 3 个 FFI 方法**（读 1 + 写 1 + 删 1）：`getBookCharacters` / `saveBookCharacter` / `deleteBookCharacter`。16 个 gateway 方法里，**只有 `getCharacterProfiles` 是详情页 Characters 区块的硬依赖**；其余 15 个中 8 个只服务 AI 工具/事件/关系图/知识/大纲，7 个是增删改。
4. **建议：做，但只做「手动录入最小闭环」**（阶段 2A），AI 识别（阶段 2C）单独立项并明确标注依赖外部服务。理由见第 7 节。
5. **工作量：阶段 2A 约 4.5–6 人日**（Rust 1.5–2 + Dart 1.5–2 + UI 1–1.5 + 契约/测试 0.5–1）；若含 5 张表全量 + AI 入口，总量约 18–25 人日且**卡在 AI 后端**。

---

## 1. 五张表的完整 schema

### 1.1 取证方法与版本结论

- schema 源：`legado-with-MD3/app/schemas/io.legado.app.data.AppDatabase/{95,103,104,133}.json`
- 实测：5 张表**首次出现于 schema v95**（v94 无，v95 共 48 表）。`book_character_profiles` 在 **v97** 追加 `voiceGender` / `voiceAgeBand` 两列（v95/v96 为 15 列，v97 起 17 列），其余 4 张表自 v95 起 DDL 未变。
- 参考版最新 `133.json` 与 `104.json` 中这 5 张表 DDL **完全一致**，且 **`foreignKeys = null`（无外键）**。这与 `book_marks` 的既有结论同构（参考版本仓也不声明外键，见契约 §2.52 注）。
- 实体类：`legado-with-MD3/app/src/main/java/io/legado/app/data/entities/BookKnowledge.kt`（193 行，5 个 `@Entity`）。
- DAO：`.../data/dao/BookKnowledgeDao.kt`（174 行）。
- 注册：`.../data/AppDatabase.kt:151-153`（5 个实体全部注册；`version = 133`）。

### 1.2 `book_character_profiles`（17 列，2 索引，无外键）

实体：`BookKnowledge.kt:8-70`（`data class BookCharacterProfile`）

| # | 列名 | 类型 | NOT NULL | 默认值 | 说明 |
|---|------|------|----------|--------|------|
| 1 | `id` | TEXT | 是 | — | **主键**（参考版用 UUID 字符串；AI 工具用 `character_<md5(bookUrl:name)>`） |
| 2 | `bookUrl` | TEXT | 是 | — | 书籍稳定主键 |
| 3 | `name` | TEXT | 是 | — | 角色名 |
| 4 | `aliasesJson` | TEXT | 是 | 实体默认 `"[]"` | 别名 JSON 数组字符串 |
| 5 | `avatarUri` | TEXT | 否 | NULL | 头像本地 `file://` URI（`filesDir/character_avatars/`，见 `CharacterAvatarImage.kt:70`） |
| 6 | `tagsJson` | TEXT | 是 | 实体默认 `"[]"` | 标签 JSON 数组字符串 |
| 7 | `role` | TEXT | 是 | 实体默认 `""` | `male_lead` / `female_lead` / `male_supporting` / `female_supporting` / `""` |
| 8 | `voiceGender` | TEXT | 是 | **`'unknown'`**（DDL DEFAULT） | `male` / `female` / `unknown`（v97 新增） |
| 9 | `voiceAgeBand` | TEXT | 是 | **`'unknown'`**（DDL DEFAULT） | **存的是「声音池名」**（`VoicePoolStore.poolNameOrEmpty`），非固定枚举（v97 新增） |
| 10 | `personality` | TEXT | 是 | 实体默认 `""` | 性格 |
| 11 | `summary` | TEXT | 是 | 实体默认 `""` | 简介 |
| 12 | `status` | INTEGER | 是 | 实体默认 `1` | `0`=DRAFT / `1`=ACTIVE / `2`=DISABLED / `3`=DELETED |
| 13 | `source` | TEXT | 是 | 实体默认 `"user"` | `user` / `ai` / `import` |
| 14 | `confidence` | REAL | 是 | 实体默认 `1f` | 置信度 0–1（AI 用，手动恒 1） |
| 15 | `schemaVersion` | INTEGER | 是 | 实体默认 `1` | 行级 schema 版本（全仓未消费，仅写入） |
| 16 | `createdAt` | INTEGER | 是 | 实体默认 `now` | Unix 毫秒 |
| 17 | `updatedAt` | INTEGER | 是 | 实体默认 `now` | Unix 毫秒；**列表排序键** |

索引（`BookKnowledge.kt:10-13`）：

- `index_book_character_profiles_bookUrl_name` — **UNIQUE** `(bookUrl, name)` → 「一书一名唯一」的硬约束（`CastProfileMirror.kt:31-38` 注释说明：正因唯一约束，按名字兜底只认完全相等，不能走 LIKE）
- `index_book_character_profiles_bookUrl_updatedAt` — `(bookUrl, updatedAt)`（列表 `order by updatedAt desc` 用）

**语义约束（重要，非 DDL 强制）**：`id` 与「配音角色 id」是**同一份身份**——`CastProfileMirror.kt:10-12` 明写「新建角色时档案 id 直接用角色 id」。我方若不实现配音链，此约束可暂不实现，但**契约草案中 id 语义要留口子**（见 §5）。

### 1.3 `book_character_events`（15 列，2 索引，无外键）

实体：`BookKnowledge.kt:72-96`

| # | 列名 | 类型 | NOT NULL | 默认值 | 说明 |
|---|------|------|----------|--------|------|
| 1 | `id` | TEXT | 是 | — | 主键（UUID） |
| 2 | `bookUrl` | TEXT | 是 | — | 书籍 |
| 3 | `characterId` | TEXT | 是 | — | 指向 `book_character_profiles.id`（**无外键，靠应用层维护**） |
| 4 | `chapterIndex` | INTEGER | 否 | NULL | 章节索引（NULL = 全书级） |
| 5 | `chapterTitle` | TEXT | 是 | `""` | 冗余章节标题 |
| 6 | `eventTimeText` | TEXT | 是 | `""` | 剧情时间文本（如「三年前」） |
| 7 | `content` | TEXT | 是 | — | 事件正文（必填） |
| 8 | `importance` | INTEGER | 是 | `0` | 重要度（排序用） |
| 9 | `sourceTextHash` | TEXT | 否 | NULL | 原文指纹（去重用） |
| 10 | `evidenceJson` | TEXT | 是 | `"[]"` | 证据 JSON |
| 11 | `source` | TEXT | 是 | `"user"` | 同 profiles |
| 12 | `confidence` | REAL | 是 | `1f` | — |
| 13 | `schemaVersion` | INTEGER | 是 | `1` | — |
| 14 | `createdAt` | INTEGER | 是 | `now` | — |
| 15 | `updatedAt` | INTEGER | 是 | `now` | — |

索引：`(bookUrl, characterId, chapterIndex)`、`(bookUrl, chapterIndex)`。

### 1.4 `book_character_relations`（15 列，3 索引，无外键）

实体：`BookKnowledge.kt:98-123`

| # | 列名 | 类型 | NOT NULL | 默认值 | 说明 |
|---|------|------|----------|--------|------|
| 1 | `id` | TEXT | 是 | — | 主键 |
| 2 | `bookUrl` | TEXT | 是 | — | — |
| 3 | `fromCharacterId` | TEXT | 是 | — | 起点角色 |
| 4 | `toCharacterId` | TEXT | 是 | — | 终点角色（**有向边**） |
| 5 | `relationType` | TEXT | 是 | — | 关系类型（自由文本，无枚举常量） |
| 6 | `summary` | TEXT | 是 | `""` | — |
| 7 | `attitude` | TEXT | 是 | `""` | 态度 |
| 8 | `evidenceJson` | TEXT | 是 | `"[]"` | — |
| 9 | `chapterIndex` | INTEGER | 否 | NULL | — |
| 10 | `status` | INTEGER | 是 | `1` | 同 profiles 枚举 |
| 11 | `source` | TEXT | 是 | `"user"` | — |
| 12 | `confidence` | REAL | 是 | `1f` | — |
| 13 | `schemaVersion` | INTEGER | 是 | `1` | — |
| 14 | `createdAt` | INTEGER | 是 | `now` | — |
| 15 | `updatedAt` | INTEGER | 是 | `now` | — |

索引：`(bookUrl, fromCharacterId, toCharacterId)` **UNIQUE**（同向同类型不重复建边）、`(bookUrl, fromCharacterId)`、`(bookUrl, toCharacterId)`。

### 1.5 `book_knowledge_entries`（15 列，2 索引，无外键）

实体：`BookKnowledge.kt:125-160`

| # | 列名 | 类型 | NOT NULL | 默认值 | 说明 |
|---|------|------|----------|--------|------|
| 1 | `id` | TEXT | 是 | — | 主键 |
| 2 | `bookUrl` | TEXT | 是 | — | — |
| 3 | `type` | TEXT | 是 | — | `world_rule`/`location`/`faction`/`object`/`terminology`/`timeline`/`style`/`theme`（`BookKnowledge.kt:151-158` 8 个常量） |
| 4 | `title` | TEXT | 是 | — | — |
| 5 | `keywordsJson` | TEXT | 是 | `"[]"` | 检索关键词 |
| 6 | `content` | TEXT | 是 | — | 正文（必填） |
| 7 | `scopeStartChapter` | INTEGER | 否 | NULL | 生效章区间起点 |
| 8 | `scopeEndChapter` | INTEGER | 否 | NULL | 生效章区间终点 |
| 9 | `priority` | INTEGER | 是 | `0` | 排序（降序） |
| 10 | `source` | TEXT | 是 | `"user"` | — |
| 11 | `confidence` | REAL | 是 | `1f` | — |
| 12 | `evidenceJson` | TEXT | 是 | `"[]"` | — |
| 13 | `schemaVersion` | INTEGER | 是 | `1` | — |
| 14 | `createdAt` | INTEGER | 是 | `now` | — |
| 15 | `updatedAt` | INTEGER | 是 | `now` | — |

索引：`(bookUrl, type, priority)`、`(bookUrl, title)`。

### 1.6 `book_outline_nodes`（14 列，2 索引，无外键）

实体：`BookKnowledge.kt:162-193`

| # | 列名 | 类型 | NOT NULL | 默认值 | 说明 |
|---|------|------|----------|--------|------|
| 1 | `id` | TEXT | 是 | — | 主键 |
| 2 | `bookUrl` | TEXT | 是 | — | — |
| 3 | `parentId` | TEXT | 否 | NULL | **自引用**（树结构，无外键） |
| 4 | `nodeType` | TEXT | 是 | — | `book`/`volume`/`arc`/`chapter`/`scene`（`:187-191`） |
| 5 | `title` | TEXT | 是 | — | — |
| 6 | `summary` | TEXT | 是 | — | — |
| 7 | `startChapterIndex` | INTEGER | 否 | NULL | — |
| 8 | `endChapterIndex` | INTEGER | 否 | NULL | — |
| 9 | `order` | INTEGER | 是 | `0` | 同级排序（SQL 里是保留字，DAO 用反引号 `` `order` ``） |
| 10 | `source` | TEXT | 是 | `"user"` | — |
| 11 | `confidence` | REAL | 是 | `1f` | — |
| 12 | `schemaVersion` | INTEGER | 是 | `1` | — |
| 13 | `createdAt` | INTEGER | 是 | `now` | — |
| 14 | `updatedAt` | INTEGER | 是 | `now` | — |

索引：`(bookUrl, nodeType, startChapterIndex, endChapterIndex)`、`(bookUrl, parentId, order)`。

### 1.7 汇总

| 表 | 列数 | 索引数 | 外键 | 我方是否需要（最小集） |
|---|---|---|---|---|
| `book_character_profiles` | 17 | 2（1 unique） | 无 | **需要** |
| `book_character_events` | 15 | 2 | 无 | 不需要（事记页） |
| `book_character_relations` | 15 | 3（1 unique） | 无 | 不需要（关系图页） |
| `book_knowledge_entries` | 15 | 2 | 无 | 不需要（世界知识页） |
| `book_outline_nodes` | 14 | 2 | 无 | 不需要（大纲，参考版**连 UI 都没有**） |
| 合计 | 76 | 11 | 0 | 1/5 表 |

---

## 2. 数据来源链路（含 AI 依赖分析）

### 2.1 写入方全景（`upsertCharacterProfile` / `bookKnowledgeDao.upsertCharacterProfile` 全部调用点）

| # | 写入方 | 文件:行 | 来源类别 | 我方可行性 |
|---|--------|---------|----------|-----------|
| 1 | `BookCharacterDetailViewModel.save()` | `ui/book/knowledge/BookCharacterDetailViewModel.kt:167`（`upsert` 在 `:200`） | **用户手动录入** | ✅ 可做 |
| 2 | `IdentifyBookCharactersUseCase.save()` | `domain/usecase/IdentifyBookCharactersUseCase.kt:196` | **AI 识别结果落库** | ❌ 需外部 LLM |
| 3 | `AiToolRepository.saveBookCharacterProfile()` | `data/repository/AiToolRepository.kt:549` | **AI 工具调用落库**（`save_book_character_profile` 工具） | ❌ 需外部 LLM |
| 4 | `BookCharacterNetworkViewModel.findOrCreateProfile()` | `ui/book/knowledge/BookCharacterNetworkViewModel.kt:269` | 用户在关系图里手动加节点 | ⚠️ 依赖关系图页（不在最小集） |
| 5 | `CastProfileMirror.ensure()` | `help/readaloud/cast/CastProfileMirror.kt:44,55` | **配音角色镜像**（把 `cast_characters` 复制成档案） | ❌ 我方无配音角色链 |
| 6 | `CastMemoryMirror`（4 处） | `CastMemoryMirror.kt:224,353,373,501` | **AI 配音分配记忆镜像** | ❌ 需 AI + 配音链 |
| 7 | `BookCastStore`（删除） | `BookCastStore.kt:258` | 配音角色删除联动 | ❌ 同上 |

**关键判断**：除 ①（手动）与 ④（关系图手动建点）外，**全部写入方都挂在「AI 分析」或「多角色朗读配音」这两条我方尚不存在的能力上**。

### 2.2 AI 依赖有多深（量化）

参考版 AI 栈实测规模：

| 层 | 文件/行数 | 关键文件 |
|---|---|---|
| AI 实体（8 张表） | `ai_provider_profiles` / `ai_model_profiles` / `ai_task_presets` / `ai_artifacts` / `ai_chat_conversations` / `ai_chat_messages` / `ai_memory` / `ai_prompt_presets` | `data/entities/Ai*.kt` |
| AI 数据访问 | `AiArtifactDao` / `AiChatDao` / `AiMemoryDao` / `AiProfileDao` / `AiPromptPresetDao` | `data/dao/` |
| AI HTTP/SSE 客户端 | `data/repository/ai/`（`AiHttpClient` / `AiProtocolHandler` / `AiProviderRegistry` / `AiSseUtils` / `AiRetryUtils` / `AiHandlerSupport`） | 6 个文件 |
| AI Gateway 接口 | 7 个：`AiArtifactGateway` / `AiChatGateway` / `AiMemoryGateway` / `AiProfileGateway` / `AiPromptPresetGateway` / `AiTextGateway` / `AiToolGateway` | `domain/gateway/` |
| AI UseCase | `AiChatGenerationUseCase` / `AiTaskManager` / `AiTextFactoryUseCase` / `AiToolAwareGenerationUseCase` / `GenerateChapterSummaryUseCase` / `CleanSelectedTextUseCase` / `RefineSpeechWithAiUseCase` / `IdentifyBookCharactersUseCase` | `domain/usecase/` |
| AI 工具注册表 | `AiToolRepository.kt` **1247 行**，注册 21 个工具（其中 5 个直接写这 5 张表：`save_book_character_profile` / `save_book_character_event` / `save_book_character_relation` / `save_book_knowledge_entry` / `save_outline_node`） | `data/repository/AiToolRepository.kt` |
| AI UI | `ui/ai/`（`AiReasoningModeButton` / `AiTaskResultSheet` / `chat/`）约 10 文件 3266 行 | `ui/ai/` |
| **合计** | `find -name "Ai*.kt"` = **78 个文件 / 16324 行** | — |

角色识别的具体链路（`IdentifyBookCharactersUseCase.kt`）：

1. `start(bookUrl)` → `aiProfileGateway.getTaskPreset(IDENTIFY_CHARACTERS)`；**无 preset 时回落 `CHAT` preset，两者皆无则 `error("No AI model configured for character identification")`**（`:75-78`）→ **无 AI 模型配置 = 功能直接不可用**。
2. 组装 prompt：优先用户自定义 `promptTemplate`，否则内置 `defaultPrompt()`（`:230-234`，要求返回 `{"characters":[{name,aliases,voiceGender,voiceAgeBand,role,personality,summary,evidence,confidence}]}`）。
3. `aiToolAwareGenerationUseCase.generateStream(...)` + `toolContext = AiToolContext(bookUrl)` → **模型需支持 tool calling，并由 AI 自行调 `read_cached_chapters` 等只读工具**取正文（`:120-136`）。
4. 结果落 `ai_artifacts` 表（`:176-189`），UI 由 `observeTask` 轮询任务状态（`BookCharacterListViewModel.kt:170-216`）。
5. 用户勾选候选 → `save()` → `upsertCharacterProfile(source = "ai", confidence = candidate.confidence)`，且 **`confidence >= 0.65` 才保留**（`:170`、`:224`）。

### 2.3 我方 AI 能力现状（实测）

| 检查项 | 结论 | 证据 |
|---|---|---|
| Rust 侧 AI 后端 | **完全没有** | `grep -rln "openai\|OpenAi" --include=*.rs rust` → 0 命中 |
| Rust 侧 AI 表 | **完全没有** | `rust/legado-db/src/schema.rs` 31 张表，无任何 `ai_*` |
| Dart 侧 AI 聊天 | **仅占位壳** | `flutter_legado/lib/src/screens/ai_chat_screen.dart`（32 行）注释：「不接任何 LLM/网络能力」 |
| Dart 侧 AI 摘要 | **不存在** | `grep aiSummary flutter_legado/lib` → 0 命中 |
| 朗读「角色与配乐」 | **全置灰** | `read_aloud_settings_screen.dart:1289` `_RoleTab`：「本批全部置灰」 |
| `cast_characters` / `book_voice_bindings` 等 10 张配音表 | **我方 DB 不存在** | `schema.rs` 无 `cast`/`voice` 表 |

**结论**：参考版「AI 识别角色」这条链在我方**需要从零建 8 张 AI 表 + HTTP/SSE 客户端 + 工具调用框架 + 模型配置 UI**，远超 R42 阶段 2 的合理范围。

### 2.4 明确回答：不做 AI，这个功能还有意义吗？

**有，但只有「手动录入」这一条腿。**

- **参考版自己也接受纯手动路径**：`BookCharacterListScreen.kt:143` 有 `AppFloatingActionButton(onClick = { onIntent(CharacterListIntent.AddCharacter) })` 新建按钮；`BookCharacterDetailViewModel.save()`（`:167-240`）落 `source = SOURCE_USER`、`confidence = 1f`；空态文案是「还没有人物档案」（`strings.xml:2925`），即**参考版预期「零数据」是常态**。
- **参考版的实际数据产生路径依赖用户已有 AI 配置**：`IdentifyBookCharactersUseCase:75-78` 明写无 preset 直接报错，所以参考版在「没配 AI 的机器」上同样只能手动建档。
- **不做的代价**：详情页 Characters 区块永远空 → 我方 `_buildCharactersSection` 恒返回 `const []` 的现状不变，功能等于不存在。
- **做的收益（最小集）**：用户可手动登记角色（姓名/角色定位/标签/简介/头像），详情页出现横向卡片区；与参考版「无数据隐藏、有数据展示」的可见行为一致。**这是唯一能在无 AI 前提下对齐参考版的部分。**

---

## 3. `BookKnowledgeGateway` 16 方法逐个语义

接口定义：`legado-with-MD3/app/src/main/java/io/legado/app/domain/gateway/BookKnowledgeGateway.kt`（73 行）
实现：`.../data/repository/BookKnowledgeRepository.kt`（142 行，含 `MAX_CHARACTER_PROFILES = 500` 上限）
SQL：`.../data/dao/BookKnowledgeDao.kt`

### 3.1 读方法（8 个）

| # | 方法签名 | 参数 | 返回 | 底层 SQL 要点 | 消费方 | 详情页 Characters 必需？ |
|---|---|---|---|---|---|---|
| 1 | `searchCharacterProfiles(bookUrl, query, limit=8)` | query 走 `name/aliasesJson/summary` LIKE | `List<BookCharacterProfile>` | `status != 3` + LIKE 三列 + `order by updatedAt desc` + `limit clamp 1..30` | **仅** `AiToolRepository:395`（AI 工具 `search_book_characters`） | ❌ |
| 2 | `getCharacterProfiles(bookUrl, limit=30)` | — | `List<BookCharacterProfile>` | `status != 3` + `order by updatedAt desc` + `limit clamp 1..500` | 详情页 `BookInfoViewModel:1900`（`limit=50`）、事记页 `:1968`（200）、人物列表 `:114`（200）、关系图 `:94`（120）、详情页角色详情 `:111`（80）、配音链 5 处（500） | ✅ **唯一硬依赖** |
| 3 | `getCharacterProfile(bookUrl, idOrName)` | id 或 name 或 aliases LIKE | `BookCharacterProfile?` | `(id = :x or name = :x or aliasesJson like '%x%')` + `limit 1` | AI 工具、角色详情页、配音链 | ❌（详情页卡片不点进去就不需要） |
| 4 | `getCharacterEvents(bookUrl, characterId?, maxChapterIndex?, limit=20)` | 三参皆可空 | `List<BookCharacterEvent>` | `order by coalesce(chapterIndex, MAX), importance desc, updatedAt desc` | 事记页、角色详情页、详情页「剧情事件」、AI 工具 | ❌ |
| 5 | `getCharacterRelations(bookUrl, characterId, limit=20)` | — | `List<BookCharacterRelation>` | 双向 `(from = x or to = x)` + `status != 3` | 角色详情页、AI 工具 | ❌ |
| 6 | `getBookCharacterRelations(bookUrl, limit=120)` | — | `List<BookCharacterRelation>` | 全书关系 + `status != 3` + `limit clamp 1..200` | 关系图页 `BookCharacterNetworkViewModel:97` | ❌ |
| 7 | `searchKnowledgeEntries(bookUrl, query, type?, chapterIndex?, limit=12)` | 类型 + 章节区间 + 三列 LIKE | `List<BookKnowledgeEntry>` | 区间判定 `(start is null or <= idx) and (end is null or >= idx)` + `order by priority desc` | 详情页「世界知识」、知识列表页、AI 工具 | ❌（参考版 `BookInfoKnowledge` composable **已死代码**，见 §4.4） |
| 8 | `getOutlineNodes(bookUrl, chapterIndex?, nodeType?, limit=20)` | — | `List<BookOutlineNode>` | `order by coalesce(startChapterIndex,-1), \`order\`, updatedAt desc` | **仅** AI 工具 `AiToolRepository:470`（**参考版无任何大纲 UI**） | ❌ |

### 3.2 写方法（8 个）

| # | 方法签名 | 语义 | 调用方 | 最小集需要？ |
|---|---|---|---|---|
| 9 | `upsertCharacterProfile(profile)` | `INSERT OR REPLACE`（同 id 覆盖） | 手动保存、AI 保存、配音镜像、关系图建点 | ✅ **必需** |
| 10 | `upsertCharacterEvent(event)` | 同上 | AI 工具、事记编辑页 | ❌ |
| 11 | `upsertCharacterRelation(relation)` | 同上 | AI 工具、关系图编辑器 | ❌ |
| 12 | `upsertKnowledgeEntry(entry)` | 同上 | AI 工具、知识编辑页 | ❌ |
| 13 | `upsertOutlineNode(node)` | 同上 | **仅** AI 工具 | ❌ |
| 14 | `deleteCharacterProfile(bookUrl, characterId, deleteRelations, deleteEvents)` | 删档案 + 可选软删关系（`status=3`）/ 硬删事件 | 角色详情页删除、配音链删除 | ✅ **建议**（否则建错了删不掉） |
| 15 | `deleteCharacterRelation(relationId)` | 硬删 | 关系图页 | ❌ |
| 16 | `deleteKnowledgeEntry(entryId)` | 硬删 | 知识编辑页 | ❌ |

### 3.3 最小集判定

**详情页 Characters 区块的数据面需求只有一条 SQL**：

```sql
select * from book_character_profiles
where bookUrl = ? and status != 3
order by updatedAt desc limit ?
```

即 **1 个读方法（#2）**。但要让这个区块「有数据可显示」，必须能写入，故：

| 角色 | 方法 | 理由 |
|---|---|---|
| **必需（读）** | `getCharacterProfiles`（#2） | 详情页区块唯一数据源 |
| **必需（写）** | `upsertCharacterProfile`（#9） | 无写入则区块恒空 = 功能不存在 |
| **强烈建议（删）** | `deleteCharacterProfile`（#14，可裁掉 `deleteRelations`/`deleteEvents` 两个开关） | 建错可删；否则用户误建的角色永久残留 |
| **可选（读单条）** | `getCharacterProfile`（#3） | 仅当要做「点卡片进详情页/编辑页」 |

→ **最小集 = 3 个方法**（读列表 + 存 + 删）；若连「点击进入编辑」都不做，UI 层无入口创建数据，故**必须同时做编辑入口**（详情页区块的「+」或书籍编辑页的知识卡片入口）。加上单条读可到 4 个。

**明确排除**（不属于最小集）：事件 3 个（#4/#10）、关系 3 个（#5/#6/#11）、知识 3 个（#7/#12/#16）、大纲 2 个（#8/#13）、检索 1 个（#1）——合计 12 个方法。**其中 8 个的唯一调用方是 AI 工具（`AiToolRepository`）**，我方无 AI 时无消费方。

---

## 4. UI 消费面细节

### 4.1 `BookInfoViewModel.loadBookCharacters`（实测行号 1889-1924，非任务书所写 1890-1925）

文件：`legado-with-MD3/app/src/main/java/io/legado/app/ui/book/info/BookInfoViewModel.kt`

- **触发点 3 处**：`:653`（`refreshShelfState` 内）、`:1246`（`upBook` 内，书籍加载完成）、`:1889` 定义。
- **并发控制**：`characterLoadJob?.cancel()` 后重启（`:1890-1891`）。
- **取数**：`bookKnowledgeGateway.getCharacterProfiles(bookUrl, limit = 50)`（`:1900`）→ **详情页只取 50 条**（与人物列表页的 200、配音链的 500 不同）。
- **排序规则**（`:1892-1897`）：`roleOrder = {male_lead:0, female_lead:1, male_supporting:2, female_supporting:3}`，`.sortedBy { roleOrder[it.role] ?: 99 }` → **男主 → 女主 → 男配 → 女配 → 其他（保持 SQL 的 updatedAt desc 相对序）**。
- **字段映射**（`:1902-1910`）→ `BookInfoCharacterUi`（`BookInfoContract.kt:127-134`，6 字段：`id/name/avatarUri/role/tags/summary`）：
  - `tags`：`GSON.fromJsonArray<String>(it.tagsJson)` 解析后 **`joinToString(" | ")`**（竖线分隔，`:1909`）
  - `summary`：**原样映射但 UI 不渲染**（见 §4.4）
- **降级**：`catch (Throwable) → emptyList()`（`:1914-1916`）；`CancellationException` 重抛。
- **竞态保护**：`if (currentBook?.bookUrl != bookUrl) return@launch`（`:1918`）。

### 4.2 `BookInfoScreen` 的 `BookInfoCharacters`（实测 2171-2322）

文件：`legado-with-MD3/app/src/main/java/io/legado/app/ui/book/info/BookInfoScreen.kt`

**渲染门控**（`:437-441`）：

```kotlin
if (state.characters.isNotEmpty() ||
    state.knowledgeEntries.isNotEmpty() ||
    state.recentEvents.isNotEmpty()) { BookInfoCharacters(...) }
```

→ **三者任一非空即整块出现**；三者全空 → 整块隐藏（**不是**「每个子块各自隐藏」）。这一点对我方很重要：若只做 Characters，则等价于「characters 非空才显示」。

**区块结构**（`BookInfoCharacters`，`:2171-2239`）：

1. 标题行：`AppText(stringResource(R.string.book_info_knowledge))` → **中文实际是「知识」**（`strings.xml:2921`），**不是「人物」**——标题与内容语义不一致，属参考版既有瑕疵。右侧 4 个图标按钮：
   - 列表 `FormatListBulleted` → 人物列表页（`contentDescription = book_characters`「人物」）
   - `Group` → 关系网（`character_network`）
   - `Book` → 世界知识（`book_knowledge`）
   - `Timeline` → 剧情事件（`plot_events`）
2. 横向 `LazyRow`，`items(key = { it.id })`，每项 `CharacterEntryCard`（`:2241-2321`）。

**卡片结构**（`CharacterEntryCard`）：

- `GlassCard(modifier = Modifier.width(160.dp))`（`:2255`），`containerColor = surfaceContainerLow`
- 内 `Column(padding 10.dp, spacedBy 4.dp)`：
  - **第 1 行**：`Box(36.dp 圆形, background = surfaceContainerHighest)` + 头像 → 姓名/角色两行
    - 头像：`avatarUri` 非空且未加载失败 → `AsyncImage(model = avatarUri, ContentScale.Crop, 圆形裁剪)`；否则 `Icons.Default.Person`（18dp，`onSurfaceVariant`）
    - 姓名：`AnimatedTextLine(labelLarge, maxLines = 1)`
    - 角色：`roleDisplayName` 经 `when(role)` 映射 `R.string.role_male_lead` 等 4 个中文（**男主/女主/男配/女配**，`strings.xml:2987-2990`），空则**不渲染该行**
  - **第 2 行**：`tags` 非空 → `AnimatedTextLine(labelSmall, onSurfaceVariant, maxLines = 1)`
- **`summary` 与 `personality` 均不渲染**（全文 `grep "character.summary"` 无命中，`character.personality` 无命中）→ **卡片只有 头像/姓名/角色/标签 四要素**，与任务书描述一致（简介在卡片上不显示）。

**点击行为**（`:2233`）：`onClick = { onCharacterClick(character.id) }` → `BookInfoIntent.CharacterClick(id)`（`BookInfoContract.kt:270`）→ `BookInfoViewModel:551` → `openCharacterDetail(id)`（`:1859-1862`）→ `BookInfoEffect.OpenCharacterDetail(bookUrl, characterId)` → `BookInfoRouteScreen:195-196` → `MainNavGraph:1469-1470` → `MainRouteBookCharacterDetail(bookUrl, characterId)` → `BookCharacterDetailScreen`（可编辑档案 + 事件 + 关系）。

→ **点击 = 跳角色详情/编辑页**（不是跳书）。这条跳转是「手动录入」闭环的**唯一编辑入口**（另一个人口在书籍编辑页的知识卡片，见 §4.5）。

### 4.3 详情页其它相关知识区块（实测状态）

| 区块 | 参考版实现 | 是否被调用 |
|---|---|---|
| `BookInfoCharacters` | `:2171-2239` + 卡片 `:2241-2321` | ✅ `:442` 调用 |
| `BookInfoKnowledge` | `:2325-2400`（世界知识横向卡） | ❌ **死代码**：全仓仅定义无调用（`grep "BookInfoKnowledge("` 只有 `private fun` 一处） |
| `BookInfoEvents` | `:2402-2478`（剧情事件横向卡） | ❌ **死代码**：同上 |
| 相关书 `RelatedBooksBanner` | `:2125` + `:482-495` | ✅（我方已接通，R42 阶段 1） |

→ **参考版详情页只渲染 Characters 一块**（加上 4 个图标入口），知识与事件虽然 ViewModel 里取了数（`:1926-1990`），但**没有任何 Composable 消费**。这解释了为何门控是三条件「或」：取了数却不用，仅作为「有数据就显示整块」的附加条件。

### 4.4 我方现状对照

| 项 | 我方位置 | 状态 |
|---|---|---|
| Characters 区块骨架 | `flutter_legado/lib/src/screens/book_info_screen_builders.part.dart:1637-1668` | `const []` 常量，`characters.isEmpty → return const []`（恒不渲染） |
| 区块调用点 | 同文件 `:1076`（在 `_buildActionCards` 之后、`_buildRelatedBooksSection` 之前） | 与参考版位置一致（参考版 `:442` 在 `BookInfoActions` 之后） |
| l10n | `app_strings.dart:1878` `charactersLabel = '角色'/'Characters'` | ⚠️ 参考版标题是「知识」（`book_info_knowledge`），我方用的是「角色」——**语义更准确但与参考版字面不同**，需用户裁决 |
| 缺的 l10n | `知识`/`关系网`/`剧情事件`/`男主`/`女主`/`男配`/`女配` 全部缺失（`grep 知识 app_strings.dart` → 0 命中） | 需补 7 个 key |
| 书籍编辑页知识卡片 | `flutter_legado/lib/src/screens/edit_book_info_screen.dart`（263 行，仅书名/作者/封面/简介） | ❌ 无 `BookKnowledgeEditCard` 对应物（参考版在 `BookInfoEditScreen.kt:223`，4 个按钮：人物/关系网/世界知识/剧情事件） |
| 角色详情/列表/关系图/知识/事件 5 个页面 | 不存在 | ❌ 全部未实现（参考版 5 个页面共 4568 行 Kotlin） |

### 4.5 编辑入口链路（参考版，供契约设计参考）

```
详情页 CharacterEntryCard 点击
  → BookInfoEffect.OpenCharacterDetail(bookUrl, characterId)
  → MainRouteBookCharacterDetail
  → BookCharacterDetailScreen（含「新建」态：characterId = null）

书籍编辑页 BookKnowledgeEditCard（BookInfoEditScreen.kt:223）
  → 4 个 MediumOutlinedButton：人物 / 关系网 / 世界知识 / 剧情事件
  → 对应 4 个路由（MainNavGraph:1475-1483）
```

我方要做最小闭环，**必须至少有其中一个入口**。推荐走「详情页区块内加一个 + 按钮」或「书籍编辑页加知识卡片（4 按钮中只启用人物）」，避免新增 5 个页面。

---

## 5. 与书源规则的关系

### 5.1 字段对比

| 版本 | `BookInfoRule` 字段数 | 字段清单 | characters 相关字段 |
|---|---|---|---|
| Android 原版（`legado-upstream`） | 12 | init/name/author/intro/kind/lastChapter/updateTime/coverUrl/tocUrl/wordCount/canReName/downloadUrls | **无** |
| 参考版 `legado-with-MD3`（`BookInfoRule.kt:12-26`） | **13** | 上述 12 + `relatedBooks` | **无** |
| 我方（`rust/legado-core/src/models/rule/book_info_rule.rs:5-38`） | 13（含 R42 阶段 1 新增 `related_books`） | 同上 13 | **无** |

### 5.2 结论

- **角色卡数据完全不走书源规则**：5 张表没有任何字段来自 `BookSource`/`BookInfoRule`；写入方全部是「本地用户操作 / AI 生成 / 配音镜像」。
- 交叉验证：`grep -rn "character" legado-with-MD3/.../data/entities/rule/` 无命中；`AiToolRepository` 的角色写入也不读规则。
- **因此：不需要任何书源规则扩展**。这与 RelatedBooks 形成鲜明对照（后者是纯规则驱动、零新表）。此点应在契约中明写，避免后续误判为「规则缺口」。

---

## 6. 契约草案（仅最小集）

> 命名遵循既有惯例：Dart `BookApi` 用 camelCase、Rust FFI 用 snake_case、JSON 跨边界用 camelCase（契约 §1.3）。返回列表一律**裸 JSON Array**（契约 §1.4 铁律）。

### 6.1 建议新增 3 个方法（§2.56 角色卡 Characters）

| # | Dart（BookApi） | Rust FFI | 入参 | 返回 | 语义 |
|---|---|---|---|---|---|
| 1 | `getBookCharacters({required String bookUrl, int limit = 50})` | `get_book_characters(book_url: String, limit: u32) -> Result<String, BridgeError>` | bookUrl、limit | `Future<String>` — **裸 JSON 数组** `[{id,bookUrl,name,aliasesJson,avatarUri,tagsJson,role,voiceGender,voiceAgeBand,personality,summary,status,source,confidence,schemaVersion,createdAt,updatedAt}]` | 对齐 `getCharacterProfiles`：`status != 3`、`order by updatedAt desc`、limit clamp `1..500`（默认 50，与详情页一致）。bookUrl 空/无数据 → `[]`（**不抛错**） |
| 2 | `saveBookCharacter({required String profileJson})` | `save_book_character(profile_json: String) -> Result<String, BridgeError>` | 档案 JSON（同 #1 字段，`id` 可空） | `Future<String>` — 落库后的完整对象 JSON | `INSERT OR REPLACE`。`id` 空串 → Rust 生成 UUID v4；`createdAt <= 0` → 当前毫秒；`updatedAt` **恒写当前毫秒**；`source` 缺省 `"user"`、`status` 缺省 `1`、`confidence` 缺省 `1.0`；`name` 空白 → 参数错误。**UNIQUE(bookUrl,name) 冲突**：同 id 覆盖；不同 id 同名 → 抛错（或按参考版语义改为按 name 查重后覆盖，需裁决，见 §7.3） |
| 3 | `deleteBookCharacter({required String bookUrl, required String characterId})` | `delete_book_character(book_url: String, character_id: String) -> Result<(), BridgeError>` | bookUrl、characterId | `Future<void>` | 硬删档案行；不存在为 no-op（对齐 `deleteCharacterProfile` 的 DAO 语义，但**裁掉** `deleteRelations`/`deleteEvents` 两开关——最小集不建这两张表） |

### 6.2 可选第 4 个（若做「点卡片编辑」需要回填）

| # | Dart | Rust FFI | 入参 | 返回 |
|---|---|---|---|---|
| 4 | `getBookCharacter({required String bookUrl, required String idOrName})` | `get_book_character(book_url, id_or_name) -> Result<String, BridgeError>` | — | `Future<String>` — 单对象 JSON 或 `"null"` |

> 注：若 UI 层的编辑页数据来自 #1 的列表缓存（点击时直接带对象过去），则 #4 可省。**推荐先省**。

### 6.3 契约登记要素（实施时须一并写入 `docs/API_CONTRACT.md`）

- 新增 §2.56「角色卡 Characters（bookKnowledge FFI，3 个方法）」
- 附录：合计 **351 → 354**；BookApi **350 → 353**；同名行 335 → **338**；§1.7 表 B 174（不变）
- DB：`SCHEMA_VERSION` **119 → 120**，新增 `book_character_profiles` 表 + 2 索引（1 unique）
- 明确声明：**不纳入备份**（参考版 `Backup.kt:69-92` 与 `Restore.kt:130-240` 均无这 5 张表 → 我方同样不纳入，保持「与参考版一致」）
- 明确声明：**无外键**（对齐参考版 `foreignKeys = null`）
- 明确声明：**不需要书源规则扩展**（§5 结论）

### 6.4 Rust 侧落地结构（对齐既有 DB-only 功能范式，以 `book_marks` 为模板）

| 层 | 文件 | 参考规模 |
|---|---|---|
| 模型 | `rust/legado-core/src/models/book_character.rs` | `book_marking.rs` 141 行 |
| 仓储 | `rust/legado-db/src/repository/book_character_repository.rs` | `book_marking_repository.rs` 503 行（含测试） |
| 迁移 | `rust/legado-db/src/migration/book_characters_v120.rs` | `book_marks_v118.rs` 216 行 |
| DDL | `rust/legado-db/src/schema.rs` 加 `CREATE_BOOK_CHARACTER_PROFILES` + 索引常量 | — |
| FFI 实现 | `rust/legado-ffi/src/api/book_character_api.rs` | `book_marking_api.rs` 256 行 |
| FFI 桥 | `rust/legado-ffi/src/ffi.rs` 加 3 个 `pub fn` | — |
| codegen | `flutter_rust_bridge_codegen` 重生成 `frb_generated.rs` + `lib/src/bridge/ffi/ffi.dart` | — |
| Dart 模型 | `flutter_legado/lib/src/models/book_character.dart` | `book_marking.dart` 146 行 |
| Dart 服务 | `book_api.dart`（接口）+ `rust_api_content_ext.part.dart`（实现）+ `mock_book_api_content_ext.part.dart`（Mock） | 3 处 |
| Dart Provider | `flutter_legado/lib/src/providers/book_info/characters_provider.dart`（`FutureProvider.autoDispose.family<List<BookCharacter>, String>`） | `related_books_provider.dart` 参考 |
| UI | `book_info_screen_builders.part.dart::_buildCharactersSection` 替换常量 + 新增 `_CharacterEntryCard` | 参考版 2171-2321 |
| 编辑入口 | 二选一：详情页区块内「+」或 `edit_book_info_screen.dart` 加知识卡片 | — |

---

## 7. 工作量与风险

### 7.1 阶段划分建议

| 阶段 | 范围 | 工作量 | 依赖 | 可否独立交付 |
|---|---|---|---|---|
| **2A 手动录入最小闭环** | 1 张表 + 3 方法 + 详情页卡片 + 编辑入口 + 空态 | **4.5–6 人日** | 无 | ✅ **推荐先做** |
| 2B 角色列表页 + 角色详情/编辑页 | 2 个新页面（列表 422 行 + 详情 572 行 Kotlin 量级）+ 分页/筛选/头像选择/裁剪 | 5–7 人日 | 2A | ✅ 可独立 |
| 2C AI 识别入口 | 8 张 AI 表 + HTTP/SSE 客户端 + 工具调用框架 + 模型配置 UI + `IdentifyBookCharactersUseCase` | **12–15 人日**（且需产品决策：API Key 谁提供、隐私、成本） | 2B + 外部服务 | ❌ 强依赖外部 |
| 2D 事记 / 关系图 / 世界知识 / 大纲 | 3 张表 + 9 方法 + 3 个页面 | 8–12 人日 | 2A | ⚠️ 参考版「大纲」连 UI 都没有，建议永不做 |

### 7.2 2A 内部拆解

| 工作项 | 人日 | 说明 |
|---|---|---|
| 契约 §2.56 + 附录计数 | 0.3 | 3 方法、351→354、350→353 |
| DB 迁移 v119→v120（1 表 + 2 索引 + 开库自愈） | 0.5 | 对齐 `book_marks_v118.rs` 模式；须同时改 `schema.rs` 的 `SCHEMA_VERSION`/`init_schema`/`INDEXES` 与 `repair_legacy_columns` |
| `legado-core` 模型 + `legado-db` 仓储 + 测试 | 1.0 | 含 unique 冲突、limit clamp、status 过滤用例 |
| `legado-ffi` API + bridge + codegen | 0.7 | — |
| Dart 模型 + 三服务层 + 契约测试闭合 | 0.6 | 注意 `api_contract_test.dart` 的双向闭合会立即校验 |
| Provider + 详情页卡片 UI + l10n 7 key | 1.0 | 卡片 160dp 宽、36dp 头像、角色中文映射、tags `" | "` 拼接 |
| 编辑入口（最小：Sheet 或独立页表单） | 0.8 | 头像可选先不做（`avatarUri` 留空走 Person 图标） |
| 测试（widget + provider + 迁移 + FFI） | 0.8 | — |
| **合计** | **≈5.7** | 若砍掉头像/删除，可压到 **4.5** |

### 7.3 风险清单

| # | 风险 | 等级 | 说明与缓解 |
|---|---|---|---|
| R1 | **功能价值依赖 AI，不做 AI 则数据永远靠用户手填** | **高** | 用户可能填 3 个角色后放弃。缓解：先交付 2A，用真实使用反馈决定是否值得做 2B/2C；文档明写「无 AI 时数据全手动」 |
| R2 | **UNIQUE(bookUrl, name) 冲突语义需裁决（参考版自身有隐患）** | 中 | 实测：**UI 手动保存路径不做同名查重**——`BookCharacterDetailViewModel.save()`（`:167-221`）的 id 取 `existing?.id ?: state.characterId ?: Uuid.random()`，新建态（`characterId == null`）直接生成新 UUID；只有 **AI 路径** `IdentifyBookCharactersUseCase.save()`（`:195`）才先 `getCharacterProfile(bookUrl, name)` 复用已有 id。故参考版「同一本书手工新建两个同名角色」会命中 `UNIQUE(bookUrl,name)`，而 `@Insert(onConflict = REPLACE)` 会**静默删旧行**（旧角色的 id 变化 → 关系/事件/配音绑定全部指向失效 id）。**建议**：我方 FFI `saveBookCharacter` 在 id 为空时先按 `(bookUrl, name)` 查，命中则复用其 id 并返回（比参考版更安全），契约写明该行为。**注意 `getCharacterProfile` 的匹配是 `id = x or name = x or aliasesJson LIKE '%x%'`**（`BookKnowledgeDao.kt:51`），用 LIKE 查重会把「记着这个别名的别人」捞出来改名——参考版自己在 `CastProfileMirror.kt:31-33` 注释里明确否定了这种用法。故我方查重应**精确匹配 `name`**（`WHERE bookUrl=? AND name=?`），不要复用 `getCharacterProfile` |
| R3 | **schema 迁移 119→120** | 中 | 风险可控（纯建表，无数据回填）。但须同时覆盖：① `schema.rs` `SCHEMA_VERSION` + `init_schema` + `INDEXES`；② `migration.rs` 注册 `Migration119To120`；③ `repair_legacy_columns` 开库自愈（防「版本已到 120 但缺表」）。参考 `book_marks_v118` 有完整先例 |
| R4 | **换源后 bookUrl 变化 → 角色丢失** | 中 | 5 张表全部以 `bookUrl` 为键，**参考版换源不迁移这些表**（`ChangeBookSourceUseCase.kt:102-120` 只迁章节/阅读记录，无 bookKnowledge）。我方 `originBookUrl` 已有跨源机制，但若照抄参考版则换源后角色全部失联。**建议**：2A 阶段照抄参考版（不迁移），在契约「已知差异」登记；后续若要修，用 `books.originBookUrl` 做跨源查找 |
| R5 | **删书不清理孤儿行** | 中 | 参考版删书**也不清理**（`grep bookKnowledgeDao 删除` 仅配音链与角色详情页 2 处，无删书联动）。我方若照抄会积累孤儿行。**建议**：FFI 侧提供按 bookUrl 批量删除，或删书流程加一步；至少登记 |
| R6 | **标题文案与参考版不一致** | 低 | 参考版区块标题是「知识」（`book_info_knowledge`）但内容是人物卡（既有瑕疵）。我方 `charactersLabel = '角色'`。**需用户裁决**：照抄「知识」（一比一）还是用「角色」（语义正确） |
| R7 | **不纳入备份** | 低 | 参考版不备份这 5 张表 → 换机/恢复备份后角色全丢。**建议**：照抄（保持一致性），但在契约与 CHANGELOG 明写「角色卡不随备份迁移」 |
| R8 | **AI 阶段的范围失控** | 高 | 若一并做 2C，需 8 张表 + 16K 行 AI 栈；应明确**拒绝**在 R42 阶段 2 内做 AI |

---

## 8. 结论与建议

### 8.1 值不值得做

**值得做「最小手动闭环」，不值得在 R42 阶段 2 内做 AI。**

判断依据：

1. **授权已明确**（2026-09-05 §〇），且参考版自身在无 AI 配置时同样只能手动建档 → 手动路径是参考版的**合法子集**，不是「自创功能」。
2. **成本可控**：1 张表（17 列）+ 3 个 FFI 方法 + 1 个区块改造 ≈ 5 人日，远低于 RelatedBooks 之外任何媒体功能。
3. **但收益有限**：数据要靠用户自己填；参考版把这块的主要价值押在 AI 识别上（`BookCharacterListScreen.kt:125` 的 AI 按钮是列表页 TopBar 的主操作）。
4. **AI 路径在本仓是「另一个工程」**：78 个 AI 文件 / 16324 行 + 8 张表 + 外部 LLM 服务，且我方 `ai_chat_screen.dart` 明写「不接任何 LLM/网络能力」——这不是 R42 阶段 2 能吞下的量。

### 8.2 建议的最小可行范围（2A）

**做**：

- 1 张表 `book_character_profiles`（17 列 + 2 索引，含 unique）
- 3 个 FFI 方法：`getBookCharacters` / `saveBookCharacter` / `deleteBookCharacter`
- DB `SCHEMA_VERSION` 119 → 120
- 详情页 `_buildCharactersSection` 接通真实数据（160dp 卡片、36dp 圆形头像、角色中文映射、tags 竖线拼接、`summary` 不上卡片）
- 一个编辑入口（推荐：书籍编辑页加知识卡片，只启用「人物」1 个按钮 —— 与参考版位置一致，且不新增页面）
- 空态隐藏（无数据整块不渲染，对齐参考版）

**不做**（明确排除，避免范围蔓延）：

- 4 张表（events / relations / knowledge_entries / outline_nodes）——无 UI 消费方（参考版 `BookInfoKnowledge`/`BookInfoEvents` 是死代码，大纲连 UI 都没有）
- 12 个 gateway 方法（其中 8 个只服务 AI 工具）
- AI 识别（独立立项，需先决策 API Key / 隐私 / 成本）
- 人物列表页 / 角色详情页 / 关系图 / 世界知识 / 事件 5 个页面（参考版共 4568 行）
- 头像选择与裁剪（`CharacterAvatarSourceSheet` 130 行 + `CharacterAvatarCropDialog` 168 行）—— 2A 先留空走 Person 图标，`avatarUri` 字段先建模不填
- 配音角色镜像（`CastProfileMirror` / `CastMemoryMirror`）—— 我方无配音链

### 8.3 待用户裁决项

| # | 裁决点 | 选项 |
|---|---|---|
| D1 | 区块标题文案 | A：照抄参考版「知识」（一比一，但语义错位）／B：用我方既有 `charactersLabel = '角色'`（语义正确，与参考版字面不同） |
| D2 | 同书同名重复建档 | A：FFI 层按 `(bookUrl,name)` 查重后复用 id（对齐参考版 `save()`）／B：直接抛错让 UI 提示「已存在同名角色」 |
| D3 | 是否在 2A 就做「删除」 | A：做（3 方法）／B：不做（2 方法，靠直接改库清理） |
| D4 | 换源后角色归属 | A：照抄参考版不迁移（登记为已知差异）／B：用 `originBookUrl` 做跨源续接（额外工作量） |
| D5 | 是否纳入备份 | A：照抄参考版不纳入（登记）／B：纳入我方备份格式（额外格式版本 +1） |

### 8.4 若后续要做 AI（2C）的前置条件

1. 用户明确提供 LLM 服务方案（API Key 归属、是否允许外发书籍正文、成本上限）。
2. 先建 8 张 `ai_*` 表 + 模型配置 UI（`ai_provider_profiles` / `ai_model_profiles` / `ai_task_presets` 三张是识别链的硬依赖）。
3. 工具调用框架（`AiToolAwareGenerationUseCase` + `AiToolRepository` 21 个工具）——角色识别**强依赖模型能调工具读章节**，纯 chat completion 拿不到正文。
4. 与「AI 摘要/改写」合并立项（同一套 AI 栈），不要单独为角色卡建 AI 基础设施。

---

## 附录 A：取证文件清单

| 用途 | 路径 |
|---|---|
| 5 表 DDL（v95 首现 / v97 加列 / v133 现状） | `legado-with-MD3/app/schemas/io.legado.app.data.AppDatabase/{95,96,97,103,104,133}.json` |
| 实体类 | `legado-with-MD3/app/src/main/java/io/legado/app/data/entities/BookKnowledge.kt` |
| DAO（16 SQL） | `legado-with-MD3/app/src/main/java/io/legado/app/data/dao/BookKnowledgeDao.kt` |
| Gateway 接口 | `legado-with-MD3/app/src/main/java/io/legado/app/domain/gateway/BookKnowledgeGateway.kt` |
| Gateway 实现（含 500 上限） | `legado-with-MD3/app/src/main/java/io/legado/app/data/repository/BookKnowledgeRepository.kt` |
| 详情页 VM（排序/映射） | `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/info/BookInfoViewModel.kt:1889-1924` |
| 详情页 UI（卡片） | `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/info/BookInfoScreen.kt:2171-2321` |
| 详情页 UI 模型 | `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/info/BookInfoContract.kt:127-134` |
| 手动录入写入方 | `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/knowledge/BookCharacterDetailViewModel.kt:170-240` |
| AI 识别链 | `legado-with-MD3/app/src/main/java/io/legado/app/domain/usecase/IdentifyBookCharactersUseCase.kt` |
| AI 工具落库 | `legado-with-MD3/app/src/main/java/io/legado/app/data/repository/AiToolRepository.kt:526-700` |
| 配音镜像 | `legado-with-MD3/app/src/main/java/io/legado/app/help/readaloud/cast/CastProfileMirror.kt` |
| 书源规则字段 | `legado-with-MD3/app/src/main/java/io/legado/app/data/entities/rule/BookInfoRule.kt` |
| 参考版备份清单 | `legado-with-MD3/app/src/main/java/io/legado/app/help/storage/Backup.kt:69-92`、`Restore.kt:130-240` |
| 参考版换源 | `legado-with-MD3/app/src/main/java/io/legado/app/domain/usecase/ChangeBookSourceUseCase.kt:99-122` |
| 我方 schema / 版本 | `rust/legado-db/src/schema.rs:96`（`SCHEMA_VERSION = 119`）、`:174-840`（31 表） |
| 我方迁移注册 | `rust/legado-db/src/migration.rs:75-92` |
| 我方 DB-only 范式模板 | `rust/legado-db/src/migration/book_marks_v118.rs`、`rust/legado-ffi/src/api/book_marking_api.rs` |
| 我方 Characters 骨架 | `flutter_legado/lib/src/screens/book_info_screen_builders.part.dart:1637-1668`（调用点 `:1076`） |
| 我方 Provider 范式 | `flutter_legado/lib/src/providers/book_info/related_books_provider.dart` |
| 我方 AI 现状 | `flutter_legado/lib/src/screens/ai_chat_screen.dart`（32 行占位）、`read_aloud_settings_screen.dart:1289`（角色页签置灰） |
| 我方契约计数基线 | `docs/API_CONTRACT.md`：附录合计 351、BookApi 350、§1.7 表 B 174 |

## 附录 B：环境检查

- `flutter_legado/analysis_options.yaml` 存在（`include: package:flutter_lints/flutter.yaml`，排除 `*.freezed.dart`/`*.g.dart`/`lib/src/bridge/**`）
- `dart analyze`（在 `flutter_legado/` 下执行）：**No issues found!**（退出码 0）
- 工具链：Flutter SDK `D:/Flutter/SDK/flutter`（`flutter` / `dart` 均在 PATH）
- 未执行 `cargo test`（只读调研，且按约束不跑有副作用的构建）

---

编写：调研员子代理 ｜ 2026-11-23
