# Characters 2A 角色卡 — MuMu 真机验收报告

- 验收时间：2026-11-23 20:22–20:31
- 代码基线：`25f12a9ddf`（HEAD）
- 设备：MuMu `192.168.100.63:5555`（SM_G9900 / r9q，Android 15）
- 应用：`io.legado.flutter_legado`，versionName `2.0.514` / versionCode `515`
- APK：`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`（221,051,496 B）
- APK sha256：`16ec132b5a822d6dfe0a2e7d298c54b2f5cca7fafe1b94f104f9d083d899989f`
- DB：`/data/data/io.legado.flutter_legado/app_flutter/legado.db`，`pragma user_version = 120`
- 在线书：`QA25 段评书`（bookUrl `http://192.168.100.52:8925/book1.html`）
- 本地书：`big_gbk_cn`（bookUrl `/data/user/0/io.legado.flutter_legado/files/external_import/big_gbk_cn.txt`）

## 设备显示坐标说明（关键）

应用窗口位于**逻辑 display 28**，与默认 display 0 不同：

- 输入 / dump 必须带 `-d 28`：`adb shell input -d 28 tap X Y`、`adb shell uiautomator dump --display 28`
- 截图必须用 SurfaceFlinger **physical uniqueId 数值**：`adb exec-out screencap -p -d 4619827807345747227`
  - `screencap -d 28`（逻辑 id）返回 `Status: -2`，产出 56 B 空文件
  - `screencap -d local:4619827807345747227` 返回 44 B 文本告警
  - 不带 `-d` 默认抓 display 0（桌面），会得到 2.6 MB 的**错误屏幕**
- 全部 17 张截图已校验 PNG 头 `89504e47` 且 > 1 KB

## 逐点结论

| # | 验收点 | 结论 | 证据 |
|---|---|---|---|
| 1 | 详情页无数据时角色区块整块不显示 | **PASS** | `01_detail_no_section_a.png`、`01_detail_scrolled_no_section_b.png` |
| 2 | 书籍编辑页应有「角色管理」入口 | **PASS** | `02_edit_entry_visible.png` |
| 3 | 角色管理空态「还没有人物档案」 | **PASS** | `03_manage_empty_state.png` |
| 4 | 新增角色后详情页显示姓名与「男主」 | **PASS** | `04a_add_form_filled.png`、`04b_manage_list_one_row.png`、`04c_detail_section_visible.png`、`db_step4.txt` |
| 5 | 同名再建复用同一行（D2=A） | **PASS** | `05a_duplicate_name_form.png`、`05b_manage_still_one_row.png`、`db_step5_before.txt`、`db_step5_after.txt` |
| 6 | 编辑改名保存成功 | **PASS** | `06a_edit_rename_form.png`、`06b_manage_renamed.png`、`06c_detail_renamed.png`、`db_step6.txt` |
| 7 | 删除后详情页区块消失 | **PASS** | `07a_delete_confirm.png`、`07b_manage_empty_after_delete.png`、`07c_detail_section_gone.png`、`db_step7.txt` |
| 8 | 本地书不显示角色管理入口 | **PASS** | `08a_local_book_detail_no_section.png`、`08b_local_edit_no_entry.png` |

**8 / 8 PASS。**

## 逐步证据摘要

### 点 1 — 空数据隐藏区块
详情页（QA25 段评书）整页滚动前后语义树均无「角色」节点；`_buildCharactersSection` 对 `characters.isEmpty` 返回 `const []`。

### 点 2 — 编辑页入口
编辑页底部出现卡片：`角色` / 副标题 `手动建档，详情页展示角色卡`，可点击。

### 点 3 — 空态文案
角色管理对话框标题「角色管理」，正文「还没有人物档案」，底部「关闭」+「新增角色」。

### 点 4 — 新增并显示
表单填入：角色名 `测试角色`、定位 `男主`、标签 `温柔|冷静`（`|` 分隔被正确拆为两个标签）。
保存后列表 1 行，详情页出现「角色」区块，卡片显示 `测试角色` / `男主` / `温柔 | 冷静`。

DB（`db_step4.txt`）：
```
d95f1820-ec70-441d-8591-830381446e70|测试角色|male_lead|["温柔","冷静"]|1
```
行数 = **1**。

### 点 5 — 同名复用（D2=A 核心）
新增前（`db_step5_before.txt`）：
```
d95f1820-ec70-441d-8591-830381446e70|测试角色|male_lead|["温柔","冷静"]|1795436751973
```
以同名 `测试角色`（本次未设定位/标签）再保存一次，保存后（`db_step5_after.txt`）：
```
d95f1820-ec70-441d-8591-830381446e70|测试角色||[]|1795436808482
```

- **行数仍为 1（不是 2）**
- **id 完全不变**：`d95f1820-ec70-441d-8591-830381446e70`
- `createdAt` 保持 `1795436751973` 未变，`updatedAt` 推进到 `1795436808482`
- 语义树列表仍只有一行，副标题消失（因 role/tags 被本次空值覆盖）

**字段被空值覆盖是契约既有语义，不是缺陷**：契约 §2.56 明写「id 为空时按 `(bookUrl, name)` 精确查重，命中则**复用其 id 并更新该行**」，实现见 `rust/legado-ffi/src/api/book_character/api::save_book_character`（空 id → `find_by_name` → 复用 `id`/`createdAt` → `upsert` 整行覆盖）。由于表单是「新增」而非「编辑」，用户未填的字段即为空，覆盖符合预期。

### 点 6 — 编辑改名
编辑对话框预填 `测试角色`，改为 `测试角色改名` 后保存：
```
d95f1820-ec70-441d-8591-830381446e70|测试角色改名||[]|1795436751973|1795436854835
```
- id 不变、`createdAt` 不变（`1795436751973`）、`updatedAt` 更新
- 列表与详情页均显示 `测试角色改名`
- 未出现「已存在同名角色」错误（按 id 覆盖自身路径正确）

### 点 7 — 删除
删除确认框文案含角色名：「确定删除角色「测试角色改名」？」。
确认后对话框回到空态「还没有人物档案」，返回详情页「角色」区块消失。

DB（`db_step7.txt`）：
```
(empty result: 0 rows)
0
```
行数 = **0**（硬删，非 status=3 软删）。

### 点 8 — 本地书无入口
本地书 `big_gbk_cn`：
- 详情页无「角色」区块（`_isOnlineBook` 短路）
- 编辑页连续滚动到页面底部（反复 swipe 后布局不再位移），语义树「角色」出现 **0 次**，无角色管理卡片

## 清理与还原

| 项 | 状态 |
|---|---|
| 测试角色已删除 | 是（DB `book_character_profiles` = 0 行） |
| 应用 force-stop | 是（`pidof` 无输出） |
| `/sdcard` 临时文件 | 已删（`qa_dump.xml` 不存在） |
| 产品代码 / 版本号 / CHANGELOG / 契约 | 未改动 |

## 未覆盖 / 说明

- 点 5 的「同名新建覆盖旧字段」是契约设计语义，本次按验收清单只判定「是否复用同一行」，未视为缺陷；若产品期望「同名新建应保留旧字段」则需另行裁决（当前契约不支持该语义）。
- 未验证换源后角色迁移、备份恢复、删书孤儿行清理——这三项按 D4=A/D5=A 裁决明确为「不迁移/不备份/不清理」，不在本轮 8 点范围。
